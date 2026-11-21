import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../services/api_client.dart';
import '../services/proxy_routing_service.dart';
import '../services/telegram_notification_service.dart';
import '../services/tv_platform_service.dart';
import '../ui/theme.dart';

class DirectoryBreadcrumb {
  final String typeId;
  final String title;

  const DirectoryBreadcrumb({
    required this.typeId,
    required this.title,
  });
}

class MiniPlayerSession {
  final String title;
  final String subtitle;
  final String streamUrl;
  final Map<String, String> headers;
  final int initialPositionSeconds;
  final bool isLive;
  final bool is115Playback;
  final VodItem? vodItem;
  final String? sourceKey;
  final String? sourceName;
  final VodSource? vodSource;
  final String? vodId;
  final String? vodTitle;
  final String? vodPoster;
  final String? episodeName;
  final LiveChannel? liveChannel;
  final int groupIndex;
  final int episodeIndex;

  const MiniPlayerSession({
    required this.title,
    this.subtitle = '',
    required this.streamUrl,
    this.headers = const {},
    this.initialPositionSeconds = 0,
    this.isLive = false,
    this.is115Playback = false,
    this.vodItem,
    this.sourceKey,
    this.sourceName,
    this.vodSource,
    this.vodId,
    this.vodTitle,
    this.vodPoster,
    this.episodeName,
    this.liveChannel,
    this.groupIndex = 0,
    this.episodeIndex = 0,
  });
}

class VodPlaybackProgress {
  final int groupIndex;
  final int episodeIndex;
  final String episodeName;
  final int positionSeconds;
  final int durationSeconds;
  final int updatedAtMs;

  const VodPlaybackProgress({
    required this.groupIndex,
    required this.episodeIndex,
    required this.episodeName,
    required this.positionSeconds,
    required this.durationSeconds,
    required this.updatedAtMs,
  });

  double get ratio {
    if (durationSeconds <= 0) return 0.0;
    return (positionSeconds / durationSeconds).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
    'g': groupIndex,
    'e': episodeIndex,
    'n': episodeName,
    'p': positionSeconds,
    'd': durationSeconds,
    't': updatedAtMs,
  };

  factory VodPlaybackProgress.fromJson(Map<String, dynamic> json) {
    return VodPlaybackProgress(
      groupIndex: int.tryParse((json['g'] ?? 0).toString()) ?? 0,
      episodeIndex: int.tryParse((json['e'] ?? 0).toString()) ?? 0,
      episodeName: (json['n'] ?? '').toString(),
      positionSeconds: int.tryParse((json['p'] ?? 0).toString()) ?? 0,
      durationSeconds: int.tryParse((json['d'] ?? 0).toString()) ?? 0,
      updatedAtMs: int.tryParse((json['t'] ?? 0).toString()) ?? 0,
    );
  }
}

class AppState extends ChangeNotifier {
  PackageInfo? _packageInfo;

  String get appShortVersion {
    final version = _packageInfo?.version.trim() ?? '';
    return version.isEmpty ? '版本未知' : 'v$version';
  }

  String get appFullVersion {
    final buildNumber = _packageInfo?.buildNumber.trim() ?? '';
    return buildNumber.isEmpty
        ? appShortVersion
        : '$appShortVersion (Build $buildNumber)';
  }

  static const _prefServerConfigKey = 'm3u8_server_config_v1';
  static const _prefSelectedSourceIdKey = 'm3u8_selected_vod_source_id_v1';
  static const _prefSelectedLiveSourceKey = 'm3u8_selected_live_source_key_v1';
  static const _prefCustomLiveSourcesKey = 'm3u8_custom_live_sources_v1';
  static const _prefAggregatedSearchKey = 'm3u8_aggregated_search_v1';
  static const _prefThemeIdKey = 'm3u8_theme_id_v1';
  static const _prefVodFilterM3u8AdsKey = 'm3u8_vod_filter_m3u8_ads_v1';
  static const _prefVodSkipIntroSecKey = 'm3u8_vod_skip_intro_sec_v1';
  static const _prefVodSkipOutroSecKey = 'm3u8_vod_skip_outro_sec_v1';
  static const _prefTvModeKey = 'm3u8_tv_mode_v2';
  static const _prefVodProgressMapKey = 'm3u8_vod_progress_map_v1';
  static const _prefPinnedSourcesKey = 'm3u8_pinned_vod_sources_v1';
  static const _prefHiddenSourcesKey = 'm3u8_hidden_vod_sources_v1';
  static const _prefHistoryClearedAtMsKey = 'm3u8_history_cleared_at_ms_v1';
  static const _prefFavoritesClearedAtMsKey = 'm3u8_favorites_cleared_at_ms_v1';
  static const _prefDeletedHistoryKeysKey = 'm3u8_deleted_history_keys_v1';
  static const _prefDeletedFavoritesKeysKey = 'm3u8_deleted_favorites_keys_v1';

  ServerConfig _serverConfig = const ServerConfig();
  late final ApiClient api;

  String _themeId = 'ocean_dark';
  bool _vodFilterM3u8Ads = true;
  int _vodSkipIntroSeconds = 0;
  int _vodSkipOutroSeconds = 0;
  bool _tvMode = false;
  bool _isHardwareTv = false;
  bool _isImmersiveFullscreen = false;
  bool _supportsAirPlay = false;
  bool _initialized = false;
  bool _isAuthenticated = false;
  bool _isConnecting = false;
  String? _connectionError;

  // Floating Mini-Player & Exact VOD Progress State
  MiniPlayerSession? _miniPlayerSession;
  Map<String, VodPlaybackProgress> _vodProgressMap = {};

  // VOD Sources & Browsing
  List<VodSource> _sources = const [];
  VodSource? _selectedSource;
  List<VodCategory> _categories = const [];
  String _selectedTypeId = '';
  List<DirectoryBreadcrumb> _directoryBreadcrumbs = const [];

  List<VodItem> _vodItems = const [];
  int _currentPage = 1;
  int _totalPages = 1;
  int _totalCount = 0;
  bool _isLoadingVod = false;
  bool _isLoadingMoreVod = false;
  String? _vodError;
  int _vodCatalogEpoch = 0;

  // In-memory VOD Catalog View Cache so returning from folders/categories/search/sources is instant (0ms)
  final Map<String, _VodCatalogViewSnapshot> _vodCatalogCache = {};
  final Map<String, List<VodCategory>> _categoriesBySourceId = {};
  _VodCatalogViewSnapshot? _preSearchSnapshot;

  // Search State
  String _searchKeyword = '';
  bool _aggregatedSearch = false;
  bool _isSearching = false;
  int _searchCompletedSources = 0;
  int _searchTotalSources = 0;
  String? _searchSourceFilterId;

  // VOD Source Speed Test & Pin/Hide Management
  Set<String> _pinnedSourceIds = {};
  Set<String> _hiddenSourceIds = {};
  final Map<String, int> _sourceLatencyMs = {};
  bool _isTestingSources = false;

  // Library (Favorites & Watch History)
  List<LibraryItem> _favorites = const [];
  List<LibraryItem> _history = const [];
  bool _isLoadingLibrary = false;
  int _historyClearedAtMs = 0;
  int _favoritesClearedAtMs = 0;
  Set<String> _deletedHistoryKeys = {};
  Set<String> _deletedFavoritesKeys = {};

  // Live TV State
  List<LiveSource> _liveSources = const [];
  List<LiveSource> _customLiveSources = const [];
  String? _savedLiveSourceKey;
  LiveSource? _selectedLiveSource;
  List<LiveChannel> _liveChannels = const [];
  bool _isLoadingLive = false;
  String? _liveError;

  // Download Tasks State
  List<DownloadTask> _tasks = const [];
  bool _isLoadingTasks = false;
  Timer? _tasksPollTimer;

  // Media Library Files State
  FileDirectoryListing? _currentDirectory;
  bool _isLoadingFiles = false;
  String? _filesError;

