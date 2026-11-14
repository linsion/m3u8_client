import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../services/proxy_routing_service.dart';
import '../theme.dart';

/// Real-time download speed HUD badge for any [Player] (`media_kit` / `libmpv`).
/// Combines `libmpv` native network cache metrics (`cache-speed`, `raw-input-rate`,
/// `fw-bytes` delta, `video-bitrate` + `audio-bitrate`) with [LocalProxyTunnelBridge]
/// downstream throughput so all video playback modes (direct, proxy node, server relay,
/// VOD, Live TV, Mini-Player, Media Library, Downloads, and Telegram video) display
/// live download speed smoothly.
class VideoDownloadSpeedBadge extends StatefulWidget {
  final Player player;
  final bool compact;
  final Color? backgroundColor;
  final EdgeInsetsGeometry? padding;

  const VideoDownloadSpeedBadge({
    super.key,
    required this.player,
    this.compact = false,
    this.backgroundColor,
    this.padding,
  });

  /// Formats a byte-per-second throughput into a human-readable speed label
  /// (e.g., `↓ 2.45 MB/s`, `↓ 680 KB/s`, `↓ 0 KB/s`).
  static String formatBytesPerSecond(
    double bytesPerSecond, {
    bool includeArrow = true,
  }) {
    final prefix = includeArrow ? '↓ ' : '';
    if (!bytesPerSecond.isFinite || bytesPerSecond <= 512) {
      return '${prefix}0 KB/s';
    }
    const kb = 1024.0;
    const mb = 1024.0 * 1024.0;
    if (bytesPerSecond >= mb) {
      final val = bytesPerSecond / mb;
      return '$prefix${val >= 10 ? val.toStringAsFixed(1) : val.toStringAsFixed(2)} MB/s';
    }
    final kbVal = bytesPerSecond / kb;
    return '$prefix${kbVal >= 10 ? kbVal.toStringAsFixed(0) : kbVal.toStringAsFixed(1)} KB/s';
  }

  @override
  State<VideoDownloadSpeedBadge> createState() =>
      _VideoDownloadSpeedBadgeState();
}

class _VideoDownloadSpeedBadgeState extends State<VideoDownloadSpeedBadge> {
  Timer? _pollTimer;
  double _smoothedBytesPerSec = 0.0;
  int _lastSampleTimeMs = 0;
  double _lastFwBytes = -1;
  Duration _lastBufferPos = Duration.zero;
  Duration _lastPlayPos = Duration.zero;
  bool _samplingInFlight = false;

  @override
  void initState() {
    super.initState();
    _lastSampleTimeMs = DateTime.now().millisecondsSinceEpoch;
    _lastBufferPos = widget.player.state.buffer;
    _lastPlayPos = widget.player.state.position;
    _startPolling();
  }

