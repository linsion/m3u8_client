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
import '../../services/proxy_routing_service.dart';
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

class SavedMusicPlaylist {
  final String id;
  final String name;
  final List<FileEntry> tracks;
  final List<SavedMusicFolderItem> sources;
  final int currentIndex;
  final int updatedEpochMs;

  const SavedMusicPlaylist({
    required this.id,
    required this.name,
    required this.tracks,
    this.sources = const [],
    this.currentIndex = 0,
    this.updatedEpochMs = 0,
  });

  SavedMusicPlaylist copyWith({
    String? name,
    List<FileEntry>? tracks,
    List<SavedMusicFolderItem>? sources,
    int? currentIndex,
    int? updatedEpochMs,
  }) {
    return SavedMusicPlaylist(
      id: id,
      name: name ?? this.name,
      tracks: tracks ?? this.tracks,
      sources: sources ?? this.sources,
      currentIndex: currentIndex ?? this.currentIndex,
      updatedEpochMs: updatedEpochMs ?? this.updatedEpochMs,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'tracks': tracks.map((e) => e.toJson()).toList(),
        'sources': sources.map((s) => s.toJson()).toList(),
        'current_index': currentIndex,
        'updated_epoch_ms': updatedEpochMs,
      };

  factory SavedMusicPlaylist.fromJson(Map<String, dynamic> json) {
    final rawTracks = json['tracks'];
    final tracks = <FileEntry>[];
    if (rawTracks is List) {
      for (final item in rawTracks) {
        if (item is Map<String, dynamic>) {
          tracks.add(FileEntry.fromJson(item));
        }
      }
    }
    final rawSources = json['sources'];
    final sources = <SavedMusicFolderItem>[];
    if (rawSources is List) {
      for (final item in rawSources) {
        if (item is Map<String, dynamic>) {
          sources.add(SavedMusicFolderItem.fromJson(item));
        }
      }
    }
    return SavedMusicPlaylist(
      id: (json['id'] ?? 'default_playlist').toString(),
      name: (json['name'] ?? '默认播放列表').toString(),
      tracks: tracks,
      sources: sources,
      currentIndex: int.tryParse((json['current_index'] ?? 0).toString()) ?? 0,
      updatedEpochMs:
          int.tryParse((json['updated_epoch_ms'] ?? 0).toString()) ?? 0,
    );
  }
}

class AiMusicCategoryDraft {
  final String name;
  final String description;
  final List<FileEntry> tracks;

  const AiMusicCategoryDraft({
    required this.name,
    this.description = '',
    required this.tracks,
  });
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
    bool forceRefresh = false,
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
    if (!forceRefresh &&
        await outFile.exists() &&
        await outFile.length() > 1024) {
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
          LocalProxyTunnelBridge.recordDownstreamBytes(chunk.length);
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
          LocalProxyTunnelBridge.recordDownstreamBytes(chunk.length);
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

class CloudMusicController extends ChangeNotifier with WidgetsBindingObserver {
  static const String _prefSavedMusicFoldersKey = 'm3u8_saved_music_folders_v1';
  static const String _prefSavedMusicPlaylistsKey =
      'm3u8_saved_music_playlists_v1';
  static const String _prefActiveMusicPlaylistIdKey =
      'm3u8_active_music_playlist_id_v1';
  static const String _prefDefaultMusicQueueKey =
      'm3u8_default_music_queue_v1';
  static const String _prefDefaultMusicIndexKey =
      'm3u8_default_music_index_v1';
  static const String _prefDefaultMusicSourcesKey =
      'm3u8_default_music_sources_v1';
  static const String _prefMountsKey = 'm3u8_storage_mounts_v1';

  static final CloudMusicController shared = CloudMusicController._internal();

  CloudEndpointResolver? _customEndpointResolver;
  AppState? _boundAppState;

  @visibleForTesting
  Future<List<FileEntry>> Function(StorageMount mount, String path)?
      customDirectoryLister;

  @visibleForTesting
  Future<String> Function(String prompt)? customAiCompletionHandler;

  AppState? get boundAppState => _boundAppState;

  Player? _player;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<String>? _errorSub;
  Timer? _openWatchdogTimer;
  Timer? _speedSampleTimer;
  double _smoothedSpeedBytesPerSec = 0.0;
  int _lastSpeedSampleMs = 0;
  double _lastSpeedFwBytes = 0.0;
  Duration _lastSpeedBufferPos = Duration.zero;
  bool _speedSampleInFlight = false;

  List<FileEntry> _queue = [];
  int _currentIndex = -1;
  bool _isPlaying = false;
  bool _isLoadingTrack = false;
  bool _isSessionDocked = false;
  bool _isScanningFolders = false;
  bool _trackHasStartedPlaying = false;
  bool _needsFreshOpenAfterBackground = false;
  DateTime? _backgroundedAt;
  DateTime _lastTrackOpenedAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastLoadingStartedAt = DateTime.fromMillisecondsSinceEpoch(0);
  Duration? _pendingResumePosition;
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
  Uint8List? _coverImageBytes;

  static const MethodChannel _mediaSessionChannel =
      MethodChannel('com.linsion.m3u8_client/media_session');
  int _lastMediaSessionSyncEpochMs = 0;

  List<CloudLrcLine> _lyrics = const [];
  String _lyricsSourceLabel = '';
  bool _isLoadingLyrics = false;

  final Map<String, List<FileEntry>> _directoryContextByMountAndDir = {};
  final Map<String, String> _mountNameById = {};
  List<StorageMount> _availableMounts = const [];
  List<SavedMusicFolderItem> _savedMusicFolders = [];
  List<SavedMusicPlaylist> _savedPlaylists = [];
  String _activePlaylistId = 'default_playlist';
  List<SavedMusicFolderItem> _currentQueueSources = [];

  int _openSeq = 0;
  bool _handlingCompletion = false;
  bool _retriedCurrentTrack = false;
  bool _initialLoadDone = false;
  Future<void>? _initialLoadFuture;
  Future<void> get _initialLoad => _initialLoadDone
      ? Future<void>.value()
      : (_initialLoadFuture ?? Future<void>.value());
  Future<void>? _playlistWrite;
  int _scanSeq = 0;

  CloudMusicController._internal() {
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {}
    _initNativeMediaSessionHandler();
    _initialLoadFuture =
        _loadSavedMusicFoldersAndMounts(restorePlaylists: true).whenComplete(() {
          _initialLoadDone = true;
          _initialLoadFuture = null;
        });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _backgroundedAt ??= DateTime.now();
        break;
      case AppLifecycleState.inactive:
        if (Platform.isIOS || Platform.isAndroid) {
          _backgroundedAt ??= DateTime.now();
        }
        break;
      case AppLifecycleState.resumed:
        final bgAt = _backgroundedAt;
        _backgroundedAt = null;
        final bgDuration =
            bgAt == null ? Duration.zero : DateTime.now().difference(bgAt);
        markResumedFromBackground(backgroundDuration: bgDuration);
        break;
    }
  }

  /// Resets stale sockets, expired URL caches, and idle native player state
  /// when returning from background inactivity.
  void markResumedFromBackground({
    Duration backgroundDuration = const Duration(minutes: 5),
  }) {
    final longBackground = backgroundDuration >= const Duration(seconds: 15);
    if (longBackground) {
      Local115DirectService.instance.resetAfterBackground();
      RemoteStorageService.instance.resetAfterBackground();
    }
    final actuallyPlaying = _player?.state.playing ?? false;
    if (!actuallyPlaying) {
      var changed = false;
      if (_isPlaying) {
        _isPlaying = false;
        changed = true;
      }
      if (_isLoadingTrack &&
          (longBackground ||
              DateTime.now().difference(_lastLoadingStartedAt) >=
                  const Duration(seconds: 6))) {
        _isLoadingTrack = false;
        changed = true;
      }
      if (longBackground || _activeStreamUrl.isNotEmpty) {
        _needsFreshOpenAfterBackground = true;
        _activeStreamUrl = '';
        _resetPlayerInstance();
        changed = true;
      }
      if (changed) {
        notifyListeners();
      }
    }
  }

  void _initNativeMediaSessionHandler() {
    if (!Platform.isIOS && !Platform.isAndroid && !Platform.isMacOS) return;
    _mediaSessionChannel.setMethodCallHandler((call) async {
      if (call.method != 'onMediaCommand') return;
      final args = call.arguments;
      String action = '';
      int? positionMs;
      if (args is Map) {
        action = (args['action'] ?? '').toString();
        final rawPos = args['positionMs'];
        if (rawPos is int) {
          positionMs = rawPos;
        } else if (rawPos is num) {
          positionMs = rawPos.round();
        }
      } else if (args is String) {
        action = args;
      }
      switch (action) {
        case 'play':
          if (!_isPlaying) {
            await togglePlayPause();
          }
          break;
        case 'pause':
          if (_isPlaying) {
            await togglePlayPause();
          }
          break;
        case 'togglePlayPause':
          await togglePlayPause();
          break;
        case 'next':
          await stepTrack(1);
          break;
        case 'previous':
          await stepTrack(-1);
          break;
        case 'stop':
          await stopAndClose();
          break;
        case 'seek':
          if (positionMs != null && positionMs >= 0) {
            await seekTo(Duration(milliseconds: positionMs));
          }
          break;
      }
    });
  }

  void _syncNativeMediaSession({
    bool force = false,
    bool includeCoverBytes = false,
  }) {
    if (!Platform.isIOS && !Platform.isAndroid && !Platform.isMacOS) return;
    final track = currentTrack;
    if (track == null) {
      unawaited(_clearNativeMediaSession());
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (!force && (nowMs - _lastMediaSessionSyncEpochMs) < 1500) {
      return;
    }
    _lastMediaSessionSyncEpochMs = nowMs;
    final meta = parseTrackMetadata(
      track,
      fallbackArtist: mountNameFor(track),
    );
    final albumText = '${mountNameFor(track)} · ${meta.qualityTag}';
    final payload = <String, dynamic>{
      'title': meta.title,
      'artist': meta.artist.isNotEmpty ? meta.artist : mountNameFor(track),
      'album': albumText,
      'isPlaying': _isPlaying,
      'positionMs': _position.inMilliseconds,
      'durationMs': _duration.inMilliseconds,
      'speed': _speed,
      'queueIndex': _currentIndex,
      'queueCount': _queue.length,
    };
    if (includeCoverBytes &&
        _coverImageBytes != null &&
        _coverImageBytes!.isNotEmpty) {
      payload['coverBytes'] = _coverImageBytes;
    }
    unawaited(
      _mediaSessionChannel
          .invokeMethod<void>('updateMediaSession', payload)
          .catchError((_) {}),
    );
  }

  Future<void> _clearNativeMediaSession() async {
    if (!Platform.isIOS && !Platform.isAndroid && !Platform.isMacOS) return;
    try {
      await _mediaSessionChannel.invokeMethod<void>('clearMediaSession');
    } catch (_) {}
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
  }

  Player? get player => _player;
  List<FileEntry> get queue => _queue;
  int get currentIndex => _currentIndex;
  FileEntry? get currentTrack =>
      (_currentIndex >= 0 && _currentIndex < _queue.length)
          ? _queue[_currentIndex]
          : null;
  bool get hasActiveSession => _isSessionDocked && currentTrack != null;
  bool get needsFreshOpenAfterBackground => _needsFreshOpenAfterBackground;
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
  Uint8List? get coverImageBytes => _coverImageBytes;
  List<CloudLrcLine> get lyrics => _lyrics;
  String get lyricsSourceLabel => _lyricsSourceLabel;
  bool get isLoadingLyrics => _isLoadingLyrics;
  List<StorageMount> get availableMounts => _availableMounts;
  List<SavedMusicFolderItem> get savedMusicFolders => _savedMusicFolders;
  List<SavedMusicPlaylist> get savedPlaylists => _savedPlaylists;
  String get activePlaylistId => _activePlaylistId;
  SavedMusicPlaylist? get activePlaylist =>
      _savedPlaylists.where((p) => p.id == _activePlaylistId).firstOrNull;
  String get activePlaylistName => activePlaylist?.name ?? '默认播放列表';

  Future<void> _loadSavedMusicFoldersAndMounts({
    bool restorePlaylists = false,
  }) async {
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

      if (restorePlaylists) {
        _loadPlaylists(prefs);
        final track = currentTrack;
        if (track != null) {
          unawaited(_loadCoverAndLyricsForTrack(track, _openSeq));
        }
      }
    } catch (_) {
      _availableMounts = builtIn;
    }
    notifyListeners();
  }

  void _loadPlaylists(SharedPreferences prefs) {
    final rawPlaylists = prefs.getString(_prefSavedMusicPlaylistsKey);
    if (rawPlaylists != null && rawPlaylists.isNotEmpty) {
      final decoded = jsonDecode(rawPlaylists);
      if (decoded is List) {
        _savedPlaylists =
            decoded
                .whereType<Map<String, dynamic>>()
                .map(SavedMusicPlaylist.fromJson)
                .toList();
      }
    } else {
      final rawQueue = prefs.getString(_prefDefaultMusicQueueKey);
      final rawSources = prefs.getString(_prefDefaultMusicSourcesKey);
      final legacy = SavedMusicPlaylist.fromJson({
        'tracks':
            rawQueue != null && rawQueue.isNotEmpty
                ? jsonDecode(rawQueue)
                : null,
        'sources':
            rawSources != null && rawSources.isNotEmpty
                ? jsonDecode(rawSources)
                : null,
        'current_index': prefs.getInt(_prefDefaultMusicIndexKey) ?? 0,
      });
      if (legacy.tracks.isNotEmpty || legacy.sources.isNotEmpty) {
        _savedPlaylists.add(legacy);
      }
    }
    final savedActiveId = prefs.getString(_prefActiveMusicPlaylistIdKey);
    final selected =
        _savedPlaylists.where((p) => p.id == savedActiveId).firstOrNull ??
        _savedPlaylists.where((p) => p.id == 'default_playlist').firstOrNull ??
        _savedPlaylists.firstOrNull;
    if (selected != null) _selectPlaylistQueue(selected);
  }

  void _selectPlaylistQueue(SavedMusicPlaylist playlist) {
    _activePlaylistId = playlist.id;
    _queue = List<FileEntry>.of(playlist.tracks);
    _currentIndex =
        _queue.isEmpty ? -1 : playlist.currentIndex.clamp(0, _queue.length - 1);
    _currentQueueSources = List<SavedMusicFolderItem>.of(playlist.sources);
  }

  Future<void> _syncActivePlaylist() {
    final idx = _savedPlaylists.indexWhere((p) => p.id == _activePlaylistId);
    final updated = SavedMusicPlaylist(
      id: _activePlaylistId,
      name: idx >= 0 ? _savedPlaylists[idx].name : '默认播放列表',
      tracks: List<FileEntry>.of(_queue),
      sources: List<SavedMusicFolderItem>.of(_currentQueueSources),
      currentIndex: math.max(0, _currentIndex),
      updatedEpochMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (idx >= 0) {
      _savedPlaylists[idx] = updated;
    } else {
      _savedPlaylists.insert(0, updated);
    }
    return _persistPlaylists();
  }

  Future<void> _persistPlaylists() {
    // Keep writes in order when the user switches lists or tracks quickly.
    final activeId = _activePlaylistId;
    final playlists = List<SavedMusicPlaylist>.of(_savedPlaylists);
    Future<void> writeNow() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _prefSavedMusicPlaylistsKey,
          jsonEncode(playlists.map((p) => p.toJson()).toList()),
        );
        await prefs.setString(_prefActiveMusicPlaylistIdKey, activeId);
      } catch (_) {}
    }

    final prev = _playlistWrite;
    late final Future<void> current;
    current = (prev == null ? writeNow() : prev.then((_) => writeNow()))
        .whenComplete(() {
          if (identical(_playlistWrite, current)) {
            _playlistWrite = null;
          }
        });
    _playlistWrite = current;
    return current;
  }

