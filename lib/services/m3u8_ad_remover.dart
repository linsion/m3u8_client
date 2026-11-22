import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class M3u8CleanResult {
  /// Cleaned local `.m3u8` file path, or original URL if not modified.
  final String playTarget;

  /// Whether [playTarget] is a local file path.
  final bool isLocalFile;

  /// Number of ad TS segments stripped.
  final int removedSegments;

  /// Total duration (in seconds) of stripped ad segments.
  final double removedSeconds;

  const M3u8CleanResult({
    required this.playTarget,
    required this.isLocalFile,
    this.removedSegments = 0,
    this.removedSeconds = 0.0,
  });
}

class _M3u8Segment {
  final List<String> metadataLines;
  final String uriLine;
  final String absoluteUri;
  final double duration;
  final String? keyLine;

  const _M3u8Segment({
    required this.metadataLines,
    required this.uriLine,
    required this.absoluteUri,
    required this.duration,
    required this.keyLine,
  });
}

class _DiscontinuityBlock {
  final List<_M3u8Segment> segments;
  final int blockIndex;

  const _DiscontinuityBlock({
    required this.segments,
    required this.blockIndex,
  });

  double get totalDuration =>
      segments.fold(0.0, (sum, seg) => sum + seg.duration);

  /// Structural prefix signature of segment URLs in this block:
  /// scheme + host + directory path
  String get dirSignature {
    if (segments.isEmpty) return '';
    final counts = <String, int>{};
    for (final s in segments) {
      final sig = _extractUrlDirSignature(s.absoluteUri);
      counts[sig] = (counts[sig] ?? 0) + 1;
    }
    String best = '';
    int bestCount = -1;
    counts.forEach((k, v) {
      if (v > bestCount) {
        bestCount = v;
        best = k;
      }
    });
    return best;
  }

  /// Dominant filename length & pattern signature in this block
  String get filenamePatternSignature {
    if (segments.isEmpty) return '';
    final counts = <String, int>{};
    for (final s in segments) {
      final pat = _extractFilenamePattern(s.absoluteUri);
      counts[pat] = (counts[pat] ?? 0) + 1;
    }
    String best = '';
    int bestCount = -1;
    counts.forEach((k, v) {
      if (v > bestCount) {
        bestCount = v;
        best = k;
      }
    });
    return best;
  }

  String? get keySignature {
    if (segments.isEmpty) return null;
    return segments.first.keyLine;
  }
}

/// Intelligent HLS (`.m3u8`) ad segment detector and stripper for VOD streams.
class M3u8AdRemover {
  static final RegExp _extInfRegex = RegExp(r'^#EXTINF:([0-9.]+)');
  static final RegExp _uriAttrRegex = RegExp(
    r'''URI=(?:"([^"]+)"|'([^']+)')''',
    caseSensitive: false,
  );
  static final RegExp _knownAdUrlPattern = RegExp(
    r'(\/ad\/|\/ads\/|\/advert|adjump|guanggao|ad_ts|adsegment|\/gg\/)',
    caseSensitive: false,
  );

  /// Fetches a VOD `.m3u8` URL, resolves nested master playlists if needed,
  /// strips `#EXT-X-DISCONTINUITY` ad blocks and known ad segments, rewrites
  /// relative URLs to absolute URLs, and saves a clean local `.m3u8` file.
  static Future<M3u8CleanResult> cleanVodM3u8({
    required String url,
    required Map<String, String> headers,
    required http.Client client,
  }) async {
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return M3u8CleanResult(playTarget: trimmed, isLocalFile: false);
    }

    final lowerPath = uri.path.toLowerCase();
    final lowerQuery = uri.query.toLowerCase();
    final looksLikeM3u8 = lowerPath.endsWith('.m3u8') ||
        lowerPath.contains('.m3u8/') ||
        lowerQuery.contains('.m3u8');
    if (!looksLikeM3u8) {
      return M3u8CleanResult(playTarget: trimmed, isLocalFile: false);
    }

