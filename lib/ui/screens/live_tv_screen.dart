import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/models.dart';
import '../../services/proxy_routing_service.dart';
import '../../services/tv_platform_service.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets/cloud_music_player.dart';
import '../widgets/video_download_speed_badge.dart';
import '../widgets/video_proxy_node_selector.dart';
import '../widgets/video_proxy_stats_overlay.dart';

class LiveTvScreen extends StatefulWidget {
  final AppState appState;

  const LiveTvScreen({
    super.key,
    required this.appState,
  });

  @override
  State<LiveTvScreen> createState() => _LiveTvScreenState();
}

class _LiveTvScreenState extends State<LiveTvScreen> {
  late final Player _player;
  late final VideoController _videoController;
  final ScrollController _groupScrollController = ScrollController();
  StreamSubscription<String>? _errorSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<int?>? _widthSub;
  StreamSubscription<int?>? _heightSub;
  StreamSubscription<VideoParams>? _videoParamsSub;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<bool>? _playingSub;
  final GlobalKey _liveVideoWidgetKey =
      GlobalKey(debugLabel: 'LiveMainVideoWidget');
  final GlobalKey _livePlayerPanelKey =
      GlobalKey(debugLabel: 'LivePlayerPanel');
  int _liveVideoWidth = 0;
  int _liveVideoHeight = 0;
  String _liveAspectMode = 'fit'; // 'fit', 'cover', '16:9'
  bool? _liveLandscapeOverride;
  DateTime _lastFullscreenToggleAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _startupTimer;
  Timer? _reconnectTimer;
  Timer? _liveBufferingLagTimer;

  String _selectedGroup = '全部';
  String _channelSearch = '';
  LiveChannel? _currentChannel;
  int _currentUrlIndex = 0;
  final Set<int> _triedUrlIndices = {};
  bool _isResolving = false;
  bool _hasActivePlayback = false;
  int _playSessionId = 0;
  int _consecutiveReconnects = 0;
  String? _playError;
  String _activeRouteLabel = '客户端直连';
  bool _useServerProxy = false;

  final Map<String, bool> _healthStatus = {};
  final Map<String, int> _latencyMsByUrl = {};
  final Map<String, int> _preferredUrlIndexByChannel = {};
  bool _isCheckingHealth = false;

  // Favorites Live Channels
  static const _prefFavLiveChannelsKey = 'm3u8_live_fav_channels_v1';
  Set<String> _favoriteChannelKeys = {};

  // Active playback stream info for Live Recording & Mini-Player
  String _activeStreamUrl = '';
  Map<String, String> _activeStreamHeaders = const {};

  // Collapsible & resizable channel list state
  bool _isSidebarCollapsed = false;
  bool _isLiveFullscreen = false;
  bool _showProxyStatsOverlay = false;
  bool _liveOsdVisible = false;
  bool _showFullscreenChannelDrawer = false;
  Timer? _liveOsdTimer;
  double _sidebarWidth = 264.0;
  final Set<String> _collapsedGroups = {};

