import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/models.dart';
import '../../services/local_115_direct_service.dart';
import '../../services/remote_storage_service.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import 'video_download_speed_badge.dart';

class CloudLrcLine {
  final Duration timestamp;
  final String text;

  const CloudLrcLine({
    required this.timestamp,
    required this.text,
  });
}

class SavedMusicFolderItem {
  final String mountId;
  final String mountName;
  final StorageSourceKind sourceKind;
  final String path;
  final String title;
  final bool isArchive;
  final int size;
  final String pickcode115;

  const SavedMusicFolderItem({
    required this.mountId,
    required this.mountName,
    required this.sourceKind,
    required this.path,
    required this.title,
    this.isArchive = false,
    this.size = 0,
    this.pickcode115 = '',
  });

  String get uniqueKey => '$mountId::$path';

  Map<String, dynamic> toJson() => {
        'mount_id': mountId,
        'mount_name': mountName,
        'source_kind': sourceKind.id,
        'path': path,
        'title': title,
        'is_archive': isArchive,
        'size': size,
        'pickcode_115': pickcode115,
      };

  factory SavedMusicFolderItem.fromJson(Map<String, dynamic> json) {
    return SavedMusicFolderItem(
      mountId: (json['mount_id'] ?? 'builtin_server').toString(),
      mountName: (json['mount_name'] ?? '远程存储').toString(),
      sourceKind: StorageSourceKind.fromId(json['source_kind']?.toString()),
      path: (json['path'] ?? '/').toString(),
      title: (json['title'] ?? '音乐目录').toString(),
      isArchive: json['is_archive'] == true,
      size: int.tryParse((json['size'] ?? 0).toString()) ?? 0,
      pickcode115: (json['pickcode_115'] ?? '').toString(),
    );
  }
}

typedef CloudEndpointResolver = Future<
    ({
      String url,
      Map<String, String> headers,
      String subtitle,
    })> Function(FileEntry entry);

// =============================================================================
// HTTP Range & Local Archive (.zip / .cbz / .tar) Music Inspector & Extractor
// =============================================================================

class CloudArchiveMusicService {
  CloudArchiveMusicService._();
  static final CloudArchiveMusicService instance = CloudArchiveMusicService._();

  final Map<String, List<FileEntry>> _archiveEntriesCache = {};

  /// Inspects a remote (115 / AList / WebDAV / Server) or local `.zip` / `.cbz` / `.tar` archive
  /// and returns all inner entries (audio files, `.lrc` lyrics, cover art images) WITHOUT downloading the whole archive.
  Future<List<FileEntry>> inspectArchiveEntries({
    required FileEntry archiveEntry,
    required CloudEndpointResolver endpointResolver,
  }) async {
    final cacheKey = '${archiveEntry.mountId}::${archiveEntry.path}::${archiveEntry.size}';
    final cached = _archiveEntriesCache[cacheKey];
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    final ext = archiveEntry.normalizedExt;
    List<FileEntry> parsed = const [];
    if (ext == '.zip' || ext == '.cbz') {
      parsed = await _inspectZipArchive(
        archiveEntry: archiveEntry,
        endpointResolver: endpointResolver,
      );
    } else if (ext == '.tar') {
      parsed = await _inspectTarArchive(
        archiveEntry: archiveEntry,
        endpointResolver: endpointResolver,
      );
    }

    if (parsed.isNotEmpty) {
      if (_archiveEntriesCache.length > 32) {
        _archiveEntriesCache.clear();
      }
      _archiveEntriesCache[cacheKey] = parsed;
    }
    return parsed;
  }

  Future<List<FileEntry>> _inspectZipArchive({
    required FileEntry archiveEntry,
    required CloudEndpointResolver endpointResolver,
  }) async {
    if (archiveEntry.sourceKind == StorageSourceKind.localCache) {
      final f = File(archiveEntry.path);
      if (!await f.exists()) return const [];
      final len = await f.length();
      if (len < 22) return const [];
      final raf = await f.open(mode: FileMode.read);
      try {
        final tailSize = math.min(len, 131072);
        await raf.setPosition(len - tailSize);
        final tailBytes = await raf.read(tailSize);
        return await _parseZipCentralDirectory(
          archiveEntry: archiveEntry,
          totalSize: len,
          tailOffset: len - tailSize,
          tailBytes: tailBytes,
          fetchRange: (start, end) async {
            await raf.setPosition(start);
            return await raf.read(end - start + 1);
          },
        );
      } finally {
        await raf.close();
      }
    }

    final resolved = await endpointResolver(archiveEntry);
    final uri = Uri.parse(resolved.url);
    int totalSize = archiveEntry.size;
    if (totalSize <= 22) {
      final probe = await _fetchRemoteRangeWithTotal(
        uri: uri,
        headers: resolved.headers,
        start: 0,
        end: 1,
      );
      totalSize = probe.totalSize;
    }
    if (totalSize <= 22) return const [];

    final tailSize = math.min(totalSize, 131072);
    final tailStart = totalSize - tailSize;
    final tailRes = await _fetchRemoteRangeWithTotal(
      uri: uri,
      headers: resolved.headers,
      start: tailStart,
      end: totalSize - 1,
    );
    if (tailRes.bytes.isEmpty) return const [];

    return await _parseZipCentralDirectory(
      archiveEntry: archiveEntry,
      totalSize: totalSize,
      tailOffset: tailStart,
      tailBytes: tailRes.bytes,
      fetchRange: (start, end) async {
        final slice = await _fetchRemoteRangeWithTotal(
          uri: uri,
          headers: resolved.headers,
          start: start,
          end: end,
        );
        return slice.bytes;
      },
    );
  }

  Future<List<FileEntry>> _parseZipCentralDirectory({
    required FileEntry archiveEntry,
    required int totalSize,
    required int tailOffset,
    required Uint8List tailBytes,
    required Future<Uint8List> Function(int start, int end) fetchRange,
  }) async {
    // 1. Locate End of Central Directory (EOCD) signature 0x06054b50 (`PK\x05\x06`)
    int eocdPos = -1;
    for (int i = tailBytes.length - 22; i >= 0; i--) {
      if (tailBytes[i] == 0x50 &&
          tailBytes[i + 1] == 0x4B &&
          tailBytes[i + 2] == 0x05 &&
          tailBytes[i + 3] == 0x06) {
        eocdPos = i;
        break;
      }
    }
    if (eocdPos < 0) return const [];

    final bd = ByteData.sublistView(tailBytes);
    final cdSize = bd.getUint32(eocdPos + 12, Endian.little);
    final cdOffset = bd.getUint32(eocdPos + 16, Endian.little);
    if (cdSize <= 0 || cdOffset < 0 || cdOffset + cdSize > totalSize) {
      return const [];
    }

    Uint8List cdBytes;
    if (cdOffset >= tailOffset &&
        (cdOffset - tailOffset) + cdSize <= tailBytes.length) {
      final relStart = cdOffset - tailOffset;
      cdBytes = Uint8List.sublistView(tailBytes, relStart, relStart + cdSize);
    } else {
      cdBytes = await fetchRange(cdOffset, cdOffset + cdSize - 1);
    }
    if (cdBytes.length < 46) return const [];

    final cdData = ByteData.sublistView(cdBytes);
    final entries = <FileEntry>[];
    int pos = 0;

    while (pos + 46 <= cdBytes.length) {
      if (cdBytes[pos] != 0x50 ||
          cdBytes[pos + 1] != 0x4B ||
          cdBytes[pos + 2] != 0x01 ||
          cdBytes[pos + 3] != 0x02) {
        break;
      }
      final flags = cdData.getUint16(pos + 8, Endian.little);
      final method = cdData.getUint16(pos + 10, Endian.little);
      final compSize = cdData.getUint32(pos + 20, Endian.little);
      final uncompSize = cdData.getUint32(pos + 24, Endian.little);
      final nameLen = cdData.getUint16(pos + 28, Endian.little);
      final extraLen = cdData.getUint16(pos + 30, Endian.little);
      final commentLen = cdData.getUint16(pos + 32, Endian.little);
      final localHeaderOffset = cdData.getUint32(pos + 42, Endian.little);

      if (pos + 46 + nameLen > cdBytes.length) break;
      final nameBytes = Uint8List.sublistView(cdBytes, pos + 46, pos + 46 + nameLen);
      final isUtf8Flag = (flags & 0x0800) != 0;
      final fullInnerPath = _decodeZipFileName(nameBytes, isUtf8Flag: isUtf8Flag);
      pos += 46 + nameLen + extraLen + commentLen;

      if (fullInnerPath.isEmpty ||
          fullInnerPath.endsWith('/') ||
          fullInnerPath.startsWith('__MACOSX/') ||
          fullInnerPath.split('/').last.startsWith('._')) {
        continue;
      }
      // Only Stored (0) and Deflate (8) are supported for streaming extraction
      if (method != 0 && method != 8) continue;

      final baseName = fullInnerPath.split('/').last;
      final dot = baseName.lastIndexOf('.');
      final ext = (dot > 0 && dot < baseName.length - 1)
          ? baseName.substring(dot).toLowerCase()
          : '';

      entries.add(
        FileEntry(
          name: baseName,
          path: '${archiveEntry.path}#zip::$fullInnerPath',
          size: uncompSize,
          modTime: archiveEntry.modTime,
          isDir: false,
          isMp4: ext == '.mp4',
          ext: ext,
          mountId: archiveEntry.mountId,
          sourceKind: archiveEntry.sourceKind,
          rawDownloadUrl: archiveEntry.rawDownloadUrl,
          thumbUrl: archiveEntry.thumbUrl,
          pickcode115: archiveEntry.pickcode115,
          fid115: archiveEntry.fid115,
          cid115: archiveEntry.cid115,
          archiveContainerPath: archiveEntry.path,
          archiveContainerName: archiveEntry.name,
          archiveInnerPath: fullInnerPath,
          archiveOffset: localHeaderOffset,
          archiveCompressedSize: compSize,
          archiveCompressionMethod: method,
        ),
      );
    }

    return entries;
  }

  Future<List<FileEntry>> _inspectTarArchive({
    required FileEntry archiveEntry,
    required CloudEndpointResolver endpointResolver,
  }) async {
    final entries = <FileEntry>[];
    if (archiveEntry.sourceKind == StorageSourceKind.localCache) {
      final f = File(archiveEntry.path);
      if (!await f.exists()) return const [];
      final len = await f.length();
      final raf = await f.open(mode: FileMode.read);
      try {
        int offset = 0;
        int safety = 0;
        while (offset + 512 <= len && safety < 500) {
          safety++;
          await raf.setPosition(offset);
          final hdr = await raf.read(512);
          if (hdr.length < 512 || hdr.every((b) => b == 0)) break;
          final parsed = _parseTarHeader(hdr);
          if (parsed == null) break;
          final dataOffset = offset + 512;
          if (!parsed.isDir &&
              parsed.name.isNotEmpty &&
              !parsed.name.startsWith('__MACOSX/') &&
              !parsed.name.split('/').last.startsWith('._')) {
            final baseName = parsed.name.split('/').last;
            final dot = baseName.lastIndexOf('.');
            final ext = (dot > 0 && dot < baseName.length - 1)
                ? baseName.substring(dot).toLowerCase()
                : '';
            entries.add(
              FileEntry(
                name: baseName,
                path: '${archiveEntry.path}#tar::${parsed.name}',
                size: parsed.size,
                modTime: archiveEntry.modTime,
                isDir: false,
                isMp4: ext == '.mp4',
                ext: ext,
                mountId: archiveEntry.mountId,
                sourceKind: archiveEntry.sourceKind,
                rawDownloadUrl: archiveEntry.rawDownloadUrl,
                thumbUrl: archiveEntry.thumbUrl,
                pickcode115: archiveEntry.pickcode115,
                fid115: archiveEntry.fid115,
                cid115: archiveEntry.cid115,
                archiveContainerPath: archiveEntry.path,
                archiveContainerName: archiveEntry.name,
                archiveInnerPath: parsed.name,
                archiveOffset: dataOffset,
                archiveCompressedSize: parsed.size,
                archiveCompressionMethod: -1, // Raw TAR byte slice
              ),
            );
          }
          final paddedSize = ((parsed.size + 511) ~/ 512) * 512;
          offset = dataOffset + paddedSize;
        }
      } finally {
        await raf.close();
      }
      return entries;
    }

    final resolved = await endpointResolver(archiveEntry);
    final uri = Uri.parse(resolved.url);
    int offset = 0;
    int totalSize = archiveEntry.size > 0 ? archiveEntry.size : 1024 * 1024 * 1024;
    for (int step = 0; step < 120 && offset + 512 <= totalSize; step++) {
      final res = await _fetchRemoteRangeWithTotal(
        uri: uri,
        headers: resolved.headers,
        start: offset,
        end: offset + 511,
      );
      if (res.totalSize > 0) totalSize = res.totalSize;
      if (res.bytes.length < 512 || res.bytes.every((b) => b == 0)) break;
      final parsed = _parseTarHeader(res.bytes);
      if (parsed == null) break;
      final dataOffset = offset + 512;
      if (!parsed.isDir &&
          parsed.name.isNotEmpty &&
          !parsed.name.startsWith('__MACOSX/') &&
          !parsed.name.split('/').last.startsWith('._')) {
        final baseName = parsed.name.split('/').last;
        final dot = baseName.lastIndexOf('.');
        final ext = (dot > 0 && dot < baseName.length - 1)
            ? baseName.substring(dot).toLowerCase()
            : '';
        entries.add(
          FileEntry(
            name: baseName,
            path: '${archiveEntry.path}#tar::${parsed.name}',
            size: parsed.size,
            modTime: archiveEntry.modTime,
            isDir: false,
            isMp4: ext == '.mp4',
            ext: ext,
            mountId: archiveEntry.mountId,
            sourceKind: archiveEntry.sourceKind,
            rawDownloadUrl: archiveEntry.rawDownloadUrl,
            thumbUrl: archiveEntry.thumbUrl,
            pickcode115: archiveEntry.pickcode115,
            fid115: archiveEntry.fid115,
            cid115: archiveEntry.cid115,
            archiveContainerPath: archiveEntry.path,
            archiveContainerName: archiveEntry.name,
            archiveInnerPath: parsed.name,
            archiveOffset: dataOffset,
            archiveCompressedSize: parsed.size,
            archiveCompressionMethod: -1,
          ),
        );
      }
      final paddedSize = ((parsed.size + 511) ~/ 512) * 512;
      offset = dataOffset + paddedSize;
    }
    return entries;
  }

  static ({String name, int size, bool isDir})? _parseTarHeader(Uint8List hdr) {
    int nameEnd = 0;
    while (nameEnd < 100 && hdr[nameEnd] != 0) {
      nameEnd++;
    }
    if (nameEnd == 0) return null;
    final name = _decodeZipFileName(Uint8List.sublistView(hdr, 0, nameEnd));
    final sizeStr = ascii
        .decode(
          hdr.sublist(124, 136).where((b) => b != 0 && b != 32).toList(),
          allowInvalid: true,
        )
        .trim();
    final size = int.tryParse(sizeStr, radix: 8) ?? 0;
    final typeFlag = hdr[156];
    final isDir = typeFlag == 53 || name.endsWith('/'); // '5' = directory
    return (name: name, size: size, isDir: isDir);
  }

  /// Extracts a single virtual `FileEntry` (`entry.isInsideArchive == true`) on demand via HTTP Range
  /// (or local RandomAccessFile) and returns its raw decompressed bytes.
  Future<Uint8List> extractArchiveEntryBytes({
    required FileEntry entry,
    required CloudEndpointResolver endpointResolver,
  }) async {
    final containerEntry = FileEntry(
      name: entry.archiveContainerName.isNotEmpty
          ? entry.archiveContainerName
          : 'archive.zip',
      path: entry.archiveContainerPath,
      size: 0,
      modTime: entry.modTime,
      isDir: false,
      isMp4: false,
      ext: '',
      mountId: entry.mountId,
      sourceKind: entry.sourceKind,
      rawDownloadUrl: entry.rawDownloadUrl,
      pickcode115: entry.pickcode115,
      fid115: entry.fid115,
      cid115: entry.cid115,
    );

    if (entry.archiveCompressionMethod == -1) {
      // Raw TAR slice
      final start = entry.archiveOffset;
      final end = start + entry.archiveCompressedSize - 1;
      return await _readContainerSlice(
        containerEntry: containerEntry,
        endpointResolver: endpointResolver,
        start: start,
        end: end,
      );
    }

    // ZIP Local File Header (`0x04034b50`) + compressed payload
    final fetchStart = entry.archiveOffset;
    final fetchLen = 30 + 512 + entry.archiveCompressedSize;
    final rawChunk = await _readContainerSlice(
      containerEntry: containerEntry,
      endpointResolver: endpointResolver,
      start: fetchStart,
      end: fetchStart + fetchLen - 1,
    );
    if (rawChunk.length < 30 ||
        rawChunk[0] != 0x50 ||
        rawChunk[1] != 0x4B ||
        rawChunk[2] != 0x03 ||
        rawChunk[3] != 0x04) {
      throw Exception('ZIP 局部文件头校验失败');
    }
    final bd = ByteData.sublistView(rawChunk);
    final nameLen = bd.getUint16(26, Endian.little);
    final extraLen = bd.getUint16(28, Endian.little);
    final dataStart = 30 + nameLen + extraLen;
    final dataEnd = math.min(rawChunk.length, dataStart + entry.archiveCompressedSize);
    if (dataStart > rawChunk.length || dataEnd <= dataStart) {
      throw Exception('ZIP 曲目数据区间不完整');
    }
    final compressedSlice = Uint8List.sublistView(rawChunk, dataStart, dataEnd);
    if (entry.archiveCompressionMethod == 0) {
      return compressedSlice;
    } else if (entry.archiveCompressionMethod == 8) {
      final inflated = ZLibCodec(raw: true).decoder.convert(compressedSlice);
      return Uint8List.fromList(inflated);
    }
    throw Exception('暂不支持该 ZIP 压缩算法 (${entry.archiveCompressionMethod})');
  }

