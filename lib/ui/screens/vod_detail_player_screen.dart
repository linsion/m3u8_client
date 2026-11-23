import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/models.dart';
import '../../services/proxy_routing_service.dart';
import '../../services/tv_platform_service.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets/cloud_music_player.dart';
import '../widgets/mobile_edge_swipe_back.dart';
import '../widgets/video_115_accelerate_button.dart';
import '../widgets/video_download_speed_badge.dart';
import '../widgets/video_proxy_node_selector.dart';
import '../widgets/video_proxy_stats_overlay.dart';
import '../../services/local_115_direct_service.dart';

class VodDetailPlayerScreen extends StatefulWidget {
  final AppState appState;
  final VodSource source;
  final String vodId;
  final String initialTitle;
  final String initialPoster;
  final String? preferredLine;
  final String? preferredEpisodeTitle;
  final double initialResumeSeconds;
  final int? initialGroupIndex;
  final int? initialEpisodeIndex;

  const VodDetailPlayerScreen({
    super.key,
    required this.appState,
    required this.source,
    required this.vodId,
    this.initialTitle = '',
    this.initialPoster = '',
    this.preferredLine,
    this.preferredEpisodeTitle,
    this.initialResumeSeconds = 0,
    this.initialGroupIndex,
    this.initialEpisodeIndex,
  });

  @override
  State<VodDetailPlayerScreen> createState() => _VodDetailPlayerScreenState();
}

class _VodDetailPlayerScreenState extends State<VodDetailPlayerScreen> {
  static const MethodChannel _nativeUtilsChannel =
      MethodChannel('com.linsion.m3u8_client/native_utils');

  late final Player _player;
  late final VideoController _videoController;

  late VodSource _activeSource;
  late String _activeVodId;

  VodDetail? _detail;
  bool _isLoadingDetail = true;
  String? _detailError;

  int _selectedGroupIndex = 0;
  Episode? _currentEpisode;
  ResolvedPlayback? _resolvedPlayback;
  String _activeStreamUrl = '';
  Map<String, String> _activeStreamHeaders = const {};
  bool _isResolvingPlay = false;
  String? _playError;

  bool _useServerProxy = false;
  bool _using115Direct = false;
  double _playbackSpeed = 1.0;
  bool _isLongPressFastForward = false;
  bool _isFullscreenMode = false;
  bool _fullscreenControlsVisible = false;
  Timer? _fullscreenControlsTimer;
  bool _mobileStageOsdVisible = false;
  Timer? _mobileStageOsdTimer;
  final FocusNode _fullscreenStageFocusNode =
      FocusNode(debugLabel: 'VodFullscreenStage');
  final FocusNode _fullscreenPlayBtnFocusNode =
      FocusNode(debugLabel: 'VodFullscreenPlayBtn');
  final FocusNode _windowedStageFocusNode =
      FocusNode(debugLabel: 'VodWindowedStage');
  final FocusNode _windowedPlayBtnFocusNode =
      FocusNode(debugLabel: 'VodWindowedPlayBtn');
  bool _isHorizontalSeeking = false;
  double _seekStartSeconds = 0.0;
  double _seekPreviewSeconds = 0.0;
  bool _isSliderDragging = false;
  double _sliderPreviewSeconds = 0.0;
  String _videoAspectMode = 'fit'; // 'fit', '16:9', '4:3', 'cover'
  String? _externalSubtitleName;
  double _pendingSeekSeconds = 0;
  bool _hasAppliedInitialSeek = false;
  bool _isAutoIntroSkipPending = false;
  bool _hasTriggeredOutroSkip = false;

  // Ad removal & skip status
  int _removedAdSegments = 0;
  double _removedAdSeconds = 0.0;
  String? _adToastMessage;
  Timer? _adToastTimer;

  // Download button animated feedback per episode (`groupName|rawUrl`)
  final Set<String> _addingDownloadKeys = {};
  final Set<String> _queuedDownloadKeys = {};
  final Set<String> _failedDownloadKeys = {};

  // Episode sorting, chunking & search filter
  bool _episodesReversed = false;
  bool _isEpisodeSidebarCollapsed = false;
  int _episodeChunkIndex = -1; // -1: 全部, >=0: 50-episode chunk index
  bool _showEpisodeSearch = false;
  String _episodeSearchQuery = '';
  final TextEditingController _episodeSearchCtrl = TextEditingController();

  // Audio track, Sleep timer & AB Repeat
  String? _selectedAudioTrackLabel;
  int _sleepTimerMinutes = 0; // 0: off, -1: pause after episode, >0: minutes
  Timer? _sleepTimer;
  double? _abPointASeconds;
  double? _abPointBSeconds;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<int?>? _widthSub;
  StreamSubscription<int?>? _heightSub;
  StreamSubscription<VideoParams>? _videoParamsSub;
  final GlobalKey _videoPlayerWidgetKey =
      GlobalKey(debugLabel: 'VodMainVideoWidget');
  int _videoWidth = 0;
  int _videoHeight = 0;
  bool? _fullscreenLandscapeOverride;
  final Map<int, Offset> _stageTouchPointers = <int, Offset>{};
  double? _initialPinchDistance;
  Timer? _startupWatchdogTimer;
  Timer? _bufferingLagTimer;
  bool _hasRenderedFirstFrame = false;
  bool _usingClientProxy = false;
  bool _showProxyStatsOverlay = false;
  int _clientProxyRetryCountForEpisode = 0;
  bool _bypassClientProxyForCurrentEpisode = false;
  bool _didTryServerResolveForEpisode = false;
  bool _didTryServerProxyFallbackForEpisode = false;
  int _playAttemptSessionId = 0;
  DateTime _lastStreamOpenInitiatedAt = DateTime.fromMillisecondsSinceEpoch(0);
  final Set<int> _triedGroupIndicesForEpisode = <int>{};
  ({
    int groupIndex,
    Episode episode,
    ResolvedPlayback resolved,
    int latencyMs,
  })? _verifiedFastestBackupLine;
  Duration _lastValidPosition = Duration.zero;
  Duration _lastValidDuration = Duration.zero;
  int _prematureEofRecoveryCount = 0;
  DateTime _lastHistorySync = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastBackHandledAt;
  bool _isVerticalVolumeDragging = false;
  double _volumePercent = 100.0;
  String _lastVodRouteSignature = '';
  int _lastObservedNetworkResumeEpoch = 0;

  void _onAppStateNetworkResumeChanged() {
    if (!mounted) return;
    final epoch = widget.appState.networkResumeEpoch;
    if (epoch == _lastObservedNetworkResumeEpoch) return;
    _lastObservedNetworkResumeEpoch = epoch;
    if (_detailError != null && !_isLoadingDetail) {
      _loadDetail();
      return;
    }
    final ep = _currentEpisode;
    final resolved = _resolvedPlayback;
    if (ep == null || _isResolvingPlay || _using115Direct) return;
    final curSec = _player.state.position.inSeconds > 2
        ? _player.state.position.inSeconds.toDouble()
        : (_lastValidPosition.inSeconds > 2
              ? _lastValidPosition.inSeconds.toDouble()
              : _pendingSeekSeconds);
    if (_playError != null ||
        _player.state.completed ||
        (_activeStreamUrl.contains('127.0.0.1') && !_player.state.playing)) {
      if (curSec > 2) {
        _pendingSeekSeconds = curSec;
        _hasAppliedInitialSeek = false;
      }
      if (resolved != null && _playError == null) {
        unawaited(
          _openResolvedStream(
            resolved,
            forceProxy: _useServerProxy,
            attemptId: _playAttemptSessionId,
            autoplay: _player.state.playing,
          ),
        );
      } else {
        _selectAndPlayEpisode(
          ep,
          resumeSeconds: curSec,
          resetTriedLines: _playError != null,
        );
      }
    }
  }

  String _computeVodRouteSignature() {
    final svc = widget.appState.proxyService;
    final effective = svc.resolveEffectiveRoute(RequestScenario.vodStream);
    final nodeId = effective == ScenarioRouteMode.proxyNode
        ? (svc.resolveNodeForScenario(RequestScenario.vodStream)?.id ?? '')
        : '';
    return '${svc.proxyEnabled}|${effective.name}|$nodeId';
  }

  void _onExternalProxyServiceChanged() {
    if (!mounted) return;
    final nextSig = _computeVodRouteSignature();
    if (nextSig == _lastVodRouteSignature) return;
    _lastVodRouteSignature = nextSig;
    if (_using115Direct || _isResolvingPlay || _resolvedPlayback == null) {
      return;
    }
    _onProxyNodeSwitched(widget.appState.proxyService.lastStatusMessage);
  }

  bool get _isPortraitVideo =>
      _videoWidth > 0 && _videoHeight > 0 && _videoHeight > _videoWidth;

  void _updateVideoDimensions({int? w, int? h, VideoParams? params}) {
    if (!mounted) return;
    final vp = params ?? _player.state.videoParams;
    final rawW = vp.dw ?? vp.w ?? w ?? _player.state.width ?? 0;
    final rawH = vp.dh ?? vp.h ?? h ?? _player.state.height ?? 0;
    final rot = ((vp.rotate ?? 0) % 360 + 360) % 360;
    int nextW = rawW;
    int nextH = rawH;
    if (rot == 90 || rot == 270) {
      nextW = rawH;
      nextH = rawW;
    }
    final firstFrame = nextW > 0 && !_hasRenderedFirstFrame;
    final dimChanged = (nextW > 0 && nextH > 0) &&
        (nextW != _videoWidth || nextH != _videoHeight);
    final clearStaleError = nextW > 0 && (_playError != null || _isResolvingPlay);
    if (nextW > 0) {
      _startupWatchdogTimer?.cancel();
    }
    if (firstFrame || dimChanged || clearStaleError) {
      final prevPortrait = _isPortraitVideo;
      setState(() {
        if (nextW > 0) {
          _hasRenderedFirstFrame = true;
          _playError = null;
          _isResolvingPlay = false;
        }
        if (nextW > 0 && nextH > 0) {
          _videoWidth = nextW;
          _videoHeight = nextH;
        }
      });
      if (_isFullscreenMode &&
          _fullscreenLandscapeOverride == null &&
          _isPortraitVideo != prevPortrait) {
        _applyFullscreenDeviceOrientation();
      }
    }
  }

  void _applyFullscreenDeviceOrientation() {
    if (!(Platform.isAndroid || Platform.isIOS) || widget.appState.tvMode) {
      return;
    }
    final useLandscape = _fullscreenLandscapeOverride ?? !_isPortraitVideo;
    if (useLandscape) {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
    }
  }