  // Server Settings State
  ServerSettings? _serverSettings;

  // Proxy Subscription & Scenario Routing Service
  late final ProxyRoutingService proxyService;

  // Telegram Real-Time Notification Service & Reading / Navigation State
  late final TelegramNotificationService telegramNotifications;
  final Map<String, String> _knownTelegramChatTitles = {};
  bool _isTelegramViewActive = false;
  bool _isAppForeground = true;
  String _activeReadingTelegramAccountId = '';
  String _activeReadingTelegramPeer = '';
  bool _activeReadingAtBottom = true;
  ({String accountId, String peer, int messageId})? _pendingTelegramJumpTarget;
  VoidCallback? onNavigateToTelegramTab;
  ValueChanged<int>? onNavigateToTab;
  bool Function()? activeChildBackHandler;
  bool Function()? activeChildDownFromHeaderHandler;

  void selectTab(int index) {
    onNavigateToTab?.call(index);
  }

  AppState({ApiClient? customApi}) {
    proxyService = ProxyRoutingService();
    proxyService.addListener(notifyListeners);
    api = customApi ?? ApiClient(_serverConfig, proxyService: proxyService);
    telegramNotifications = TelegramNotificationService(
      apiProvider: () => api,
      isReadingPeer: (accountId, peer) =>
          _isAppForeground &&
          _isTelegramViewActive &&
          _activeReadingAtBottom &&
          _activeReadingTelegramAccountId == accountId &&
          _activeReadingTelegramPeer == peer,
      resolveChatTitle: (accountId, peer) =>
          _knownTelegramChatTitles['$accountId|$peer'] ?? '',
      onOpenNotification: (accountId, peer, messageId) {
        _pendingTelegramJumpTarget = (
          accountId: accountId,
          peer: peer,
          messageId: messageId,
        );
        onNavigateToTelegramTab?.call();
        notifyListeners();
      },
    );
    telegramNotifications.addListener(notifyListeners);
  }

  ({String accountId, String peer, int messageId})?
      consumePendingTelegramJumpTarget() {
    final target = _pendingTelegramJumpTarget;
    _pendingTelegramJumpTarget = null;
    return target;
  }

  ({String accountId, String peer, int messageId})?
      get pendingTelegramJumpTarget => _pendingTelegramJumpTarget;

  void registerTelegramChatTitle(
    String accountId,
    String peer,
    String title,
  ) {
    final clean = title.trim();
    if (clean.isNotEmpty) {
      _knownTelegramChatTitles['$accountId|$peer'] = clean;
    }
  }

  bool get isTelegramViewActive => _isTelegramViewActive;

  void updateTelegramReadingContext({
    bool? isTelegramViewActive,
    bool? isAppForeground,
    String? accountId,
    String? peer,
    bool? atBottom,
  }) {
    final becameForeground = isAppForeground == true && !_isAppForeground;
    final becameViewActive =
        isTelegramViewActive == true && !_isTelegramViewActive;
    if (isTelegramViewActive != null) {
      _isTelegramViewActive = isTelegramViewActive;
    }
    if (isAppForeground != null) {
      _isAppForeground = isAppForeground;
    }
    if (accountId != null) {
      _activeReadingTelegramAccountId = accountId;
      telegramNotifications.registerActiveAccountId(accountId);
    }
    if (peer != null) {
      _activeReadingTelegramPeer = peer;
    }
    if (atBottom != null) {
      _activeReadingAtBottom = atBottom;
    }
    telegramNotifications.reconcileReadingState();
    if (becameForeground || becameViewActive) {
      unawaited(telegramNotifications.refreshAccountsAndConnect());
    }
  }

  // Getters
  ServerConfig get serverConfig => _serverConfig;
  String get themeId => _themeId;
  bool get vodFilterM3u8Ads => _vodFilterM3u8Ads;
  int get vodSkipIntroSeconds => _vodSkipIntroSeconds;
  int get vodSkipOutroSeconds => _vodSkipOutroSeconds;
  bool get tvMode => _tvMode;
  bool get isHardwareTv => _isHardwareTv;
  bool get isImmersiveFullscreen => _isImmersiveFullscreen;
  bool get supportsAirPlay => _supportsAirPlay;

  void setImmersiveFullscreen(bool value) {
    if (_isImmersiveFullscreen == value) return;
    _isImmersiveFullscreen = value;
    notifyListeners();
  }
  bool get initialized => _initialized;
  bool get isAuthenticated => _isAuthenticated;
  bool get isConnecting => _isConnecting;
  String? get connectionError => _connectionError;
  MiniPlayerSession? get miniPlayerSession => _miniPlayerSession;
  Map<String, VodPlaybackProgress> get vodProgressMap => _vodProgressMap;

  List<VodSource> get sources => _sources;
  VodSource? get selectedSource => _selectedSource;
  List<VodCategory> get categories => _categories;
  String get selectedTypeId => _selectedTypeId;
  List<DirectoryBreadcrumb> get directoryBreadcrumbs => _directoryBreadcrumbs;

  List<VodItem> get vodItems => _vodItems;
  int get currentPage => _currentPage;
  int get totalPages => _totalPages;
  int get totalCount => _totalCount;
  bool get isLoadingVod => _isLoadingVod;
  bool get isLoadingMoreVod => _isLoadingMoreVod;
  String? get vodError => _vodError;
  bool get hasMoreVod =>
      _searchKeyword.isEmpty && !_isLoadingVod && _currentPage < _totalPages;

  String get searchKeyword => _searchKeyword;
  bool get aggregatedSearch => _aggregatedSearch;
  bool get isSearching => _isSearching;
  int get searchCompletedSources => _searchCompletedSources;
  int get searchTotalSources => _searchTotalSources;
  String? get searchSourceFilterId => _searchSourceFilterId;
  Set<String> get pinnedSourceIds => _pinnedSourceIds;
  Set<String> get hiddenSourceIds => _hiddenSourceIds;
  Map<String, int> get sourceLatencyMs => _sourceLatencyMs;
  bool get isTestingSources => _isTestingSources;

  List<VodSource> get visibleSources {
    final visible = _sources
        .where((s) => !_hiddenSourceIds.contains(s.id))
        .toList();
    visible.sort((a, b) {
      final ap = _pinnedSourceIds.contains(a.id) ? 0 : 1;
      final bp = _pinnedSourceIds.contains(b.id) ? 0 : 1;
      if (ap != bp) return ap.compareTo(bp);
      return 0;
    });
    return visible.isNotEmpty ? visible : _sources;
  }

  List<VodItem> get filteredVodItems {
    if (_searchKeyword.isEmpty ||
        !_aggregatedSearch ||
        _searchSourceFilterId == null ||
        _searchSourceFilterId!.isEmpty) {
      return _vodItems;
    }
    return _vodItems
        .where((item) => item.source?.id == _searchSourceFilterId)
        .toList();
  }

  List<LibraryItem> get favorites => _favorites;
  List<LibraryItem> get history => _history;
  bool get isLoadingLibrary => _isLoadingLibrary;

  List<LiveSource> get liveSources => _liveSources;
  LiveSource? get selectedLiveSource => _selectedLiveSource;
  List<LiveChannel> get liveChannels => _liveChannels;
  bool get isLoadingLive => _isLoadingLive;
  String? get liveError => _liveError;

  List<DownloadTask> get tasks => _tasks;
  bool get isLoadingTasks => _isLoadingTasks;
  int get activeTasksCount => _tasks.where((t) => t.isActive).length;

  FileDirectoryListing? get currentDirectory => _currentDirectory;
  bool get isLoadingFiles => _isLoadingFiles;
  String? get filesError => _filesError;

  ServerSettings? get serverSettings => _serverSettings;