  /// Extracts a virtual archive audio track to a local temporary file so `media_kit` can play and seek it seamlessly.
  Future<String> extractArchiveAudioToTempFile({
    required FileEntry entry,
    required CloudEndpointResolver endpointResolver,
  }) async {
    final tempRoot = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}liuguang_archive_audio',
    );
    if (!await tempRoot.exists()) {
      await tempRoot.create(recursive: true);
    }
    final ext = entry.normalizedExt.isEmpty ? '.mp3' : entry.normalizedExt;
    final hashKey =
        '${entry.mountId}_${entry.archiveContainerPath}_${entry.archiveInnerPath}_${entry.size}'
            .hashCode
            .toUnsigned(32);
    final outFile = File(
      '${tempRoot.path}${Platform.pathSeparator}track_$hashKey$ext',
    );
    if (await outFile.exists() && await outFile.length() > 1024) {
      return outFile.path;
    }

    final bytes = await extractArchiveEntryBytes(
      entry: entry,
      endpointResolver: endpointResolver,
    );
    await outFile.writeAsBytes(bytes, flush: true);
    return outFile.path;
  }

  Future<Uint8List> _readContainerSlice({
    required FileEntry containerEntry,
    required CloudEndpointResolver endpointResolver,
    required int start,
    required int end,
  }) async {
    if (containerEntry.sourceKind == StorageSourceKind.localCache) {
      final f = File(containerEntry.path);
      final raf = await f.open(mode: FileMode.read);
      try {
        await raf.setPosition(start);
        return await raf.read(end - start + 1);
      } finally {
        await raf.close();
      }
    }
    final resolved = await endpointResolver(containerEntry);
    final res = await _fetchRemoteRangeWithTotal(
      uri: Uri.parse(resolved.url),
      headers: resolved.headers,
      start: start,
      end: end,
    );
    return res.bytes;
  }

  Future<({Uint8List bytes, int totalSize})> _fetchRemoteRangeWithTotal({
    required Uri uri,
    required Map<String, String> headers,
    required int start,
    required int end,
  }) async {
    final client = HttpClient()..badCertificateCallback = (_, __, ___) => true;
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 20));
      headers.forEach((k, v) {
        if (v.isNotEmpty) req.headers.set(k, v);
      });
      req.headers.set('Range', 'bytes=$start-$end');
      final resp = await req.close().timeout(const Duration(seconds: 25));
      int totalSize = 0;
      final cr = resp.headers.value('content-range') ??
          resp.headers.value('Content-Range') ??
          '';
      final slashIdx = cr.lastIndexOf('/');
      if (slashIdx > 0) {
        totalSize = int.tryParse(cr.substring(slashIdx + 1).trim()) ?? 0;
      }
      if (totalSize <= 0 && resp.contentLength > 0 && resp.statusCode == 200) {
        totalSize = resp.contentLength;
      }

      final maxWanted = (end - start + 1).clamp(1, 180 * 1024 * 1024);
      final builder = BytesBuilder(copy: false);
      if (resp.statusCode == 206) {
        await for (final chunk in resp) {
          builder.add(chunk);
          if (builder.length >= maxWanted) break;
        }
        final out = builder.takeBytes();
        return (
          bytes: out.length > maxWanted
              ? Uint8List.sublistView(out, 0, maxWanted)
              : out,
          totalSize: totalSize,
        );
      } else if (resp.statusCode == 200) {
        // Server ignored Range header; stream up to `end + 1` and slice `[start..end]`
        int skipped = 0;
        await for (final chunk in resp) {
          if (skipped + chunk.length <= start) {
            skipped += chunk.length;
            continue;
          }
          final sliceStart = math.max(0, start - skipped);
          final slice = chunk.sublist(sliceStart);
          builder.add(slice);
          skipped += chunk.length;
          if (builder.length >= maxWanted) break;
        }
        final out = builder.takeBytes();
        return (
          bytes: out.length > maxWanted
              ? Uint8List.sublistView(out, 0, maxWanted)
              : out,
          totalSize: totalSize,
        );
      }
      return (bytes: Uint8List(0), totalSize: totalSize);
    } finally {
      client.close(force: true);
    }
  }

  static String _decodeZipFileName(
    Uint8List bytes, {
    bool isUtf8Flag = false,
  }) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      // Fallback for GBK / CP936 / Latin1 encoded filenames in Windows ZIP archives
      return latin1.decode(bytes, allowInvalid: true);
    }
  }
}

// =============================================================================
// Global Cloud Hi-Fi Music Controller (Standalone + MediaLibrary Shared Engine)
// =============================================================================

class CloudMusicController extends ChangeNotifier {
  static const String _prefSavedMusicFoldersKey = 'm3u8_saved_music_folders_v1';
  static const String _prefMountsKey = 'm3u8_storage_mounts_v1';

  static final CloudMusicController shared = CloudMusicController._internal();

  CloudEndpointResolver? _customEndpointResolver;
  AppState? _boundAppState;

  Player? _player;

  List<FileEntry> _queue = [];
  int _currentIndex = -1;
  bool _isPlaying = false;
  bool _isLoadingTrack = false;
  bool _isScanningFolders = false;
  String _scanningStatusText = '';
  String _errorText = '';
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _speed = 1.0;
  double _volume = 100.0;
  String _playMode = 'repeatAll'; // 'sequential', 'repeatAll', 'repeatOne', 'shuffle'

  String _activeStreamUrl = '';
  String _activeSubtitle = '';
  String? _coverImageUrl;
  Map<String, String> _coverImageHeaders = const {};
  bool _coverIsLocalFile = false;

  List<CloudLrcLine> _lyrics = const [];
  String _lyricsSourceLabel = '';
  bool _isLoadingLyrics = false;

  final Map<String, List<FileEntry>> _directoryContextByMountAndDir = {};
  final Map<String, String> _mountNameById = {};
  List<StorageMount> _availableMounts = const [];
  List<SavedMusicFolderItem> _savedMusicFolders = [];

  int _openSeq = 0;
  bool _handlingCompletion = false;
  bool _retriedCurrentTrack = false;
  bool _prefsLoaded = false;

  CloudMusicController._internal() {
    _loadSavedMusicFoldersAndMounts();
  }

  factory CloudMusicController({
    CloudEndpointResolver? endpointResolver,
    AppState? appState,
  }) {
    if (endpointResolver != null) {
      shared._customEndpointResolver = endpointResolver;
    }
    if (appState != null) {
      shared.bindAppState(appState);
    }
    return shared;
  }

  void bindAppState(AppState appState) {
    _boundAppState = appState;
    if (!_prefsLoaded) {
      unawaited(_loadSavedMusicFoldersAndMounts());
    }
  }

  Player? get player => _player;
  List<FileEntry> get queue => _queue;
  int get currentIndex => _currentIndex;
  FileEntry? get currentTrack =>
      (_currentIndex >= 0 && _currentIndex < _queue.length)
          ? _queue[_currentIndex]
          : null;
  bool get hasActiveSession => currentTrack != null;
  bool get isPlaying => _isPlaying;
  bool get isLoadingTrack => _isLoadingTrack;
  bool get isScanningFolders => _isScanningFolders;
  String get scanningStatusText => _scanningStatusText;
  String get errorText => _errorText;
  Duration get position => _position;
  Duration get duration => _duration;
  double get speed => _speed;
  double get volume => _volume;
  String get playMode => _playMode;
  String get activeStreamUrl => _activeStreamUrl;
  String get activeSubtitle => _activeSubtitle;
  String? get coverImageUrl => _coverImageUrl;
  Map<String, String> get coverImageHeaders => _coverImageHeaders;
  bool get coverIsLocalFile => _coverIsLocalFile;
  List<CloudLrcLine> get lyrics => _lyrics;
  String get lyricsSourceLabel => _lyricsSourceLabel;
  bool get isLoadingLyrics => _isLoadingLyrics;
  List<StorageMount> get availableMounts => _availableMounts;
  List<SavedMusicFolderItem> get savedMusicFolders => _savedMusicFolders;

