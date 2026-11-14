import 'dart:async';
import 'dart:io';

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
import '../widgets/video_download_speed_badge.dart';
import '../widgets/video_proxy_node_selector.dart';

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
  StreamSubscription<Duration>? _posSub;
  Timer? _startupTimer;
  Timer? _reconnectTimer;

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
  double _sidebarWidth = 340.0;
  final Set<String> _collapsedGroups = {};

  // Player focus, mouse wheel channel switching & number pad channel jump state
  final FocusNode _playerFocusNode = FocusNode(debugLabel: 'LivePlayerStage');
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

  @override
  void initState() {
    super.initState();
    _player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 64 * 1024 * 1024,
      ),
    );
    _videoController = VideoController(_player);
    _configureLiveNativePlayer();

    _widthSub = _player.stream.width.listen((w) {
      if ((w ?? 0) > 0 && mounted && !_isResolving) {
        _hasActivePlayback = true;
        _consecutiveReconnects = 0;
        _startupTimer?.cancel();
        final ch = _currentChannel;
        if (ch != null) {
          _preferredUrlIndexByChannel['${ch.group}|${ch.name}'] =
              _currentUrlIndex;
        }
        if (_playError != null) {
          setState(() => _playError = null);
        }
      }
    });

    _posSub = _player.stream.position.listen((pos) {
      if (pos >= const Duration(seconds: 1) && mounted && !_isResolving) {
        _hasActivePlayback = true;
        _consecutiveReconnects = 0;
        _startupTimer?.cancel();
      }
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

  Future<void> _configureLiveNativePlayer() async {
    try {
      final dynamic platform = _player.platform;
      final props = <String, String>{
        'cache': 'yes',
        'cache-on-disk': 'no',
        'cache-secs': '20',
        'cache-pause-initial': 'no',
        'cache-pause-wait': '0.1',
        'demuxer-thread': 'yes',
        'demuxer-max-bytes': '67108864',
        'demuxer-max-back-bytes': '16777216',
        'demuxer-readahead-secs': '12',
        'vd-lavc-threads': '0',
        'ad-lavc-threads': '0',
        // Fast stream probe for sub-second first frame display
        'demuxer-lavf-probesize': '262144',
        'demuxer-lavf-analyzeduration': '0',
        'network-timeout': '8',
        'tls-verify': 'no',
        // Prevent libmpv from pausing permanently at temporary live stream EOF
        'keep-open': 'no',
        'loop-file': 'inf',
        'loop-playlist': 'inf',
        'force-seekable': 'yes',
        'hr-seek-framedrop': 'yes',
        // Enable FFmpeg/libavformat HTTP stream auto-reconnect
        'stream-lavf-o':
            'reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_on_http_error=4xx,5xx,reconnect_delay_max=5',
        // Enable HTTP persistent keep-alive and pipelining
        'demuxer-lavf-o':
            'seg_max_retry=10,live_start_index=-1,http_persistent=1,http_multiple=1,strict=experimental,allowed_extensions=ALL',
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
    _startupTimer?.cancel();
    _reconnectTimer?.cancel();
    _channelOsdTimer?.cancel();
    _digitInputTimer?.cancel();
    _errorSub?.cancel();
    _completedSub?.cancel();
    _widthSub?.cancel();
    _posSub?.cancel();
    _groupScrollController.dispose();
    _playerFocusNode.dispose();
    for (final p in _subPlayers.values) {
      p.dispose();
    }
    _subPlayers.clear();
    _subControllers.clear();
    _subChannels.clear();
    _player.dispose();
    super.dispose();
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
          bufferSize: 32 * 1024 * 1024,
        ),
      );
      _subPlayers[slot] = p;
      _subControllers[slot] = VideoController(p);
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
      await p.open(Media(playUrl, httpHeaders: headers), play: true);
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
      if (widget.appState.miniPlayerSession != null) {
        widget.appState.closeMiniPlayer();
      }
      _showChannelOsd(channel);
      _playerFocusNode.requestFocus();
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

      final forceProxy = _useServerProxy || resolved.backendProxyPlayback;
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
      if (!forceProxy) {
        final relayed = await widget.appState.proxyService.resolveProxiedStreamUrl(
          RequestScenario.liveStream,
          playUrl,
          headers: headers,
        );
        if (!mounted || sessionId != _playSessionId) return;
        if (relayed != playUrl && relayed.contains('/__m3u8_proxy__/')) {
          finalPlayUrl = relayed;
          usingStreamRelay = true;
          routeLabel = '客户端代理';
        }
      }

      setState(() {
        _isResolving = false;
        _activeRouteLabel = routeLabel;
        _activeStreamUrl = finalPlayUrl;
        _activeStreamHeaders = headers;
      });

      await _applyPlayerStreamHeaders(headers, streamUrl: finalPlayUrl);
      await _player.open(
        Media(
          finalPlayUrl,
          httpHeaders: usingStreamRelay ? const {} : headers,
        ),
        play: true,
      );

      // Concurrently probe the active signal and up to 3 backup signals right at startup:
      // if the active signal fails HTTP probe while a backup signal responds fast, switch immediately!
      if (!forceProxy && channel.urls.length > 1) {
        unawaited(
          _raceChannelSignalsAtStartup(
            channel: channel,
            activeIndex: safeIdx,
            sessionId: sessionId,
          ),
        );
      }

      // Start a 3.2-second fast watchdog: if this signal line hangs without
      // producing any video frames and there are untested backup lines, switch automatically.
      _startupTimer?.cancel();
      _startupTimer = Timer(const Duration(milliseconds: 3200), () {
        if (!mounted || sessionId != _playSessionId) return;
        if (!_hasActivePlayback && !_isResolving) {
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
          _buildTopBar(state, filteredChannels),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isDesktop = constraints.maxWidth >= 900;
              if (isDesktop) {
                return Row(
                  children: [
                    if (!_isSidebarCollapsed) ...[
                      SizedBox(
                        width: _sidebarWidth.clamp(
                          220.0,
                          (constraints.maxWidth * 0.55).clamp(260.0, 580.0),
                        ),
                        child: _buildChannelSidebar(
                          state,
                          groups.toList(),
                          filteredChannels,
                        ),
                      ),
                      // Draggable resize splitter + quick collapse handle
                      MouseRegion(
                        cursor: SystemMouseCursors.resizeLeftRight,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragUpdate: (details) {
                            setState(() {
                              final maxW = (constraints.maxWidth * 0.55)
                                  .clamp(260.0, 580.0);
                              final next = _sidebarWidth + details.delta.dx;
                              if (next < 150) {
                                _isSidebarCollapsed = true;
                              } else {
                                _sidebarWidth = next.clamp(220.0, maxW);
                              }
                            });
                          },
                          onDoubleTap: () {
                            setState(() => _sidebarWidth = 340.0);
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
                                borderRadius: BorderRadius.circular(1),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                    Expanded(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _buildPlayerPanel(
                            visibleChannels: filteredChannels,
                          ),
                          // Edge toggle handle to collapse/expand channel list
                          Positioned(
                            left: 0,
                            top: 0,
                            bottom: 48,
                            child: Center(
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: const BorderRadius.horizontal(
                                    right: Radius.circular(8),
                                  ),
                                  onTap: () {
                                    setState(
                                      () => _isSidebarCollapsed =
                                          !_isSidebarCollapsed,
                                    );
                                  },
                                  child: Tooltip(
                                    message: _isSidebarCollapsed
                                        ? '展开频道列表'
                                        : '收起频道列表',
                                    child: Container(
                                      width: 22,
                                      height: 56,
                                      decoration: BoxDecoration(
                                        color: VideoPlatformTheme.bgElevated
                                            .withValues(alpha: 0.88),
                                        borderRadius:
                                            const BorderRadius.horizontal(
                                          right: Radius.circular(8),
                                        ),
                                        border: Border.all(
                                          color:
                                              VideoPlatformTheme.borderStrong,
                                        ),
                                      ),
                                      child: Icon(
                                        _isSidebarCollapsed
                                            ? Icons.chevron_right_rounded
                                            : Icons.chevron_left_rounded,
                                        size: 18,
                                        color: VideoPlatformTheme.textPrimary,
                                      ),
                                    ),
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
              return Column(
                children: [
                  if (_isSidebarCollapsed)
                    Expanded(
                      child: _buildPlayerPanel(
                        compact: false,
                        visibleChannels: filteredChannels,
                      ),
                    )
                  else ...[
                    AspectRatio(
                      aspectRatio: 16 / 9,
                      child: _buildPlayerPanel(
                        compact: true,
                        visibleChannels: filteredChannels,
                      ),
                    ),
                    const Divider(height: 1),
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

  Widget _buildTopBar(AppState state, List<LiveChannel> visibleChannels) {
    final selectedSource = state.selectedLiveSource;
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        border: Border(
          bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: Row(
        children: [
          IconButton(
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
          Text(
            '电视直播',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: VideoPlatformTheme.textPrimary,
            ),
          ),
          const SizedBox(width: 16),
          if (state.liveSources.isNotEmpty)
            DropdownButtonHideUnderline(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: VideoPlatformTheme.bgCard,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: VideoPlatformTheme.borderSubtle),
                ),
                child: DropdownButton<LiveSource>(
                  value: state.liveSources.contains(selectedSource)
                      ? selectedSource
                      : state.liveSources.first,
                  isDense: true,
                  dropdownColor: VideoPlatformTheme.bgElevated,
                  style: TextStyle(
                    fontSize: 13,
                    color: VideoPlatformTheme.textPrimary,
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
            ),
          if (selectedSource != null && selectedSource.isCustom) ...[
            const SizedBox(width: 6),
            IconButton(
              tooltip: '删除此自定义直播源',
              onPressed: () => state.removeCustomLiveSource(selectedSource),
              icon: Icon(
                Icons.delete_outline,
                size: 18,
                color: VideoPlatformTheme.danger,
              ),
            ),
          ],
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
                    backgroundColor:
                        VideoPlatformTheme.accent.withValues(alpha: 0.16),
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
          const Spacer(),
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
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _currentChannel == null ? null : _captureLiveScreenshot,
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
          const SizedBox(width: 8),
          IconButton(
            tooltip: '刷新直播源',
            onPressed: state.loadLiveSources,
            icon: const Icon(Icons.refresh, size: 18),
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

    return Container(
      color: VideoPlatformTheme.bgElevated,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: TextField(
              onChanged: (v) => setState(() => _channelSearch = v),
              decoration: InputDecoration(
                hintText: '搜索频道名称（如：CCTV、卫视）...',
                prefixIcon: Icon(
                  Icons.search,
                  size: 17,
                  color: VideoPlatformTheme.textMuted,
                ),
              ),
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
                    return InkWell(
                      borderRadius: BorderRadius.circular(5),
                      onTap: () => setState(() => _selectedGroup = g),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: selected
                              ? VideoPlatformTheme.accent
                              : VideoPlatformTheme.bgCard,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          g,
                          style: TextStyle(
                            fontSize: 12,
                            color: selected
                                ? Colors.white
                                : VideoPlatformTheme.textSecondary,
                          ),
                        ),
                      ),
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

    // If only 1 group is visible (e.g. a specific category chip is selected)
    // still show its collapsible header so the user can collapse/expand it.
    final allCollapsed = groupEntries.isNotEmpty &&
        groupEntries.every((e) => _collapsedGroups.contains(e.key));

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
                InkWell(
                  borderRadius: BorderRadius.circular(4),
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
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          allCollapsed
                              ? Icons.unfold_more_rounded
                              : Icons.unfold_less_rounded,
                          size: 14,
                          color: VideoPlatformTheme.accent,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          allCollapsed ? '展开全部分组' : '折叠全部分组',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
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
        Expanded(
          child: ListView.builder(
            itemCount: groupEntries.length,
            itemBuilder: (_, gIdx) {
              final entry = groupEntries[gIdx];
              final groupName = entry.key;
              final groupChannels = entry.value;
              final isCollapsed = _collapsedGroups.contains(groupName);
              final hasPlayingChannel = groupChannels.any(
                (c) =>
                    _currentChannel?.name == c.name &&
                    _currentChannel?.group == c.group,
              );

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Collapsible Group Header
                  InkWell(
                    onTap: () {
                      setState(() {
                        if (isCollapsed) {
                          _collapsedGroups.remove(groupName);
                        } else {
                          _collapsedGroups.add(groupName);
                        }
                      });
                    },
                    child: Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: hasPlayingChannel
                            ? VideoPlatformTheme.accent.withValues(alpha: 0.08)
                            : VideoPlatformTheme.bgCard.withValues(alpha: 0.65),
                        border: Border(
                          bottom: BorderSide(
                            color: VideoPlatformTheme.borderSubtle,
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
                            color: hasPlayingChannel
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
                                color: hasPlayingChannel
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
                              '${groupChannels.length}',
                              style: TextStyle(
                                fontSize: 11,
                                color: VideoPlatformTheme.textMuted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Channels inside this group (hidden when collapsed)
                  if (!isCollapsed)
                    ...groupChannels.map((ch) {
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

                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ListTile(
                            dense: true,
                            contentPadding:
                                const EdgeInsets.fromLTRB(10, 2, 6, 2),
                            selected: isSelected,
                            selectedTileColor: VideoPlatformTheme.accent
                                .withValues(alpha: 0.14),
                            leading: Row(
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
                                    color: isSelected
                                        ? VideoPlatformTheme.accent
                                        : VideoPlatformTheme.textMuted,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    ch.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: isSelected
                                          ? VideoPlatformTheme.accent
                                          : VideoPlatformTheme.textPrimary,
                                      fontWeight: isSelected
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                  ),
                                ),
                                if (latencyMs != null) ...[
                                  const SizedBox(width: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: (latencyMs < 0
                                              ? VideoPlatformTheme.danger
                                              : (latencyMs < 260
                                                  ? VideoPlatformTheme.success
                                                  : VideoPlatformTheme.warning))
                                          .withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      latencyMs < 0 ? '超时' : '${latencyMs}ms',
                                      style: TextStyle(
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w600,
                                        color: latencyMs < 0
                                            ? VideoPlatformTheme.danger
                                            : (latencyMs < 260
                                                ? VideoPlatformTheme.success
                                                : VideoPlatformTheme.warning),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '正在播出: ${epg.currentTitle}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isSelected
                                        ? VideoPlatformTheme.textSecondary
                                        : VideoPlatformTheme.textMuted,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(2),
                                  child: LinearProgressIndicator(
                                    value: epg.progress,
                                    minHeight: 2,
                                    backgroundColor: VideoPlatformTheme
                                        .borderSubtle
                                        .withValues(alpha: 0.5),
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      isSelected
                                          ? VideoPlatformTheme.accent
                                          : VideoPlatformTheme.textMuted
                                              .withValues(alpha: 0.6),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            trailing: IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 28,
                                minHeight: 28,
                              ),
                              tooltip: isFav ? '取消收藏频道' : '收藏频道',
                              onPressed: () => _toggleFavoriteChannel(ch),
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
                            onTap: () {
                              if (_isMultiViewMode &&
                                  _activeMultiViewSlot > 0) {
                                _playSubSlotChannel(_activeMultiViewSlot, ch);
                              } else {
                                _playChannel(ch);
                              }
                            },
                          ),
                          const Divider(height: 1),
                        ],
                      );
                    }),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPlayerPanel({
    bool compact = false,
    List<LiveChannel> visibleChannels = const [],
  }) {
    final ch = _currentChannel;
    final activeList = visibleChannels.isNotEmpty
        ? visibleChannels
        : widget.appState.liveChannels;

    return Focus(
      focusNode: _playerFocusNode,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
            _stepChannel(activeList, -1);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
            _stepChannel(activeList, 1);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _stepSignalLine(-1);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _stepSignalLine(1);
            return KeyEventResult.handled;
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
          if (!_playerFocusNode.hasFocus) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && !_playerFocusNode.hasFocus) {
                _playerFocusNode.requestFocus();
              }
            });
          }
        },
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) {
            if (!_playerFocusNode.hasFocus) {
              _playerFocusNode.requestFocus();
            }
          },
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
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
                            Video(
                              controller: _videoController,
                              fill: Colors.black,
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
                                  const Text(
                                    '滚轮/上下键/数字键换台',
                                    style: TextStyle(
                                      color: Colors.white60,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      // Top-right proxy selector + real-time download speed HUD
                      if (ch != null && _digitInputBuffer.isEmpty)
                        Positioned(
                          top: 14,
                          right: 18,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              VideoProxyNodeSelector(
                                proxyService: widget.appState.proxyService,
                                scenario: RequestScenario.liveStream,
                                overlayStyle: true,
                                onProxyChanged: (_) {
                                  _playChannel(
                                    ch,
                                    urlIndex: _currentUrlIndex,
                                    resetTried: false,
                                    isAutoReconnect: true,
                                  );
                                },
                              ),
                              const SizedBox(width: 8),
                              VideoDownloadSpeedBadge(player: _player),
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
                        SizedBox(height: 10),
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
                if (_isResolving)
                  Container(
                    color: const Color(0x88000000),
                    alignment: Alignment.center,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: VideoPlatformTheme.accent,
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
                                  urlIndex:
                                      (_currentUrlIndex + 1) % ch.urls.length,
                                ),
                                child: const Text('切换备用信号源'),
                              ),
                            if (ch != null)
                              OutlinedButton(
                                onPressed: () {
                                  setState(
                                    () => _useServerProxy = !_useServerProxy,
                                  );
                                  _playChannel(ch, urlIndex: _currentUrlIndex);
                                },
                                child: Text(
                                  _useServerProxy ? '切换为客户端直连' : '改用服务端代理重试',
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (!compact && ch != null)
            Container(
              height: 54,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: VideoPlatformTheme.bgElevated,
                border: Border(
                  top: BorderSide(color: VideoPlatformTheme.borderSubtle),
                ),
              ),
              child: Builder(
                builder: (context) {
                  final epg = _getChannelEpgInfo(ch);
                  final isFav = _favoriteChannelKeys.contains(_channelKey(ch));
                  return Row(
                    children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: isFav ? '取消收藏此频道' : '收藏此频道',
                        onPressed: () => _toggleFavoriteChannel(ch),
                        icon: Icon(
                          isFav
                              ? Icons.star_rounded
                              : Icons.star_border_rounded,
                          size: 19,
                          color: isFav
                              ? VideoPlatformTheme.warning
                              : VideoPlatformTheme.textSecondary,
                        ),
                      ),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 270),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              ch.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: VideoPlatformTheme.textPrimary,
                              ),
                            ),
                            Text(
                              '${epg.timeSlot} ${epg.currentTitle}  ·  下一档: ${epg.nextTitle}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: VideoPlatformTheme.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      if (ch.urls.length > 1)
                        Flexible(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: List.generate(ch.urls.length, (idx) {
                                final active = idx == _currentUrlIndex;
                                final lineUrl = ch.urls[idx];
                                final isIpv6Line = lineUrl.contains('[2') ||
                                    lineUrl.toLowerCase().contains('ipv6');
                                final lat = _latencyMsByUrl[lineUrl];
                                return Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: InkWell(
                                    onTap: () => _playChannel(ch, urlIndex: idx),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: active
                                            ? VideoPlatformTheme.accent
                                            : VideoPlatformTheme.bgCard,
                                        borderRadius: BorderRadius.circular(4),
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
                                          color: active
                                              ? Colors.white
                                              : VideoPlatformTheme.textSecondary,
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }),
                            ),
                          ),
                        ),
                      const Spacer(),
                      IconButton(
                        tooltip: '上一频道 (遥控器 CH▲ / PageUp)',
                        onPressed: () =>
                            _stepChannel(widget.appState.liveChannels, -1),
                        icon: const Icon(Icons.skip_previous_rounded, size: 18),
                      ),
                      IconButton(
                        tooltip: '下一频道 (遥控器 CH▼ / PageDown)',
                        onPressed: () =>
                            _stepChannel(widget.appState.liveChannels, 1),
                        icon: const Icon(Icons.skip_next_rounded, size: 18),
                      ),
                      if (ch.urls.length > 1)
                        IconButton(
                          tooltip: '切换备用信号源',
                          onPressed: () => _stepSignalLine(1),
                          icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                        ),
                      IconButton(
                        tooltip: '🔴 录制当前直播流到下载队列',
                        onPressed: _activeStreamUrl.isEmpty
                            ? null
                            : _recordCurrentLiveStream,
                        icon: Icon(
                          Icons.fiber_manual_record_rounded,
                          size: 18,
                          color: VideoPlatformTheme.danger,
                        ),
                      ),
                      IconButton(
                        tooltip: '小窗悬浮播放（切换其他页面不中断直播）',
                        onPressed:
                            _activeStreamUrl.isEmpty ? null : _enterLiveMiniPlayer,
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
                            final ok =
                                await TvPlatformService.showAirPlayPicker();
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
                      OutlinedButton.icon(
                        onPressed: () {
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
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    ),
    ),
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
