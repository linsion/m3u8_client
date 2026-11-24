import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../models/models.dart';
import 'api_client.dart';
import 'proxy_routing_service.dart';
import 'remote_storage_service.dart';

/// Pure Dart SMB2 (SMB 2.0.2 / 2.1) Client & Local HTTP Range Streaming Gateway
/// Supports NAS / Windows / Samba / macOS / OpenWrt SMB shares across all platforms
/// (Android TV, Android, iOS, macOS, Windows, Linux).
class SmbClientService {
  SmbClientService._();
  static final SmbClientService instance = SmbClientService._();

  final Map<String, StorageMount> _registeredMounts = {};
  final Map<String, String> _sniffedMimeCache = {};
  final Map<String, List<_Smb2Connection>> _idleConnections = {};
  HttpServer? _proxyServer;
  int _proxyPort = 0;
  Future<int>? _startingServer;

  String _poolKey(
    String host,
    int port,
    String share,
    String username,
    String password,
    String domainHint,
  ) =>
      '${host.toLowerCase()}:$port:${share.toLowerCase()}:$username:$domainHint:${password.hashCode}';

  Future<_Smb2Connection> _acquirePooledConnection({
    required String host,
    required int port,
    required String share,
    required String username,
    required String password,
    required String domainHint,
  }) async {
    final key = _poolKey(host, port, share, username, password, domainHint);
    final list = _idleConnections[key];
    while (list != null && list.isNotEmpty) {
      final candidate = list.removeLast();
      if (!candidate.isClosed &&
          DateTime.now().difference(candidate.lastUsedAt).inSeconds < 25) {
        candidate.lastUsedAt = DateTime.now();
        return candidate;
      }
      unawaited(candidate.close());
    }
    final conn = await _Smb2Connection.connectAndAuthenticate(
      host: host,
      port: port,
      username: username,
      password: password,
      domainHint: domainHint,
    );
    try {
      await conn.treeConnect(share);
      conn.lastUsedAt = DateTime.now();
      return conn;
    } catch (_) {
      await conn.close();
      rethrow;
    }
  }

  void _releasePooledConnection({
    required String host,
    required int port,
    required String share,
    required String username,
    required String password,
    required String domainHint,
    required _Smb2Connection conn,
  }) {
    if (conn.isClosed) return;
    final key = _poolKey(host, port, share, username, password, domainHint);
    final list = _idleConnections.putIfAbsent(key, () => <_Smb2Connection>[]);
    if (list.length >= 4) {
      final oldest = list.removeAt(0);
      unawaited(oldest.close());
    }
    conn.lastUsedAt = DateTime.now();
    list.add(conn);
  }

  Future<void> _clearConnectionPool() async {
    final all = _idleConnections.values.expand((e) => e).toList();
    _idleConnections.clear();
    for (final c in all) {
      unawaited(c.close());
    }
  }

  void registerMount(StorageMount mount) {
    if (mount.kind == StorageSourceKind.smb) {
      _registeredMounts[mount.id] = mount;
    }
  }

