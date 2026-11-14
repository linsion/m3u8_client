import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/api_client.dart';
import '../theme.dart';

/// Shared two-tier (In-Memory LRU + Local Disk) poster image cache.
/// Ensures once a VOD cover is loaded, scrolling back, returning from detail/search/folder,
/// or switching tabs renders the poster synchronously in 0ms without re-downloading.
class VodPosterImageCache {
  static const int _maxMemoryEntries = 500;
  static final LinkedHashMap<String, Uint8List> _memoryCache =
      LinkedHashMap<String, Uint8List>();
  static final Map<String, Future<Uint8List?>> _inFlight = {};
  static final Set<String> _preferFallbackUrls = {};
  static final Set<String> _preferFallbackHosts = {};
  static Directory? _diskCacheDir;
  static bool _imageCacheConfigured = false;

  static void ensureFlutterImageCacheConfigured() {
    if (_imageCacheConfigured) return;
    _imageCacheConfigured = true;
    try {
      final cache = PaintingBinding.instance.imageCache;
      if (cache.maximumSize < 2500) {
        cache.maximumSize = 2500;
      }
      if (cache.maximumSizeBytes < (256 << 20)) {
        cache.maximumSizeBytes = 256 << 20; // 256 MB
      }
    } catch (_) {}
  }

  static String _normalizeKey(String rawPic) => rawPic.trim();

  /// Synchronously returns cached compressed image bytes if already in memory.
  static Uint8List? getMemoryBytes(String rawPic) {
    final key = _normalizeKey(rawPic);
    if (key.isEmpty) return null;
    final existing = _memoryCache.remove(key);
    if (existing != null) {
      // Refresh LRU order
      _memoryCache[key] = existing;
    }
    return existing;
  }

  static void _putMemoryBytes(String key, Uint8List bytes) {
    if (key.isEmpty || bytes.isEmpty) return;
    _memoryCache.remove(key);
    _memoryCache[key] = bytes;
    while (_memoryCache.length > _maxMemoryEntries) {
      _memoryCache.remove(_memoryCache.keys.first);
    }
  }