    try {
      var currentUri = uri;
      var body = await _fetchText(currentUri, headers, client);
      if (body == null || !body.contains('#EXTM3U')) {
        return M3u8CleanResult(playTarget: trimmed, isLocalFile: false);
      }

      // Resolve Master Playlist (`#EXT-X-STREAM-INF`) up to 2 levels deep
      for (var depth = 0; depth < 2; depth++) {
        if (!body!.contains('#EXT-X-STREAM-INF')) break;
        final variantUri = extractBestVariantUri(body, currentUri);
        if (variantUri == null) break;
        final nextBody = await _fetchText(variantUri, headers, client);
        if (nextBody == null || !nextBody.contains('#EXTM3U')) break;
        currentUri = variantUri;
        body = nextBody;
      }

      if (body == null || !body.contains('#EXTINF')) {
        return M3u8CleanResult(playTarget: trimmed, isLocalFile: false);
      }

      final stripped = stripAdsFromMediaPlaylist(
        body,
        baseUri: currentUri,
      );

      // Even if 0 ad segments were found, if we already fetched and resolved
      // the media playlist, only use the local file when ads were actually
      // removed so normal playback remains completely untouched.
      if (stripped.removedSegments <= 0) {
        return M3u8CleanResult(
          playTarget: currentUri.toString(),
          isLocalFile: false,
          removedSegments: 0,
          removedSeconds: 0.0,
        );
      }

      final tempDir = await Directory.systemTemp.createTemp('m3u8_adfree_');
      final outFile = File('${tempDir.path}/playlist.m3u8');
      await outFile.writeAsString(stripped.cleanedM3u8, flush: true);

      return M3u8CleanResult(
        playTarget: outFile.path,
        isLocalFile: true,
        removedSegments: stripped.removedSegments,
        removedSeconds: stripped.removedSeconds,
      );
    } catch (_) {
      return M3u8CleanResult(playTarget: trimmed, isLocalFile: false);
    }
  }

  static Future<String?> _fetchText(
    Uri uri,
    Map<String, String> headers,
    http.Client client,
  ) async {
    final response = await client
        .get(
          uri,
          headers: {
            'Accept': '*/*',
            ...headers,
          },
        )
        .timeout(const Duration(milliseconds: 2200));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  /// Extracts the highest-bandwidth or first variant URI from a Master Playlist.
  static Uri? extractBestVariantUri(String masterContent, Uri baseUri) {
    final lines = const LineSplitter().convert(masterContent);
    Uri? bestUri;
    int bestBandwidth = -1;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('#EXT-X-STREAM-INF')) {
        int bw = 0;
        final bwMatch = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
        if (bwMatch != null) {
          bw = int.tryParse(bwMatch.group(1)!) ?? 0;
        }
        // Find the next non-empty, non-comment line
        for (var j = i + 1; j < lines.length; j++) {
          final nextLine = lines[j].trim();
          if (nextLine.isEmpty) continue;
          if (nextLine.startsWith('#')) break;
          final resolved = baseUri.resolve(nextLine);
          if (bw >= bestBandwidth) {
            bestBandwidth = bw;
            bestUri = resolved;
          }
          break;
        }
      }
    }
    return bestUri;
  }

  /// Pure function that parses a media `.m3u8` playlist, removes ad blocks
  /// separated by `#EXT-X-DISCONTINUITY` or matching ad URL rules, and
  /// rewrites relative segment/key URLs to absolute URLs.
  static ({
    String cleanedM3u8,
    int removedSegments,
    double removedSeconds,
  }) stripAdsFromMediaPlaylist(
    String content, {
    required Uri baseUri,
  }) {
    final lines = const LineSplitter().convert(content);
    final headerLines = <String>[];
    final blocks = <_DiscontinuityBlock>[];
    var currentBlockSegments = <_M3u8Segment>[];
    var pendingMeta = <String>[];
    double pendingDuration = 0.0;
    String? currentKeyLine;
    bool seenFirstSegmentOrDiscontinuity = false;

    void flushBlock() {
      if (currentBlockSegments.isNotEmpty) {
        blocks.add(
          _DiscontinuityBlock(
            segments: List.unmodifiable(currentBlockSegments),
            blockIndex: blocks.length,
          ),
        );
        currentBlockSegments = <_M3u8Segment>[];
      }
    }

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXT-X-DISCONTINUITY')) {
        seenFirstSegmentOrDiscontinuity = true;
        flushBlock();
        pendingMeta.clear();
        continue;
      }

      if (line.startsWith('#EXT-X-KEY:')) {
        seenFirstSegmentOrDiscontinuity = true;
        currentKeyLine = _rewriteTagUriAttribute(line, baseUri);
        continue;
      }

      if (line.startsWith('#EXT-X-MAP:')) {
        seenFirstSegmentOrDiscontinuity = true;
        pendingMeta.add(_rewriteTagUriAttribute(line, baseUri));
        continue;
      }

      if (line.startsWith('#EXTINF:')) {
        seenFirstSegmentOrDiscontinuity = true;
        final m = _extInfRegex.firstMatch(line);
        pendingDuration =
            m != null ? (double.tryParse(m.group(1)!) ?? 0.0) : 0.0;
        pendingMeta.add(line);
        continue;
      }

      if (line.startsWith('#')) {
        // Playlist-level tags
        if (line.startsWith('#EXTM3U') ||
            line.startsWith('#EXT-X-VERSION') ||
            line.startsWith('#EXT-X-TARGETDURATION') ||
            line.startsWith('#EXT-X-MEDIA-SEQUENCE') ||
            line.startsWith('#EXT-X-PLAYLIST-TYPE') ||
            line.startsWith('#EXT-X-ALLOW-CACHE') ||
            line.startsWith('#EXT-X-INDEPENDENT-SEGMENTS')) {
          if (!headerLines.contains(line)) {
            headerLines.add(line);
          }
        } else if (line.startsWith('#EXT-X-ENDLIST')) {
          // Appended at the end
        } else if (!seenFirstSegmentOrDiscontinuity) {
          headerLines.add(line);
        } else {
          pendingMeta.add(line);
        }
        continue;
      }

      // Segment URI line
      seenFirstSegmentOrDiscontinuity = true;
      final absUri = baseUri.resolve(line).toString();
      currentBlockSegments.add(
        _M3u8Segment(
          metadataLines: List.unmodifiable(pendingMeta),
          uriLine: line,
          absoluteUri: absUri,
          duration: pendingDuration,
          keyLine: currentKeyLine,
        ),
      );
      pendingMeta = <String>[];
      pendingDuration = 0.0;
    }
    flushBlock();

    if (blocks.isEmpty) {
      return (
        cleanedM3u8: content,
        removedSegments: 0,
        removedSeconds: 0.0,
      );
    }

    // Determine dominant directory signature and filename pattern across total duration
    final dirDurationMap = <String, double>{};
    final patternDurationMap = <String, double>{};
    double totalPlaylistDuration = 0.0;

    for (final block in blocks) {
      final d = block.totalDuration;
      totalPlaylistDuration += d;
      final dirSig = block.dirSignature;
      final patSig = block.filenamePatternSignature;
      dirDurationMap[dirSig] = (dirDurationMap[dirSig] ?? 0.0) + d;
      patternDurationMap[patSig] = (patternDurationMap[patSig] ?? 0.0) + d;
    }

    String dominantDir = '';
    double bestDirDur = -1.0;
    dirDurationMap.forEach((k, v) {
      if (v > bestDirDur) {
        bestDirDur = v;
        dominantDir = k;
      }
    });

    String dominantPattern = '';
    double bestPatDur = -1.0;
    patternDurationMap.forEach((k, v) {
      if (v > bestPatDur) {
        bestPatDur = v;
        dominantPattern = k;
      }
    });

    int removedSegments = 0;
    double removedSeconds = 0.0;
    final keptBlocks = <_DiscontinuityBlock>[];

    for (final block in blocks) {
      final blockDur = block.totalDuration;
      final isShortBlock =
          blockDur <= 120.0 && blockDur < totalPlaylistDuration * 0.35;

      bool isAdBlock = false;

      // Rule 1: Explicit ad keywords in segment URLs
      if (block.segments.any((s) => _knownAdUrlPattern.hasMatch(s.absoluteUri))) {
        isAdBlock = true;
      }

      // Rule 2: Multiple discontinuity blocks where a short block comes from
      // a different server/directory than the main video content
      if (!isAdBlock &&
          blocks.length > 1 &&
          isShortBlock &&
          block.dirSignature != dominantDir) {
        isAdBlock = true;
      }

      // Rule 3: Multiple discontinuity blocks where a short block (<= 90s)
      // has a completely different filename naming pattern (e.g., ad hashes vs
      // sequential numbers, or different hash lengths) than the main content
      if (!isAdBlock &&
          blocks.length > 1 &&
          blockDur <= 90.0 &&
          blockDur < totalPlaylistDuration * 0.25 &&
          block.filenamePatternSignature != dominantPattern) {
        isAdBlock = true;
      }

      if (isAdBlock) {
        removedSegments += block.segments.length;
        removedSeconds += blockDur;
        continue;
      }

      // Even inside a kept block, filter individual segments matching explicit ad URLs
      final cleanSegs = <_M3u8Segment>[];
      for (final seg in block.segments) {
        if (_knownAdUrlPattern.hasMatch(seg.absoluteUri)) {
          removedSegments++;
          removedSeconds += seg.duration;
        } else {
          cleanSegs.add(seg);
        }
      }

      if (cleanSegs.isNotEmpty) {
        keptBlocks.add(
          _DiscontinuityBlock(
            segments: cleanSegs,
            blockIndex: block.blockIndex,
          ),
        );
      }
    }

    // Safety guard: never strip everything if a playlist was tiny or unusual
    if (keptBlocks.isEmpty) {
      return (
        cleanedM3u8: content,
        removedSegments: 0,
        removedSeconds: 0.0,
      );
    }

    final out = StringBuffer();
    if (headerLines.isEmpty || !headerLines.first.startsWith('#EXTM3U')) {
      out.writeln('#EXTM3U');
    }
    for (final h in headerLines) {
      out.writeln(h);
    }

    String? lastEmittedKey;
    for (var bIdx = 0; bIdx < keptBlocks.length; bIdx++) {
      final block = keptBlocks[bIdx];
      // Preserve `#EXT-X-DISCONTINUITY` between adjacent non-ad blocks (genuine PTS reset),
      // or when encryption key / directory changed after stripping an intermediate ad block.
      if (bIdx > 0) {
        final prevBlock = keptBlocks[bIdx - 1];
        final wasAdjacentInOriginal =
            block.blockIndex == prevBlock.blockIndex + 1;
        if (wasAdjacentInOriginal ||
            prevBlock.dirSignature != block.dirSignature ||
            prevBlock.keySignature != block.keySignature) {
          out.writeln('#EXT-X-DISCONTINUITY');
        }
      }
      for (final seg in block.segments) {
        if (seg.keyLine != null && seg.keyLine != lastEmittedKey) {
          out.writeln(seg.keyLine!);
          lastEmittedKey = seg.keyLine;
        }
        for (final meta in seg.metadataLines) {
          out.writeln(meta);
        }
        out.writeln(seg.absoluteUri);
      }
    }
    if (content.contains('#EXT-X-ENDLIST')) {
      out.writeln('#EXT-X-ENDLIST');
    }

    return (
      cleanedM3u8: out.toString(),
      removedSegments: removedSegments,
      removedSeconds: removedSeconds,
    );
  }

  static String _rewriteTagUriAttribute(String tagLine, Uri baseUri) {
    return tagLine.replaceAllMapped(_uriAttrRegex, (match) {
      final raw = (match.group(1) ?? match.group(2) ?? '').trim();
      if (raw.isEmpty) return match.group(0)!;
      final resolved = baseUri.resolve(raw).toString();
      return 'URI="$resolved"';
    });
  }
}

String _extractUrlDirSignature(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return '';
  final lastSlash = uri.path.lastIndexOf('/');
  final dir = lastSlash >= 0 ? uri.path.substring(0, lastSlash) : uri.path;
  return '${uri.scheme}://${uri.authority}$dir';
}

String _extractFilenamePattern(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return '';
  final lastSlash = uri.path.lastIndexOf('/');
  final filename =
      lastSlash >= 0 ? uri.path.substring(lastSlash + 1) : uri.path;
  final dotIdx = filename.lastIndexOf('.');
  final stem = dotIdx > 0 ? filename.substring(0, dotIdx) : filename;

  final isPureDigits = RegExp(r'^\d+$').hasMatch(stem);
  if (isPureDigits) {
    return 'digits_${stem.length}';
  }
  final isHexHash = RegExp(r'^[0-9a-fA-F]{12,}$').hasMatch(stem);
  if (isHexHash) {
    return 'hex_${stem.length}';
  }
  // Collapse trailing digits to `#` to capture prefix + length bucket
  final prefix = stem.replaceAll(RegExp(r'\d+$'), '#');
  return '${prefix}_${stem.length ~/ 4}';
}