  Future<void> createPlaylist(String name) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) return;
    await _initialLoad;
    final now = DateTime.now();
    final playlist = SavedMusicPlaylist(
      id: 'pl_${now.microsecondsSinceEpoch}',
      name: cleanName,
      tracks: const [],
      sources: const [],
      currentIndex: 0,
      updatedEpochMs: now.millisecondsSinceEpoch,
    );
    _savedPlaylists.add(playlist);
    _selectPlaylistQueue(playlist);
    final persisted = _persistPlaylists();
    await stopAndClose();
    await persisted;
  }

  /// Creates a new saved playlist pre-populated with [tracks] and [sources],
  /// persists it, and optionally switches to it / plays it immediately.
  Future<SavedMusicPlaylist> createPlaylistWithTracks({
    required String name,
    required List<FileEntry> tracks,
    List<SavedMusicFolderItem> sources = const [],
    bool switchToPlaylist = true,
    bool autoPlay = false,
    bool shuffle = false,
  }) async {
    await _initialLoad;
    final cleanName = name.trim().isEmpty ? '新建播放列表' : name.trim();
    final now = DateTime.now();
    final orderedTracks = List<FileEntry>.of(tracks);
    if (shuffle && orderedTracks.length > 1) {
      orderedTracks.shuffle(math.Random());
    }
    final playlist = SavedMusicPlaylist(
      id: 'pl_${now.microsecondsSinceEpoch}_${_savedPlaylists.length}',
      name: cleanName,
      tracks: orderedTracks,
      sources: List<SavedMusicFolderItem>.of(sources),
      currentIndex: 0,
      updatedEpochMs: now.millisecondsSinceEpoch,
    );
    _savedPlaylists.add(playlist);
    if (switchToPlaylist) {
      _selectPlaylistQueue(playlist);
      if (shuffle) {
        _playMode = 'shuffle';
      }
    }
    notifyListeners();
    final persisted = _persistPlaylists();
    if (switchToPlaylist && autoPlay && orderedTracks.isNotEmpty) {
      await _openCurrentTrack(forceRefreshUrl: true);
    } else if (switchToPlaylist && !autoPlay) {
      unawaited(stopAndClose());
    }
    await persisted;
    return playlist;
  }

  Future<void> renameSavedPlaylist(String playlistId, String newName) async {
    final clean = newName.trim();
    if (clean.isEmpty) return;
    final idx = _savedPlaylists.indexWhere((p) => p.id == playlistId);
    if (idx < 0) return;
    _savedPlaylists[idx] = _savedPlaylists[idx].copyWith(
      name: clean,
      updatedEpochMs: DateTime.now().millisecondsSinceEpoch,
    );
    notifyListeners();
    await _persistPlaylists();
  }

  Future<void> deleteSavedPlaylist(String playlistId) async {
    await _initialLoad;
    if (playlistId == 'default_playlist' && _savedPlaylists.length <= 1) {
      return;
    }
    _savedPlaylists.removeWhere((p) => p.id == playlistId);
    if (_activePlaylistId == playlistId) {
      final next = _savedPlaylists.firstOrNull;
      if (next != null) {
        await switchAndPlayPlaylist(next.id, autoPlay: false);
        return;
      }
      _activePlaylistId = 'default_playlist';
      _queue = [];
      _currentIndex = -1;
      _currentQueueSources = [];
      await stopAndClose();
    }
    notifyListeners();
    await _persistPlaylists();
  }

  Future<void> switchAndPlayPlaylist(
    String playlistId, {
    bool autoPlay = true,
    bool shuffle = false,
  }) async {
    await _initialLoad;
    final playlist =
        _savedPlaylists.where((p) => p.id == playlistId).firstOrNull;
    if (playlist == null) return;
    _selectPlaylistQueue(playlist);

    if (autoPlay && _queue.isNotEmpty) {
      _cancelFolderScan();
      if (shuffle) {
        _playMode = 'shuffle';
        _queue.shuffle(math.Random());
        _currentIndex = 0;
      }
      final persisted = _syncActivePlaylist();
      await _openCurrentTrack(forceRefreshUrl: true);
      await persisted;
      return;
    }

    final persisted = _persistPlaylists();
    final stopped = stopAndClose();
    final seq = _openSeq;
    await stopped;
    await persisted;
    if (seq != _openSeq) return;
    if (autoPlay && playlist.sources.isNotEmpty) {
      await scanAndPlayFoldersOrArchives(
        sources: playlist.sources,
        shuffle: shuffle,
      );
    } else if (currentTrack case final track?) {
      unawaited(_loadCoverAndLyricsForTrack(track, seq));
    }
  }

  Future<void> refreshAvailableMounts() async {
    await _initialLoad;
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
      resolveEntryEndpoint(FileEntry entry, {bool forceRefreshUrl = false}) async {
    await _initialLoad;
    if (_customEndpointResolver != null &&
        !(forceRefreshUrl &&
            (entry.sourceKind == StorageSourceKind.cloud115 ||
                entry.sourceKind == StorageSourceKind.alist))) {
      try {
        return await _customEndpointResolver!(entry);
      } catch (_) {}
    }

    var mount = _availableMounts.where((m) => m.id == entry.mountId).firstOrNull;
    if (mount == null &&
        (entry.sourceKind == StorageSourceKind.alist ||
            entry.sourceKind == StorageSourceKind.webdav)) {
      await _loadSavedMusicFoldersAndMounts();
      mount = _availableMounts.where((m) => m.id == entry.mountId).firstOrNull;
    }
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
        final info = await RemoteStorageService.instance.resolveAlistStreamInfo(
          mount,
          entry.path,
          fallbackUrl: entry.rawDownloadUrl,
          forceRefresh: forceRefreshUrl,
        );
        return (
          url: info.url,
          headers: info.headers,
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
        var pickcode = entry.pickcode115.trim();
        if (pickcode.isEmpty && entry.fid115.trim().isNotEmpty) {
          pickcode = await Local115DirectService.instance
                  .resolvePickcodeFromFid(entry.fid115.trim()) ??
              '';
        }
        if (pickcode.isEmpty &&
            entry.path.trim().isNotEmpty &&
            entry.path.trim() != '0' &&
            !entry.path.contains('/')) {
          final candidate = entry.path.trim();
          if (RegExp(r'^[0-9]+$').hasMatch(candidate)) {
            pickcode = await Local115DirectService.instance
                    .resolvePickcodeFromFid(candidate) ??
                '';
          } else {
            pickcode = candidate;
          }
        }
        if (pickcode.isEmpty) {
          throw Exception('该 115 文件缺少 pickcode');
        }
        var directUrl = await Local115DirectService.instance
            .resolvePickcodeStreamUrl(
              pickcode,
              forceRefresh: forceRefreshUrl,
              allowVideoFallback: false,
            );
        if ((directUrl == null || directUrl.isEmpty) &&
            forceRefreshUrl &&
            entry.fid115.trim().isNotEmpty) {
          final refreshedPc = await Local115DirectService.instance
              .resolvePickcodeFromFid(entry.fid115.trim());
          if (refreshedPc != null && refreshedPc.isNotEmpty) {
            directUrl = await Local115DirectService.instance
                .resolvePickcodeStreamUrl(
                  refreshedPc,
                  forceRefresh: true,
                  allowVideoFallback: false,
                );
          }
        }
        if (directUrl == null || directUrl.isEmpty) {
          throw Exception('无法获取 115 直链，请检查 115 登录状态');
        }
        return (
          url: directUrl,
          headers: Local115DirectService.instance.requestHeadersForUrl(directUrl),
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
    if (customDirectoryLister != null) {
      return await customDirectoryLister!(mount, path);
    }
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
  /// and returns all discovered audio files without interrupting active playback.
  Future<List<FileEntry>> collectTracksFromSources({
    required List<SavedMusicFolderItem> sources,
    bool includeSubfolders = true,
    bool includeArchives = true,
    void Function(String statusText, int foundCount)? onProgress,
  }) async {
    if (sources.isEmpty) return const [];
    await refreshAvailableMounts();
    final collectedTracks = <FileEntry>[];
    final seenTrackKeys = <String>{};
    final visitedDirs = <String>{};

    void addTrackIfNew(FileEntry track) {
      final trackKey =
          '${track.mountId}::${track.path}::${track.archiveInnerPath}';
      if (seenTrackKeys.add(trackKey)) {
        collectedTracks.add(track);
      }
    }

    Future<void> scanFolderRecursive(
      StorageMount mount,
      String folderPath,
      String folderTitle,
      int depth,
    ) async {
      final key = '${mount.id}::$folderPath';
      if (visitedDirs.contains(key)) return;
      visitedDirs.add(key);

      onProgress?.call(
        '正在扫描「${mount.name} / $folderTitle」... (已发现 ${collectedTracks.length} 首)',
        collectedTracks.length,
      );

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
          addTrackIfNew(e);
        } else if (includeArchives && e.isStreamableMusicArchive) {
          onProgress?.call(
            '正在解析压缩包「${e.name}」内的音乐... (已发现 ${collectedTracks.length} 首)',
            collectedTracks.length,
          );
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
                  addTrackIfNew(inner);
                }
              }
            }
          } catch (_) {}
        }
      }

      if (includeSubfolders &&
          depth < 5 &&
          subfolders.isNotEmpty &&
          collectedTracks.length < 3000) {
        for (final sub in subfolders) {
          if (collectedTracks.length >= 3000) break;
          await scanFolderRecursive(mount, sub.path, sub.name, depth + 1);
        }
      }
    }

    for (final src in sources) {
      final mount =
          _availableMounts.where((m) => m.id == src.mountId).firstOrNull ??
              StorageMount(
                id: src.mountId,
                name: src.mountName,
                kind: src.sourceKind,
                rootPath: src.path,
              );

      if (src.isArchive) {
        onProgress?.call(
          '正在读取压缩包「${src.title}」曲目列表...',
          collectedTracks.length,
        );
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
            for (final inner in archiveEntries) {
              if (inner.isAudio) {
                addTrackIfNew(inner);
              }
            }
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
            RegExp(
              r'\.(ape|wav|wave|flac|mp3|m4a|aac|ogg|opus|alac|aiff|aif|wma|dsf|dff|wv|tta)$',
            ).hasMatch(lowerPath)) {
          addTrackIfNew(potentialTrack);
        } else {
          await scanFolderRecursive(mount, src.path, src.title, 0);
        }
      }
    }

    return collectedTracks;
  }

  /// Splits a raw user query into normalized lowercase search keywords.
  static List<String> parseSearchKeywords(String rawQuery) {
    return rawQuery
        .split(RegExp(r'[\s,，;；、/|]+'))
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// Filters [tracks] by artist name or keywords (matching song title, parsed artist,
  /// filename, parent directory path, or archive inner path).
  static List<FileEntry> filterTracksByArtistOrKeywords({
    required List<FileEntry> tracks,
    required String query,
    bool matchAllKeywords = false,
  }) {
    final keywords = parseSearchKeywords(query);
    if (keywords.isEmpty) return List<FileEntry>.of(tracks);

    final matched = <FileEntry>[];
    for (final track in tracks) {
      final meta = parseTrackMetadata(track);
      final haystack = [
        track.name,
        meta.title,
        meta.artist,
        track.path,
        track.archiveInnerPath,
      ].join(' ').toLowerCase();

      final isMatch = matchAllKeywords
          ? keywords.every((kw) => haystack.contains(kw))
          : keywords.any((kw) => haystack.contains(kw));
      if (isMatch) {
        matched.add(track);
      }
    }
    return matched;
  }

  /// Scans specified directories [sources] for songs matching [query] (artist name or keywords),
  /// and creates a new [SavedMusicPlaylist] from the matched songs.
  Future<SavedMusicPlaylist?> searchSourcesAndCreatePlaylist({
    required List<SavedMusicFolderItem> sources,
    required String query,
    String? playlistName,
    bool matchAllKeywords = false,
    bool includeSubfolders = true,
    bool includeArchives = true,
    bool switchToPlaylist = true,
    bool autoPlay = false,
    bool shuffle = false,
    void Function(String statusText, int foundCount)? onProgress,
  }) async {
    final allTracks = await collectTracksFromSources(
      sources: sources,
      includeSubfolders: includeSubfolders,
      includeArchives: includeArchives,
      onProgress: onProgress,
    );
    final matched = filterTracksByArtistOrKeywords(
      tracks: allTracks,
      query: query,
      matchAllKeywords: matchAllKeywords,
    );
    if (matched.isEmpty) return null;

    final cleanQuery = query.trim();
    final targetName = (playlistName != null && playlistName.trim().isNotEmpty)
        ? playlistName.trim()
        : (cleanQuery.isNotEmpty ? cleanQuery : '目录精选歌单');

    return await createPlaylistWithTracks(
      name: targetName,
      tracks: matched,
      sources: sources,
      switchToPlaylist: switchToPlaylist,
      autoPlay: autoPlay,
      shuffle: shuffle,
    );
  }

  /// Analyzes [tracks] using the configured AI model (OpenAI / DeepSeek / Qwen / Gemini / Claude)
  /// and categorizes them into themed playlists.
  Future<List<AiMusicCategoryDraft>> analyzeTracksWithAi({
    required List<FileEntry> tracks,
    String dimension = 'auto',
    String customInstruction = '',
    String? apiKeyOverride,
    String? providerOverride,
    String? baseUrlOverride,
    String? modelOverride,
  }) async {
    if (tracks.isEmpty) return const [];

    final dimensionPrompt = switch (dimension) {
      'artist' =>
        '按【歌手 / 艺术家】分类：识别歌曲的演唱者或乐队，为每位主要歌手建立专属播放列表（例如：“周杰伦 精选”、“陈奕迅 精选”等）。',
      'genre' =>
        '按【音乐曲风 / 流派】分类：根据歌名、歌手风格与目录信息，划分为如“华语流行”、“摇滚热曲”、“民谣治愈”、“古风国风”、“电子动感”、“说唱 R&B”、“纯音乐 / 原声”等播放列表。',
      'mood' =>
        '按【情感 / 心情 / 听歌场景】分类：划分为如“深夜抒情治愈”、“运动燃曲 / 动感节奏”、“驾车兜风精选”、“怀旧伤感经典”、“轻松工作学习”等播放列表。',
      'language' =>
        '按【语种 / 地区】分类：划分为如“华语国语精选”、“粤语经典金曲”、“欧美英文流行”、“日韩音乐精选”等播放列表。',
      'era' =>
        '按【年代 / 时期】分类：划分为如“80/90年代经典老歌”、“00年代黄金华语”、“近年流行热歌”等播放列表。',
      _ =>
        '【AI 综合智能归类】：综合分析曲库的歌手、曲风、语种、心情与目录特征，自动划分为 2 到 8 个主题鲜明、最合理的精品播放列表。',
    };

    final maxPromptTracks = math.min(tracks.length, 450);
    final trackLines = <String>[];
    for (int i = 0; i < maxPromptTracks; i++) {
      final t = tracks[i];
      final meta = parseTrackMetadata(t);
      final rawPath =
          t.archiveInnerPath.isNotEmpty ? t.archiveInnerPath : t.path;
      final segments = rawPath
          .split(RegExp(r'[/\\]'))
          .where((s) => s.isNotEmpty)
          .toList();
      final folderHint = segments.length >= 2
          ? segments.sublist(math.max(0, segments.length - 3), segments.length - 1).join('/')
          : '';
      final artistPart = meta.artist.isNotEmpty ? '${meta.artist} - ' : '';
      final folderPart = folderHint.isNotEmpty ? ' [目录:$folderHint]' : '';
      trackLines.add('$i|$artistPart${meta.title}$folderPart');
    }

    const systemPrompt =
        '你是一位专业的数字音乐库整理与歌单策展 AI 助手。请严格只输出合法的 JSON 对象，不要包含任何额外的解释文字。';
    final userPrompt = StringBuffer()
      ..writeln('请对以下音乐目录中的 $maxPromptTracks 首歌曲进行分析并归类生成播放列表。')
      ..writeln('分类要求：$dimensionPrompt')
      ..writeln(
        customInstruction.trim().isNotEmpty
            ? '用户补充分类要求：${customInstruction.trim()}'
            : '',
      )
      ..writeln('请严格按照以下 JSON 格式返回结果（track_ids 为歌曲对应的数字序号数组）：')
      ..writeln('{"playlists":[{"name":"播放列表名称","description":"分类简短说明","track_ids":[0,1,2]}]}')
      ..writeln('\n待分析歌曲列表（格式：序号|歌手 - 歌名 [目录]）：')
      ..writeln(trackLines.join('\n'));

    String rawResponse;
    if (customAiCompletionHandler != null) {
      rawResponse = await customAiCompletionHandler!(userPrompt.toString());
    } else {
      rawResponse = await _requestAiChatCompletion(
        systemPrompt: systemPrompt,
        userPrompt: userPrompt.toString(),
        apiKeyOverride: apiKeyOverride,
        providerOverride: providerOverride,
        baseUrlOverride: baseUrlOverride,
        modelOverride: modelOverride,
      );
    }

    final parsed = parseAiCategorizationJson(rawResponse, tracks);
    if (parsed.isEmpty) {
      throw Exception('AI 返回的分类结果为空或格式无法解析');
    }
    return parsed;
  }

  /// Scans [sources], analyzes the discovered songs with AI according to [dimension]
  /// and [customInstruction], and creates a [SavedMusicPlaylist] for each AI category.
  Future<List<SavedMusicPlaylist>> analyzeSourcesAndCreatePlaylistsWithAi({
    required List<SavedMusicFolderItem> sources,
    String dimension = 'auto',
    String customInstruction = '',
    bool includeSubfolders = true,
    bool includeArchives = true,
    bool switchToFirstPlaylist = true,
    void Function(String statusText, int foundCount)? onProgress,
  }) async {
    final allTracks = await collectTracksFromSources(
      sources: sources,
      includeSubfolders: includeSubfolders,
      includeArchives: includeArchives,
      onProgress: onProgress,
    );
    if (allTracks.isEmpty) return const [];

    onProgress?.call('已扫描 ${allTracks.length} 首歌曲，正在请求 AI 智能分类...', allTracks.length);
    final drafts = await analyzeTracksWithAi(
      tracks: allTracks,
      dimension: dimension,
      customInstruction: customInstruction,
    );

    final created = <SavedMusicPlaylist>[];
    for (int i = 0; i < drafts.length; i++) {
      final draft = drafts[i];
      if (draft.tracks.isEmpty) continue;
      final pl = await createPlaylistWithTracks(
        name: draft.name,
        tracks: draft.tracks,
        sources: sources,
        switchToPlaylist: switchToFirstPlaylist && created.isEmpty,
        autoPlay: false,
      );
      created.add(pl);
    }
    return created;
  }

  Future<String> _requestAiChatCompletion({
    required String systemPrompt,
    required String userPrompt,
    String? apiKeyOverride,
    String? providerOverride,
    String? baseUrlOverride,
    String? modelOverride,
  }) async {
    final state = _boundAppState;
    final apiKey = (apiKeyOverride ?? state?.aiApiKey ?? '').trim();
    if (apiKey.isEmpty) {
      throw Exception('未配置 AI API Key，请先在设置或弹窗中填入 AI API Key');
    }

    final rawProvider = (providerOverride ?? state?.effectiveAiProvider ?? 'openai')
        .trim()
        .toLowerCase();
    final provider = apiKey.startsWith('AIza')
        ? 'gemini'
        : (apiKey.startsWith('sk-ant-') ? 'claude' : rawProvider);

    final baseUrl = (baseUrlOverride != null && baseUrlOverride.trim().isNotEmpty)
        ? baseUrlOverride.trim().replaceAll(RegExp(r'/+$'), '')
        : (state?.effectiveAiBaseUrl ?? 'https://api.openai.com/v1');

    final model = (modelOverride != null && modelOverride.trim().isNotEmpty)
        ? modelOverride.trim()
        : (state?.effectiveAiModel ?? 'gpt-4o-mini');

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    if (state != null) {
      client.findProxy = (Uri u) => state.api.buildProxyDirectiveForUri(u);
    }

    try {
      late final Uri uri;
      late final Map<String, String> headers;
      late final Map<String, dynamic> bodyMap;

      if (provider == 'gemini') {
        final cleanBase = baseUrl.contains('generativelanguage.googleapis.com')
            ? baseUrl
            : 'https://generativelanguage.googleapis.com/v1beta';
        uri = Uri.parse(
          '$cleanBase/models/$model:generateContent?key=${Uri.encodeQueryComponent(apiKey)}',
        );
        headers = {'Content-Type': 'application/json'};
        bodyMap = {
          'contents': [
            {
              'parts': [
                {'text': '$systemPrompt\n\n$userPrompt'},
              ],
            },
          ],
          'generationConfig': {
            'temperature': 0.2,
            'responseMimeType': 'application/json',
          },
        };
      } else if (provider == 'claude') {
        final endpoint = baseUrl.endsWith('/messages')
            ? baseUrl
            : '$baseUrl/messages';
        uri = Uri.parse(endpoint);
        headers = {
          'Content-Type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
        };
        bodyMap = {
          'model': model,
          'max_tokens': 4096,
          'temperature': 0.2,
          'system': systemPrompt,
          'messages': [
            {'role': 'user', 'content': userPrompt},
          ],
        };
      } else {
        final endpoint = baseUrl.endsWith('/chat/completions')
            ? baseUrl
            : '$baseUrl/chat/completions';
        uri = Uri.parse(endpoint);
        headers = {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        };
        bodyMap = {
          'model': model,
          'temperature': 0.2,
          'messages': [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': userPrompt},
          ],
        };
      }

      final req = await client.postUrl(uri).timeout(const Duration(seconds: 30));
      headers.forEach((k, v) => req.headers.set(k, v));
      final payloadBytes = utf8.encode(jsonEncode(bodyMap));
      req.contentLength = payloadBytes.length;
      req.add(payloadBytes);

      final resp = await req.close().timeout(const Duration(seconds: 60));
      final respBody = await utf8.decoder.bind(resp).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('AI 接口返回错误 (HTTP ${resp.statusCode}): $respBody');
      }

      final decoded = jsonDecode(respBody);
      if (decoded is Map<String, dynamic>) {
        if (provider == 'gemini') {
          final candidates = decoded['candidates'];
          if (candidates is List && candidates.isNotEmpty) {
            final content = candidates.first['content'];
            final parts = content is Map ? content['parts'] : null;
            if (parts is List && parts.isNotEmpty) {
              return (parts.first['text'] ?? '').toString();
            }
          }
        } else if (provider == 'claude') {
          final content = decoded['content'];
          if (content is List && content.isNotEmpty) {
            return (content.first['text'] ?? '').toString();
          }
        } else {
          final choices = decoded['choices'];
          if (choices is List && choices.isNotEmpty) {
            final msg = choices.first['message'];
            if (msg is Map) {
              return (msg['content'] ?? '').toString();
            }
          }
        }
      }
      return respBody;
    } finally {
      client.close(force: true);
    }
  }

  /// Parses an AI JSON categorization response and maps track IDs / names back to [sourceTracks].
  static List<AiMusicCategoryDraft> parseAiCategorizationJson(
    String rawResponse,
    List<FileEntry> sourceTracks,
  ) {
    if (rawResponse.trim().isEmpty || sourceTracks.isEmpty) return const [];

    String cleaned = rawResponse.trim();
    final fenceMatch = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(cleaned);
    if (fenceMatch != null) {
      cleaned = fenceMatch.group(1)!.trim();
    } else {
      final firstBrace = cleaned.indexOf('{');
      final lastBrace = cleaned.lastIndexOf('}');
      final firstBracket = cleaned.indexOf('[');
      final lastBracket = cleaned.lastIndexOf(']');
      if (firstBrace >= 0 &&
          lastBrace > firstBrace &&
          (firstBracket < 0 || firstBrace < firstBracket)) {
        cleaned = cleaned.substring(firstBrace, lastBrace + 1);
      } else if (firstBracket >= 0 && lastBracket > firstBracket) {
        cleaned = cleaned.substring(firstBracket, lastBracket + 1);
      }
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(cleaned);
    } catch (_) {
      return const [];
    }

    List<dynamic> rawList = const [];
    if (decoded is List) {
      rawList = decoded;
    } else if (decoded is Map) {
      final candidates =
          decoded['playlists'] ?? decoded['categories'] ?? decoded['groups'];
      if (candidates is List) {
        rawList = candidates;
      }
    }

    final results = <AiMusicCategoryDraft>[];
    for (final item in rawList) {
      if (item is! Map) continue;
      final name = (item['name'] ?? item['title'] ?? item['category'] ?? '')
          .toString()
          .trim();
      if (name.isEmpty) continue;
      final desc = (item['description'] ?? item['reason'] ?? '')
          .toString()
          .trim();
      final rawIds = item['track_ids'] ??
          item['tracks'] ??
          item['ids'] ??
          item['indices'] ??
          item['songs'];
      if (rawIds is! List) continue;

      final categoryTracks = <FileEntry>[];
      final seenIndices = <int>{};

      for (final idItem in rawIds) {
        int? idx;
        if (idItem is int) {
          idx = idItem;
        } else if (idItem is num) {
          idx = idItem.toInt();
        } else if (idItem is String) {
          idx = int.tryParse(idItem.trim());
          if (idx == null) {
            final lower = idItem.trim().toLowerCase();
            final foundIdx = sourceTracks.indexWhere(
              (t) =>
                  t.name.toLowerCase().contains(lower) ||
                  parseTrackMetadata(t).title.toLowerCase().contains(lower),
            );
            if (foundIdx >= 0) idx = foundIdx;
          }
        }
        if (idx != null &&
            idx >= 0 &&
            idx < sourceTracks.length &&
            seenIndices.add(idx)) {
          categoryTracks.add(sourceTracks[idx]);
        }
      }

      if (categoryTracks.isNotEmpty) {
        results.add(
          AiMusicCategoryDraft(
            name: name,
            description: desc,
            tracks: categoryTracks,
          ),
        );
      }
    }

    return results;
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
    final scan = ++_scanSeq;
    await refreshAvailableMounts();
    if (scan != _scanSeq) return 0;

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
        if (scan != _scanSeq || visitedKeys.contains(key)) return;
        visitedKeys.add(key);

        _scanningStatusText = '正在扫描「${mount.name} / $folderTitle」... (已发现 ${collectedTracks.length} 首)';
        notifyListeners();

        List<FileEntry> entries = const [];
        try {
          entries = await listDirectoryForMount(mount, folderPath);
        } catch (_) {
          return;
        }
        if (scan != _scanSeq || entries.isEmpty) return;

        registerDirectoryContext(
          mounts: _availableMounts,
          directoryEntries: entries,
        );

        final subfolders = <FileEntry>[];
        for (final e in entries) {
          if (scan != _scanSeq) return;
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

        if (includeSubfolders &&
            depth < 5 &&
            subfolders.isNotEmpty &&
            collectedTracks.length < 3000) {
          for (final sub in subfolders) {
            if (collectedTracks.length >= 3000) break;
            await scanFolderRecursive(mount, sub.path, sub.name, depth + 1);
          }
        }
      }

      for (final src in sources) {
        if (scan != _scanSeq) return 0;
        final mount =
            _availableMounts.where((m) => m.id == src.mountId).firstOrNull ??
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

      if (scan != _scanSeq) return 0;
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
      _currentQueueSources = List<SavedMusicFolderItem>.from(sources);
      unawaited(_syncActivePlaylist());
      notifyListeners();
      await _openCurrentTrack();
      return collectedTracks.length;
    } catch (e) {
      if (scan != _scanSeq) return 0;
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
    await _initialLoad;
    final scan = ++_scanSeq;
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
      final allInner = await CloudArchiveMusicService.instance
          .inspectArchiveEntries(
            archiveEntry: archiveEntry,
            endpointResolver: resolveEntryEndpoint,
          );
      if (scan != _scanSeq) return 0;
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
      _currentQueueSources = [
        SavedMusicFolderItem(
          mountId: archiveEntry.mountId,
          mountName: mountNameFor(archiveEntry),
          sourceKind: archiveEntry.sourceKind,
          path: archiveEntry.path,
          title: archiveEntry.name,
          isArchive: true,
          size: archiveEntry.size,
          pickcode115: archiveEntry.pickcode115,
        ),
      ];
      unawaited(_syncActivePlaylist());
      notifyListeners();
      await _openCurrentTrack();
      return audioTracks.length;
    } catch (e) {
      if (scan != _scanSeq) return 0;
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

  static final Map<String, ({String title, String artist, String qualityTag})>
      _trackMetaCache = {};
  static final RegExp _leadingTrackNumPattern =
      RegExp(r'^\s*(\[\d+\]|\(\d+\)|\d{1,4}[\.\-_、\s]+)\s*');
  static final RegExp _qualitySuffixPattern = RegExp(
    r'\s*(\[(?:FLAC|APE|WAV|MP3|AAC|ALAC|DSD|Hi-Res|24bit|16bit|320K|无损|母带)[^\]]*\]|\((?:FLAC|APE|WAV|MP3|AAC|ALAC|DSD|Hi-Res|24bit|16bit|320K|无损|母带)[^\)]*\))\s*$',
    caseSensitive: false,
  );

  static int _looksMoreLikeSongTitle(String text) {
    int score = 0;
    if (text.contains('《') ||
        text.contains('》') ||
        text.contains('「') ||
        text.contains('」')) {
      score += 4;
    }
    final lower = text.toLowerCase();
    const titleKeywords = [
      'live',
      'remix',
      'ver.',
      'version',
      'ost',
      '伴奏',
      '纯音乐',
      '主题曲',
      '片尾曲',
      '插曲',
      '推广曲',
      '概念曲',
      '合唱',
      '独唱',
      '钢琴版',
      '吉他版',
      'acoustic',
      'instrumental',
      'cover',
      '翻唱',
    ];
    for (final kw in titleKeywords) {
      if (lower.contains(kw)) score += 2;
    }
    if ((text.contains('(') && text.contains(')')) ||
        (text.contains('（') && text.contains('）'))) {
      score += 1;
    }
    return score;
  }

  static ({String title, String artist, String qualityTag}) parseTrackMetadata(
    FileEntry entry, {
    String fallbackArtist = '',
  }) {
    final cacheKey =
        '${entry.mountId}::${entry.path}::${entry.size}::$fallbackArtist';
    final cached = _trackMetaCache[cacheKey];
    if (cached != null) return cached;

    String base = entry.name;
    final dot = base.lastIndexOf('.');
    if (dot > 0) {
      base = base.substring(0, dot);
    }
    base = base.replaceFirst(_leadingTrackNumPattern, '');
    base = base.replaceFirst(_qualitySuffixPattern, '').trim();

    String artist = entry.isInsideArchive && fallbackArtist.isEmpty
        ? entry.archiveContainerName
        : fallbackArtist;
    String title = base;

    final openBook = base.indexOf('《');
    final closeBook = base.indexOf('》');
    if (openBook >= 0 && closeBook > openBook + 1) {
      final inside = base.substring(openBook + 1, closeBook).trim();
      final before = base
          .substring(0, openBook)
          .replaceAll(RegExp(r'^[\s\-–—_·:]+|[\s\-–—_·:]+$'), '');
      final after = base
          .substring(closeBook + 1)
          .replaceAll(RegExp(r'^[\s\-–—_·:]+|[\s\-–—_·:]+$'), '');
      if (inside.isNotEmpty) {
        title = inside;
        if (before.isNotEmpty) {
          artist = before;
        } else if (after.isNotEmpty) {
          artist = after;
        }
      }
    } else {
      String leftPart = '';
      String rightPart = '';
      for (final sep in const [' - ', ' – ', ' — ', ' _ ']) {
        final idx = base.indexOf(sep);
        if (idx > 0 && idx < base.length - sep.length) {
          leftPart = base.substring(0, idx).trim();
          rightPart = base.substring(idx + sep.length).trim();
          break;
        }
      }
      if (leftPart.isEmpty) {
        final altDash = base.indexOf('-');
        if (altDash > 0 && altDash < base.length - 1) {
          leftPart = base.substring(0, altDash).trim();
          rightPart = base.substring(altDash + 1).trim();
        }
      }
      if (leftPart.isNotEmpty && rightPart.isNotEmpty) {
        final cleanedRight =
            rightPart.replaceFirst(_leadingTrackNumPattern, '').trim();
        if (cleanedRight.isNotEmpty) {
          rightPart = cleanedRight;
        }
        final leftScore = _looksMoreLikeSongTitle(leftPart);
        final rightScore = _looksMoreLikeSongTitle(rightPart);
        if (leftScore > rightScore) {
          title = leftPart;
          artist = rightPart;
        } else {
          artist = leftPart;
          title = rightPart;
        }
      }
    }

    if (artist.isEmpty || artist == fallbackArtist) {
      String rawParent = '';
      if (entry.isInsideArchive) {
        final slash = entry.archiveInnerPath.lastIndexOf('/');
        if (slash > 0) {
          final dirPart = entry.archiveInnerPath.substring(0, slash);
          rawParent = dirPart.split('/').last;
        } else if (entry.archiveContainerName.isNotEmpty) {
          final cDot = entry.archiveContainerName.lastIndexOf('.');
          rawParent = cDot > 0
              ? entry.archiveContainerName.substring(0, cDot)
              : entry.archiveContainerName;
        }
      } else {
        final parts = entry.path
            .replaceAll('\\', '/')
            .split('/')
            .where((s) => s.isNotEmpty)
            .toList();
        if (parts.length >= 2) {
          rawParent = parts[parts.length - 2];
        }
      }
      final cleanParent = rawParent.trim();
      if (cleanParent.isNotEmpty &&
          cleanParent != '0' &&
          cleanParent != title) {
        artist = cleanParent;
      }
    }
    if (title.isEmpty) title = base.isEmpty ? entry.name : base;
    if (artist.isEmpty) artist = fallbackArtist;

    final ext = entry.normalizedExt.replaceAll('.', '').toUpperCase();
    String qualityTag;
    switch (ext) {
      case 'FLAC':
        qualityTag =
            entry.size > 35 * 1024 * 1024 ? 'Hi-Res · FLAC 无损' : 'FLAC 无损';
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

    final res = (title: title, artist: artist, qualityTag: qualityTag);
    if (_trackMetaCache.length > 6000) {
      _trackMetaCache.clear();
    }
    _trackMetaCache[cacheKey] = res;
    return res;
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

  void _resetPlayerInstance() {
    _openWatchdogTimer?.cancel();
    _openWatchdogTimer = null;
    _speedSampleTimer?.cancel();
    _speedSampleTimer = null;
    _smoothedSpeedBytesPerSec = 0.0;
    _lastSpeedFwBytes = 0.0;
    GlobalSpeedTracker.instance.unregister(this);
    _playingSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _completedSub?.cancel();
    _errorSub?.cancel();
    _playingSub = null;
    _positionSub = null;
    _durationSub = null;
    _completedSub = null;
    _errorSub = null;
    final oldPlayer = _player;
    _player = null;
    if (oldPlayer != null) {
      unawaited(
        oldPlayer
            .stop()
            .catchError((_) {})
            .whenComplete(() => oldPlayer.dispose().catchError((_) {})),
      );
    }
  }

  Future<void> _configureMusicPlayer(Player p, {required bool isLocalRelay}) async {
    try {
      final dynamic platform = p.platform;
      final props = <String, String>{
        'cache': 'yes',
        'cache-on-disk': 'no',
        'cache-secs': '60',
        'demuxer-readahead-secs': '30',
        'network-timeout': '15',
        'tls-verify': 'no',
        'keep-open': 'no',
        'stream-lavf-o':
            'reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=5',
        if (isLocalRelay) 'http-proxy': '',
      };
      await Future(() async {
        for (final entry in props.entries) {
          await platform.setProperty(entry.key, entry.value);
        }
      }).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  void _ensurePlayerInitialized() {
    if (_player != null) return;
    final p = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 32 * 1024 * 1024,
      ),
    );
    _player = p;
    _playingSub = p.stream.playing.listen((playing) {
      if (!identical(_player, p)) return;
      if (_isPlaying != playing || (playing && _isLoadingTrack)) {
        _isPlaying = playing;
        if (playing) {
          _isLoadingTrack = false;
          _errorText = '';
          _openWatchdogTimer?.cancel();
        }
        notifyListeners();
        _syncNativeMediaSession(force: true);
      }
    });
    _positionSub = p.stream.position.listen((pos) {
      if (!identical(_player, p)) return;
      if (pos > Duration.zero && _isLoadingTrack) {
        _isLoadingTrack = false;
        _openWatchdogTimer?.cancel();
      }
      if (pos.inMilliseconds >= 400 && _isPlaying) {
        _trackHasStartedPlaying = true;
      }
      final resumeTarget = _pendingResumePosition;
      if (resumeTarget != null &&
          resumeTarget.inSeconds > 2 &&
          _duration.inSeconds > resumeTarget.inSeconds + 3 &&
          pos.inSeconds < 2) {
        _pendingResumePosition = null;
        unawaited(p.seek(resumeTarget).catchError((_) {}));
      }
      if ((pos.inMilliseconds - _position.inMilliseconds).abs() >= 200 ||
           pos == Duration.zero) {
        _position = pos;
        notifyListeners();
        _syncNativeMediaSession(force: false);
      }
    });
    _durationSub = p.stream.duration.listen((dur) {
      if (!identical(_player, p)) return;
      if (dur > Duration.zero && dur != _duration) {
        _duration = dur;
        final resumeTarget = _pendingResumePosition;
        if (resumeTarget != null &&
            resumeTarget.inSeconds > 2 &&
            dur.inSeconds > resumeTarget.inSeconds + 3) {
          _pendingResumePosition = null;
          unawaited(p.seek(resumeTarget).catchError((_) {}));
        }
        notifyListeners();
        _syncNativeMediaSession(force: true);
      }
    });
    _completedSub = p.stream.completed.listen((completed) {
      if (!identical(_player, p) || !completed) return;
      if (_isLoadingTrack || _errorText.isNotEmpty) return;
      if (!_trackHasStartedPlaying && _position.inMilliseconds < 400) {
        if (!_retriedCurrentTrack && currentTrack != null) {
          _retriedCurrentTrack = true;
          unawaited(
            _openCurrentTrack(
              forceRefreshUrl: true,
              resetPlayer: true,
              isRetry: true,
            ),
          );
        }
        return;
      }
      _trackHasStartedPlaying = false;
      _onTrackCompleted();
    });
    _errorSub = p.stream.error.listen((err) {
      if (!identical(_player, p) || err.trim().isEmpty) return;
      if (!_retriedCurrentTrack && currentTrack != null) {
        _retriedCurrentTrack = true;
        unawaited(
          _openCurrentTrack(
            forceRefreshUrl: true,
            resetPlayer: true,
            isRetry: true,
          ),
        );
      } else if (_isLoadingTrack || _errorText.isEmpty) {
        _openWatchdogTimer?.cancel();
        _isLoadingTrack = false;
        _isPlaying = false;
        _errorText = '音频播放失败：$err';
        notifyListeners();
      }
    });
    _startSpeedSampling();
  }

  Future<double> _readMpvNumericProperty(
    dynamic platform,
    String propertyName,
  ) async {
    try {
      final raw = await platform.getProperty(propertyName);
      if (raw == null) return 0.0;
      final val = double.tryParse(raw.toString().trim());
      if (val != null && val.isFinite && val > 0) {
        return val;
      }
    } catch (_) {}
    return 0.0;
  }

  void _startSpeedSampling() {
    _speedSampleTimer?.cancel();
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    _lastSpeedSampleMs = DateTime.now().millisecondsSinceEpoch;
    _lastSpeedFwBytes = 0.0;
    _lastSpeedBufferPos = _player?.state.buffer ?? Duration.zero;
    _speedSampleTimer = Timer.periodic(
      const Duration(milliseconds: 850),
      (_) => unawaited(_sampleMusicPlayerSpeed()),
    );
  }

  Future<void> _sampleMusicPlayerSpeed() async {
    if (_speedSampleInFlight) return;
    final p = _player;
    final track = currentTrack;
    if (p == null || track == null || (!_isPlaying && !_isLoadingTrack)) {
      _smoothedSpeedBytesPerSec = 0.0;
      GlobalSpeedTracker.instance.unregister(this);
      return;
    }
    _speedSampleInFlight = true;
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final elapsedSec =
          ((nowMs - _lastSpeedSampleMs).clamp(200, 5000)) / 1000.0;
      _lastSpeedSampleMs = nowMs;

      final state = p.state;
      final curBuffer = state.buffer;
      final deltaBufferSec =
          (curBuffer - _lastSpeedBufferPos).inMilliseconds / 1000.0;
      _lastSpeedBufferPos = curBuffer;

      double mpvCacheSpeed = 0.0;
      double mpvRawInputRate = 0.0;
      double fwBytesDeltaRate = 0.0;
      double audioBitrateBytesPerSec = 0.0;

      try {
        final dynamic platform = p.platform;
        if (platform != null) {
          final results = await Future.wait<double>([
            _readMpvNumericProperty(platform, 'cache-speed'),
            _readMpvNumericProperty(
              platform,
              'demuxer-cache-state/raw-input-rate',
            ),
            _readMpvNumericProperty(platform, 'demuxer-cache-state/fw-bytes'),
            _readMpvNumericProperty(platform, 'audio-bitrate'),
          ]).timeout(
            const Duration(milliseconds: 420),
            onTimeout: () => const [0.0, 0.0, 0.0, 0.0],
          );

          mpvCacheSpeed = results[0];
          mpvRawInputRate = results[1];
          final fwBytes = results[2];
          final aBitrate = results[3];

          if (fwBytes > 0) {
            if (fwBytes > _lastSpeedFwBytes && _lastSpeedFwBytes >= 0) {
              fwBytesDeltaRate = (fwBytes - _lastSpeedFwBytes) / elapsedSec;
            }
            _lastSpeedFwBytes = fwBytes;
          }
          if (aBitrate > 0) {
            audioBitrateBytesPerSec = aBitrate / 8.0;
          }
        }
      } catch (_) {}

      final proxyRate = LocalProxyTunnelBridge.recentDownstreamBytesPerSecond;
      double measured = mpvCacheSpeed;
      if (mpvRawInputRate > measured) measured = mpvRawInputRate;
      if (fwBytesDeltaRate > measured) measured = fwBytesDeltaRate;
      if (proxyRate > measured) measured = proxyRate;

      if (measured <= 0 && (_isPlaying || _isLoadingTrack)) {
        double fallbackAudioRate = audioBitrateBytesPerSec;
        if (fallbackAudioRate <= 4096) {
          final durSec = _duration.inSeconds;
          if (track.size > 0 && durSec > 1) {
            fallbackAudioRate = (track.size / durSec).clamp(16384.0, 512000.0);
          } else {
            final isLossless = const {
              '.flac',
              '.wav',
              '.wave',
              '.ape',
              '.mac',
              '.alac',
              '.aiff',
              '.aif',
              '.dsf',
              '.dff',
            }.contains(track.normalizedExt);
            fallbackAudioRate = isLossless ? 112 * 1024.0 : 40 * 1024.0;
          }
        }
        final waveFactor = 0.88 + ((nowMs ~/ 850) % 7) * 0.04;
        if (deltaBufferSec > 0.1) {
          measured =
              (deltaBufferSec / elapsedSec).clamp(0.5, 6.0) *
              fallbackAudioRate *
              waveFactor;
        } else if (_isPlaying || _isLoadingTrack) {
          measured = fallbackAudioRate * waveFactor;
        }
      }

      if (measured > 0) {
        _smoothedSpeedBytesPerSec = _smoothedSpeedBytesPerSec <= 1024
            ? measured
            : (_smoothedSpeedBytesPerSec * 0.42 + measured * 0.58);
      } else {
        _smoothedSpeedBytesPerSec *= 0.55;
        if (_smoothedSpeedBytesPerSec < 1024) _smoothedSpeedBytesPerSec = 0.0;
      }

      GlobalSpeedTracker.instance.reportPlayerSpeed(
        this,
        _smoothedSpeedBytesPerSec,
        player: p,
      );
    } finally {
      _speedSampleInFlight = false;
    }
  }

  Future<void> playFromDirectory({
    required FileEntry targetTrack,
    required List<FileEntry> directoryEntries,
    required List<StorageMount> mounts,
    bool shuffle = false,
  }) async {
    await _initialLoad;
    registerDirectoryContext(
      mounts: mounts,
      directoryEntries: directoryEntries,
    );
    final audioTracks =
        directoryEntries.where((e) => !e.isDir && e.isAudio).toList();
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
    unawaited(_syncActivePlaylist());
    await _openCurrentTrack();
  }

  /// Shuffles the current queue and starts playing a random track immediately!
  Future<void> shuffleCurrentQueue() async {
    await _initialLoad;
    if (_queue.isEmpty) return;
    _playMode = 'shuffle';
    _queue.shuffle(math.Random());
    _currentIndex = 0;
    unawaited(_syncActivePlaylist());
    notifyListeners();
    await _openCurrentTrack(forceRefreshUrl: _needsFreshOpenAfterBackground);
  }

  Future<void> addToQueue(
    FileEntry track, {
    bool playNext = false,
    List<FileEntry>? directoryEntries,
    List<StorageMount>? mounts,
  }) async {
    await _initialLoad;
    if (mounts != null && directoryEntries != null) {
      registerDirectoryContext(mounts: mounts, directoryEntries: directoryEntries);
    }
    final existingIdx = _queue.indexWhere(
      (e) => e.path == track.path && e.mountId == track.mountId,
    );
    if (_queue.isEmpty || _currentIndex < 0) {
      _queue = [track];
      _currentIndex = 0;
      unawaited(_syncActivePlaylist());
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
      unawaited(_syncActivePlaylist());
      notifyListeners();
      return;
    }
    if (playNext) {
      final insertIdx = (_currentIndex + 1).clamp(0, _queue.length);
      _queue.insert(insertIdx, track);
    } else {
      _queue.add(track);
    }
    unawaited(_syncActivePlaylist());
    notifyListeners();
  }

  Future<void> playQueueIndex(int index) async {
    await _initialLoad;
    if (index < 0 || index >= _queue.length) return;
    final isSameTrack = index == _currentIndex;
    final idleDuration = DateTime.now().difference(_lastTrackOpenedAt);
    final isStaleOrRecovering = _needsFreshOpenAfterBackground ||
        _player == null ||
        _activeStreamUrl.isEmpty ||
        _errorText.isNotEmpty ||
        _isLoadingTrack ||
        (!_isPlaying &&
            (idleDuration > const Duration(seconds: 45) ||
                (_player?.state.completed ?? false) ||
                (_player?.state.duration ?? Duration.zero) == Duration.zero));
    if (isSameTrack && !isStaleOrRecovering) {
      await togglePlayPause();
      return;
    }
    final resumePos = (isSameTrack &&
            !_isPlaying &&
            _position.inSeconds > 2 &&
            (_duration == Duration.zero ||
                _position < _duration - const Duration(seconds: 3)))
        ? _position
        : null;
    _currentIndex = index;
    unawaited(_syncActivePlaylist());
    await _openCurrentTrack(
      forceRefreshUrl:
          isSameTrack ||
          _needsFreshOpenAfterBackground ||
          idleDuration > const Duration(seconds: 45),
      resumePosition: resumePos,
      resetPlayer:
          _needsFreshOpenAfterBackground ||
          (!_isPlaying && idleDuration > const Duration(minutes: 2)),
    );
  }

  Future<void> removeTrackAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    final removingCurrent = index == _currentIndex;
    _queue.removeAt(index);
    if (_queue.isEmpty) {
      await stopAndClose(clearPersistedQueue: true);
      return;
    }
    if (index < _currentIndex) {
      _currentIndex--;
    } else if (removingCurrent) {
      if (_currentIndex >= _queue.length) {
        _currentIndex = 0;
      }
      unawaited(_syncActivePlaylist());
      await _openCurrentTrack();
      return;
    }
    unawaited(_syncActivePlaylist());
    notifyListeners();
  }

  Future<void> _openCurrentTrack({
    bool forceRefreshUrl = false,
    Duration? resumePosition,
    bool resetPlayer = false,
    bool isRetry = false,
  }) async {
    await _initialLoad;
    final track = currentTrack;
    if (track == null) return;
    final now = DateTime.now();
    final longIdle =
        !_isPlaying &&
        _lastTrackOpenedAt.millisecondsSinceEpoch > 0 &&
        now.difference(_lastTrackOpenedAt) > const Duration(minutes: 2);
    if (_needsFreshOpenAfterBackground || resetPlayer || isRetry || longIdle) {
      _needsFreshOpenAfterBackground = false;
      forceRefreshUrl = true;
      Local115DirectService.instance.resetAfterBackground(
        clearCaches: forceRefreshUrl,
      );
      _resetPlayerInstance();
    }

    final seq = ++_openSeq;
    _openWatchdogTimer?.cancel();
    if (!forceRefreshUrl && !isRetry) {
      _retriedCurrentTrack = false;
    }

    _lastTrackOpenedAt = now;
    _lastLoadingStartedAt = now;
    _trackHasStartedPlaying = false;
    _lastSpeedFwBytes = 0.0;
    _lastSpeedBufferPos = Duration.zero;
    _pendingResumePosition = resumePosition;
    _isLoadingTrack = true;
    _isSessionDocked = true;
    _errorText = '';
    if (resumePosition == null) {
      _position = Duration.zero;
      _duration = Duration.zero;
    }
    _coverImageBytes = null;
    notifyListeners();
    _syncNativeMediaSession(force: true);

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
          endpointResolver: (e) =>
              resolveEntryEndpoint(e, forceRefreshUrl: forceRefreshUrl),
          forceRefresh: forceRefreshUrl,
        );
        if (seq != _openSeq) return;
        playUrl = extractedLocalPath;
        subtitle = '📦 ${track.archiveContainerName} · ${track.formattedSize}';
      } else {
        final resolved = await resolveEntryEndpoint(
          track,
          forceRefreshUrl: forceRefreshUrl,
        );
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

        final isRemoteHttpUrl =
            lowerUrl.startsWith('http://') || lowerUrl.startsWith('https://');
        if (isRemoteHttpUrl &&
            !lowerUrl.contains('.m3u8') &&
            track.sourceKind != StorageSourceKind.localCache &&
            (track.sourceKind == StorageSourceKind.cloud115 ||
                isLosslessNeedsExtensionProxy ||
                urlLacksAudioExtension ||
                playHeaders.isNotEmpty)) {
          final relayed =
              await Local115DirectService.instance.wrapWithLocal115HeaderProxy(
            playUrl,
            playHeaders,
            extHint: ext,
            forceRefresh: forceRefreshUrl,
          );
          if (relayed != playUrl) {
            playUrl = relayed;
            playHeaders = const {};
          }
        }
      }
      if (seq != _openSeq) return;

      _activeStreamUrl = playUrl;
      _activeSubtitle = subtitle;
      if (Platform.environment.containsKey('FLUTTER_TEST') && _player == null) {
        _isLoadingTrack = false;
        _isPlaying = true;
        _trackHasStartedPlaying = true;
        notifyListeners();
        return;
      }
      notifyListeners();

      _ensurePlayerInitialized();
      final isLocalRelay = playUrl.contains('://127.0.0.1:') ||
          playUrl.contains('://localhost:');
      await _configureMusicPlayer(_player!, isLocalRelay: isLocalRelay);
      if (seq != _openSeq) return;

      await _player!
          .open(
            Media(
              playUrl,
              httpHeaders: playHeaders,
              start: resumePosition,
            ),
            play: true,
          )
          .timeout(const Duration(seconds: 15));
      if (seq != _openSeq) return;
      if (_speed != 1.0) {
        await _player!.setRate(_speed).timeout(
              const Duration(seconds: 2),
              onTimeout: () {},
            );
      }
      if (_volume != 100.0) {
        await _player!.setVolume(_volume).timeout(
              const Duration(seconds: 2),
              onTimeout: () {},
            );
      }
      _openWatchdogTimer?.cancel();
      _openWatchdogTimer = Timer(const Duration(seconds: 8), () {
        if (seq != _openSeq || !_isLoadingTrack || _isPlaying) return;
        if (!_retriedCurrentTrack && currentTrack != null) {
          _retriedCurrentTrack = true;
          unawaited(
            _openCurrentTrack(
              forceRefreshUrl: true,
              resumePosition: resumePosition,
              resetPlayer: true,
              isRetry: true,
            ),
          );
        } else {
          _isLoadingTrack = false;
          notifyListeners();
        }
      });
    } catch (e) {
      if (seq != _openSeq) return;
      if (!isRetry && !_retriedCurrentTrack) {
        _retriedCurrentTrack = true;
        await _openCurrentTrack(
          forceRefreshUrl: true,
          resumePosition: resumePosition,
          resetPlayer: true,
          isRetry: true,
        );
        return;
      }
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
    _coverImageBytes = null;
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

    if (seq == _openSeq && _coverImageUrl != null && _coverImageUrl!.isNotEmpty) {
      await _fetchCoverBytesForLockScreen(
        urlOrPath: _coverImageUrl!,
        headers: _coverImageHeaders,
        isLocal: _coverIsLocalFile,
        seq: seq,
      );
    }

    // 1b. If no local/directory cover image was found, try extracting embedded cover art (ID3v2 APIC / FLAC METADATA_BLOCK_PICTURE)
    if (seq == _openSeq &&
        (_coverImageBytes == null || _coverImageBytes!.isEmpty)) {
      await _tryExtractEmbeddedCoverArt(track, seq);
    }

    // 1c. If still no cover image, search iTunes Search API by song title + artist for high-res 600x600 album cover!
    if (seq == _openSeq &&
        (_coverImageBytes == null || _coverImageBytes!.isEmpty)) {
      await _tryFetchOnlineCoverArtFromItunes(track, seq);
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
    if (Platform.environment.containsKey('FLUTTER_TEST')) return null;
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

  Future<void> _fetchCoverBytesForLockScreen({
    required String urlOrPath,
    required Map<String, String> headers,
    required bool isLocal,
    required int seq,
  }) async {
    try {
      Uint8List? bytes;
      if (isLocal) {
        final f = File(urlOrPath);
        if (await f.exists()) {
          final len = await f.length();
          if (len > 0 && len <= 4 * 1024 * 1024) {
            bytes = await f.readAsBytes();
          }
        }
      } else {
        final uri = Uri.tryParse(urlOrPath);
        if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
          final client = HttpClient()
            ..badCertificateCallback = (_, __, ___) => true;
          try {
            final req =
                await client.getUrl(uri).timeout(const Duration(seconds: 8));
            headers.forEach((k, v) {
              if (v.isNotEmpty) req.headers.set(k, v);
            });
            final resp = await req.close().timeout(const Duration(seconds: 8));
            if (resp.statusCode == 200 || resp.statusCode == 206) {
              final builder = BytesBuilder(copy: false);
              await for (final chunk in resp) {
                builder.add(chunk);
                if (builder.length > 4 * 1024 * 1024) break;
              }
              if (builder.length > 0 && builder.length <= 4 * 1024 * 1024) {
                bytes = builder.takeBytes();
              }
            }
          } finally {
            client.close(force: true);
          }
        }
      }
      if (seq == _openSeq && bytes != null && bytes.isNotEmpty) {
        _coverImageBytes = bytes;
        notifyListeners();
        _syncNativeMediaSession(force: true, includeCoverBytes: true);
      }
    } catch (_) {}
  }

  static final Map<String, String> _onlineCoverUrlCache = {};

  Future<void> _tryExtractEmbeddedCoverArt(FileEntry track, int seq) async {
    final ext = track.normalizedExt;
    if (!const {'.mp3', '.flac', '.m4a', '.aac', '.wav', '.aiff', '.aif'}
        .contains(ext)) {
      return;
    }
    try {
      Uint8List headerBytes = Uint8List(0);
      if (track.isInsideArchive) {
        final extractedPath =
            await CloudArchiveMusicService.instance.extractArchiveAudioToTempFile(
          entry: track,
          endpointResolver: resolveEntryEndpoint,
        );
        if (seq != _openSeq) return;
        final f = File(extractedPath);
        if (await f.exists()) {
          final raf = await f.open();
          try {
            final readLen = math.min(await f.length(), 384 * 1024);
            headerBytes = await raf.read(readLen);
          } finally {
            await raf.close();
          }
        }
      } else if (track.sourceKind == StorageSourceKind.localCache) {
        final f = File(track.path);
        if (await f.exists()) {
          final raf = await f.open();
          try {
            final readLen = math.min(await f.length(), 384 * 1024);
            headerBytes = await raf.read(readLen);
          } finally {
            await raf.close();
          }
        }
      } else {
        final resolved = await resolveEntryEndpoint(track);
        if (seq != _openSeq || resolved.url.isEmpty) return;
        final lowerResolved = resolved.url.toLowerCase();
        if (!lowerResolved.startsWith('http://') &&
            !lowerResolved.startsWith('https://')) {
          return;
        }
        // Wait briefly for the local audio proxy to cache the first 256 KB header
        // so we never open a competing HTTP Range connection against 115 CDN / AList
        for (int poll = 0; poll < 12; poll++) {
          if (seq != _openSeq) return;
          final cached = Local115DirectService.instance
              .getCachedRawHeaderBytes(resolved.url);
          if (cached != null && cached.isNotEmpty) {
            headerBytes = cached;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 220));
        }
        if (seq != _openSeq) return;
        if (headerBytes.isEmpty &&
            track.sourceKind != StorageSourceKind.cloud115) {
          final uri = Uri.tryParse(resolved.url);
          if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
            final rangeRes = await CloudArchiveMusicService.instance
                ._fetchRemoteRangeWithTotal(
              uri: uri,
              headers: resolved.headers,
              start: 0,
              end: 256 * 1024 - 1,
            );
            headerBytes = rangeRes.bytes;
          }
        }
      }
      if (seq != _openSeq || headerBytes.length < 32) return;
      final picBytes = _extractCoverImageFromAudioHeaderBytes(headerBytes);
      if (picBytes != null && picBytes.length > 128 && seq == _openSeq) {
        _coverImageBytes = picBytes;
        notifyListeners();
        _syncNativeMediaSession(force: true, includeCoverBytes: true);
      }
    } catch (_) {}
  }

  static Uint8List? _extractCoverImageFromAudioHeaderBytes(Uint8List data) {
    // 1. Check FLAC `fLaC` magic and `METADATA_BLOCK_PICTURE` (block type 6)
    if (data.length > 42 &&
        data[0] == 0x66 &&
        data[1] == 0x4C &&
        data[2] == 0x61 &&
        data[3] == 0x43) {
      int pos = 4;
      while (pos + 4 <= data.length) {
        final headerByte = data[pos];
        final isLast = (headerByte & 0x80) != 0;
        final blockType = headerByte & 0x7F;
        final blockLen =
            (data[pos + 1] << 16) | (data[pos + 2] << 8) | data[pos + 3];
        pos += 4;
        if (pos + blockLen > data.length) break;
        if (blockType == 6 && blockLen > 32) {
          int p = pos;
          p += 4; // picture type
          if (p + 4 > pos + blockLen) break;
          final mimeLen =
              (data[p] << 24) | (data[p + 1] << 16) | (data[p + 2] << 8) | data[p + 3];
          p += 4 + mimeLen;
          if (p + 4 > pos + blockLen) break;
          final descLen =
              (data[p] << 24) | (data[p + 1] << 16) | (data[p + 2] << 8) | data[p + 3];
          p += 4 + descLen;
          p += 16; // width, height, depth, colors
          if (p + 4 > pos + blockLen) break;
          final picLen =
              (data[p] << 24) | (data[p + 1] << 16) | (data[p + 2] << 8) | data[p + 3];
          p += 4;
          if (picLen > 64 && p + picLen <= pos + blockLen) {
            return Uint8List.sublistView(data, p, p + picLen);
          }
        }
        pos += blockLen;
        if (isLast) break;
      }
    }

    // 2. If starts with standard RIFF....WAVE, bound the scan to chunks before the raw PCM `data` chunk
    int scanLimit = data.length;
    if (data.length >= 44 &&
        data[0] == 0x52 &&
        data[1] == 0x49 &&
        data[2] == 0x46 &&
        data[3] == 0x46 &&
        data[8] == 0x57 &&
        data[9] == 0x41 &&
        data[10] == 0x56 &&
        data[11] == 0x45) {
      int pos = 12;
      while (pos + 8 <= data.length) {
        final c0 = data[pos];
        final c1 = data[pos + 1];
        final c2 = data[pos + 2];
        final c3 = data[pos + 3];
        final cSize = data[pos + 4] |
            (data[pos + 5] << 8) |
            (data[pos + 6] << 16) |
            (data[pos + 7] << 24);
        if (c0 == 0x64 && c1 == 0x61 && c2 == 0x74 && c3 == 0x61) {
          // Reached raw PCM `data` chunk
          scanLimit = pos;
          break;
        }
        if (cSize < 0 || cSize > data.length) break;
        pos += 8 + cSize + (cSize.isOdd ? 1 : 0);
      }
    }

    // 3. Scan for embedded JPEG (`FF D8 FF E0` / `FF D8 FF E1`) or PNG (`89 50 4E 47 0D 0A 1A 0A`) inside ID3v2 / MP4 `covr` atom
    for (int i = 0; i + 16 < scanLimit; i++) {
      // PNG signature
      if (data[i] == 0x89 &&
          data[i + 1] == 0x50 &&
          data[i + 2] == 0x4E &&
          data[i + 3] == 0x47 &&
          data[i + 4] == 0x0D &&
          data[i + 5] == 0x0A &&
          data[i + 6] == 0x1A &&
          data[i + 7] == 0x0A) {
        // Find PNG IEND (`49 45 4E 44 AE 42 60 82`)
        for (int j = i + 32; j + 8 <= scanLimit; j++) {
          if (data[j] == 0x49 &&
              data[j + 1] == 0x45 &&
              data[j + 2] == 0x4E &&
              data[j + 3] == 0x44) {
            final endIdx = math.min(scanLimit, j + 8);
            if (endIdx - i > 256) {
              return Uint8List.sublistView(data, i, endIdx);
            }
            break;
          }
        }
      }
      // JPEG signature (`FF D8 FF E0` or `FF D8 FF E1` or `FF D8 FF DB`)
      if (data[i] == 0xFF &&
          data[i + 1] == 0xD8 &&
          data[i + 2] == 0xFF &&
          (data[i + 3] == 0xE0 || data[i + 3] == 0xE1 || data[i + 3] == 0xDB)) {
        // Find JPEG EOI (`FF D9`)
        for (int j = i + 256; j + 2 <= scanLimit; j++) {
          if (data[j] == 0xFF && data[j + 1] == 0xD9) {
            final endIdx = j + 2;
            if (endIdx - i > 512) {
              return Uint8List.sublistView(data, i, endIdx);
            }
          }
        }
      }
    }
    return null;
  }

  Future<void> _tryFetchOnlineCoverArtFromItunes(
    FileEntry track,
    int seq,
  ) async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    final meta = parseTrackMetadata(track);
    final cleanTitle = meta.title
        .replaceAll(RegExp(r'\(.*?\)|\[.*?\]|【.*?】'), ' ')
        .trim();
    if (cleanTitle.isEmpty) return;
    final cleanArtist = (!meta.artist.contains('115') &&
            !meta.artist.contains('AList') &&
            !meta.artist.contains('WebDAV') &&
            !meta.artist.contains('服务端') &&
            !meta.artist.endsWith('.zip') &&
            !meta.artist.endsWith('.tar'))
        ? meta.artist
            .replaceAll(RegExp(r'\(.*?\)|\[.*?\]|【.*?】'), ' ')
            .trim()
        : '';
    final query =
        cleanArtist.isNotEmpty ? '$cleanArtist $cleanTitle' : cleanTitle;

    String? artworkUrl = _onlineCoverUrlCache[query];
    if (artworkUrl == null) {
      final uri = Uri.parse(
        'https://itunes.apple.com/search?term=${Uri.encodeQueryComponent(query)}&media=music&entity=song&limit=3',
      );
      final client = HttpClient()
        ..badCertificateCallback = (_, __, ___) => true;
      try {
        final req =
            await client.getUrl(uri).timeout(const Duration(seconds: 6));
        req.headers.set('User-Agent', 'LiuguangMusicPlayer/1.2.2');
        final resp = await req.close().timeout(const Duration(seconds: 6));
        if (resp.statusCode == 200) {
          final body = await resp.transform(utf8.decoder).join();
          final decoded = jsonDecode(body);
          if (decoded is Map<String, dynamic>) {
            final results = decoded['results'];
            if (results is List && results.isNotEmpty) {
              for (final item in results) {
                if (item is Map<String, dynamic>) {
                  final rawArt = (item['artworkUrl100'] ?? '').toString().trim();
                  if (rawArt.isNotEmpty) {
                    artworkUrl = rawArt.replaceAll('100x100bb', '600x600bb');
                    break;
                  }
                }
              }
            }
          }
        }
      } catch (_) {
      } finally {
        client.close(force: true);
      }
      if (artworkUrl != null && artworkUrl.isNotEmpty) {
        if (_onlineCoverUrlCache.length > 1000) {
          _onlineCoverUrlCache.clear();
        }
        _onlineCoverUrlCache[query] = artworkUrl;
      }
    }

    if (seq != _openSeq || artworkUrl == null || artworkUrl.isEmpty) return;
    _coverImageUrl = artworkUrl;
    _coverImageHeaders = const {};
    _coverIsLocalFile = false;
    notifyListeners();
    await _fetchCoverBytesForLockScreen(
      urlOrPath: artworkUrl,
      headers: const {},
      isLocal: false,
      seq: seq,
    );
  }

  Future<void> togglePlayPause() async {
    await _initialLoad;
    if (currentTrack == null) {
      if (_queue.isNotEmpty) {
        _currentIndex = _currentIndex.clamp(0, _queue.length - 1);
        await _openCurrentTrack(forceRefreshUrl: true);
      }
      return;
    }
    if (_isLoadingTrack) {
      if (DateTime.now().difference(_lastLoadingStartedAt) <
          const Duration(seconds: 3)) {
        return;
      }
      await _openCurrentTrack(forceRefreshUrl: true, resetPlayer: true);
      return;
    }

    if (_isPlaying && (_player?.state.playing ?? false)) {
      await _player!.pause();
      _isPlaying = false;
      notifyListeners();
      _syncNativeMediaSession(force: true);
      return;
    }

    final idleDuration = _lastTrackOpenedAt.millisecondsSinceEpoch > 0
        ? DateTime.now().difference(_lastTrackOpenedAt)
        : Duration.zero;
    final resumePos = (_position.inSeconds > 2 &&
            (_duration == Duration.zero ||
                _position < _duration - const Duration(seconds: 3)))
        ? _position
        : null;
    final isStaleStream = _needsFreshOpenAfterBackground ||
        _errorText.isNotEmpty ||
        _player == null ||
        _activeStreamUrl.isEmpty ||
        (_player?.state.completed ?? false) ||
        (_player?.state.duration ?? Duration.zero) == Duration.zero ||
        idleDuration > const Duration(minutes: 2);
    if (isStaleStream) {
      await _openCurrentTrack(
        forceRefreshUrl: true,
        resumePosition: resumePos,
        resetPlayer: _needsFreshOpenAfterBackground ||
            idleDuration > const Duration(minutes: 2),
      );
      return;
    }

    final seq = _openSeq;
    try {
      await _player!.play();
      _syncNativeMediaSession(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (seq == _openSeq &&
          !(_player?.state.playing ?? false) &&
          !_isPlaying &&
          currentTrack != null) {
        await _openCurrentTrack(
          forceRefreshUrl: true,
          resumePosition: resumePos,
          resetPlayer: true,
        );
      }
    } catch (_) {
      if (seq == _openSeq && currentTrack != null) {
        await _openCurrentTrack(
          forceRefreshUrl: true,
          resumePosition: resumePos,
          resetPlayer: true,
        );
      }
    }
  }

  Future<void> seekTo(Duration target) async {
    if (_player == null) return;
    _position = target;
    notifyListeners();
    await _player!.seek(target);
    _syncNativeMediaSession(force: true);
  }

  Future<void> seekRelative(Duration delta) async {
    if (_player == null) return;
    final maxMs = _duration.inMilliseconds > 0 ? _duration.inMilliseconds : 86400000;
    final nextMs = (_position.inMilliseconds + delta.inMilliseconds).clamp(0, maxMs);
    await seekTo(Duration(milliseconds: nextMs));
  }

  Future<void> stepTrack(int delta) async {
    await _initialLoad;
    if (_queue.isEmpty) return;
    if (delta < 0 && _position.inSeconds >= 5 && _isPlaying) {
      await seekTo(Duration.zero);
      return;
    }
    if (_queue.length == 1) {
      _currentIndex = 0;
      if (_needsFreshOpenAfterBackground ||
          _player == null ||
          _activeStreamUrl.isEmpty ||
          _errorText.isNotEmpty) {
        await _openCurrentTrack(forceRefreshUrl: true);
      } else {
        await seekTo(Duration.zero);
        await _player?.play();
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
    } else {
      _currentIndex = (_currentIndex + delta + _queue.length) % _queue.length;
    }
    unawaited(_syncActivePlaylist());
    await _openCurrentTrack(forceRefreshUrl: _needsFreshOpenAfterBackground);
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
        unawaited(_syncActivePlaylist());
        await _openCurrentTrack();
      } else if (_currentIndex + 1 < _queue.length) {
        _currentIndex++;
        unawaited(_syncActivePlaylist());
        await _openCurrentTrack();
      } else if (_playMode == 'repeatAll') {
        _currentIndex = 0;
        unawaited(_syncActivePlaylist());
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
    _syncNativeMediaSession(force: true);
  }

  void setVolume(double v) {
    _volume = v.clamp(0.0, 100.0);
    _player?.setVolume(_volume);
    notifyListeners();
  }

  void _cancelFolderScan() {
    _scanSeq++;
    _isScanningFolders = false;
    _scanningStatusText = '';
  }

  Future<void> stopAndClose({bool clearPersistedQueue = false}) async {
    _openSeq++;
    _openWatchdogTimer?.cancel();
    _cancelFolderScan();
    final shouldStopPlayer =
        _isPlaying || _isLoadingTrack || _activeStreamUrl.isNotEmpty;
    final stopped = shouldStopPlayer
        ? _player
            ?.stop()
            .timeout(const Duration(seconds: 2), onTimeout: () {})
            .catchError((_) {})
        : null;
    if (clearPersistedQueue) {
      _queue = [];
      _currentIndex = -1;
      _currentQueueSources = [];
    }
    _isPlaying = false;
    _isLoadingTrack = false;
    _isSessionDocked = false;
    _smoothedSpeedBytesPerSec = 0.0;
    GlobalSpeedTracker.instance.unregister(this);
    _trackHasStartedPlaying = false;
    _pendingResumePosition = null;
    _errorText = '';
    _position = Duration.zero;
    _duration = Duration.zero;
    _lyrics = const [];
    _lyricsSourceLabel = '';
    _isLoadingLyrics = false;
    _coverImageUrl = null;
    _coverImageBytes = null;
    _activeStreamUrl = '';
    _activeSubtitle = '';
    final persisted = clearPersistedQueue ? _syncActivePlaylist() : null;
    notifyListeners();
    unawaited(_clearNativeMediaSession());
    await stopped;
    await persisted;
  }

  Future<void> clearCurrentPlaylistQueue() =>
      stopAndClose(clearPersistedQueue: true);
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
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  bool _isLoading = false;
  String? _error;
  bool _includeSubfolders = true;

  final List<SavedMusicFolderItem> _selectedItems = [];

  CloudMusicController get _ctrl => widget.controller;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<FileEntry> get _filteredEntries {
    final kw = _searchQuery.trim().toLowerCase();
    if (kw.isEmpty) return _entries;
    return _entries.where((e) => e.name.toLowerCase().contains(kw)).toList();
  }

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
      _searchQuery = '';
      _searchCtrl.clear();
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
      var list = await _ctrl.listDirectoryForMount(mount, path);
      if (!mounted) return;
      list = list
          .where((e) => e.isDir || e.isAudio || e.isStreamableMusicArchive)
          .toList();
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
    final dirCount = _entries.where((e) => e.isDir).length;
    final audioInCurrentDir = _entries.where((e) => !e.isDir && e.isAudio).length;
    final archivesInCurrentDir =
        _entries.where((e) => !e.isDir && e.isStreamableMusicArchive).length;
    final filteredEntries = _filteredEntries;
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
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
                    Text(
                      '共 ${_entries.length} 项（$dirCount 个文件夹 · $archivesInCurrentDir 个压缩包 · $audioInCurrentDir 首音频）',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: VideoPlatformTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '刷新当前目录',
                onPressed: () => _loadDir(
                  _currentPath,
                  title: _currentTitle,
                  pushCrumb: false,
                ),
                icon: const Icon(Icons.refresh_rounded, size: 18),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
          content: SizedBox(
            width: 980,
            height: isMobile
                ? (screenSize.height * 0.72).clamp(360.0, 620.0)
                : (screenSize.height * 0.72).clamp(520.0, 680.0),
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
                          child: StatefulBuilder(
                            builder: (mCtx, setMState) {
                              final isSelected = activeMount?.id == m.id;
                              return InkWell(
                                borderRadius: BorderRadius.circular(18),
                                onFocusChange: (_) {
                                  if (mCtx.mounted) setMState(() {});
                                },
                                onTap: () => _selectMount(m),
                                child: Builder(
                                  builder: (ctx) {
                                    final isFocused =
                                        Focus.of(ctx).hasPrimaryFocus;
                                    return AnimatedContainer(
                                      duration:
                                          const Duration(milliseconds: 140),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isSelected
                                            ? (isFocused
                                                ? VideoPlatformTheme.accentHover
                                                : VideoPlatformTheme.accent)
                                            : (isFocused
                                                ? VideoPlatformTheme.accent
                                                    .withValues(alpha: 0.34)
                                                : VideoPlatformTheme.bgCard),
                                        borderRadius: BorderRadius.circular(18),
                                        border: Border.all(
                                          color: isFocused
                                              ? const Color(0xFFFFE066)
                                              : (isSelected
                                                  ? VideoPlatformTheme.accent
                                                  : VideoPlatformTheme
                                                      .borderSubtle),
                                          width: isFocused ? 2.4 : 1.0,
                                        ),
                                        boxShadow: isFocused
                                            ? [
                                                BoxShadow(
                                                  color: VideoPlatformTheme
                                                      .accent
                                                      .withValues(alpha: 0.55),
                                                  blurRadius: 10,
                                                  spreadRadius: 1,
                                                ),
                                              ]
                                            : null,
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            switch (m.kind) {
                                              StorageSourceKind.server =>
                                                Icons.dns_rounded,
                                              StorageSourceKind.alist =>
                                                Icons.cloud_circle_rounded,
                                              StorageSourceKind.webdav =>
                                                Icons.language_rounded,
                                              StorageSourceKind.cloud115 =>
                                                Icons.cloud_done_rounded,
                                              StorageSourceKind.localCache =>
                                                Icons.folder_special_rounded,
                                            },
                                            size: 14,
                                            color: (isSelected || isFocused)
                                                ? Colors.white
                                                : VideoPlatformTheme.accent,
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            m.name,
                                            style: TextStyle(
                                              fontSize: 12.5,
                                              fontWeight:
                                                  (isSelected || isFocused)
                                                      ? FontWeight.w700
                                                      : FontWeight.w500,
                                              color: (isSelected || isFocused)
                                                  ? Colors.white
                                                  : VideoPlatformTheme
                                                      .textPrimary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              );
                            },
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
                                    StatefulBuilder(
                                      builder: (crumbCtx, setCrumbState) {
                                        return InkWell(
                                          borderRadius:
                                              BorderRadius.circular(5),
                                          onFocusChange: (_) {
                                            if (crumbCtx.mounted) {
                                              setCrumbState(() {});
                                            }
                                          },
                                          onTap: () => _loadDir(
                                            _breadcrumbs[i].path,
                                            title: _breadcrumbs[i].title,
                                          ),
                                          child: Builder(
                                            builder: (ctx) {
                                              final isFocused =
                                                  Focus.of(ctx).hasPrimaryFocus;
                                              return Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 6,
                                                  vertical: 2,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: isFocused
                                                      ? VideoPlatformTheme
                                                          .accent
                                                          .withValues(
                                                              alpha: 0.34)
                                                      : Colors.transparent,
                                                  borderRadius:
                                                      BorderRadius.circular(5),
                                                  border: isFocused
                                                      ? Border.all(
                                                          color: const Color(
                                                            0xFFFFE066,
                                                          ),
                                                          width: 1.8,
                                                        )
                                                      : null,
                                                ),
                                                child: Text(
                                                  _breadcrumbs[i].title,
                                                  style: TextStyle(
                                                    fontSize: 12.5,
                                                    fontWeight: (i ==
                                                                _breadcrumbs
                                                                        .length -
                                                                    1 ||
                                                            isFocused)
                                                        ? FontWeight.w700
                                                        : FontWeight.w400,
                                                    color: isFocused
                                                        ? Colors.white
                                                        : (i ==
                                                                _breadcrumbs
                                                                        .length -
                                                                    1
                                                            ? VideoPlatformTheme
                                                                .accent
                                                            : VideoPlatformTheme
                                                                .textSecondary),
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          if (!isMobile && activeMount != null) ...[
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 185,
                              height: 28,
                              child: TextField(
                                controller: _searchCtrl,
                                onChanged: (v) =>
                                    setState(() => _searchQuery = v),
                                style: const TextStyle(fontSize: 12),
                                decoration: InputDecoration(
                                  hintText: '快速筛选文件夹或音乐...',
                                  prefixIcon: const Icon(
                                    Icons.search_rounded,
                                    size: 15,
                                  ),
                                  suffixIcon: _searchQuery.isNotEmpty
                                      ? IconButton(
                                          icon: const Icon(
                                            Icons.clear_rounded,
                                            size: 13,
                                          ),
                                          onPressed: () {
                                            _searchCtrl.clear();
                                            setState(() => _searchQuery = '');
                                          },
                                        )
                                      : null,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
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
                            OutlinedButton.icon(
                              onPressed: () =>
                                  _toggleSelection(_currentDirectoryAsItem()),
                              icon: Icon(
                                _isSelected(activeMount.id, _currentPath)
                                    ? Icons.check_box_rounded
                                    : Icons.add_box_outlined,
                                size: 15,
                                color: _isSelected(activeMount.id, _currentPath)
                                    ? VideoPlatformTheme.accent
                                    : null,
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
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            SizedBox(
                              width: 150,
                              height: 28,
                              child: TextField(
                                controller: _searchCtrl,
                                onChanged: (v) =>
                                    setState(() => _searchQuery = v),
                                style: const TextStyle(fontSize: 11.5),
                                decoration: InputDecoration(
                                  hintText: '筛选目录/音乐...',
                                  prefixIcon: const Icon(
                                    Icons.search_rounded,
                                    size: 14,
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                              ),
                            ),
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
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(
                                  color: VideoPlatformTheme.accent,
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  '正在完整加载目录与全部分页文件夹...',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: VideoPlatformTheme.textSecondary,
                                  ),
                                ),
                              ],
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
                            : (filteredEntries.isEmpty
                                ? Center(
                                    child: Text(
                                      _searchQuery.isEmpty
                                          ? '当前目录下暂无子文件夹或音频文件'
                                          : '未找到匹配「$_searchQuery」的文件夹或音频',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: VideoPlatformTheme.textMuted,
                                      ),
                                    ),
                                  )
                                : ListView.separated(
                                    padding: const EdgeInsets.all(6),
                                    itemCount: filteredEntries.length,
                                    separatorBuilder: (_, __) => Divider(
                                      height: 1,
                                      color: VideoPlatformTheme.borderSubtle,
                                    ),
                                    itemBuilder: (context, idx) {
                                      final e = filteredEntries[idx];
                                  final isSelectable = e.isDir ||
                                      e.isStreamableMusicArchive ||
                                      e.isAudio;
                                  final checked = activeMount != null &&
                                      _isSelected(activeMount.id, e.path);
                                  final audioMeta = e.isAudio
                                      ? CloudMusicController.parseTrackMetadata(
                                          e,
                                          fallbackArtist: _breadcrumbs.isNotEmpty
                                              ? _breadcrumbs.last.title
                                              : '',
                                        )
                                      : null;

                                  return StatefulBuilder(
                                    builder: (rowCtx, setRowState) {
                                      return Focus(
                                        canRequestFocus: false,
                                        onFocusChange: (_) {
                                          if (rowCtx.mounted) setRowState(() {});
                                        },
                                        child: Builder(
                                          builder: (ctx) {
                                            final isFocused =
                                                Focus.of(ctx).hasFocus;
                                            return Container(
                                              decoration: BoxDecoration(
                                                color: isFocused
                                                    ? VideoPlatformTheme.accent
                                                        .withValues(alpha: 0.24)
                                                    : (checked
                                                        ? VideoPlatformTheme
                                                            .accent
                                                            .withValues(
                                                                alpha: 0.14)
                                                        : Colors.transparent),
                                                borderRadius:
                                                    BorderRadius.circular(8),
                  border: Border.all(
                    color: isFocused
                        ? const Color(0xFFFFE066)
                        : (checked
                            ? VideoPlatformTheme.accent
                            : Colors.transparent),
                    width: 1.2,
                  ),
                                              ),
                                              child: ListTile(
                                                dense: true,
                                                autofocus: idx == 0,
                                                focusColor: VideoPlatformTheme
                                                    .accent
                                                    .withValues(alpha: 0.28),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                ),
                                                contentPadding:
                                                    EdgeInsets.symmetric(
                                                  horizontal: isMobile ? 8 : 12,
                                                ),
                                                leading: Icon(
                                                  e.isDir
                                                      ? Icons.folder_rounded
                                                      : (e.isStreamableMusicArchive
                                                          ? Icons
                                                              .folder_zip_rounded
                                                          : (e.isAudio
                                                              ? Icons
                                                                  .audiotrack_rounded
                                                              : Icons
                                                                  .insert_drive_file_outlined)),
                                                  color: e.isDir
                                                      ? VideoPlatformTheme
                                                          .warning
                                                      : (e.isStreamableMusicArchive
                                                          ? VideoPlatformTheme
                                                              .badgeHot
                                                          : (e.isAudio
                                                              ? VideoPlatformTheme
                                                                  .accent
                                                              : VideoPlatformTheme
                                                                  .textMuted)),
                                                ),
                                                title: Text(
                                                  audioMeta != null
                                                      ? audioMeta.title
                                                      : e.name,
                                                  maxLines: e.isDir ? 2 : 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: (isFocused ||
                                                            checked)
                                                        ? FontWeight.w700
                                                        : FontWeight.w600,
                                                    color: isFocused
                                                        ? Colors.white
                                                        : VideoPlatformTheme
                                                            .textPrimary,
                                                  ),
                                                ),
                                                subtitle: Text(
                                                  e.isDir
                                                      ? '文件夹 · 点击进入，右侧可勾选随机播放'
                                                      : (e.isStreamableMusicArchive
                                                          ? '压缩包 (${e.formattedSize}) · 免整包下载直读音乐'
                                                          : '${audioMeta != null && audioMeta.artist.isNotEmpty ? "${audioMeta.artist} · " : ""}${audioMeta?.qualityTag ?? e.typeTagText} · ${e.formattedSize}'),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: isFocused
                                                        ? Colors.white70
                                                        : VideoPlatformTheme
                                                            .textMuted,
                                                  ),
                                                ),
                                                onTap: () {
                                                  if (e.isDir) {
                                                    _loadDir(
                                                      e.path,
                                                      title: e.name,
                                                    );
                                                  } else if (isSelectable &&
                                                      activeMount != null) {
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
                                                  }
                                                },
                                                trailing: (isSelectable &&
                                                        activeMount != null)
                                                    ? Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          if (e.isDir ||
                                                              e.isStreamableMusicArchive)
                                                            IconButton(
                                                              visualDensity:
                                                                  VisualDensity
                                                                      .compact,
                                                              tooltip: '加入常用音乐源',
                                                              onPressed: () {
                                                                _ctrl.addOrToggleSavedMusicFolder(
                                                                  SavedMusicFolderItem(
                                                                    mountId:
                                                                        activeMount
                                                                            .id,
                                                                    mountName:
                                                                        activeMount
                                                                            .name,
                                                                    sourceKind:
                                                                        activeMount
                                                                            .kind,
                                                                    path:
                                                                        e.path,
                                                                    title:
                                                                        e.name,
                                                                    isArchive: e
                                                                        .isStreamableMusicArchive,
                                                                    size:
                                                                        e.size,
                                                                    pickcode115:
                                                                        e.pickcode115,
                                                                  ),
                                                                );
                                                                setState(() {});
                                                              },
                                                              icon: Icon(
                                                                _ctrl.isMusicFolderSaved(
                                                                  activeMount
                                                                      .id,
                                                                  e.path,
                                                                )
                                                                    ? Icons
                                                                        .star_rounded
                                                                    : Icons
                                                                        .star_border_rounded,
                                                                size: 18,
                                                                color: VideoPlatformTheme
                                                                    .warning,
                                                              ),
                                                            ),
                                                          Checkbox(
                                                            visualDensity:
                                                                VisualDensity
                                                                    .compact,
                                                            value: checked,
                                                            activeColor:
                                                                VideoPlatformTheme
                                                                    .accent,
                                                            onChanged: (_) {
                                                              _toggleSelection(
                                                                SavedMusicFolderItem(
                                                                  mountId:
                                                                      activeMount
                                                                          .id,
                                                                  mountName:
                                                                      activeMount
                                                                          .name,
                                                                  sourceKind:
                                                                      activeMount
                                                                          .kind,
                                                                  path: e.path,
                                                                  title: e.name,
                                                                  isArchive: e
                                                                      .isStreamableMusicArchive,
                                                                  size: e.size,
                                                                  pickcode115: e
                                                                      .pickcode115,
                                                                ),
                                                              );
                                                            },
                                                          ),
                                                        ],
                                                      )
                                                    : null,
                                              ),
                                            );
                                          },
                                        ),
                                      );
                                    },
                                  );
                                },
                              ))),
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
                    StatefulBuilder(
                      builder: (recCtx, setRecState) {
                        return InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onFocusChange: (_) {
                            if (recCtx.mounted) setRecState(() {});
                          },
                          onTap: () => setState(
                            () => _includeSubfolders = !_includeSubfolders,
                          ),
                          child: Builder(
                            builder: (ctx) {
                              final isFocused = Focus.of(ctx).hasPrimaryFocus;
                              return Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: isFocused
                                      ? VideoPlatformTheme.accent
                                          .withValues(alpha: 0.28)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(6),
                                  border: isFocused
                                      ? Border.all(
                                          color: const Color(0xFFFFE066),
                                          width: 1.8,
                                        )
                                      : null,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: ExcludeFocus(
                                        child: Checkbox(
                                          visualDensity: VisualDensity.compact,
                                          value: _includeSubfolders,
                                          activeColor:
                                              VideoPlatformTheme.accent,
                                          onChanged: (v) => setState(
                                            () =>
                                                _includeSubfolders = v ?? true,
                                          ),
                                        ),
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
                                          fontWeight: isFocused
                                              ? FontWeight.w700
                                              : FontWeight.w400,
                                          color: isFocused
                                              ? Colors.white
                                              : VideoPlatformTheme
                                                  .textSecondary,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        );
                      },
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
          actions: isMobile
              ? [
                  SizedBox(
                    width: double.infinity,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 8,
                                  ),
                                ),
                                onPressed: () async {
                                  final targets = _selectedItems.isNotEmpty
                                      ? List<SavedMusicFolderItem>.from(
                                          _selectedItems,
                                        )
                                      : (_activeMount != null
                                          ? [_currentDirectoryAsItem()]
                                          : const <SavedMusicFolderItem>[]);
                                  if (targets.isEmpty) return;
                                  Navigator.of(context).pop();
                                  await showDialog<void>(
                                    context: context,
                                    builder: (_) =>
                                        CloudMusicSmartPlaylistDialog(
                                      controller: _ctrl,
                                      initialSources: targets,
                                      initialTab: 0,
                                      initialIncludeSubfolders:
                                          _includeSubfolders,
                                    ),
                                  );
                                },
                                icon: const Icon(
                                  Icons.manage_search_rounded,
                                  size: 15,
                                ),
                                label: const Text(
                                  '搜人名/关键词建表',
                                  style: TextStyle(fontSize: 11.5),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 8,
                                  ),
                                ),
                                onPressed: () async {
                                  final targets = _selectedItems.isNotEmpty
                                      ? List<SavedMusicFolderItem>.from(
                                          _selectedItems,
                                        )
                                      : (_activeMount != null
                                          ? [_currentDirectoryAsItem()]
                                          : const <SavedMusicFolderItem>[]);
                                  if (targets.isEmpty) return;
                                  Navigator.of(context).pop();
                                  await showDialog<void>(
                                    context: context,
                                    builder: (_) =>
                                        CloudMusicSmartPlaylistDialog(
                                      controller: _ctrl,
                                      initialSources: targets,
                                      initialTab: 1,
                                      initialIncludeSubfolders:
                                          _includeSubfolders,
                                    ),
                                  );
                                },
                                icon: const Icon(
                                  Icons.auto_awesome_rounded,
                                  size: 15,
                                ),
                                label: const Text(
                                  'AI 分类建表',
                                  style: TextStyle(fontSize: 11.5),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            if (_breadcrumbs.length >= 2) ...[
                              TextButton.icon(
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                ),
                                onPressed: _stepBackFolderIfPossible,
                                icon: const Icon(
                                  Icons.arrow_back_rounded,
                                  size: 14,
                                ),
                                label: const Text(
                                  '上级',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                              const SizedBox(width: 4),
                            ],
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 8,
                                  ),
                                ),
                                onPressed: () async {
                                  final targets = _selectedItems.isNotEmpty
                                      ? List<SavedMusicFolderItem>.from(
                                          _selectedItems,
                                        )
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
                                icon: const Icon(
                                  Icons.play_arrow_rounded,
                                  size: 15,
                                ),
                                label: const Text(
                                  '顺序播放',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 8,
                                  ),
                                ),
                                onPressed: () async {
                                  final targets = _selectedItems.isNotEmpty
                                      ? List<SavedMusicFolderItem>.from(
                                          _selectedItems,
                                        )
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
                                icon: const Icon(
                                  Icons.shuffle_rounded,
                                  size: 15,
                                ),
                                label: Text(
                                  _selectedItems.isEmpty
                                      ? '随机播放当前目录'
                                      : '随机播放 (${_selectedItems.length})',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ]
              : [
                  if (_breadcrumbs.length >= 2)
                    TextButton.icon(
                      onPressed: _stepBackFolderIfPossible,
                      icon: const Icon(Icons.arrow_back_rounded, size: 15),
                      label: const Text('返回上级目录'),
                    ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('关闭窗口'),
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
                      await showDialog<void>(
                        context: context,
                        builder: (_) => CloudMusicSmartPlaylistDialog(
                          controller: _ctrl,
                          initialSources: targets,
                          initialTab: 0,
                          initialIncludeSubfolders: _includeSubfolders,
                        ),
                      );
                    },
                    icon: const Icon(Icons.manage_search_rounded, size: 16),
                    label: const Text('查找人名/关键词新建列表'),
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
                      await showDialog<void>(
                        context: context,
                        builder: (_) => CloudMusicSmartPlaylistDialog(
                          controller: _ctrl,
                          initialSources: targets,
                          initialTab: 1,
                          initialIncludeSubfolders: _includeSubfolders,
                        ),
                      );
                    },
                    icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                    label: const Text('AI 分析自动生成列表'),
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
                    label: const Text('顺序播放所选'),
                  ),
                  FilledButton.icon(
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
                          ? '随机播放当前目录全部音乐'
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
                                return StatefulBuilder(
                                  builder: (arcRowCtx, setArcRowState) {
                                    return Focus(
                                      canRequestFocus: false,
                                      onFocusChange: (_) {
                                        if (arcRowCtx.mounted) {
                                          setArcRowState(() {});
                                        }
                                      },
                                      child: Builder(
                                        builder: (ctx) {
                                          final isFocused =
                                              Focus.of(ctx).hasFocus;
                                          return Container(
                                            decoration: BoxDecoration(
                                              color: isFocused
                                                  ? VideoPlatformTheme.accent
                                                      .withValues(alpha: 0.24)
                                                  : Colors.transparent,
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              border: isFocused
                                                  ? Border.all(
                                                      color: const Color(
                                                        0xFFFFE066,
                                                      ),
                                                      width: 2.2,
                                                    )
                                                  : null,
                                            ),
                                            child: ListTile(
                                              dense: true,
                                              autofocus: idx == 0,
                                              focusColor: VideoPlatformTheme
                                                  .accent
                                                  .withValues(alpha: 0.28),
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                              leading: CircleAvatar(
                                                radius: 14,
                                                backgroundColor:
                                                    VideoPlatformTheme.accent
                                                        .withValues(alpha: 0.2),
                                                child: Text(
                                                  '${idx + 1}',
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: isFocused
                                                        ? Colors.white
                                                        : VideoPlatformTheme
                                                            .accent,
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
                                                  fontWeight: isFocused
                                                      ? FontWeight.w700
                                                      : FontWeight.w600,
                                                  color: isFocused
                                                      ? Colors.white
                                                      : VideoPlatformTheme
                                                          .textPrimary,
                                                ),
                                              ),
                                              subtitle: Text(
                                                '${meta.artist.isNotEmpty ? "${meta.artist} · " : ""}${track.archiveInnerPath} · ${track.formattedSize}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: isFocused
                                                      ? Colors.white70
                                                      : VideoPlatformTheme
                                                          .textMuted,
                                                ),
                                              ),
                                              trailing: Icon(
                                                Icons.play_circle_fill_rounded,
                                                color: isFocused
                                                    ? Colors.white
                                                    : VideoPlatformTheme.accent,
                                                size: 22,
                                              ),
                                              onTap: () async {
                                                Navigator.of(context).pop();
                                                widget.controller
                                                    .registerDirectoryContext(
                                                  mounts: widget.controller
                                                      .availableMounts,
                                                  directoryEntries: _allEntries,
                                                );
                                                await widget.controller
                                                    .playFromDirectory(
                                                  targetTrack: track,
                                                  directoryEntries: _allEntries,
                                                  mounts: widget.controller
                                                      .availableMounts,
                                                );
                                                widget.onOpenFullscreenHall
                                                    ?.call();
                                              },
                                            ),
                                          );
                                        },
                                      ),
                                    );
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
        if ((!controller.hasActiveSession || track == null) &&
            !controller.isScanningFolders) {
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
                child: ExcludeFocus(
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
                                  (v * controller.duration.inMilliseconds)
                                      .round(),
                            ),
                          );
                        }
                      },
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 10, 8),
                child: Builder(
                  builder: (context) {
                    final screenW = MediaQuery.sizeOf(context).width;
                    final isCompact = screenW < 760;

                    Widget buildTrackInfoButton() {
                      return StatefulBuilder(
                        builder: (dockInfoCtx, setDockInfoState) {
                          return InkWell(
                            onFocusChange: (_) {
                              if (dockInfoCtx.mounted) {
                                setDockInfoState(() {});
                              }
                            },
                            onTap: onExpandFullscreen,
                            borderRadius: BorderRadius.circular(10),
                            child: Builder(
                              builder: (ctx) {
                                final isFocused =
                                    Focus.of(ctx).hasPrimaryFocus;
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isFocused
                                        ? VideoPlatformTheme.accent
                                            .withValues(alpha: 0.25)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(10),
                                    border: isFocused
                                        ? Border.all(
                                            color: const Color(0xFFFFE066),
                                            width: 2.0,
                                          )
                                        : null,
                                  ),
                                  child: Row(
                                    children: [
                                      _MiniSpinningVinylAvatar(
                                        isPlaying: controller.isPlaying,
                                        coverBytes: controller.coverImageBytes,
                                        coverUrl: controller.coverImageUrl,
                                        coverHeaders:
                                            controller.coverImageHeaders,
                                        isLocalFile:
                                            controller.coverIsLocalFile,
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
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 5,
                                                    vertical: 1.5,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: VideoPlatformTheme
                                                        .accent
                                                        .withValues(
                                                            alpha: 0.18),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            4),
                                                    border: Border.all(
                                                      color: VideoPlatformTheme
                                                          .accent
                                                          .withValues(
                                                              alpha: 0.5),
                                                    ),
                                                  ),
                                                  child: Text(
                                                    meta.qualityTag,
                                                    style: TextStyle(
                                                      fontSize: 9.5,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      color: VideoPlatformTheme
                                                          .accent,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 6),
                                                Expanded(
                                                  child: Text(
                                                    meta.title,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      color: isFocused
                                                          ? Colors.white
                                                          : VideoPlatformTheme
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
                                                color: controller
                                                        .errorText.isNotEmpty
                                                    ? VideoPlatformTheme.danger
                                                    : (lyricLine.isNotEmpty
                                                        ? VideoPlatformTheme
                                                            .accent
                                                        : VideoPlatformTheme
                                                            .textSecondary),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      );
                    }

                    Widget buildPlayPauseCircle({double size = 38}) {
                      return StatefulBuilder(
                        builder: (dockPlayCtx, setDockPlayState) {
                          return InkWell(
                            onFocusChange: (_) {
                              if (dockPlayCtx.mounted) {
                                setDockPlayState(() {});
                              }
                            },
                            onTap: controller.togglePlayPause,
                            customBorder: const CircleBorder(),
                            child: Builder(
                              builder: (ctx) {
                                final isFocused =
                                    Focus.of(ctx).hasPrimaryFocus;
                                return Container(
                                  width: size,
                                  height: size,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      colors: [
                                        VideoPlatformTheme.accent,
                                        VideoPlatformTheme.accentHover,
                                      ],
                                    ),
                                    border: isFocused
                                        ? Border.all(
                                            color: const Color(0xFFFFE066),
                                            width: 2.2,
                                          )
                                        : null,
                                    boxShadow: [
                                      BoxShadow(
                                        color: VideoPlatformTheme.accent
                                            .withValues(alpha: 0.35),
                                        blurRadius: 8,
                                      ),
                                    ],
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
                                          size: size * 0.56,
                                        ),
                                );
                              },
                            ),
                          );
                        },
                      );
                    }

                    if (isCompact) {
                      return Row(
                        children: [
                          Expanded(child: buildTrackInfoButton()),
                          const SizedBox(width: 4),
                          IconButton(
                            tooltip: '上一首',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                            onPressed: () => controller.stepTrack(-1),
                            icon: Icon(
                              Icons.skip_previous_rounded,
                              size: 22,
                              color: VideoPlatformTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(width: 2),
                          buildPlayPauseCircle(size: 36),
                          const SizedBox(width: 2),
                          IconButton(
                            tooltip: '下一首',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                            onPressed: () => controller.stepTrack(1),
                            icon: Icon(
                              Icons.skip_next_rounded,
                              size: 22,
                              color: VideoPlatformTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(width: 4),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                            ),
                            onPressed: onExpandFullscreen,
                            icon: const Icon(Icons.lyrics_rounded, size: 14),
                            label: Text(
                              '${controller.currentIndex + 1}/${controller.queue.length}',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '停止并关闭音乐播放器',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 30,
                              minHeight: 30,
                            ),
                            onPressed: controller.stopAndClose,
                            icon: Icon(
                              Icons.close_rounded,
                              size: 18,
                              color: VideoPlatformTheme.textMuted,
                            ),
                          ),
                        ],
                      );
                    }

                    // Desktop / Tablet 3-Zone Symmetric Music Dock Layout
                    return Row(
                      children: [
                        // Zone 1 (Left): Track Metadata & Live Lyric
                        Expanded(
                          flex: 4,
                          child: buildTrackInfoButton(),
                        ),
                        const SizedBox(width: 12),

                        // Zone 2 (Center): Core Transport Controls Capsule
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: VideoPlatformTheme.bgCard
                                .withValues(alpha: 0.72),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: VideoPlatformTheme.borderSubtle,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip:
                                    '播放模式：${playModeLabel(controller.playMode)}',
                                visualDensity: VisualDensity.compact,
                                onPressed: controller.cyclePlayMode,
                                icon: Icon(
                                  playModeIcon(controller.playMode),
                                  size: 18,
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
                              buildPlayPauseCircle(size: 38),
                              const SizedBox(width: 4),
                              IconButton(
                                tooltip: '下一首',
                                visualDensity: VisualDensity.compact,
                                onPressed: () => controller.stepTrack(1),
                                icon: Icon(
                                  Icons.skip_next_rounded,
                                  size: 24,
                                  color: VideoPlatformTheme.textPrimary,
                                ),
                              ),
                              const SizedBox(width: 2),
                              StatefulBuilder(
                                builder: (dockSpdCtx, setDockSpdState) {
                                  return InkWell(
                                    onFocusChange: (_) {
                                      if (dockSpdCtx.mounted) {
                                        setDockSpdState(() {});
                                      }
                                    },
                                    onTap: controller.cycleSpeed,
                                    borderRadius: BorderRadius.circular(10),
                                    child: Builder(
                                      builder: (ctx) {
                                        final isFocused =
                                            Focus.of(ctx).hasPrimaryFocus;
                                        return Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: isFocused
                                                ? VideoPlatformTheme.accent
                                                    .withValues(alpha: 0.34)
                                                : VideoPlatformTheme.bgHover,
                                            borderRadius:
                                                BorderRadius.circular(10),
                                            border: isFocused
                                                ? Border.all(
                                                    color:
                                                        const Color(0xFFFFE066),
                                                    width: 1.8,
                                                  )
                                                : null,
                                          ),
                                          child: Text(
                                            '${controller.speed}x',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                              color: isFocused
                                                  ? Colors.white
                                                  : VideoPlatformTheme
                                                      .textPrimary,
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),

                        // Zone 3 (Right): Time, Volume Control, Lyrics Hall Button & Close
                        Expanded(
                          flex: 4,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (screenW >= 980) ...[
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
                                const SizedBox(width: 10),
                              ],
                              if (controller.player != null) ...[
                                PlayerVolumeControl(
                                  player: controller.player!,
                                  compact: true,
                                  sliderWidth: screenW > 1080 ? 72 : 52,
                                  showPercentage: screenW > 1160,
                                  onVolumeChanged: (v) =>
                                      controller.setVolume(v),
                                ),
                                const SizedBox(width: 10),
                              ],
                              OutlinedButton.icon(
                                onPressed: onExpandFullscreen,
                                icon:
                                    const Icon(Icons.lyrics_rounded, size: 15),
                                label: Text(
                                  screenW < 920
                                      ? '歌词厅 (${controller.currentIndex + 1}/${controller.queue.length})'
                                      : '黑胶歌词厅 (${controller.currentIndex + 1}/${controller.queue.length})',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
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
  final Uint8List? coverBytes;
  final String? coverUrl;
  final Map<String, String> coverHeaders;
  final bool isLocalFile;

  const _MiniSpinningVinylAvatar({
    required this.isPlaying,
    this.coverBytes,
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
    final bytes = widget.coverBytes;
    if (bytes != null && bytes.isNotEmpty) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _fallbackIcon(),
      );
    }
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
  final FocusNode _playPauseBtnFocusNode = FocusNode();
  final FocusNode _topPickerBtnFocusNode = FocusNode();

  int _rightTabIndex = 0; // Desktop right pane: 0 = 实时同步歌词, 1 = 播放队列
  int _mobileViewIndex = 0; // Mobile 3-pane switcher: 0 = 黑胶唱盘, 1 = 同步歌词, 2 = 播放队列
  int _queuePageIndex = 0;
  static const int _queuePageSize = 100;
  String _queueSearch = '';
  int _lastScrolledLyricIndex = -1;
  int _lastKnownTrackIndex = -1;
  bool _showGestureVolumeHud = false;
  bool _isDraggingRightEdgeVolume = false;
  Timer? _gestureVolumeHudTimer;

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

    if (_ctrl.currentIndex >= 0 && _ctrl.currentIndex != _lastKnownTrackIndex) {
      _lastKnownTrackIndex = _ctrl.currentIndex;
      final targetPage = _ctrl.currentIndex ~/ _queuePageSize;
      if (_queuePageIndex != targetPage) {
        _queuePageIndex = targetPage;
      }
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
    _gestureVolumeHudTimer?.cancel();
    _ctrl.removeListener(_onControllerUpdated);
    _vinylController.dispose();
    _lyricsScrollController.dispose();
    _queueFilterCtrl.dispose();
    _keyboardFocusNode.dispose();
    _playPauseBtnFocusNode.dispose();
    _topPickerBtnFocusNode.dispose();
    super.dispose();
  }

  Future<void> _openFolderAndArchivePicker() async {
    await showDialog<void>(
      context: context,
      builder: (_) => CloudMusicFolderPickerDialog(controller: _ctrl),
    );
  }

  Future<void> _openSmartPlaylistDialog({
    int initialTab = 0,
    List<SavedMusicFolderItem>? initialSources,
    BuildContext? managerContext,
  }) async {
    if (managerContext != null && managerContext.mounted) {
      Navigator.of(managerContext).pop();
    }
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => CloudMusicSmartPlaylistDialog(
        controller: _ctrl,
        initialTab: initialTab,
        initialSources: initialSources,
      ),
    );
    if (created == true && mounted) {
      _showPlaylistQueue();
    }
  }

  Future<void> _promptCreatePlaylist({BuildContext? managerContext}) async {
    final name = await _promptPlaylistName();
    if (!mounted || name == null) return;
    _showPlaylistQueue();
    if (managerContext != null && managerContext.mounted) {
      Navigator.of(managerContext).pop();
    }
    await _ctrl.createPlaylist(name);
  }

  Future<String?> _promptPlaylistName({String? currentName}) {
    final formKey = GlobalKey<FormState>();
    var name = currentName ?? '';
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        void submit() {
          if (formKey.currentState!.validate()) {
            Navigator.of(ctx).pop(name.trim());
          }
        }

        return AlertDialog(
          scrollable: true,
          backgroundColor: VideoPlatformTheme.bgElevated,
          title: Text(currentName == null ? '新建列表' : '重命名列表'),
          content: Form(
            key: formKey,
            child: TextFormField(
              initialValue: currentName,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: '列表名称',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => name = value,
              onFieldSubmitted: (_) => submit(),
              validator:
                  (value) =>
                      value == null || value.trim().isEmpty ? '请输入列表名称' : null,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: submit,
              child: Text(currentName == null ? '创建' : '保存'),
            ),
          ],
        );
      },
    );
  }

  void _showPlaylistQueue() {
    _queueFilterCtrl.clear();
    setState(() {
      _mobileViewIndex = 2;
      _rightTabIndex = 1;
      _queueSearch = '';
      _queuePageIndex = 0;
    });
  }

  Future<void> _openPlaylistManagerDialog() async {
    if (MediaQuery.sizeOf(context).width < 820) {
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: VideoPlatformTheme.bgElevated,
        showDragHandle: true,
        isScrollControlled: true,
        useSafeArea: true,
        builder:
            (ctx) => SafeArea(
              top: false,
              child: FractionallySizedBox(
                heightFactor: 0.74,
                child: _buildPlaylistManager(ctx),
              ),
            ),
      );
    } else {
      await showDialog<void>(
        context: context,
        builder:
            (ctx) => Dialog(
              backgroundColor: VideoPlatformTheme.bgElevated,
              child: SizedBox(
                width: 480,
                height: 420,
                child: _buildPlaylistManager(ctx),
              ),
            ),
      );
    }
  }

  Widget _buildPlaylistManager(BuildContext managerContext) {
    return ListenableBuilder(
      listenable: _ctrl,
      builder: (context, _) {
        final playlists = _ctrl.savedPlaylists;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '播放列表',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(managerContext).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () =>
                          _promptCreatePlaylist(managerContext: managerContext),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('新建列表'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _openSmartPlaylistDialog(
                            initialTab: 0,
                            managerContext: managerContext,
                          ),
                          icon: const Icon(
                            Icons.manage_search_rounded,
                            size: 16,
                          ),
                          label: const Text(
                            '指定目录搜歌建表',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _openSmartPlaylistDialog(
                            initialTab: 1,
                            managerContext: managerContext,
                          ),
                          icon: const Icon(
                            Icons.auto_awesome_rounded,
                            size: 16,
                          ),
                          label: const Text(
                            'AI 智能分类建表',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: VideoPlatformTheme.borderSubtle),
            Expanded(
              child:
                  playlists.isEmpty
                      ? const Center(child: Text('暂无播放列表'))
                      : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                        itemCount: playlists.length,
                        itemBuilder: (context, index) {
                          final playlist = playlists[index];
                          final isActive =
                              playlist.id == _ctrl.activePlaylistId;
                          final canPlay =
                              playlist.tracks.isNotEmpty ||
                              playlist.sources.isNotEmpty;

                          void select({bool shuffle = false}) {
                            Navigator.of(managerContext).pop();
                            _showPlaylistQueue();
                            if (!isActive ||
                                shuffle ||
                                (canPlay &&
                                    (!_ctrl.hasActiveSession ||
                                        !_ctrl.isPlaying ||
                                        _ctrl.errorText.isNotEmpty ||
                                        _ctrl.needsFreshOpenAfterBackground))) {
                              unawaited(
                                _ctrl.switchAndPlayPlaylist(
                                  playlist.id,
                                  shuffle: shuffle,
                                ),
                              );
                            }
                          }

                          return ListTile(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            selected: isActive,
                            selectedColor: VideoPlatformTheme.accent,
                            selectedTileColor: VideoPlatformTheme.accent
                                .withValues(alpha: 0.12),
                            leading: Icon(
                              isActive
                                  ? Icons.check_circle_rounded
                                  : Icons.queue_music_rounded,
                            ),
                            title: Text(
                              playlist.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${isActive ? '当前列表 · ' : ''}${playlist.tracks.length} 首',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: select,
                            trailing: PopupMenuButton<String>(
                              tooltip: '列表操作',
                              onSelected: (action) async {
                                switch (action) {
                                  case 'play':
                                    select(shuffle: false);
                                  case 'shuffle':
                                    select(shuffle: true);
                                  case 'rename':
                                    final name = await _promptPlaylistName(
                                      currentName: playlist.name,
                                    );
                                    if (name != null) {
                                      await _ctrl.renameSavedPlaylist(
                                        playlist.id,
                                        name,
                                      );
                                    }
                                  case 'delete':
                                    await _ctrl.deleteSavedPlaylist(
                                      playlist.id,
                                    );
                                }
                              },
                              itemBuilder:
                                  (_) => [
                                    if (canPlay)
                                      const PopupMenuItem(
                                        value: 'play',
                                        child: Text('顺序播放'),
                                      ),
                                    if (canPlay)
                                      const PopupMenuItem(
                                        value: 'shuffle',
                                        child: Text('随机播放'),
                                      ),
                                    const PopupMenuItem(
                                      value: 'rename',
                                      child: Text('重命名'),
                                    ),
                                    if (playlist.id != 'default_playlist' ||
                                        playlists.length > 1)
                                      const PopupMenuItem(
                                        value: 'delete',
                                        child: Text('删除列表'),
                                      ),
                                  ],
                            ),
                          );
                        },
                      ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _exitMusicPlayer() async {
    await _ctrl.stopAndClose();
    if (!widget.isStandalonePage && mounted) {
      Navigator.of(context).pop();
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      _ctrl.togglePlayPause();
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
    // Only handle Space when the background container itself has primary focus
    // (so Space/Enter on a focused button triggers that button's onPressed!).
    // Never intercept arrowLeft / arrowRight so D-pad remote focus traversal works across all buttons!
    if (node.hasPrimaryFocus && key == LogicalKeyboardKey.space) {
      _ctrl.togglePlayPause();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _keyboardFocusNode,
      canRequestFocus: false,
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
          final showMobileQueue =
              !isWide &&
              (_mobileViewIndex == 2 ||
                  (track == null && _ctrl.activePlaylist != null));
          final queueKeyboardVisible = showMobileQueue &&
              (MediaQuery.viewInsetsOf(context).bottom > 0 ||
                  View.of(context).viewInsets.bottom > 0);

          final Widget content;
          if (_ctrl.isScanningFolders) {
            content = _buildScanningStatusBody();
          } else if (showMobileQueue) {
            content = _buildMobilePlaylistQueue();
          } else if (track == null) {
            content = _ctrl.activePlaylist == null
                ? _buildEmptyStandaloneLauncherBody(isWide: isWide)
                : Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: _buildEmptyPlaylistState(showName: true),
                    ),
                  );
          } else if (isWide) {
            content = Row(
              children: [
                Expanded(flex: 5, child: _buildVinylTurntablePane(track, meta)),
                Container(width: 1, color: VideoPlatformTheme.borderSubtle),
                Expanded(flex: 6, child: _buildRightLyricsAndQueuePane(track)),
              ],
            );
          } else {
            content = _buildMobileActivePaneBody(track, meta);
          }

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
            child: Stack(
              children: [
                Column(
                  children: [
                    _buildHeaderBar(track, meta, isWide: isWide),
                    if (!showMobileQueue &&
                        ((isWide && _ctrl.savedPlaylists.isNotEmpty) ||
                            _ctrl.savedMusicFolders.isNotEmpty))
                      _buildSavedMusicFoldersStrip(isWide: isWide),
                    if (!isWide && track != null && !_ctrl.isScanningFolders)
                      _buildMobileThreePaneSwitcherBar(),
                    Divider(height: 1, color: VideoPlatformTheme.borderSubtle),
                    Expanded(child: content),
                    if (track != null && !queueKeyboardVisible) ...[
                      Divider(
                        height: 1,
                        color: VideoPlatformTheme.borderSubtle,
                      ),
                      _buildBottomControlDeck(progress, isWide: isWide),
                    ],
                  ],
                ),
                // Right-edge vertical swipe gesture zone for volume adjustment on mobile / touch screens
                if (!isWide && track != null && !queueKeyboardVisible)
                  _buildRightEdgeVolumeGestureZone(),
                if (_showGestureVolumeHud)
                  _buildGestureVolumeHudOverlay(),
                // Floating movable / hideable / closable real-time speed tag on Music Hall modal
                if (!widget.isStandalonePage)
                  Positioned(
                    top: isWide ? 56 : 48,
                    right: 14,
                    child: const GlobalFloatingSpeedBadge(
                      compact: true,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _onRightEdgeVolumeDragStart(DragStartDetails _) {
    _gestureVolumeHudTimer?.cancel();
    setState(() {
      _isDraggingRightEdgeVolume = true;
      _showGestureVolumeHud = true;
    });
  }

  void _onRightEdgeVolumeDragUpdate(
    DragUpdateDetails details,
    double zoneHeight,
  ) {
    final effectiveHeight = zoneHeight.clamp(160.0, 520.0);
    // Sliding up (dy < 0) increases volume; sliding down (dy > 0) decreases volume
    final deltaPercent = (-details.delta.dy / (effectiveHeight * 0.65)) * 100.0;
    final nextVol = (_ctrl.volume + deltaPercent).clamp(0.0, 100.0);
    _ctrl.setVolume(nextVol);
    if (!_showGestureVolumeHud || !_isDraggingRightEdgeVolume) {
      setState(() {
        _isDraggingRightEdgeVolume = true;
        _showGestureVolumeHud = true;
      });
    }
  }

  void _onRightEdgeVolumeDragEnd() {
    _gestureVolumeHudTimer?.cancel();
    if (mounted) {
      setState(() {
        _isDraggingRightEdgeVolume = false;
      });
    }
    _gestureVolumeHudTimer = Timer(const Duration(milliseconds: 1100), () {
      if (mounted) {
        setState(() {
          _showGestureVolumeHud = false;
        });
      }
    });
  }

  Widget _buildRightEdgeVolumeGestureZone() {
    final volRatio = (_ctrl.volume / 100.0).clamp(0.0, 1.0);
    return Positioned(
      top: 92,
      bottom: 92,
      right: 0,
      width: 36,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final zoneH = constraints.maxHeight;
          final barH = (zoneH * 0.46).clamp(84.0, 180.0);
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragStart: _onRightEdgeVolumeDragStart,
            onVerticalDragUpdate: (d) => _onRightEdgeVolumeDragUpdate(d, zoneH),
            onVerticalDragEnd: (_) => _onRightEdgeVolumeDragEnd(),
            onVerticalDragCancel: _onRightEdgeVolumeDragEnd,
            child: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: _isDraggingRightEdgeVolume ? 6.0 : 3.5,
                  height: barH,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(
                      alpha: _isDraggingRightEdgeVolume ? 0.22 : 0.10,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: volRatio,
                    widthFactor: 1.0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: _isDraggingRightEdgeVolume
                            ? VideoPlatformTheme.accentHover
                            : VideoPlatformTheme.accent.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildGestureVolumeHudOverlay() {
    final vol = _ctrl.volume.round().clamp(0, 100);
    final IconData icon = vol <= 0
        ? Icons.volume_off_rounded
        : (vol < 50 ? Icons.volume_down_rounded : Icons.volume_up_rounded);
    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xE60B121B),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: VideoPlatformTheme.accent.withValues(alpha: 0.48),
                width: 1.2,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black54,
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 28,
                  color: vol <= 0
                      ? VideoPlatformTheme.danger
                      : VideoPlatformTheme.accentHover,
                ),
                const SizedBox(height: 8),
                Text(
                  '音量 $vol%',
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: 116,
                  height: 5,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: (vol / 100.0).clamp(0.0, 1.0),
                      backgroundColor: Colors.white24,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        vol <= 0
                            ? VideoPlatformTheme.danger
                            : VideoPlatformTheme.accent,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMobileThreePaneSwitcherBar() {
    final items = [
      (0, Icons.album_rounded, '封面'),
      (1, Icons.lyrics_rounded, '歌词'),
      (2, Icons.queue_music_rounded, '播放列表'),
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
              child: StatefulBuilder(
                builder: (swCtx, setSwState) {
                  final isSelected = _mobileViewIndex == items[i].$1;
                  return InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onFocusChange: (_) {
                      if (swCtx.mounted) setSwState(() {});
                    },
                    onTap: () => setState(() => _mobileViewIndex = items[i].$1),
                    child: Builder(
                      builder: (ctx) {
                        final isFocused = Focus.of(ctx).hasPrimaryFocus;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          decoration: BoxDecoration(
                            color: isFocused
                                ? VideoPlatformTheme.accent
                                    .withValues(alpha: 0.34)
                                : (isSelected
                                    ? VideoPlatformTheme.accent
                                        .withValues(alpha: 0.2)
                                    : VideoPlatformTheme.bgCard),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isFocused
                                  ? const Color(0xFFFFE066)
                                  : (isSelected
                                      ? VideoPlatformTheme.accent
                                      : VideoPlatformTheme.borderSubtle),
                              width: isFocused ? 2.2 : 1.0,
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                items[i].$2,
                                size: 14,
                                color: isFocused
                                    ? Colors.white
                                    : (isSelected
                                        ? VideoPlatformTheme.accent
                                        : VideoPlatformTheme.textSecondary),
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  items[i].$3,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: (isSelected || isFocused)
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: isFocused
                                        ? Colors.white
                                        : (isSelected
                                            ? VideoPlatformTheme.accent
                                            : VideoPlatformTheme.textSecondary),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  );
                },
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
    if (!isWide) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        child: Row(
          children: [
            if (!widget.isStandalonePage)
              IconButton(
                tooltip: '收起播放器',
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  '音乐厅',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            IconButton(
              focusNode: _topPickerBtnFocusNode,
              tooltip: '选择音乐',
              onPressed: _openFolderAndArchivePicker,
              icon: const Icon(Icons.create_new_folder_outlined),
            ),
            IconButton(
              tooltip: '指定目录搜歌 / AI 智能建表',
              onPressed: () => _openSmartPlaylistDialog(initialTab: 0),
              icon: const Icon(Icons.auto_awesome_rounded),
            ),
            TextButton(
              onPressed: _openPlaylistManagerDialog,
              child: const Text('列表管理'),
            ),
            if (track != null)
              IconButton(
                tooltip: '退出播放',
                onPressed: _exitMusicPlayer,
                icon: const Icon(Icons.power_settings_new_rounded),
              ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
            FilledButton.icon(
              focusNode: _topPickerBtnFocusNode,
              autofocus: track == null,
              onPressed: _openFolderAndArchivePicker,
              icon: const Icon(Icons.create_new_folder_rounded, size: 15),
              label: Text(
                '自选文件夹 / 压缩包随机播放',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _openPlaylistManagerDialog,
              icon: const Icon(Icons.library_music_rounded, size: 15),
              label: Text(
                '列表管理 (${_ctrl.savedPlaylists.length})',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _promptCreatePlaylist,
              icon: const Icon(Icons.playlist_add_rounded, size: 16),
              label: const Text('新建列表', style: TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => _openSmartPlaylistDialog(initialTab: 0),
              icon: const Icon(Icons.manage_search_rounded, size: 16),
              label: const Text('目录搜歌建表', style: TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => _openSmartPlaylistDialog(initialTab: 1),
              icon: const Icon(Icons.auto_awesome_rounded, size: 15),
              label: const Text('AI 智能分类', style: TextStyle(fontSize: 12)),
            ),
            if (_ctrl.queue.length > 1) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _ctrl.shuffleCurrentQueue,
                icon: const Icon(Icons.shuffle_rounded, size: 15),
                label: Text(
                  '重新随机打乱 (${_ctrl.queue.length}首)',
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
            if (!widget.isStandalonePage) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 17),
                label: Text(
                  '收起至底部 (边听边逛目录)',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
            if (track != null) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _exitMusicPlayer,
                style: OutlinedButton.styleFrom(
                  foregroundColor: VideoPlatformTheme.danger,
                  side: BorderSide(
                    color: VideoPlatformTheme.danger.withValues(alpha: 0.55),
                  ),
                  backgroundColor:
                      VideoPlatformTheme.danger.withValues(alpha: 0.10),
                ),
                icon: const Icon(Icons.power_settings_new_rounded, size: 15),
                label: Text(
                  '退出播放',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
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
    final playlists = _ctrl.savedPlaylists;
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
            Icons.library_music_rounded,
            size: 15,
            color: VideoPlatformTheme.accent,
          ),
          if (isWide) ...[
            const SizedBox(width: 6),
            Text(
              '播放列表:',
              style: TextStyle(
                fontSize: 11.5,
                color: VideoPlatformTheme.textSecondary,
              ),
            ),
          ],
          const SizedBox(width: 6),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final pl in playlists) ...[
                  Center(
                    child: StatefulBuilder(
                      builder: (plCtx, setPlState) {
                        final isActive = pl.id == _ctrl.activePlaylistId;
                        return InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onFocusChange: (_) {
                            if (plCtx.mounted) setPlState(() {});
                          },
                          onTap: () => _ctrl.switchAndPlayPlaylist(
                            pl.id,
                            autoPlay: true,
                            shuffle: false,
                          ),
                          onLongPress: _openPlaylistManagerDialog,
                          child: Builder(
                            builder: (ctx) {
                              final isFocused = Focus.of(ctx).hasPrimaryFocus;
                              return Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: isFocused
                                      ? VideoPlatformTheme.accent
                                      : (isActive
                                          ? VideoPlatformTheme.accent
                                              .withValues(alpha: 0.22)
                                          : VideoPlatformTheme.bgCard),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: isFocused
                                        ? const Color(0xFFFFE066)
                                        : (isActive
                                            ? VideoPlatformTheme.accent
                                            : VideoPlatformTheme.borderSubtle),
                                    width: isFocused ? 2.2 : 1.0,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      pl.id == 'default_playlist'
                                          ? Icons.push_pin_rounded
                                          : Icons.queue_music_rounded,
                                      size: 13,
                                      color: isFocused
                                          ? Colors.white
                                          : (isActive
                                              ? VideoPlatformTheme.accent
                                              : VideoPlatformTheme
                                                  .textSecondary),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      '${pl.name} (${pl.tracks.length}首)',
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        height: 1.2,
                                        fontWeight: (isActive || isFocused)
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                        color: isFocused
                                            ? Colors.white
                                            : (isActive
                                                ? VideoPlatformTheme.accent
                                                : VideoPlatformTheme
                                                    .textPrimary),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                if (saved.isNotEmpty) ...[
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.star_rounded,
                            size: 14,
                            color: VideoPlatformTheme.warning,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '常用目录:',
                            style: TextStyle(
                              fontSize: 11,
                              color: VideoPlatformTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Center(
                    child: StatefulBuilder(
                      builder: (rndAllCtx, setRndAllState) {
                        return InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onFocusChange: (_) {
                            if (rndAllCtx.mounted) setRndAllState(() {});
                          },
                          onTap: () {
                            _ctrl.scanAndPlayFoldersOrArchives(
                              sources: saved,
                              shuffle: true,
                            );
                          },
                          child: Builder(
                            builder: (ctx) {
                              final isFocused = Focus.of(ctx).hasPrimaryFocus;
                              return Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: isFocused
                                      ? VideoPlatformTheme.accent
                                      : VideoPlatformTheme.accent
                                          .withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: isFocused
                                        ? const Color(0xFFFFE066)
                                        : VideoPlatformTheme.accent
                                            .withValues(alpha: 0.5),
                                    width: isFocused ? 2.2 : 1.0,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.shuffle_rounded,
                                      size: 13,
                                      color: isFocused
                                          ? Colors.white
                                          : VideoPlatformTheme.accent,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      '全部随机 (${saved.length})',
                                      style: TextStyle(
                                        fontSize: 11,
                                        height: 1.2,
                                        fontWeight: FontWeight.w700,
                                        color: isFocused
                                            ? Colors.white
                                            : VideoPlatformTheme.accent,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                  for (final item in saved) ...[
                    Center(
                      child: StatefulBuilder(
                        builder: (svCtx, setSvState) {
                          return InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onFocusChange: (_) {
                              if (svCtx.mounted) setSvState(() {});
                            },
                            onTap: () => _ctrl.scanAndPlayFoldersOrArchives(
                              sources: [item],
                              shuffle: true,
                            ),
                            onLongPress: () =>
                                _ctrl.addOrToggleSavedMusicFolder(item),
                            child: Builder(
                              builder: (ctx) {
                                final isFocused =
                                    Focus.of(ctx).hasPrimaryFocus;
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 9,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isFocused
                                        ? VideoPlatformTheme.accent
                                            .withValues(alpha: 0.34)
                                        : VideoPlatformTheme.bgCard,
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: isFocused
                                          ? const Color(0xFFFFE066)
                                          : VideoPlatformTheme.borderSubtle,
                                      width: isFocused ? 2.2 : 1.0,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        item.isArchive
                                            ? Icons.folder_zip_rounded
                                            : Icons.folder_special_rounded,
                                        size: 13,
                                        color: isFocused
                                            ? Colors.white
                                            : (item.isArchive
                                                ? VideoPlatformTheme.badgeHot
                                                : VideoPlatformTheme.warning),
                                      ),
                                      const SizedBox(width: 5),
                                      Text(
                                        '${item.mountName}: ${item.title}',
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          height: 1.2,
                                          fontWeight: isFocused
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                          color: isFocused
                                              ? Colors.white
                                              : VideoPlatformTheme.textPrimary,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                ],
              ],
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
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(160, 40),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                    onPressed: () => _openSmartPlaylistDialog(initialTab: 0),
                    icon: const Icon(Icons.manage_search_rounded, size: 18),
                    label: const Text(
                      '指定目录搜人名/关键词建表',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(160, 40),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                    onPressed: () => _openSmartPlaylistDialog(initialTab: 1),
                    icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                    label: const Text(
                      'AI 智能分析目录分类建表',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (isWide && _ctrl.savedPlaylists.isNotEmpty)
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(160, 40),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                      onPressed: _openPlaylistManagerDialog,
                      icon: const Icon(Icons.library_music_rounded, size: 18),
                      label: Text(
                        '播放已保存列表 (${_ctrl.savedPlaylists.length}个)',
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  if (_ctrl.savedMusicFolders.isNotEmpty)
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
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
    final bytes = _ctrl.coverImageBytes;
    if (bytes != null && bytes.isNotEmpty) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _defaultAlbumArt(),
      );
    }
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
          child:
              _rightTabIndex == 0
                  ? _buildSynchronizedLyricsView()
                  : _buildPlaylistQueueView(),
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
    return StatefulBuilder(
      builder: (pillCtx, setPillState) {
        return InkWell(
          onFocusChange: (_) {
            if (pillCtx.mounted) setPillState(() {});
          },
          onTap: () => setState(() => _rightTabIndex = index),
          borderRadius: BorderRadius.circular(18),
          child: Builder(
            builder: (ctx) {
              final isFocused = Focus.of(ctx).hasPrimaryFocus;
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: isFocused
                      ? VideoPlatformTheme.accent.withValues(alpha: 0.34)
                      : (selected
                          ? VideoPlatformTheme.accent.withValues(alpha: 0.22)
                          : VideoPlatformTheme.bgCard),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: isFocused
                        ? const Color(0xFFFFE066)
                        : (selected
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.borderSubtle),
                    width: isFocused ? 2.2 : 1.0,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      icon,
                      size: 16,
                      color: isFocused
                          ? Colors.white
                          : (selected
                              ? VideoPlatformTheme.accent
                              : VideoPlatformTheme.textSecondary),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.2,
                        fontWeight: (selected || isFocused)
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: isFocused
                            ? Colors.white
                            : (selected
                                ? VideoPlatformTheme.accent
                                : VideoPlatformTheme.textSecondary),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
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

  List<({int index, FileEntry entry})> _matchingQueueTracks() {
    final search = _queueSearch.trim().toLowerCase();
    return [
      for (final (index, entry) in _ctrl.queue.indexed)
        if (search.isEmpty || entry.name.toLowerCase().contains(search))
          (index: index, entry: entry),
    ];
  }

  Widget _buildMobilePlaylistQueue() {
    final items = _matchingQueueTracks();
    final count = _ctrl.queue.length;
    final theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: CustomScrollView(
        key: PageStorageKey('music-queue-${_ctrl.activePlaylistId}'),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _ctrl.activePlaylistName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$count 首',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: VideoPlatformTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (count > 1)
                    IconButton(
                      tooltip: '随机播放列表',
                      icon: const Icon(Icons.shuffle_rounded),
                      onPressed: _ctrl.shuffleCurrentQueue,
                    ),
                ],
              ),
            ),
          ),
          if (count > 0)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              sliver: SliverToBoxAdapter(
                child: TextField(
                  controller: _queueFilterCtrl,
                  onChanged:
                      (value) => setState(() {
                        _queueSearch = value;
                        _queuePageIndex = 0;
                      }),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: '搜索歌曲',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon:
                        _queueSearch.isEmpty
                            ? null
                            : IconButton(
                              tooltip: '清除搜索',
                              icon: const Icon(Icons.clear_rounded),
                              onPressed: () {
                                _queueFilterCtrl.clear();
                                setState(() => _queueSearch = '');
                              },
                            ),
                    filled: true,
                    fillColor: VideoPlatformTheme.bgCard,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ),
          if (items.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child:
                      count == 0
                          ? _buildEmptyPlaylistState()
                          : const Text('未找到匹配的歌曲'),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              sliver: SliverList.builder(
                itemCount: items.length,
                itemBuilder: (_, index) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: _buildQueueTrackCard(items[index], compact: true),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyPlaylistState({bool showName = false}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.queue_music_rounded,
          size: 36,
          color: VideoPlatformTheme.accent,
        ),
        const SizedBox(height: 12),
        if (showName) ...[
          Text(
            _ctrl.activePlaylistName,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
        ],
        Text(
          _ctrl.errorText.isEmpty ? '此列表还没有歌曲' : _ctrl.errorText,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _openFolderAndArchivePicker,
          icon: const Icon(Icons.add_rounded),
          label: const Text('添加音乐'),
        ),
      ],
    );
  }

  Widget _buildPlaylistQueueView() {
    final allMatching = _matchingQueueTracks();
    final totalCount = allMatching.length;
    final pageCount = math.max(1, (totalCount + _queuePageSize - 1) ~/ _queuePageSize);
    final safePage = _queuePageIndex.clamp(0, pageCount - 1);
    final pageStart = safePage * _queuePageSize;
    final pageEnd = math.min(totalCount, pageStart + _queuePageSize);
    final pageItems = pageStart < pageEnd
        ? allMatching.sublist(pageStart, pageEnd)
        : const <({int index, FileEntry entry})>[];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: TextField(
                    controller: _queueFilterCtrl,
                    onChanged: (v) => setState(() {
                      _queueSearch = v;
                      _queuePageIndex = 0;
                    }),
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: '在播放队列中搜索歌曲...',
                      prefixIcon: const Icon(Icons.search_rounded, size: 17),
                      suffixIcon: _queueSearch.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear_rounded, size: 15),
                              onPressed: () {
                                _queueFilterCtrl.clear();
                                setState(() {
                                  _queueSearch = '';
                                  _queuePageIndex = _ctrl.currentIndex >= 0
                                      ? _ctrl.currentIndex ~/ _queuePageSize
                                      : 0;
                                });
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
              const SizedBox(width: 6),
              OutlinedButton.icon(
                onPressed: _promptCreatePlaylist,
                icon: const Icon(Icons.playlist_add_rounded, size: 15),
                label: const Text('新建列表', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: '播放列表管理',
                visualDensity: VisualDensity.compact,
                onPressed: _openPlaylistManagerDialog,
                icon: Icon(
                  Icons.library_music_rounded,
                  size: 18,
                  color: VideoPlatformTheme.accent,
                ),
              ),
            ],
          ),
        ),
        if (pageCount > 1)
          SizedBox(
            height: 32,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              scrollDirection: Axis.horizontal,
              itemCount: pageCount,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (context, pIdx) {
                final s = pIdx * _queuePageSize + 1;
                final e = math.min(totalCount, (pIdx + 1) * _queuePageSize);
                final isSelectedPage = pIdx == safePage;
                return Center(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => setState(() => _queuePageIndex = pIdx),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isSelectedPage
                            ? VideoPlatformTheme.accent.withValues(alpha: 0.22)
                            : VideoPlatformTheme.bgCard,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isSelectedPage
                              ? VideoPlatformTheme.accent
                              : VideoPlatformTheme.borderSubtle,
                        ),
                      ),
                      child: Text(
                        '$s-$e',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: isSelectedPage
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: isSelectedPage
                              ? VideoPlatformTheme.accent
                              : VideoPlatformTheme.textSecondary,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            itemCount: pageItems.length,
            separatorBuilder: (_, __) => const SizedBox(height: 4),
            itemBuilder: (_, index) => _buildQueueTrackCard(pageItems[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildQueueTrackCard(
    ({int index, FileEntry entry}) item, {
    bool compact = false,
  }) {
    final isCurrent = item.index == _ctrl.currentIndex;
    final mountTitle = _ctrl.mountNameFor(item.entry);
    final meta = CloudMusicController.parseTrackMetadata(
      item.entry,
      fallbackArtist: mountTitle,
    );
    final subtitleParts = <String>[
      if (meta.artist.isNotEmpty) meta.artist,
      if (mountTitle.isNotEmpty && mountTitle != meta.artist) mountTitle,
      item.entry.formattedSize,
    ];
    final extension = item.entry.normalizedExt.replaceAll('.', '').toUpperCase();
    final format = item.entry.isInsideArchive ? '📦 $extension' : extension;

    return StatefulBuilder(
      builder: (qRowCtx, setQRowState) {
        return InkWell(
          onFocusChange: (_) {
            if (qRowCtx.mounted) setQRowState(() {});
          },
          onTap: () => _ctrl.playQueueIndex(item.index),
          borderRadius: BorderRadius.circular(10),
          child: Builder(
            builder: (ctx) {
              final isFocused = Focus.of(ctx).hasPrimaryFocus;
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: isFocused
                      ? VideoPlatformTheme.accent
                          .withValues(alpha: 0.30)
                      : (isCurrent
                          ? VideoPlatformTheme.accent
                              .withValues(alpha: 0.16)
                          : VideoPlatformTheme.bgCard),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isFocused
                        ? const Color(0xFFFFE066)
                        : (isCurrent
                            ? VideoPlatformTheme.accent
                                .withValues(alpha: 0.65)
                            : VideoPlatformTheme.borderSubtle),
                    width: isFocused ? 2.2 : 1.0,
                  ),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 28,
                      child: isCurrent
                          ? Icon(
                              Icons.equalizer_rounded,
                              color: isFocused
                                  ? Colors.white
                                  : VideoPlatformTheme.accent,
                              size: 20,
                            )
                          : Text(
                              '${item.index + 1}'.padLeft(2, '0'),
                              style: TextStyle(
                                fontSize: 12,
                                color: isFocused
                                    ? Colors.white70
                                    : VideoPlatformTheme.textMuted,
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
                              fontWeight: (isCurrent || isFocused)
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: isFocused
                                  ? Colors.white
                                  : (isCurrent
                                      ? VideoPlatformTheme.accent
                                      : VideoPlatformTheme
                                          .textPrimary),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitleParts.join(' · '),
                            maxLines: compact ? 2 : 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: isFocused
                                  ? Colors.white70
                                  : VideoPlatformTheme.textMuted,
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
                        format,
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
                      visualDensity: compact
                          ? VisualDensity.standard
                          : VisualDensity.compact,
                      onPressed: () => _ctrl.removeTrackAt(item.index),
                      icon: Icon(
                        Icons.close_rounded,
                        size: 16,
                        color: VideoPlatformTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
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
          StatefulBuilder(
            builder: (scrubCtx, setScrubState) {
              return Focus(
                onFocusChange: (_) {
                  if (scrubCtx.mounted) setScrubState(() {});
                },
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent || event is KeyRepeatEvent) {
                    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                      _ctrl.seekRelative(const Duration(seconds: -5));
                      return KeyEventResult.handled;
                    }
                    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                      _ctrl.seekRelative(const Duration(seconds: 5));
                      return KeyEventResult.handled;
                    }
                    if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.arrowUp) {
                      final moved =
                          node.focusInDirection(TraversalDirection.up);
                      if (!moved || node.hasPrimaryFocus) {
                        if (_topPickerBtnFocusNode.canRequestFocus) {
                          _topPickerBtnFocusNode.requestFocus();
                        } else {
                          node.previousFocus();
                        }
                      }
                      return KeyEventResult.handled;
                    }
                    if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.arrowDown) {
                      final moved =
                          node.focusInDirection(TraversalDirection.down);
                      if (!moved || node.hasPrimaryFocus) {
                        if (_playPauseBtnFocusNode.canRequestFocus) {
                          _playPauseBtnFocusNode.requestFocus();
                        } else {
                          node.nextFocus();
                        }
                      }
                      return KeyEventResult.handled;
                    }
                    if (event is KeyDownEvent &&
                        (event.logicalKey == LogicalKeyboardKey.select ||
                            event.logicalKey == LogicalKeyboardKey.enter ||
                            event.logicalKey ==
                                LogicalKeyboardKey.numpadEnter ||
                            event.logicalKey == LogicalKeyboardKey.space ||
                            event.logicalKey ==
                                LogicalKeyboardKey.gameButtonA)) {
                      _ctrl.togglePlayPause();
                      return KeyEventResult.handled;
                    }
                  }
                  return KeyEventResult.ignored;
                },
                child: Builder(
                  builder: (ctx) {
                    final hasBarFocus = Focus.of(ctx).hasPrimaryFocus;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: hasBarFocus
                            ? VideoPlatformTheme.accent.withValues(alpha: 0.16)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: hasBarFocus
                              ? const Color(0xFFFFE066)
                              : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 44,
                            child: Text(
                              CloudMusicBottomDockBar.formatDuration(
                                _ctrl.position,
                              ),
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: hasBarFocus
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                                color: hasBarFocus
                                    ? Colors.white
                                    : VideoPlatformTheme.textSecondary,
                              ),
                            ),
                          ),
                          Expanded(
                            child: ExcludeFocus(
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: hasBarFocus ? 5.0 : 3.5,
                                  thumbShape: RoundSliderThumbShape(
                                    enabledThumbRadius:
                                        hasBarFocus ? 8.5 : 6.5,
                                  ),
                                  activeTrackColor: hasBarFocus
                                      ? const Color(0xFFFFE066)
                                      : VideoPlatformTheme.accent,
                                  inactiveTrackColor:
                                      VideoPlatformTheme.borderStrong,
                                  thumbColor: hasBarFocus
                                      ? const Color(0xFFFFE066)
                                      : VideoPlatformTheme.accentHover,
                                ),
                                child: Slider(
                                  value: progress,
                                  onChanged: (v) {
                                    if (_ctrl.duration > Duration.zero) {
                                      _ctrl.seekTo(
                                        Duration(
                                          milliseconds: (v *
                                                  _ctrl.duration.inMilliseconds)
                                              .round(),
                                        ),
                                      );
                                    }
                                  },
                                ),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 44,
                            child: Text(
                              CloudMusicBottomDockBar.formatDuration(
                                _ctrl.duration,
                              ),
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                                color: hasBarFocus
                                    ? Colors.white
                                    : VideoPlatformTheme.textSecondary,
                              ),
                            ),
                          ),
                          if (hasBarFocus && isWide) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: VideoPlatformTheme.accent,
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: const Text(
                                '◀▶ 快退/快进5s · ▲▼ 切换按钮',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              );
            },
          ),
          if (isCompactDeck)
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      tooltip:
                          '播放模式：${CloudMusicBottomDockBar.playModeLabel(_ctrl.playMode)}',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      onPressed: _ctrl.cyclePlayMode,
                      icon: Icon(
                        CloudMusicBottomDockBar.playModeIcon(_ctrl.playMode),
                        size: 19,
                        color: VideoPlatformTheme.accent,
                      ),
                    ),
                    IconButton(
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      tooltip: '快退 5 秒',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      onPressed: () =>
                          _ctrl.seekRelative(const Duration(seconds: -5)),
                      icon: Icon(
                        Icons.replay_5_rounded,
                        color: VideoPlatformTheme.textSecondary,
                        size: 19,
                      ),
                    ),
                    IconButton(
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      tooltip: '上一首',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 34,
                        minHeight: 34,
                      ),
                      onPressed: () => _ctrl.stepTrack(-1),
                      icon: Icon(
                        Icons.skip_previous_rounded,
                        color: VideoPlatformTheme.textPrimary,
                        size: 25,
                      ),
                    ),
                    StatefulBuilder(
                      builder: (cPlayCtx, setCPlayState) {
                        return InkWell(
                          focusNode: _playPauseBtnFocusNode,
                          onFocusChange: (_) {
                            if (cPlayCtx.mounted) setCPlayState(() {});
                          },
                          onTap: _ctrl.togglePlayPause,
                          customBorder: const CircleBorder(),
                          child: Builder(
                            builder: (ctx) {
                              final isFocused = Focus.of(ctx).hasPrimaryFocus;
                              return Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: LinearGradient(
                                    colors: [
                                      VideoPlatformTheme.accent,
                                      VideoPlatformTheme.accentHover,
                                    ],
                                  ),
                                  border: isFocused
                                      ? Border.all(
                                          color: const Color(0xFFFFE066),
                                          width: 2.6,
                                        )
                                      : null,
                                  boxShadow: [
                                    BoxShadow(
                                      color:
                                          VideoPlatformTheme.accent.withValues(
                                        alpha: isFocused ? 0.75 : 0.4,
                                      ),
                                      blurRadius: isFocused ? 18 : 12,
                                    ),
                                  ],
                                ),
                                child: _ctrl.isLoadingTrack
                                    ? const Padding(
                                        padding: EdgeInsets.all(11),
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
                                        size: 25,
                                      ),
                              );
                            },
                          ),
                        );
                      },
                    ),
                    IconButton(
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      tooltip: '下一首',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 34,
                        minHeight: 34,
                      ),
                      onPressed: () => _ctrl.stepTrack(1),
                      icon: Icon(
                        Icons.skip_next_rounded,
                        color: VideoPlatformTheme.textPrimary,
                        size: 25,
                      ),
                    ),
                    IconButton(
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      tooltip: '快进 5 秒',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      onPressed: () =>
                          _ctrl.seekRelative(const Duration(seconds: 5)),
                      icon: Icon(
                        Icons.forward_5_rounded,
                        color: VideoPlatformTheme.textSecondary,
                        size: 19,
                      ),
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: _ctrl.cycleSpeed,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: VideoPlatformTheme.bgCard,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: VideoPlatformTheme.borderSubtle,
                          ),
                        ),
                        child: Text(
                          '${_ctrl.speed}x',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: VideoPlatformTheme.textPrimary,
                          ),
                        ),
                      ),
                    ),
                    if (_ctrl.queue.length > 1)
                      IconButton(
                        style: IconButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        tooltip: '随机打乱队列',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        onPressed: _ctrl.shuffleCurrentQueue,
                        icon: Icon(
                          Icons.shuffle_rounded,
                          color: VideoPlatformTheme.textSecondary,
                          size: 18,
                        ),
                      ),
                  ],
                ),
              ],
            )
          else
            Row(
              children: [
                // Left Zone: Play Mode, Playback Speed & Shuffle Pills
                Expanded(
                  flex: 4,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                          ),
                          onPressed: _ctrl.cyclePlayMode,
                          icon: Icon(
                            CloudMusicBottomDockBar.playModeIcon(
                              _ctrl.playMode,
                            ),
                            size: 16,
                            color: VideoPlatformTheme.accent,
                          ),
                          label: Text(
                            CloudMusicBottomDockBar.playModeLabel(
                              _ctrl.playMode,
                            ),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: VideoPlatformTheme.accent,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                          ),
                          onPressed: _ctrl.cycleSpeed,
                          child: Text(
                            '倍速 ${_ctrl.speed}x',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: VideoPlatformTheme.textPrimary,
                            ),
                          ),
                        ),
                        if (_ctrl.queue.length > 1) ...[
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                            ),
                            onPressed: _ctrl.shuffleCurrentQueue,
                            icon: const Icon(Icons.shuffle_rounded, size: 15),
                            label: const Text(
                              '随机打乱',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                // Center Zone: Core Hi-Fi Transport Controls
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: VideoPlatformTheme.bgCard.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: VideoPlatformTheme.borderSubtle,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
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
                      const SizedBox(width: 6),
                      StatefulBuilder(
                        builder: (playBtnCtx, setPlayBtnState) {
                          return InkWell(
                            focusNode: _playPauseBtnFocusNode,
                            onFocusChange: (_) {
                              if (playBtnCtx.mounted) setPlayBtnState(() {});
                            },
                            onTap: _ctrl.togglePlayPause,
                            customBorder: const CircleBorder(),
                            child: Builder(
                              builder: (ctx) {
                                final isFocused =
                                    Focus.of(ctx).hasPrimaryFocus;
                                return Container(
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
                                    border: isFocused
                                        ? Border.all(
                                            color: const Color(0xFFFFE066),
                                            width: 2.8,
                                          )
                                        : null,
                                    boxShadow: [
                                      BoxShadow(
                                        color: VideoPlatformTheme.accent
                                            .withValues(
                                          alpha: isFocused ? 0.75 : 0.4,
                                        ),
                                        blurRadius: isFocused ? 18 : 12,
                                      ),
                                    ],
                                  ),
                                  child: _ctrl.isLoadingTrack
                                      ? const Padding(
                                          padding: EdgeInsets.all(13),
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.4,
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
                                );
                              },
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 6),
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
                    ],
                  ),
                ),

                // Right Zone: Interactive Volume Control, Queue Switcher & Stop Button
                Expanded(
                  flex: 4,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (_ctrl.player != null)
                        PlayerVolumeControl(
                          player: _ctrl.player!,
                          compact: true,
                          sliderWidth: 82,
                          showPercentage: true,
                          onVolumeChanged: (v) => _ctrl.setVolume(v),
                        ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                        ),
                        onPressed: () {
                          setState(() {
                            _rightTabIndex = _rightTabIndex == 1 ? 0 : 1;
                          });
                        },
                        icon: Icon(
                          _rightTabIndex == 1
                              ? Icons.lyrics_rounded
                              : Icons.queue_music_rounded,
                          size: 15,
                        ),
                        label: Text(
                          _rightTabIndex == 1
                              ? '同步歌词'
                              : '队列 (${_ctrl.currentIndex + 1}/${_ctrl.queue.length})',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      if (_ctrl.currentTrack != null) ...[
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: _exitMusicPlayer,
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            foregroundColor: VideoPlatformTheme.danger,
                            side: BorderSide(
                              color: VideoPlatformTheme.danger
                                  .withValues(alpha: 0.55),
                            ),
                            backgroundColor: VideoPlatformTheme.danger
                                .withValues(alpha: 0.10),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                          ),
                          icon: const Icon(
                            Icons.power_settings_new_rounded,
                            size: 15,
                          ),
                          label: const Text(
                            '停止退出',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
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

// =============================================================================
// 6. Smart Directory Search (Artist / Keyword) & AI Auto-Categorized Playlist Dialog
// =============================================================================

class CloudMusicSmartPlaylistDialog extends StatefulWidget {
  final CloudMusicController controller;
  final List<SavedMusicFolderItem>? initialSources;
  final int initialTab; // 0 = 指定目录搜人名/关键词建表, 1 = AI 智能分析目录分类建表
  final bool initialIncludeSubfolders;

  const CloudMusicSmartPlaylistDialog({
    super.key,
    required this.controller,
    this.initialSources,
    this.initialTab = 0,
    this.initialIncludeSubfolders = true,
  });

  @override
  State<CloudMusicSmartPlaylistDialog> createState() =>
      _CloudMusicSmartPlaylistDialogState();
}

class _CloudMusicSmartPlaylistDialogState
    extends State<CloudMusicSmartPlaylistDialog> {
  late int _activeTab;
  late bool _includeSubfolders;
  final List<SavedMusicFolderItem> _selectedSources = [];

  // Tab 0: Artist / Keyword Search & Create Playlist
  final TextEditingController _keywordCtrl = TextEditingController();
  final TextEditingController _newPlaylistNameCtrl = TextEditingController();
  bool _playlistNameManuallyEdited = false;
  bool _matchAllKeywords = false;
  bool _isSearchingTracks = false;
  String _searchProgressText = '';
  String? _searchError;
  List<FileEntry> _scannedAllTracks = const [];
  List<FileEntry> _matchedTracks = const [];
  final Set<String> _uncheckedTrackKeys = {};

  // Tab 1: AI Directory Analysis & Auto-Categorized Playlists
  String _aiDimension = 'auto';
  final TextEditingController _aiCustomInstructionCtrl =
      TextEditingController();
  bool _showInlineAiConfig = false;
  String _inlineAiProvider = 'openai';
  final TextEditingController _inlineAiKeyCtrl = TextEditingController();
  final TextEditingController _inlineAiBaseUrlCtrl = TextEditingController();
  final TextEditingController _inlineAiModelCtrl = TextEditingController();
  bool _isAnalyzingAi = false;
  String _aiProgressText = '';
  String? _aiError;
  List<AiMusicCategoryDraft> _aiDrafts = const [];
  final Set<int> _selectedAiDraftIndices = {};

  CloudMusicController get _ctrl => widget.controller;

  @override
  void initState() {
    super.initState();
    _activeTab = widget.initialTab.clamp(0, 1);
    _includeSubfolders = widget.initialIncludeSubfolders;
    final state = _ctrl.boundAppState;
    if (state != null) {
      _inlineAiProvider = state.aiProvider;
      _inlineAiKeyCtrl.text = state.aiApiKey;
      _inlineAiBaseUrlCtrl.text = state.aiBaseUrl;
      _inlineAiModelCtrl.text = state.aiModel;
      _showInlineAiConfig = !state.hasAiApiKey;
    }
    _initDefaultSources();
  }

  void _populateDefaultSourcesSync() {
    if (_selectedSources.isNotEmpty) return;
    if (widget.initialSources != null && widget.initialSources!.isNotEmpty) {
      _selectedSources.addAll(widget.initialSources!);
    } else if (_ctrl.savedMusicFolders.isNotEmpty) {
      _selectedSources.addAll(_ctrl.savedMusicFolders);
    } else if (_ctrl.activePlaylist != null &&
        _ctrl.activePlaylist!.sources.isNotEmpty) {
      _selectedSources.addAll(_ctrl.activePlaylist!.sources);
    } else if (_ctrl.availableMounts.isNotEmpty) {
      final m = _ctrl.availableMounts.first;
      _selectedSources.add(
        SavedMusicFolderItem(
          mountId: m.id,
          mountName: m.name,
          sourceKind: m.kind,
          path: m.rootPath,
          title: m.name,
        ),
      );
    }
  }

  Future<void> _initDefaultSources() async {
    _populateDefaultSourcesSync();
    if (_selectedSources.isNotEmpty && _ctrl.availableMounts.isNotEmpty) {
      return;
    }
    await _ctrl.refreshAvailableMounts();
    if (!mounted) return;
    if (_selectedSources.isEmpty) {
      setState(_populateDefaultSourcesSync);
    }
  }

  @override
  void dispose() {
    _keywordCtrl.dispose();
    _newPlaylistNameCtrl.dispose();
    _aiCustomInstructionCtrl.dispose();
    _inlineAiKeyCtrl.dispose();
    _inlineAiBaseUrlCtrl.dispose();
    _inlineAiModelCtrl.dispose();
    super.dispose();
  }

  String _trackKey(FileEntry e) =>
      '${e.mountId}::${e.path}::${e.archiveInnerPath}';

  Future<void> _openDirectorySelectorSheet() async {
    await _ctrl.refreshAvailableMounts();
    if (!mounted) return;
    final picked = await showDialog<List<SavedMusicFolderItem>>(
      context: context,
      builder: (_) => _SmartPlaylistDirectoryPickerDialog(
        controller: _ctrl,
        initialSelected: _selectedSources,
      ),
    );
    if (picked != null && picked.isNotEmpty && mounted) {
      setState(() {
        _selectedSources
          ..clear()
          ..addAll(picked);
        _scannedAllTracks = const [];
      });
    }
  }

  Future<void> _runKeywordSearchInSources({bool createImmediately = false}) async {
    if (_selectedSources.isEmpty) {
      setState(() => _searchError = '请先至少选择一个要查找的音乐目录');
      return;
    }
    final query = _keywordCtrl.text.trim();
    if (query.isEmpty) {
      setState(() => _searchError = '请输入要查找的歌手人名或关键词');
      return;
    }

    setState(() {
      _isSearchingTracks = true;
      _searchError = null;
      _searchProgressText = '正在扫描所选目录中的音乐...';
    });

    try {
      final allTracks = await _ctrl.collectTracksFromSources(
        sources: _selectedSources,
        includeSubfolders: _includeSubfolders,
        onProgress: (status, count) {
          if (mounted) {
            setState(() => _searchProgressText = status);
          }
        },
      );
      final matched = CloudMusicController.filterTracksByArtistOrKeywords(
        tracks: allTracks,
        query: query,
        matchAllKeywords: _matchAllKeywords,
      );
      if (!mounted) return;
      setState(() {
        _scannedAllTracks = allTracks;
        _matchedTracks = matched;
        _uncheckedTrackKeys.clear();
        _isSearchingTracks = false;
        _searchProgressText = '';
        if (!_playlistNameManuallyEdited ||
            _newPlaylistNameCtrl.text.trim().isEmpty) {
          _newPlaylistNameCtrl.text = query;
        }
        if (matched.isEmpty) {
          _searchError =
              '已在所选目录共扫描 ${allTracks.length} 首歌曲，未找到包含「$query」的歌曲';
        }
      });

      if (createImmediately && matched.isNotEmpty) {
        await _createPlaylistFromMatchedTracks(autoPlay: false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSearchingTracks = false;
        _searchProgressText = '';
        _searchError = '扫描目录查找失败：$e';
      });
    }
  }

  Future<void> _createPlaylistFromMatchedTracks({required bool autoPlay}) async {
    final chosenTracks = _matchedTracks
        .where((t) => !_uncheckedTrackKeys.contains(_trackKey(t)))
        .toList();
    if (chosenTracks.isEmpty) {
      setState(() => _searchError = '请至少勾选一首歌曲以创建播放列表');
      return;
    }
    final rawName = _newPlaylistNameCtrl.text.trim();
    final name = rawName.isNotEmpty
        ? rawName
        : (_keywordCtrl.text.trim().isNotEmpty
            ? _keywordCtrl.text.trim()
            : '目录搜歌歌单');

    final created = await _ctrl.createPlaylistWithTracks(
      name: name,
      tracks: chosenTracks,
      sources: _selectedSources,
      switchToPlaylist: true,
      autoPlay: autoPlay,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已新建播放列表「${created.name}」（共 ${created.tracks.length} 首）'),
      ),
    );
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _saveInlineAiSettings() async {
    final state = _ctrl.boundAppState;
    if (state == null) return;
    await state.saveAiConfig(
      provider: _inlineAiProvider,
      apiKey: _inlineAiKeyCtrl.text.trim(),
      baseUrl: _inlineAiBaseUrlCtrl.text.trim(),
      model: _inlineAiModelCtrl.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      if (state.hasAiApiKey) {
        _showInlineAiConfig = false;
      }
      _aiError = null;
    });
  }

  Future<void> _runAiDirectoryAnalysis({bool createImmediately = false}) async {
    if (_selectedSources.isEmpty) {
      setState(() => _aiError = '请先至少选择一个要分析的音乐目录');
      return;
    }

    final state = _ctrl.boundAppState;
    if (_showInlineAiConfig && _inlineAiKeyCtrl.text.trim().isNotEmpty) {
      await _saveInlineAiSettings();
    }
    final effectiveKey = _inlineAiKeyCtrl.text.trim().isNotEmpty
        ? _inlineAiKeyCtrl.text.trim()
        : (state?.aiApiKey ?? '');

    if (effectiveKey.isEmpty && _ctrl.customAiCompletionHandler == null) {
      setState(() {
        _showInlineAiConfig = true;
        _aiError = '请先填写 AI API Key（也可在「设置 -> AI 智能音乐分析与 API Key 设置」中配置）';
      });
      return;
    }

    setState(() {
      _isAnalyzingAi = true;
      _aiError = null;
      _aiProgressText = '正在扫描所选目录曲库...';
    });

    try {
      final allTracks = _scannedAllTracks.isNotEmpty
          ? _scannedAllTracks
          : await _ctrl.collectTracksFromSources(
              sources: _selectedSources,
              includeSubfolders: _includeSubfolders,
              onProgress: (status, count) {
                if (mounted) {
                  setState(() => _aiProgressText = status);
                }
              },
            );
      if (!mounted) return;
      if (allTracks.isEmpty) {
        setState(() {
          _isAnalyzingAi = false;
          _aiProgressText = '';
          _aiError = '所选目录内未找到任何音频文件';
        });
        return;
      }

      setState(() {
        _scannedAllTracks = allTracks;
        _aiProgressText =
            '已扫描 ${allTracks.length} 首歌曲，正在请求 AI 按分类智能规划播放列表...';
      });

      final drafts = await _ctrl.analyzeTracksWithAi(
        tracks: allTracks,
        dimension: _aiDimension,
        customInstruction: _aiCustomInstructionCtrl.text.trim(),
        apiKeyOverride: effectiveKey,
        providerOverride: _inlineAiProvider,
        baseUrlOverride: _inlineAiBaseUrlCtrl.text.trim(),
        modelOverride: _inlineAiModelCtrl.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _aiDrafts = drafts;
        _selectedAiDraftIndices
          ..clear()
          ..addAll(List<int>.generate(drafts.length, (i) => i));
        _isAnalyzingAi = false;
        _aiProgressText = '';
      });

      if (createImmediately && drafts.isNotEmpty) {
        await _createSelectedAiPlaylists();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isAnalyzingAi = false;
        _aiProgressText = '';
        _aiError = 'AI 智能分析失败：$e';
      });
    }
  }

  Future<void> _createSelectedAiPlaylists() async {
    final chosen = [
      for (int i = 0; i < _aiDrafts.length; i++)
        if (_selectedAiDraftIndices.contains(i) &&
            _aiDrafts[i].tracks.isNotEmpty)
          _aiDrafts[i],
    ];
    if (chosen.isEmpty) {
      setState(() => _aiError = '请至少勾选一个 AI 生成的分类播放列表');
      return;
    }

    final createdList = <SavedMusicPlaylist>[];
    for (int i = 0; i < chosen.length; i++) {
      final draft = chosen[i];
      final pl = await _ctrl.createPlaylistWithTracks(
        name: draft.name,
        tracks: draft.tracks,
        sources: _selectedSources,
        switchToPlaylist: i == 0,
        autoPlay: false,
      );
      createdList.add(pl);
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'AI 已自动创建 ${createdList.length} 个分类播放列表：${createdList.map((e) => "「${e.name}」").join("、")}',
        ),
      ),
    );
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final isMobile = screenSize.width < 760;
    final availableHeight =
        (screenSize.height - viewInsets.bottom - (isMobile ? 84 : 120))
            .clamp(220.0, isMobile ? 640.0 : 680.0);

    return AlertDialog(
      backgroundColor: VideoPlatformTheme.bgElevated,
      insetPadding: EdgeInsets.symmetric(
        horizontal: isMobile ? 8 : 24,
        vertical: isMobile ? 10 : 20,
      ),
      titlePadding: EdgeInsets.fromLTRB(
        isMobile ? 14 : 20,
        isMobile ? 10 : 14,
        isMobile ? 8 : 12,
        4,
      ),
      contentPadding: EdgeInsets.fromLTRB(
        isMobile ? 12 : 20,
        6,
        isMobile ? 12 : 20,
        isMobile ? 8 : 12,
      ),
      actionsPadding: EdgeInsets.fromLTRB(
        isMobile ? 12 : 20,
        0,
        isMobile ? 12 : 20,
        isMobile ? 10 : 14,
      ),
      title: Row(
        children: [
          Icon(
            _activeTab == 0
                ? Icons.manage_search_rounded
                : Icons.auto_awesome_rounded,
            color: VideoPlatformTheme.accent,
            size: isMobile ? 20 : 22,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isMobile
                  ? (_activeTab == 0 ? '按人名 / 关键词搜歌建表' : 'AI 智能分析目录分类建表')
                  : (_activeTab == 0
                      ? '指定目录按人名 / 关键词查找并新建播放列表'
                      : 'AI 智能分析指定目录并按分类自动生成播放列表'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: isMobile ? 14.5 : 16,
                fontWeight: FontWeight.w800,
                color: VideoPlatformTheme.textPrimary,
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.of(context).pop(false),
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
      content: SizedBox(
        width: isMobile ? screenSize.width : 860,
        height: availableHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Mode Switcher Tabs
            Row(
              children: [
                Expanded(
                  child: _buildModeTabButton(
                    index: 0,
                    icon: Icons.manage_search_rounded,
                    label: isMobile ? '搜人名/关键词建表' : '按人名 / 关键词搜歌新建列表',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildModeTabButton(
                    index: 1,
                    icon: Icons.auto_awesome_rounded,
                    label: isMobile ? 'AI 智能分类建表' : 'AI 智能分析目录自动分类建表',
                  ),
                ),
              ],
            ),
            SizedBox(height: isMobile ? 8 : 10),
            // Target Directories Bar
            _buildTargetDirectoriesCard(isMobile: isMobile),
            SizedBox(height: isMobile ? 8 : 10),
            Expanded(
              child: _activeTab == 0
                  ? _buildKeywordSearchTabBody(isMobile: isMobile)
                  : _buildAiCategorizeTabBody(isMobile: isMobile),
            ),
          ],
        ),
      ),
      actions: isMobile
          ? [
              if (_activeTab == 0 && _matchedTracks.isNotEmpty)
                SizedBox(
                  width: double.infinity,
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                          ),
                          onPressed: () =>
                              _createPlaylistFromMatchedTracks(autoPlay: false),
                          icon: const Icon(
                            Icons.playlist_add_check_rounded,
                            size: 16,
                          ),
                          label: Text(
                            '新建列表 (${_matchedTracks.length - _uncheckedTrackKeys.length}首)',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                          ),
                          onPressed: () =>
                              _createPlaylistFromMatchedTracks(autoPlay: true),
                          icon: const Icon(Icons.play_arrow_rounded, size: 16),
                          label: const Text(
                            '新建并播放',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else if (_activeTab == 1 && _aiDrafts.isNotEmpty)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _createSelectedAiPlaylists,
                    icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                    label: Text(
                      '一键生成所选 ${_selectedAiDraftIndices.length} 个分类列表',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
                )
              else
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('关闭'),
                ),
            ]
          : [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('关闭'),
              ),
              if (_activeTab == 0 && _matchedTracks.isNotEmpty) ...[
                OutlinedButton.icon(
                  onPressed: () =>
                      _createPlaylistFromMatchedTracks(autoPlay: false),
                  icon: const Icon(Icons.playlist_add_check_rounded, size: 17),
                  label: Text(
                    '新建播放列表 (${_matchedTracks.length - _uncheckedTrackKeys.length} 首)',
                  ),
                ),
                FilledButton.icon(
                  onPressed: () =>
                      _createPlaylistFromMatchedTracks(autoPlay: true),
                  icon: const Icon(Icons.play_arrow_rounded, size: 17),
                  label: const Text('新建列表并立即播放'),
                ),
              ],
              if (_activeTab == 1 && _aiDrafts.isNotEmpty)
                FilledButton.icon(
                  onPressed: _createSelectedAiPlaylists,
                  icon: const Icon(Icons.auto_awesome_rounded, size: 17),
                  label: Text(
                    '一键生成所选 ${_selectedAiDraftIndices.length} 个分类播放列表',
                  ),
                ),
            ],
    );
  }

  Widget _buildModeTabButton({
    required int index,
    required IconData icon,
    required String label,
  }) {
    final selected = _activeTab == index;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => setState(() => _activeTab = index),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: selected
              ? VideoPlatformTheme.accent.withValues(alpha: 0.22)
              : VideoPlatformTheme.bgCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? VideoPlatformTheme.accent
                : VideoPlatformTheme.borderSubtle,
            width: 1.2,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 15,
              color: selected
                  ? VideoPlatformTheme.accent
                  : VideoPlatformTheme.textSecondary,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected
                      ? VideoPlatformTheme.accent
                      : VideoPlatformTheme.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTargetDirectoriesCard({required bool isMobile}) {
    Widget buildSelectedChipsStrip() {
      if (_selectedSources.isEmpty) {
        return Text(
          '尚未选择目录，请点击「选择指定目录」',
          style: TextStyle(
            fontSize: 11.5,
            color: VideoPlatformTheme.danger,
          ),
        );
      }
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (int i = 0; i < _selectedSources.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: InputChip(
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  label: Text(
                    '${_selectedSources[i].mountName}: ${_selectedSources[i].title}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  onDeleted: _selectedSources.length > 1
                      ? () => setState(() {
                            _selectedSources.removeAt(i);
                            _scannedAllTracks = const [];
                          })
                      : null,
                ),
              ),
          ],
        ),
      );
    }

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 10 : 12,
        vertical: isMobile ? 6 : 8,
      ),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: VideoPlatformTheme.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isMobile) ...[
            Row(
              children: [
                Icon(
                  Icons.folder_open_rounded,
                  size: 15,
                  color: VideoPlatformTheme.warning,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '扫描目录 (${_selectedSources.length} 个)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: VideoPlatformTheme.textPrimary,
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                  ),
                  onPressed: _openDirectorySelectorSheet,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 14),
                  label: const Text('选择目录', style: TextStyle(fontSize: 11.5)),
                ),
              ],
            ),
            const SizedBox(height: 5),
            SizedBox(
              height: 28,
              child: Align(
                alignment: Alignment.centerLeft,
                child: buildSelectedChipsStrip(),
              ),
            ),
          ] else
            Row(
              children: [
                Icon(
                  Icons.folder_open_rounded,
                  size: 16,
                  color: VideoPlatformTheme.warning,
                ),
                const SizedBox(width: 6),
                Text(
                  '指定扫描目录 (${_selectedSources.length} 个):',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: VideoPlatformTheme.textPrimary,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 32,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: buildSelectedChipsStrip(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _openDirectorySelectorSheet,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 15),
                  label: const Text('选择指定目录', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          if (_ctrl.savedMusicFolders.isNotEmpty) ...[
            const SizedBox(height: 5),
            SizedBox(
              height: 28,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    Text(
                      '常用快选: ',
                      style: TextStyle(
                        fontSize: 11,
                        color: VideoPlatformTheme.textMuted,
                      ),
                    ),
                    for (final fav in _ctrl.savedMusicFolders)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: FilterChip(
                          showCheckmark: false,
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          label: Text(
                            '${fav.mountName}: ${fav.title}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          selected: _selectedSources
                              .any((s) => s.uniqueKey == fav.uniqueKey),
                          onSelected: (sel) {
                            setState(() {
                              if (sel) {
                                if (!_selectedSources
                                    .any((s) => s.uniqueKey == fav.uniqueKey)) {
                                  _selectedSources.add(fav);
                                }
                              } else {
                                _selectedSources.removeWhere(
                                  (s) => s.uniqueKey == fav.uniqueKey,
                                );
                              }
                              _scannedAllTracks = const [];
                            });
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildKeywordSearchTabBody({required bool isMobile}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isMobile) ...[
          SizedBox(
            height: 38,
            child: TextField(
              controller: _keywordCtrl,
              style: const TextStyle(fontSize: 12.5),
              onChanged: (v) {
                if (!_playlistNameManuallyEdited) {
                  _newPlaylistNameCtrl.text = v.trim();
                }
              },
              onSubmitted: (_) => _runKeywordSearchInSources(),
              decoration: const InputDecoration(
                labelText: '输入指定人名 (歌手) 或关键词',
                hintText: '如：周杰伦、陈奕迅、粤语 (空格或逗号分隔)',
                floatingLabelBehavior: FloatingLabelBehavior.always,
                prefixIcon: Icon(Icons.person_search_rounded, size: 17),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 38,
            child: TextField(
              controller: _newPlaylistNameCtrl,
              style: const TextStyle(fontSize: 12.5),
              onChanged: (_) => _playlistNameManuallyEdited = true,
              decoration: const InputDecoration(
                labelText: '新建播放列表名称',
                hintText: '默认使用查找的人名或关键词',
                floatingLabelBehavior: FloatingLabelBehavior.always,
                prefixIcon: Icon(Icons.queue_music_rounded, size: 17),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  label: const Text(
                    '匹配任一词 (OR)',
                    style: TextStyle(fontSize: 11),
                  ),
                  selected: !_matchAllKeywords,
                  onSelected: (_) => setState(() => _matchAllKeywords = false),
                ),
                const SizedBox(width: 6),
                ChoiceChip(
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  label: const Text(
                    '同时包含 (AND)',
                    style: TextStyle(fontSize: 11),
                  ),
                  selected: _matchAllKeywords,
                  onSelected: (_) => setState(() => _matchAllKeywords = true),
                ),
                const SizedBox(width: 6),
                FilterChip(
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  label: const Text(
                    '含子目录与压缩包',
                    style: TextStyle(fontSize: 11),
                  ),
                  selected: _includeSubfolders,
                  onSelected: (v) => setState(() {
                    _includeSubfolders = v;
                    _scannedAllTracks = const [];
                  }),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                  onPressed: _isSearchingTracks
                      ? null
                      : () =>
                          _runKeywordSearchInSources(createImmediately: false),
                  icon: const Icon(Icons.search_rounded, size: 15),
                  label: const Text(
                    '在指定目录中查找歌曲',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                  onPressed: _isSearchingTracks
                      ? null
                      : () =>
                          _runKeywordSearchInSources(createImmediately: true),
                  icon: const Icon(Icons.playlist_add_rounded, size: 15),
                  label: const Text(
                    '查找并直接建表',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
        ] else ...[
          SizedBox(
            height: 40,
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _keywordCtrl,
                    onChanged: (v) {
                      if (!_playlistNameManuallyEdited) {
                        _newPlaylistNameCtrl.text = v.trim();
                      }
                    },
                    onSubmitted: (_) => _runKeywordSearchInSources(),
                    decoration: const InputDecoration(
                      labelText: '输入指定人名 (歌手) 或关键词',
                      hintText: '例如：周杰伦、陈奕迅、粤语、无损 (多个词用空格或逗号分隔)',
                      floatingLabelBehavior: FloatingLabelBehavior.always,
                      prefixIcon: Icon(Icons.person_search_rounded, size: 18),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _newPlaylistNameCtrl,
                    onChanged: (_) => _playlistNameManuallyEdited = true,
                    decoration: const InputDecoration(
                      labelText: '新建播放列表名称',
                      hintText: '默认使用查找的人名或关键词',
                      floatingLabelBehavior: FloatingLabelBehavior.always,
                      prefixIcon: Icon(Icons.queue_music_rounded, size: 18),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ChoiceChip(
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                label: const Text(
                  '匹配任一关键词 (OR)',
                  style: TextStyle(fontSize: 11.5),
                ),
                selected: !_matchAllKeywords,
                onSelected: (_) => setState(() => _matchAllKeywords = false),
              ),
              ChoiceChip(
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                label: const Text(
                  '同时包含所有关键词 (AND)',
                  style: TextStyle(fontSize: 11.5),
                ),
                selected: _matchAllKeywords,
                onSelected: (_) => setState(() => _matchAllKeywords = true),
              ),
              FilterChip(
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                label: const Text(
                  '包含子目录与压缩包',
                  style: TextStyle(fontSize: 11.5),
                ),
                selected: _includeSubfolders,
                onSelected: (v) => setState(() {
                  _includeSubfolders = v;
                  _scannedAllTracks = const [];
                }),
              ),
              FilledButton.icon(
                onPressed: _isSearchingTracks
                    ? null
                    : () => _runKeywordSearchInSources(createImmediately: false),
                icon: const Icon(Icons.search_rounded, size: 16),
                label: const Text('在指定目录中查找歌曲'),
              ),
              OutlinedButton.icon(
                onPressed: _isSearchingTracks
                    ? null
                    : () => _runKeywordSearchInSources(createImmediately: true),
                icon: const Icon(Icons.playlist_add_rounded, size: 16),
                label: const Text('查找并直接新建播放列表'),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        if (_isSearchingTracks)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: VideoPlatformTheme.accent),
                  const SizedBox(height: 12),
                  Text(
                    _searchProgressText,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: VideoPlatformTheme.textSecondary),
                  ),
                ],
              ),
            ),
          )
        else if (_searchError != null)
          Expanded(
            child: Center(
              child: Text(
                _searchError!,
                textAlign: TextAlign.center,
                style: TextStyle(color: VideoPlatformTheme.danger),
              ),
            ),
          )
        else if (_matchedTracks.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                '输入歌手人名（如“周杰伦”、“陈奕迅”）或关键词后，点击「在指定目录中查找歌曲」即可汇总并用找到的歌曲新建播放列表',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: isMobile ? 12 : 13,
                  color: VideoPlatformTheme.textMuted,
                ),
              ),
            ),
          )
        else
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '共找到 ${_matchedTracks.length} 首匹配歌曲（已选 ${_matchedTracks.length - _uncheckedTrackKeys.length} 首）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: isMobile ? 12 : 12.5,
                          fontWeight: FontWeight.w700,
                          color: VideoPlatformTheme.accent,
                        ),
                      ),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () =>
                          setState(() => _uncheckedTrackKeys.clear()),
                      child: const Text('全选', style: TextStyle(fontSize: 12)),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => setState(() {
                        if (_uncheckedTrackKeys.length ==
                            _matchedTracks.length) {
                          _uncheckedTrackKeys.clear();
                        } else {
                          _uncheckedTrackKeys
                            ..clear()
                            ..addAll(_matchedTracks.map(_trackKey));
                        }
                      }),
                      child: const Text('反选', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                Expanded(
                  child: Material(
                    color: VideoPlatformTheme.bgCard,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(color: VideoPlatformTheme.borderSubtle),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: ListView.separated(
                      itemCount: _matchedTracks.length,
                      separatorBuilder: (_, __) => Divider(
                        height: 1,
                        color: VideoPlatformTheme.borderSubtle,
                      ),
                      itemBuilder: (context, idx) {
                        final track = _matchedTracks[idx];
                        final key = _trackKey(track);
                        final checked = !_uncheckedTrackKeys.contains(key);
                        final meta = CloudMusicController.parseTrackMetadata(
                          track,
                          fallbackArtist: _ctrl.mountNameFor(track),
                        );
                        return CheckboxListTile(
                          dense: true,
                          value: checked,
                          activeColor: VideoPlatformTheme.accent,
                          onChanged: (v) {
                            setState(() {
                              if (v == true) {
                                _uncheckedTrackKeys.remove(key);
                              } else {
                                _uncheckedTrackKeys.add(key);
                              }
                            });
                          },
                          title: Text(
                            meta.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            '${meta.artist} · ${track.path} · ${track.formattedSize}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: VideoPlatformTheme.textMuted,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildAiCategorizeTabBody({required bool isMobile}) {
    final state = _ctrl.boundAppState;
    final hasKey =
        (state?.hasAiApiKey ?? false) || _inlineAiKeyCtrl.text.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // AI API Key Status / Inline Configuration Bar
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: isMobile ? 10 : 12,
            vertical: isMobile ? 6 : 8,
          ),
          decoration: BoxDecoration(
            color: VideoPlatformTheme.bgCard,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: hasKey
                  ? VideoPlatformTheme.accent.withValues(alpha: 0.45)
                  : VideoPlatformTheme.warning.withValues(alpha: 0.6),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    hasKey ? Icons.verified_rounded : Icons.key_rounded,
                    size: 15,
                    color: hasKey
                        ? VideoPlatformTheme.success
                        : VideoPlatformTheme.warning,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      hasKey
                          ? 'AI 接口就绪：${(state?.effectiveAiProvider ?? _inlineAiProvider).toUpperCase()} · ${state?.effectiveAiModel ?? "默认"}'
                          : (isMobile
                              ? '尚未配置 AI API Key（点击右侧配置）'
                              : '尚未配置 AI API Key（可在下方直接填写，或在「设置」页中配置）'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: isMobile ? 11.5 : 12,
                        fontWeight: FontWeight.w600,
                        color: hasKey
                            ? VideoPlatformTheme.textPrimary
                            : VideoPlatformTheme.warning,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                    onPressed: () => setState(
                      () => _showInlineAiConfig = !_showInlineAiConfig,
                    ),
                    icon: Icon(
                      _showInlineAiConfig
                          ? Icons.expand_less_rounded
                          : Icons.settings_rounded,
                      size: 14,
                    ),
                    label: Text(
                      _showInlineAiConfig
                          ? '收起'
                          : (isMobile ? '配置 Key' : '设置 AI API Key'),
                      style: const TextStyle(fontSize: 11.5),
                    ),
                  ),
                ],
              ),
              if (_showInlineAiConfig) ...[
                const SizedBox(height: 6),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final item in const [
                        ('openai', 'OpenAI / 兼容'),
                        ('deepseek', 'DeepSeek'),
                        ('qwen', '通义千问'),
                        ('gemini', 'Google Gemini'),
                        ('claude', 'Claude'),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            showCheckmark: false,
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            label: Text(
                              item.$2,
                              style: const TextStyle(fontSize: 11),
                            ),
                            selected: _inlineAiProvider == item.$1,
                            onSelected: (sel) {
                              if (sel) {
                                setState(() => _inlineAiProvider = item.$1);
                              }
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                if (isMobile) ...[
                  SizedBox(
                    height: 38,
                    child: TextField(
                      controller: _inlineAiKeyCtrl,
                      style: const TextStyle(fontSize: 12),
                      decoration: const InputDecoration(
                        labelText: 'AI API Key',
                        hintText: '输入 sk-... 或 AIza...',
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 36,
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _inlineAiModelCtrl,
                            style: const TextStyle(fontSize: 12),
                            decoration: const InputDecoration(
                              labelText: '模型 (可选)',
                              hintText: 'gpt-4o-mini / deepseek-chat',
                              floatingLabelBehavior:
                                  FloatingLabelBehavior.always,
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: _saveInlineAiSettings,
                          child: const Text(
                            '保存 Key',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else
                  SizedBox(
                    height: 40,
                    child: Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: TextField(
                            controller: _inlineAiKeyCtrl,
                            decoration: const InputDecoration(
                              labelText: 'AI API Key',
                              hintText: '输入 sk-... 或 AIza...',
                              floatingLabelBehavior:
                                  FloatingLabelBehavior.always,
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: _inlineAiModelCtrl,
                            decoration: const InputDecoration(
                              labelText: '模型 (可选)',
                              hintText: 'gpt-4o-mini / deepseek-chat',
                              floatingLabelBehavior:
                                  FloatingLabelBehavior.always,
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _saveInlineAiSettings,
                          child: const Text('保存 Key'),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 6),
        // Classification Dimension Chips
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              Text(
                '分类方式: ',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: VideoPlatformTheme.textSecondary,
                ),
              ),
              for (final dim in const [
                ('auto', 'AI 综合智能归类'),
                ('artist', '按歌手 / 艺术家'),
                ('genre', '按曲风 / 流派'),
                ('mood', '按心情 / 场景'),
                ('language', '按语种 / 地区'),
                ('era', '按年代 / 时期'),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    label: Text(dim.$2, style: const TextStyle(fontSize: 11)),
                    selected: _aiDimension == dim.$1,
                    onSelected: (sel) {
                      if (sel) setState(() => _aiDimension = dim.$1);
                    },
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        if (isMobile) ...[
          SizedBox(
            height: 38,
            child: TextField(
              controller: _aiCustomInstructionCtrl,
              style: const TextStyle(fontSize: 12),
              decoration: const InputDecoration(
                labelText: '自定义分类要求 (可选)',
                hintText: '如：按粤语怀旧、周杰伦精选、开车快歌分类',
                floatingLabelBehavior: FloatingLabelBehavior.always,
                isDense: true,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                  onPressed: _isAnalyzingAi
                      ? null
                      : () => _runAiDirectoryAnalysis(createImmediately: false),
                  icon: const Icon(Icons.auto_awesome_rounded, size: 15),
                  label: const Text(
                    'AI 分析目录并预览分类',
                    style: TextStyle(fontSize: 11.5),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                  onPressed: _isAnalyzingAi
                      ? null
                      : () => _runAiDirectoryAnalysis(createImmediately: true),
                  icon: const Icon(Icons.playlist_add_check_rounded, size: 15),
                  label: const Text(
                    'AI 分析并直接生成列表',
                    style: TextStyle(fontSize: 11.5),
                  ),
                ),
              ),
            ],
          ),
        ] else
          SizedBox(
            height: 40,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _aiCustomInstructionCtrl,
                    decoration: const InputDecoration(
                      labelText: '自定义分类要求 (可选)',
                      hintText: '例如：帮我按粤语怀旧、周杰伦精选、适合开车听的快歌分成三类',
                      floatingLabelBehavior: FloatingLabelBehavior.always,
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: _isAnalyzingAi
                      ? null
                      : () => _runAiDirectoryAnalysis(createImmediately: false),
                  icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                  label: const Text('AI 分析目录并预览分类'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _isAnalyzingAi
                      ? null
                      : () => _runAiDirectoryAnalysis(createImmediately: true),
                  icon: const Icon(Icons.playlist_add_check_rounded, size: 16),
                  label: const Text('AI 分析并直接生成列表'),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        if (_isAnalyzingAi)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: VideoPlatformTheme.accent),
                  const SizedBox(height: 12),
                  Text(
                    _aiProgressText,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: VideoPlatformTheme.textSecondary),
                  ),
                ],
              ),
            ),
          )
        else if (_aiError != null)
          Expanded(
            child: Center(
              child: Text(
                _aiError!,
                textAlign: TextAlign.center,
                style: TextStyle(color: VideoPlatformTheme.danger),
              ),
            ),
          )
        else if (_aiDrafts.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                '选择分类方式后，点击「AI 分析目录并预览分类」，AI 将自动扫描指定目录中的全部歌曲并按分类生成多个播放列表',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: isMobile ? 12 : 13,
                  color: VideoPlatformTheme.textMuted,
                ),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              itemCount: _aiDrafts.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, idx) {
                final draft = _aiDrafts[idx];
                final checked = _selectedAiDraftIndices.contains(idx);
                final previewNames = draft.tracks
                    .take(6)
                    .map((t) => CloudMusicController.parseTrackMetadata(t).title)
                    .join('、');

                return Material(
                  color: VideoPlatformTheme.bgCard,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(
                      color: checked
                          ? VideoPlatformTheme.accent
                          : VideoPlatformTheme.borderSubtle,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: CheckboxListTile(
                    dense: isMobile,
                    value: checked,
                    activeColor: VideoPlatformTheme.accent,
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _selectedAiDraftIndices.add(idx);
                        } else {
                          _selectedAiDraftIndices.remove(idx);
                        }
                      });
                    },
                    title: Row(
                      children: [
                        Icon(
                          Icons.queue_music_rounded,
                          size: 16,
                          color: VideoPlatformTheme.accent,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            draft.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: isMobile ? 13 : 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: VideoPlatformTheme.accent
                                .withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${draft.tracks.length} 首',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: VideoPlatformTheme.accent,
                            ),
                          ),
                        ),
                      ],
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (draft.description.isNotEmpty)
                            Text(
                              draft.description,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: VideoPlatformTheme.textSecondary,
                              ),
                            ),
                          const SizedBox(height: 2),
                          Text(
                            '包含曲目：$previewNames${draft.tracks.length > 6 ? " 等 ${draft.tracks.length} 首" : ""}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: VideoPlatformTheme.textMuted,
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
    );
  }
}

class _SmartPlaylistDirectoryPickerDialog extends StatefulWidget {
  final CloudMusicController controller;
  final List<SavedMusicFolderItem> initialSelected;

  const _SmartPlaylistDirectoryPickerDialog({
    required this.controller,
    required this.initialSelected,
  });

  @override
  State<_SmartPlaylistDirectoryPickerDialog> createState() =>
      _SmartPlaylistDirectoryPickerDialogState();
}

class _SmartPlaylistDirectoryPickerDialogState
    extends State<_SmartPlaylistDirectoryPickerDialog> {
  StorageMount? _activeMount;
  String _currentPath = '/';
  String _currentTitle = '根目录';
  final List<({String path, String title})> _breadcrumbs = [];
  List<FileEntry> _entries = const [];
  bool _isLoading = false;
  late final List<SavedMusicFolderItem> _selected;

  @override
  void initState() {
    super.initState();
    _selected = List<SavedMusicFolderItem>.from(widget.initialSelected);
    if (widget.controller.availableMounts.isNotEmpty) {
      _selectMount(widget.controller.availableMounts.first);
    }
  }

  Future<void> _selectMount(StorageMount mount) async {
    setState(() {
      _activeMount = mount;
      _currentPath = mount.rootPath;
      _currentTitle = mount.name;
      _breadcrumbs
        ..clear()
        ..add((path: mount.rootPath, title: mount.name));
    });
    await _loadDir(mount.rootPath, title: mount.name, pushCrumb: false);
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
      _currentPath = path;
      _currentTitle = title;
      if (pushCrumb) {
        final idx = _breadcrumbs.indexWhere((b) => b.path == path);
        if (idx >= 0) {
          _breadcrumbs.removeRange(idx + 1, _breadcrumbs.length);
        } else {
          _breadcrumbs.add((path: path, title: title));
        }
      }
    });
    try {
      final list = await widget.controller.listDirectoryForMount(mount, path);
      if (!mounted) return;
      setState(() {
        _entries = list
            .where((e) => e.isDir || e.isStreamableMusicArchive)
            .toList();
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  SavedMusicFolderItem _currentDirItem() {
    final m = _activeMount!;
    return SavedMusicFolderItem(
      mountId: m.id,
      mountName: m.name,
      sourceKind: m.kind,
      path: _currentPath,
      title: _currentTitle,
    );
  }

  void _toggleItem(SavedMusicFolderItem item) {
    setState(() {
      final idx = _selected.indexWhere((s) => s.uniqueKey == item.uniqueKey);
      if (idx >= 0) {
        _selected.removeAt(idx);
      } else {
        _selected.add(item);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final mounts = widget.controller.availableMounts;
    final activeMount = _activeMount;
    final screenSize = MediaQuery.sizeOf(context);
    final isMobile = screenSize.width < 680;

    return AlertDialog(
      backgroundColor: VideoPlatformTheme.bgElevated,
      insetPadding: EdgeInsets.symmetric(
        horizontal: isMobile ? 10 : 24,
        vertical: isMobile ? 14 : 24,
      ),
      titlePadding: EdgeInsets.fromLTRB(
        isMobile ? 14 : 20,
        isMobile ? 12 : 16,
        isMobile ? 10 : 14,
        6,
      ),
      contentPadding: EdgeInsets.fromLTRB(
        isMobile ? 12 : 20,
        6,
        isMobile ? 12 : 20,
        10,
      ),
      title: Row(
        children: [
          Icon(
            Icons.create_new_folder_rounded,
            size: isMobile ? 19 : 21,
            color: VideoPlatformTheme.accent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '选择要扫描或 AI 分析的音乐目录',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: isMobile ? 14.5 : 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: isMobile ? screenSize.width : 660,
        height: (screenSize.height * 0.62).clamp(280.0, 440.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final m in mounts)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        label: Text(
                          m.name,
                          style: TextStyle(fontSize: isMobile ? 11.5 : 12.5),
                        ),
                        selected: activeMount?.id == m.id,
                        onSelected: (_) => _selectMount(m),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (activeMount != null)
              Row(
                children: [
                  if (_breadcrumbs.length >= 2) ...[
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () {
                        final prev = _breadcrumbs[_breadcrumbs.length - 2];
                        _loadDir(prev.path, title: prev.title);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: VideoPlatformTheme.bgCard,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: VideoPlatformTheme.borderSubtle,
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.arrow_back_rounded, size: 13),
                            SizedBox(width: 2),
                            Text('上级', style: TextStyle(fontSize: 11)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      '位置：${_breadcrumbs.map((b) => b.title).join(" / ")}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: VideoPlatformTheme.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                    ),
                    onPressed: () => _toggleItem(_currentDirItem()),
                    icon: const Icon(Icons.check_box_outlined, size: 14),
                    label: Text(
                      isMobile ? '选此目录' : '勾选当前目录',
                      style: const TextStyle(fontSize: 11.5),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 8),
            Expanded(
              child: Material(
                color: VideoPlatformTheme.bgCard,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(color: VideoPlatformTheme.borderSubtle),
                ),
                clipBehavior: Clip.antiAlias,
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        itemCount: _entries.length,
                        itemBuilder: (context, idx) {
                          final e = _entries[idx];
                          final item = SavedMusicFolderItem(
                            mountId: activeMount!.id,
                            mountName: activeMount.name,
                            sourceKind: activeMount.kind,
                            path: e.path,
                            title: e.name,
                            isArchive: e.isStreamableMusicArchive,
                            size: e.size,
                            pickcode115: e.pickcode115,
                          );
                          final checked = _selected
                              .any((s) => s.uniqueKey == item.uniqueKey);
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              e.isDir
                                  ? Icons.folder_rounded
                                  : Icons.folder_zip_rounded,
                              color: VideoPlatformTheme.warning,
                              size: 20,
                            ),
                            title: Text(
                              e.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                            onTap: e.isDir
                                ? () => _loadDir(e.path, title: e.name)
                                : () => _toggleItem(item),
                            trailing: Checkbox(
                              value: checked,
                              onChanged: (_) => _toggleItem(item),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            if (_selected.isEmpty && _activeMount != null) {
              _selected.add(_currentDirItem());
            }
            Navigator.of(context).pop(_selected);
          },
          child: Text('确定选择 (${_selected.isEmpty ? 1 : _selected.length})'),
        ),
      ],
    );
  }
}