  static String _diskFileNameForKey(String key) {
    // Fast FNV-1a 64-bit hash + length suffix for collision-free safe filenames
    int hash1 = 0xcbf29ce484222325;
    int hash2 = 0x84222325cbf29ce4;
    final units = utf8.encode(key);
    for (var i = 0; i < units.length; i++) {
      final b = units[i];
      hash1 ^= b;
      hash1 = (hash1 * 0x100000001b3) & 0x7fffffffffffffff;
      hash2 ^= (b + i);
      hash2 = (hash2 * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return 'p_${hash1.toRadixString(16)}_${hash2.toRadixString(16)}_${units.length}.bin';
  }

  static Future<Directory?> _getDiskCacheDir() async {
    if (_diskCacheDir != null) return _diskCacheDir;
    try {
      final dir = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}m3u8_poster_cache_v1',
      );
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _diskCacheDir = dir;
      return dir;
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> _readDiskCache(String key) async {
    try {
      final dir = await _getDiskCacheDir();
      if (dir == null) return null;
      final file = File(
        '${dir.path}${Platform.pathSeparator}${_diskFileNameForKey(key)}',
      );
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        if (bytes.length > 64) {
          return bytes;
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<void> _writeDiskCache(String key, Uint8List bytes) async {
    try {
      final dir = await _getDiskCacheDir();
      if (dir == null) return;
      final file = File(
        '${dir.path}${Platform.pathSeparator}${_diskFileNameForKey(key)}',
      );
      await file.writeAsBytes(bytes, flush: false);
    } catch (_) {}
  }

  static Future<Uint8List?> loadPosterBytes(
    String rawPic, {
    required ApiClient api,
  }) {
    final key = _normalizeKey(rawPic);
    if (key.isEmpty) return Future<Uint8List?>.value(null);

    final mem = getMemoryBytes(key);
    if (mem != null) {
      return Future<Uint8List?>.value(mem);
    }

    final existingFlight = _inFlight[key];
    if (existingFlight != null) {
      return existingFlight;
    }

    final future = _loadPosterBytesInternal(key, api: api);
    _inFlight[key] = future;
    future.whenComplete(() {
      _inFlight.remove(key);
    });
    return future;
  }

  static Future<Uint8List?> _loadPosterBytesInternal(
    String key, {
    required ApiClient api,
  }) async {
    // 1. Check persistent local disk cache first
    final diskBytes = await _readDiskCache(key);
    if (diskBytes != null && diskBytes.isNotEmpty) {
      _putMemoryBytes(key, diskBytes);
      return diskBytes;
    }

    // 2. Extract any inline TVBox headers (`@Referer=.../@User-Agent=...` or `|Referer=...`)
    final splitPic = ApiClient.splitTvboxUrlAndHeaders(key);
    final cleanPicUrl = splitPic.cleanUrl.isNotEmpty ? splitPic.cleanUrl : key;
    final directPicHeaders = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
      ...splitPic.headers,
    };

    final isDirectHttpPic = cleanPicUrl.startsWith('http://') ||
        cleanPicUrl.startsWith('https://');
    final host =
        isDirectHttpPic ? (Uri.tryParse(cleanPicUrl)?.host ?? '') : '';
    final knownFallback = _preferFallbackUrls.contains(key) ||
        (host.isNotEmpty && _preferFallbackHosts.contains(host));

    final preferDirectPic = api.config.preferDirectPlayback && isDirectHttpPic;
    final tryDirectFirst =
        preferDirectPic ? !knownFallback : knownFallback;

    final primaryUrl = tryDirectFirst
        ? api.resolveUrl(cleanPicUrl)
        : api.buildProxiedImageUrl(cleanPicUrl);
    final primaryHeaders =
        tryDirectFirst ? directPicHeaders : api.authHeaders;

    final primaryBytes = await _fetchImageBytesFromUrl(
      primaryUrl,
      headers: primaryHeaders,
    );
    if (primaryBytes != null && primaryBytes.isNotEmpty) {
      _putMemoryBytes(key, primaryBytes);
      unawaited(_writeDiskCache(key, primaryBytes));
      return primaryBytes;
    }

    // 3. Automatic fallback between direct URL and server proxy URL
    if (isDirectHttpPic) {
      final fallbackDirect = !tryDirectFirst;
      final fallbackUrl = fallbackDirect
          ? api.resolveUrl(cleanPicUrl)
          : api.buildProxiedImageUrl(cleanPicUrl);
      final fallbackHeaders =
          fallbackDirect ? directPicHeaders : api.authHeaders;

      final fallbackBytes = await _fetchImageBytesFromUrl(
        fallbackUrl,
        headers: fallbackHeaders,
      );
      if (fallbackBytes != null && fallbackBytes.isNotEmpty) {
        _preferFallbackUrls.add(key);
        if (host.isNotEmpty) {
          _preferFallbackHosts.add(host);
        }
        _putMemoryBytes(key, fallbackBytes);
        unawaited(_writeDiskCache(key, fallbackBytes));
        return fallbackBytes;
      }
    }

    return null;
  }

  static Future<Uint8List?> _fetchImageBytesFromUrl(
    String url, {
    required Map<String, String> headers,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..badCertificateCallback = (_, __, ___) => true;
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 8));
      headers.forEach(req.headers.set);
      final resp = await req.close().timeout(const Duration(seconds: 10));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return null;
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp.timeout(const Duration(seconds: 12))) {
        builder.add(chunk);
        if (builder.length > 8 * 1024 * 1024) {
          // Guard against abnormally huge images
          break;
        }
      }
      final bytes = builder.takeBytes();
      if (bytes.length < 64) return null;
      return bytes;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

/// Reusable cached poster image widget backed by [VodPosterImageCache].
class VodCachedPosterImage extends StatefulWidget {
  final String rawPicUrl;
  final ApiClient api;
  final BoxFit fit;
  final int cacheWidth;
  final Widget Function(BuildContext context) placeholderBuilder;

  const VodCachedPosterImage({
    super.key,
    required this.rawPicUrl,
    required this.api,
    this.fit = BoxFit.cover,
    this.cacheWidth = 360,
    required this.placeholderBuilder,
  });

  @override
  State<VodCachedPosterImage> createState() => _VodCachedPosterImageState();
}

class _VodCachedPosterImageState extends State<VodCachedPosterImage> {
  Uint8List? _bytes;
  bool _loading = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    VodPosterImageCache.ensureFlutterImageCacheConfigured();
    _resolvePoster();
  }

  @override
  void didUpdateWidget(covariant VodCachedPosterImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rawPicUrl.trim() != widget.rawPicUrl.trim()) {
      _resolvePoster();
    }
  }

  void _resolvePoster() {
    final key = widget.rawPicUrl.trim();
    if (key.isEmpty) {
      _bytes = null;
      _loading = false;
      _failed = true;
      return;
    }

    // Synchronous 0ms hit from memory LRU cache!
    final syncBytes = VodPosterImageCache.getMemoryBytes(key);
    if (syncBytes != null) {
      _bytes = syncBytes;
      _loading = false;
      _failed = false;
      return;
    }

    _bytes = null;
    _loading = true;
    _failed = false;
    VodPosterImageCache.loadPosterBytes(key, api: widget.api).then((loaded) {
      if (!mounted || widget.rawPicUrl.trim() != key) return;
      setState(() {
        _bytes = loaded;
        _loading = false;
        _failed = loaded == null || loaded.isEmpty;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null && bytes.isNotEmpty) {
      return Image.memory(
        bytes,
        fit: widget.fit,
        cacheWidth: widget.cacheWidth,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (ctx, _, __) => widget.placeholderBuilder(ctx),
      );
    }

    if (_loading && !_failed) {
      return Container(
        color: VideoPlatformTheme.bgCard,
        alignment: Alignment.center,
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: VideoPlatformTheme.borderStrong,
          ),
        ),
      );
    }

    return widget.placeholderBuilder(context);
  }
}

class VodPosterCard extends StatefulWidget {
  final VodItem item;
  final ApiClient api;
  final VoidCallback onTap;
  final bool showSourceBadge;

  const VodPosterCard({
    super.key,
    required this.item,
    required this.api,
    required this.onTap,
    this.showSourceBadge = false,
  });

  @override
  State<VodPosterCard> createState() => _VodPosterCardState();
}

class _VodPosterCardState extends State<VodPosterCard> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final activeHighlight = _hovered || _focused;
    final subtitleParts = <String>[
      if (item.vodYear.isNotEmpty && item.vodYear != '0') item.vodYear,
      if (item.typeName.isNotEmpty) item.typeName,
      if (item.vodClass.isNotEmpty && item.vodClass != item.typeName)
        item.vodClass,
    ];
    final subtitle = subtitleParts.join(' · ');

    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (v) => setState(() => _hovered = v),
      onShowFocusHighlight: (v) {
        setState(() => _focused = v);
        if (v && mounted) {
          Scrollable.ensureVisible(
            context,
            alignment: 0.35,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
          );
        }
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _focused ? 1.04 : 1.0,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  decoration: BoxDecoration(
                    color: VideoPlatformTheme.bgCard,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: activeHighlight
                          ? VideoPlatformTheme.accent
                          : VideoPlatformTheme.borderSubtle,
                      width: _focused ? 2.5 : 1.0,
                    ),
                    boxShadow: _focused
                        ? [
                            BoxShadow(
                              color: VideoPlatformTheme.accent
                                  .withValues(alpha: 0.45),
                              blurRadius: 14,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildPosterImage(item),
                      // Bottom subtle dark gradient for remark readability
                      if (item.vodRemarks.isNotEmpty)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(8, 18, 8, 6),
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [
                                  Color(0xD9000000),
                                  Color(0x00000000),
                                ],
                              ),
                            ),
                            child: Text(
                              item.vodRemarks,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      // Top-left source badge when displaying aggregated search results
                      if (widget.showSourceBadge && item.source != null)
                        Positioned(
                          top: 6,
                          left: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xCC17181E),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: VideoPlatformTheme.borderStrong,
                                width: 0.5,
                              ),
                            ),
                            child: Text(
                              item.source!.name,
                              style: TextStyle(
                                color: VideoPlatformTheme.textPrimary,
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      // Hover / TV Remote Focus play overlay
                      if (activeHighlight)
                        Container(
                          color: const Color(0x38000000),
                          alignment: Alignment.center,
                          child: Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: VideoPlatformTheme.accent
                                  .withValues(alpha: 0.88),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              item.isAlistDirectory
                                  ? Icons.folder_open_rounded
                                  : Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 26,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                item.vodName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: activeHighlight
                      ? VideoPlatformTheme.accent
                      : VideoPlatformTheme.textPrimary,
                  fontSize: 13,
                  fontWeight:
                      _focused ? FontWeight.w700 : FontWeight.w500,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle.isNotEmpty
                    ? subtitle
                    : (item.isAlistDirectory ? '目录文件夹' : '影视资源'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: VideoPlatformTheme.textMuted,
                  fontSize: 11,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPosterImage(VodItem item) {
    if (item.isAlistDirectory && item.vodPic.isEmpty) {
      return Container(
        color: VideoPlatformTheme.bgCard,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_rounded,
              size: 46,
              color: VideoPlatformTheme.accent,
            ),
            const SizedBox(height: 6),
            Text(
              '目录',
              style: TextStyle(
                color: VideoPlatformTheme.textSecondary,
                fontSize: 11,
              ),
            ),
          ],
        ),
      );
    }

    final rawPic = item.vodPic.trim();
    if (rawPic.isEmpty) {
      return _buildPlaceholder(item.vodName);
    }

    return VodCachedPosterImage(
      rawPicUrl: rawPic,
      api: widget.api,
      placeholderBuilder: (_) => _buildPlaceholder(item.vodName),
    );
  }

  Widget _buildPlaceholder(String title) {
    return Container(
      color: VideoPlatformTheme.bgCard,
      padding: const EdgeInsets.all(12),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.movie_creation_outlined,
            color: VideoPlatformTheme.textMuted,
            size: 32,
          ),
          const SizedBox(height: 8),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: VideoPlatformTheme.textSecondary,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