  Future<void> initialize() async {
    if (_initialized) return;
    try {
      _packageInfo = await PackageInfo.fromPlatform();
    } catch (error) {
      debugPrint('Unable to read app version: $error');
    }
    String? savedSourceId;
    bool hasSavedConfig = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawCfg = prefs.getString(_prefServerConfigKey);
      if (rawCfg != null && rawCfg.isNotEmpty) {
        final decoded = jsonDecode(rawCfg);
        if (decoded is Map<String, dynamic>) {
          _serverConfig = ServerConfig.fromJson(decoded);
          api.updateConfig(_serverConfig);
          hasSavedConfig = true;
        }
      }
      savedSourceId = prefs.getString(_prefSelectedSourceIdKey);
      _savedLiveSourceKey = prefs.getString(_prefSelectedLiveSourceKey);
      final rawCustomLives = prefs.getString(_prefCustomLiveSourcesKey);
      if (rawCustomLives != null && rawCustomLives.isNotEmpty) {
        final decodedLives = jsonDecode(rawCustomLives);
        if (decodedLives is List) {
          _customLiveSources = decodedLives
              .whereType<Map<String, dynamic>>()
              .map(LiveSource.fromJson)
              .toList();
        }
      }
      _aggregatedSearch = prefs.getBool(_prefAggregatedSearchKey) ?? false;
      _vodFilterM3u8Ads = prefs.getBool(_prefVodFilterM3u8AdsKey) ?? true;
      _vodSkipIntroSeconds = prefs.getInt(_prefVodSkipIntroSecKey) ?? 0;
      _vodSkipOutroSeconds = prefs.getInt(_prefVodSkipOutroSecKey) ?? 0;
      final savedTvMode = prefs.getBool(_prefTvModeKey);
      if (savedTvMode != null) {
        _tvMode = savedTvMode;
      }
      final savedTheme = prefs.getString(_prefThemeIdKey);
      if (savedTheme != null && savedTheme.isNotEmpty) {
        _themeId = savedTheme;
        VideoPlatformTheme.setTheme(_themeId);
      }
      final rawProgress = prefs.getString(_prefVodProgressMapKey);
      if (rawProgress != null && rawProgress.isNotEmpty) {
        final decodedProgress = jsonDecode(rawProgress);
        if (decodedProgress is Map) {
          final loaded = <String, VodPlaybackProgress>{};
          decodedProgress.forEach((k, v) {
            if (v is Map) {
              loaded[k.toString()] = VodPlaybackProgress.fromJson(
                Map<String, dynamic>.from(v),
              );
            }
          });
          _vodProgressMap = loaded;
        }
      }
      final pinnedList = prefs.getStringList(_prefPinnedSourcesKey);
      if (pinnedList != null) {
        _pinnedSourceIds = pinnedList.toSet();
      }
      final hiddenList = prefs.getStringList(_prefHiddenSourcesKey);
      if (hiddenList != null) {
        _hiddenSourceIds = hiddenList.toSet();
      }
      _historyClearedAtMs = prefs.getInt(_prefHistoryClearedAtMsKey) ?? 0;
      _favoritesClearedAtMs = prefs.getInt(_prefFavoritesClearedAtMsKey) ?? 0;
      final deletedHist = prefs.getStringList(_prefDeletedHistoryKeysKey);
      if (deletedHist != null) {
        _deletedHistoryKeys = deletedHist.toSet();
      }
      final deletedFavs = prefs.getStringList(_prefDeletedFavoritesKeysKey);
      if (deletedFavs != null) {
        _deletedFavoritesKeys = deletedFavs.toSet();
      }

      // Detect Android TV (Leanback) or Apple TV (tvOS / AirPlay)
      final tvInfo = await TvPlatformService.detectPlatformTvInfo();
      _isHardwareTv = tvInfo.isTv;
      _supportsAirPlay = tvInfo.supportsAirPlay;
      if (tvInfo.isTv) {
        _tvMode = savedTvMode ?? true;
      } else if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS)) {
        // On Android/iOS phones & tablets (where hardware Leanback is false),
        // always start in touch/mobile mode so a phone never gets stuck in TV mode.
        _tvMode = false;
      } else if (savedTvMode != null) {
        _tvMode = savedTvMode;
      }
      await proxyService.initialize();
    } catch (_) {
      // Ignore storage init errors
    }

    final hasCredentials = _serverConfig.secret.trim().isNotEmpty ||
        (hasSavedConfig && _serverConfig.authMode == AuthMode.none);
    _isAuthenticated = hasCredentials;
    _initialized = true;
    notifyListeners();

    if (!hasCredentials) {
      return;
    }

    // Bootstrap in the background so the app enters the main UI immediately
    // without prompting for the password again on every launch.
    unawaited(telegramNotifications.initializeAndStart());
    unawaited(
      connectAndBootstrap(preferredSourceId: savedSourceId).then((ok) {
        if (ok) {
          _startTasksPolling();
        }
      }),
    );
  }

  void _startTasksPolling() {
    _tasksPollTimer?.cancel();
    _tasksPollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (_isAuthenticated) {
        refreshDownloadTasks(silent: true);
      }
    });
  }

  Future<void> logout() async {
    _tasksPollTimer?.cancel();
    telegramNotifications.stop();
    _isAuthenticated = false;
    _connectionError = null;
    _serverConfig = _serverConfig.copyWith(secret: '');
    api.updateConfig(_serverConfig);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefServerConfigKey,
        jsonEncode(_serverConfig.toJson()),
      );
    } catch (_) {}
    notifyListeners();
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _tasksPollTimer?.cancel();
    proxyService.removeListener(notifyListeners);
    proxyService.dispose();
    telegramNotifications.removeListener(notifyListeners);
    telegramNotifications.dispose();
    super.dispose();
  }

  Future<bool> updateServerConfig(ServerConfig newConfig) async {
    _serverConfig = newConfig;
    api.updateConfig(newConfig);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefServerConfigKey,
        jsonEncode(newConfig.toJson()),
      );
    } catch (_) {}
    notifyListeners();
    return connectAndBootstrap();
  }

  Future<void> setThemeId(String id) async {
    final palette = VideoPlatformTheme.paletteById(id);
    if (_themeId == palette.id &&
        VideoPlatformTheme.currentPalette.id == palette.id) {
      return;
    }
    _themeId = palette.id;
    VideoPlatformTheme.setTheme(_themeId);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefThemeIdKey, _themeId);
    } catch (_) {}
  }

  Future<void> setAggregatedSearch(bool value) async {
    if (_aggregatedSearch == value) return;
    _aggregatedSearch = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefAggregatedSearchKey, value);
    } catch (_) {}
    if (_searchKeyword.isNotEmpty) {
      await performSearch(_searchKeyword);
    }
  }

  Future<bool> connectAndBootstrap({String? preferredSourceId}) async {
    _isConnecting = true;
    _connectionError = null;
    notifyListeners();

    try {
      await api.verifyConnection();
      final loadedSources = await api.fetchAllVodSources();
      _sources = loadedSources;

      if (loadedSources.isNotEmpty) {
        VodSource? chosen;
        if (preferredSourceId != null && preferredSourceId.isNotEmpty) {
          for (final s in loadedSources) {
            if (s.id == preferredSourceId ||
                s.librarySourceKey == preferredSourceId) {
              chosen = s;
              break;
            }
          }
        }
        // Prefer standard custom CMS VOD sources first for reliable instant browsing
        chosen ??= loadedSources.firstWhere(
          (s) => !s.isTvBox,
          orElse: () => loadedSources.first,
        );
        _selectedSource = chosen;
      } else {
        _selectedSource = null;
      }

      _isAuthenticated = true;
      _isConnecting = false;
      notifyListeners();
      _startTasksPolling();
      unawaited(telegramNotifications.initializeAndStart());

      if (_selectedSource != null) {
        unawaited(loadVodCatalog(resetCategories: true));
      }
      unawaited(refreshLibrary());
      unawaited(refreshDownloadTasks(silent: true));
      unawaited(refreshServerSettings());
      return true;
    } catch (e) {
      if (e is ApiException && (e.statusCode == 401 || e.statusCode == 403)) {
        _isAuthenticated = false;
      }
      _isConnecting = false;
      _connectionError = e.toString();
      notifyListeners();
      return false;
    }
  }

  String _catalogCacheKey(String sourceId, String typeId) =>
      '$sourceId|$typeId';

  void _saveCurrentCatalogSnapshot() {
    final src = _selectedSource;
    if (src == null ||
        _searchKeyword.isNotEmpty ||
        _isLoadingVod ||
        _vodItems.isEmpty) {
      return;
    }
    if (_categories.isNotEmpty) {
      _categoriesBySourceId[src.id] = List<VodCategory>.unmodifiable(_categories);
    }
    final key = _catalogCacheKey(src.id, _selectedTypeId);
    _vodCatalogCache[key] = _VodCatalogViewSnapshot(
      sourceId: src.id,
      selectedTypeId: _selectedTypeId,
      directoryBreadcrumbs:
          List<DirectoryBreadcrumb>.unmodifiable(_directoryBreadcrumbs),
      categories: List<VodCategory>.unmodifiable(_categories),
      vodItems: List<VodItem>.unmodifiable(_vodItems),
      currentPage: _currentPage,
      totalPages: _totalPages,
      totalCount: _totalCount,
    );
  }

  bool _restoreCatalogSnapshotIfAvailable(
    String sourceId,
    String typeId, {
    List<DirectoryBreadcrumb>? breadcrumbsOverride,
  }) {
    final key = _catalogCacheKey(sourceId, typeId);
    final cached = _vodCatalogCache[key];
    if (cached == null || cached.vodItems.isEmpty) return false;
    _vodCatalogEpoch++;
    _selectedTypeId = typeId;
    _directoryBreadcrumbs =
        breadcrumbsOverride ?? cached.directoryBreadcrumbs;
    final cachedCats = _categoriesBySourceId[sourceId] ?? cached.categories;
    if (cachedCats.isNotEmpty) {
      _categories = cachedCats;
    } else {
      unawaited(_ensureCategoriesForSource(sourceId));
    }
    _vodItems = cached.vodItems;
    _currentPage = cached.currentPage;
    _totalPages = cached.totalPages;
    _totalCount = cached.totalCount;
    _isLoadingVod = false;
    _isLoadingMoreVod = false;
    _vodError = null;
    _searchKeyword = '';
    _searchSourceFilterId = null;
    _isSearching = false;
    notifyListeners();
    return true;
  }

  Future<void> _ensureCategoriesForSource(String sourceId) async {
    final src = _selectedSource;
    if (src == null || src.id != sourceId) return;
    if (_categories.isNotEmpty) return;
    try {
      final resp = await api.fetchVodList(
        src,
        typeId: '',
        page: 1,
        forceRefresh: true,
      );
      if (_selectedSource?.id == sourceId && resp.categories.isNotEmpty) {
        _categories = List<VodCategory>.unmodifiable(resp.categories);
        _categoriesBySourceId[sourceId] = _categories;
        _saveCurrentCatalogSnapshot();
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> selectVodSource(VodSource source) async {
    if (_selectedSource?.id == source.id &&
        _vodItems.isNotEmpty &&
        _searchKeyword.isEmpty) {
      return;
    }
    _saveCurrentCatalogSnapshot();
    _selectedSource = source;
    _preSearchSnapshot = null;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefSelectedSourceIdKey, source.id);
    } catch (_) {}

    if (_restoreCatalogSnapshotIfAvailable(
      source.id,
      '',
      breadcrumbsOverride: const [],
    )) {
      return;
    }

    _selectedTypeId = '';
    _directoryBreadcrumbs = const [];
    _categories = _categoriesBySourceId[source.id] ?? const [];
    _vodItems = const [];
    _currentPage = 1;
    _totalPages = 1;
    _totalCount = 0;
    _isLoadingMoreVod = false;
    _searchKeyword = '';
    notifyListeners();

    await loadVodCatalog(resetCategories: true);
  }

  Future<void> selectCategory(String typeId) async {
    if (_selectedTypeId == typeId &&
        _searchKeyword.isEmpty &&
        _directoryBreadcrumbs.isEmpty &&
        _vodItems.isNotEmpty) {
      return;
    }
    _saveCurrentCatalogSnapshot();
    final src = _selectedSource;
    if (src != null &&
        _restoreCatalogSnapshotIfAvailable(
          src.id,
          typeId,
          breadcrumbsOverride: const [],
        )) {
      return;
    }
    _selectedTypeId = typeId;
    _directoryBreadcrumbs = const [];
    _vodItems = const [];
    _currentPage = 1;
    _totalPages = 1;
    _isLoadingMoreVod = false;
    _searchKeyword = '';
    notifyListeners();
    await loadVodCatalog(resetCategories: false);
  }

  Future<void> enterAlistDirectory(VodItem dirItem) async {
    if (!dirItem.isAlistDirectory) return;
    _saveCurrentCatalogSnapshot();
    final nextBreadcrumbs = [
      ..._directoryBreadcrumbs,
      DirectoryBreadcrumb(typeId: dirItem.vodId, title: dirItem.vodName),
    ];
    final src = _selectedSource;
    if (src != null &&
        _restoreCatalogSnapshotIfAvailable(
          src.id,
          dirItem.vodId,
          breadcrumbsOverride: nextBreadcrumbs,
        )) {
      return;
    }
    _directoryBreadcrumbs = nextBreadcrumbs;
    _selectedTypeId = dirItem.vodId;
    _vodItems = const [];
    _currentPage = 1;
    _totalPages = 1;
    _isLoadingMoreVod = false;
    _searchKeyword = '';
    notifyListeners();
    await loadVodCatalog(resetCategories: false);
  }

  Future<void> navigateToDirectoryBreadcrumb(int index) async {
    _saveCurrentCatalogSnapshot();
    final src = _selectedSource;
    if (index < 0) {
      if (src != null &&
          _restoreCatalogSnapshotIfAvailable(
            src.id,
            '',
            breadcrumbsOverride: const [],
          )) {
        return;
      }
      _directoryBreadcrumbs = const [];
      _selectedTypeId = '';
      _vodItems = const [];
      _currentPage = 1;
      _totalPages = 1;
      _isLoadingMoreVod = false;
      notifyListeners();
      await loadVodCatalog(resetCategories: false);
      return;
    }
    if (index >= _directoryBreadcrumbs.length) return;
    final target = _directoryBreadcrumbs[index];
    final nextBreadcrumbs = _directoryBreadcrumbs.sublist(0, index + 1);
    if (src != null &&
        _restoreCatalogSnapshotIfAvailable(
          src.id,
          target.typeId,
          breadcrumbsOverride: nextBreadcrumbs,
        )) {
      return;
    }
    _directoryBreadcrumbs = nextBreadcrumbs;
    _selectedTypeId = target.typeId;
    _vodItems = const [];
    _currentPage = 1;
    _totalPages = 1;
    _isLoadingMoreVod = false;
    notifyListeners();
    await loadVodCatalog(resetCategories: false);
  }

  Future<void> loadVodCatalog({
    bool resetCategories = false,
    bool forceRefresh = false,
  }) async {
    final src = _selectedSource;
    if (src == null) return;

    final requestedTypeId = _selectedTypeId;
    if (!forceRefresh &&
        _searchKeyword.isEmpty &&
        _vodItems.isEmpty &&
        _restoreCatalogSnapshotIfAvailable(
          src.id,
          requestedTypeId,
          breadcrumbsOverride: _directoryBreadcrumbs,
        )) {
      return;
    }

    final epoch = ++_vodCatalogEpoch;

    _isLoadingVod = true;
    _isLoadingMoreVod = false;
    _vodError = null;
    _currentPage = 1;
    notifyListeners();

    try {
      final resp = await api.fetchVodList(
        src,
        typeId: requestedTypeId,
        page: 1,
        forceRefresh: forceRefresh,
      );
      if (epoch != _vodCatalogEpoch || _selectedSource?.id != src.id) {
        return;
      }
      if (resetCategories || _categories.isEmpty) {
        if (resp.categories.isNotEmpty) {
          _categories = resp.categories;
          _categoriesBySourceId[src.id] =
              List<VodCategory>.unmodifiable(_categories);
        }
      }
      if (requestedTypeId.isEmpty &&
          resp.resolvedTypeId != null &&
          resp.resolvedTypeId!.isNotEmpty) {
        _selectedTypeId = resp.resolvedTypeId!;
      }
      _vodItems = resp.items;
      _currentPage = 1;
      _totalPages = resp.pageCount;
      _totalCount = resp.total;
      _isLoadingVod = false;
      _saveCurrentCatalogSnapshot();
      notifyListeners();
    } catch (e) {
      if (epoch != _vodCatalogEpoch) return;
      _isLoadingVod = false;
      _vodError = e.toString();
      notifyListeners();
    }
  }

  Future<void> loadMoreVod() async {
    final src = _selectedSource;
    if (src == null ||
        _isLoadingVod ||
        _isLoadingMoreVod ||
        _searchKeyword.isNotEmpty ||
        _currentPage >= _totalPages) {
      return;
    }

    final epoch = _vodCatalogEpoch;
    final requestedTypeId = _selectedTypeId;

    _isLoadingMoreVod = true;
    notifyListeners();

    try {
      final nextPage = _currentPage + 1;
      final resp = await api.fetchVodList(
        src,
        typeId: requestedTypeId,
        page: nextPage,
      );
      if (epoch != _vodCatalogEpoch ||
          _selectedSource?.id != src.id ||
          _selectedTypeId != requestedTypeId) {
        return;
      }

      final existingIds = _vodItems.map((e) => e.vodId).toSet();
      final newUniqueItems =
          resp.items.where((e) => !existingIds.contains(e.vodId)).toList();

      if (newUniqueItems.isEmpty) {
        // Reached the end of available unique items for this source/category
        _currentPage = nextPage;
        _totalPages = nextPage;
      } else {
        _vodItems = [..._vodItems, ...newUniqueItems];
        _currentPage = resp.page >= nextPage ? resp.page : nextPage;
        final inferredTotalPages = resp.pageCount >= _totalPages
            ? resp.pageCount
            : (resp.items.length >= 15 ? _currentPage + 1 : _currentPage);
        _totalPages = inferredTotalPages;
        if (resp.total > _totalCount) {
          _totalCount = resp.total;
        }
      }
      _saveCurrentCatalogSnapshot();
    } catch (_) {
      // Keep existing items on pagination failure
    } finally {
      if (epoch == _vodCatalogEpoch) {
        _isLoadingMoreVod = false;
        notifyListeners();
      }
    }
  }

  Future<void> clearSearch() async {
    if (_searchKeyword.isEmpty) return;
    _searchKeyword = '';
    _searchSourceFilterId = null;
    _isSearching = false;

    final snap = _preSearchSnapshot;
    final src = _selectedSource;
    if (snap != null && src != null && snap.sourceId == src.id) {
      _preSearchSnapshot = null;
      _vodCatalogEpoch++;
      _selectedTypeId = snap.selectedTypeId;
      _directoryBreadcrumbs = snap.directoryBreadcrumbs;
      if (snap.categories.isNotEmpty) {
        _categories = snap.categories;
      }
      _vodItems = snap.vodItems;
      _currentPage = snap.currentPage;
      _totalPages = snap.totalPages;
      _totalCount = snap.totalCount;
      _isLoadingVod = false;
      _isLoadingMoreVod = false;
      _vodError = null;
      notifyListeners();
      return;
    }

    if (src != null &&
        _restoreCatalogSnapshotIfAvailable(
          src.id,
          _selectedTypeId,
          breadcrumbsOverride: _directoryBreadcrumbs,
        )) {
      return;
    }

    notifyListeners();
    await loadVodCatalog(resetCategories: false);
  }

  void setSearchSourceFilterId(String? sourceId) {
    if (_searchSourceFilterId == sourceId) return;
    _searchSourceFilterId = sourceId;
    notifyListeners();
  }

  Future<void> togglePinSource(String sourceId) async {
    if (_pinnedSourceIds.contains(sourceId)) {
      _pinnedSourceIds.remove(sourceId);
    } else {
      _pinnedSourceIds.add(sourceId);
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _prefPinnedSourcesKey,
        _pinnedSourceIds.toList(),
      );
    } catch (_) {}
  }

  Future<void> toggleHideSource(String sourceId) async {
    if (_hiddenSourceIds.contains(sourceId)) {
      _hiddenSourceIds.remove(sourceId);
    } else {
      _hiddenSourceIds.add(sourceId);
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _prefHiddenSourcesKey,
        _hiddenSourceIds.toList(),
      );
    } catch (_) {}
  }

  Future<void> batchTestVodSources() async {
    if (_isTestingSources || _sources.isEmpty) return;
    _isTestingSources = true;
    notifyListeners();

    final targets = _sources.take(28).toList();
    final fastTargets =
        targets.where((s) => !s.isTvBox || s.tvboxType != 3).toList();
    final spiderTargets =
        targets.where((s) => s.isTvBox && s.tvboxType == 3).toList();

    Future<void> runBatch(
      List<VodSource> list,
      int concurrency,
      Duration timeout,
    ) async {
      for (var i = 0; i < list.length; i += concurrency) {
        final batch = list.skip(i).take(concurrency);
        await Future.wait(
          batch.map((src) async {
            final sw = Stopwatch()..start();
            try {
              final res =
                  await api.fetchVodList(src, page: 1).timeout(timeout);
              sw.stop();
              _sourceLatencyMs[src.id] =
                  (res.items.isNotEmpty || res.categories.isNotEmpty)
                      ? sw.elapsedMilliseconds
                      : -1;
            } catch (_) {
              sw.stop();
              _sourceLatencyMs[src.id] = -1;
            }
            notifyListeners();
          }),
        );
      }
    }

    await runBatch(fastTargets, 5, const Duration(milliseconds: 6000));
    await runBatch(spiderTargets, 2, const Duration(milliseconds: 9000));

    _isTestingSources = false;
    notifyListeners();
  }

  void sortSourcesByLatency() {
    if (_sourceLatencyMs.isEmpty) return;
    final copy = [..._sources];
    copy.sort((a, b) {
      final ap = _pinnedSourceIds.contains(a.id) ? 0 : 1;
      final bp = _pinnedSourceIds.contains(b.id) ? 0 : 1;
      if (ap != bp) return ap.compareTo(bp);
      final la = _sourceLatencyMs[a.id] ?? 99999;
      final lb = _sourceLatencyMs[b.id] ?? 99999;
      final effA = la <= 0 ? 999999 : la;
      final effB = lb <= 0 ? 999999 : lb;
      return effA.compareTo(effB);
    });
    _sources = copy;
    notifyListeners();
  }

  Future<void> performSearch(String keyword) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) {
      await clearSearch();
      return;
    }

    if (_searchKeyword.isEmpty &&
        _selectedSource != null &&
        _vodItems.isNotEmpty) {
      _saveCurrentCatalogSnapshot();
      _preSearchSnapshot = _VodCatalogViewSnapshot(
        sourceId: _selectedSource!.id,
        selectedTypeId: _selectedTypeId,
        directoryBreadcrumbs:
            List<DirectoryBreadcrumb>.unmodifiable(_directoryBreadcrumbs),
        categories: List<VodCategory>.unmodifiable(_categories),
        vodItems: List<VodItem>.unmodifiable(_vodItems),
        currentPage: _currentPage,
        totalPages: _totalPages,
        totalCount: _totalCount,
      );
    }

    _searchKeyword = trimmed;
    _isSearching = true;
    _isLoadingVod = true;
    _vodError = null;
    _vodItems = const [];
    _searchCompletedSources = 0;
    _searchTotalSources = 1;
    notifyListeners();

    if (!_aggregatedSearch || _sources.length <= 1) {
      final src = _selectedSource;
      if (src == null) {
        _isSearching = false;
        _isLoadingVod = false;
        notifyListeners();
        return;
      }
      try {
        final results = await api.searchVod(src, trimmed);
        _vodItems = results;
        _totalCount = results.length;
        _currentPage = 1;
        _totalPages = 1;
      } catch (e) {
        _vodError = e.toString();
      } finally {
        _isSearching = false;
        _isLoadingVod = false;
        _searchCompletedSources = 1;
        notifyListeners();
      }
      return;
    }

    // Multi-source aggregated search: prioritize standard CMS & TVBox type 1/0/4 first,
    // and cap Java spider (`tvboxType == 3`) concurrency to 2 to avoid saturating TVBoxJarBridge.
    final fastSearchable = _sources
        .where(
          (s) =>
              s.searchable &&
              s.id != _selectedSource?.id &&
              (!s.isTvBox || s.tvboxType != 3),
        )
        .toList();
    final spiderSearchable = _sources
        .where(
          (s) =>
              s.searchable &&
              s.id != _selectedSource?.id &&
              s.isTvBox &&
              s.tvboxType == 3,
        )
        .take(4)
        .toList();

    final searchableSources = <VodSource>[
      if (_selectedSource != null) _selectedSource!,
      ...fastSearchable,
      ...spiderSearchable,
    ].take(18).toList();

    _searchTotalSources = searchableSources.length;
    notifyListeners();

    final aggregated = <VodItem>[];
    var idx = 0;
    while (idx < searchableSources.length) {
      if (_searchKeyword != trimmed) break;
      final firstInBatch = searchableSources[idx];
      final batchSize =
          (firstInBatch.isTvBox && firstInBatch.tvboxType == 3) ? 2 : 6;
      final batch = searchableSources.skip(idx).take(batchSize).toList();
      idx += batch.length;
      await Future.wait(
        batch.map((src) async {
          try {
            final items = await api.searchVod(src, trimmed);
            if (_searchKeyword == trimmed && items.isNotEmpty) {
              aggregated.addAll(items.map((e) => e.withSource(src)));
              _vodItems = List<VodItem>.unmodifiable(aggregated);
              _totalCount = _vodItems.length;
            }
          } catch (_) {
            // Ignore failed individual source during aggregated search
          } finally {
            _searchCompletedSources++;
            notifyListeners();
          }
        }),
      );
    }

    _isSearching = false;
    _isLoadingVod = false;
    notifyListeners();
  }

  /// Resolve a library source key (`custom_0` or `tvbox_10`) back to a `VodSource`
  VodSource? findSourceByLibraryKey(String key) {
    for (final s in _sources) {
      if (s.librarySourceKey == key || s.id == key) {
        return s;
      }
    }
    return _selectedSource;
  }

  // Library (Favorites & History)
  String _libraryItemKey(String source, String vodId) =>
      '${source.trim()}|${vodId.trim()}';

  int _normalizeLibraryUpdatedMs(int rawUpdated) {
    if (rawUpdated <= 0) return 0;
    return rawUpdated < 10000000000 ? rawUpdated * 1000 : rawUpdated;
  }

  bool _isLibraryItemDeleted(String kind, LibraryItem item) {
    final key = _libraryItemKey(item.source, item.vodId);
    final updatedMs = _normalizeLibraryUpdatedMs(item.updated);
    if (kind == 'favorites') {
      if (_deletedFavoritesKeys.contains(key)) return true;
      if (_favoritesClearedAtMs > 0 &&
          (updatedMs == 0 || updatedMs <= _favoritesClearedAtMs)) {
        return true;
      }
      return false;
    } else {
      if (_deletedHistoryKeys.contains(key)) return true;
      if (_historyClearedAtMs > 0 &&
          (updatedMs == 0 || updatedMs <= _historyClearedAtMs)) {
        return true;
      }
      return false;
    }
  }

  Future<void> _persistLibraryTombstones() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefHistoryClearedAtMsKey, _historyClearedAtMs);
      await prefs.setInt(_prefFavoritesClearedAtMsKey, _favoritesClearedAtMs);
      await prefs.setStringList(
        _prefDeletedHistoryKeysKey,
        _deletedHistoryKeys.take(1000).toList(),
      );
      await prefs.setStringList(
        _prefDeletedFavoritesKeysKey,
        _deletedFavoritesKeys.take(1000).toList(),
      );
    } catch (_) {}
  }

  Future<void> _deleteItemsFromServer(
    String kind,
    Iterable<LibraryItem> items,
  ) async {
    final list = items.toList();
    const batchSize = 6;
    for (var i = 0; i < list.length; i += batchSize) {
      final batch = list.skip(i).take(batchSize);
      await Future.wait(
        batch.map((item) async {
          try {
            await api.deleteLibraryItem(
              kind,
              source: item.source,
              vodId: item.vodId,
            );
          } catch (_) {}
        }),
      );
    }
  }

  Future<void> refreshLibrary() async {
    _isLoadingLibrary = true;
    notifyListeners();
    try {
      final data = await api.fetchLibrary();
      final staleFavorites = <LibraryItem>[];
      final validFavorites = <LibraryItem>[];
      for (final f in data.favorites) {
        if (_isLibraryItemDeleted('favorites', f)) {
          staleFavorites.add(f);
        } else {
          validFavorites.add(f);
        }
      }

      final staleHistory = <LibraryItem>[];
      final validHistory = <LibraryItem>[];
      for (final h in data.history) {
        if (_isLibraryItemDeleted('history', h)) {
          staleHistory.add(h);
        } else {
          validHistory.add(h);
        }
      }

      _favorites = validFavorites;
      _history = validHistory;

      if (staleFavorites.isNotEmpty) {
        unawaited(_deleteItemsFromServer('favorites', staleFavorites));
      }
      if (staleHistory.isNotEmpty) {
        unawaited(_deleteItemsFromServer('history', staleHistory));
      }
    } catch (_) {
      // Ignore library error
    } finally {
      _isLoadingLibrary = false;
      notifyListeners();
    }
  }

  bool isFavorite(VodSource source, String vodId) {
    final key = source.librarySourceKey;
    return _favorites.any(
      (f) => f.vodId == vodId && (f.source == key || f.source == source.id),
    );
  }

  LibraryItem? findHistoryItem(VodSource source, String vodId) {
    final key = source.librarySourceKey;
    for (final h in _history) {
      if (h.vodId == vodId && (h.source == key || h.source == source.id)) {
        return h;
      }
    }
    return null;
  }

  Future<void> toggleFavorite({
    required VodSource source,
    required VodDetail detail,
    String currentEpisode = '',
    String currentLine = '',
  }) async {
    final fav = isFavorite(source, detail.vodId);
    final key = source.librarySourceKey;
    if (fav) {
      _deletedFavoritesKeys.add(_libraryItemKey(key, detail.vodId));
      _deletedFavoritesKeys.add(_libraryItemKey(source.id, detail.vodId));
      _favorites = _favorites
          .where(
            (f) => !(f.vodId == detail.vodId &&
                (f.source == key || f.source == source.id)),
          )
          .toList();
      notifyListeners();
      await _persistLibraryTombstones();
      try {
        await api.deleteLibraryItem(
          'favorites',
          source: key,
          vodId: detail.vodId,
        );
      } catch (_) {}
    } else {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      _deletedFavoritesKeys.remove(_libraryItemKey(key, detail.vodId));
      _deletedFavoritesKeys.remove(_libraryItemKey(source.id, detail.vodId));
      final item = LibraryItem(
        source: key,
        vodId: detail.vodId,
        title: detail.vodName,
        poster: detail.vodPic,
        remark: detail.vodRemarks,
        episode: currentEpisode,
        line: currentLine,
        updated: nowMs,
      );
      _favorites = [item, ..._favorites];
      notifyListeners();
      await _persistLibraryTombstones();
      try {
        await api.upsertLibraryItem('favorites', item);
      } catch (_) {}
    }
  }

  Future<void> recordWatchHistory({
    required VodSource source,
    required VodDetail detail,
    required String episodeTitle,
    required String lineName,
    required double positionSeconds,
    required double durationSeconds,
  }) async {
    final key = source.librarySourceKey;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _deletedHistoryKeys.remove(_libraryItemKey(key, detail.vodId));
    _deletedHistoryKeys.remove(_libraryItemKey(source.id, detail.vodId));
    final item = LibraryItem(
      source: key,
      vodId: detail.vodId,
      title: detail.vodName,
      poster: detail.vodPic,
      remark: detail.vodRemarks,
      episode: episodeTitle,
      line: lineName,
      position: positionSeconds,
      duration: durationSeconds,
      updated: nowMs,
    );
    _history = [
      item,
      ..._history.where(
        (h) => !(h.vodId == detail.vodId &&
            (h.source == key || h.source == source.id)),
      ),
    ];
    notifyListeners();
    unawaited(_persistLibraryTombstones());
    try {
      await api.upsertLibraryItem('history', item);
    } catch (_) {}
  }

  Future<void> deleteLibraryEntry(String kind, LibraryItem item) async {
    final itemKey = _libraryItemKey(item.source, item.vodId);
    if (kind == 'favorites') {
      _deletedFavoritesKeys.add(itemKey);
      _favorites = _favorites
          .where((f) => !(f.vodId == item.vodId && f.source == item.source))
          .toList();
    } else {
      _deletedHistoryKeys.add(itemKey);
      _history = _history
          .where((h) => !(h.vodId == item.vodId && h.source == item.source))
          .toList();
      _vodProgressMap.removeWhere(
        (k, _) =>
            k == '${item.source}::${item.vodId}' ||
            k.endsWith('::${item.vodId}'),
      );
      try {
        final prefs = await SharedPreferences.getInstance();
        final encoded = _vodProgressMap.map((k, v) => MapEntry(k, v.toJson()));
        await prefs.setString(_prefVodProgressMapKey, jsonEncode(encoded));
      } catch (_) {}
    }
    notifyListeners();
    await _persistLibraryTombstones();
    try {
      await api.deleteLibraryItem(
        kind,
        source: item.source,
        vodId: item.vodId,
      );
    } catch (_) {}
  }

  Future<void> clearLibraryKind(String kind) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final snapshot = kind == 'favorites'
        ? List<LibraryItem>.from(_favorites)
        : List<LibraryItem>.from(_history);

    if (kind == 'favorites') {
      _favoritesClearedAtMs = nowMs;
      for (final item in snapshot) {
        _deletedFavoritesKeys.add(_libraryItemKey(item.source, item.vodId));
      }
      _favorites = const [];
    } else {
      _historyClearedAtMs = nowMs;
      for (final item in snapshot) {
        _deletedHistoryKeys.add(_libraryItemKey(item.source, item.vodId));
      }
      _history = const [];
      _vodProgressMap.clear();
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_prefVodProgressMapKey);
      } catch (_) {}
    }
    notifyListeners();
    await _persistLibraryTombstones();

    // Merge with any items currently on the server and delete every item by (source, vod_id)
    final allToDelete = <String, LibraryItem>{
      for (final item in snapshot)
        _libraryItemKey(item.source, item.vodId): item,
    };
    try {
      final remote = await api.fetchLibrary();
      final remoteList =
          kind == 'favorites' ? remote.favorites : remote.history;
      for (final item in remoteList) {
        final k = _libraryItemKey(item.source, item.vodId);
        allToDelete[k] = item;
        if (kind == 'favorites') {
          _deletedFavoritesKeys.add(k);
        } else {
          _deletedHistoryKeys.add(k);
        }
      }
      await _persistLibraryTombstones();
    } catch (_) {}

    await _deleteItemsFromServer(kind, allToDelete.values);
    try {
      await api.deleteLibraryItem(kind);
    } catch (_) {}
  }

  Future<int> importLibraryBackup({
    required List<LibraryItem> favorites,
    required List<LibraryItem> history,
  }) async {
    var imported = 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final favMap = {
      for (final f in _favorites) '${f.source}|${f.vodId}': f,
    };
    for (final rawItem in favorites) {
      final item = LibraryItem(
        source: rawItem.source,
        vodId: rawItem.vodId,
        title: rawItem.title,
        poster: rawItem.poster,
        remark: rawItem.remark,
        episode: rawItem.episode,
        line: rawItem.line,
        position: rawItem.position,
        duration: rawItem.duration,
        updated: rawItem.updated > nowMs ? rawItem.updated : nowMs,
      );
      final k = _libraryItemKey(item.source, item.vodId);
      _deletedFavoritesKeys.remove(k);
      favMap[k] = item;
      imported++;
      try {
        await api.upsertLibraryItem('favorites', item);
      } catch (_) {}
    }
    _favorites = favMap.values.toList();

    final histMap = {
      for (final h in _history) '${h.source}|${h.vodId}': h,
    };
    for (final rawItem in history) {
      final item = LibraryItem(
        source: rawItem.source,
        vodId: rawItem.vodId,
        title: rawItem.title,
        poster: rawItem.poster,
        remark: rawItem.remark,
        episode: rawItem.episode,
        line: rawItem.line,
        position: rawItem.position,
        duration: rawItem.duration,
        updated: rawItem.updated > nowMs ? rawItem.updated : nowMs,
      );
      final k = _libraryItemKey(item.source, item.vodId);
      _deletedHistoryKeys.remove(k);
      histMap[k] = item;
      imported++;
      try {
        await api.upsertLibraryItem('history', item);
      } catch (_) {}
    }
    _history = histMap.values.toList();
    notifyListeners();
    await _persistLibraryTombstones();
    return imported;
  }

  // Live TV
  Future<void> loadLiveSources() async {
    _isLoadingLive = true;
    _liveError = null;
    notifyListeners();
    try {
      List<LiveSource> serverLives = const [];
      try {
        serverLives = await api.fetchLiveSources();
      } catch (e) {
        if (_customLiveSources.isEmpty) rethrow;
      }

      final combined = <LiveSource>[
        ..._customLiveSources,
        ...serverLives,
      ];
      _liveSources = combined;

      if (combined.isEmpty) {
        _liveChannels = const [];
        _isLoadingLive = false;
        notifyListeners();
        return;
      }

      // Build candidate order: preferred/saved source first, then active non-loopback sources
      final orderedCandidates = <LiveSource>[];
      void addCandidate(LiveSource? s) {
        if (s != null && !orderedCandidates.any((x) => x.key == s.key)) {
          orderedCandidates.add(s);
        }
      }

      if (_selectedLiveSource != null) {
        for (final s in combined) {
          if (s.key == _selectedLiveSource!.key) {
            addCandidate(s);
            break;
          }
        }
      }
      if (_savedLiveSourceKey != null &&
          _savedLiveSourceKey!.isNotEmpty &&
          _savedLiveSourceKey != 'tvbox_0_0' &&
          _savedLiveSourceKey != 'tvbox_0_1') {
        for (final s in combined) {
          if (s.key == _savedLiveSourceKey) {
            addCandidate(s);
            break;
          }
        }
      }
      // Prefer active aggregated live sources before archived `fanmingming/live`
      for (final s in combined) {
        final urlLower = s.url.toLowerCase();
        if (!urlLower.contains('127.0.0.1') &&
            !urlLower.contains('localhost') &&
            !urlLower.contains('fanmingming/live')) {
          addCandidate(s);
        }
      }
      for (final s in combined) {
        if (!s.url.contains('127.0.0.1') && !s.url.contains('localhost')) {
          addCandidate(s);
        }
      }
      for (final s in combined) {
        addCandidate(s);
      }

      Object? lastErr;
      for (final candidate in orderedCandidates) {
        _selectedLiveSource = candidate;
        notifyListeners();
        try {
          final channels = await api.fetchLiveChannels(
            candidate,
            preferClientDirect: true,
          );
          if (channels.isNotEmpty) {
            _liveChannels = channels;
            _liveError = null;
            _isLoadingLive = false;
            _savedLiveSourceKey = candidate.key;
            notifyListeners();
            try {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString(_prefSelectedLiveSourceKey, candidate.key);
            } catch (_) {}
            return;
          }
        } catch (e) {
          lastErr = e;
        }
      }

      _liveChannels = const [];
      _isLoadingLive = false;
      _liveError = lastErr?.toString() ?? '未能从当前直播源解析出有效频道';
      notifyListeners();
    } catch (e) {
      _isLoadingLive = false;
      _liveError = e.toString();
      notifyListeners();
    }
  }

  Future<void> selectLiveSource(
    LiveSource source, {
    bool preferClientDirect = true,
  }) async {
    _selectedLiveSource = source;
    _savedLiveSourceKey = source.key;
    _isLoadingLive = true;
    _liveError = null;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefSelectedLiveSourceKey, source.key);
    } catch (_) {}

    try {
      _liveChannels = await api.fetchLiveChannels(
        source,
        preferClientDirect: preferClientDirect,
      );
      _isLoadingLive = false;
      notifyListeners();
    } catch (e) {
      _liveChannels = const [];
      _isLoadingLive = false;
      _liveError = e.toString();
      notifyListeners();
    }
  }

  Future<void> addCustomLiveSource({
    required String name,
    required String url,
    String ua = '',
  }) async {
    final cleanName = name.trim().isEmpty ? '自定义直播源' : name.trim();
    final cleanUrl = url.trim();
    if (cleanUrl.isEmpty) return;

    final newSource = LiveSource(
      name: cleanName,
      url: cleanUrl,
      sourceIndex: -1,
      liveIndex: _customLiveSources.length,
      sourceName: '本地直连',
      ua: ua.trim(),
      isCustom: true,
    );

    _customLiveSources = [
      newSource,
      ..._customLiveSources.where((s) => s.url != cleanUrl),
    ];
    _liveSources = [
      ..._customLiveSources,
      ..._liveSources.where((s) => !s.isCustom),
    ];
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefCustomLiveSourcesKey,
        jsonEncode(_customLiveSources.map((s) => s.toJson()).toList()),
      );
    } catch (_) {}

    await selectLiveSource(newSource, preferClientDirect: true);
  }

  Future<void> removeCustomLiveSource(LiveSource source) async {
    if (!source.isCustom) return;
    _customLiveSources =
        _customLiveSources.where((s) => s.key != source.key).toList();
    _liveSources = _liveSources.where((s) => s.key != source.key).toList();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefCustomLiveSourcesKey,
        jsonEncode(_customLiveSources.map((s) => s.toJson()).toList()),
      );
    } catch (_) {}

    if (_selectedLiveSource?.key == source.key) {
      if (_liveSources.isNotEmpty) {
        await selectLiveSource(_liveSources.first);
      } else {
        _selectedLiveSource = null;
        _liveChannels = const [];
        notifyListeners();
      }
    } else {
      notifyListeners();
    }
  }

  // Download Tasks
  Future<void> refreshDownloadTasks({bool silent = false}) async {
    if (!silent) {
      _isLoadingTasks = true;
      notifyListeners();
    }
    try {
      final list = await api.fetchDownloadTasks();
      _tasks = list;
    } catch (_) {
      // Keep last known tasks on background poll error
    } finally {
      if (!silent) {
        _isLoadingTasks = false;
      }
      notifyListeners();
    }
  }

  // Media Library
  Future<void> loadFiles({String path = ''}) async {
    _isLoadingFiles = true;
    _filesError = null;
    notifyListeners();
    try {
      _currentDirectory = await api.fetchFiles(path: path);
      _isLoadingFiles = false;
      notifyListeners();
    } catch (e) {
      _isLoadingFiles = false;
      _filesError = e.toString();
      notifyListeners();
    }
  }

  // Server Settings
  Future<void> refreshServerSettings() async {
    try {
      _serverSettings = await api.fetchServerSettings();
      notifyListeners();
    } catch (_) {}
  }

  // VOD Ad-Skipping Settings
  Future<void> setVodAdSettings({
    bool? filterM3u8Ads,
    int? skipIntroSeconds,
    int? skipOutroSeconds,
  }) async {
    if (filterM3u8Ads != null) _vodFilterM3u8Ads = filterM3u8Ads;
    if (skipIntroSeconds != null) {
      _vodSkipIntroSeconds = skipIntroSeconds.clamp(0, 600);
    }
    if (skipOutroSeconds != null) {
      _vodSkipOutroSeconds = skipOutroSeconds.clamp(0, 600);
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (filterM3u8Ads != null) {
        await prefs.setBool(_prefVodFilterM3u8AdsKey, _vodFilterM3u8Ads);
      }
      if (skipIntroSeconds != null) {
        await prefs.setInt(_prefVodSkipIntroSecKey, _vodSkipIntroSeconds);
      }
      if (skipOutroSeconds != null) {
        await prefs.setInt(_prefVodSkipOutroSecKey, _vodSkipOutroSeconds);
      }
    } catch (_) {}
  }

  Future<void> setTvMode(bool enabled) async {
    if (_tvMode == enabled) return;
    _tvMode = enabled;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefTvModeKey, enabled);
    } catch (_) {}
  }

  // Mini-Player Management
  void startMiniPlayer(MiniPlayerSession session) {
    _miniPlayerSession = session;
    notifyListeners();
  }

  void closeMiniPlayer() {
    if (_miniPlayerSession == null) return;
    _miniPlayerSession = null;
    notifyListeners();
  }

  VodSource? resolveLibrarySource(LibraryItem item) {
    for (final s in _sources) {
      if (s.librarySourceKey == item.source || s.id == item.source) {
        return s;
      }
    }
    return _selectedSource;
  }

  // Exact VOD Playback Progress Management
  VodPlaybackProgress? getVodProgress(String sourceKey, String vodId) {
    if (sourceKey.isEmpty || vodId.isEmpty) return null;
    return _vodProgressMap['$sourceKey::$vodId'];
  }

  Future<void> saveVodProgress({
    required String sourceKey,
    required String vodId,
    required int groupIndex,
    required int episodeIndex,
    required String episodeName,
    required int positionSeconds,
    required int durationSeconds,
  }) async {
    if (sourceKey.isEmpty || vodId.isEmpty) return;
    final key = '$sourceKey::$vodId';
    _vodProgressMap[key] = VodPlaybackProgress(
      groupIndex: groupIndex,
      episodeIndex: episodeIndex,
      episodeName: episodeName,
      positionSeconds: positionSeconds,
      durationSeconds: durationSeconds,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    // Keep at most 400 recent items
    if (_vodProgressMap.length > 400) {
      final entries = _vodProgressMap.entries.toList()
        ..sort((a, b) => b.value.updatedAtMs.compareTo(a.value.updatedAtMs));
      _vodProgressMap = Map.fromEntries(entries.take(350));
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = _vodProgressMap.map((k, v) => MapEntry(k, v.toJson()));
      await prefs.setString(_prefVodProgressMapKey, jsonEncode(encoded));
    } catch (_) {}
  }
}

class _VodCatalogViewSnapshot {
  final String sourceId;
  final String selectedTypeId;
  final List<DirectoryBreadcrumb> directoryBreadcrumbs;
  final List<VodCategory> categories;
  final List<VodItem> vodItems;
  final int currentPage;
  final int totalPages;
  final int totalCount;

  const _VodCatalogViewSnapshot({
    required this.sourceId,
    required this.selectedTypeId,
    required this.directoryBreadcrumbs,
    required this.categories,
    required this.vodItems,
    required this.currentPage,
    required this.totalPages,
    required this.totalCount,
  });
}