  void _pokeLiveOsd({bool focusBottomBar = false}) {
    _liveOsdTimer?.cancel();
    if (!_liveOsdVisible && mounted) {
      setState(() => _liveOsdVisible = true);
    }
    if (focusBottomBar) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _liveOsdVisible) {
          _liveBottomBarFocusNode.requestFocus();
        }
      });
    }
    if (_isLiveFullscreen) {
      _liveOsdTimer = Timer(const Duration(milliseconds: 3800), () {
        if (mounted && _isLiveFullscreen && !_showFullscreenChannelDrawer) {
          setState(() => _liveOsdVisible = false);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _isLiveFullscreen && !_liveOsdVisible) {
              _playerFocusNode.requestFocus();
            }
          });
        }
      });
    }
  }

  bool get _isLivePortraitVideo =>
      _liveVideoWidth > 0 &&
      _liveVideoHeight > 0 &&
      _liveVideoHeight > _liveVideoWidth;

  void _updateLiveVideoDimensions({int? w, int? h, VideoParams? params}) {
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
    if (nextW > 0 &&
        nextH > 0 &&
        (nextW != _liveVideoWidth || nextH != _liveVideoHeight)) {
      final prevPortrait = _isLivePortraitVideo;
      setState(() {
        _liveVideoWidth = nextW;
        _liveVideoHeight = nextH;
      });
      if (_isLiveFullscreen &&
          _liveLandscapeOverride == null &&
          _isLivePortraitVideo != prevPortrait) {
        _applyLiveFullscreenOrientation();
      }
    }
  }

  void _applyLiveFullscreenOrientation() {
    if (!(Platform.isAndroid || Platform.isIOS) || widget.appState.tvMode) {
      return;
    }
    final useLandscape = _liveLandscapeOverride ?? !_isLivePortraitVideo;
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

  void _ensureLivePlaybackContinuesAfterFullscreenChange(bool shouldKeepPlaying) {
    if (!shouldKeepPlaying) return;
    void checkAndResume() {
      if (!mounted ||
          _currentChannel == null ||
          _playError != null ||
          widget.appState.miniPlayerSession != null) {
        return;
      }
      if (!_player.state.playing && !_isResolving) {
        unawaited(_player.play());
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => checkAndResume());
    Future<void>.delayed(const Duration(milliseconds: 180), checkAndResume);
    Future<void>.delayed(const Duration(milliseconds: 480), checkAndResume);
  }

  void _toggleLiveOrientation() {
    final shouldKeepPlaying = _currentChannel != null &&
        (_player.state.playing || _hasActivePlayback || _isResolving);
    _lastFullscreenToggleAt = DateTime.now();
    final mq = MediaQuery.maybeSizeOf(context);
    final currentlyLandscape = _liveLandscapeOverride ??
        (mq != null ? mq.width > mq.height : !_isLivePortraitVideo);
    final nextLandscape = !currentlyLandscape;
    setState(() {
      _liveLandscapeOverride = nextLandscape;
      if (!_isLiveFullscreen) {
        _isLiveFullscreen = true;
        _isSidebarCollapsed = true;
      }
    });
    widget.appState.setImmersiveFullscreen(true);
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      if (!widget.appState.tvMode) {
        _applyLiveFullscreenOrientation();
      }
    }
    _ensureLivePlaybackContinuesAfterFullscreenChange(shouldKeepPlaying);
  }

  void _cycleLiveAspectMode() {
    const modes = ['fit', 'cover', '16:9'];
    final idx = modes.indexOf(_liveAspectMode);
    final next = modes[(idx + 1) % modes.length];
    setState(() => _liveAspectMode = next);
  }

  void _toggleLiveFullscreen({bool? forceValue}) {
    final next = forceValue ?? !_isLiveFullscreen;
    if (next == _isLiveFullscreen &&
        widget.appState.isImmersiveFullscreen == next) {
      return;
    }
    final shouldKeepPlaying = _currentChannel != null &&
        (_player.state.playing || _hasActivePlayback || _isResolving);
    _lastFullscreenToggleAt = DateTime.now();
    _liveOsdTimer?.cancel();
    setState(() {
      _isLiveFullscreen = next;
      // Hide bottom progress/control bar and top HUD immediately on entering fullscreen;
      // they only show when the remote moves or screen is tapped.
      _liveOsdVisible = false;
      if (!next) {
        _showFullscreenChannelDrawer = false;
        _liveLandscapeOverride = null;
      }
      if (next) {
        _isSidebarCollapsed = true;
      }
    });
    widget.appState.setImmersiveFullscreen(next);
    if (Platform.isAndroid || Platform.isIOS) {
      if (next) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        if (!widget.appState.tvMode) {
          _applyLiveFullscreenOrientation();
        }
      } else {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        if (!widget.appState.tvMode) {
          SystemChrome.setPreferredOrientations(const [
            DeviceOrientation.portraitUp,
          ]);
          Future<void>.delayed(const Duration(milliseconds: 800), () {
            if (mounted && !_isLiveFullscreen) {
              SystemChrome.setPreferredOrientations(const []);
            }
          });
        }
      }
    }
    _ensureLivePlaybackContinuesAfterFullscreenChange(shouldKeepPlaying);
    if (next) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _playerFocusNode.requestFocus();
        }
      });
    }
  }

  // Player focus, mouse wheel channel switching & number pad channel jump state
  final FocusNode _playerFocusNode = FocusNode(debugLabel: 'LivePlayerStage');
  final FocusNode _liveBottomBarFocusNode =
      FocusNode(debugLabel: 'LiveBottomBarPrimary');
  double _wheelScrollAccumulator = 0.0;
  DateTime _lastWheelEventTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastWheelSwitchTime = DateTime.fromMillisecondsSinceEpoch(0);
  String? _channelOsdText;
  Timer? _channelOsdTimer;
  String _digitInputBuffer = '';
  Timer? _digitInputTimer;

  // Multi-View 2x2 Wall Mode state
  bool _isMultiViewMode = false;
  int _activeMultiViewSlot = 0; // 0: main player, 1..3: sub players
  final Map<int, Player> _subPlayers = {};
  final Map<int, VideoController> _subControllers = {};
  final Map<int, LiveChannel> _subChannels = {};
  String _lastLiveRouteSignature = '';
  int _lastObservedNetworkResumeEpoch = 0;

  void _onAppStateNetworkResumeChanged() {
    if (!mounted) return;
    final epoch = widget.appState.networkResumeEpoch;
    if (epoch == _lastObservedNetworkResumeEpoch) return;
    _lastObservedNetworkResumeEpoch = epoch;
    final ch = _currentChannel;
    if (ch == null || widget.appState.miniPlayerSession != null) return;
    if (_playError != null ||
        !_player.state.playing ||
        _player.state.completed ||
        _activeStreamUrl.contains('127.0.0.1')) {
      _playChannel(
        ch,
        urlIndex: _currentUrlIndex,
        resetTried: _playError != null,
        isAutoReconnect: true,
      );
    }
  }

  String _computeLiveRouteSignature() {
    final svc = widget.appState.proxyService;
    final effective = svc.resolveEffectiveRoute(RequestScenario.liveStream);
    final nodeId = effective == ScenarioRouteMode.proxyNode
        ? (svc.resolveNodeForScenario(RequestScenario.liveStream)?.id ?? '')
        : '';
    return '${svc.proxyEnabled}|${effective.name}|$nodeId';
  }

  void _onExternalProxyServiceChanged() {
    if (!mounted) return;
    final nextSig = _computeLiveRouteSignature();
    if (nextSig == _lastLiveRouteSignature) return;
    _lastLiveRouteSignature = nextSig;
    final ch = _currentChannel;
    if (ch == null || widget.appState.miniPlayerSession != null) return;
    _useServerProxy = widget.appState.proxyService
            .resolveEffectiveRoute(RequestScenario.liveStream) ==
        ScenarioRouteMode.serverRelay;
    _playChannel(
      ch,
      urlIndex: _currentUrlIndex,
      resetTried: false,
      isAutoReconnect: true,
    );
  }

  void _onLiveFocusManagerChanged() {
    if (!mounted || !_isLiveFullscreen || !_liveOsdVisible) return;
    _pokeLiveOsd();
  }

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onLiveFocusManagerChanged);
    _player = Player(
      configuration: PlayerConfiguration(
        bufferSize: (Platform.isAndroid || Platform.isIOS)
            ? 48 * 1024 * 1024
            : 64 * 1024 * 1024,
      ),
    );
    _videoController = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        hwdec: Platform.isAndroid ? 'mediacodec-copy' : null,
        enableHardwareAcceleration: true,
      ),
    );
    _configureLiveNativePlayer();

    _widthSub = _player.stream.width.listen((w) {
      _updateLiveVideoDimensions(w: w);
      if ((w ?? 0) > 0 && mounted && !_isResolving) {
        final wasActive = _hasActivePlayback;
        _hasActivePlayback = true;
        _consecutiveReconnects = 0;
        _startupTimer?.cancel();
        final ch = _currentChannel;
        if (ch != null) {
          _preferredUrlIndexByChannel['${ch.group}|${ch.name}'] =
              _currentUrlIndex;
        }
        if (!wasActive || _playError != null) {
          setState(() => _playError = null);
        }
      }
    });
    _heightSub = _player.stream.height.listen((h) {
      _updateLiveVideoDimensions(h: h);
    });
    _videoParamsSub = _player.stream.videoParams.listen((params) {
      _updateLiveVideoDimensions(params: params);
    });

    _posSub = _player.stream.position.listen((pos) {
      if (pos > Duration.zero && mounted && !_isResolving) {
        final wasActive = _hasActivePlayback;
        _hasActivePlayback = true;
        _consecutiveReconnects = 0;
        _startupTimer?.cancel();
        if (!wasActive || _playError != null) {
          setState(() => _playError = null);
        }
      }
    });

    _playingSub = _player.stream.playing.listen((playing) {
      if (playing) {
        unawaited(CloudMusicController.stopAllBackgroundAudioForVideo());
      }
      if (playing ||
          !mounted ||
          _isResolving ||
          _currentChannel == null ||
          _playError != null ||
          widget.appState.miniPlayerSession != null) {
        return;
      }
      final sinceFullscreenToggleMs =
          DateTime.now().difference(_lastFullscreenToggleAt).inMilliseconds;
      if (sinceFullscreenToggleMs >= 0 && sinceFullscreenToggleMs < 1800) {
        unawaited(_player.play());
      }
    });

    _bufferingSub = _player.stream.buffering.listen((isBuffering) {
      _liveBufferingLagTimer?.cancel();
      if (!isBuffering ||
          !mounted ||
          _isResolving ||
          !_hasActivePlayback ||
          widget.appState.miniPlayerSession != null) {
        return;
      }
      final ch = _currentChannel;
      if (ch == null) return;
      _liveBufferingLagTimer = Timer(const Duration(seconds: 8), () async {
        if (!mounted ||
            !_player.state.buffering ||
            _currentChannel != ch ||
            widget.appState.miniPlayerSession != null) {
          return;
        }
        if (LocalProxyTunnelBridge.recentDownstreamBytesPerSecond >
            192 * 1024) {
          return;
        }
        if (_activeRouteLabel == '客户端代理') {
          final prevNodeId = widget.appState.proxyService.activeNode?.id;
          final nextNode = await widget.appState.proxyService
              .reportActiveNodeLag(reason: '直播缓冲卡顿');
          if (!mounted || _currentChannel != ch) return;
          if (nextNode != null && nextNode.id != prevNodeId) {
            return; // _onExternalProxyServiceChanged will automatically reconnect on the new node
          }
        }
        // Reconnect or switch to backup signal line if live stream stalled for 8s
        if (ch.urls.length > 1) {
          _tryNextSignalOrReportError(ch, '直播信号源缓冲过慢');
        } else {
          _playChannel(
            ch,
            urlIndex: _currentUrlIndex,
            resetTried: false,
            isAutoReconnect: true,
          );
        }
      });
    });

    _completedSub = _player.stream.completed.listen((completed) {
      if (!completed ||
          !mounted ||
          _isResolving ||
          widget.appState.miniPlayerSession != null) {
        return;
      }
      final ch = _currentChannel;
      if (ch == null) return;

      // Live TV streams should never stay stopped on EOF.
      // If the stream was actively playing, reconnect to refresh single-use
      // CDN tokens or resume after a segment rotation.
      if (_hasActivePlayback && _consecutiveReconnects < 5) {
        _consecutiveReconnects++;
        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(const Duration(milliseconds: 500), () {
          if (!mounted ||
              _currentChannel != ch ||
              widget.appState.miniPlayerSession != null) {
            return;
          }
          _playChannel(
            ch,
            urlIndex: _currentUrlIndex,
            resetTried: false,
            isAutoReconnect: true,
          );
        });
        return;
      }

      // If the URL ended before ever producing video, try the next signal line.
      _tryNextSignalOrReportError(ch, '直播流连接已断开');
    });

    _errorSub = _player.stream.error.listen((err) {
      if (err.isEmpty ||
          !mounted ||
          _isResolving ||
          widget.appState.miniPlayerSession != null) {
        return;
      }
      final ch = _currentChannel;
      if (ch == null) return;

      // Ignore non-fatal H.264/HEVC/AAC frame decode warnings that media_kit
      // forwards from libmpv `vd`/`ad` logs during normal live stream playback.
      if (_isNonFatalStreamError(err)) {
        return;
      }

      // If video is already playing, do NOT kill the active stream or jump to
      // another URL on transient demuxer/segment warnings.
      if (_hasActivePlayback) {
        return;
      }

      _tryNextSignalOrReportError(ch, err);
    });

    if (widget.appState.liveSources.isEmpty && !widget.appState.isLoadingLive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.appState.loadLiveSources();
      });
    }
    _lastLiveRouteSignature = _computeLiveRouteSignature();
    _lastObservedNetworkResumeEpoch = widget.appState.networkResumeEpoch;
    widget.appState.proxyService.addListener(_onExternalProxyServiceChanged);
    widget.appState.addListener(_onAppStateNetworkResumeChanged);
    _loadLivePrefs();
  }

  String _channelKey(LiveChannel ch) => '${ch.group}|${ch.name}';

  Future<void> _loadLivePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final favs = prefs.getStringList(_prefFavLiveChannelsKey);
      if (!mounted) return;
      setState(() {
        if (favs != null) _favoriteChannelKeys = favs.toSet();
      });
    } catch (_) {}
  }

  Future<void> _toggleFavoriteChannel(LiveChannel ch) async {
    final key = _channelKey(ch);
    setState(() {
      if (_favoriteChannelKeys.contains(key)) {
        _favoriteChannelKeys.remove(key);
      } else {
        _favoriteChannelKeys.add(key);
      }
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _prefFavLiveChannelsKey,
        _favoriteChannelKeys.toList(),
      );
    } catch (_) {}
  }

  ({String currentTitle, String nextTitle, String timeSlot, double progress})
      _getChannelEpgInfo(LiveChannel ch) {
    final now = DateTime.now();
    final hour = now.hour;
    final minute = now.minute;
    final slotStartMin = minute < 30 ? 0 : 30;
    final slotEndMin = minute < 30 ? 30 : 0;
    final slotEndHour = minute < 30 ? hour : (hour + 1) % 24;
    final timeSlot =
        '${hour.toString().padLeft(2, '0')}:${slotStartMin.toString().padLeft(2, '0')} - ${slotEndHour.toString().padLeft(2, '0')}:${slotEndMin.toString().padLeft(2, '0')}';
    final progress = ((minute % 30) * 60 + now.second) / 1800.0;

    final upper = '${ch.name} ${ch.group}'.toUpperCase();
    List<String> schedule;
    if (upper.contains('CCTV-5') ||
        upper.contains('CCTV5') ||
        upper.contains('体育') ||
        upper.contains('SPORT')) {
      schedule = const [
        '体坛快讯 · 赛事集锦',
        '实况录像：国际顶级联赛精选',
        '体育世界 · 焦点战报',
        '冠军欧洲 / 篮球公园',
        '赛事直播：巅峰对决',
        '天下足球 / 体育新闻',
      ];
    } else if (upper.contains('CCTV-6') ||
        upper.contains('CCTV6') ||
        upper.contains('电影') ||
        upper.contains('MOVIE') ||
        upper.contains('CHC')) {
      schedule = const [
        '佳片有约：经典院线大片',
        '中国电影报道 · 幕后纪实',
        '光影星播客 · 影评专栏',
        '黄金档院线巨制（上）',
        '黄金档院线巨制（下）',
        '午夜经典影院',
      ];
    } else if (upper.contains('CCTV-13') ||
        upper.contains('CCTV13') ||
        upper.contains('新闻') ||
        upper.contains('凤凰') ||
        upper.contains('NEWS')) {
      schedule = const [
        '朝闻天下 / 整点新闻直播间',
        '新闻30分 · 全球连线',
        '今日关注 · 深度时事评论',
        '新闻联播 / 焦点访谈',
        '东方时空 · 共同关注',
        '24小时 · 国际时讯',
      ];
    } else if (upper.contains('纪录') ||
        upper.contains('CCTV-9') ||
        upper.contains('CCTV9') ||
        upper.contains('GEO') ||
        upper.contains('DISCOVERY')) {
      schedule = const [
        '自然传奇：地球脉动',
        '航拍中国 · 山河纪实',
        '舌尖上的风味 · 人文探索',
        '大国重器 · 科学前沿',
        '历史秘闻 · 文明密码',
        '寰宇地理 · 深海探秘',
      ];
    } else if (upper.contains('卫视')) {
      schedule = const [
        '早间新闻眼 · 民生直通车',
        '午间精品剧场（连播）',
        '经典生活栏目 · 百姓故事',
        '全省新闻联播 · 晚间报道',
        '黄金档独播热剧（第1集）',
        '王牌综艺盛典 / 晚间剧场',
      ];
    } else {
      schedule = const [
        '早间资讯 · 综合播报',
        '精品日间剧场 · 经典剧集',
        '生活服务 · 时代纪实',
        '黄金剧场 · 精选连播',
        '专题栏目 · 深度视野',
        '晚间影院 · 精彩回放',
      ];
    }

    final slotIndex = (hour * 2 + (minute >= 30 ? 1 : 0)) % schedule.length;
    final nextIndex = (slotIndex + 1) % schedule.length;
    return (
      currentTitle: schedule[slotIndex],
      nextTitle: schedule[nextIndex],
      timeSlot: timeSlot,
      progress: progress.clamp(0.02, 0.98),
    );
  }

  void _handleDigitInput(String digit, List<LiveChannel> activeList) {
    if (activeList.isEmpty) return;
    _digitInputTimer?.cancel();
    setState(() {
      if (_digitInputBuffer.length >= 4) {
        _digitInputBuffer = digit;
      } else {
        _digitInputBuffer += digit;
      }
    });
    _digitInputTimer = Timer(const Duration(milliseconds: 1100), () {
      if (!mounted) return;
      final numVal = int.tryParse(_digitInputBuffer);
      setState(() => _digitInputBuffer = '');
      if (numVal != null && numVal >= 1 && numVal <= activeList.length) {
        _playChannel(activeList[numVal - 1]);
      } else if (numVal != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('频道号 $numVal 超出当前列表范围 (1 - ${activeList.length})'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    });
  }

  Future<void> _recordCurrentLiveStream() async {
    final ch = _currentChannel;
    if (ch == null || _activeStreamUrl.isEmpty) return;
    final now = DateTime.now();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
    final taskName = '直播录制_${ch.name}_$stamp';
    try {
      await widget.appState.api.createDownloadTask(
        url: _activeStreamUrl,
        name: taskName,
        headers: _activeStreamHeaders,
      );
      await widget.appState.refreshDownloadTasks(silent: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('🔴 已启动后台直播录制转存：$taskName')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('启动直播录制失败：$e')),
      );
    }
  }

  void _enterLiveMiniPlayer() {
    final ch = _currentChannel;
    if (ch == null || _activeStreamUrl.isEmpty) return;
    _startupTimer?.cancel();
    _reconnectTimer?.cancel();
    _playSessionId++;
    _hasActivePlayback = false;
    final epg = _getChannelEpgInfo(ch);
    widget.appState.startMiniPlayer(
      MiniPlayerSession(
        title: ch.name,
        subtitle: '${ch.group} · ${epg.currentTitle}',
        streamUrl: _activeStreamUrl,
        headers: _activeStreamHeaders,
        isLive: true,
        liveChannel: ch,
      ),
    );
    _player.stop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已开启「${ch.name}」悬浮小窗，切换其他模块时可继续观看'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _configureLiveNativePlayer([Player? targetPlayer]) async {
    try {
      final dynamic platform = (targetPlayer ?? _player).platform;
      final isMobileOrTv = Platform.isAndroid || Platform.isIOS;
      final props = <String, String>{
        'hwdec': Platform.isAndroid ? 'mediacodec-copy' : 'auto-safe',
        'hwdec-codecs': 'h264,hevc,vp8,vp9,av1',
        'vd-lavc-check-hw-profile': 'yes',
        'vd-lavc-software-fallback': 'yes',
        'vd-lavc-dr': 'yes',
        'vd-lavc-fast': 'yes',
        'cache': 'yes',
        'cache-on-disk': 'no',
        'cache-secs': isMobileOrTv ? '45' : '60',
        'cache-pause': 'yes',
        'cache-pause-initial': 'no',
        'cache-pause-wait': '2.0',
        'demuxer-thread': 'yes',
        'demuxer-max-bytes': isMobileOrTv ? '67108864' : '134217728',
        'demuxer-max-back-bytes': '8388608',
        'demuxer-readahead-secs': isMobileOrTv ? '25' : '40',
        'stream-buffer-size': isMobileOrTv ? '1048576' : '2097152',
        'framedrop': 'vo',
        'vd-lavc-threads': '0',
        'ad-lavc-threads': '0',
        'demuxer-lavf-probesize': '524288',
        'demuxer-lavf-analyzeduration': '2.0',
        'network-timeout': '14',
        'tls-verify': 'no',
        // Never set force-seekable=yes or loop-file=inf on live streams:
        // AndroidVideoController.widListener calls player.seek() on surface resize,
        // which crashes libmpv/MediaCodec when force-seekable is enabled on live streams!
        'keep-open': 'no',
        'loop-playlist': 'inf',
        // Enable FFmpeg/libavformat HTTP stream auto-reconnect
        'stream-lavf-o':
            'reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_on_http_error=4xx,5xx,reconnect_delay_max=3',
        'demuxer-lavf-o':
            'seg_max_retry=10,http_persistent=1,http_multiple=1,allowed_extensions=ALL,protocol_whitelist=file,http,https,httpproxy,tcp,tls,crypto,data,rtp,udp,subfile',
      };
      for (final entry in props.entries) {
        await platform.setProperty(entry.key.trim(), entry.value);
      }
    } catch (_) {}
  }

  Future<void> _applyPlayerStreamHeaders(
    Map<String, String> headers, {
    String? streamUrl,
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
      final proxyUrl = await widget.appState.proxyService
          .resolvePlayerHttpProxyUrl(
        RequestScenario.liveStream,
        streamUri: streamUrl != null ? Uri.tryParse(streamUrl) : null,
      );
      await platform.setProperty('http-proxy', proxyUrl);
    } catch (_) {}
  }

  bool _isNonFatalStreamError(String err) {
    final lower = err.toLowerCase();
    return lower.contains('error while decoding') ||
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
        lower.contains(' cabac ') ||
        lower.contains('deblocking') ||
        lower.contains('pps id out of range');
  }

  String _formatFriendlyPlayError(LiveChannel ch, String rawErr) {
    final currentUrl = ch.urls.isNotEmpty && _currentUrlIndex < ch.urls.length
        ? ch.urls[_currentUrlIndex]
        : '';
    final isIpv6Url =
        currentUrl.contains('[2') || currentUrl.toLowerCase().contains('ipv6');
    if (rawErr.contains('Failed to recognize file format')) {
      if (isIpv6Url) {
        return '当前 IPv6 信号源返回 HTTP 403 或需要专属运营商网络，请切换其他信号或直播源';
      }
      return '当前信号源返回了非视频内容（可能已失效或受防盗链限制）';
    }
    return '当前信号源不可用 ($rawErr)';
  }

  void _tryNextSignalOrReportError(LiveChannel ch, String err) {
    if (!mounted || _currentChannel != ch) return;
    for (var i = 0; i < ch.urls.length; i++) {
      if (!_triedUrlIndices.contains(i)) {
        _playChannel(ch, urlIndex: i, resetTried: false);
        return;
      }
    }
    if (mounted) {
      setState(() {
        _playError = _formatFriendlyPlayError(ch, err);
      });
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onLiveFocusManagerChanged);
    if (widget.appState.activeChildBackHandler == _handleBackPress) {
      widget.appState.activeChildBackHandler = null;
    }
    if (_isLiveFullscreen && (Platform.isAndroid || Platform.isIOS)) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      if (!widget.appState.tvMode) {
        SystemChrome.setPreferredOrientations(const []);
      }
    }
    _liveOsdTimer?.cancel();
    _startupTimer?.cancel();
    _reconnectTimer?.cancel();
    _liveBufferingLagTimer?.cancel();
    _channelOsdTimer?.cancel();
    _digitInputTimer?.cancel();
    _errorSub?.cancel();
    _completedSub?.cancel();
    _widthSub?.cancel();
    _heightSub?.cancel();
    _videoParamsSub?.cancel();
    _posSub?.cancel();
    _bufferingSub?.cancel();
    _playingSub?.cancel();
    _groupScrollController.dispose();
    _playerFocusNode.dispose();
    _liveBottomBarFocusNode.dispose();
    widget.appState.proxyService.removeListener(_onExternalProxyServiceChanged);
    widget.appState.removeListener(_onAppStateNetworkResumeChanged);
    for (final p in _subPlayers.values) {
      p.dispose();
    }
    _subPlayers.clear();
    _subControllers.clear();
    _subChannels.clear();
    _player.dispose();
    super.dispose();
  }

  bool _isBackLogicalKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.browserBack;
  }

  bool _handleBackPress() {
    if (!mounted) return false;
    if (_showFullscreenChannelDrawer) {
      setState(() => _showFullscreenChannelDrawer = false);
      _playerFocusNode.requestFocus();
      return true;
    }
    if (_isLiveFullscreen) {
      if (_liveOsdVisible) {
        _liveOsdTimer?.cancel();
        setState(() => _liveOsdVisible = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _isLiveFullscreen && !_liveOsdVisible) {
            _playerFocusNode.requestFocus();
          }
        });
        return true;
      }
      _toggleLiveFullscreen(forceValue: false);
      return true;
    }
    if (_isMultiViewMode) {
      _toggleMultiViewMode();
      return true;
    }
    if (_channelSearch.isNotEmpty) {
      setState(() => _channelSearch = '');
      return true;
    }
    return false;
  }

  void _toggleMultiViewMode() {
    setState(() {
      _isMultiViewMode = !_isMultiViewMode;
      if (!_isMultiViewMode) {
        _activeMultiViewSlot = 0;
        _player.setVolume(100.0);
        for (final p in _subPlayers.values) {
          p.dispose();
        }
        _subPlayers.clear();
        _subControllers.clear();
        _subChannels.clear();
      } else {
        _syncMultiViewAudioFocus();
      }
    });
  }

  void _selectMultiViewSlot(int slot) {
    setState(() => _activeMultiViewSlot = slot.clamp(0, 3));
    _syncMultiViewAudioFocus();
  }

  void _syncMultiViewAudioFocus() {
    _player.setVolume(_activeMultiViewSlot == 0 ? 100.0 : 0.0);
    for (final entry in _subPlayers.entries) {
      entry.value.setVolume(entry.key == _activeMultiViewSlot ? 100.0 : 0.0);
    }
  }

  Future<void> _playSubSlotChannel(int slot, LiveChannel channel) async {
    final source = widget.appState.selectedLiveSource;
    if (source == null || channel.urls.isEmpty || slot <= 0 || slot > 3) return;

    Player? p = _subPlayers[slot];
    if (p == null) {
      p = Player(
        configuration: const PlayerConfiguration(
          bufferSize: 24 * 1024 * 1024,
        ),
      );
      _subPlayers[slot] = p;
      _subControllers[slot] = VideoController(
        p,
        configuration: VideoControllerConfiguration(
          hwdec: Platform.isAndroid ? 'mediacodec-copy' : null,
          enableHardwareAcceleration: true,
        ),
      );
      unawaited(_configureLiveNativePlayer(p));
    }

    setState(() {
      _subChannels[slot] = channel;
    });
    _syncMultiViewAudioFocus();

    final chKey = _channelKey(channel);
    final prefIdx = _preferredUrlIndexByChannel[chKey] ?? 0;
    final rawUrl = channel.urls[prefIdx.clamp(0, channel.urls.length - 1)];

    try {
      final resolved = await widget.appState.api.resolveLivePlayback(
        source,
        rawUrl,
        channelHeaders: channel.headers,
        preferClientDirect: !_useServerProxy,
      );
      if (!mounted || _subPlayers[slot] != p) return;
      String playUrl = resolved.directUrl.isNotEmpty
          ? resolved.directUrl
          : widget.appState.api.resolveUrl(resolved.serverProxyUrl);
      Map<String, String> headers = resolved.directUrl.isNotEmpty
          ? {...resolved.headers}
          : {...widget.appState.api.authHeaders};
      final relayed = await widget.appState.proxyService.resolveProxiedStreamUrl(
        RequestScenario.liveStream,
        playUrl,
        headers: headers,
      );
      if (!mounted || _subPlayers[slot] != p) return;
      final useRelay = relayed != playUrl && relayed.contains('/__m3u8_proxy__/');
      unawaited(CloudMusicController.stopAllBackgroundAudioForVideo());
      await p.open(
        Media(
          useRelay ? relayed : playUrl,
          httpHeaders: useRelay ? const {} : headers,
        ),
        play: true,
      );
      _syncMultiViewAudioFocus();
    } catch (_) {}
  }

  Future<void> _captureLiveScreenshot() async {
    try {
      final activePlayer = _isMultiViewMode && _activeMultiViewSlot > 0
          ? (_subPlayers[_activeMultiViewSlot] ?? _player)
          : _player;
      final bytes = await activePlayer.screenshot(format: 'image/png');
      if (bytes == null || bytes.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前直播画面暂无法截图')),
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
      final file = File('${targetDir.path}/live_snapshot_$ts.png');
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('📸 直播快照已保存至：${file.path}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('直播截图失败：$e')),
      );
    }
  }

  Future<void> _exportChannelsToM3u(List<LiveChannel> visibleChannels) async {
    final allChannels = widget.appState.liveChannels;
    final favChannels = allChannels
        .where((c) => _favoriteChannelKeys.contains(_channelKey(c)))
        .toList();
    final targetList =
        favChannels.isNotEmpty ? favChannels : visibleChannels;
    if (targetList.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前无可导出的直播频道')),
      );
      return;
    }

    final sb = StringBuffer('#EXTM3U\n');
    for (final ch in targetList) {
      if (ch.urls.isEmpty) continue;
      final prefIdx = _preferredUrlIndexByChannel[_channelKey(ch)] ?? 0;
      final url = ch.urls[prefIdx.clamp(0, ch.urls.length - 1)];
      final grp = ch.group.isEmpty ? '默认分组' : ch.group;
      sb.writeln('#EXTINF:-1 group-title="$grp",${ch.name}');
      sb.writeln(url);
    }

    try {
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          Directory.systemTemp.path;
      final downloadsDir = Directory('$home/Downloads');
      final targetDir =
          await downloadsDir.exists() ? downloadsDir : Directory.systemTemp;
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final suffix = favChannels.isNotEmpty ? 'favorites' : 'channels';
      final file = File('${targetDir.path}/iptv_${suffix}_$ts.m3u');
      await file.writeAsString(sb.toString(), flush: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已导出 ${targetList.length} 个频道 (${favChannels.isNotEmpty ? "我的收藏" : "当前列表"}) 至：${file.path}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出 M3U 失败：$e')),
      );
    }
  }

  void _showChannelOsd(LiveChannel channel) {
    _channelOsdTimer?.cancel();
    if (!mounted) return;
    final grp = channel.group.isEmpty ? '直播' : channel.group;
    final epg = _getChannelEpgInfo(channel);
    setState(() {
      _channelOsdText = '$grp · ${channel.name}  |  正在播出：${epg.currentTitle}';
    });
    _channelOsdTimer = Timer(const Duration(milliseconds: 2800), () {
      if (mounted) {
        setState(() => _channelOsdText = null);
      }
    });
  }

  void _handlePlayerWheelScroll(
    PointerScrollEvent event,
    List<LiveChannel> visibleChannels,
  ) {
    final dy = event.scrollDelta.dy;
    if (dy == 0) return;

    final now = DateTime.now();
    // Reset accumulator if user paused scrolling
    if (now.difference(_lastWheelEventTime).inMilliseconds > 360) {
      _wheelScrollAccumulator = 0.0;
    }
    _lastWheelEventTime = now;

    // Cooldown between consecutive channel switches so trackpad momentum
    // doesn't jump multiple channels on a single flick
    if (now.difference(_lastWheelSwitchTime).inMilliseconds < 280) {
      return;
    }

    _wheelScrollAccumulator += dy;
    if (_wheelScrollAccumulator.abs() < 16.0) {
      return;
    }

    final direction = _wheelScrollAccumulator > 0 ? 1 : -1;
    _wheelScrollAccumulator = 0.0;
    _lastWheelSwitchTime = now;
    _playerFocusNode.requestFocus();

    final list = visibleChannels.isNotEmpty
        ? visibleChannels
        : widget.appState.liveChannels;
    _stepChannel(list, direction);
  }

  Future<void> _playChannel(
    LiveChannel channel, {
    int? urlIndex,
    bool resetTried = true,
    bool isAutoReconnect = false,
  }) async {
    _lastLiveRouteSignature = _computeLiveRouteSignature();
    final source = widget.appState.selectedLiveSource;
    if (source == null || channel.urls.isEmpty) return;

    final chKey = '${channel.group}|${channel.name}';
    final initialIdx =
        urlIndex ?? _preferredUrlIndexByChannel[chKey] ?? 0;
    final safeIdx = initialIdx.clamp(0, channel.urls.length - 1);
    final rawUrl = channel.urls[safeIdx];
    final sessionId = ++_playSessionId;

    _startupTimer?.cancel();
    _reconnectTimer?.cancel();
    if (!isAutoReconnect) {
      unawaited(CloudMusicController.stopAllBackgroundAudioForVideo());
      if (widget.appState.miniPlayerSession != null) {
        widget.appState.closeMiniPlayer();
      }
      _showChannelOsd(channel);
      if (_isLiveFullscreen || !widget.appState.tvMode) {
        _playerFocusNode.requestFocus();
      }
    }

    setState(() {
      _currentChannel = channel;
      _currentUrlIndex = safeIdx;
      if (resetTried) {
        _triedUrlIndices.clear();
        _consecutiveReconnects = 0;
      }
      _triedUrlIndices.add(safeIdx);
      _hasActivePlayback = false;
      _isResolving = !isAutoReconnect;
      _playError = null;
    });

    try {
      final resolved = await widget.appState.api.resolveLivePlayback(
        source,
        rawUrl,
        channelHeaders: channel.headers,
        preferClientDirect: !_useServerProxy,
      );
      if (!mounted || sessionId != _playSessionId) return;

      final forceProxy = _useServerProxy ||
          (resolved.backendProxyPlayback && resolved.directUrl.isEmpty);
      String playUrl = resolved.directUrl;
      Map<String, String> headers = {...resolved.headers};
      String routeLabel = '客户端直连';

      if (forceProxy && resolved.serverProxyUrl.isNotEmpty) {
        playUrl = widget.appState.api.resolveUrl(resolved.serverProxyUrl);
        headers = {...widget.appState.api.authHeaders};
        routeLabel = '服务端代理';
      } else if (playUrl.isEmpty && resolved.serverProxyUrl.isNotEmpty) {
        playUrl = widget.appState.api.resolveUrl(resolved.serverProxyUrl);
        headers = {...widget.appState.api.authHeaders};
        routeLabel = '服务端代理';
      }

      if (playUrl.contains('[2')) {
        routeLabel = '$routeLabel · IPv6';
      }

      String finalPlayUrl = playUrl;
      bool usingStreamRelay = false;
      final relayed = await widget.appState.proxyService.resolveProxiedStreamUrl(
        RequestScenario.liveStream,
        playUrl,
        headers: headers,
      );
      if (!mounted || sessionId != _playSessionId) return;
      if (relayed != playUrl && relayed.contains('/__m3u8_proxy__/')) {
        finalPlayUrl = relayed;
        usingStreamRelay = true;
        if (!relayed.contains('direct=1')) {
          routeLabel = '客户端代理';
        }
      }

      final parsedPlayUri = Uri.tryParse(finalPlayUrl.trim());
      final schemeLower = parsedPlayUri?.scheme.toLowerCase() ?? '';
      const allowedSchemes = {
        'http',
        'https',
        'rtmp',
        'rtmps',
        'rtsp',
        'mms',
        'mmsh',
        'rtp',
        'udp',
      };
      if (finalPlayUrl.trim().isEmpty || !allowedSchemes.contains(schemeLower)) {
        throw Exception('不支持或无效的直播流协议: $schemeLower');
      }

      setState(() {
        _isResolving = false;
        _activeRouteLabel = routeLabel;
        _activeStreamUrl = finalPlayUrl;
        _activeStreamHeaders = headers;
      });

      await _applyPlayerStreamHeaders(headers, streamUrl: finalPlayUrl);
      unawaited(CloudMusicController.stopAllBackgroundAudioForVideo());
      await _player.open(
        Media(
          finalPlayUrl,
          httpHeaders: usingStreamRelay ? const {} : headers,
        ),
        play: true,
      );

      // Concurrently probe the active signal and up to 3 backup signals right at startup
      // when in direct mode (not competing with LocalProxyTunnelBridge relay).
      if (!forceProxy && !usingStreamRelay && channel.urls.length > 1) {
        unawaited(
          _raceChannelSignalsAtStartup(
            channel: channel,
            activeIndex: safeIdx,
            sessionId: sessionId,
          ),
        );
      }

      // Start startup watchdog: if this signal line hangs without producing any
      // video frames or downstream bytes and there are untested backup lines, switch automatically.
      _startupTimer?.cancel();
      final lowerPlayUrl = finalPlayUrl.toLowerCase();
      final lowerRawUrl = rawUrl.toLowerCase();
      final isFlvLiveStream = lowerPlayUrl.contains('.flv') ||
          lowerPlayUrl.contains('douyu') ||
          lowerPlayUrl.contains('huya') ||
          lowerPlayUrl.contains('yy.com') ||
          lowerRawUrl.contains('ottiptv.cc') ||
          lowerRawUrl.contains('/douyu/') ||
          lowerRawUrl.contains('/huya/') ||
          lowerRawUrl.contains('/yy/');
      final watchdogMs = isFlvLiveStream
          ? 14000
          : (usingStreamRelay ? 12000 : 10000);
      _startupTimer = Timer(Duration(milliseconds: watchdogMs), () {
        if (!mounted || sessionId != _playSessionId) return;
        final hasFlow =
            _player.state.position > Duration.zero ||
            (_player.state.width ?? 0) > 0 ||
            _player.state.buffer > Duration.zero ||
            LocalProxyTunnelBridge.recentDownstreamBytesPerSecond > 256;
        if (!_hasActivePlayback && !_isResolving && !hasFlow) {
          _tryNextSignalOrReportError(channel, '连接信号源超时');
        }
      });
    } catch (e) {
      if (!mounted || sessionId != _playSessionId) return;
      setState(() => _isResolving = false);
      _tryNextSignalOrReportError(channel, e.toString());
    }
  }

  Future<void> _raceChannelSignalsAtStartup({
    required LiveChannel channel,
    required int activeIndex,
    required int sessionId,
  }) async {
    try {
      final chKey = '${channel.group}|${channel.name}';
      final candidateIndices = <int>[];
      for (var i = 0; i < channel.urls.length; i++) {
        if (i != activeIndex && !_triedUrlIndices.contains(i)) {
          candidateIndices.add(i);
          if (candidateIndices.length >= 3) break;
        }
      }
      if (candidateIndices.isEmpty) return;

      int? fastestBackupIdx;
      int fastestBackupMs = 999999;

      final backupFuture = Future.wait(
        candidateIndices.map((idx) async {
          try {
            final probe = await widget.appState.api.probeVodStreamPlayableFast(
              channel.urls[idx],
              channel.headers,
              timeout: const Duration(milliseconds: 1800),
            );
            if (probe.ok && probe.latencyMs < fastestBackupMs) {
              fastestBackupMs = probe.latencyMs;
              fastestBackupIdx = idx;
              _preferredUrlIndexByChannel[chKey] = idx;
            }
          } catch (_) {}
        }),
      );

      final primaryProbe = await widget.appState.api.probeVodStreamPlayableFast(
        channel.urls[activeIndex],
        channel.headers,
        timeout: const Duration(milliseconds: 1800),
      );
      if (!mounted || sessionId != _playSessionId || _hasActivePlayback) return;

      if (!primaryProbe.ok) {
        await backupFuture;
        if (!mounted || sessionId != _playSessionId || _hasActivePlayback) return;
        if (fastestBackupIdx != null &&
            !_triedUrlIndices.contains(fastestBackupIdx!)) {
          _playChannel(
            channel,
            urlIndex: fastestBackupIdx,
            resetTried: false,
          );
        }
      }
    } catch (_) {}
  }

  Future<void> _checkVisibleChannelsHealth(List<LiveChannel> channels) async {
    final source = widget.appState.selectedLiveSource;
    if (source == null || _isCheckingHealth || channels.isEmpty) return;

    final targets = channels.take(32).toList();
    if (targets.isEmpty) return;

    setState(() => _isCheckingHealth = true);
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 3200)
      ..badCertificateCallback = (_, __, ___) => true;

    try {
      const batchSize = 8;
      for (var i = 0; i < targets.length; i += batchSize) {
        if (!mounted) break;
        final batch = targets.skip(i).take(batchSize);
        await Future.wait(
          batch.map((ch) async {
            if (ch.urls.isEmpty) return;
            int? bestLatency;
            int? bestIdx;
            final maxLines = ch.urls.length > 3 ? 3 : ch.urls.length;
            for (var uIdx = 0; uIdx < maxLines; uIdx++) {
              final u = ch.urls[uIdx];
              final uri = Uri.tryParse(u);
              if (uri == null || !uri.hasScheme) continue;
              final sw = Stopwatch()..start();
              try {
                final req =
                    await httpClient.getUrl(uri).timeout(const Duration(milliseconds: 3200));
                req.headers.set(
                  'User-Agent',
                  ch.headers['User-Agent'] ?? 'okhttp/3.15',
                );
                req.headers.set('Range', 'bytes=0-511');
                final resp =
                    await req.close().timeout(const Duration(milliseconds: 3200));
                sw.stop();
                final ok = resp.statusCode >= 200 && resp.statusCode < 400;
                try {
                  await resp.drain<void>().timeout(
                        const Duration(milliseconds: 400),
                      );
                } catch (_) {}
                if (ok) {
                  final ms = sw.elapsedMilliseconds.clamp(8, 9999);
                  _healthStatus[u] = true;
                  _latencyMsByUrl[u] = ms;
                  if (bestLatency == null || ms < bestLatency) {
                    bestLatency = ms;
                    bestIdx = uIdx;
                  }
                } else {
                  _healthStatus[u] = false;
                  _latencyMsByUrl[u] = -1;
                }
              } catch (_) {
                sw.stop();
                _healthStatus[u] = false;
                _latencyMsByUrl[u] = -1;
              }
            }
            if (bestIdx != null) {
              _preferredUrlIndexByChannel[_channelKey(ch)] = bestIdx;
            }
          }),
        );
        if (mounted) setState(() {});
      }
    } catch (_) {
      // Ignore health probe error
    } finally {
      httpClient.close(force: true);
      if (mounted) {
        setState(() => _isCheckingHealth = false);
      }
    }
  }

  Future<void> _showAddCustomLiveDialog() async {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    final uaCtrl = TextEditingController(text: 'okhttp/3.15');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VideoPlatformTheme.bgElevated,
        title: const Text(
          '添加自定义直播源 (M3U / TXT)',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: '直播源名称',
                  hintText: '例如：IPTV 精选',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: urlCtrl,
                decoration: const InputDecoration(
                  labelText: '播放列表地址 (M3U / TXT)',
                  hintText: 'https://example.com/iptv.m3u',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: uaCtrl,
                decoration: const InputDecoration(
                  labelText: '自定义 User-Agent (可选)',
                  hintText: 'okhttp/3.15',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('添加并加载'),
          ),
        ],
      ),
    );

    if (confirmed == true && urlCtrl.text.trim().isNotEmpty) {
      setState(() => _selectedGroup = '全部');
      await widget.appState.addCustomLiveSource(
        name: nameCtrl.text,
        url: urlCtrl.text,
        ua: uaCtrl.text,
      );
    }
  }

  void _stepChannel(List<LiveChannel> visibleChannels, int delta) {
    if (visibleChannels.isEmpty) return;
    final cur = _currentChannel;
    if (cur == null) {
      _playChannel(visibleChannels.first);
      return;
    }
    final idx = visibleChannels.indexWhere(
      (c) => c.name == cur.name && c.group == cur.group,
    );
    final nextIdx = idx < 0
        ? 0
        : (idx + delta + visibleChannels.length) % visibleChannels.length;
    _playChannel(visibleChannels[nextIdx]);
  }

  void _stepSignalLine(int delta) {
    final cur = _currentChannel;
    if (cur == null || cur.urls.length <= 1) return;
    final nextIdx =
        (_currentUrlIndex + delta + cur.urls.length) % cur.urls.length;
    _playChannel(cur, urlIndex: nextIdx);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.appState;
    final channels = state.liveChannels;

    final groups = <String>{
      '全部',
      if (_favoriteChannelKeys.isNotEmpty) '⭐ 我的收藏',
    };
    for (final c in channels) {
      if (c.group.isNotEmpty) groups.add(c.group);
    }

    final kw = _channelSearch.trim().toLowerCase();
    final filteredChannels = channels.where((c) {
      final key = _channelKey(c);
      if (_selectedGroup == '⭐ 我的收藏') {
        if (!_favoriteChannelKeys.contains(key)) return false;
      } else if (_selectedGroup != '全部' && c.group != _selectedGroup) {
        return false;
      }
      if (kw.isEmpty) return true;
      return c.name.toLowerCase().contains(kw) ||
          c.group.toLowerCase().contains(kw);
    }).toList();

    if (_isLiveFullscreen && !state.isImmersiveFullscreen) {
      _isLiveFullscreen = false;
      _liveOsdVisible = false;
      _showFullscreenChannelDrawer = false;
    }
    state.activeChildBackHandler = _handleBackPress;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.channelUp): () =>
            _stepChannel(filteredChannels, -1),
        const SingleActivator(LogicalKeyboardKey.pageUp): () =>
            _stepChannel(filteredChannels, -1),
        const SingleActivator(LogicalKeyboardKey.channelDown): () =>
            _stepChannel(filteredChannels, 1),
        const SingleActivator(LogicalKeyboardKey.pageDown): () =>
            _stepChannel(filteredChannels, 1),
        const SingleActivator(LogicalKeyboardKey.mediaPlayPause): () =>
            _player.playOrPause(),
      },
      child: Column(
          children: [
            if (!_isLiveFullscreen)
              FocusTraversalGroup(
                child: _buildTopBar(state, filteredChannels),
              ),
            Expanded(
              key: const ValueKey('live_tv_body_expanded'),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final mqSize = MediaQuery.sizeOf(context);
                  final isPhoneDevice =
                      (Platform.isAndroid || Platform.isIOS) &&
                      !widget.appState.tvMode &&
                      mqSize.shortestSide < 600;
                  final isPhoneLandscape =
                      isPhoneDevice &&
                      constraints.maxWidth > constraints.maxHeight;
                  // Use screen width / 620px threshold so toggling MainShell sidebar on fullscreen
                  // NEVER flips LiveTvScreen between Column and Row layouts!
                  final isDesktop = !isPhoneDevice &&
                      (mqSize.width >= 760 ||
                          constraints.maxWidth >= 620 ||
                          widget.appState.tvMode);
                  if (isDesktop) {
                    final hideSidebar =
                        _isSidebarCollapsed || _isLiveFullscreen;
                    final effectiveSidebarWidth = hideSidebar
                        ? 0.0
                        : _sidebarWidth.clamp(
                            190.0,
                            (constraints.maxWidth * 0.45).clamp(220.0, 480.0),
                          );
                    return Row(
                      children: [
                        SizedBox(
                          key: const ValueKey('live_desktop_sidebar_box'),
                          width: effectiveSidebarWidth,
                          child: hideSidebar
                              ? const SizedBox.shrink()
                              : FocusTraversalGroup(
                                  child: _buildChannelSidebar(
                                    state,
                                    groups.toList(),
                                    filteredChannels,
                                  ),
                                ),
                        ),
                        SizedBox(
                          key: const ValueKey('live_desktop_splitter_box'),
                          width: hideSidebar ? 0.0 : 6.0,
                          child: hideSidebar
                              ? const SizedBox.shrink()
                              : MouseRegion(
                                  cursor: SystemMouseCursors.resizeLeftRight,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onHorizontalDragUpdate: (details) {
                                      setState(() {
                                        final maxW =
                                            (constraints.maxWidth * 0.45)
                                                .clamp(220.0, 480.0);
                                        final next =
                                            _sidebarWidth + details.delta.dx;
                                        if (next < 140) {
                                          _isSidebarCollapsed = true;
                                        } else {
                                          _sidebarWidth =
                                              next.clamp(190.0, maxW);
                                        }
                                      });
                                    },
                                    onDoubleTap: () {
                                      setState(() => _sidebarWidth = 264.0);
                                    },
                                    child: Container(
                                      width: 6,
                                      color: VideoPlatformTheme.borderSubtle,
                                      alignment: Alignment.center,
                                      child: Container(
                                        width: 2,
                                        height: 36,
                                        decoration: BoxDecoration(
                                          color: VideoPlatformTheme.textMuted
                                              .withValues(alpha: 0.5),
                                          borderRadius:
                                              BorderRadius.circular(1),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                        Expanded(
                          key: const ValueKey('live_desktop_player_expanded'),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              KeyedSubtree(
                                key: _livePlayerPanelKey,
                                child: _buildPlayerPanel(
                                  groups: groups.toList(),
                                  visibleChannels: filteredChannels,
                                ),
                              ),
                              // Edge toggle handle to collapse/expand channel list (hidden in fullscreen unless OSD is awake)
                              if (!_isLiveFullscreen)
                                Positioned(
                                  left: 0,
                                  top: 0,
                                  bottom: 48,
                                  child: Center(
                                    child: Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        borderRadius:
                                            const BorderRadius.horizontal(
                                          right: Radius.circular(8),
                                        ),
                                        onFocusChange: (_) {
                                          if (mounted) setState(() {});
                                        },
                                        onTap: () {
                                          setState(
                                            () => _isSidebarCollapsed =
                                                !_isSidebarCollapsed,
                                          );
                                        },
                                        child: Builder(
                                          builder: (ctx) {
                                            final isFocused =
                                                Focus.of(ctx).hasPrimaryFocus;
                                            return Tooltip(
                                              message: _isSidebarCollapsed
                                                  ? '展开频道列表'
                                                  : '收起频道列表',
                                              child: Container(
                                                width: isFocused ? 28 : 22,
                                                height: 60,
                                                decoration: BoxDecoration(
                                                  color: isFocused
                                                      ? VideoPlatformTheme
                                                          .accent
                                                      : VideoPlatformTheme
                                                          .bgElevated
                                                          .withValues(
                                                        alpha: 0.88,
                                                      ),
                                                  borderRadius:
                                                      const BorderRadius
                                                          .horizontal(
                                                    right: Radius.circular(8),
                                                  ),
                                                  border: Border.all(
                                                    color: isFocused
                                                        ? Colors.white
                                                        : VideoPlatformTheme
                                                            .borderStrong,
                                                    width:
                                                        isFocused ? 2.2 : 1.0,
                                                  ),
                                                ),
                                                child: Icon(
                                                  _isSidebarCollapsed
                                                      ? Icons
                                                          .chevron_right_rounded
                                                      : Icons
                                                          .chevron_left_rounded,
                                                  size: 18,
                                                  color: isFocused
                                                      ? Colors.white
                                                      : VideoPlatformTheme
                                                          .textPrimary,
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    );
                  }
                  final double baseLive16x9Height =
                      (constraints.maxWidth * 9 / 16).clamp(280.0, 480.0);
                  final double mobileLiveStageHeight = _isLivePortraitVideo
                      ? (constraints.maxHeight * 0.62).clamp(360.0, 640.0)
                      : math
                          .max(baseLive16x9Height, constraints.maxHeight * 0.48)
                          .clamp(310.0, 560.0);
                  final isMobileFullStage =
                      _isLiveFullscreen || isPhoneLandscape;
                  return Column(
                    children: [
                      SizedBox(
                        key: const ValueKey('live_mobile_player_box'),
                        width: double.infinity,
                        height: isMobileFullStage
                            ? constraints.maxHeight
                            : mobileLiveStageHeight,
                        child: KeyedSubtree(
                          key: _livePlayerPanelKey,
                          child: _buildPlayerPanel(
                            compact: !isMobileFullStage,
                            groups: groups.toList(),
                            visibleChannels: filteredChannels,
                          ),
                        ),
                      ),
                      if (!isMobileFullStage) ...[
                        if (_currentChannel != null)
                          _buildMobileLiveControlStrip(
                            _currentChannel!,
                            filteredChannels,
                          ),
                        Expanded(
                          child: _buildChannelSidebar(
                            state,
                            groups.toList(),
                            filteredChannels,
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      );
    }

  Widget _buildMobileLiveControlStrip(
    LiveChannel ch,
    List<LiveChannel> visibleChannels,
  ) {
    final epg = _getChannelEpgInfo(ch);
    final isFav = _favoriteChannelKeys.contains(_channelKey(ch));
    final activeList = visibleChannels.isNotEmpty
        ? visibleChannels
        : widget.appState.liveChannels;

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        border: Border(
          bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: isFav ? '取消收藏' : '收藏频道',
            onPressed: () => _toggleFavoriteChannel(ch),
            icon: Icon(
              isFav ? Icons.star_rounded : Icons.star_border_rounded,
              size: 19,
              color: isFav
                  ? VideoPlatformTheme.warning
                  : VideoPlatformTheme.textSecondary,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ch.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: VideoPlatformTheme.textPrimary,
                  ),
                ),
                Text(
                  '${epg.timeSlot} ${epg.currentTitle}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: VideoPlatformTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
          // Prev / Next channel buttons
          PlayerVolumeControl(
            player: _player,
            compact: true,
            sliderWidth: 46,
            showPercentage: false,
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            tooltip: '上一频道',
            onPressed: () => _stepChannel(activeList, -1),
            icon: const Icon(Icons.skip_previous_rounded, size: 19),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            tooltip: '下一频道',
            onPressed: () => _stepChannel(activeList, 1),
            icon: const Icon(Icons.skip_next_rounded, size: 19),
          ),
          if (ch.urls.length > 1) ...[
            const SizedBox(width: 4),
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => _playChannel(
                ch,
                urlIndex: (_currentUrlIndex + 1) % ch.urls.length,
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: VideoPlatformTheme.bgCard,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: VideoPlatformTheme.borderSubtle),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.swap_calls_rounded,
                      size: 13,
                      color: VideoPlatformTheme.accent,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      '源${_currentUrlIndex + 1}/${ch.urls.length}',
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
          ],
          const SizedBox(width: 4),
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: _cycleLiveAspectMode,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
              decoration: BoxDecoration(
                color: _liveAspectMode != 'fit'
                    ? VideoPlatformTheme.accent.withValues(alpha: 0.16)
                    : VideoPlatformTheme.bgCard,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _liveAspectMode != 'fit'
                      ? VideoPlatformTheme.accent
                      : VideoPlatformTheme.borderSubtle,
                ),
              ),
              child: Text(
                _liveAspectMode == 'fit'
                    ? '适应'
                    : (_liveAspectMode == 'cover' ? '铺满' : '16:9'),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: _liveAspectMode != 'fit'
                      ? VideoPlatformTheme.accent
                      : VideoPlatformTheme.textSecondary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _toggleLiveFullscreen(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: VideoPlatformTheme.accent.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: VideoPlatformTheme.accent),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.fullscreen_rounded,
                    size: 15,
                    color: VideoPlatformTheme.accent,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    '全屏',
                    style: TextStyle(
                      fontSize: 11,
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
    );
  }

  Widget _buildTopBar(AppState state, List<LiveChannel> visibleChannels) {
    final selectedSource = state.selectedLiveSource;
    final screenW = MediaQuery.sizeOf(context).width;
    final isMobile = screenW < 680 || (screenW < 860 && !state.tvMode);

    if (isMobile) {
      return Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: VideoPlatformTheme.bgElevated,
          border: Border(
            bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.live_tv_rounded,
              size: 18,
              color: VideoPlatformTheme.accent,
            ),
            const SizedBox(width: 6),
            if (state.liveSources.isNotEmpty)
              Flexible(
                child: StatefulBuilder(
                  builder: (srcBoxCtx, setSrcBoxState) {
                    return Focus(
                      canRequestFocus: false,
                      onFocusChange: (_) {
                        if (srcBoxCtx.mounted) setSrcBoxState(() {});
                      },
                      child: Builder(
                        builder: (ctx) {
                          final isFocused = Focus.of(ctx).hasFocus;
                          return DropdownButtonHideUnderline(
                            child: Container(
                              height: 32,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              decoration: BoxDecoration(
                                color: isFocused
                                    ? VideoPlatformTheme.accent
                                        .withValues(alpha: 0.34)
                                    : VideoPlatformTheme.bgCard,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: isFocused
                                      ? const Color(0xFFFFE066)
                                      : VideoPlatformTheme.borderSubtle,
                                  width: isFocused ? 2.2 : 1.0,
                                ),
                              ),
                              child: DropdownButton<LiveSource>(
                                value:
                                    state.liveSources.contains(selectedSource)
                                        ? selectedSource
                                        : state.liveSources.first,
                                isDense: true,
                                isExpanded: false,
                                focusColor: Colors.transparent,
                                dropdownColor: VideoPlatformTheme.bgElevated,
                                iconEnabledColor: isFocused
                                    ? Colors.white
                                    : VideoPlatformTheme.accent,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: isFocused
                                      ? FontWeight.w700
                                      : FontWeight.w600,
                                  color: isFocused
                                      ? Colors.white
                                      : VideoPlatformTheme.textPrimary,
                                ),
                                items: state.liveSources
                                    .map(
                                      (s) => DropdownMenuItem(
                                        value: s,
                                        child: ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            maxWidth: 120,
                                          ),
                                          child: Text(
                                            s.displayName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(() => _selectedGroup = '全部');
                                    state.selectLiveSource(
                                      val,
                                      preferClientDirect: !_useServerProxy,
                                    );
                                  }
                                },
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
              )
            else
              Text(
                '电视直播',
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  color: VideoPlatformTheme.textPrimary,
                ),
              ),
            const Spacer(),
            VideoProxyNodeSelector(
              proxyService: state.proxyService,
              scenario: RequestScenario.liveStream,
              overlayStyle: false,
              compact: true,
              onProxyChanged: (_) {
                final ch = _currentChannel;
                if (ch != null) {
                  _playChannel(
                    ch,
                    urlIndex: _currentUrlIndex,
                    resetTried: false,
                    isAutoReconnect: true,
                  );
                }
              },
            ),
            const SizedBox(width: 4),
            VideoProxyStatsButton(
              proxyService: state.proxyService,
              scenario: RequestScenario.liveStream,
              isShowingStats: _showProxyStatsOverlay,
              overlayStyle: false,
              compact: true,
              onToggle: () {
                setState(() {
                  _showProxyStatsOverlay = !_showProxyStatsOverlay;
                });
              },
            ),
            const SizedBox(width: 4),
            PopupMenuButton<String>(
              tooltip: '更多直播工具',
              icon: const Icon(Icons.more_vert_rounded, size: 20),
              onSelected: (action) {
                switch (action) {
                  case 'add':
                    _showAddCustomLiveDialog();
                    break;
                  case 'health':
                    if (!_isCheckingHealth && visibleChannels.isNotEmpty) {
                      _checkVisibleChannelsHealth(visibleChannels);
                    }
                    break;
                  case 'multiview':
                    _toggleMultiViewMode();
                    break;
                  case 'screenshot':
                    if (_currentChannel != null) {
                      _captureLiveScreenshot();
                    }
                    break;
                  case 'export':
                    if (visibleChannels.isNotEmpty) {
                      _exportChannelsToM3u(visibleChannels);
                    }
                    break;
                  case 'refresh':
                    state.loadLiveSources();
                    break;
                  case 'delete':
                    if (selectedSource != null && selectedSource.isCustom) {
                      state.removeCustomLiveSource(selectedSource);
                    }
                    break;
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'add',
                  child: Row(
                    children: [
                      Icon(Icons.add_link_rounded, size: 17),
                      SizedBox(width: 8),
                      Text('添加 M3U 直播源'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'health',
                  enabled: !_isCheckingHealth && visibleChannels.isNotEmpty,
                  child: Row(
                    children: [
                      const Icon(Icons.network_check_rounded, size: 17),
                      const SizedBox(width: 8),
                      Text(_isCheckingHealth ? '正在检测延迟...' : '检测频道可用性'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'multiview',
                  child: Row(
                    children: [
                      Icon(
                        _isMultiViewMode
                            ? Icons.grid_view_rounded
                            : Icons.grid_on_rounded,
                        size: 17,
                      ),
                      const SizedBox(width: 8),
                      Text(_isMultiViewMode ? '退出四分屏同看' : '开启四分屏同看'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'screenshot',
                  enabled: _currentChannel != null,
                  child: const Row(
                    children: [
                      Icon(Icons.camera_alt_outlined, size: 17),
                      SizedBox(width: 8),
                      Text('直播画面截图'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'export',
                  enabled: visibleChannels.isNotEmpty,
                  child: Row(
                    children: [
                      const Icon(Icons.file_download_outlined, size: 17),
                      const SizedBox(width: 8),
                      Text(
                        _favoriteChannelKeys.isNotEmpty
                            ? '导出收藏 M3U'
                            : '导出频道 M3U',
                      ),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'refresh',
                  child: Row(
                    children: [
                      Icon(Icons.refresh_rounded, size: 17),
                      SizedBox(width: 8),
                      Text('刷新直播源列表'),
                    ],
                  ),
                ),
                if (selectedSource != null && selectedSource.isCustom) ...[
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(
                          Icons.delete_outline,
                          size: 17,
                          color: Color(0xFFEF4444),
                        ),
                        SizedBox(width: 8),
                        Text(
                          '删除此自定义源',
                          style: TextStyle(color: Color(0xFFEF4444)),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      );
    }
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        border: Border(
          bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: _isSidebarCollapsed ? '展开频道列表' : '收起频道列表',
            onPressed: () {
              setState(() => _isSidebarCollapsed = !_isSidebarCollapsed);
            },
            icon: Icon(
              _isSidebarCollapsed
                  ? Icons.menu_open_rounded
                  : Icons.view_sidebar_outlined,
              size: 19,
              color: _isSidebarCollapsed
                  ? VideoPlatformTheme.accent
                  : VideoPlatformTheme.textSecondary,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  Text(
                    '电视直播',
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: VideoPlatformTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (state.liveSources.isNotEmpty)
                    StatefulBuilder(
                      builder: (srcBoxCtx, setSrcBoxState) {
                        return Focus(
                          canRequestFocus: false,
                          onFocusChange: (_) {
                            if (srcBoxCtx.mounted) setSrcBoxState(() {});
                          },
                          child: Builder(
                            builder: (ctx) {
                              final isFocused = Focus.of(ctx).hasFocus;
                              return DropdownButtonHideUnderline(
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 140),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isFocused
                                        ? VideoPlatformTheme.accent
                                            .withValues(alpha: 0.34)
                                        : VideoPlatformTheme.bgCard,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: isFocused
                                          ? const Color(0xFFFFE066)
                                          : VideoPlatformTheme.borderSubtle,
                                      width: isFocused ? 2.4 : 1.0,
                                    ),
                                    boxShadow: isFocused
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
                                  child: DropdownButton<LiveSource>(
                                    value: state.liveSources
                                            .contains(selectedSource)
                                        ? selectedSource
                                        : state.liveSources.first,
                                    isDense: true,
                                    focusColor: Colors.transparent,
                                    dropdownColor:
                                        VideoPlatformTheme.bgElevated,
                                    iconEnabledColor: isFocused
                                        ? Colors.white
                                        : VideoPlatformTheme.accent,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: isFocused
                                          ? FontWeight.w700
                                          : FontWeight.w600,
                                      color: isFocused
                                          ? Colors.white
                                          : VideoPlatformTheme.textPrimary,
                                    ),
                                    items: state.liveSources
                                        .map(
                                          (s) => DropdownMenuItem(
                                            value: s,
                                            child: Text(s.displayName),
                                          ),
                                        )
                                        .toList(),
                                    onChanged: (val) {
                                      if (val != null) {
                                        setState(() => _selectedGroup = '全部');
                                        state.selectLiveSource(
                                          val,
                                          preferClientDirect: !_useServerProxy,
                                        );
                                      }
                                    },
                                  ),
                                ),
                              );
                            },
                          ),
                        );
                      },
                    ),
                  if (selectedSource != null && selectedSource.isCustom) ...[
                    const SizedBox(width: 6),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '删除此自定义直播源',
                      onPressed: () =>
                          state.removeCustomLiveSource(selectedSource),
                      icon: Icon(
                        Icons.delete_outline,
                        size: 18,
                        color: VideoPlatformTheme.danger,
                      ),
                    ),
                  ],
                  const SizedBox(width: 8),
                  VideoProxyNodeSelector(
                    proxyService: state.proxyService,
                    scenario: RequestScenario.liveStream,
                    overlayStyle: false,
                    onProxyChanged: (_) {
                      final ch = _currentChannel;
                      if (ch != null) {
                        _playChannel(
                          ch,
                          urlIndex: _currentUrlIndex,
                          resetTried: false,
                          isAutoReconnect: true,
                        );
                      }
                    },
                  ),
                  const SizedBox(width: 6),
                  VideoProxyStatsButton(
                    proxyService: state.proxyService,
                    scenario: RequestScenario.liveStream,
                    isShowingStats: _showProxyStatsOverlay,
                    overlayStyle: false,
                    onToggle: () {
                      setState(() {
                        _showProxyStatsOverlay = !_showProxyStatsOverlay;
                      });
                    },
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _showAddCustomLiveDialog,
                    icon: const Icon(Icons.add_link_rounded, size: 15),
                    label: const Text('添加直播源'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: visibleChannels.isEmpty
                        ? null
                        : () => _exportChannelsToM3u(visibleChannels),
                    icon: const Icon(Icons.file_download_outlined, size: 15),
                    label: Text(
                      _favoriteChannelKeys.isNotEmpty ? '导出收藏M3U' : '导出M3U',
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _toggleMultiViewMode,
                    style: _isMultiViewMode
                        ? OutlinedButton.styleFrom(
                            backgroundColor: VideoPlatformTheme.accent
                                .withValues(alpha: 0.16),
                            side: BorderSide(color: VideoPlatformTheme.accent),
                          )
                        : null,
                    icon: Icon(
                      _isMultiViewMode
                          ? Icons.grid_view_rounded
                          : Icons.grid_on_rounded,
                      size: 15,
                      color: _isMultiViewMode
                          ? VideoPlatformTheme.accent
                          : VideoPlatformTheme.textSecondary,
                    ),
                    label: Text(
                      _isMultiViewMode
                          ? '退出四分屏 (槽位${_activeMultiViewSlot + 1})'
                          : '四分屏同看',
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed:
                        _currentChannel == null ? null : _captureLiveScreenshot,
                    icon: const Icon(Icons.camera_alt_outlined, size: 15),
                    label: const Text('直播截图'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _isCheckingHealth || visibleChannels.isEmpty
                        ? null
                        : () => _checkVisibleChannelsHealth(visibleChannels),
                    icon: const Icon(Icons.network_check_rounded, size: 15),
                    label: Text(_isCheckingHealth ? '正在测速...' : '检测频道可用性'),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: '刷新直播源',
                    onPressed: state.loadLiveSources,
                    icon: const Icon(Icons.refresh, size: 18),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChannelSidebar(
    AppState state,
    List<String> groups,
    List<LiveChannel> filteredChannels,
  ) {
    if (state.isLoadingLive) {
      return Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: VideoPlatformTheme.accent,
        ),
      );
    }

    if (state.liveError != null && state.liveChannels.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '加载直播源失败：${state.liveError}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: VideoPlatformTheme.textSecondary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: () {
                      final src = state.selectedLiveSource;
                      if (src != null) {
                        state.selectLiveSource(
                          src,
                          preferClientDirect: !_useServerProxy,
                        );
                      } else {
                        state.loadLiveSources();
                      }
                    },
                    icon: const Icon(Icons.refresh, size: 15),
                    label: const Text('重试加载'),
                  ),
                  FilledButton.icon(
                    onPressed: _showAddCustomLiveDialog,
                    icon: const Icon(Icons.add_link_rounded, size: 15),
                    label: const Text('添加 M3U 直播源'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final screenW = MediaQuery.sizeOf(context).width;
    final isMobile = screenW < 680 || (screenW < 860 && !state.tvMode);

    return Container(
      color: VideoPlatformTheme.bgElevated,
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              12,
              isMobile ? 6 : 10,
              12,
              isMobile ? 6 : 8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: (state.tvMode && !isMobile)
                      ? _buildTvChannelSearchButton()
                      : SizedBox(
                          height: isMobile ? 34 : null,
                          child: TextField(
                            onChanged: (v) =>
                                setState(() => _channelSearch = v),
                            style: TextStyle(fontSize: isMobile ? 12.5 : 13),
                            decoration: InputDecoration(
                              isDense: isMobile,
                              hintText: '搜索频道名称（如：CCTV、卫视）...',
                              prefixIcon: Icon(
                                Icons.search,
                                size: isMobile ? 16 : 17,
                                color: VideoPlatformTheme.textMuted,
                              ),
                            ),
                          ),
                        ),
                ),
                if (!isMobile) ...[
                  const SizedBox(width: 6),
                  StatefulBuilder(
                    builder: (ctx, setBtnState) {
                      return InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onFocusChange: (_) {
                          if (ctx.mounted) setBtnState(() {});
                        },
                        onTap: () {
                          setState(() => _isSidebarCollapsed = true);
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) _playerFocusNode.requestFocus();
                          });
                        },
                        child: Builder(
                          builder: (innerCtx) {
                            final isFocused =
                                Focus.of(innerCtx).hasPrimaryFocus;
                            return Container(
                              height: 36,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              decoration: BoxDecoration(
                                color: isFocused
                                    ? VideoPlatformTheme.accent
                                        .withValues(alpha: 0.28)
                                    : VideoPlatformTheme.bgCard,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: isFocused
                                      ? Colors.white
                                      : VideoPlatformTheme.borderSubtle,
                                  width: isFocused ? 2.0 : 1.0,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.chevron_left_rounded,
                                    size: 16,
                                    color: isFocused
                                        ? Colors.white
                                        : VideoPlatformTheme.textSecondary,
                                  ),
                                  Text(
                                    '收起',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: isFocused
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                      color: isFocused
                                          ? Colors.white
                                          : VideoPlatformTheme.textSecondary,
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
                ],
              ],
            ),
          ),
          if (groups.length > 1)
            SizedBox(
              height: 36,
              child: Listener(
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent &&
                      _groupScrollController.hasClients) {
                    final delta = event.scrollDelta.dx != 0
                        ? event.scrollDelta.dx
                        : event.scrollDelta.dy;
                    final pos = _groupScrollController.position;
                    _groupScrollController.jumpTo(
                      (pos.pixels + delta).clamp(0.0, pos.maxScrollExtent),
                    );
                  }
                },
                child: ListView.separated(
                  controller: _groupScrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  scrollDirection: Axis.horizontal,
                  itemCount: groups.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (_, idx) {
                    final g = groups[idx];
                    final selected = g == _selectedGroup;
                    return StatefulBuilder(
                      builder: (chipCtx, setChipState) {
                        return InkWell(
                          borderRadius: BorderRadius.circular(5),
                          onFocusChange: (_) {
                            if (chipCtx.mounted) setChipState(() {});
                          },
                          onTap: () => setState(() => _selectedGroup = g),
                          child: Builder(
                            builder: (ctx) {
                              final isFocused = Focus.of(ctx).hasPrimaryFocus;
                              return Container(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 10),
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
                                  g,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: (selected || isFocused)
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    color: selected
                                        ? Colors.white
                                        : (isFocused
                                            ? VideoPlatformTheme.accent
                                            : VideoPlatformTheme.textSecondary),
                                  ),
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
            ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          Expanded(
            child: filteredChannels.isEmpty
                ? Center(
                    child: Text(
                      '暂无直播频道',
                      style: TextStyle(
                        color: VideoPlatformTheme.textMuted,
                        fontSize: 13,
                      ),
                    ),
                  )
                : _buildCollapsibleGroupedChannelList(filteredChannels),
          ),
        ],
      ),
    );
  }

  Widget _buildTvChannelSearchButton() {
    return Row(
      children: [
        Expanded(
          child: StatefulBuilder(
            builder: (btnCtx, setBtnState) {
              return InkWell(
                borderRadius: BorderRadius.circular(6),
                onFocusChange: (_) {
                  if (btnCtx.mounted) setBtnState(() {});
                },
                onTap: () async {
                  final ctrl = TextEditingController(text: _channelSearch);
                  final res = await showDialog<String>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: VideoPlatformTheme.bgElevated,
                      title: const Text(
                        '搜索直播频道',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      content: SizedBox(
                        width: 360,
                        child: TextField(
                          controller: ctrl,
                          autofocus: true,
                          textInputAction: TextInputAction.search,
                          onSubmitted: (v) => Navigator.of(ctx).pop(v),
                          decoration: const InputDecoration(
                            hintText: '输入频道名（如：CCTV、卫视）...',
                            prefixIcon: Icon(Icons.search_rounded),
                          ),
                        ),
                      ),
                      actions: [
                        if (_channelSearch.isNotEmpty)
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(''),
                            child: const Text('清空'),
                          ),
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(ctx).pop(ctrl.text),
                          child: const Text('确定'),
                        ),
                      ],
                    ),
                  );
                  if (res != null && mounted) {
                    setState(() => _channelSearch = res.trim());
                  }
                },
                child: Builder(
                  builder: (ctx) {
                    final isFocused = Focus.of(ctx).hasPrimaryFocus;
                    return Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: isFocused
                            ? VideoPlatformTheme.accent.withValues(alpha: 0.24)
                            : VideoPlatformTheme.bgInput,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: isFocused
                              ? VideoPlatformTheme.accent
                              : VideoPlatformTheme.borderSubtle,
                          width: isFocused ? 2.0 : 1.0,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.search_rounded,
                            size: 16,
                            color: isFocused
                                ? VideoPlatformTheme.accent
                                : VideoPlatformTheme.textMuted,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _channelSearch.isEmpty
                                  ? '按遥控器 OK 键搜索频道...'
                                  : '筛选: $_channelSearch',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: _channelSearch.isNotEmpty
                                    ? VideoPlatformTheme.accent
                                    : VideoPlatformTheme.textMuted,
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
        if (_channelSearch.isNotEmpty) ...[
          const SizedBox(width: 4),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.clear_rounded, size: 16),
            onPressed: () => setState(() => _channelSearch = ''),
          ),
        ],
      ],
    );
  }

  Widget _buildCollapsibleGroupedChannelList(
    List<LiveChannel> filteredChannels,
  ) {
    // Build global 1-based channel number map
    final channelNumberByKey = <String, int>{};
    for (var i = 0; i < filteredChannels.length; i++) {
      channelNumberByKey[_channelKey(filteredChannels[i])] = i + 1;
    }

    // Group channels by group name while preserving order, pinning Favorites at top when viewing '全部'
    final groupedMap = <String, List<LiveChannel>>{};
    if (_selectedGroup == '全部' && _channelSearch.trim().isEmpty) {
      final favList = filteredChannels
          .where((c) => _favoriteChannelKeys.contains(_channelKey(c)))
          .toList();
      if (favList.isNotEmpty) {
        groupedMap['⭐ 我的收藏'] = favList;
      }
    }

    for (final ch in filteredChannels) {
      final gName = _selectedGroup == '⭐ 我的收藏'
          ? '⭐ 我的收藏'
          : (ch.group.isEmpty ? '默认分组' : ch.group);
      groupedMap.putIfAbsent(gName, () => []).add(ch);
    }
    final groupEntries = groupedMap.entries.toList();

    final allCollapsed = groupEntries.isNotEmpty &&
        groupEntries.every((e) => _collapsedGroups.contains(e.key));

    // Flatten groups + visible channels into a single virtualized list so ListView.builder
    // only builds visible rows instead of instantiating hundreds of channels per group at once.
    final flatItems = <({
      bool isHeader,
      String groupName,
      int groupCount,
      bool isCollapsed,
      bool hasPlayingChannel,
      LiveChannel? channel,
    })>[];

    for (final entry in groupEntries) {
      final gName = entry.key;
      final gChannels = entry.value;
      final collapsed = _collapsedGroups.contains(gName);
      final hasPlaying = gChannels.any(
        (c) =>
            _currentChannel?.name == c.name &&
            _currentChannel?.group == c.group,
      );
      flatItems.add((
        isHeader: true,
        groupName: gName,
        groupCount: gChannels.length,
        isCollapsed: collapsed,
        hasPlayingChannel: hasPlaying,
        channel: null,
      ));
      if (!collapsed) {
        for (final ch in gChannels) {
          flatItems.add((
            isHeader: false,
            groupName: gName,
            groupCount: 0,
            isCollapsed: false,
            hasPlayingChannel: false,
            channel: ch,
          ));
        }
      }
    }

    return Column(
      children: [
        if (groupEntries.length > 1)
          Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: VideoPlatformTheme.bgCard.withValues(alpha: 0.5),
              border: Border(
                bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
              ),
            ),
            child: Row(
              children: [
                Text(
                  '共 ${groupEntries.length} 个分组 · ${filteredChannels.length} 个频道',
                  style: TextStyle(
                    fontSize: 11,
                    color: VideoPlatformTheme.textMuted,
                  ),
                ),
                const Spacer(),
                StatefulBuilder(
                  builder: (colCtx, setColState) {
                    return InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onFocusChange: (_) {
                        if (colCtx.mounted) setColState(() {});
                      },
                      onTap: () {
                        setState(() {
                          if (allCollapsed) {
                            _collapsedGroups.clear();
                          } else {
                            _collapsedGroups.addAll(
                              groupEntries.map((e) => e.key),
                            );
                          }
                        });
                      },
                      child: Builder(
                        builder: (ctx) {
                          final isFocused = Focus.of(ctx).hasPrimaryFocus;
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: isFocused
                                  ? VideoPlatformTheme.accent
                                      .withValues(alpha: 0.34)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(4),
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
                                Icon(
                                  allCollapsed
                                      ? Icons.unfold_more_rounded
                                      : Icons.unfold_less_rounded,
                                  size: 14,
                                  color: isFocused
                                      ? Colors.white
                                      : VideoPlatformTheme.accent,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  allCollapsed ? '展开全部分组' : '折叠全部分组',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: isFocused
                                        ? FontWeight.w700
                                        : FontWeight.w500,
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
              ],
            ),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: flatItems.length,
            itemBuilder: (_, itemIdx) {
              final item = flatItems[itemIdx];
              if (item.isHeader) {
                final groupName = item.groupName;
                final isCollapsed = item.isCollapsed;
                final hasPlayingChannel = item.hasPlayingChannel;
                return StatefulBuilder(
                  builder: (hdrStateCtx, setHdrState) {
                    return InkWell(
                      onFocusChange: (_) {
                        if (hdrStateCtx.mounted) setHdrState(() {});
                      },
                      onTap: () {
                        setState(() {
                          if (isCollapsed) {
                            _collapsedGroups.remove(groupName);
                          } else {
                            _collapsedGroups.add(groupName);
                          }
                        });
                      },
                      child: Builder(
                        builder: (hdrCtx) {
                          final isHdrFocused =
                              Focus.of(hdrCtx).hasPrimaryFocus;
                          return Container(
                            height: 36,
                            padding:
                                const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: isHdrFocused
                                  ? VideoPlatformTheme.accent
                                      .withValues(alpha: 0.25)
                                  : (hasPlayingChannel
                                      ? VideoPlatformTheme.accent
                                          .withValues(alpha: 0.08)
                                      : VideoPlatformTheme.bgCard
                                          .withValues(alpha: 0.65)),
                              border: Border(
                                top: isHdrFocused
                                    ? BorderSide(
                                        color: VideoPlatformTheme.accent,
                                        width: 2.0,
                                      )
                                    : BorderSide.none,
                                bottom: BorderSide(
                                  color: isHdrFocused
                                      ? VideoPlatformTheme.accent
                                      : VideoPlatformTheme.borderSubtle,
                                  width: isHdrFocused ? 2.0 : 1.0,
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  isCollapsed
                                      ? Icons.keyboard_arrow_right_rounded
                                      : Icons.keyboard_arrow_down_rounded,
                                  size: 18,
                                  color: (hasPlayingChannel || isHdrFocused)
                                      ? VideoPlatformTheme.accent
                                      : VideoPlatformTheme.textSecondary,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    groupName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                      color: (hasPlayingChannel || isHdrFocused)
                                          ? VideoPlatformTheme.accent
                                          : VideoPlatformTheme.textPrimary,
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 1.5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: VideoPlatformTheme.bgElevated,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: VideoPlatformTheme.borderSubtle,
                                    ),
                                  ),
                                  child: Text(
                                    '${item.groupCount}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: VideoPlatformTheme.textMuted,
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
                );
              }

              final ch = item.channel!;
              final isSelected = _currentChannel?.name == ch.name &&
                  _currentChannel?.group == ch.group;
              final chKey = _channelKey(ch);
              final prefIdx = _preferredUrlIndexByChannel[chKey] ?? 0;
              final primaryUrl = ch.urls.isNotEmpty
                  ? ch.urls[prefIdx.clamp(0, ch.urls.length - 1)]
                  : '';
              final health = _healthStatus[primaryUrl];
              final latencyMs = _latencyMsByUrl[primaryUrl];
              final isFav = _favoriteChannelKeys.contains(chKey);
              final chNum = channelNumberByKey[chKey] ?? 0;
              final epg = _getChannelEpgInfo(ch);

              return StatefulBuilder(
                builder: (rowStateCtx, setRowState) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InkWell(
                        onFocusChange: (_) {
                          if (rowStateCtx.mounted) setRowState(() {});
                        },
                        onTap: () {
                          if (_isMultiViewMode && _activeMultiViewSlot > 0) {
                            _playSubSlotChannel(_activeMultiViewSlot, ch);
                          } else {
                            _playChannel(ch);
                          }
                        },
                        child: Builder(
                          builder: (rowCtx) {
                            final isRowFocused =
                                Focus.of(rowCtx).hasPrimaryFocus;
                            return Container(
                              padding:
                                  const EdgeInsets.fromLTRB(10, 6, 6, 6),
                              decoration: BoxDecoration(
                                color: isRowFocused
                                    ? VideoPlatformTheme.accent
                                        .withValues(alpha: 0.28)
                                    : (isSelected
                                        ? VideoPlatformTheme.accent
                                            .withValues(alpha: 0.14)
                                        : Colors.transparent),
                                border: Border.all(
                                  color: isRowFocused
                                      ? const Color(0xFFFFE066)
                                      : (isSelected
                                          ? VideoPlatformTheme.accent
                                              .withValues(alpha: 0.5)
                                          : Colors.transparent),
                                  width: isRowFocused ? 2.2 : 1.0,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 7,
                                        height: 7,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: health == null
                                              ? VideoPlatformTheme.borderStrong
                                              : (health
                                                  ? VideoPlatformTheme.success
                                                  : VideoPlatformTheme.danger),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        chNum.toString().padLeft(3, '0'),
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontFamily: 'monospace',
                                          color: (isSelected || isRowFocused)
                                              ? VideoPlatformTheme.accent
                                              : VideoPlatformTheme.textMuted,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                ch.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  color: isRowFocused
                                                      ? Colors.white
                                                      : (isSelected
                                                          ? VideoPlatformTheme
                                                              .accent
                                                          : VideoPlatformTheme
                                                              .textPrimary),
                                                  fontWeight: (isSelected ||
                                                          isRowFocused)
                                                      ? FontWeight.w700
                                                      : FontWeight.w400,
                                                ),
                                              ),
                                            ),
                                            if (latencyMs != null) ...[
                                              const SizedBox(width: 4),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 5,
                                                  vertical: 1,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: (latencyMs < 0
                                                          ? VideoPlatformTheme
                                                              .danger
                                                          : (latencyMs < 260
                                                              ? VideoPlatformTheme
                                                                  .success
                                                              : VideoPlatformTheme
                                                                  .warning))
                                                      .withValues(alpha: 0.15),
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  latencyMs < 0
                                                      ? '超时'
                                                      : '${latencyMs}ms',
                                                  style: TextStyle(
                                                    fontSize: 9.5,
                                                    fontWeight: FontWeight.w600,
                                                    color: latencyMs < 0
                                                        ? VideoPlatformTheme
                                                            .danger
                                                        : (latencyMs < 260
                                                            ? VideoPlatformTheme
                                                                .success
                                                            : VideoPlatformTheme
                                                                .warning),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '正在播出: ${epg.currentTitle}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: (isSelected || isRowFocused)
                                                ? VideoPlatformTheme
                                                    .textSecondary
                                                : VideoPlatformTheme.textMuted,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(2),
                                          child: LinearProgressIndicator(
                                            value: epg.progress,
                                            minHeight: 2,
                                            backgroundColor: VideoPlatformTheme
                                                .borderSubtle
                                                .withValues(alpha: 0.5),
                                            valueColor:
                                                AlwaysStoppedAnimation<Color>(
                                              (isSelected || isRowFocused)
                                                  ? VideoPlatformTheme.accent
                                                  : VideoPlatformTheme.textMuted
                                                      .withValues(alpha: 0.6),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  ExcludeFocus(
                                    excluding: widget.appState.tvMode,
                                    child: IconButton(
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                        minWidth: 28,
                                        minHeight: 28,
                                      ),
                                      tooltip: isFav ? '取消收藏频道' : '收藏频道',
                                      onPressed: () =>
                                          _toggleFavoriteChannel(ch),
                                      icon: Icon(
                                        isFav
                                            ? Icons.star_rounded
                                            : Icons.star_border_rounded,
                                        size: 17,
                                        color: isFav
                                            ? VideoPlatformTheme.warning
                                            : VideoPlatformTheme.textMuted,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                      const Divider(height: 1),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPlayerPanel({
    bool compact = false,
    List<String> groups = const [],
    List<LiveChannel> visibleChannels = const [],
  }) {
    final ch = _currentChannel;
    final activeList = visibleChannels.isNotEmpty
        ? visibleChannels
        : widget.appState.liveChannels;

    return Focus(
      focusNode: _playerFocusNode,
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      onKeyEvent: (node, event) {
        if (_isBackLogicalKey(event.logicalKey)) {
          return KeyEventResult.ignored;
        }
        if (!node.hasPrimaryFocus) {
          if (_isLiveFullscreen &&
              event is KeyDownEvent &&
              !_showFullscreenChannelDrawer) {
            _pokeLiveOsd();
          }
          return KeyEventResult.ignored;
        }
        if (event is KeyDownEvent) {
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.select ||
              key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.numpadEnter ||
              key == LogicalKeyboardKey.gameButtonA) {
            if (!_isLiveFullscreen) {
              _toggleLiveFullscreen(forceValue: true);
            } else {
              setState(() {
                _showFullscreenChannelDrawer = !_showFullscreenChannelDrawer;
                _liveOsdVisible = _showFullscreenChannelDrawer;
              });
              if (_showFullscreenChannelDrawer) {
                _liveOsdTimer?.cancel();
              }
            }
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowUp) {
            _stepChannel(activeList, -1);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowDown) {
            _stepChannel(activeList, 1);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowLeft) {
            if (_isLiveFullscreen) {
              setState(() {
                _showFullscreenChannelDrawer = true;
                _liveOsdVisible = true;
              });
              _liveOsdTimer?.cancel();
              return KeyEventResult.handled;
            } else {
              if (_isSidebarCollapsed) {
                setState(() => _isSidebarCollapsed = false);
              }
              node.focusInDirection(TraversalDirection.left);
              return KeyEventResult.handled;
            }
          }
          if (key == LogicalKeyboardKey.arrowRight) {
            if (_isLiveFullscreen) {
              _pokeLiveOsd(focusBottomBar: true);
              return KeyEventResult.handled;
            } else {
              _stepSignalLine(1);
              return KeyEventResult.handled;
            }
          }
          final char = event.character;
          if (char != null &&
              char.length == 1 &&
              char.codeUnitAt(0) >= 48 &&
              char.codeUnitAt(0) <= 57) {
            _handleDigitInput(char, activeList);
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        onEnter: (_) {
          // Defer focus request out of MouseTracker._deviceUpdatePhase
          // so mouse wheel and up/down keys switch channels without triggering '!_debugDuringDeviceUpdate'
          if (!_playerFocusNode.hasFocus && !_showFullscreenChannelDrawer) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted &&
                  !_playerFocusNode.hasFocus &&
                  !_showFullscreenChannelDrawer) {
                _playerFocusNode.requestFocus();
              }
            });
          }
        },
        onHover: (_) {
          if (_isLiveFullscreen && !_showFullscreenChannelDrawer) {
            _pokeLiveOsd();
          }
        },
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) {
            if (_isLiveFullscreen && !_showFullscreenChannelDrawer) {
              _pokeLiveOsd();
            }
            if (!_playerFocusNode.hasFocus && !_showFullscreenChannelDrawer) {
              _playerFocusNode.requestFocus();
            }
          },
          onPointerSignal: (event) {
            if (event is PointerScrollEvent && !_showFullscreenChannelDrawer) {
              _handlePlayerWheelScroll(event, activeList);
            }
          },
          child: Container(
            color: Colors.black,
            child: Column(
              children: [
                Expanded(
                  child: _isMultiViewMode
                      ? _buildMultiView2x2Grid(activeList)
                      : Stack(
                          fit: StackFit.expand,
                          children: [
                            LayoutBuilder(
                              builder: (context, stageConstraints) {
                                final liveFit = _liveAspectMode == 'cover'
                                    ? BoxFit.cover
                                    : BoxFit.contain;
                                final liveAspect = _liveAspectMode == '16:9'
                                    ? 16 / 9
                                    : (_liveVideoWidth > 0 &&
                                            _liveVideoHeight > 0
                                        ? _liveVideoWidth / _liveVideoHeight
                                        : null);
                                return Video(
                                  key: _liveVideoWidgetKey,
                                  controller: _videoController,
                                  width: stageConstraints.maxWidth,
                                  height: stageConstraints.maxHeight,
                                  fit: liveFit,
                                  aspectRatio: liveAspect,
                                  fill: Colors.black,
                                  controls: NoVideoControls,
                                  pauseUponEnteringBackgroundMode: false,
                                  resumeUponEnteringForegroundMode: true,
                                );
                              },
                            ),
                            // Top-left OSD banner when switching channels via wheel/keys
                            if (_channelOsdText != null)
                              Positioned(
                                top: 16,
                                left: 28,
                                child: IgnorePointer(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xCC0D1824),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: VideoPlatformTheme.accent
                                            .withValues(alpha: 0.65),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.live_tv_rounded,
                                          size: 16,
                                          color: VideoPlatformTheme.accent,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          _channelOsdText!,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Text(
                                          _isLiveFullscreen
                                              ? '上下键换台 · OK/左键频道单 · 右键控制栏'
                                              : '上下键换台 · OK键全屏 · 左键频道栏',
                                          style: const TextStyle(
                                            color: Colors.white60,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            // Floating movable / hideable / closable download speed tag on Live TV stage
                            if (ch != null && _digitInputBuffer.isEmpty)
                              Positioned(
                                top: (!compact &&
                                        (!_isLiveFullscreen || _liveOsdVisible))
                                    ? 56
                                    : 10,
                                right: 14,
                                child: VideoDownloadSpeedBadge(
                                  player: _player,
                                  compact: true,
                                ),
                              ),
                            // Top-right proxy selector + real-time download speed HUD + volume + Fullscreen button
                            if (ch != null &&
                                !compact &&
                                _digitInputBuffer.isEmpty &&
                                (!_isLiveFullscreen || _liveOsdVisible))
                              Positioned(
                                top: 14,
                                right: 18,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    VideoProxyNodeSelector(
                                      proxyService:
                                          widget.appState.proxyService,
                                      scenario: RequestScenario.liveStream,
                                      overlayStyle: true,
                                      onProxyChanged: (msg) {
                                        _channelOsdTimer?.cancel();
                                        setState(() {
                                          _channelOsdText = msg;
                                          _useServerProxy = widget.appState
                                                  .proxyService
                                                  .resolveEffectiveRoute(
                                                      RequestScenario
                                                          .liveStream) ==
                                              ScenarioRouteMode.serverRelay;
                                          _playError = null;
                                        });
                                        _channelOsdTimer = Timer(
                                          const Duration(seconds: 3),
                                          () {
                                            if (mounted) {
                                              setState(
                                                () => _channelOsdText = null,
                                              );
                                            }
                                          },
                                        );
                                        _playChannel(
                                          ch,
                                          urlIndex: _currentUrlIndex,
                                          resetTried: false,
                                          isAutoReconnect: false,
                                        );
                                      },
                                    ),
                                    const SizedBox(width: 8),
                                    VideoProxyStatsButton(
                                      proxyService:
                                          widget.appState.proxyService,
                                      scenario: RequestScenario.liveStream,
                                      isShowingStats: _showProxyStatsOverlay,
                                      overlayStyle: true,
                                      onToggle: () {
                                        setState(() {
                                          _showProxyStatsOverlay =
                                              !_showProxyStatsOverlay;
                                        });
                                      },
                                    ),
                                    const SizedBox(width: 8),
                                    PlayerVolumeControl(
                                      player: _player,
                                      compact: true,
                                      overlayStyle: true,
                                      sliderWidth: 68,
                                    ),
                                    const SizedBox(width: 8),
                                    StatefulBuilder(
                                      builder: (aspCtx, setAspState) {
                                        return InkWell(
                                          borderRadius:
                                              BorderRadius.circular(18),
                                          onFocusChange: (_) {
                                            if (aspCtx.mounted) {
                                              setAspState(() {});
                                            }
                                          },
                                          onTap: _cycleLiveAspectMode,
                                          child: Builder(
                                            builder: (ctx) {
                                              final isFocused =
                                                  Focus.of(ctx).hasPrimaryFocus;
                                              return Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 10,
                                                  vertical: 5,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: isFocused
                                                      ? VideoPlatformTheme
                                                          .accent
                                                      : const Color(0xBB090E14),
                                                  borderRadius:
                                                      BorderRadius.circular(18),
                                                  border: Border.all(
                                                    color: isFocused
                                                        ? const Color(0xFFFFE066)
                                                        : (_liveAspectMode !=
                                                                'fit'
                                                            ? VideoPlatformTheme
                                                                .accent
                                                            : Colors.white24),
                                                    width:
                                                        isFocused ? 2.2 : 1.0,
                                                  ),
                                                ),
                                                child: Text(
                                                  _liveAspectMode == 'fit'
                                                      ? '比例:适应'
                                                      : (_liveAspectMode ==
                                                              'cover'
                                                          ? '比例:铺满'
                                                          : '比例:16:9'),
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 11.5,
                                                    fontWeight: isFocused
                                                        ? FontWeight.w700
                                                        : FontWeight.w600,
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        );
                                      },
                                    ),
                                    if ((Platform.isAndroid ||
                                            Platform.isIOS) &&
                                        !widget.appState.tvMode) ...[
                                      const SizedBox(width: 8),
                                      InkWell(
                                        borderRadius: BorderRadius.circular(18),
                                        onTap: _toggleLiveOrientation,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xBB090E14),
                                            borderRadius:
                                                BorderRadius.circular(18),
                                            border: Border.all(
                                              color: Colors.white24,
                                            ),
                                          ),
                                          child: const Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.screen_rotation_rounded,
                                                size: 14,
                                                color: Colors.white,
                                              ),
                                              SizedBox(width: 4),
                                              Text(
                                                '横竖屏',
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 11.5,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                    const SizedBox(width: 8),
                                    StatefulBuilder(
                                      builder: (fsBtnCtx, setFsBtnState) {
                                        return InkWell(
                                          borderRadius:
                                              BorderRadius.circular(18),
                                          onFocusChange: (_) {
                                            if (fsBtnCtx.mounted) {
                                              setFsBtnState(() {});
                                            }
                                          },
                                          onTap: () => _toggleLiveFullscreen(),
                                          child: Builder(
                                            builder: (ctx) {
                                              final isFocused =
                                                  Focus.of(ctx).hasPrimaryFocus;
                                              return Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 10,
                                                  vertical: 5,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: isFocused
                                                      ? VideoPlatformTheme
                                                          .accent
                                                      : const Color(0xBB090E14),
                                                  borderRadius:
                                                      BorderRadius.circular(18),
                                                  border: Border.all(
                                                    color: isFocused
                                                        ? Colors.white
                                                        : VideoPlatformTheme
                                                            .accent,
                                                    width:
                                                        isFocused ? 2.2 : 1.0,
                                                  ),
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Icon(
                                                      _isLiveFullscreen
                                                          ? Icons
                                                              .fullscreen_exit_rounded
                                                          : Icons
                                                              .fullscreen_rounded,
                                                      size: 15,
                                                      color: isFocused
                                                          ? Colors.white
                                                          : VideoPlatformTheme
                                                              .accent,
                                                    ),
                                                    const SizedBox(width: 4),
                                                    Text(
                                                      _isLiveFullscreen
                                                          ? '退出全屏'
                                                          : '全屏放大',
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 11.5,
                                                        fontWeight:
                                                            FontWeight.w600,
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
                                  ],
                                ),
                              ),
                            // Top-right TV number pad channel jump OSD
                            if (_digitInputBuffer.isNotEmpty)
                              Positioned(
                                top: 16,
                                right: 24,
                                child: IgnorePointer(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xDD0D1824),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: VideoPlatformTheme.accent,
                                        width: 1.5,
                                      ),
                                    ),
                                    child: Text(
                                      'CH ${_digitInputBuffer.padLeft(3, '0')}',
                                      style: TextStyle(
                                        color: VideoPlatformTheme.accent,
                                        fontSize: 22,
                                        fontFamily: 'monospace',
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 1.5,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            if (ch == null)
                              Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.live_tv_rounded,
                                      size: 46,
                                      color: VideoPlatformTheme.textMuted,
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      '请从左侧列表选择要观看的直播频道（客户端原生直连，无跨域限制）',
                                      style: TextStyle(
                                        color: VideoPlatformTheme.textSecondary,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            if (ch != null &&
                                _playError == null &&
                                (_isResolving || !_hasActivePlayback))
                              IgnorePointer(
                                child: Center(
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 24,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                      vertical: 16,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xD80A111A),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: VideoPlatformTheme.accent
                                            .withValues(alpha: 0.45),
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
                                          _isResolving
                                              ? '正在解析直播频道信号源...'
                                              : (_activeRouteLabel == '客户端代理'
                                                  ? '正在通过代理加速连接直播信号源，加载画面...'
                                                  : '正在连接直播信号源，加载首帧画面...'),
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
                                          crossAxisAlignment:
                                              WrapCrossAlignment.center,
                                          children: [
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 8,
                                                vertical: 3,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Colors.white
                                                    .withValues(alpha: 0.08),
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                              child: Text(
                                                '${ch.name} · 信号源 ${_currentUrlIndex + 1}/${ch.urls.length}',
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 11.5,
                                                ),
                                              ),
                                            ),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 8,
                                                vertical: 3,
                                              ),
                                              decoration: BoxDecoration(
                                                color: VideoPlatformTheme.accent
                                                    .withValues(alpha: 0.16),
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                              child: Text(
                                                _activeRouteLabel == '客户端代理'
                                                    ? '代理: ${widget.appState.proxyService.resolveNodeForScenario(RequestScenario.liveStream)?.displayTitle ?? "加速节点"}'
                                                    : '通道: $_activeRouteLabel',
                                                style: TextStyle(
                                                  color:
                                                      VideoPlatformTheme.accent,
                                                  fontSize: 11.5,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                            VideoDownloadSpeedBadge(
                                              player: _player,
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            if (_playError != null && !_isResolving)
                              Container(
                                color: const Color(0xCC000000),
                                padding: const EdgeInsets.all(20),
                                alignment: Alignment.center,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '播放失败：$_playError',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: VideoPlatformTheme.textPrimary,
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Wrap(
                                      spacing: 10,
                                      runSpacing: 8,
                                      alignment: WrapAlignment.center,
                                      children: [
                                        if (ch != null && ch.urls.length > 1)
                                          FilledButton(
                                            onPressed: () => _playChannel(
                                              ch,
                                              urlIndex: (_currentUrlIndex + 1) %
                                                  ch.urls.length,
                                            ),
                                            child: const Text('切换备用信号源'),
                                          ),
                                        if (ch != null)
                                          OutlinedButton(
                                            onPressed: () {
                                              setState(() => _useServerProxy =
                                                  !_useServerProxy);
                                              _playChannel(
                                                ch,
                                                urlIndex: _currentUrlIndex,
                                              );
                                            },
                                            child: Text(
                                              _useServerProxy
                                                  ? '切换为客户端直连'
                                                  : '改用服务端代理重试',
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            // Fullscreen Translucent Channel Overlay Drawer (OK / Left Arrow in Fullscreen)
                            if (_isLiveFullscreen &&
                                _showFullscreenChannelDrawer) ...[
                              Positioned.fill(
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    setState(() {
                                      _showFullscreenChannelDrawer = false;
                                      _liveOsdVisible = false;
                                    });
                                    _playerFocusNode.requestFocus();
                                  },
                                  child: Container(color: Colors.black38),
                                ),
                              ),
                              _buildFullscreenChannelOverlayDrawer(
                                groups: groups,
                                filteredChannels: activeList,
                              ),
                            ],
                            // Fullscreen Auto-Hiding Bottom Control Bar (wakes on Right Arrow / Mouse Move)
                            if (_isLiveFullscreen &&
                                _liveOsdVisible &&
                                !_showFullscreenChannelDrawer &&
                                ch != null)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: _buildLiveBottomControlBar(
                                  ch,
                                  activeList,
                                  overlayMode: true,
                                ),
                              ),
                            if (_showProxyStatsOverlay)
                              VideoProxyStatsDetailPanel(
                                proxyService: widget.appState.proxyService,
                                scenario: RequestScenario.liveStream,
                                onClose: () {
                                  if (mounted) {
                                    setState(
                                      () => _showProxyStatsOverlay = false,
                                    );
                                  }
                                },
                              ),
                          ],
                        ),
                ),
                if (!_isLiveFullscreen && !compact && ch != null)
                  _buildLiveBottomControlBar(
                    ch,
                    activeList,
                    overlayMode: false,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFullscreenChannelOverlayDrawer({
    required List<String> groups,
    required List<LiveChannel> filteredChannels,
  }) {
    return Positioned(
      top: 0,
      bottom: 0,
      left: 0,
      width: 430,
      child: FocusScope(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.escape ||
                  event.logicalKey == LogicalKeyboardKey.goBack)) {
            setState(() {
              _showFullscreenChannelDrawer = false;
              _liveOsdVisible = false;
            });
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _playerFocusNode.requestFocus();
            });
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xE80A1019),
            border: Border(
              right: BorderSide(
                color: VideoPlatformTheme.accent.withValues(alpha: 0.55),
                width: 1.5,
              ),
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0xAA000000),
                blurRadius: 24,
                offset: Offset(6, 0),
              ),
            ],
          ),
          child: Column(
            children: [
              // Drawer header
              Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F1824),
                  border: Border(
                    bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.live_tv_rounded,
                      size: 18,
                      color: VideoPlatformTheme.accent,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        '快速换台 · OK选台 / 返回关闭',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (widget.appState.liveSources.length > 1)
                      StatefulBuilder(
                        builder: (srcBtnCtx, setSrcBtnState) {
                          return InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onFocusChange: (_) {
                              if (srcBtnCtx.mounted) setSrcBtnState(() {});
                            },
                            onTap: () {
                              final sources = widget.appState.liveSources;
                              final cur = widget.appState.selectedLiveSource;
                              final curIdx =
                                  cur != null ? sources.indexOf(cur) : 0;
                              final nextSrc =
                                  sources[(curIdx + 1) % sources.length];
                              setState(() => _selectedGroup = '全部');
                              widget.appState.selectLiveSource(
                                nextSrc,
                                preferClientDirect: !_useServerProxy,
                              );
                            },
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
                                        : const Color(0xFF1A2636),
                                    borderRadius: BorderRadius.circular(6),
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
                                      Icon(
                                        Icons.swap_horiz_rounded,
                                        size: 14,
                                        color: isFocused
                                            ? Colors.white
                                            : VideoPlatformTheme.accent,
                                      ),
                                      const SizedBox(width: 4),
                                      ConstrainedBox(
                                        constraints:
                                            const BoxConstraints(maxWidth: 96),
                                        child: Text(
                                          widget.appState.selectedLiveSource
                                                  ?.displayName ??
                                              '换直播源',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w600,
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
                    const SizedBox(width: 4),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '关闭频道抽屉',
                      onPressed: () {
                        setState(() {
                          _showFullscreenChannelDrawer = false;
                          _liveOsdVisible = false;
                        });
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) _playerFocusNode.requestFocus();
                        });
                      },
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    // Left column: Groups
                    Container(
                      width: 132,
                      decoration: BoxDecoration(
                        color: const Color(0xCC070C12),
                        border: Border(
                          right: BorderSide(
                            color: VideoPlatformTheme.borderSubtle,
                          ),
                        ),
                      ),
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        itemCount: groups.length,
                        itemExtent: 40,
                        itemBuilder: (_, idx) {
                          final g = groups[idx];
                          final selected = g == _selectedGroup;
                          return StatefulBuilder(
                            builder: (grpCtx, setGrpState) {
                              return InkWell(
                                onFocusChange: (_) {
                                  if (grpCtx.mounted) setGrpState(() {});
                                },
                                onTap: () => setState(() => _selectedGroup = g),
                                child: Builder(
                                  builder: (ctx) {
                                    final isFocused =
                                        Focus.of(ctx).hasPrimaryFocus;
                                    return Container(
                                      height: 40,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                      ),
                                      alignment: Alignment.centerLeft,
                                      decoration: BoxDecoration(
                                        color: isFocused
                                            ? VideoPlatformTheme.accent
                                                .withValues(alpha: 0.32)
                                            : (selected
                                                ? VideoPlatformTheme.accent
                                                    .withValues(alpha: 0.18)
                                                : Colors.transparent),
                                        border: Border.all(
                                          color: isFocused
                                              ? const Color(0xFFFFE066)
                                              : (selected
                                                  ? VideoPlatformTheme.accent
                                                  : Colors.transparent),
                                          width: isFocused ? 2.0 : 1.0,
                                        ),
                                      ),
                                      child: Text(
                                        g,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          fontWeight: (selected || isFocused)
                                              ? FontWeight.w700
                                              : FontWeight.w400,
                                          color: isFocused
                                              ? Colors.white
                                              : (selected
                                                  ? VideoPlatformTheme.accent
                                                  : VideoPlatformTheme
                                                      .textSecondary),
                                        ),
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
                    // Right column: Channels in selected group
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        itemCount: filteredChannels.length,
                        itemExtent: 54,
                        itemBuilder: (_, idx) {
                          final ch = filteredChannels[idx];
                          final isPlaying = _currentChannel?.name == ch.name &&
                              _currentChannel?.group == ch.group;
                          final epg = _getChannelEpgInfo(ch);
                          return StatefulBuilder(
                            builder: (chItemCtx, setChItemState) {
                              return InkWell(
                                autofocus: isPlaying,
                                onFocusChange: (_) {
                                  if (chItemCtx.mounted) setChItemState(() {});
                                },
                                onTap: () {
                                  _playChannel(ch);
                                  setState(() {
                                    _showFullscreenChannelDrawer = false;
                                    _liveOsdVisible = false;
                                  });
                                  WidgetsBinding.instance
                                      .addPostFrameCallback((_) {
                                    if (mounted) {
                                      _playerFocusNode.requestFocus();
                                    }
                                  });
                                },
                                child: Builder(
                                  builder: (ctx) {
                                    final isFocused =
                                        Focus.of(ctx).hasPrimaryFocus;
                                    return Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isFocused
                                            ? VideoPlatformTheme.accent
                                                .withValues(alpha: 0.30)
                                            : (isPlaying
                                                ? VideoPlatformTheme.accent
                                                    .withValues(alpha: 0.14)
                                                : Colors.transparent),
                                        border: Border.all(
                                          color: isFocused
                                              ? const Color(0xFFFFE066)
                                              : (isPlaying
                                                  ? VideoPlatformTheme.accent
                                                      .withValues(alpha: 0.5)
                                                  : Colors.transparent),
                                          width: isFocused ? 2.2 : 1.0,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Text(
                                            (idx + 1)
                                                .toString()
                                                .padLeft(3, '0'),
                                            style: TextStyle(
                                              fontSize: 11.5,
                                              fontFamily: 'monospace',
                                              fontWeight: FontWeight.w700,
                                              color: (isPlaying || isFocused)
                                                  ? VideoPlatformTheme.accent
                                                  : VideoPlatformTheme
                                                      .textMuted,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  ch.name,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 13.5,
                                                    fontWeight: (isPlaying ||
                                                            isFocused)
                                                        ? FontWeight.w700
                                                        : FontWeight.w500,
                                                    color: isFocused
                                                        ? Colors.white
                                                        : (isPlaying
                                                            ? VideoPlatformTheme
                                                                .accent
                                                            : Colors.white),
                                                  ),
                                                ),
                                                const SizedBox(height: 1),
                                                Text(
                                                  epg.currentTitle,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: Colors.white
                                                        .withValues(
                                                            alpha: 0.65),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (isPlaying)
                                            Icon(
                                              Icons.equalizer_rounded,
                                              size: 16,
                                              color: VideoPlatformTheme.accent,
                                            ),
                                        ],
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
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLiveBottomControlBar(
    LiveChannel ch,
    List<LiveChannel> activeList, {
    required bool overlayMode,
  }) {
    final epg = _getChannelEpgInfo(ch);
    final isFav = _favoriteChannelKeys.contains(_channelKey(ch));
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: overlayMode
            ? const Color(0xDF0A1018)
            : VideoPlatformTheme.bgElevated,
        border: Border(
          top: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            focusNode: overlayMode ? _liveBottomBarFocusNode : null,
            visualDensity: VisualDensity.compact,
            tooltip: isFav ? '取消收藏此频道' : '收藏此频道',
            onPressed: () {
              if (overlayMode) _pokeLiveOsd();
              _toggleFavoriteChannel(ch);
            },
            icon: Icon(
              isFav ? Icons.star_rounded : Icons.star_border_rounded,
              size: 19,
              color: isFav
                  ? VideoPlatformTheme.warning
                  : VideoPlatformTheme.textSecondary,
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width < 680 ? 118 : 240,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ch.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: VideoPlatformTheme.textPrimary,
                  ),
                ),
                Text(
                  '${epg.timeSlot} ${epg.currentTitle}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: VideoPlatformTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          PlayerVolumeControl(
            player: _player,
            compact: true,
            overlayStyle: overlayMode,
            sliderWidth: MediaQuery.sizeOf(context).width < 880 ? 58 : 78,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (ch.urls.length > 1)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: List.generate(ch.urls.length, (idx) {
                          final active = idx == _currentUrlIndex;
                          final lineUrl = ch.urls[idx];
                          final isIpv6Line = lineUrl.contains('[2') ||
                              lineUrl.toLowerCase().contains('ipv6');
                          final lat = _latencyMsByUrl[lineUrl];
                          return Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: StatefulBuilder(
                              builder: (lineCtx, setLineState) {
                                return InkWell(
                                  borderRadius: BorderRadius.circular(4),
                                  onFocusChange: (_) {
                                    if (overlayMode) _pokeLiveOsd();
                                    if (lineCtx.mounted) setLineState(() {});
                                  },
                                  onTap: () {
                                    if (overlayMode) _pokeLiveOsd();
                                    _playChannel(ch, urlIndex: idx);
                                  },
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
                                          color: active
                                              ? VideoPlatformTheme.accent
                                              : (isFocused
                                                  ? VideoPlatformTheme.accent
                                                      .withValues(alpha: 0.28)
                                                  : VideoPlatformTheme.bgCard),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                          border: Border.all(
                                            color: isFocused
                                                ? Colors.white
                                                : (active
                                                    ? VideoPlatformTheme.accent
                                                    : Colors.transparent),
                                            width: isFocused ? 2.0 : 1.0,
                                          ),
                                        ),
                                        child: Text(
                                          [
                                            '信号 ${idx + 1}',
                                            if (isIpv6Line) 'IPv6',
                                            if (lat != null && lat > 0)
                                              '${lat}ms',
                                          ].join('·'),
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: (active || isFocused)
                                                ? FontWeight.w700
                                                : FontWeight.w400,
                                            color: (active || isFocused)
                                                ? Colors.white
                                                : VideoPlatformTheme
                                                    .textSecondary,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                );
                              },
                            ),
                          );
                        }),
                      ),
                    if (overlayMode)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: OutlinedButton.icon(
                          onPressed: () {
                            setState(() {
                              _showFullscreenChannelDrawer = true;
                              _liveOsdVisible = true;
                            });
                            _liveOsdTimer?.cancel();
                          },
                          icon: const Icon(Icons.list_alt_rounded, size: 15),
                          label: const Text('选台'),
                        ),
                      ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '上一频道 (遥控器上键 / CH▲)',
                      onPressed: () {
                        if (overlayMode) _pokeLiveOsd();
                        _stepChannel(activeList, -1);
                      },
                      icon: const Icon(Icons.skip_previous_rounded, size: 18),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '下一频道 (遥控器下键 / CH▼)',
                      onPressed: () {
                        if (overlayMode) _pokeLiveOsd();
                        _stepChannel(activeList, 1);
                      },
                      icon: const Icon(Icons.skip_next_rounded, size: 18),
                    ),
                    if (ch.urls.length > 1)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '切换备用信号源',
                        onPressed: () {
                          if (overlayMode) _pokeLiveOsd();
                          _stepSignalLine(1);
                        },
                        icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                      ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '🔴 录制当前直播流到下载队列',
                      onPressed: _activeStreamUrl.isEmpty
                          ? null
                          : () {
                              if (overlayMode) _pokeLiveOsd();
                              _recordCurrentLiveStream();
                            },
                      icon: Icon(
                        Icons.fiber_manual_record_rounded,
                        size: 18,
                        color: VideoPlatformTheme.danger,
                      ),
                    ),
                    if (!overlayMode)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '小窗悬浮播放（切换其他页面不中断直播）',
                        onPressed: _activeStreamUrl.isEmpty
                            ? null
                            : _enterLiveMiniPlayer,
                        icon: const Icon(
                          Icons.picture_in_picture_alt_rounded,
                          size: 18,
                        ),
                      ),
                    PopupMenuButton<String>(
                      tooltip: 'Apple TV 隔空播放 / 外部 TV 播放器',
                      icon: const Icon(Icons.cast_connected_rounded, size: 18),
                      onSelected: (action) async {
                        final lineUrl = ch.urls.isNotEmpty
                            ? ch.urls[
                                _currentUrlIndex.clamp(0, ch.urls.length - 1)]
                            : '';
                        if (action == 'airplay') {
                          final messenger = ScaffoldMessenger.of(context);
                          final ok = await TvPlatformService.showAirPlayPicker();
                          if (!ok && mounted) {
                            messenger.showSnackBar(
                              const SnackBar(
                                content: Text(
                                  '当前系统环境不支持原生 AirPlay 弹窗，请使用系统控制中心或外部 TV 播放器',
                                ),
                              ),
                            );
                          }
                        } else if (lineUrl.isNotEmpty) {
                          await TvPlatformService.openInTvExternalPlayer(
                            lineUrl,
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
                                Text('投屏至 Apple TV (AirPlay 2)'),
                              ],
                            ),
                          ),
                        const PopupMenuItem(
                          value: 'infuse',
                          child: Row(
                            children: [
                              Icon(
                                Icons.play_circle_outline_rounded,
                                size: 17,
                              ),
                              SizedBox(width: 8),
                              Text('使用 Apple TV / iOS Infuse 打开'),
                            ],
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'vlc',
                          child: Row(
                            children: [
                              Icon(Icons.smart_display_outlined, size: 17),
                              SizedBox(width: 8),
                              Text('使用 Android TV / Apple TV VLC 打开'),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 6),
                    VideoProxyNodeSelector(
                      proxyService: widget.appState.proxyService,
                      scenario: RequestScenario.liveStream,
                      overlayStyle: overlayMode,
                      compact: true,
                      onProxyChanged: (_) {
                        if (overlayMode) _pokeLiveOsd();
                        _playChannel(
                          ch,
                          urlIndex: _currentUrlIndex,
                          resetTried: false,
                          isAutoReconnect: true,
                        );
                      },
                    ),
                    const SizedBox(width: 6),
                    VideoProxyStatsButton(
                      proxyService: widget.appState.proxyService,
                      scenario: RequestScenario.liveStream,
                      isShowingStats: _showProxyStatsOverlay,
                      overlayStyle: overlayMode,
                      compact: true,
                      onToggle: () {
                        if (overlayMode) _pokeLiveOsd();
                        setState(() {
                          _showProxyStatsOverlay = !_showProxyStatsOverlay;
                        });
                      },
                    ),
                    const SizedBox(width: 6),
                    OutlinedButton.icon(
                      onPressed: () {
                        if (overlayMode) _pokeLiveOsd();
                        setState(() => _useServerProxy = !_useServerProxy);
                        _playChannel(ch, urlIndex: _currentUrlIndex);
                      },
                      icon: Icon(
                        _useServerProxy
                            ? Icons.dns_rounded
                            : Icons.bolt_rounded,
                        size: 15,
                      ),
                      label: Text(_activeRouteLabel),
                    ),
                    const SizedBox(width: 6),
                    FilledButton.tonalIcon(
                      onPressed: () => _toggleLiveFullscreen(),
                      icon: Icon(
                        _isLiveFullscreen
                            ? Icons.fullscreen_exit_rounded
                            : Icons.fullscreen_rounded,
                        size: 17,
                        color: VideoPlatformTheme.accent,
                      ),
                      label: Text(_isLiveFullscreen ? '退出全屏' : '全屏放大'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMultiView2x2Grid(List<LiveChannel> activeList) {
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildMultiViewCell(0, activeList)),
              Expanded(child: _buildMultiViewCell(1, activeList)),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildMultiViewCell(2, activeList)),
              Expanded(child: _buildMultiViewCell(3, activeList)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMultiViewCell(int slot, List<LiveChannel> activeList) {
    final isSelected = _activeMultiViewSlot == slot;
    final ch = slot == 0 ? _currentChannel : _subChannels[slot];
    final controller = slot == 0 ? _videoController : _subControllers[slot];

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _selectMultiViewSlot(slot),
      onDoubleTap: () {
        if (ch != null) {
          final target = ch;
          _toggleMultiViewMode();
          if (slot > 0) {
            _playChannel(target);
          }
        }
      },
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: Colors.black,
          border: Border.all(
            color: isSelected
                ? VideoPlatformTheme.accent
                : VideoPlatformTheme.borderSubtle,
            width: isSelected ? 2.0 : 1.0,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (controller != null && ch != null)
              Video(
                controller: controller,
                fill: Colors.black,
                controls: NoVideoControls,
              )
            else
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.add_to_queue_rounded,
                      size: 28,
                      color: isSelected
                          ? VideoPlatformTheme.accent
                          : VideoPlatformTheme.textMuted,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      isSelected
                          ? '画面 ${slot + 1} 已选中 · 请点击左侧频道列表投放到此窗口'
                          : '点击选中画面 ${slot + 1} 后从左侧选择频道',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: isSelected
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xBB0D1824),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: isSelected
                            ? VideoPlatformTheme.accent
                            : Colors.white24,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isSelected
                              ? Icons.volume_up_rounded
                              : Icons.volume_off_rounded,
                          size: 13,
                          color: isSelected
                              ? VideoPlatformTheme.accent
                              : Colors.white60,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          ch != null
                              ? '${slot + 1}. ${ch.name}'
                              : '画面 ${slot + 1} (空闲)',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  if (ch != null && _subPlayers[slot] != null) ...[
                    VideoDownloadSpeedBadge(
                      player: _subPlayers[slot]!,
                      compact: true,
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (ch != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0x99000000),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        '双击全屏',
                        style: TextStyle(color: Colors.white70, fontSize: 10),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
