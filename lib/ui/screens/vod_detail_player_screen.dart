import 'dart:async';
import 'dart:io';

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
import '../widgets/video_download_speed_badge.dart';
import '../widgets/video_proxy_node_selector.dart';

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
  double _playbackSpeed = 1.0;
  bool _isLongPressFastForward = false;
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
  Timer? _startupWatchdogTimer;
  Timer? _bufferingLagTimer;
  bool _usingClientProxy = false;
  int _clientProxyRetryCountForEpisode = 0;
  bool _bypassClientProxyForCurrentEpisode = false;
  bool _didTryServerResolveForEpisode = false;
  int _playAttemptSessionId = 0;
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

  @override
  void initState() {
    super.initState();
    _activeSource = widget.source;
    _activeVodId = widget.vodId;
    if (widget.appState.miniPlayerSession != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.appState.closeMiniPlayer();
      });
    }
    _useServerProxy = !widget.appState.serverConfig.preferDirectPlayback;
    _player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 64 * 1024 * 1024,
      ),
    );
    _videoController = VideoController(_player);
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
    _bufferingSub = _player.stream.buffering.listen((isBuffering) {
      _bufferingLagTimer?.cancel();
      if (isBuffering && _usingClientProxy) {
        final hasStarted = _player.state.duration > Duration.zero ||
            _player.state.position > Duration.zero;
        if (hasStarted) {
          _bufferingLagTimer = Timer(const Duration(seconds: 10), () async {
            if (!mounted || !_player.state.buffering || !_usingClientProxy) {
              return;
            }
            final prevNodeId = widget.appState.proxyService.activeNode?.id;
            final nextNode = await widget.appState.proxyService
                .reportActiveNodeLag(reason: '视频播放缓冲卡顿');
            if (mounted && nextNode != null && nextNode.id != prevNodeId) {
              _showAdToast('当前代理卡顿，已自动切换至：${nextNode.displayTitle}');
            }
          });
        }
      }
    });
    _errorSub = _player.stream.error.listen((err) {
      if (err.isNotEmpty && mounted) {
        final lower = err.toLowerCase();
        final isNonFatalDecodeError =
            lower.contains('error while decoding') ||
            lower.contains('decoding frame') ||
            lower.contains('co located pocs') ||
            lower.contains('reference picture missing') ||
            lower.contains('non-existing pps') ||
            lower.contains('invalid data found when processing input') ||
            lower.contains('concealing') ||
            lower.contains('packet corrupt');
        if (isNonFatalDecodeError) return;

        final hasStartedPlaying = _player.state.duration > Duration.zero ||
            _player.state.position > Duration.zero ||
            (_player.state.width ?? 0) > 0;
        if (hasStartedPlaying) return;

        _triggerFastStartupFallback(reason: '当前播放地址不可用');
      }
    });

    _loadDetail();
  }

  Future<void> _configureVodNativePlayer() async {
    try {
      final dynamic platform = _player.platform;
      final props = <String, String>{
        'cache': 'yes',
        'cache-on-disk': 'no',
        'cache-secs': '30',
        'cache-pause-initial': 'no',
        'cache-pause-wait': '0.1',
        'demuxer-thread': 'yes',
        'demuxer-max-bytes': '67108864',
        'demuxer-max-back-bytes': '16777216',
        'demuxer-readahead-secs': '20',
        'vd-lavc-threads': '0',
        'ad-lavc-threads': '0',
        // Ultra-small initial probe size so first video frame renders in sub-second time
        'demuxer-lavf-probesize': '262144',
        'demuxer-lavf-analyzeduration': '0',
        'network-timeout': '8',
        'tls-verify': 'no',
        'stream-lavf-o':
            'reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_on_http_error=4xx,5xx,reconnect_delay_max=5',
        'demuxer-lavf-o':
            'seg_max_retry=8,http_persistent=1,http_multiple=1,allowed_extensions=ALL,protocol_whitelist=file,http,https,httpproxy,tcp,tls,crypto,data,rtp,udp,subfile',
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

  @override
  void dispose() {
    _adToastTimer?.cancel();
    _sleepTimer?.cancel();
    _startupWatchdogTimer?.cancel();
    _bufferingLagTimer?.cancel();
    _episodeSearchCtrl.dispose();
    _syncHistoryNow();
    _positionSub?.cancel();
    _completedSub?.cancel();
    _errorSub?.cancel();
    _bufferingSub?.cancel();
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
      // Avoid seeking beyond video duration
      if (_pendingSeekSeconds < totalSec - 5) {
        final target = Duration(seconds: _pendingSeekSeconds.round());
        _player.seek(target);
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
      _detailError = null;
    });

    try {
      final detail = await widget.appState.api.fetchVodDetail(
        _activeSource,
        _activeVodId,
      );
      if (!mounted) return;

      // Match saved exact progress or history or preferred line/episode
      final exactProgress = widget.appState.getVodProgress(
        _activeSource.id,
        _activeVodId,
      );
      final savedHist = widget.appState.findHistoryItem(
        _activeSource,
        _activeVodId,
      );
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
      _isResolvingPlay = true;
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

    // Concurrently pre-probe alternate play lines in the background right from the start!
    if (resetTriedLines) {
      unawaited(
        _precheckAlternateLinesInParallel(
          episode: episode,
          attemptId: attemptId,
        ),
      );
    }

    try {
      final resolved = await widget.appState.api.resolveVodPlayback(
        _activeSource,
        playGroup: episode.groupName,
        episodeUrl: episode.rawUrl,
      );
      if (!mounted || attemptId != _playAttemptSessionId) return;

      final shouldProxy = _useServerProxy || resolved.backendProxyPlayback;
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

    if (!forceProxy && !bypassClientProxy) {
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
      bypassClientProxy: bypassClientProxy || forceProxy || usingLocalStreamRelay,
    );
    if (usingLocalStreamRelay) {
      _usingClientProxy = !finalMediaTarget.contains('direct=1');
    }

    _activeStreamUrl = finalMediaTarget;
    _activeStreamHeaders = headers;
    await _player.open(
      Media(
        finalMediaTarget,
        httpHeaders: usingLocalStreamRelay ? const {} : headers,
      ),
      play: true,
    );
    if (_playbackSpeed != 1.0) {
      await _player.setRate(_playbackSpeed);
    }

    // 1. Concurrent fast playability probe on the primary stream: if the origin URL
    // immediately fails or returns 4xx/5xx while libmpv hasn't started yet, switch right away!
    if (!forceProxy && playUrl.startsWith('http')) {
      unawaited(
        widget.appState.api
            .probeVodStreamPlayableFast(
          playUrl,
          headers,
          timeout: const Duration(milliseconds: 2200),
        )
            .then((probe) {
          if (!mounted || activeAttemptId != _playAttemptSessionId) return;
          if (!probe.ok) {
            final hasStarted = _player.state.duration > Duration.zero ||
                _player.state.position > Duration.zero ||
                (_player.state.width ?? 0) > 0 ||
                LocalProxyTunnelBridge.recentDownstreamBytesPerSecond > 2048;
            if (!hasStarted) {
              _triggerFastStartupFallback(reason: '主线路探测不可达');
            }
          }
        }),
      );
    }

    // 2. Fast 3.8-second startup watchdog for ALL playback modes (both Direct & Proxy):
    // if no frames, duration, or downstream bytes have arrived within 3.8s, switch immediately!
    _startupWatchdogTimer = Timer(const Duration(milliseconds: 3800), () {
      if (!mounted || activeAttemptId != _playAttemptSessionId) return;
      final hasStarted = _player.state.duration > Duration.zero ||
          _player.state.position > Duration.zero ||
          (_player.state.width ?? 0) > 0 ||
          LocalProxyTunnelBridge.recentDownstreamBytesPerSecond > 4096;
      if (!hasStarted) {
        _triggerFastStartupFallback(reason: '当前线路响应超时');
      }
    });
  }

  void _triggerFastStartupFallback({required String reason}) {
    if (!mounted) return;
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
        '⚡ $reason，已极速切换至最快可用线路：${backupLine.episode.groupName} (${backupLine.latencyMs}ms)',
      );
      unawaited(
        _openResolvedStream(
          backupLine.resolved,
          forceProxy: _useServerProxy || backupLine.resolved.backendProxyPlayback,
        ),
      );
      return;
    }

    // 2. If TVBox source used the 0ms direct shortcut, try server-side `/api/vod/play` parser once
    if (_activeSource.isTvBox &&
        !_didTryServerResolveForEpisode &&
        currentEp != null) {
      _didTryServerResolveForEpisode = true;
      unawaited(
        widget.appState.api
            .resolveVodPlayback(
          _activeSource,
          playGroup: currentEp.groupName,
          episodeUrl: currentEp.rawUrl,
          forceServerResolve: true,
        )
            .then((srvResolved) {
          if (!mounted) return;
          setState(() => _resolvedPlayback = srvResolved);
          _openResolvedStream(
            srvResolved,
            forceProxy: _useServerProxy || srvResolved.backendProxyPlayback,
          );
        }).catchError((_) {}),
      );
      return;
    }

    // 3. If using client proxy, switch to the next fastest proxy node or bypass proxy
    if (_usingClientProxy &&
        !_bypassClientProxyForCurrentEpisode &&
        resolved != null) {
      if (_clientProxyRetryCountForEpisode < 1) {
        _clientProxyRetryCountForEpisode++;
        unawaited(
          widget.appState.proxyService
              .reportActiveNodeLag(reason: '代理加载视频缓慢，极速切换备用节点')
              .then((_) {
            if (mounted) {
              _openResolvedStream(
                resolved,
                forceProxy: _useServerProxy,
                skipM3u8Clean: true,
                bypassClientProxy: false,
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
      );
      return;
    }

    // 4. Fallback to server proxy if not yet tried
    if (!_useServerProxy &&
        resolved != null &&
        resolved.serverProxyUrl.isNotEmpty) {
      setState(() => _useServerProxy = true);
      _openResolvedStream(
        resolved,
        forceProxy: true,
        bypassClientProxy: true,
      );
      return;
    }

    // 5. Try the next untested play line in `_detail.playGroups` if available
    final detail = _detail;
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
            _useServerProxy = !widget.appState.serverConfig.preferDirectPlayback;
          });
          _showAdToast('⚡ 当前线路不可用，正在尝试备用线路：${nextGrp.name}');
          _selectAndPlayEpisode(
            nextEp,
            resumeSeconds: _pendingSeekSeconds,
            resetTriedLines: false,
          );
          return;
        }
      }
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
    _showAdToast(statusMessage);
    final curPosSec = _player.state.position.inSeconds > 0
        ? _player.state.position.inSeconds.toDouble()
        : _lastValidPosition.inSeconds.toDouble();
    if (curPosSec > 2) {
      _pendingSeekSeconds = curPosSec;
      _hasAppliedInitialSeek = false;
    }
    _bypassClientProxyForCurrentEpisode = false;
    _clientProxyRetryCountForEpisode = 0;
    final resolved = _resolvedPlayback;
    if (resolved != null) {
      _openResolvedStream(
        resolved,
        forceProxy: _useServerProxy,
        bypassClientProxy: false,
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

    return CallbackShortcuts(
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
      child: Scaffold(
        backgroundColor: VideoPlatformTheme.bgPrimary,
      appBar: AppBar(
        toolbarHeight: 50,
        titleSpacing: 4,
        title: Row(
          children: [
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_currentEpisode != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: VideoPlatformTheme.bgCard,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: VideoPlatformTheme.borderSubtle),
                ),
                child: Text(
                  _currentEpisode!.title,
                  style: TextStyle(
                    fontSize: 12,
                    color: VideoPlatformTheme.textSecondary,
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: VideoProxyNodeSelector(
                proxyService: widget.appState.proxyService,
                scenario: RequestScenario.vodStream,
                overlayStyle: false,
                onProxyChanged: _onProxyNodeSwitched,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: _showCrossSiteSourceSwitchDialog,
            icon: Icon(
              Icons.swap_horiz_rounded,
              size: 16,
              color: VideoPlatformTheme.accent,
            ),
            label: Text(
              '换源 (${_activeSource.name})',
              style: TextStyle(
                fontSize: 12.5,
                color: VideoPlatformTheme.textPrimary,
              ),
            ),
          ),
          IconButton(
            tooltip: '小窗悬浮播放（切回首页/Telegram 不中断视频）',
            onPressed: _activeStreamUrl.isEmpty ? null : _enterMiniPlayerMode,
            icon: const Icon(Icons.picture_in_picture_alt_rounded, size: 19),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isDesktopWide = constraints.maxWidth >= 980;
          if (isDesktopWide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 7,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 12, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildVideoPlayerStage(),
                        const SizedBox(height: 12),
                        _buildPlayerToolbar(),
                        const SizedBox(height: 16),
                        _buildMetadataPanel(),
                      ],
                    ),
                  ),
                ),
                Container(
                  width: 360,
                  height: constraints.maxHeight,
                  decoration: BoxDecoration(
                    color: VideoPlatformTheme.bgElevated,
                    border: Border(
                      left: BorderSide(color: VideoPlatformTheme.borderSubtle),
                    ),
                  ),
                  child: _buildRightSideEpisodePanel(),
                ),
              ],
            );
          }

          // Mobile / Tablet stacked layout
          return Column(
            children: [
              _buildVideoPlayerStage(fullBleed: true),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildPlayerToolbar(),
                      const SizedBox(height: 14),
                      _buildInlineEpisodeSection(),
                      const SizedBox(height: 16),
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
    );
  }

  Widget _buildVideoPlayerStage({bool fullBleed = false}) {
    final BoxFit videoFit =
        _videoAspectMode == 'cover' ? BoxFit.cover : BoxFit.contain;
    final double? customAspectRatio = _videoAspectMode == '16:9'
        ? 16 / 9
        : (_videoAspectMode == '4:3' ? 4 / 3 : null);

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
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
          child: Stack(
            fit: StackFit.expand,
            children: [
              Video(
                controller: _videoController,
                fill: Colors.black,
                fit: videoFit,
                aspectRatio: customAspectRatio,
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
            // Floating proxy node selector + download speed HUD + quick "跳过广告" pill on video stage
            Positioned(
              top: 14,
              right: 14,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  VideoProxyNodeSelector(
                    proxyService: widget.appState.proxyService,
                    scenario: RequestScenario.vodStream,
                    overlayStyle: true,
                    onProxyChanged: _onProxyNodeSwitched,
                  ),
                  const SizedBox(width: 8),
                  VideoDownloadSpeedBadge(player: _player),
                  if (_playError == null &&
                      !_isResolvingPlay &&
                      _currentEpisode != null) ...[
                    const SizedBox(width: 8),
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
                              borderRadius: const BorderRadius.horizontal(
                                left: Radius.circular(18),
                              ),
                              onTap: () => _skipForwardSeconds(30),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 11,
                                  vertical: 5,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.skip_next_rounded,
                                      size: 15,
                                      color: VideoPlatformTheme.accent,
                                    ),
                                    const SizedBox(width: 4),
                                    const Text(
                                      '跳过广告 +30s',
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
                            Container(
                              width: 1,
                              height: 16,
                              color: Colors.white.withValues(alpha: 0.18),
                            ),
                            InkWell(
                              onTap: () => _skipForwardSeconds(15),
                              child: const Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 8,
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
                              height: 16,
                              color: Colors.white.withValues(alpha: 0.18),
                            ),
                            InkWell(
                              borderRadius: const BorderRadius.horizontal(
                                right: Radius.circular(18),
                              ),
                              onTap: _showAdSkipSettingsDialog,
                              child: const Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 5,
                                ),
                                child: Icon(
                                  Icons.tune_rounded,
                                  size: 14,
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
            if (_isResolvingPlay)
              Container(
                color: const Color(0x99000000),
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: VideoPlatformTheme.accent,
                      ),
                    ),
                    SizedBox(height: 10),
                    Text(
                      '正在解析播放地址...',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ],
                ),
              ),
            if (_playError != null && !_isResolvingPlay)
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
          ],
        ),
        ),
      ),
    );
  }

  Widget _buildPlayerToolbar() {
    final detail = _detail;
    final isFav =
        detail != null && widget.appState.isFavorite(_activeSource, detail.vodId);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: VideoPlatformTheme.borderSubtle),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // Real-time download speed indicator
          VideoDownloadSpeedBadge(
            player: _player,
            backgroundColor: VideoPlatformTheme.bgCard,
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
          PopupMenuButton<double>(
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
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: VideoPlatformTheme.borderStrong),
              ),
              child: Text(
                '倍速 ${_playbackSpeed}x',
                style: TextStyle(
                  fontSize: 13,
                  color: VideoPlatformTheme.textPrimary,
                ),
              ),
            ),
          ),
          // Aspect ratio selector
          PopupMenuButton<String>(
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
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: VideoPlatformTheme.borderStrong),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.aspect_ratio_rounded, size: 15),
                  const SizedBox(width: 5),
                  Text(
                    '比例 ${_videoAspectMode == 'fit' ? '适应' : (_videoAspectMode == 'cover' ? '铺满' : _videoAspectMode)}',
                    style: TextStyle(
                      fontSize: 13,
                      color: VideoPlatformTheme.textPrimary,
                    ),
                  ),
                ],
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
        ],
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
                    onTap: () => setState(() => _episodeChunkIndex = chunkIdx),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected
                            ? VideoPlatformTheme.accent.withValues(alpha: 0.18)
                            : VideoPlatformTheme.bgCard,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: selected
                              ? VideoPlatformTheme.accent
                              : VideoPlatformTheme.borderSubtle,
                        ),
                      ),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 11,
                          color: selected
                              ? VideoPlatformTheme.accent
                              : VideoPlatformTheme.textSecondary,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
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
                onTap: () =>
                    setState(() => _episodesReversed = !_episodesReversed),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.swap_vert_rounded,
                        size: 15,
                        color: _episodesReversed
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.textSecondary,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        _episodesReversed ? '倒序' : '正序',
                        style: TextStyle(
                          fontSize: 12,
                          color: _episodesReversed
                              ? VideoPlatformTheme.accent
                              : VideoPlatformTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
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
                onTap: () => setState(() {
                  _selectedGroupIndex = idx;
                  _episodeChunkIndex = -1;
                }),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected
                        ? VideoPlatformTheme.accent
                        : VideoPlatformTheme.bgCard,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: selected
                          ? VideoPlatformTheme.accent
                          : VideoPlatformTheme.borderSubtle,
                    ),
                  ),
                  child: Text(
                    '${grp.name} (${grp.episodes.length})',
                    style: TextStyle(
                      fontSize: 12,
                      color: selected
                          ? Colors.white
                          : VideoPlatformTheme.textSecondary,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
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
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: VideoPlatformTheme.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '播放线路与选集 (${currentGroup.episodes.length}集)',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
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
            height: 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: detail.playGroups.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, idx) {
                final grp = detail.playGroups[idx];
                final selected = idx == _selectedGroupIndex;
                return InkWell(
                  borderRadius: BorderRadius.circular(5),
                  onTap: () => setState(() {
                    _selectedGroupIndex = idx;
                    _episodeChunkIndex = -1;
                  }),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected
                          ? VideoPlatformTheme.accent
                          : VideoPlatformTheme.bgCard,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      grp.name,
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
          _buildEpisodeChunkAndSearchControls(currentGroup.episodes.length),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: GridView.builder(
              shrinkWrap: true,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 110,
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
      borderRadius: BorderRadius.circular(5),
      focusColor: VideoPlatformTheme.accent.withValues(alpha: 0.35),
      onTap: () => _selectAndPlayEpisode(
        ep,
        resumeSeconds:
            isSavedEpisode ? savedProg.positionSeconds.toDouble() : 0,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isPlaying
              ? VideoPlatformTheme.accent.withValues(alpha: 0.16)
              : VideoPlatformTheme.bgCard,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: isPlaying
                ? VideoPlatformTheme.accent
                : (isSavedEpisode
                    ? VideoPlatformTheme.accent.withValues(alpha: 0.5)
                    : VideoPlatformTheme.borderSubtle),
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
                color: isPlaying
                    ? VideoPlatformTheme.accent
                    : VideoPlatformTheme.textPrimary,
                fontWeight: isPlaying ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            if (isSavedEpisode)
              Text(
                _formatDurationLabel(savedProg.positionSeconds),
                style: TextStyle(
                  fontSize: 9.5,
                  color: VideoPlatformTheme.accent,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetadataPanel() {
    final detail = _detail;
    if (detail == null) return const SizedBox.shrink();

    final tags = <String>[
      if (detail.typeName.isNotEmpty) detail.typeName,
      if (detail.vodYear.isNotEmpty && detail.vodYear != '0') detail.vodYear,
      if (detail.vodArea.isNotEmpty) detail.vodArea,
      if (detail.vodRemarks.isNotEmpty) detail.vodRemarks,
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: VideoPlatformTheme.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            detail.vodName,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: VideoPlatformTheme.textPrimary,
            ),
          ),
          if (tags.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: tags
                  .map(
                    (t) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: VideoPlatformTheme.bgCard,
                        borderRadius: BorderRadius.circular(4),
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
          ],
          if (detail.vodDirector.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '导演：${detail.vodDirector}',
              style: TextStyle(
                fontSize: 13,
                color: VideoPlatformTheme.textSecondary,
              ),
            ),
          ],
          if (detail.vodActor.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '主演：${detail.vodActor}',
              style: TextStyle(
                fontSize: 13,
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
                fontWeight: FontWeight.w600,
                color: VideoPlatformTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              detail.vodContent,
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
