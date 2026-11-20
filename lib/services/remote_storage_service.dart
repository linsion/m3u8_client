import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/models.dart';
import 'api_client.dart';

/// Unified AList / OpenList v3 + Standard WebDAV Remote Storage & Streaming Upload/Download Client
class RemoteStorageService {
  RemoteStorageService._();
  static final RemoteStorageService instance = RemoteStorageService._();

  final Map<String, String> _cachedAlistTokens = {};

  HttpClient _createHttpClient({Duration timeout = const Duration(seconds: 25)}) {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..badCertificateCallback = (_, __, ___) => true;
    return client;
  }

  static String normalizePath(String raw) {
    final trimmed = raw.trim().replaceAll('\\', '/');
    if (trimmed.isEmpty || trimmed == '/') return '/';
    var p = trimmed.startsWith('/') ? trimmed : '/$trimmed';
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  static String parentPathOf(String path) {
    final norm = normalizePath(path);
    if (norm == '/') return '';
    final idx = norm.lastIndexOf('/');
    if (idx <= 0) return '/';
    return norm.substring(0, idx);
  }

  static String joinPath(String dir, String name) {
    final normDir = normalizePath(dir);
    final cleanName = name.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    if (normDir == '/') return '/$cleanName';
    return '$normDir/$cleanName';
  }

  static String cleanBaseUrl(String raw) {
    var s = raw.trim();
    if (!s.toLowerCase().startsWith('http://') &&
        !s.toLowerCase().startsWith('https://')) {
      s = 'http://$s';
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  // ===========================================================================
  // 1. AList / OpenList v3 API Protocol
  // ===========================================================================

  Future<String> resolveAlistToken(
    StorageMount mount, {
    bool forceRefresh = false,
  }) async {
    final explicit = mount.token.trim();
    if (explicit.isNotEmpty && !forceRefresh) {
      return explicit;
    }
    final cached = _cachedAlistTokens[mount.id];
    if (cached != null && cached.isNotEmpty && !forceRefresh) {
      return cached;
    }
    final user = mount.username.trim();
    final pass = mount.password;
    if (user.isEmpty && pass.isEmpty) {
      return ''; // Guest access
    }
    final base = cleanBaseUrl(mount.baseUrl);
    final uri = Uri.parse('$base/api/auth/login');
    final client = _createHttpClient();
    try {
      final req = await client.postUrl(uri);
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      final bodyBytes = utf8.encode(
        jsonEncode({'username': user, 'password': pass}),
      );
      req.contentLength = bodyBytes.length;
      req.add(bodyBytes);
      final resp = await req.close();
      final bytes =
          await resp.fold<List<int>>(<int>[], (acc, b) => acc..addAll(b));
      final root = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      if (root is! Map<String, dynamic>) {
        throw const ApiException('AList 登录响应解析失败');
      }
      final code = int.tryParse((root['code'] ?? 500).toString()) ?? 500;
      if (code != 200) {
        final msg = (root['message'] ?? 'AList 登录失败 ($code)').toString();
        throw ApiException(msg, statusCode: code);
      }
      final data = root['data'];
      final token = data is Map<String, dynamic>
          ? (data['token'] ?? '').toString().trim()
          : '';
      _cachedAlistTokens[mount.id] = token;
      return token;
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _alistJsonRequest(
    StorageMount mount,
    String endpointPath,
    Map<String, dynamic> body, {
    bool isRetry = false,
  }) async {
    final base = cleanBaseUrl(mount.baseUrl);
    final uri = Uri.parse('$base$endpointPath');
    final token = await resolveAlistToken(mount, forceRefresh: isRetry);
    final client = _createHttpClient();
    try {
      final req = await client.postUrl(uri);
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      if (token.isNotEmpty) {
        req.headers.set('Authorization', token);
      }
      final bodyBytes = utf8.encode(jsonEncode(body));
      req.contentLength = bodyBytes.length;
      req.add(bodyBytes);
      final resp = await req.close();
      final bytes =
          await resp.fold<List<int>>(<int>[], (acc, b) => acc..addAll(b));
      final root = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      if (root is! Map<String, dynamic>) {
        throw const ApiException('无法解析 AList JSON 响应');
      }
      final code = int.tryParse((root['code'] ?? 200).toString()) ?? 200;
      if (code == 401 &&
          !isRetry &&
          (mount.username.isNotEmpty || mount.password.isNotEmpty)) {
        return await _alistJsonRequest(
          mount,
          endpointPath,
          body,
          isRetry: true,
        );
      }
      if (code != 200) {
        final msg = (root['message'] ?? 'AList 请求失败 ($code)').toString();
        throw ApiException(msg, statusCode: code);
      }
      return root;
    } finally {
      client.close(force: true);
    }
  }

  Future<FileDirectoryListing> listAlistDirectory(
    StorageMount mount,
    String path, {
    int maxPages = 8,
  }) async {
    final effectivePath =
        path.trim().isEmpty ? normalizePath(mount.rootPath) : normalizePath(path);
    final base = cleanBaseUrl(mount.baseUrl);
    final entries = <FileEntry>[];
    final seenPaths = <String>{};
    const perPage = 500;

    for (var page = 1; page <= maxPages; page++) {
      final root = await _alistJsonRequest(
        mount,
        '/api/fs/list',
        {
          'path': effectivePath,
          'password': '',
          'page': page,
          'per_page': perPage,
          'refresh': false,
        },
      );
      final data = root['data'];
      final content = (data is Map<String, dynamic> && data['content'] is List)
          ? data['content'] as List
          : const [];
      final totalCount = data is Map<String, dynamic>
          ? (int.tryParse((data['total'] ?? 0).toString()) ?? 0)
          : 0;

      if (content.isEmpty) break;
      int addedThisPage = 0;

      for (final item in content) {
        if (item is! Map<String, dynamic>) continue;
        final name = (item['name'] ?? '').toString().trim();
        if (name.isEmpty) continue;
        final isDir = item['is_dir'] == true;
        final size = int.tryParse((item['size'] ?? 0).toString()) ?? 0;
        var modTime = (item['modified'] ?? '').toString();
        if (modTime.length > 16) {
          modTime = modTime.substring(0, 16).replaceAll('T', ' ');
        }
        final sign = (item['sign'] ?? '').toString().trim();
        final thumb = (item['thumb'] ?? '').toString().trim();
        final itemPath = joinPath(effectivePath, name);
        if (!seenPaths.add(itemPath)) continue;
        addedThisPage++;
        String ext = '';
        if (!isDir) {
          final dot = name.lastIndexOf('.');
          if (dot > 0) ext = name.substring(dot).toLowerCase();
        }
        String directDownload = '';
        if (!isDir) {
          final encodedPath = itemPath
              .split('/')
              .map(Uri.encodeComponent)
              .join('/');
          directDownload = sign.isEmpty
              ? '$base/d$encodedPath'
              : '$base/d$encodedPath?sign=${Uri.encodeQueryComponent(sign)}';
        }
        entries.add(
          FileEntry(
            name: name,
            path: itemPath,
            size: size,
            modTime: modTime,
            isDir: isDir,
            isMp4: ext == '.mp4',
            ext: ext,
            mountId: mount.id,
            sourceKind: StorageSourceKind.alist,
            rawDownloadUrl: directDownload,
            thumbUrl: thumb,
          ),
        );
      }

      if (addedThisPage == 0 ||
          content.length < perPage ||
          (totalCount > 0 && entries.length >= totalCount)) {
        break;
      }
    }

    return FileDirectoryListing(
      path: effectivePath,
      parent: parentPathOf(effectivePath),
      root: normalizePath(mount.rootPath),
      entries: entries,
    );
  }

  Future<String> resolveAlistDirectUrl(
    StorageMount mount,
    String path, {
    String fallbackUrl = '',
  }) async {
    final norm = normalizePath(path);
    final root = await _alistJsonRequest(
      mount,
      '/api/fs/get',
      {'path': norm, 'password': ''},
    );
    final data = root['data'];
    if (data is Map<String, dynamic>) {
      final rawUrl = (data['raw_url'] ?? '').toString().trim();
      if (rawUrl.startsWith('http')) {
        return rawUrl;
      }
      final sign = (data['sign'] ?? '').toString().trim();
      final base = cleanBaseUrl(mount.baseUrl);
      final encodedPath = norm.split('/').map(Uri.encodeComponent).join('/');
      if (sign.isNotEmpty) {
        return '$base/d$encodedPath?sign=${Uri.encodeQueryComponent(sign)}';
      }
    }
    if (fallbackUrl.isNotEmpty) return fallbackUrl;
    final base = cleanBaseUrl(mount.baseUrl);
    final encodedPath = norm.split('/').map(Uri.encodeComponent).join('/');
    return '$base/d$encodedPath';
  }

  Future<void> createAlistFolder(
    StorageMount mount,
    String parentPath,
    String name,
  ) async {
    final fullPath = joinPath(parentPath, name);
    await _alistJsonRequest(mount, '/api/fs/mkdir', {'path': fullPath});
  }

  Future<void> renameAlistEntry(
    StorageMount mount,
    String path,
    String newName,
  ) async {
    await _alistJsonRequest(
      mount,
      '/api/fs/rename',
      {'path': normalizePath(path), 'name': newName},
    );
  }

  Future<void> deleteAlistEntries(
    StorageMount mount,
    String dirPath,
    List<String> names,
  ) async {
    await _alistJsonRequest(
      mount,
      '/api/fs/remove',
      {'dir': normalizePath(dirPath), 'names': names},
    );
  }

  Future<void> copyOrMoveAlistEntries({
    required StorageMount mount,
    required String srcDir,
    required String dstDir,
    required List<String> names,
    required bool isMove,
  }) async {
    await _alistJsonRequest(
      mount,
      isMove ? '/api/fs/move' : '/api/fs/copy',
      {
        'src_dir': normalizePath(srcDir),
        'dst_dir': normalizePath(dstDir),
        'names': names,
      },
    );
  }

  // ===========================================================================
  // 2. Standard WebDAV Protocol
  // ===========================================================================

  Map<String, String> webdavAuthHeaders(StorageMount mount) {
    final headers = <String, String>{};
    if (mount.username.isNotEmpty || mount.password.isNotEmpty) {
      final raw = '${mount.username}:${mount.password}';
      final b64 = base64Encode(utf8.encode(raw));
      headers['Authorization'] = 'Basic $b64';
    } else if (mount.token.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${mount.token}';
    }
    return headers;
  }

  Uri buildWebdavUri(
    StorageMount mount,
    String path, {
    bool isDirectory = false,
  }) {
    final base = cleanBaseUrl(mount.baseUrl);
    final norm = normalizePath(path);
    final segs = norm
        .split('/')
        .where((s) => s.isNotEmpty)
        .map(Uri.encodeComponent)
        .toList();
    final joined = segs.isEmpty ? '/' : '/${segs.join('/')}';
    final suffix = (isDirectory && !joined.endsWith('/')) ? '$joined/' : joined;
    return Uri.parse('$base$suffix');
  }

  Future<FileDirectoryListing> listWebdavDirectory(
    StorageMount mount,
    String path,
  ) async {
    final effectivePath =
        path.trim().isEmpty ? normalizePath(mount.rootPath) : normalizePath(path);
    final uri = buildWebdavUri(mount, effectivePath, isDirectory: true);
    final client = _createHttpClient();
    try {
      final req = await client.openUrl('PROPFIND', uri);
      req.headers.set('Depth', '1');
      req.headers.set('Content-Type', 'application/xml; charset=utf-8');
      webdavAuthHeaders(mount).forEach(req.headers.set);
      final resp = await req.close();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw ApiException(
          'WebDAV 连接失败 (HTTP ${resp.statusCode})',
          statusCode: resp.statusCode,
        );
      }
      final bytes =
          await resp.fold<List<int>>(<int>[], (acc, b) => acc..addAll(b));
      final xmlStr = utf8.decode(bytes, allowMalformed: true);
      final basePrefix = Uri.tryParse(cleanBaseUrl(mount.baseUrl))?.path ?? '';
      final entries = _parseWebdavPropfindXml(
        xml: xmlStr,
        mount: mount,
        currentPath: effectivePath,
        serverBasePrefix: basePrefix,
      );
      return FileDirectoryListing(
        path: effectivePath,
        parent: parentPathOf(effectivePath),
        root: normalizePath(mount.rootPath),
        entries: entries,
      );
    } finally {
      client.close(force: true);
    }
  }

  List<FileEntry> _parseWebdavPropfindXml({
    required String xml,
    required StorageMount mount,
    required String currentPath,
    required String serverBasePrefix,
  }) {
    final entries = <FileEntry>[];
    final respRegex = RegExp(
      r'<(?:[a-zA-Z0-9]+:)?response[^>]*>([\s\S]*?)</(?:[a-zA-Z0-9]+:)?response>',
      caseSensitive: false,
    );
    final normCurrent = normalizePath(currentPath);
    final cleanPrefix =
        serverBasePrefix.replaceAll(RegExp(r'^/+|/+$'), '').trim();

    String extractTag(String block, String tag) {
      final rx = RegExp(
        '<(?:[a-zA-Z0-9]+:)?$tag[^>]*>([\\s\\S]*?)</(?:[a-zA-Z0-9]+:)?$tag>',
        caseSensitive: false,
      );
      final m = rx.firstMatch(block);
      return (m?.group(1) ?? '').trim();
    }

    for (final m in respRegex.allMatches(xml)) {
      final block = m.group(1) ?? '';
      final rawHref = extractTag(block, 'href');
      if (rawHref.isEmpty) continue;
      String decodedHref;
      try {
        final parsedUri = Uri.tryParse(rawHref);
        final pathPart =
            (parsedUri != null && parsedUri.hasScheme) ? parsedUri.path : rawHref;
        decodedHref = Uri.decodeFull(pathPart);
      } catch (_) {
        decodedHref = rawHref;
      }

      var relPath = decodedHref;
      if (cleanPrefix.isNotEmpty) {
        final prefixSlash = '/$cleanPrefix';
        if (relPath.startsWith(prefixSlash)) {
          relPath = relPath.substring(prefixSlash.length);
        }
      }
      final normHref = normalizePath(relPath);
      if (normHref == normCurrent) continue;

      final isDir =
          RegExp(r'collection', caseSensitive: false).hasMatch(block) ||
              decodedHref.endsWith('/');
      var name = extractTag(block, 'displayname');
      try {
        name = Uri.decodeFull(name);
      } catch (_) {}
      if (name.isEmpty) {
        name = normHref.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '';
      }
      if (name.isEmpty) continue;

      final size = int.tryParse(extractTag(block, 'getcontentlength')) ?? 0;
      final modTime = extractTag(block, 'getlastmodified');
      String ext = '';
      if (!isDir) {
        final dot = name.lastIndexOf('.');
        if (dot > 0) ext = name.substring(dot).toLowerCase();
      }
      final directUrl =
          buildWebdavUri(mount, normHref, isDirectory: isDir).toString();
      entries.add(
        FileEntry(
          name: name,
          path: normHref,
          size: size,
          modTime: modTime,
          isDir: isDir,
          isMp4: ext == '.mp4',
          ext: ext,
          mountId: mount.id,
          sourceKind: StorageSourceKind.webdav,
          rawDownloadUrl: directUrl,
        ),
      );
    }
    return entries;
  }

  Future<void> createWebdavFolder(
    StorageMount mount,
    String parentPath,
    String name,
  ) async {
    final fullPath = joinPath(parentPath, name);
    final uri = buildWebdavUri(mount, fullPath, isDirectory: true);
    final client = _createHttpClient();
    try {
      final req = await client.openUrl('MKCOL', uri);
      webdavAuthHeaders(mount).forEach(req.headers.set);
      final resp = await req.close();
      await resp.drain<void>();
    } finally {
      client.close(force: true);
    }
  }

  Future<void> deleteWebdavEntry(
    StorageMount mount,
    String path, {
    bool isDir = false,
  }) async {
    final uri = buildWebdavUri(mount, path, isDirectory: isDir);
    final client = _createHttpClient();
    try {
      final req = await client.openUrl('DELETE', uri);
      webdavAuthHeaders(mount).forEach(req.headers.set);
      final resp = await req.close();
      await resp.drain<void>();
    } finally {
      client.close(force: true);
    }
  }

  Future<void> moveOrCopyWebdavEntry({
    required StorageMount mount,
    required String srcPath,
    required String dstPath,
    required bool isMove,
  }) async {
    final srcUri = buildWebdavUri(mount, srcPath);
    final dstUri = buildWebdavUri(mount, dstPath);
    final client = _createHttpClient();
    try {
      final req = await client.openUrl(isMove ? 'MOVE' : 'COPY', srcUri);
      webdavAuthHeaders(mount).forEach(req.headers.set);
      req.headers.set('Destination', dstUri.toString());
      req.headers.set('Overwrite', 'T');
      final resp = await req.close();
      await resp.drain<void>();
    } finally {
      client.close(force: true);
    }
  }

  // ===========================================================================
  // 3. Streaming Upload & Download Engine with Real-Time Byte Progress & Speed
  // ===========================================================================

  /// Streams a remote file to local disk (`destinationPath`) while reporting real-time `(receivedBytes, totalBytes, speedBytesPerSec)`
  Future<void> downloadStreamWithProgress({
    required Uri uri,
    required Map<String, String> headers,
    required String destinationPath,
    int expectedSizeHint = 0,
    required bool Function() isCancelled,
    required void Function(int receivedBytes, int totalBytes, double speed)
        onProgress,
  }) async {
    final client = _createHttpClient(timeout: const Duration(minutes: 60));
    IOSink? sink;
    final outFile = File(destinationPath);
    try {
      await outFile.parent.create(recursive: true);
      final req = await client.getUrl(uri);
      headers.forEach((k, v) {
        if (v.isNotEmpty) req.headers.set(k, v);
      });
      final resp = await req.close();
      if (resp.statusCode < 200 || resp.statusCode >= 400) {
        throw ApiException(
          '下载失败 (HTTP ${resp.statusCode})',
          statusCode: resp.statusCode,
        );
      }
      final totalBytes = resp.contentLength > 0
          ? resp.contentLength
          : expectedSizeHint;
      sink = outFile.openWrite();
      int received = 0;
      final startedAt = DateTime.now().millisecondsSinceEpoch;
      int lastReportMs = 0;

      await for (final chunk in resp) {
        if (isCancelled()) {
          throw const ApiException('用户已取消下载');
        }
        sink.add(chunk);
        received += chunk.length;
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs - lastReportMs >= 120 ||
            (totalBytes > 0 && received >= totalBytes)) {
          lastReportMs = nowMs;
          final elapsedSec = ((nowMs - startedAt) / 1000.0).clamp(0.1, 86400.0);
          final speed = received / elapsedSec;
          onProgress(received, totalBytes, speed);
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      final elapsedSec =
          ((DateTime.now().millisecondsSinceEpoch - startedAt) / 1000.0)
              .clamp(0.1, 86400.0);
      final finalTotal = totalBytes > received ? totalBytes : received;
      onProgress(received, finalTotal, received / elapsedSec);
    } catch (e) {
      await sink?.close();
      if (await outFile.exists()) {
        try {
          await outFile.delete();
        } catch (_) {}
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// Streams a file or byte array upload to AList (`/api/fs/put`), WebDAV (`PUT`), or Backend Server (`/api/files/upload`) with real-time progress!
  Future<void> uploadWithProgress({
    required StorageMount targetMount,
    required String targetDir,
    required String fileName,
    String? localFilePath,
    Uint8List? rawBytes,
    ApiClient? serverApi,
    required bool Function() isCancelled,
    required void Function(int sentBytes, int totalBytes, double speed)
        onProgress,
  }) async {
    int totalBytes = rawBytes?.length ?? 0;
    File? fileObj;
    if (localFilePath != null && localFilePath.isNotEmpty) {
      fileObj = File(localFilePath);
      if (await fileObj.exists()) {
        totalBytes = await fileObj.length();
      }
    }
    if (totalBytes <= 0 && (rawBytes == null || rawBytes.isEmpty)) {
      throw const ApiException('待上传文件为空或不存在');
    }

    Stream<List<int>> openByteStream() {
      if (fileObj != null) {
        return fileObj.openRead();
      }
      // Split rawBytes into 64KB chunks for smooth progress reporting
      return Stream<List<int>>.fromIterable(_chunkBytes(rawBytes!, 65536));
    }

    // 1. Local directory copy with progress
    if (targetMount.kind == StorageSourceKind.localCache) {
      final destPath = joinLocalPath(targetDir, fileName);
      final outFile = File(destPath);
      await outFile.parent.create(recursive: true);
      final sink = outFile.openWrite();
      int sent = 0;
      final startedAt = DateTime.now().millisecondsSinceEpoch;
      int lastReportMs = 0;
      try {
        await for (final chunk in openByteStream()) {
          if (isCancelled()) throw const ApiException('用户已取消上传');
          sink.add(chunk);
          sent += chunk.length;
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          if (nowMs - lastReportMs >= 80 || sent >= totalBytes) {
            lastReportMs = nowMs;
            final elapsedSec =
                ((nowMs - startedAt) / 1000.0).clamp(0.05, 86400.0);
            onProgress(sent, totalBytes, sent / elapsedSec);
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      return;
    }

    // 2. AList / OpenList PUT (`/api/fs/put`)
    if (targetMount.kind == StorageSourceKind.alist) {
      final base = cleanBaseUrl(targetMount.baseUrl);
      final uri = Uri.parse('$base/api/fs/put');
      final token = await resolveAlistToken(targetMount);
      final destPath = joinPath(targetDir, fileName);
      final encodedPath = destPath.split('/').map(Uri.encodeComponent).join('/');

      await _streamHttpUpload(
        method: 'PUT',
        uri: uri,
        headers: {
          if (token.isNotEmpty) 'Authorization': token,
          'File-Path': encodedPath,
          'Content-Type': 'application/octet-stream',
        },
        byteStream: openByteStream(),
        totalBytes: totalBytes,
        isCancelled: isCancelled,
        onProgress: onProgress,
      );
      return;
    }

    // 3. WebDAV PUT
    if (targetMount.kind == StorageSourceKind.webdav) {
      final destPath = joinPath(targetDir, fileName);
      final uri = buildWebdavUri(targetMount, destPath);
      final headers = {
        ...webdavAuthHeaders(targetMount),
        'Content-Type': 'application/octet-stream',
      };
      await _streamHttpUpload(
        method: 'PUT',
        uri: uri,
        headers: headers,
        byteStream: openByteStream(),
        totalBytes: totalBytes,
        isCancelled: isCancelled,
        onProgress: onProgress,
      );
      return;
    }

    // 4. Backend Server (`/api/files/upload`) with multipart streaming
    if (serverApi != null) {
      final base = cleanBaseUrl(serverApi.config.normalizedBaseUrl);
      final uri = Uri.parse('$base/api/files/upload').replace(
        queryParameters: {
          'path': targetDir,
          'name': fileName,
        },
      );
      final boundary =
          '----LiuguangUploadBoundary${DateTime.now().millisecondsSinceEpoch}';
      final headPart = utf8.encode(
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="path"\r\n\r\n$targetDir\r\n'
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="file"; filename="$fileName"\r\n'
        'Content-Type: application/octet-stream\r\n\r\n',
      );
      final tailPart = utf8.encode('\r\n--$boundary--\r\n');
      final multipartTotal = headPart.length + totalBytes + tailPart.length;

      Stream<List<int>> multipartStream() async* {
        yield headPart;
        await for (final chunk in openByteStream()) {
          yield chunk;
        }
        yield tailPart;
      }

      try {
        await _streamHttpUpload(
          method: 'POST',
          uri: uri,
          headers: {
            ...serverApi.authHeaders,
            'Content-Type': 'multipart/form-data; boundary=$boundary',
          },
          byteStream: multipartStream(),
          totalBytes: multipartTotal,
          logicalTotalBytes: totalBytes,
          isCancelled: isCancelled,
          onProgress: onProgress,
        );
        return;
      } catch (e) {
        throw ApiException(
          '服务端直传接口暂未开启或返回错误 ($e)，建议挂载 AList / WebDAV 或切换到本机离线目录上传',
        );
      }
    }
  }

  Future<void> _streamHttpUpload({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required Stream<List<int>> byteStream,
    required int totalBytes,
    int? logicalTotalBytes,
    required bool Function() isCancelled,
    required void Function(int sentBytes, int totalBytes, double speed)
        onProgress,
  }) async {
    final client = _createHttpClient(timeout: const Duration(minutes: 60));
    final displayTotal = logicalTotalBytes ?? totalBytes;
    try {
      final req = await client.openUrl(method, uri);
      req.bufferOutput = false;
      headers.forEach((k, v) {
        if (v.isNotEmpty) req.headers.set(k, v);
      });
      req.contentLength = totalBytes;

      int sent = 0;
      final startedAt = DateTime.now().millisecondsSinceEpoch;
      int lastReportMs = 0;

      final trackedStream = byteStream.transform<List<int>>(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (chunk, sink) {
            if (isCancelled()) {
              sink.addError(const ApiException('用户已取消上传'));
              return;
            }
            sink.add(chunk);
            sent += chunk.length;
            final clampedSent = sent.clamp(0, displayTotal);
            final nowMs = DateTime.now().millisecondsSinceEpoch;
            if (nowMs - lastReportMs >= 100 || clampedSent >= displayTotal) {
              lastReportMs = nowMs;
              final elapsedSec =
                  ((nowMs - startedAt) / 1000.0).clamp(0.1, 86400.0);
              onProgress(clampedSent, displayTotal, clampedSent / elapsedSec);
            }
          },
        ),
      );

      await req.addStream(trackedStream);
      final resp = await req.close();
      final respBytes =
          await resp.fold<List<int>>(<int>[], (acc, b) => acc..addAll(b));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final errText = utf8.decode(respBytes, allowMalformed: true);
        throw ApiException(
          'HTTP ${resp.statusCode}: ${errText.length > 120 ? errText.substring(0, 120) : errText}',
          statusCode: resp.statusCode,
        );
      }
      // If AList JSON response has `code != 200`, check it
      final respStr = utf8.decode(respBytes, allowMalformed: true).trim();
      if (respStr.startsWith('{')) {
        try {
          final json = jsonDecode(respStr);
          if (json is Map<String, dynamic> && json['code'] != null) {
            final code = int.tryParse(json['code'].toString()) ?? 200;
            if (code != 200) {
              throw ApiException(
                (json['message'] ?? '上传返回错误 ($code)').toString(),
                statusCode: code,
              );
            }
          }
        } catch (e) {
          if (e is ApiException) rethrow;
        }
      }
      final elapsedSec =
          ((DateTime.now().millisecondsSinceEpoch - startedAt) / 1000.0)
              .clamp(0.1, 86400.0);
      onProgress(displayTotal, displayTotal, displayTotal / elapsedSec);
    } finally {
      client.close(force: true);
    }
  }

  static Iterable<List<int>> _chunkBytes(Uint8List bytes, int chunkSize) sync* {
    for (int i = 0; i < bytes.length; i += chunkSize) {
      final end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
      yield bytes.sublist(i, end);
    }
  }

  static String defaultLocalDownloadsRoot() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
    final dl = Directory('$home${Platform.pathSeparator}Downloads');
    if (dl.existsSync()) {
      return dl.path;
    }
    return home;
  }

  static String joinLocalPath(String dir, String name) {
    final sep = Platform.pathSeparator;
    final cleanDir = dir.trim().isEmpty ? defaultLocalDownloadsRoot() : dir;
    if (cleanDir.endsWith(sep) || cleanDir.endsWith('/')) {
      return '$cleanDir$name';
    }
    return '$cleanDir$sep$name';
  }
}