  /// Parses an SMB mount's `baseUrl` and `path` into:
  /// - `host`: IP or hostname
  /// - `port`: TCP port (default 445)
  /// - `share`: SMB share name (empty if at server root `/` listing shares)
  /// - `relPath`: path inside the share using `\` (empty if at share root)
  /// - `virtualPath`: normalized `/share/subpath` for UI display
  static ({
    String host,
    int port,
    String share,
    String relPath,
    String virtualPath,
  }) parseSmbTarget(StorageMount mount, String requestedPath) {
    var rawBase = mount.baseUrl.trim();
    rawBase = rawBase.replaceAll('\\', '/');
    if (rawBase.toLowerCase().startsWith('smb://')) {
      rawBase = rawBase.substring(6);
    } else if (rawBase.toLowerCase().startsWith('cifs://')) {
      rawBase = rawBase.substring(7);
    } else if (rawBase.toLowerCase().startsWith('http://')) {
      rawBase = rawBase.substring(7);
    } else if (rawBase.toLowerCase().startsWith('https://')) {
      rawBase = rawBase.substring(8);
    }
    while (rawBase.startsWith('/')) {
      rawBase = rawBase.substring(1);
    }

    // Strip optional user:pass@ prefix in baseUrl
    final atIdx = rawBase.indexOf('@');
    final slashIdx = rawBase.indexOf('/');
    if (atIdx > 0 && (slashIdx < 0 || atIdx < slashIdx)) {
      rawBase = rawBase.substring(atIdx + 1);
    }

    String hostPort = rawBase;
    String baseSubPath = '';
    if (slashIdx >= 0) {
      final firstSlash = rawBase.indexOf('/');
      hostPort = rawBase.substring(0, firstSlash);
      baseSubPath = rawBase.substring(firstSlash + 1);
    }

    String host = hostPort.trim();
    int port = 445;
    if (host.startsWith('[')) {
      final closeBracket = host.indexOf(']');
      if (closeBracket > 0) {
        final ipv6 = host.substring(1, closeBracket);
        final rest = host.substring(closeBracket + 1);
        if (rest.startsWith(':')) {
          port = int.tryParse(rest.substring(1)) ?? 445;
        }
        host = ipv6;
      }
    } else {
      final colonIdx = host.lastIndexOf(':');
      if (colonIdx > 0) {
        final parsedPort = int.tryParse(host.substring(colonIdx + 1));
        if (parsedPort != null && parsedPort > 0 && parsedPort <= 65535) {
          port = parsedPort;
          host = host.substring(0, colonIdx);
        }
      }
    }

    final reqTrim = requestedPath.trim().replaceAll('\\', '/');
    final rootTrim = mount.rootPath.trim().replaceAll('\\', '/');
    String effectiveVirtual = reqTrim.isEmpty ? rootTrim : reqTrim;
    if (effectiveVirtual.isEmpty) effectiveVirtual = '/';
    if (!effectiveVirtual.startsWith('/')) {
      effectiveVirtual = '/$effectiveVirtual';
    }

    // If baseUrl already includes a share name (e.g. smb://192.168.1.10/Movies)
    // and effectiveVirtual doesn't start with that share name, prepend it when at root.
    final baseSegments = baseSubPath
        .split('/')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final reqSegments = effectiveVirtual
        .split('/')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    List<String> allSegments;
    if (baseSegments.isNotEmpty) {
      if (reqSegments.isEmpty) {
        allSegments = baseSegments;
      } else if (reqSegments.first.toLowerCase() ==
          baseSegments.first.toLowerCase()) {
        allSegments = reqSegments;
      } else {
        allSegments = [...baseSegments, ...reqSegments];
      }
    } else {
      allSegments = reqSegments;
    }

    final normVirtual =
        allSegments.isEmpty ? '/' : '/${allSegments.join('/')}';
    if (allSegments.isEmpty) {
      return (
        host: host,
        port: port,
        share: '',
        relPath: '',
        virtualPath: '/',
      );
    }
    final share = allSegments.first;
    final relPath =
        allSegments.length > 1 ? allSegments.sublist(1).join(r'\') : '';
    return (
      host: host,
      port: port,
      share: share,
      relPath: relPath,
      virtualPath: normVirtual,
    );
  }

  /// Ensures the local HTTP Range proxy server is running and returns a streamable URL
  /// for the given SMB file path.
  Future<String> buildLocalStreamUrl(
    StorageMount mount,
    String virtualPath, {
    String? fileNameHint,
  }) async {
    registerMount(mount);
    final port = await _ensureProxyServerStarted();
    final normPath = RemoteStorageService.normalizePath(virtualPath);
    final nameSegment = (fileNameHint != null && fileNameHint.trim().isNotEmpty)
        ? Uri.encodeComponent(fileNameHint.trim())
        : Uri.encodeComponent(
            normPath.split('/').where((s) => s.isNotEmpty).lastOrNull ??
                'stream.mp4',
          );
    return 'http://127.0.0.1:$port/smb-stream/$nameSegment?mount=${Uri.encodeQueryComponent(mount.id)}&path=${Uri.encodeQueryComponent(normPath)}';
  }

  String buildLocalStreamUrlSyncIfRunning(
    StorageMount mount,
    String virtualPath, {
    String? fileNameHint,
  }) {
    registerMount(mount);
    if (_proxyPort <= 0) {
      unawaited(_ensureProxyServerStarted());
      return 'smb://${mount.baseUrl}$virtualPath';
    }
    final normPath = RemoteStorageService.normalizePath(virtualPath);
    final nameSegment = (fileNameHint != null && fileNameHint.trim().isNotEmpty)
        ? Uri.encodeComponent(fileNameHint.trim())
        : Uri.encodeComponent(
            normPath.split('/').where((s) => s.isNotEmpty).lastOrNull ??
                'stream.mp4',
          );
    return 'http://127.0.0.1:$_proxyPort/smb-stream/$nameSegment?mount=${Uri.encodeQueryComponent(mount.id)}&path=${Uri.encodeQueryComponent(normPath)}';
  }

  Future<int> _ensureProxyServerStarted() async {
    if (_proxyServer != null && _proxyPort > 0) return _proxyPort;
    if (_startingServer != null) return _startingServer!;
    final completer = Completer<int>();
    _startingServer = completer.future;
    try {
      final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _proxyServer = srv;
      _proxyPort = srv.port;
      srv.listen(
        _handleProxyHttpRequest,
        onError: (_) {
          if (identical(_proxyServer, srv)) {
            _proxyServer = null;
            _proxyPort = 0;
          }
        },
        onDone: () {
          if (identical(_proxyServer, srv)) {
            _proxyServer = null;
            _proxyPort = 0;
          }
        },
      );
      completer.complete(_proxyPort);
      return _proxyPort;
    } catch (e) {
      _startingServer = null;
      completer.completeError(e);
      rethrow;
    }
  }

  /// Verifies that the local SMB HTTP Range gateway (`127.0.0.1:<port>`) is alive
  /// when returning from background or OS sleep, restarting it if needed.
  Future<void> resetAllSessions() async {
    await _clearConnectionPool();
    final srv = _proxyServer;
    final port = _proxyPort;
    if (srv == null || port <= 0) return;
    try {
      final probe = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 250),
      );
      probe.destroy();
    } catch (_) {
      if (identical(_proxyServer, srv)) {
        _proxyServer = null;
        _proxyPort = 0;
        _startingServer = null;
      }
      try {
        await srv.close(force: true);
      } catch (_) {}
      if (_registeredMounts.isNotEmpty) {
        unawaited(_ensureProxyServerStarted().catchError((_) => 0));
      }
    }
  }

  static String? sniffContainerMimeType(Uint8List head) {
    if (head.length < 12) return null;
    // Matroska / WebM EBML header: 1A 45 DF A3
    if (head[0] == 0x1A &&
        head[1] == 0x45 &&
        head[2] == 0xDF &&
        head[3] == 0xA3) {
      return 'video/x-matroska';
    }
    // RealMedia (.rm / .rmvb): ".RMF" (2E 52 4D 46)
    if (head[0] == 0x2E &&
        head[1] == 0x52 &&
        head[2] == 0x4D &&
        head[3] == 0x46) {
      return 'application/vnd.rn-realmedia';
    }
    // AVI / WAV: "RIFF" .... "AVI "
    if (head[0] == 0x52 &&
        head[1] == 0x49 &&
        head[2] == 0x46 &&
        head[3] == 0x46 &&
        head[8] == 0x41 &&
        head[9] == 0x56 &&
        head[10] == 0x49 &&
        head[11] == 0x20) {
      return 'video/x-msvideo';
    }
    // FLV: "FLV\x01"
    if (head[0] == 0x46 &&
        head[1] == 0x4C &&
        head[2] == 0x56 &&
        head[3] == 0x01) {
      return 'video/x-flv';
    }
    // Ogg: "OggS"
    if (head[0] == 0x4F &&
        head[1] == 0x67 &&
        head[2] == 0x67 &&
        head[3] == 0x53) {
      return 'video/ogg';
    }
    // ISO Base Media / MP4 / MOV: "ftyp" at offset 4
    if (head[4] == 0x66 &&
        head[5] == 0x74 &&
        head[6] == 0x79 &&
        head[7] == 0x70) {
      return 'video/mp4';
    }
    return null;
  }

  Future<void> _handleProxyHttpRequest(HttpRequest req) async {
    try {
      if (!req.uri.path.startsWith('/smb-stream')) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final mountId = req.uri.queryParameters['mount'] ?? '';
      final filePath = req.uri.queryParameters['path'] ?? '';
      final mount = _registeredMounts[mountId];
      if (mount == null || filePath.isEmpty) {
        req.response.statusCode = HttpStatus.notFound;
        req.response.write('SMB mount not found');
        await req.response.close();
        return;
      }

      final target = parseSmbTarget(mount, filePath);
      if (target.host.isEmpty || target.share.isEmpty || target.relPath.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        req.response.write('Invalid SMB file path');
        await req.response.close();
        return;
      }

      _Smb2Connection conn = await _acquirePooledConnection(
        host: target.host,
        port: target.port,
        share: target.share,
        username: mount.username,
        password: mount.password,
        domainHint: mount.token,
      );
      Uint8List? fileId;
      var canReturnToPool = true;
      try {
        ({Uint8List fileId, int fileSize, bool isDir}) opened;
        try {
          opened = await conn.openFileForRead(target.relPath);
        } catch (_) {
          // Pooled connection may have been closed by SMB server idle timeout; reconnect once
          await conn.close();
          conn = await _Smb2Connection.connectAndAuthenticate(
            host: target.host,
            port: target.port,
            username: mount.username,
            password: mount.password,
            domainHint: mount.token,
          );
          await conn.treeConnect(target.share);
          opened = await conn.openFileForRead(target.relPath);
        }
        fileId = opened.fileId;
        final totalSize = opened.fileSize;

        int start = 0;
        int end = totalSize > 0 ? totalSize - 1 : 0;
        bool isPartial = false;
        final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
        if (rangeHeader != null &&
            rangeHeader.startsWith('bytes=') &&
            totalSize > 0) {
          final spec = rangeHeader.substring(6).split(',').first.trim();
          final dash = spec.indexOf('-');
          if (dash >= 0) {
            final sStr = spec.substring(0, dash).trim();
            final eStr = spec.substring(dash + 1).trim();
            if (sStr.isEmpty && eStr.isNotEmpty) {
              final suffix = int.tryParse(eStr) ?? 0;
              start = math.max(0, totalSize - suffix);
              end = totalSize - 1;
              isPartial = true;
            } else if (sStr.isNotEmpty) {
              start = int.tryParse(sStr) ?? 0;
              end = eStr.isNotEmpty
                  ? (int.tryParse(eStr) ?? (totalSize - 1))
                  : (totalSize - 1);
              if (end >= totalSize) end = totalSize - 1;
              isPartial = true;
            }
          }
        } else if (rangeHeader == null && totalSize > 32 * 1024 * 1024) {
          // Serve large files as 206 Partial Content from byte 0 so demuxers
          // immediately recognize byte-range seeking support without waiting.
          isPartial = true;
        }

        if (totalSize > 0 && (start < 0 || start >= totalSize || start > end)) {
          req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */$totalSize',
          );
          await req.response.close();
          return;
        }

        final contentLength = totalSize > 0 ? (end - start + 1) : 0;
        final chunkSize = conn.safeReadChunkSize;
        Uint8List? prefetchedFirstChunk;
        final cacheKey = '${mount.id}:${target.virtualPath}';
        String mimeType =
            _sniffedMimeCache[cacheKey] ?? _guessMimeType(target.relPath);
        if (req.method.toUpperCase() != 'HEAD' &&
            contentLength > 0 &&
            start == 0) {
          final firstReadLen = math.min(contentLength, chunkSize);
          prefetchedFirstChunk = await conn.readFileChunk(
            fileId: fileId,
            offset: 0,
            length: firstReadLen,
          );
          final sniffed = sniffContainerMimeType(prefetchedFirstChunk);
          if (sniffed != null) {
            mimeType = sniffed;
            _sniffedMimeCache[cacheKey] = sniffed;
          }
        }

        req.response.statusCode =
            isPartial ? HttpStatus.partialContent : HttpStatus.ok;
        req.response.headers.set(
          HttpHeaders.contentTypeHeader,
          mimeType,
        );
        req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        req.response.headers.contentLength = contentLength;
        if (isPartial && totalSize > 0) {
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/$totalSize',
          );
        }
        req.response.bufferOutput = false;

        if (req.method.toUpperCase() == 'HEAD' || contentLength <= 0) {
          await req.response.close();
          return;
        }

        int offset = start;
        int remaining = contentLength;
        var clientDisconnected = false;
        unawaited(
          req.response.done.then<void>(
            (_) => clientDisconnected = true,
            onError: (Object _) => clientDisconnected = true,
          ),
        );
        if (prefetchedFirstChunk != null &&
            prefetchedFirstChunk.isNotEmpty &&
            !clientDisconnected) {
          LocalProxyTunnelBridge.recordDownstreamBytes(
            prefetchedFirstChunk.length,
          );
          req.response.add(prefetchedFirstChunk);
          offset += prefetchedFirstChunk.length;
          remaining -= prefetchedFirstChunk.length;
        }
        while (remaining > 0 && !clientDisconnected) {
          final int toRead = math.min(remaining, chunkSize);
          final chunk = await conn.readFileChunk(
            fileId: fileId,
            offset: offset,
            length: toRead,
          );
          if (chunk.isEmpty || clientDisconnected) break;
          LocalProxyTunnelBridge.recordDownstreamBytes(chunk.length);
          req.response.add(chunk);
          offset += chunk.length;
          remaining -= chunk.length;
        }
        if (!clientDisconnected) {
          await req.response.flush();
        }
        await req.response.close();
      } catch (_) {
        canReturnToPool = false;
        rethrow;
      } finally {
        if (fileId != null) {
          try {
            await conn.closeFile(fileId);
          } catch (_) {
            canReturnToPool = false;
          }
        }
        if (canReturnToPool && !conn.isClosed) {
          _releasePooledConnection(
            host: target.host,
            port: target.port,
            share: target.share,
            username: mount.username,
            password: mount.password,
            domainHint: mount.token,
            conn: conn,
          );
        } else {
          await conn.close();
        }
      }
    } catch (_) {
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  static String _guessMimeType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.mp4') || lower.endsWith('.m4v')) return 'video/mp4';
    if (lower.endsWith('.mkv')) return 'video/x-matroska';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.ts')) return 'video/mp2t';
    if (lower.endsWith('.flv')) return 'video/x-flv';
    if (lower.endsWith('.avi')) return 'video/x-msvideo';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.flac')) return 'audio/flac';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.m4a') || lower.endsWith('.aac')) return 'audio/mp4';
    if (lower.endsWith('.ogg') || lower.endsWith('.opus')) return 'audio/ogg';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.lrc') ||
        lower.endsWith('.srt') ||
        lower.endsWith('.ass') ||
        lower.endsWith('.txt')) {
      return 'text/plain; charset=utf-8';
    }
    return 'application/octet-stream';
  }

  // ===========================================================================
  // Directory Listing & Share Enumeration
  // ===========================================================================

  Future<FileDirectoryListing> listSmbDirectory(
    StorageMount mount,
    String path,
  ) async {
    registerMount(mount);
    await _ensureProxyServerStarted();

    final target = parseSmbTarget(mount, path);
    if (target.host.isEmpty) {
      throw const ApiException('请输入有效的 SMB 服务器 IP 或主机名');
    }

    final conn = await _Smb2Connection.connectAndAuthenticate(
      host: target.host,
      port: target.port,
      username: mount.username,
      password: mount.password,
      domainHint: mount.token,
    );
    try {
      // 1. If at root `/` with no share specified, enumerate SMB shares via SRVSVC over IPC$
      if (target.share.isEmpty) {
        final shares = await conn.enumerateShares();
        final entries = shares
            .map(
              (shareName) => FileEntry(
                name: shareName,
                path: '/$shareName',
                size: 0,
                modTime: 'SMB 共享目录',
                isDir: true,
                isMp4: false,
                ext: '',
                mountId: mount.id,
                sourceKind: StorageSourceKind.smb,
              ),
            )
            .toList();
        return FileDirectoryListing(
          path: '/',
          parent: '',
          root: '/',
          entries: entries,
        );
      }

      // 2. Connect to `\\host\share` and query directory entries
      await conn.treeConnect(target.share);
      final rawEntries = await conn.queryDirectory(target.relPath);
      final entries = <FileEntry>[];
      for (final item in rawEntries) {
        if (item.name == '.' ||
            item.name == '..' ||
            item.name == '.DS_Store' ||
            item.name.startsWith('._')) {
          continue;
        }
        final itemVirtualPath =
            RemoteStorageService.joinPath(target.virtualPath, item.name);
        String ext = '';
        if (!item.isDir) {
          final dot = item.name.lastIndexOf('.');
          if (dot > 0) ext = item.name.substring(dot).toLowerCase();
        }
        final directUrl = item.isDir
            ? ''
            : buildLocalStreamUrlSyncIfRunning(
                mount,
                itemVirtualPath,
                fileNameHint: item.name,
              );
        entries.add(
          FileEntry(
            name: item.name,
            path: itemVirtualPath,
            size: item.size,
            modTime: item.modTime,
            isDir: item.isDir,
            isMp4: ext == '.mp4',
            ext: ext,
            mountId: mount.id,
            sourceKind: StorageSourceKind.smb,
            rawDownloadUrl: directUrl,
          ),
        );
      }

      final rootNorm = RemoteStorageService.normalizePath(mount.rootPath);
      return FileDirectoryListing(
        path: target.virtualPath,
        parent: RemoteStorageService.parentPathOf(target.virtualPath),
        root: rootNorm,
        entries: entries,
      );
    } finally {
      await conn.close();
    }
  }

  // ===========================================================================
  // File Operations (Mkdir / Delete / Rename / Copy / Move / Upload)
  // ===========================================================================

  Future<void> createSmbFolder(
    StorageMount mount,
    String parentPath,
    String name,
  ) async {
    final fullVirtual = RemoteStorageService.joinPath(parentPath, name);
    final target = parseSmbTarget(mount, fullVirtual);
    if (target.share.isEmpty || target.relPath.isEmpty) {
      throw const ApiException('请先进入具体的 SMB 共享目录后再新建文件夹');
    }
    final conn = await _Smb2Connection.connectAndAuthenticate(
      host: target.host,
      port: target.port,
      username: mount.username,
      password: mount.password,
      domainHint: mount.token,
    );
    try {
      await conn.treeConnect(target.share);
      await conn.createDirectory(target.relPath);
    } finally {
      await conn.close();
    }
  }

  Future<void> deleteSmbEntry(
    StorageMount mount,
    String virtualPath, {
    bool isDir = false,
  }) async {
    final target = parseSmbTarget(mount, virtualPath);
    if (target.share.isEmpty || target.relPath.isEmpty) {
      throw const ApiException('无法删除 SMB 根共享节点');
    }
    final conn = await _Smb2Connection.connectAndAuthenticate(
      host: target.host,
      port: target.port,
      username: mount.username,
      password: mount.password,
      domainHint: mount.token,
    );
    try {
      await conn.treeConnect(target.share);
      await conn.deleteEntryRecursive(target.relPath, isDir: isDir);
    } finally {
      await conn.close();
    }
  }

  Future<void> moveOrCopySmbEntry({
    required StorageMount mount,
    required String srcVirtualPath,
    required String dstVirtualPath,
    required bool isMove,
  }) async {
    final srcTarget = parseSmbTarget(mount, srcVirtualPath);
    final dstTarget = parseSmbTarget(mount, dstVirtualPath);
    if (srcTarget.share.isEmpty ||
        srcTarget.relPath.isEmpty ||
        dstTarget.share.isEmpty ||
        dstTarget.relPath.isEmpty) {
      throw const ApiException('SMB 路径无效，请确认处于共享目录内');
    }
    final conn = await _Smb2Connection.connectAndAuthenticate(
      host: srcTarget.host,
      port: srcTarget.port,
      username: mount.username,
      password: mount.password,
      domainHint: mount.token,
    );
    try {
      await conn.treeConnect(srcTarget.share);
      if (isMove &&
          srcTarget.share.toLowerCase() == dstTarget.share.toLowerCase()) {
        await conn.renameEntry(srcTarget.relPath, dstTarget.relPath);
        return;
      }
      // Stream copy within share
      final openedSrc = await conn.openFileForRead(srcTarget.relPath);
      Uint8List? dstId;
      try {
        dstId = await conn.openFileForWrite(dstTarget.relPath);
        int offset = 0;
        final chunkSize = conn.safeWriteChunkSize;
        while (offset < openedSrc.fileSize) {
          final toRead = math.min(chunkSize, openedSrc.fileSize - offset);
          final chunk = await conn.readFileChunk(
            fileId: openedSrc.fileId,
            offset: offset,
            length: toRead,
          );
          if (chunk.isEmpty) break;
          await conn.writeFileChunk(
            fileId: dstId,
            offset: offset,
            data: chunk,
          );
          offset += chunk.length;
        }
      } finally {
        try {
          await conn.closeFile(openedSrc.fileId);
        } catch (_) {}
        if (dstId != null) {
          try {
            await conn.closeFile(dstId);
          } catch (_) {}
        }
      }
      if (isMove) {
        await conn.deleteEntryRecursive(srcTarget.relPath, isDir: false);
      }
    } finally {
      await conn.close();
    }
  }

  Future<void> uploadSmbStreamWithProgress({
    required StorageMount mount,
    required String targetDir,
    required String fileName,
    required Stream<List<int>> byteStream,
    required int totalBytes,
    required bool Function() isCancelled,
    required void Function(int sentBytes, int totalBytes, double speed)
        onProgress,
  }) async {
    final fullVirtual = RemoteStorageService.joinPath(targetDir, fileName);
    final target = parseSmbTarget(mount, fullVirtual);
    if (target.share.isEmpty || target.relPath.isEmpty) {
      throw const ApiException('请先进入具体的 SMB 共享目录后再上传文件');
    }
    final conn = await _Smb2Connection.connectAndAuthenticate(
      host: target.host,
      port: target.port,
      username: mount.username,
      password: mount.password,
      domainHint: mount.token,
    );
    Uint8List? fileId;
    try {
      await conn.treeConnect(target.share);
      fileId = await conn.openFileForWrite(target.relPath);
      final maxChunk = conn.safeWriteChunkSize;
      final buffer = BytesBuilder(copy: false);
      int offset = 0;
      final startedAt = DateTime.now().millisecondsSinceEpoch;
      int lastReportMs = 0;

      Future<void> flushChunk(Uint8List chunkBytes) async {
        if (isCancelled()) {
          throw const ApiException('用户已取消上传');
        }
        await conn.writeFileChunk(
          fileId: fileId!,
          offset: offset,
          data: chunkBytes,
        );
        offset += chunkBytes.length;
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs - lastReportMs >= 100 || offset >= totalBytes) {
          lastReportMs = nowMs;
          final elapsedSec =
              ((nowMs - startedAt) / 1000.0).clamp(0.1, 86400.0);
          onProgress(offset, totalBytes, offset / elapsedSec);
        }
      }

      await for (final part in byteStream) {
        if (isCancelled()) throw const ApiException('用户已取消上传');
        buffer.add(part);
        while (buffer.length >= maxChunk) {
          final all = buffer.takeBytes();
          final slice = Uint8List.sublistView(all, 0, maxChunk);
          if (all.length > maxChunk) {
            buffer.add(Uint8List.sublistView(all, maxChunk));
          }
          await flushChunk(slice);
        }
      }
      if (buffer.length > 0) {
        await flushChunk(buffer.takeBytes());
      }
      final elapsedSec =
          ((DateTime.now().millisecondsSinceEpoch - startedAt) / 1000.0)
              .clamp(0.1, 86400.0);
      onProgress(totalBytes, totalBytes, totalBytes / elapsedSec);
    } finally {
      if (fileId != null) {
        try {
          await conn.closeFile(fileId);
        } catch (_) {}
      }
      await conn.close();
    }
  }
}