  void _toggleFullscreenOrientation() {
    final mq = MediaQuery.maybeSizeOf(context);
    final currentlyLandscape = _fullscreenLandscapeOverride ??
        (mq != null ? mq.width > mq.height : !_isPortraitVideo);
    final nextLandscape = !currentlyLandscape;
    setState(() {
      _fullscreenLandscapeOverride = nextLandscape;
      if (!_isFullscreenMode) {
        _isFullscreenMode = true;
      }
    });
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      if (!widget.appState.tvMode) {
        _applyFullscreenDeviceOrientation();
      }
    }
    _showAdToast(nextLandscape ? '已切换为：横屏全屏模式' : '已切换为：竖屏全屏模式');
  }

  void _cycleVideoAspectMode() {
    const modes = ['fit', 'cover', '16:9', '4:3'];
    final idx = modes.indexOf(_videoAspectMode);
    final next = modes[(idx + 1) % modes.length];
    setState(() => _videoAspectMode = next);
    final label = switch (next) {
      'cover' => '铺满裁剪 (去黑边)',
      '16:9' => '强制 16:9',
      '4:3' => '强制 4:3',
      _ => '适应屏幕 (原始比例)',
    };
    _showAdToast('画面比例：$label');
  }

  bool _isBackLogicalKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.browserBack;
  }

  void _handleBackPress() {
    if (!mounted) return;
    final now = DateTime.now();
    if (_lastBackHandledAt != null &&
        now.difference(_lastBackHandledAt!) <
            const Duration(milliseconds: 280)) {
      return;
    }
    _lastBackHandledAt = now;

    if (_isFullscreenMode) {
      if (_fullscreenControlsVisible) {
        _fullscreenControlsTimer?.cancel();
        setState(() => _fullscreenControlsVisible = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _isFullscreenMode && !_fullscreenControlsVisible) {
            _fullscreenStageFocusNode.requestFocus();
          }
        });
        return;
      }
      _toggleFullscreenMode(forceValue: false);
      return;
    }
    final mq = MediaQuery.maybeSizeOf(context);
    final isPhoneLandscape = (Platform.isAndroid || Platform.isIOS) &&
        !widget.appState.tvMode &&
        mq != null &&
        mq.shortestSide < 600 &&
        mq.width > mq.height;
    if (isPhoneLandscape) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
      Future<void>.delayed(const Duration(milliseconds: 900), () {
        if (mounted && !_isFullscreenMode) {
          SystemChrome.setPreferredOrientations(const []);
        }
      });
      return;
    }
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  void _onVodFocusManagerChanged() {
    if (!mounted || !_isFullscreenMode || !_fullscreenControlsVisible) return;
    _pokeFullscreenControls();
  }

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onVodFocusManagerChanged);
    _activeSource = widget.source;
    _activeVodId = widget.vodId;
    unawaited(CloudMusicController.stopAllBackgroundAudioForVideo());
    if (widget.appState.miniPlayerSession != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.appState.closeMiniPlayer();
      });
    }
    _useServerProxy = !widget.appState.serverConfig.preferDirectPlayback;
    _player = Player(
      configuration: PlayerConfiguration(
        bufferSize: (Platform.isAndroid || Platform.isIOS)
            ? 32 * 1024 * 1024
            : 128 * 1024 * 1024,
      ),
    );
    _videoController = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        hwdec: Platform.isAndroid ? 'no' : null,
        enableHardwareAcceleration: !Platform.isAndroid,
      ),
    );
    _configureVodNativePlayer();

    _positionSub = _player.stream.position.listen(_onPositionUpdate);
    _completedSub = _player.stream.completed.listen((completed) {
      if (completed && mounted) {
        final durSec = _player.state.duration.inSeconds > 0
            ? _player.state.duration.inSeconds
            : _lastValidDuration.inSeconds;
        final posSec = _lastValidPosition.inSeconds;
        final isPrematureEof =
            durSec > 15 && posSec > 3 && posSec < durSec - 8;
        if (isPrematureEof &&
            _activeStreamUrl.isNotEmpty &&
            _prematureEofRecoveryCount < 4) {
          _prematureEofRecoveryCount++;
          _pendingSeekSeconds = posSec.toDouble();
          _hasAppliedInitialSeek = false;
          final usingLocalRelay = _activeStreamUrl.contains('/__m3u8_proxy__/') ||
              _activeStreamUrl.contains('://127.0.0.1:');
          unawaited(
            _player.open(
              Media(
                _activeStreamUrl,
                httpHeaders: usingLocalRelay ? const {} : _activeStreamHeaders,
              ),
              play: true,
            ),
          );
          return;
        }
        if (_sleepTimerMinutes == -1) {
          setState(() => _sleepTimerMinutes = 0);
          _player.pause();
          _showAdToast('🌙 已按睡眠定时在播完本集后自动暂停');
          return;
        }
        _playNextEpisodeIfAvailable();
      }
    });
    _widthSub = _player.stream.width.listen((w) {
      _updateVideoDimensions(w: w);
    });
    _heightSub = _player.stream.height.listen((h) {
      _updateVideoDimensions(h: h);
    });
    _videoParamsSub = _player.stream.videoParams.listen((params) {
      _updateVideoDimensions(params: params);
    });
    _bufferingSub = _player.stream.buffering.listen((isBuffering) {
      if (mounted) {
        setState(() {});
      }
      _bufferingLagTimer?.cancel();
      if (isBuffering && !_using115Direct) {
        final hasStarted = _player.state.duration > Duration.zero ||
            _player.state.position > Duration.zero;
        if (hasStarted) {
          _bufferingLagTimer = Timer(const Duration(seconds: 7), () async {
            if (!mounted || !_player.state.buffering || _using115Direct) {
              return;
            }
            // If bytes are actively flowing at > 256 KB/s, let the buffer fill naturally
            if (LocalProxyTunnelBridge.recentDownstreamBytesPerSecond >
                256 * 1024) {
              return;
            }
            if (_usingClientProxy) {
              final prevNodeId = widget.appState.proxyService.activeNode?.id;
              final nextNode = await widget.appState.proxyService
                  .reportActiveNodeLag(reason: '视频播放缓冲卡顿');
              if (mounted && nextNode != null && nextNode.id != prevNodeId) {
                _showAdToast('⚡ 当前代理缓冲卡顿，已自动切换至：${nextNode.displayTitle}');
                return;
              }
            }
            // If direct playback (or single proxy node) is stalled mid-stream and a faster backup line exists, switch seamlessly preserving progress!
            final backupLine = _verifiedFastestBackupLine;
            if (backupLine != null &&
                !_triedGroupIndicesForEpisode.contains(backupLine.groupIndex)) {
              final curPosSec = _player.state.position.inSeconds > 0
                  ? _player.state.position.inSeconds.toDouble()
                  : _lastValidPosition.inSeconds.toDouble();
              if (curPosSec > 2) {
                _pendingSeekSeconds = curPosSec;
                _hasAppliedInitialSeek = false;
              }
              _triggerFastStartupFallback(reason: '当前播放线路缓冲过慢');
            }
          });
        }
      }
    });
    _errorSub = _player.stream.error.listen((err) {
      if (err.isNotEmpty && mounted) {
        if (_isResolvingPlay || _activeStreamUrl.isEmpty) return;

        final hasStartedPlaying = _hasRenderedFirstFrame ||
            _player.state.duration > Duration.zero ||
            _player.state.position > Duration.zero ||
            (_player.state.width ?? 0) > 0 ||
            (_player.state.height ?? 0) > 0;
        if (hasStartedPlaying) return;

        final lower = err.toLowerCase();
        // Only ignore transient abort/cancel notices right after `_player.open()`;
        // never ignore real `Failed to open ...` stream errors.
        final sinceOpenMs =
            DateTime.now().difference(_lastStreamOpenInitiatedAt).inMilliseconds;
        if (sinceOpenMs >= 0 &&
            sinceOpenMs < 380 &&
            !lower.contains('failed to open')) {
          return;
        }
        final isNonFatalDecodeError =
            lower.contains('error while decoding') ||
            lower.contains('decoding frame') ||
            lower.contains('co located pocs') ||
            lower.contains('reference picture missing') ||
            lower.contains('non-existing pps') ||
            lower.contains('non-existing sps') ||
            lower.contains('invalid data found when processing input') ||
            lower.contains('concealing') ||
            lower.contains('packet corrupt') ||
            lower.contains('missing picture in access unit') ||
            lower.contains('no frame!') ||
            lower.contains('discarding') ||
            lower.contains('overread') ||
            lower.contains('cabac') ||
            lower.contains('deblocking') ||
            lower.contains('pps id out of range') ||
            lower.contains('loading aborted') ||
            lower.contains('operation was aborted');
        if (isNonFatalDecodeError) return;

        // If the stream is actively buffering or receiving bytes via our local relay,
        // do not prematurely trigger fallback on non-fatal probe warnings.
        if (_player.state.buffering &&
            LocalProxyTunnelBridge.recentDownstreamBytesPerSecond > 1024) {
          return;
        }

        _triggerFastStartupFallback(reason: '当前播放地址不可用');
      }
    });

    _lastVodRouteSignature = _computeVodRouteSignature();
    _lastObservedNetworkResumeEpoch = widget.appState.networkResumeEpoch;
    widget.appState.proxyService.addListener(_onExternalProxyServiceChanged);
    widget.appState.addListener(_onAppStateNetworkResumeChanged);
    _loadDetail();
  }

  Future<void> _configureVodNativePlayer() async {
    try {
      final dynamic platform = _player.platform;
      final isMobileOrTv = Platform.isAndroid || Platform.isIOS;
      final props = <String, String>{
        'hwdec': Platform.isAndroid ? 'no' : 'auto-safe',
        'hwdec-codecs': 'h264,hevc,vp8,vp9,av1',
        'vd-lavc-check-hw-profile': 'yes',
        'vd-lavc-software-fallback': 'yes',
        'cache': 'yes',
        'cache-on-disk': 'no',
        'cache-secs': isMobileOrTv ? '60' : '180',
        'cache-pause': 'yes',
        'cache-pause-initial': 'no',
        'cache-pause-wait': '2.0',
        'demuxer-thread': 'yes',
        'demuxer-max-bytes': isMobileOrTv ? '67108864' : '201326592',
        'demuxer-max-back-bytes': isMobileOrTv ? '16777216' : '33554432',
        'demuxer-readahead-secs': isMobileOrTv ? '45' : '90',
        'stream-buffer-size': isMobileOrTv ? '1048576' : '2097152',
        'framedrop': 'vo',
        'vd-lavc-threads': Platform.isAndroid ? '4' : '0',
        'ad-lavc-threads': '0',
        'demuxer-lavf-probesize': '131072',
        'demuxer-lavf-analyzeduration': '0.5',
        'network-timeout': '15',
        'tls-verify': 'no',
        'stream-lavf-o':
            'reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_on_http_error=4xx,5xx,reconnect_delay_max=3',
        'demuxer-lavf-o':
            'seg_max_retry=10,http_persistent=1,http_multiple=1,allowed_extensions=ALL,protocol_whitelist=file,http,https,httpproxy,tcp,tls,crypto,data,rtp,udp,subfile',
      };
      for (final entry in props.entries) {
        await platform.setProperty(entry.key, entry.value);
      }
    } catch (_) {}
  }

  Future<void> _applyVodStreamHeaders(
    Map<String, String> headers, {
    String? streamUrl,
    bool bypassClientProxy = false,
  }) async {
    try {
      final dynamic platform = _player.platform;
      final ua = headers['User-Agent'] ??
          headers['user-agent'] ??
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
      await platform.setProperty('user-agent', ua);
      final referer =
          headers['Referer'] ?? headers['referer'] ?? headers['Referrer'] ?? '';
      await platform.setProperty('referrer', referer);
      final proxyUrl = bypassClientProxy
          ? ''
          : await widget.appState.proxyService.resolvePlayerHttpProxyUrl(
              RequestScenario.vodStream,
              streamUri: streamUrl != null ? Uri.tryParse(streamUrl) : null,
            );
      _usingClientProxy = proxyUrl.isNotEmpty;
      await platform.setProperty('http-proxy', proxyUrl);
    } catch (_) {}
  }

  void _showAdToast(String message) {
    _adToastTimer?.cancel();
    if (!mounted) return;
    setState(() => _adToastMessage = message);
    _adToastTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() => _adToastMessage = null);
      }
    });
  }

  void _skipForwardSeconds(int seconds, {String? customReason}) {
    final currentPos = _player.state.position;
    final totalDur = _player.state.duration;
    var nextPos = currentPos + Duration(seconds: seconds);
    if (totalDur > Duration.zero && nextPos > totalDur) {
      nextPos = totalDur - const Duration(seconds: 1);
    }
    _player.seek(nextPos);
    _showAdToast(customReason ?? '已快进跳过广告 ${seconds}s');
  }

  void _rewindSeconds(int seconds) {
    final currentPos = _player.state.position;
    var nextPos = currentPos - Duration(seconds: seconds);
    if (nextPos < Duration.zero) {
      nextPos = Duration.zero;
    }
    _player.seek(nextPos);
    _showAdToast('已快退 ${seconds}s');
  }

  void _pokeFullscreenControls({bool focusBar = false}) {
    _fullscreenControlsTimer?.cancel();
    final wasHidden = !_fullscreenControlsVisible;
    if (wasHidden && mounted) {
      setState(() => _fullscreenControlsVisible = true);
    }
    if (focusBar || wasHidden) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _isFullscreenMode && _fullscreenControlsVisible) {
          _fullscreenPlayBtnFocusNode.requestFocus();
        }
      });
    }
    if (_isFullscreenMode) {
      _fullscreenControlsTimer =
          Timer(const Duration(milliseconds: 3800), () {
        if (mounted && _isFullscreenMode && !_isSliderDragging) {
          setState(() => _fullscreenControlsVisible = false);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _isFullscreenMode && !_fullscreenControlsVisible) {
              _fullscreenStageFocusNode.requestFocus();
            }
          });
        }
      });
    }
  }

  void _toggleFullscreenMode({bool? forceValue}) {
    final next = forceValue ?? !_isFullscreenMode;
    if (next == _isFullscreenMode) return;
    _fullscreenControlsTimer?.cancel();
    setState(() {
      _isFullscreenMode = next;
      if (!next) {
        _fullscreenLandscapeOverride = null;
      }
      // Hide bottom progress bar immediately upon entering fullscreen;
      // it only appears when the remote moves or screen is tapped.
      _fullscreenControlsVisible = false;
    });
    if (next) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _isFullscreenMode) {
          _fullscreenStageFocusNode.requestFocus();
        }
      });
    }
    if (Platform.isAndroid || Platform.isIOS) {
      if (next) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        if (!widget.appState.tvMode) {
          _applyFullscreenDeviceOrientation();
        }
      } else {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        if (!widget.appState.tvMode) {
          SystemChrome.setPreferredOrientations(const [
            DeviceOrientation.portraitUp,
          ]);
          Future<void>.delayed(const Duration(milliseconds: 800), () {
            if (mounted && !_isFullscreenMode) {
              SystemChrome.setPreferredOrientations(const []);
            }
          });
        }
      }
    }
  }

  void _toggleMobileStageOsd() {
    _mobileStageOsdTimer?.cancel();
    final next = !_mobileStageOsdVisible;
    if (mounted) {
      setState(() => _mobileStageOsdVisible = next);
    }
    if (next) {
      _mobileStageOsdTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) {
          setState(() => _mobileStageOsdVisible = false);
        }
      });
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onVodFocusManagerChanged);
    if (_isFullscreenMode && (Platform.isAndroid || Platform.isIOS)) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      if (!widget.appState.tvMode) {
        SystemChrome.setPreferredOrientations(const []);
      }
    }
    _fullscreenControlsTimer?.cancel();
    _mobileStageOsdTimer?.cancel();
    _fullscreenStageFocusNode.dispose();
    _fullscreenPlayBtnFocusNode.dispose();
    _windowedStageFocusNode.dispose();
    _windowedPlayBtnFocusNode.dispose();
    _adToastTimer?.cancel();
    _sleepTimer?.cancel();
    _startupWatchdogTimer?.cancel();
    _bufferingLagTimer?.cancel();
    _episodeSearchCtrl.dispose();
    _syncHistoryNow();
    widget.appState.proxyService.removeListener(_onExternalProxyServiceChanged);
    widget.appState.removeListener(_onAppStateNetworkResumeChanged);
    _positionSub?.cancel();
    _completedSub?.cancel();
    _errorSub?.cancel();
    _bufferingSub?.cancel();
    _widthSub?.cancel();
    _heightSub?.cancel();
    _videoParamsSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  void _setSleepTimer(int minutes) {
    _sleepTimer?.cancel();
    setState(() => _sleepTimerMinutes = minutes);
    if (minutes > 0) {
      _sleepTimer = Timer(Duration(minutes: minutes), () {
        if (!mounted) return;
        _player.pause();
        setState(() => _sleepTimerMinutes = 0);
        _showAdToast('🌙 睡眠定时 ($minutes 分钟) 已到，已暂停播放');
      });
      _showAdToast('🌙 已开启睡眠定时：$minutes 分钟后暂停');
    } else if (minutes == -1) {
      _showAdToast('🌙 已设置：播完本集后自动暂停');
    } else {
      _showAdToast('已关闭睡眠定时');
    }
  }

  void _onPositionUpdate(Duration pos) {
    if (pos > Duration.zero) {
      if (_player.state.playing) {
        unawaited(CloudMusicController.stopAllBackgroundAudioForVideo());
      }
      _startupWatchdogTimer?.cancel();
      if ((!_hasRenderedFirstFrame || _playError != null || _isResolvingPlay) &&
          mounted) {
        setState(() {
          _hasRenderedFirstFrame = true;
          _playError = null;
          _isResolvingPlay = false;
        });
      }
      if ((pos - _lastValidPosition).inSeconds.abs() >= 3) {
        _prematureEofRecoveryCount = 0;
      }
      _lastValidPosition = pos;
    }
    final curDur = _player.state.duration;
    if (curDur > Duration.zero) {
      _lastValidDuration = curDur;
    }

    // AB Repeat loop check
    final aSec = _abPointASeconds;
    final bSec = _abPointBSeconds;
    if (aSec != null && bSec != null && bSec > aSec + 1.0) {
      final curSec = pos.inMilliseconds / 1000.0;
      if (curSec >= bSec) {
        _player.seek(Duration(milliseconds: (aSec * 1000).round()));
        return;
      }
    }

    final totalSec = _player.state.duration.inSeconds;
    if (!_hasAppliedInitialSeek &&
        _pendingSeekSeconds > 3 &&
        totalSec > 0) {
      _hasAppliedInitialSeek = true;
      // Avoid seeking beyond video duration or re-seeking if `Media(start: ...)` already landed there
      if (_pendingSeekSeconds < totalSec - 5) {
        if ((pos.inSeconds - _pendingSeekSeconds).abs() > 4) {
          final target = Duration(seconds: _pendingSeekSeconds.round());
          _player.seek(target);
        }
        if (_isAutoIntroSkipPending) {
          _isAutoIntroSkipPending = false;
          _showAdToast('已自动跳过片头 (${_pendingSeekSeconds.round()}s)');
        }
        return;
      }
      _isAutoIntroSkipPending = false;
    }

    // Auto skip outro when reaching the outro window on full-length episodes (> 5 min)
    final outroSkipSec = widget.appState.vodSkipOutroSeconds;
    if (!_hasTriggeredOutroSkip &&
        outroSkipSec > 0 &&
        totalSec > 300 &&
        pos.inSeconds > 60) {
      final remainingSec = totalSec - pos.inSeconds;
      if (remainingSec > 0 && remainingSec <= outroSkipSec) {
        _hasTriggeredOutroSkip = true;
        if (_sleepTimerMinutes == -1) {
          setState(() => _sleepTimerMinutes = 0);
          _player.pause();
          _showAdToast('🌙 已到达片尾并按睡眠定时暂停播放');
          return;
        }
        _showAdToast('已自动跳过片尾 (${outroSkipSec}s)，正在切换下一集');
        _playNextEpisodeIfAvailable();
        return;
      }
    }

    final now = DateTime.now();
    if (now.difference(_lastHistorySync).inSeconds >= 5 &&
        pos.inSeconds > 2) {
      _lastHistorySync = now;
      _syncHistoryNow();
    }
  }

  String _formatDurationLabel(int totalSec) {
    if (totalSec <= 0) return '00:00';
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  void _syncHistoryNow() {
    final detail = _detail;
    final ep = _currentEpisode;
    if (detail == null || ep == null) return;
    final posSec = _player.state.position.inMilliseconds / 1000.0;
    final durSec = _player.state.duration.inMilliseconds / 1000.0;
    if (posSec <= 1) return;

    widget.appState.recordWatchHistory(
      source: _activeSource,
      detail: detail,
      episodeTitle: ep.title,
      lineName: ep.groupName,
      positionSeconds: posSec,
      durationSeconds: durSec,
    );
    widget.appState.saveVodProgress(
      sourceKey: _activeSource.id,
      vodId: _activeVodId,
      groupIndex: _selectedGroupIndex,
      episodeIndex: ep.index,
      episodeName: ep.title,
      positionSeconds: posSec.round(),
      durationSeconds: durSec.round(),
    );
  }

  Future<void> _loadDetail({
    int? overrideGroupIndex,
    int? overrideEpisodeIndex,
    double? overrideResumeSeconds,
  }) async {
    setState(() {
      _isLoadingDetail = true;
      _hasRenderedFirstFrame = false;
      _detailError = null;
    });

    try {
      final detail = await widget.appState.api.fetchVodDetail(
        _activeSource,
        _activeVodId,
      );
      if (!mounted) return;

      // Match saved exact progress or history or preferred line/episode (when watch history is enabled)
      final historyEnabled = widget.appState.watchHistoryEnabled;
      final exactProgress = historyEnabled
          ? widget.appState.getVodProgress(
              _activeSource.id,
              _activeVodId,
            )
          : null;
      final savedHist = historyEnabled
          ? widget.appState.findHistoryItem(
              _activeSource,
              _activeVodId,
            )
          : null;
      final targetLine = widget.preferredLine ?? savedHist?.line;
      final targetEpTitle = widget.preferredEpisodeTitle ??
          exactProgress?.episodeName ??
          savedHist?.episode;
      final resumeSec = overrideResumeSeconds ??
          (widget.initialResumeSeconds > 0
              ? widget.initialResumeSeconds
              : (exactProgress != null && exactProgress.positionSeconds > 0
                  ? exactProgress.positionSeconds.toDouble()
                  : (savedHist?.position ?? 0)));

      var groupIdx = 0;
      if (overrideGroupIndex != null &&
          overrideGroupIndex >= 0 &&
          overrideGroupIndex < detail.playGroups.length) {
        groupIdx = overrideGroupIndex;
      } else if (widget.initialGroupIndex != null &&
          widget.initialGroupIndex! >= 0 &&
          widget.initialGroupIndex! < detail.playGroups.length) {
        groupIdx = widget.initialGroupIndex!;
      } else if (targetLine != null && targetLine.isNotEmpty) {
        final foundIdx = detail.playGroups.indexWhere(
          (g) => g.name == targetLine,
        );
        if (foundIdx >= 0) groupIdx = foundIdx;
      } else if (exactProgress != null &&
          exactProgress.groupIndex >= 0 &&
          exactProgress.groupIndex < detail.playGroups.length) {
        groupIdx = exactProgress.groupIndex;
      }

      // If no explicit override was passed and the chosen group uses HTML share-page URLs (`/share/`)
      // while a direct `.m3u8`/`.mp4` play group is available, prefer the direct `.m3u8` group!
      if (overrideGroupIndex == null &&
          widget.initialGroupIndex == null &&
          widget.preferredLine == null &&
          detail.playGroups.length > 1) {
        final chosenGrp = detail.playGroups[groupIdx];
        final chosenFirstUrl = chosenGrp.episodes.isNotEmpty
            ? chosenGrp.episodes.first.rawUrl.toLowerCase()
            : '';
        final chosenIsDirectMedia = chosenFirstUrl.contains('.m3u8') ||
            chosenFirstUrl.contains('.mp4') ||
            chosenFirstUrl.contains('.flv');
        if (!chosenIsDirectMedia) {
          final directM3u8Idx = detail.playGroups.indexWhere((g) {
            if (g.episodes.isEmpty) return false;
            final u = g.episodes.first.rawUrl.toLowerCase();
            return u.contains('.m3u8') || u.contains('.mp4') || u.contains('.flv');
          });
          if (directM3u8Idx >= 0) {
            groupIdx = directM3u8Idx;
          }
        }
      }

      Episode? initialEp;
      if (detail.playGroups.isNotEmpty) {
        final grp = detail.playGroups[groupIdx];
        final targetEpIdx = overrideEpisodeIndex ??
            widget.initialEpisodeIndex ??
            exactProgress?.episodeIndex;
        if (targetEpIdx != null &&
            targetEpIdx >= 0 &&
            targetEpIdx < grp.episodes.length) {
          initialEp = grp.episodes[targetEpIdx];
        } else if (targetEpTitle != null && targetEpTitle.isNotEmpty) {
          initialEp = grp.episodes.firstWhere(
            (e) => e.title == targetEpTitle,
            orElse: () => grp.episodes.first,
          );
        } else if (grp.episodes.isNotEmpty) {
          initialEp = grp.episodes.first;
        }
      }

      setState(() {
        _detail = detail;
        _selectedGroupIndex = groupIdx;
        _isLoadingDetail = false;
      });

      if (initialEp != null) {
        await _selectAndPlayEpisode(initialEp, resumeSeconds: resumeSec);
        if (resumeSec > 5 && mounted) {
          _showAdToast(
            '已为您续播：${initialEp.title} · ${_formatDurationLabel(resumeSec.round())}',
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingDetail = false;
        _detailError = e.toString();
      });
    }
  }

  Future<void> _selectAndPlayEpisode(
    Episode episode, {
    double resumeSeconds = 0,
    bool resetTriedLines = true,
  }) async {
    _syncHistoryNow();
    final introSkip = widget.appState.vodSkipIntroSeconds.toDouble();
    final useIntroSkip = resumeSeconds <= 3 && introSkip > 3;
    final effectiveSeek = useIntroSkip ? introSkip : resumeSeconds;
    final attemptId = ++_playAttemptSessionId;

    setState(() {
      _currentEpisode = episode;
      _using115Direct = false;
      _isResolvingPlay = true;
      _hasRenderedFirstFrame = false;
      _videoWidth = 0;
      _videoHeight = 0;
      _fullscreenLandscapeOverride = null;
      _playError = null;
      _pendingSeekSeconds = effectiveSeek;
      _hasAppliedInitialSeek = false;
      _isAutoIntroSkipPending = useIntroSkip;
      _hasTriggeredOutroSkip = false;
      _removedAdSegments = 0;
      _removedAdSeconds = 0.0;
      _clientProxyRetryCountForEpisode = 0;
      _bypassClientProxyForCurrentEpisode = false;
      _didTryServerResolveForEpisode = false;
      _didTryServerProxyFallbackForEpisode = false;
      _externalSubtitleName = null;
      if (resetTriedLines) {
        _triedGroupIndicesForEpisode
          ..clear()
          ..add(_selectedGroupIndex);
        _verifiedFastestBackupLine = null;
      } else {
        _triedGroupIndicesForEpisode.add(_selectedGroupIndex);
      }
    });

    // Delay background alternate-line probing by 1.8s so 100% of network/proxy
    // bandwidth is dedicated to the primary stream's initial handshake & first frame!
    if (resetTriedLines) {
      Future<void>.delayed(const Duration(milliseconds: 1800), () {
        if (!mounted || attemptId != _playAttemptSessionId) {
          return;
        }
        unawaited(
          _precheckAlternateLinesInParallel(
            episode: episode,
            attemptId: attemptId,
          ),
        );
      });
    }

    try {
      final resolved = await widget.appState.api.resolveVodPlayback(
        _activeSource,
        playGroup: episode.groupName,
        episodeUrl: episode.rawUrl,
      );
      if (!mounted || attemptId != _playAttemptSessionId) return;

      final shouldProxy = _useServerProxy ||
          (resolved.backendProxyPlayback && resolved.directUrl.isEmpty);
      setState(() {
        _resolvedPlayback = resolved;
        _isResolvingPlay = false;
      });

      await _openResolvedStream(
        resolved,
        forceProxy: shouldProxy,
        attemptId: attemptId,
      );
    } catch (e) {
      if (!mounted || attemptId != _playAttemptSessionId) return;
      setState(() {
        _isResolvingPlay = false;
      });
      _triggerFastStartupFallback(reason: '解析播放地址失败：$e');
    }
  }

  /// Simultaneously probes up to 3 alternate play lines (`detail.playGroups`) for the
  /// current episode so if the primary line is dead or slow, we can switch in 0ms.
  Future<void> _precheckAlternateLinesInParallel({
    required Episode episode,
    required int attemptId,
  }) async {
    final detail = _detail;
    if (detail == null || detail.playGroups.length <= 1) return;

    final candidateGroupIndices = <int>[];
    for (var i = 0; i < detail.playGroups.length; i++) {
      if (i != _selectedGroupIndex &&
          !_triedGroupIndicesForEpisode.contains(i) &&
          detail.playGroups[i].episodes.isNotEmpty) {
        candidateGroupIndices.add(i);
        if (candidateGroupIndices.length >= 3) break;
      }
    }
    if (candidateGroupIndices.isEmpty) return;

    await Future.wait(
      candidateGroupIndices.map((gIdx) async {
        try {
          final grp = detail.playGroups[gIdx];
          final matchingEp = grp.episodes.firstWhere(
            (e) => e.title == episode.title,
            orElse: () => episode.index < grp.episodes.length
                ? grp.episodes[episode.index]
                : grp.episodes.first,
          );
          final resolved = await widget.appState.api.resolveVodPlayback(
            _activeSource,
            playGroup: matchingEp.groupName,
            episodeUrl: matchingEp.rawUrl,
          );
          if (!mounted || attemptId != _playAttemptSessionId) return;
          if (resolved.directUrl.isEmpty) return;
          final probe = await widget.appState.api.probeVodStreamPlayableFast(
            resolved.directUrl,
            resolved.headers,
            timeout: const Duration(milliseconds: 2200),
          );
          if (!mounted || attemptId != _playAttemptSessionId || !probe.ok) {
            return;
          }
          final curBest = _verifiedFastestBackupLine;
          if (curBest == null || probe.latencyMs < curBest.latencyMs) {
            _verifiedFastestBackupLine = (
              groupIndex: gIdx,
              episode: matchingEp,
              resolved: resolved,
              latencyMs: probe.latencyMs,
            );
          }
        } catch (_) {}
      }),
    );
  }

  Future<void> _openResolvedStream(
    ResolvedPlayback resolved, {
    required bool forceProxy,
    bool skipM3u8Clean = false,
    bool bypassClientProxy = false,
    bool autoplay = true,
    int? attemptId,
  }) async {
    final activeAttemptId = attemptId ?? _playAttemptSessionId;
    _startupWatchdogTimer?.cancel();
    String playUrl = resolved.directUrl;
    Map<String, String> headers = {...resolved.headers};

    if (forceProxy && resolved.serverProxyUrl.isNotEmpty) {
      playUrl = widget.appState.api.resolveUrl(resolved.serverProxyUrl);
      headers = {
        ...widget.appState.api.authHeaders,
      };
    } else if (playUrl.isEmpty && resolved.serverProxyUrl.isNotEmpty) {
      playUrl = widget.appState.api.resolveUrl(resolved.serverProxyUrl);
      headers = {
        ...widget.appState.api.authHeaders,
      };
    } else if (playUrl.startsWith('/')) {
      playUrl = widget.appState.api.resolveUrl(playUrl);
      headers = {
        ...widget.appState.api.authHeaders,
        ...headers,
      };
    }

    if (playUrl.isEmpty) {
      _triggerFastStartupFallback(reason: '未获取到有效播放地址');
      return;
    }

    String finalMediaTarget = playUrl;
    bool usingLocalStreamRelay = false;

    if (!bypassClientProxy) {
      final relayed = await widget.appState.proxyService.resolveProxiedStreamUrl(
        RequestScenario.vodStream,
        playUrl,
        headers: headers,
        cleanM3u8Ads: !skipM3u8Clean && widget.appState.vodFilterM3u8Ads,
      );
      if (!mounted || activeAttemptId != _playAttemptSessionId) return;
      if (relayed != playUrl && relayed.contains('/__m3u8_proxy__/')) {
        finalMediaTarget = relayed;
        usingLocalStreamRelay = true;
      }
    }

    await _applyVodStreamHeaders(
      headers,
      streamUrl: finalMediaTarget,
      bypassClientProxy: bypassClientProxy || usingLocalStreamRelay,
    );
    if (!mounted || activeAttemptId != _playAttemptSessionId) return;
    if (usingLocalStreamRelay) {
      _usingClientProxy = !finalMediaTarget.contains('direct=1');
    }

    if (mounted) {
      setState(() {
        _using115Direct = false;
        _playError = null;
        _hasRenderedFirstFrame =
            (_player.state.width ?? 0) > 0 || _player.state.position > Duration.zero;
      });
    }

    _activeStreamUrl = finalMediaTarget;
    _activeStreamHeaders = headers;
    _lastStreamOpenInitiatedAt = DateTime.now();
    unawaited(CloudMusicController.stopAllBackgroundAudioForVideo());
    final startOffset = (!_hasAppliedInitialSeek && _pendingSeekSeconds > 3)
        ? Duration(seconds: _pendingSeekSeconds.round())
        : null;
    await _player.open(
      Media(
        finalMediaTarget,
        httpHeaders: usingLocalStreamRelay ? const {} : headers,
        start: startOffset,
      ),
      play: autoplay,
    );
    if (!mounted || activeAttemptId != _playAttemptSessionId) return;
    if (_playbackSpeed != 1.0) {
      await _player.setRate(_playbackSpeed);
    }

    // Startup watchdog: give VOD CDNs, M3U8 ad-stripping, and proxy tunnels adequate time
    // (15s direct/relay, 18s client proxy) for TLS + playlist + key + first segment,
    // and never abort while video has rendered, buffered, or downstream bytes are flowing!
    final watchdogMs = _usingClientProxy ? 18000 : 15000;
    _startupWatchdogTimer = Timer(Duration(milliseconds: watchdogMs), () {
      if (!mounted || activeAttemptId != _playAttemptSessionId) return;
      final hasStarted = _hasRenderedFirstFrame ||
          _player.state.duration > Duration.zero ||
          _player.state.position > Duration.zero ||
          _player.state.buffer > Duration.zero ||
          (_player.state.width ?? 0) > 0 ||
          (_player.state.height ?? 0) > 0 ||
          LocalProxyTunnelBridge.recentDownstreamBytesPerSecond > 256;
      if (!hasStarted) {
        _triggerFastStartupFallback(reason: '当前线路响应超时');
      }
    });
  }

  String _resolveCurrent115DownloadUrl() {
    final resolved = _resolvedPlayback;
    if (resolved != null && resolved.directUrl.trim().isNotEmpty) {
      return resolved.directUrl.trim();
    }
    if (_activeStreamUrl.trim().isNotEmpty) {
      final unwrapped = Local115DirectService.unwrapDownloadTargetUrlAndHeaders(
        _activeStreamUrl.trim(),
        _activeStreamHeaders,
      ).url;
      if (unwrapped.isNotEmpty && !unwrapped.contains('127.0.0.1')) {
        return _activeStreamUrl.trim();
      }
    }
    return _currentEpisode?.rawUrl.trim() ?? '';
  }

  List<String> _resolveFallback115DownloadUrls() {
    final result = <String>[];
    void addIfValid(String raw) {
      final u = Local115DirectService.unwrapDownloadTargetUrlAndHeaders(
        raw,
        _activeStreamHeaders,
      ).url.trim();
      if (u.isEmpty ||
          u.contains('127.0.0.1') ||
          u.contains('localhost') ||
          u.startsWith('file://')) {
        return;
      }
      if (u.startsWith('http://') || u.startsWith('https://')) {
        if (!result.contains(raw)) {
          result.add(raw);
        }
      }
    }

    if (_verifiedFastestBackupLine != null) {
      addIfValid(_verifiedFastestBackupLine!.resolved.directUrl);
      addIfValid(_verifiedFastestBackupLine!.episode.rawUrl);
    }
    if (_activeStreamUrl.trim().isNotEmpty) {
      addIfValid(_activeStreamUrl.trim());
    }
    final curEp = _currentEpisode;
    if (curEp != null) {
      addIfValid(curEp.rawUrl);
    }
    final detail = _detail;
    if (detail != null && curEp != null) {
      for (var i = 0; i < detail.playGroups.length; i++) {
        if (i == _selectedGroupIndex) continue;
        final grp = detail.playGroups[i];
        if (grp.episodes.isEmpty) continue;
        final match =
            grp.episodes.where((e) => e.title == curEp.title).firstOrNull ??
            (curEp.index < grp.episodes.length
                ? grp.episodes[curEp.index]
                : null);
        if (match != null) addIfValid(match.rawUrl);
      }
    }
    return result;
  }

  String _resolveCurrent115VideoName() {
    final vodTitle = (_detail?.vodName ?? widget.initialTitle).trim();
    final epTitle = (_currentEpisode?.title ?? '').trim();
    if (vodTitle.isNotEmpty && epTitle.isNotEmpty) {
      return '$vodTitle - $epTitle';
    }
    if (vodTitle.isNotEmpty) return vodTitle;
    return epTitle.isNotEmpty ? epTitle : '点播视频';
  }

  Future<void> _applyResolved115Stream(Resolved115Stream resolved) async {
    if (!mounted) return;
    final attempt = ++_playAttemptSessionId;
    _startupWatchdogTimer?.cancel();
    _bufferingLagTimer?.cancel();
    final playerPosSec = _player.state.position.inSeconds;
    final curSec = playerPosSec > 2
        ? playerPosSec
        : (_lastValidPosition.inSeconds > 2
              ? _lastValidPosition.inSeconds
              : _pendingSeekSeconds.round());
    setState(() {
      _using115Direct = true;
      _activeStreamUrl = resolved.proxyStreamUrl;
      _activeStreamHeaders = resolved.playbackHeaders;
      _playError = null;
      _isResolvingPlay = false;
      if (curSec > 2) {
        _pendingSeekSeconds = curSec.toDouble();
        _hasAppliedInitialSeek = false;
      }
    });
    await _applyVodStreamHeaders(
      resolved.playbackHeaders,
      streamUrl: resolved.proxyStreamUrl,
      bypassClientProxy: true,
    );
    if (!mounted || attempt != _playAttemptSessionId) return;
    unawaited(CloudMusicController.stopAllBackgroundAudioForVideo());
    await _player.open(
      Media(
        resolved.proxyStreamUrl,
        httpHeaders: resolved.playbackHeaders,
        start: curSec > 2 ? Duration(seconds: curSec) : null,
      ),
      play: true,
    );
    if (!mounted || attempt != _playAttemptSessionId) return;
    if (_playbackSpeed != 1.0) {
      await _player.setRate(_playbackSpeed);
    }
    _showAdToast('⚡ 已切换至本地直连 115 高速播放：${resolved.fileName}');
  }

  void _triggerFastStartupFallback({required String reason}) {
    if (!mounted || _using115Direct) return;
    _startupWatchdogTimer?.cancel();
    final resolved = _resolvedPlayback;
    final currentEp = _currentEpisode;

    // 1. If a parallel-verified backup play line is already ready, switch to it in 0ms!
    final backupLine = _verifiedFastestBackupLine;
    if (backupLine != null &&
        !_triedGroupIndicesForEpisode.contains(backupLine.groupIndex)) {
      _verifiedFastestBackupLine = null;
      _triedGroupIndicesForEpisode.add(backupLine.groupIndex);
      setState(() {
        _selectedGroupIndex = backupLine.groupIndex;
        _currentEpisode = backupLine.episode;
        _resolvedPlayback = backupLine.resolved;
        _playError = null;
      });
      _showAdToast(
        '⚡ 正在为您自动切换至最快可用线路：${backupLine.episode.groupName} (${backupLine.latencyMs}ms)',
      );
      unawaited(
        _openResolvedStream(
          backupLine.resolved,
          forceProxy: _useServerProxy ||
              (backupLine.resolved.backendProxyPlayback &&
                  backupLine.resolved.directUrl.isEmpty),
          attemptId: _playAttemptSessionId,
        ),
      );
      return;
    }

    // 2. If TVBox source used the 0ms direct shortcut, try server-side `/api/vod/play` parser once
    if (_activeSource.isTvBox &&
        !_didTryServerResolveForEpisode &&
        currentEp != null) {
      _didTryServerResolveForEpisode = true;
      final activeAttempt = _playAttemptSessionId;
      if (mounted) {
        setState(() {
          _isResolvingPlay = true;
          _playError = null;
        });
      }
      unawaited(
        widget.appState.api
            .resolveVodPlayback(
          _activeSource,
          playGroup: currentEp.groupName,
          episodeUrl: currentEp.rawUrl,
          forceServerResolve: true,
        )
            .then((srvResolved) {
          if (!mounted || activeAttempt != _playAttemptSessionId) return;
          final sameDirectFailed = resolved != null &&
              srvResolved.directUrl.isNotEmpty &&
              srvResolved.directUrl == resolved.directUrl;
          setState(() {
            _resolvedPlayback = srvResolved;
            _isResolvingPlay = false;
            _playError = null;
          });
          _openResolvedStream(
            srvResolved,
            forceProxy: _useServerProxy ||
                sameDirectFailed ||
                (srvResolved.backendProxyPlayback &&
                    srvResolved.directUrl.isEmpty),
            attemptId: activeAttempt,
          );
        }).catchError((Object err) {
          if (mounted && activeAttempt == _playAttemptSessionId) {
            setState(() => _isResolvingPlay = false);
            _triggerFastStartupFallback(reason: '服务端解析未就绪');
          }
        }),
      );
      return;
    }

    // 3. If using client proxy, switch to the next fastest proxy node or bypass proxy
    if (_usingClientProxy &&
        !_bypassClientProxyForCurrentEpisode &&
        resolved != null) {
      final activeAttempt = _playAttemptSessionId;
      if (_clientProxyRetryCountForEpisode < 1) {
        _clientProxyRetryCountForEpisode++;
        unawaited(
          widget.appState.proxyService
              .reportActiveNodeLag(reason: '代理加载视频缓慢，极速切换备用节点')
              .then((_) {
            if (mounted && activeAttempt == _playAttemptSessionId) {
              _openResolvedStream(
                resolved,
                forceProxy: _useServerProxy,
                skipM3u8Clean: true,
                bypassClientProxy: false,
                attemptId: activeAttempt,
              );
            }
          }),
        );
        return;
      }
      _bypassClientProxyForCurrentEpisode = true;
      _openResolvedStream(
        resolved,
        forceProxy: _useServerProxy,
        skipM3u8Clean: true,
        bypassClientProxy: true,
        attemptId: activeAttempt,
      );
      return;
    }

    // 4. Try the next untested play line in `_detail.playGroups` that provides a direct media stream
    final detail = _detail;
    bool isDirectMediaUrl(String raw) {
      final lower = raw.toLowerCase();
      return lower.contains('.m3u8') ||
          lower.contains('.mp4') ||
          lower.contains('.flv') ||
          lower.contains('.mkv');
    }

    if (detail != null && currentEp != null && detail.playGroups.length > 1) {
      for (var i = 0; i < detail.playGroups.length; i++) {
        if (!_triedGroupIndicesForEpisode.contains(i) &&
            detail.playGroups[i].episodes.isNotEmpty) {
          final nextGrp = detail.playGroups[i];
          final nextEp = nextGrp.episodes.firstWhere(
            (e) => e.title == currentEp.title,
            orElse: () => currentEp.index < nextGrp.episodes.length
                ? nextGrp.episodes[currentEp.index]
                : nextGrp.episodes.first,
          );
          if (!isDirectMediaUrl(nextEp.rawUrl) &&
              isDirectMediaUrl(currentEp.rawUrl)) {
            continue;
          }
          _triedGroupIndicesForEpisode.add(i);
          setState(() {
            _selectedGroupIndex = i;
            _playError = null;
          });
          _showAdToast('⚡ 正在自动切换至备用播放线路：${nextGrp.name}');
          _selectAndPlayEpisode(
            nextEp,
            resumeSeconds: _pendingSeekSeconds,
            resetTriedLines: false,
          );
          return;
        }
      }
    }

    // 5. Fallback: if direct/client-proxy failed and a server proxy URL exists, try server proxy via local relay
    if (resolved != null &&
        resolved.serverProxyUrl.isNotEmpty &&
        !_activeStreamUrl.contains('/api/vod/proxy') &&
        !_didTryServerProxyFallbackForEpisode) {
      _didTryServerProxyFallbackForEpisode = true;
      _showAdToast('⚡ 正在尝试服务端中转通道播放...');
      unawaited(
        _openResolvedStream(
          resolved,
          forceProxy: true,
          skipM3u8Clean: false,
          bypassClientProxy: false,
          attemptId: _playAttemptSessionId,
        ),
      );
      return;
    }

    // 6. Try any remaining untested play lines (including web share/iframe lines)
    if (detail != null && currentEp != null && detail.playGroups.length > 1) {
      for (var i = 0; i < detail.playGroups.length; i++) {
        if (!_triedGroupIndicesForEpisode.contains(i) &&
            detail.playGroups[i].episodes.isNotEmpty) {
          _triedGroupIndicesForEpisode.add(i);
          final nextGrp = detail.playGroups[i];
          final nextEp = nextGrp.episodes.firstWhere(
            (e) => e.title == currentEp.title,
            orElse: () => currentEp.index < nextGrp.episodes.length
                ? nextGrp.episodes[currentEp.index]
                : nextGrp.episodes.first,
          );
          setState(() {
            _selectedGroupIndex = i;
            _playError = null;
          });
          _showAdToast('⚡ 正在自动切换至备用播放线路：${nextGrp.name}');
          _selectAndPlayEpisode(
            nextEp,
            resumeSeconds: _pendingSeekSeconds,
            resetTriedLines: false,
          );
          return;
        }
      }
    }

    // Before showing a fatal error overlay, double-check that video hasn't started or buffered in the meantime
    if (_hasRenderedFirstFrame ||
        _player.state.duration > Duration.zero ||
        _player.state.position > Duration.zero ||
        (_player.state.width ?? 0) > 0 ||
        (_player.state.height ?? 0) > 0) {
      return;
    }

    if (mounted) {
      setState(() {
        _isResolvingPlay = false;
        _playError = reason;
      });
    }
  }

  void _playNextEpisodeIfAvailable() {
    final detail = _detail;
    final current = _currentEpisode;
    if (detail == null || current == null) return;
    final grpIdx = detail.playGroups.indexWhere(
      (g) => g.name == current.groupName,
    );
    if (grpIdx < 0) return;
    final episodes = detail.playGroups[grpIdx].episodes;
    final nextIdx = current.index + 1;
    if (nextIdx < episodes.length) {
      _selectAndPlayEpisode(episodes[nextIdx]);
    }
  }

  String _episodeDownloadKey(Episode ep) => '${ep.groupName}|${ep.rawUrl}';

  Future<void> _downloadCurrentEpisode() async {
    final detail = _detail;
    final ep = _currentEpisode;
    final resolved = _resolvedPlayback;
    if (detail == null || ep == null) return;

    final epKey = _episodeDownloadKey(ep);
    if (_addingDownloadKeys.contains(epKey)) return;

    setState(() {
      _addingDownloadKeys.add(epKey);
      _failedDownloadKeys.remove(epKey);
    });

    String downloadUrl = resolved?.directUrl ?? '';
    Map<String, String> headers = resolved?.headers ?? {};

    if (downloadUrl.isEmpty) {
      try {
        final r = await widget.appState.api.resolveVodPlayback(
          _activeSource,
          playGroup: ep.groupName,
          episodeUrl: ep.rawUrl,
        );
        downloadUrl = r.directUrl;
        headers = r.headers;
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _addingDownloadKeys.remove(epKey);
          _failedDownloadKeys.add(epKey);
        });
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              backgroundColor: const Color(0xFF7A1F2B),
              behavior: SnackBarBehavior.floating,
              content: Row(
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    color: Color(0xFFFF8A80),
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text('解析下载地址失败：$e')),
                ],
              ),
            ),
          );
        return;
      }
    }

    final taskName = detail.playGroups.any((g) => g.episodes.length > 1)
        ? '${detail.vodName} - ${ep.title}'
        : detail.vodName;

    try {
      await widget.appState.api.createDownloadTask(
        url: downloadUrl,
        name: taskName,
        headers: headers,
        videoContext: {
          'source': _activeSource.librarySourceKey,
          'vod_id': detail.vodId,
          'vod_name': detail.vodName,
          'episode': ep.title,
          'line': ep.groupName,
        },
      );
      await widget.appState.refreshDownloadTasks(silent: true);
      if (!mounted) return;
      setState(() {
        _addingDownloadKeys.remove(epKey);
        _queuedDownloadKeys.add(epKey);
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF165B36),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(milliseconds: 2200),
            content: Row(
              children: [
                const Icon(
                  Icons.check_circle_rounded,
                  color: Color(0xFF69F0AE),
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text('已成功加入下载队列：$taskName')),
              ],
            ),
          ),
        );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _addingDownloadKeys.remove(epKey);
        _failedDownloadKeys.add(epKey);
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF7A1F2B),
            behavior: SnackBarBehavior.floating,
            content: Row(
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  color: Color(0xFFFF8A80),
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text('创建下载任务失败：$e')),
              ],
            ),
          ),
        );
    }
  }

  void _onProxyNodeSwitched(String statusMessage) {
    if (!mounted) return;
    _lastVodRouteSignature = _computeVodRouteSignature();
    final attemptId = ++_playAttemptSessionId;
    final wasPlaying = _player.state.playing || !_hasRenderedFirstFrame;
    if (statusMessage.isNotEmpty) {
      _showAdToast(statusMessage);
    }
    final curPosSec = _player.state.position.inSeconds > 0
        ? _player.state.position.inSeconds.toDouble()
        : _lastValidPosition.inSeconds.toDouble();
    if (curPosSec > 2) {
      _pendingSeekSeconds = curPosSec;
      _hasAppliedInitialSeek = false;
    }
    final isRelayMode = widget.appState.proxyService
            .resolveEffectiveRoute(RequestScenario.vodStream) ==
        ScenarioRouteMode.serverRelay;
    setState(() {
      _useServerProxy = isRelayMode;
      _using115Direct = false;
      _bypassClientProxyForCurrentEpisode = false;
      _clientProxyRetryCountForEpisode = 0;
      _hasRenderedFirstFrame = false;
      _playError = null;
    });
    final resolved = _resolvedPlayback;
    if (resolved != null) {
      _openResolvedStream(
        resolved,
        forceProxy: isRelayMode ||
            (resolved.backendProxyPlayback && resolved.directUrl.isEmpty),
        bypassClientProxy: isRelayMode,
        autoplay: wasPlaying,
        attemptId: attemptId,
      );
    } else if (_currentEpisode != null) {
      _selectAndPlayEpisode(_currentEpisode!, resumeSeconds: curPosSec);
    }
  }

  void _enterMiniPlayerMode() {
    if (_activeStreamUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前视频尚未开始播放，无法开启小窗')),
      );
      return;
    }
    _startupWatchdogTimer?.cancel();
    _bufferingLagTimer?.cancel();
    _syncHistoryNow();
    final resumeSec = _player.state.position.inSeconds > 0
        ? _player.state.position.inSeconds
        : _lastValidPosition.inSeconds;
    final title = _detail?.vodName.isNotEmpty == true
        ? _detail!.vodName
        : (widget.initialTitle.isNotEmpty ? widget.initialTitle : '视频播放');
    final epName = _currentEpisode?.title ?? '';
    final session = MiniPlayerSession(
      title: title,
      subtitle: epName.isNotEmpty
          ? '$epName · ${_activeSource.name}'
          : _activeSource.name,
      streamUrl: _activeStreamUrl,
      headers: _activeStreamHeaders,
      isLive: false,
      is115Playback: _using115Direct,
      vodSource: _activeSource,
      vodId: _activeVodId,
      vodTitle: title,
      vodPoster: _detail?.vodPic.isNotEmpty == true
          ? _detail!.vodPic
          : widget.initialPoster,
      episodeName: epName,
      groupIndex: _selectedGroupIndex,
      episodeIndex: _currentEpisode?.index ?? 0,
      initialPositionSeconds: resumeSec,
    );
    _player.stop();
    widget.appState.startMiniPlayer(session);
    Navigator.of(context).pop();
  }

  Future<void> _captureVideoScreenshot() async {
    try {
      final bytes = await _player.screenshot(format: 'image/png');
      if (bytes == null || bytes.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前视频画面暂无法截图')),
        );
        return;
      }
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          Directory.systemTemp.path;
      final downloadsDir = Directory('$home/Downloads');
      final targetDir =
          await downloadsDir.exists() ? downloadsDir : Directory.systemTemp;
      final ts = DateTime.now().millisecondsSinceEpoch;
      final file = File('${targetDir.path}/vod_snapshot_$ts.png');
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      _showAdToast('📸 画面截图已保存：${file.path.split('/').last}');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('视频画面截图已保存至：${file.path}'),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('截图失败：$e')),
      );
    }
  }

  Future<void> _showExternalSubtitleDialog() async {
    final urlCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final embeddedTracks = _player.state.tracks.subtitle;
            final activeSub = _player.state.track.subtitle;
            return AlertDialog(
              backgroundColor: VideoPlatformTheme.bgElevated,
              title: Row(
                children: [
                  Icon(
                    Icons.subtitles_rounded,
                    size: 19,
                    color: VideoPlatformTheme.accent,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '外挂字幕与内嵌字幕管理 (.srt / .ass / .vtt)',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              content: SizedBox(
                width: 480,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed: () async {
                            try {
                              final res = await _nativeUtilsChannel
                                  .invokeMethod<dynamic>('pickFiles', {
                                'allowMultiple': false,
                              });
                              if (res is List && res.isNotEmpty) {
                                final path = res.first.toString().trim();
                                if (path.isNotEmpty) {
                                  final name = path.split('/').last;
                                  await _player.setSubtitleTrack(
                                    SubtitleTrack.uri(
                                      Uri.file(path).toString(),
                                      title: name,
                                    ),
                                  );
                                  if (mounted) {
                                    setState(() => _externalSubtitleName = name);
                                    _showAdToast('已加载外挂字幕：$name');
                                  }
                                  if (ctx.mounted) Navigator.pop(ctx);
                                }
                              }
                            } catch (e) {
                              if (ctx.mounted) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  SnackBar(content: Text('选择字幕文件失败：$e')),
                                );
                              }
                            }
                          },
                          icon: const Icon(Icons.folder_open_rounded, size: 16),
                          label: const Text('选择本地字幕文件 (.srt / .ass / .vtt)'),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          onPressed: () async {
                            await _player.setSubtitleTrack(SubtitleTrack.no());
                            if (mounted) {
                              setState(() => _externalSubtitleName = null);
                              _showAdToast('已关闭字幕显示');
                            }
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                          icon: const Icon(
                            Icons.subtitles_off_outlined,
                            size: 16,
                          ),
                          label: const Text('关闭字幕'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '或输入远程字幕 URL / 本地绝对路径：',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: VideoPlatformTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: urlCtrl,
                            style: const TextStyle(fontSize: 13),
                            decoration: const InputDecoration(
                              hintText:
                                  'https://example.com/sub.srt 或 /Users/.../movie.ass',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: () async {
                            final raw = urlCtrl.text.trim();
                            if (raw.isEmpty) return;
                            final uriStr = raw.startsWith('/')
                                ? Uri.file(raw).toString()
                                : raw;
                            final name = raw.split('/').last;
                            await _player.setSubtitleTrack(
                              SubtitleTrack.uri(uriStr, title: name),
                            );
                            if (mounted) {
                              setState(() => _externalSubtitleName = name);
                              _showAdToast('已加载字幕：$name');
                            }
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                          child: const Text('加载'),
                        ),
                      ],
                    ),
                    if (embeddedTracks.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Divider(height: 1),
                      const SizedBox(height: 10),
                      Text(
                        '流内可用字幕轨道 (${embeddedTracks.length})：',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: VideoPlatformTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: embeddedTracks.map((t) {
                          final selected = activeSub.id == t.id;
                          final label = (t.title?.isNotEmpty == true)
                              ? t.title!
                              : (t.language?.isNotEmpty == true
                                  ? t.language!
                                  : '轨道 ${t.id}');
                          return ChoiceChip(
                            label: Text(label),
                            selected: selected,
                            selectedColor: VideoPlatformTheme.accent,
                            onSelected: (_) async {
                              await _player.setSubtitleTrack(t);
                              setDialogState(() {});
                              if (mounted) setState(() {});
                            },
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        );
      },
    );
    urlCtrl.dispose();
  }

  Future<void> _showCrossSiteSourceSwitchDialog() async {
    final keyword = (_detail?.vodName.isNotEmpty == true
            ? _detail!.vodName
            : widget.initialTitle)
        .trim();
    if (keyword.isEmpty) return;

    final candidateSources = widget.appState.sources
        .where((s) => s.searchable && s.id != _activeSource.id)
        .toList();

    final matches = <({VodSource source, VodItem item})>[];
    bool isSearching = true;
    int finishedCount = 0;
    final totalToSearch =
        candidateSources.length > 18 ? 18 : candidateSources.length;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        bool startedSearch = false;
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            if (!startedSearch) {
              startedSearch = true;
              Future.microtask(() async {
                final targets = candidateSources.take(totalToSearch).toList();
                const batchSize = 6;
                for (var i = 0; i < targets.length; i += batchSize) {
                  if (!ctx.mounted) return;
                  final batch = targets.skip(i).take(batchSize);
                  await Future.wait(
                    batch.map((src) async {
                      try {
                        final res =
                            await widget.appState.api.searchVod(src, keyword);
                        if (!ctx.mounted) return;
                        for (final item in res) {
                          if (item.vodName.contains(keyword) ||
                              keyword.contains(item.vodName)) {
                            matches.add((source: src, item: item));
                          }
                        }
                      } catch (_) {
                      } finally {
                        finishedCount++;
                        if (ctx.mounted) {
                          setDialogState(() {});
                        }
                      }
                    }),
                  );
                }
                if (ctx.mounted) {
                  setDialogState(() => isSearching = false);
                }
              });
            }

            return AlertDialog(
              backgroundColor: VideoPlatformTheme.bgElevated,
              title: Row(
                children: [
                  Icon(
                    Icons.swap_horiz_rounded,
                    size: 20,
                    color: VideoPlatformTheme.accent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '跨站点智能换源 · 《$keyword》',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (isSearching)
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: VideoPlatformTheme.accent,
                      ),
                    ),
                ],
              ),
              content: SizedBox(
                width: 540,
                height: 360,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isSearching
                          ? '正在并发检索备用站点 ($finishedCount / $totalToSearch)，已匹配 ${matches.length} 个片源（切换后自动衔接当前集数与进度）...'
                          : '共检索 $totalToSearch 个备用站点，找到 ${matches.length} 个同名可用片源（点击即可无缝切换并续播）：',
                      style: TextStyle(
                        fontSize: 12,
                        color: VideoPlatformTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: matches.isEmpty
                          ? Center(
                              child: Text(
                                isSearching
                                    ? '正在全网搜索同名影片线路...'
                                    : '未在其他站点找到同名影片',
                                style: TextStyle(
                                  color: VideoPlatformTheme.textMuted,
                                  fontSize: 13,
                                ),
                              ),
                            )
                          : ListView.separated(
                              itemCount: matches.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (_, idx) {
                                final m = matches[idx];
                                final exactExactMatch =
                                    m.item.vodName.trim() == keyword;
                                return ListTile(
                                  dense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  leading: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: exactExactMatch
                                          ? VideoPlatformTheme.accent
                                              .withValues(alpha: 0.16)
                                          : VideoPlatformTheme.bgCard,
                                      borderRadius: BorderRadius.circular(5),
                                      border: Border.all(
                                        color: exactExactMatch
                                            ? VideoPlatformTheme.accent
                                            : VideoPlatformTheme.borderSubtle,
                                      ),
                                    ),
                                    child: Text(
                                      m.source.name,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: exactExactMatch
                                            ? VideoPlatformTheme.accent
                                            : VideoPlatformTheme.textPrimary,
                                      ),
                                    ),
                                  ),
                                  title: Text(
                                    m.item.vodName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w500,
                                      color: VideoPlatformTheme.textPrimary,
                                    ),
                                  ),
                                  subtitle: Text(
                                    [
                                      if (m.item.vodRemarks.isNotEmpty)
                                        m.item.vodRemarks,
                                      if (m.item.typeName.isNotEmpty)
                                        m.item.typeName,
                                    ].join(' · '),
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: VideoPlatformTheme.textSecondary,
                                    ),
                                  ),
                                  trailing: FilledButton.tonal(
                                    onPressed: () {
                                      final keepEpIdx =
                                          _currentEpisode?.index ?? 0;
                                      final keepPosSec = _player
                                          .state.position.inSeconds
                                          .toDouble();
                                      Navigator.of(ctx).pop();
                                      setState(() {
                                        _activeSource = m.source;
                                        _activeVodId = m.item.vodId;
                                      });
                                      _showAdToast(
                                        '正在切换至片源「${m.source.name}」并衔接进度...',
                                      );
                                      _loadDetail(
                                        overrideGroupIndex: 0,
                                        overrideEpisodeIndex: keepEpIdx,
                                        overrideResumeSeconds: keepPosSec,
                                      );
                                    },
                                    child: const Text('一键换源'),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showBatchDownloadDialog() async {
    final detail = _detail;
    if (detail == null || detail.playGroups.isEmpty) return;
    final group = detail.playGroups[_selectedGroupIndex];
    final selectedIndices = <int>{
      if (_currentEpisode != null) _currentEpisode!.index,
    };

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        bool isSubmitting = false;
        int processedCount = 0;
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: VideoPlatformTheme.bgElevated,
              title: Text(
                '批量缓存下载 · ${group.name}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              content: SizedBox(
                width: 580,
                height: 400,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        TextButton.icon(
                          onPressed: isSubmitting
                              ? null
                              : () {
                                  setDialogState(() {
                                    selectedIndices.addAll(
                                      group.episodes.map((e) => e.index),
                                    );
                                  });
                                },
                          icon: const Icon(Icons.select_all_rounded, size: 15),
                          label: const Text('全选'),
                        ),
                        TextButton.icon(
                          onPressed: isSubmitting
                              ? null
                              : () {
                                  setDialogState(() {
                                    for (final ep in group.episodes) {
                                      if (selectedIndices.contains(ep.index)) {
                                        selectedIndices.remove(ep.index);
                                      } else {
                                        selectedIndices.add(ep.index);
                                      }
                                    }
                                  });
                                },
                          icon: const Icon(Icons.flip_rounded, size: 15),
                          label: const Text('反选'),
                        ),
                        if (_currentEpisode != null)
                          TextButton.icon(
                            onPressed: isSubmitting
                                ? null
                                : () {
                                    final start = _currentEpisode!.index;
                                    setDialogState(() {
                                      for (final ep in group.episodes) {
                                        if (ep.index >= start) {
                                          selectedIndices.add(ep.index);
                                        }
                                      }
                                    });
                                  },
                            icon: const Icon(
                              Icons.playlist_play_rounded,
                              size: 16,
                            ),
                            label: const Text('从本集往后全选'),
                          ),
                        TextButton(
                          onPressed: isSubmitting
                              ? null
                              : () => setDialogState(selectedIndices.clear),
                          child: const Text('清空'),
                        ),
                        Text(
                          '已选 ${selectedIndices.length} / ${group.episodes.length} 集',
                          style: TextStyle(
                            color: VideoPlatformTheme.accent,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: GridView.builder(
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 130,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          childAspectRatio: 2.8,
                        ),
                        itemCount: group.episodes.length,
                        itemBuilder: (_, idx) {
                          final ep = group.episodes[idx];
                          final checked = selectedIndices.contains(ep.index);
                          return InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: isSubmitting
                                ? null
                                : () {
                                    setDialogState(() {
                                      if (checked) {
                                        selectedIndices.remove(ep.index);
                                      } else {
                                        selectedIndices.add(ep.index);
                                      }
                                    });
                                  },
                            child: Container(
                              alignment: Alignment.center,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              decoration: BoxDecoration(
                                color: checked
                                    ? VideoPlatformTheme.accent
                                        .withValues(alpha: 0.2)
                                    : VideoPlatformTheme.bgCard,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: checked
                                      ? VideoPlatformTheme.accent
                                      : VideoPlatformTheme.borderSubtle,
                                ),
                              ),
                              child: Text(
                                ep.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: checked
                                      ? VideoPlatformTheme.accent
                                      : VideoPlatformTheme.textPrimary,
                                  fontWeight: checked
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    if (isSubmitting) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: selectedIndices.isEmpty
                            ? null
                            : processedCount / selectedIndices.length,
                        color: VideoPlatformTheme.accent,
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed:
                      isSubmitting ? null : () => Navigator.of(ctx).pop(),
                  child: const Text('取消'),
                ),
                FilledButton.icon(
                  onPressed: isSubmitting || selectedIndices.isEmpty
                      ? null
                      : () async {
                          setDialogState(() {
                            isSubmitting = true;
                            processedCount = 0;
                          });
                          var successCount = 0;
                          final sorted = selectedIndices.toList()..sort();
                          const batchSize = 3;
                          for (var i = 0; i < sorted.length; i += batchSize) {
                            final chunk = sorted.skip(i).take(batchSize);
                            await Future.wait(
                              chunk.map((epIdx) async {
                                if (epIdx < 0 ||
                                    epIdx >= group.episodes.length) {
                                  return;
                                }
                                final ep = group.episodes[epIdx];
                                try {
                                  final r = await widget.appState.api
                                      .resolveVodPlayback(
                                    _activeSource,
                                    playGroup: ep.groupName,
                                    episodeUrl: ep.rawUrl,
                                  );
                                  if (r.directUrl.isNotEmpty) {
                                    await widget.appState.api
                                        .createDownloadTask(
                                      url: r.directUrl,
                                      name: '${detail.vodName} - ${ep.title}',
                                      headers: r.headers,
                                      videoContext: {
                                        'source':
                                            _activeSource.librarySourceKey,
                                        'vod_id': detail.vodId,
                                        'vod_name': detail.vodName,
                                        'episode': ep.title,
                                        'line': ep.groupName,
                                      },
                                    );
                                    successCount++;
                                  }
                                } catch (_) {
                                } finally {
                                  processedCount++;
                                  if (ctx.mounted) {
                                    setDialogState(() {});
                                  }
                                }
                              }),
                            );
                          }
                          await widget.appState.refreshDownloadTasks(
                            silent: true,
                          );
                          if (ctx.mounted) {
                            Navigator.of(ctx).pop();
                          }
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('已成功批量添加 $successCount 个下载任务'),
                              ),
                            );
                          }
                        },
                  icon: const Icon(Icons.download_for_offline_rounded, size: 16),
                  label: Text(
                    isSubmitting
                        ? '正在并发解析 ($processedCount/${selectedIndices.length})...'
                        : '批量加入下载队列 (${selectedIndices.length})',
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showAudioSleepAbDialog() async {
    const sleepOptions = <({int value, String label})>[
      (value: 0, label: '关闭定时'),
      (value: -1, label: '播完本集暂停'),
      (value: 15, label: '15 分钟'),
      (value: 30, label: '30 分钟'),
      (value: 60, label: '60 分钟'),
      (value: 90, label: '90 分钟'),
    ];

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final audioTracks = _player.state.tracks.audio;
            final activeAudio = _player.state.track.audio;
            final curSec = _player.state.position.inMilliseconds / 1000.0;

            return AlertDialog(
              backgroundColor: VideoPlatformTheme.bgElevated,
              title: Row(
                children: [
                  Icon(
                    Icons.tune_rounded,
                    size: 19,
                    color: VideoPlatformTheme.accent,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '多音轨切换 · 睡眠定时 · AB区间循环',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              content: SizedBox(
                width: 500,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 1. Audio Tracks
                      Text(
                        '🎵 音轨 / 配音选择 (${audioTracks.length})',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: VideoPlatformTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (audioTracks.isEmpty)
                        Text(
                          '当前视频流仅包含默认音轨',
                          style: TextStyle(
                            fontSize: 12,
                            color: VideoPlatformTheme.textMuted,
                          ),
                        )
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: audioTracks.map((t) {
                            final selected = activeAudio.id == t.id;
                            final label = (t.title?.isNotEmpty == true)
                                ? t.title!
                                : (t.language?.isNotEmpty == true
                                    ? t.language!
                                    : '音轨 ${t.id}');
                            return ChoiceChip(
                              label: Text(label),
                              selected: selected,
                              selectedColor: VideoPlatformTheme.accent,
                              labelStyle: TextStyle(
                                fontSize: 12,
                                color: selected
                                    ? Colors.white
                                    : VideoPlatformTheme.textPrimary,
                              ),
                              onSelected: (_) async {
                                await _player.setAudioTrack(t);
                                if (mounted) {
                                  setState(
                                    () => _selectedAudioTrackLabel = label,
                                  );
                                }
                                setDialogState(() {});
                              },
                            );
                          }).toList(),
                        ),
                      const Divider(height: 24),
                      // 2. Sleep Timer
                      Text(
                        '🌙 睡眠定时关闭',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: VideoPlatformTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: sleepOptions.map((opt) {
                          final selected = _sleepTimerMinutes == opt.value;
                          return ChoiceChip(
                            label: Text(opt.label),
                            selected: selected,
                            selectedColor: VideoPlatformTheme.accent,
                            labelStyle: TextStyle(
                              fontSize: 12,
                              color: selected
                                  ? Colors.white
                                  : VideoPlatformTheme.textPrimary,
                            ),
                            onSelected: (_) {
                              _setSleepTimer(opt.value);
                              setDialogState(() {});
                            },
                          );
                        }).toList(),
                      ),
                      const Divider(height: 24),
                      // 3. AB Repeat
                      Row(
                        children: [
                          Text(
                            '🔁 AB 区间循环播放',
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: VideoPlatformTheme.textPrimary,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '当前位置: ${_formatDurationLabel(curSec.round())}',
                            style: TextStyle(
                              fontSize: 12,
                              color: VideoPlatformTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () {
                              setState(() => _abPointASeconds = curSec);
                              setDialogState(() {});
                              _showAdToast(
                                '已设 A 点：${_formatDurationLabel(curSec.round())}',
                              );
                            },
                            icon: const Icon(Icons.looks_one_outlined, size: 16),
                            label: Text(
                              _abPointASeconds == null
                                  ? '设当前为起点 A'
                                  : 'A 点: ${_formatDurationLabel(_abPointASeconds!.round())}',
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: () {
                              if (_abPointASeconds != null &&
                                  curSec <= _abPointASeconds! + 1) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('终点 B 必须晚于起点 A'),
                                  ),
                                );
                                return;
                              }
                              setState(() => _abPointBSeconds = curSec);
                              setDialogState(() {});
                              _showAdToast(
                                '已设 B 点：${_formatDurationLabel(curSec.round())}，AB循环已生效',
                              );
                            },
                            icon: const Icon(Icons.looks_two_outlined, size: 16),
                            label: Text(
                              _abPointBSeconds == null
                                  ? '设当前为终点 B'
                                  : 'B 点: ${_formatDurationLabel(_abPointBSeconds!.round())}',
                            ),
                          ),
                          if (_abPointASeconds != null ||
                              _abPointBSeconds != null)
                            TextButton.icon(
                              onPressed: () {
                                setState(() {
                                  _abPointASeconds = null;
                                  _abPointBSeconds = null;
                                });
                                setDialogState(() {});
                                _showAdToast('已清除 AB 区间循环');
                              },
                              icon: const Icon(Icons.clear_rounded, size: 15),
                              label: const Text('清除 AB 循环'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('完成'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _detail?.vodName.isNotEmpty == true
        ? _detail!.vodName
        : (widget.initialTitle.isNotEmpty ? widget.initialTitle : '视频播放');
    final mqSize = MediaQuery.sizeOf(context);
    final isPhoneDevice = (Platform.isAndroid || Platform.isIOS) &&
        !widget.appState.tvMode &&
        mqSize.shortestSide < 600;
    final isPhoneLandscape = isPhoneDevice && mqSize.width > mqSize.height;
    final effectiveFullscreen = _isFullscreenMode || isPhoneLandscape;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _handleBackPress();
        }
      },
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent && _isBackLogicalKey(event.logicalKey)) {
            final route = ModalRoute.of(context);
            if (route != null && route.isCurrent) {
              _handleBackPress();
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.mediaPlayPause): () =>
              _player.playOrPause(),
          const SingleActivator(LogicalKeyboardKey.space): () =>
              _player.playOrPause(),
          const SingleActivator(LogicalKeyboardKey.mediaFastForward): () =>
              _skipForwardSeconds(30),
          const SingleActivator(LogicalKeyboardKey.mediaRewind): () =>
              _rewindSeconds(15),
          const SingleActivator(LogicalKeyboardKey.channelUp): () =>
              _skipForwardSeconds(30),
          const SingleActivator(LogicalKeyboardKey.pageUp): () =>
              _skipForwardSeconds(30),
          const SingleActivator(LogicalKeyboardKey.channelDown): () =>
              _playNextEpisodeIfAvailable(),
          const SingleActivator(LogicalKeyboardKey.pageDown): () =>
              _playNextEpisodeIfAvailable(),
        },
        child: MobileEdgeSwipeBack(
          enabled: !widget.appState.tvMode,
          onBack: _handleBackPress,
          child: Scaffold(
          backgroundColor:
              effectiveFullscreen ? Colors.black : VideoPlatformTheme.bgPrimary,
          appBar: effectiveFullscreen
              ? null
              : AppBar(
                  toolbarHeight: isPhoneDevice ? 44 : 50,
                  titleSpacing: 4,
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15),
                        ),
                      ),
                      if (_currentEpisode != null) ...[
                        const SizedBox(width: 6),
                        Container(
                          constraints: const BoxConstraints(maxWidth: 96),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: VideoPlatformTheme.bgCard,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: VideoPlatformTheme.borderSubtle,
                            ),
                          ),
                          child: Text(
                            _currentEpisode!.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: VideoPlatformTheme.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  actions: [
                    Builder(
                      builder: (ctx) {
                        final w = MediaQuery.sizeOf(ctx).width;
                        final isNarrow = w < 600;
                        final isWide =
                            w >= 860 || (widget.appState.tvMode && w >= 680);
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Center(
                              child: Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Video115AccelerateButton(
                                  api: widget.appState.api,
                                  downloadUrlBuilder:
                                      _resolveCurrent115DownloadUrl,
                                  fallbackUrlsBuilder:
                                      _resolveFallback115DownloadUrls,
                                  videoNameBuilder: _resolveCurrent115VideoName,
                                  headersBuilder: () => _activeStreamHeaders,
                                  player: _player,
                                  selected115Url: _using115Direct
                                      ? _activeStreamUrl
                                      : null,
                                  overlayStyle: false,
                                  compact: isNarrow,
                                  onResolved: _applyResolved115Stream,
                                ),
                              ),
                            ),
                            Center(
                              child: Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: VideoProxyNodeSelector(
                                  proxyService: widget.appState.proxyService,
                                  scenario: RequestScenario.vodStream,
                                  overlayStyle: false,
                                  compact: isNarrow,
                                  onProxyChanged: _onProxyNodeSwitched,
                                ),
                              ),
                            ),
                            Center(
                              child: Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: VideoProxyStatsButton(
                                  proxyService: widget.appState.proxyService,
                                  scenario: RequestScenario.vodStream,
                                  isShowingStats: _showProxyStatsOverlay,
                                  overlayStyle: false,
                                  compact: isNarrow,
                                  onToggle: () {
                                    setState(() {
                                      _showProxyStatsOverlay =
                                          !_showProxyStatsOverlay;
                                    });
                                  },
                                ),
                              ),
                            ),
                            TextButton.icon(
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.symmetric(
                                  horizontal: isNarrow ? 6 : 10,
                                ),
                              ),
                              onPressed: _showCrossSiteSourceSwitchDialog,
                              icon: Icon(
                                Icons.swap_horiz_rounded,
                                size: 16,
                                color: VideoPlatformTheme.accent,
                              ),
                              label: Text(
                                isNarrow
                                    ? '换源'
                                    : '换源 (${_activeSource.name})',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: VideoPlatformTheme.textPrimary,
                                ),
                              ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              tooltip: '小窗悬浮播放（切回首页/Telegram 不中断视频）',
                              onPressed: _activeStreamUrl.isEmpty
                                  ? null
                                  : _enterMiniPlayerMode,
                              icon: const Icon(
                                Icons.picture_in_picture_alt_rounded,
                                size: 18,
                              ),
                            ),
                            if (isWide)
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                tooltip: _isEpisodeSidebarCollapsed
                                    ? '展开右侧选集栏'
                                    : '收起右侧选集栏',
                                onPressed: () => setState(
                                  () => _isEpisodeSidebarCollapsed =
                                      !_isEpisodeSidebarCollapsed,
                                ),
                                icon: Icon(
                                  _isEpisodeSidebarCollapsed
                                      ? Icons.menu_open_rounded
                                      : Icons.view_sidebar_outlined,
                                  size: 19,
                                  color: _isEpisodeSidebarCollapsed
                                      ? VideoPlatformTheme.accent
                                      : VideoPlatformTheme.textSecondary,
                                ),
                              ),
                            const SizedBox(width: 4),
                          ],
                        );
                      },
                    ),
                  ],
                ),
          body: effectiveFullscreen
              ? MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  removeBottom: true,
                  removeLeft: true,
                  removeRight: true,
                  child: Focus(
                    focusNode: _fullscreenStageFocusNode,
                    autofocus: true,
                    onKeyEvent: (node, event) {
                      if (_isBackLogicalKey(event.logicalKey)) {
                        return KeyEventResult.ignored;
                      }
                      if (event is KeyDownEvent || event is KeyRepeatEvent) {
                        final wasHidden = !_fullscreenControlsVisible;
                        _pokeFullscreenControls(focusBar: wasHidden);
                        if (!wasHidden && !node.hasPrimaryFocus) {
                          return KeyEventResult.ignored;
                        }
                        if (wasHidden || node.hasPrimaryFocus) {
                          if (event.logicalKey ==
                              LogicalKeyboardKey.arrowLeft) {
                            _rewindSeconds(15);
                            return KeyEventResult.handled;
                          } else if (event.logicalKey ==
                              LogicalKeyboardKey.arrowRight) {
                            _skipForwardSeconds(15, customReason: '已快进 15s');
                            return KeyEventResult.handled;
                          } else if (event is KeyDownEvent &&
                              (event.logicalKey == LogicalKeyboardKey.select ||
                                  event.logicalKey ==
                                      LogicalKeyboardKey.enter ||
                                  event.logicalKey ==
                                      LogicalKeyboardKey.numpadEnter ||
                                  event.logicalKey ==
                                      LogicalKeyboardKey.gameButtonA)) {
                            _player.playOrPause();
                            return KeyEventResult.handled;
                          } else if (wasHidden &&
                              (event.logicalKey ==
                                      LogicalKeyboardKey.arrowUp ||
                                  event.logicalKey ==
                                      LogicalKeyboardKey.arrowDown)) {
                            return KeyEventResult.handled;
                          }
                        }
                      }
                      return KeyEventResult.ignored;
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: () {
                        if (_fullscreenControlsVisible) {
                          _fullscreenControlsTimer?.cancel();
                          setState(() => _fullscreenControlsVisible = false);
                          _fullscreenStageFocusNode.requestFocus();
                        } else {
                          _pokeFullscreenControls(focusBar: true);
                        }
                      },
                      child: Container(
                        color: Colors.black,
                        width: double.infinity,
                        height: double.infinity,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _buildVideoPlayerStage(
                              fullBleed: true,
                              isFullscreen: true,
                            ),
                            if (_fullscreenControlsVisible)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: FocusTraversalGroup(
                                  child: _buildInteractiveProgressBar(
                                    isFullscreen: true,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    if (widget.appState.tvMode &&
                        constraints.maxWidth >= 680) {
                      return _buildTvLeanbackDetailLayout(constraints);
                    }
                    final isDesktopWide =
                        !isPhoneDevice && constraints.maxWidth >= 860;
                    if (isDesktopWide) {
                      return Stack(
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 7,
                                child: SingleChildScrollView(
                                  padding: const EdgeInsets.fromLTRB(
                                    20,
                                    16,
                                    12,
                                    24,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      _buildVideoPlayerStage(),
                                      const SizedBox(height: 6),
                                      _buildInteractiveProgressBar(),
                                      const SizedBox(height: 10),
                                      _buildPlayerToolbar(),
                                      const SizedBox(height: 16),
                                      _buildMetadataPanel(),
                                    ],
                                  ),
                                ),
                              ),
                              if (!_isEpisodeSidebarCollapsed)
                                FocusTraversalGroup(
                                  child: Container(
                                    width:
                                        constraints.maxWidth < 1050 ? 290 : 340,
                                    height: constraints.maxHeight,
                                    decoration: BoxDecoration(
                                      color: VideoPlatformTheme.bgElevated,
                                      border: Border(
                                        left: BorderSide(
                                          color:
                                              VideoPlatformTheme.borderSubtle,
                                        ),
                                      ),
                                    ),
                                    child: _buildRightSideEpisodePanel(),
                                  ),
                                ),
                            ],
                          ),
                          if (_isEpisodeSidebarCollapsed)
                            Positioned(
                              right: 0,
                              top: 16,
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: const BorderRadius.horizontal(
                                    left: Radius.circular(8),
                                  ),
                                  onFocusChange: (_) {
                                    if (mounted) setState(() {});
                                  },
                                  onTap: () => setState(
                                    () => _isEpisodeSidebarCollapsed = false,
                                  ),
                                  child: Builder(
                                    builder: (ctx) {
                                      final isFocused =
                                          Focus.of(ctx).hasPrimaryFocus;
                                      return Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: isFocused
                                              ? VideoPlatformTheme.accent
                                              : VideoPlatformTheme.bgElevated
                                                  .withValues(alpha: 0.94),
                                          borderRadius:
                                              const BorderRadius.horizontal(
                                            left: Radius.circular(8),
                                          ),
                                          border: Border.all(
                                            color: isFocused
                                                ? Colors.white
                                                : VideoPlatformTheme.accent,
                                            width: isFocused ? 2.2 : 1.2,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.first_page_rounded,
                                              size: 16,
                                              color: isFocused
                                                  ? Colors.white
                                                  : VideoPlatformTheme.accent,
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              '展开选集',
                                              style: TextStyle(
                                                fontSize: 12,
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
                                ),
                              ),
                            ),
                        ],
                      );
                    }

                    // Mobile / Tablet stacked layout (NetEase Filmly Cinema Style)
                    return Column(
                      children: [
                        _buildVideoPlayerStage(fullBleed: true),
                        _buildMobileCompactTransportBar(),
                        Expanded(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildMobileQuickActionBar(),
                                const SizedBox(height: 12),
                                _buildInlineEpisodeSection(),
                                const SizedBox(height: 12),
                                _buildMetadataPanel(),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
        ),
      ),
      ),
    );
  }

  Widget _buildTvLeanbackDetailLayout(BoxConstraints constraints) {
    final detail = _detail;
    final title = detail?.vodName.isNotEmpty == true
        ? detail!.vodName
        : widget.initialTitle;
    final isFav = detail != null &&
        widget.appState.isFavorite(_activeSource, detail.vodId);
    final hasMultipleEps = detail != null &&
        detail.playGroups.any((g) => g.episodes.length > 1);
    final tags = <String>[
      '片源: ${_activeSource.name}',
      if (detail != null && detail.typeName.isNotEmpty) detail.typeName,
      if (detail != null &&
          detail.vodYear.isNotEmpty &&
          detail.vodYear != '0')
        detail.vodYear,
      if (detail != null && detail.vodArea.isNotEmpty) detail.vodArea,
      if (detail != null && detail.vodRemarks.isNotEmpty) detail.vodRemarks,
    ];
    final currentGroup =
        (detail != null && detail.playGroups.isNotEmpty)
            ? detail.playGroups[
                _selectedGroupIndex.clamp(0, detail.playGroups.length - 1)]
            : null;
    final displayEpisodes = currentGroup != null
        ? _getFilteredAndSortedEpisodes(currentGroup.episodes)
        : const <Episode>[];

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Top Hero Row: 16:9 Live Preview Player (left) + TV Metadata & Big D-Pad Action Bar (right)
          SizedBox(
            height: (constraints.maxHeight * 0.42).clamp(256.0, 400.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 16:9 Preview Player Box
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: _buildVideoPlayerStage(),
                ),
                const SizedBox(width: 22),
                // Right: Movie Title, Tags, Synopsis, and Big TV Action Buttons
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                color: VideoPlatformTheme.textPrimary,
                              ),
                            ),
                          ),
                          if (_currentEpisode != null) ...[
                            const SizedBox(width: 10),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: VideoPlatformTheme.accent
                                    .withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: VideoPlatformTheme.accent,
                                ),
                              ),
                              child: Text(
                                '正在播放: ${_currentEpisode!.title}',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: VideoPlatformTheme.accent,
                                ),
                              ),
                            ),
                          ],
                          const Spacer(),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: tags
                            .map(
                              (t) => Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: VideoPlatformTheme.bgCard,
                                  borderRadius: BorderRadius.circular(5),
                                  border: Border.all(
                                    color: VideoPlatformTheme.borderSubtle,
                                  ),
                                ),
                                child: Text(
                                  t,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: VideoPlatformTheme.textSecondary,
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: Text(
                          (detail != null && detail.vodContent.isNotEmpty)
                              ? detail.vodContent
                                  .replaceAll(RegExp(r'<[^>]*>'), '')
                                  .trim()
                              : (detail?.vodActor.isNotEmpty == true
                                  ? '主演：${detail!.vodActor}'
                                  : '按“全屏观看”即可进入沉浸全屏，全屏下按遥控器左右键快进/快退，上下键唤出控制栏，返回键退出全屏。'),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.45,
                            color: VideoPlatformTheme.textSecondary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      // Big TV Remote Action Bar
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _buildTvFocusableControlBtn(
                              icon: Icons.fullscreen_rounded,
                              label: '全屏观看',
                              tooltip: '进入 100% 沉浸全屏播放',
                              isPrimary: true,
                              autofocus: true,
                              onPressed: () =>
                                  _toggleFullscreenMode(forceValue: true),
                            ),
                            if (hasMultipleEps) ...[
                              const SizedBox(width: 10),
                              _buildTvFocusableControlBtn(
                                icon: Icons.skip_next_rounded,
                                label: '下一集',
                                onPressed: _playNextEpisodeIfAvailable,
                              ),
                            ],
                            const SizedBox(width: 10),
                            _buildTvFocusableControlBtn(
                              icon: Icons.swap_horiz_rounded,
                              label: '同片换源',
                              onPressed: _showCrossSiteSourceSwitchDialog,
                            ),
                            const SizedBox(width: 10),
                            _buildTvFocusableControlBtn(
                              icon: Icons.fast_forward_rounded,
                              label: '跳广告+30s',
                              onPressed: () => _skipForwardSeconds(30),
                            ),
                            const SizedBox(width: 10),
                            _buildTvFocusableControlBtn(
                              icon: Icons.verified_user_rounded,
                              label: widget.appState.vodSkipIntroSeconds > 0
                                  ? '片头${widget.appState.vodSkipIntroSeconds}s/去广告'
                                  : '片头/去广告',
                              onPressed: _showAdSkipSettingsDialog,
                            ),
                            const SizedBox(width: 10),
                            _buildTvFocusableControlBtn(
                              icon: isFav
                                  ? Icons.star_rounded
                                  : Icons.star_border_rounded,
                              label: isFav ? '已收藏' : '收藏',
                              onPressed: detail == null
                                  ? null
                                  : () async {
                                      await widget.appState.toggleFavorite(
                                        source: _activeSource,
                                        detail: detail,
                                        currentEpisode:
                                            _currentEpisode?.title ?? '',
                                        currentLine:
                                            _currentEpisode?.groupName ?? '',
                                      );
                                      if (mounted) setState(() {});
                                    },
                            ),
                            const SizedBox(width: 10),
                            Video115AccelerateButton(
                              api: widget.appState.api,
                              downloadUrlBuilder: _resolveCurrent115DownloadUrl,
                              fallbackUrlsBuilder:
                                  _resolveFallback115DownloadUrls,
                              videoNameBuilder: _resolveCurrent115VideoName,
                              headersBuilder: () => _activeStreamHeaders,
                              player: _player,
                              selected115Url: _using115Direct
                                  ? _activeStreamUrl
                                  : null,
                              overlayStyle: false,
                              compact: false,
                              onResolved: _applyResolved115Stream,
                            ),
                            const SizedBox(width: 10),
                            VideoProxyNodeSelector(
                              proxyService: widget.appState.proxyService,
                              scenario: RequestScenario.vodStream,
                              overlayStyle: false,
                              compact: false,
                              onProxyChanged: _onProxyNodeSwitched,
                            ),
                            const SizedBox(width: 8),
                            VideoProxyStatsButton(
                              proxyService: widget.appState.proxyService,
                              scenario: RequestScenario.vodStream,
                              isShowingStats: _showProxyStatsOverlay,
                              overlayStyle: false,
                              compact: false,
                              onToggle: () {
                                setState(() {
                                  _showProxyStatsOverlay =
                                      !_showProxyStatsOverlay;
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // 2. Play Line Bar + Episode Chunk Controls
          if (detail != null && detail.playGroups.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: VideoPlatformTheme.bgElevated,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(10)),
                border: Border.all(color: VideoPlatformTheme.borderSubtle),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.playlist_play_rounded,
                        size: 20,
                        color: VideoPlatformTheme.accent,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '播放线路与选集',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: VideoPlatformTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: SizedBox(
                          height: 36,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: detail.playGroups.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 8),
                            itemBuilder: (_, idx) {
                              final grp = detail.playGroups[idx];
                              final selected = idx == _selectedGroupIndex;
                              return InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onFocusChange: (_) {
                                  if (mounted) setState(() {});
                                },
                                onTap: () => setState(() {
                                  _selectedGroupIndex = idx;
                                  _episodeChunkIndex = -1;
                                }),
                                child: Builder(
                                  builder: (ctx) {
                                    final isFocused =
                                        Focus.of(ctx).hasPrimaryFocus;
                                    return Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                      ),
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: isFocused
                                            ? VideoPlatformTheme.accent
                                            : (selected
                                                ? VideoPlatformTheme.accent
                                                    .withValues(alpha: 0.22)
                                                : VideoPlatformTheme.bgCard),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: isFocused
                                              ? Colors.white
                                              : (selected
                                                  ? VideoPlatformTheme.accent
                                                  : VideoPlatformTheme
                                                      .borderSubtle),
                                          width: isFocused ? 2.2 : 1.0,
                                        ),
                                      ),
                                      child: Text(
                                        '${grp.name} (${grp.episodes.length})',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: (selected || isFocused)
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                          color: isFocused
                                              ? Colors.white
                                              : (selected
                                                  ? VideoPlatformTheme.accent
                                                  : VideoPlatformTheme
                                                      .textPrimary),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _buildTvFocusableControlBtn(
                        icon: Icons.swap_vert_rounded,
                        label: _episodesReversed ? '倒序' : '正序',
                        onPressed: () => setState(
                          () => _episodesReversed = !_episodesReversed,
                        ),
                      ),
                    ],
                  ),
                  if (currentGroup != null &&
                      currentGroup.episodes.length > 50)
                    _buildEpisodeChunkAndSearchControls(
                      currentGroup.episodes.length,
                    ),
                ],
              ),
            ),
            // 3. Full-Width Large TV Episode Grid
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: VideoPlatformTheme.bgElevated,
                  borderRadius:
                      const BorderRadius.vertical(bottom: Radius.circular(10)),
                  border: Border(
                    left: BorderSide(color: VideoPlatformTheme.borderSubtle),
                    right: BorderSide(color: VideoPlatformTheme.borderSubtle),
                    bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
                  ),
                ),
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 150,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 2.75,
                  ),
                  itemCount: displayEpisodes.length,
                  itemBuilder: (_, idx) {
                    final ep = displayEpisodes[idx];
                    final isPlaying =
                        _currentEpisode?.groupName == ep.groupName &&
                            _currentEpisode?.index == ep.index;
                    return _buildEpisodeButton(ep, isPlaying);
                  },
                ),
              ),
            ),
          ] else
            Expanded(
              child: Center(
                child: Text(
                  _isLoadingDetail ? '正在加载剧集列表...' : '暂无可用播放线路',
                  style: TextStyle(
                    fontSize: 14,
                    color: VideoPlatformTheme.textMuted,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showFullscreenEpisodePickerDialog() async {
    final detail = _detail;
    if (detail == null || detail.playGroups.isEmpty) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final currentGroup = detail.playGroups[_selectedGroupIndex];
            final displayEpisodes =
                _getFilteredAndSortedEpisodes(currentGroup.episodes);
            return Dialog(
              backgroundColor: VideoPlatformTheme.bgElevated,
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: 760, maxHeight: 520),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.playlist_play_rounded,
                            size: 20,
                            color: VideoPlatformTheme.accent,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '选集与播放线路 · ${detail.vodName}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: VideoPlatformTheme.textPrimary,
                              ),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: () {
                              setState(
                                () => _episodesReversed = !_episodesReversed,
                              );
                              setDialogState(() {});
                            },
                            icon: Icon(
                              Icons.swap_vert_rounded,
                              size: 16,
                              color: _episodesReversed
                                  ? VideoPlatformTheme.accent
                                  : VideoPlatformTheme.textSecondary,
                            ),
                            label: Text(_episodesReversed ? '倒序' : '正序'),
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            icon: const Icon(Icons.close_rounded, size: 18),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 36,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: detail.playGroups.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (_, idx) {
                            final grp = detail.playGroups[idx];
                            final selected = idx == _selectedGroupIndex;
                            return InkWell(
                              borderRadius: BorderRadius.circular(6),
                              onFocusChange: (_) => setDialogState(() {}),
                              onTap: () {
                                setState(() {
                                  _selectedGroupIndex = idx;
                                  _episodeChunkIndex = -1;
                                });
                                setDialogState(() {});
                              },
                              child: Builder(
                                builder: (itemCtx) {
                                  final isFocused =
                                      Focus.of(itemCtx).hasPrimaryFocus;
                                  return Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: selected
                                          ? VideoPlatformTheme.accent
                                          : (isFocused
                                              ? VideoPlatformTheme.accent
                                                  .withValues(alpha: 0.25)
                                              : VideoPlatformTheme.bgCard),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: (selected || isFocused)
                                            ? VideoPlatformTheme.accent
                                            : VideoPlatformTheme.borderSubtle,
                                        width: isFocused ? 2.0 : 1.0,
                                      ),
                                    ),
                                    child: Text(
                                      '${grp.name} (${grp.episodes.length})',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: selected
                                            ? Colors.white
                                            : (isFocused
                                                ? VideoPlatformTheme.accent
                                                : VideoPlatformTheme
                                                    .textSecondary),
                                        fontWeight: (selected || isFocused)
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Divider(height: 1),
                      const SizedBox(height: 10),
                      Expanded(
                        child: GridView.builder(
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 120,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                            childAspectRatio: 2.6,
                          ),
                          itemCount: displayEpisodes.length,
                          itemBuilder: (_, idx) {
                            final ep = displayEpisodes[idx];
                            final isPlaying =
                                _currentEpisode?.groupName == ep.groupName &&
                                    _currentEpisode?.index == ep.index;
                            return InkWell(
                              autofocus: isPlaying,
                              borderRadius: BorderRadius.circular(6),
                              onFocusChange: (_) => setDialogState(() {}),
                              onTap: () {
                                Navigator.of(ctx).pop();
                                _selectAndPlayEpisode(ep);
                              },
                              child: Builder(
                                builder: (epCtx) {
                                  final isFocused =
                                      Focus.of(epCtx).hasPrimaryFocus;
                                  if (isFocused) {
                                    WidgetsBinding.instance
                                        .addPostFrameCallback((_) {
                                      if (epCtx.mounted) {
                                        Scrollable.ensureVisible(
                                          epCtx,
                                          alignment: 0.5,
                                          duration: const Duration(
                                            milliseconds: 140,
                                          ),
                                        );
                                      }
                                    });
                                  }
                                  return Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: isFocused
                                          ? VideoPlatformTheme.accent
                                              .withValues(alpha: 0.28)
                                          : (isPlaying
                                              ? VideoPlatformTheme.accent
                                                  .withValues(alpha: 0.16)
                                              : VideoPlatformTheme.bgCard),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: (isFocused || isPlaying)
                                            ? VideoPlatformTheme.accent
                                            : VideoPlatformTheme.borderSubtle,
                                        width: isFocused ? 2.0 : 1.0,
                                      ),
                                    ),
                                    child: Text(
                                      ep.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: (isPlaying || isFocused)
                                            ? VideoPlatformTheme.accent
                                            : VideoPlatformTheme.textPrimary,
                                        fontWeight: (isPlaying || isFocused)
                                            ? FontWeight.w700
                                            : FontWeight.w400,
                                      ),
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
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildTvFocusableControlBtn({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    String? tooltip,
    bool isPrimary = false,
    bool showLabel = true,
    bool autofocus = false,
    FocusNode? focusNode,
  }) {
    return Focus(
      focusNode: focusNode,
      autofocus: autofocus,
      canRequestFocus: onPressed != null,
      onFocusChange: (focused) {
        if (focused && _isFullscreenMode) {
          _pokeFullscreenControls();
        }
        if (mounted) setState(() {});
      },
      onKeyEvent: (node, event) {
        if (onPressed == null || _isBackLogicalKey(event.logicalKey)) {
          return KeyEventResult.ignored;
        }
        if (event is KeyDownEvent) {
          if (_isFullscreenMode) _pokeFullscreenControls();
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter ||
              event.logicalKey == LogicalKeyboardKey.space ||
              event.logicalKey == LogicalKeyboardKey.gameButtonA) {
            onPressed();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final hasFocus = Focus.of(ctx).hasPrimaryFocus;
          return Tooltip(
            message: tooltip ?? label,
            child: InkWell(
              canRequestFocus: false,
              borderRadius: BorderRadius.circular(6),
              onTap: onPressed,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: showLabel ? 10 : 8,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: hasFocus
                      ? VideoPlatformTheme.accent
                      : (isPrimary
                          ? VideoPlatformTheme.accent.withValues(alpha: 0.16)
                          : VideoPlatformTheme.bgCard),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: hasFocus
                        ? Colors.white
                        : (isPrimary
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.borderSubtle),
                    width: hasFocus ? 2.0 : 1.0,
                  ),
                  boxShadow: hasFocus
                      ? [
                          BoxShadow(
                            color: VideoPlatformTheme.accent
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
                      icon,
                      size: 18,
                      color: hasFocus
                          ? Colors.white
                          : (isPrimary
                              ? VideoPlatformTheme.accent
                              : VideoPlatformTheme.textPrimary),
                    ),
                    if (showLabel) ...[
                      const SizedBox(width: 5),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight:
                              hasFocus || isPrimary ? FontWeight.w700 : FontWeight.w500,
                          color: hasFocus
                              ? Colors.white
                              : (isPrimary
                                  ? VideoPlatformTheme.accent
                                  : VideoPlatformTheme.textPrimary),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildInteractiveProgressBar({
    bool fullBleed = false,
    bool isFullscreen = false,
  }) {
    return StreamBuilder<Duration>(
      stream: _player.stream.position,
      initialData: _player.state.position,
      builder: (context, posSnap) {
        return StreamBuilder<Duration>(
          stream: _player.stream.duration,
          initialData: _player.state.duration,
          builder: (context, durSnap) {
            final rawPos = posSnap.data ?? _lastValidPosition;
            final rawDur = (durSnap.data != null && durSnap.data! > Duration.zero)
                ? durSnap.data!
                : _lastValidDuration;
            final maxSec =
                rawDur.inSeconds > 0 ? rawDur.inSeconds.toDouble() : 1.0;
            final curSec = _isSliderDragging
                ? _sliderPreviewSeconds.clamp(0.0, maxSec)
                : (_isHorizontalSeeking
                    ? _seekPreviewSeconds.clamp(0.0, maxSec)
                    : rawPos.inSeconds.toDouble().clamp(0.0, maxSec));

            return Container(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              decoration: BoxDecoration(
                color: isFullscreen
                    ? const Color(0xEE090E14)
                    : VideoPlatformTheme.bgElevated,
                borderRadius: (fullBleed || isFullscreen)
                    ? BorderRadius.zero
                    : BorderRadius.circular(6),
                border: Border.all(
                  color: VideoPlatformTheme.borderSubtle,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Row 1: Dedicated Progress Scrubber Bar (own Focus node ONLY for slider seeking)
                  Focus(
                    onFocusChange: (focused) {
                      if (focused && _isFullscreenMode) {
                        _pokeFullscreenControls();
                      }
                      if (mounted) setState(() {});
                    },
                    onKeyEvent: (node, event) {
                      if (_isBackLogicalKey(event.logicalKey)) {
                        return KeyEventResult.ignored;
                      }
                      if (event is KeyDownEvent || event is KeyRepeatEvent) {
                        if (_isFullscreenMode) _pokeFullscreenControls();
                        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                          _rewindSeconds(15);
                          return KeyEventResult.handled;
                        } else if (event.logicalKey ==
                            LogicalKeyboardKey.arrowRight) {
                          _skipForwardSeconds(15, customReason: '已快进 15s');
                          return KeyEventResult.handled;
                        } else if (event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.arrowUp) {
                          final moved =
                              node.focusInDirection(TraversalDirection.up);
                          if (!moved || node.hasPrimaryFocus) {
                            if (isFullscreen) {
                              if (_fullscreenPlayBtnFocusNode.canRequestFocus) {
                                _fullscreenPlayBtnFocusNode.requestFocus();
                              }
                            } else if (_windowedStageFocusNode
                                .canRequestFocus) {
                              _windowedStageFocusNode.requestFocus();
                            } else {
                              node.previousFocus();
                            }
                          }
                          return KeyEventResult.handled;
                        } else if (event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.arrowDown) {
                          final targetBtn = isFullscreen
                              ? _fullscreenPlayBtnFocusNode
                              : _windowedPlayBtnFocusNode;
                          final moved =
                              node.focusInDirection(TraversalDirection.down);
                          if (!moved || node.hasPrimaryFocus) {
                            if (targetBtn.canRequestFocus) {
                              targetBtn.requestFocus();
                            } else {
                              node.nextFocus();
                            }
                          }
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
                                ? VideoPlatformTheme.accent
                                    .withValues(alpha: 0.12)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: hasBarFocus
                                  ? VideoPlatformTheme.accent
                                  : Colors.transparent,
                              width: hasBarFocus ? 1.8 : 1.0,
                            ),
                          ),
                          child: Row(
                            children: [
                              Text(
                                _formatDurationLabel(curSec.round()),
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: hasBarFocus
                                      ? VideoPlatformTheme.accent
                                      : VideoPlatformTheme.textPrimary,
                                ),
                              ),
                              Expanded(
                                child: ExcludeFocus(
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: hasBarFocus ? 5.5 : 4.0,
                                      thumbShape: RoundSliderThumbShape(
                                        enabledThumbRadius:
                                            hasBarFocus ? 9.0 : 7.5,
                                      ),
                                      overlayShape:
                                          const RoundSliderOverlayShape(
                                        overlayRadius: 15.0,
                                      ),
                                      activeTrackColor:
                                          VideoPlatformTheme.accent,
                                      inactiveTrackColor:
                                          VideoPlatformTheme.borderStrong,
                                      thumbColor: Colors.white,
                                    ),
                                    child: Slider(
                                      value: curSec,
                                      min: 0.0,
                                      max: maxSec,
                                      onChangeStart: (val) {
                                        setState(() {
                                          _isSliderDragging = true;
                                          _sliderPreviewSeconds = val;
                                        });
                                      },
                                      onChanged: (val) {
                                        setState(() {
                                          _isSliderDragging = true;
                                          _sliderPreviewSeconds = val;
                                        });
                                      },
                                      onChangeEnd: (val) {
                                        setState(() {
                                          _isSliderDragging = false;
                                          _sliderPreviewSeconds = val;
                                        });
                                        _player.seek(
                                          Duration(seconds: val.round()),
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              ),
                              Text(
                                _formatDurationLabel(
                                  rawDur.inSeconds > 0 ? rawDur.inSeconds : 0,
                                ),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: VideoPlatformTheme.textSecondary,
                                ),
                              ),
                              const SizedBox(width: 8),
                              PlayerVolumeControl(
                                player: _player,
                                compact: true,
                                overlayStyle: isFullscreen,
                                sliderWidth:
                                    MediaQuery.sizeOf(context).width < 720
                                        ? 52
                                        : 76,
                                onVolumeChanged: (val) {
                                  if (mounted) {
                                    setState(() => _volumePercent = val);
                                  }
                                },
                              ),
                              if (hasBarFocus) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: VideoPlatformTheme.accent,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    '◀▶ 左右键调进度 · ▼ 下键选全屏/按钮',
                                    style: TextStyle(
                                      fontSize: 10.5,
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
                  ),
                  const SizedBox(height: 6),
                  // Row 2: Dedicated Playback & Fullscreen Control Buttons (horizontally scrollable on mobile, pinned Fullscreen on right)
                  Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              StreamBuilder<bool>(
                                stream: _player.stream.playing,
                                initialData: _player.state.playing,
                                builder: (_, playSnap) {
                                  final playing = playSnap.data ?? false;
                                  return _buildTvFocusableControlBtn(
                                    focusNode: isFullscreen
                                        ? _fullscreenPlayBtnFocusNode
                                        : _windowedPlayBtnFocusNode,
                                    icon: playing
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                    label: playing ? '暂停' : '播放',
                                    tooltip: playing ? '暂停' : '播放',
                                    onPressed: () => _player.playOrPause(),
                                  );
                                },
                              ),
                              const SizedBox(width: 8),
                              _buildTvFocusableControlBtn(
                                icon: Icons.replay_10_rounded,
                                label: '快退15s',
                                tooltip: '快退 15 秒',
                                onPressed: () => _rewindSeconds(15),
                              ),
                              const SizedBox(width: 8),
                              _buildTvFocusableControlBtn(
                                icon: Icons.forward_10_rounded,
                                label: '快进15s',
                                tooltip: '快进 15 秒',
                                onPressed: () => _skipForwardSeconds(
                                  15,
                                  customReason: '已快进 15s',
                                ),
                              ),
                              const SizedBox(width: 8),
                              _buildTvFocusableControlBtn(
                                icon: Icons.skip_next_rounded,
                                label: '跳广告+30s',
                                tooltip: '快进跳过 30 秒广告',
                                onPressed: () => _skipForwardSeconds(30),
                              ),
                              if (_detail != null &&
                                  _detail!.playGroups.any(
                                    (g) => g.episodes.length > 1,
                                  )) ...[
                                const SizedBox(width: 8),
                                _buildTvFocusableControlBtn(
                                  icon: Icons.skip_next_outlined,
                                  label: '下一集',
                                  tooltip: '播放下一集',
                                  onPressed: _playNextEpisodeIfAvailable,
                                ),
                              ],
                              if (_detail != null &&
                                  _detail!.playGroups.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                _buildTvFocusableControlBtn(
                                  icon: Icons.playlist_play_rounded,
                                  label: '选集/线路',
                                  tooltip: '弹窗选择剧集或切换播放线路',
                                  onPressed: _showFullscreenEpisodePickerDialog,
                                ),
                              ],
                              if (isFullscreen) ...[
                                const SizedBox(width: 8),
                                _buildTvFocusableControlBtn(
                                  icon: Icons.swap_horiz_rounded,
                                  label: '换源',
                                  tooltip: '跨站点智能切换同名片源',
                                  onPressed: _showCrossSiteSourceSwitchDialog,
                                ),
                              ],
                              const SizedBox(width: 8),
                              _buildTvFocusableControlBtn(
                                icon: _videoAspectMode == 'cover'
                                    ? Icons.crop_free_rounded
                                    : Icons.aspect_ratio_rounded,
                                label: _videoAspectMode == 'fit'
                                    ? '比例:适应'
                                    : (_videoAspectMode == 'cover'
                                        ? '比例:铺满'
                                        : '比例:$_videoAspectMode'),
                                tooltip: '切换画面比例 (适应/铺满去黑边/16:9/4:3)',
                                isPrimary: _videoAspectMode != 'fit',
                                onPressed: _cycleVideoAspectMode,
                              ),
                              if ((Platform.isAndroid || Platform.isIOS) &&
                                  !widget.appState.tvMode) ...[
                                const SizedBox(width: 8),
                                _buildTvFocusableControlBtn(
                                  icon: Icons.screen_rotation_rounded,
                                  label: '横竖屏',
                                  tooltip: '手动切换横屏全屏 / 竖屏全屏',
                                  onPressed: _toggleFullscreenOrientation,
                                ),
                              ],
                              const SizedBox(width: 8),
                              Video115AccelerateButton(
                                api: widget.appState.api,
                                downloadUrlBuilder:
                                    _resolveCurrent115DownloadUrl,
                                fallbackUrlsBuilder:
                                    _resolveFallback115DownloadUrls,
                                videoNameBuilder: _resolveCurrent115VideoName,
                                headersBuilder: () => _activeStreamHeaders,
                                player: _player,
                                selected115Url: _using115Direct
                                    ? _activeStreamUrl
                                    : null,
                                overlayStyle: isFullscreen,
                                compact: true,
                                onResolved: _applyResolved115Stream,
                              ),
                              const SizedBox(width: 8),
                              VideoProxyNodeSelector(
                                proxyService: widget.appState.proxyService,
                                scenario: RequestScenario.vodStream,
                                overlayStyle: isFullscreen,
                                compact: true,
                                onProxyChanged: _onProxyNodeSwitched,
                              ),
                              const SizedBox(width: 8),
                              VideoProxyStatsButton(
                                proxyService: widget.appState.proxyService,
                                scenario: RequestScenario.vodStream,
                                isShowingStats: _showProxyStatsOverlay,
                                overlayStyle: isFullscreen,
                                compact: true,
                                onToggle: () {
                                  setState(() {
                                    _showProxyStatsOverlay =
                                        !_showProxyStatsOverlay;
                                  });
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _buildTvFocusableControlBtn(
                        icon: isFullscreen
                            ? Icons.fullscreen_exit_rounded
                            : Icons.fullscreen_rounded,
                        label: isFullscreen ? '退出全屏' : '全屏放大',
                        tooltip: isFullscreen
                            ? '退出全屏 (按返回键或左边缘右滑也可退出)'
                            : '全屏放大播放',
                        isPrimary: true,
                        autofocus:
                            widget.appState.tvMode && !isFullscreen,
                        onPressed: () {
                          if (isFullscreen && !_isFullscreenMode) {
                            _handleBackPress();
                          } else {
                            _toggleFullscreenMode();
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildVideoPlayerStage({
    bool fullBleed = false,
    bool isFullscreen = false,
  }) {
    final BoxFit videoFit =
        _videoAspectMode == 'cover' ? BoxFit.cover : BoxFit.contain;
    final double? customAspectRatio = _videoAspectMode == '16:9'
        ? 16 / 9
        : (_videoAspectMode == '4:3' ? 4 / 3 : null);

    final screenSize = MediaQuery.sizeOf(context);
    final isMobilePortrait =
        screenSize.height >= screenSize.width &&
        (screenSize.width < 680 ||
            (screenSize.width < 860 && !widget.appState.tvMode));
    // Larger video window on mobile portrait:
    // - For portrait/vertical videos (9:16), expand up to 52% of screen height.
    // - For standard/landscape videos, use at least 35% of screen height (or 16:9 width), up to 420px.
    final double base16x9Height =
        (screenSize.width * 9 / 16).clamp(235.0, 380.0);
    final double mobileStageHeight = _isPortraitVideo
        ? (screenSize.height * 0.52).clamp(320.0, 540.0)
        : math.max(base16x9Height, screenSize.height * 0.35).clamp(256.0, 420.0);

    final Widget stageContent = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        _stageTouchPointers[e.pointer] = e.position;
        if (_stageTouchPointers.length == 2) {
          final pts = _stageTouchPointers.values.toList();
          _initialPinchDistance = (pts[0] - pts[1]).distance;
        }
      },
      onPointerMove: (e) {
        if (!_stageTouchPointers.containsKey(e.pointer)) return;
        _stageTouchPointers[e.pointer] = e.position;
        if (_stageTouchPointers.length == 2 && _initialPinchDistance != null) {
          final pts = _stageTouchPointers.values.toList();
          final dist = (pts[0] - pts[1]).distance;
          if (_initialPinchDistance! > 16) {
            final ratio = dist / _initialPinchDistance!;
            if (ratio > 1.24 && _videoAspectMode != 'cover') {
              _initialPinchDistance = dist;
              setState(() => _videoAspectMode = 'cover');
              _showAdToast('已双指放大为：铺满裁剪 (捏合恢复适应屏幕)');
            } else if (ratio < 0.78 && _videoAspectMode != 'fit') {
              _initialPinchDistance = dist;
              setState(() => _videoAspectMode = 'fit');
              _showAdToast('已恢复为：适应屏幕');
            }
          }
        }
      },
      onPointerUp: (e) {
        _stageTouchPointers.remove(e.pointer);
        if (_stageTouchPointers.length < 2) {
          _initialPinchDistance = null;
        }
      },
      onPointerCancel: (e) {
        _stageTouchPointers.remove(e.pointer);
        if (_stageTouchPointers.length < 2) {
          _initialPinchDistance = null;
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: isFullscreen
            ? null
            : () {
                if (isMobilePortrait) {
                  _toggleMobileStageOsd();
                } else if (!widget.appState.tvMode &&
                    _currentEpisode != null &&
                    !_isResolvingPlay) {
                  _player.playOrPause();
                }
              },
        onDoubleTap: () => _player.playOrPause(),
        onVerticalDragStart: (details) {
          if (details.globalPosition.dx <= 40.0) return;
          if (_currentEpisode == null || _isResolvingPlay) return;
          setState(() => _isVerticalVolumeDragging = true);
        },
        onVerticalDragUpdate: (details) {
          if (!_isVerticalVolumeDragging) return;
          final stageH = isFullscreen
              ? screenSize.height.clamp(240.0, 1200.0)
              : mobileStageHeight;
          final deltaVol = (-details.delta.dy / stageH) * 120.0;
          final nextVol = (_volumePercent + deltaVol).clamp(0.0, 100.0);
          setState(() => _volumePercent = nextVol);
          _player.setVolume(nextVol);
        },
        onVerticalDragEnd: (_) {
          if (!_isVerticalVolumeDragging) return;
          setState(() => _isVerticalVolumeDragging = false);
        },
        onHorizontalDragStart: (details) {
          // Reserve left-edge swipe (dx <= 40) for mobile swipe-back gesture!
          if (details.globalPosition.dx <= 40.0) return;
          if (_currentEpisode == null || _isResolvingPlay) return;
          final curSec = _player.state.position.inSeconds > 0
              ? _player.state.position.inSeconds.toDouble()
              : _lastValidPosition.inSeconds.toDouble();
          setState(() {
            _isHorizontalSeeking = true;
            _seekStartSeconds = curSec;
            _seekPreviewSeconds = curSec;
          });
        },
        onHorizontalDragUpdate: (details) {
          if (!_isHorizontalSeeking) return;
          final width = screenSize.width.clamp(260.0, 1920.0);
          final rawDurSec = _player.state.duration.inSeconds > 0
              ? _player.state.duration.inSeconds.toDouble()
              : (_lastValidDuration.inSeconds > 0
                  ? _lastValidDuration.inSeconds.toDouble()
                  : 3600.0);
          final spanSec = rawDurSec.clamp(90.0, 300.0);
          final deltaSec = (details.delta.dx / width) * spanSec;
          final nextSec =
              (_seekPreviewSeconds + deltaSec).clamp(0.0, rawDurSec);
          setState(() {
            _seekPreviewSeconds = nextSec;
          });
        },
        onHorizontalDragEnd: (_) {
          if (!_isHorizontalSeeking) return;
          final targetSec = _seekPreviewSeconds.round();
          setState(() {
            _isHorizontalSeeking = false;
          });
          _player.seek(Duration(seconds: targetSec));
        },
        onLongPressStart: (_) {
          if (_currentEpisode == null || _isResolvingPlay) return;
          setState(() => _isLongPressFastForward = true);
          _player.setRate(3.0);
        },
        onLongPressEnd: (_) {
          if (!_isLongPressFastForward) return;
          setState(() => _isLongPressFastForward = false);
          _player.setRate(_playbackSpeed);
        },
        onLongPressCancel: () {
          if (!_isLongPressFastForward) return;
          setState(() => _isLongPressFastForward = false);
          _player.setRate(_playbackSpeed);
        },
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius:
                fullBleed ? BorderRadius.zero : BorderRadius.circular(6),
            border: fullBleed
                ? null
                : Border.all(color: VideoPlatformTheme.borderSubtle),
          ),
          clipBehavior: Clip.antiAlias,
          child: LayoutBuilder(
            builder: (context, stageConstraints) {
              final effectiveAspectRatio = customAspectRatio ??
                  (_videoWidth > 0 && _videoHeight > 0
                      ? _videoWidth / _videoHeight
                      : null);
              return Stack(
                fit: StackFit.expand,
                children: [
                  Video(
                    key: _videoPlayerWidgetKey,
                    controller: _videoController,
                    width: stageConstraints.maxWidth,
                    height: stageConstraints.maxHeight,
                    fill: Colors.black,
                    fit: videoFit,
                    aspectRatio: effectiveAspectRatio,
                    controls: NoVideoControls,
                    pauseUponEnteringBackgroundMode: false,
                    resumeUponEnteringForegroundMode: true,
                  ),
              if (_isHorizontalSeeking)
                Center(
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xE0090E14),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: VideoPlatformTheme.accent,
                          width: 1.4,
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${_seekPreviewSeconds >= _seekStartSeconds ? '⏩ 快进' : '⏪ 快退'}  ${_formatDurationLabel(_seekPreviewSeconds.round())} / ${_formatDurationLabel((_player.state.duration.inSeconds > 0 ? _player.state.duration.inSeconds : _lastValidDuration.inSeconds))}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${(_seekPreviewSeconds - _seekStartSeconds) >= 0 ? '+' : ''}${(_seekPreviewSeconds - _seekStartSeconds).round()} 秒 (左右滑动调节进度)',
                            style: TextStyle(
                              color: VideoPlatformTheme.accent,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (_isVerticalVolumeDragging && !_isHorizontalSeeking)
                Center(
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xE0090E14),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: VideoPlatformTheme.accent,
                          width: 1.4,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _volumePercent <= 0
                                ? Icons.volume_off_rounded
                                : (_volumePercent < 50
                                    ? Icons.volume_down_rounded
                                    : Icons.volume_up_rounded),
                            color: VideoPlatformTheme.accent,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '音量 ${_volumePercent.round()}%',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (!_isHorizontalSeeking &&
                  !_isVerticalVolumeDragging &&
                  !_isLoadingDetail &&
                  !_isResolvingPlay &&
                  _hasRenderedFirstFrame &&
                  !_player.state.buffering &&
                  _playError == null &&
                  _currentEpisode != null)
                StreamBuilder<bool>(
                  stream: _player.stream.playing,
                  initialData: _player.state.playing,
                  builder: (_, playSnap) {
                    final isPlaying = playSnap.data ?? false;
                    if (isPlaying) return const SizedBox.shrink();
                    return Center(
                      child: GestureDetector(
                        onTap: () => _player.play(),
                        child: Container(
                          width: 62,
                          height: 62,
                          decoration: BoxDecoration(
                            color: const Color(0xAA090E14),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: VideoPlatformTheme.accent,
                              width: 2.0,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 38,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              if (_isLongPressFastForward)
                Positioned(
                  top: 14,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xDD0D1824),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: VideoPlatformTheme.accent),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.bolt_rounded,
                              size: 16,
                              color: VideoPlatformTheme.accent,
                            ),
                            const SizedBox(width: 4),
                            const Text(
                              '3.0x 倍速快进中 (松手恢复)',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            // Ad-filter / Auto-skip notification toast
            if (_adToastMessage != null)
              Positioned(
                top: 14,
                left: 14,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xCC0D1824),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: VideoPlatformTheme.accent.withValues(alpha: 0.6),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.shield_rounded,
                          size: 15,
                          color: VideoPlatformTheme.accent,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _adToastMessage!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // Floating movable / hideable / closable download speed badge on VOD stage
            if (_currentEpisode != null)
              Positioned(
                top: (isFullscreen
                        ? _fullscreenControlsVisible
                        : (!widget.appState.tvMode &&
                            (!isMobilePortrait || _mobileStageOsdVisible)))
                    ? 50
                    : 10,
                right: 12,
                child: VideoDownloadSpeedBadge(
                  player: _player,
                  compact: true,
                ),
              ),
            // Floating proxy node selector + download speed HUD + quick "跳过广告" pill on video stage
            // Hidden in fullscreen mode, TV preview window, or mobile portrait unless controls are woken up!
            if (isFullscreen
                ? _fullscreenControlsVisible
                : (!widget.appState.tvMode &&
                    (!isMobilePortrait || _mobileStageOsdVisible)))
              Positioned(
                top: 10,
                left: 10,
                right: 10,
                child: Row(
                  children: [
                    if (isFullscreen)
                      InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () => _toggleFullscreenMode(forceValue: false),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xCC090E14),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.25),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.fullscreen_exit_rounded,
                                size: 16,
                                color: VideoPlatformTheme.accent,
                              ),
                              const SizedBox(width: 4),
                              ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 240),
                                child: Text(
                                  [
                                    _detail?.vodName ?? widget.initialTitle,
                                    if (_currentEpisode != null)
                                      _currentEpisode!.title,
                                  ].where((s) => s.isNotEmpty).join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const Spacer(),
                    Flexible(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Video115AccelerateButton(
                              api: widget.appState.api,
                              downloadUrlBuilder: _resolveCurrent115DownloadUrl,
                              fallbackUrlsBuilder:
                                  _resolveFallback115DownloadUrls,
                              videoNameBuilder: _resolveCurrent115VideoName,
                              headersBuilder: () => _activeStreamHeaders,
                              player: _player,
                              selected115Url: _using115Direct
                                  ? _activeStreamUrl
                                  : null,
                              overlayStyle: true,
                              compact: screenSize.width < 520,
                              onResolved: _applyResolved115Stream,
                            ),
                            const SizedBox(width: 6),
                            VideoProxyNodeSelector(
                              proxyService: widget.appState.proxyService,
                              scenario: RequestScenario.vodStream,
                              overlayStyle: true,
                              compact: screenSize.width < 520,
                              onProxyChanged: _onProxyNodeSwitched,
                            ),
                            const SizedBox(width: 6),
                            VideoProxyStatsButton(
                              proxyService: widget.appState.proxyService,
                              scenario: RequestScenario.vodStream,
                              isShowingStats: _showProxyStatsOverlay,
                              overlayStyle: true,
                              compact: screenSize.width < 520,
                              onToggle: () {
                                setState(() {
                                  _showProxyStatsOverlay =
                                      !_showProxyStatsOverlay;
                                });
                              },
                            ),
                            if (_playError == null &&
                                !_isResolvingPlay &&
                                _currentEpisode != null) ...[
                              const SizedBox(width: 6),
                              Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xAA000000),
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.22),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    InkWell(
                                      borderRadius:
                                          const BorderRadius.horizontal(
                                        left: Radius.circular(18),
                                      ),
                                      onTap: () => _skipForwardSeconds(30),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 9,
                                          vertical: 5,
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.skip_next_rounded,
                                              size: 14,
                                              color: VideoPlatformTheme.accent,
                                            ),
                                            const SizedBox(width: 3),
                                            Text(
                                              screenSize.width < 480
                                                  ? '跳广告+30s'
                                                  : '跳过广告 +30s',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 11,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    Container(
                                      width: 1,
                                      height: 15,
                                      color:
                                          Colors.white.withValues(alpha: 0.18),
                                    ),
                                    InkWell(
                                      onTap: () => _skipForwardSeconds(15),
                                      child: const Padding(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: 7,
                                          vertical: 5,
                                        ),
                                        child: Text(
                                          '+15s',
                                          style: TextStyle(
                                            color: Colors.white70,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ),
                                    ),
                                    Container(
                                      width: 1,
                                      height: 15,
                                      color:
                                          Colors.white.withValues(alpha: 0.18),
                                    ),
                                    InkWell(
                                      borderRadius:
                                          const BorderRadius.horizontal(
                                        right: Radius.circular(18),
                                      ),
                                      onTap: _showAdSkipSettingsDialog,
                                      child: const Padding(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: 7,
                                          vertical: 5,
                                        ),
                                        child: Icon(
                                          Icons.tune_rounded,
                                          size: 13.5,
                                          color: Colors.white70,
                                        ),
                                      ),
                                    ),
                                  ],
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
            if (_playError == null &&
                _detailError == null &&
                (_isLoadingDetail ||
                    _isResolvingPlay ||
                    (_currentEpisode != null && !_hasRenderedFirstFrame) ||
                    _player.state.buffering))
              IgnorePointer(
                child: Center(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xD80A111A),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: VideoPlatformTheme.accent.withValues(alpha: 0.45),
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x77000000),
                          blurRadius: 16,
                          offset: Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.6,
                            color: VideoPlatformTheme.accent,
                          ),
                        ),
                        const SizedBox(height: 11),
                        Text(
                          _isLoadingDetail
                              ? '正在连接片源 (${_activeSource.name}) 获取剧集信息...'
                              : (_isResolvingPlay
                                  ? '正在解析播放地址 (${_currentEpisode?.groupName ?? "默认线路"})...'
                                  : (!_hasRenderedFirstFrame
                                      ? (_usingClientProxy
                                          ? '正在通过代理加速连接视频源，加载首帧画面...'
                                          : (_useServerProxy
                                              ? '正在通过服务端中转连接视频源，加载首帧画面...'
                                              : '正在直连视频源，加载首帧画面...'))
                                      : '正在缓冲视频数据，请稍候...')),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (_currentEpisode != null)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  '${_currentEpisode!.groupName} · ${_currentEpisode!.title}',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 11.5,
                                  ),
                                ),
                              ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: VideoPlatformTheme.accent
                                    .withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                _usingClientProxy
                                    ? '代理: ${widget.appState.proxyService.resolveNodeForScenario(RequestScenario.vodStream)?.displayTitle ?? "加速节点"}'
                                    : (_useServerProxy ? '通道: 服务端中转' : '通道: 客户端直连'),
                                style: TextStyle(
                                  color: VideoPlatformTheme.accent,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            VideoDownloadSpeedBadge(player: _player),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_playError != null &&
                !_isResolvingPlay &&
                !_hasRenderedFirstFrame)
              Container(
                color: const Color(0xCC000000),
                padding: const EdgeInsets.all(20),
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.error_outline,
                      color: VideoPlatformTheme.danger,
                      size: 36,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _playError!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: VideoPlatformTheme.textPrimary,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      children: [
                        if (_currentEpisode != null)
                          FilledButton.icon(
                            onPressed: () =>
                                _selectAndPlayEpisode(_currentEpisode!),
                            icon: const Icon(Icons.refresh, size: 16),
                            label: const Text('重试'),
                          ),
                        if (!_useServerProxy &&
                            _resolvedPlayback?.serverProxyUrl.isNotEmpty ==
                                true)
                          OutlinedButton(
                            onPressed: () {
                              setState(() => _useServerProxy = true);
                              _openResolvedStream(
                                _resolvedPlayback!,
                                forceProxy: true,
                              );
                            },
                            child: const Text('切换代理模式播放'),
                          ),
                        OutlinedButton.icon(
                          onPressed: _showCrossSiteSourceSwitchDialog,
                          icon: const Icon(Icons.swap_horiz_rounded, size: 16),
                          label: const Text('跨站点一键换源'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            if (_showProxyStatsOverlay)
              VideoProxyStatsDetailPanel(
                proxyService: widget.appState.proxyService,
                scenario: RequestScenario.vodStream,
                onClose: () {
                  if (mounted) {
                    setState(() => _showProxyStatsOverlay = false);
                  }
                },
              ),
              ],
            );
          },
        ),
        ),
      ),
    );

    final Widget focusableStage = Focus(
      focusNode: isFullscreen ? null : _windowedStageFocusNode,
      canRequestFocus: !isFullscreen,
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      onKeyEvent: (node, event) {
        if (!node.hasPrimaryFocus) {
          return KeyEventResult.ignored;
        }
        if (event is KeyDownEvent || event is KeyRepeatEvent) {
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _rewindSeconds(15);
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _skipForwardSeconds(15, customReason: '已快进 15s');
            return KeyEventResult.handled;
          } else if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.select ||
                  event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.numpadEnter ||
                  event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
            if (_isFullscreenMode) {
              _player.playOrPause();
            } else {
              _toggleFullscreenMode(forceValue: true);
            }
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final hasStageFocus = Focus.of(ctx).hasPrimaryFocus;
          return Stack(
            fit: StackFit.expand,
            children: [
              stageContent,
              if (hasStageFocus && !isFullscreen)
                IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: fullBleed
                          ? BorderRadius.zero
                          : BorderRadius.circular(6),
                      border: Border.all(
                        color: VideoPlatformTheme.accent,
                        width: 2.5,
                      ),
                    ),
                    alignment: Alignment.bottomLeft,
                    padding: const EdgeInsets.all(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xDD090E14),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: VideoPlatformTheme.accent),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _isFullscreenMode
                                ? Icons.play_circle_fill_rounded
                                : Icons.fullscreen_rounded,
                            size: 16,
                            color: VideoPlatformTheme.accent,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _isFullscreenMode
                                ? '按确认键(OK)暂停/播放 · 左右键快退/快进 · 返回键退出全屏'
                                : '按确认键(OK)全屏放大播放 · 左右键快退/快进 15s',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );

    if (isFullscreen) {
      return SizedBox.expand(child: focusableStage);
    }
    if (fullBleed) {
      return SizedBox(
        width: double.infinity,
        height: mobileStageHeight,
        child: focusableStage,
      );
    }
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: focusableStage,
    );
  }

  Widget _buildMobileCompactTransportBar() {
    return StreamBuilder<Duration>(
      stream: _player.stream.position,
      initialData: _player.state.position,
      builder: (context, posSnap) {
        return StreamBuilder<Duration>(
          stream: _player.stream.duration,
          initialData: _player.state.duration,
          builder: (context, durSnap) {
            final rawPos = posSnap.data ?? _lastValidPosition;
            final rawDur =
                (durSnap.data != null && durSnap.data! > Duration.zero)
                    ? durSnap.data!
                    : _lastValidDuration;
            final maxSec =
                rawDur.inSeconds > 0 ? rawDur.inSeconds.toDouble() : 1.0;
            final curSec = _isSliderDragging
                ? _sliderPreviewSeconds.clamp(0.0, maxSec)
                : (_isHorizontalSeeking
                    ? _seekPreviewSeconds.clamp(0.0, maxSec)
                    : rawPos.inSeconds.toDouble().clamp(0.0, maxSec));
            final hasMultipleEps = _detail != null &&
                _detail!.playGroups.any((g) => g.episodes.length > 1);

            return Container(
              padding: const EdgeInsets.fromLTRB(12, 4, 8, 6),
              decoration: BoxDecoration(
                color: VideoPlatformTheme.bgElevated,
                border: Border(
                  bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Row 1: Ultra-slim touch progress bar
                  SizedBox(
                    height: 24,
                    child: Row(
                      children: [
                        Text(
                          _formatDurationLabel(curSec.round()),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: VideoPlatformTheme.textPrimary,
                          ),
                        ),
                        Expanded(
                          child: ExcludeFocus(
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 3.0,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6.5,
                                ),
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 12.0,
                                ),
                                activeTrackColor: VideoPlatformTheme.accent,
                                inactiveTrackColor:
                                    VideoPlatformTheme.borderStrong,
                                thumbColor: Colors.white,
                              ),
                              child: Slider(
                                value: curSec,
                                min: 0.0,
                                max: maxSec,
                                onChangeStart: (val) {
                                  setState(() {
                                    _isSliderDragging = true;
                                    _sliderPreviewSeconds = val;
                                  });
                                },
                                onChanged: (val) {
                                  setState(() {
                                    _isSliderDragging = true;
                                    _sliderPreviewSeconds = val;
                                  });
                                },
                                onChangeEnd: (val) {
                                  setState(() {
                                    _isSliderDragging = false;
                                    _sliderPreviewSeconds = val;
                                  });
                                  _player.seek(Duration(seconds: val.round()));
                                },
                              ),
                            ),
                          ),
                        ),
                        Text(
                          _formatDurationLabel(
                            rawDur.inSeconds > 0 ? rawDur.inSeconds : 0,
                          ),
                          style: TextStyle(
                            fontSize: 11,
                            color: VideoPlatformTheme.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 2),
                  // Row 2: Clean 1-row mobile transport strip
                  SizedBox(
                    height: 34,
                    child: Row(
                      children: [
                        StreamBuilder<bool>(
                          stream: _player.stream.playing,
                          initialData: _player.state.playing,
                          builder: (_, playSnap) {
                            final playing = playSnap.data ?? false;
                            return InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () => _player.playOrPause(),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 4,
                                ),
                                child: Icon(
                                  playing
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  size: 24,
                                  color: VideoPlatformTheme.textPrimary,
                                ),
                              ),
                            );
                          },
                        ),
                        if (hasMultipleEps)
                          InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: _playNextEpisodeIfAvailable,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 4,
                              ),
                              child: Icon(
                                Icons.skip_next_rounded,
                                size: 22,
                                color: VideoPlatformTheme.textPrimary,
                              ),
                            ),
                          ),
                        const SizedBox(width: 4),
                        InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => _skipForwardSeconds(30),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: VideoPlatformTheme.bgCard,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: VideoPlatformTheme.borderSubtle,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.fast_forward_rounded,
                                  size: 13,
                                  color: VideoPlatformTheme.accent,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  '跳广告+30s',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: VideoPlatformTheme.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const Spacer(),
                        PlayerVolumeControl(
                          player: _player,
                          compact: true,
                          sliderWidth: 44,
                          showPercentage: false,
                          onVolumeChanged: (val) {
                            if (mounted) {
                              setState(() => _volumePercent = val);
                            }
                          },
                        ),
                        const SizedBox(width: 4),
                        // Aspect ratio / Fit-Cover quick toggle pill
                        InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: _cycleVideoAspectMode,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: _videoAspectMode != 'fit'
                                  ? VideoPlatformTheme.accent
                                      .withValues(alpha: 0.16)
                                  : VideoPlatformTheme.bgCard,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: _videoAspectMode != 'fit'
                                    ? VideoPlatformTheme.accent
                                    : VideoPlatformTheme.borderSubtle,
                              ),
                            ),
                            child: Text(
                              _videoAspectMode == 'fit'
                                  ? '适应'
                                  : (_videoAspectMode == 'cover'
                                      ? '铺满'
                                      : _videoAspectMode),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: _videoAspectMode != 'fit'
                                    ? VideoPlatformTheme.accent
                                    : VideoPlatformTheme.textSecondary,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 5),
                        // Speed selector pill
                        PopupMenuButton<double>(
                          tooltip: '倍速播放',
                          initialValue: _playbackSpeed,
                          onSelected: (speed) {
                            setState(() => _playbackSpeed = speed);
                            _player.setRate(speed);
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 0.75, child: Text('0.75x')),
                            PopupMenuItem(value: 1.0, child: Text('1.0x 正常')),
                            PopupMenuItem(value: 1.25, child: Text('1.25x')),
                            PopupMenuItem(value: 1.5, child: Text('1.5x')),
                            PopupMenuItem(value: 2.0, child: Text('2.0x')),
                            PopupMenuItem(value: 3.0, child: Text('3.0x 极速')),
                          ],
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: _playbackSpeed != 1.0
                                  ? VideoPlatformTheme.accent
                                      .withValues(alpha: 0.16)
                                  : VideoPlatformTheme.bgCard,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: _playbackSpeed != 1.0
                                    ? VideoPlatformTheme.accent
                                    : VideoPlatformTheme.borderSubtle,
                              ),
                            ),
                            child: Text(
                              '${_playbackSpeed}x',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: _playbackSpeed != 1.0
                                    ? VideoPlatformTheme.accent
                                    : VideoPlatformTheme.textSecondary,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        // Fullscreen button
                        InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => _toggleFullscreenMode(),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: VideoPlatformTheme.accent
                                  .withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: VideoPlatformTheme.accent,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.fullscreen_rounded,
                                  size: 16,
                                  color: VideoPlatformTheme.accent,
                                ),
                                const SizedBox(width: 2),
                                Text(
                                  '全屏',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: VideoPlatformTheme.accent,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildMobileQuickActionBar() {
    final detail = _detail;
    final isFav = detail != null &&
        widget.appState.isFavorite(_activeSource, detail.vodId);
    final ep = _currentEpisode;
    final epKey = ep == null ? '' : _episodeDownloadKey(ep);
    final isAdding = epKey.isNotEmpty && _addingDownloadKeys.contains(epKey);
    final isQueued = epKey.isNotEmpty && _queuedDownloadKeys.contains(epKey);

    Widget buildActionPill({
      required IconData icon,
      required String label,
      required VoidCallback? onTap,
      bool highlighted = false,
      Color? activeColor,
    }) {
      final accent = activeColor ?? VideoPlatformTheme.accent;
      return InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: BoxDecoration(
            color: highlighted
                ? accent.withValues(alpha: 0.16)
                : VideoPlatformTheme.bgElevated,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: highlighted ? accent : VideoPlatformTheme.borderSubtle,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 15,
                color: highlighted ? accent : VideoPlatformTheme.textSecondary,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight:
                      highlighted ? FontWeight.w600 : FontWeight.normal,
                  color: highlighted ? accent : VideoPlatformTheme.textPrimary,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          buildActionPill(
            icon: Icons.swap_horiz_rounded,
            label: '同片换源',
            highlighted: true,
            onTap: _showCrossSiteSourceSwitchDialog,
          ),
          const SizedBox(width: 8),
          buildActionPill(
            icon: isQueued
                ? Icons.check_circle_rounded
                : Icons.download_rounded,
            label: isAdding
                ? '入队中...'
                : (isQueued ? '已加入下载' : '下载本集'),
            highlighted: isQueued,
            activeColor: const Color(0xFF22C55E),
            onTap: (ep == null || isAdding) ? null : _downloadCurrentEpisode,
          ),
          if (detail != null && detail.playGroups.isNotEmpty) ...[
            const SizedBox(width: 8),
            buildActionPill(
              icon: Icons.playlist_add_check_rounded,
              label: '批量下载',
              onTap: _showBatchDownloadDialog,
            ),
          ],
          const SizedBox(width: 8),
          buildActionPill(
            icon: isFav ? Icons.star_rounded : Icons.star_border_rounded,
            label: isFav ? '已收藏' : '收藏',
            highlighted: isFav,
            activeColor: VideoPlatformTheme.warning,
            onTap: detail == null
                ? null
                : () async {
                    await widget.appState.toggleFavorite(
                      source: _activeSource,
                      detail: detail,
                      currentEpisode: _currentEpisode?.title ?? '',
                      currentLine: _currentEpisode?.groupName ?? '',
                    );
                    if (mounted) setState(() {});
                  },
          ),
          const SizedBox(width: 8),
          buildActionPill(
            icon: Icons.verified_user_rounded,
            label: _removedAdSegments > 0
                ? '已除广告($_removedAdSegments)'
                : '片头/去广告',
            highlighted: widget.appState.vodFilterM3u8Ads,
            activeColor: VideoPlatformTheme.success,
            onTap: _showAdSkipSettingsDialog,
          ),
          const SizedBox(width: 8),
          buildActionPill(
            icon: Icons.tune_rounded,
            label: '更多设置',
            onTap: _showMobilePlayerMoreSettingsSheet,
          ),
        ],
      ),
    );
  }

  void _showMobilePlayerMoreSettingsSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: VideoPlatformTheme.bgElevated,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: VideoPlatformTheme.borderStrong,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Icon(
                          Icons.tune_rounded,
                          size: 18,
                          color: VideoPlatformTheme.accent,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '播放高级控制与工具',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: VideoPlatformTheme.textPrimary,
                          ),
                        ),
                        const Spacer(),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '画面比例',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: VideoPlatformTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        for (final entry in const [
                          ('fit', '适应屏幕'),
                          ('16:9', '16:9'),
                          ('4:3', '4:3'),
                          ('cover', '铺满裁剪'),
                        ])
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () {
                                  setState(() => _videoAspectMode = entry.$1);
                                  setSheetState(() {});
                                },
                                child: Container(
                                  height: 34,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: _videoAspectMode == entry.$1
                                        ? VideoPlatformTheme.accent
                                            .withValues(alpha: 0.18)
                                        : VideoPlatformTheme.bgCard,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: _videoAspectMode == entry.$1
                                          ? VideoPlatformTheme.accent
                                          : VideoPlatformTheme.borderSubtle,
                                    ),
                                  ),
                                  child: Text(
                                    entry.$2,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: _videoAspectMode == entry.$1
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                      color: _videoAspectMode == entry.$1
                                          ? VideoPlatformTheme.accent
                                          : VideoPlatformTheme.textPrimary,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _resolvedPlayback == null
                              ? null
                              : () {
                                  Navigator.of(ctx).pop();
                                  final nextMode = !_useServerProxy;
                                  setState(() => _useServerProxy = nextMode);
                                  _openResolvedStream(
                                    _resolvedPlayback!,
                                    forceProxy: nextMode,
                                  );
                                },
                          icon: Icon(
                            _useServerProxy
                                ? Icons.dns_rounded
                                : Icons.bolt_rounded,
                            size: 16,
                          ),
                          label: Text(
                            _useServerProxy ? '当前：服务端中转' : '当前：客户端直连',
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            _showExternalSubtitleDialog();
                          },
                          icon: const Icon(Icons.subtitles_rounded, size: 16),
                          label: Text(
                            _externalSubtitleName != null
                                ? '字幕: $_externalSubtitleName'
                                : '加载外挂字幕',
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            _showAudioSleepAbDialog();
                          },
                          icon: const Icon(Icons.graphic_eq_rounded, size: 16),
                          label: const Text('音轨 / 睡眠定时 / AB循环'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _currentEpisode == null
                              ? null
                              : () {
                                  Navigator.of(ctx).pop();
                                  _captureVideoScreenshot();
                                },
                          icon: const Icon(Icons.camera_alt_outlined, size: 16),
                          label: const Text('视频画面截图'),
                        ),
                        if (_resolvedPlayback != null &&
                            _resolvedPlayback!.directUrl.isNotEmpty) ...[
                          OutlinedButton.icon(
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(
                                  text: _resolvedPlayback!.directUrl,
                                ),
                              );
                              Navigator.of(ctx).pop();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('已复制流媒体地址到剪贴板'),
                                ),
                              );
                            },
                            icon: const Icon(Icons.link_rounded, size: 16),
                            label: const Text('复制流地址'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () {
                              final uri = Uri.tryParse(
                                _resolvedPlayback!.directUrl,
                              );
                              Navigator.of(ctx).pop();
                              if (uri != null) {
                                launchUrl(
                                  uri,
                                  mode: LaunchMode.externalApplication,
                                );
                              }
                            },
                            icon: const Icon(
                              Icons.open_in_new_rounded,
                              size: 16,
                            ),
                            label: const Text('外部播放器打开'),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPlayerToolbar() {
    final detail = _detail;
    final isFav =
        detail != null && widget.appState.isFavorite(_activeSource, detail.vodId);
    final isCompactMobile =
        MediaQuery.sizeOf(context).width < 680 && !widget.appState.tvMode;

    final items = <Widget>[
          // Prominent Fullscreen button in toolbar as well
          FilledButton.tonalIcon(
            onPressed: () => _toggleFullscreenMode(),
            icon: Icon(
              _isFullscreenMode
                  ? Icons.fullscreen_exit_rounded
                  : Icons.fullscreen_rounded,
              size: 18,
              color: VideoPlatformTheme.accent,
            ),
            label: Text(_isFullscreenMode ? '退出全屏' : '全屏放大'),
          ),
          // Favorite button
          OutlinedButton.icon(
            onPressed: detail == null
                ? null
                : () async {
                    await widget.appState.toggleFavorite(
                      source: _activeSource,
                      detail: detail,
                      currentEpisode: _currentEpisode?.title ?? '',
                      currentLine: _currentEpisode?.groupName ?? '',
                    );
                    if (mounted) setState(() {});
                  },
            icon: Icon(
              isFav ? Icons.star_rounded : Icons.star_border_rounded,
              size: 17,
              color: isFav
                  ? VideoPlatformTheme.warning
                  : VideoPlatformTheme.textSecondary,
            ),
            label: Text(isFav ? '已收藏' : '收藏'),
          ),
          // Floating Mini-Player (PiP) button
          OutlinedButton.icon(
            onPressed: _activeStreamUrl.isEmpty ? null : _enterMiniPlayerMode,
            icon: Icon(
              Icons.picture_in_picture_alt_rounded,
              size: 16,
              color: VideoPlatformTheme.accent,
            ),
            label: const Text('小窗播放'),
          ),
          // Cross-site intelligent source switch
          OutlinedButton.icon(
            onPressed: _showCrossSiteSourceSwitchDialog,
            icon: Icon(
              Icons.swap_horiz_rounded,
              size: 16,
              color: VideoPlatformTheme.accent,
            ),
            label: const Text('同片换源'),
          ),
          // Download current episode with animated status feedback
          Builder(
            builder: (context) {
              final ep = _currentEpisode;
              final epKey = ep == null ? '' : _episodeDownloadKey(ep);
              final isAdding =
                  epKey.isNotEmpty && _addingDownloadKeys.contains(epKey);
              final isQueued =
                  epKey.isNotEmpty && _queuedDownloadKeys.contains(epKey);
              final isFailed =
                  epKey.isNotEmpty && _failedDownloadKeys.contains(epKey);
              return FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: isQueued
                      ? const Color(0xFF1F6E43)
                      : (isFailed ? const Color(0xFF8B2635) : null),
                  foregroundColor: (isQueued || isFailed) ? Colors.white : null,
                ),
                onPressed: (ep == null || isAdding)
                    ? null
                    : _downloadCurrentEpisode,
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  transitionBuilder: (child, anim) =>
                      ScaleTransition(scale: anim, child: child),
                  child: isAdding
                      ? const SizedBox(
                          key: ValueKey('vod_dl_loading'),
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          isQueued
                              ? Icons.check_circle_rounded
                              : (isFailed
                                  ? Icons.error_outline_rounded
                                  : Icons.download_rounded),
                          key: ValueKey(
                            isQueued
                                ? 'vod_dl_done'
                                : (isFailed ? 'vod_dl_err' : 'vod_dl_idle'),
                          ),
                          size: 16,
                          color: isQueued ? const Color(0xFF69F0AE) : null,
                        ),
                ),
                label: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: Text(
                    isAdding
                        ? '正在入队...'
                        : (isQueued
                            ? '已加入下载 ✓'
                            : (isFailed ? '添加失败·重试' : '下载本集')),
                    key: ValueKey(
                      isAdding
                          ? 'l_add'
                          : (isQueued
                              ? 'l_done'
                              : (isFailed ? 'l_err' : 'l_idle')),
                    ),
                  ),
                ),
              );
            },
          ),
          // Batch download
          if (detail != null && detail.playGroups.isNotEmpty)
            OutlinedButton.icon(
              onPressed: _showBatchDownloadDialog,
              icon: const Icon(Icons.playlist_add_check_rounded, size: 17),
              label: const Text('批量下载'),
            ),
          // Direct vs Server proxy switch
          OutlinedButton.icon(
            onPressed: _resolvedPlayback == null
                ? null
                : () {
                    final nextMode = !_useServerProxy;
                    setState(() => _useServerProxy = nextMode);
                    _openResolvedStream(
                      _resolvedPlayback!,
                      forceProxy: nextMode,
                    );
                  },
            icon: Icon(
              _useServerProxy ? Icons.dns_rounded : Icons.bolt_rounded,
              size: 16,
              color: _useServerProxy
                  ? VideoPlatformTheme.warning
                  : VideoPlatformTheme.success,
            ),
            label: Text(_useServerProxy ? '服务端中转' : '直连播放'),
          ),
          // Speed selector
          Focus(
            canRequestFocus: false,
            onFocusChange: (_) {
              if (mounted) setState(() {});
            },
            child: PopupMenuButton<double>(
              tooltip: '倍速播放（长按画面也可3.0x快进）',
              initialValue: _playbackSpeed,
              onSelected: (speed) {
                setState(() => _playbackSpeed = speed);
                _player.setRate(speed);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 0.75, child: Text('0.75x')),
                PopupMenuItem(value: 1.0, child: Text('1.0x 正常')),
                PopupMenuItem(value: 1.25, child: Text('1.25x')),
                PopupMenuItem(value: 1.5, child: Text('1.5x')),
                PopupMenuItem(value: 2.0, child: Text('2.0x')),
                PopupMenuItem(value: 3.0, child: Text('3.0x 极速')),
              ],
              child: Builder(
                builder: (ctx) {
                  final isFocused = Focus.of(ctx).hasFocus;
                  return Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: isFocused
                          ? VideoPlatformTheme.accent.withValues(alpha: 0.24)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isFocused
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.borderStrong,
                        width: isFocused ? 2.0 : 1.0,
                      ),
                    ),
                    child: Text(
                      '倍速 ${_playbackSpeed}x',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            isFocused ? FontWeight.w600 : FontWeight.w400,
                        color: isFocused
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.textPrimary,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          // Aspect ratio selector
          Focus(
            canRequestFocus: false,
            onFocusChange: (_) {
              if (mounted) setState(() {});
            },
            child: PopupMenuButton<String>(
              tooltip: '切换画面比例',
              initialValue: _videoAspectMode,
              onSelected: (mode) {
                setState(() => _videoAspectMode = mode);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'fit', child: Text('适应屏幕 (默认)')),
                PopupMenuItem(value: '16:9', child: Text('强制 16:9')),
                PopupMenuItem(value: '4:3', child: Text('强制 4:3')),
                PopupMenuItem(value: 'cover', child: Text('铺满裁剪 (去黑边)')),
              ],
              child: Builder(
                builder: (ctx) {
                  final isFocused = Focus.of(ctx).hasFocus;
                  return Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                    decoration: BoxDecoration(
                      color: isFocused
                          ? VideoPlatformTheme.accent.withValues(alpha: 0.24)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isFocused
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.borderStrong,
                        width: isFocused ? 2.0 : 1.0,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.aspect_ratio_rounded,
                          size: 15,
                          color: isFocused
                              ? VideoPlatformTheme.accent
                              : VideoPlatformTheme.textPrimary,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          '比例 ${_videoAspectMode == 'fit' ? '适应' : (_videoAspectMode == 'cover' ? '铺满' : _videoAspectMode)}',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight:
                                isFocused ? FontWeight.w600 : FontWeight.w400,
                            color: isFocused
                                ? VideoPlatformTheme.accent
                                : VideoPlatformTheme.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          // External Subtitle loader button
          OutlinedButton.icon(
            onPressed: _showExternalSubtitleDialog,
            icon: Icon(
              Icons.subtitles_rounded,
              size: 16,
              color: _externalSubtitleName != null
                  ? VideoPlatformTheme.accent
                  : VideoPlatformTheme.textSecondary,
            ),
            label: Text(
              _externalSubtitleName != null
                  ? '字幕: $_externalSubtitleName'
                  : '外挂字幕',
            ),
          ),
          // Audio Track / Sleep Timer / AB Repeat button
          OutlinedButton.icon(
            onPressed: _showAudioSleepAbDialog,
            icon: Icon(
              _sleepTimerMinutes != 0 ||
                      _abPointASeconds != null ||
                      _selectedAudioTrackLabel != null
                  ? Icons.graphic_eq_rounded
                  : Icons.tune_rounded,
              size: 16,
              color: _sleepTimerMinutes != 0 ||
                      _abPointASeconds != null ||
                      _selectedAudioTrackLabel != null
                  ? VideoPlatformTheme.accent
                  : VideoPlatformTheme.textSecondary,
            ),
            label: Text(
              [
                if (_selectedAudioTrackLabel != null)
                  '音轨:$_selectedAudioTrackLabel'
                else
                  '音轨',
                if (_sleepTimerMinutes == -1)
                  '播完暂停'
                else if (_sleepTimerMinutes > 0)
                  '定时${_sleepTimerMinutes}m'
                else
                  '睡眠',
                if (_abPointASeconds != null && _abPointBSeconds != null)
                  'AB循环中'
                else
                  'AB循环',
              ].join('/'),
            ),
          ),
          // Video Frame Screenshot button
          OutlinedButton.icon(
            onPressed:
                _currentEpisode == null ? null : _captureVideoScreenshot,
            icon: const Icon(Icons.camera_alt_outlined, size: 16),
            label: const Text('画面截图'),
          ),
          // One-click Skip Ad button
          OutlinedButton.icon(
            onPressed: _currentEpisode == null
                ? null
                : () => _skipForwardSeconds(30),
            icon: Icon(
              Icons.fast_forward_rounded,
              size: 16,
              color: VideoPlatformTheme.accent,
            ),
            label: const Text('跳过广告 (+30s)'),
          ),
          // Ad-Skip & Intro/Outro Settings button
          OutlinedButton.icon(
            onPressed: _showAdSkipSettingsDialog,
            icon: Icon(
              widget.appState.vodFilterM3u8Ads
                  ? Icons.verified_user_rounded
                  : Icons.shield_outlined,
              size: 16,
              color: widget.appState.vodFilterM3u8Ads
                  ? VideoPlatformTheme.success
                  : VideoPlatformTheme.textSecondary,
            ),
            label: Text(
              _removedAdSegments > 0
                  ? '已除广告 $_removedAdSegments段(${_removedAdSeconds.toStringAsFixed(0)}s)'
                  : (widget.appState.vodSkipIntroSeconds > 0
                      ? '去广告 · 跳片头${widget.appState.vodSkipIntroSeconds}s'
                      : '去广告设置'),
            ),
          ),
          // Apple TV AirPlay & External TV Player menu
          if (_resolvedPlayback != null &&
              _resolvedPlayback!.directUrl.isNotEmpty)
            PopupMenuButton<String>(
              tooltip: '投屏至 Apple TV (AirPlay) / 外部专业播放器 (IINA / VLC / Infuse / PotPlayer)',
              onSelected: (action) async {
                final url = _resolvedPlayback!.directUrl;
                final hdrs = _resolvedPlayback!.headers;
                if (action == 'airplay') {
                  final ok = await TvPlatformService.showAirPlayPicker();
                  if (!ok && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('当前系统环境不支持原生 AirPlay 弹窗，请使用控制中心或外部 TV 播放器'),
                      ),
                    );
                  }
                } else if (action == 'curl') {
                  final ref = hdrs['Referer'] ?? hdrs['referer'] ?? '';
                  final ua = hdrs['User-Agent'] ??
                      hdrs['user-agent'] ??
                      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)';
                  final safeName = (_detail?.vodName ?? 'video')
                      .replaceAll(RegExp(r'[^\w\u4e00-\u9fa5\-_]'), '_');
                  final curlCmd = [
                    'curl -L',
                    if (ref.isNotEmpty) '-H "Referer: $ref"',
                    '-H "User-Agent: $ua"',
                    '"$url"',
                    '-o "$safeName.mp4"',
                  ].join(' ');
                  await Clipboard.setData(ClipboardData(text: curlCmd));
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('已复制带防盗链 Header 的 cURL 命令到剪贴板'),
                      ),
                    );
                  }
                } else {
                  await TvPlatformService.openInTvExternalPlayer(
                    url,
                    playerType: action,
                  );
                }
              },
              itemBuilder: (_) => [
                if (widget.appState.supportsAirPlay)
                  const PopupMenuItem(
                    value: 'airplay',
                    child: Row(
                      children: [
                        Icon(Icons.airplay_rounded, size: 17),
                        SizedBox(width: 8),
                        Text('Apple TV 隔空播放 (AirPlay 2)'),
                      ],
                    ),
                  ),
                const PopupMenuItem(
                  value: 'iina',
                  child: Row(
                    children: [
                      Icon(Icons.tv_rounded, size: 17),
                      SizedBox(width: 8),
                      Text('使用 macOS IINA 播放'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'infuse',
                  child: Row(
                    children: [
                      Icon(Icons.play_circle_outline_rounded, size: 17),
                      SizedBox(width: 8),
                      Text('使用 Apple TV / iOS Infuse 播放'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'vlc',
                  child: Row(
                    children: [
                      Icon(Icons.smart_display_outlined, size: 17),
                      SizedBox(width: 8),
                      Text('使用 VLC 播放器打开'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'potplayer',
                  child: Row(
                    children: [
                      Icon(Icons.desktop_windows_rounded, size: 17),
                      SizedBox(width: 8),
                      Text('使用 Windows PotPlayer 播放'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'nplayer',
                  child: Row(
                    children: [
                      Icon(Icons.phone_iphone_rounded, size: 17),
                      SizedBox(width: 8),
                      Text('使用 iOS / tvOS nPlayer 播放'),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'curl',
                  child: Row(
                    children: [
                      Icon(Icons.terminal_rounded, size: 17),
                      SizedBox(width: 8),
                      Text('复制带防盗链 Header 的 cURL 命令'),
                    ],
                  ),
                ),
              ],
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: VideoPlatformTheme.borderStrong),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.cast_connected_rounded,
                      size: 15,
                      color: VideoPlatformTheme.accent,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '外部播放器 / 投屏',
                      style: TextStyle(
                        fontSize: 13,
                        color: VideoPlatformTheme.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // Copy stream link
          if (_resolvedPlayback != null &&
              _resolvedPlayback!.directUrl.isNotEmpty)
            IconButton(
              tooltip: '复制流媒体地址',
              icon: const Icon(Icons.link_rounded, size: 18),
              onPressed: () {
                Clipboard.setData(
                  ClipboardData(text: _resolvedPlayback!.directUrl),
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制流媒体地址到剪贴板')),
                );
              },
            ),
          if (_resolvedPlayback != null &&
              _resolvedPlayback!.directUrl.isNotEmpty)
            IconButton(
              tooltip: '使用外部播放器或浏览器打开',
              icon: const Icon(Icons.open_in_new_rounded, size: 17),
              onPressed: () {
                final uri = Uri.tryParse(_resolvedPlayback!.directUrl);
                if (uri != null) {
                  launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
            ),
        ];

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: isCompactMobile ? 10 : 12,
        vertical: isCompactMobile ? 8 : 10,
      ),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: VideoPlatformTheme.borderSubtle),
      ),
      child: isCompactMobile
          ? SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (int i = 0; i < items.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    items[i],
                  ],
                ],
              ),
            )
          : Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: items,
            ),
    );
  }

  List<Episode> _getFilteredAndSortedEpisodes(List<Episode> all) {
    Iterable<Episode> result = all;
    if (_episodeChunkIndex >= 0 && all.length > 50) {
      final start = _episodeChunkIndex * 50;
      if (start < all.length) {
        result = result.skip(start).take(50);
      }
    }
    final kw = _episodeSearchQuery.trim().toLowerCase();
    if (kw.isNotEmpty) {
      result = result.where((e) => e.title.toLowerCase().contains(kw));
    }
    final list = result.toList();
    if (_episodesReversed) {
      return list.reversed.toList();
    }
    return list;
  }

  Widget _buildEpisodeChunkAndSearchControls(int totalEpisodes) {
    final chunkCount = totalEpisodes > 50 ? (totalEpisodes / 50).ceil() : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_showEpisodeSearch)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
            child: SizedBox(
              height: 32,
              child: TextField(
                controller: _episodeSearchCtrl,
                onChanged: (v) => setState(() => _episodeSearchQuery = v),
                style: const TextStyle(fontSize: 12),
                decoration: InputDecoration(
                  hintText: '搜索集数或标题 (如: 12、大结局)...',
                  prefixIcon: const Icon(Icons.search_rounded, size: 15),
                  suffixIcon: _episodeSearchQuery.isNotEmpty
                      ? IconButton(
                          padding: EdgeInsets.zero,
                          icon: const Icon(Icons.clear_rounded, size: 14),
                          onPressed: () {
                            _episodeSearchCtrl.clear();
                            setState(() => _episodeSearchQuery = '');
                          },
                        )
                      : null,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ),
          ),
        if (chunkCount > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SizedBox(
              height: 28,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                scrollDirection: Axis.horizontal,
                itemCount: chunkCount + 1,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (_, i) {
                  final chunkIdx = i - 1;
                  final selected = _episodeChunkIndex == chunkIdx;
                  String label = '全部';
                  if (chunkIdx >= 0) {
                    final s = chunkIdx * 50 + 1;
                    final e = ((chunkIdx + 1) * 50).clamp(1, totalEpisodes);
                    label = '$s-$e';
                  }
                  return InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onFocusChange: (_) {
                      if (mounted) setState(() {});
                    },
                    onTap: () => setState(() => _episodeChunkIndex = chunkIdx),
                    child: Builder(
                      builder: (ctx) {
                        final isFocused = Focus.of(ctx).hasPrimaryFocus;
                        if (isFocused) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (ctx.mounted) {
                              Scrollable.ensureVisible(
                                ctx,
                                alignment: 0.5,
                                duration: const Duration(milliseconds: 140),
                              );
                            }
                          });
                        }
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isFocused
                                ? VideoPlatformTheme.accent
                                    .withValues(alpha: 0.28)
                                : (selected
                                    ? VideoPlatformTheme.accent
                                        .withValues(alpha: 0.18)
                                    : VideoPlatformTheme.bgCard),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: (selected || isFocused)
                                  ? VideoPlatformTheme.accent
                                  : VideoPlatformTheme.borderSubtle,
                              width: isFocused ? 2.0 : 1.0,
                            ),
                          ),
                          child: Text(
                            label,
                            style: TextStyle(
                              fontSize: 11,
                              color: (selected || isFocused)
                                  ? VideoPlatformTheme.accent
                                  : VideoPlatformTheme.textSecondary,
                              fontWeight: (selected || isFocused)
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildRightSideEpisodePanel() {
    if (_isLoadingDetail) {
      return Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: VideoPlatformTheme.accent,
        ),
      );
    }
    if (_detailError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _detailError!,
            style: TextStyle(color: VideoPlatformTheme.textSecondary),
          ),
        ),
      );
    }
    final detail = _detail;
    if (detail == null || detail.playGroups.isEmpty) {
      return Center(
        child: Text(
          '暂无可用播放线路',
          style: TextStyle(color: VideoPlatformTheme.textMuted),
        ),
      );
    }

    final currentGroup = detail.playGroups[_selectedGroupIndex];
    final displayEpisodes =
        _getFilteredAndSortedEpisodes(currentGroup.episodes);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
          child: Row(
            children: [
              Text(
                '选集播放',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: VideoPlatformTheme.textPrimary,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '(${currentGroup.episodes.length}集)',
                style: TextStyle(
                  fontSize: 12,
                  color: VideoPlatformTheme.textMuted,
                ),
              ),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '搜索剧集',
                icon: Icon(
                  Icons.search_rounded,
                  size: 17,
                  color: _showEpisodeSearch
                      ? VideoPlatformTheme.accent
                      : VideoPlatformTheme.textSecondary,
                ),
                onPressed: () {
                  setState(() {
                    _showEpisodeSearch = !_showEpisodeSearch;
                    if (!_showEpisodeSearch) {
                      _episodeSearchCtrl.clear();
                      _episodeSearchQuery = '';
                    }
                  });
                },
              ),
              InkWell(
                borderRadius: BorderRadius.circular(4),
                onFocusChange: (_) {
                  if (mounted) setState(() {});
                },
                onTap: () =>
                    setState(() => _episodesReversed = !_episodesReversed),
                child: Builder(
                  builder: (ctx) {
                    final isFocused = Focus.of(ctx).hasPrimaryFocus;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isFocused
                            ? VideoPlatformTheme.accent.withValues(alpha: 0.24)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(4),
                        border: isFocused
                            ? Border.all(
                                color: VideoPlatformTheme.accent,
                                width: 1.8,
                              )
                            : null,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.swap_vert_rounded,
                            size: 15,
                            color: (_episodesReversed || isFocused)
                                ? VideoPlatformTheme.accent
                                : VideoPlatformTheme.textSecondary,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            _episodesReversed ? '倒序' : '正序',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: isFocused
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: (_episodesReversed || isFocused)
                                  ? VideoPlatformTheme.accent
                                  : VideoPlatformTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                borderRadius: BorderRadius.circular(5),
                onFocusChange: (_) {
                  if (mounted) setState(() {});
                },
                onTap: () =>
                    setState(() => _isEpisodeSidebarCollapsed = true),
                child: Builder(
                  builder: (ctx) {
                    final isFocused = Focus.of(ctx).hasPrimaryFocus;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isFocused
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.accent.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(
                          color: isFocused
                              ? Colors.white
                              : VideoPlatformTheme.accent,
                          width: isFocused ? 2.0 : 1.0,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '收起',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: isFocused
                                  ? Colors.white
                                  : VideoPlatformTheme.accent,
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 16,
                            color: isFocused
                                ? Colors.white
                                : VideoPlatformTheme.accent,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        // Play line tabs
        SizedBox(
          height: 36,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            scrollDirection: Axis.horizontal,
            itemCount: detail.playGroups.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, idx) {
              final grp = detail.playGroups[idx];
              final selected = idx == _selectedGroupIndex;
              return InkWell(
                borderRadius: BorderRadius.circular(5),
                onFocusChange: (_) {
                  if (mounted) setState(() {});
                },
                onTap: () => setState(() {
                  _selectedGroupIndex = idx;
                  _episodeChunkIndex = -1;
                }),
                child: Builder(
                  builder: (ctx) {
                    final isFocused = Focus.of(ctx).hasPrimaryFocus;
                    if (isFocused) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (ctx.mounted) {
                          Scrollable.ensureVisible(
                            ctx,
                            alignment: 0.5,
                            duration: const Duration(milliseconds: 140),
                          );
                        }
                      });
                    }
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected
                            ? VideoPlatformTheme.accent
                            : (isFocused
                                ? VideoPlatformTheme.accent
                                    .withValues(alpha: 0.25)
                                : VideoPlatformTheme.bgCard),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(
                          color: (selected || isFocused)
                              ? VideoPlatformTheme.accent
                              : VideoPlatformTheme.borderSubtle,
                          width: isFocused ? 2.0 : 1.0,
                        ),
                      ),
                      child: Text(
                        '${grp.name} (${grp.episodes.length})',
                        style: TextStyle(
                          fontSize: 12,
                          color: selected
                              ? Colors.white
                              : (isFocused
                                  ? VideoPlatformTheme.accent
                                  : VideoPlatformTheme.textSecondary),
                          fontWeight: (selected || isFocused)
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
        _buildEpisodeChunkAndSearchControls(currentGroup.episodes.length),
        const SizedBox(height: 10),
        const Divider(height: 1),
        // Episode grid
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(14),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 112,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 2.6,
            ),
            itemCount: displayEpisodes.length,
            itemBuilder: (_, idx) {
              final ep = displayEpisodes[idx];
              final isPlaying = _currentEpisode?.groupName == ep.groupName &&
                  _currentEpisode?.index == ep.index;
              return _buildEpisodeButton(ep, isPlaying);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildInlineEpisodeSection() {
    final detail = _detail;
    if (_isLoadingDetail) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (detail == null || detail.playGroups.isEmpty) {
      return const SizedBox.shrink();
    }
    final currentGroup = detail.playGroups[_selectedGroupIndex];
    final displayEpisodes =
        _getFilteredAndSortedEpisodes(currentGroup.episodes);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: VideoPlatformTheme.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.playlist_play_rounded,
                size: 18,
                color: VideoPlatformTheme.accent,
              ),
              const SizedBox(width: 6),
              Text(
                '选集与片源线路 (${currentGroup.episodes.length}集)',
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w800,
                  color: VideoPlatformTheme.textPrimary,
                ),
              ),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '搜索剧集',
                icon: Icon(
                  Icons.search_rounded,
                  size: 17,
                  color: _showEpisodeSearch
                      ? VideoPlatformTheme.accent
                      : VideoPlatformTheme.textSecondary,
                ),
                onPressed: () {
                  setState(() {
                    _showEpisodeSearch = !_showEpisodeSearch;
                    if (!_showEpisodeSearch) {
                      _episodeSearchCtrl.clear();
                      _episodeSearchQuery = '';
                    }
                  });
                },
              ),
              TextButton.icon(
                onPressed: () =>
                    setState(() => _episodesReversed = !_episodesReversed),
                icon: Icon(
                  Icons.swap_vert_rounded,
                  size: 15,
                  color: _episodesReversed
                      ? VideoPlatformTheme.accent
                      : VideoPlatformTheme.textSecondary,
                ),
                label: Text(_episodesReversed ? '倒序' : '正序'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 32,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: detail.playGroups.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, idx) {
                final grp = detail.playGroups[idx];
                final selected = idx == _selectedGroupIndex;
                return InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => setState(() {
                    _selectedGroupIndex = idx;
                    _episodeChunkIndex = -1;
                  }),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 13),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected
                          ? VideoPlatformTheme.accent
                          : VideoPlatformTheme.bgCard,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: selected
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.borderSubtle,
                      ),
                    ),
                    child: Text(
                      grp.name,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            selected ? FontWeight.w800 : FontWeight.w500,
                        color: selected
                            ? Colors.black
                            : VideoPlatformTheme.textSecondary,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          _buildEpisodeChunkAndSearchControls(currentGroup.episodes.length),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 224),
            child: GridView.builder(
              shrinkWrap: true,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 108,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 2.55,
              ),
              itemCount: displayEpisodes.length,
              itemBuilder: (_, idx) {
                final ep = displayEpisodes[idx];
                final isPlaying = _currentEpisode?.groupName == ep.groupName &&
                    _currentEpisode?.index == ep.index;
                return _buildEpisodeButton(ep, isPlaying);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEpisodeButton(Episode ep, bool isPlaying) {
    final savedProg = widget.appState.getVodProgress(
      _activeSource.id,
      _activeVodId,
    );
    final isSavedEpisode = savedProg != null &&
        savedProg.episodeIndex == ep.index &&
        savedProg.positionSeconds > 5;

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      focusColor: VideoPlatformTheme.accent.withValues(alpha: 0.35),
      onFocusChange: (focused) {
        if (focused && mounted) {
          setState(() {});
        }
      },
      onTap: () => _selectAndPlayEpisode(
        ep,
        resumeSeconds:
            isSavedEpisode ? savedProg.positionSeconds.toDouble() : 0,
      ),
      child: Builder(
        builder: (ctx) {
          final isFocused = Focus.of(ctx).hasPrimaryFocus;
          if (isFocused) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (ctx.mounted) {
                Scrollable.ensureVisible(
                  ctx,
                  alignment: 0.5,
                  duration: const Duration(milliseconds: 140),
                );
              }
            });
          }
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isFocused
                  ? VideoPlatformTheme.accent
                  : (isPlaying
                      ? VideoPlatformTheme.accent.withValues(alpha: 0.18)
                      : VideoPlatformTheme.bgCard),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isFocused
                    ? Colors.white
                    : (isPlaying
                        ? VideoPlatformTheme.accent
                        : (isSavedEpisode
                            ? VideoPlatformTheme.accent.withValues(alpha: 0.5)
                            : VideoPlatformTheme.borderSubtle)),
                width: isFocused ? 2.2 : 1.0,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  ep.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: isFocused
                        ? Colors.black
                        : (isPlaying
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.textPrimary),
                    fontWeight: (isPlaying || isFocused)
                        ? FontWeight.w800
                        : FontWeight.w500,
                  ),
                ),
                if (isSavedEpisode)
                  Text(
                    _formatDurationLabel(savedProg.positionSeconds),
                    style: TextStyle(
                      fontSize: 9.5,
                      color: isFocused
                          ? Colors.black87
                          : VideoPlatformTheme.accent,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildMetadataPanel() {
    final detail = _detail;
    if (detail == null) return const SizedBox.shrink();

    final metaParts = <String>[
      if (detail.vodYear.isNotEmpty && detail.vodYear != '0') detail.vodYear,
      if (detail.vodArea.isNotEmpty) detail.vodArea,
      if (detail.typeName.isNotEmpty) detail.typeName,
      '媒体源: ${_activeSource.name}',
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: VideoPlatformTheme.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  detail.vodName,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: VideoPlatformTheme.textPrimary,
                  ),
                ),
              ),
              if (detail.vodRemarks.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: VideoPlatformTheme.accent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: VideoPlatformTheme.accent.withValues(alpha: 0.55),
                    ),
                  ),
                  child: Text(
                    detail.vodRemarks,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: VideoPlatformTheme.accent,
                    ),
                  ),
                ),
            ],
          ),
          if (metaParts.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              metaParts.join(' · '),
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: VideoPlatformTheme.textSecondary,
              ),
            ),
          ],
          if (detail.vodDirector.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '导演：${detail.vodDirector}',
              style: TextStyle(
                fontSize: 12.5,
                color: VideoPlatformTheme.textSecondary,
              ),
            ),
          ],
          if (detail.vodActor.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              '演职员：${detail.vodActor}',
              style: TextStyle(
                fontSize: 12.5,
                color: VideoPlatformTheme.textSecondary,
              ),
            ),
          ],
          if (detail.vodContent.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Text(
              '剧情简介',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: VideoPlatformTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              detail.vodContent.replaceAll(RegExp(r'<[^>]*>'), '').trim(),
              style: TextStyle(
                fontSize: 13,
                height: 1.55,
                color: VideoPlatformTheme.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _showAdSkipSettingsDialog() async {
    const introPresets = [0, 15, 30, 45, 60, 90, 120, 150];
    const outroPresets = [0, 30, 45, 60, 90, 120, 150];

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final filterAds = widget.appState.vodFilterM3u8Ads;
            final introSec = widget.appState.vodSkipIntroSeconds;
            final outroSec = widget.appState.vodSkipOutroSeconds;
            final currentPosSec = _player.state.position.inSeconds;

            return AlertDialog(
              backgroundColor: VideoPlatformTheme.bgElevated,
              title: Row(
                children: [
                  Icon(
                    Icons.verified_user_rounded,
                    size: 19,
                    color: VideoPlatformTheme.accent,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '智能去广告与跳过片头/片尾设置',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              content: SizedBox(
                width: 480,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        'M3U8 切片级智能去广告',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: VideoPlatformTheme.textPrimary,
                        ),
                      ),
                      subtitle: Text(
                        '自动分析播放列表，识别并剔除 #EXT-X-DISCONTINUITY 插播的赌场/游戏广告切片',
                        style: TextStyle(
                          fontSize: 12,
                          color: VideoPlatformTheme.textSecondary,
                        ),
                      ),
                      value: filterAds,
                      activeColor: VideoPlatformTheme.accent,
                      onChanged: (val) async {
                        await widget.appState.setVodAdSettings(
                          filterM3u8Ads: val,
                        );
                        setDialogState(() {});
                        if (mounted) setState(() {});
                      },
                    ),
                    const Divider(height: 20),
                    Row(
                      children: [
                        Text(
                          '自动跳过片头广告 / 片头曲',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: VideoPlatformTheme.textPrimary,
                          ),
                        ),
                        const Spacer(),
                        if (currentPosSec > 0 && currentPosSec <= 300)
                          TextButton.icon(
                            onPressed: () async {
                              await widget.appState.setVodAdSettings(
                                skipIntroSeconds: currentPosSec,
                              );
                              setDialogState(() {});
                              if (mounted) setState(() {});
                            },
                            icon: const Icon(Icons.flag_rounded, size: 14),
                            label: Text('设当前位置 (${currentPosSec}s) 为片头结束'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: introPresets.map((sec) {
                        final selected = introSec == sec;
                        return ChoiceChip(
                          label: Text(sec == 0 ? '不跳过' : '$sec秒'),
                          selected: selected,
                          selectedColor: VideoPlatformTheme.accent,
                          labelStyle: TextStyle(
                            fontSize: 12,
                            color: selected
                                ? Colors.white
                                : VideoPlatformTheme.textPrimary,
                          ),
                          onSelected: (_) async {
                            await widget.appState.setVodAdSettings(
                              skipIntroSeconds: sec,
                            );
                            setDialogState(() {});
                            if (mounted) setState(() {});
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '自动跳过片尾广告 / 片尾曲（自动连播下一集）',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: VideoPlatformTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: outroPresets.map((sec) {
                        final selected = outroSec == sec;
                        return ChoiceChip(
                          label: Text(sec == 0 ? '不跳过' : '$sec秒'),
                          selected: selected,
                          selectedColor: VideoPlatformTheme.accent,
                          labelStyle: TextStyle(
                            fontSize: 12,
                            color: selected
                                ? Colors.white
                                : VideoPlatformTheme.textPrimary,
                          ),
                          onSelected: (_) async {
                            await widget.appState.setVodAdSettings(
                              skipOutroSeconds: sec,
                            );
                            setDialogState(() {});
                            if (mounted) setState(() {});
                          },
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _skipForwardSeconds(30);
                  },
                  child: const Text('立即快进 +30s'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('完成'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