  @override
  void didUpdateWidget(covariant VideoDownloadSpeedBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      _smoothedBytesPerSec = 0.0;
      _lastFwBytes = -1;
      _lastSampleTimeMs = DateTime.now().millisecondsSinceEpoch;
      _lastBufferPos = widget.player.state.buffer;
      _lastPlayPos = widget.player.state.position;
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 900), (_) {
      _sampleSpeed();
    });
    unawaited(_sampleSpeed());
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

  Future<void> _sampleSpeed() async {
    if (!mounted || _samplingInFlight) return;
    _samplingInFlight = true;
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final elapsedSec =
          ((nowMs - _lastSampleTimeMs).clamp(200, 5000)) / 1000.0;
      _lastSampleTimeMs = nowMs;

      final state = widget.player.state;
      final isPlaying = state.playing;
      final isBuffering = state.buffering;
      final curBuffer = state.buffer;
      final curPos = state.position;

      final deltaBufferSec =
          (curBuffer - _lastBufferPos).inMilliseconds / 1000.0;
      final deltaPlaySec = (curPos - _lastPlayPos).inMilliseconds / 1000.0;
      _lastBufferPos = curBuffer;
      _lastPlayPos = curPos;

      double mpvCacheSpeed = 0.0;
      double mpvRawInputRate = 0.0;
      double fwBytesDeltaRate = 0.0;
      double mediaBitrateBytesPerSec = 0.0;

      try {
        final dynamic platform = widget.player.platform;
        if (platform != null) {
          final results = await Future.wait<double>([
            _readMpvNumericProperty(platform, 'cache-speed'),
            _readMpvNumericProperty(
              platform,
              'demuxer-cache-state/raw-input-rate',
            ),
            _readMpvNumericProperty(platform, 'demuxer-cache-state/fw-bytes'),
            _readMpvNumericProperty(platform, 'video-bitrate'),
            _readMpvNumericProperty(platform, 'audio-bitrate'),
          ]).timeout(
            const Duration(milliseconds: 450),
            onTimeout: () => const [0.0, 0.0, 0.0, 0.0, 0.0],
          );

          mpvCacheSpeed = results[0];
          mpvRawInputRate = results[1];
          final fwBytes = results[2];
          final vBitrate = results[3];
          final aBitrate = results[4];

          if (fwBytes > 0) {
            if (_lastFwBytes >= 0 && fwBytes > _lastFwBytes) {
              fwBytesDeltaRate = (fwBytes - _lastFwBytes) / elapsedSec;
            }
            _lastFwBytes = fwBytes;
          }

          if (vBitrate > 0 || aBitrate > 0) {
            mediaBitrateBytesPerSec = (vBitrate + aBitrate) / 8.0;
          }
        }
      } catch (_) {}

      final proxyRate =
          (isPlaying || isBuffering)
              ? LocalProxyTunnelBridge.recentDownstreamBytesPerSecond
              : 0.0;

      double measured = mpvCacheSpeed;
      if (mpvRawInputRate > measured) measured = mpvRawInputRate;
      if (fwBytesDeltaRate > measured) measured = fwBytesDeltaRate;
      if (proxyRate > measured) measured = proxyRate;

      // When HLS/DASH segments download in bursts, `cache-speed` can briefly report 0
      // between segment fetches even while the buffer or playback is actively advancing.
      if (measured <= 0 && (isPlaying || isBuffering)) {
        final effectiveStreamRate = mediaBitrateBytesPerSec > 16384
            ? mediaBitrateBytesPerSec
            : ((state.width ?? 0) >= 1920
                ? 420 * 1024.0
                : ((state.width ?? 0) >= 1280 ? 260 * 1024.0 : 160 * 1024.0));

        if (deltaBufferSec > 0.15) {
          measured =
              (deltaBufferSec / elapsedSec).clamp(0.4, 6.0) *
              effectiveStreamRate;
        } else if (isPlaying && deltaPlaySec > 0.1) {
          measured = mediaBitrateBytesPerSec > 0
              ? mediaBitrateBytesPerSec
              : (_smoothedBytesPerSec > 32 * 1024
                  ? _smoothedBytesPerSec * 0.72
                  : effectiveStreamRate * 0.85);
        }
      }

      double nextSmoothed;
      if (measured > 0) {
        nextSmoothed = _smoothedBytesPerSec <= 1024
            ? measured
            : (_smoothedBytesPerSec * 0.42 + measured * 0.58);
      } else if (isPlaying || isBuffering) {
        nextSmoothed = _smoothedBytesPerSec * 0.55;
        if (nextSmoothed < 1024) nextSmoothed = 0.0;
      } else {
        nextSmoothed = 0.0;
      }

      if (!mounted) return;
      if ((nextSmoothed - _smoothedBytesPerSec).abs() > 512 ||
          (nextSmoothed == 0 && _smoothedBytesPerSec != 0)) {
        setState(() {
          _smoothedBytesPerSec = nextSmoothed;
        });
      }
    } finally {
      _samplingInFlight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isBuffering = widget.player.state.buffering;
    final label = VideoDownloadSpeedBadge.formatBytesPerSecond(
      _smoothedBytesPerSec,
      includeArrow: true,
    );
    final compact = widget.compact;

    return IgnorePointer(
      child: Container(
        padding:
            widget.padding ??
            EdgeInsets.symmetric(
              horizontal: compact ? 6 : 9,
              vertical: compact ? 2.5 : 4,
            ),
        decoration: BoxDecoration(
          color: widget.backgroundColor ?? const Color(0xB80B121B),
          borderRadius: BorderRadius.circular(compact ? 6 : 14),
          border: Border.all(
            color: isBuffering
                ? VideoPlatformTheme.accent.withValues(alpha: 0.7)
                : Colors.white.withValues(alpha: 0.18),
            width: 0.9,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.speed_rounded,
              size: compact ? 10.5 : 13,
              color: _smoothedBytesPerSec > 1024
                  ? VideoPlatformTheme.success
                  : VideoPlatformTheme.accent,
            ),
            SizedBox(width: compact ? 3 : 4.5),
            Text(
              label,
              style: TextStyle(
                color: Colors.white,
                fontSize: compact ? 10 : 11.5,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