// =============================================================================
// Internal SMB2 Protocol Engine (SMB 2.0.2 / 2.1 + NTLMv2 + SRVSVC)
// =============================================================================

class _SmbRawDirEntry {
  final String name;
  final int size;
  final String modTime;
  final bool isDir;

  const _SmbRawDirEntry({
    required this.name,
    required this.size,
    required this.modTime,
    required this.isDir,
  });
}

class _Smb2Connection {
  final String host;
  final int port;
  final Socket _socket;
  final StreamIterator<Uint8List> _reader;
  final BytesBuilder _rxBuffer = BytesBuilder(copy: false);

  int _messageId = 0;
  int _sessionId = 0;
  int _treeId = 0;
  int _serverSecurityMode = 0;
  int _serverCapabilities = 0;
  int _maxReadSize = 65536;
  int _maxWriteSize = 65536;
  Uint8List? _signingKey;
  bool isClosed = false;
  DateTime lastUsedAt = DateTime.now();

  _Smb2Connection._(this.host, this.port, this._socket)
      : _reader = StreamIterator<Uint8List>(_socket);

  bool get _supportsLargeMtu => (_serverCapabilities & 0x00000004) != 0;
  int get safeReadChunkSize =>
      math.min(_maxReadSize, _supportsLargeMtu ? 262144 : 65536);
  int get safeWriteChunkSize =>
      math.min(_maxWriteSize, _supportsLargeMtu ? 262144 : 65536);

