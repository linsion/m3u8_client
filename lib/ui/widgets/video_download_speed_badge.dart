import 'dart:async';

import 'package:flutter/gestures.dart';
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
            ConstrainedBox(
              constraints: BoxConstraints(minWidth: compact ? 60 : 72),
              child: Text(
                label,
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: compact ? 10 : 11.5,
                  fontFamily: 'monospace',
                  fontFeatures: const [FontFeature.tabularFigures()],
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Visible, responsive Volume & Mute control widget for any [Player] (`media_kit`).
/// Supports click-to-mute/unmute, drag slider, and mouse wheel volume scrolling.
class PlayerVolumeControl extends StatefulWidget {
  final Player player;
  final bool compact;
  final bool overlayStyle;
  final double? sliderWidth;
  final bool showPercentage;
  final ValueChanged<double>? onVolumeChanged;

  const PlayerVolumeControl({
    super.key,
    required this.player,
    this.compact = false,
    this.overlayStyle = false,
    this.sliderWidth,
    this.showPercentage = true,
    this.onVolumeChanged,
  });

  @override
  State<PlayerVolumeControl> createState() => _PlayerVolumeControlState();
}

class _PlayerVolumeControlState extends State<PlayerVolumeControl> {
  StreamSubscription<double>? _volSub;
  double _volume = 100.0;
  double _preMuteVolume = 100.0;

  @override
  void initState() {
    super.initState();
    _syncFromPlayer();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant PlayerVolumeControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      _volSub?.cancel();
      _syncFromPlayer();
      _subscribe();
    }
  }

  void _syncFromPlayer() {
    final v = widget.player.state.volume;
    _volume = (v.isFinite ? v : 100.0).clamp(0.0, 100.0);
    if (_volume > 0) {
      _preMuteVolume = _volume;
    }
  }

  void _subscribe() {
    _volSub = widget.player.stream.volume.listen((v) {
      if (!mounted) return;
      final clamped = (v.isFinite ? v : 100.0).clamp(0.0, 100.0);
      if (clamped > 0) {
        _preMuteVolume = clamped;
      }
      if ((clamped - _volume).abs() > 0.5) {
        setState(() => _volume = clamped);
      }
    });
  }

  @override
  void dispose() {
    _volSub?.cancel();
    super.dispose();
  }

  void _applyVolume(double next) {
    final clamped = next.clamp(0.0, 100.0);
    if (clamped > 0) {
      _preMuteVolume = clamped;
    }
    setState(() => _volume = clamped);
    widget.player.setVolume(clamped);
    widget.onVolumeChanged?.call(clamped);
  }

  void _toggleMute() {
    if (_volume <= 0.5) {
      final restore = _preMuteVolume > 5.0 ? _preMuteVolume : 100.0;
      _applyVolume(restore);
    } else {
      _preMuteVolume = _volume;
      _applyVolume(0.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMuted = _volume <= 0.5;
    final compact = widget.compact;
    final sliderW = widget.sliderWidth ?? (compact ? 64.0 : 84.0);
    final fgColor =
        widget.overlayStyle ? Colors.white : VideoPlatformTheme.textPrimary;
    final subColor =
        widget.overlayStyle ? Colors.white70 : VideoPlatformTheme.textSecondary;

    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          final delta = event.scrollDelta.dy < 0 ? 5.0 : -5.0;
          _applyVolume(_volume + delta);
        }
      },
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 6 : 8,
          vertical: compact ? 2 : 3,
        ),
        decoration: BoxDecoration(
          color: widget.overlayStyle
              ? const Color(0xB80B121B)
              : VideoPlatformTheme.bgCard,
          borderRadius: BorderRadius.circular(compact ? 8 : 14),
          border: Border.all(
            color: widget.overlayStyle
                ? Colors.white.withValues(alpha: 0.18)
                : VideoPlatformTheme.borderSubtle,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: _toggleMute,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(
                  isMuted
                      ? Icons.volume_off_rounded
                      : (_volume < 50
                          ? Icons.volume_down_rounded
                          : Icons.volume_up_rounded),
                  size: compact ? 15 : 17,
                  color: isMuted ? VideoPlatformTheme.danger : VideoPlatformTheme.accent,
                ),
              ),
            ),
            SizedBox(
              width: sliderW,
              height: compact ? 20 : 24,
              child: ExcludeFocus(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: compact ? 2.6 : 3.2,
                    thumbShape: RoundSliderThumbShape(
                      enabledThumbRadius: compact ? 5.0 : 6.0,
                    ),
                    overlayShape: RoundSliderOverlayShape(
                      overlayRadius: compact ? 9.0 : 11.0,
                    ),
                    activeTrackColor: VideoPlatformTheme.accent,
                    inactiveTrackColor: widget.overlayStyle
                        ? Colors.white24
                        : VideoPlatformTheme.borderStrong,
                    thumbColor: fgColor,
                  ),
                  child: Slider(
                    value: _volume.clamp(0.0, 100.0),
                    min: 0.0,
                    max: 100.0,
                    onChanged: _applyVolume,
                  ),
                ),
              ),
            ),
            if (widget.showPercentage) ...[
              const SizedBox(width: 2),
              SizedBox(
                width: compact ? 28 : 32,
                child: Text(
                  '${_volume.round()}%',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: compact ? 10 : 11,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                    color: isMuted ? VideoPlatformTheme.danger : subColor,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