  Future<void> _loadSavedMusicFoldersAndMounts() async {
    _prefsLoaded = true;
    final builtIn = <StorageMount>[
      const StorageMount(
        id: 'builtin_server',
        name: '流光服务端',
        kind: StorageSourceKind.server,
        rootPath: '/',
      ),
      const StorageMount(
        id: 'builtin_115',
        name: '115 网盘直连',
        kind: StorageSourceKind.cloud115,
        rootPath: '0',
      ),
      StorageMount(
        id: 'builtin_local',
        name: '本机离线目录',
        kind: StorageSourceKind.localCache,
        rootPath: RemoteStorageService.defaultLocalDownloadsRoot(),
      ),
    ];
    try {
      final prefs = await SharedPreferences.getInstance();
      final customMounts = <StorageMount>[];
      final rawMounts = prefs.getString(_prefMountsKey);
      if (rawMounts != null && rawMounts.isNotEmpty) {
        final decoded = jsonDecode(rawMounts);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              final m = StorageMount.fromJson(item);
              if (!m.isBuiltIn) customMounts.add(m);
            }
          }
        }
      }
      _availableMounts = [...builtIn, ...customMounts];
      for (final m in _availableMounts) {
        _mountNameById[m.id] = m.name;
      }

      final rawSaved = prefs.getString(_prefSavedMusicFoldersKey);
      if (rawSaved != null && rawSaved.isNotEmpty) {
        final decoded = jsonDecode(rawSaved);
        if (decoded is List) {
          _savedMusicFolders = decoded
              .whereType<Map<String, dynamic>>()
              .map(SavedMusicFolderItem.fromJson)
              .toList();
        }
      }
    } catch (_) {
      _availableMounts = builtIn;
    }
    notifyListeners();
  }

  Future<void> refreshAvailableMounts() async {
    await _loadSavedMusicFoldersAndMounts();
  }

  Future<void> addOrToggleSavedMusicFolder(SavedMusicFolderItem folder) async {
    final idx = _savedMusicFolders.indexWhere((f) => f.uniqueKey == folder.uniqueKey);
    if (idx >= 0) {
      _savedMusicFolders.removeAt(idx);
    } else {
      _savedMusicFolders.insert(0, folder);
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefSavedMusicFoldersKey,
        jsonEncode(_savedMusicFolders.map((f) => f.toJson()).toList()),
      );
    } catch (_) {}
  }

  bool isMusicFolderSaved(String mountId, String path) {
    return _savedMusicFolders.any((f) => f.mountId == mountId && f.path == path);
  }

  Future<({String url, Map<String, String> headers, String subtitle})>
      resolveEntryEndpoint(FileEntry entry) async {
    if (_customEndpointResolver != null) {
      try {
        return await _customEndpointResolver!(entry);
      } catch (_) {}
    }

    final mount = _availableMounts.where((m) => m.id == entry.mountId).firstOrNull;
    switch (entry.sourceKind) {
      case StorageSourceKind.server:
        final api = _boundAppState?.api;
        if (api == null) throw Exception('未连接流光服务端');
        final url = api.buildFileStreamUrl(entry.path);
        return (
          url: url,
          headers: api.authHeaders,
          subtitle: '流光服务端 · ${entry.formattedSize}',
        );
      case StorageSourceKind.alist:
        if (mount == null) throw Exception('未找到对应的 AList 存储挂载');
        final url = await RemoteStorageService.instance.resolveAlistDirectUrl(
          mount,
          entry.path,
          fallbackUrl: entry.rawDownloadUrl,
        );
        return (
          url: url,
          headers: const <String, String>{},
          subtitle: '${mount.name} · ${entry.formattedSize}',
        );
      case StorageSourceKind.webdav:
        if (mount == null) throw Exception('未找到对应的 WebDAV 存储挂载');
        final uri = RemoteStorageService.instance.buildWebdavUri(mount, entry.path);
        final headers = RemoteStorageService.instance.webdavAuthHeaders(mount);
        return (
          url: uri.toString(),
          headers: headers,
          subtitle: '${mount.name} · ${entry.formattedSize}',
        );
      case StorageSourceKind.cloud115:
        await Local115DirectService.instance.ensureInitialized();
        if (entry.pickcode115.isEmpty) {
          throw Exception('该 115 文件缺少 pickcode');
        }
        final directUrl = await Local115DirectService.instance
            .resolvePickcodeStreamUrl(entry.pickcode115);
        if (directUrl == null || directUrl.isEmpty) {
          throw Exception('无法获取 115 直链，请检查 115 登录状态');
        }
        return (
          url: directUrl,
          headers: Local115DirectService.instance.requestHeaders,
          subtitle: '115 网盘直连 · ${entry.formattedSize}',
        );
      case StorageSourceKind.localCache:
        return (
          url: entry.path,
          headers: const <String, String>{},
          subtitle: '本机离线目录 · ${entry.formattedSize}',
        );
    }
  }

  /// Lists any directory across 115 / AList / WebDAV / Server / Local Cache
  Future<List<FileEntry>> listDirectoryForMount(
    StorageMount mount,
    String path,
  ) async {
    switch (mount.kind) {
      case StorageSourceKind.server:
        final api = _boundAppState?.api;
        if (api == null) return const [];
        final res = await api.fetchFiles(path: path);
        return res.entries;
      case StorageSourceKind.alist:
        final res = await RemoteStorageService.instance.listAlistDirectory(
          mount,
          path.isEmpty ? mount.rootPath : path,
        );
        return res.entries;
      case StorageSourceKind.webdav:
        final res = await RemoteStorageService.instance.listWebdavDirectory(
          mount,
          path.isEmpty ? mount.rootPath : path,
        );
        return res.entries;
      case StorageSourceKind.cloud115:
        await Local115DirectService.instance.ensureInitialized();
        final res = await Local115DirectService.instance.list115Directory(
          cid: (path.isEmpty || path == '/') ? '0' : path,
          mountId: mount.id,
        );
        return res.entries;
      case StorageSourceKind.localCache:
        return await _listLocalDirectory(
          path.isEmpty ? mount.rootPath : path,
          mount.id,
        );
    }
  }

  Future<List<FileEntry>> _listLocalDirectory(
    String rawDirPath,
    String mountId,
  ) async {
    final targetPath = rawDirPath.trim().isEmpty
        ? RemoteStorageService.defaultLocalDownloadsRoot()
        : rawDirPath;
    final dir = Directory(targetPath);
    if (!await dir.exists()) return const [];
    final entities = await dir.list(followLinks: false).toList();
    final entries = <FileEntry>[];
    for (final entity in entities) {
      final name = entity.path
              .split(RegExp(r'[/\\]'))
              .where((s) => s.isNotEmpty)
              .lastOrNull ??
          '';
      if (name.isEmpty || name.startsWith('.')) continue;
      try {
        final stat = await entity.stat();
        final isDir = stat.type == FileSystemEntityType.directory;
        String ext = '';
        if (!isDir) {
          final dot = name.lastIndexOf('.');
          if (dot > 0) ext = name.substring(dot).toLowerCase();
        }
        final dt = stat.modified;
        final modTime =
            '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
            '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
        entries.add(
          FileEntry(
            name: name,
            path: entity.path,
            size: isDir ? 0 : stat.size,
            modTime: modTime,
            isDir: isDir,
            isMp4: ext == '.mp4',
            ext: ext,
            mountId: mountId,
            sourceKind: StorageSourceKind.localCache,
            rawDownloadUrl: Uri.file(entity.path).toString(),
          ),
        );
      } catch (_) {}
    }
    return entries;
  }

  /// Recursively scans selected folders and/or `.zip`/`.tar` archives across 115, AList, WebDAV, Server, and Local Cache,
  /// collects all audio files (including tracks inside `.zip` / `.tar` archives!), and plays them (in shuffle mode by default!).
  Future<int> scanAndPlayFoldersOrArchives({
    required List<SavedMusicFolderItem> sources,
    bool shuffle = true,
    bool includeSubfolders = true,
    bool includeArchives = true,
  }) async {
    if (sources.isEmpty) return 0;
    await refreshAvailableMounts();

    _isScanningFolders = true;
    _scanningStatusText = '正在扫描所选目录与压缩包中的音乐...';
    _errorText = '';
    notifyListeners();

    final collectedTracks = <FileEntry>[];
    final visitedKeys = <String>{};

    try {
      Future<void> scanFolderRecursive(
        StorageMount mount,
        String folderPath,
        String folderTitle,
        int depth,
      ) async {
        final key = '${mount.id}::$folderPath';
        if (visitedKeys.contains(key)) return;
        visitedKeys.add(key);

        _scanningStatusText = '正在扫描「${mount.name} / $folderTitle」... (已发现 ${collectedTracks.length} 首)';
        notifyListeners();

        List<FileEntry> entries = const [];
        try {
          entries = await listDirectoryForMount(mount, folderPath);
        } catch (_) {
          return;
        }
        if (entries.isEmpty) return;

        registerDirectoryContext(
          mounts: _availableMounts,
          directoryEntries: entries,
        );

        final subfolders = <FileEntry>[];
        for (final e in entries) {
          if (e.isDir) {
            subfolders.add(e);
          } else if (e.isAudio) {
            collectedTracks.add(e);
          } else if (includeArchives && e.isStreamableMusicArchive) {
            _scanningStatusText =
                '正在解析压缩包「${e.name}」内的音乐... (已发现 ${collectedTracks.length} 首)';
            notifyListeners();
            try {
              final archiveEntries =
                  await CloudArchiveMusicService.instance.inspectArchiveEntries(
                archiveEntry: e,
                endpointResolver: resolveEntryEndpoint,
              );
              if (archiveEntries.isNotEmpty) {
                registerDirectoryContext(
                  mounts: _availableMounts,
                  directoryEntries: archiveEntries,
                );
                for (final inner in archiveEntries) {
                  if (inner.isAudio) {
                    collectedTracks.add(inner);
                  }
                }
              }
            } catch (_) {}
          }
        }

        if (includeSubfolders && depth < 2 && subfolders.isNotEmpty) {
          // Scan up to 12 subfolders per directory to prevent excessive network wait on huge trees
          for (final sub in subfolders.take(12)) {
            await scanFolderRecursive(mount, sub.path, sub.name, depth + 1);
          }
        }
      }

      for (final src in sources) {
        final mount = _availableMounts
                .where((m) => m.id == src.mountId)
                .firstOrNull ??
            StorageMount(
              id: src.mountId,
              name: src.mountName,
              kind: src.sourceKind,
              rootPath: src.path,
            );

        if (src.isArchive) {
          _scanningStatusText = '正在读取压缩包「${src.title}」曲目列表...';
          notifyListeners();
          final archiveFile = FileEntry(
            name: src.title,
            path: src.path,
            size: src.size,
            modTime: '',
            isDir: false,
            isMp4: false,
            ext: '',
            mountId: src.mountId,
            sourceKind: src.sourceKind,
            pickcode115: src.pickcode115,
          );
          try {
            final archiveEntries =
                await CloudArchiveMusicService.instance.inspectArchiveEntries(
              archiveEntry: archiveFile,
              endpointResolver: resolveEntryEndpoint,
            );
            if (archiveEntries.isNotEmpty) {
              registerDirectoryContext(
                mounts: _availableMounts,
                directoryEntries: archiveEntries,
              );
              collectedTracks.addAll(archiveEntries.where((e) => e.isAudio));
            }
          } catch (_) {}
        } else {
          final lowerTitle = src.title.toLowerCase();
          final lowerPath = src.path.toLowerCase();
          final dotIdx = lowerTitle.lastIndexOf('.');
          final titleExt = (dotIdx > 0 && dotIdx < lowerTitle.length - 1)
              ? lowerTitle.substring(dotIdx)
              : '';
          final potentialTrack = FileEntry(
            name: src.title,
            path: src.path,
            size: src.size,
            modTime: '',
            isDir: false,
            isMp4: titleExt == '.mp4',
            ext: titleExt,
            mountId: src.mountId,
            sourceKind: src.sourceKind,
            pickcode115: src.pickcode115,
          );
          if (potentialTrack.isAudio ||
              RegExp(r'\.(ape|wav|wave|flac|mp3|m4a|aac|ogg|opus|alac|aiff|aif|wma|dsf|dff|wv|tta)$')
                  .hasMatch(lowerPath)) {
            collectedTracks.add(potentialTrack);
          } else {
            await scanFolderRecursive(mount, src.path, src.title, 0);
          }
        }
      }

      _isScanningFolders = false;
      _scanningStatusText = '';

      if (collectedTracks.isEmpty) {
        _errorText = '所选文件夹或压缩包内未找到可播放的音乐文件';
        notifyListeners();
        return 0;
      }

      if (shuffle) {
        _playMode = 'shuffle';
        collectedTracks.shuffle(math.Random());
      } else if (_playMode == 'shuffle') {
        _playMode = 'repeatAll';
      }

      _queue = collectedTracks;
      _currentIndex = 0;
      notifyListeners();
      await _openCurrentTrack();
      return collectedTracks.length;
    } catch (e) {
      _isScanningFolders = false;
      _scanningStatusText = '';
      _errorText = '扫描音乐目录失败：$e';
      notifyListeners();
      return 0;
    }
  }

  /// Directly inspects a `.zip` / `.cbz` / `.tar` archive and plays its inner audio files!
  Future<int> playArchiveMusic({
    required FileEntry archiveEntry,
    bool shuffle = false,
    FileEntry? startWithInnerTrack,
    List<StorageMount>? mounts,
  }) async {
    if (mounts != null && mounts.isNotEmpty) {
      for (final m in mounts) {
        _mountNameById[m.id] = m.name;
      }
    }
    _isScanningFolders = true;
    _scanningStatusText = '正在读取压缩包「${archiveEntry.name}」内的音乐列表...';
    _errorText = '';
    notifyListeners();

    try {
      final allInner = await CloudArchiveMusicService.instance.inspectArchiveEntries(
        archiveEntry: archiveEntry,
        endpointResolver: resolveEntryEndpoint,
      );
      _isScanningFolders = false;
      _scanningStatusText = '';

      final audioTracks = allInner.where((e) => e.isAudio).toList();
      if (audioTracks.isEmpty) {
        _errorText = '压缩包「${archiveEntry.name}」内未发现支持的音频文件';
        notifyListeners();
        return 0;
      }

      registerDirectoryContext(
        mounts: _availableMounts,
        directoryEntries: allInner,
      );

      if (shuffle) {
        _playMode = 'shuffle';
        audioTracks.shuffle(math.Random());
        _queue = audioTracks;
        _currentIndex = 0;
      } else {
        _queue = audioTracks;
        if (startWithInnerTrack != null) {
          final idx = _queue.indexWhere((e) => e.path == startWithInnerTrack.path);
          _currentIndex = idx >= 0 ? idx : 0;
        } else {
          _currentIndex = 0;
        }
      }
      notifyListeners();
      await _openCurrentTrack();
      return audioTracks.length;
    } catch (e) {
      _isScanningFolders = false;
      _scanningStatusText = '';
      _errorText = '解析压缩包音乐失败：$e';
      notifyListeners();
      return 0;
    }
  }

  int get activeLyricIndex {
    if (_lyrics.isEmpty) return -1;
    final posMs = _position.inMilliseconds + 180;
    int idx = -1;
    for (int i = 0; i < _lyrics.length; i++) {
      if (_lyrics[i].timestamp.inMilliseconds <= posMs) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  String get currentLyricLineText {
    final idx = activeLyricIndex;
    if (idx >= 0 && idx < _lyrics.length) {
      return _lyrics[idx].text;
    }
    return '';
  }

  static ({String title, String artist, String qualityTag}) parseTrackMetadata(
    FileEntry entry, {
    String fallbackArtist = '',
  }) {
    String base = entry.name;
    final dot = base.lastIndexOf('.');
    if (dot > 0) {
      base = base.substring(0, dot);
    }
    base = base.replaceAll(RegExp(r'^\s*(\[\d+\]|\d+[\.\-_、\s]+)\s*'), '').trim();

    String artist = entry.isInsideArchive && fallbackArtist.isEmpty
        ? entry.archiveContainerName
        : fallbackArtist;
    String title = base;
    final dashIdx = base.indexOf(' - ');
    if (dashIdx > 0 && dashIdx < base.length - 3) {
      artist = base.substring(0, dashIdx).trim();
      title = base.substring(dashIdx + 3).trim();
    } else {
      final altDash = base.indexOf('-');
      if (altDash > 1 && altDash < 24 && altDash < base.length - 2) {
        artist = base.substring(0, altDash).trim();
        title = base.substring(altDash + 1).trim();
      }
    }
    if (title.isEmpty) title = entry.name;

    final ext = entry.normalizedExt.replaceAll('.', '').toUpperCase();
    String qualityTag;
    switch (ext) {
      case 'FLAC':
        qualityTag = entry.size > 35 * 1024 * 1024 ? 'Hi-Res · FLAC 无损' : 'FLAC 无损';
        break;
      case 'WAV':
      case 'WAVE':
      case 'AIFF':
      case 'AIF':
      case 'AIFC':
        qualityTag = '${ext == 'WAVE' ? 'WAV' : ext} 母带无损';
        break;
      case 'APE':
      case 'MAC':
      case 'ALAC':
      case 'WV':
      case 'TTA':
      case 'TAK':
        qualityTag = '${ext == 'MAC' ? 'APE' : ext} 无损音频';
        break;
      case 'DSF':
      case 'DFF':
        qualityTag = 'DSD 母带';
        break;
      case 'MP3':
        qualityTag = entry.size > 7 * 1024 * 1024 ? 'MP3 320K' : 'MP3';
        break;
      case 'M4A':
      case 'AAC':
        qualityTag = 'AAC 高清';
        break;
      case 'OGG':
      case 'OGA':
      case 'OPUS':
        qualityTag = '$ext 高清';
        break;
      default:
        qualityTag = ext.isEmpty ? 'AUDIO' : ext;
    }
    if (entry.isInsideArchive) {
      qualityTag = '📦 $qualityTag';
    }

    return (title: title, artist: artist, qualityTag: qualityTag);
  }

  String mountNameFor(FileEntry entry) {
    final baseMount = _mountNameById[entry.mountId] ?? entry.sourceKind.badge;
    if (entry.isInsideArchive && entry.archiveContainerName.isNotEmpty) {
      return '$baseMount · 📦 ${entry.archiveContainerName}';
    }
    return baseMount;
  }

  void registerDirectoryContext({
    required List<StorageMount> mounts,
    required List<FileEntry> directoryEntries,
  }) {
    for (final m in mounts) {
      _mountNameById[m.id] = m.name;
    }
    if (directoryEntries.isNotEmpty) {
      final first = directoryEntries.first;
      final dirKey = _dirKeyForEntry(first);
      _directoryContextByMountAndDir[dirKey] = List<FileEntry>.from(directoryEntries);
    }
  }

  String _dirKeyForEntry(FileEntry entry) {
    if (entry.isInsideArchive) {
      return '${entry.mountId}::archive::${entry.archiveContainerPath}';
    }
    if (entry.sourceKind == StorageSourceKind.cloud115) {
      return '${entry.mountId}::${entry.cid115}';
    }
    final slash = entry.path.lastIndexOf('/');
    final parent = slash > 0 ? entry.path.substring(0, slash) : '/';
    return '${entry.mountId}::$parent';
  }

  void _ensurePlayerInitialized() {
    if (_player != null) return;
    final p = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 32 * 1024 * 1024,
      ),
    );
    _player = p;
    p.stream.playing.listen((playing) {
      if (_isPlaying != playing || (playing && _isLoadingTrack)) {
        _isPlaying = playing;
        if (playing) {
          _isLoadingTrack = false;
          _errorText = '';
        }
        notifyListeners();
      }
    });
    p.stream.position.listen((pos) {
      if (pos > Duration.zero && _isLoadingTrack) {
        _isLoadingTrack = false;
      }
      if ((pos.inMilliseconds - _position.inMilliseconds).abs() >= 200 ||
          pos == Duration.zero) {
        _position = pos;
        notifyListeners();
      }
    });
    p.stream.duration.listen((dur) {
      if (dur > Duration.zero && dur != _duration) {
        _duration = dur;
        notifyListeners();
      }
    });
    p.stream.completed.listen((completed) {
      if (completed) {
        _onTrackCompleted();
      }
    });
    p.stream.error.listen((err) {
      if (err.trim().isEmpty) return;
      if (!_retriedCurrentTrack && currentTrack != null) {
        _retriedCurrentTrack = true;
        unawaited(_openCurrentTrack(forceRefreshUrl: true));
      }
    });
  }

  Future<void> playFromDirectory({
    required FileEntry targetTrack,
    required List<FileEntry> directoryEntries,
    required List<StorageMount> mounts,
    bool shuffle = false,
  }) async {
    registerDirectoryContext(mounts: mounts, directoryEntries: directoryEntries);
    final audioTracks = directoryEntries.where((e) => !e.isDir && e.isAudio).toList();
    if (audioTracks.isEmpty) {
      _queue = [targetTrack];
      _currentIndex = 0;
    } else if (shuffle) {
      _playMode = 'shuffle';
      audioTracks.shuffle(math.Random());
      _queue = audioTracks;
      _currentIndex = 0;
    } else {
      _queue = audioTracks;
      final idx = _queue.indexWhere(
        (e) => e.path == targetTrack.path && e.mountId == targetTrack.mountId,
      );
      if (idx >= 0) {
        _currentIndex = idx;
      } else {
        _queue.insert(0, targetTrack);
        _currentIndex = 0;
      }
    }
    await _openCurrentTrack();
  }

  /// Shuffles the current queue and starts playing a random track immediately!
  Future<void> shuffleCurrentQueue() async {
    if (_queue.isEmpty) return;
    _playMode = 'shuffle';
    _queue.shuffle(math.Random());
    _currentIndex = 0;
    notifyListeners();
    await _openCurrentTrack();
  }

  Future<void> addToQueue(
    FileEntry track, {
    bool playNext = false,
    List<FileEntry>? directoryEntries,
    List<StorageMount>? mounts,
  }) async {
    if (mounts != null && directoryEntries != null) {
      registerDirectoryContext(mounts: mounts, directoryEntries: directoryEntries);
    }
    final existingIdx = _queue.indexWhere(
      (e) => e.path == track.path && e.mountId == track.mountId,
    );
    if (_queue.isEmpty || _currentIndex < 0) {
      _queue = [track];
      _currentIndex = 0;
      await _openCurrentTrack();
      return;
    }
    if (existingIdx >= 0) {
      if (playNext && existingIdx != _currentIndex) {
        final item = _queue.removeAt(existingIdx);
        if (existingIdx < _currentIndex) _currentIndex--;
        final insertIdx = (_currentIndex + 1).clamp(0, _queue.length);
        _queue.insert(insertIdx, item);
      }
      notifyListeners();
      return;
    }
    if (playNext) {
      final insertIdx = (_currentIndex + 1).clamp(0, _queue.length);
      _queue.insert(insertIdx, track);
    } else {
      _queue.add(track);
    }
    notifyListeners();
  }

  Future<void> playQueueIndex(int index) async {
    if (index < 0 || index >= _queue.length) return;
    if (index == _currentIndex && _player != null && _errorText.isEmpty) {
      await togglePlayPause();
      return;
    }
    _currentIndex = index;
    await _openCurrentTrack();
  }

  Future<void> removeTrackAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    final removingCurrent = index == _currentIndex;
    _queue.removeAt(index);
    if (_queue.isEmpty) {
      await stopAndClose();
      return;
    }
    if (index < _currentIndex) {
      _currentIndex--;
    } else if (removingCurrent) {
      if (_currentIndex >= _queue.length) {
        _currentIndex = 0;
      }
      await _openCurrentTrack();
      return;
    }
    notifyListeners();
  }

  Future<void> _openCurrentTrack({bool forceRefreshUrl = false}) async {
    final track = currentTrack;
    if (track == null) return;
    _ensurePlayerInitialized();
    final seq = ++_openSeq;
    if (!forceRefreshUrl) {
      _retriedCurrentTrack = false;
    }

    _isLoadingTrack = true;
    _errorText = '';
    _position = Duration.zero;
    _duration = Duration.zero;
    notifyListeners();

    unawaited(_loadCoverAndLyricsForTrack(track, seq));

    try {
      String playUrl;
      Map<String, String> playHeaders = const {};
      String subtitle;

      if (track.isInsideArchive) {
        // On-demand HTTP Range single-track extraction from `.zip` / `.cbz` / `.tar`
        final extractedLocalPath =
            await CloudArchiveMusicService.instance.extractArchiveAudioToTempFile(
          entry: track,
          endpointResolver: resolveEntryEndpoint,
        );
        if (seq != _openSeq) return;
        playUrl = extractedLocalPath;
        subtitle = '📦 ${track.archiveContainerName} · ${track.formattedSize}';
      } else {
        final resolved = await resolveEntryEndpoint(track);
        if (seq != _openSeq) return;
        playUrl = resolved.url;
        playHeaders = resolved.headers;
        subtitle = resolved.subtitle;
        final lowerUrl = playUrl.toLowerCase();
        final ext = track.normalizedExt;
        final isLosslessNeedsExtensionProxy = const {
          '.ape',
          '.mac',
          '.wav',
          '.wave',
          '.flac',
          '.alac',
          '.aiff',
          '.aif',
          '.dsf',
          '.dff',
          '.wv',
          '.tta',
          '.tak',
          '.wma',
        }.contains(ext);
        final uriPathLower = Uri.tryParse(playUrl)?.path.toLowerCase() ?? '';
        final urlLacksAudioExtension =
            ext.isNotEmpty && !uriPathLower.endsWith(ext);

        if (!lowerUrl.contains('.m3u8') &&
            track.sourceKind != StorageSourceKind.localCache &&
            (track.sourceKind == StorageSourceKind.cloud115 ||
                (isLosslessNeedsExtensionProxy &&
                    (urlLacksAudioExtension || playHeaders.isNotEmpty)))) {
          playUrl =
              await Local115DirectService.instance.wrapWithLocal115HeaderProxy(
            playUrl,
            playHeaders,
            extHint: ext,
          );
          playHeaders = const {};
        }
      }
      if (seq != _openSeq) return;

      _activeStreamUrl = playUrl;
      _activeSubtitle = subtitle;
      notifyListeners();

      await _player!.open(
        Media(playUrl, httpHeaders: playHeaders),
        play: true,
      );
      if (seq != _openSeq) return;
      if (_speed != 1.0) {
        await _player!.setRate(_speed);
      }
      if (_volume != 100.0) {
        await _player!.setVolume(_volume);
      }
    } catch (e) {
      if (seq != _openSeq) return;
      _isLoadingTrack = false;
      _isPlaying = false;
      _errorText = '音频加载失败：$e';
      notifyListeners();
    }
  }

  Future<void> _loadCoverAndLyricsForTrack(FileEntry track, int seq) async {
    _coverImageUrl = track.thumbUrl.isNotEmpty ? track.thumbUrl : null;
    _coverImageHeaders = const {};
    _coverIsLocalFile = false;
    _lyrics = const [];
    _lyricsSourceLabel = '';
    _isLoadingLyrics = true;
    notifyListeners();

    final dirKey = _dirKeyForEntry(track);
    final siblings = _directoryContextByMountAndDir[dirKey] ?? const [];
    final baseName = _stripExt(track.name).toLowerCase();

    // 1. Discover cover art in same folder or inside the same `.zip` / `.tar` archive!
    if (siblings.isNotEmpty) {
      FileEntry? coverEntry;
      for (final s in siblings) {
        if (!s.isImage) continue;
        final sBase = _stripExt(s.name).toLowerCase();
        if (sBase == baseName) {
          coverEntry = s;
          break;
        }
      }
      if (coverEntry == null) {
        for (final s in siblings) {
          if (!s.isImage) continue;
          final sBase = _stripExt(s.name).toLowerCase();
          if (const {'cover', 'folder', 'album', 'front', 'artwork', 'thumb'}
              .contains(sBase)) {
            coverEntry = s;
            break;
          }
        }
      }
      coverEntry ??= siblings.where((s) => s.isImage).firstOrNull;

      if (coverEntry != null) {
        try {
          if (coverEntry.isInsideArchive) {
            final extractedPath = await CloudArchiveMusicService.instance
                .extractArchiveAudioToTempFile(
              entry: coverEntry,
              endpointResolver: resolveEntryEndpoint,
            );
            if (seq == _openSeq) {
              _coverImageUrl = extractedPath;
              _coverIsLocalFile = true;
            }
          } else if (coverEntry.sourceKind == StorageSourceKind.localCache) {
            _coverImageUrl = coverEntry.path;
            _coverIsLocalFile = true;
          } else {
            final res = await resolveEntryEndpoint(coverEntry);
            if (seq == _openSeq && res.url.isNotEmpty) {
              _coverImageUrl = res.url;
              _coverImageHeaders = res.headers;
              _coverIsLocalFile = false;
            }
          }
          if (seq == _openSeq) notifyListeners();
        } catch (_) {}
      }
    }

    // 2. Discover `.lrc` sidecar file in the same directory or inside the same `.zip` / `.tar` archive!
    FileEntry? lrcEntry;
    if (siblings.isNotEmpty) {
      for (final s in siblings) {
        if (s.isDir || s.normalizedExt != '.lrc') continue;
        final sBase = _stripExt(s.name).toLowerCase();
        if (sBase == baseName ||
            baseName.contains(sBase) ||
            sBase.contains(baseName)) {
          lrcEntry = s;
          break;
        }
      }
    }

    if (lrcEntry != null) {
      try {
        final rawLrc = await _fetchTextFromEntry(lrcEntry);
        if (seq == _openSeq && rawLrc.trim().isNotEmpty) {
          final parsed = parseLrcContent(rawLrc);
          if (parsed.isNotEmpty) {
            _lyrics = parsed;
            _lyricsSourceLabel = lrcEntry.isInsideArchive
                ? '压缩包内 .lrc 歌词 (${lrcEntry.name})'
                : '同目录 .lrc 歌词 (${lrcEntry.name})';
            _isLoadingLyrics = false;
            notifyListeners();
            return;
          }
        }
      } catch (_) {}
    }

    // 3. Fallback: Query open-source LRCLIB synchronized lyrics API
    try {
      final meta = parseTrackMetadata(track);
      final query = meta.artist.isNotEmpty &&
              !meta.artist.contains('115') &&
              !meta.artist.contains('AList') &&
              !meta.artist.endsWith('.zip') &&
              !meta.artist.endsWith('.tar')
          ? '${meta.artist} ${meta.title}'
          : meta.title;
      final onlineLrc = await _fetchOnlineLrcFromLrclib(query);
      if (seq == _openSeq && onlineLrc != null && onlineLrc.isNotEmpty) {
        _lyrics = onlineLrc;
        _lyricsSourceLabel = 'LRCLIB 云端同步歌词';
        _isLoadingLyrics = false;
        notifyListeners();
        return;
      }
    } catch (_) {}

    if (seq == _openSeq) {
      _isLoadingLyrics = false;
      notifyListeners();
    }
  }

  Future<String> _fetchTextFromEntry(FileEntry entry) async {
    if (entry.isInsideArchive) {
      final bytes = await CloudArchiveMusicService.instance.extractArchiveEntryBytes(
        entry: entry,
        endpointResolver: resolveEntryEndpoint,
      );
      return _decodeTextBytes(bytes);
    }
    if (entry.sourceKind == StorageSourceKind.localCache) {
      final bytes = await File(entry.path).readAsBytes();
      return _decodeTextBytes(bytes);
    }
    final resolved = await resolveEntryEndpoint(entry);
    final client = HttpClient()..badCertificateCallback = (_, __, ___) => true;
    try {
      final req = await client.getUrl(Uri.parse(resolved.url));
      resolved.headers.forEach((k, v) {
        if (v.isNotEmpty) req.headers.set(k, v);
      });
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final bytes = await resp.fold<List<int>>(
        <int>[],
        (acc, chunk) {
          if (acc.length < 256 * 1024) acc.addAll(chunk);
          return acc;
        },
      );
      return _decodeTextBytes(bytes);
    } finally {
      client.close(force: true);
    }
  }

  static String _decodeTextBytes(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  Future<List<CloudLrcLine>?> _fetchOnlineLrcFromLrclib(String query) async {
    final cleanQ = query
        .replaceAll(RegExp(r'\(.*?\)|\[.*?\]|【.*?】'), ' ')
        .trim();
    if (cleanQ.isEmpty) return null;
    final uri = Uri.parse(
      'https://lrclib.net/api/search?q=${Uri.encodeQueryComponent(cleanQ)}',
    );
    final client = HttpClient()..badCertificateCallback = (_, __, ___) => true;
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 6));
      req.headers.set('User-Agent', 'LiuguangMusicPlayer/1.2.1');
      final resp = await req.close().timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is List && decoded.isNotEmpty) {
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            final synced = (item['syncedLyrics'] ?? '').toString().trim();
            if (synced.isNotEmpty) {
              final parsed = parseLrcContent(synced);
              if (parsed.isNotEmpty) return parsed;
            }
          }
        }
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            final plain = (item['plainLyrics'] ?? '').toString().trim();
            if (plain.isNotEmpty) {
              final lines = plain
                  .split(RegExp(r'\r?\n'))
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty)
                  .toList();
              if (lines.isNotEmpty) {
                return [
                  for (int i = 0; i < lines.length; i++)
                    CloudLrcLine(
                      timestamp: Duration(seconds: i * 4),
                      text: lines[i],
                    ),
                ];
              }
            }
          }
        }
      }
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
    return null;
  }

  static List<CloudLrcLine> parseLrcContent(String raw) {
    final result = <CloudLrcLine>[];
    final tagReg = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[\.:](\d{1,3}))?\]');
    for (final rawLine in raw.split(RegExp(r'\r?\n'))) {
      final matches = tagReg.allMatches(rawLine).toList();
      if (matches.isEmpty) continue;
      final lyricText = rawLine.replaceAll(tagReg, '').trim();
      if (lyricText.isEmpty) continue;
      for (final m in matches) {
        final min = int.tryParse(m.group(1) ?? '0') ?? 0;
        final sec = int.tryParse(m.group(2) ?? '0') ?? 0;
        final fracStr = m.group(3) ?? '0';
        int ms = int.tryParse(fracStr) ?? 0;
        if (fracStr.length == 1) {
          ms *= 100;
        } else if (fracStr.length == 2) {
          ms *= 10;
        }
        result.add(
          CloudLrcLine(
            timestamp: Duration(minutes: min, seconds: sec, milliseconds: ms),
            text: lyricText,
          ),
        );
      }
    }
    result.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return result;
  }

  static String _stripExt(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  Future<void> togglePlayPause() async {
    if (currentTrack == null) return;
    if (_errorText.isNotEmpty || _player == null) {
      await _openCurrentTrack(forceRefreshUrl: true);
      return;
    }
    await _player!.playOrPause();
  }

  Future<void> seekTo(Duration target) async {
    if (_player == null) return;
    _position = target;
    notifyListeners();
    await _player!.seek(target);
  }

  Future<void> seekRelative(Duration delta) async {
    if (_player == null) return;
    final maxMs = _duration.inMilliseconds > 0 ? _duration.inMilliseconds : 86400000;
    final nextMs = (_position.inMilliseconds + delta.inMilliseconds).clamp(0, maxMs);
    await seekTo(Duration(milliseconds: nextMs));
  }

  Future<void> stepTrack(int delta) async {
    if (_queue.isEmpty) return;
    if (delta < 0 && _position.inSeconds >= 5) {
      await seekTo(Duration.zero);
      return;
    }
    if (_queue.length == 1) {
      await seekTo(Duration.zero);
      await _player?.play();
      return;
    }
    if (_playMode == 'shuffle') {
      final rnd = math.Random();
      int nextIdx = _currentIndex;
      for (int i = 0; i < 6; i++) {
        final cand = rnd.nextInt(_queue.length);
        if (cand != _currentIndex) {
          nextIdx = cand;
          break;
        }
      }
      _currentIndex = nextIdx;
    } else {
      _currentIndex = (_currentIndex + delta + _queue.length) % _queue.length;
    }
    await _openCurrentTrack();
  }

  Future<void> _onTrackCompleted() async {
    if (_handlingCompletion || _queue.isEmpty) return;
    _handlingCompletion = true;
    try {
      if (_playMode == 'repeatOne') {
        await _player?.seek(Duration.zero);
        await _player?.play();
        return;
      }
      if (_queue.length == 1) {
        if (_playMode == 'repeatAll') {
          await _player?.seek(Duration.zero);
          await _player?.play();
        } else {
          _isPlaying = false;
          _position = Duration.zero;
          notifyListeners();
        }
        return;
      }
      if (_playMode == 'shuffle') {
        final rnd = math.Random();
        int nextIdx = _currentIndex;
        for (int i = 0; i < 6; i++) {
          final cand = rnd.nextInt(_queue.length);
          if (cand != _currentIndex) {
            nextIdx = cand;
            break;
          }
        }
        _currentIndex = nextIdx;
        await _openCurrentTrack();
      } else if (_currentIndex + 1 < _queue.length) {
        _currentIndex++;
        await _openCurrentTrack();
      } else if (_playMode == 'repeatAll') {
        _currentIndex = 0;
        await _openCurrentTrack();
      } else {
        _isPlaying = false;
        _position = Duration.zero;
        notifyListeners();
      }
    } finally {
      _handlingCompletion = false;
    }
  }

  void cyclePlayMode() {
    const modes = ['repeatAll', 'repeatOne', 'shuffle', 'sequential'];
    final idx = modes.indexOf(_playMode);
    _playMode = modes[(idx + 1) % modes.length];
    notifyListeners();
  }

  void cycleSpeed() {
    const speeds = [1.0, 1.25, 1.5, 2.0, 0.75];
    final idx = speeds.indexOf(_speed);
    _speed = speeds[(idx + 1) % speeds.length];
    _player?.setRate(_speed);
    notifyListeners();
  }

  void setVolume(double v) {
    _volume = v.clamp(0.0, 100.0);
    _player?.setVolume(_volume);
    notifyListeners();
  }

  Future<void> stopAndClose() async {
    _openSeq++;
    await _player?.stop();
    _queue = [];
    _currentIndex = -1;
    _isPlaying = false;
    _isLoadingTrack = false;
    _errorText = '';
    _position = Duration.zero;
    _duration = Duration.zero;
    _lyrics = const [];
    _coverImageUrl = null;
    notifyListeners();
  }
}