  static Future<_Smb2Connection> connectAndAuthenticate({
    required String host,
    required int port,
    required String username,
    required String password,
    String domainHint = '',
  }) async {
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 10),
    );
    socket.setOption(SocketOption.tcpNoDelay, true);
    final conn = _Smb2Connection._(host, port, socket);
    try {
      await conn._negotiate();
      await conn._authenticate(
        rawUsername: username,
        password: password,
        domainHint: domainHint,
      );
      return conn;
    } catch (e) {
      await conn.close();
      rethrow;
    }
  }

  Future<void> close() async {
    isClosed = true;
    try {
      await _reader.cancel();
    } catch (_) {}
    try {
      _socket.destroy();
    } catch (_) {}
  }

  Future<Uint8List> _sendAndReceive({
    required int command,
    required Uint8List body,
    int flags = 0,
    int? creditChargeOverride,
    bool allowMoreProcessing = false,
    bool allowNoMoreFiles = false,
  }) async {
    while (true) {
      final creditCharge = creditChargeOverride ??
          ((_supportsLargeMtu && body.length > 65536)
              ? ((body.length - 1) ~/ 65536) + 1
              : (command == 0 ? 0 : 1));
      final msgId = _messageId;
      _messageId += math.max(1, creditCharge);
      final header = ByteData(64);
      // ProtocolId: \xFESMB
      header.setUint8(0, 0xFE);
      header.setUint8(1, 0x53);
      header.setUint8(2, 0x4D);
      header.setUint8(3, 0x42);
      header.setUint16(4, 64, Endian.little); // StructureSize
      header.setUint16(6, creditCharge, Endian.little); // CreditCharge
      header.setUint32(8, 0, Endian.little); // Status
      header.setUint16(12, command, Endian.little); // Command
      header.setUint16(14, 64, Endian.little); // CreditRequest
      final shouldSign = _signingKey != null &&
          _signingKey!.isNotEmpty &&
          command != 0 &&
          command != 1 &&
          ((_serverSecurityMode & 0x02) != 0 ||
              (_serverSecurityMode & 0x01) != 0);
      final effectiveFlags = shouldSign ? (flags | 0x00000008) : flags;
      header.setUint32(16, effectiveFlags, Endian.little);
      header.setUint32(20, 0, Endian.little); // NextCommand
      header.setUint64(24, msgId, Endian.little); // MessageId
      header.setUint32(32, 0xFEFF, Endian.little); // ProcessId
      header.setUint32(36, _treeId, Endian.little); // TreeId
      header.setUint64(40, _sessionId, Endian.little); // SessionId

      final packet = Uint8List(64 + body.length);
      packet.setRange(0, 64, header.buffer.asUint8List());
      packet.setRange(64, packet.length, body);

      if (shouldSign) {
        final hmac = crypto.Hmac(crypto.sha256, _signingKey!);
        final digest = hmac.convert(packet).bytes;
        packet.setRange(48, 64, digest.sublist(0, 16));
      }

      final frame = Uint8List(4 + packet.length);
      frame[0] = 0x00;
      frame[1] = (packet.length >> 16) & 0xFF;
      frame[2] = (packet.length >> 8) & 0xFF;
      frame[3] = packet.length & 0xFF;
      frame.setRange(4, frame.length, packet);

      _socket.add(frame);

      // Read response packets, skipping interim STATUS_PENDING (0x00000103) responses
      while (true) {
        final resp = await _readOnePacket().timeout(const Duration(seconds: 15));
        if (resp.length < 64) {
          throw const ApiException('SMB2 响应数据包长度不足');
        }
        final respData = ByteData.sublistView(resp);
        final status = respData.getUint32(8, Endian.little);
        final respFlags = respData.getUint32(16, Endian.little);
        // Interim STATUS_PENDING response
        if (status == 0x00000103 && (respFlags & 0x00000002) != 0) {
          continue;
        }
        final respSessionId = respData.getUint64(40, Endian.little);
        if (respSessionId != 0) {
          _sessionId = respSessionId;
        }
        final respTreeId = respData.getUint32(36, Endian.little);
        if (respTreeId != 0 && command == 0x0003) {
          _treeId = respTreeId;
        }

        if (status == 0x00000000 ||
            (allowMoreProcessing && status == 0xC0000016) ||
            (allowNoMoreFiles &&
                (status == 0x80000006 || status == 0x00000107))) {
          return resp;
        }
        throw ApiException(_formatNtStatusError(status, command));
      }
    }
  }

  Future<Uint8List> _readOnePacket() async {
    while (true) {
      final current = _rxBuffer.toBytes();
      if (current.length >= 4) {
        final pktLen =
            ((current[1] & 0xFF) << 16) | ((current[2] & 0xFF) << 8) | (current[3] & 0xFF);
        if (current.length >= 4 + pktLen) {
          _rxBuffer.clear();
          final pkt = Uint8List.sublistView(current, 4, 4 + pktLen);
          if (current.length > 4 + pktLen) {
            _rxBuffer.add(Uint8List.sublistView(current, 4 + pktLen));
          }
          return Uint8List.fromList(pkt);
        }
      }
      final hasMore = await _reader.moveNext();
      if (!hasMore) {
        throw const ApiException('SMB 服务器连接已断开');
      }
      _rxBuffer.add(_reader.current);
    }
  }

  Future<void> _negotiate() async {
    final body = ByteData(36 + 4);
    body.setUint16(0, 36, Endian.little); // StructureSize
    body.setUint16(2, 2, Endian.little); // DialectCount = 2
    body.setUint16(4, 0x0001, Endian.little); // SecurityMode: Signing Enabled
    body.setUint16(6, 0, Endian.little);
    body.setUint32(8, 0x00000004, Endian.little); // Capabilities: SMB2_GLOBAL_CAP_LARGE_MTU
    // ClientGuid (16 bytes)
    for (int i = 0; i < 16; i++) {
      body.setUint8(12 + i, (i * 17 + 0x42) & 0xFF);
    }
    body.setUint16(36, 0x0202, Endian.little); // SMB 2.0.2
    body.setUint16(38, 0x0210, Endian.little); // SMB 2.1

    final resp = await _sendAndReceive(
      command: 0x0000,
      body: body.buffer.asUint8List(),
    );
    if (resp.length >= 64 + 48) {
      final bd = ByteData.sublistView(resp, 64);
      _serverSecurityMode = bd.getUint16(2, Endian.little);
      final dialect = bd.getUint16(4, Endian.little);
      final serverCaps = bd.getUint32(24, Endian.little);
      if (dialect >= 0x0210 && (serverCaps & 0x00000004) != 0) {
        _serverCapabilities = serverCaps;
      }
      final maxRead = bd.getUint32(40, Endian.little);
      final maxWrite = bd.getUint32(44, Endian.little);
      final capLimit = _supportsLargeMtu ? 262144 : 65536;
      if (maxRead >= 4096) _maxReadSize = math.min(maxRead, capLimit);
      if (maxWrite >= 4096) _maxWriteSize = math.min(maxWrite, capLimit);
    }
  }

  Future<void> _authenticate({
    required String rawUsername,
    required String password,
    required String domainHint,
  }) async {
    String user = rawUsername.trim();
    String domain = domainHint.trim();
    if (user.contains('\\')) {
      final parts = user.split('\\');
      if (domain.isEmpty) domain = parts.first.trim();
      user = parts.sublist(1).join('\\').trim();
    } else if (user.contains('@')) {
      final parts = user.split('@');
      user = parts.first.trim();
      if (domain.isEmpty) domain = parts.sublist(1).join('@').trim();
    }

    try {
      await _performNtlmSessionSetup(
        user: user,
        password: password,
        domain: domain,
      );
    } catch (e) {
      // If anonymous login failed and username was empty, retry once with 'guest'
      if (user.isEmpty && password.isEmpty) {
        _sessionId = 0;
        _signingKey = null;
        await _performNtlmSessionSetup(
          user: 'guest',
          password: '',
          domain: domain,
        );
        return;
      }
      rethrow;
    }
  }

  Future<void> _performNtlmSessionSetup({
    required String user,
    required String password,
    required String domain,
  }) async {
    final type1 = _NtlmAuthHelper.buildType1Message();
    final secOut1 = _NtlmAuthHelper.wrapSpnegoNegTokenInit(type1);
    final reqBody1 = _buildSessionSetupBody(secOut1);

    final resp1 = await _sendAndReceive(
      command: 0x0001,
      body: reqBody1,
      allowMoreProcessing: true,
    );
    final respStatus1 = ByteData.sublistView(resp1).getUint32(8, Endian.little);
    if (respStatus1 == 0x00000000) {
      return;
    }

    final bd1 = ByteData.sublistView(resp1, 64);
    final secOffset = bd1.getUint16(4, Endian.little);
    final secLen = bd1.getUint16(6, Endian.little);
    if (secOffset + secLen > resp1.length || secLen < 8) {
      throw const ApiException('SMB2 NTLM 质询数据包无效');
    }
    final serverSecBuf = Uint8List.sublistView(resp1, secOffset, secOffset + secLen);
    final usedSpnego = serverSecBuf.isNotEmpty && serverSecBuf[0] == 0xA1;
    final challenge = _NtlmAuthHelper.extractType2Challenge(serverSecBuf);

    final authResult = _NtlmAuthHelper.buildType3Message(
      username: user,
      password: password,
      domain: domain,
      serverChallenge: challenge.serverChallenge,
      targetInfo: challenge.targetInfo,
      negotiateFlags: challenge.flags,
    );
    final secOut3 = usedSpnego
        ? _NtlmAuthHelper.wrapSpnegoNegTokenResp(authResult.type3Message)
        : authResult.type3Message;
    final reqBody3 = _buildSessionSetupBody(secOut3);

    await _sendAndReceive(
      command: 0x0001,
      body: reqBody3,
    );
    if (user.isNotEmpty && password.isNotEmpty) {
      _signingKey = authResult.sessionBaseKey;
    }
  }

  Uint8List _buildSessionSetupBody(Uint8List secBuf) {
    final out = Uint8List(24 + secBuf.length);
    final bd = ByteData.sublistView(out);
    bd.setUint16(0, 25, Endian.little); // StructureSize
    bd.setUint8(2, 0); // Flags
    bd.setUint8(3, 0x01); // SecurityMode: Signing Enabled
    bd.setUint32(4, 0, Endian.little); // Capabilities
    bd.setUint32(8, 0, Endian.little); // Channel
    bd.setUint16(12, 64 + 24, Endian.little); // SecurityBufferOffset
    bd.setUint16(14, secBuf.length, Endian.little); // SecurityBufferLength
    bd.setUint64(16, 0, Endian.little); // PreviousSessionId
    out.setRange(24, out.length, secBuf);
    return out;
  }

  Future<void> treeConnect(String shareName) async {
    final unc = '\\\\$host\\$shareName';
    final pathBytes = _encodeUtf16Le(unc);
    final body = Uint8List(8 + pathBytes.length);
    final bd = ByteData.sublistView(body);
    bd.setUint16(0, 9, Endian.little); // StructureSize
    bd.setUint16(2, 0, Endian.little); // Reserved
    bd.setUint16(4, 64 + 8, Endian.little); // PathOffset
    bd.setUint16(6, pathBytes.length, Endian.little); // PathLength
    body.setRange(8, body.length, pathBytes);

    await _sendAndReceive(command: 0x0003, body: body);
  }

  /// Enumerates disk shares on the SMB server via `\\host\IPC$` `\pipe\srvsvc` `NetrShareEnum` (Level 1)
  Future<List<String>> enumerateShares() async {
    await treeConnect(r'IPC$');
    final pipeId = await _createRaw(
      path: 'srvsvc',
      desiredAccess: 0x0012019F,
      fileAttributes: 0,
      shareAccess: 0x07,
      createDisposition: 1, // FILE_OPEN
      createOptions: 0,
    );
    try {
      // 1. DCE/RPC Bind for SRVSVC v3.0
      final bindPkt = Uint8List.fromList(<int>[
        0x05, 0x00, 0x0B, 0x03, 0x10, 0x00, 0x00, 0x00,
        0x48, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        0xB8, 0x10, 0xB8, 0x10, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
        // Abstract Syntax: SRVSVC UUID 4b324fc8-1670-01d3-1278-5a47bf6ee188 v3.0
        0xC8, 0x4F, 0x32, 0x4B, 0x70, 0x16, 0xD3, 0x01,
        0x12, 0x78, 0x5A, 0x47, 0xBF, 0x6E, 0xE1, 0x88,
        0x03, 0x00, 0x00, 0x00,
        // Transfer Syntax: NDR 32-bit 8a885d04-1ceb-11c9-9fe8-08002b104860 v2.0
        0x04, 0x5D, 0x88, 0x8A, 0xEB, 0x1C, 0xC9, 0x11,
        0x9F, 0xE8, 0x08, 0x00, 0x2B, 0x10, 0x48, 0x60,
        0x02, 0x00, 0x00, 0x00,
      ]);
      await writeFileChunk(fileId: pipeId.fileId, offset: 0, data: bindPkt);
      final bindAck = await readFileChunk(
        fileId: pipeId.fileId,
        offset: 0,
        length: 4096,
      );
      if (bindAck.length < 24 || bindAck[2] != 0x0C) {
        throw const ApiException('SMB SRVSVC 管道绑定失败，请在路径中直接填写共享目录名（如 /Movies）');
      }

      // 2. DCE/RPC NetrShareEnum Request (Opnum 15, Level 1)
      final serverUnc = '\\\\$host\x00';
      final uncUtf16 = _encodeUtf16Le(serverUnc);
      final charCount = serverUnc.length;
      final stub = BytesBuilder(copy: false);

      void addU32(int v) {
        final b = ByteData(4)..setUint32(0, v, Endian.little);
        stub.add(b.buffer.asUint8List());
      }

      addU32(0x00020000); // ServerUnc Referent ID
      addU32(charCount); // MaxCount
      addU32(0); // Offset
      addU32(charCount); // ActualCount
      stub.add(uncUtf16);
      while ((stub.length % 4) != 0) {
        stub.addByte(0);
      }
      addU32(1); // Level = 1
      addU32(1); // SwitchIs = 1
      addU32(0x00020004); // CtrlPtr (SHARE_INFO_1_CONTAINER)
      addU32(0); // EntriesRead = 0
      addU32(0); // BufferPtr = NULL
      addU32(0xFFFFFFFF); // PreferedMaximumLength
      addU32(0x00020008); // ResumeHandlePtr
      addU32(0); // ResumeHandle = 0

      final stubBytes = stub.toBytes();
      final rpcReq = Uint8List(24 + stubBytes.length);
      final rpcBd = ByteData.sublistView(rpcReq);
      rpcBd.setUint8(0, 5); // Version 5
      rpcBd.setUint8(1, 0); // Minor 0
      rpcBd.setUint8(2, 0); // PacketType: Request (0)
      rpcBd.setUint8(3, 0x03); // Flags: FirstFrag | LastFrag
      rpcBd.setUint32(4, 0x00000010, Endian.little); // DataRep
      rpcBd.setUint16(8, rpcReq.length, Endian.little); // FragLength
      rpcBd.setUint16(10, 0, Endian.little); // AuthLength
      rpcBd.setUint32(12, 2, Endian.little); // CallId
      rpcBd.setUint32(16, stubBytes.length, Endian.little); // AllocHint
      rpcBd.setUint16(20, 0, Endian.little); // ContextId
      rpcBd.setUint16(22, 15, Endian.little); // Opnum = 15 (NetrShareEnum)
      rpcReq.setRange(24, rpcReq.length, stubBytes);

      await writeFileChunk(fileId: pipeId.fileId, offset: 0, data: rpcReq);

      final rpcStubOut = BytesBuilder(copy: false);
      while (true) {
        final frag = await readFileChunk(
          fileId: pipeId.fileId,
          offset: 0,
          length: 16384,
        );
        if (frag.length < 24 || frag[2] != 0x02) break;
        final flags = frag[3];
        final fragLen =
            ByteData.sublistView(frag).getUint16(8, Endian.little);
        final end = math.min(frag.length, fragLen);
        if (end > 24) {
          rpcStubOut.add(Uint8List.sublistView(frag, 24, end));
        }
        if ((flags & 0x02) != 0) break; // LastFrag
      }

      return _parseNetrShareEnumLevel1(rpcStubOut.toBytes());
    } finally {
      try {
        await closeFile(pipeId.fileId);
      } catch (_) {}
    }
  }

  List<String> _parseNetrShareEnumLevel1(Uint8List stub) {
    if (stub.length < 24) return const <String>[];
    final bd = ByteData.sublistView(stub);
    final entriesRead = bd.getUint32(12, Endian.little);
    final arrayPtr = bd.getUint32(16, Endian.little);
    if (entriesRead == 0 || arrayPtr == 0 || entriesRead > 2048) {
      return const <String>[];
    }
    int pos = 24; // Past Level, Switch, ContainerPtr, EntriesRead, ArrayPtr, MaxCount
    if (pos + entriesRead * 12 > stub.length) return const <String>[];

    final headers = <({int namePtr, int type, int remarkPtr})>[];
    for (int i = 0; i < entriesRead; i++) {
      final namePtr = bd.getUint32(pos, Endian.little);
      final type = bd.getUint32(pos + 4, Endian.little);
      final remarkPtr = bd.getUint32(pos + 8, Endian.little);
      headers.add((namePtr: namePtr, type: type, remarkPtr: remarkPtr));
      pos += 12;
    }

    String readNdrString() {
      while ((pos % 4) != 0 && pos < stub.length) {
        pos++;
      }
      if (pos + 12 > stub.length) return '';
      final actualCount = bd.getUint32(pos + 8, Endian.little);
      pos += 12;
      final byteLen = actualCount * 2;
      if (byteLen <= 0 || pos + byteLen > stub.length) {
        pos = math.min(stub.length, pos + math.max(0, byteLen));
        return '';
      }
      final strBytes = Uint8List.sublistView(stub, pos, pos + byteLen);
      pos += byteLen;
      while ((pos % 4) != 0 && pos < stub.length) {
        pos++;
      }
      var s = _decodeUtf16Le(strBytes);
      if (s.endsWith('\x00')) {
        s = s.substring(0, s.length - 1);
      }
      return s.trim();
    }

    final shares = <String>[];
    for (final h in headers) {
      final name = h.namePtr != 0 ? readNdrString() : '';
      if (h.remarkPtr != 0) {
        readNdrString();
      }
      final baseType = h.type & 0x03; // 0 = STYPE_DISKTREE
      if (name.isNotEmpty && baseType == 0 && !name.endsWith(r'$')) {
        shares.add(name);
      }
    }
    return shares;
  }

  Future<List<_SmbRawDirEntry>> queryDirectory(String relPath) async {
    final cleanRel = relPath.replaceAll('/', r'\').replaceAll(RegExp(r'^\\+|\\+$'), '');
    final opened = await _createRaw(
      path: cleanRel,
      desiredAccess: 0x00120089, // FILE_READ_DATA | FILE_READ_ATTRIBUTES | SYNCHRONIZE
      fileAttributes: 0x00000010,
      shareAccess: 0x00000007,
      createDisposition: 1, // FILE_OPEN
      createOptions: 0x00000001, // FILE_DIRECTORY_FILE
    );
    final entries = <_SmbRawDirEntry>[];
    try {
      bool firstCall = true;
      while (true) {
        final patternBytes = _encodeUtf16Le('*');
        final body = Uint8List(32 + patternBytes.length);
        final bd = ByteData.sublistView(body);
        bd.setUint16(0, 33, Endian.little); // StructureSize
        bd.setUint8(2, 0x25); // FileIdBothDirectoryInformation
        bd.setUint8(3, firstCall ? 0x01 : 0x00); // SMB2_RESTART_SCANS on first call
        bd.setUint32(4, 0, Endian.little); // FileIndex
        body.setRange(8, 24, opened.fileId);
        bd.setUint16(24, 64 + 32, Endian.little); // FileNameOffset
        bd.setUint16(26, patternBytes.length, Endian.little); // FileNameLength
        bd.setUint32(28, 65536, Endian.little); // OutputBufferLength
        body.setRange(32, body.length, patternBytes);
        firstCall = false;

        final resp = await _sendAndReceive(
          command: 0x000E,
          body: body,
          allowNoMoreFiles: true,
        );
        final status = ByteData.sublistView(resp).getUint32(8, Endian.little);
        if (status == 0x80000006 || resp.length < 64 + 8) {
          break;
        }
        final rBd = ByteData.sublistView(resp, 64);
        final outOffset = rBd.getUint16(2, Endian.little);
        final outLen = rBd.getUint32(4, Endian.little);
        if (outLen == 0 || outOffset + outLen > resp.length) break;

        final dirBuf = Uint8List.sublistView(resp, outOffset, outOffset + outLen);
        _parseFileIdBothDirInfo(dirBuf, entries);
      }
      return entries;
    } finally {
      try {
        await closeFile(opened.fileId);
      } catch (_) {}
    }
  }

  void _parseFileIdBothDirInfo(Uint8List buf, List<_SmbRawDirEntry> out) {
    final bd = ByteData.sublistView(buf);
    int offset = 0;
    while (offset + 104 <= buf.length) {
      final nextOffset = bd.getUint32(offset, Endian.little);
      final lastWriteFiletime = bd.getUint64(offset + 16, Endian.little);
      final endOfFile = bd.getInt64(offset + 40, Endian.little);
      final fileAttr = bd.getUint32(offset + 56, Endian.little);
      final nameLen = bd.getUint32(offset + 60, Endian.little);

      if (offset + 104 + nameLen <= buf.length && nameLen > 0) {
        final nameBytes = Uint8List.sublistView(
          buf,
          offset + 104,
          offset + 104 + nameLen,
        );
        final name = _decodeUtf16Le(nameBytes);
        final isDir = (fileAttr & 0x00000010) != 0;
        final modTimeStr = _formatWindowsFileTime(lastWriteFiletime);
        out.add(
          _SmbRawDirEntry(
            name: name,
            size: endOfFile > 0 ? endOfFile : 0,
            modTime: modTimeStr,
            isDir: isDir,
          ),
        );
      }
      if (nextOffset == 0) break;
      offset += nextOffset;
    }
  }

  static String _formatWindowsFileTime(int filetime) {
    if (filetime <= 0) return '';
    final unixMs = (filetime ~/ 10000) - 11644473600000;
    if (unixMs <= 0 || unixMs > 4102444800000) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(unixMs, isUtc: true).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  Future<({Uint8List fileId, int fileSize, bool isDir})> openFileForRead(
    String relPath,
  ) {
    final cleanRel = relPath.replaceAll('/', r'\').replaceAll(RegExp(r'^\\+|\\+$'), '');
    return _createRaw(
      path: cleanRel,
      desiredAccess: 0x00120089,
      fileAttributes: 0x00000080,
      shareAccess: 0x00000007,
      createDisposition: 1, // FILE_OPEN
      createOptions: 0x00000040, // FILE_NON_DIRECTORY_FILE
    );
  }

  Future<Uint8List> openFileForWrite(String relPath) async {
    final cleanRel = relPath.replaceAll('/', r'\').replaceAll(RegExp(r'^\\+|\\+$'), '');
    final created = await _createRaw(
      path: cleanRel,
      desiredAccess: 0x00120196,
      fileAttributes: 0x00000080,
      shareAccess: 0x00000007,
      createDisposition: 5, // FILE_OVERWRITE_IF
      createOptions: 0x00000040, // FILE_NON_DIRECTORY_FILE
    );
    return created.fileId;
  }

  Future<void> createDirectory(String relPath) async {
    final cleanRel = relPath.replaceAll('/', r'\').replaceAll(RegExp(r'^\\+|\\+$'), '');
    final created = await _createRaw(
      path: cleanRel,
      desiredAccess: 0x00120089,
      fileAttributes: 0x00000010,
      shareAccess: 0x00000007,
      createDisposition: 2, // FILE_CREATE
      createOptions: 0x00000001, // FILE_DIRECTORY_FILE
    );
    await closeFile(created.fileId);
  }

  Future<void> deleteEntryRecursive(String relPath, {required bool isDir}) async {
    final cleanRel = relPath.replaceAll('/', r'\').replaceAll(RegExp(r'^\\+|\\+$'), '');
    if (isDir) {
      final children = await queryDirectory(cleanRel);
      for (final child in children) {
        if (child.name == '.' || child.name == '..') continue;
        await deleteEntryRecursive(
          '$cleanRel\\${child.name}',
          isDir: child.isDir,
        );
      }
    }
    final opened = await _createRaw(
      path: cleanRel,
      desiredAccess: 0x00010080, // DELETE | FILE_READ_ATTRIBUTES
      fileAttributes: isDir ? 0x00000010 : 0x00000080,
      shareAccess: 0x00000007,
      createDisposition: 1, // FILE_OPEN
      createOptions: isDir ? 0x00000001 : 0x00000040,
    );
    try {
      // SMB2_SET_INFO (0x0011): FileDispositionInformation (0x0D) -> DeletePending = 1
      final infoBuf = Uint8List.fromList(<int>[1]);
      await _setInfo(
        fileId: opened.fileId,
        fileInfoClass: 0x0D,
        infoBuffer: infoBuf,
      );
    } finally {
      await closeFile(opened.fileId);
    }
  }

  Future<void> renameEntry(String srcRelPath, String dstRelPath) async {
    final cleanSrc = srcRelPath.replaceAll('/', r'\').replaceAll(RegExp(r'^\\+|\\+$'), '');
    final cleanDst = dstRelPath.replaceAll('/', r'\').replaceAll(RegExp(r'^\\+|\\+$'), '');
    final opened = await _createRaw(
      path: cleanSrc,
      desiredAccess: 0x00110080, // DELETE | FILE_READ_ATTRIBUTES | SYNCHRONIZE
      fileAttributes: 0,
      shareAccess: 0x00000007,
      createDisposition: 1, // FILE_OPEN
      createOptions: 0,
    );
    try {
      // SMB2_SET_INFO (0x0011): FileRenameInformation (0x0A)
      // 20-byte header (ReplaceIfExists: 1B, Reserved: 7B, RootDirectory: 8B, FileNameLength: 4B) + UTF-16LE name
      final dstNameBytes = _encodeUtf16Le(cleanDst);
      final infoBuf = Uint8List(20 + dstNameBytes.length);
      final bd = ByteData.sublistView(infoBuf);
      bd.setUint8(0, 1); // ReplaceIfExists = 1
      bd.setUint32(16, dstNameBytes.length, Endian.little);
      infoBuf.setRange(20, infoBuf.length, dstNameBytes);

      await _setInfo(
        fileId: opened.fileId,
        fileInfoClass: 0x0A,
        infoBuffer: infoBuf,
      );
    } finally {
      await closeFile(opened.fileId);
    }
  }

  Future<void> _setInfo({
    required Uint8List fileId,
    required int fileInfoClass,
    required Uint8List infoBuffer,
  }) async {
    final body = Uint8List(32 + infoBuffer.length);
    final bd = ByteData.sublistView(body);
    bd.setUint16(0, 33, Endian.little); // StructureSize
    bd.setUint8(2, 0x01); // InfoType: SMB2_0_INFO_FILE
    bd.setUint8(3, fileInfoClass);
    bd.setUint32(4, infoBuffer.length, Endian.little); // BufferLength
    bd.setUint16(8, 64 + 32, Endian.little); // BufferOffset
    bd.setUint16(10, 0, Endian.little); // Reserved
    bd.setUint32(12, 0, Endian.little); // AdditionalInformation
    body.setRange(16, 32, fileId);
    body.setRange(32, body.length, infoBuffer);

    await _sendAndReceive(command: 0x0011, body: body);
  }

  Future<({Uint8List fileId, int fileSize, bool isDir})> _createRaw({
    required String path,
    required int desiredAccess,
    required int fileAttributes,
    required int shareAccess,
    required int createDisposition,
    required int createOptions,
  }) async {
    final nameBytes = path.isEmpty ? Uint8List(0) : _encodeUtf16Le(path);
    final bufBytes = nameBytes.isEmpty ? Uint8List(1) : nameBytes;
    final body = Uint8List(56 + bufBytes.length);
    final bd = ByteData.sublistView(body);
    bd.setUint16(0, 57, Endian.little); // StructureSize
    bd.setUint8(2, 0); // SecurityFlags
    bd.setUint8(3, 0); // RequestedOplockLevel
    bd.setUint32(4, 2, Endian.little); // ImpersonationLevel = Impersonation
    bd.setUint64(8, 0, Endian.little); // SmbCreateFlags
    bd.setUint64(16, 0, Endian.little); // Reserved
    bd.setUint32(24, desiredAccess, Endian.little);
    bd.setUint32(28, fileAttributes, Endian.little);
    bd.setUint32(32, shareAccess, Endian.little);
    bd.setUint32(36, createDisposition, Endian.little);
    bd.setUint32(40, createOptions, Endian.little);
    bd.setUint16(44, 64 + 56, Endian.little); // NameOffset
    bd.setUint16(46, nameBytes.length, Endian.little); // NameLength
    bd.setUint32(48, 0, Endian.little); // CreateContextsOffset
    bd.setUint32(52, 0, Endian.little); // CreateContextsLength
    body.setRange(56, body.length, bufBytes);

    final resp = await _sendAndReceive(command: 0x0005, body: body);
    if (resp.length < 64 + 80) {
      throw const ApiException('SMB2_CREATE 响应格式异常');
    }
    final rBd = ByteData.sublistView(resp, 64);
    final endOfFile = rBd.getInt64(48, Endian.little);
    final attr = rBd.getUint32(56, Endian.little);
    final fileId = Uint8List.fromList(
      Uint8List.sublistView(resp, 64 + 64, 64 + 80),
    );
    return (
      fileId: fileId,
      fileSize: endOfFile > 0 ? endOfFile : 0,
      isDir: (attr & 0x00000010) != 0,
    );
  }

  Future<Uint8List> readFileChunk({
    required Uint8List fileId,
    required int offset,
    required int length,
  }) async {
    final body = Uint8List(49);
    final bd = ByteData.sublistView(body);
    bd.setUint16(0, 49, Endian.little); // StructureSize
    bd.setUint8(2, 0x50); // Padding
    bd.setUint8(3, 0); // Flags
    bd.setUint32(4, length, Endian.little); // Length
    bd.setUint64(8, offset, Endian.little); // Offset
    body.setRange(16, 32, fileId);
    bd.setUint32(32, 0, Endian.little); // MinimumCount
    bd.setUint32(36, 0, Endian.little); // Channel
    bd.setUint32(40, 0, Endian.little); // RemainingBytes
    bd.setUint16(44, 0, Endian.little); // ReadChannelInfoOffset
    bd.setUint16(46, 0, Endian.little); // ReadChannelInfoLength
    body[48] = 0;

    final creditCharge = (_supportsLargeMtu && length > 65536)
        ? ((length - 1) ~/ 65536) + 1
        : 1;
    final resp = await _sendAndReceive(
      command: 0x0008,
      body: body,
      creditChargeOverride: creditCharge,
      allowNoMoreFiles: true,
    );
    final status = ByteData.sublistView(resp).getUint32(8, Endian.little);
    if (status == 0x00000107 || resp.length < 64 + 16) {
      // STATUS_END_OF_FILE
      return Uint8List(0);
    }
    final rBd = ByteData.sublistView(resp, 64);
    final dataOffset = rBd.getUint8(2);
    final dataLength = rBd.getUint32(4, Endian.little);
    if (dataLength == 0 || dataOffset + dataLength > resp.length) {
      return Uint8List(0);
    }
    return Uint8List.fromList(
      Uint8List.sublistView(resp, dataOffset, dataOffset + dataLength),
    );
  }

  Future<void> writeFileChunk({
    required Uint8List fileId,
    required int offset,
    required Uint8List data,
  }) async {
    final body = Uint8List(48 + data.length);
    final bd = ByteData.sublistView(body);
    bd.setUint16(0, 49, Endian.little); // StructureSize
    bd.setUint16(2, 64 + 48, Endian.little); // DataOffset
    bd.setUint32(4, data.length, Endian.little); // Length
    bd.setUint64(8, offset, Endian.little); // Offset
    body.setRange(16, 32, fileId);
    bd.setUint32(32, 0, Endian.little); // Channel
    bd.setUint32(36, 0, Endian.little); // RemainingBytes
    bd.setUint16(40, 0, Endian.little); // WriteChannelInfoOffset
    bd.setUint16(42, 0, Endian.little); // WriteChannelInfoLength
    bd.setUint32(44, 0, Endian.little); // Flags
    body.setRange(48, body.length, data);

    await _sendAndReceive(command: 0x0009, body: body);
  }

  Future<void> closeFile(Uint8List fileId) async {
    final body = Uint8List(24);
    final bd = ByteData.sublistView(body);
    bd.setUint16(0, 24, Endian.little); // StructureSize
    bd.setUint16(2, 0, Endian.little); // Flags
    bd.setUint32(4, 0, Endian.little); // Reserved
    body.setRange(8, 24, fileId);
    await _sendAndReceive(command: 0x0006, body: body);
  }

  static String _formatNtStatusError(int status, int cmd) {
    final hex = '0x${status.toRadixString(16).padLeft(8, '0').toUpperCase()}';
    switch (status) {
      case 0xC000006D: // STATUS_LOGON_FAILURE
      case 0xC000006A: // STATUS_WRONG_PASSWORD
      case 0xC000006E: // STATUS_ACCOUNT_RESTRICTION
        return 'SMB 账号或密码错误 ($hex)';
      case 0xC0000022: // STATUS_ACCESS_DENIED
        return 'SMB 权限不足：拒绝访问 ($hex)';
      case 0xC00000CC: // STATUS_BAD_NETWORK_NAME
        return 'SMB 共享目录名不存在，请检查共享路径 ($hex)';
      case 0xC0000034: // STATUS_OBJECT_NAME_NOT_FOUND
      case 0xC000003A: // STATUS_OBJECT_PATH_NOT_FOUND
        return 'SMB 指定的文件或目录不存在 ($hex)';
      case 0xC0000035: // STATUS_OBJECT_NAME_COLLISION
        return 'SMB 同名文件或文件夹已存在 ($hex)';
      default:
        return 'SMB 请求失败 (命令 $cmd, 状态 $hex)';
    }
  }
}

// =============================================================================
// NTLMv2 + SPNEGO + Pure Dart MD4 Helper
// =============================================================================

class _NtlmAuthHelper {
  static const List<int> _ntlmsspSig = <int>[
    0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00, // "NTLMSSP\0"
  ];

  // NTLMSSP_NEGOTIATE_UNICODE (0x01) | NTLMSSP_REQUEST_TARGET (0x04) |
  // NTLMSSP_NEGOTIATE_SIGN (0x10) | NTLMSSP_NEGOTIATE_NTLM (0x200) |
  // NTLMSSP_NEGOTIATE_ALWAYS_SIGN (0x8000) | NTLMSSP_NEGOTIATE_EXTENDED_SESSIONSECURITY (0x80000) |
  // NTLMSSP_NEGOTIATE_128 (0x20000000) | NTLMSSP_NEGOTIATE_56 (0x80000000)
  // Note: NTLMSSP_NEGOTIATE_KEY_EXCH (0x40000000) is intentionally omitted so
  // ExportedSessionKey == SessionBaseKey without RC4 key exchange.
  static const int _defaultFlags = 0xA0088215;

  static Uint8List buildType1Message() {
    final out = Uint8List(32);
    out.setRange(0, 8, _ntlmsspSig);
    final bd = ByteData.sublistView(out);
    bd.setUint32(8, 1, Endian.little); // Type 1 (NEGOTIATE)
    bd.setUint32(12, _defaultFlags, Endian.little);
    // DomainNameFields (8 bytes = 0), WorkstationFields (8 bytes = 0)
    return out;
  }

  static ({
    Uint8List serverChallenge,
    Uint8List targetInfo,
    int flags,
  }) extractType2Challenge(Uint8List secBuf) {
    int ntlmStart = -1;
    for (int i = 0; i <= secBuf.length - 8; i++) {
      bool match = true;
      for (int j = 0; j < 8; j++) {
        if (secBuf[i + j] != _ntlmsspSig[j]) {
          match = false;
          break;
        }
      }
      if (match) {
        ntlmStart = i;
        break;
      }
    }
    if (ntlmStart < 0 || ntlmStart + 32 > secBuf.length) {
      throw const ApiException('未在 SMB2 响应中找到 NTLMSSP 质询信息');
    }
    final msg = Uint8List.sublistView(secBuf, ntlmStart);
    final bd = ByteData.sublistView(msg);
    final msgType = bd.getUint32(8, Endian.little);
    if (msgType != 2) {
      throw ApiException('非预期的 NTLMSSP 消息类型: $msgType');
    }
    final flags = bd.getUint32(20, Endian.little);
    final serverChallenge =
        Uint8List.fromList(Uint8List.sublistView(msg, 24, 32));
    Uint8List targetInfo = Uint8List(0);
    if (msg.length >= 48) {
      final tiLen = bd.getUint16(40, Endian.little);
      final tiOff = bd.getUint32(44, Endian.little);
      if (tiLen > 0 && tiOff >= 48 && tiOff + tiLen <= msg.length) {
        targetInfo = Uint8List.fromList(
          Uint8List.sublistView(msg, tiOff, tiOff + tiLen),
        );
      }
    }
    return (
      serverChallenge: serverChallenge,
      targetInfo: targetInfo,
      flags: flags,
    );
  }

  static ({Uint8List type3Message, Uint8List sessionBaseKey}) buildType3Message({
    required String username,
    required String password,
    required String domain,
    required Uint8List serverChallenge,
    required Uint8List targetInfo,
    required int negotiateFlags,
  }) {
    final flags = (negotiateFlags & ~0x40000000) | 0x00088205;
    final isAnonymous = username.isEmpty && password.isEmpty;

    Uint8List ntChallengeResp;
    Uint8List lmChallengeResp;
    Uint8List sessionBaseKey;

    if (isAnonymous) {
      ntChallengeResp = Uint8List(0);
      lmChallengeResp = Uint8List(1);
      sessionBaseKey = Uint8List(16);
    } else {
      final ntHash = _md4(_encodeUtf16Le(password));
      final userDomBytes = _encodeUtf16Le('${username.toUpperCase()}$domain');
      final ntlmv2Key = Uint8List.fromList(
        crypto.Hmac(crypto.md5, ntHash).convert(userDomBytes).bytes,
      );

      final rnd = math.Random.secure();
      final clientChallenge = Uint8List.fromList(
        List<int>.generate(8, (_) => rnd.nextInt(256)),
      );

      // Windows FILETIME: 100-ns intervals since Jan 1, 1601 UTC
      final unixMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      final filetime = (unixMs + 11644473600000) * 10000;

      final effectiveTi =
          targetInfo.isNotEmpty ? targetInfo : Uint8List.fromList(<int>[0, 0, 0, 0]);
      final blob = Uint8List(28 + effectiveTi.length + 4);
      final bBd = ByteData.sublistView(blob);
      bBd.setUint8(0, 0x01);
      bBd.setUint8(1, 0x01);
      bBd.setUint16(2, 0, Endian.little);
      bBd.setUint32(4, 0, Endian.little);
      bBd.setUint64(8, filetime, Endian.little);
      blob.setRange(16, 24, clientChallenge);
      bBd.setUint32(24, 0, Endian.little);
      blob.setRange(28, 28 + effectiveTi.length, effectiveTi);

      final challAndBlob = Uint8List(8 + blob.length);
      challAndBlob.setRange(0, 8, serverChallenge);
      challAndBlob.setRange(8, challAndBlob.length, blob);
      final ntProofStr = Uint8List.fromList(
        crypto.Hmac(crypto.md5, ntlmv2Key).convert(challAndBlob).bytes,
      );

      ntChallengeResp = Uint8List(16 + blob.length);
      ntChallengeResp.setRange(0, 16, ntProofStr);
      ntChallengeResp.setRange(16, ntChallengeResp.length, blob);

      // LMv2 response (24 bytes)
      final challAndClient = Uint8List(16);
      challAndClient.setRange(0, 8, serverChallenge);
      challAndClient.setRange(8, 16, clientChallenge);
      final lmv2Hmac = Uint8List.fromList(
        crypto.Hmac(crypto.md5, ntlmv2Key).convert(challAndClient).bytes,
      );
      lmChallengeResp = Uint8List(24);
      lmChallengeResp.setRange(0, 16, lmv2Hmac);
      lmChallengeResp.setRange(16, 24, clientChallenge);

      sessionBaseKey = Uint8List.fromList(
        crypto.Hmac(crypto.md5, ntlmv2Key).convert(ntProofStr).bytes,
      );
    }

    final domainBytes = _encodeUtf16Le(domain);
    final userBytes = _encodeUtf16Le(username);
    final workstationBytes = _encodeUtf16Le('LIUGUANG');
    final sessionKeyBytes = Uint8List(0);

    const int headerLen = 64;
    final int domainOff = headerLen;
    final int userOff = domainOff + domainBytes.length;
    final int wsOff = userOff + userBytes.length;
    final int lmOff = wsOff + workstationBytes.length;
    final int ntOff = lmOff + lmChallengeResp.length;
    final int skOff = ntOff + ntChallengeResp.length;
    final int totalLen = skOff + sessionKeyBytes.length;

    final out = Uint8List(totalLen);
    out.setRange(0, 8, _ntlmsspSig);
    final bd = ByteData.sublistView(out);
    bd.setUint32(8, 3, Endian.little); // Type 3 (AUTHENTICATE)

    void setSecField(int fieldOffset, int len, int off) {
      bd.setUint16(fieldOffset, len, Endian.little);
      bd.setUint16(fieldOffset + 2, len, Endian.little);
      bd.setUint32(fieldOffset + 4, off, Endian.little);
    }

    setSecField(12, lmChallengeResp.length, lmOff);
    setSecField(20, ntChallengeResp.length, ntOff);
    setSecField(28, domainBytes.length, domainOff);
    setSecField(36, userBytes.length, userOff);
    setSecField(44, workstationBytes.length, wsOff);
    setSecField(52, sessionKeyBytes.length, skOff);
    bd.setUint32(60, flags, Endian.little);

    out.setRange(domainOff, domainOff + domainBytes.length, domainBytes);
    out.setRange(userOff, userOff + userBytes.length, userBytes);
    out.setRange(wsOff, wsOff + workstationBytes.length, workstationBytes);
    out.setRange(lmOff, lmOff + lmChallengeResp.length, lmChallengeResp);
    out.setRange(ntOff, ntOff + ntChallengeResp.length, ntChallengeResp);

    return (type3Message: out, sessionBaseKey: sessionBaseKey);
  }

  static List<int> _asn1Len(int len) {
    if (len < 0x80) return <int>[len];
    if (len <= 0xFF) return <int>[0x81, len];
    return <int>[0x82, (len >> 8) & 0xFF, len & 0xFF];
  }

  static Uint8List _asn1Wrap(int tag, List<int> content) {
    final lenBytes = _asn1Len(content.length);
    return Uint8List.fromList(<int>[tag, ...lenBytes, ...content]);
  }

  static Uint8List wrapSpnegoNegTokenInit(Uint8List ntlmType1) {
    // OID 1.3.6.1.4.1.311.2.2.10 (NTLMSSP)
    const ntlmOid = <int>[
      0x06, 0x0A, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x02, 0x0A,
    ];
    // OID 1.3.6.1.5.5.2 (SPNEGO)
    const spnegoOid = <int>[
      0x06, 0x06, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x02,
    ];
    final mechTypes = _asn1Wrap(0xA0, _asn1Wrap(0x30, ntlmOid));
    final mechToken = _asn1Wrap(0xA2, _asn1Wrap(0x04, ntlmType1));
    final negTokenInitSeq = _asn1Wrap(0x30, <int>[...mechTypes, ...mechToken]);
    final negTokenInit = _asn1Wrap(0xA0, negTokenInitSeq);
    return _asn1Wrap(0x60, <int>[...spnegoOid, ...negTokenInit]);
  }

  static Uint8List wrapSpnegoNegTokenResp(Uint8List ntlmType3) {
    final responseToken = _asn1Wrap(0xA2, _asn1Wrap(0x04, ntlmType3));
    final seq = _asn1Wrap(0x30, responseToken);
    return _asn1Wrap(0xA1, seq);
  }

  /// Pure Dart RFC 1320 MD4 implementation for NTLM password hashing
  static Uint8List _md4(Uint8List input) {
    final origBitLen = input.length * 8;
    int padLen = (56 - ((input.length + 1) % 64)) % 64;
    final padded = Uint8List(input.length + 1 + padLen + 8);
    padded.setRange(0, input.length, input);
    padded[input.length] = 0x80;
    final bd = ByteData.sublistView(padded);
    bd.setUint64(padded.length - 8, origBitLen, Endian.little);

    int a = 0x67452301;
    int b = 0xEFCDAB89;
    int c = 0x98BADCFE;
    int d = 0x10325476;

    int rotl32(int x, int s) => ((x << s) | ((x & 0xFFFFFFFF) >>> (32 - s))) & 0xFFFFFFFF;
    int f(int x, int y, int z) => ((x & y) | ((~x & 0xFFFFFFFF) & z)) & 0xFFFFFFFF;
    int g(int x, int y, int z) => ((x & y) | (x & z) | (y & z)) & 0xFFFFFFFF;
    int h(int x, int y, int z) => (x ^ y ^ z) & 0xFFFFFFFF;

    final x = List<int>.filled(16, 0);
    for (int offset = 0; offset < padded.length; offset += 64) {
      for (int i = 0; i < 16; i++) {
        x[i] = bd.getUint32(offset + i * 4, Endian.little);
      }
      final aa = a, bb = b, cc = c, dd = d;

      // Round 1
      const r1s = <int>[3, 7, 11, 19];
      for (int i = 0; i < 16; i++) {
        final s = r1s[i % 4];
        final t = (a + f(b, c, d) + x[i]) & 0xFFFFFFFF;
        a = d;
        d = c;
        c = b;
        b = rotl32(t, s);
      }

      // Round 2
      const r2k = <int>[0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15];
      const r2s = <int>[3, 5, 9, 13];
      for (int i = 0; i < 16; i++) {
        final s = r2s[i % 4];
        final t = (a + g(b, c, d) + x[r2k[i]] + 0x5A827999) & 0xFFFFFFFF;
        a = d;
        d = c;
        c = b;
        b = rotl32(t, s);
      }

      // Round 3
      const r3k = <int>[0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15];
      const r3s = <int>[3, 9, 11, 15];
      for (int i = 0; i < 16; i++) {
        final s = r3s[i % 4];
        final t = (a + h(b, c, d) + x[r3k[i]] + 0x6ED9EBA1) & 0xFFFFFFFF;
        a = d;
        d = c;
        c = b;
        b = rotl32(t, s);
      }

      a = (a + aa) & 0xFFFFFFFF;
      b = (b + bb) & 0xFFFFFFFF;
      c = (c + cc) & 0xFFFFFFFF;
      d = (d + dd) & 0xFFFFFFFF;
    }

    final out = ByteData(16);
    out.setUint32(0, a, Endian.little);
    out.setUint32(4, b, Endian.little);
    out.setUint32(8, c, Endian.little);
    out.setUint32(12, d, Endian.little);
    return out.buffer.asUint8List();
  }
}

Uint8List _encodeUtf16Le(String s) {
  final units = s.codeUnits;
  final out = Uint8List(units.length * 2);
  final bd = ByteData.sublistView(out);
  for (int i = 0; i < units.length; i++) {
    bd.setUint16(i * 2, units[i], Endian.little);
  }
  return out;
}

String _decodeUtf16Le(Uint8List bytes) {
  final count = bytes.length ~/ 2;
  if (count <= 0) return '';
  final bd = ByteData.sublistView(bytes);
  final units = Uint16List(count);
  for (int i = 0; i < count; i++) {
    units[i] = bd.getUint16(i * 2, Endian.little);
  }
  return String.fromCharCodes(units);
}
