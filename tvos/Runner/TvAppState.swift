import AVFoundation
import Compression
import Foundation
import MediaPlayer
import Network
import SwiftUI
import UIKit

@MainActor
final class TvAppState: ObservableObject {
  static weak var shared: TvAppState? = nil
  @Published var serverUrl: String {
    didSet { UserDefaults.standard.set(serverUrl, forKey: "tv_server_url") }
  }
  @Published var authSecret: String {
    didSet { UserDefaults.standard.set(authSecret, forKey: "tv_auth_secret") }
  }
  @Published var enableAdFilter: Bool {
    didSet { UserDefaults.standard.set(enableAdFilter, forKey: "tv_ad_filter") }
  }
  @Published var preferDirectPlayback: Bool
  @Published var skipIntroSeconds: Int
  @Published var skipOutroSeconds: Int
  @Published var isAuthenticated: Bool = false
  @Published var isBootstrapping: Bool = false
  @Published var statusBanner: String? = nil
  @Published var toastMessage: String? = nil
  @Published var ambientBackdropUrl: String = ""
  @Published var lastPrimarySection: TvMainSection = .vod
  @Published var selectedSection: TvMainSection = .vod {
    didSet {
      if selectedSection != .proxy && selectedSection != .settings {
        lastPrimarySection = selectedSection
      }
    }
  }
  @Published var watchHistoryEnabled: Bool = true
  @Published var sourceLatencyMs: [String: Int] = [:]
  @Published var testingSourceIds: Set<String> = []
  @Published var isTestingSources: Bool = false
  @Published var pinnedSourceIds: Set<String> = []
  @Published var aiProvider: String = "openai"
  @Published var aiApiKey: String = ""
  @Published var aiBaseUrl: String = ""
  @Published var aiModel: String = ""
  @Published var liveGuideCollapsed: Bool = false
  @Published var liveFullscreenControlsVisible: Bool = true
  @Published var liveChannelListScrolledDown: Bool = false
  @Published var liveScrollToTopTrigger: Int = 0
  @Published var vodIsScrolledDown: Bool = false
  @Published var vodScrollToTopTrigger: Int = 0
  @Published var detailShowSourceShelf: Bool = false
  @Published var detailDownloadMode: Bool = false
  @Published var detailIsScrolledDown: Bool = false
  @Published var detailScrollToTopTrigger: Int = 0
  @Published var playerControlsVisible: Bool = true
  @Published var playerShowEpisodeDrawer: Bool = false
  @Published var galleryControlsVisible: Bool = true
  @Published var telegramChatListScrolledDown: Bool = false
  @Published var telegramScrollToTopTrigger: Int = 0
  @Published var isTopNavBarFocused: Bool = false
  @Published var pageScrollToTopTrigger: Int = 0
  @Published var topBarFocusTrigger: Int = 0
  @Published var remoteActivityTick: Int = 0
  var lastRemoteActivityAt: Date = Date()
  var lastControlsManualHideAt: Date = .distantPast
  @Published var themeId: String = "ocean_dark"
  @Published var subscriptionHistory: [String] = []
  @Published var lanInputUrl: String = ""
  @Published var lanInputRunning: Bool = false
  @Published var activeLanQuickInputPrompt: String = ""
  @Published var activeLanQuickInputPlaceholder: String = ""
  @Published var showLanQuickInputModal: Bool = false
  var activeLanQuickInputReceiver: ((String) -> Void)? = nil
  var customBackHandler: (() -> Bool)? = nil
  var scrollWindowToTopHandler: (() -> Bool)? = nil
  var exitApplicationHandler: (() -> Void)? = nil
  var liveFullscreenChannelStepHandler: ((Int) -> Void)? = nil
  var videoDirectSeekHandler: ((Int) -> Void)? = nil
  var isPlayerScrubberFocused: Bool = true
  var isAppInBackground: Bool = false
  @Published var foregroundResumeTick: Int = 0
  private var lastLiveChannelStepAt: Date = .distantPast
  private var lanListener: NWListener? = nil

  func handleDidEnterBackground() {
    guard !isAppInBackground else { return }
    isAppInBackground = true
    let hasActiveBackgroundAudio = isCloudMusicPlaying || isAudioPlaying
    if !hasActiveBackgroundAudio {
      api.handleEnterBackground()
    }
    stopLanInputServer()
    TvTelegramAvatarMemoryCache.shared.handleAppLifecycleTransition(enteringBackground: true)
    // Keep Cloud Hi-Fi Music and Telegram Audio playing in the background (tvOS UIBackgroundModes: audio)
    if hasActiveBackgroundAudio {
      try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.allowAirPlay])
      try? AVAudioSession.sharedInstance().setActive(true)
      updateNowPlayingInfo()
    }
  }

  func handleDidBecomeActive() {
    UIApplication.shared.isIdleTimerDisabled = true
    let wasInBackground = isAppInBackground
    isAppInBackground = false
    lastRemoteActivityAt = Date()
    api.handleEnterForeground()
    TvTelegramAvatarMemoryCache.shared.handleAppLifecycleTransition(enteringBackground: false)
    guard wasInBackground else { return }
    // Defer media stream reconnection by 0.25s so the UI and focus system render the foreground frame in 0ms
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self = self, !self.isAppInBackground else { return }
      self.foregroundResumeTick &+= 1
      if self.isAudioPlaying {
        self.audioPlayer?.play()
      }
      if self.isCloudMusicPlaying {
        self.cloudMusicPlayer?.playImmediately(atRate: self.cloudMusicSpeed)
      }
      guard self.isAuthenticated, !self.isBootstrapping else { return }
      Task { @MainActor in
        if self.vodSources.isEmpty {
          await self.bootstrapAll()
        } else {
          if self.vodItems.isEmpty, !self.isLoadingVod, let src = self.selectedSource {
            await self.loadVodList(
              source: src,
              page: max(1, self.currentPage),
              categoryId: self.selectedCategoryId,
              resetCategories: self.categories.isEmpty
            )
          }
          if (self.liveSources.isEmpty || self.liveChannels.isEmpty), !self.isLoadingLive {
            await self.loadLiveSources()
          }
        }
      }
    }
  }

  var activeTheme: TvThemePalette {
    TvThemePalette.palette(for: themeId)
  }

  var appShortVersion: String {
    guard let version = bundleValue(forKey: "CFBundleShortVersionString") else {
      return "版本未知"
    }
    return "v\(version)"
  }

  var appFullVersion: String {
    guard let buildNumber = bundleValue(forKey: "CFBundleVersion") else {
      return appShortVersion
    }
    return "\(appShortVersion) (Build \(buildNumber))"
  }

  private func bundleValue(forKey key: String) -> String? {
    let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (value.isEmpty || value.contains("$(")) ? nil : value
  }

  func setTheme(_ id: String) {
    let palette = TvThemePalette.palette(for: id)
    TvThemePalette.current = palette
    themeId = palette.id
    defaults.set(palette.id, forKey: "tv_theme_id")
    showToast("🎨 已切换主题：\(palette.name)（\(palette.subtitle)）")
  }

  func cycleTheme() {
    let presets = TvThemePalette.presets
    let curIdx = presets.firstIndex(where: { $0.id == themeId }) ?? 0
    let next = presets[(curIdx + 1) % presets.count]
    setTheme(next.id)
  }

  func triggerLiveFullscreenChannelStep(_ delta: Int) {
    let now = Date()
    guard now.timeIntervalSince(lastLiveChannelStepAt) >= 0.22 else { return }
    lastLiveChannelStepAt = now
    if activePlayback?.isLive == true {
      stepActiveLivePlaybackChannel(delta: delta)
      return
    }
    liveFullscreenChannelStepHandler?(delta)
  }

  func triggerVideoDirectSeek(direction: Int) {
    lastRemoteActivityAt = Date()
    if activePlayback != nil && !playerControlsVisible {
      playerControlsVisible = true
    } else if activeTelegramGallery != nil && !galleryControlsVisible {
      galleryControlsVisible = true
    }
    videoDirectSeekHandler?(direction)
  }

  func registerRemoteInteraction() {
    let now = Date()
    guard now.timeIntervalSince(lastControlsManualHideAt) > 0.75 else { return }
    lastRemoteActivityAt = now
    // Only broadcast a @Published state change when a fullscreen player's controls are hidden and need waking up.
    // Never fire objectWillChange during normal scrolling/focus navigation in VOD, Live Guide, or Telegram!
    if activePlayback != nil && !playerControlsVisible {
      playerControlsVisible = true
      remoteActivityTick &+= 1
    } else if activeTelegramGallery != nil && !galleryControlsVisible {
      galleryControlsVisible = true
      remoteActivityTick &+= 1
    } else if selectedSection == .live && liveGuideCollapsed && !liveFullscreenControlsVisible {
      liveFullscreenControlsVisible = true
      remoteActivityTick &+= 1
    }
  }

  // 1. VOD
  @Published var vodSources: [TvVodSource] = []
  @Published var selectedSource: TvVodSource? = nil
  @Published var categories: [TvVodCategory] = []
  @Published var selectedCategoryId: String? = nil
  @Published var vodCategoriesExpanded: Bool = false
  @Published var vodCategoryGroupTab: String = "全部"
  @Published var vodCategoryFilterQuery: String = ""
  @Published var vodItems: [TvVodItem] = []
  @Published var currentPage: Int = 1
  @Published var totalPages: Int = 1
  @Published var hasMoreVodPages: Bool = true
  @Published var isLoadingVod: Bool = false
  @Published var isLoadingMoreVod: Bool = false
  @Published var searchKeyword: String = ""
  @Published var isAggregateSearch: Bool = true
  private var homeFallbackCategoryIdx: Int = 0
  private var homeFallbackCategoryPage: Int = 0

  // Detail & Active Playback
  @Published var selectedDetailItem: TvVodItem? = nil
  @Published var activePlayback: TvPlaybackRequest? = nil {
    didSet {
      if activePlayback != nil {
        stopBackgroundAudioForVideoPlayback()
      }
    }
  }
  @Published var activeTelegramGallery: TvTelegramGallerySession? = nil {
    didSet {
      if let gallery = activeTelegramGallery,
         gallery.mediaMessages.indices.contains(gallery.initialIndex),
         gallery.mediaMessages[gallery.initialIndex].attachment?.isVideo == true {
        stopBackgroundAudioForVideoPlayback()
      }
    }
  }
  @Published var isResolvingPlay: Bool = false

  // 2. Live TV
  @Published var liveSources: [TvLiveSource] = []
  @Published var selectedLiveSource: TvLiveSource? = nil
  @Published var liveChannels: [TvLiveChannel] = [] {
    didSet { rebuildLiveChannelCaches() }
  }
  @Published var selectedLiveGroup: String = "全部" {
    didSet {
      defaults.set(selectedLiveGroup, forKey: "tv_selected_live_group")
      rebuildFilteredLiveChannelsCache()
    }
  }
  @Published var liveSearchKeyword: String = "" {
    didSet { rebuildFilteredLiveChannelsCache() }
  }
  @Published var isLoadingLive: Bool = false
  @Published var favoriteLiveChannelIds: Set<String> = [] {
    didSet { rebuildLiveChannelCaches() }
  }
  @Published var lastLiveChannelId: String = ""
  private var preferredLiveUrlIndices: [String: Int] = [:]
  private var cachedLiveGroups: [String] = ["全部"]
  private var cachedLiveGroupCounts: [String: Int] = ["全部": 0]
  private var cachedFilteredLiveChannels: [TvLiveChannel] = []
  private var cachedLiveChannelIndexMap: [String: Int] = [:]

  // 3. Library (Favorites & History)
  @Published var favorites: [TvLibraryItem] = []
  @Published var history: [TvLibraryItem] = []

  // 4. Telegram (1:1 Official Telegram Desktop / macOS / Apple TV State)
  @Published var telegramAccounts: [TvTelegramAccount] = []
  @Published var activeTelegramAccountId: String = "default"
  @Published var telegramAuthStatus: TvTelegramAuthStatus = TvTelegramAuthStatus()
  @Published var telegramFolders: [TvTelegramFolder] = [
    TvTelegramFolder(key: "0", title: "全部会话", emoji: ""),
    TvTelegramFolder(key: "1", title: "已归档", emoji: "")
  ]
  @Published var selectedTelegramFolderKey: String = "0"
  @Published var telegramChats: [TvTelegramChat] = [] {
    didSet { rebuildTelegramChatCaches() }
  }
  @Published var nextTelegramChatCursor: String = ""
  @Published var telegramChatFilter: String = "" {
    didSet { rebuildTelegramChatCaches() }
  }
  @Published var selectedTelegramChat: TvTelegramChat? = nil
  @Published var telegramMessages: [TvTelegramMessage] = [] {
    didSet { rebuildTelegramMessageCaches() }
  }
  @Published var nextTelegramMessageOffset: Int = 0
  @Published var telegramMediaFilter: String = "all" { // all, video, photo, music, file
    didSet { rebuildTelegramMessageCaches() }
  }
  @Published var telegramMessageKeyword: String = "" {
    didSet { rebuildTelegramMessageCaches() }
  }
  private var cachedFilteredTelegramChats: [TvTelegramChat] = []
  private var cachedFilteredTelegramMessages: [TvTelegramMessage] = []
  private var cachedGroupedTelegramEntries: [TvTelegramMessageGroup] = []
  private(set) var cachedTelegramVideoCount: Int = 0
  private(set) var cachedTelegramPhotoCount: Int = 0
  private(set) var cachedTelegramMusicCount: Int = 0
  @Published var telegramInChatSearchOpen: Bool = false
  @Published var telegramSidebarCollapsed: Bool = false
  @Published var telegramShowRightInfoPanel: Bool = false
  @Published var telegramRightPanelTab: String = "video" // video, photo, music, file, link
  @Published var telegramSelectionMode: Bool = false
  @Published var telegramSelectedMessageIds: Set<Int> = []
  @Published var telegramReplyingTo: TvTelegramMessage? = nil
  @Published var telegramDrafts: [String: String] = [:]
  @Published var telegramMutedPeers: Set<String> = []
  var knownPeerSharpAvatars: [String: (photoId: String, dcId: Int, hdUrl: String)] = [:]
  var knownTitleHdAvatarUrls: [String: String] = [:]
  var knownPeerPreviewAvatars: [String: String] = [:]
  var knownTitlePreviewAvatars: [String: String] = [:]
  var knownTelegramChatTitles: [String: String] = [:]
  @Published var telegramAvatarRegistryVersion: Int = 0
  @Published var telegramQuickReplies: [String] = [
    "收到，谢谢！👍",
    "感谢分享 ❤️",
    "求补档 🙏",
    "清晰度非常棒 🎬",
    "辛苦了！🙏",
    "好的，马上处理 ✅"
  ]
  @Published var activeTelegramFilePreview: TvTelegramFilePreview? = nil
  @Published var isLoadingTelegram: Bool = false

  // Telegram Pinned Top Audio / Music Player State
  @Published var playingAudioMessage: TvTelegramMessage? = nil
  @Published var playingAudioChat: TvTelegramChat? = nil
  @Published var isAudioPlaying: Bool = false
  @Published var audioPosition: Double = 0
  @Published var audioDuration: Double = 0
  @Published var audioSpeed: Float = 1.0
  @Published var audioPlayMode: String = "sequential" // sequential, repeatAll, repeatOne, shuffle

  // Telegram Floating Mini-Player PIP State
  @Published var miniPlayerMessage: TvTelegramMessage? = nil {
    didSet {
      if miniPlayerMessage != nil {
        stopBackgroundAudioForVideoPlayback()
      }
    }
  }
  @Published var miniPlayerChat: TvTelegramChat? = nil

  // 5. Downloads & Web Extract
  @Published var downloadTasks: [TvDownloadTask] = []
  @Published var isLoadingTasks: Bool = false
  @Published var extractedCandidates: [TvExtractedCandidate] = []
  @Published var isExtractingWeb: Bool = false

  // 6. Server Media Library & Multi-Storage File Manager (Server / AList / WebDAV / 115 / Local Cache)
  @Published var fileListing: TvFileListing = TvFileListing(path: "", parent: "", root: "/", entries: [])
  @Published var displayedFileEntries: [TvFileEntry] = []
  @Published var visibleFileLimit: Int = 80
  @Published var isLoadingFiles: Bool = false
  @Published var isLoadingMoreFiles: Bool = false
  @Published var fileManagerError: String? = nil
  @Published var storageMounts: [TvStorageMount] = []
  @Published var activeStorageMountId: String = "builtin_server"
  @Published var fileTransferTasks: [TvFileTransferTask] = []
  @Published var fileClipboard: TvFileClipboardItem? = nil
  @Published var fileFavoritePaths: [String] = [] // Format: "<mountId>::<name>::<path>"
  @Published var fileSortOption: TvFileSortOption = .dateDesc {
    didSet { recomputeDisplayedFileEntries() }
  }
  @Published var fileCategoryFilter: TvFileCategoryFilter = .all {
    didSet { recomputeDisplayedFileEntries() }
  }
  @Published var fileViewIsGrid: Bool = false
  @Published var fileSearchKeyword: String = "" {
    didSet { recomputeDisplayedFileEntries() }
  }
  @Published var fileMultiSelectMode: Bool = false
  @Published var fileSelectedPaths: Set<String> = []
  @Published var cloud115Breadcrumbs: [(cid: String, name: String)] = [("0", "115根目录")]
  private var loadFilesGeneration: Int = 0

  // 6b. Cloud Hi-Fi Music Player State (115 / AList / WebDAV / Server / Local Cache)
  @Published var cloudMusicQueue: [TvFileEntry] = []
  @Published var cloudMusicCurrentIndex: Int = -1
  @Published var isCloudMusicPlaying: Bool = false
  @Published var isCloudMusicLoading: Bool = false
  @Published var cloudMusicPosition: Double = 0
  @Published var cloudMusicDuration: Double = 0
  @Published var cloudMusicSpeed: Float = 1.0
  @Published var cloudMusicPlayMode: String = "repeatAll" // repeatAll, repeatOne, shuffle, sequential
  @Published var cloudMusicErrorText: String = ""
  @Published var cloudMusicSubtitle: String = ""
  @Published var cloudMusicCoverImage: UIImage? = nil
  @Published var cloudMusicLyrics: [TvCloudLrcLine] = []
  @Published var cloudMusicLyricsSource: String = ""
  @Published var isCloudMusicLoadingLyrics: Bool = false
  @Published var showCloudMusicFullscreen: Bool = false
  @Published var isCloudMusicSessionDocked: Bool = false
  @Published var savedMusicFolders: [TvSavedMusicFolderItem] = []
  @Published var savedMusicPlaylists: [TvSavedMusicPlaylist] = []
  @Published var activeMusicPlaylistId: String = "default_playlist"
  @Published var currentMusicQueueSources: [TvSavedMusicFolderItem] = []
  @Published var showMusicPlaylistManagerSheet: Bool = false
  @Published var isScanningMusicFolders: Bool = false
  @Published var scanningMusicStatusText: String = ""
  @Published var activeArchiveMusicBrowserEntry: TvFileEntry? = nil
  @Published var showMusicFolderPickerSheet: Bool = false
  @Published var showMusicSmartAiSheet: Bool = false
  @Published var musicSmartAiInitialTab: Int = 1
  @Published var musicSmartAiInitialSources: [TvSavedMusicFolderItem] = []
  @Published var cloudMusicVolume: Float = 1.0
  @Published var cloudMusicIsMuted: Bool = false
  @Published var speedBadgeCornerPreset: Int = 0 // 0: 右上, 1: 左上, 2: 右下, 3: 左下
  @Published var speedBadgeIsHidden: Bool = false
  @Published var speedBadgeIsClosed: Bool = false
  var latestMeasuredSpeedBytesPerSec: Double = 0.0
  var musicFolderPickerBackHandler: (() -> Bool)? = nil
  private var cloudMusicPlayer: AVPlayer? = nil
  private var cloudMusicTimeObserver: Any? = nil
  private var cloudMusicEndObserver: NSObjectProtocol? = nil
  private var cloudMusicFailObserver: NSObjectProtocol? = nil
  private var cloudMusicOpenSeq: Int = 0
  private var cloudMusicRetriedWithProxy: Bool = false
  private var cloudMusicDirectorySiblingsByKey: [String: [TvFileEntry]] = [:]
  private var archiveInspectionCache: [String: [TvFileEntry]] = [:]
  private var extractedArchiveTempFileCache: [String: URL] = [:]

  // 7. Proxy, Multi-Subscription & Scenario Routing (1:1 Parity with ProxyRoutingService)
  @Published var proxyEnabled: Bool = false
  @Published var proxySelectionMode: TvProxySelectionMode = .autoFastest
  @Published var subscriptions: [TvProxySubscription] = []
  @Published var updatingSubscriptionId: String? = nil
  @Published var scenarioRules: [TvRequestScenario: TvScenarioRuleConfig] = [:]
  @Published var vodRouteMode: TvRouteMode
  @Published var liveRouteMode: TvRouteMode
  @Published var telegramRouteMode: TvRouteMode
  @Published var subscriptionUrl: String
  @Published var subscriptionNodes: [TvSubscriptionNode] = []
  @Published var selectedProxyNodeId: String = ""
  @Published var isRefreshingSubscription: Bool = false
  @Published var backendProxyServices: [TvProxyServiceConfig] = []
  @Published var backendProxyStatuses: [TvProxyRuntimeStatus] = []
  @Published var showProxyStatsOverlay: Bool = false

  // 8. 115 Cloud Drive & Backend Settings + In-Player 115 Cloud Acceleration Pipeline
  @Published var is115LoggedIn: Bool = false
  @Published var user115Name: String = ""
  @Published var qr115Token: String = ""
  @Published var qr115Content: String = ""
  @Published var qr115ImageUrl: String = ""
  @Published var qr115StatusText: String = ""
  @Published var is115Accelerating: Bool = false
  @Published var accel115StageTitle: String = ""
  @Published var accel115DetailText: String = ""
  @Published var accel115Progress: Double = 0
  private var qr115Time: Int64 = 0
  private var qr115Sign: String = ""
  private var qr115CreatedAt: Date = .distantPast
  private var qr115OnLoginSuccess: (() -> Void)? = nil
  private var qr115PollTask: Task<Void, Never>? = nil
  private var accel115Task: Task<Void, Never>? = nil

  private let defaults = UserDefaults.standard
  private var localProgress: [String: Double] = [:]
  private var lastHistoryPersistAt: Date = .distantPast
  private var lastHistoryPersistKey: String = ""
  private var toastTask: Task<Void, Never>? = nil
  private var audioPlayer: AVPlayer? = nil
  private var audioTimeObserver: Any? = nil
  private var audioEndObserver: NSObjectProtocol? = nil

  var api: TvApiClient

  init() {
    let savedUrl = UserDefaults.standard.string(forKey: "tv_server_url") ?? "https://jp2.linsionwinwin.top:8081"
    let savedSecret = UserDefaults.standard.string(forKey: "tv_auth_secret") ?? ""
    let savedAdFilter = UserDefaults.standard.object(forKey: "tv_ad_filter") as? Bool ?? true
    let savedDirect = UserDefaults.standard.object(forKey: "tv_prefer_direct") as? Bool ?? true
    let savedIntro = UserDefaults.standard.object(forKey: "tv_skip_intro") as? Int ?? 0
    let savedOutro = UserDefaults.standard.object(forKey: "tv_skip_outro") as? Int ?? 0
    let savedVodRoute = TvRouteMode(rawValue: UserDefaults.standard.string(forKey: "tv_route_vod") ?? "direct") ?? .direct
    let savedLiveRoute = TvRouteMode(rawValue: UserDefaults.standard.string(forKey: "tv_route_live") ?? "direct") ?? .direct
    let savedTgRoute = TvRouteMode(rawValue: UserDefaults.standard.string(forKey: "tv_route_tg") ?? "direct") ?? .direct
    let defaultSub = "https://liangxin.xyz/api/v1/liangxin?token=4332903289b108cd7d99272b0f183d2e"
    let savedSubUrl = UserDefaults.standard.string(forKey: "tv_sub_url") ?? defaultSub
    let savedThemeId = UserDefaults.standard.string(forKey: "tv_theme_id") ?? "ocean_dark"
    let savedSubHist = UserDefaults.standard.stringArray(forKey: "tv_sub_history") ?? [defaultSub]

    self.serverUrl = savedUrl
    self.authSecret = savedSecret
    self.enableAdFilter = savedAdFilter
    self.preferDirectPlayback = savedDirect
    self.skipIntroSeconds = savedIntro
    self.skipOutroSeconds = savedOutro
    self.vodRouteMode = savedVodRoute
    self.liveRouteMode = savedLiveRoute
    self.telegramRouteMode = savedTgRoute
    self.subscriptionUrl = savedSubUrl
    self.themeId = savedThemeId
    self.subscriptionHistory = savedSubHist
    TvThemePalette.current = TvThemePalette.palette(for: savedThemeId)
    self.localProgress = (UserDefaults.standard.dictionary(forKey: "tv_watch_progress") as? [String: Double]) ?? [:]
    if let mutedArr = UserDefaults.standard.stringArray(forKey: "tv_tg_muted_peers") {
      self.telegramMutedPeers = Set(mutedArr)
    }
    if let savedTitles = UserDefaults.standard.dictionary(forKey: "tv_tg_known_chat_titles_v1") as? [String: String] {
      self.knownTelegramChatTitles = savedTitles
    }
    if let favLiveArr = UserDefaults.standard.stringArray(forKey: "tv_fav_live_channels") {
      self.favoriteLiveChannelIds = Set(favLiveArr)
    }
    if let savedLiveGrp = UserDefaults.standard.string(forKey: "tv_selected_live_group"), !savedLiveGrp.isEmpty {
      self.selectedLiveGroup = savedLiveGrp
    }
    self.lastLiveChannelId = UserDefaults.standard.string(forKey: "tv_last_live_channel_id") ?? ""
    self.preferredLiveUrlIndices = (UserDefaults.standard.dictionary(forKey: "tv_live_url_indices_v1") as? [String: Int]) ?? [:]
    if let savedLiveSrcData = UserDefaults.standard.data(forKey: "tv_selected_live_source_json"),
       let decodedLiveSrc = try? JSONDecoder().decode(TvLiveSource.self, from: savedLiveSrcData) {
      self.selectedLiveSource = decodedLiveSrc
    }
    if let cachedLiveData = Self.loadCachedLiveChannelsData(),
       let decodedChannels = try? JSONDecoder().decode([TvLiveChannel].self, from: cachedLiveData),
       !decodedChannels.isEmpty {
      self.liveChannels = decodedChannels
    }
    if let quickArr = UserDefaults.standard.stringArray(forKey: "tv_tg_quick_replies"), !quickArr.isEmpty {
      self.telegramQuickReplies = quickArr
    }
    self.api = TvApiClient(baseUrl: savedUrl, authSecret: savedSecret, preferDirectPlayback: savedDirect)
    self.isAuthenticated = !savedSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    Self.shared = self
    if !self.liveChannels.isEmpty {
      self.rebuildLiveChannelCaches()
    }

    // Load persisted multi-subscription & scenario routing state
    self.proxyEnabled = UserDefaults.standard.object(forKey: "tv_proxy_enabled") as? Bool ?? true
    if let modeRaw = UserDefaults.standard.string(forKey: "tv_proxy_selection_mode"),
       let mode = TvProxySelectionMode(rawValue: modeRaw) {
      self.proxySelectionMode = mode
    }
    self.selectedProxyNodeId = UserDefaults.standard.string(forKey: "tv_selected_proxy_node_id") ?? ""

    if let subData = UserDefaults.standard.data(forKey: "tv_proxy_subscriptions_v2"),
       let decodedSubs = try? JSONDecoder().decode([TvProxySubscription].self, from: subData),
       !decodedSubs.isEmpty {
      self.subscriptions = decodedSubs
    } else {
      // Migrate existing single subscriptionUrl + subscriptionHistory into multi-subscription list
      var initialSubs: [TvProxySubscription] = []
      var seenUrls = Set<String>()
      let candidates = ([savedSubUrl] + savedSubHist)
        .map { Self.normalizeSubscriptionInput($0) }
        .filter { !$0.isEmpty }
      for (idx, u) in candidates.enumerated() where seenUrls.insert(u).inserted {
        let host = URL(string: u)?.host ?? "机场订阅 \(idx + 1)"
        let name = idx == 0 ? "主力订阅 (\(host))" : "备用订阅 \(idx) (\(host))"
        initialSubs.append(
          TvProxySubscription(
            id: "sub_init_\(idx + 1)",
            name: name,
            url: u,
            enabled: true
          )
        )
      }
      self.subscriptions = initialSubs
      if let encoded = try? JSONEncoder().encode(initialSubs) {
        UserDefaults.standard.set(encoded, forKey: "tv_proxy_subscriptions_v2")
      }
    }

    if let nodeData = UserDefaults.standard.data(forKey: "tv_proxy_nodes_v2"),
       let decodedNodes = try? JSONDecoder().decode([TvSubscriptionNode].self, from: nodeData) {
      self.subscriptionNodes = decodedNodes
    }

    var defaultRules: [TvRequestScenario: TvScenarioRuleConfig] = [
      .vodApi: TvScenarioRuleConfig(scenario: .vodApi, mode: .direct),
      .vodStream: TvScenarioRuleConfig(scenario: .vodStream, mode: .direct),
      .liveStream: TvScenarioRuleConfig(scenario: .liveStream, mode: .direct),
      .telegram: TvScenarioRuleConfig(scenario: .telegram, mode: .proxyNode),
      .backendApi: TvScenarioRuleConfig(scenario: .backendApi, mode: .direct),
      .externalWeb: TvScenarioRuleConfig(scenario: .externalWeb, mode: .smartAuto),
    ]
    if let rulesData = UserDefaults.standard.data(forKey: "tv_proxy_scenario_rules_v2"),
       let decodedArr = try? JSONDecoder().decode([TvScenarioRuleConfig].self, from: rulesData) {
      for r in decodedArr {
        defaultRules[r.scenario] = r
      }
    }
    self.scenarioRules = defaultRules
    if let initialNode = self.fastestProxyNode ?? self.activeProxyNode {
      TvLocalProxyTunnelServer.shared.seedFallbackNode(initialNode)
    }

    // Load persisted storage mounts (Built-in Server, 115 Cloud Drive, Local Cache + custom AList / WebDAV mounts)
    let builtInMounts: [TvStorageMount] = [
      TvStorageMount(id: "builtin_server", name: "流光服务端", kind: .server, rootPath: "/", enabled: true),
      TvStorageMount(id: "builtin_115", name: "115 网盘直连", kind: .cloud115, rootPath: "0", enabled: true),
      TvStorageMount(id: "builtin_local", name: "Apple TV 本机缓存", kind: .localCache, rootPath: "/", enabled: true)
    ]
    if let mountData = UserDefaults.standard.data(forKey: "tv_storage_mounts_v1"),
       let customMounts = try? JSONDecoder().decode([TvStorageMount].self, from: mountData) {
      let filteredCustom = customMounts.filter { !$0.isBuiltIn }
      self.storageMounts = builtInMounts + filteredCustom
    } else {
      self.storageMounts = builtInMounts
    }
    if let savedMountId = UserDefaults.standard.string(forKey: "tv_active_storage_mount_id_v1"),
       self.storageMounts.contains(where: { $0.id == savedMountId }) {
      self.activeStorageMountId = savedMountId
    }
    if let savedFavPaths = UserDefaults.standard.stringArray(forKey: "tv_file_fav_paths_v1") {
      self.fileFavoritePaths = savedFavPaths
    }
    if let savedMusicData = UserDefaults.standard.data(forKey: "tv_saved_music_folders_v1"),
       let decodedMusic = try? JSONDecoder().decode([TvSavedMusicFolderItem].self, from: savedMusicData) {
      self.savedMusicFolders = decodedMusic
    }
    if let savedPlData = UserDefaults.standard.data(forKey: "tv_saved_music_playlists_v1"),
       let decodedPls = try? JSONDecoder().decode([TvSavedMusicPlaylist].self, from: savedPlData) {
      self.savedMusicPlaylists = decodedPls
    }
    if let savedActivePlId = UserDefaults.standard.string(forKey: "tv_active_music_playlist_id_v1"),
       !savedActivePlId.isEmpty {
      self.activeMusicPlaylistId = savedActivePlId
    }
    if let defaultQueueData = UserDefaults.standard.data(forKey: "tv_default_music_queue_v1"),
       let decodedQueue = try? JSONDecoder().decode([TvFileEntry].self, from: defaultQueueData),
       !decodedQueue.isEmpty {
      self.cloudMusicQueue = decodedQueue
      let savedIdx = UserDefaults.standard.integer(forKey: "tv_default_music_index_v1")
      self.cloudMusicCurrentIndex = min(max(0, savedIdx), decodedQueue.count - 1)
    }
    if let defaultSrcData = UserDefaults.standard.data(forKey: "tv_default_music_sources_v1"),
       let decodedSrc = try? JSONDecoder().decode([TvSavedMusicFolderItem].self, from: defaultSrcData) {
      self.currentMusicQueueSources = decodedSrc
    }
    if self.cloudMusicQueue.isEmpty, let firstPl = self.savedMusicPlaylists.first(where: { $0.id == self.activeMusicPlaylistId }) ?? self.savedMusicPlaylists.first, !firstPl.tracks.isEmpty {
      self.activeMusicPlaylistId = firstPl.id
      self.cloudMusicQueue = firstPl.tracks
      self.cloudMusicCurrentIndex = min(max(0, firstPl.currentIndex), firstPl.tracks.count - 1)
      self.currentMusicQueueSources = firstPl.sources
    }
    self.fileViewIsGrid = UserDefaults.standard.bool(forKey: "tv_file_view_grid_v1")
    self.watchHistoryEnabled = UserDefaults.standard.object(forKey: "tv_watch_history_enabled") as? Bool ?? true
    if let pinnedArr = UserDefaults.standard.stringArray(forKey: "tv_pinned_sources_v1") {
      self.pinnedSourceIds = Set(pinnedArr)
    }
    self.aiProvider = UserDefaults.standard.string(forKey: "tv_ai_provider_v1") ?? "openai"
    self.aiApiKey = UserDefaults.standard.string(forKey: "tv_ai_api_key_v1") ?? ""
    self.aiBaseUrl = UserDefaults.standard.string(forKey: "tv_ai_base_url_v1") ?? ""
    self.aiModel = UserDefaults.standard.string(forKey: "tv_ai_model_v1") ?? ""
    setupRemoteTransportCommands()
    syncDefaultCloudMusicPlaylist(persist: false)
    if let track = currentCloudMusicTrack {
      loadCloudMusicCoverAndLyrics(for: track, seq: cloudMusicOpenSeq)
    }
  }

  private var remoteCommandsConfigured: Bool = false
  private var lastNowPlayingUpdateAt: Date = .distantPast

  func setupRemoteTransportCommands() {
    guard !remoteCommandsConfigured else { return }
    remoteCommandsConfigured = true
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.isEnabled = true
    center.playCommand.addTarget { [weak self] _ in
      Task { @MainActor in
        guard let self = self else { return }
        if self.currentCloudMusicTrack != nil {
          if !self.isCloudMusicPlaying {
            self.toggleCloudMusicPlayPause()
          }
        } else if self.playingAudioMessage != nil, !self.isAudioPlaying {
          self.audioPlayer?.play()
          self.isAudioPlaying = true
          self.updateNowPlayingInfo(force: true)
        }
      }
      return .success
    }
    center.pauseCommand.isEnabled = true
    center.pauseCommand.addTarget { [weak self] _ in
      Task { @MainActor in
        guard let self = self else { return }
        if self.currentCloudMusicTrack != nil {
          if self.isCloudMusicPlaying {
            self.toggleCloudMusicPlayPause()
          }
        } else if self.playingAudioMessage != nil, self.isAudioPlaying {
          self.audioPlayer?.pause()
          self.isAudioPlaying = false
          self.updateNowPlayingInfo(force: true)
        }
      }
      return .success
    }
    center.togglePlayPauseCommand.isEnabled = true
    center.togglePlayPauseCommand.addTarget { [weak self] _ in
      Task { @MainActor in
        guard let self = self else { return }
        if self.currentCloudMusicTrack != nil {
          self.toggleCloudMusicPlayPause()
        } else if let chat = self.playingAudioChat, let msg = self.playingAudioMessage {
          self.togglePlayAudioMessage(chat: chat, message: msg)
        }
      }
      return .success
    }
    center.nextTrackCommand.isEnabled = true
    center.nextTrackCommand.addTarget { [weak self] _ in
      Task { @MainActor in
        guard let self = self else { return }
        if self.currentCloudMusicTrack != nil {
          self.stepCloudMusicTrack(delta: 1)
        } else if self.playingAudioMessage != nil {
          self.playAdjacentAudioTrack(delta: 1)
        }
      }
      return .success
    }
    center.previousTrackCommand.isEnabled = true
    center.previousTrackCommand.addTarget { [weak self] _ in
      Task { @MainActor in
        guard let self = self else { return }
        if self.currentCloudMusicTrack != nil {
          self.stepCloudMusicTrack(delta: -1)
        } else if self.playingAudioMessage != nil {
          self.playAdjacentAudioTrack(delta: -1)
        }
      }
      return .success
    }
    center.changePlaybackPositionCommand.isEnabled = true
    center.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      Task { @MainActor in
        self?.seekCloudMusic(to: posEvent.positionTime)
      }
      return .success
    }
  }

  func updateNowPlayingInfo(force: Bool = false) {
    let now = Date()
    if !force && now.timeIntervalSince(lastNowPlayingUpdateAt) < 1.5 {
      return
    }
    lastNowPlayingUpdateAt = now

    if let track = currentCloudMusicTrack {
      let meta = Self.parseCloudTrackMetadata(
        track,
        fallbackArtist: mountDisplayName(for: track)
      )
      var info: [String: Any] = [
        MPMediaItemPropertyTitle: meta.title,
        MPMediaItemPropertyArtist: meta.artist,
        MPMediaItemPropertyAlbumTitle: "流光音乐 · \(mountDisplayName(for: track))",
        MPNowPlayingInfoPropertyElapsedPlaybackTime: cloudMusicPosition,
        MPMediaItemPropertyPlaybackDuration: max(cloudMusicDuration, 0),
        MPNowPlayingInfoPropertyPlaybackRate: isCloudMusicPlaying ? Double(cloudMusicSpeed) : 0.0
      ]
      if let img = cloudMusicCoverImage {
        let artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        info[MPMediaItemPropertyArtwork] = artwork
      }
      MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    } else if let msg = playingAudioMessage {
      let title = msg.attachment?.displayName ?? (msg.text.isEmpty ? "Telegram 音乐" : msg.text)
      let artist = playingAudioChat?.title ?? "Telegram"
      let info: [String: Any] = [
        MPMediaItemPropertyTitle: title,
        MPMediaItemPropertyArtist: artist,
        MPNowPlayingInfoPropertyElapsedPlaybackTime: audioPosition,
        MPMediaItemPropertyPlaybackDuration: max(audioDuration, 0),
        MPNowPlayingInfoPropertyPlaybackRate: isAudioPlaying ? Double(audioSpeed) : 0.0
      ]
      MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    } else {
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
  }

  func showToast(_ message: String) {
    toastTask?.cancel()
    toastMessage = message
    toastTask = Task {
      try? await Task.sleep(nanoseconds: 3_200_000_000)
      if !Task.isCancelled {
        toastMessage = nil
      }
    }
  }

  /// Centralized hierarchical step-by-step Back / Menu button handler for Apple TV Siri Remote
  func handleRemoteMenuBackPress() {
    // 1. File preview sheet on top of Telegram
    if activeTelegramFilePreview != nil {
      activeTelegramFilePreview = nil
      return
    }

    // 2. Fullscreen VOD / Live Video Player:
    //    - If 115 acceleration overlay is active -> Cancel 115 acceleration
    //    - If episode drawer is open -> Close episode drawer
    //    - If control bar IS visible -> First Back press hides control bar to show clean fullscreen video!
    //    - If control bar is NOT visible -> Back press exits player (returning to Detail Page, etc.)!
    if activePlayback != nil {
      if is115Accelerating {
        cancel115Acceleration()
        return
      }
      if playerShowEpisodeDrawer {
        playerShowEpisodeDrawer = false
        return
      }
      if playerControlsVisible {
        lastControlsManualHideAt = Date()
        playerControlsVisible = false
        return
      }
      activePlayback = nil
      return
    }

    // 3. Fullscreen Telegram Video / Media Gallery:
    //    - If 115 acceleration overlay is active -> Cancel 115 acceleration
    //    - If control bar IS visible -> First Back press hides control bar to show clean fullscreen video!
    //    - If control bar is NOT visible -> Back press exits gallery back to Telegram chat!
    if activeTelegramGallery != nil {
      if is115Accelerating {
        cancel115Acceleration()
        return
      }
      if galleryControlsVisible {
        lastControlsManualHideAt = Date()
        galleryControlsVisible = false
        return
      }
      activeTelegramGallery = nil
      return
    }

    // 4. VOD Detail Page:
    //    - Close cross-site source shelf if open
    //    - Exit download mode if active
    //    - If scrolled down in episode list -> Scroll back to top of Detail Page
    //    - Otherwise close Detail Page and return to VOD poster wall
    if selectedDetailItem != nil {
      if detailShowSourceShelf {
        detailShowSourceShelf = false
        return
      }
      if detailDownloadMode {
        detailDownloadMode = false
        return
      }
      let didScrollWindow = scrollWindowToTopHandler?() ?? false
      if detailIsScrolledDown || didScrollWindow {
        detailIsScrolledDown = false
        detailScrollToTopTrigger &+= 1
        return
      }
      selectedDetailItem = nil
      return
    }

    if let custom = customBackHandler, custom() {
      return
    }

    // 5. Live TV Fullscreen:
    //    - If control bar IS visible -> First Back press hides control bar to show clean fullscreen live video!
    //    - If control bar is NOT visible -> Back press exits fullscreen and shows channel guide!
    if selectedSection == .live && liveGuideCollapsed {
      if liveFullscreenControlsVisible {
        lastControlsManualHideAt = Date()
        liveFullscreenControlsVisible = false
        return
      }
      liveGuideCollapsed = false
      liveFullscreenControlsVisible = true
      return
    }

    // 6. If focus is inside the Page Content (NOT on Top Navigation Bar):
    //    Step 6a: If any scroll view on the page is not at its top starting position -> Scroll back to top (`顶点处`)!
    if !isTopNavBarFocused {
      let didScrollWindow = scrollWindowToTopHandler?() ?? false
      if didScrollWindow || vodIsScrolledDown || liveChannelListScrolledDown || telegramChatListScrolledDown {
        vodIsScrolledDown = false
        liveChannelListScrolledDown = false
        telegramChatListScrolledDown = false
        pageScrollToTopTrigger &+= 1
        vodScrollToTopTrigger &+= 1
        liveScrollToTopTrigger &+= 1
        telegramScrollToTopTrigger &+= 1
        return
      }

      // Step 6b: Clear section sub-filters / drawers when already at the top of the page
      switch selectedSection {
      case .vod:
        if vodCategoriesExpanded {
          vodCategoriesExpanded = false
          return
        }
        if !searchKeyword.isEmpty {
          searchKeyword = ""
          if let src = selectedSource {
            Task {
              await loadVodList(source: src, page: 1, categoryId: selectedCategoryId, resetCategories: false)
            }
          }
          return
        }
        if selectedCategoryId != nil {
          Task { await selectCategory(nil) }
          return
        }
      case .live:
        if !liveSearchKeyword.isEmpty {
          liveSearchKeyword = ""
          return
        }
        if selectedLiveGroup != "全部" {
          selectedLiveGroup = "全部"
          return
        }
      case .telegram:
        if telegramShowRightInfoPanel {
          telegramShowRightInfoPanel = false
          return
        }
        if telegramSelectionMode {
          telegramSelectionMode = false
          telegramSelectedMessageIds.removeAll()
          return
        }
        if telegramInChatSearchOpen {
          telegramInChatSearchOpen = false
          telegramMessageKeyword = ""
          return
        }
        if telegramReplyingTo != nil {
          telegramReplyingTo = nil
          return
        }
        if telegramMediaFilter != "all" {
          telegramMediaFilter = "all"
          return
        }
        if telegramSidebarCollapsed {
          telegramSidebarCollapsed = false
          return
        }
        if miniPlayerMessage != nil {
          closeTelegramMiniPlayer()
          return
        }
      case .mediaLibrary:
        if fileMultiSelectMode {
          fileMultiSelectMode = false
          fileSelectedPaths.removeAll()
          return
        }
        if !fileSearchKeyword.isEmpty {
          fileSearchKeyword = ""
          return
        }
        if fileCategoryFilter != .all {
          fileCategoryFilter = .all
          return
        }
        if activeStorageMount.kind == .cloud115 {
          if !fileListing.path.isEmpty && fileListing.path != "0" {
            if cloud115Breadcrumbs.count >= 2 {
              let prev = cloud115Breadcrumbs[cloud115Breadcrumbs.count - 2]
              Task { await loadFiles(path: prev.cid, folderTitleHint: prev.name) }
            } else {
              Task { await loadFiles(path: "0", folderTitleHint: "115根目录") }
            }
            return
          }
        } else if !fileListing.path.isEmpty && fileListing.path != fileListing.root && fileListing.path != "/" {
          Task { await loadFiles(path: fileListing.parent) }
          return
        }
      case .proxy, .settings:
        if lastPrimarySection != selectedSection {
          selectedSection = lastPrimarySection
          return
        }
      default:
        break
      }

      // Step 6c: Already at the top of the page -> Move focus to the Top Navigation Bar (`继续按返回导航栏`)!
      isTopNavBarFocused = true
      topBarFocusTrigger &+= 1
      return
    }

    // 7. Focus IS already on the Top Navigation Bar (`isTopNavBarFocused == true`):
    //    Step 7a: If on Proxy or Settings -> Return to lastPrimarySection; otherwise switch back to 影视点播 (.vod)!
    if (selectedSection == .proxy || selectedSection == .settings) && lastPrimarySection != selectedSection {
      selectedSection = lastPrimarySection
      topBarFocusTrigger &+= 1
      return
    }
    if selectedSection != .vod {
      selectedSection = .vod
      topBarFocusTrigger &+= 1
      return
    }

    //    Step 7b: Already on 影视点播 (.vod) in the Top Navigation Bar -> Exit Application (`再返回就是退出应用`)!
    exitApplicationHandler?()
  }

  func navigateBackToPreviousSection() {
    let target = (lastPrimarySection == .proxy || lastPrimarySection == .settings) ? .vod : lastPrimarySection
    selectedSection = target
  }

  func setWatchHistoryEnabled(_ enabled: Bool) {
    watchHistoryEnabled = enabled
    defaults.set(enabled, forKey: "tv_watch_history_enabled")
    showToast(enabled ? "✓ 已开启观看历史记录" : "🕵️ 已关闭观看历史记录（无痕观看模式）")
  }

  static let aiProviderPresets: [(id: String, label: String, defaultBaseUrl: String, defaultModel: String, keyPlaceholder: String)] = [
    ("openai", "OpenAI / 兼容接口", "https://api.openai.com/v1", "gpt-4o-mini", "sk-..."),
    ("deepseek", "DeepSeek 官方", "https://api.deepseek.com/v1", "deepseek-chat", "sk-..."),
    ("qwen", "阿里云通义千问", "https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-plus", "sk-..."),
    ("gemini", "Google Gemini", "https://generativelanguage.googleapis.com/v1beta", "gemini-2.0-flash", "AIzaSy..."),
    ("claude", "Anthropic Claude", "https://api.anthropic.com/v1", "claude-3-5-haiku-latest", "sk-ant-..."),
    ("siliconflow", "硅基流动 SiliconFlow", "https://api.siliconflow.cn/v1", "deepseek-ai/DeepSeek-V3", "sk-...")
  ]

  static func aiProviderPreset(for rawId: String) -> (id: String, label: String, defaultBaseUrl: String, defaultModel: String, keyPlaceholder: String) {
    let lower = rawId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let match = aiProviderPresets.first(where: { $0.id == lower }) {
      return match
    }
    return aiProviderPresets[0]
  }

  var effectiveAiProvider: String {
    let key = aiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let raw = aiProvider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if raw == "gemini" || key.hasPrefix("AIza") {
      return "gemini"
    }
    if raw == "claude" || key.hasPrefix("sk-ant-") {
      return "claude"
    }
    return raw.isEmpty ? "openai" : raw
  }

  var effectiveAiProviderLabel: String {
    Self.aiProviderPreset(for: effectiveAiProvider).label
  }

  var effectiveAiBaseUrl: String {
    let custom = aiBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if !custom.isEmpty {
      return custom
    }
    return Self.aiProviderPreset(for: effectiveAiProvider).defaultBaseUrl
  }

  var effectiveAiModel: String {
    let custom = aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
    if !custom.isEmpty {
      return custom
    }
    return Self.aiProviderPreset(for: effectiveAiProvider).defaultModel
  }

  func saveAiConfig(provider: String, apiKey: String, baseUrl: String, model: String) {
    let cleanProv = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    self.aiProvider = cleanProv.isEmpty ? "openai" : cleanProv
    self.aiApiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    self.aiBaseUrl = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    self.aiModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    defaults.set(self.aiProvider, forKey: "tv_ai_provider_v1")
    defaults.set(self.aiApiKey, forKey: "tv_ai_api_key_v1")
    defaults.set(self.aiBaseUrl, forKey: "tv_ai_base_url_v1")
    defaults.set(self.aiModel, forKey: "tv_ai_model_v1")
    showToast("✓ AI 配置已保存（\(effectiveAiProviderLabel) · \(effectiveAiModel)）")
  }

  func togglePinSource(_ sourceId: String) {
    if pinnedSourceIds.contains(sourceId) {
      pinnedSourceIds.remove(sourceId)
    } else {
      pinnedSourceIds.insert(sourceId)
    }
    defaults.set(Array(pinnedSourceIds), forKey: "tv_pinned_sources_v1")
  }

  @discardableResult
  func testSingleVodSource(_ src: TvVodSource, silent: Bool = false) async -> Int {
    if testingSourceIds.contains(src.id) {
      return sourceLatencyMs[src.id] ?? -1
    }
    testingSourceIds.insert(src.id)
    let start = Date()
    var latency = -1
    if let res = try? await api.fetchVodList(source: src, page: 1) {
      let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
      if !res.items.isEmpty || !res.categories.isEmpty {
        latency = max(1, min(99999, elapsedMs))
      }
    }
    sourceLatencyMs[src.id] = latency
    testingSourceIds.remove(src.id)
    return latency
  }

  func batchTestVodSources(targetSources: [TvVodSource]? = nil) async {
    guard !isTestingSources, !vodSources.isEmpty else { return }
    isTestingSources = true
    let candidates = Array((targetSources ?? vodSources).prefix(40))
    let batchSize = 5
    var idx = 0
    while idx < candidates.count {
      let end = min(idx + batchSize, candidates.count)
      let batch = Array(candidates[idx..<end])
      idx = end
      await withTaskGroup(of: Void.self) { group in
        for src in batch {
          group.addTask { [weak self] in
            _ = await self?.testSingleVodSource(src, silent: true)
          }
        }
      }
    }
    isTestingSources = false
    let okCount = sourceLatencyMs.values.filter { $0 > 0 }.count
    showToast("⚡ 片源测速完成：可用 \(okCount) / \(candidates.count) 个站点")
  }

  func sortVodSourcesByLatency() {
    guard !sourceLatencyMs.isEmpty else { return }
    vodSources.sort { a, b in
      let ap = pinnedSourceIds.contains(a.id) ? 0 : 1
      let bp = pinnedSourceIds.contains(b.id) ? 0 : 1
      if ap != bp { return ap < bp }
      let la = sourceLatencyMs[a.id]
      let lb = sourceLatencyMs[b.id]
      let effA = (la == nil) ? 500000 : (la! <= 0 ? 999999 : la!)
      let effB = (lb == nil) ? 500000 : (lb! <= 0 ? 999999 : lb!)
      return effA < effB
    }
  }

  func saveConfig(
    newUrl: String,
    newSecret: String,
    adFilter: Bool,
    directPlayback: Bool,
    introSec: Int,
    outroSec: Int
  ) {
    let normalized = TvApiClient.normalizeBaseUrl(newUrl)
    let trimmedSecret = newSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    self.serverUrl = normalized
    self.authSecret = trimmedSecret
    self.enableAdFilter = adFilter
    self.preferDirectPlayback = directPlayback
    self.skipIntroSeconds = max(0, introSec)
    self.skipOutroSeconds = max(0, outroSec)
    defaults.set(normalized, forKey: "tv_server_url")
    defaults.set(trimmedSecret, forKey: "tv_auth_secret")
    defaults.set(adFilter, forKey: "tv_ad_filter")
    defaults.set(directPlayback, forKey: "tv_prefer_direct")
    defaults.set(self.skipIntroSeconds, forKey: "tv_skip_intro")
    defaults.set(self.skipOutroSeconds, forKey: "tv_skip_outro")
    self.api = TvApiClient(baseUrl: normalized, authSecret: trimmedSecret, preferDirectPlayback: directPlayback)
  }

  func saveRouteModes(vod: TvRouteMode, live: TvRouteMode, tg: TvRouteMode, subUrl: String) {
    self.vodRouteMode = vod
    self.liveRouteMode = live
    self.telegramRouteMode = tg
    let normalizedSub = Self.normalizeSubscriptionInput(subUrl)
    self.subscriptionUrl = normalizedSub
    defaults.set(vod.rawValue, forKey: "tv_route_vod")
    defaults.set(live.rawValue, forKey: "tv_route_live")
    defaults.set(tg.rawValue, forKey: "tv_route_tg")
    defaults.set(normalizedSub, forKey: "tv_sub_url")
    if !normalizedSub.isEmpty {
      var hist = subscriptionHistory.filter { $0 != normalizedSub }
      hist.insert(normalizedSub, at: 0)
      if hist.count > 8 { hist = Array(hist.prefix(8)) }
      subscriptionHistory = hist
      defaults.set(hist, forKey: "tv_sub_history")
    }
  }

  static func normalizeSubscriptionInput(_ rawInput: String) -> String {
    let raw = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return "" }
    let lower = raw.lowercased()

    // 1. clash://install-config?url=... or sing-box://import-remote-profile?url=... or shadowrocket://
    if lower.hasPrefix("clash://") || lower.hasPrefix("sing-box://") || lower.hasPrefix("shadowrocket://") {
      if let comp = URLComponents(string: raw),
         let urlParam = comp.queryItems?.first(where: { $0.name.lowercased() == "url" })?.value,
         !urlParam.isEmpty {
        return urlParam.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }

    // 2. sub://base64_or_url#name
    if lower.hasPrefix("sub://") {
      var body = String(raw.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
      if let hashIdx = body.firstIndex(of: "#") {
        body = String(body[..<hashIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      if body.hasPrefix("http://") || body.hasPrefix("https://") {
        return body
      }
      var b64 = body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
      while b64.count % 4 != 0 { b64.append("=") }
      if let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
         let decoded = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
         (decoded.hasPrefix("http://") || decoded.hasPrefix("https://")) {
        return decoded.components(separatedBy: "#").first ?? decoded
      }
    }

    return raw.components(separatedBy: "#").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? raw
  }

  func loginAndBootstrap(url: String, password: String) async -> Bool {
    isBootstrapping = true
    statusBanner = nil
    let normalized = TvApiClient.normalizeBaseUrl(url)
    let trimmedPwd = password.trimmingCharacters(in: .whitespacesAndNewlines)
    let client = TvApiClient(baseUrl: normalized, authSecret: trimmedPwd, preferDirectPlayback: preferDirectPlayback)
    let ok = await client.login(password: trimmedPwd)
    if ok {
      saveConfig(
        newUrl: normalized,
        newSecret: trimmedPwd,
        adFilter: enableAdFilter,
        directPlayback: preferDirectPlayback,
        introSec: skipIntroSeconds,
        outroSec: skipOutroSeconds
      )
      isAuthenticated = true
      await bootstrapAll()
      isBootstrapping = false
      return true
    } else {
      self.api = client
      if let sources = try? await client.fetchVodSources(), !sources.isEmpty {
        saveConfig(
          newUrl: normalized,
          newSecret: trimmedPwd,
          adFilter: enableAdFilter,
          directPlayback: preferDirectPlayback,
          introSec: skipIntroSeconds,
          outroSec: skipOutroSeconds
        )
        isAuthenticated = true
        await bootstrapAll()
        isBootstrapping = false
        return true
      }
      statusBanner = "连接或密码验证失败，请检查服务器地址与访问密码"
      isBootstrapping = false
      return false
    }
  }

  func logout() {
    isAuthenticated = false
    authSecret = ""
    defaults.removeObject(forKey: "tv_auth_secret")
  }

  func bootstrapAll() async {
    guard isAuthenticated else { return }
    isBootstrapping = true
    defer { isBootstrapping = false }

    do {
      let fetchedSources = try await api.fetchVodSources()
      self.vodSources = fetchedSources
      if selectedSource == nil || !fetchedSources.contains(where: { $0.id == selectedSource?.id }) {
        let savedSourceId = defaults.string(forKey: "tv_selected_source_id")
        self.selectedSource = fetchedSources.first(where: { $0.id == savedSourceId }) ?? fetchedSources.first
      }
      if let src = selectedSource {
        await loadVodList(source: src, page: 1, categoryId: nil, resetCategories: true)
      }
    } catch {
      statusBanner = "加载影视源失败: \(error.localizedDescription)"
    }

    Task {
      await refreshLibrary()
      await loadLiveSources()
      await loadTelegramAccounts()
      await refreshDownloadTasks()
      if self.fileListing.entries.isEmpty && !self.isLoadingFiles {
        let mount = self.activeStorageMount
        let initPath = mount.kind == .cloud115 ? "0" : (mount.kind == .server ? "" : mount.rootPath)
        await loadFiles(path: initPath)
      }
      await refresh115Status()
      if self.subscriptionNodes.isEmpty {
        await refreshAllSubscriptions(silent: true)
      } else if let best = self.fastestProxyNode ?? self.activeProxyNode {
        let backups = self.activePoolNodes
          .filter(\.isSupportedByClientTunnel)
          .sorted { ($0.latencyMs ?? 9999) < ($1.latencyMs ?? 9999) }
        TvLocalProxyTunnelServer.shared.seedFallbackNode(best, backupNodes: backups)
      }
    }
  }

  // MARK: - 1. VOD Methods

  func selectSource(_ source: TvVodSource) async {
    selectedSource = source
    defaults.set(source.id, forKey: "tv_selected_source_id")
    selectedCategoryId = nil
    vodCategoriesExpanded = false
    vodCategoryGroupTab = "全部"
    vodCategoryFilterQuery = ""
    searchKeyword = ""
    categories = []
    await loadVodList(source: source, page: 1, categoryId: nil, resetCategories: true)
  }

  func selectCategory(_ categoryId: String?) async {
    guard let src = selectedSource else { return }
    selectedCategoryId = categoryId
    searchKeyword = ""
    await loadVodList(source: src, page: 1, categoryId: categoryId, resetCategories: false)
  }

  func loadVodList(
    source: TvVodSource,
    page: Int,
    categoryId: String?,
    resetCategories: Bool
  ) async {
    let isFirstPage = page <= 1
    if isFirstPage {
      isLoadingVod = true
      homeFallbackCategoryIdx = 0
      homeFallbackCategoryPage = 0
    } else {
      isLoadingMoreVod = true
    }
    defer {
      if isFirstPage {
        isLoadingVod = false
      } else {
        isLoadingMoreVod = false
      }
    }

    do {
      let res = try await api.fetchVodList(source: source, page: page, typeId: categoryId)
      if resetCategories || (categories.isEmpty && !res.categories.isEmpty) {
        self.categories = res.categories
      }
      if let autoCat = res.resolvedTypeId, selectedCategoryId == nil {
        self.selectedCategoryId = autoCat
      }

      if isFirstPage {
        self.vodItems = res.items
        if let firstPic = res.items.first?.vodPic, !firstPic.isEmpty {
          self.ambientBackdropUrl = firstPic
        }
        self.currentPage = 1
        self.totalPages = max(1, res.pageCount)
        self.hasMoreVodPages = !res.items.isEmpty && (res.pageCount > 1 || res.items.count >= 12 || !self.categories.isEmpty)
        self.statusBanner = res.items.isEmpty ? "当前分类下暂无影片数据，可尝试切换分类或影视源" : nil
        // Standard CMS sites return 20 items per page (only ~3 rows on a 6-column Apple TV grid).
        // Automatically prefetch page 2 on initial load so the screen is filled with ~40 posters (~7 rows).
        if !self.vodItems.isEmpty && self.vodItems.count < 36 && self.hasMoreVodPages {
          let activeCategory = self.selectedCategoryId
          if let page2 = try? await api.fetchVodList(source: source, page: 2, typeId: activeCategory) {
            let existingIds = Set(self.vodItems.map { $0.id })
            let moreItems = page2.items.filter { !existingIds.contains($0.id) }
            if !moreItems.isEmpty {
              self.vodItems.append(contentsOf: moreItems)
              self.currentPage = 2
              self.totalPages = max(2, page2.pageCount)
              self.hasMoreVodPages = 2 < self.totalPages || moreItems.count >= 12
            } else if activeCategory == nil && !self.categories.isEmpty {
              await loadMoreFromFallbackCategories(source: source)
            }
          }
        }
      } else {
        let existingIds = Set(self.vodItems.map { $0.id })
        let newItems = res.items.filter { !existingIds.contains($0.id) }
        if !newItems.isEmpty {
          self.vodItems.append(contentsOf: newItems)
          self.currentPage = page
          self.totalPages = max(page, res.pageCount)
          self.hasMoreVodPages = page < self.totalPages || newItems.count >= 12
        } else if categoryId == nil && !self.categories.isEmpty {
          // If home feed (typeId == nil) doesn't paginate further, seamlessly roll into category pagination!
          await loadMoreFromFallbackCategories(source: source)
        } else {
          self.hasMoreVodPages = false
        }
      }
    } catch {
      if isFirstPage {
        self.statusBanner = "获取影片列表失败: \(error.localizedDescription)"
      }
    }
  }

  private func loadMoreFromFallbackCategories(source: TvVodSource) async {
    while homeFallbackCategoryIdx < categories.count {
      let cat = categories[homeFallbackCategoryIdx]
      let nextPage = homeFallbackCategoryPage + 1
      if let res = try? await api.fetchVodList(source: source, page: nextPage, typeId: cat.typeId) {
        let existingIds = Set(self.vodItems.map { $0.id })
        let newItems = res.items.filter { !existingIds.contains($0.id) }
        if !newItems.isEmpty {
          self.vodItems.append(contentsOf: newItems)
          self.homeFallbackCategoryPage = nextPage
          if nextPage >= max(1, res.pageCount) && newItems.count < 12 {
            self.homeFallbackCategoryIdx += 1
            self.homeFallbackCategoryPage = 0
          }
          self.hasMoreVodPages = true
          return
        }
      }
      homeFallbackCategoryIdx += 1
      homeFallbackCategoryPage = 0
    }
    self.hasMoreVodPages = false
  }

  func loadMoreVodIfNeeded(currentItem: TvVodItem? = nil) async {
    guard searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !isLoadingVod,
          !isLoadingMoreVod,
          hasMoreVodPages,
          let src = selectedSource else {
      return
    }

    if let item = currentItem {
      let thresholdIdx = max(0, vodItems.count - 18)
      guard let idx = vodItems.firstIndex(where: { $0.id == item.id }),
            idx >= thresholdIdx else {
        return
      }
    }

    if selectedCategoryId == nil && homeFallbackCategoryPage > 0 {
      isLoadingMoreVod = true
      defer { isLoadingMoreVod = false }
      await loadMoreFromFallbackCategories(source: src)
    } else {
      await loadVodList(
        source: src,
        page: currentPage + 1,
        categoryId: selectedCategoryId,
        resetCategories: false
      )
    }
  }

  func performSearch() async {
    let kw = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !kw.isEmpty else {
      if let src = selectedSource {
        await loadVodList(source: src, page: 1, categoryId: selectedCategoryId, resetCategories: false)
      }
      return
    }

    isLoadingVod = true
    defer { isLoadingVod = false }

    if !isAggregateSearch, let src = selectedSource {
      let found = await api.searchVod(source: src, keyword: kw)
      self.vodItems = found
      if let firstPic = found.first?.vodPic, !firstPic.isEmpty {
        self.ambientBackdropUrl = firstPic
      }
      self.currentPage = 1
      self.totalPages = 1
      self.hasMoreVodPages = false
      return
    }

    let searchableSources = Array(vodSources.filter { $0.searchable }.prefix(18))
    var aggregated: [TvVodItem] = []
    await withTaskGroup(of: [TvVodItem].self) { group in
      for src in searchableSources {
        group.addTask { [api] in
          await api.searchVod(source: src, keyword: kw)
        }
      }
      for await items in group {
        aggregated.append(contentsOf: items)
      }
    }
    self.vodItems = aggregated
    if let firstPic = aggregated.first?.vodPic, !firstPic.isEmpty {
      self.ambientBackdropUrl = firstPic
    }
    self.currentPage = 1
    self.totalPages = 1
    self.hasMoreVodPages = false
  }

  // MARK: - 2. Playback & Progress

  func progressKey(vodId: String, episodeTitle: String) -> String {
    "\(vodId)@@\(episodeTitle)"
  }

  func savedPosition(vodId: String, episodeTitle: String) -> Double {
    guard watchHistoryEnabled else { return 0 }
    return localProgress[progressKey(vodId: vodId, episodeTitle: episodeTitle)] ?? 0
  }

  func lastWatchedEpisode(for detail: TvVodDetail) -> (groupIndex: Int, episodeIndex: Int, episodeTitle: String, savedSec: Double)? {
    guard watchHistoryEnabled else { return nil }
    if let hist = history.first(where: { $0.vodId == detail.vodId && $0.position > 5 }) {
      for (gIdx, grp) in detail.playGroups.enumerated() {
        if let epIdx = grp.episodes.firstIndex(where: { $0.title == hist.episode }) {
          return (gIdx, epIdx, hist.episode, hist.position)
        }
      }
    }
    var best: (groupIndex: Int, episodeIndex: Int, episodeTitle: String, savedSec: Double)? = nil
    for (gIdx, grp) in detail.playGroups.enumerated() {
      for (epIdx, ep) in grp.episodes.enumerated() {
        let pos = savedPosition(vodId: detail.vodId, episodeTitle: ep.title)
        if pos > 5, pos > (best?.savedSec ?? 0) {
          best = (gIdx, epIdx, ep.title, pos)
        }
      }
    }
    return best
  }

  func recordPlaybackProgress(
    source: TvVodSource?,
    detail: TvVodDetail?,
    groupName: String,
    episodeTitle: String,
    position: Double,
    duration: Double,
    force: Bool = false
  ) {
    guard watchHistoryEnabled else { return }
    guard let detail = detail, position > 3 else { return }
    let key = progressKey(vodId: detail.vodId, episodeTitle: episodeTitle)
    localProgress[key] = position

    let now = Date()
    let shouldPersist = force || key != lastHistoryPersistKey || now.timeIntervalSince(lastHistoryPersistAt) >= 12.0
    guard shouldPersist else { return }
    lastHistoryPersistAt = now
    lastHistoryPersistKey = key
    defaults.set(localProgress, forKey: "tv_watch_progress")

    let srcKey = source?.librarySourceKey ?? "default"
    let srcName = source?.displayName ?? "默认源"
    let item = TvLibraryItem(
      source: srcKey,
      sourceName: srcName,
      vodId: detail.vodId,
      title: detail.vodName,
      poster: detail.vodPic,
      remark: detail.vodRemarks,
      episode: episodeTitle,
      line: groupName,
      position: position,
      duration: max(duration, position),
      updated: Int64(now.timeIntervalSince1970)
    )
    if let idx = history.firstIndex(where: { $0.id == item.id }) {
      history[idx] = item
    } else {
      history.insert(item, at: 0)
    }
    Task {
      await api.upsertLibraryItem(kind: "history", item: item)
    }
  }

  func resolveEpisodePlaybackInfo(
    source: TvVodSource,
    detail: TvVodDetail,
    groupIndex: Int,
    episodeIndex: Int
  ) async -> (finalStream: String, backupProxyUrl: String, headers: [String: String], viaBadge: String, resumeSec: Double)? {
    guard groupIndex >= 0, groupIndex < detail.playGroups.count else { return nil }
    let group = detail.playGroups[groupIndex]
    guard episodeIndex >= 0, episodeIndex < group.episodes.count else { return nil }
    let ep = group.episodes[episodeIndex]

    activateScenarioProxyTunnel(for: .vodStream)
    let effRoute = resolveEffectiveRoute(for: .vodStream)
    let forceRelay = (effRoute == .serverRelay)
    let resolved = await api.resolvePlayback(
      source: source,
      playFrom: group.name,
      rawUrl: ep.rawUrl,
      forceServerRelay: forceRelay
    )
    var finalStream = await api.prepareAdFilteredStreamIfPossible(
      streamUrl: resolved.directUrl,
      headers: resolved.headers,
      enableAdFilter: enableAdFilter
    )
    var mergedHeaders = resolved.headers
    if finalStream.contains("/api/vod/proxy") && mergedHeaders["Cookie"] == nil && !api.cookieHeaderValue.isEmpty {
      mergedHeaders["Cookie"] = api.cookieHeaderValue
    }
    let isHlsCandidate = finalStream.lowercased().contains(".m3u8") || finalStream.contains("/api/vod/proxy")
    if !finalStream.contains("127.0.0.1:") {
      if isHlsCandidate {
        if !TvLocalHlsProxyServer.isDomesticOrLocalUrl(finalStream),
           let proxiedHls = await TvLocalHlsProxyServer.shared.prepareProxyPlaylistUrl(
             gatewayUrl: finalStream,
             resolvedUrl: finalStream,
             headers: mergedHeaders
           ) {
          finalStream = proxiedHls
        }
      } else if finalStream.hasPrefix("http") {
        // Infer container extension from URL path or episode/VOD title so AList/115 `.mkv`/`.ts`/`.m2ts`/`.mp4`
        // movies opened from VOD (`tvbox_0` / `alistfile:...`) also run through our 64 MB continuous Range proxy & Matroska hardware engine!
        let urlPathExt = ((URL(string: finalStream)?.path ?? "") as NSString).pathExtension.lowercased()
        let titleExt = (ep.title as NSString).pathExtension.lowercased()
        let vodExt = (detail.vodName as NSString).pathExtension.lowercased()
        let detectedExt = !urlPathExt.isEmpty ? ".\(urlPathExt)" : (!titleExt.isEmpty ? ".\(titleExt)" : (!vodExt.isEmpty ? ".\(vodExt)" : ".mp4"))
        let isDomesticDirect = TvLocalHlsProxyServer.isDomesticOrLocalUrl(finalStream) || finalStream.contains("/d/")
        if isDomesticDirect || effRoute == .proxyNode || [".mkv", ".webm", ".ts", ".m2ts", ".mts", ".mp4", ".mov", ".m4v"].contains(detectedExt) {
          finalStream = TvLocalHlsProxyServer.shared.prepareTelegramVideoProxyUrl(
            remoteUrl: finalStream,
            headers: mergedHeaders,
            extHint: detectedExt,
            forceDirectConnection: isDomesticDirect
          )
        }
      }
    }

    let savedSec = savedPosition(vodId: detail.vodId, episodeTitle: ep.title)
    let resumeSec = savedSec > 5 ? savedSec : Double(skipIntroSeconds)
    let viaBadge = (effRoute == .proxyNode)
      ? "代理: \(resolveNode(for: .vodStream)?.displayTitle ?? resolved.parseVia)"
      : resolved.parseVia
    return (finalStream, resolved.serverProxyUrl, mergedHeaders, viaBadge, resumeSec)
  }

  func startEpisodePlayback(
    source: TvVodSource,
    detail: TvVodDetail,
    groupIndex: Int,
    episodeIndex: Int,
    preResolvedInfo: (finalStream: String, backupProxyUrl: String, headers: [String: String], viaBadge: String, resumeSec: Double)? = nil
  ) async {
    guard groupIndex >= 0, groupIndex < detail.playGroups.count else { return }
    let group = detail.playGroups[groupIndex]
    guard episodeIndex >= 0, episodeIndex < group.episodes.count else { return }
    let ep = group.episodes[episodeIndex]
    stopBackgroundAudioForVideoPlayback()

    let info: (finalStream: String, backupProxyUrl: String, headers: [String: String], viaBadge: String, resumeSec: Double)
    if let pre = preResolvedInfo, !pre.finalStream.isEmpty {
      info = pre
    } else {
      isResolvingPlay = true
      defer { isResolvingPlay = false }
      guard let resolvedInfo = await resolveEpisodePlaybackInfo(
        source: source,
        detail: detail,
        groupIndex: groupIndex,
        episodeIndex: episodeIndex
      ) else { return }
      info = resolvedInfo
    }

    self.playerControlsVisible = true
    self.playerShowEpisodeDrawer = false
    self.activePlayback = TvPlaybackRequest(
      title: detail.vodName,
      subtitle: "\(group.name) · \(ep.title) (\(info.viaBadge))",
      streamUrl: info.finalStream,
      backupProxyUrl: info.backupProxyUrl,
      headers: info.headers,
      resumeSeconds: info.resumeSec,
      isLive: false,
      vodSource: source,
      vodDetail: detail,
      playGroupIndex: groupIndex,
      episodeIndex: episodeIndex,
      liveChannel: nil,
      liveUrlIndex: 0
    )
  }

  func queueEpisodeDownload(source: TvVodSource, detail: TvVodDetail, groupName: String, episode: TvEpisode) async {
    let resolved = await api.resolvePlayback(
      source: source,
      playFrom: groupName,
      rawUrl: episode.rawUrl,
      forceServerRelay: false
    )
    let taskName = "\(detail.vodName)_\(episode.title)"
    do {
      try await api.createDownloadTask(url: resolved.directUrl, name: taskName, headers: resolved.headers)
      showToast("已加入服务器下载队列：\(taskName)")
      await refreshDownloadTasks()
    } catch {
      showToast("添加下载失败：\(error.localizedDescription)")
    }
  }

  // MARK: - 3. Favorites & History

  func refreshLibrary() async {
    let res = await api.fetchLibrary()
    self.favorites = res.favorites
    self.history = res.history
  }

  func isFavorite(source: TvVodSource, vodId: String) -> Bool {
    let key = "\(source.librarySourceKey)_\(vodId)"
    return favorites.contains(where: { $0.id == key || $0.vodId == vodId })
  }

  func toggleFavorite(source: TvVodSource, detail: TvVodDetail) async {
    let item = TvLibraryItem(
      source: source.librarySourceKey,
      sourceName: source.displayName,
      vodId: detail.vodId,
      title: detail.vodName,
      poster: detail.vodPic,
      remark: detail.vodRemarks,
      episode: detail.vodRemarks,
      line: detail.playGroups.first?.name ?? "",
      position: 0,
      duration: 0,
      updated: Int64(Date().timeIntervalSince1970)
    )
    if isFavorite(source: source, vodId: detail.vodId) {
      favorites.removeAll(where: { $0.vodId == detail.vodId })
      await api.deleteLibraryItem(kind: "favorites", source: source.librarySourceKey, vodId: detail.vodId)
      showToast("已取消收藏：\(detail.vodName)")
    } else {
      favorites.insert(item, at: 0)
      await api.upsertLibraryItem(kind: "favorites", item: item)
      showToast("已加入收藏：\(detail.vodName)")
    }
  }

  func removeLibraryItem(kind: String, item: TvLibraryItem) async {
    if kind == "history" {
      history.removeAll { $0.id == item.id }
    } else {
      favorites.removeAll { $0.id == item.id }
    }
    await api.deleteLibraryItem(kind: kind, source: item.source, vodId: item.vodId)
    showToast("已移除：\(item.title)")
  }

  func clearLibrary(kind: String) async {
    if kind == "history" {
      history.removeAll()
    } else {
      favorites.removeAll()
    }
    await api.deleteLibraryItem(kind: kind)
    showToast(kind == "history" ? "已清空观看历史" : "已清空收藏夹")
  }

  func resolveSourceForLibraryItem(_ item: TvLibraryItem) -> TvVodSource? {
    if let match = vodSources.first(where: { $0.librarySourceKey == item.source }) {
      return match
    }
    if let byName = vodSources.first(where: { $0.displayName == item.sourceName || $0.name == item.sourceName }) {
      return byName
    }
    return selectedSource ?? vodSources.first
  }

  // MARK: - 4. Live TV

  private func rebuildLiveChannelCaches() {
    var seen = Set<String>()
    var groups: [String] = ["全部"]
    var counts: [String: Int] = ["全部": liveChannels.count]
    var favCount = 0

    for ch in liveChannels {
      if favoriteLiveChannelIds.contains(ch.id) {
        favCount += 1
      }
      if !seen.contains(ch.group) {
        seen.insert(ch.group)
        groups.append(ch.group)
      }
      counts[ch.group, default: 0] += 1
    }
    if favCount > 0 {
      groups.insert("★ 收藏", at: 1)
      counts["★ 收藏"] = favCount
    }
    self.cachedLiveGroups = groups
    self.cachedLiveGroupCounts = counts
    rebuildFilteredLiveChannelsCache()
  }

  private func rebuildFilteredLiveChannelsCache() {
    let kw = liveSearchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let grp = selectedLiveGroup
    let filtered: [TvLiveChannel]
    if grp == "全部" && kw.isEmpty {
      filtered = liveChannels
    } else {
      let favIds = favoriteLiveChannelIds
      filtered = liveChannels.filter { ch in
        let matchGroup: Bool
        if grp == "全部" {
          matchGroup = true
        } else if grp == "★ 收藏" {
          matchGroup = favIds.contains(ch.id)
        } else {
          matchGroup = ch.group == grp
        }
        guard matchGroup else { return false }
        if kw.isEmpty { return true }
        return ch.name.lowercased().contains(kw) || ch.group.lowercased().contains(kw)
      }
    }
    self.cachedFilteredLiveChannels = filtered
    var idxMap: [String: Int] = [:]
    idxMap.reserveCapacity(filtered.count)
    for (i, ch) in filtered.enumerated() {
      idxMap[ch.id] = i + 1
    }
    self.cachedLiveChannelIndexMap = idxMap
  }

  func liveChannelNumber(for id: String) -> Int {
    cachedLiveChannelIndexMap[id] ?? 1
  }

  var liveGroups: [String] {
    cachedLiveGroups
  }

  func liveGroupCount(_ group: String) -> Int {
    cachedLiveGroupCounts[group] ?? 0
  }

  func isLiveChannelFavorite(_ channel: TvLiveChannel) -> Bool {
    favoriteLiveChannelIds.contains(channel.id)
  }

  func toggleLiveChannelFavorite(_ channel: TvLiveChannel) {
    if favoriteLiveChannelIds.contains(channel.id) {
      favoriteLiveChannelIds.remove(channel.id)
      showToast("已取消收藏频道：\(channel.name)")
    } else {
      favoriteLiveChannelIds.insert(channel.id)
      showToast("★ 已收藏频道：\(channel.name)")
    }
    defaults.set(Array(favoriteLiveChannelIds), forKey: "tv_fav_live_channels")
  }

  var filteredLiveChannels: [TvLiveChannel] {
    cachedFilteredLiveChannels
  }

  private static func liveChannelsCacheFileUrl() -> URL? {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("tv_cached_live_channels_v2.json")
  }

  private static func loadCachedLiveChannelsData() -> Data? {
    guard let url = liveChannelsCacheFileUrl() else { return nil }
    return try? Data(contentsOf: url)
  }

  private static func saveCachedLiveChannels(_ channels: [TvLiveChannel]) {
    guard !channels.isEmpty, let url = liveChannelsCacheFileUrl(),
          let data = try? JSONEncoder().encode(channels) else { return }
    try? data.write(to: url, options: .atomic)
  }

  private func persistSelectedLiveSource(_ source: TvLiveSource, explicitUserChoice: Bool) {
    defaults.set(source.id, forKey: "tv_selected_live_source_id")
    defaults.set(source.url, forKey: "tv_selected_live_source_url")
    defaults.set(source.displayName, forKey: "tv_selected_live_source_name")
    defaults.set(source.name, forKey: "tv_selected_live_source_raw_name")
    if explicitUserChoice {
      defaults.set(true, forKey: "tv_user_explicit_live_source")
    }
    if let encoded = try? JSONEncoder().encode(source) {
      defaults.set(encoded, forKey: "tv_selected_live_source_json")
    }
  }

  private func findSavedLiveSource(in sources: [TvLiveSource]) -> TvLiveSource? {
    let savedId = (defaults.string(forKey: "tv_selected_live_source_id") ?? selectedLiveSource?.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let savedUrl = (defaults.string(forKey: "tv_selected_live_source_url") ?? selectedLiveSource?.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let savedDisplayName = (defaults.string(forKey: "tv_selected_live_source_name") ?? selectedLiveSource?.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let savedRawName = (defaults.string(forKey: "tv_selected_live_source_raw_name") ?? selectedLiveSource?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let isExplicit = defaults.bool(forKey: "tv_user_explicit_live_source")

    // 1. Exact ID match
    if !savedId.isEmpty {
      if isExplicit || (savedId != "tvbox_0_0" && savedId != "tvbox_0_1") {
        if let match = sources.first(where: { $0.id == savedId }) {
          return match
        }
      }
    }
    // 2. Non-empty URL match (survives index shifts when TVBox or custom sources are added/reordered)
    if !savedUrl.isEmpty {
      if let match = sources.first(where: { $0.url.trimmingCharacters(in: .whitespacesAndNewlines) == savedUrl }) {
        return match
      }
    }
    // 3. DisplayName or raw name match
    if !savedDisplayName.isEmpty {
      if let match = sources.first(where: { $0.displayName == savedDisplayName }) {
        return match
      }
    }
    if !savedRawName.isEmpty {
      if let match = sources.first(where: { $0.name == savedRawName }) {
        return match
      }
    }
    return nil
  }

  func recordLiveChannelSelection(channel: TvLiveChannel, urlIndex: Int) {
    let safeIdx = min(max(0, urlIndex), max(0, channel.urls.count - 1))
    if lastLiveChannelId != channel.id {
      lastLiveChannelId = channel.id
      defaults.set(channel.id, forKey: "tv_last_live_channel_id")
    }
    if preferredLiveUrlIndices[channel.id] != safeIdx {
      preferredLiveUrlIndices[channel.id] = safeIdx
      if preferredLiveUrlIndices.count > 400 {
        preferredLiveUrlIndices.removeAll(keepingCapacity: true)
        preferredLiveUrlIndices[channel.id] = safeIdx
      }
      defaults.set(preferredLiveUrlIndices, forKey: "tv_live_url_indices_v1")
    }
  }

  func preferredLiveUrlIndex(for channel: TvLiveChannel) -> Int {
    guard !channel.urls.isEmpty else { return 0 }
    if let saved = preferredLiveUrlIndices[channel.id] {
      return min(max(0, saved), channel.urls.count - 1)
    }
    return 0
  }

  func preferredLiveChannelToStart() -> (channel: TvLiveChannel, urlIndex: Int)? {
    let pool = filteredLiveChannels.isEmpty ? liveChannels : filteredLiveChannels
    guard !pool.isEmpty else { return nil }
    if !lastLiveChannelId.isEmpty {
      if let foundInPool = pool.first(where: { $0.id == lastLiveChannelId }) {
        return (foundInPool, preferredLiveUrlIndex(for: foundInPool))
      }
      if let foundInAll = liveChannels.first(where: { $0.id == lastLiveChannelId }) {
        return (foundInAll, preferredLiveUrlIndex(for: foundInAll))
      }
    }
    let first = pool[0]
    return (first, preferredLiveUrlIndex(for: first))
  }

  func loadLiveSources() async {
    guard !isLoadingLive else { return }
    let hadCachedChannels = !liveChannels.isEmpty
    if !hadCachedChannels {
      isLoadingLive = true
    }
    defer { isLoadingLive = false }

    let sources = await api.fetchLiveSources()
    guard !sources.isEmpty else { return }
    self.liveSources = sources

    // 1. If the user has a saved live source, ALWAYS honor it and never overwrite their choice with a fallback source!
    if let savedSource = findSavedLiveSource(in: sources) {
      self.selectedLiveSource = savedSource
      persistSelectedLiveSource(savedSource, explicitUserChoice: defaults.bool(forKey: "tv_user_explicit_live_source"))

      let chs = await api.fetchLiveChannels(source: savedSource)
      if !chs.isEmpty {
        self.liveChannels = chs
        Self.saveCachedLiveChannels(chs)
        if !liveGroups.contains(selectedLiveGroup) {
          selectedLiveGroup = "全部"
        }
        return
      }
      // If the user explicitly chose this source or we already have cached channels for it, keep their saved source!
      if defaults.bool(forKey: "tv_user_explicit_live_source") || !self.liveChannels.isEmpty {
        return
      }
    }

    // 2. First-time fallback candidate order when no saved source exists yet
    var orderedCandidates: [TvLiveSource] = []
    func addCandidate(_ s: TvLiveSource?) {
      guard let s = s, !orderedCandidates.contains(where: { $0.id == s.id }) else { return }
      orderedCandidates.append(s)
    }

    for s in sources {
      let uLower = s.url.lowercased()
      if !uLower.contains("127.0.0.1") && !uLower.contains("localhost") && !uLower.contains("fanmingming/live") {
        addCandidate(s)
      }
    }
    for s in sources {
      let uLower = s.url.lowercased()
      if !uLower.contains("127.0.0.1") && !uLower.contains("localhost") {
        addCandidate(s)
      }
    }
    for s in sources {
      addCandidate(s)
    }

    for candidate in orderedCandidates {
      selectedLiveSource = candidate
      selectedLiveGroup = "全部"
      let chs = await api.fetchLiveChannels(source: candidate)
      if !chs.isEmpty {
        self.liveChannels = chs
        Self.saveCachedLiveChannels(chs)
        persistSelectedLiveSource(candidate, explicitUserChoice: false)
        return
      }
    }
  }

  func selectLiveSource(_ source: TvLiveSource) async {
    selectedLiveSource = source
    selectedLiveGroup = "全部"
    persistSelectedLiveSource(source, explicitUserChoice: true)
    isLoadingLive = true
    defer { isLoadingLive = false }
    let chs = await api.fetchLiveChannels(source: source, forceRefresh: false)
    self.liveChannels = chs
    if !chs.isEmpty {
      Self.saveCachedLiveChannels(chs)
    }
    showToast("📺 已保存并切换直播源：\(source.displayName)")
  }

  func playLiveChannel(_ channel: TvLiveChannel, urlIndex: Int? = nil) {
    guard !channel.urls.isEmpty else { return }
    stopBackgroundAudioForVideoPlayback()
    let resolvedIndex = urlIndex ?? preferredLiveUrlIndex(for: channel)
    let idx = min(max(0, resolvedIndex), channel.urls.count - 1)
    recordLiveChannelSelection(channel: channel, urlIndex: idx)
    Task {
      activateScenarioProxyTunnel(for: .liveStream)
      let useRelay = shouldUseServerRelay(for: .liveStream)
      let resolved = await api.resolveLivePlayback(
        source: selectedLiveSource,
        channel: channel,
        urlIndex: idx,
        forceServerRelay: useRelay
      )
      var headers = resolved.headers
      if !api.cookieHeaderValue.isEmpty && (resolved.directUrl.contains("/api/") || resolved.backendProxyPlayback) {
        headers["Cookie"] = api.cookieHeaderValue
      }
      self.playerControlsVisible = true
      self.playerShowEpisodeDrawer = false
      self.activePlayback = TvPlaybackRequest(
        title: channel.name,
        subtitle: "电视直播 · \(channel.group) · 信号 \(idx + 1)/\(channel.urls.count) (\(resolved.parseVia))",
        streamUrl: resolved.directUrl,
        backupProxyUrl: resolved.serverProxyUrl,
        headers: headers,
        resumeSeconds: 0,
        isLive: true,
        vodSource: nil,
        vodDetail: nil,
        playGroupIndex: 0,
        episodeIndex: 0,
        liveChannel: channel,
        liveUrlIndex: idx,
        isFlvHardwareStream: resolved.isFlvHardwareStream,
        flvPrimaryUrl: resolved.flvPrimaryUrl,
        flvGatewayUrl: resolved.flvGatewayUrl
      )
    }
  }

  func stepActiveLivePlaybackChannel(delta: Int) {
    guard let req = activePlayback, req.isLive else { return }
    let list = filteredLiveChannels.isEmpty ? liveChannels : filteredLiveChannels
    guard !list.isEmpty else { return }
    let nextChannel: TvLiveChannel
    if let cur = req.liveChannel,
       let curIdx = list.firstIndex(where: { $0.id == cur.id }) {
      let nextIdx = (curIdx + delta + list.count) % list.count
      nextChannel = list[nextIdx]
    } else {
      nextChannel = list[0]
    }
    showToast("📺 切换频道：\(nextChannel.name)")
    playLiveChannel(nextChannel, urlIndex: preferredLiveUrlIndex(for: nextChannel))
  }

  func recordLiveChannel(_ channel: TvLiveChannel, urlIndex: Int = 0) async {
    guard !channel.urls.isEmpty else { return }
    let rawUrl = channel.urls[min(max(0, urlIndex), channel.urls.count - 1)]
    let split = TvApiClient.splitUrlAndInlineHeaders(rawUrl)
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyyMMdd_HHmm"
    let taskName = "直播录制_\(channel.name)_\(fmt.string(from: Date()))"
    do {
      try await api.createDownloadTask(url: split.cleanUrl, name: taskName, headers: channel.headers)
      showToast("🔴 已启动后台直播录制转存：\(taskName)")
      await refreshDownloadTasks()
    } catch {
      showToast("启动直播录制失败：\(error.localizedDescription)")
    }
  }

  // MARK: - 5. Telegram (1:1 Official Telegram Desktop / macOS / Apple TV)

  private func rebuildTelegramChatCaches() {
    let kw = telegramChatFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if kw.isEmpty {
      cachedFilteredTelegramChats = telegramChats
    } else {
      cachedFilteredTelegramChats = telegramChats.filter {
        $0.title.lowercased().contains(kw) || $0.preview.lowercased().contains(kw) || $0.kind.lowercased().contains(kw)
      }
    }
  }

  private func rebuildTelegramMessageCaches() {
    var vCount = 0
    var pCount = 0
    var mCount = 0
    for msg in telegramMessages {
      if msg.isVideo { vCount += 1 }
      if msg.isPhoto { pCount += 1 }
      if msg.isAudio { mCount += 1 }
    }
    cachedTelegramVideoCount = vCount
    cachedTelegramPhotoCount = pCount
    cachedTelegramMusicCount = mCount

    let kw = telegramMessageKeyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let msgs = telegramMessages.filter { msg in
      switch telegramMediaFilter {
      case "video": if !msg.isVideo { return false }
      case "photo": if !msg.isPhoto { return false }
      case "music", "audio": if !msg.isAudio { return false }
      case "file":
        if msg.attachment == nil || msg.isVisualMedia || msg.isAudio { return false }
      default: break
      }
      if kw.isEmpty { return true }
      return msg.text.lowercased().contains(kw)
        || (msg.attachment?.displayName.lowercased().contains(kw) ?? false)
        || (msg.attachment?.musicTitle.lowercased().contains(kw) ?? false)
        || (msg.attachment?.musicPerformer.lowercased().contains(kw) ?? false)
        || msg.sender.lowercased().contains(kw)
    }
    cachedFilteredTelegramMessages = msgs

    var rawGroups: [[TvTelegramMessage]] = []
    var gidIndexMap: [String: Int] = [:]

    for m in msgs {
      let gid = m.groupedId.trimmingCharacters(in: .whitespacesAndNewlines)
      if !gid.isEmpty && gid != "0", let att = m.attachment {
        let key = att.isVisualMedia ? "visual:\(gid)" : "doc:\(gid)"
        if let idx = gidIndexMap[key] {
          rawGroups[idx].append(m)
        } else {
          gidIndexMap[key] = rawGroups.count
          rawGroups.append([m])
        }
      } else {
        rawGroups.append([m])
      }
    }

    var result: [TvTelegramMessageGroup] = []
    result.reserveCapacity(rawGroups.count)
    var lastDatePill = ""
    for group in rawGroups {
      guard let first = group.first else { continue }
      let pill = first.formattedDatePill
      let header: String? = (!pill.isEmpty && pill != lastDatePill) ? pill : nil
      if !pill.isEmpty { lastDatePill = pill }
      result.append(TvTelegramMessageGroup(messages: group, datePillHeader: header))
    }
    cachedGroupedTelegramEntries = result
  }

  var filteredTelegramChats: [TvTelegramChat] {
    cachedFilteredTelegramChats
  }

  var filteredTelegramMessages: [TvTelegramMessage] {
    cachedFilteredTelegramMessages
  }

  var groupedTelegramEntries: [TvTelegramMessageGroup] {
    cachedGroupedTelegramEntries
  }

  func isPeerMuted(_ chat: TvTelegramChat) -> Bool {
    chat.muted || telegramMutedPeers.contains("\(activeTelegramAccountId)|\(chat.peer)")
  }

  func togglePeerMute(_ chat: TvTelegramChat) {
    let key = "\(activeTelegramAccountId)|\(chat.peer)"
    if telegramMutedPeers.contains(key) {
      telegramMutedPeers.remove(key)
      showToast("已恢复「\(chat.title)」的新消息通知")
    } else {
      telegramMutedPeers.insert(key)
      showToast("已将「\(chat.title)」设为免打扰")
    }
    defaults.set(Array(telegramMutedPeers), forKey: "tv_tg_muted_peers")
  }

  func draftKey(for chat: TvTelegramChat) -> String {
    "\(activeTelegramAccountId)|\(chat.peer)"
  }

  func isOutgoingMessageRead(chat: TvTelegramChat, message: TvTelegramMessage) -> Bool {
    if chat.isSelf { return true }
    if chat.readOutboxMaxId > 0 {
      return message.id <= chat.readOutboxMaxId
    }
    return true
  }

  func findMessage(byId id: Int) -> TvTelegramMessage? {
    telegramMessages.first(where: { $0.id == id })
  }

  func registerTelegramChatTitle(accountId: String, peer: String, title: String) {
    let normPeer = TvTelegramChat.normalizePeerIdentifier(peer)
    let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normPeer.isEmpty, !clean.isEmpty, !TvTelegramChat.isRawPeerIdentifier(clean) else { return }
    let acc = accountId.isEmpty ? "default" : accountId
    knownTelegramChatTitles["\(acc)|\(normPeer)"] = clean
    knownTelegramChatTitles["*|\(normPeer)"] = clean
    defaults.set(knownTelegramChatTitles, forKey: "tv_tg_known_chat_titles_v1")
  }

  func resolveTelegramChatTitle(accountId: String, peer: String) -> String {
    let normPeer = TvTelegramChat.normalizePeerIdentifier(peer)
    guard !normPeer.isEmpty else { return "" }
    let acc = accountId.isEmpty ? "default" : accountId
    if let exact = knownTelegramChatTitles["\(acc)|\(normPeer)"],
       !exact.isEmpty,
       !TvTelegramChat.isRawPeerIdentifier(exact) {
      return exact
    }
    if let global = knownTelegramChatTitles["*|\(normPeer)"],
       !global.isEmpty,
       !TvTelegramChat.isRawPeerIdentifier(global) {
      return global
    }
    return ""
  }

  func resolveDisplayChatTitle(_ chat: TvTelegramChat) -> String {
    let clean = chat.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !clean.isEmpty && !TvTelegramChat.isRawPeerIdentifier(clean) {
      return clean
    }
    let known = resolveTelegramChatTitle(accountId: activeTelegramAccountId, peer: chat.peer)
    if !known.isEmpty && !TvTelegramChat.isRawPeerIdentifier(known) {
      return known
    }
    let normPeer = TvTelegramChat.normalizePeerIdentifier(chat.peer)
    if let found = telegramChats.first(where: {
      TvTelegramChat.normalizePeerIdentifier($0.peer) == normPeer
        && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !TvTelegramChat.isRawPeerIdentifier($0.title)
    }) {
      return found.title
    }
    return TvTelegramChat.friendlyFallbackTitle(forPeer: chat.peer, kind: chat.kind)
  }

  func resolveDisplaySenderName(chat: TvTelegramChat, message: TvTelegramMessage) -> String {
    let chatTitle = resolveDisplayChatTitle(chat)
    let rawSender = message.sender.trimmingCharacters(in: .whitespacesAndNewlines)
    if !rawSender.isEmpty && !TvTelegramChat.isRawPeerIdentifier(rawSender) {
      return rawSender
    }
    let candidatePeer = !message.senderPeer.isEmpty
      ? TvTelegramChat.normalizePeerIdentifier(message.senderPeer)
      : TvTelegramChat.normalizePeerIdentifier(rawSender)
    if !candidatePeer.isEmpty {
      let known = resolveTelegramChatTitle(accountId: activeTelegramAccountId, peer: candidatePeer)
      if !known.isEmpty && !TvTelegramChat.isRawPeerIdentifier(known) {
        return known
      }
      if let found = telegramChats.first(where: {
        TvTelegramChat.normalizePeerIdentifier($0.peer) == candidatePeer
          && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !TvTelegramChat.isRawPeerIdentifier($0.title)
      }) {
        return found.title
      }
      for acc in telegramAccounts where !acc.userId.isEmpty && "user:\(acc.userId)" == candidatePeer {
        let accName = acc.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !accName.isEmpty && !TvTelegramChat.isRawPeerIdentifier(accName) {
          return accName
        }
      }
    }
    if message.outgoing && !chat.broadcast {
      return "我"
    }
    return chatTitle
  }

  func isGroupConversation(_ chat: TvTelegramChat) -> Bool {
    let norm = TvTelegramChat.normalizePeerIdentifier(chat.peer)
    if norm.hasPrefix("chat:") { return true }
    if norm.hasPrefix("channel:") && !chat.broadcast { return true }
    if chat.kind.contains("群") { return true }
    return false
  }

  struct TvGroupMemberItem: Identifiable {
    let id: String
    let name: String
    let peer: String
    let avatar: String
    let lastActiveDate: Int
    let messageCount: Int
    let isSelf: Bool
    let roleBadge: String

    var isOnlineNow: Bool {
      if isSelf { return true }
      if lastActiveDate <= 0 { return false }
      let nowSec = Int(Date().timeIntervalSince1970)
      return (nowSec - lastActiveDate) <= 300
    }

    var statusLabel: String {
      if isSelf { return "在线" }
      if lastActiveDate <= 0 { return "最近在线" }
      let nowSec = Int(Date().timeIntervalSince1970)
      let diff = nowSec - lastActiveDate
      if diff <= 300 { return "在线" }
      if diff < 3600 { return "\(max(1, diff / 60)) 分钟前在线" }
      return "最近在线"
    }
  }

  func collectTelegramGroupMembers(for chat: TvTelegramChat) -> [TvGroupMemberItem] {
    var byKey: [String: TvGroupMemberItem] = [:]
    let chatTitle = resolveDisplayChatTitle(chat)
    var selfName = "我"
    var selfPeer = ""
    var selfAvatar = ""
    if let acc = telegramAccounts.first(where: { $0.id == activeTelegramAccountId }) {
      let n = acc.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if !n.isEmpty && n != "Telegram" && !TvTelegramChat.isRawPeerIdentifier(n) {
        selfName = n
      }
      if !acc.userId.isEmpty {
        selfPeer = "user:\(acc.userId)"
      }
      selfAvatar = acc.avatar
    }
    var selfLastDate = 0
    var selfCount = 0

    for m in telegramMessages {
      if m.outgoing && !chat.broadcast {
        selfCount += 1
        if m.date > selfLastDate { selfLastDate = m.date }
        continue
      }
      if m.isServiceMessage && m.sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        continue
      }
      let resolvedName = resolveDisplaySenderName(chat: chat, message: m).trimmingCharacters(in: .whitespacesAndNewlines)
      if resolvedName.isEmpty { continue }
      let key = resolvedName.lowercased()
      let isAnonAdmin = (resolvedName == chatTitle)
      let peer = !m.senderPeer.isEmpty ? TvTelegramChat.normalizePeerIdentifier(m.senderPeer) : ""
      let avatar = !m.senderAvatar.isEmpty ? m.senderAvatar : (isAnonAdmin ? chat.avatar : "")
      if let old = byKey[key] {
        byKey[key] = TvGroupMemberItem(
          id: key,
          name: old.name,
          peer: !old.peer.isEmpty ? old.peer : peer,
          avatar: !old.avatar.isEmpty ? old.avatar : avatar,
          lastActiveDate: max(old.lastActiveDate, m.date),
          messageCount: old.messageCount + 1,
          isSelf: false,
          roleBadge: isAnonAdmin ? "匿名管理员" : (old.messageCount + 1 >= 5 ? "活跃成员" : "")
        )
      } else {
        byKey[key] = TvGroupMemberItem(
          id: key,
          name: resolvedName,
          peer: peer,
          avatar: avatar,
          lastActiveDate: m.date,
          messageCount: 1,
          isSelf: false,
          roleBadge: isAnonAdmin ? "匿名管理员" : ""
        )
      }
    }

    byKey["__self__"] = TvGroupMemberItem(
      id: "__self__",
      name: selfName,
      peer: selfPeer,
      avatar: selfAvatar,
      lastActiveDate: selfLastDate > 0 ? selfLastDate : Int(Date().timeIntervalSince1970),
      messageCount: selfCount,
      isSelf: true,
      roleBadge: "我"
    )

    return byKey.values.sorted { a, b in
      if a.isOnlineNow != b.isOnlineNow { return a.isOnlineNow && !b.isOnlineNow }
      if a.lastActiveDate != b.lastActiveDate { return a.lastActiveDate > b.lastActiveDate }
      return a.messageCount > b.messageCount
    }
  }

  /// Returns the High-Definition (HD) avatar URL (`/api/telegram/avatar`) when available, falling back to inline preview
  func resolvePeerAvatarUrl(for chat: TvTelegramChat) -> String {
    if chat.canRequestHdAvatar {
      return api.telegramAvatarUrl(
        accountId: activeTelegramAccountId,
        peer: chat.peer,
        photoId: chat.avatarPhotoId,
        dcId: chat.avatarDcId
      )
    }
    let key = "\(activeTelegramAccountId)|\(chat.peer)"
    if let cached = knownPeerSharpAvatars[key], !cached.hdUrl.isEmpty {
      return cached.hdUrl
    }
    return chat.avatar
  }

  /// Resolves the fast inline preview (`data:image/jpeg;base64,...`) for instant 0ms placeholder rendering
  func resolvePeerPreviewAvatar(peer: String, title: String, explicit: String = "") -> String {
    let cleanExplicit = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleanExplicit.hasPrefix("data:image/") {
      return cleanExplicit
    }
    let cleanPeer = peer.trimmingCharacters(in: .whitespacesAndNewlines)
    if !cleanPeer.isEmpty {
      if let cachedPrev = knownPeerPreviewAvatars["\(activeTelegramAccountId)|\(cleanPeer)"], !cachedPrev.isEmpty {
        return cachedPrev
      }
      if let c = telegramChats.first(where: { $0.peer == cleanPeer }), !c.avatar.isEmpty {
        return c.avatar
      }
      if let acc = telegramAccounts.first(where: { $0.id == cleanPeer }) {
        if !acc.avatar.isEmpty { return acc.avatar }
        if !acc.userId.isEmpty && acc.userId != "0" {
          let userPeer = "user:\(acc.userId)"
          if let cachedUserPrev = knownPeerPreviewAvatars["\(acc.id)|\(userPeer)"] ?? knownPeerPreviewAvatars["\(activeTelegramAccountId)|\(userPeer)"],
             !cachedUserPrev.isEmpty {
            return cachedUserPrev
          }
          if let c = telegramChats.first(where: { ($0.peer == userPeer || $0.isSelf) && !$0.avatar.isEmpty }) {
            return c.avatar
          }
        }
      }
    }
    let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !cleanTitle.isEmpty {
      if let cachedTitlePrev = knownTitlePreviewAvatars["\(activeTelegramAccountId)|\(cleanTitle)"], !cachedTitlePrev.isEmpty {
        return cachedTitlePrev
      }
      if let c = telegramChats.first(where: { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == cleanTitle }),
         !c.avatar.isEmpty {
        return c.avatar
      }
    }
    return ""
  }

  /// Resolves the High-Definition (HD) avatar URL (`/api/telegram/avatar?account_id=...&peer=...&photo_id=...&dc_id=...`)
  /// matching `_resolvePeerHdAvatarUrl` in `lib/ui/screens/telegram_screen.dart` 1:1, plus support for all `user:`/`chat:`/`channel:` peers with avatars.
  func resolvePeerHdAvatarUrl(peer: String, title: String, explicit: String = "") -> String {
    let cleanExplicit = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleanExplicit.contains("/api/telegram/avatar") {
      return cleanExplicit.hasPrefix("http") ? cleanExplicit : "\(serverUrl)\(cleanExplicit)"
    }

    let cleanPeer = peer.trimmingCharacters(in: .whitespacesAndNewlines)
    if !cleanPeer.isEmpty {
      let peerKey = "\(activeTelegramAccountId)|\(cleanPeer)"
      if let cached = knownPeerSharpAvatars[peerKey], !cached.hdUrl.isEmpty {
        return cached.hdUrl
      }
      if let c = telegramChats.first(where: { $0.peer == cleanPeer && $0.canRequestHdAvatar }) {
        let hd = api.telegramAvatarUrl(
          accountId: activeTelegramAccountId,
          peer: c.peer,
          photoId: c.avatarPhotoId,
          dcId: c.avatarDcId
        )
        knownPeerSharpAvatars[peerKey] = (c.avatarPhotoId, c.avatarDcId, hd)
        return hd
      }
      for acc in telegramAccounts where acc.id == cleanPeer && !acc.userId.isEmpty && acc.userId != "0" {
        let userPeer = "user:\(acc.userId)"
        if let cachedAcc = knownPeerSharpAvatars["\(acc.id)|\(userPeer)"] ?? knownPeerSharpAvatars["\(activeTelegramAccountId)|\(userPeer)"],
           !cachedAcc.hdUrl.isEmpty {
          return cachedAcc.hdUrl
        }
        if let c = telegramChats.first(where: { ($0.peer == userPeer || $0.isSelf) && $0.canRequestHdAvatar }) {
          return api.telegramAvatarUrl(
            accountId: acc.id,
            peer: c.peer,
            photoId: c.avatarPhotoId,
            dcId: c.avatarDcId
          )
        }
        if !acc.avatar.isEmpty {
          return api.telegramAvatarUrl(
            accountId: acc.id,
            peer: userPeer,
            photoId: "",
            dcId: 0
          )
        }
      }
      // If cleanPeer is directly a valid user:/chat:/channel: peer and we have an inline preview, request its HD avatar from the backend
      if (cleanPeer.hasPrefix("user:") || cleanPeer.hasPrefix("chat:") || cleanPeer.hasPrefix("channel:"))
          && (cleanExplicit.hasPrefix("data:image/") || knownPeerPreviewAvatars[peerKey] != nil) {
        let hd = api.telegramAvatarUrl(
          accountId: activeTelegramAccountId,
          peer: cleanPeer,
          photoId: "",
          dcId: 0
        )
        knownPeerSharpAvatars[peerKey] = ("", 0, hd)
        return hd
      }
    }

    let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !cleanTitle.isEmpty {
      let titleKey = "\(activeTelegramAccountId)|\(cleanTitle)"
      if let cachedTitleHd = knownTitleHdAvatarUrls[titleKey], !cachedTitleHd.isEmpty {
        return cachedTitleHd
      }
      if let c = telegramChats.first(where: { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == cleanTitle && $0.canRequestHdAvatar }) {
        let hd = api.telegramAvatarUrl(
          accountId: activeTelegramAccountId,
          peer: c.peer,
          photoId: c.avatarPhotoId,
          dcId: c.avatarDcId
        )
        knownTitleHdAvatarUrls[titleKey] = hd
        return hd
      }
    }

    if cleanExplicit.hasPrefix("http://") || cleanExplicit.hasPrefix("https://") {
      return cleanExplicit
    }
    return ""
  }

  func loadTelegramAccounts(preferredId: String? = nil) async {
    isLoadingTelegram = true
    defer { isLoadingTelegram = false }
    let res = await api.fetchTelegramAccounts()
    self.telegramAccounts = res.accounts
    let targetId = preferredId ?? (!res.activeId.isEmpty ? res.activeId : (res.accounts.first?.id ?? "default"))
    self.activeTelegramAccountId = targetId
    self.telegramAuthStatus = await api.fetchTelegramStatus(accountId: targetId)
    if telegramAuthStatus.authorized {
      self.telegramFolders = await api.fetchTelegramFolders(accountId: targetId)
      await loadTelegramChats(accountId: targetId, folder: selectedTelegramFolderKey, loadMore: false)
    } else {
      self.telegramChats = []
      self.telegramMessages = []
      self.selectedTelegramChat = nil
    }
  }

  func switchTelegramAccount(_ accountId: String) async {
    await api.setActiveTelegramAccount(accountId)
    selectedTelegramFolderKey = "0"
    await loadTelegramAccounts(preferredId: accountId)
  }

  func switchTelegramFolder(_ folderKey: String) async {
    selectedTelegramFolderKey = folderKey
    await loadTelegramChats(accountId: activeTelegramAccountId, folder: folderKey, loadMore: false)
  }

  func loadTelegramChats(accountId: String, folder: String = "0", loadMore: Bool = false) async {
    isLoadingTelegram = true
    defer { isLoadingTelegram = false }
    let res = await api.fetchTelegramChats(
      accountId: accountId,
      folder: folder,
      cursor: loadMore ? nextTelegramChatCursor : ""
    )
    var updatedChats: [TvTelegramChat] = []
    for rawChat in res.chats {
      var chat = rawChat
      let peerKey = "\(accountId)|\(chat.peer)"
      var cleanTitle = chat.title.trimmingCharacters(in: .whitespacesAndNewlines)
      if cleanTitle.isEmpty || TvTelegramChat.isRawPeerIdentifier(cleanTitle) {
        let known = resolveTelegramChatTitle(accountId: accountId, peer: chat.peer)
        cleanTitle = (!known.isEmpty && !TvTelegramChat.isRawPeerIdentifier(known))
          ? known
          : TvTelegramChat.friendlyFallbackTitle(forPeer: chat.peer, kind: chat.kind)
        chat = TvTelegramChat(
          peer: chat.peer,
          title: cleanTitle,
          kind: chat.kind,
          preview: chat.preview,
          avatar: chat.avatar,
          avatarPhotoId: chat.avatarPhotoId,
          avatarDcId: chat.avatarDcId,
          date: chat.date,
          unread: chat.unread,
          readOnly: chat.readOnly,
          broadcast: chat.broadcast,
          isSelf: chat.isSelf,
          isContact: chat.isContact,
          muted: chat.muted,
          topMessageId: chat.topMessageId,
          readOutboxMaxId: chat.readOutboxMaxId
        )
      } else {
        registerTelegramChatTitle(accountId: accountId, peer: chat.peer, title: cleanTitle)
      }
      let titleKey = (cleanTitle.isEmpty || TvTelegramChat.isRawPeerIdentifier(cleanTitle))
        ? ""
        : "\(accountId)|\(cleanTitle)"

      if !chat.avatar.isEmpty && chat.avatar != "<null>" {
        knownPeerPreviewAvatars[peerKey] = chat.avatar
        if !titleKey.isEmpty {
          knownTitlePreviewAvatars[titleKey] = chat.avatar
        }
      } else if let cachedPrev = knownPeerPreviewAvatars[peerKey], !cachedPrev.isEmpty {
        chat = TvTelegramChat(
          peer: chat.peer,
          title: chat.title,
          kind: chat.kind,
          preview: chat.preview,
          avatar: cachedPrev,
          avatarPhotoId: chat.avatarPhotoId,
          avatarDcId: chat.avatarDcId,
          date: chat.date,
          unread: chat.unread,
          readOnly: chat.readOnly,
          broadcast: chat.broadcast,
          isSelf: chat.isSelf,
          isContact: chat.isContact,
          muted: chat.muted,
          topMessageId: chat.topMessageId,
          readOutboxMaxId: chat.readOutboxMaxId
        )
      }

      if chat.canRequestHdAvatar {
        let hdUrl = api.telegramAvatarUrl(
          accountId: accountId,
          peer: chat.peer,
          photoId: chat.avatarPhotoId,
          dcId: chat.avatarDcId
        )
        knownPeerSharpAvatars[peerKey] = (chat.avatarPhotoId, chat.avatarDcId, hdUrl)
        if !titleKey.isEmpty {
          knownTitleHdAvatarUrls[titleKey] = hdUrl
        }
      } else if let cachedSharp = knownPeerSharpAvatars[peerKey] {
        chat = TvTelegramChat(
          peer: chat.peer,
          title: chat.title,
          kind: chat.kind,
          preview: chat.preview,
          avatar: chat.avatar,
          avatarPhotoId: cachedSharp.photoId,
          avatarDcId: cachedSharp.dcId,
          date: chat.date,
          unread: chat.unread,
          readOnly: chat.readOnly,
          broadcast: chat.broadcast,
          isSelf: chat.isSelf,
          isContact: chat.isContact,
          muted: chat.muted,
          topMessageId: chat.topMessageId,
          readOutboxMaxId: chat.readOutboxMaxId
        )
      }
      updatedChats.append(chat)
    }

    telegramAvatarRegistryVersion &+= 1

    if loadMore {
      let existingPeers = Set(telegramChats.map { $0.peer })
      telegramChats.append(contentsOf: updatedChats.filter { !existingPeers.contains($0.peer) })
    } else {
      telegramChats = updatedChats
      if let first = telegramChats.first,
         (selectedTelegramChat == nil || !telegramChats.contains(where: { $0.peer == selectedTelegramChat?.peer })) {
        await selectTelegramChat(first)
      }
    }
    nextTelegramChatCursor = res.nextCursor
  }

  func selectTelegramChat(_ chat: TvTelegramChat) async {
    let isGroup = chat.peer.hasPrefix("chat:") || (chat.peer.hasPrefix("channel:") && !chat.broadcast) || chat.kind.contains("群")
    if selectedTelegramChat?.peer != chat.peer {
      telegramRightPanelTab = isGroup ? "members" : "video"
    }
    selectedTelegramChat = chat
    telegramReplyingTo = nil
    telegramSelectionMode = false
    telegramSelectedMessageIds.removeAll()
    isLoadingTelegram = true
    defer { isLoadingTelegram = false }
    let res = await api.fetchTelegramMessages(accountId: activeTelegramAccountId, peer: chat.peer, offsetId: 0)
    let normalized = res.messages.map { m -> TvTelegramMessage in
      let rawSender = m.sender.trimmingCharacters(in: .whitespacesAndNewlines)
      if !rawSender.isEmpty && !TvTelegramChat.isRawPeerIdentifier(rawSender) {
        if chat.peer.hasPrefix("user:") && !m.outgoing && rawSender != "收藏夹" {
          registerTelegramChatTitle(accountId: activeTelegramAccountId, peer: chat.peer, title: rawSender)
        }
        return m
      }
      if rawSender.isEmpty && (m.isServiceMessage || m.isPhoneCall) {
        return m
      }
      let resolved = resolveDisplaySenderName(chat: chat, message: m)
      if !resolved.isEmpty && !TvTelegramChat.isRawPeerIdentifier(resolved) {
        return TvTelegramMessage(
          id: m.id,
          date: m.date,
          sender: resolved,
          senderPeer: m.senderPeer,
          senderAvatar: m.senderAvatar,
          text: m.text,
          outgoing: m.outgoing,
          groupedId: m.groupedId,
          replyToId: m.replyToId,
          links: m.links,
          buttons: m.buttons,
          attachment: m.attachment
        )
      }
      return m
    }
    self.telegramMessages = normalized
    self.nextTelegramMessageOffset = res.nextOffset
    if let lastMsg = normalized.last {
      let fallbackPrev = lastMsg.resolvedPreviewText(isPrivateUserChat: chat.peer.hasPrefix("user:"))
      if !fallbackPrev.isEmpty,
         let idx = telegramChats.firstIndex(where: { $0.peer == chat.peer }),
         (telegramChats[idx].preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || lastMsg.id >= telegramChats[idx].topMessageId) {
        let old = telegramChats[idx]
        telegramChats[idx] = TvTelegramChat(
          peer: old.peer,
          title: old.title,
          kind: old.kind,
          preview: fallbackPrev,
          avatar: old.avatar,
          avatarPhotoId: old.avatarPhotoId,
          avatarDcId: old.avatarDcId,
          date: old.date,
          unread: old.unread,
          readOnly: old.readOnly,
          broadcast: old.broadcast,
          isSelf: old.isSelf,
          isContact: old.isContact,
          muted: old.muted,
          topMessageId: max(old.topMessageId, lastMsg.id),
          readOutboxMaxId: old.readOutboxMaxId
        )
      }
    }
    if chat.unread > 0 {
      await markChatAsRead(chat, maxId: normalized.last?.id ?? 0)
    }
  }

  func selectSavedMessagesChat() async {
    if let found = telegramChats.first(where: { $0.isSelf || $0.peer == "self" || $0.title == "收藏夹" }) {
      await selectTelegramChat(found)
    } else {
      let selfChat = TvTelegramChat(
        peer: "self",
        title: "收藏夹 (Saved Messages)",
        kind: "私聊",
        preview: "",
        avatar: "",
        avatarPhotoId: "",
        avatarDcId: 0,
        date: Int(Date().timeIntervalSince1970),
        unread: 0,
        readOnly: false,
        broadcast: false,
        isSelf: true,
        isContact: false,
        muted: false,
        topMessageId: 0,
        readOutboxMaxId: 0
      )
      await selectTelegramChat(selfChat)
    }
  }

  func markChatAsRead(_ chat: TvTelegramChat, maxId: Int = 0) async {
    if let idx = telegramChats.firstIndex(where: { $0.peer == chat.peer }) {
      let old = telegramChats[idx]
      telegramChats[idx] = TvTelegramChat(
        peer: old.peer,
        title: old.title,
        kind: old.kind,
        preview: old.preview,
        avatar: old.avatar,
        avatarPhotoId: old.avatarPhotoId,
        avatarDcId: old.avatarDcId,
        date: old.date,
        unread: 0,
        readOnly: old.readOnly,
        broadcast: old.broadcast,
        isSelf: old.isSelf,
        isContact: old.isContact,
        muted: old.muted,
        topMessageId: old.topMessageId,
        readOutboxMaxId: old.readOutboxMaxId
      )
    }
    await api.markTelegramChatRead(accountId: activeTelegramAccountId, peer: chat.peer, maxId: maxId)
  }

  func markAllTelegramChatsRead() async {
    let unreadChats = telegramChats.filter { $0.unread > 0 }
    guard !unreadChats.isEmpty else {
      showToast("所有会话均已读")
      return
    }
    for c in unreadChats {
      await markChatAsRead(c, maxId: c.topMessageId)
    }
    showToast("已将 \(unreadChats.count) 个会话全部标为已读")
  }

  func loadOlderTelegramMessages() async {
    guard let chat = selectedTelegramChat, nextTelegramMessageOffset > 0, !isLoadingTelegram else { return }
    isLoadingTelegram = true
    defer { isLoadingTelegram = false }
    let res = await api.fetchTelegramMessages(
      accountId: activeTelegramAccountId,
      peer: chat.peer,
      offsetId: nextTelegramMessageOffset
    )
    let existingIds = Set(telegramMessages.map { $0.id })
    let incoming = res.messages.filter { !existingIds.contains($0.id) }
    telegramMessages = (incoming + telegramMessages).sorted { $0.id < $1.id }
    nextTelegramMessageOffset = incoming.isEmpty ? 0 : res.nextOffset
  }

  func sendTelegramMessage(text: String) async {
    guard let chat = selectedTelegramChat else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let replyId = telegramReplyingTo?.id ?? 0
    telegramReplyingTo = nil
    telegramDrafts[draftKey(for: chat)] = ""
    do {
      if let sent = try await api.sendTelegramTextMessage(
        accountId: activeTelegramAccountId,
        peer: chat.peer,
        text: trimmed,
        replyTo: replyId
      ) {
        if !telegramMessages.contains(where: { $0.id == sent.id }) {
          telegramMessages.append(sent)
          telegramMessages.sort { $0.id < $1.id }
        }
      } else {
        await selectTelegramChat(chat)
      }
    } catch {
      showToast("发送失败：\(error.localizedDescription)")
    }
  }

  func forwardTelegramMessages(_ messages: [TvTelegramMessage], to targetChat: TvTelegramChat) async {
    guard !messages.isEmpty else { return }
    let srcTitle = selectedTelegramChat?.title ?? "会话"
    var okCount = 0
    for m in messages {
      let who = m.sender.isEmpty ? srcTitle : m.sender
      var lines = ["📤 [转发自 \(who)]"]
      if !m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        lines.append(m.text.trimmingCharacters(in: .whitespacesAndNewlines))
      }
      if let att = m.attachment {
        lines.append("📎 \(att.displayName) \(att.formattedSize)")
      }
      let body = lines.joined(separator: "\n")
      if (try? await api.sendTelegramTextMessage(
        accountId: activeTelegramAccountId,
        peer: targetChat.peer,
        text: body,
        replyTo: 0
      )) != nil {
        okCount += 1
      }
    }
    showToast("已转发 \(max(1, okCount)) 条消息至「\(targetChat.title)」")
  }

  func deleteSelectedTelegramMessages(chat: TvTelegramChat) async {
    let ids = Array(telegramSelectedMessageIds)
    guard !ids.isEmpty else { return }
    do {
      try await api.deleteTelegramMessages(accountId: activeTelegramAccountId, peer: chat.peer, messageIds: ids)
      telegramMessages.removeAll { telegramSelectedMessageIds.contains($0.id) }
      telegramSelectedMessageIds.removeAll()
      telegramSelectionMode = false
      showToast("已删除 \(ids.count) 条消息")
    } catch {
      showToast("删除消息失败：\(error.localizedDescription)")
    }
  }

  func openTelegramFilePreview(chat: TvTelegramChat, message: TvTelegramMessage) async {
    do {
      let preview = try await api.fetchTelegramFilePreview(
        accountId: activeTelegramAccountId,
        peer: chat.peer,
        messageId: message.id
      )
      self.activeTelegramFilePreview = preview
    } catch {
      showToast("无法预览此文件：\(error.localizedDescription)")
    }
  }

  func openTelegramGallery(chat: TvTelegramChat, message: TvTelegramMessage, albumMessages: [TvTelegramMessage]? = nil) {
    if message.attachment?.isVideo == true {
      stopBackgroundAudioForVideoPlayback()
    }
    let visualMedia = telegramMessages.filter { $0.isVisualMedia }
    let items = visualMedia.isEmpty ? (albumMessages ?? [message]) : visualMedia
    let idx = items.firstIndex(where: { $0.id == message.id }) ?? 0
    if items.indices.contains(idx), items[idx].attachment?.isVideo == true {
      stopBackgroundAudioForVideoPlayback()
    }
    self.galleryControlsVisible = true
    self.activeTelegramGallery = TvTelegramGallerySession(
      accountId: activeTelegramAccountId,
      chat: chat,
      mediaMessages: items,
      initialIndex: idx
    )
  }

  func openTelegramMiniPlayer(chat: TvTelegramChat, message: TvTelegramMessage) {
    stopBackgroundAudioForVideoPlayback()
    self.miniPlayerChat = chat
    self.miniPlayerMessage = message
  }

  func closeTelegramMiniPlayer() {
    self.miniPlayerMessage = nil
    self.miniPlayerChat = nil
  }

  // MARK: - Official Telegram Music / Voice Audio Player

  func togglePlayAudioMessage(chat: TvTelegramChat, message: TvTelegramMessage, forceRestart: Bool = false) {
    guard let att = message.attachment, att.isAudio else { return }
    if !forceRestart,
       playingAudioMessage?.id == message.id,
       playingAudioChat?.peer == chat.peer,
       let player = audioPlayer {
      if isAudioPlaying {
        player.pause()
        isAudioPlaying = false
      } else {
        if isCloudMusicPlaying || isCloudMusicLoading || cloudMusicPlayer != nil || isCloudMusicSessionDocked {
          stopCloudMusicPlayer(clearPersistedQueue: false)
        }
        player.playImmediately(atRate: audioSpeed)
        isAudioPlaying = true
      }
      return
    }

    if isCloudMusicPlaying || isCloudMusicLoading || cloudMusicPlayer != nil || isCloudMusicSessionDocked {
      stopCloudMusicPlayer(clearPersistedQueue: false)
    }
    stopAudioPlayer()
    playingAudioChat = chat
    playingAudioMessage = message
    audioDuration = Double(max(1, att.duration))
    audioPosition = 0

    let streamUrl = api.telegramAcceleratedFileContentUrl(
      accountId: activeTelegramAccountId,
      peer: chat.peer,
      messageId: message.id
    )
    guard let url = URL(string: streamUrl) else { return }
    let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": api.authHeaders])
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = 30
    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = true
    self.audioPlayer = player

    audioTimeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
      queue: .main
    ) { [weak self] time in
      let sec = CMTimeGetSeconds(time)
      let durSec = player.currentItem.map { CMTimeGetSeconds($0.duration) } ?? 0
      Task { @MainActor [weak self] in
        guard let self = self else { return }
        if sec.isFinite && sec >= 0 {
          self.audioPosition = sec
        }
        if durSec.isFinite && durSec > 0 {
          self.audioDuration = durSec
        }
      }
    }

    audioEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      Task { @MainActor in
        self.onAudioTrackCompleted()
      }
    }

    player.playImmediately(atRate: audioSpeed)
    isAudioPlaying = true
  }

  private func onAudioTrackCompleted() {
    guard let chat = playingAudioChat, let current = playingAudioMessage else { return }
    if audioPlayMode == "repeatOne" {
      audioPlayer?.seek(to: .zero)
      audioPlayer?.playImmediately(atRate: audioSpeed)
      return
    }
    let playlist = telegramMessages.filter { $0.isAudio }
    guard playlist.count > 1, let curIdx = playlist.firstIndex(where: { $0.id == current.id }) else {
      isAudioPlaying = false
      audioPosition = 0
      return
    }
    if audioPlayMode == "shuffle" {
      let others = playlist.filter { $0.id != current.id }
      if let randomNext = others.randomElement() {
        togglePlayAudioMessage(chat: chat, message: randomNext, forceRestart: true)
        return
      }
    }
    let nextIdx = curIdx + 1
    if nextIdx < playlist.count {
      togglePlayAudioMessage(chat: chat, message: playlist[nextIdx], forceRestart: true)
    } else if audioPlayMode == "repeatAll", let first = playlist.first {
      togglePlayAudioMessage(chat: chat, message: first, forceRestart: true)
    } else {
      isAudioPlaying = false
      audioPosition = 0
    }
  }

  func playAdjacentAudioTrack(delta: Int) {
    guard let chat = playingAudioChat, let current = playingAudioMessage else { return }
    let playlist = telegramMessages.filter { $0.isAudio }
    guard !playlist.isEmpty else { return }
    guard let curIdx = playlist.firstIndex(where: { $0.id == current.id }) else {
      togglePlayAudioMessage(chat: chat, message: playlist[0], forceRestart: true)
      return
    }
    let nextIdx = (curIdx + delta + playlist.count) % playlist.count
    togglePlayAudioMessage(chat: chat, message: playlist[nextIdx], forceRestart: true)
  }

  func cycleAudioSpeed() {
    let speeds: [Float] = [1.0, 1.25, 1.5, 2.0]
    let nextIdx = ((speeds.firstIndex(of: audioSpeed) ?? 0) + 1) % speeds.count
    audioSpeed = speeds[nextIdx]
    if isAudioPlaying {
      audioPlayer?.rate = audioSpeed
    }
  }

  func cycleAudioPlayMode() {
    let modes = ["sequential", "repeatAll", "repeatOne", "shuffle"]
    let idx = modes.firstIndex(of: audioPlayMode) ?? 0
    audioPlayMode = modes[(idx + 1) % modes.count]
    let label: String
    switch audioPlayMode {
    case "repeatAll": label = "列表循环"
    case "repeatOne": label = "单曲循环"
    case "shuffle": label = "随机播放"
    default: label = "顺序连播"
    }
    showToast("音乐播放模式：\(label)")
  }

  func stopAudioPlayer() {
    if let obs = audioTimeObserver {
      audioPlayer?.removeTimeObserver(obs)
      audioTimeObserver = nil
    }
    if let endObs = audioEndObserver {
      NotificationCenter.default.removeObserver(endObs)
      audioEndObserver = nil
    }
    audioPlayer?.pause()
    audioPlayer = nil
    isAudioPlaying = false
    playingAudioMessage = nil
    playingAudioChat = nil
    audioPosition = 0
    audioDuration = 0
  }

  func queueTelegramDownload(chat: TvTelegramChat, message: TvTelegramMessage, silent: Bool = false) async -> Bool {
    guard let att = message.attachment else { return false }
    let rawUrl = att.url.isEmpty
      ? api.telegramVideoUrl(accountId: activeTelegramAccountId, peer: chat.peer, messageId: message.id)
      : (att.url.hasPrefix("http") ? att.url : "\(serverUrl)\(att.url)")
    let name = att.displayName
    do {
      try await api.createDownloadTask(
        url: rawUrl,
        name: name,
        headers: api.authHeaders,
        telegramAccountId: activeTelegramAccountId
      )
      if !silent {
        showToast("已加入服务器转存队列：\(name)")
        await refreshDownloadTasks()
      }
      return true
    } catch {
      if !silent {
        showToast("转存失败：\(error.localizedDescription)")
      }
      return false
    }
  }

  func batchQueueTelegramDownloads(chat: TvTelegramChat, messages: [TvTelegramMessage]) async {
    var okCount = 0
    for m in messages where m.attachment != nil {
      if await queueTelegramDownload(chat: chat, message: m, silent: true) {
        okCount += 1
      }
    }
    await refreshDownloadTasks()
    showToast(okCount > 0 ? "已将 \(okCount) 项媒体批量加入转存下载队列" : "未找到可转存的媒体附件")
  }

  func performConversationAction(chat: TvTelegramChat) async {
    let action = chat.conversationActionType
    let label = chat.conversationActionLabel
    guard !action.isEmpty else { return }
    do {
      try await api.performTelegramConversationAction(
        accountId: activeTelegramAccountId,
        peer: chat.peer,
        action: action
      )
      telegramChats.removeAll { $0.peer == chat.peer }
      if selectedTelegramChat?.peer == chat.peer {
        selectedTelegramChat = telegramChats.first
        if let next = selectedTelegramChat {
          await selectTelegramChat(next)
        } else {
          telegramMessages = []
        }
      }
      showToast("已成功\(label)：\(chat.title)")
    } catch {
      showToast("\(label)失败：\(error.localizedDescription)")
    }
  }

  // MARK: - 6. Downloads & Web Extract

  func refreshDownloadTasks() async {
    isLoadingTasks = true
    defer { isLoadingTasks = false }
    self.downloadTasks = await api.fetchDownloadTasks()
  }

  func extractWebVideoCandidates(input: String) async {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    isExtractingWeb = true
    defer { isExtractingWeb = false }
    do {
      self.extractedCandidates = try await api.extractWebVideo(urlOrText: trimmed)
      if extractedCandidates.isEmpty {
        showToast("未嗅探到可直接播放的视频流")
      } else {
        showToast("嗅探成功：共发现 \(extractedCandidates.count) 个视频流")
      }
    } catch {
      showToast("嗅探失败：\(error.localizedDescription)")
    }
  }

  func playDirectStream(title: String, subtitle: String, url: String, headers: [String: String] = [:]) {
    var merged = headers
    if url.contains(serverUrl), !api.cookieHeaderValue.isEmpty {
      merged["Cookie"] = api.cookieHeaderValue
    }
    let proxy = api.buildServerProxyUrl(targetUrl: url, headers: merged)
    self.playerControlsVisible = true
    self.playerShowEpisodeDrawer = false
    self.activePlayback = TvPlaybackRequest(
      title: title,
      subtitle: subtitle,
      streamUrl: url,
      backupProxyUrl: proxy,
      headers: merged,
      resumeSeconds: 0,
      isLive: false,
      vodSource: nil,
      vodDetail: nil,
      playGroupIndex: 0,
      episodeIndex: 0,
      liveChannel: nil,
      liveUrlIndex: 0
    )
  }

  // MARK: - 7. Multi-Storage File Manager (Server / AList / WebDAV / 115 / Apple TV Local Cache) & Transfer Engine

  var activeStorageMount: TvStorageMount {
    storageMounts.first(where: { $0.id == activeStorageMountId })
      ?? TvStorageMount(id: "builtin_server", name: "流光服务端", kind: .server, rootPath: "/", enabled: true)
  }

  private func persistStorageMounts() {
    let customOnly = storageMounts.filter { !$0.isBuiltIn }
    if let data = try? JSONEncoder().encode(customOnly) {
      defaults.set(data, forKey: "tv_storage_mounts_v1")
    }
  }

  @discardableResult
  func upsertStorageMount(
    id: String? = nil,
    name: String,
    kind: TvStorageSourceKind,
    baseUrl: String,
    username: String,
    password: String,
    token: String,
    rootPath: String
  ) -> TvStorageMount {
    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "\(kind.title) (\(URL(string: baseUrl)?.host ?? "远程盘"))"
      : name.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanRoot = rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "/"
      : TvRemoteStorageClient.normalizePath(rootPath)
    if let editId = id, let idx = storageMounts.firstIndex(where: { $0.id == editId }) {
      storageMounts[idx].name = cleanName
      storageMounts[idx].kind = kind
      storageMounts[idx].baseUrl = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
      storageMounts[idx].username = username.trimmingCharacters(in: .whitespacesAndNewlines)
      storageMounts[idx].password = password
      storageMounts[idx].token = token.trimmingCharacters(in: .whitespacesAndNewlines)
      storageMounts[idx].rootPath = cleanRoot
      persistStorageMounts()
      showToast("✓ 已更新挂载存储：\(cleanName)")
      return storageMounts[idx]
    }
    let mount = TvStorageMount(
      id: "mount_\(Int(Date().timeIntervalSince1970 * 1000))",
      name: cleanName,
      kind: kind,
      baseUrl: baseUrl.trimmingCharacters(in: .whitespacesAndNewlines),
      username: username.trimmingCharacters(in: .whitespacesAndNewlines),
      password: password,
      token: token.trimmingCharacters(in: .whitespacesAndNewlines),
      rootPath: cleanRoot,
      enabled: true
    )
    storageMounts.append(mount)
    persistStorageMounts()
    showToast("✓ 已挂载 \(kind.title)：\(cleanName)")
    return mount
  }

  func deleteStorageMount(_ mountId: String) {
    guard let mount = storageMounts.first(where: { $0.id == mountId }), !mount.isBuiltIn else { return }
    storageMounts.removeAll { $0.id == mountId }
    persistStorageMounts()
    if activeStorageMountId == mountId {
      switchStorageMount("builtin_server")
    }
    showToast("已卸载远程存储：\(mount.name)")
  }

  func recomputeDisplayedFileEntries() {
    let keyword = fileSearchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let cat = fileCategoryFilter
    let raw = fileListing.entries
    let filtered = raw.filter { entry in
      if !keyword.isEmpty && !entry.name.lowercased().contains(keyword) {
        return false
      }
      if entry.isDir {
        return true
      }
      switch cat {
      case .all:
        return true
      case .video:
        return entry.isVideo
      case .audio:
        return entry.isAudio
      case .image:
        return entry.isImage
      case .document:
        return entry.isTextPreviewable || entry.isArchive
      }
    }

    let useFastCompare = filtered.count > 250
    let sortOpt = fileSortOption
    displayedFileEntries = filtered.sorted { a, b in
      if a.isDir != b.isDir {
        return a.isDir && !b.isDir
      }
      switch sortOpt {
      case .nameAsc:
        if useFastCompare { return a.name < b.name }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
      case .sizeDesc:
        if a.size != b.size { return a.size > b.size }
        return a.name < b.name
      case .dateDesc:
        if a.modTime != b.modTime { return a.modTime > b.modTime }
        return a.name < b.name
      case .typeAsc:
        if a.normalizedExt != b.normalizedExt { return a.normalizedExt < b.normalizedExt }
        return a.name < b.name
      }
    }
  }

  func switchStorageMount(_ mountId: String) {
    guard let mount = storageMounts.first(where: { $0.id == mountId }) else { return }
    loadFilesGeneration &+= 1
    activeStorageMountId = mount.id
    defaults.set(mount.id, forKey: "tv_active_storage_mount_id_v1")
    fileMultiSelectMode = false
    fileSelectedPaths.removeAll()
    fileSearchKeyword = ""
    fileManagerError = nil
    visibleFileLimit = 80
    let initialPath = mount.kind == .cloud115 ? "0" : (mount.kind == .server ? "" : mount.rootPath)
    let initialRoot = mount.kind == .cloud115 ? "0" : (mount.kind == .server ? "/" : mount.rootPath)
    fileListing = TvFileListing(path: initialPath, parent: "", root: initialRoot, entries: [])
    displayedFileEntries = []
    if mount.kind == .cloud115 {
      cloud115Breadcrumbs = [("0", "115根目录")]
    }
    Task {
      await loadFiles(path: initialPath)
    }
  }

  func toggleFileViewMode() {
    fileViewIsGrid.toggle()
    defaults.set(fileViewIsGrid, forKey: "tv_file_view_grid_v1")
  }

  func toggleFavoriteCurrentDirectory() {
    let mount = activeStorageMount
    let curPath = fileListing.path.isEmpty ? mount.rootPath : fileListing.path
    let folderName: String = {
      if mount.kind == .cloud115 {
        return cloud115Breadcrumbs.last?.name ?? "115目录"
      }
      let last = (curPath as NSString).lastPathComponent
      return (last.isEmpty || last == "/") ? mount.name : last
    }()
    let keyPrefix = "\(mount.id)::"
    let existingIdx = fileFavoritePaths.firstIndex(where: { item in
      let parts = item.components(separatedBy: "::")
      return parts.count >= 3 && parts[0] == mount.id && parts.dropFirst(2).joined(separator: "::") == curPath
    })
    if let idx = existingIdx {
      fileFavoritePaths.remove(at: idx)
      defaults.set(fileFavoritePaths, forKey: "tv_file_fav_paths_v1")
      showToast("已取消收藏目录：\(folderName)")
    } else {
      let record = "\(keyPrefix)\(folderName)::\(curPath)"
      fileFavoritePaths.insert(record, at: 0)
      defaults.set(fileFavoritePaths, forKey: "tv_file_fav_paths_v1")
      showToast("★ 已收藏常用目录：\(folderName)")
    }
  }

  var isCurrentDirectoryFavorited: Bool {
    let mount = activeStorageMount
    let curPath = fileListing.path.isEmpty ? mount.rootPath : fileListing.path
    return fileFavoritePaths.contains(where: { item in
      let parts = item.components(separatedBy: "::")
      return parts.count >= 3 && parts[0] == mount.id && parts.dropFirst(2).joined(separator: "::") == curPath
    })
  }

  nonisolated static func localOfflineRootUrl() -> URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let dir = base.appendingPathComponent("TvOfflineFiles", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  nonisolated static func resolveLocalOfflineUrl(relativePath: String) -> URL {
    let root = localOfflineRootUrl()
    let clean = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if clean.isEmpty { return root }
    return root.appendingPathComponent(clean)
  }

  private func listLocalOfflineDirectory(path: String) -> TvFileListing {
    let norm = TvRemoteStorageClient.normalizePath(path)
    let targetUrl = Self.resolveLocalOfflineUrl(relativePath: norm)
    let fm = FileManager.default
    try? fm.createDirectory(at: targetUrl, withIntermediateDirectories: true)
    let items = (try? fm.contentsOfDirectory(
      at: targetUrl,
      includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm"

    var entries: [TvFileEntry] = []
    for itemUrl in items {
      let vals = try? itemUrl.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
      let isDir = vals?.isDirectory == true
      let size = Int64(vals?.fileSize ?? 0)
      let modDate = vals?.contentModificationDate ?? Date()
      let name = itemUrl.lastPathComponent
      let itemPath = TvRemoteStorageClient.joinPath(norm, name)
      let ext = isDir ? "" : ".\(itemUrl.pathExtension.lowercased())"
      entries.append(
        TvFileEntry(
          name: name,
          path: itemPath,
          size: size,
          modTime: df.string(from: modDate),
          isDir: isDir,
          isMp4: ext == ".mp4",
          ext: ext,
          mountId: "builtin_local",
          sourceKind: .localCache,
          rawDownloadUrl: itemUrl.absoluteString
        )
      )
    }

    return TvFileListing(
      path: norm,
      parent: TvRemoteStorageClient.parentPath(of: norm),
      root: "/",
      entries: entries
    )
  }

  func loadFiles(path: String, folderTitleHint: String? = nil) async {
    loadFilesGeneration &+= 1
    let reqGen = loadFilesGeneration
    let mount = activeStorageMount
    let reqMountId = mount.id

    if path != fileListing.path && !fileSearchKeyword.isEmpty {
      fileSearchKeyword = ""
    }
    isLoadingFiles = true
    fileManagerError = nil
    visibleFileLimit = 80
    defer {
      if reqGen == self.loadFilesGeneration {
        isLoadingFiles = false
      }
    }

    do {
      let listing: TvFileListing
      switch mount.kind {
      case .server:
        listing = try await api.fetchFiles(path: path)

      case .alist:
        listing = try await TvRemoteStorageClient.shared.listAlistDirectory(mount: mount, path: path, page: 1, perPage: 250)

      case .webdav:
        listing = try await TvRemoteStorageClient.shared.listWebdavDirectory(mount: mount, path: path)

      case .smb:
        listing = try await TvSmbClient.shared.listSmbDirectory(mount: mount, path: path)

      case .cloud115:
        if !TvLocal115DirectClient.shared.hasLocalCookie {
          let srvSettings = await api.fetchServerSettings()
          let srvCookie = TvApiClient.stringValue(
            srvSettings["cookie_115"],
            fallback: TvApiClient.stringValue(
              srvSettings["115_cookie"],
              fallback: TvApiClient.stringValue(srvSettings["cookies"])
            )
          )
          let norm = TvLocal115DirectClient.normalizeCookieString(srvCookie)
          if norm.contains("UID=") && norm.contains("CID=") && norm.contains("SEID=") {
            TvLocal115DirectClient.shared.savedCookie = norm
            self.is115LoggedIn = true
          }
        }
        let targetCid = (path.isEmpty || path == "/") ? "0" : path
        listing = try await TvLocal115DirectClient.shared.list115Directory(cid: targetCid, mountId: mount.id, page: 1, perPage: 100)
        guard reqGen == self.loadFilesGeneration, reqMountId == self.activeStorageMountId else { return }
        if targetCid == "0" {
          self.cloud115Breadcrumbs = [("0", "115根目录")]
        } else if let existingIdx = self.cloud115Breadcrumbs.firstIndex(where: { $0.cid == targetCid }) {
          self.cloud115Breadcrumbs = Array(self.cloud115Breadcrumbs.prefix(existingIdx + 1))
        } else {
          let title = folderTitleHint ?? "目录 \(targetCid.prefix(6))"
          self.cloud115Breadcrumbs.append((targetCid, title))
        }

      case .localCache:
        listing = listLocalOfflineDirectory(path: path)
      }

      guard reqGen == self.loadFilesGeneration, reqMountId == self.activeStorageMountId else { return }
      self.fileListing = listing
      self.recomputeDisplayedFileEntries()
      // If a previous category filter (e.g. Audio/Image) hides every item in the newly entered directory, auto-reset filter to `.all` so the folder never appears blank!
      if self.displayedFileEntries.isEmpty && !listing.entries.isEmpty && self.fileCategoryFilter != .all {
        self.fileCategoryFilter = .all
      }
    } catch {
      guard reqGen == self.loadFilesGeneration, reqMountId == self.activeStorageMountId else { return }
      let fallbackPath = mount.kind == .cloud115 ? ((path.isEmpty || path == "/") ? "0" : path) : path
      let fallbackRoot = mount.kind == .cloud115 ? "0" : mount.rootPath
      let fallbackParent = mount.kind == .cloud115 ? "0" : TvRemoteStorageClient.parentPath(of: fallbackPath)
      self.fileListing = TvFileListing(path: fallbackPath, parent: fallbackParent, root: fallbackRoot, entries: [])
      self.recomputeDisplayedFileEntries()
      self.fileManagerError = error.localizedDescription
      self.showToast("⚠️ 读取目录失败：\(error.localizedDescription)")
    }
  }

  /// Appends the next page of directory entries for paginated storage sources (AList / 115) so directories with thousands of files never freeze
  func loadNextPageOfFiles() async {
    guard !isLoadingFiles, !isLoadingMoreFiles, fileListing.hasMoreRemotePages else { return }
    let mount = activeStorageMount
    let nextPage = fileListing.currentPage + 1
    let curPath = fileListing.path
    let reqGen = loadFilesGeneration

    isLoadingMoreFiles = true
    defer { isLoadingMoreFiles = false }

    do {
      let nextListing: TvFileListing
      switch mount.kind {
      case .alist:
        nextListing = try await TvRemoteStorageClient.shared.listAlistDirectory(
          mount: mount,
          path: curPath,
          page: nextPage,
          perPage: 250
        )
      case .cloud115:
        nextListing = try await TvLocal115DirectClient.shared.list115Directory(
          cid: curPath.isEmpty ? "0" : curPath,
          mountId: mount.id,
          page: nextPage,
          perPage: 100
        )
      default:
        return
      }
      guard reqGen == self.loadFilesGeneration, mount.id == self.activeStorageMountId else { return }
      guard !nextListing.entries.isEmpty else {
        self.fileListing.totalCount = self.fileListing.entries.count
        return
      }
      let existingIds = Set(self.fileListing.entries.map(\.id))
      let uniqueNew = nextListing.entries.filter { !existingIds.contains($0.id) }
      self.fileListing.entries.append(contentsOf: uniqueNew)
      self.fileListing.currentPage = nextPage
      self.fileListing.totalCount = max(nextListing.totalCount, self.fileListing.entries.count)
      self.recomputeDisplayedFileEntries()
      self.visibleFileLimit += 100
    } catch {
      showToast("⚠️ 加载下一页失败：\(error.localizedDescription)")
    }
  }

  /// Resolves a direct HTTP stream / download URL and headers for any file entry across all 5 storage sources
  func resolveFileStreamEndpoint(_ entry: TvFileEntry) async throws -> (url: String, headers: [String: String], subtitle: String) {
    let mount = storageMounts.first(where: { $0.id == entry.mountId }) ?? activeStorageMount
    switch entry.sourceKind {
    case .server:
      let url = api.buildFileStreamUrl(path: entry.path)
      return (url, api.authHeaders, "流光服务端 · \(entry.formattedSize)")

    case .alist:
      let info = try await TvRemoteStorageClient.shared.resolveAlistStreamInfo(
        mount: mount,
        path: entry.path,
        fallbackUrl: entry.rawDownloadUrl
      )
      return (info.url, info.headers, "\(mount.name) · \(entry.formattedSize)")

    case .webdav:
      let url = TvRemoteStorageClient.shared.buildWebdavUrl(mount: mount, path: entry.path)?.absoluteString ?? entry.rawDownloadUrl
      let headers = TvRemoteStorageClient.shared.webdavAuthHeaders(for: mount)
      return (url, headers, "\(mount.name) · \(entry.formattedSize)")

    case .smb:
      let url = await TvSmbClient.shared.buildLocalStreamUrl(
        mount: mount,
        virtualPath: entry.path,
        fileNameHint: entry.name
      )
      return (url, [:], "\(mount.name) (SMB) · \(entry.formattedSize)")

    case .cloud115:
      if !TvLocal115DirectClient.shared.hasLocalCookie {
        let srvSettings = await api.fetchServerSettings()
        let srvCookie = TvApiClient.stringValue(
          srvSettings["cookie_115"],
          fallback: TvApiClient.stringValue(
            srvSettings["115_cookie"],
            fallback: TvApiClient.stringValue(srvSettings["cookies"])
          )
        )
        let norm = TvLocal115DirectClient.normalizeCookieString(srvCookie)
        if norm.contains("UID=") && norm.contains("CID=") && norm.contains("SEID=") {
          TvLocal115DirectClient.shared.savedCookie = norm
          self.is115LoggedIn = true
        }
      }
      guard !entry.pickcode115.isEmpty else {
        throw NSError(domain: "Tv115", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法获取 115 文件直链，请确认登录状态"])
      }
      let directUrl: String?
      if entry.isImage {
        directUrl = await TvLocal115DirectClient.shared.resolvePickcodeImageUrl(pickcode: entry.pickcode115)
      } else {
        directUrl = await TvLocal115DirectClient.shared.resolvePickcodeStreamUrl(pickcode: entry.pickcode115)
      }
      guard let validUrl = directUrl, !validUrl.isEmpty else {
        throw NSError(domain: "Tv115", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法获取 115 文件直链，请确认登录状态"])
      }
      let hdrs = TvLocal115DirectClient.shared.streamHeaders(forUrl: validUrl)
      return (validUrl, hdrs, "115 网盘原画直连 · \(entry.formattedSize)")

    case .localCache:
      let localUrl = Self.resolveLocalOfflineUrl(relativePath: entry.path).absoluteString
      return (localUrl, [:], "Apple TV 本机离线缓存 · \(entry.formattedSize)")
    }
  }

  func playMediaFile(_ entry: TvFileEntry) {
    if entry.isStreamableMusicArchive {
      activeArchiveMusicBrowserEntry = entry
      return
    }
    if entry.isAudio {
      playCloudMusicFromDirectory(entry, openFullscreen: true)
      return
    }
    stopBackgroundAudioForVideoPlayback()
    if entry.sourceKind == .localCache {
      let fileUrl = Self.resolveLocalOfflineUrl(relativePath: entry.path)
      guard FileManager.default.fileExists(atPath: fileUrl.path) else {
        showToast("⚠️ 本地缓存文件不存在")
        return
      }
      playerControlsVisible = true
      playerShowEpisodeDrawer = false
      activePlayback = TvPlaybackRequest(
        title: entry.name,
        subtitle: "Apple TV 本机离线缓存 · \(entry.formattedSize)",
        streamUrl: fileUrl.absoluteString,
        backupProxyUrl: fileUrl.absoluteString,
        headers: [:],
        resumeSeconds: 0,
        isLive: false,
        vodSource: nil,
        vodDetail: nil,
        playGroupIndex: 0,
        episodeIndex: 0,
        liveChannel: nil,
        liveUrlIndex: 0
      )
      return
    }

    Task {
      self.isResolvingPlay = true
      defer { self.isResolvingPlay = false }

      // 1. Server Media Library files: open immediately with multi-block Range prefetch proxy acceleration (0ms wait, no blocking 115 search)
      if entry.sourceKind == .server {
        let rawServerUrl = self.api.buildFileStreamUrl(path: entry.path)
        guard !rawServerUrl.isEmpty else {
          self.showToast("⚠️ 无法生成服务端文件播放地址")
          return
        }
        let ext = entry.normalizedExt
        let isHls = ext == ".m3u8" || rawServerUrl.lowercased().contains(".m3u8")
        let primaryUrl = isHls
          ? rawServerUrl
          : TvLocalHlsProxyServer.shared.prepareTelegramVideoProxyUrl(
              remoteUrl: rawServerUrl,
              headers: self.api.authHeaders,
              extHint: ext.isEmpty ? ".mp4" : ext
            )
        self.playerControlsVisible = true
        self.playerShowEpisodeDrawer = false
        self.activePlayback = TvPlaybackRequest(
          title: entry.name,
          subtitle: "流光服务端高速直连 · \(entry.formattedSize)",
          streamUrl: primaryUrl,
          backupProxyUrl: rawServerUrl,
          headers: self.api.authHeaders,
          resumeSeconds: 0,
          isLive: false,
          vodSource: nil,
          vodDetail: nil,
          playGroupIndex: 0,
          episodeIndex: 0,
          liveChannel: nil,
          liveUrlIndex: 0
        )
        return
      }

      // 2. Direct 115 Cloud Drive playback:
      // - For .mp4 / .mov / .m4v / .mkv / .webm / .ts / .m2ts / .mts: stream original 4K raw file via VidHub-grade 2 MB Range block proxy + hardware VideoToolbox engine!
      // - For legacy containers (.avi / .rmvb / .wmv / .flv / .f4v / .iso): try 115 official cloud HLS transcode (`resolvePickcodeHlsM3u8Url`) first and fall back to direct stream
      if entry.sourceKind == .cloud115 {
        guard !entry.pickcode115.isEmpty else {
          self.showToast("⚠️ 该 115 文件缺少 pickcode，无法播放")
          return
        }
        let ext = entry.normalizedExt
        let preferCloudHlsTranscode = [".f4v", ".flv", ".avi", ".rmvb", ".wmv", ".iso"].contains(ext)

        var primaryStream = ""
        var backupStream = ""
        var hdrs: [String: String] = [:]

        if preferCloudHlsTranscode {
          if let hls = await TvLocal115DirectClient.shared.resolvePickcodeHlsM3u8Url(pickcode: entry.pickcode115),
             !hls.isEmpty {
            hdrs = TvLocal115DirectClient.shared.streamHeaders(forUrl: hls)
            let phls = await TvLocalHlsProxyServer.shared.prepareProxyPlaylistUrl(
              gatewayUrl: hls,
              resolvedUrl: hls,
              headers: hdrs
            ) ?? hls
            primaryStream = phls
            backupStream = hls
          } else if let dir = await TvLocal115DirectClient.shared.resolvePickcodeStreamUrl(pickcode: entry.pickcode115),
                    !dir.isEmpty {
            hdrs = TvLocal115DirectClient.shared.streamHeaders(forUrl: dir)
            primaryStream = TvLocalHlsProxyServer.shared.prepareTelegramVideoProxyUrl(
              remoteUrl: dir,
              headers: hdrs,
              extHint: ext,
              forceDirectConnection: true
            )
            backupStream = dir
          }
        } else {
          if let dir = await TvLocal115DirectClient.shared.resolvePickcodeStreamUrl(pickcode: entry.pickcode115),
             !dir.isEmpty {
            hdrs = TvLocal115DirectClient.shared.streamHeaders(forUrl: dir)
            if dir.lowercased().contains(".m3u8") {
              let phls = await TvLocalHlsProxyServer.shared.prepareProxyPlaylistUrl(
                gatewayUrl: dir,
                resolvedUrl: dir,
                headers: hdrs
              ) ?? dir
              primaryStream = phls
              backupStream = dir
            } else {
              primaryStream = TvLocalHlsProxyServer.shared.prepareTelegramVideoProxyUrl(
                remoteUrl: dir,
                headers: hdrs,
                extHint: ext.isEmpty ? ".mp4" : ext,
                forceDirectConnection: true
              )
              backupStream = dir
            }
          } else if let hls = await TvLocal115DirectClient.shared.resolvePickcodeHlsM3u8Url(pickcode: entry.pickcode115),
                    !hls.isEmpty {
            hdrs = TvLocal115DirectClient.shared.streamHeaders(forUrl: hls)
            let phls = await TvLocalHlsProxyServer.shared.prepareProxyPlaylistUrl(
              gatewayUrl: hls,
              resolvedUrl: hls,
              headers: hdrs
            ) ?? hls
            primaryStream = phls
            backupStream = hls
          }
        }

        guard !primaryStream.isEmpty else {
          self.showToast("⚠️ 无法获取 115 视频播放直链，请确认 115 登录状态")
          return
        }

        self.playerControlsVisible = true
        self.playerShowEpisodeDrawer = false
        self.activePlayback = TvPlaybackRequest(
          title: entry.name,
          subtitle: "115 网盘直连 · \(entry.formattedSize)",
          streamUrl: primaryStream,
          backupProxyUrl: backupStream.isEmpty ? primaryStream : backupStream,
          headers: hdrs,
          resumeSeconds: 0,
          isLive: false,
          vodSource: nil,
          vodDetail: nil,
          playGroupIndex: 0,
          episodeIndex: 0,
          liveChannel: nil,
          liveUrlIndex: 0
        )
        return
      }

      do {
        if entry.sourceKind == .alist {
          let mount = self.storageMounts.first(where: { $0.id == entry.mountId }) ?? self.activeStorageMount
          let ext = entry.normalizedExt
          let preferCloudHlsTranscode = [".avi", ".rmvb", ".wmv", ".flv", ".f4v", ".iso"].contains(ext)

          async let infoTask = TvRemoteStorageClient.shared.resolveAlistStreamInfo(
            mount: mount,
            path: entry.path,
            fallbackUrl: entry.rawDownloadUrl
          )
          var previewHls: (url: String, headers: [String: String])? = nil
          if preferCloudHlsTranscode {
            previewHls = await TvRemoteStorageClient.shared.resolveAlistVideoPreviewHlsUrl(
              mount: mount,
              path: entry.path
            )
          }
          let info = try await infoTask
          guard !info.url.isEmpty else { return }

          var primaryUrl = ""
          var backupUrl = ""
          var playHeaders = info.headers

          if let hlsPreview = previewHls, !hlsPreview.url.isEmpty {
            for (k, v) in hlsPreview.headers { playHeaders[k] = v }
            primaryUrl = await TvLocalHlsProxyServer.shared.prepareProxyPlaylistUrl(
              gatewayUrl: hlsPreview.url,
              resolvedUrl: hlsPreview.url,
              headers: playHeaders
            ) ?? hlsPreview.url
            backupUrl = primaryUrl
          } else if info.url.lowercased().contains(".m3u8") {
            primaryUrl = await TvLocalHlsProxyServer.shared.prepareProxyPlaylistUrl(
              gatewayUrl: info.url,
              resolvedUrl: info.url,
              headers: playHeaders
            ) ?? info.url
            backupUrl = primaryUrl
          } else {
            primaryUrl = TvLocalHlsProxyServer.shared.prepareTelegramVideoProxyUrl(
              remoteUrl: info.url,
              headers: playHeaders,
              extHint: ext.isEmpty ? ".mp4" : ext,
              forceDirectConnection: true,
              fallbackRemoteUrl: info.alistProxyUrl
            )
            // Never call `prepareTelegramVideoProxyUrl` a second time for `backupUrl` here!
            // A second call immediately overwrites `tgActiveBackgroundUrl` with `backupUrl`, killing `primaryUrl`'s
            // 16-worker 1 Gbps prefetcher and launching competing downloads for `backupUrl`.
            backupUrl = (!info.alistProxyUrl.isEmpty && info.alistProxyUrl != info.url)
              ? info.alistProxyUrl
              : primaryUrl
          }

          self.playerControlsVisible = true
          self.playerShowEpisodeDrawer = false
          self.activePlayback = TvPlaybackRequest(
            title: entry.name,
            subtitle: "\(mount.name) · \(entry.formattedSize)",
            streamUrl: primaryUrl,
            backupProxyUrl: backupUrl,
            headers: playHeaders,
            resumeSeconds: 0,
            isLive: false,
            vodSource: nil,
            vodDetail: nil,
            playGroupIndex: 0,
            episodeIndex: 0,
            liveChannel: nil,
            liveUrlIndex: 0
          )
          return
        }

        let resolved = try await self.resolveFileStreamEndpoint(entry)
        guard !resolved.url.isEmpty else { return }
        let ext = entry.normalizedExt
        let shouldProxyDirect = !resolved.url.contains("127.0.0.1:")
          && !resolved.url.hasPrefix("file://")
          && !resolved.url.lowercased().contains(".m3u8")
        let streamUrl = shouldProxyDirect
          ? TvLocalHlsProxyServer.shared.prepareTelegramVideoProxyUrl(
              remoteUrl: resolved.url,
              headers: resolved.headers,
              extHint: ext.isEmpty ? ".mp4" : ext,
              forceDirectConnection: true
            )
          : resolved.url
        let backupUrl = resolved.url
        self.playerControlsVisible = true
        self.playerShowEpisodeDrawer = false
        self.activePlayback = TvPlaybackRequest(
          title: entry.name,
          subtitle: resolved.subtitle,
          streamUrl: streamUrl,
          backupProxyUrl: backupUrl,
          headers: resolved.headers,
          resumeSeconds: 0,
          isLive: false,
          vodSource: nil,
          vodDetail: nil,
          playGroupIndex: 0,
          episodeIndex: 0,
          liveChannel: nil,
          liveUrlIndex: 0
        )
      } catch {
        self.showToast("播放失败：\(error.localizedDescription)")
      }
    }
  }

  // MARK: - Cloud Hi-Fi Music Player Engine (115 / AList / WebDAV / Server / Local Cache)

  var currentCloudMusicTrack: TvFileEntry? {
    guard cloudMusicCurrentIndex >= 0 && cloudMusicCurrentIndex < cloudMusicQueue.count else {
      return nil
    }
    return cloudMusicQueue[cloudMusicCurrentIndex]
  }

  var activeCloudLyricIndex: Int {
    guard !cloudMusicLyrics.isEmpty else { return -1 }
    let pos = cloudMusicPosition + 0.18
    var idx = -1
    for (i, line) in cloudMusicLyrics.enumerated() {
      if line.timeSeconds <= pos {
        idx = i
      } else {
        break
      }
    }
    return idx
  }

  var currentCloudLyricLineText: String {
    let idx = activeCloudLyricIndex
    guard idx >= 0 && idx < cloudMusicLyrics.count else { return "" }
    return cloudMusicLyrics[idx].text
  }

  private static let trackMetadataCacheLock = NSLock()
  private static var trackMetadataCache: [String: (title: String, artist: String, qualityTag: String)] = [:]
  private static let leadingTrackNumRegex = try? NSRegularExpression(
    pattern: #"^\s*(\[\d+\]|\(\d+\)|\d{1,4}[\.\-_、\s]+)\s*"#
  )
  private static let qualitySuffixRegex = try? NSRegularExpression(
    pattern: #"\s*(\[(?:FLAC|APE|WAV|MP3|AAC|ALAC|DSD|Hi-Res|24bit|16bit|320K|无损|母带)[^\]]*\]|\((?:FLAC|APE|WAV|MP3|AAC|ALAC|DSD|Hi-Res|24bit|16bit|320K|无损|母带)[^\)]*\))\s*$"#,
    options: [.caseInsensitive]
  )
  private static let separatorPatternStrings = [" - ", " – ", " — ", " _ "]

  /// Heuristic to determine if a segment looks more like a song title than an artist name
  /// (e.g., quoted with 《...》, contains feat/live/version/OST/主题曲/插曲/片尾曲/Remix/伴奏)
  private static func looksMoreLikeSongTitle(_ text: String) -> Int {
    var score = 0
    if text.contains("《") || text.contains("》") || text.contains("「") || text.contains("」") {
      score += 4
    }
    let lower = text.lowercased()
    let titleKeywords = [
      "live", "remix", "ver.", "version", "ost", "伴奏", "纯音乐", "主题曲", "片尾曲", "插曲",
      "推广曲", "概念曲", "合唱", "独唱", "钢琴版", "吉他版", "acoustic", "instrumental", "cover", "翻唱"
    ]
    for kw in titleKeywords where lower.contains(kw) {
      score += 2
    }
    if (text.contains("(") && text.contains(")")) || (text.contains("（") && text.contains("）")) {
      score += 1
    }
    return score
  }

  static func parseCloudTrackMetadata(_ entry: TvFileEntry, fallbackArtist: String = "") -> (title: String, artist: String, qualityTag: String) {
    let cacheKey = "\(entry.mountId)::\(entry.path)::\(entry.size)::\(fallbackArtist)"
    trackMetadataCacheLock.lock()
    if let hit = trackMetadataCache[cacheKey] {
      trackMetadataCacheLock.unlock()
      return hit
    }
    trackMetadataCacheLock.unlock()

    var base = (entry.name as NSString).deletingPathExtension
    if base.isEmpty { base = entry.name }
    if let regex = leadingTrackNumRegex {
      let ns = base as NSString
      base = regex.stringByReplacingMatches(in: base, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }
    if let qRegex = qualitySuffixRegex {
      let ns = base as NSString
      base = qRegex.stringByReplacingMatches(in: base, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }
    base = base.trimmingCharacters(in: .whitespacesAndNewlines)

    var artist = fallbackArtist
    var title = base

    // 1. Check explicit book-title quotes: e.g. `周杰伦《晴天》` or `《晴天》周杰伦`
    if let openIdx = base.firstIndex(of: "《"),
       let closeIdx = base.firstIndex(of: "》"),
       openIdx < closeIdx {
      let inside = String(base[base.index(after: openIdx)..<closeIdx]).trimmingCharacters(in: .whitespaces)
      let before = String(base[..<openIdx]).trimmingCharacters(in: CharacterSet(charactersIn: " -–—_·:"))
      let after = String(base[base.index(after: closeIdx)...]).trimmingCharacters(in: CharacterSet(charactersIn: " -–—_·:"))
      if !inside.isEmpty {
        title = inside
        if !before.isEmpty {
          artist = before
        } else if !after.isEmpty {
          artist = after
        }
      }
    } else {
      // 2. Split by ` - `, ` – `, ` — `, ` _ `, or `-`
      var leftPart = ""
      var rightPart = ""
      for sep in separatorPatternStrings {
        if let r = base.range(of: sep) {
          leftPart = String(base[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
          rightPart = String(base[r.upperBound...]).trimmingCharacters(in: .whitespaces)
          break
        }
      }
      if leftPart.isEmpty, let dashIdx = base.firstIndex(of: "-") {
        let l = String(base[..<dashIdx]).trimmingCharacters(in: .whitespaces)
        let r = String(base[base.index(after: dashIdx)...]).trimmingCharacters(in: .whitespaces)
        if !l.isEmpty && !r.isEmpty {
          leftPart = l
          rightPart = r
        }
      }

      if !leftPart.isEmpty && !rightPart.isEmpty {
        // Strip leading track numbers from rightPart too (e.g. `周杰伦 - 01. 晴天`)
        if let regex = leadingTrackNumRegex {
          let nsR = rightPart as NSString
          let cleanedR = regex.stringByReplacingMatches(in: rightPart, range: NSRange(location: 0, length: nsR.length), withTemplate: "").trimmingCharacters(in: .whitespaces)
          if !cleanedR.isEmpty { rightPart = cleanedR }
        }
        let leftTitleScore = looksMoreLikeSongTitle(leftPart)
        let rightTitleScore = looksMoreLikeSongTitle(rightPart)
        if leftTitleScore > rightTitleScore {
          title = leftPart
          artist = rightPart
        } else {
          // Standard `歌手 - 歌名`: Song title is the primary title, artist is the subtitle
          artist = leftPart
          title = rightPart
        }
      }
    }

    // Fallback: if artist is still empty or equals mount name, try parent folder name
    if artist.isEmpty || artist == fallbackArtist {
      let rawParent: String
      if entry.isInsideArchive {
        let innerDir = (entry.archiveInnerPath as NSString).deletingLastPathComponent
        rawParent = innerDir.isEmpty
          ? (entry.archiveContainerName as NSString).deletingPathExtension
          : (innerDir as NSString).lastPathComponent
      } else {
        let pDir = (entry.path as NSString).deletingLastPathComponent
        rawParent = (pDir as NSString).lastPathComponent
      }
      let cleanParent = rawParent.trimmingCharacters(in: .whitespacesAndNewlines)
      if !cleanParent.isEmpty && cleanParent != "/" && cleanParent != "0" && cleanParent != title {
        artist = cleanParent
      }
    }
    if title.isEmpty { title = base.isEmpty ? entry.name : base }
    if artist.isEmpty { artist = fallbackArtist }

    let ext = entry.normalizedExt.replacingOccurrences(of: ".", with: "").uppercased()
    let qualityTag: String
    switch ext {
    case "FLAC":
      qualityTag = entry.size > 35 * 1024 * 1024 ? "Hi-Res · FLAC 无损" : "FLAC 无损"
    case "WAV", "AIFF", "AIF":
      qualityTag = "\(ext) 母带无损"
    case "APE", "ALAC":
      qualityTag = "\(ext) 无损音频"
    case "DSF", "DFF":
      qualityTag = "DSD 母带"
    case "MP3":
      qualityTag = entry.size > 7 * 1024 * 1024 ? "MP3 320K" : "MP3"
    case "M4A", "AAC":
      qualityTag = "AAC 高清"
    case "OGG", "OPUS":
      qualityTag = "\(ext) 高清"
    default:
      qualityTag = ext.isEmpty ? "AUDIO" : ext
    }
    let result = (title: title, artist: artist, qualityTag: qualityTag)
    trackMetadataCacheLock.lock()
    if trackMetadataCache.count > 6000 {
      trackMetadataCache.removeAll(keepingCapacity: true)
    }
    trackMetadataCache[cacheKey] = result
    trackMetadataCacheLock.unlock()
    return result
  }

  func mountDisplayName(for entry: TvFileEntry) -> String {
    if let m = storageMounts.first(where: { $0.id == entry.mountId }) {
      return m.name
    }
    return entry.sourceKind.title
  }

  private func dirKeyForCloudMusicEntry(_ entry: TvFileEntry) -> String {
    if entry.isInsideArchive {
      return "\(entry.mountId)::archive::\(entry.archiveContainerPath)"
    }
    if entry.sourceKind == .cloud115 {
      return "\(entry.mountId)::\(entry.cid115)"
    }
    let parent = (entry.path as NSString).deletingLastPathComponent
    return "\(entry.mountId)::\(parent.isEmpty ? "/" : parent)"
  }

  private func cacheCurrentDirectorySiblings() {
    let all = fileListing.entries
    guard let first = all.first else { return }
    cloudMusicDirectorySiblingsByKey[dirKeyForCloudMusicEntry(first)] = all
  }

  func toggleSavedMusicFolder(_ item: TvSavedMusicFolderItem) {
    if let idx = savedMusicFolders.firstIndex(where: { $0.mountId == item.mountId && $0.path == item.path }) {
      savedMusicFolders.remove(at: idx)
      showToast("已移除常用音乐源：\(item.title)")
    } else {
      savedMusicFolders.append(item)
      showToast("⭐ 已加入常用音乐源：\(item.title)")
    }
    if let data = try? JSONEncoder().encode(savedMusicFolders) {
      defaults.set(data, forKey: "tv_saved_music_folders_v1")
    }
  }

  func isMusicFolderSaved(mountId: String, path: String) -> Bool {
    savedMusicFolders.contains { $0.mountId == mountId && $0.path == path }
  }

  var activeMusicPlaylist: TvSavedMusicPlaylist? {
    savedMusicPlaylists.first(where: { $0.id == activeMusicPlaylistId })
  }

  var activeMusicPlaylistName: String {
    activeMusicPlaylist?.name ?? "默认播放列表"
  }

  func syncDefaultCloudMusicPlaylist(persist: Bool = true) {
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    if !cloudMusicQueue.isEmpty {
      let safeIdx = min(max(0, cloudMusicCurrentIndex), cloudMusicQueue.count - 1)
      let defaultIdx = savedMusicPlaylists.firstIndex(where: { $0.id == "default_playlist" })
      let defaultName = defaultIdx != nil ? savedMusicPlaylists[defaultIdx!].name : "默认播放列表"
      let updatedDefault = TvSavedMusicPlaylist(
        id: "default_playlist",
        name: defaultName,
        tracks: cloudMusicQueue,
        sources: currentMusicQueueSources,
        currentIndex: safeIdx,
        updatedEpochMs: nowMs
      )
      if let dIdx = defaultIdx {
        savedMusicPlaylists[dIdx] = updatedDefault
      } else {
        savedMusicPlaylists.insert(updatedDefault, at: 0)
      }
      if activeMusicPlaylistId.isEmpty {
        activeMusicPlaylistId = "default_playlist"
      } else if activeMusicPlaylistId != "default_playlist",
                let aIdx = savedMusicPlaylists.firstIndex(where: { $0.id == activeMusicPlaylistId }) {
        savedMusicPlaylists[aIdx].tracks = cloudMusicQueue
        savedMusicPlaylists[aIdx].sources = currentMusicQueueSources
        savedMusicPlaylists[aIdx].currentIndex = safeIdx
        savedMusicPlaylists[aIdx].updatedEpochMs = nowMs
      }
    }
    if persist {
      persistDefaultMusicQueueAndPlaylists()
    }
  }

  private func persistDefaultMusicQueueAndPlaylists() {
    if !cloudMusicQueue.isEmpty {
      if let qData = try? JSONEncoder().encode(cloudMusicQueue) {
        defaults.set(qData, forKey: "tv_default_music_queue_v1")
      }
      let safeIdx = min(max(0, cloudMusicCurrentIndex), cloudMusicQueue.count - 1)
      defaults.set(safeIdx, forKey: "tv_default_music_index_v1")
      if let sData = try? JSONEncoder().encode(currentMusicQueueSources) {
        defaults.set(sData, forKey: "tv_default_music_sources_v1")
      }
    }
    if let plData = try? JSONEncoder().encode(savedMusicPlaylists) {
      defaults.set(plData, forKey: "tv_saved_music_playlists_v1")
    }
    defaults.set(activeMusicPlaylistId, forKey: "tv_active_music_playlist_id_v1")
  }

  @discardableResult
  func saveCurrentCloudMusicQueueAsPlaylist(name: String) -> TvSavedMusicPlaylist {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let finalName = clean.isEmpty ? "我的歌单 \(savedMusicPlaylists.count + 1)" : clean
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    let safeIdx = cloudMusicQueue.isEmpty ? 0 : min(max(0, cloudMusicCurrentIndex), cloudMusicQueue.count - 1)
    let pl = TvSavedMusicPlaylist(
      id: "pl_\(nowMs)",
      name: finalName,
      tracks: cloudMusicQueue,
      sources: currentMusicQueueSources,
      currentIndex: safeIdx,
      updatedEpochMs: nowMs
    )
    savedMusicPlaylists.append(pl)
    activeMusicPlaylistId = pl.id
    persistDefaultMusicQueueAndPlaylists()
    showToast("✓ 已保存播放列表「\(finalName)」（共 \(cloudMusicQueue.count) 首）")
    return pl
  }

  func deleteSavedMusicPlaylist(_ playlistId: String) {
    if playlistId == "default_playlist" && savedMusicPlaylists.count <= 1 {
      return
    }
    savedMusicPlaylists.removeAll { $0.id == playlistId }
    if activeMusicPlaylistId == playlistId {
      activeMusicPlaylistId = savedMusicPlaylists.first?.id ?? "default_playlist"
    }
    persistDefaultMusicQueueAndPlaylists()
    showToast("已删除播放列表")
  }

  func switchAndPlayMusicPlaylist(_ playlistId: String, shuffle: Bool = false) {
    guard let pl = savedMusicPlaylists.first(where: { $0.id == playlistId }) else { return }
    activeMusicPlaylistId = pl.id
    currentMusicQueueSources = pl.sources
    if pl.tracks.isEmpty && !pl.sources.isEmpty {
      Task {
        _ = await scanAndPlayMusicFoldersOrArchives(
          sources: pl.sources,
          shuffle: shuffle,
          openFullscreen: false
        )
      }
      return
    }
    guard !pl.tracks.isEmpty else { return }
    var tracks = pl.tracks
    if shuffle {
      cloudMusicPlayMode = "shuffle"
      tracks.shuffle()
      cloudMusicQueue = tracks
      cloudMusicCurrentIndex = 0
    } else {
      cloudMusicQueue = tracks
      cloudMusicCurrentIndex = min(max(0, pl.currentIndex), tracks.count - 1)
    }
    persistDefaultMusicQueueAndPlaylists()
    openCurrentCloudMusicTrack()
    showToast("🎵 已切换至列表「\(pl.name)」（共 \(tracks.count) 首）")
  }

  func shuffleCurrentCloudMusicQueue() {
    guard cloudMusicQueue.count > 1 else { return }
    cloudMusicPlayMode = "shuffle"
    var shuffled = cloudMusicQueue
    shuffled.shuffle()
    cloudMusicQueue = shuffled
    cloudMusicCurrentIndex = 0
    syncDefaultCloudMusicPlaylist()
    openCurrentCloudMusicTrack()
    showToast("🔀 已随机打乱播放队列（共 \(cloudMusicQueue.count) 首）")
  }

  func listDirectoryForMount(mount: TvStorageMount, path: String) async throws -> [TvFileEntry] {
    switch mount.kind {
    case .server:
      let res = try await api.fetchFiles(path: path)
      return res.entries
    case .alist:
      let targetPath = path.isEmpty ? mount.rootPath : path
      var allEntries: [TvFileEntry] = []
      var existingIds = Set<String>()
      let perPage = 500
      for page in 1...8 {
        let res = try await TvRemoteStorageClient.shared.listAlistDirectory(
          mount: mount,
          path: targetPath,
          page: page,
          perPage: perPage
        )
        let newItems = res.entries.filter { existingIds.insert($0.id).inserted }
        allEntries.append(contentsOf: newItems)
        if !res.hasMoreRemotePages || newItems.isEmpty || allEntries.count >= res.totalCount {
          break
        }
      }
      return allEntries
    case .webdav:
      let res = try await TvRemoteStorageClient.shared.listWebdavDirectory(
        mount: mount,
        path: path.isEmpty ? mount.rootPath : path
      )
      return res.entries
    case .smb:
      let res = try await TvSmbClient.shared.listSmbDirectory(
        mount: mount,
        path: path.isEmpty ? mount.rootPath : path
      )
      return res.entries
    case .cloud115:
      if !TvLocal115DirectClient.shared.hasLocalCookie {
        let srvSettings = await api.fetchServerSettings()
        let srvCookie = TvApiClient.stringValue(
          srvSettings["cookie_115"],
          fallback: TvApiClient.stringValue(
            srvSettings["115_cookie"],
            fallback: TvApiClient.stringValue(srvSettings["cookies"])
          )
        )
        let norm = TvLocal115DirectClient.normalizeCookieString(srvCookie)
        if norm.contains("UID=") && norm.contains("CID=") && norm.contains("SEID=") {
          TvLocal115DirectClient.shared.savedCookie = norm
          self.is115LoggedIn = true
        }
      }
      let cid = (path.isEmpty || path == "/") ? "0" : path
      var allEntries: [TvFileEntry] = []
      var existingIds = Set<String>()
      let perPage = 115
      for page in 1...15 {
        let res = try await TvLocal115DirectClient.shared.list115Directory(
          cid: cid,
          mountId: mount.id,
          page: page,
          perPage: perPage
        )
        let newItems = res.entries.filter { existingIds.insert($0.id).inserted }
        allEntries.append(contentsOf: newItems)
        if !res.hasMoreRemotePages || newItems.isEmpty || allEntries.count >= res.totalCount {
          break
        }
      }
      return allEntries
    case .localCache:
      return listLocalOfflineDirectory(path: path).entries
    }
  }

  // MARK: - HTTP Range Archive (.zip / .cbz / .tar) Music Inspector & Per-Track Extractor

  private func fetchArchiveByteRange(
    archiveEntry: TvFileEntry,
    start: Int64,
    endInclusive: Int64
  ) async throws -> Data {
    if archiveEntry.sourceKind == .localCache {
      let localUrl = Self.resolveLocalOfflineUrl(relativePath: archiveEntry.path)
      let handle = try FileHandle(forReadingFrom: localUrl)
      defer { try? handle.close() }
      try handle.seek(toOffset: UInt64(max(0, start)))
      let len = Int(max(0, endInclusive - start + 1))
      return try handle.read(upToCount: len) ?? Data()
    }
    let resolved = try await resolveFileStreamEndpoint(archiveEntry)
    guard let url = URL(string: resolved.url) else {
      throw NSError(domain: "TvArchive", code: -1, userInfo: [NSLocalizedDescriptionKey: "压缩包直链无效"])
    }
    var req = URLRequest(url: url)
    req.timeoutInterval = 25
    for (k, v) in resolved.headers {
      req.setValue(v, forHTTPHeaderField: k)
    }
    req.setValue("bytes=\(start)-\(endInclusive)", forHTTPHeaderField: "Range")
    let (data, resp) = try await URLSession.shared.data(for: req)
    if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
      throw NSError(domain: "TvArchive", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "压缩包 Range 读取失败 (HTTP \(http.statusCode))"])
    }
    let expectedLen = Int(max(0, endInclusive - start + 1))
    if data.count > expectedLen && Int(start) + expectedLen <= data.count {
      return data.subdata(in: Int(start)..<(Int(start) + expectedLen))
    }
    return data
  }

  private static func readUInt16LE(_ data: Data, _ offset: Int) -> UInt16 {
    guard offset + 2 <= data.count else { return 0 }
    return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
  }

  private static func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
    guard offset + 4 <= data.count else { return 0 }
    return UInt32(data[offset])
      | (UInt32(data[offset + 1]) << 8)
      | (UInt32(data[offset + 2]) << 16)
      | (UInt32(data[offset + 3]) << 24)
  }

  private static func readUInt64LE(_ data: Data, _ offset: Int) -> UInt64 {
    guard offset + 8 <= data.count else { return 0 }
    let lo = UInt64(readUInt32LE(data, offset))
    let hi = UInt64(readUInt32LE(data, offset + 4))
    return lo | (hi << 32)
  }

  func inspectArchiveEntries(_ archiveEntry: TvFileEntry) async throws -> [TvFileEntry] {
    let cacheKey = "\(archiveEntry.mountId)::\(archiveEntry.path)::\(archiveEntry.size)"
    if let cached = archiveInspectionCache[cacheKey], !cached.isEmpty {
      return cached
    }
    let ext = archiveEntry.normalizedExt
    let entries: [TvFileEntry]
    if ext == ".zip" || ext == ".cbz" {
      entries = try await inspectZipArchive(archiveEntry)
    } else if ext == ".tar" {
      entries = try await inspectTarArchive(archiveEntry)
    } else {
      return []
    }
    archiveInspectionCache[cacheKey] = entries
    cloudMusicDirectorySiblingsByKey["\(archiveEntry.mountId)::archive::\(archiveEntry.path)"] = entries
    return entries
  }

  private func inspectZipArchive(_ archiveEntry: TvFileEntry) async throws -> [TvFileEntry] {
    let totalSize = archiveEntry.size
    if totalSize <= 0 || totalSize <= 8 * 1024 * 1024 {
      let endIdx = totalSize > 0 ? totalSize - 1 : 8 * 1024 * 1024 - 1
      let fullBytes = try await fetchArchiveByteRange(archiveEntry: archiveEntry, start: 0, endInclusive: endIdx)
      return parseZipCentralDirectory(
        archiveEntry: archiveEntry,
        buffer: fullBytes,
        bufferStartOffsetInFile: 0,
        totalFileSize: Int64(fullBytes.count)
      )
    }
    let tailLen = min(Int64(65558), totalSize)
    let tailStart = totalSize - tailLen
    let tailBytes = try await fetchArchiveByteRange(
      archiveEntry: archiveEntry,
      start: tailStart,
      endInclusive: totalSize - 1
    )

    var eocdPos = -1
    if tailBytes.count >= 22 {
      for i in stride(from: tailBytes.count - 22, through: 0, by: -1) {
        if tailBytes[i] == 0x50 && tailBytes[i + 1] == 0x4B && tailBytes[i + 2] == 0x05 && tailBytes[i + 3] == 0x06 {
          eocdPos = i
          break
        }
      }
    }
    guard eocdPos >= 0 else {
      throw NSError(domain: "TvArchive", code: -2, userInfo: [NSLocalizedDescriptionKey: "未找到 ZIP 中央目录签名"])
    }

    var cdSize = Int64(Self.readUInt32LE(tailBytes, eocdPos + 12))
    var cdOffset = Int64(Self.readUInt32LE(tailBytes, eocdPos + 16))

    if (cdOffset == 0xFFFFFFFF || cdSize == 0xFFFFFFFF) && eocdPos >= 20 {
      let locPos = eocdPos - 20
      if tailBytes[locPos] == 0x50 && tailBytes[locPos + 1] == 0x4B && tailBytes[locPos + 2] == 0x06 && tailBytes[locPos + 3] == 0x07 {
        let zip64EocdOffset = Int64(Self.readUInt64LE(tailBytes, locPos + 8))
        let z64Bytes = try await fetchArchiveByteRange(
          archiveEntry: archiveEntry,
          start: zip64EocdOffset,
          endInclusive: min(totalSize - 1, zip64EocdOffset + 56)
        )
        if z64Bytes.count >= 56 && Self.readUInt32LE(z64Bytes, 0) == 0x06064B50 {
          cdSize = Int64(Self.readUInt64LE(z64Bytes, 40))
          cdOffset = Int64(Self.readUInt64LE(z64Bytes, 48))
        }
      }
    }

    if cdOffset >= tailStart && (cdOffset + cdSize) <= totalSize {
      return parseZipCentralDirectory(
        archiveEntry: archiveEntry,
        buffer: tailBytes,
        bufferStartOffsetInFile: tailStart,
        totalFileSize: totalSize,
        explicitCdOffset: cdOffset,
        explicitCdSize: cdSize
      )
    }

    let cdBytes = try await fetchArchiveByteRange(
      archiveEntry: archiveEntry,
      start: cdOffset,
      endInclusive: min(totalSize - 1, cdOffset + cdSize - 1)
    )
    return parseZipCentralDirectory(
      archiveEntry: archiveEntry,
      buffer: cdBytes,
      bufferStartOffsetInFile: cdOffset,
      totalFileSize: totalSize,
      explicitCdOffset: cdOffset,
      explicitCdSize: Int64(cdBytes.count)
    )
  }

  private func parseZipCentralDirectory(
    archiveEntry: TvFileEntry,
    buffer: Data,
    bufferStartOffsetInFile: Int64,
    totalFileSize: Int64,
    explicitCdOffset: Int64? = nil,
    explicitCdSize: Int64? = nil
  ) -> [TvFileEntry] {
    var cdOffsetInBuf = 0
    var cdEndInBuf = buffer.count
    if let expOff = explicitCdOffset, let expSize = explicitCdSize {
      cdOffsetInBuf = Int(expOff - bufferStartOffsetInFile)
      cdEndInBuf = min(buffer.count, cdOffsetInBuf + Int(expSize))
    } else if buffer.count >= 22 {
      for i in stride(from: buffer.count - 22, through: 0, by: -1) {
        if buffer[i] == 0x50 && buffer[i + 1] == 0x4B && buffer[i + 2] == 0x05 && buffer[i + 3] == 0x06 {
          let cSize = Int(Self.readUInt32LE(buffer, i + 12))
          let cOff = Int(Self.readUInt32LE(buffer, i + 16))
          cdOffsetInBuf = cOff - Int(bufferStartOffsetInFile)
          cdEndInBuf = min(buffer.count, cdOffsetInBuf + cSize)
          break
        }
      }
    }
    if cdOffsetInBuf < 0 || cdOffsetInBuf >= buffer.count {
      cdOffsetInBuf = 0
      cdEndInBuf = buffer.count
    }

    var results: [TvFileEntry] = []
    var ptr = cdOffsetInBuf
    while ptr + 46 <= cdEndInBuf {
      let sig = Self.readUInt32LE(buffer, ptr)
      if sig != 0x02014B50 { break }
      let flags = Int(Self.readUInt16LE(buffer, ptr + 8))
      let method = Int(Self.readUInt16LE(buffer, ptr + 10))
      var compSize = Int64(Self.readUInt32LE(buffer, ptr + 20))
      var uncompSize = Int64(Self.readUInt32LE(buffer, ptr + 24))
      let nameLen = Int(Self.readUInt16LE(buffer, ptr + 28))
      let extraLen = Int(Self.readUInt16LE(buffer, ptr + 30))
      let commentLen = Int(Self.readUInt16LE(buffer, ptr + 32))
      var localHeaderOffset = Int64(Self.readUInt32LE(buffer, ptr + 42))

      if ptr + 46 + nameLen > buffer.count { break }
      let nameData = buffer.subdata(in: (ptr + 46)..<(ptr + 46 + nameLen))
      let rawName = String(data: nameData, encoding: .utf8)
        ?? String(data: nameData, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))))
        ?? String(decoding: nameData, as: UTF8.self)

      if (uncompSize == 0xFFFFFFFF || compSize == 0xFFFFFFFF || localHeaderOffset == 0xFFFFFFFF) && extraLen >= 4 {
        let extraStart = ptr + 46 + nameLen
        let extraEnd = min(buffer.count, extraStart + extraLen)
        var ep = extraStart
        while ep + 4 <= extraEnd {
          let hId = Self.readUInt16LE(buffer, ep)
          let dSize = Int(Self.readUInt16LE(buffer, ep + 2))
          if hId == 0x0001 {
            var zp = ep + 4
            if uncompSize == 0xFFFFFFFF && zp + 8 <= ep + 4 + dSize {
              uncompSize = Int64(Self.readUInt64LE(buffer, zp))
              zp += 8
            }
            if compSize == 0xFFFFFFFF && zp + 8 <= ep + 4 + dSize {
              compSize = Int64(Self.readUInt64LE(buffer, zp))
              zp += 8
            }
            if localHeaderOffset == 0xFFFFFFFF && zp + 8 <= ep + 4 + dSize {
              localHeaderOffset = Int64(Self.readUInt64LE(buffer, zp))
            }
            break
          }
          ep += 4 + dSize
        }
      }

      ptr += 46 + nameLen + extraLen + commentLen
      let isEncrypted = (flags & 0x01) != 0
      if isEncrypted { continue }
      let cleanPath = rawName.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: .whitespacesAndNewlines)
      if cleanPath.isEmpty || cleanPath.hasSuffix("/") { continue }
      let baseName = (cleanPath as NSString).lastPathComponent
      if baseName.isEmpty || baseName.hasPrefix("._") || cleanPath.contains("__MACOSX/") { continue }
      let ext = (baseName as NSString).pathExtension.lowercased()
      let dotExt = ext.isEmpty ? "" : ".\(ext)"

      let virtualEntry = TvFileEntry(
        name: baseName,
        path: "\(archiveEntry.path)#/\(cleanPath)",
        size: uncompSize > 0 ? uncompSize : compSize,
        modTime: archiveEntry.modTime,
        isDir: false,
        isMp4: dotExt == ".mp4",
        ext: dotExt,
        mountId: archiveEntry.mountId,
        sourceKind: archiveEntry.sourceKind,
        rawDownloadUrl: archiveEntry.rawDownloadUrl,
        thumbUrl: archiveEntry.thumbUrl,
        pickcode115: archiveEntry.pickcode115,
        fid115: archiveEntry.fid115,
        cid115: archiveEntry.cid115,
        archiveContainerPath: archiveEntry.path,
        archiveContainerName: archiveEntry.name,
        archiveInnerPath: cleanPath,
        archiveOffset: localHeaderOffset,
        archiveCompressedSize: compSize,
        archiveCompressionMethod: method
      )
      if virtualEntry.isAudio || virtualEntry.isImage || dotExt == ".lrc" {
        results.append(virtualEntry)
      }
    }
    results.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    return results
  }

  private func inspectTarArchive(_ archiveEntry: TvFileEntry) async throws -> [TvFileEntry] {
    var results: [TvFileEntry] = []
    let totalSize = archiveEntry.size
    var offset: Int64 = 0
    var scannedEntries = 0
    while (totalSize <= 0 || offset + 512 <= totalSize) && scannedEntries < 400 {
      scannedEntries += 1
      let header = try await fetchArchiveByteRange(archiveEntry: archiveEntry, start: offset, endInclusive: offset + 511)
      if header.count < 512 { break }
      if header.allSatisfy({ $0 == 0 }) { break }

      func readNullTerminated(_ start: Int, _ maxLen: Int) -> String {
        let sub = header.subdata(in: start..<min(header.count, start + maxLen))
        let prefix = sub.prefix(while: { $0 != 0 })
        return (String(data: prefix, encoding: .utf8) ?? String(decoding: prefix, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
      }

      let name = readNullTerminated(0, 100)
      let sizeOctal = readNullTerminated(124, 12)
      let typeFlag = header[156]
      let prefix = readNullTerminated(345, 155)
      let fullName = prefix.isEmpty ? name : "\(prefix)/\(name)"
      let fileSize = Int64(sizeOctal, radix: 8) ?? 0
      let dataOffset = offset + 512

      if (typeFlag == 0 || typeFlag == 48) && fileSize > 0 && !fullName.isEmpty {
        let cleanPath = fullName.replacingOccurrences(of: "\\", with: "/")
        let baseName = (cleanPath as NSString).lastPathComponent
        if !baseName.hasPrefix("._") && !cleanPath.contains("__MACOSX/") {
          let ext = (baseName as NSString).pathExtension.lowercased()
          let dotExt = ext.isEmpty ? "" : ".\(ext)"
          let virtualEntry = TvFileEntry(
            name: baseName,
            path: "\(archiveEntry.path)#/\(cleanPath)",
            size: fileSize,
            modTime: archiveEntry.modTime,
            isDir: false,
            isMp4: dotExt == ".mp4",
            ext: dotExt,
            mountId: archiveEntry.mountId,
            sourceKind: archiveEntry.sourceKind,
            rawDownloadUrl: archiveEntry.rawDownloadUrl,
            thumbUrl: archiveEntry.thumbUrl,
            pickcode115: archiveEntry.pickcode115,
            fid115: archiveEntry.fid115,
            cid115: archiveEntry.cid115,
            archiveContainerPath: archiveEntry.path,
            archiveContainerName: archiveEntry.name,
            archiveInnerPath: cleanPath,
            archiveOffset: dataOffset,
            archiveCompressedSize: fileSize,
            archiveCompressionMethod: 0
          )
          if virtualEntry.isAudio || virtualEntry.isImage || dotExt == ".lrc" {
            results.append(virtualEntry)
          }
        }
      }
      let blocks = (fileSize + 511) / 512
      offset = dataOffset + blocks * 512
    }
    results.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    return results
  }

  private func extractArchiveEntryData(_ innerEntry: TvFileEntry) async throws -> Data {
    let containerExt = ((innerEntry.archiveContainerName as NSString).pathExtension).lowercased()
    let containerEntry = TvFileEntry(
      name: innerEntry.archiveContainerName,
      path: innerEntry.archiveContainerPath,
      size: 0,
      modTime: innerEntry.modTime,
      isDir: false,
      isMp4: false,
      ext: containerExt.isEmpty ? ".zip" : ".\(containerExt)",
      mountId: innerEntry.mountId,
      sourceKind: innerEntry.sourceKind,
      rawDownloadUrl: innerEntry.rawDownloadUrl,
      thumbUrl: innerEntry.thumbUrl,
      pickcode115: innerEntry.pickcode115,
      fid115: innerEntry.fid115,
      cid115: innerEntry.cid115
    )

    if containerExt == "tar" {
      let start = innerEntry.archiveOffset
      let end = start + innerEntry.archiveCompressedSize - 1
      return try await fetchArchiveByteRange(archiveEntry: containerEntry, start: start, endInclusive: end)
    }

    let localHeaderOffset = innerEntry.archiveOffset
    let compSize = innerEntry.archiveCompressedSize
    let fetchStart = localHeaderOffset
    let fetchEnd = localHeaderOffset + 30 + 512 + compSize - 1
    let chunk = try await fetchArchiveByteRange(archiveEntry: containerEntry, start: fetchStart, endInclusive: fetchEnd)
    guard chunk.count >= 30, Self.readUInt32LE(chunk, 0) == 0x04034B50 else {
      throw NSError(domain: "TvArchive", code: -3, userInfo: [NSLocalizedDescriptionKey: "ZIP Local File Header 校验失败"])
    }
    let method = Int(Self.readUInt16LE(chunk, 8))
    let nameLen = Int(Self.readUInt16LE(chunk, 26))
    let extraLen = Int(Self.readUInt16LE(chunk, 28))
    let dataStartInChunk = 30 + nameLen + extraLen

    let payload: Data
    if dataStartInChunk + Int(compSize) <= chunk.count {
      payload = chunk.subdata(in: dataStartInChunk..<(dataStartInChunk + Int(compSize)))
    } else {
      let exactDataStart = localHeaderOffset + Int64(dataStartInChunk)
      payload = try await fetchArchiveByteRange(
        archiveEntry: containerEntry,
        start: exactDataStart,
        endInclusive: exactDataStart + compSize - 1
      )
    }

    if method == 0 {
      return payload
    } else if method == 8 {
      let expectedOutSize = max(Int(innerEntry.size), payload.count * 3) + 65536
      var dstBuffer = Data(count: expectedOutSize)
      let decodedSize = payload.withUnsafeBytes { srcPtr -> Int in
        guard let srcBase = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        return dstBuffer.withUnsafeMutableBytes { dstPtr -> Int in
          guard let dstBase = dstPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
          return compression_decode_buffer(
            dstBase,
            expectedOutSize,
            srcBase,
            payload.count,
            nil,
            COMPRESSION_ZLIB
          )
        }
      }
      guard decodedSize > 0 else {
        throw NSError(domain: "TvArchive", code: -4, userInfo: [NSLocalizedDescriptionKey: "ZIP Deflate 解压失败"])
      }
      dstBuffer.count = decodedSize
      return dstBuffer
    } else {
      throw NSError(domain: "TvArchive", code: -5, userInfo: [NSLocalizedDescriptionKey: "暂不支持的 ZIP 压缩算法 (Method \(method))"])
    }
  }

  private func extractArchiveAudioToTempUrl(_ innerEntry: TvFileEntry) async throws -> URL {
    let cacheKey = "\(innerEntry.mountId)::\(innerEntry.path)::\(innerEntry.archiveOffset)"
    if let existingUrl = extractedArchiveTempFileCache[cacheKey],
       FileManager.default.fileExists(atPath: existingUrl.path) {
      return existingUrl
    }
    let bytes = try await extractArchiveEntryData(innerEntry)
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("liuguang_archive_music", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let ext = innerEntry.normalizedExt.isEmpty ? ".mp3" : innerEntry.normalizedExt
    let fileUrl = tmpDir.appendingPathComponent("track_\(abs(cacheKey.hashValue))\(ext)")
    try bytes.write(to: fileUrl, options: .atomic)
    extractedArchiveTempFileCache[cacheKey] = fileUrl
    return fileUrl
  }

  /// Plays all audio files inside a `.zip` / `.cbz` / `.tar` archive directly via HTTP Range!
  func playArchiveMusic(
    archiveEntry: TvFileEntry,
    shuffle: Bool = false,
    startWithInnerTrack: TvFileEntry? = nil,
    openFullscreen: Bool = true
  ) async -> Int {
    isScanningMusicFolders = true
    scanningMusicStatusText = "正在读取压缩包「\(archiveEntry.name)」内的音乐列表..."
    cloudMusicErrorText = ""
    do {
      let allInner = try await inspectArchiveEntries(archiveEntry)
      isScanningMusicFolders = false
      scanningMusicStatusText = ""
      var audioTracks = allInner.filter { $0.isAudio }
      guard !audioTracks.isEmpty else {
        showToast("⚠️ 压缩包「\(archiveEntry.name)」内未找到音频文件")
        return 0
      }
      if shuffle {
        cloudMusicPlayMode = "shuffle"
        audioTracks.shuffle()
        cloudMusicQueue = audioTracks
        cloudMusicCurrentIndex = 0
      } else {
        cloudMusicQueue = audioTracks
        if let start = startWithInnerTrack,
           let idx = cloudMusicQueue.firstIndex(where: { $0.path == start.path }) {
          cloudMusicCurrentIndex = idx
        } else {
          cloudMusicCurrentIndex = 0
        }
      }
      if openFullscreen {
        showCloudMusicFullscreen = true
      }
      currentMusicQueueSources = [
        TvSavedMusicFolderItem(
          mountId: archiveEntry.mountId,
          mountName: mountDisplayName(for: archiveEntry),
          sourceKind: archiveEntry.sourceKind,
          path: archiveEntry.path,
          title: archiveEntry.name,
          isArchive: true,
          size: archiveEntry.size,
          pickcode115: archiveEntry.pickcode115
        )
      ]
      syncDefaultCloudMusicPlaylist()
      openCurrentCloudMusicTrack()
      return audioTracks.count
    } catch {
      isScanningMusicFolders = false
      scanningMusicStatusText = ""
      showToast("⚠️ 解析压缩包音乐失败：\(error.localizedDescription)")
      return 0
    }
  }

  /// Recursively scans selected folders and/or archives across 115 / AList / WebDAV / Server / Local Cache and shuffle-plays them!
  func scanAndPlayMusicFoldersOrArchives(
    sources: [TvSavedMusicFolderItem],
    shuffle: Bool = true,
    includeSubfolders: Bool = true,
    includeArchives: Bool = true,
    openFullscreen: Bool = true
  ) async -> Int {
    guard !sources.isEmpty else { return 0 }
    isScanningMusicFolders = true
    scanningMusicStatusText = "正在扫描所选目录与压缩包中的音乐..."
    cloudMusicErrorText = ""

    var collectedTracks: [TvFileEntry] = []
    var visitedKeys: Set<String> = []

    func scanFolderRecursive(mount: TvStorageMount, folderPath: String, folderTitle: String, depth: Int) async {
      let key = "\(mount.id)::\(folderPath)"
      guard !visitedKeys.contains(key) else { return }
      visitedKeys.insert(key)
      scanningMusicStatusText = "正在扫描「\(mount.name) / \(folderTitle)」... (已发现 \(collectedTracks.count) 首)"
      guard let entries = try? await listDirectoryForMount(mount: mount, path: folderPath) else { return }
      if let first = entries.first {
        cloudMusicDirectorySiblingsByKey[dirKeyForCloudMusicEntry(first)] = entries
      }
      for e in entries where !e.isDir && e.isAudio {
        collectedTracks.append(e)
      }
      if includeArchives {
        for e in entries where !e.isDir && e.isStreamableMusicArchive {
          scanningMusicStatusText = "正在解析压缩包「\(e.name)」... (已发现 \(collectedTracks.count) 首)"
          if let innerList = try? await inspectArchiveEntries(e) {
            for inner in innerList where inner.isAudio {
              collectedTracks.append(inner)
            }
          }
        }
      }
      if includeSubfolders && depth < 5 && collectedTracks.count < 3000 {
        for sub in entries where sub.isDir {
          if collectedTracks.count >= 3000 { break }
          await scanFolderRecursive(mount: mount, folderPath: sub.path, folderTitle: sub.name, depth: depth + 1)
        }
      }
    }

    for src in sources {
      let mount = storageMounts.first(where: { $0.id == src.mountId })
        ?? TvStorageMount(id: src.mountId, name: src.mountName, kind: src.sourceKind, rootPath: src.path, enabled: true)
      if src.isArchive {
        let dot = (src.title as NSString).pathExtension.lowercased()
        let archEntry = TvFileEntry(
          name: src.title,
          path: src.path,
          size: src.size,
          modTime: "",
          isDir: false,
          isMp4: false,
          ext: dot.isEmpty ? ".zip" : ".\(dot)",
          mountId: src.mountId,
          sourceKind: src.sourceKind,
          pickcode115: src.pickcode115
        )
        if let innerList = try? await inspectArchiveEntries(archEntry) {
          for inner in innerList where inner.isAudio {
            collectedTracks.append(inner)
          }
        }
      } else {
        let dotExt = ".\((src.title as NSString).pathExtension.lowercased())"
        let potentialAudio = TvFileEntry(
          name: src.title,
          path: src.path,
          size: src.size,
          modTime: "",
          isDir: false,
          isMp4: dotExt == ".mp4",
          ext: dotExt == "." ? "" : dotExt,
          mountId: src.mountId,
          sourceKind: src.sourceKind,
          pickcode115: src.pickcode115
        )
        if potentialAudio.isAudio {
          collectedTracks.append(potentialAudio)
        } else {
          await scanFolderRecursive(mount: mount, folderPath: src.path, folderTitle: src.title, depth: 0)
        }
      }
    }

    isScanningMusicFolders = false
    scanningMusicStatusText = ""

    guard !collectedTracks.isEmpty else {
      cloudMusicErrorText = "所选目录或压缩包内未发现可播放的音频文件"
      showToast("⚠️ 所选目录或压缩包内未发现音乐文件")
      return 0
    }

    if shuffle {
      cloudMusicPlayMode = "shuffle"
      collectedTracks.shuffle()
    }
    cloudMusicQueue = collectedTracks
    cloudMusicCurrentIndex = 0
    currentMusicQueueSources = sources
    syncDefaultCloudMusicPlaylist()
    if openFullscreen && selectedSection != .music {
      showCloudMusicFullscreen = true
    }
    openCurrentCloudMusicTrack()
    showToast("🎵 已为您\(shuffle ? "随机" : "顺序")播放 \(collectedTracks.count) 首音乐")
    return collectedTracks.count
  }

  /// Collects all audio tracks from selected directories / archives without modifying active playback.
  func collectMusicTracksFromSources(
    sources: [TvSavedMusicFolderItem],
    includeSubfolders: Bool = true,
    includeArchives: Bool = true
  ) async -> [TvFileEntry] {
    guard !sources.isEmpty else { return [] }
    isScanningMusicFolders = true
    scanningMusicStatusText = "正在扫描所选目录与压缩包中的音乐..."

    var collectedTracks: [TvFileEntry] = []
    var visitedKeys: Set<String> = []

    func scanFolderRecursive(mount: TvStorageMount, folderPath: String, folderTitle: String, depth: Int) async {
      let key = "\(mount.id)::\(folderPath)"
      guard !visitedKeys.contains(key) else { return }
      visitedKeys.insert(key)
      scanningMusicStatusText = "正在扫描「\(mount.name) / \(folderTitle)」... (已发现 \(collectedTracks.count) 首)"
      guard let entries = try? await listDirectoryForMount(mount: mount, path: folderPath) else { return }
      if let first = entries.first {
        cloudMusicDirectorySiblingsByKey[dirKeyForCloudMusicEntry(first)] = entries
      }
      for e in entries where !e.isDir && e.isAudio {
        collectedTracks.append(e)
      }
      if includeArchives {
        for e in entries where !e.isDir && e.isStreamableMusicArchive {
          scanningMusicStatusText = "正在解析压缩包「\(e.name)」... (已发现 \(collectedTracks.count) 首)"
          if let innerList = try? await inspectArchiveEntries(e) {
            for inner in innerList where inner.isAudio {
              collectedTracks.append(inner)
            }
          }
        }
      }
      if includeSubfolders && depth < 5 && collectedTracks.count < 3000 {
        for sub in entries where sub.isDir {
          if collectedTracks.count >= 3000 { break }
          await scanFolderRecursive(mount: mount, folderPath: sub.path, folderTitle: sub.name, depth: depth + 1)
        }
      }
    }

    for src in sources {
      let mount = storageMounts.first(where: { $0.id == src.mountId })
        ?? TvStorageMount(id: src.mountId, name: src.mountName, kind: src.sourceKind, rootPath: src.path, enabled: true)
      if src.isArchive {
        let dot = (src.title as NSString).pathExtension.lowercased()
        let archEntry = TvFileEntry(
          name: src.title,
          path: src.path,
          size: src.size,
          modTime: "",
          isDir: false,
          isMp4: false,
          ext: dot.isEmpty ? ".zip" : ".\(dot)",
          mountId: src.mountId,
          sourceKind: src.sourceKind,
          pickcode115: src.pickcode115
        )
        if let innerList = try? await inspectArchiveEntries(archEntry) {
          for inner in innerList where inner.isAudio {
            collectedTracks.append(inner)
          }
        }
      } else {
        let dotExt = ".\((src.title as NSString).pathExtension.lowercased())"
        let potentialAudio = TvFileEntry(
          name: src.title,
          path: src.path,
          size: src.size,
          modTime: "",
          isDir: false,
          isMp4: dotExt == ".mp4",
          ext: dotExt == "." ? "" : dotExt,
          mountId: src.mountId,
          sourceKind: src.sourceKind,
          pickcode115: src.pickcode115
        )
        if potentialAudio.isAudio {
          collectedTracks.append(potentialAudio)
        } else {
          await scanFolderRecursive(mount: mount, folderPath: src.path, folderTitle: src.title, depth: 0)
        }
      }
    }

    isScanningMusicFolders = false
    scanningMusicStatusText = ""
    return collectedTracks
  }

  /// Searches directory tracks by artist / keywords (supporting multiple comma/space keywords) and creates a new playlist.
  @discardableResult
  func searchMusicDirectoryAndCreatePlaylist(
    sources: [TvSavedMusicFolderItem],
    keyword: String,
    playlistName: String = "",
    includeSubfolders: Bool = true,
    playImmediately: Bool = true
  ) async -> TvSavedMusicPlaylist? {
    let rawKw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawKw.isEmpty else {
      showToast("⚠️ 请输入要查找的歌手人名或歌曲关键词")
      return nil
    }
    let allTracks = await collectMusicTracksFromSources(
      sources: sources,
      includeSubfolders: includeSubfolders,
      includeArchives: true
    )
    guard !allTracks.isEmpty else {
      showToast("⚠️ 所选目录中未找到音频文件")
      return nil
    }
    let tokens = rawKw
      .components(separatedBy: CharacterSet(charactersIn: ",，、;；/ "))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }
    let matched = allTracks.filter { track in
      let meta = Self.parseCloudTrackMetadata(track)
      let haystack = "\(track.name) \(track.path) \(track.archiveInnerPath) \(meta.title) \(meta.artist)".lowercased()
      return tokens.contains { haystack.contains($0) }
    }
    guard !matched.isEmpty else {
      showToast("⚠️ 未在目录中找到包含「\(rawKw)」的歌曲（共扫描 \(allTracks.count) 首）")
      return nil
    }
    let cleanTitle = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
    let finalTitle = cleanTitle.isEmpty ? "精选 · \(rawKw)" : cleanTitle
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    let pl = TvSavedMusicPlaylist(
      id: "pl_kw_\(nowMs)",
      name: finalTitle,
      tracks: matched,
      sources: sources,
      currentIndex: 0,
      updatedEpochMs: nowMs
    )
    savedMusicPlaylists.append(pl)
    activeMusicPlaylistId = pl.id
    if playImmediately {
      cloudMusicQueue = matched
      cloudMusicCurrentIndex = 0
      currentMusicQueueSources = sources
      persistDefaultMusicQueueAndPlaylists()
      openCurrentCloudMusicTrack()
    } else {
      persistDefaultMusicQueueAndPlaylists()
    }
    showToast("🎵 已为您创建歌单「\(finalTitle)」（匹配 \(matched.count) 首歌曲）")
    return pl
  }

  func openMusicSmartAiSheet(tab: Int = 1, sources: [TvSavedMusicFolderItem] = []) {
    musicSmartAiInitialTab = tab
    if !sources.isEmpty {
      musicSmartAiInitialSources = sources
    } else if !currentMusicQueueSources.isEmpty {
      musicSmartAiInitialSources = currentMusicQueueSources
    } else if !savedMusicFolders.isEmpty {
      musicSmartAiInitialSources = savedMusicFolders
    } else if let m = storageMounts.first {
      musicSmartAiInitialSources = [
        TvSavedMusicFolderItem(
          mountId: m.id,
          mountName: m.name,
          sourceKind: m.kind,
          path: m.rootPath,
          title: m.name,
          isArchive: false,
          size: 0,
          pickcode115: ""
        )
      ]
    }
    if showMusicFolderPickerSheet {
      showMusicFolderPickerSheet = false
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        self.showMusicSmartAiSheet = true
      }
    } else if showMusicPlaylistManagerSheet {
      showMusicPlaylistManagerSheet = false
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        self.showMusicSmartAiSheet = true
      }
    } else {
      showMusicSmartAiSheet = true
    }
  }

  func analyzeTracksWithAiOrHeuristic(
    tracks: [TvFileEntry],
    dimension: String = "auto",
    customInstruction: String = ""
  ) async -> [(name: String, description: String, tracks: [TvFileEntry])] {
    guard !tracks.isEmpty else { return [] }
    var groupedIndices: [String: [Int]] = [:]

    let apiKey = aiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if !apiKey.isEmpty {
      let dimInstruction: String = {
        switch dimension {
        case "artist": return "按歌手 / 艺术家归类，将同一歌手或相关乐队的歌曲归入同一播放列表"
        case "genre": return "按音乐曲风 / 流派（如流行、摇滚、电子、民谣、古典、R&B、说唱等）归类"
        case "mood": return "按心情 / 聆听场景（如开车兜风、深夜放松、运动燃曲、工作专注、怀旧伤感等）归类"
        case "language": return "按语种 / 地区（如国语流行、粤语经典、欧美金曲、日韩音乐、纯音乐等）归类"
        case "era": return "按年代 / 时期（如80/90怀旧金曲、00年代华语巅峰、近年热歌等）归类"
        default: return "综合分析歌手、曲风、语种、心情与目录特征，自动划分为 2 到 8 个主题鲜明的精品播放列表"
        }
      }()
      let extraRule = customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
      let sampleTracks = Array(tracks.prefix(160))
      var lines: [String] = []
      for (i, t) in sampleTracks.enumerated() {
        let meta = Self.parseCloudTrackMetadata(t)
        let label = meta.artist.isEmpty ? meta.title : "\(meta.artist) - \(meta.title)"
        lines.append("\(i): \(label)")
      }
      let prompt = """
      请将以下音乐曲目按【\(dimInstruction)】智能归类为 2 到 8 个精选播放列表。
      \(extraRule.isEmpty ? "" : "用户附加要求：\(extraRule)")
      只返回严格合法的 JSON 对象，格式如下：
      {"playlists":[{"name":"列表名称","indices":[0,1,2]}]}
      曲目清单：
      \(lines.joined(separator: "\n"))
      """

      if let llmGroups = await requestAiPlaylistGrouping(prompt: prompt, maxIndex: sampleTracks.count - 1) {
        groupedIndices = llmGroups
      }
    }

    if groupedIndices.isEmpty {
      var byArtist: [String: [Int]] = [:]
      var losslessIndices: [Int] = []
      var folderGroups: [String: [Int]] = [:]
      for (i, t) in tracks.enumerated() {
        let meta = Self.parseCloudTrackMetadata(t)
        let ext = t.normalizedExt
        if [".flac", ".ape", ".wav", ".alac", ".dsf", ".dff"].contains(ext) {
          losslessIndices.append(i)
        }
        let artist = meta.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !artist.isEmpty && artist != "未知歌手" && !artist.contains("115") && !artist.contains("AList") {
          byArtist[artist, default: []].append(i)
        }
        let parentDir = ((t.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        if !parentDir.isEmpty && parentDir != "/" && parentDir != "0" {
          folderGroups[parentDir, default: []].append(i)
        }
      }
      let topArtists = byArtist.sorted { $0.value.count > $1.value.count }.prefix(6)
      for (artist, idxs) in topArtists where idxs.count >= 2 {
        groupedIndices["🎤 \(artist) 精选"] = idxs
      }
      if groupedIndices.isEmpty {
        for (folder, idxs) in folderGroups.sorted(by: { $0.value.count > $1.value.count }).prefix(6) where idxs.count >= 2 {
          groupedIndices["📂 \(folder) 精选"] = idxs
        }
      }
      if !losslessIndices.isEmpty && losslessIndices.count < tracks.count {
        groupedIndices["💎 Hi-Res 无损臻选"] = losslessIndices
      }
      if groupedIndices.isEmpty {
        groupedIndices["🎵 智能精选合集"] = Array(tracks.indices)
      }
    }

    var drafts: [(name: String, description: String, tracks: [TvFileEntry])] = []
    for entry in groupedIndices.sorted(by: { $0.value.count > $1.value.count }) {
      let validTracks = entry.value.compactMap { idx -> TvFileEntry? in
        (idx >= 0 && idx < tracks.count) ? tracks[idx] : nil
      }
      guard !validTracks.isEmpty else { continue }
      let previewNames = validTracks.prefix(5).map { Self.parseCloudTrackMetadata($0).title }.joined(separator: "、")
      let desc = "包含：\(previewNames)\(validTracks.count > 5 ? " 等共 \(validTracks.count) 首" : "")"
      drafts.append((name: entry.key, description: desc, tracks: validTracks))
    }
    return drafts
  }

  @discardableResult
  func createPlaylistsFromAiDrafts(
    _ drafts: [(name: String, description: String, tracks: [TvFileEntry])],
    sources: [TvSavedMusicFolderItem],
    playFirst: Bool = true
  ) -> [TvSavedMusicPlaylist] {
    var created: [TvSavedMusicPlaylist] = []
    let baseMs = Int64(Date().timeIntervalSince1970 * 1000)
    for (offset, draft) in drafts.enumerated() where !draft.tracks.isEmpty {
      let pl = TvSavedMusicPlaylist(
        id: "pl_ai_\(baseMs + Int64(offset))",
        name: draft.name,
        tracks: draft.tracks,
        sources: sources,
        currentIndex: 0,
        updatedEpochMs: baseMs + Int64(offset)
      )
      savedMusicPlaylists.append(pl)
      created.append(pl)
    }
    if let first = created.first {
      activeMusicPlaylistId = first.id
      if playFirst {
        cloudMusicQueue = first.tracks
        cloudMusicCurrentIndex = 0
        currentMusicQueueSources = sources
        persistDefaultMusicQueueAndPlaylists()
        openCurrentCloudMusicTrack()
        showToast("✨ 已创建 \(created.count) 个 AI 分类歌单并开始播放「\(first.name)」")
      } else {
        persistDefaultMusicQueueAndPlaylists()
        showToast("✨ 已成功创建 \(created.count) 个 AI 分类歌单")
      }
    }
    return created
  }

  /// Uses AI (or smart local artist/style heuristic fallback) to categorize tracks in the selected directory and batch-create playlists.
  func aiCategorizeMusicDirectoryAndCreatePlaylists(
    sources: [TvSavedMusicFolderItem],
    includeSubfolders: Bool = true
  ) async -> [TvSavedMusicPlaylist] {
    let allTracks = await collectMusicTracksFromSources(
      sources: sources,
      includeSubfolders: includeSubfolders,
      includeArchives: true
    )
    guard !allTracks.isEmpty else {
      showToast("⚠️ 所选目录中未找到音频文件")
      return []
    }

    isScanningMusicFolders = true
    scanningMusicStatusText = "正在通过 AI 智能分析 \(allTracks.count) 首歌曲风格与歌手分类..."

    var groupedIndices: [String: [Int]] = [:]

    // 1. Try LLM API if aiApiKey is configured
    let apiKey = aiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if !apiKey.isEmpty {
      let sampleTracks = Array(allTracks.prefix(160))
      var lines: [String] = []
      for (i, t) in sampleTracks.enumerated() {
        let meta = Self.parseCloudTrackMetadata(t)
        let label = meta.artist.isEmpty ? meta.title : "\(meta.artist) - \(meta.title)"
        lines.append("\(i): \(label)")
      }
      let prompt = """
      请将以下音乐曲目按歌手、曲风或年代智能归类为 2 到 8 个精选播放列表。
      只返回严格合法的 JSON 对象，格式如下：
      {"playlists":[{"name":"列表名称","indices":[0,1,2]}]}
      曲目清单：
      \(lines.joined(separator: "\n"))
      """

      if let llmGroups = await requestAiPlaylistGrouping(prompt: prompt, maxIndex: sampleTracks.count - 1) {
        groupedIndices = llmGroups
      }
    }

    // 2. Smart Local Artist / Style Heuristic Categorization Fallback (or supplement)
    if groupedIndices.isEmpty {
      var byArtist: [String: [Int]] = [:]
      var losslessIndices: [Int] = []
      for (i, t) in allTracks.enumerated() {
        let meta = Self.parseCloudTrackMetadata(t)
        let ext = t.normalizedExt
        if [".flac", ".ape", ".wav", ".alac", ".dsf", ".dff"].contains(ext) {
          losslessIndices.append(i)
        }
        let artist = meta.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !artist.isEmpty && artist != "未知歌手" && !artist.contains("115") && !artist.contains("AList") {
          byArtist[artist, default: []].append(i)
        }
      }
      let topArtists = byArtist.sorted { $0.value.count > $1.value.count }.prefix(6)
      for (artist, idxs) in topArtists where idxs.count >= 2 {
        groupedIndices["🎤 \(artist) 精选"] = idxs
      }
      if !losslessIndices.isEmpty && losslessIndices.count < allTracks.count {
        groupedIndices["💎 Hi-Res 无损臻选"] = losslessIndices
      }
      if groupedIndices.isEmpty {
        groupedIndices["🎵 智能精选合集"] = Array(allTracks.indices)
      }
    }

    isScanningMusicFolders = false
    scanningMusicStatusText = ""

    var created: [TvSavedMusicPlaylist] = []
    let baseMs = Int64(Date().timeIntervalSince1970 * 1000)
    for (offset, entry) in groupedIndices.sorted(by: { $0.value.count > $1.value.count }).enumerated() {
      let validTracks = entry.value.compactMap { idx -> TvFileEntry? in
        (idx >= 0 && idx < allTracks.count) ? allTracks[idx] : nil
      }
      guard !validTracks.isEmpty else { continue }
      let pl = TvSavedMusicPlaylist(
        id: "pl_ai_\(baseMs + Int64(offset))",
        name: entry.key,
        tracks: validTracks,
        sources: sources,
        currentIndex: 0,
        updatedEpochMs: baseMs + Int64(offset)
      )
      savedMusicPlaylists.append(pl)
      created.append(pl)
    }

    if let first = created.first {
      activeMusicPlaylistId = first.id
      cloudMusicQueue = first.tracks
      cloudMusicCurrentIndex = 0
      currentMusicQueueSources = sources
      persistDefaultMusicQueueAndPlaylists()
      openCurrentCloudMusicTrack()
      showToast("✨ AI 智能分类完成：已自动生成 \(created.count) 个精选歌单并开始播放「\(first.name)」")
    }
    return created
  }

  private func requestAiPlaylistGrouping(prompt: String, maxIndex: Int) async -> [String: [Int]]? {
    let key = aiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return nil }
    let provider = effectiveAiProvider
    let base = effectiveAiBaseUrl
    let modelName = effectiveAiModel
    let systemPrompt = "You are a music librarian that returns only JSON."

    let endpoint: String
    if provider == "gemini" {
      let cleanBase = base.contains("generativelanguage.googleapis.com")
        ? base
        : "https://generativelanguage.googleapis.com/v1beta"
      let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
      endpoint = "\(cleanBase)/models/\(modelName):generateContent?key=\(encodedKey)"
    } else if provider == "claude" {
      endpoint = base.hasSuffix("/messages") ? base : "\(base)/messages"
    } else {
      endpoint = base.hasSuffix("/chat/completions") ? base : "\(base)/chat/completions"
    }

    guard let url = URL(string: endpoint) else { return nil }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = 30
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let bodyObj: [String: Any]
    if provider == "gemini" {
      bodyObj = [
        "contents": [
          ["parts": [["text": "\(systemPrompt)\n\n\(prompt)"]]]
        ],
        "generationConfig": [
          "temperature": 0.2,
          "responseMimeType": "application/json"
        ]
      ]
    } else if provider == "claude" {
      req.setValue(key, forHTTPHeaderField: "x-api-key")
      req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
      bodyObj = [
        "model": modelName,
        "max_tokens": 4096,
        "temperature": 0.2,
        "system": systemPrompt,
        "messages": [
          ["role": "user", "content": prompt]
        ]
      ]
    } else {
      req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
      bodyObj = [
        "model": modelName,
        "messages": [
          ["role": "system", "content": systemPrompt],
          ["role": "user", "content": prompt]
        ],
        "temperature": 0.2
      ]
    }

    guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyObj),
          let (data, resp) = try? await URLSession.shared.upload(for: req, from: bodyData),
          let http = resp as? HTTPURLResponse,
          (200..<300).contains(http.statusCode),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }

    var textContent = ""
    if provider == "gemini" {
      if let cands = root["candidates"] as? [[String: Any]],
         let content = cands.first?["content"] as? [String: Any],
         let parts = content["parts"] as? [[String: Any]],
         let txt = parts.first?["text"] as? String {
        textContent = txt
      }
    } else if provider == "claude" {
      if let contentList = root["content"] as? [[String: Any]] {
        for block in contentList {
          if let txt = block["text"] as? String, !txt.isEmpty {
            textContent = txt
            break
          }
        }
      }
    } else {
      if let choices = root["choices"] as? [[String: Any]],
         let msg = choices.first?["message"] as? [String: Any],
         let txt = msg["content"] as? String {
        textContent = txt
      }
    }

    guard let startBrace = textContent.firstIndex(of: "{"),
          let endBrace = textContent.lastIndex(of: "}") else {
      return nil
    }
    let jsonSlice = String(textContent[startBrace...endBrace])
    guard let jsonData = jsonSlice.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
          let list = parsed["playlists"] as? [[String: Any]] else {
      return nil
    }

    var result: [String: [Int]] = [:]
    for item in list {
      guard let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty,
            let rawIndices = item["indices"] as? [Any] else { continue }
      let valid = rawIndices.compactMap { v -> Int? in
        if let i = v as? Int, i >= 0, i <= maxIndex { return i }
        if let s = v as? String, let i = Int(s), i >= 0, i <= maxIndex { return i }
        return nil
      }
      if !valid.isEmpty {
        result["✨ \(name)"] = valid
      }
    }
    return result.isEmpty ? nil : result
  }

  func playCloudMusicFromDirectory(
    _ targetTrack: TvFileEntry,
    openFullscreen: Bool = true,
    shuffle: Bool = false
  ) {
    if isAudioPlaying {
      audioPlayer?.pause()
      isAudioPlaying = false
    }
    cacheCurrentDirectorySiblings()
    let currentList = displayedFileEntries.isEmpty ? fileListing.entries : displayedFileEntries
    var audioTracks = currentList.filter { !$0.isDir && $0.isAudio }
    if audioTracks.isEmpty {
      cloudMusicQueue = [targetTrack]
      cloudMusicCurrentIndex = 0
    } else if shuffle {
      cloudMusicPlayMode = "shuffle"
      audioTracks.shuffle()
      cloudMusicQueue = audioTracks
      cloudMusicCurrentIndex = 0
    } else {
      cloudMusicQueue = audioTracks
      if let idx = cloudMusicQueue.firstIndex(where: { $0.path == targetTrack.path && $0.mountId == targetTrack.mountId }) {
        cloudMusicCurrentIndex = idx
      } else {
        cloudMusicQueue.insert(targetTrack, at: 0)
        cloudMusicCurrentIndex = 0
      }
    }
    if openFullscreen {
      showCloudMusicFullscreen = true
    }
    syncDefaultCloudMusicPlaylist()
    openCurrentCloudMusicTrack()
  }

  func addCloudMusicToQueue(_ track: TvFileEntry, playNext: Bool = false) {
    cacheCurrentDirectorySiblings()
    if cloudMusicQueue.isEmpty || cloudMusicCurrentIndex < 0 {
      cloudMusicQueue = [track]
      cloudMusicCurrentIndex = 0
      syncDefaultCloudMusicPlaylist()
      openCurrentCloudMusicTrack()
      return
    }
    if let existingIdx = cloudMusicQueue.firstIndex(where: { $0.path == track.path && $0.mountId == track.mountId }) {
      if playNext && existingIdx != cloudMusicCurrentIndex {
        let item = cloudMusicQueue.remove(at: existingIdx)
        if existingIdx < cloudMusicCurrentIndex {
          cloudMusicCurrentIndex -= 1
        }
        let insertIdx = min(max(0, cloudMusicCurrentIndex + 1), cloudMusicQueue.count)
        cloudMusicQueue.insert(item, at: insertIdx)
      }
      syncDefaultCloudMusicPlaylist()
      return
    }
    if playNext {
      let insertIdx = min(max(0, cloudMusicCurrentIndex + 1), cloudMusicQueue.count)
      cloudMusicQueue.insert(track, at: insertIdx)
    } else {
      cloudMusicQueue.append(track)
    }
    syncDefaultCloudMusicPlaylist()
  }

  func playCloudMusicQueueIndex(_ index: Int) {
    guard index >= 0 && index < cloudMusicQueue.count else { return }
    if index == cloudMusicCurrentIndex, cloudMusicPlayer != nil, cloudMusicErrorText.isEmpty {
      toggleCloudMusicPlayPause()
      return
    }
    cloudMusicCurrentIndex = index
    syncDefaultCloudMusicPlaylist()
    openCurrentCloudMusicTrack()
  }

  func removeCloudMusicTrackAt(_ index: Int) {
    guard index >= 0 && index < cloudMusicQueue.count else { return }
    let removingCurrent = (index == cloudMusicCurrentIndex)
    cloudMusicQueue.remove(at: index)
    if cloudMusicQueue.isEmpty {
      stopCloudMusicPlayer()
      return
    }
    if index < cloudMusicCurrentIndex {
      cloudMusicCurrentIndex -= 1
    } else if removingCurrent {
      if cloudMusicCurrentIndex >= cloudMusicQueue.count {
        cloudMusicCurrentIndex = 0
      }
      syncDefaultCloudMusicPlaylist()
      openCurrentCloudMusicTrack()
      return
    }
    syncDefaultCloudMusicPlaylist()
  }

  private func openCurrentCloudMusicTrack(useLocalChunkProxy: Bool = false) {
    guard let track = currentCloudMusicTrack else { return }
    cloudMusicOpenSeq &+= 1
    let seq = cloudMusicOpenSeq
    if !useLocalChunkProxy {
      cloudMusicRetriedWithProxy = false
    }

    cleanupCloudMusicPlayerInstance()
    isCloudMusicLoading = true
    isCloudMusicSessionDocked = true
    cloudMusicErrorText = ""
    cloudMusicPosition = 0
    cloudMusicDuration = 0

    if !useLocalChunkProxy {
      loadCloudMusicCoverAndLyrics(for: track, seq: seq)
    }

    Task {
      do {
        if track.isInsideArchive {
          let extractedUrl = try await self.extractArchiveAudioToTempUrl(track)
          guard seq == self.cloudMusicOpenSeq else { return }
          self.cloudMusicSubtitle = "压缩包直读 (\(track.archiveContainerName)) · \(track.formattedSize)"
          self.startCloudMusicAvPlayer(url: extractedUrl, headers: [:], track: track, seq: seq)
          return
        }

        if track.sourceKind == .localCache {
          let localUrl = Self.resolveLocalOfflineUrl(relativePath: track.path)
          guard seq == self.cloudMusicOpenSeq else { return }
          self.cloudMusicSubtitle = "Apple TV 本机离线缓存 · \(track.formattedSize)"
          self.startCloudMusicAvPlayer(url: localUrl, headers: [:], track: track, seq: seq)
          return
        }

        let resolved = try await self.resolveFileStreamEndpoint(track)
        guard seq == self.cloudMusicOpenSeq else { return }
        guard !resolved.url.isEmpty else {
          self.isCloudMusicLoading = false
          self.cloudMusicErrorText = "无法解析音频播放直链"
          return
        }

        self.cloudMusicSubtitle = resolved.subtitle
        var targetUrlStr = resolved.url
        var targetHeaders = resolved.headers
        let ext = track.normalizedExt
        let urlPathLower = (URL(string: resolved.url)?.path ?? "").lowercased()
        let urlHasAudioExtension = !ext.isEmpty && urlPathLower.hasSuffix(ext)

        // When URL path lacks the audio extension (e.g. `/api/files/stream?path=...`) or when retrying with WAV header normalization proxy (`useLocalChunkProxy`),
        // route through local loopback proxy (`TvLocalHlsProxyServer`).
        // For direct CDN URLs that already carry `.wav` / `.flac` / `.mp3` / `.m4a` in their path (e.g. 115 CDN with `auth_cookie`),
        // play directly via `AVURLAssetHTTPHeaderFieldsKey` first so AppleCoreMedia handles WAV tail-chunk seeks over a single native socket in 0.3s,
        // and automatically fall back to `useLocalChunkProxy = true` if the file has a non-standard header (e.g. leading ID3v2 before RIFF).
        if useLocalChunkProxy || !urlHasAudioExtension {
          targetUrlStr = TvLocalHlsProxyServer.shared.prepareTelegramVideoProxyUrl(
            remoteUrl: resolved.url,
            headers: resolved.headers,
            extHint: ext
          )
          targetHeaders = [:]
        }

        guard let playUrl = URL(string: targetUrlStr) else {
          self.isCloudMusicLoading = false
          self.cloudMusicErrorText = "音频地址格式无效"
          return
        }
        self.startCloudMusicAvPlayer(url: playUrl, headers: targetHeaders, track: track, seq: seq)
      } catch {
        guard seq == self.cloudMusicOpenSeq else { return }
        self.isCloudMusicLoading = false
        self.isCloudMusicPlaying = false
        self.cloudMusicErrorText = "音频加载失败：\(error.localizedDescription)"
      }
    }
  }

  private func startCloudMusicAvPlayer(
    url: URL,
    headers: [String: String],
    track: TvFileEntry,
    seq: Int
  ) {
    let options: [String: Any] = headers.isEmpty ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": headers]
    let asset = AVURLAsset(url: url, options: options)
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = 30
    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = true
    self.cloudMusicPlayer = player

    let isLocalProxyStream = url.host == "127.0.0.1" || url.host == "localhost"
    var lastReportedAccessLogBytes: Int64 = 0
    cloudMusicTimeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
      queue: .main
    ) { [weak self] time in
      let sec = CMTimeGetSeconds(time)
      let durSec = player.currentItem.map { CMTimeGetSeconds($0.duration) } ?? 0
      let itemStatus = player.currentItem?.status ?? .unknown
      let itemErr = player.currentItem?.error
      let accessLogBytes: Int64 = {
        guard !isLocalProxyStream,
              let events = player.currentItem?.accessLog()?.events else { return 0 }
        return events.reduce(Int64(0)) { $0 + max(0, $1.numberOfBytesTransferred) }
      }()
      Task { @MainActor [weak self] in
        guard let self = self, seq == self.cloudMusicOpenSeq else { return }
        if !isLocalProxyStream && track.sourceKind != .localCache {
          if accessLogBytes > lastReportedAccessLogBytes {
            let delta = Int(min(Int64(50_000_000), accessLogBytes - lastReportedAccessLogBytes))
            lastReportedAccessLogBytes = accessLogBytes
            TvNetworkSpeedMonitor.shared.recordDownstreamBytes(delta)
          } else if self.isCloudMusicPlaying && sec > 0.05 && TvNetworkSpeedMonitor.shared.recentDownstreamBytesPerSecond < 1024 {
            let estPerTick: Int = {
              if track.size > 0 && durSec.isFinite && durSec > 1 {
                return max(4096, min(128_000, Int(Double(track.size) / durSec * 0.25)))
              }
              return 10_240
            }()
            TvNetworkSpeedMonitor.shared.recordDownstreamBytes(estPerTick)
          }
        }
        if itemStatus == .failed {
          if !self.cloudMusicRetriedWithProxy && track.sourceKind != .localCache {
            self.cloudMusicRetriedWithProxy = true
            self.openCurrentCloudMusicTrack(useLocalChunkProxy: true)
            return
          }
          self.isCloudMusicLoading = false
          self.isCloudMusicPlaying = false
          self.cloudMusicErrorText = "音频解码失败：\(itemErr?.localizedDescription ?? "格式暂不支持")"
          return
        }
        if sec.isFinite && sec >= 0 {
          self.cloudMusicPosition = sec
          if sec > 0.05 && self.isCloudMusicLoading {
            self.isCloudMusicLoading = false
          }
        }
        if durSec.isFinite && durSec > 0 {
          self.cloudMusicDuration = durSec
          if self.isCloudMusicLoading && itemStatus == .readyToPlay {
            self.isCloudMusicLoading = false
          }
        }
        self.updateNowPlayingInfo()
      }
    }

    cloudMusicEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      Task { @MainActor in
        guard seq == self.cloudMusicOpenSeq else { return }
        self.onCloudMusicTrackCompleted()
      }
    }

    cloudMusicFailObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      Task { @MainActor in
        guard seq == self.cloudMusicOpenSeq else { return }
        if !self.cloudMusicRetriedWithProxy && track.sourceKind != .localCache {
          self.cloudMusicRetriedWithProxy = true
          self.openCurrentCloudMusicTrack(useLocalChunkProxy: true)
        }
      }
    }

    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.allowAirPlay])
    try? AVAudioSession.sharedInstance().setActive(true)
    player.playImmediately(atRate: cloudMusicSpeed)
    isCloudMusicPlaying = true
    updateNowPlayingInfo(force: true)
  }

  private func loadCloudMusicCoverAndLyrics(for track: TvFileEntry, seq: Int) {
    cloudMusicCoverImage = nil
    cloudMusicLyrics = []
    cloudMusicLyricsSource = ""
    isCloudMusicLoadingLyrics = true

    let dirKey = dirKeyForCloudMusicEntry(track)
    let siblings = cloudMusicDirectorySiblingsByKey[dirKey] ?? fileListing.entries
    let baseName = ((track.name as NSString).deletingPathExtension).lowercased()

    Task {
      // 1. Discover cover art in same 115 / AList / WebDAV / Local directory
      var coverEntry: TvFileEntry? = siblings.first(where: {
        $0.isImage && (($0.name as NSString).deletingPathExtension).lowercased() == baseName
      })
      if coverEntry == nil {
        let stdNames: Set<String> = ["cover", "folder", "album", "front", "artwork", "thumb"]
        coverEntry = siblings.first(where: {
          $0.isImage && stdNames.contains((($0.name as NSString).deletingPathExtension).lowercased())
        })
      }
      if coverEntry == nil {
        coverEntry = siblings.first(where: { $0.isImage })
      }

      if let ce = coverEntry {
        if ce.isInsideArchive {
          if let d = try? await self.extractArchiveEntryData(ce),
             let img = UIImage(data: d),
             seq == self.cloudMusicOpenSeq {
            self.cloudMusicCoverImage = img
          }
        } else if ce.sourceKind == .localCache {
          let localUrl = Self.resolveLocalOfflineUrl(relativePath: ce.path)
          if let d = try? Data(contentsOf: localUrl), let img = UIImage(data: d), seq == self.cloudMusicOpenSeq {
            self.cloudMusicCoverImage = img
          }
        } else if ce.sourceKind == .cloud115 {
          if let resolved = try? await self.resolveFileStreamEndpoint(ce),
             let data = await TvLocal115DirectClient.shared.fetch115ImageData(urlStr: resolved.url),
             let img = UIImage(data: data),
             seq == self.cloudMusicOpenSeq {
            self.cloudMusicCoverImage = img
          } else if !ce.thumbUrl.isEmpty,
                    let data = await TvLocal115DirectClient.shared.fetch115ImageData(urlStr: ce.thumbUrl),
                    let img = UIImage(data: data),
                    seq == self.cloudMusicOpenSeq {
            self.cloudMusicCoverImage = img
          }
        } else if let resolved = try? await self.resolveFileStreamEndpoint(ce),
                  let data = await self.api.fetchFilePreviewImageData(urlStr: resolved.url, headers: resolved.headers),
                  let img = UIImage(data: data),
                  seq == self.cloudMusicOpenSeq {
          self.cloudMusicCoverImage = img
        }
      } else if !track.thumbUrl.isEmpty {
        if let data = await self.api.fetchFilePreviewImageData(urlStr: track.thumbUrl, headers: [:]),
           let img = UIImage(data: data),
           seq == self.cloudMusicOpenSeq {
          self.cloudMusicCoverImage = img
        }
      }

      if self.cloudMusicCoverImage == nil, seq == self.cloudMusicOpenSeq {
        let meta = Self.parseCloudTrackMetadata(track)
        let cleanTitle = meta.title.replacingOccurrences(
          of: #"\(.*?\)|\[.*?\]|【.*?】"#,
          with: " ",
          options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = (!meta.artist.contains("115") && !meta.artist.contains("AList") && !meta.artist.contains("WebDAV"))
          ? meta.artist.replacingOccurrences(
              of: #"\(.*?\)|\[.*?\]|【.*?】"#,
              with: " ",
              options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
          : ""
        let artQuery = cleanArtist.isEmpty ? cleanTitle : "\(cleanArtist) \(cleanTitle)"
        if let onlineImg = await Self.fetchOnlineItunesCoverImage(query: artQuery),
           seq == self.cloudMusicOpenSeq {
          self.cloudMusicCoverImage = onlineImg
        }
      }
      if self.cloudMusicCoverImage != nil, seq == self.cloudMusicOpenSeq {
        self.updateNowPlayingInfo(force: true)
      }

      // 2. Discover `.lrc` sidecar file in the same 115 / AList / WebDAV / Local directory
      let lrcEntry = siblings.first(where: { s in
        guard !s.isDir && s.normalizedExt == ".lrc" else { return false }
        let sBase = ((s.name as NSString).deletingPathExtension).lowercased()
        return sBase == baseName || baseName.contains(sBase) || sBase.contains(baseName)
      })

      if let lrc = lrcEntry {
        if let rawText = try? await self.fetchCloudTextContent(for: lrc),
           !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          let parsed = Self.parseCloudLrcText(rawText)
          if !parsed.isEmpty, seq == self.cloudMusicOpenSeq {
            self.cloudMusicLyrics = parsed
            self.cloudMusicLyricsSource = "同目录 .lrc 歌词 (\(lrc.name))"
            self.isCloudMusicLoadingLyrics = false
            return
          }
        }
      }

      // 3. Fallback: Query open-source LRCLIB synchronized lyrics API
      let meta = Self.parseCloudTrackMetadata(track)
      let query = (!meta.artist.isEmpty && !meta.artist.contains("115") && !meta.artist.contains("AList"))
        ? "\(meta.artist) \(meta.title)"
        : meta.title
      if let onlineLrc = await Self.fetchOnlineLrclibLyrics(query: query),
         !onlineLrc.isEmpty,
         seq == self.cloudMusicOpenSeq {
        self.cloudMusicLyrics = onlineLrc
        self.cloudMusicLyricsSource = "LRCLIB 云端同步歌词"
        self.isCloudMusicLoadingLyrics = false
        return
      }

      if seq == self.cloudMusicOpenSeq {
        self.isCloudMusicLoadingLyrics = false
      }
    }
  }

  private func fetchCloudTextContent(for entry: TvFileEntry) async throws -> String {
    if entry.isInsideArchive {
      let d = try await extractArchiveEntryData(entry)
      return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
    }
    if entry.sourceKind == .localCache {
      let localUrl = Self.resolveLocalOfflineUrl(relativePath: entry.path)
      let d = try Data(contentsOf: localUrl)
      return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
    }
    let resolved = try await resolveFileStreamEndpoint(entry)
    return try await api.fetchFilePreviewText(urlStr: resolved.url, headers: resolved.headers)
  }

  static func parseCloudLrcText(_ raw: String) -> [TvCloudLrcLine] {
    var result: [TvCloudLrcLine] = []
    guard let regex = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[\.:](\d{1,3}))?\]"#) else {
      return result
    }
    let lines = raw.components(separatedBy: .newlines)
    for line in lines {
      let nsLine = line as NSString
      let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
      guard !matches.isEmpty else { continue }
      let cleanText = regex.stringByReplacingMatches(
        in: line,
        range: NSRange(location: 0, length: nsLine.length),
        withTemplate: ""
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !cleanText.isEmpty else { continue }

      for m in matches {
        let minStr = nsLine.substring(with: m.range(at: 1))
        let secStr = nsLine.substring(with: m.range(at: 2))
        let mins = Double(minStr) ?? 0
        let secs = Double(secStr) ?? 0
        var ms: Double = 0
        if m.range(at: 3).location != NSNotFound {
          let fracStr = nsLine.substring(with: m.range(at: 3))
          let fracVal = Double(fracStr) ?? 0
          if fracStr.count == 1 {
            ms = fracVal * 100.0
          } else if fracStr.count == 2 {
            ms = fracVal * 10.0
          } else {
            ms = fracVal
          }
        }
        let totalSec = mins * 60.0 + secs + (ms / 1000.0)
        result.append(TvCloudLrcLine(timeSeconds: totalSec, text: cleanText))
      }
    }
    result.sort { $0.timeSeconds < $1.timeSeconds }
    return result
  }

  private static func fetchOnlineItunesCoverImage(query: String) async -> UIImage? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let enc = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://itunes.apple.com/search?term=\(enc)&media=music&entity=song&limit=3") else {
      return nil
    }
    var req = URLRequest(url: url)
    req.timeoutInterval = 6.0
    req.setValue("LiuguangMusicPlayerTV/1.2.2", forHTTPHeaderField: "User-Agent")
    guard let (data, resp) = try? await URLSession.shared.data(for: req),
          let http = resp as? HTTPURLResponse,
          http.statusCode == 200,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let results = obj["results"] as? [[String: Any]] else {
      return nil
    }
    for item in results {
      if let rawArt = item["artworkUrl100"] as? String, !rawArt.isEmpty {
        let hdArt = rawArt.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        if let artUrl = URL(string: hdArt),
           let (imgData, _) = try? await URLSession.shared.data(from: artUrl),
           let img = UIImage(data: imgData) {
          return img
        }
      }
    }
    return nil
  }

  private static func fetchOnlineLrclibLyrics(query: String) async -> [TvCloudLrcLine]? {
    let cleaned = query.replacingOccurrences(
      of: #"\(.*?\)|\[.*?\]|【.*?】"#,
      with: " ",
      options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty,
          let enc = cleaned.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://lrclib.net/api/search?q=\(enc)") else {
      return nil
    }
    var req = URLRequest(url: url)
    req.timeoutInterval = 6.0
    req.setValue("LiuguangMusicPlayerTV/1.2.1", forHTTPHeaderField: "User-Agent")
    guard let (data, resp) = try? await URLSession.shared.data(for: req),
          let http = resp as? HTTPURLResponse,
          http.statusCode == 200,
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return nil
    }
    for item in arr {
      if let synced = item["syncedLyrics"] as? String, !synced.isEmpty {
        let parsed = parseCloudLrcText(synced)
        if !parsed.isEmpty { return parsed }
      }
    }
    for item in arr {
      if let plain = item["plainLyrics"] as? String, !plain.isEmpty {
        let rawLines = plain
          .components(separatedBy: .newlines)
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
        if !rawLines.isEmpty {
          return rawLines.enumerated().map { idx, txt in
            TvCloudLrcLine(timeSeconds: Double(idx * 4), text: txt)
          }
        }
      }
    }
    return nil
  }

  func toggleCloudMusicPlayPause() {
    guard currentCloudMusicTrack != nil else { return }
    if !cloudMusicErrorText.isEmpty || cloudMusicPlayer == nil {
      openCurrentCloudMusicTrack()
      return
    }
    if isCloudMusicPlaying {
      cloudMusicPlayer?.pause()
      isCloudMusicPlaying = false
    } else {
      try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.allowAirPlay])
      try? AVAudioSession.sharedInstance().setActive(true)
      cloudMusicPlayer?.playImmediately(atRate: cloudMusicSpeed)
      isCloudMusicPlaying = true
    }
    updateNowPlayingInfo(force: true)
  }

  func seekCloudMusic(to seconds: Double) {
    guard let player = cloudMusicPlayer else { return }
    let clamped = max(0, min(seconds, cloudMusicDuration > 0 ? cloudMusicDuration : 86400))
    cloudMusicPosition = clamped
    player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
    updateNowPlayingInfo(force: true)
  }

  func seekCloudMusicRelative(delta: Double) {
    seekCloudMusic(to: cloudMusicPosition + delta)
  }

  func stepCloudMusicTrack(delta: Int) {
    guard !cloudMusicQueue.isEmpty else { return }
    if delta < 0 && cloudMusicPosition >= 5.0 {
      seekCloudMusic(to: 0)
      return
    }
    if cloudMusicQueue.count == 1 {
      seekCloudMusic(to: 0)
      cloudMusicPlayer?.playImmediately(atRate: cloudMusicSpeed)
      isCloudMusicPlaying = true
      return
    }
    if cloudMusicPlayMode == "shuffle" {
      let indices = cloudMusicQueue.indices.filter { $0 != cloudMusicCurrentIndex }
      cloudMusicCurrentIndex = indices.randomElement() ?? 0
    } else {
      cloudMusicCurrentIndex = (cloudMusicCurrentIndex + delta + cloudMusicQueue.count) % cloudMusicQueue.count
    }
    syncDefaultCloudMusicPlaylist()
    openCurrentCloudMusicTrack()
  }

  private func onCloudMusicTrackCompleted() {
    guard !cloudMusicQueue.isEmpty else { return }
    if cloudMusicPlayMode == "repeatOne" {
      seekCloudMusic(to: 0)
      cloudMusicPlayer?.playImmediately(atRate: cloudMusicSpeed)
      isCloudMusicPlaying = true
      return
    }
    if cloudMusicQueue.count == 1 {
      if cloudMusicPlayMode == "repeatAll" {
        seekCloudMusic(to: 0)
        cloudMusicPlayer?.playImmediately(atRate: cloudMusicSpeed)
        isCloudMusicPlaying = true
      } else {
        isCloudMusicPlaying = false
        cloudMusicPosition = 0
      }
      return
    }
    if cloudMusicPlayMode == "shuffle" {
      let indices = cloudMusicQueue.indices.filter { $0 != cloudMusicCurrentIndex }
      cloudMusicCurrentIndex = indices.randomElement() ?? 0
      syncDefaultCloudMusicPlaylist()
      openCurrentCloudMusicTrack()
    } else if cloudMusicCurrentIndex + 1 < cloudMusicQueue.count {
      cloudMusicCurrentIndex += 1
      syncDefaultCloudMusicPlaylist()
      openCurrentCloudMusicTrack()
    } else if cloudMusicPlayMode == "repeatAll" {
      cloudMusicCurrentIndex = 0
      syncDefaultCloudMusicPlaylist()
      openCurrentCloudMusicTrack()
    } else {
      isCloudMusicPlaying = false
      cloudMusicPosition = 0
    }
  }

  func cycleCloudMusicPlayMode() {
    let modes = ["repeatAll", "repeatOne", "shuffle", "sequential"]
    let idx = modes.firstIndex(of: cloudMusicPlayMode) ?? 0
    cloudMusicPlayMode = modes[(idx + 1) % modes.count]
    showToast("音乐播放模式：\(cloudMusicPlayModeLabel)")
  }

  var cloudMusicPlayModeLabel: String {
    switch cloudMusicPlayMode {
    case "repeatOne": return "单曲循环"
    case "shuffle": return "随机播放"
    case "sequential": return "顺序播放"
    default: return "列表循环"
    }
  }

  var cloudMusicPlayModeIcon: String {
    switch cloudMusicPlayMode {
    case "repeatOne": return "repeat.1"
    case "shuffle": return "shuffle"
    case "sequential": return "text.line.first.and.arrowtriangle.forward"
    default: return "repeat"
    }
  }

  func cycleCloudMusicSpeed() {
    let speeds: [Float] = [1.0, 1.25, 1.5, 2.0, 0.75]
    let idx = speeds.firstIndex(of: cloudMusicSpeed) ?? 0
    cloudMusicSpeed = speeds[(idx + 1) % speeds.count]
    if isCloudMusicPlaying {
      cloudMusicPlayer?.rate = cloudMusicSpeed
    }
  }

  func toggleCloudMusicMute() {
    cloudMusicIsMuted.toggle()
    cloudMusicPlayer?.isMuted = cloudMusicIsMuted
  }

  func stepCloudMusicVolume(delta: Float) {
    cloudMusicIsMuted = false
    cloudMusicVolume = min(max(0.0, cloudMusicVolume + delta), 1.0)
    cloudMusicPlayer?.isMuted = (cloudMusicVolume <= 0.01)
    cloudMusicPlayer?.volume = cloudMusicVolume
  }

  func cycleSpeedBadgeCorner() {
    speedBadgeCornerPreset = (speedBadgeCornerPreset + 1) % 4
  }

  private func cleanupCloudMusicPlayerInstance() {
    if let obs = cloudMusicTimeObserver {
      cloudMusicPlayer?.removeTimeObserver(obs)
      cloudMusicTimeObserver = nil
    }
    if let endObs = cloudMusicEndObserver {
      NotificationCenter.default.removeObserver(endObs)
      cloudMusicEndObserver = nil
    }
    if let failObs = cloudMusicFailObserver {
      NotificationCenter.default.removeObserver(failObs)
      cloudMusicFailObserver = nil
    }
    let previousUrl = (cloudMusicPlayer?.currentItem?.asset as? AVURLAsset)?.url
    cloudMusicPlayer?.pause()
    cloudMusicPlayer?.replaceCurrentItem(with: nil)
    cloudMusicPlayer = nil
    if let previousUrl {
      TvLocalHlsProxyServer.shared.releaseTelegramVideoProxyUrl(previousUrl)
    }
  }

  /// Stops any active background music (`cloudMusicPlayer`) or Telegram audio (`audioPlayer`)
  /// whenever any video playback starts across the app.
  func stopBackgroundAudioForVideoPlayback() {
    if isCloudMusicPlaying || isCloudMusicLoading || cloudMusicPlayer != nil || isCloudMusicSessionDocked {
      stopCloudMusicPlayer(clearPersistedQueue: false)
    }
    if isAudioPlaying || audioPlayer != nil || playingAudioMessage != nil {
      stopAudioPlayer()
    }
  }

  func stopCloudMusicPlayer(clearPersistedQueue: Bool = false) {
    cloudMusicOpenSeq &+= 1
    cleanupCloudMusicPlayerInstance()
    if clearPersistedQueue {
      cloudMusicQueue = []
      cloudMusicCurrentIndex = -1
    }
    isCloudMusicPlaying = false
    isCloudMusicLoading = false
    isCloudMusicSessionDocked = false
    cloudMusicErrorText = ""
    cloudMusicPosition = 0
    cloudMusicDuration = 0
    showCloudMusicFullscreen = false
    updateNowPlayingInfo(force: true)
  }

  // MARK: - Unified File Operations (Mkdir / Rename / Delete / Copy / Move) Across All Storage Mounts

  func createFolderInActiveMount(name: String) async {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let mount = activeStorageMount
    let currentDir = fileListing.path.isEmpty ? mount.rootPath : fileListing.path
    do {
      switch mount.kind {
      case .server:
        try await api.createDirectory(parentPath: fileListing.path, name: trimmed)
      case .alist:
        try await TvRemoteStorageClient.shared.createAlistFolder(mount: mount, parentPath: currentDir, name: trimmed)
      case .webdav:
        try await TvRemoteStorageClient.shared.createWebdavFolder(mount: mount, parentPath: currentDir, name: trimmed)
      case .smb:
        try await TvSmbClient.shared.createSmbFolder(mount: mount, parentPath: currentDir, name: trimmed)
      case .cloud115:
        try await TvLocal115DirectClient.shared.create115Folder(parentCid: currentDir, name: trimmed)
      case .localCache:
        let folderUrl = Self.resolveLocalOfflineUrl(relativePath: TvRemoteStorageClient.joinPath(currentDir, trimmed))
        try FileManager.default.createDirectory(at: folderUrl, withIntermediateDirectories: true)
      }
      showToast("✓ 已新建文件夹：\(trimmed)")
      await loadFiles(path: fileListing.path)
    } catch {
      showToast("新建文件夹失败：\(error.localizedDescription)")
    }
  }

  func renameEntryInActiveMount(_ entry: TvFileEntry, newName: String) async {
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != entry.name else { return }
    let mount = storageMounts.first(where: { $0.id == entry.mountId }) ?? activeStorageMount
    do {
      switch mount.kind {
      case .server:
        try await api.renameFile(path: entry.path, newName: trimmed)
      case .alist:
        try await TvRemoteStorageClient.shared.renameAlistEntry(mount: mount, path: entry.path, newName: trimmed)
      case .webdav:
        let parent = TvRemoteStorageClient.parentPath(of: entry.path)
        let dst = TvRemoteStorageClient.joinPath(parent.isEmpty ? "/" : parent, trimmed)
        try await TvRemoteStorageClient.shared.moveOrCopyWebdavEntry(mount: mount, srcPath: entry.path, dstPath: dst, isMove: true)
      case .smb:
        let parent = TvRemoteStorageClient.parentPath(of: entry.path)
        let dst = TvRemoteStorageClient.joinPath(parent.isEmpty ? "/" : parent, trimmed)
        try await TvSmbClient.shared.moveOrCopySmbEntry(mount: mount, srcVirtualPath: entry.path, dstVirtualPath: dst, isMove: true)
      case .cloud115:
        try await TvLocal115DirectClient.shared.rename115File(fid: entry.fid115.isEmpty ? entry.path : entry.fid115, newName: trimmed)
      case .localCache:
        let srcUrl = Self.resolveLocalOfflineUrl(relativePath: entry.path)
        let dstUrl = srcUrl.deletingLastPathComponent().appendingPathComponent(trimmed)
        try FileManager.default.moveItem(at: srcUrl, to: dstUrl)
      }
      showToast("✓ 已重命名为：\(trimmed)")
      await loadFiles(path: fileListing.path)
    } catch {
      showToast("重命名失败：\(error.localizedDescription)")
    }
  }

  func deleteEntriesInActiveMount(_ entries: [TvFileEntry]) async {
    guard !entries.isEmpty else { return }
    let mount = activeStorageMount
    let currentDir = fileListing.path.isEmpty ? mount.rootPath : fileListing.path
    do {
      switch mount.kind {
      case .server:
        for e in entries {
          try await api.deleteFile(path: e.path)
        }
      case .alist:
        let names = entries.map(\.name)
        try await TvRemoteStorageClient.shared.deleteAlistEntries(mount: mount, dirPath: currentDir, names: names)
      case .webdav:
        for e in entries {
          try await TvRemoteStorageClient.shared.deleteWebdavEntry(mount: mount, path: e.path, isDir: e.isDir)
        }
      case .smb:
        for e in entries {
          try await TvSmbClient.shared.deleteSmbEntry(mount: mount, virtualPath: e.path, isDir: e.isDir)
        }
      case .cloud115:
        for e in entries {
          let fid = e.fid115.isEmpty ? e.path : e.fid115
          try await TvLocal115DirectClient.shared.delete115File(fid: fid, parentCid: currentDir)
        }
      case .localCache:
        for e in entries {
          let url = Self.resolveLocalOfflineUrl(relativePath: e.path)
          try? FileManager.default.removeItem(at: url)
        }
      }
      fileSelectedPaths.removeAll()
      fileMultiSelectMode = false
      showToast("🗑️ 已删除 \(entries.count) 个项目")
      await loadFiles(path: fileListing.path)
    } catch {
      showToast("删除失败：\(error.localizedDescription)")
    }
  }

  func setClipboard(entries: [TvFileEntry], operation: TvFileClipboardOperation) {
    guard !entries.isEmpty else { return }
    let mount = activeStorageMount
    let srcDir = fileListing.path.isEmpty ? mount.rootPath : fileListing.path
    fileClipboard = TvFileClipboardItem(
      mountId: mount.id,
      sourceDirectory: srcDir,
      entries: entries,
      operation: operation
    )
    fileMultiSelectMode = false
    fileSelectedPaths.removeAll()
    let verb = operation == .copy ? "已复制" : "已剪切"
    showToast("📋 \(verb) \(entries.count) 个项目，请进入目标文件夹后点击「粘贴到此处」")
  }

  func pasteClipboardToCurrentDirectory() async {
    guard let clip = fileClipboard else { return }
    let dstMount = activeStorageMount
    let dstDir = fileListing.path.isEmpty ? dstMount.rootPath : fileListing.path

    // Same-mount fast copy/move for AList, WebDAV, and Local Cache
    if clip.mountId == dstMount.id {
      do {
        switch dstMount.kind {
        case .alist:
          let names = clip.entries.map(\.name)
          try await TvRemoteStorageClient.shared.copyOrMoveAlistEntries(
            mount: dstMount,
            srcDir: clip.sourceDirectory,
            dstDir: dstDir,
            names: names,
            isMove: clip.operation == .move
          )
          fileClipboard = nil
          showToast("✓ 已\(clip.operation == .move ? "移动" : "复制") \(names.count) 个项目到当前目录")
          await loadFiles(path: fileListing.path)
          return

        case .webdav:
          for entry in clip.entries {
            let dstPath = TvRemoteStorageClient.joinPath(dstDir, entry.name)
            try await TvRemoteStorageClient.shared.moveOrCopyWebdavEntry(
              mount: dstMount,
              srcPath: entry.path,
              dstPath: dstPath,
              isMove: clip.operation == .move
            )
          }
          fileClipboard = nil
          showToast("✓ 已\(clip.operation == .move ? "移动" : "复制") \(clip.entries.count) 个项目")
          await loadFiles(path: fileListing.path)
          return

        case .smb:
          for entry in clip.entries {
            let dstPath = TvRemoteStorageClient.joinPath(dstDir, entry.name)
            try await TvSmbClient.shared.moveOrCopySmbEntry(
              mount: dstMount,
              srcVirtualPath: entry.path,
              dstVirtualPath: dstPath,
              isMove: clip.operation == .move
            )
          }
          fileClipboard = nil
          showToast("✓ 已\(clip.operation == .move ? "移动" : "复制") \(clip.entries.count) 个项目")
          await loadFiles(path: fileListing.path)
          return

        case .localCache:
          for entry in clip.entries {
            let srcUrl = Self.resolveLocalOfflineUrl(relativePath: entry.path)
            let dstUrl = Self.resolveLocalOfflineUrl(relativePath: TvRemoteStorageClient.joinPath(dstDir, entry.name))
            if clip.operation == .move {
              try FileManager.default.moveItem(at: srcUrl, to: dstUrl)
            } else {
              try FileManager.default.copyItem(at: srcUrl, to: dstUrl)
            }
          }
          fileClipboard = nil
          showToast("✓ 已\(clip.operation == .move ? "移动" : "复制") \(clip.entries.count) 个本地文件")
          await loadFiles(path: fileListing.path)
          return

        case .cloud115:
          let fids = clip.entries.map { $0.fid115.isEmpty ? $0.path : $0.fid115 }
          try await TvLocal115DirectClient.shared.copyOrMove115Entries(
            fids: fids,
            targetCid: dstDir,
            isMove: clip.operation == .move
          )
          fileClipboard = nil
          showToast("✓ 已在 115 网盘内\(clip.operation == .move ? "移动" : "复制") \(clip.entries.count) 个项目")
          await loadFiles(path: fileListing.path)
          return

        default:
          break
        }
      } catch {
        showToast("粘贴操作失败：\(error.localizedDescription)")
        return
      }
    }

    // Cross-mount transfer (e.g., Server/115/AList -> Local Cache or Local Cache/Server -> AList/WebDAV) with full progress!
    let filesToTransfer = clip.entries.filter { !$0.isDir }
    guard !filesToTransfer.isEmpty else {
      showToast("⚠️ 跨存储源暂仅支持复制/上传文件（不支持空文件夹跨源粘贴）")
      return
    }
    fileClipboard = nil
    for entry in filesToTransfer {
      if dstMount.kind == .localCache {
        startDownloadFileWithProgress(entry, targetSubfolder: dstDir)
      } else {
        startCrossMountUploadWithProgress(entry: entry, targetMount: dstMount, targetDir: dstDir)
      }
    }
  }

  // MARK: - Upload & Download Transfer Manager with Real-Time Progress Display

  var activeRunningTransfersCount: Int {
    fileTransferTasks.filter { $0.status == .running }.count
  }

  var primaryActiveTransferTask: TvFileTransferTask? {
    fileTransferTasks.first(where: { $0.status == .running }) ?? fileTransferTasks.first
  }

  func updateTransferTaskProgress(
    id: String,
    transferredBytes: Int64,
    totalBytes: Int64,
    speedBytesPerSec: Double,
    status: TvFileTransferStatus? = nil,
    detail: String? = nil,
    localSavedPath: String? = nil
  ) {
    guard let idx = fileTransferTasks.firstIndex(where: { $0.id == id }) else { return }
    fileTransferTasks[idx].transferredBytes = max(0, transferredBytes)
    if totalBytes > 0 {
      fileTransferTasks[idx].totalBytes = totalBytes
    }
    fileTransferTasks[idx].speedBytesPerSec = max(0, speedBytesPerSec)
    if let st = status {
      fileTransferTasks[idx].status = st
    }
    if let d = detail {
      fileTransferTasks[idx].detailMessage = d
    }
    if let lp = localSavedPath {
      fileTransferTasks[idx].localSavedPath = lp
    }
  }

  func cancelFileTransfer(id: String) {
    TvStreamingHttpTransfer.shared.cancelTransfer(id: id)
    if let idx = fileTransferTasks.firstIndex(where: { $0.id == id }) {
      fileTransferTasks[idx].status = .cancelled
      fileTransferTasks[idx].speedBytesPerSec = 0
      fileTransferTasks[idx].detailMessage = "用户已取消"
    }
    showToast("已取消传输任务")
  }

  func clearCompletedFileTransfers() {
    fileTransferTasks.removeAll { $0.status != .running }
  }

  /// Downloads any file from Server / AList / WebDAV / 115 to Apple TV Local Offline Cache with real-time progress bar & speed
  func startDownloadFileWithProgress(_ entry: TvFileEntry, targetSubfolder: String = "/") {
    guard !entry.isDir else {
      showToast("暂不支持直接整目录下载，请进入目录后选择文件下载")
      return
    }
    let transferId = "dl_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(4))"
    let sourceMount = storageMounts.first(where: { $0.id == entry.mountId }) ?? activeStorageMount
    let newTask = TvFileTransferTask(
      id: transferId,
      name: entry.name,
      direction: .download,
      sourceLabel: sourceMount.name,
      targetLabel: "本机离线缓存",
      totalBytes: max(0, entry.size),
      transferredBytes: 0,
      speedBytesPerSec: 0,
      status: .running,
      detailMessage: "正在解析下载直链...",
      localSavedPath: nil,
      createdAt: Date()
    )
    fileTransferTasks.insert(newTask, at: 0)
    showToast("⬇️ 开始下载「\(entry.name)」，可在顶部传输栏实时查看进度")

    Task {
      let startTime = Date().timeIntervalSince1970
      do {
        let resolved: (url: String, headers: [String: String], subtitle: String)
        if entry.sourceKind == .server {
          let dlUrl = self.api.buildFileDownloadUrl(path: entry.path)
          resolved = (dlUrl, self.api.authHeaders, "服务端")
        } else {
          resolved = try await self.resolveFileStreamEndpoint(entry)
        }
        guard let url = URL(string: resolved.url) else {
          throw NSError(domain: "TvDownload", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载地址无效"])
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3600
        for (k, v) in resolved.headers {
          req.setValue(v, forHTTPHeaderField: k)
        }
        let relDestPath = TvRemoteStorageClient.joinPath(targetSubfolder, entry.name)
        let destFileUrl = Self.resolveLocalOfflineUrl(relativePath: relDestPath)

        _ = try await TvStreamingHttpTransfer.shared.downloadToFile(
          transferId: transferId,
          request: req,
          destinationUrl: destFileUrl,
          expectedSizeHint: entry.size
        ) { received, total in
          let elapsed = max(0.15, Date().timeIntervalSince1970 - startTime)
          let speed = Double(received) / elapsed
          Task { @MainActor [weak self] in
            self?.updateTransferTaskProgress(
              id: transferId,
              transferredBytes: received,
              totalBytes: total,
              speedBytesPerSec: speed,
              status: .running,
              detail: "正在下载至本机离线缓存..."
            )
          }
        }

        let finalSize = (try? FileManager.default.attributesOfItem(atPath: destFileUrl.path)[.size] as? Int64) ?? entry.size
        let elapsed = max(0.2, Date().timeIntervalSince1970 - startTime)
        self.updateTransferTaskProgress(
          id: transferId,
          transferredBytes: finalSize,
          totalBytes: max(finalSize, entry.size),
          speedBytesPerSec: Double(finalSize) / elapsed,
          status: .completed,
          detail: "✓ 已下载至 Apple TV 本机缓存（支持零缓冲离线播放）",
          localSavedPath: relDestPath
        )
        self.showToast("✅ 下载完成：\(entry.name)")
        if self.activeStorageMount.kind == .localCache {
          await self.loadFiles(path: self.fileListing.path)
        }
      } catch {
        if (error as NSError).code == NSURLErrorCancelled {
          return
        }
        self.updateTransferTaskProgress(
          id: transferId,
          transferredBytes: 0,
          totalBytes: entry.size,
          speedBytesPerSec: 0,
          status: .failed,
          detail: "下载失败：\(error.localizedDescription)"
        )
        self.showToast("⚠️ 下载失败：\(error.localizedDescription)")
      }
    }
  }

  /// Uploads a server file to 115 Cloud Drive (`/api/files/upload-115`) while tracking real-time upload progress in `fileTransferTasks`
  func startUploadServerFileTo115WithProgress(_ entry: TvFileEntry) {
    let transferId = "up115_\(Int(Date().timeIntervalSince1970 * 1000))"
    let totalBytes = max(1, entry.size)
    let task = TvFileTransferTask(
      id: transferId,
      name: entry.name,
      direction: .upload,
      sourceLabel: "流光服务端",
      targetLabel: "115 网盘",
      totalBytes: totalBytes,
      transferredBytes: 0,
      speedBytesPerSec: 0,
      status: .running,
      detailMessage: "正在提交 115 网盘上传任务...",
      localSavedPath: nil,
      createdAt: Date()
    )
    fileTransferTasks.insert(task, at: 0)
    showToast("☁️ 已开始上传「\(entry.name)」到 115 网盘，正在实时跟踪进度...")

    Task {
      let startTime = Date().timeIntervalSince1970
      do {
        if TvLocal115DirectClient.shared.hasLocalCookie {
          try? await self.api.login115WithCookie(cookie: TvLocal115DirectClient.shared.savedCookie)
        }
        try await self.api.uploadFileTo115(path: entry.path)

        // Poll `/api/tasks` and 115 Cloud Drive to track real-time upload progress
        var finished = false
        for tick in 0..<180 {
          try? await Task.sleep(nanoseconds: 1_000_000_000)
          let tasks = await self.api.fetchDownloadTasks()
          self.downloadTasks = tasks
          if let matching = tasks.first(where: {
            $0.outputFile == entry.path || $0.name.contains(entry.name) || entry.name.contains($0.name)
          }) {
            if matching.status == "Uploading" {
              let pct = max(2.0, min(99.0, matching.progress))
              let transferred = Int64(Double(totalBytes) * (pct / 100.0))
              let elapsed = max(0.5, Date().timeIntervalSince1970 - startTime)
              let speed = matching.speed > 0 ? matching.speed : (Double(transferred) / elapsed)
              self.updateTransferTaskProgress(
                id: transferId,
                transferredBytes: transferred,
                totalBytes: totalBytes,
                speedBytesPerSec: speed,
                status: .running,
                detail: String(format: "正在上传至 115 网盘 (%.1f%%)", pct)
              )
              continue
            } else if matching.status == "Failed" {
              throw NSError(domain: "Tv115Upload", code: -1, userInfo: [NSLocalizedDescriptionKey: matching.error.isEmpty ? "115 上传失败" : matching.error])
            }
          }

          // Check if file already appeared in 115 Cloud Drive (or rapid upload succeeded)
          if tick >= 2, TvLocal115DirectClient.shared.hasLocalCookie {
            if let _ = await TvLocal115DirectClient.shared.findAndResolveDirectPlayUrl(keywords: [entry.name]) {
              finished = true
              break
            }
          }
          // Smooth synthetic progress if backend performs synchronous/rapid upload without a `/api/tasks` row
          let simulatedPct = min(0.92, Double(tick + 1) * 0.15)
          let simBytes = Int64(Double(totalBytes) * simulatedPct)
          let elapsed = max(0.5, Date().timeIntervalSince1970 - startTime)
          self.updateTransferTaskProgress(
            id: transferId,
            transferredBytes: simBytes,
            totalBytes: totalBytes,
            speedBytesPerSec: Double(simBytes) / elapsed,
            status: .running,
            detail: "服务端正在同步至 115 网盘..."
          )
          if tick >= 6 && !tasks.contains(where: { $0.status == "Uploading" }) {
            finished = true
            break
          }
        }

        if finished {
          let elapsed = max(0.5, Date().timeIntervalSince1970 - startTime)
          self.updateTransferTaskProgress(
            id: transferId,
            transferredBytes: totalBytes,
            totalBytes: totalBytes,
            speedBytesPerSec: Double(totalBytes) / elapsed,
            status: .completed,
            detail: "✓ 已成功上传至 115 网盘"
          )
          self.showToast("✅ 已上传至 115 网盘：\(entry.name)")
        }
      } catch {
        self.updateTransferTaskProgress(
          id: transferId,
          transferredBytes: 0,
          totalBytes: totalBytes,
          speedBytesPerSec: 0,
          status: .failed,
          detail: "上传 115 失败：\(error.localizedDescription)"
        )
        self.showToast("⚠️ 上传 115 失败：\(error.localizedDescription)")
      }
    }
  }

  /// Uploads raw data (e.g. from LAN Phone/PC browser upload or local cache file) into the specified mount & directory with live progress on Apple TV
  func uploadRawDataToMountWithProgress(
    transferId: String = "up_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(4))",
    fileName: String,
    fileData: Data,
    targetMount: TvStorageMount? = nil,
    targetDir: String? = nil,
    sourceLabel: String = "局域网快传"
  ) async -> Bool {
    let mount = targetMount ?? activeStorageMount
    let dir = targetDir ?? (fileListing.path.isEmpty ? mount.rootPath : fileListing.path)
    let totalBytes = Int64(fileData.count)

    if !fileTransferTasks.contains(where: { $0.id == transferId }) {
      let task = TvFileTransferTask(
        id: transferId,
        name: fileName,
        direction: .upload,
        sourceLabel: sourceLabel,
        targetLabel: "\(mount.name) (\(dir.isEmpty ? "/" : dir))",
        totalBytes: totalBytes,
        transferredBytes: 0,
        speedBytesPerSec: 0,
        status: .running,
        detailMessage: "正在上传文件...",
        localSavedPath: nil,
        createdAt: Date()
      )
      fileTransferTasks.insert(task, at: 0)
    }

    let startTime = Date().timeIntervalSince1970
    do {
      switch mount.kind {
      case .localCache:
        let relPath = TvRemoteStorageClient.joinPath(dir, fileName)
        let destUrl = Self.resolveLocalOfflineUrl(relativePath: relPath)
        try? FileManager.default.createDirectory(at: destUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileData.write(to: destUrl, options: .atomic)
        updateTransferTaskProgress(
          id: transferId,
          transferredBytes: totalBytes,
          totalBytes: totalBytes,
          speedBytesPerSec: Double(totalBytes) / max(0.1, Date().timeIntervalSince1970 - startTime),
          status: .completed,
          detail: "✓ 已存入 Apple TV 本机离线缓存",
          localSavedPath: relPath
        )

      case .alist:
        try await TvRemoteStorageClient.shared.uploadToAlist(
          transferId: transferId,
          mount: mount,
          targetDir: dir,
          fileName: fileName,
          fileData: fileData
        ) { sent, total in
          let elapsed = max(0.15, Date().timeIntervalSince1970 - startTime)
          Task { @MainActor [weak self] in
            self?.updateTransferTaskProgress(
              id: transferId,
              transferredBytes: sent,
              totalBytes: total,
              speedBytesPerSec: Double(sent) / elapsed,
              status: .running,
              detail: "正在上传至 \(mount.name)..."
            )
          }
        }
        updateTransferTaskProgress(
          id: transferId,
          transferredBytes: totalBytes,
          totalBytes: totalBytes,
          speedBytesPerSec: Double(totalBytes) / max(0.2, Date().timeIntervalSince1970 - startTime),
          status: .completed,
          detail: "✓ 已上传至 \(mount.name)"
        )

      case .webdav:
        try await TvRemoteStorageClient.shared.uploadToWebdav(
          transferId: transferId,
          mount: mount,
          targetDir: dir,
          fileName: fileName,
          fileData: fileData
        ) { sent, total in
          let elapsed = max(0.15, Date().timeIntervalSince1970 - startTime)
          Task { @MainActor [weak self] in
            self?.updateTransferTaskProgress(
              id: transferId,
              transferredBytes: sent,
              totalBytes: total,
              speedBytesPerSec: Double(sent) / elapsed,
              status: .running,
              detail: "正在通过 WebDAV 上传至 \(mount.name)..."
            )
          }
        }
        updateTransferTaskProgress(
          id: transferId,
          transferredBytes: totalBytes,
          totalBytes: totalBytes,
          speedBytesPerSec: Double(totalBytes) / max(0.2, Date().timeIntervalSince1970 - startTime),
          status: .completed,
          detail: "✓ 已通过 WebDAV 上传至 \(mount.name)"
        )

      case .smb:
        try await TvSmbClient.shared.uploadToSmb(
          mount: mount,
          targetDir: dir,
          fileName: fileName,
          fileData: fileData
        ) { sent, total in
          let elapsed = max(0.15, Date().timeIntervalSince1970 - startTime)
          Task { @MainActor [weak self] in
            self?.updateTransferTaskProgress(
              id: transferId,
              transferredBytes: sent,
              totalBytes: total,
              speedBytesPerSec: Double(sent) / elapsed,
              status: .running,
              detail: "正在通过 SMB 上传至 \(mount.name)..."
            )
          }
        }
        updateTransferTaskProgress(
          id: transferId,
          transferredBytes: totalBytes,
          totalBytes: totalBytes,
          speedBytesPerSec: Double(totalBytes) / max(0.2, Date().timeIntervalSince1970 - startTime),
          status: .completed,
          detail: "✓ 已通过 SMB 上传至 \(mount.name)"
        )

      case .cloud115:
        try await TvLocal115DirectClient.shared.uploadDataTo115(
          parentCid: dir,
          fileName: fileName,
          fileData: fileData
        ) { sent, total in
          let elapsed = max(0.15, Date().timeIntervalSince1970 - startTime)
          Task { @MainActor [weak self] in
            self?.updateTransferTaskProgress(
              id: transferId,
              transferredBytes: sent,
              totalBytes: total,
              speedBytesPerSec: Double(sent) / elapsed,
              status: .running,
              detail: "正在直传至 115 网盘..."
            )
          }
        }
        updateTransferTaskProgress(
          id: transferId,
          transferredBytes: totalBytes,
          totalBytes: totalBytes,
          speedBytesPerSec: Double(totalBytes) / max(0.2, Date().timeIntervalSince1970 - startTime),
          status: .completed,
          detail: "✓ 已直传至 115 网盘"
        )

      case .server:
        // Always save a copy to Apple TV local cache first so it can be served or played immediately
        let cacheRelPath = TvRemoteStorageClient.joinPath("/", fileName)
        let cacheUrl = Self.resolveLocalOfflineUrl(relativePath: cacheRelPath)
        try? fileData.write(to: cacheUrl, options: .atomic)
        if !lanInputRunning {
          startLanInputServer()
        }
        try await api.uploadDataToServerDirectory(
          fileData: fileData,
          fileName: fileName,
          targetDir: dir,
          lanBaseUrl: lanInputUrl
        ) { sent, total in
          let elapsed = max(0.15, Date().timeIntervalSince1970 - startTime)
          Task { @MainActor [weak self] in
            self?.updateTransferTaskProgress(
              id: transferId,
              transferredBytes: sent,
              totalBytes: total,
              speedBytesPerSec: Double(sent) / elapsed,
              status: .running,
              detail: "正在上传至流光服务端..."
            )
          }
        }
        updateTransferTaskProgress(
          id: transferId,
          transferredBytes: totalBytes,
          totalBytes: totalBytes,
          speedBytesPerSec: Double(totalBytes) / max(0.2, Date().timeIntervalSince1970 - startTime),
          status: .completed,
          detail: "✓ 已上传至流光服务端并缓存至本机",
          localSavedPath: cacheRelPath
        )
      }

      showToast("✅ 上传完成：\(fileName)")
      if activeStorageMount.id == mount.id {
        await loadFiles(path: fileListing.path)
      }
      return true
    } catch {
      updateTransferTaskProgress(
        id: transferId,
        transferredBytes: 0,
        totalBytes: totalBytes,
        speedBytesPerSec: 0,
        status: .failed,
        detail: "上传失败：\(error.localizedDescription)"
      )
      showToast("⚠️ 上传失败：\(error.localizedDescription)")
      return false
    }
  }

  /// Cross-mount upload: downloads file from source mount if remote, then uploads it to `targetMount` (e.g. AList / WebDAV / Server) with live progress
  func startCrossMountUploadWithProgress(
    entry: TvFileEntry,
    targetMount: TvStorageMount,
    targetDir: String
  ) {
    let transferId = "xup_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(4))"
    let sourceMount = storageMounts.first(where: { $0.id == entry.mountId }) ?? activeStorageMount
    let task = TvFileTransferTask(
      id: transferId,
      name: entry.name,
      direction: .upload,
      sourceLabel: sourceMount.name,
      targetLabel: targetMount.name,
      totalBytes: max(0, entry.size),
      transferredBytes: 0,
      speedBytesPerSec: 0,
      status: .running,
      detailMessage: "正在准备跨源上传...",
      localSavedPath: nil,
      createdAt: Date()
    )
    fileTransferTasks.insert(task, at: 0)
    showToast("⬆️ 开始上传「\(entry.name)」至 \(targetMount.name)")

    Task {
      do {
        let fileData: Data
        if entry.sourceKind == .localCache {
          let localUrl = Self.resolveLocalOfflineUrl(relativePath: entry.path)
          fileData = try Data(contentsOf: localUrl)
        } else {
          self.updateTransferTaskProgress(
            id: transferId,
            transferredBytes: 0,
            totalBytes: entry.size,
            speedBytesPerSec: 0,
            status: .running,
            detail: "阶段 1/2 · 正在读取源文件数据..."
          )
          let resolved = try await self.resolveFileStreamEndpoint(entry)
          guard let u = URL(string: resolved.url) else {
            throw NSError(domain: "TvCrossUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: "源文件地址无效"])
          }
          var req = URLRequest(url: u)
          for (k, v) in resolved.headers {
            req.setValue(v, forHTTPHeaderField: k)
          }
          let tmpUrl = FileManager.default.temporaryDirectory.appendingPathComponent("xup_\(UUID().uuidString)")
          let startDl = Date().timeIntervalSince1970
          _ = try await TvStreamingHttpTransfer.shared.downloadToFile(
            transferId: transferId,
            request: req,
            destinationUrl: tmpUrl,
            expectedSizeHint: entry.size
          ) { rec, tot in
            let elapsed = max(0.15, Date().timeIntervalSince1970 - startDl)
            Task { @MainActor [weak self] in
              self?.updateTransferTaskProgress(
                id: transferId,
                transferredBytes: rec / 2,
                totalBytes: tot,
                speedBytesPerSec: Double(rec) / elapsed,
                status: .running,
                detail: "阶段 1/2 · 正在拉取源文件..."
              )
            }
          }
          fileData = try Data(contentsOf: tmpUrl)
          try? FileManager.default.removeItem(at: tmpUrl)
        }

        _ = await self.uploadRawDataToMountWithProgress(
          transferId: transferId,
          fileName: entry.name,
          fileData: fileData,
          targetMount: targetMount,
          targetDir: targetDir,
          sourceLabel: sourceMount.name
        )
      } catch {
        self.updateTransferTaskProgress(
          id: transferId,
          transferredBytes: 0,
          totalBytes: entry.size,
          speedBytesPerSec: 0,
          status: .failed,
          detail: "上传失败：\(error.localizedDescription)"
        )
      }
    }
  }

  /// Creates a remote URL / Magnet / M3U8 download task and tracks its progress in `fileTransferTasks`
  func startRemoteUrlDownloadToServerWithProgress(url: String, customName: String = "") {
    let cleanUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanUrl.isEmpty else { return }
    let fileName: String = {
      let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
      let last = (URL(string: cleanUrl)?.lastPathComponent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      return last.isEmpty ? "离线下载_\(Int(Date().timeIntervalSince1970))" : last
    }()

    // If current active mount is Apple TV Local Cache and URL is a direct HTTP file (not m3u8/magnet), download directly to Apple TV with byte progress
    if activeStorageMount.kind == .localCache && cleanUrl.lowercased().hasPrefix("http") && !cleanUrl.lowercased().contains(".m3u8") {
      let pseudoEntry = TvFileEntry(
        name: fileName,
        path: cleanUrl,
        size: 0,
        modTime: "",
        isDir: false,
        isMp4: fileName.lowercased().hasSuffix(".mp4"),
        ext: ".\((fileName as NSString).pathExtension.lowercased())",
        mountId: "builtin_local",
        sourceKind: .alist,
        rawDownloadUrl: cleanUrl
      )
      startDownloadFileWithProgress(pseudoEntry, targetSubfolder: fileListing.path)
      return
    }

    let transferId = "remdl_\(Int(Date().timeIntervalSince1970 * 1000))"
    let task = TvFileTransferTask(
      id: transferId,
      name: fileName,
      direction: .download,
      sourceLabel: "远程链接",
      targetLabel: "流光服务端媒体库",
      totalBytes: 100,
      transferredBytes: 0,
      speedBytesPerSec: 0,
      status: .running,
      detailMessage: "正在提交服务端高速离线下载任务...",
      localSavedPath: nil,
      createdAt: Date()
    )
    fileTransferTasks.insert(task, at: 0)
    showToast("⬇️ 已提交离线下载：\(fileName)")

    Task {
      do {
        let serverTaskId = try await self.api.createDownloadTask(url: cleanUrl, name: fileName)
        for _ in 0..<600 {
          try? await Task.sleep(nanoseconds: 1_200_000_000)
          let tasks = await self.api.fetchDownloadTasks()
          self.downloadTasks = tasks
          guard let t = tasks.first(where: { $0.id == serverTaskId || $0.name == fileName || $0.url == cleanUrl }) else {
            break
          }
          let pct = Int64(max(0, min(100, t.progress)))
          if t.status == "Completed" || t.status == "Duplicate" {
            self.updateTransferTaskProgress(
              id: transferId,
              transferredBytes: 100,
              totalBytes: 100,
              speedBytesPerSec: t.speed,
              status: .completed,
              detail: "✓ 服务端离线下载已完成"
            )
            self.showToast("✅ 离线下载完成：\(fileName)")
            if self.activeStorageMount.kind == .server {
              await self.loadFiles(path: self.fileListing.path)
            }
            return
          } else if t.status == "Failed" {
            throw NSError(domain: "TvRemoteDl", code: -1, userInfo: [NSLocalizedDescriptionKey: t.error.isEmpty ? "下载失败" : t.error])
          } else {
            let seg = t.totalSegments > 0 ? " · 分片 \(t.downloadedSegments)/\(t.totalSegments)" : ""
            self.updateTransferTaskProgress(
              id: transferId,
              transferredBytes: pct,
              totalBytes: 100,
              speedBytesPerSec: t.speed,
              status: .running,
              detail: "服务端\(t.statusLabel) \(String(format: "%.1f%%", t.progress))\(seg)"
            )
          }
        }
      } catch {
        self.updateTransferTaskProgress(
          id: transferId,
          transferredBytes: 0,
          totalBytes: 100,
          speedBytesPerSec: 0,
          status: .failed,
          detail: "离线下载失败：\(error.localizedDescription)"
        )
        self.showToast("⚠️ 离线下载失败：\(error.localizedDescription)")
      }
    }
  }

  // MARK: - 8. Multi-Subscription Proxy Management & 6-Scenario Routing (1:1 Parity with ProxyRoutingService)

  private func persistProxyState() {
    defaults.set(proxyEnabled, forKey: "tv_proxy_enabled")
    defaults.set(proxySelectionMode.rawValue, forKey: "tv_proxy_selection_mode")
    defaults.set(selectedProxyNodeId, forKey: "tv_selected_proxy_node_id")
    if let firstEnabled = subscriptions.first(where: { $0.enabled }) ?? subscriptions.first {
      subscriptionUrl = firstEnabled.url
      defaults.set(firstEnabled.url, forKey: "tv_sub_url")
    }
    if let subData = try? JSONEncoder().encode(subscriptions) {
      defaults.set(subData, forKey: "tv_proxy_subscriptions_v2")
    }
    if let nodeData = try? JSONEncoder().encode(subscriptionNodes) {
      defaults.set(nodeData, forKey: "tv_proxy_nodes_v2")
    }
    let rulesArr = TvRequestScenario.allCases.map { rule(for: $0) }
    if let rulesData = try? JSONEncoder().encode(rulesArr) {
      defaults.set(rulesData, forKey: "tv_proxy_scenario_rules_v2")
    }
  }

  /// Enabled subscription IDs
  var enabledSubscriptionIds: Set<String> {
    Set(subscriptions.filter(\.enabled).map(\.id))
  }

  /// Nodes belonging to enabled subscriptions (or manual / server nodes)
  var activePoolNodes: [TvSubscriptionNode] {
    let enabledIds = enabledSubscriptionIds
    return subscriptionNodes.filter { n in
      if n.subscriptionId == "manual" || n.subscriptionId == "server" { return true }
      if subscriptions.isEmpty { return true }
      return enabledIds.contains(n.subscriptionId)
    }
  }

  /// Lowest latency supported node in active pool
  var fastestProxyNode: TvSubscriptionNode? {
    let pool = activePoolNodes.filter(\.isSupportedByClientTunnel)
    let available = pool.filter { ($0.latencyMs ?? 9999) > 0 && ($0.latencyMs ?? 9999) < 9000 }
    if let best = available.min(by: { ($0.latencyMs ?? 9999) < ($1.latencyMs ?? 9999) }) {
      return best
    }
    return pool.first ?? activePoolNodes.first
  }

  /// Currently active global proxy node (respecting `autoFastest` vs `manual`)
  var activeProxyNode: TvSubscriptionNode? {
    let pool = activePoolNodes
    guard !pool.isEmpty else { return subscriptionNodes.first }
    if proxySelectionMode == .manual,
       !selectedProxyNodeId.isEmpty {
      if let matched = pool.first(where: { $0.id == selectedProxyNodeId }) {
        return matched
      }
      if let anyMatched = subscriptionNodes.first(where: { $0.id == selectedProxyNodeId }) {
        return anyMatched
      }
    }
    if let fastest = fastestProxyNode {
      return fastest
    }
    if !selectedProxyNodeId.isEmpty,
       let matched = pool.first(where: { $0.id == selectedProxyNodeId }) {
      return matched
    }
    return pool.first(where: \.isSupportedByClientTunnel) ?? pool.first
  }

  func setProxyEnabled(_ enabled: Bool) {
    proxyEnabled = enabled
    if !enabled {
      for sc in TvRequestScenario.allCases {
        if var r = scenarioRules[sc], r.mode == .proxyNode {
          r.mode = .followGlobal
          r.specificNodeId = nil
          scenarioRules[sc] = r
        }
      }
      vodRouteMode = .direct
      liveRouteMode = .direct
      telegramRouteMode = .direct
      TvLocalProxyTunnelServer.shared.configure(node: nil, enabled: false)
      TvLocalProxyTunnelServer.shared.seedFallbackNode(nil, backupNodes: [])
    } else if let node = activeProxyNode {
      let backups = activePoolNodes
        .filter(\.isSupportedByClientTunnel)
        .sorted { ($0.latencyMs ?? 9999) < ($1.latencyMs ?? 9999) }
      TvLocalProxyTunnelServer.shared.seedFallbackNode(node, backupNodes: backups)
      TvLocalProxyTunnelServer.shared.configure(node: node, enabled: true)
    }
    persistProxyState()
    showToast(enabled ? "⚡ 全局代理已开启" : "🌐 已彻底关闭全局代理，所有请求与视频流已恢复直连")
  }

  func setProxySelectionMode(_ mode: TvProxySelectionMode) {
    proxySelectionMode = mode
    if mode == .autoFastest, let fastest = fastestProxyNode {
      selectedProxyNodeId = fastest.id
    } else if selectedProxyNodeId.isEmpty, let first = activePoolNodes.first {
      selectedProxyNodeId = first.id
    }
    persistProxyState()
    if mode == .autoFastest, let best = activeProxyNode {
      showToast("⚡ 已切换为自动择优：\(best.displayTitle) (\(best.formattedLatency))")
    } else if mode == .manual, let cur = activeProxyNode {
      showToast("🎯 已切换为手动指定节点：\(cur.displayTitle)")
    }
  }

  private func syncManualNodeSelectionAcrossRules(_ node: TvSubscriptionNode) {
    selectedProxyNodeId = node.id
    proxySelectionMode = .manual
    proxyEnabled = true
    if let subIdx = subscriptions.firstIndex(where: { $0.id == node.subscriptionId }), !subscriptions[subIdx].enabled {
      subscriptions[subIdx].enabled = true
    }
    for sc in TvRequestScenario.allCases {
      if var r = scenarioRules[sc], let spec = r.specificNodeId, !spec.isEmpty, spec != node.id {
        r.specificNodeId = node.id
        scenarioRules[sc] = r
      }
    }
    TvLocalProxyTunnelServer.shared.configure(node: node, enabled: true)
    persistProxyState()
  }

  func selectManualNode(_ nodeId: String) {
    guard let node = subscriptionNodes.first(where: { $0.id == nodeId }) else { return }
    syncManualNodeSelectionAcrossRules(node)
    Task {
      let ms = await Self.tcpPing(host: node.host, port: node.port)
      if let idx = subscriptionNodes.firstIndex(where: { $0.id == node.id }) {
        subscriptionNodes[idx].latencyMs = ms
        persistProxyState()
      }
      let latStr = ms >= 9999 ? "超时" : "\(ms) ms"
      showToast("🎯 已锁定代理节点：\(node.displayTitle) (\(latStr))")
    }
  }

  func selectAndTestProxyNode(_ node: TvSubscriptionNode) async {
    syncManualNodeSelectionAcrossRules(node)
    let ms = await Self.tcpPing(host: node.host, port: node.port)
    if let idx = subscriptionNodes.firstIndex(where: { $0.id == node.id }) {
      subscriptionNodes[idx].latencyMs = ms
    }
    persistProxyState()
    let latStr = ms >= 9999 ? "超时" : "\(ms) ms"
    showToast("🎯 已锁定代理节点：\(node.displayTitle) (\(latStr))")
  }

  // MARK: - Multi-Subscription CRUD & Refresh

  @discardableResult
  func upsertSubscription(
    id: String? = nil,
    name: String,
    url: String,
    enabled: Bool = true,
    autoUpdateHours: Int = 24
  ) -> TvProxySubscription? {
    let normalizedUrl = Self.normalizeSubscriptionInput(url)
    guard !normalizedUrl.isEmpty else { return nil }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedName: String = {
      if !trimmedName.isEmpty { return trimmedName }
      if let host = URL(string: normalizedUrl)?.host, !host.isEmpty {
        return "机场订阅 (\(host))"
      }
      return "机场订阅 \(subscriptions.count + 1)"
    }()

    if let editId = id, let idx = subscriptions.firstIndex(where: { $0.id == editId }) {
      subscriptions[idx].name = resolvedName
      subscriptions[idx].url = normalizedUrl
      subscriptions[idx].enabled = enabled
      subscriptions[idx].autoUpdateHours = autoUpdateHours
      for nIdx in subscriptionNodes.indices where subscriptionNodes[nIdx].subscriptionId == editId {
        subscriptionNodes[nIdx].subscriptionName = resolvedName
      }
      persistProxyState()
      return subscriptions[idx]
    }

    if let existingIdx = subscriptions.firstIndex(where: { $0.url == normalizedUrl }) {
      if !trimmedName.isEmpty {
        subscriptions[existingIdx].name = resolvedName
      }
      subscriptions[existingIdx].enabled = true
      persistProxyState()
      return subscriptions[existingIdx]
    }

    let newSub = TvProxySubscription(
      name: resolvedName,
      url: normalizedUrl,
      enabled: enabled,
      autoUpdateHours: autoUpdateHours
    )
    subscriptions.append(newSub)

    var hist = subscriptionHistory.filter { $0 != normalizedUrl }
    hist.insert(normalizedUrl, at: 0)
    if hist.count > 12 { hist = Array(hist.prefix(12)) }
    subscriptionHistory = hist
    defaults.set(hist, forKey: "tv_sub_history")

    persistProxyState()
    return newSub
  }

  func toggleSubscriptionEnabled(_ id: String) {
    guard let idx = subscriptions.firstIndex(where: { $0.id == id }) else { return }
    subscriptions[idx].enabled.toggle()
    let sub = subscriptions[idx]
    if !sub.enabled && selectedProxyNodeId.hasPrefix(sub.id) {
      selectedProxyNodeId = fastestProxyNode?.id ?? ""
    }
    persistProxyState()
    showToast(sub.enabled ? "✓ 已启用订阅：\(sub.name)" : "已停用订阅：\(sub.name)")
  }

  func deleteSubscription(_ id: String) {
    let removedName = subscriptions.first(where: { $0.id == id })?.name ?? "订阅"
    subscriptions.removeAll { $0.id == id }
    subscriptionNodes.removeAll { $0.subscriptionId == id }
    if !subscriptionNodes.contains(where: { $0.id == selectedProxyNodeId }) {
      selectedProxyNodeId = fastestProxyNode?.id ?? ""
    }
    persistProxyState()
    showToast("已删除订阅「\(removedName)」及其关联节点")
  }

  func refreshSubscription(_ id: String, silent: Bool = false) async {
    guard let idx = subscriptions.firstIndex(where: { $0.id == id }) else { return }
    let sub = subscriptions[idx]
    updatingSubscriptionId = id
    isRefreshingSubscription = true
    defer {
      if updatingSubscriptionId == id {
        updatingSubscriptionId = nil
      }
      isRefreshingSubscription = false
    }

    let res = await api.fetchSubscriptionDetail(urlStr: sub.url, subId: sub.id, subName: sub.name)
    guard let curIdx = subscriptions.firstIndex(where: { $0.id == id }) else { return }

    if !res.nodes.isEmpty {
      // Preserve favorites for matching host+port
      let oldFavKeys = Set(
        subscriptionNodes
          .filter { $0.subscriptionId == id && $0.favorite }
          .map { "\($0.type)_\($0.host)_\($0.port)" }
      )
      var freshNodes = res.nodes.map { n -> TvSubscriptionNode in
        var copy = n
        if oldFavKeys.contains("\(n.type)_\(n.host)_\(n.port)") {
          copy.favorite = true
        }
        return copy
      }

      // Ping the new nodes concurrently off MainActor
      freshNodes = await Self.pingNodesConcurrently(freshNodes, maxCount: 36)

      // Replace only this subscription's nodes while keeping other subscriptions' nodes intact!
      var merged = subscriptionNodes.filter { $0.subscriptionId != id }
      merged.append(contentsOf: freshNodes)
      merged.sort { a, b in
        if a.favorite != b.favorite { return a.favorite && !b.favorite }
        return (a.latencyMs ?? 9999) < (b.latencyMs ?? 9999)
      }
      self.subscriptionNodes = merged

      subscriptions[curIdx].nodeCount = freshNodes.count
      subscriptions[curIdx].lastUpdatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
      subscriptions[curIdx].uploadBytes = res.uploadBytes ?? subscriptions[curIdx].uploadBytes
      subscriptions[curIdx].downloadBytes = res.downloadBytes ?? subscriptions[curIdx].downloadBytes
      subscriptions[curIdx].totalBytes = res.totalBytes ?? subscriptions[curIdx].totalBytes
      subscriptions[curIdx].expireTimestampSec = res.expireTimestampSec ?? subscriptions[curIdx].expireTimestampSec
      subscriptions[curIdx].lastError = nil

      if proxySelectionMode == .autoFastest || selectedProxyNodeId.isEmpty || !merged.contains(where: { $0.id == selectedProxyNodeId }) {
        if let best = fastestProxyNode {
          selectedProxyNodeId = best.id
        }
      }
      if let best = fastestProxyNode ?? activeProxyNode {
        let backups = activePoolNodes
          .filter(\.isSupportedByClientTunnel)
          .sorted { ($0.latencyMs ?? 9999) < ($1.latencyMs ?? 9999) }
        TvLocalProxyTunnelServer.shared.seedFallbackNode(best, backupNodes: backups)
      }
      persistProxyState()
      if !silent {
        showToast("✓ 「\(sub.name)」已更新 \(freshNodes.count) 个节点并完成测速")
      }
    } else {
      let errMsg = res.error ?? "未解析到有效代理节点"
      subscriptions[curIdx].lastError = errMsg
      persistProxyState()
      if !silent {
        showToast("⚠️ 「\(sub.name)」更新失败：\(errMsg)")
      }
    }
  }

  func refreshAllSubscriptions(silent: Bool = false) async {
    guard !isRefreshingSubscription else { return }
    let backend = await api.fetchProxyConfig()
    self.backendProxyServices = backend.services
    self.backendProxyStatuses = backend.statuses

    let enabledSubs = subscriptions.filter { $0.enabled && !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    if enabledSubs.isEmpty {
      if !subscriptionUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if let created = upsertSubscription(name: "默认订阅", url: subscriptionUrl, enabled: true) {
          await refreshSubscription(created.id, silent: silent)
        }
      } else if !backendProxyServices.isEmpty {
        await syncNodesFromBackendServer(silent: silent)
      }
      return
    }

    for sub in enabledSubs {
      await refreshSubscription(sub.id, silent: true)
    }

    if subscriptionNodes.isEmpty && !backendProxyServices.isEmpty {
      await syncNodesFromBackendServer(silent: true)
    }

    if !silent {
      if let best = activeProxyNode {
        showToast("⚡ 已更新 \(enabledSubs.count) 个订阅源（共 \(subscriptionNodes.count) 节点），当前最优：\(best.displayTitle) (\(best.formattedLatency))")
      } else {
        showToast("已尝试更新 \(enabledSubs.count) 个订阅源")
      }
    }
  }

  func refreshProxyData() async {
    await refreshAllSubscriptions(silent: false)
  }

  func testAllNodesLatency() async {
    guard !isRefreshingSubscription, !subscriptionNodes.isEmpty else { return }
    isRefreshingSubscription = true
    defer { isRefreshingSubscription = false }
    let pinged = await Self.pingNodesConcurrently(subscriptionNodes, maxCount: 48)
    self.subscriptionNodes = pinged
    if proxySelectionMode == .autoFastest, let best = fastestProxyNode {
      selectedProxyNodeId = best.id
    }
    persistProxyState()
    if let best = activeProxyNode {
      showToast("⚡ 全部节点测速完成！最快节点：\(best.displayTitle) (\(best.formattedLatency))")
    } else {
      showToast("✓ 节点测速完成")
    }
  }

  func testSingleNodeLatency(_ nodeId: String) async {
    guard let idx = subscriptionNodes.firstIndex(where: { $0.id == nodeId }) else { return }
    let node = subscriptionNodes[idx]
    let ms = await Self.tcpPing(host: node.host, port: node.port)
    if let curIdx = subscriptionNodes.firstIndex(where: { $0.id == nodeId }) {
      subscriptionNodes[curIdx].latencyMs = ms
      persistProxyState()
    }
    let latStr = ms >= 9999 ? "超时" : "\(ms) ms"
    showToast("测速结果：\(node.displayTitle) → \(latStr)")
  }

  func importManualNodesFromText(_ rawText: String) async -> Int {
    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return 0 }
    var parsed = TvApiClient.parseSubscriptionText(trimmed, subId: "manual", subName: "手动导入")
    guard !parsed.isEmpty else { return 0 }
    parsed = await Self.pingNodesConcurrently(parsed, maxCount: 24)
    var merged = subscriptionNodes
    var added = 0
    for node in parsed {
      if !merged.contains(where: { $0.type == node.type && $0.host == node.host && $0.port == node.port }) {
        merged.append(node)
        added += 1
      }
    }
    merged.sort { ($0.latencyMs ?? 9999) < ($1.latencyMs ?? 9999) }
    self.subscriptionNodes = merged
    if selectedProxyNodeId.isEmpty, let first = merged.first {
      selectedProxyNodeId = first.id
    }
    persistProxyState()
    showToast("✓ 成功导入 \(added) 个代理节点并完成测速")
    return added
  }

  func addManualProxyNode(name: String, proto: String, host: String, port: Int) async {
    let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanHost.isEmpty, port > 0 && port <= 65535 else { return }
    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "\(proto.uppercased()) \(cleanHost):\(port)"
      : name.trimmingCharacters(in: .whitespacesAndNewlines)
    var node = TvSubscriptionNode(
      id: "manual_\(proto.uppercased())_\(cleanHost)_\(port)",
      name: cleanName,
      type: proto.uppercased(),
      host: cleanHost,
      port: port,
      subscriptionId: "manual",
      subscriptionName: "手动添加",
      rawUri: "\(proto.lowercased())://\(cleanHost):\(port)#\(cleanName)"
    )
    node.latencyMs = await Self.tcpPing(host: cleanHost, port: port)
    subscriptionNodes.removeAll { $0.id == node.id }
    subscriptionNodes.insert(node, at: 0)
    selectedProxyNodeId = node.id
    persistProxyState()
    showToast("✓ 已添加节点：\(node.displayTitle) (\(node.formattedLatency))")
  }

  @discardableResult
  func removeTimeoutNodes() -> Int {
    let before = subscriptionNodes.count
    subscriptionNodes.removeAll { ($0.latencyMs ?? 0) >= 9000 && !$0.favorite }
    let removed = max(0, before - subscriptionNodes.count)
    if !subscriptionNodes.contains(where: { $0.id == selectedProxyNodeId }) {
      selectedProxyNodeId = fastestProxyNode?.id ?? ""
    }
    persistProxyState()
    showToast(removed > 0 ? "🧹 已清理 \(removed) 个超时不可用节点" : "当前没有超时节点需要清理")
    return removed
  }

  func toggleNodeFavorite(_ nodeId: String) {
    guard let idx = subscriptionNodes.firstIndex(where: { $0.id == nodeId }) else { return }
    subscriptionNodes[idx].favorite.toggle()
    let isFav = subscriptionNodes[idx].favorite
    let title = subscriptionNodes[idx].displayTitle
    subscriptionNodes.sort { a, b in
      if a.favorite != b.favorite { return a.favorite && !b.favorite }
      return (a.latencyMs ?? 9999) < (b.latencyMs ?? 9999)
    }
    persistProxyState()
    showToast(isFav ? "★ 已收藏节点：\(title)" : "已取消收藏：\(title)")
  }

  func deleteNode(_ nodeId: String) {
    let removed = subscriptionNodes.first(where: { $0.id == nodeId })?.displayTitle ?? "节点"
    subscriptionNodes.removeAll { $0.id == nodeId }
    if selectedProxyNodeId == nodeId {
      selectedProxyNodeId = fastestProxyNode?.id ?? ""
    }
    persistProxyState()
    showToast("已移除节点：\(removed)")
  }

  // MARK: - 6-Scenario Routing Rules & In-Player Quick Selector (1:1 Parity with ProxyRoutingService & VideoProxyNodeSelector)

  func rule(for scenario: TvRequestScenario) -> TvScenarioRuleConfig {
    scenarioRules[scenario] ?? TvScenarioRuleConfig(scenario: scenario, mode: .followGlobal)
  }

  func updateScenarioRule(
    _ scenario: TvRequestScenario,
    mode: TvScenarioRouteMode? = nil,
    specificNodeId: String? = nil,
    clearSpecificNode: Bool = false
  ) {
    var current = rule(for: scenario)
    if let m = mode {
      current.mode = m
    }
    if clearSpecificNode {
      current.specificNodeId = nil
    } else if let nid = specificNodeId {
      current.specificNodeId = nid.isEmpty ? nil : nid
    }
    scenarioRules[scenario] = current

    // Keep legacy route mode properties synchronized (only set `.serverRelay` when explicitly requested!)
    switch scenario {
    case .vodStream:
      vodRouteMode = (current.mode == .serverRelay) ? .serverRelay : .direct
      defaults.set(vodRouteMode.rawValue, forKey: "tv_route_vod")
    case .liveStream:
      liveRouteMode = (current.mode == .serverRelay) ? .serverRelay : .direct
      defaults.set(liveRouteMode.rawValue, forKey: "tv_route_live")
    case .telegram:
      telegramRouteMode = (current.mode == .serverRelay) ? .serverRelay : .direct
      defaults.set(telegramRouteMode.rawValue, forKey: "tv_route_tg")
    default:
      break
    }
    persistProxyState()
  }

  func applyScenarioPreset(_ preset: String) {
    switch preset {
    case "smart_recommended":
      proxyEnabled = true
      proxySelectionMode = .autoFastest
      scenarioRules[.vodApi] = TvScenarioRuleConfig(scenario: .vodApi, mode: .direct)
      scenarioRules[.vodStream] = TvScenarioRuleConfig(scenario: .vodStream, mode: .direct)
      scenarioRules[.liveStream] = TvScenarioRuleConfig(scenario: .liveStream, mode: .direct)
      scenarioRules[.telegram] = TvScenarioRuleConfig(scenario: .telegram, mode: .proxyNode)
      scenarioRules[.backendApi] = TvScenarioRuleConfig(scenario: .backendApi, mode: .direct)
      scenarioRules[.externalWeb] = TvScenarioRuleConfig(scenario: .externalWeb, mode: .smartAuto)
      vodRouteMode = .direct
      liveRouteMode = .direct
      telegramRouteMode = .direct
      showToast("🚀 已应用「推荐智能分流」：海外/TG 走代理 · 国内点播/直播直连")

    case "follow_global":
      for sc in TvRequestScenario.allCases {
        scenarioRules[sc] = TvScenarioRuleConfig(scenario: sc, mode: .followGlobal)
      }
      vodRouteMode = .direct
      liveRouteMode = .direct
      telegramRouteMode = .direct
      showToast("🔄 已将全部 6 个场景设为「跟随全局开关」")

    case "telegram_only":
      proxyEnabled = true
      for sc in TvRequestScenario.allCases {
        let m: TvScenarioRouteMode = (sc == .telegram || sc == .externalWeb) ? .proxyNode : .direct
        scenarioRules[sc] = TvScenarioRuleConfig(scenario: sc, mode: m)
      }
      vodRouteMode = .direct
      liveRouteMode = .direct
      telegramRouteMode = .direct
      showToast("✈️ 已设为「仅 Telegram 与订阅走代理」")

    case "all_proxy":
      proxyEnabled = true
      for sc in TvRequestScenario.allCases {
        scenarioRules[sc] = TvScenarioRuleConfig(scenario: sc, mode: sc == .backendApi ? .direct : .proxyNode)
      }
      vodRouteMode = .direct
      liveRouteMode = .direct
      telegramRouteMode = .direct
      showToast("🌐 已开启「全场景走代理节点」")

    case "server_relay":
      for sc in TvRequestScenario.allCases {
        let m: TvScenarioRouteMode = (sc == .vodStream || sc == .liveStream || sc == .vodApi) ? .serverRelay : .followGlobal
        scenarioRules[sc] = TvScenarioRuleConfig(scenario: sc, mode: m)
      }
      vodRouteMode = .serverRelay
      liveRouteMode = .serverRelay
      showToast("🛡️ 已将点播与直播设为「服务端中转 (/api/vod/proxy)」")

    default:
      break
    }
    persistProxyState()
  }

  /// Resolves the effective route mode for a scenario (matching `resolveEffectiveRoute` in `proxy_routing_service.dart`)
  /// Never automatically falls back to `.serverRelay` unless the user explicitly selected `.serverRelay`!
  func resolveEffectiveRoute(for scenario: TvRequestScenario) -> TvScenarioRouteMode {
    let r = rule(for: scenario)
    if r.mode == .direct {
      return .direct
    }
    if r.mode == .serverRelay {
      return .serverRelay
    }
    // Master global proxy switch: when disabled, NEVER route through any client proxy node!
    if !proxyEnabled {
      return .direct
    }
    switch r.mode {
    case .direct:
      return .direct
    case .serverRelay:
      return .serverRelay
    case .proxyNode:
      return activePoolNodes.isEmpty ? .direct : .proxyNode
    case .smartAuto:
      if scenario == .telegram || scenario == .externalWeb {
        return activePoolNodes.isEmpty ? .direct : .proxyNode
      }
      return .direct
    case .followGlobal:
      return activePoolNodes.isEmpty ? .direct : .proxyNode
    }
  }

  /// Resolves the specific or global proxy node for a scenario
  func resolveNode(for scenario: TvRequestScenario) -> TvSubscriptionNode? {
    let r = rule(for: scenario)
    if let specId = r.specificNodeId,
       !specId.isEmpty,
       let found = subscriptionNodes.first(where: { $0.id == specId }) {
      return found
    }
    return activeProxyNode
  }

  /// Returns true when the scenario should route through proxy/relay
  func shouldUseProxyOrRelay(for scenario: TvRequestScenario) -> Bool {
    let eff = resolveEffectiveRoute(for: scenario)
    return eff == .proxyNode || eff == .serverRelay
  }

  /// Returns true ONLY when the scenario explicitly requests Server Relay (`/api/vod/proxy`)
  func shouldUseServerRelay(for scenario: TvRequestScenario) -> Bool {
    rule(for: scenario).mode == .serverRelay
  }

  /// Builds the concise status badge text for video player proxy selector buttons (matching `VideoProxyNodeSelector._buildTriggerContent`)
  func buildProxyControlLabel(for scenario: TvRequestScenario, compact: Bool = true) -> String {
    let eff = resolveEffectiveRoute(for: scenario)
    switch eff {
    case .direct:
      return "直连"
    case .serverRelay:
      return "服务端中转"
    case .proxyNode, .smartAuto, .followGlobal:
      if let node = resolveNode(for: scenario) {
        let shortName = node.name.count > (compact ? 8 : 14)
          ? "\(node.name.prefix(compact ? 8 : 14))…"
          : node.name
        if let ms = node.latencyMs, ms > 0 && ms < 9000 {
          return "\(node.regionFlag)\(shortName) \(ms)ms"
        }
        return "\(node.regionFlag)\(shortName)"
      }
      return "代理自动"
    }
  }

  /// Configures `TvLocalProxyTunnelServer.shared` for the given scenario's effective route & node
  func activateScenarioProxyTunnel(for scenario: TvRequestScenario) {
    let eff = resolveEffectiveRoute(for: scenario)
    let fallbackNode = resolveNode(for: scenario) ?? fastestProxyNode ?? activeProxyNode
    let backups = activePoolNodes
      .filter(\.isSupportedByClientTunnel)
      .sorted { ($0.latencyMs ?? 9999) < ($1.latencyMs ?? 9999) }
    TvLocalProxyTunnelServer.shared.seedFallbackNode(fallbackNode, backupNodes: backups)
    if eff == .proxyNode, let node = fallbackNode {
      TvLocalProxyTunnelServer.shared.configure(node: node, enabled: true)
    } else {
      TvLocalProxyTunnelServer.shared.configure(node: nil, enabled: false)
    }
  }

  /// Handles selection from `TvVideoProxyNodeSelectorSheet` (matching `_onSelected` in `lib/ui/widgets/video_proxy_node_selector.dart`)
  func applyInPlayerProxyChoice(scenario: TvRequestScenario, choice: String) {
    if choice == "direct" {
      updateScenarioRule(scenario, mode: .direct, clearSpecificNode: true)
      activateScenarioProxyTunnel(for: scenario)
      showToast("🚫 「\(scenario.label)」已切换为直连播放")
    } else if choice == "auto_fastest" {
      proxyEnabled = true
      proxySelectionMode = .autoFastest
      if let best = fastestProxyNode {
        selectedProxyNodeId = best.id
      }
      updateScenarioRule(scenario, mode: .proxyNode, clearSpecificNode: true)
      activateScenarioProxyTunnel(for: scenario)
      let bestLabel = fastestProxyNode.map { "\($0.displayTitle) (\($0.formattedLatency))" } ?? "自动最快"
      showToast("⚡ 「\(scenario.label)」已切换为自动择优：\(bestLabel)")
    } else if choice == "server_relay" {
      updateScenarioRule(scenario, mode: .serverRelay, clearSpecificNode: true)
      activateScenarioProxyTunnel(for: scenario)
      showToast("🛡️ 「\(scenario.label)」已切换为服务端代理中转")
    } else if choice.hasPrefix("node:") {
      let nodeId = String(choice.dropFirst(5))
      proxyEnabled = true
      proxySelectionMode = .manual
      selectedProxyNodeId = nodeId
      updateScenarioRule(scenario, mode: .proxyNode, specificNodeId: nodeId)
      activateScenarioProxyTunnel(for: scenario)
      if let node = subscriptionNodes.first(where: { $0.id == nodeId }) {
        showToast("🎯 「\(scenario.label)」已切换至节点：\(node.displayTitle) (\(node.formattedLatency))")
        if (node.latencyMs ?? 9999) >= 9999 {
          Task {
            let ms = await Self.tcpPing(host: node.host, port: node.port)
            if let idx = subscriptionNodes.firstIndex(where: { $0.id == nodeId }) {
              subscriptionNodes[idx].latencyMs = ms
              persistProxyState()
            }
          }
        }
      }
    }
  }

  nonisolated private static func pingNodesConcurrently(_ input: [TvSubscriptionNode], maxCount: Int) async -> [TvSubscriptionNode] {
    var nodes = input
    guard !nodes.isEmpty else { return nodes }

    // Mark unsupported protocols (hysteria2, anytls, vless-reality) as 9999 immediately
    var supportedIndices: [Int] = []
    for idx in nodes.indices {
      if nodes[idx].isSupportedByClientTunnel {
        supportedIndices.append(idx)
      } else {
        nodes[idx].latencyMs = 9999
      }
    }

    let indicesToPing = Array(supportedIndices.prefix(max(maxCount, 64)))
    guard !indicesToPing.isEmpty else { return nodes }

    // Pre-warm DoH Real-IP cache once per unique host before concurrent pinging
    let uniqueHosts = Array(Set(indicesToPing.map { nodes[$0].host }))
    await withTaskGroup(of: Void.self) { group in
      for h in uniqueHosts {
        group.addTask {
          _ = await TvLocalProxyTunnelServer.resolveRealEntryIp(h)
        }
      }
    }

    let results: [(Int, Int)] = await withTaskGroup(of: (Int, Int).self) { group in
      for idx in indicesToPing {
        let host = nodes[idx].host
        let port = nodes[idx].port
        group.addTask {
          let ms = await Self.tcpPing(host: host, port: port)
          return (idx, ms)
        }
      }
      var collected: [(Int, Int)] = []
      for await pair in group {
        collected.append(pair)
      }
      return collected
    }

    for (idx, ms) in results where idx < nodes.count {
      nodes[idx].latencyMs = ms
    }
    nodes.sort { a, b in
      if a.favorite != b.favorite { return a.favorite && !b.favorite }
      if a.isSupportedByClientTunnel != b.isSupportedByClientTunnel {
        return a.isSupportedByClientTunnel && !b.isSupportedByClientTunnel
      }
      return (a.latencyMs ?? 9999) < (b.latencyMs ?? 9999)
    }
    return nodes
  }

  func syncNodesFromBackendServer(silent: Bool = false) async {
    guard !isRefreshingSubscription else { return }
    isRefreshingSubscription = true
    defer { isRefreshingSubscription = false }
    let backend = await api.fetchProxyConfig()
    self.backendProxyServices = backend.services
    self.backendProxyStatuses = backend.statuses
    let serverHost = URL(string: serverUrl)?.host ?? "127.0.0.1"
    var serverNodes: [TvSubscriptionNode] = []
    for (idx, svc) in backend.services.enumerated() where svc.enabled {
      let host = (svc.listenHost.isEmpty || svc.listenHost == "0.0.0.0" || svc.listenHost == "127.0.0.1" || svc.listenHost == "::")
        ? serverHost
        : svc.listenHost
      var authPrefix = ""
      if !svc.username.isEmpty || !svc.password.isEmpty {
        let u = svc.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? svc.username
        let p = svc.password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? svc.password
        authPrefix = "\(u):\(p)@"
      }
      let node = TvSubscriptionNode(
        id: "srv_\(idx)_\(svc.proto)_\(host)_\(svc.port)",
        name: svc.name.isEmpty ? "服务端 \(svc.proto.uppercased())" : svc.name,
        type: svc.proto.uppercased(),
        host: host,
        port: svc.port,
        subscriptionId: "server",
        subscriptionName: "流光服务端",
        rawUri: "\(svc.proto.lowercased())://\(authPrefix)\(host):\(svc.port)#\(svc.name)",
        latencyMs: nil
      )
      serverNodes.append(node)
    }
    serverNodes = await Self.pingNodesConcurrently(serverNodes, maxCount: 16)
    var merged = subscriptionNodes.filter { $0.subscriptionId != "server" }
    merged.insert(contentsOf: serverNodes, at: 0)
    merged.sort { a, b in
      if a.favorite != b.favorite { return a.favorite && !b.favorite }
      if a.isSupportedByClientTunnel != b.isSupportedByClientTunnel {
        return a.isSupportedByClientTunnel && !b.isSupportedByClientTunnel
      }
      return (a.latencyMs ?? 9999) < (b.latencyMs ?? 9999)
    }
    self.subscriptionNodes = merged
    if selectedProxyNodeId.isEmpty || !merged.contains(where: { $0.id == selectedProxyNodeId }),
       let first = fastestProxyNode ?? merged.first {
      selectedProxyNodeId = first.id
    }
    persistProxyState()
    if !silent {
      showToast(serverNodes.isEmpty ? "服务端暂未开启代理监听节点" : "✓ 已从服务端同步 \(serverNodes.count) 个代理节点并完成测速")
    }
  }

  // MARK: - 9. LAN Mobile QR Code Fast Input Server (Supports Adding Multiple Subscriptions & Node Links!)

  func startLanInputServer() {
    if lanInputRunning && !lanInputUrl.isEmpty { return }
    stopLanInputServer()

    let portNum: UInt16 = 18088
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    let listener: NWListener
    if let p = NWEndpoint.Port(rawValue: portNum),
       let l = try? NWListener(using: params, on: p) {
      listener = l
    } else if let l = try? NWListener(using: params) {
      listener = l
    } else {
      return
    }

    self.lanListener = listener

    listener.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        guard let self = self else { return }
        switch state {
        case .ready:
          let actualPort = listener.port?.rawValue ?? portNum
          let ip = Self.localLanIPv4Address() ?? "10.0.0.222"
          self.lanInputUrl = "http://\(ip):\(actualPort)"
          self.lanInputRunning = true
        case .failed, .cancelled:
          self.lanInputRunning = false
        default:
          break
        }
      }
    }

    listener.newConnectionHandler = { [weak self] conn in
      guard let self = self else { return }
      Self.handleLanHttpConnection(conn, appState: self)
    }

    listener.start(queue: .global(qos: .userInitiated))
  }

  func stopLanInputServer() {
    lanListener?.cancel()
    lanListener = nil
    lanInputRunning = false
  }

  func presentLanQuickInput(
    prompt: String,
    placeholder: String = "在此输入或粘贴内容...",
    onReceive: @escaping (String) -> Void
  ) {
    startLanInputServer()
    activeLanQuickInputPrompt = prompt
    activeLanQuickInputPlaceholder = placeholder
    activeLanQuickInputReceiver = onReceive
    showLanQuickInputModal = true
  }

  private nonisolated static func handleLanHttpConnection(_ conn: NWConnection, appState: TvAppState) {
    conn.start(queue: .global(qos: .userInitiated))

    final class LanStreamBuffer: @unchecked Sendable {
      var buffer = Data()
      var headerParsed = false
      var headerEndOffset = 0
      var contentLength = 0
      var method = ""
      var pathAndQuery = ""
      var headers: [String: String] = [:]
      var uploadTaskId: String? = nil
      var uploadFileName: String = "上传文件"
      var uploadStartedAt: TimeInterval = Date().timeIntervalSince1970
      var lastProgressTick: TimeInterval = 0
    }
    let state = LanStreamBuffer()

    @Sendable func readMore() {
      conn.receive(minimumIncompleteLength: 1, maximumLength: 262144) { data, _, isComplete, error in
        if let data = data, !data.isEmpty {
          state.buffer.append(data)

          if !state.headerParsed {
            let sep = Data("\r\n\r\n".utf8)
            if let range = state.buffer.range(of: sep) {
              state.headerParsed = true
              state.headerEndOffset = range.upperBound
              let headerData = state.buffer.subdata(in: 0..<range.lowerBound)
              let headerStr = String(data: headerData, encoding: .utf8) ?? ""
              let lines = headerStr.components(separatedBy: "\r\n")
              let firstParts = (lines.first ?? "").split(separator: " ")
              if firstParts.count >= 2 {
                state.method = String(firstParts[0]).uppercased()
                state.pathAndQuery = String(firstParts[1])
              }
              for line in lines.dropFirst() {
                if let colon = line.firstIndex(of: ":") {
                  let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                  let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                  state.headers[k] = v
                }
              }
              state.contentLength = Int(state.headers["content-length"] ?? "0") ?? 0

              if state.method == "POST" && state.pathAndQuery.hasPrefix("/upload-raw") {
                let comps = URLComponents(string: "http://localhost\(state.pathAndQuery)")
                let rawName = comps?.queryItems?.first(where: { $0.name == "name" })?.value ?? "上传文件_\(Int(Date().timeIntervalSince1970))"
                state.uploadFileName = rawName.removingPercentEncoding ?? rawName
                let tid = "lanup_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(4))"
                state.uploadTaskId = tid
                state.uploadStartedAt = Date().timeIntervalSince1970
                let totalLen = Int64(max(1, state.contentLength))
                let fname = state.uploadFileName
                Task { @MainActor in
                  let mount = appState.activeStorageMount
                  let dir = appState.fileListing.path.isEmpty ? mount.rootPath : appState.fileListing.path
                  let newTask = TvFileTransferTask(
                    id: tid,
                    name: fname,
                    direction: .upload,
                    sourceLabel: "手机/电脑浏览器快传",
                    targetLabel: "\(mount.name) (\(dir.isEmpty ? "/" : dir))",
                    totalBytes: totalLen,
                    transferredBytes: 0,
                    speedBytesPerSec: 0,
                    status: .running,
                    detailMessage: "正在接收局域网浏览器上传数据流...",
                    localSavedPath: nil,
                    createdAt: Date()
                  )
                  appState.fileTransferTasks.insert(newTask, at: 0)
                }
              }
            }
          }

          if state.headerParsed {
            let receivedBodyBytes = max(0, state.buffer.count - state.headerEndOffset)
            if let tid = state.uploadTaskId, state.contentLength > 0 {
              let now = Date().timeIntervalSince1970
              if now - state.lastProgressTick >= 0.12 || receivedBodyBytes >= state.contentLength {
                state.lastProgressTick = now
                let elapsed = max(0.1, now - state.uploadStartedAt)
                let speed = Double(receivedBodyBytes) / elapsed
                let rec64 = Int64(receivedBodyBytes)
                let tot64 = Int64(state.contentLength)
                Task { @MainActor in
                  appState.updateTransferTaskProgress(
                    id: tid,
                    transferredBytes: min(rec64, tot64),
                    totalBytes: tot64,
                    speedBytesPerSec: speed,
                    status: .running,
                    detail: "正在接收局域网快传数据..."
                  )
                }
              }
            }

            if receivedBodyBytes >= state.contentLength {
              let bodyEnd = min(state.buffer.count, state.headerEndOffset + state.contentLength)
              let bodyData = state.buffer.subdata(in: state.headerEndOffset..<bodyEnd)
              processCompleteLanRequest(
                conn: conn,
                appState: appState,
                method: state.method,
                pathAndQuery: state.pathAndQuery,
                bodyData: bodyData,
                uploadTaskId: state.uploadTaskId,
                uploadFileName: state.uploadFileName
              )
              return
            }
          }
        }

        if isComplete || error != nil {
          if state.headerParsed {
            let bodyData = state.buffer.count > state.headerEndOffset
              ? state.buffer.subdata(in: state.headerEndOffset..<state.buffer.count)
              : Data()
            processCompleteLanRequest(
              conn: conn,
              appState: appState,
              method: state.method,
              pathAndQuery: state.pathAndQuery,
              bodyData: bodyData,
              uploadTaskId: state.uploadTaskId,
              uploadFileName: state.uploadFileName
            )
          } else {
            conn.cancel()
          }
          return
        }
        readMore()
      }
    }
    readMore()
  }

  private nonisolated static func processCompleteLanRequest(
    conn: NWConnection,
    appState: TvAppState,
    method: String,
    pathAndQuery: String,
    bodyData: Data,
    uploadTaskId: String?,
    uploadFileName: String
  ) {
    // 1. Raw file stream upload from LAN Web File Portal (`POST /upload-raw?name=...`)
    if method == "POST" && pathAndQuery.hasPrefix("/upload-raw") {
      let tid = uploadTaskId ?? "lanup_\(Int(Date().timeIntervalSince1970 * 1000))"
      Task { @MainActor in
        let ok = await appState.uploadRawDataToMountWithProgress(
          transferId: tid,
          fileName: uploadFileName,
          fileData: bodyData,
          sourceLabel: "手机/电脑浏览器快传"
        )
        let json = ok
          ? "{\"ok\":true,\"name\":\"\(uploadFileName)\",\"size\":\(bodyData.count)}"
          : "{\"ok\":false,\"error\":\"upload_failed\"}"
        sendHttpRawResponse(conn: conn, status: ok ? "200 OK" : "500 Internal Server Error", contentType: "application/json; charset=utf-8", bodyData: Data(json.utf8))
      }
      return
    }

    // 2. Mount AList / WebDAV remotely from phone/PC browser (`POST /mount-storage`)
    if method == "POST" && pathAndQuery.hasPrefix("/mount-storage") {
      let bodyStr = String(data: bodyData, encoding: .utf8) ?? ""
      let form = parseFormUrlEncoded(bodyStr)
      let kindStr = (form["kind"] ?? "alist").lowercased()
      let name = form["name"] ?? ""
      let baseUrl = form["base_url"] ?? ""
      let username = form["username"] ?? ""
      let password = form["password"] ?? ""
      let token = form["token"] ?? ""
      let rootPath = form["root_path"] ?? "/"
      Task { @MainActor in
        if !baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          let kind: TvStorageSourceKind
          if kindStr == "smb" {
            kind = .smb
          } else if kindStr == "webdav" {
            kind = .webdav
          } else {
            kind = .alist
          }
          let created = appState.upsertStorageMount(
            name: name,
            kind: kind,
            baseUrl: baseUrl,
            username: username,
            password: password,
            token: token,
            rootPath: rootPath
          )
          appState.switchStorageMount(created.id)
        }
        let html = buildLanPortalPage(appState: appState, pushedBanner: "✅ 已成功挂载远程存储并在 Apple TV 打开！")
        sendHttpResponse(conn: conn, html: html)
      }
      return
    }

    // 3. Download file from Apple TV Local Offline Cache (`GET /local-cache/<filename>`)
    if method == "GET" && pathAndQuery.hasPrefix("/local-cache/") {
      let rel = String(pathAndQuery.dropFirst("/local-cache/".count)).removingPercentEncoding ?? ""
      let fileUrl = resolveLocalOfflineUrl(relativePath: rel)
      if let fileData = try? Data(contentsOf: fileUrl) {
        let fname = fileUrl.lastPathComponent
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"\(fname)\"\r\nContent-Length: \(fileData.count)\r\nConnection: close\r\n\r\n"
        var packet = Data(header.utf8)
        packet.append(fileData)
        conn.send(content: packet, completion: .contentProcessed { _ in conn.cancel() })
      } else {
        sendHttpRawResponse(conn: conn, status: "404 Not Found", contentType: "text/plain; charset=utf-8", bodyData: Data("File not found".utf8))
      }
      return
    }

    // 4. Download / Proxy current directory file to Phone/PC browser (`GET /download-entry?idx=<index>`)
    if method == "GET" && pathAndQuery.hasPrefix("/download-entry") {
      let comps = URLComponents(string: "http://localhost\(pathAndQuery)")
      let idx = Int(comps?.queryItems?.first(where: { $0.name == "idx" })?.value ?? "-1") ?? -1
      Task { @MainActor in
        let entries = appState.fileListing.entries
        guard idx >= 0 && idx < entries.count else {
          sendHttpRawResponse(conn: conn, status: "404 Not Found", contentType: "text/plain", bodyData: Data("Invalid entry".utf8))
          return
        }
        let entry = entries[idx]
        if entry.sourceKind == .localCache {
          let fileUrl = resolveLocalOfflineUrl(relativePath: entry.path)
          if let d = try? Data(contentsOf: fileUrl) {
            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"\(entry.name)\"\r\nContent-Length: \(d.count)\r\nConnection: close\r\n\r\n"
            var pkt = Data(header.utf8)
            pkt.append(d)
            conn.send(content: pkt, completion: .contentProcessed { _ in conn.cancel() })
            return
          }
        }
        if let resolved = try? await appState.resolveFileStreamEndpoint(entry),
           !resolved.url.isEmpty {
          let redirectHeader = "HTTP/1.1 302 Found\r\nLocation: \(resolved.url)\r\nConnection: close\r\n\r\n"
          conn.send(content: Data(redirectHeader.utf8), completion: .contentProcessed { _ in conn.cancel() })
        } else {
          sendHttpRawResponse(conn: conn, status: "404 Not Found", contentType: "text/plain", bodyData: Data("Unable to resolve download URL".utf8))
        }
      }
      return
    }

    // 5. Push Subscription / 115 Cookie / Server Config (`POST /push`)
    if method == "POST" && pathAndQuery.hasPrefix("/quick-input") {
      let bodyPart = String(data: bodyData, encoding: .utf8) ?? ""
      let form = parseFormUrlEncoded(bodyPart)
      let text = form["text"] ?? ""
      Task { @MainActor in
        let targetName = appState.activeLanQuickInputPrompt.isEmpty ? "当前输入框" : appState.activeLanQuickInputPrompt
        if let receiver = appState.activeLanQuickInputReceiver {
          receiver(text)
          appState.showLanQuickInputModal = false
          appState.showToast("📱 已收到手机扫码输入：\(targetName)")
        } else {
          // Intelligent fallback if no specific input modal was open
          switch appState.selectedSection {
          case .vod:
            appState.searchKeyword = text
            Task { await appState.performSearch() }
          case .live:
            appState.liveSearchKeyword = text
          case .telegram:
            appState.telegramChatFilter = text
          case .mediaLibrary:
            appState.fileSearchKeyword = text
          default:
            break
          }
          appState.showToast("📱 已收到手机扫码输入：\(text)")
        }
        let okHtml = buildLanPortalPage(appState: appState, pushedBanner: "✅ 已成功填入 Apple TV「\(targetName)」！")
        sendHttpResponse(conn: conn, html: okHtml)
      }
      return
    }

    if method == "POST" && pathAndQuery.hasPrefix("/push") {
      let bodyPart = String(data: bodyData, encoding: .utf8) ?? ""
      let form = parseFormUrlEncoded(bodyPart)
      let subNameInput = (form["sub_name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let subInput = form["sub_url"] ?? ""
      let cookieInput = form["cookie_115"] ?? ""
      let serverInput = form["server_url"] ?? ""
      let pwdInput = form["server_pwd"] ?? ""

      Task { @MainActor in
        var actions: [String] = []
        let rawLines = subInput
          .components(separatedBy: .newlines)
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }

        if !rawLines.isEmpty {
          var subIdsToRefresh: [String] = []
          var rawNodeLines: [String] = []

          for (idx, line) in rawLines.enumerated() {
            let lower = line.lowercased()
            if lower.hasPrefix("vmess://") || lower.hasPrefix("vless://") || lower.hasPrefix("ss://")
                || lower.hasPrefix("trojan://") || lower.hasPrefix("hy2://") || lower.hasPrefix("hysteria2://")
                || lower.hasPrefix("socks5://") {
              rawNodeLines.append(line)
            } else {
              let name = rawLines.count > 1 && !subNameInput.isEmpty
                ? "\(subNameInput) \(idx + 1)"
                : subNameInput
              if let sub = appState.upsertSubscription(name: name, url: line, enabled: true) {
                subIdsToRefresh.append(sub.id)
              }
            }
          }

          if !subIdsToRefresh.isEmpty {
            actions.append("\(subIdsToRefresh.count) 个代理订阅")
            Task {
              for sid in subIdsToRefresh {
                await appState.refreshSubscription(sid, silent: false)
              }
            }
          }
          if !rawNodeLines.isEmpty {
            actions.append("节点直链")
            Task {
              _ = await appState.importManualNodesFromText(rawNodeLines.joined(separator: "\n"))
            }
          }
        }

        if !cookieInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          actions.append("115 Cookie")
          Task {
            await appState.save115Cookie(cookieInput)
          }
        }
        if !serverInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          appState.saveConfig(
            newUrl: serverInput,
            newSecret: pwdInput.isEmpty ? appState.authSecret : pwdInput,
            adFilter: appState.enableAdFilter,
            directPlayback: appState.preferDirectPlayback,
            introSec: appState.skipIntroSeconds,
            outroSec: appState.skipOutroSeconds
          )
          actions.append("服务器配置")
          Task { await appState.bootstrapAll() }
        }
        let summary = actions.isEmpty ? "配置" : actions.joined(separator: "、")
        appState.showToast("📱 已收到手机扫码推送的\(summary)，正在自动更新测速！")
        let okHtml = buildLanPortalPage(appState: appState, pushedBanner: "✅ 已成功推送 \(summary) 到 Apple TV！")
        sendHttpResponse(conn: conn, html: okHtml)
      }
      return
    }

    // Default: GET / -> Render full Apple TV LAN File Upload/Download + AList Mount + Subscription Web Portal
    Task { @MainActor in
      let html = buildLanPortalPage(appState: appState, pushedBanner: nil)
      sendHttpResponse(conn: conn, html: html)
    }
  }

  private nonisolated static func sendHttpRawResponse(
    conn: NWConnection,
    status: String,
    contentType: String,
    bodyData: Data
  ) {
    let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
    var respData = Data(header.utf8)
    respData.append(bodyData)
    conn.send(content: respData, completion: .contentProcessed { _ in
      conn.cancel()
    })
  }

  private nonisolated static func sendHttpResponse(conn: NWConnection, html: String) {
    let bodyData = Data(html.utf8)
    let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
    var respData = Data(header.utf8)
    respData.append(bodyData)
    conn.send(content: respData, completion: .contentProcessed { _ in
      conn.cancel()
    })
  }

  private nonisolated static func parseFormUrlEncoded(_ body: String) -> [String: String] {
    var result: [String: String] = [:]
    for pair in body.components(separatedBy: "&") {
      let kv = pair.components(separatedBy: "=")
      guard kv.count >= 2 else { continue }
      let key = kv[0].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[0]
      let rawVal = kv.dropFirst().joined(separator: "=").replacingOccurrences(of: "+", with: " ")
      let val = rawVal.removingPercentEncoding ?? rawVal
      result[key] = val
    }
    return result
  }

  @MainActor
  private static func buildLanPortalPage(appState: TvAppState, pushedBanner: String?) -> String {
    let mount = appState.activeStorageMount
    let currentDir = appState.fileListing.path.isEmpty ? mount.rootPath : appState.fileListing.path
    let existingSummary = appState.subscriptions
      .map { "• \($0.name): \($0.maskedUrlSummary) (\($0.nodeCount) 节点)" }
      .joined(separator: "<br>")
    let filesRowsHtml: String = {
      let files = appState.fileListing.entries.enumerated().filter { !$0.element.isDir }.prefix(40)
      if files.isEmpty {
        return "<div style='color:#7E869A;font-size:13px;padding:10px 0;'>当前目录暂无可下载文件</div>"
      }
      return files.map { (idx, entry) in
        """
        <div style='display:flex;justify-content:space-between;align-items:center;padding:9px 12px;border-bottom:1px solid #262B3A;font-size:13px;'>
          <div style='overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:72%;color:#E5E9F2;'>📄 \(entry.name) <span style='color:#8892A8;'>(\(entry.formattedSize))</span></div>
          <a href='/download-entry?idx=\(idx)' style='background:#2563EB;color:#fff;text-decoration:none;padding:5px 11px;border-radius:8px;font-weight:600;font-size:12px;'>下载到手机/电脑</a>
        </div>
        """
      }.joined(separator: "\n")
    }()

    let bannerHtml = (pushedBanner != nil)
      ? "<div style='background:#184d30;border:1px solid #30d158;color:#fff;padding:14px 16px;border-radius:14px;margin-bottom:18px;font-weight:600;'>\(pushedBanner!)</div>"
      : ""

    let subListBox = existingSummary.isEmpty
      ? ""
      : "<div style='background:#11131A;border:1px solid #2B3042;border-radius:12px;padding:10px 12px;margin-bottom:14px;font-size:12px;color:#A5ADBA;line-height:1.6;'><strong style='color:#FFB340;'>电视端已配置的订阅源：</strong><br>\(existingSummary)</div>"

    return """
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
      <title>流光视频 · Apple TV 文件快传与远程挂载中心</title>
      <style>
        * { box-sizing: border-box; }
        body {
          margin: 0; padding: 18px;
          background: #0B0C10; color: #F5F6FA;
          font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif;
        }
        .card {
          max-width: 620px; margin: 0 auto 18px auto;
          background: #191C26; border: 1px solid #2E3446;
          border-radius: 20px; padding: 20px;
          box-shadow: 0 12px 32px rgba(0,0,0,0.45);
        }
        h2 { margin: 0 0 6px 0; font-size: 20px; color: #FF9F0A; }
        p.sub { margin: 0 0 14px 0; font-size: 13px; color: #9EA3B0; line-height: 1.45; }
        label { display: block; font-size: 13px; font-weight: 600; margin: 11px 0 5px 0; color: #E2E6F0; }
        textarea, input, select {
          width: 100%; background: #11131A; color: #fff;
          border: 1px solid #343A4D; border-radius: 12px;
          padding: 11px; font-size: 14px; outline: none;
        }
        textarea:focus, input:focus, select:focus { border-color: #FF9F0A; }
        button {
          margin-top: 16px; width: 100%;
          background: linear-gradient(135deg, #FF9F0A, #FF7A00);
          color: #fff; font-weight: 700; font-size: 15px;
          border: none; border-radius: 14px; padding: 13px;
          cursor: pointer;
        }
        .dropzone {
          border: 2px dashed #3B82F6; background: rgba(59,130,246,0.08);
          border-radius: 16px; padding: 22px 14px; text-align: center;
          cursor: pointer; transition: 0.2s;
        }
        .dropzone:hover { background: rgba(59,130,246,0.16); }
        .prog-wrap {
          margin-top: 14px; display: none;
          background: #11131A; border: 1px solid #2E3446; border-radius: 12px; padding: 12px;
        }
        .prog-bar-bg {
          width: 100%; height: 10px; background: #262B3A; border-radius: 6px; overflow: hidden; margin: 8px 0;
        }
        .prog-bar-fill {
          height: 100%; width: 0%; background: linear-gradient(90deg, #3B82F6, #10B981); transition: width 0.1s;
        }
      </style>
    </head>
    <body>
      \(bannerHtml)
      <div class="card" style="border-color:#FF9F0A;">
        <h2>⌨️ 0. 电视端万能扫码快捷输入（\(appState.activeLanQuickInputPrompt.isEmpty ? "自动填入当前页面搜索/输入框" : "当前目标：\(appState.activeLanQuickInputPrompt)")）</h2>
        <p class="sub">在下方输入或粘贴文字、影视片名、频道名、网址、密码、歌单名或聊天内容，点击发送即可立即填入 Apple TV 当前输入框：</p>
        <form method="POST" action="/quick-input">
          <textarea name="text" rows="3" placeholder="\(appState.activeLanQuickInputPlaceholder.isEmpty ? "在此输入或粘贴要发送到电视的内容..." : appState.activeLanQuickInputPlaceholder)" autofocus></textarea>
          <button type="submit">🚀 立即填入 Apple TV 输入框</button>
        </form>
      </div>
      <div class="card">
        <h2>📂 1. 局域网文件上传与下载（Apple TV 实时同步显示进度）</h2>
        <p class="sub">当前 Apple TV 正在浏览：<strong style="color:#60A5FA;">\(mount.name)</strong> · 目录 <code style="color:#FFB340;">\(currentDir.isEmpty ? "/" : currentDir)</code>。选择或拖拽文件后将直接上传至该目录，并在手机与电视屏幕上同时显示实时进度条！</p>
        <div class="dropzone" onclick="document.getElementById('fileInput').click()">
          <div style="font-size:28px;margin-bottom:6px;">⬆️</div>
          <div style="font-weight:700;font-size:15px;color:#93C5FD;">点击选择文件 或 拖拽多个文件到此处上传到 Apple TV</div>
          <div style="font-size:12px;color:#8892A8;margin-top:4px;">支持视频 (MP4/MKV/TS)、字幕 (SRT/ASS)、音频、播放列表 (M3U8)、图片等任意文件</div>
          <input type="file" id="fileInput" multiple style="display:none" onchange="uploadFiles(this.files)" />
        </div>
        <div id="progWrap" class="prog-wrap">
          <div id="progTitle" style="font-size:13px;font-weight:600;color:#E2E6F0;">准备上传...</div>
          <div class="prog-bar-bg"><div id="progFill" class="prog-bar-fill"></div></div>
          <div id="progDetail" style="font-size:12px;color:#9EA3B0;">0%</div>
        </div>
        <div style="margin-top:16px;">
          <div style="font-size:13px;font-weight:700;color:#FFB340;margin-bottom:6px;">⬇️ 当前目录文件列表（点击可直接下载到手机/电脑）：</div>
          <div style="background:#11131A;border:1px solid #2B3042;border-radius:12px;max-height:240px;overflow-y:auto;">
            \(filesRowsHtml)
          </div>
        </div>
      </div>

      <div class="card">
        <h2>☁️ 2. 远程挂载 AList / OpenList / WebDAV / SMB 共享到 Apple TV</h2>
        <p class="sub">无需用遥控器逐字输入，在此填入 AList、WebDAV 或 SMB (NAS/Windows) 地址后点击挂载，Apple TV 文件管理器将立即打开该存储！</p>
        <form method="POST" action="/mount-storage">
          <label>存储类型</label>
          <select name="kind">
            <option value="alist">AList / OpenList (v3 API 原生挂载)</option>
            <option value="webdav">WebDAV 标准网盘 (如 AList /dav、群晖、CloudDrive2、Nextcloud)</option>
            <option value="smb">SMB 局域网共享 (群晖 / 飞牛 fnOS / Unraid / 威联通 / Windows)</option>
          </select>
          <label>显示名称（例如：家庭 NAS / 家庭 AList）</label>
          <input type="text" name="name" placeholder="例如：家庭 NAS 媒体库" />
          <label>服务器地址（AList 填 http://IP:5244；WebDAV 填 http://IP:5244/dav；SMB 填 smb://192.168.1.10 或 192.168.1.10）</label>
          <input type="text" name="base_url" placeholder="smb://192.168.1.10 或 http://192.168.1.10:5244" required />
          <div style="display:flex;gap:10px;">
            <div style="flex:1;">
              <label>用户名（选填，游客留空）</label>
              <input type="text" name="username" placeholder="admin" />
            </div>
            <div style="flex:1;">
              <label>密码（选填）</label>
              <input type="password" name="password" placeholder="密码" />
            </div>
          </div>
          <div style="display:flex;gap:10px;">
            <div style="flex:1;">
              <label>默认初始目录</label>
              <input type="text" name="root_path" value="/" placeholder="/" />
            </div>
            <div style="flex:1;">
              <label>AList Token（选填，填账号密码可留空）</label>
              <input type="text" name="token" placeholder="选填" />
            </div>
          </div>
          <button type="submit">🔗 立即挂载并在 Apple TV 打开</button>
        </form>
      </div>

      <div class="card">
        <h2>📺 3. 多订阅、节点直链与 115 Cookie 推送</h2>
        \(subListBox)
        <form method="POST" action="/push">
          <label>订阅备注名称（选填）</label>
          <input type="text" name="sub_name" placeholder="不填则自动提取域名作为订阅名称" />
          <label>订阅链接或节点直链（支持每行一个）</label>
          <textarea name="sub_url" rows="3" placeholder="在此粘贴 https://... 订阅地址或 vmess:// / ss:// 节点链接"></textarea>
          <label>115 网盘 Cookie（选填）</label>
          <input type="text" name="cookie_115" placeholder="UID=...; CID=...; SEID=..." />
          <label>流光服务端地址（选填）</label>
          <input type="text" name="server_url" placeholder="例如 https://jp2.linsionwinwin.top:8081" />
          <button type="submit">🚀 推送配置到 Apple TV</button>
        </form>
      </div>

      <script>
        async function uploadFiles(files) {
          if (!files || !files.length) return;
          const wrap = document.getElementById('progWrap');
          const title = document.getElementById('progTitle');
          const fill = document.getElementById('progFill');
          const detail = document.getElementById('progDetail');
          wrap.style.display = 'block';

          for (let i = 0; i < files.length; i++) {
            const file = files[i];
            title.textContent = `正在上传 (${i + 1}/${files.length}): ${file.name}`;
            fill.style.width = '0%';
            const startMs = Date.now();

            await new Promise((resolve) => {
              const xhr = new XMLHttpRequest();
              xhr.open('POST', '/upload-raw?name=' + encodeURIComponent(file.name), true);
              xhr.upload.onprogress = (e) => {
                if (e.lengthComputable) {
                  const pct = ((e.loaded / e.total) * 100).toFixed(1);
                  fill.style.width = pct + '%';
                  const elapsed = Math.max(0.1, (Date.now() - startMs) / 1000);
                  const mbps = (e.loaded / (1024 * 1024) / elapsed).toFixed(2);
                  detail.textContent = `${pct}% · ${(e.loaded / (1024 * 1024)).toFixed(2)} MB / ${(e.total / (1024 * 1024)).toFixed(2)} MB · ${mbps} MB/s（Apple TV 屏幕正同步显示进度）`;
                }
              };
              xhr.onload = () => {
                fill.style.width = '100%';
                detail.textContent = `✅ ${file.name} 上传完成！`;
                resolve();
              };
              xhr.onerror = () => {
                detail.textContent = `⚠️ ${file.name} 上传失败`;
                resolve();
              };
              xhr.send(file);
            });
          }
          setTimeout(() => { location.reload(); }, 900);
        }
      </script>
    </body>
    </html>
    """
  }

  nonisolated static func localLanIPv4Address() -> String? {
    var address: String? = nil
    var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }

    var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
    while let cur = ptr {
      let interface = cur.pointee
      let addrFamily = interface.ifa_addr.pointee.sa_family
      if addrFamily == UInt8(AF_INET) {
        let name = String(cString: interface.ifa_name)
        if name.hasPrefix("en") || name.hasPrefix("eth") || name.hasPrefix("wlan") {
          var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
          getnameinfo(
            interface.ifa_addr,
            socklen_t(interface.ifa_addr.pointee.sa_len),
            &hostname,
            socklen_t(hostname.count),
            nil,
            socklen_t(0),
            NI_NUMERICHOST
          )
          let ip = String(cString: hostname)
          if !ip.hasPrefix("169.254.") && ip != "127.0.0.1" {
            address = ip
            if name == "en0" || name == "en1" { break }
          }
        }
      }
      ptr = interface.ifa_next
    }
    return address
  }

  private nonisolated static func tcpPing(host: String, port: Int) async -> Int {
    guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return 9999 }
    let realHost = await TvLocalProxyTunnelServer.resolveRealEntryIp(host)
    let start = DispatchTime.now()
    let serialQueue = DispatchQueue(label: "com.linsion.tvos.tcpping")
    return await withCheckedContinuation { cont in
      let conn = NWConnection(host: NWEndpoint.Host(realHost), port: nwPort, using: .tcp)
      final class OnceFlag: @unchecked Sendable {
        var done = false
      }
      let flag = OnceFlag()
      conn.stateUpdateHandler = { state in
        switch state {
        case .ready:
          guard !flag.done else { return }
          flag.done = true
          let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
          conn.cancel()
          cont.resume(returning: max(1, elapsed))
        case .failed, .cancelled:
          guard !flag.done else { return }
          flag.done = true
          conn.cancel()
          cont.resume(returning: 9999)
        default:
          break
        }
      }
      conn.start(queue: serialQueue)
      serialQueue.asyncAfter(deadline: .now() + 1.8) {
        guard !flag.done else { return }
        flag.done = true
        conn.cancel()
        cont.resume(returning: 9999)
      }
    }
  }

  func refresh115Status() async {
    if TvLocal115DirectClient.shared.hasLocalCookie {
      let localRes = await TvLocal115DirectClient.shared.verifyStatus()
      if localRes.loggedIn {
        self.is115LoggedIn = true
        self.user115Name = localRes.userName
        try? await api.login115WithCookie(cookie: TvLocal115DirectClient.shared.savedCookie)
        return
      }
    }
    let dict = await api.fetch115Status()
    let srvLoggedIn = (dict["logged_in"] as? Bool) == true
      || (dict["authorized"] as? Bool) == true
      || dict["Id"] != nil
      || dict["user_id"] != nil
    self.is115LoggedIn = srvLoggedIn || TvLocal115DirectClient.shared.hasLocalCookie
    self.user115Name = TvApiClient.stringValue(
      dict["Name"],
      fallback: TvApiClient.stringValue(
        dict["user_name"],
        fallback: TvApiClient.stringValue(dict["uid"], fallback: TvLocal115DirectClient.shared.savedUserName)
      )
    )
  }

  func save115Cookie(_ rawCookie: String) async {
    let normalized = TvLocal115DirectClient.normalizeCookieString(rawCookie)
    guard !normalized.isEmpty else { return }
    TvLocal115DirectClient.shared.savedCookie = normalized
    try? await api.login115WithCookie(cookie: normalized)
    await refresh115Status()
  }

  func start115QrCode(forceRefresh: Bool = false, onLoginSuccess: (() -> Void)? = nil) async {
    if let cb = onLoginSuccess {
      self.qr115OnLoginSuccess = cb
    }
    // Reuse existing QR code for 180 seconds unless the user explicitly clicked "刷新二维码"
    if !forceRefresh,
       !qr115Token.isEmpty,
       !qr115Content.isEmpty,
       Date().timeIntervalSince(qr115CreatedAt) < 180 {
      if qr115PollTask == nil {
        start115QrPollLoop(uid: qr115Token, time: qr115Time, sign: qr115Sign)
      }
      return
    }

    qr115PollTask?.cancel()
    qr115PollTask = nil
    if qr115Content.isEmpty || forceRefresh {
      qr115StatusText = "正在获取 115 官方扫码二维码..."
    }
    do {
      let session = try await TvLocal115DirectClient.shared.startQrCodeSession()
      self.qr115Token = session.uid
      self.qr115Time = session.time
      self.qr115Sign = session.sign
      self.qr115CreatedAt = Date()
      if self.qr115Content != session.qrContent {
        self.qr115Content = session.qrContent
      }
      if self.qr115ImageUrl != session.imageUrl {
        self.qr115ImageUrl = session.imageUrl
      }
      let initialMsg = "请使用手机 115 网盘 App 扫描二维码（确认后自动完成登录）"
      if self.qr115StatusText != initialMsg {
        self.qr115StatusText = initialMsg
      }

      start115QrPollLoop(uid: session.uid, time: session.time, sign: session.sign)
    } catch {
      self.qr115StatusText = "获取 115 二维码失败：\(error.localizedDescription)"
    }
  }

  private func start115QrPollLoop(uid: String, time: Int64, sign: String) {
    qr115PollTask?.cancel()
    qr115PollTask = Task { @MainActor [weak self] in
      guard let self = self else { return }
      // Poll calmly every 2.5s for up to 5 minutes without refreshing or replacing the QR code!
      for _ in 0..<120 {
        if Task.isCancelled { break }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        if Task.isCancelled { break }
        let poll = await TvLocal115DirectClient.shared.pollQrCodeStatus(uid: uid, time: time, sign: sign)
        if Task.isCancelled { break }
        if self.qr115StatusText != poll.message {
          self.qr115StatusText = poll.message
        }
        if poll.status == 2, let ck = poll.cookie {
          try? await self.api.login115WithCookie(cookie: ck)
          self.is115LoggedIn = true
          self.user115Name = poll.userName ?? "115 用户"
          self.qr115Token = ""
          self.qr115Content = ""
          self.qr115ImageUrl = ""
          self.qr115CreatedAt = .distantPast
          self.qr115PollTask = nil
          self.showToast("✓ 115 网盘扫码登录成功（\(self.user115Name)）")
          let cb = self.qr115OnLoginSuccess
          self.qr115OnLoginSuccess = nil
          cb?()
          break
        } else if poll.status < 0 {
          self.qr115CreatedAt = .distantPast
          self.qr115PollTask = nil
          break
        }
      }
    }
  }

  func poll115QrCodeOnce() async {
    guard !qr115Token.isEmpty else { return }
    await refresh115Status()
  }

  func cancel115Acceleration() {
    accel115Task?.cancel()
    accel115Task = nil
    is115Accelerating = false
    accel115StageTitle = ""
    accel115DetailText = ""
    accel115Progress = 0
  }

  /// Full 3-stage pipeline with automatic URL unwrapping, stale-failed-task recovery,
  /// multi-line candidate failover, and 115 official Cloud Offline Download (`离线下载`) fallback:
  /// 1) Checks if the video is already in 115 Cloud Drive (`/流光115加速` priority, instant switch if found)
  /// 2) Unwraps any local loopback (`127.0.0.1`) / `/api/vod/proxy` / inline header URL, instructs the server to download (`POST /api/download`),
  ///    automatically retries or switches to backup candidate URLs if a line fails on the server, and falls back to 115 Cloud Offline Download if all server lines fail
  /// 3) Waits for 115 upload (`Uploading` / `/api/115/upload/:id` / CloudDrive2 sync), then resolves the official 115 domestic CDN direct link locally from Apple TV (`TvLocal115DirectClient`) and invokes `onResolved`!
  func start115AcceleratedPlayback(
    downloadUrl: String,
    fallbackDownloadUrls: [String] = [],
    videoName: String,
    headers: [String: String] = [:],
    telegramAccountId: String? = nil,
    onResolved: @escaping (_ proxyStreamUrl: String, _ directCdnUrl: String, _ headers115: [String: String], _ fileName: String) -> Void
  ) {
    accel115Task?.cancel()
    let cleanName = videoName
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let taskTitle = cleanName.isEmpty ? "115加速_\(Int(Date().timeIntervalSince1970))" : cleanName

    is115Accelerating = true
    accel115StageTitle = "正在检索 115 网盘是否已存在该视频..."
    accel115DetailText = taskTitle
    accel115Progress = 0.06

    accel115Task = Task { @MainActor [weak self] in
      guard let self = self else { return }
      let pipelineStartedAt = Date()

      // Ensure backend server also has our local 115 Cookie and designated target folder (`eleven_dir_id`)
      if TvLocal115DirectClient.shared.hasLocalCookie {
        try? await self.api.login115WithCookie(cookie: TvLocal115DirectClient.shared.savedCookie)
        _ = await TvLocal115DirectClient.shared.ensureAccelerationFolderCid(syncToServerApi: self.api)
      }

      // Step 1: Fast-check if the video already exists in the user's 115 Cloud Drive
      if let existing = await TvLocal115DirectClient.shared.findAndResolveDirectPlayUrl(keywords: [taskTitle, videoName]) {
        guard !Task.isCancelled else { return }
        self.accel115Progress = 1.0
        self.is115Accelerating = false
        self.showToast("⚡ 115 网盘已存在该视频，已切换本地直连 115 播放！")
        onResolved(existing.proxyStreamUrl, existing.directCdnUrl, existing.headers, existing.fileName)
        return
      }

      guard !Task.isCancelled else { return }

      // Fetch active HLS proxy upstream config in case `downloadUrl` is `http://127.0.0.1:<port>/live.m3u8?gen=...`
      let hlsCfg = await TvLocalHlsProxyServer.shared.currentUpstreamConfig()
      let hlsUpstream = !hlsCfg.streamUrl.isEmpty ? hlsCfg.streamUrl : hlsCfg.gatewayUrl

      var candidates: [(url: String, headers: [String: String])] = []
      var seenUrls = Set<String>()

      func addCandidate(_ rawU: String, _ baseH: [String: String]) {
        let unwrapped = TvLocal115DirectClient.unwrapDownloadTargetUrlAndHeaders(
          rawUrl: rawU,
          baseHeaders: baseH,
          hlsUpstreamUrl: hlsUpstream,
          hlsUpstreamHeaders: hlsCfg.headers
        )
        let u = unwrapped.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return }
        if u.contains("://127.0.0.1") || u.contains("://localhost") || u.hasPrefix("file://") {
          return
        }
        if seenUrls.insert(u).inserted {
          candidates.append((url: u, headers: unwrapped.headers))
        }
      }

      addCandidate(downloadUrl, headers)
      for fb in fallbackDownloadUrls {
        addCandidate(fb, headers)
      }
      if !hlsUpstream.isEmpty {
        addCandidate(hlsUpstream, hlsCfg.headers)
      }

      guard !candidates.isEmpty else {
        self.is115Accelerating = false
        self.showToast("⚠️ 无法提取有效的远程视频源链接，请切换其他线路后重试")
        return
      }

      var createdTaskId: String? = nil
      var matchedTask: TvDownloadTask? = nil
      var lastServerFailureReason = ""
      var serverDownloadSucceeded = false

      // Step 2 & 3: Try each candidate URL on the backend server (with automatic cleanup/retry of stale Failed tasks)
      for (cIdx, candidate) in candidates.enumerated() {
        guard !Task.isCancelled else { return }
        let lineLabel = candidates.count > 1 ? " (线路 \(cIdx + 1)/\(candidates.count))" : ""

        self.accel115StageTitle = cIdx == 0
          ? "阶段 1/3 · 正在提交服务器高速下载任务..."
          : "阶段 1/3 · 当前线路下载失败，正在自动切换备用线路 (\(cIdx + 1)/\(candidates.count))..."
        self.accel115DetailText = "\(taskTitle)\(lineLabel)"
        self.accel115Progress = 0.10

        // Pre-clean any stale Failed task with the same name or URL so `/api/download` doesn't attach to an old Failed task
        let existingTasks = await self.api.fetchDownloadTasks()
        for t in existingTasks where (t.name == taskTitle || t.url == candidate.url) && t.status == "Failed" {
          try? await self.api.deleteDownloadTask(id: t.id, deleteFiles: true)
        }

        do {
          createdTaskId = try await self.api.createDownloadTask(
            url: candidate.url,
            name: taskTitle,
            headers: candidate.headers,
            telegramAccountId: telegramAccountId,
            forceDuplicate: cIdx > 0
          )
        } catch {
          lastServerFailureReason = error.localizedDescription
          continue
        }

        matchedTask = nil
        var didTriggerManual115Upload = false
        var didRetryFailedTaskOnce = false
        var candidateFailed = false

        for pollTick in 0..<600 {
          guard !Task.isCancelled else { return }
          let tasks = await self.api.fetchDownloadTasks()
          self.downloadTasks = tasks

          if let tid = createdTaskId, !tid.isEmpty,
             let byId = tasks.first(where: { $0.id == tid }) {
            matchedTask = byId
          } else if let activeMatch = tasks.first(where: { ($0.url == candidate.url || $0.name == taskTitle) && $0.status != "Failed" }) {
            matchedTask = activeMatch
            createdTaskId = activeMatch.id
          } else if let anyMatch = tasks.first(where: { $0.url == candidate.url || $0.name == taskTitle }) {
            matchedTask = anyMatch
            createdTaskId = anyMatch.id
          }

          if let t = matchedTask {
            switch t.status {
            case "Pending", "Downloading":
              let pct = max(1.0, min(99.5, t.progress))
              self.accel115StageTitle = "阶段 1/3 · 服务器正在高速下载该视频\(lineLabel)..."
              self.accel115Progress = 0.10 + (pct / 100.0) * 0.58
              let segInfo = t.totalSegments > 0 ? " · 分片 \(t.downloadedSegments)/\(t.totalSegments)" : ""
              self.accel115DetailText = String(format: "下载进度 %.1f%% · 速度 %@%@", pct, t.formattedSpeed, segInfo)

            case "Converting":
              self.accel115StageTitle = "阶段 1/3 · 服务器正在无损转封装 MP4..."
              self.accel115Progress = 0.70
              self.accel115DetailText = "即将自动上传至 115 网盘"

            case "Uploading":
              let upPct = max(1.0, min(99.5, t.progress))
              self.accel115StageTitle = "阶段 2/3 · 服务器正在上传视频至 115 网盘..."
              self.accel115Progress = 0.72 + (upPct / 100.0) * 0.18
              self.accel115DetailText = String(format: "上传 115 进度 %.1f%% · %@", upPct, t.name)

            case "Completed", "Duplicate":
              serverDownloadSucceeded = true
              var quickKeywords: [String] = []
              if !t.outputFile.isEmpty {
                quickKeywords.append((t.outputFile as NSString).lastPathComponent)
              }
              if !t.name.isEmpty {
                quickKeywords.append(t.name)
              }
              quickKeywords.append(taskTitle)
              quickKeywords.append(videoName)
              if let alreadyIn115 = await TvLocal115DirectClient.shared.findAndResolveDirectPlayUrl(
                keywords: quickKeywords,
                allowNewestRecentFallbackAfter: pipelineStartedAt
              ) {
                guard !Task.isCancelled else { return }
                self.accel115Progress = 1.0
                self.is115Accelerating = false
                self.showToast("⚡ 已切换至本地直连 115 高速播放：\(alreadyIn115.fileName)")
                onResolved(alreadyIn115.proxyStreamUrl, alreadyIn115.directCdnUrl, alreadyIn115.headers, alreadyIn115.fileName)
                return
              }

              if !didTriggerManual115Upload {
                didTriggerManual115Upload = true
                if t.error.lowercased().contains("115") || !t.outputFile.isEmpty {
                  let folderName = TvLocal115DirectClient.shared.targetFolderName
                  self.accel115StageTitle = "阶段 2/3 · 正在同步视频至 115 网盘 (/\(folderName))..."
                  self.accel115Progress = 0.76
                  self.accel115DetailText = "正在触发 115 秒传 / 接口上传..."
                  try? await self.api.uploadTaskTo115(id: t.id)
                  if !t.outputFile.isEmpty {
                    try? await self.api.uploadFileTo115(path: t.outputFile)
                  }
                  try? await Task.sleep(nanoseconds: 1_200_000_000)
                  let refreshed = await self.api.fetchDownloadTasks()
                  if let reTask = refreshed.first(where: { $0.id == t.id }), reTask.status == "Uploading" {
                    continue
                  }
                }
              }
              break

            case "Failed":
              let errText = t.error.trimmingCharacters(in: .whitespacesAndNewlines)
              lastServerFailureReason = errText.isEmpty ? "视频源连接被拒绝或超时" : errText

              // If the file actually finished downloading on server (`outputFile` non-empty) and only 115 upload failed, retry 115 upload directly
              if !t.outputFile.isEmpty && !didTriggerManual115Upload {
                didTriggerManual115Upload = true
                let folderName = TvLocal115DirectClient.shared.targetFolderName
                self.accel115StageTitle = "阶段 2/3 · 正在重新上传视频至 115 网盘 (/\(folderName))..."
                self.accel115Progress = 0.76
                self.accel115DetailText = "正在触发 115 秒传 / 接口上传..."
                try? await self.api.uploadTaskTo115(id: t.id)
                try? await self.api.uploadFileTo115(path: t.outputFile)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if let postUpload = await TvLocal115DirectClient.shared.findAndResolveDirectPlayUrl(
                  keywords: [(t.outputFile as NSString).lastPathComponent, t.name, taskTitle, videoName],
                  allowNewestRecentFallbackAfter: pipelineStartedAt
                ) {
                  guard !Task.isCancelled else { return }
                  self.accel115Progress = 1.0
                  self.is115Accelerating = false
                  self.showToast("⚡ 已切换至本地直连 115 高速播放：\(postUpload.fileName)")
                  onResolved(postUpload.proxyStreamUrl, postUpload.directCdnUrl, postUpload.headers, postUpload.fileName)
                  return
                }
              }

              if !didRetryFailedTaskOnce && cIdx == candidates.count - 1 {
                didRetryFailedTaskOnce = true
                self.accel115StageTitle = "阶段 1/3 · 服务器下载遇到波动，正在自动重试..."
                self.accel115DetailText = lastServerFailureReason
                try? await self.api.retryDownloadTask(id: t.id)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                continue
              }

              candidateFailed = true
              break

            default:
              break
            }

            if candidateFailed {
              break
            }
            if (t.status == "Completed" || t.status == "Duplicate") && didTriggerManual115Upload {
              break
            }
          } else if pollTick >= 4 {
            serverDownloadSucceeded = true
            break
          }

          try? await Task.sleep(nanoseconds: 1_200_000_000)
        }

        if serverDownloadSucceeded && !candidateFailed {
          break
        }
      }

      guard !Task.isCancelled else { return }

      var keywords: [String] = []
      if let outPath = matchedTask?.outputFile, !outPath.isEmpty {
        keywords.append((outPath as NSString).lastPathComponent)
      }
      if let tName = matchedTask?.name, !tName.isEmpty {
        keywords.append(tName)
      }
      keywords.append(taskTitle)
      keywords.append(videoName)

      // If all server download candidates failed, automatically fall back to 115 Official Cloud Offline Download (`离线下载` `add_task_url`)
      if !serverDownloadSucceeded {
        if let lixianResolved = await TvLocal115DirectClient.shared.try115CloudOfflineLixianFallback(
          candidateUrls: candidates.map { $0.url },
          searchKeywords: keywords,
          pipelineStartedAt: pipelineStartedAt,
          onProgressUpdate: { [weak self] stage, detail, prog in
            self?.accel115StageTitle = stage
            self?.accel115DetailText = detail
            self?.accel115Progress = prog
          }
        ) {
          guard !Task.isCancelled else { return }
          self.accel115Progress = 1.0
          self.is115Accelerating = false
          self.showToast("⚡ 已通过 115 云端离线完成加速：\(lixianResolved.fileName)")
          onResolved(lixianResolved.proxyStreamUrl, lixianResolved.directCdnUrl, lixianResolved.headers, lixianResolved.fileName)
          return
        }

        if let finalCheck = await TvLocal115DirectClient.shared.findAndResolveDirectPlayUrl(
          keywords: keywords,
          allowNewestRecentFallbackAfter: pipelineStartedAt
        ) {
          guard !Task.isCancelled else { return }
          self.accel115Progress = 1.0
          self.is115Accelerating = false
          self.showToast("⚡ 已切换至本地直连 115 高速播放：\(finalCheck.fileName)")
          onResolved(finalCheck.proxyStreamUrl, finalCheck.directCdnUrl, finalCheck.headers, finalCheck.fileName)
          return
        }

        self.is115Accelerating = false
        let errDetail = lastServerFailureReason.isEmpty
          ? "当前视频源防盗链限制了海外服务器下载，请切换其他线路后再试"
          : lastServerFailureReason
        self.showToast("服务器下载失败：\(errDetail)")
        return
      }

      // Step 4: Poll local 115 Cloud Drive (`TvLocal115DirectClient`) to get the official 115 domestic CDN direct URL
      self.accel115StageTitle = "阶段 3/3 · 正在从本地连接 115 获取高速直链..."
      self.accel115Progress = 0.92

      for attempt in 0..<25 {
        guard !Task.isCancelled else { return }
        self.accel115DetailText = attempt == 0
          ? "正在通过本地网络请求 115 官方直链..."
          : "正在等待 115 网盘完成文件索引 (\(attempt + 1)/25)..."

        if let resolved115 = await TvLocal115DirectClient.shared.findAndResolveDirectPlayUrl(
          keywords: keywords,
          allowNewestRecentFallbackAfter: pipelineStartedAt
        ) {
          guard !Task.isCancelled else { return }
          self.accel115Progress = 1.0
          self.is115Accelerating = false
          self.showToast("⚡ 已切换至本地直连 115 高速播放：\(resolved115.fileName)")
          onResolved(resolved115.proxyStreamUrl, resolved115.directCdnUrl, resolved115.headers, resolved115.fileName)
          return
        }

        // Also check if `/api/tasks` is still in `Uploading` state
        if let tid = createdTaskId, !tid.isEmpty {
          let tasks = await self.api.fetchDownloadTasks()
          if let t = tasks.first(where: { $0.id == tid }), t.status == "Uploading" {
            let upPct = max(1.0, min(99.5, t.progress))
            self.accel115StageTitle = "阶段 2/3 · 服务器正在上传视频至 115 网盘..."
            self.accel115Progress = 0.72 + (upPct / 100.0) * 0.20
            self.accel115DetailText = String(format: "上传 115 进度 %.1f%% · %@", upPct, t.name)
          }
        }

        try? await Task.sleep(nanoseconds: 1_500_000_000)
      }

      guard !Task.isCancelled else { return }
      self.is115Accelerating = false
      self.showToast("⚠️ 暂未在 115 网盘中找到已上传文件，请确认 115 账号已登录且空间充足")
    }
  }
}