// =============================================================================
// 1. Multi-Source Music Folder & Archive Picker Dialog (自选文件夹/压缩包随机播放)
// =============================================================================

class CloudMusicFolderPickerDialog extends StatefulWidget {
  final CloudMusicController controller;
  final StorageMount? initialMount;
  final String? initialPath;

  const CloudMusicFolderPickerDialog({
    super.key,
    required this.controller,
    this.initialMount,
    this.initialPath,
  });

  @override
  State<CloudMusicFolderPickerDialog> createState() =>
      _CloudMusicFolderPickerDialogState();
}

class _CloudMusicFolderPickerDialogState
    extends State<CloudMusicFolderPickerDialog> {
  StorageMount? _activeMount;
  String _currentPath = '';
  String _currentTitle = '根目录';
  final List<({String path, String title})> _breadcrumbs = [];
  List<FileEntry> _entries = const [];
  bool _isLoading = false;
  String? _error;
  bool _includeSubfolders = true;

  final List<SavedMusicFolderItem> _selectedItems = [];

  CloudMusicController get _ctrl => widget.controller;

  @override
  void initState() {
    super.initState();
    _initMountsAndLoad();
  }

  Future<void> _initMountsAndLoad() async {
    await _ctrl.refreshAvailableMounts();
    if (!mounted) return;
    final mounts = _ctrl.availableMounts;
    final preferred = widget.initialMount != null
        ? (mounts.where((m) => m.id == widget.initialMount!.id).firstOrNull ??
            widget.initialMount)
        : (Local115DirectService.instance.hasLocalCookie
            ? (mounts
                    .where((m) => m.kind == StorageSourceKind.cloud115)
                    .firstOrNull ??
                mounts.firstOrNull)
            : mounts.firstOrNull);
    if (preferred != null) {
      await _selectMount(preferred, overridePath: widget.initialPath);
    }
  }

  Future<void> _selectMount(
    StorageMount mount, {
    String? overridePath,
  }) async {
    final defaultRoot = switch (mount.kind) {
      StorageSourceKind.server => '',
      StorageSourceKind.cloud115 => '0',
      _ => mount.rootPath,
    };
    final initPath = (overridePath != null && overridePath.isNotEmpty)
        ? overridePath
        : defaultRoot;
    setState(() {
      _activeMount = mount;
      _breadcrumbs
        ..clear()
        ..add((path: defaultRoot, title: mount.name));
      if (initPath != defaultRoot) {
        _breadcrumbs.add((path: initPath, title: initPath));
      }
    });
    await _loadDir(initPath, title: mount.name, pushCrumb: false);
  }

  Future<void> _loadDir(
    String path, {
    required String title,
    bool pushCrumb = true,
  }) async {
    final mount = _activeMount;
    if (mount == null) return;
    setState(() {
      _isLoading = true;
      _error = null;
      _currentPath = path;
      _currentTitle = title;
      if (pushCrumb) {
        final existingIdx = _breadcrumbs.indexWhere((c) => c.path == path);
        if (existingIdx >= 0) {
          _breadcrumbs.removeRange(existingIdx + 1, _breadcrumbs.length);
        } else {
          _breadcrumbs.add((path: path, title: title));
        }
      }
    });
    try {
      final list = await _ctrl.listDirectoryForMount(mount, path);
      if (!mounted) return;
      list.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      setState(() {
        _entries = list;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _isLoading = false;
      });
    }
  }

  void _toggleSelection(SavedMusicFolderItem item) {
    setState(() {
      final idx = _selectedItems.indexWhere((s) => s.uniqueKey == item.uniqueKey);
      if (idx >= 0) {
        _selectedItems.removeAt(idx);
      } else {
        _selectedItems.add(item);
      }
    });
  }

  bool _isSelected(String mountId, String path) {
    return _selectedItems.any((s) => s.mountId == mountId && s.path == path);
  }

  SavedMusicFolderItem _currentDirectoryAsItem() {
    final m = _activeMount!;
    return SavedMusicFolderItem(
      mountId: m.id,
      mountName: m.name,
      sourceKind: m.kind,
      path: _currentPath,
      title: _currentTitle.isEmpty ? m.name : _currentTitle,
      isArchive: false,
    );
  }

  bool _stepBackFolderIfPossible() {
    if (_breadcrumbs.length >= 2) {
      final prev = _breadcrumbs[_breadcrumbs.length - 2];
      _loadDir(prev.path, title: prev.title);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final mounts = _ctrl.availableMounts;
    final activeMount = _activeMount;
    final audioInCurrentDir = _entries.where((e) => !e.isDir && e.isAudio).length;
    final archivesInCurrentDir =
        _entries.where((e) => !e.isDir && e.isStreamableMusicArchive).length;
    final screenSize = MediaQuery.sizeOf(context);
    final isMobile = screenSize.width < 680;

    return PopScope(
      canPop: _breadcrumbs.length <= 1,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (!_stepBackFolderIfPossible()) {
          Navigator.of(context).pop();
        }
      },
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.goBack ||
                  event.logicalKey == LogicalKeyboardKey.escape ||
                  event.logicalKey == LogicalKeyboardKey.browserBack)) {
            if (_stepBackFolderIfPossible()) {
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: AlertDialog(
          backgroundColor: VideoPlatformTheme.bgElevated,
          insetPadding: EdgeInsets.symmetric(
            horizontal: isMobile ? 10 : 24,
            vertical: isMobile ? 12 : 24,
          ),
          titlePadding: EdgeInsets.fromLTRB(
            isMobile ? 14 : 20,
            12,
            isMobile ? 8 : 14,
            4,
          ),
          contentPadding: EdgeInsets.fromLTRB(
            isMobile ? 12 : 20,
            8,
            isMobile ? 12 : 20,
            8,
          ),
          actionsPadding: EdgeInsets.fromLTRB(
            isMobile ? 12 : 20,
            4,
            isMobile ? 12 : 20,
            12,
          ),
          title: Row(
            children: [
              Icon(
                Icons.folder_special_rounded,
                color: VideoPlatformTheme.accent,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isMobile
                      ? '自选音乐目录 / 压缩包'
                      : '自选音乐文件夹 / 压缩包 (支持 115 · AList · WebDAV · 本地)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: isMobile ? 14.5 : 15.5,
                    fontWeight: FontWeight.w800,
                    color: VideoPlatformTheme.textPrimary,
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
          content: SizedBox(
            width: 820,
            height: isMobile ? (screenSize.height * 0.66).clamp(320.0, 520.0) : 520,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. Storage Mount Switcher Strip
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final m in mounts)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(m.name),
                            selected: activeMount?.id == m.id,
                            onSelected: (_) => _selectMount(m),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // 2. Breadcrumb + "Select Current Folder" + "Save to Favorites" Bar
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: VideoPlatformTheme.bgCard,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: VideoPlatformTheme.borderSubtle),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          if (_breadcrumbs.length >= 2)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: OutlinedButton.icon(
                                onPressed: _stepBackFolderIfPossible,
                                icon: const Icon(
                                  Icons.arrow_back_rounded,
                                  size: 14,
                                ),
                                label: const Text(
                                  '返回上级',
                                  style: TextStyle(fontSize: 11.5),
                                ),
                              ),
                            ),
                          Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  for (int i = 0; i < _breadcrumbs.length; i++) ...[
                                    if (i > 0)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4,
                                        ),
                                        child: Icon(
                                          Icons.chevron_right_rounded,
                                          size: 15,
                                          color: VideoPlatformTheme.textMuted,
                                        ),
                                      ),
                                    InkWell(
                                      onTap: () => _loadDir(
                                        _breadcrumbs[i].path,
                                        title: _breadcrumbs[i].title,
                                      ),
                                      child: Text(
                                        _breadcrumbs[i].title,
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          fontWeight: i == _breadcrumbs.length - 1
                                              ? FontWeight.w700
                                              : FontWeight.w400,
                                          color: i == _breadcrumbs.length - 1
                                              ? VideoPlatformTheme.accent
                                              : VideoPlatformTheme.textSecondary,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          if (!isMobile && activeMount != null) ...[
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              onPressed: () {
                                final item = _currentDirectoryAsItem();
                                _ctrl.addOrToggleSavedMusicFolder(item);
                                setState(() {});
                              },
                              icon: Icon(
                                _ctrl.isMusicFolderSaved(
                                  activeMount.id,
                                  _currentPath,
                                )
                                    ? Icons.star_rounded
                                    : Icons.star_border_rounded,
                                size: 15,
                                color: VideoPlatformTheme.warning,
                              ),
                              label: Text(
                                _ctrl.isMusicFolderSaved(
                                  activeMount.id,
                                  _currentPath,
                                )
                                    ? '已存常用'
                                    : '存为常用目录',
                                style: const TextStyle(fontSize: 11.5),
                              ),
                            ),
                            const SizedBox(width: 6),
                            FilledButton.tonalIcon(
                              style: FilledButton.styleFrom(
                                backgroundColor:
                                    _isSelected(activeMount.id, _currentPath)
                                        ? VideoPlatformTheme.accent
                                            .withValues(alpha: 0.25)
                                        : null,
                              ),
                              onPressed: () =>
                                  _toggleSelection(_currentDirectoryAsItem()),
                              icon: Icon(
                                _isSelected(activeMount.id, _currentPath)
                                    ? Icons.check_box_rounded
                                    : Icons.add_box_outlined,
                                size: 15,
                              ),
                              label: Text(
                                _isSelected(activeMount.id, _currentPath)
                                    ? '已选当前目录'
                                    : '勾选当前目录 ($audioInCurrentDir首 / $archivesInCurrentDir包)',
                                style: const TextStyle(fontSize: 11.5),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (isMobile && activeMount != null) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () {
                                final item = _currentDirectoryAsItem();
                                _ctrl.addOrToggleSavedMusicFolder(item);
                                setState(() {});
                              },
                              icon: Icon(
                                _ctrl.isMusicFolderSaved(
                                  activeMount.id,
                                  _currentPath,
                                )
                                    ? Icons.star_rounded
                                    : Icons.star_border_rounded,
                                size: 14,
                                color: VideoPlatformTheme.warning,
                              ),
                              label: Text(
                                _ctrl.isMusicFolderSaved(
                                  activeMount.id,
                                  _currentPath,
                                )
                                    ? '已存常用'
                                    : '存为常用',
                                style: const TextStyle(fontSize: 11.5),
                              ),
                            ),
                            FilledButton.tonalIcon(
                              style: FilledButton.styleFrom(
                                backgroundColor:
                                    _isSelected(activeMount.id, _currentPath)
                                        ? VideoPlatformTheme.accent
                                            .withValues(alpha: 0.25)
                                        : null,
                              ),
                              onPressed: () =>
                                  _toggleSelection(_currentDirectoryAsItem()),
                              icon: Icon(
                                _isSelected(activeMount.id, _currentPath)
                                    ? Icons.check_box_rounded
                                    : Icons.add_box_outlined,
                                size: 14,
                              ),
                              label: Text(
                                _isSelected(activeMount.id, _currentPath)
                                    ? '已选当前目录'
                                    : '勾选当前目录 ($audioInCurrentDir首/$archivesInCurrentDir包)',
                                style: const TextStyle(fontSize: 11.5),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // 3. Directory & Archive Browser List
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: VideoPlatformTheme.bgCard,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: VideoPlatformTheme.borderSubtle),
                    ),
                    child: _isLoading
                        ? Center(
                            child: CircularProgressIndicator(
                              color: VideoPlatformTheme.accent,
                            ),
                          )
                        : (_error != null
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(
                                    '加载目录失败：$_error',
                                    style: TextStyle(
                                      color: VideoPlatformTheme.danger,
                                    ),
                                  ),
                                ),
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.all(6),
                                itemCount: _entries.length,
                                separatorBuilder: (_, __) => Divider(
                                  height: 1,
                                  color: VideoPlatformTheme.borderSubtle,
                                ),
                                itemBuilder: (context, idx) {
                                  final e = _entries[idx];
                                  final isSelectable = e.isDir ||
                                      e.isStreamableMusicArchive ||
                                      e.isAudio;
                                  final checked = activeMount != null &&
                                      _isSelected(activeMount.id, e.path);

                                  return ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                      horizontal: isMobile ? 8 : 12,
                                    ),
                                    leading: Icon(
                                      e.isDir
                                          ? Icons.folder_rounded
                                          : (e.isStreamableMusicArchive
                                              ? Icons.folder_zip_rounded
                                              : (e.isAudio
                                                  ? Icons.audiotrack_rounded
                                                  : Icons
                                                      .insert_drive_file_outlined)),
                                      color: e.isDir
                                          ? VideoPlatformTheme.warning
                                          : (e.isStreamableMusicArchive
                                              ? VideoPlatformTheme.badgeHot
                                              : (e.isAudio
                                                  ? VideoPlatformTheme.accent
                                                  : VideoPlatformTheme
                                                      .textMuted)),
                                    ),
                                    title: Text(
                                      e.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: VideoPlatformTheme.textPrimary,
                                      ),
                                    ),
                                    subtitle: Text(
                                      e.isDir
                                          ? '文件夹 · 点击进入，右侧可勾选随机播放'
                                          : (e.isStreamableMusicArchive
                                              ? '压缩包 (${e.formattedSize}) · 免整包下载直读音乐'
                                              : '${e.typeTagText} · ${e.formattedSize}'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: VideoPlatformTheme.textMuted,
                                      ),
                                    ),
                                    onTap: () {
                                      if (e.isDir) {
                                        _loadDir(e.path, title: e.name);
                                      } else if (isSelectable &&
                                          activeMount != null) {
                                        _toggleSelection(
                                          SavedMusicFolderItem(
                                            mountId: activeMount.id,
                                            mountName: activeMount.name,
                                            sourceKind: activeMount.kind,
                                            path: e.path,
                                            title: e.name,
                                            isArchive:
                                                e.isStreamableMusicArchive,
                                            size: e.size,
                                            pickcode115: e.pickcode115,
                                          ),
                                        );
                                      }
                                    },
                                    trailing: (isSelectable &&
                                            activeMount != null)
                                        ? Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (e.isDir ||
                                                  e.isStreamableMusicArchive)
                                                IconButton(
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  tooltip: '加入常用音乐源',
                                                  onPressed: () {
                                                    _ctrl
                                                        .addOrToggleSavedMusicFolder(
                                                      SavedMusicFolderItem(
                                                        mountId: activeMount.id,
                                                        mountName:
                                                            activeMount.name,
                                                        sourceKind:
                                                            activeMount.kind,
                                                        path: e.path,
                                                        title: e.name,
                                                        isArchive: e
                                                            .isStreamableMusicArchive,
                                                        size: e.size,
                                                        pickcode115:
                                                            e.pickcode115,
                                                      ),
                                                    );
                                                    setState(() {});
                                                  },
                                                  icon: Icon(
                                                    _ctrl.isMusicFolderSaved(
                                                      activeMount.id,
                                                      e.path,
                                                    )
                                                        ? Icons.star_rounded
                                                        : Icons
                                                            .star_border_rounded,
                                                    size: 18,
                                                    color: VideoPlatformTheme
                                                        .warning,
                                                  ),
                                                ),
                                              Checkbox(
                                                visualDensity:
                                                    VisualDensity.compact,
                                                value: checked,
                                                activeColor:
                                                    VideoPlatformTheme.accent,
                                                onChanged: (_) {
                                                  _toggleSelection(
                                                    SavedMusicFolderItem(
                                                      mountId: activeMount.id,
                                                      mountName:
                                                          activeMount.name,
                                                      sourceKind:
                                                          activeMount.kind,
                                                      path: e.path,
                                                      title: e.name,
                                                      isArchive: e
                                                          .isStreamableMusicArchive,
                                                      size: e.size,
                                                      pickcode115:
                                                          e.pickcode115,
                                                    ),
                                                  );
                                                },
                                              ),
                                            ],
                                          )
                                        : null,
                                  );
                                },
                              )),
                  ),
                ),
                const SizedBox(height: 6),
                // 4. Selected Folders / Archives Summary + Recursive Checkbox
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  alignment: WrapAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 28,
                          height: 28,
                          child: Checkbox(
                            visualDensity: VisualDensity.compact,
                            value: _includeSubfolders,
                            activeColor: VideoPlatformTheme.accent,
                            onChanged: (v) =>
                                setState(() => _includeSubfolders = v ?? true),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            isMobile
                                ? '递归扫描子目录与压缩包'
                                : '自动递归扫描子目录与内部 .zip / .tar 音乐压缩包',
                            style: TextStyle(
                              fontSize: 12,
                              color: VideoPlatformTheme.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Text(
                      _selectedItems.isEmpty
                          ? (isMobile
                              ? '默认扫描当前打开目录'
                              : '未勾选特定项（默认将扫描当前打开的目录）')
                          : '已选 ${_selectedItems.length} 个目录/压缩包',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: VideoPlatformTheme.accent,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            if (_breadcrumbs.length >= 2)
              TextButton.icon(
                onPressed: _stepBackFolderIfPossible,
                icon: const Icon(Icons.arrow_back_rounded, size: 15),
                label: Text(isMobile ? '上级' : '返回上级目录'),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(isMobile ? '关闭' : '关闭窗口'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final targets = _selectedItems.isNotEmpty
                    ? List<SavedMusicFolderItem>.from(_selectedItems)
                    : (_activeMount != null
                        ? [_currentDirectoryAsItem()]
                        : const <SavedMusicFolderItem>[]);
                if (targets.isEmpty) return;
                Navigator.of(context).pop();
                await _ctrl.scanAndPlayFoldersOrArchives(
                  sources: targets,
                  shuffle: false,
                  includeSubfolders: _includeSubfolders,
                );
              },
              icon: const Icon(Icons.play_arrow_rounded, size: 16),
              label: Text(isMobile ? '顺序播放' : '顺序播放所选'),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: VideoPlatformTheme.accent,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                final targets = _selectedItems.isNotEmpty
                    ? List<SavedMusicFolderItem>.from(_selectedItems)
                    : (_activeMount != null
                        ? [_currentDirectoryAsItem()]
                        : const <SavedMusicFolderItem>[]);
                if (targets.isEmpty) return;
                Navigator.of(context).pop();
                await _ctrl.scanAndPlayFoldersOrArchives(
                  sources: targets,
                  shuffle: true,
                  includeSubfolders: _includeSubfolders,
                );
              },
              icon: const Icon(Icons.shuffle_rounded, size: 16),
              label: Text(
                _selectedItems.isEmpty
                    ? (isMobile ? '随机播放当前目录' : '随机播放当前目录全部音乐')
                    : '随机播放 (${_selectedItems.length})',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// 2. Archive (.zip / .cbz / .tar) Inner Music Browser Dialog (压缩包音乐浏览器)
// =============================================================================

class CloudArchiveMusicBrowserDialog extends StatefulWidget {
  final FileEntry archiveEntry;
  final CloudMusicController controller;
  final VoidCallback? onOpenFullscreenHall;

  const CloudArchiveMusicBrowserDialog({
    super.key,
    required this.archiveEntry,
    required this.controller,
    this.onOpenFullscreenHall,
  });

  @override
  State<CloudArchiveMusicBrowserDialog> createState() =>
      _CloudArchiveMusicBrowserDialogState();
}

class _CloudArchiveMusicBrowserDialogState
    extends State<CloudArchiveMusicBrowserDialog> {
  List<FileEntry> _allEntries = const [];
  List<FileEntry> _audioEntries = const [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _inspectArchive();
  }

  Future<void> _inspectArchive() async {
    try {
      final list = await CloudArchiveMusicService.instance.inspectArchiveEntries(
        archiveEntry: widget.archiveEntry,
        endpointResolver: widget.controller.resolveEntryEndpoint,
      );
      if (!mounted) return;
      setState(() {
        _allEntries = list;
        _audioEntries = list.where((e) => e.isAudio).toList();
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: VideoPlatformTheme.bgElevated,
      title: Row(
        children: [
          const Icon(
            Icons.folder_zip_rounded,
            color: Color(0xFFF97316),
            size: 22,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '压缩包音乐直读：${widget.archiveEntry.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800),
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
      content: SizedBox(
        width: 680,
        height: 440,
        child: _isLoading
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: VideoPlatformTheme.accent),
                    const SizedBox(height: 12),
                    Text(
                      '正在通过 HTTP Range 读取压缩包中央目录...',
                      style: TextStyle(color: VideoPlatformTheme.textSecondary),
                    ),
                  ],
                ),
              )
            : (_error != null
                ? Center(
                    child: Text(
                      '解析压缩包失败：$_error',
                      style: TextStyle(color: VideoPlatformTheme.danger),
                    ),
                  )
                : (_audioEntries.isEmpty
                    ? Center(
                        child: Text(
                          '该压缩包内未发现可播放的音频文件 (.flac / .ape / .wav / .mp3 / .m4a 等)',
                          style: TextStyle(color: VideoPlatformTheme.textSecondary),
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: VideoPlatformTheme.accent
                                  .withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.bolt_rounded,
                                  color: VideoPlatformTheme.accent,
                                  size: 18,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    '共发现 ${_audioEntries.length} 首音乐（总计 ${_allEntries.length} 个文件）· 免下载整包，点击任意曲目即按需分片解压播放',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: VideoPlatformTheme.accent,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: ListView.separated(
                              itemCount: _audioEntries.length,
                              separatorBuilder: (_, __) => Divider(
                                height: 1,
                                color: VideoPlatformTheme.borderSubtle,
                              ),
                              itemBuilder: (context, idx) {
                                final track = _audioEntries[idx];
                                final meta =
                                    CloudMusicController.parseTrackMetadata(
                                  track,
                                  fallbackArtist: widget.archiveEntry.name,
                                );
                                return ListTile(
                                  dense: true,
                                  leading: CircleAvatar(
                                    radius: 14,
                                    backgroundColor: VideoPlatformTheme.accent
                                        .withValues(alpha: 0.2),
                                    child: Text(
                                      '${idx + 1}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: VideoPlatformTheme.accent,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  title: Text(
                                    meta.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                      color: VideoPlatformTheme.textPrimary,
                                    ),
                                  ),
                                  subtitle: Text(
                                    '${track.archiveInnerPath} · ${track.formattedSize}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: VideoPlatformTheme.textMuted,
                                    ),
                                  ),
                                  trailing: Icon(
                                    Icons.play_circle_fill_rounded,
                                    color: VideoPlatformTheme.accent,
                                    size: 22,
                                  ),
                                  onTap: () async {
                                    Navigator.of(context).pop();
                                    widget.controller.registerDirectoryContext(
                                      mounts: widget.controller.availableMounts,
                                      directoryEntries: _allEntries,
                                    );
                                    await widget.controller.playFromDirectory(
                                      targetTrack: track,
                                      directoryEntries: _allEntries,
                                      mounts: widget.controller.availableMounts,
                                    );
                                    widget.onOpenFullscreenHall?.call();
                                  },
                                );
                              },
                            ),
                          ),
                        ],
                      ))),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        if (_audioEntries.isNotEmpty) ...[
          OutlinedButton.icon(
            onPressed: () async {
              Navigator.of(context).pop();
              widget.controller.registerDirectoryContext(
                mounts: widget.controller.availableMounts,
                directoryEntries: _allEntries,
              );
              await widget.controller.playFromDirectory(
                targetTrack: _audioEntries.first,
                directoryEntries: _allEntries,
                mounts: widget.controller.availableMounts,
                shuffle: false,
              );
              widget.onOpenFullscreenHall?.call();
            },
            icon: const Icon(Icons.play_arrow_rounded, size: 17),
            label: Text('顺序播放 (${_audioEntries.length})'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: VideoPlatformTheme.accent,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              Navigator.of(context).pop();
              widget.controller.registerDirectoryContext(
                mounts: widget.controller.availableMounts,
                directoryEntries: _allEntries,
              );
              await widget.controller.playFromDirectory(
                targetTrack: _audioEntries.first,
                directoryEntries: _allEntries,
                mounts: widget.controller.availableMounts,
                shuffle: true,
              );
              widget.onOpenFullscreenHall?.call();
            },
            icon: const Icon(Icons.shuffle_rounded, size: 17),
            label: Text('随机播放压缩包 (${_audioEntries.length})'),
          ),
        ],
      ],
    );
  }
}

// =============================================================================
// 3. Standalone Music Player Screen (音乐可以单独启动 - Tab 9 in MainShell)
// =============================================================================

class CloudMusicStandaloneScreen extends StatelessWidget {
  final AppState appState;

  const CloudMusicStandaloneScreen({
    super.key,
    required this.appState,
  });

  @override
  Widget build(BuildContext context) {
    final controller = CloudMusicController(appState: appState);
    return CloudMusicHallBody(
      controller: controller,
      isStandalonePage: true,
    );
  }
}

// =============================================================================
// 4. Persistent Bottom Music Dock Bar (边听边逛115/AList目录)
// =============================================================================

class CloudMusicBottomDockBar extends StatelessWidget {
  final CloudMusicController controller;
  final VoidCallback onExpandFullscreen;

  const CloudMusicBottomDockBar({
    super.key,
    required this.controller,
    required this.onExpandFullscreen,
  });

  static String formatDuration(Duration d) {
    final totalSeconds = d.inSeconds.clamp(0, 359999);
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  static IconData playModeIcon(String mode) {
    switch (mode) {
      case 'repeatOne':
        return Icons.repeat_one_rounded;
      case 'shuffle':
        return Icons.shuffle_rounded;
      case 'sequential':
        return Icons.playlist_play_rounded;
      case 'repeatAll':
      default:
        return Icons.repeat_rounded;
    }
  }

  static String playModeLabel(String mode) {
    switch (mode) {
      case 'repeatOne':
        return '单曲循环';
      case 'shuffle':
        return '随机播放';
      case 'sequential':
        return '顺序播放';
      case 'repeatAll':
      default:
        return '列表循环';
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final track = controller.currentTrack;
        if (track == null && !controller.isScanningFolders) {
          return const SizedBox.shrink();
        }

        if (track == null && controller.isScanningFolders) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: VideoPlatformTheme.bgElevated,
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: VideoPlatformTheme.accent,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    controller.scanningStatusText,
                    style: TextStyle(
                      fontSize: 13,
                      color: VideoPlatformTheme.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        final activeTrack = track!;
        final meta = CloudMusicController.parseTrackMetadata(
          activeTrack,
          fallbackArtist: controller.mountNameFor(activeTrack),
        );
        final durMs = controller.duration.inMilliseconds > 0
            ? controller.duration.inMilliseconds
            : 1;
        final posMs = controller.position.inMilliseconds.clamp(0, durMs);
        final progress = (posMs / durMs).clamp(0.0, 1.0);
        final lyricLine = controller.currentLyricLineText;

        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                VideoPlatformTheme.bgElevated,
                VideoPlatformTheme.bgCard,
                VideoPlatformTheme.bgElevated,
              ],
            ),
            border: Border(
              top: BorderSide(
                color: VideoPlatformTheme.accent.withValues(alpha: 0.45),
                width: 1.2,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: VideoPlatformTheme.isDark ? 0.45 : 0.12,
                ),
                blurRadius: 18,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 14,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2.5,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 5.5,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 10,
                    ),
                    activeTrackColor: VideoPlatformTheme.accent,
                    inactiveTrackColor: VideoPlatformTheme.borderStrong,
                    thumbColor: VideoPlatformTheme.accentHover,
                  ),
                  child: Slider(
                    value: progress,
                    onChanged: (v) {
                      if (controller.duration > Duration.zero) {
                        controller.seekTo(
                          Duration(
                            milliseconds:
                                (v * controller.duration.inMilliseconds).round(),
                          ),
                        );
                      }
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 10, 8),
                child: Builder(
                  builder: (context) {
                    final screenW = MediaQuery.sizeOf(context).width;
                    final isCompact = screenW < 720;
                    return Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: onExpandFullscreen,
                            borderRadius: BorderRadius.circular(10),
                            child: Row(
                              children: [
                                _MiniSpinningVinylAvatar(
                                  isPlaying: controller.isPlaying,
                                  coverUrl: controller.coverImageUrl,
                                  coverHeaders: controller.coverImageHeaders,
                                  isLocalFile: controller.coverIsLocalFile,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 5,
                                              vertical: 1.5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: VideoPlatformTheme.accent
                                                  .withValues(alpha: 0.18),
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                              border: Border.all(
                                                color: VideoPlatformTheme.accent
                                                    .withValues(alpha: 0.5),
                                              ),
                                            ),
                                            child: Text(
                                              meta.qualityTag,
                                              style: TextStyle(
                                                fontSize: 9.5,
                                                fontWeight: FontWeight.w800,
                                                color:
                                                    VideoPlatformTheme.accent,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              meta.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w700,
                                                color: VideoPlatformTheme
                                                    .textPrimary,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        controller.errorText.isNotEmpty
                                            ? controller.errorText
                                            : (lyricLine.isNotEmpty
                                                ? '♪ $lyricLine'
                                                : '${meta.artist} · ${controller.mountNameFor(activeTrack)}'),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: controller.errorText.isNotEmpty
                                              ? VideoPlatformTheme.danger
                                              : (lyricLine.isNotEmpty
                                                  ? VideoPlatformTheme.accent
                                                  : VideoPlatformTheme
                                                      .textSecondary),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        if (!isCompact) ...[
                          IconButton(
                            tooltip:
                                '播放模式：${playModeLabel(controller.playMode)}',
                            visualDensity: VisualDensity.compact,
                            onPressed: controller.cyclePlayMode,
                            icon: Icon(
                              playModeIcon(controller.playMode),
                              size: 19,
                              color: VideoPlatformTheme.accent,
                            ),
                          ),
                          IconButton(
                            tooltip: '上一首',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => controller.stepTrack(-1),
                            icon: Icon(
                              Icons.skip_previous_rounded,
                              size: 24,
                              color: VideoPlatformTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(width: 4),
                        ],
                        InkWell(
                          onTap: controller.togglePlayPause,
                          customBorder: const CircleBorder(),
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                colors: [
                                  VideoPlatformTheme.accent,
                                  VideoPlatformTheme.accentHover,
                                ],
                              ),
                            ),
                            child: controller.isLoadingTrack
                                ? const Padding(
                                    padding: EdgeInsets.all(9),
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Icon(
                                    controller.isPlaying
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                    color: Colors.white,
                                    size: 20,
                                  ),
                          ),
                        ),
                        const SizedBox(width: 2),
                        IconButton(
                          tooltip: '下一首',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => controller.stepTrack(1),
                          icon: Icon(
                            Icons.skip_next_rounded,
                            size: 23,
                            color: VideoPlatformTheme.textPrimary,
                          ),
                        ),
                        if (screenW > 860) ...[
                          const SizedBox(width: 8),
                          if (controller.player != null) ...[
                            VideoDownloadSpeedBadge(
                              player: controller.player!,
                              compact: true,
                            ),
                            const SizedBox(width: 10),
                          ],
                          Text(
                            '${formatDuration(controller.position)} / ${formatDuration(controller.duration)}',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                              color: VideoPlatformTheme.textSecondary,
                            ),
                          ),
                          const SizedBox(width: 8),
                          InkWell(
                            onTap: controller.cycleSpeed,
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: VideoPlatformTheme.bgHover,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '${controller.speed}x',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: VideoPlatformTheme.textPrimary,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        FilledButton.tonalIcon(
                          style: FilledButton.styleFrom(
                            backgroundColor: VideoPlatformTheme.accent
                                .withValues(alpha: 0.18),
                            foregroundColor: VideoPlatformTheme.accent,
                          ),
                          onPressed: onExpandFullscreen,
                          icon: const Icon(Icons.lyrics_rounded, size: 15),
                          label: Text(
                            isCompact
                                ? '${controller.currentIndex + 1}/${controller.queue.length}'
                                : '黑胶歌词厅 (${controller.currentIndex + 1}/${controller.queue.length})',
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '停止并关闭音乐播放器',
                          visualDensity: VisualDensity.compact,
                          onPressed: controller.stopAndClose,
                          icon: Icon(
                            Icons.close_rounded,
                            size: 18,
                            color: VideoPlatformTheme.textMuted,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MiniSpinningVinylAvatar extends StatefulWidget {
  final bool isPlaying;
  final String? coverUrl;
  final Map<String, String> coverHeaders;
  final bool isLocalFile;

  const _MiniSpinningVinylAvatar({
    required this.isPlaying,
    this.coverUrl,
    this.coverHeaders = const {},
    this.isLocalFile = false,
  });

  @override
  State<_MiniSpinningVinylAvatar> createState() =>
      _MiniSpinningVinylAvatarState();
}

class _MiniSpinningVinylAvatarState extends State<_MiniSpinningVinylAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotCtrl;

  @override
  void initState() {
    super.initState();
    _rotCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    );
    if (widget.isPlaying) _rotCtrl.repeat();
  }

  @override
  void didUpdateWidget(covariant _MiniSpinningVinylAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying && !_rotCtrl.isAnimating) {
      _rotCtrl.repeat();
    } else if (!widget.isPlaying && _rotCtrl.isAnimating) {
      _rotCtrl.stop();
    }
  }

  @override
  void dispose() {
    _rotCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _rotCtrl,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const RadialGradient(
            colors: [
              Color(0xFF27272A),
              Color(0xFF09090B),
              Color(0xFF18181B),
            ],
          ),
          border: Border.all(
            color: VideoPlatformTheme.accent.withValues(alpha: 0.6),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: VideoPlatformTheme.accent.withValues(alpha: 0.25),
              blurRadius: 8,
            ),
          ],
        ),
        child: Center(
          child: ClipOval(
            child: SizedBox(
              width: 26,
              height: 26,
              child: _buildCoverImage(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCoverImage() {
    final url = widget.coverUrl;
    if (url != null && url.isNotEmpty) {
      if (widget.isLocalFile) {
        return Image.file(
          File(url),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _fallbackIcon(),
        );
      }
      return Image.network(
        url,
        headers: widget.coverHeaders.isEmpty ? null : widget.coverHeaders,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _fallbackIcon(),
      );
    }
    return _fallbackIcon();
  }

  Widget _fallbackIcon() {
    return Container(
      color: VideoPlatformTheme.accent,
      child: const Icon(
        Icons.music_note_rounded,
        size: 15,
        color: Colors.white,
      ),
    );
  }
}

// =============================================================================
// 5. Fullscreen Modal & Standalone Hi-Fi Vinyl & Synchronized Lyrics Music Hall
// =============================================================================

class CloudMusicFullscreenModal extends StatelessWidget {
  final CloudMusicController controller;

  const CloudMusicFullscreenModal({
    super.key,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < 720;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.symmetric(
        horizontal: isMobile ? 8 : 20,
        vertical: isMobile ? 10 : 16,
      ),
      child: Container(
        width: 1140,
        height: 730,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(isMobile ? 16 : 20),
          border: Border.all(
            color: VideoPlatformTheme.accent.withValues(alpha: 0.38),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.65),
              blurRadius: 36,
              offset: const Offset(0, 16),
            ),
          ],
        ),
        child: CloudMusicHallBody(
          controller: controller,
          isStandalonePage: false,
        ),
      ),
    );
  }
}

class CloudMusicHallBody extends StatefulWidget {
  final CloudMusicController controller;
  final bool isStandalonePage;

  const CloudMusicHallBody({
    super.key,
    required this.controller,
    this.isStandalonePage = false,
  });

  @override
  State<CloudMusicHallBody> createState() => _CloudMusicHallBodyState();
}

class _CloudMusicHallBodyState extends State<CloudMusicHallBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _vinylController;
  final ScrollController _lyricsScrollController = ScrollController();
  final TextEditingController _queueFilterCtrl = TextEditingController();
  final FocusNode _keyboardFocusNode = FocusNode();

  int _rightTabIndex = 0; // Desktop right pane: 0 = 实时同步歌词, 1 = 播放队列
  int _mobileViewIndex = 0; // Mobile 3-pane switcher: 0 = 黑胶唱盘, 1 = 同步歌词, 2 = 播放队列
  String _queueSearch = '';
  int _lastScrolledLyricIndex = -1;

  CloudMusicController get _ctrl => widget.controller;

  @override
  void initState() {
    super.initState();
    _vinylController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    );
    if (_ctrl.isPlaying) {
      _vinylController.repeat();
    }
    _ctrl.addListener(_onControllerUpdated);
  }

  void _onControllerUpdated() {
    if (!mounted) return;
    if (_ctrl.isPlaying && !_vinylController.isAnimating) {
      _vinylController.repeat();
    } else if (!_ctrl.isPlaying && _vinylController.isAnimating) {
      _vinylController.stop();
    }

    final lyricIdx = _ctrl.activeLyricIndex;
    if (lyricIdx != _lastScrolledLyricIndex &&
        lyricIdx >= 0 &&
        _lyricsScrollController.hasClients) {
      _lastScrolledLyricIndex = lyricIdx;
      final targetOffset = (lyricIdx * 48.0 - 140.0).clamp(
        0.0,
        _lyricsScrollController.position.maxScrollExtent,
      );
      _lyricsScrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onControllerUpdated);
    _vinylController.dispose();
    _lyricsScrollController.dispose();
    _queueFilterCtrl.dispose();
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  Future<void> _openFolderAndArchivePicker() async {
    await showDialog<void>(
      context: context,
      builder: (_) => CloudMusicFolderPickerDialog(controller: _ctrl),
    );
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      _ctrl.togglePlayPause();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _ctrl.seekRelative(const Duration(seconds: -5));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _ctrl.seekRelative(const Duration(seconds: 5));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.bracketLeft ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      _ctrl.stepTrack(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.bracketRight ||
        key == LogicalKeyboardKey.mediaTrackNext) {
      _ctrl.stepTrack(1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _keyboardFocusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: ListenableBuilder(
        listenable: _ctrl,
        builder: (context, _) {
          final track = _ctrl.currentTrack;
          final meta = track != null
              ? CloudMusicController.parseTrackMetadata(
                  track,
                  fallbackArtist: _ctrl.mountNameFor(track),
                )
              : (
                  title: '流光 Hi-Fi 云端音乐播放器',
                  artist: '支持 115 · AList · WebDAV · 压缩包直读',
                  qualityTag: 'Hi-Fi',
                );
          final durMs = _ctrl.duration.inMilliseconds > 0
              ? _ctrl.duration.inMilliseconds
              : 1;
          final posMs = _ctrl.position.inMilliseconds.clamp(0, durMs);
          final progress = (posMs / durMs).clamp(0.0, 1.0);
          final screenW = MediaQuery.sizeOf(context).width;
          final isWide = screenW >= 820;

          return Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  VideoPlatformTheme.bgPrimary,
                  VideoPlatformTheme.bgElevated,
                  VideoPlatformTheme.bgCard,
                ],
              ),
            ),
            child: Column(
              children: [
                _buildHeaderBar(track, meta, isWide: isWide),
                if (_ctrl.savedMusicFolders.isNotEmpty)
                  _buildSavedMusicFoldersStrip(isWide: isWide),
                if (!isWide && track != null && !_ctrl.isScanningFolders)
                  _buildMobileThreePaneSwitcherBar(),
                Divider(height: 1, color: VideoPlatformTheme.borderSubtle),
                Expanded(
                  child: _ctrl.isScanningFolders
                      ? _buildScanningStatusBody()
                      : (track == null
                          ? _buildEmptyStandaloneLauncherBody(isWide: isWide)
                          : (isWide
                              ? Row(
                                  children: [
                                    Expanded(
                                      flex: 5,
                                      child: _buildVinylTurntablePane(
                                        track,
                                        meta,
                                      ),
                                    ),
                                    Container(
                                      width: 1,
                                      color: VideoPlatformTheme.borderSubtle,
                                    ),
                                    Expanded(
                                      flex: 6,
                                      child: _buildRightLyricsAndQueuePane(
                                        track,
                                      ),
                                    ),
                                  ],
                                )
                              : _buildMobileActivePaneBody(track, meta))),
                ),
                Divider(height: 1, color: VideoPlatformTheme.borderSubtle),
                _buildBottomControlDeck(progress, isWide: isWide),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildMobileThreePaneSwitcherBar() {
    final items = [
      (0, Icons.album_rounded, '黑胶封面'),
      (1, Icons.lyrics_rounded, '同步歌词'),
      (2, Icons.queue_music_rounded, '播放队列 (${_ctrl.queue.length})'),
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: VideoPlatformTheme.bgElevated,
      child: Row(
        children: [
          for (int i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => setState(() => _mobileViewIndex = items[i].$1),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: _mobileViewIndex == items[i].$1
                        ? VideoPlatformTheme.accent.withValues(alpha: 0.2)
                        : VideoPlatformTheme.bgCard,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _mobileViewIndex == items[i].$1
                          ? VideoPlatformTheme.accent
                          : VideoPlatformTheme.borderSubtle,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        items[i].$2,
                        size: 14,
                        color: _mobileViewIndex == items[i].$1
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          items[i].$3,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: _mobileViewIndex == items[i].$1
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: _mobileViewIndex == items[i].$1
                                ? VideoPlatformTheme.accent
                                : VideoPlatformTheme.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMobileActivePaneBody(
    FileEntry track,
    ({String title, String artist, String qualityTag}) meta,
  ) {
    if (_mobileViewIndex == 1) {
      return _buildSynchronizedLyricsView();
    }
    if (_mobileViewIndex == 2) {
      return _buildPlaylistQueueView(track);
    }

    // Mobile View 0: Full-height responsive Vinyl Turntable + Live 2-Line Lyrics Card
    return LayoutBuilder(
      builder: (context, constraints) {
        final availH = constraints.maxHeight;
        final discSize = (availH * 0.44).clamp(120.0, 210.0);
        final activeLyricIdx = _ctrl.activeLyricIndex;
        final currentLyric = _ctrl.currentLyricLineText;
        final nextLyric = (activeLyricIdx >= 0 &&
                activeLyricIdx + 1 < _ctrl.lyrics.length)
            ? _ctrl.lyrics[activeLyricIdx + 1].text
            : '';

        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: math.max(0.0, availH - 20),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                GestureDetector(
                  onTap: () => setState(() => _mobileViewIndex = 1),
                  child: SizedBox(
                    width: discSize + 24,
                    height: discSize + 12,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 500),
                          width: discSize + 8,
                          height: discSize + 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: VideoPlatformTheme.accent.withValues(
                                  alpha: _ctrl.isPlaying ? 0.25 : 0.08,
                                ),
                                blurRadius: 28,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                        ),
                        RotationTransition(
                          turns: _vinylController,
                          child: Container(
                            width: discSize,
                            height: discSize,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: const SweepGradient(
                                colors: [
                                  Color(0xFF111318),
                                  Color(0xFF282C37),
                                  Color(0xFF111318),
                                  Color(0xFF282C37),
                                  Color(0xFF111318),
                                ],
                              ),
                              border: Border.all(
                                color: VideoPlatformTheme.accent
                                    .withValues(alpha: 0.45),
                                width: 2.5,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.5),
                                  blurRadius: 16,
                                ),
                              ],
                            ),
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                for (final factor in const [0.88, 0.76, 0.64])
                                  Container(
                                    width: discSize * factor,
                                    height: discSize * factor,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color:
                                            Colors.white.withValues(alpha: 0.06),
                                        width: 1,
                                      ),
                                    ),
                                  ),
                                Container(
                                  width: discSize * 0.48,
                                  height: discSize * 0.48,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: VideoPlatformTheme.accent
                                          .withValues(alpha: 0.75),
                                      width: 2,
                                    ),
                                  ),
                                  child: ClipOval(
                                    child: _buildAlbumCoverWidget(),
                                  ),
                                ),
                                Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: VideoPlatformTheme.bgPrimary,
                                    border: Border.all(
                                      color: Colors.white38,
                                      width: 1.5,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  meta.title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: VideoPlatformTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${meta.artist} · ${_ctrl.mountNameFor(track)} · ${track.formattedSize}',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: VideoPlatformTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 10),
                _AnimatedAudioSpectrumBars(
                  isPlaying: _ctrl.isPlaying,
                  positionMs: _ctrl.position.inMilliseconds,
                ),
                const SizedBox(height: 12),
                // Live 2-line synchronized lyrics card (tap to open full-screen lyrics)
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => setState(() => _mobileViewIndex = 1),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: VideoPlatformTheme.bgCard.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: VideoPlatformTheme.borderSubtle),
                    ),
                    child: Column(
                      children: [
                        Text(
                          currentLyric.isNotEmpty
                              ? '♪ $currentLyric'
                              : (_ctrl.isLoadingLyrics
                                  ? '正在匹配同步歌词...'
                                  : '点击切换到全屏歌词 / 播放队列 ›'),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: currentLyric.isNotEmpty
                                ? VideoPlatformTheme.accent
                                : VideoPlatformTheme.textSecondary,
                          ),
                        ),
                        if (nextLyric.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            nextLyric,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: VideoPlatformTheme.textMuted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeaderBar(
    FileEntry? track,
    ({String title, String artist, String qualityTag}) meta, {
    required bool isWide,
  }) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        isWide ? 20 : 12,
        isWide ? 12 : 8,
        isWide ? 16 : 12,
        isWide ? 10 : 8,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            if (isWide) ...[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      VideoPlatformTheme.accent,
                      VideoPlatformTheme.accentHover,
                    ],
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.album_rounded, size: 16, color: Colors.white),
                    SizedBox(width: 6),
                    Text(
                      '流光 Hi-Fi 云端音乐厅',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
            ],
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: VideoPlatformTheme.accent,
                foregroundColor: Colors.white,
              ),
              onPressed: _openFolderAndArchivePicker,
              icon: const Icon(Icons.create_new_folder_rounded, size: 15),
              label: Text(
                isWide ? '自选文件夹 / 压缩包随机播放' : '自选目录/压缩包',
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
            if (_ctrl.queue.length > 1) ...[
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  backgroundColor:
                      VideoPlatformTheme.accent.withValues(alpha: 0.18),
                  foregroundColor: VideoPlatformTheme.accent,
                ),
                onPressed: _ctrl.shuffleCurrentQueue,
                icon: const Icon(Icons.shuffle_rounded, size: 15),
                label: Text(
                  isWide
                      ? '重新随机打乱 (${_ctrl.queue.length}首)'
                      : '随机打乱 (${_ctrl.queue.length})',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
            if (track != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: VideoPlatformTheme.bgCard,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: VideoPlatformTheme.borderSubtle),
                ),
                child: Text(
                  _ctrl.mountNameFor(track),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: VideoPlatformTheme.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: VideoPlatformTheme.warning.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: VideoPlatformTheme.warning.withValues(alpha: 0.45),
                  ),
                ),
                child: Text(
                  '${meta.qualityTag} · ${track.formattedSize}',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: VideoPlatformTheme.warning,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
            if (_ctrl.player != null && track != null && isWide) ...[
              const SizedBox(width: 12),
              VideoDownloadSpeedBadge(
                player: _ctrl.player!,
              ),
            ],
            if (!widget.isStandalonePage) ...[
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  backgroundColor: VideoPlatformTheme.bgCard,
                  foregroundColor: VideoPlatformTheme.textPrimary,
                ),
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 17),
                label: Text(
                  isWide ? '收起至底部 (边听边逛目录)' : '收起',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSavedMusicFoldersStrip({required bool isWide}) {
    final saved = _ctrl.savedMusicFolders;
    return Container(
      height: 40,
      padding: EdgeInsets.symmetric(horizontal: isWide ? 18 : 12),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgCard.withValues(alpha: 0.6),
        border: Border(
          top: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.star_rounded,
            size: 15,
            color: VideoPlatformTheme.warning,
          ),
          if (isWide) ...[
            const SizedBox(width: 6),
            Text(
              '常用音乐源:',
              style: TextStyle(
                fontSize: 11.5,
                color: VideoPlatformTheme.textSecondary,
              ),
            ),
          ],
          const SizedBox(width: 6),
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              _ctrl.scanAndPlayFoldersOrArchives(
                sources: saved,
                shuffle: true,
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: VideoPlatformTheme.accent.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: VideoPlatformTheme.accent.withValues(alpha: 0.5),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.shuffle_rounded,
                    size: 13,
                    color: VideoPlatformTheme.accent,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '全部随机 (${saved.length})',
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.2,
                      fontWeight: FontWeight.w700,
                      color: VideoPlatformTheme.accent,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: saved.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (context, idx) {
                final item = saved[idx];
                return Center(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => _ctrl.scanAndPlayFoldersOrArchives(
                      sources: [item],
                      shuffle: true,
                    ),
                    onLongPress: () => _ctrl.addOrToggleSavedMusicFolder(item),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: VideoPlatformTheme.bgCard,
                        borderRadius: BorderRadius.circular(14),
                        border:
                            Border.all(color: VideoPlatformTheme.borderSubtle),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            item.isArchive
                                ? Icons.folder_zip_rounded
                                : Icons.folder_special_rounded,
                            size: 13,
                            color: item.isArchive
                                ? VideoPlatformTheme.badgeHot
                                : VideoPlatformTheme.warning,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            '${item.mountName}: ${item.title}',
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.2,
                              color: VideoPlatformTheme.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScanningStatusBody() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 46,
              height: 46,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: VideoPlatformTheme.accent,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _ctrl.scanningStatusText.isNotEmpty
                  ? _ctrl.scanningStatusText
                  : '正在扫描音乐目录与压缩包...',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: VideoPlatformTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '支持递归读取 115 / AList / WebDAV 子文件夹及 .zip / .tar 压缩包内的无损音乐',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: VideoPlatformTheme.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyStandaloneLauncherBody({required bool isWide}) {
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(isWide ? 28 : 18),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: isWide ? 104 : 80,
                height: isWide ? 104 : 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      VideoPlatformTheme.accent,
                      VideoPlatformTheme.accent.withValues(alpha: 0.45),
                      VideoPlatformTheme.bgElevated,
                    ],
                  ),
                  border: Border.all(
                    color: VideoPlatformTheme.accentHover.withValues(alpha: 0.6),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: VideoPlatformTheme.accent.withValues(alpha: 0.28),
                      blurRadius: 24,
                    ),
                  ],
                ),
                child: Icon(
                  Icons.album_rounded,
                  size: isWide ? 52 : 40,
                  color: Colors.white,
                ),
              ),
              SizedBox(height: isWide ? 18 : 14),
              Text(
                '流光 Hi-Fi 云端音乐播放器',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: isWide ? 22 : 18,
                  fontWeight: FontWeight.w800,
                  color: VideoPlatformTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '支持 115 网盘直连 · AList / OpenList · WebDAV · 本机目录\n完整支持 APE / WAV / FLAC / ALAC / DSD / MP3 / M4A 等无损音频，支持直读 .zip / .tar 压缩包音乐与多目录随机播放',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: isWide ? 13.5 : 12.5,
                  height: 1.5,
                  color: VideoPlatformTheme.textSecondary,
                ),
              ),
              if (_ctrl.errorText.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _ctrl.errorText,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: VideoPlatformTheme.danger,
                  ),
                ),
              ],
              SizedBox(height: isWide ? 22 : 16),
              Wrap(
                spacing: 12,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: VideoPlatformTheme.accent,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(160, 40),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                    ),
                    onPressed: _openFolderAndArchivePicker,
                    icon: const Icon(Icons.shuffle_rounded, size: 18),
                    label: const Text(
                      '自选文件夹 / 压缩包随机播放',
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (_ctrl.savedMusicFolders.isNotEmpty)
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        backgroundColor:
                            VideoPlatformTheme.accent.withValues(alpha: 0.2),
                        foregroundColor: VideoPlatformTheme.accent,
                        minimumSize: const Size(160, 40),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                      onPressed: () {
                        _ctrl.scanAndPlayFoldersOrArchives(
                          sources: _ctrl.savedMusicFolders,
                          shuffle: true,
                        );
                      },
                      icon: const Icon(Icons.star_rounded, size: 18),
                      label: Text(
                        '随机播放常用音乐源 (${_ctrl.savedMusicFolders.length}个)',
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVinylTurntablePane(
    FileEntry track,
    ({String title, String artist, String qualityTag}) meta, {
    bool compact = false,
  }) {
    final discSize = compact ? 155.0 : 270.0;
    return Padding(
      padding: EdgeInsets.all(compact ? 12 : 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: discSize + 40,
            height: discSize + 16,
            child: Stack(
              alignment: Alignment.center,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 500),
                  width: discSize + 10,
                  height: discSize + 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: VideoPlatformTheme.accent.withValues(
                          alpha: _ctrl.isPlaying ? 0.25 : 0.08,
                        ),
                        blurRadius: 36,
                        spreadRadius: 6,
                      ),
                    ],
                  ),
                ),
                RotationTransition(
                  turns: _vinylController,
                  child: Container(
                    width: discSize,
                    height: discSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const SweepGradient(
                        colors: [
                          Color(0xFF111318),
                          Color(0xFF282C37),
                          Color(0xFF111318),
                          Color(0xFF282C37),
                          Color(0xFF111318),
                        ],
                      ),
                      border: Border.all(
                        color: VideoPlatformTheme.accent.withValues(alpha: 0.45),
                        width: 3,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.55),
                          blurRadius: 20,
                        ),
                      ],
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        for (final factor in const [0.88, 0.76, 0.64])
                          Container(
                            width: discSize * factor,
                            height: discSize * factor,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.06),
                                width: 1,
                              ),
                            ),
                          ),
                        Container(
                          width: discSize * 0.48,
                          height: discSize * 0.48,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: VideoPlatformTheme.accent
                                  .withValues(alpha: 0.75),
                              width: 2.5,
                            ),
                          ),
                          child: ClipOval(
                            child: _buildAlbumCoverWidget(),
                          ),
                        ),
                        Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: VideoPlatformTheme.bgPrimary,
                            border: Border.all(
                              color: Colors.white38,
                              width: 2,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (!compact)
                  Positioned(
                    top: 0,
                    right: 14,
                    child: AnimatedRotation(
                      turns: _ctrl.isPlaying ? 0.02 : -0.07,
                      duration: const Duration(milliseconds: 420),
                      curve: Curves.easeInOutCubic,
                      alignment: Alignment.topRight,
                      child: SizedBox(
                        width: 72,
                        height: 130,
                        child: CustomPaint(
                          painter: _VinylTonearmPainter(
                            accentColor: VideoPlatformTheme.accent,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(height: compact ? 8 : 18),
          Text(
            meta.title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 16 : 20,
              fontWeight: FontWeight.w800,
              color: VideoPlatformTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${meta.artist} · ${_ctrl.activeSubtitle.isNotEmpty ? _ctrl.activeSubtitle : track.formattedSize}',
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              color: VideoPlatformTheme.textSecondary,
            ),
          ),
          if (!compact) ...[
            const SizedBox(height: 18),
            _AnimatedAudioSpectrumBars(
              isPlaying: _ctrl.isPlaying,
              positionMs: _ctrl.position.inMilliseconds,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAlbumCoverWidget() {
    final url = _ctrl.coverImageUrl;
    if (url != null && url.isNotEmpty) {
      if (_ctrl.coverIsLocalFile) {
        return Image.file(
          File(url),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _defaultAlbumArt(),
        );
      }
      return Image.network(
        url,
        headers: _ctrl.coverImageHeaders.isEmpty ? null : _ctrl.coverImageHeaders,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _defaultAlbumArt(),
      );
    }
    return _defaultAlbumArt();
  }

  Widget _defaultAlbumArt() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            VideoPlatformTheme.accent,
            VideoPlatformTheme.accentHover,
            VideoPlatformTheme.bgElevated,
          ],
        ),
      ),
      child: const Center(
        child: Icon(
          Icons.music_note_rounded,
          size: 46,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _buildRightLyricsAndQueuePane(FileEntry currentTrack) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
          child: Row(
            children: [
              _buildTabPill(
                index: 0,
                icon: Icons.lyrics_rounded,
                label: '实时同步歌词',
              ),
              const SizedBox(width: 10),
              _buildTabPill(
                index: 1,
                icon: Icons.queue_music_rounded,
                label: '播放队列 (${_ctrl.queue.length})',
              ),
              const Spacer(),
              if (_rightTabIndex == 0 && _ctrl.lyricsSourceLabel.isNotEmpty)
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: VideoPlatformTheme.accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _ctrl.lyricsSourceLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: VideoPlatformTheme.accent,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Divider(height: 1, color: VideoPlatformTheme.borderSubtle),
        Expanded(
          child: _rightTabIndex == 0
              ? _buildSynchronizedLyricsView()
              : _buildPlaylistQueueView(currentTrack),
        ),
      ],
    );
  }

  Widget _buildTabPill({
    required int index,
    required IconData icon,
    required String label,
  }) {
    final selected = _rightTabIndex == index;
    return InkWell(
      onTap: () => setState(() => _rightTabIndex = index),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? VideoPlatformTheme.accent.withValues(alpha: 0.22)
              : VideoPlatformTheme.bgCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected
                ? VideoPlatformTheme.accent
                : VideoPlatformTheme.borderSubtle,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: selected
                  ? VideoPlatformTheme.accent
                  : VideoPlatformTheme.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.2,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected
                    ? VideoPlatformTheme.accent
                    : VideoPlatformTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSynchronizedLyricsView() {
    if (_ctrl.isLoadingLyrics) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(
              strokeWidth: 2.5,
              color: VideoPlatformTheme.accent,
            ),
            const SizedBox(height: 12),
            Text(
              '正在匹配同目录 / 压缩包内 .lrc 歌词与云端同步歌词...',
              style: TextStyle(
                fontSize: 13,
                color: VideoPlatformTheme.textSecondary,
              ),
            ),
          ],
        ),
      );
    }

    final lines = _ctrl.lyrics;
    if (lines.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lyrics_outlined,
                size: 46,
                color: VideoPlatformTheme.textMuted.withValues(alpha: 0.45),
              ),
              const SizedBox(height: 12),
              Text(
                '当前曲目暂无同步歌词',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: VideoPlatformTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '支持自动加载 115 / AList 同目录或压缩包内的同名 .lrc 歌词文件，或自动从 LRCLIB 匹配云端同步歌词',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: VideoPlatformTheme.textMuted,
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => setState(() {
                  _rightTabIndex = 1;
                  _mobileViewIndex = 2;
                }),
                icon: const Icon(Icons.queue_music_rounded, size: 16),
                label: Text('查看当前播放队列 (${_ctrl.queue.length} 首)'),
              ),
            ],
          ),
        ),
      );
    }

    final activeIdx = _ctrl.activeLyricIndex;
    return ListView.builder(
      controller: _lyricsScrollController,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 80),
      itemCount: lines.length,
      itemBuilder: (context, idx) {
        final line = lines[idx];
        final isActive = idx == activeIdx;
        return InkWell(
          onTap: () => _ctrl.seekTo(line.timestamp),
          borderRadius: BorderRadius.circular(8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isActive
                  ? VideoPlatformTheme.accent.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Text(
                  CloudMusicBottomDockBar.formatDuration(line.timestamp),
                  style: TextStyle(
                    fontSize: 11,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: isActive
                        ? VideoPlatformTheme.accent
                        : VideoPlatformTheme.textMuted,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    line.text,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: isActive ? 16.5 : 13.5,
                      fontWeight:
                          isActive ? FontWeight.w800 : FontWeight.w400,
                      color: isActive
                          ? VideoPlatformTheme.accent
                          : VideoPlatformTheme.textSecondary,
                      shadows: isActive
                          ? [
                              Shadow(
                                color: VideoPlatformTheme.accent
                                    .withValues(alpha: 0.45),
                                blurRadius: 12,
                              ),
                            ]
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlaylistQueueView(FileEntry currentTrack) {
    final kw = _queueSearch.trim().toLowerCase();
    final items = <({int index, FileEntry entry})>[];
    for (int i = 0; i < _ctrl.queue.length; i++) {
      final e = _ctrl.queue[i];
      if (kw.isEmpty || e.name.toLowerCase().contains(kw)) {
        items.add((index: i, entry: e));
      }
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: TextField(
                    controller: _queueFilterCtrl,
                    onChanged: (v) => setState(() => _queueSearch = v),
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: '在播放队列中搜索歌曲...',
                      prefixIcon: const Icon(Icons.search_rounded, size: 17),
                      suffixIcon: _queueSearch.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear_rounded, size: 15),
                              onPressed: () {
                                _queueFilterCtrl.clear();
                                setState(() => _queueSearch = '');
                              },
                            )
                          : null,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _ctrl.shuffleCurrentQueue,
                icon: const Icon(Icons.shuffle_rounded, size: 15),
                label: const Text('随机重排', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 4),
            itemBuilder: (context, i) {
              final item = items[i];
              final isCurrent = item.index == _ctrl.currentIndex;
              final meta = CloudMusicController.parseTrackMetadata(
                item.entry,
                fallbackArtist: _ctrl.mountNameFor(item.entry),
              );
              return InkWell(
                onTap: () => _ctrl.playQueueIndex(item.index),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: isCurrent
                        ? VideoPlatformTheme.accent.withValues(alpha: 0.16)
                        : VideoPlatformTheme.bgCard,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isCurrent
                          ? VideoPlatformTheme.accent.withValues(alpha: 0.65)
                          : VideoPlatformTheme.borderSubtle,
                    ),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 28,
                        child: isCurrent
                            ? Icon(
                                Icons.equalizer_rounded,
                                color: VideoPlatformTheme.accent,
                                size: 20,
                              )
                            : Text(
                                '${item.index + 1}'.padLeft(2, '0'),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: VideoPlatformTheme.textMuted,
                                ),
                              ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              meta.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: isCurrent
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: isCurrent
                                    ? VideoPlatformTheme.accent
                                    : VideoPlatformTheme.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${meta.artist} · ${_ctrl.mountNameFor(item.entry)} · ${item.entry.formattedSize}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: VideoPlatformTheme.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: VideoPlatformTheme.bgHover,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          item.entry.isInsideArchive
                              ? '📦 ${item.entry.normalizedExt.replaceAll('.', '').toUpperCase()}'
                              : item.entry.normalizedExt
                                  .replaceAll('.', '')
                                  .toUpperCase(),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: VideoPlatformTheme.accent,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: '从队列移除',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _ctrl.removeTrackAt(item.index),
                        icon: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: VideoPlatformTheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildBottomControlDeck(double progress, {required bool isWide}) {
    final screenW = MediaQuery.sizeOf(context).width;
    final isCompactDeck = screenW < 760;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        isCompactDeck ? 14 : 22,
        isCompactDeck ? 6 : 10,
        isCompactDeck ? 14 : 22,
        isCompactDeck ? 10 : 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                CloudMusicBottomDockBar.formatDuration(_ctrl.position),
                style: TextStyle(
                  fontSize: 11.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: VideoPlatformTheme.textSecondary,
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3.5,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6.5,
                    ),
                    activeTrackColor: VideoPlatformTheme.accent,
                    inactiveTrackColor: VideoPlatformTheme.borderStrong,
                    thumbColor: VideoPlatformTheme.accentHover,
                  ),
                  child: Slider(
                    value: progress,
                    onChanged: (v) {
                      if (_ctrl.duration > Duration.zero) {
                        _ctrl.seekTo(
                          Duration(
                            milliseconds:
                                (v * _ctrl.duration.inMilliseconds).round(),
                          ),
                        );
                      }
                    },
                  ),
                ),
              ),
              Text(
                CloudMusicBottomDockBar.formatDuration(_ctrl.duration),
                style: TextStyle(
                  fontSize: 11.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: VideoPlatformTheme.textSecondary,
                ),
              ),
            ],
          ),
          if (isCompactDeck)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  tooltip:
                      '播放模式：${CloudMusicBottomDockBar.playModeLabel(_ctrl.playMode)}',
                  visualDensity: VisualDensity.compact,
                  onPressed: _ctrl.cyclePlayMode,
                  icon: Icon(
                    CloudMusicBottomDockBar.playModeIcon(_ctrl.playMode),
                    size: 20,
                    color: VideoPlatformTheme.accent,
                  ),
                ),
                IconButton(
                  tooltip: '快退 5 秒',
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      _ctrl.seekRelative(const Duration(seconds: -5)),
                  icon: Icon(
                    Icons.replay_5_rounded,
                    color: VideoPlatformTheme.textSecondary,
                    size: 21,
                  ),
                ),
                IconButton(
                  tooltip: '上一首',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _ctrl.stepTrack(-1),
                  icon: Icon(
                    Icons.skip_previous_rounded,
                    color: VideoPlatformTheme.textPrimary,
                    size: 28,
                  ),
                ),
                InkWell(
                  onTap: _ctrl.togglePlayPause,
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          VideoPlatformTheme.accent,
                          VideoPlatformTheme.accentHover,
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color:
                              VideoPlatformTheme.accent.withValues(alpha: 0.4),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                    child: _ctrl.isLoadingTrack
                        ? const Padding(
                            padding: EdgeInsets.all(13),
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(
                            _ctrl.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 28,
                          ),
                  ),
                ),
                IconButton(
                  tooltip: '下一首',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _ctrl.stepTrack(1),
                  icon: Icon(
                    Icons.skip_next_rounded,
                    color: VideoPlatformTheme.textPrimary,
                    size: 28,
                  ),
                ),
                IconButton(
                  tooltip: '快进 5 秒',
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      _ctrl.seekRelative(const Duration(seconds: 5)),
                  icon: Icon(
                    Icons.forward_5_rounded,
                    color: VideoPlatformTheme.textSecondary,
                    size: 21,
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: _ctrl.cycleSpeed,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: VideoPlatformTheme.bgCard,
                      borderRadius: BorderRadius.circular(14),
                      border:
                          Border.all(color: VideoPlatformTheme.borderStrong),
                    ),
                    child: Text(
                      '${_ctrl.speed}x',
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                        color: VideoPlatformTheme.textPrimary,
                      ),
                    ),
                  ),
                ),
              ],
            )
          else
            Row(
              children: [
                TextButton.icon(
                  onPressed: _ctrl.cyclePlayMode,
                  icon: Icon(
                    CloudMusicBottomDockBar.playModeIcon(_ctrl.playMode),
                    size: 18,
                    color: VideoPlatformTheme.accent,
                  ),
                  label: Text(
                    CloudMusicBottomDockBar.playModeLabel(_ctrl.playMode),
                    style: TextStyle(
                      fontSize: 12.5,
                      color: VideoPlatformTheme.accent,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _ctrl.cycleSpeed,
                  child: Text(
                    '倍速 ${_ctrl.speed}x',
                    style: TextStyle(
                      fontSize: 12,
                      color: VideoPlatformTheme.textPrimary,
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '快退 5 秒',
                  onPressed: () =>
                      _ctrl.seekRelative(const Duration(seconds: -5)),
                  icon: Icon(
                    Icons.replay_5_rounded,
                    color: VideoPlatformTheme.textSecondary,
                    size: 22,
                  ),
                ),
                IconButton(
                  tooltip: '上一首',
                  onPressed: () => _ctrl.stepTrack(-1),
                  icon: Icon(
                    Icons.skip_previous_rounded,
                    color: VideoPlatformTheme.textPrimary,
                    size: 30,
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: _ctrl.togglePlayPause,
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          VideoPlatformTheme.accent,
                          VideoPlatformTheme.accentHover,
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color:
                              VideoPlatformTheme.accent.withValues(alpha: 0.4),
                          blurRadius: 14,
                        ),
                      ],
                    ),
                    child: _ctrl.isLoadingTrack
                        ? const Padding(
                            padding: EdgeInsets.all(14),
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.white,
                            ),
                          )
                        : Icon(
                            _ctrl.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 30,
                          ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '下一首',
                  onPressed: () => _ctrl.stepTrack(1),
                  icon: Icon(
                    Icons.skip_next_rounded,
                    color: VideoPlatformTheme.textPrimary,
                    size: 30,
                  ),
                ),
                IconButton(
                  tooltip: '快进 5 秒',
                  onPressed: () =>
                      _ctrl.seekRelative(const Duration(seconds: 5)),
                  icon: Icon(
                    Icons.forward_5_rounded,
                    color: VideoPlatformTheme.textSecondary,
                    size: 22,
                  ),
                ),
                const Spacer(),
                Icon(
                  _ctrl.volume <= 1
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded,
                  size: 18,
                  color: VideoPlatformTheme.textSecondary,
                ),
                SizedBox(
                  width: 110,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 5,
                      ),
                      activeTrackColor: VideoPlatformTheme.accent,
                      inactiveTrackColor: VideoPlatformTheme.borderStrong,
                      thumbColor: VideoPlatformTheme.accentHover,
                    ),
                    child: Slider(
                      value: _ctrl.volume,
                      min: 0,
                      max: 100,
                      onChanged: _ctrl.setVolume,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _VinylTonearmPainter extends CustomPainter {
  final Color accentColor;

  const _VinylTonearmPainter({
    required this.accentColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final basePaint = Paint()
      ..color = const Color(0xFF3F3F46)
      ..style = PaintingStyle.fill;
    final armPaint = Paint()
      ..color = const Color(0xFFD4D4D8)
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final pivot = Offset(size.width - 16, 16);
    canvas.drawCircle(pivot, 12, basePaint);
    canvas.drawCircle(
      pivot,
      6,
      Paint()..color = accentColor,
    );

    final path = Path()
      ..moveTo(pivot.dx, pivot.dy)
      ..lineTo(pivot.dx - 16, size.height * 0.68)
      ..lineTo(pivot.dx - 38, size.height * 0.90);
    canvas.drawPath(path, armPaint);

    final headPaint = Paint()
      ..color = accentColor
      ..strokeWidth = 7.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(pivot.dx - 32, size.height * 0.85),
      Offset(pivot.dx - 42, size.height * 0.93),
      headPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _VinylTonearmPainter oldDelegate) =>
      oldDelegate.accentColor != accentColor;
}

class _AnimatedAudioSpectrumBars extends StatelessWidget {
  final bool isPlaying;
  final int positionMs;

  const _AnimatedAudioSpectrumBars({
    required this.isPlaying,
    required this.positionMs,
  });

  @override
  Widget build(BuildContext context) {
    const barCount = 26;
    final tick = positionMs ~/ 180;
    return SizedBox(
      height: 32,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(barCount, (i) {
          double h = 5.0;
          if (isPlaying) {
            final wave1 = math.sin((tick * 0.65) + (i * 0.55)).abs();
            final wave2 = math.cos((tick * 0.42) - (i * 0.35)).abs();
            h = 5.0 + 25.0 * (0.55 * wave1 + 0.45 * wave2);
          }
          return AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            margin: const EdgeInsets.symmetric(horizontal: 2),
            width: 3.5,
            height: h.clamp(4.0, 30.0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  VideoPlatformTheme.accent,
                  VideoPlatformTheme.accentHover,
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}
