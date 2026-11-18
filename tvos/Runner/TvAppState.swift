import AVFoundation
import Foundation
import Network
import SwiftUI

@MainActor
final class TvAppState: ObservableObject {
  static weak var shared: TvAppState? = nil
  @Published var serverUrl: String
  @Published var authSecret: String
  @Published var enableAdFilter: Bool
  @Published var preferDirectPlayback: Bool
  @Published var skipIntroSeconds: Int
  @Published var skipOutroSeconds: Int
  @Published var isAuthenticated: Bool = false
  @Published var isBootstrapping: Bool = false
  @Published var statusBanner: String? = nil
  @Published var toastMessage: String? = nil
  @Published var ambientBackdropUrl: String = ""
  @Published var selectedSection: TvMainSection = .vod
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
    api.handleEnterBackground()
    stopLanInputServer()
    TvTelegramAvatarMemoryCache.shared.handleAppLifecycleTransition(enteringBackground: true)
    if isAudioPlaying {
      audioPlayer?.pause()
    }
  }

  func handleDidBecomeActive() {
    guard isAppInBackground else { return }
    isAppInBackground = false
    lastRemoteActivityAt = Date()
    api.handleEnterForeground()
    TvTelegramAvatarMemoryCache.shared.handleAppLifecycleTransition(enteringBackground: false)
    // Defer media stream reconnection by 0.25s so the UI and focus system render the foreground frame in 0ms
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self = self, !self.isAppInBackground else { return }
      self.foregroundResumeTick &+= 1
      if self.isAudioPlaying {
        self.audioPlayer?.play()
      }
    }
  }

  var activeTheme: TvThemePalette {
    TvThemePalette.palette(for: themeId)
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
    guard now.timeIntervalSince(lastControlsManualHideAt) > 0.45 else { return }
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
  @Published var activePlayback: TvPlaybackRequest? = nil
  @Published var activeTelegramGallery: TvTelegramGallerySession? = nil
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
  @Published var miniPlayerMessage: TvTelegramMessage? = nil
  @Published var miniPlayerChat: TvTelegramChat? = nil

  // 5. Downloads & Web Extract
  @Published var downloadTasks: [TvDownloadTask] = []
  @Published var isLoadingTasks: Bool = false
  @Published var extractedCandidates: [TvExtractedCandidate] = []
  @Published var isExtractingWeb: Bool = false

  // 6. Server Media Library (/api/files)
  @Published var fileListing: TvFileListing = TvFileListing(path: "", parent: "", root: "/", entries: [])
  @Published var isLoadingFiles: Bool = false

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
      .vodStream: TvScenarioRuleConfig(scenario: .vodStream, mode: savedVodRoute == .serverRelay ? .serverRelay : .direct),
      .liveStream: TvScenarioRuleConfig(scenario: .liveStream, mode: savedLiveRoute == .serverRelay ? .serverRelay : .direct),
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
        if !fileListing.path.isEmpty && fileListing.path != fileListing.root {
          Task { await loadFiles(path: fileListing.parent) }
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
    //    Step 7a: If not on 影视点播 (.vod) -> Switch back to 影视点播 (`再继续返回影视点播`)!
    if selectedSection != .vod {
      selectedSection = .vod
      topBarFocusTrigger &+= 1
      return
    }

    //    Step 7b: Already on 影视点播 (.vod) in the Top Navigation Bar -> Exit Application (`再返回就是退出应用`)!
    exitApplicationHandler?()
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
      await loadFiles(path: "")
      await refresh115Status()
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
      let thresholdIdx = max(0, vodItems.count - 12)
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
    localProgress[progressKey(vodId: vodId, episodeTitle: episodeTitle)] ?? 0
  }

  func lastWatchedEpisode(for detail: TvVodDetail) -> (groupIndex: Int, episodeIndex: Int, episodeTitle: String, savedSec: Double)? {
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
    duration: Double
  ) {
    guard let detail = detail, position > 3 else { return }
    let key = progressKey(vodId: detail.vodId, episodeTitle: episodeTitle)
    localProgress[key] = position
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
      updated: Int64(Date().timeIntervalSince1970)
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

  func startEpisodePlayback(
    source: TvVodSource,
    detail: TvVodDetail,
    groupIndex: Int,
    episodeIndex: Int
  ) async {
    guard groupIndex >= 0, groupIndex < detail.playGroups.count else { return }
    let group = detail.playGroups[groupIndex]
    guard episodeIndex >= 0, episodeIndex < group.episodes.count else { return }
    let ep = group.episodes[episodeIndex]

    isResolvingPlay = true
    defer { isResolvingPlay = false }

    let forceRelay = shouldUseServerRelay(for: .vodStream) || !preferDirectPlayback
    let resolved = await api.resolvePlayback(
      source: source,
      playFrom: group.name,
      rawUrl: ep.rawUrl,
      forceServerRelay: forceRelay
    )
    let finalStream = await api.prepareAdFilteredStreamIfPossible(
      streamUrl: resolved.directUrl,
      headers: resolved.headers,
      enableAdFilter: enableAdFilter
    )
    var mergedHeaders = resolved.headers
    if mergedHeaders["Cookie"] == nil && !api.cookieHeaderValue.isEmpty {
      mergedHeaders["Cookie"] = api.cookieHeaderValue
    }

    let savedSec = savedPosition(vodId: detail.vodId, episodeTitle: ep.title)
    let resumeSec = savedSec > 5 ? savedSec : Double(skipIntroSeconds)

    self.playerControlsVisible = true
    self.playerShowEpisodeDrawer = false
    self.activePlayback = TvPlaybackRequest(
      title: detail.vodName,
      subtitle: "\(group.name) · \(ep.title) (\(resolved.parseVia))",
      streamUrl: finalStream,
      backupProxyUrl: resolved.serverProxyUrl,
      headers: mergedHeaders,
      resumeSeconds: resumeSec,
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
    let resolvedIndex = urlIndex ?? preferredLiveUrlIndex(for: channel)
    let idx = min(max(0, resolvedIndex), channel.urls.count - 1)
    recordLiveChannelSelection(channel: channel, urlIndex: idx)
    Task {
      let useRelay = shouldUseServerRelay(for: .liveStream)
      let resolved = await api.resolveLivePlayback(
        source: selectedLiveSource,
        channel: channel,
        urlIndex: idx,
        forceServerRelay: useRelay
      )
      var headers = resolved.headers
      if !api.cookieHeaderValue.isEmpty {
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
        liveUrlIndex: idx
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
      let cleanTitle = chat.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let titleKey = cleanTitle.isEmpty ? "" : "\(accountId)|\(cleanTitle)"

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
    selectedTelegramChat = chat
    telegramReplyingTo = nil
    telegramSelectionMode = false
    telegramSelectedMessageIds.removeAll()
    isLoadingTelegram = true
    defer { isLoadingTelegram = false }
    let res = await api.fetchTelegramMessages(accountId: activeTelegramAccountId, peer: chat.peer, offsetId: 0)
    self.telegramMessages = res.messages
    self.nextTelegramMessageOffset = res.nextOffset
    if chat.unread > 0 {
      await markChatAsRead(chat, maxId: res.messages.last?.id ?? 0)
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
    if isAudioPlaying {
      audioPlayer?.pause()
      isAudioPlaying = false
    }
    let visualMedia = telegramMessages.filter { $0.isVisualMedia }
    let items = visualMedia.isEmpty ? (albumMessages ?? [message]) : visualMedia
    let idx = items.firstIndex(where: { $0.id == message.id }) ?? 0
    self.galleryControlsVisible = true
    self.activeTelegramGallery = TvTelegramGallerySession(
      accountId: activeTelegramAccountId,
      chat: chat,
      mediaMessages: items,
      initialIndex: idx
    )
  }

  func openTelegramMiniPlayer(chat: TvTelegramChat, message: TvTelegramMessage) {
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
        player.playImmediately(atRate: audioSpeed)
        isAudioPlaying = true
      }
      return
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

  // MARK: - 7. Server Media Library (/api/files)

  func loadFiles(path: String) async {
    isLoadingFiles = true
    defer { isLoadingFiles = false }
    if let listing = try? await api.fetchFiles(path: path) {
      self.fileListing = listing
    }
  }

  func playMediaFile(_ entry: TvFileEntry) {
    let serverFileUrl = api.buildFileStreamUrl(path: entry.path)
    guard !serverFileUrl.isEmpty else { return }
    if TvLocal115DirectClient.shared.hasLocalCookie {
      Task {
        self.isResolvingPlay = true
        defer { self.isResolvingPlay = false }
        if let resolved115 = await TvLocal115DirectClient.shared.findAndResolveDirectPlayUrl(keywords: [entry.name]) {
          self.showToast("⚡ 已从本地直连 115 网盘播放：\(entry.name)")
          self.playerControlsVisible = true
          self.playerShowEpisodeDrawer = false
          self.activePlayback = TvPlaybackRequest(
            title: entry.name,
            subtitle: "115 本地直连 · \(entry.formattedSize)",
            streamUrl: resolved115.proxyStreamUrl,
            backupProxyUrl: serverFileUrl,
            headers: resolved115.headers,
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
        let localProxyServerFile = TvLocalHlsProxyServer.shared.prepareTelegramVideoProxyUrl(
          remoteUrl: serverFileUrl,
          headers: self.api.authHeaders
        )
        self.playDirectStream(
          title: entry.name,
          subtitle: "服务器媒体库 · \(entry.formattedSize)",
          url: localProxyServerFile,
          headers: self.api.authHeaders
        )
      }
      return
    }
    let localProxyServerFile = TvLocalHlsProxyServer.shared.prepareTelegramVideoProxyUrl(
      remoteUrl: serverFileUrl,
      headers: api.authHeaders
    )
    playDirectStream(
      title: entry.name,
      subtitle: "服务器媒体库 · \(entry.formattedSize)",
      url: localProxyServerFile,
      headers: api.authHeaders
    )
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

  /// Lowest latency node in active pool
  var fastestProxyNode: TvSubscriptionNode? {
    let pool = activePoolNodes
    let available = pool.filter { ($0.latencyMs ?? 9999) > 0 && ($0.latencyMs ?? 9999) < 9000 }
    if let best = available.min(by: { ($0.latencyMs ?? 9999) < ($1.latencyMs ?? 9999) }) {
      return best
    }
    return pool.first
  }

  /// Currently active global proxy node (respecting `autoFastest` vs `manual`)
  var activeProxyNode: TvSubscriptionNode? {
    let pool = activePoolNodes
    guard !pool.isEmpty else { return nil }
    if proxySelectionMode == .manual,
       !selectedProxyNodeId.isEmpty,
       let matched = pool.first(where: { $0.id == selectedProxyNodeId }) {
      return matched
    }
    if let fastest = fastestProxyNode {
      return fastest
    }
    if !selectedProxyNodeId.isEmpty,
       let matched = pool.first(where: { $0.id == selectedProxyNodeId }) {
      return matched
    }
    return pool.first
  }

  func setProxyEnabled(_ enabled: Bool) {
    proxyEnabled = enabled
    persistProxyState()
    showToast(enabled ? "⚡ 全局代理已开启" : "🌐 全局代理已关闭（跟随全局的场景将直连）")
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

  func selectManualNode(_ nodeId: String) {
    guard let node = subscriptionNodes.first(where: { $0.id == nodeId }) else { return }
    selectedProxyNodeId = node.id
    proxySelectionMode = .manual
    proxyEnabled = true
    persistProxyState()
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
    selectedProxyNodeId = node.id
    proxySelectionMode = .manual
    proxyEnabled = true
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

    // Keep legacy route mode properties synchronized
    switch scenario {
    case .vodStream:
      vodRouteMode = (current.mode == .direct) ? .direct : .serverRelay
      defaults.set(vodRouteMode.rawValue, forKey: "tv_route_vod")
    case .liveStream:
      liveRouteMode = (current.mode == .direct) ? .direct : .serverRelay
      defaults.set(liveRouteMode.rawValue, forKey: "tv_route_live")
    case .telegram:
      telegramRouteMode = (current.mode == .direct) ? .direct : .serverRelay
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
      telegramRouteMode = .serverRelay
      showToast("🚀 已应用「推荐智能分流」：海外/TG 走代理 · 国内点播/直播直连")

    case "follow_global":
      for sc in TvRequestScenario.allCases {
        scenarioRules[sc] = TvScenarioRuleConfig(scenario: sc, mode: .followGlobal)
      }
      showToast("🔄 已将全部 6 个场景设为「跟随全局开关」")

    case "telegram_only":
      proxyEnabled = true
      for sc in TvRequestScenario.allCases {
        let m: TvScenarioRouteMode = (sc == .telegram || sc == .externalWeb) ? .proxyNode : .direct
        scenarioRules[sc] = TvScenarioRuleConfig(scenario: sc, mode: m)
      }
      vodRouteMode = .direct
      liveRouteMode = .direct
      telegramRouteMode = .serverRelay
      showToast("✈️ 已设为「仅 Telegram 与订阅走代理」")

    case "all_proxy":
      proxyEnabled = true
      for sc in TvRequestScenario.allCases {
        scenarioRules[sc] = TvScenarioRuleConfig(scenario: sc, mode: sc == .backendApi ? .direct : .proxyNode)
      }
      vodRouteMode = .serverRelay
      liveRouteMode = .serverRelay
      telegramRouteMode = .serverRelay
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
  func resolveEffectiveRoute(for scenario: TvRequestScenario) -> TvScenarioRouteMode {
    let r = rule(for: scenario)
    switch r.mode {
    case .direct:
      return .direct
    case .serverRelay:
      return .serverRelay
    case .proxyNode:
      return activePoolNodes.isEmpty ? .serverRelay : .proxyNode
    case .smartAuto:
      if scenario == .telegram || scenario == .externalWeb {
        return activePoolNodes.isEmpty ? .serverRelay : .proxyNode
      }
      return .direct
    case .followGlobal:
      if !proxyEnabled { return .direct }
      return activePoolNodes.isEmpty ? .serverRelay : .proxyNode
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

  /// Handles selection from `TvVideoProxyNodeSelectorSheet` (matching `_onSelected` in `lib/ui/widgets/video_proxy_node_selector.dart`)
  func applyInPlayerProxyChoice(scenario: TvRequestScenario, choice: String) {
    if choice == "direct" {
      updateScenarioRule(scenario, mode: .direct, clearSpecificNode: true)
      showToast("🚫 「\(scenario.label)」已切换为直连播放")
    } else if choice == "auto_fastest" {
      proxyEnabled = true
      proxySelectionMode = .autoFastest
      if let best = fastestProxyNode {
        selectedProxyNodeId = best.id
      }
      updateScenarioRule(scenario, mode: .proxyNode, clearSpecificNode: true)
      let bestLabel = fastestProxyNode.map { "\($0.displayTitle) (\($0.formattedLatency))" } ?? "自动最快"
      showToast("⚡ 「\(scenario.label)」已切换为自动择优：\(bestLabel)")
    } else if choice == "server_relay" {
      updateScenarioRule(scenario, mode: .serverRelay, clearSpecificNode: true)
      showToast("🛡️ 「\(scenario.label)」已切换为服务端代理中转")
    } else if choice.hasPrefix("node:") {
      let nodeId = String(choice.dropFirst(5))
      proxyEnabled = true
      selectedProxyNodeId = nodeId
      updateScenarioRule(scenario, mode: .proxyNode, specificNodeId: nodeId)
      if let node = subscriptionNodes.first(where: { $0.id == nodeId }) {
        showToast("🎯 「\(scenario.label)」已切换至节点：\(node.displayTitle) (\(node.formattedLatency))")
      }
    }
  }

  nonisolated private static func pingNodesConcurrently(_ input: [TvSubscriptionNode], maxCount: Int) async -> [TvSubscriptionNode] {
    var nodes = input
    let countToPing = min(nodes.count, maxCount)
    guard countToPing > 0 else { return nodes }

    let results: [(Int, Int)] = await withTaskGroup(of: (Int, Int).self) { group in
      for idx in 0..<countToPing {
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
      let node = TvSubscriptionNode(
        id: "srv_\(idx)_\(svc.proto)_\(host)_\(svc.port)",
        name: svc.name.isEmpty ? "服务端 \(svc.proto.uppercased())" : svc.name,
        type: svc.proto.uppercased(),
        host: host,
        port: svc.port,
        subscriptionId: "server",
        subscriptionName: "流光服务端",
        rawUri: "\(svc.proto.lowercased())://\(host):\(svc.port)#\(svc.name)",
        latencyMs: nil
      )
      serverNodes.append(node)
    }
    serverNodes = await Self.pingNodesConcurrently(serverNodes, maxCount: 16)
    var merged = subscriptionNodes.filter { $0.subscriptionId != "server" }
    merged.insert(contentsOf: serverNodes, at: 0)
    merged.sort { a, b in
      if a.favorite != b.favorite { return a.favorite && !b.favorite }
      return (a.latencyMs ?? 9999) < (b.latencyMs ?? 9999)
    }
    self.subscriptionNodes = merged
    if selectedProxyNodeId.isEmpty || !merged.contains(where: { $0.id == selectedProxyNodeId }),
       let first = merged.first {
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

  private nonisolated static func handleLanHttpConnection(_ conn: NWConnection, appState: TvAppState) {
    conn.start(queue: .global(qos: .userInitiated))
    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
      guard let data = data, !data.isEmpty,
            let rawReq = String(data: data, encoding: .utf8) else {
        conn.cancel()
        return
      }

      let parts = rawReq.components(separatedBy: "\r\n\r\n")
      let headerPart = parts.first ?? ""
      let bodyPart = parts.dropFirst().joined(separator: "\r\n\r\n")
      let firstLine = headerPart.components(separatedBy: "\r\n").first ?? ""

      if firstLine.hasPrefix("POST /push") {
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
          let existingSummary = appState.subscriptions.map { "• \($0.name): \($0.maskedUrlSummary) (\($0.nodeCount) 节点)" }.joined(separator: "<br>")
          let okHtml = buildLanWebHtml(pushedSuccess: true, existingSubsHtml: existingSummary)
          sendHttpResponse(conn: conn, html: okHtml)
        }
      } else {
        Task { @MainActor in
          let existingSummary = appState.subscriptions.map { "• \($0.name): \($0.maskedUrlSummary) (\($0.nodeCount) 节点)" }.joined(separator: "<br>")
          let html = buildLanWebHtml(pushedSuccess: false, existingSubsHtml: existingSummary)
          sendHttpResponse(conn: conn, html: html)
        }
      }
    }
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

  private nonisolated static func buildLanWebHtml(pushedSuccess: Bool, existingSubsHtml: String) -> String {
    let banner = pushedSuccess
      ? "<div style='background:#184d30;border:1px solid #30d158;color:#fff;padding:14px 16px;border-radius:14px;margin-bottom:18px;font-weight:600;'>✅ 已成功添加到 Apple TV 多订阅列表！电视端正在自动拉取节点并测速。</div>"
      : ""
    let subListBox = existingSubsHtml.isEmpty
      ? ""
      : "<div style='background:#11131A;border:1px solid #2B3042;border-radius:12px;padding:10px 12px;margin-bottom:14px;font-size:12px;color:#A5ADBA;line-height:1.6;'><strong style='color:#FFB340;'>电视端已配置的订阅源：</strong><br>\(existingSubsHtml)</div>"
    return """
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
      <title>流光视频 · Apple TV 多订阅与配置推送</title>
      <style>
        * { box-sizing: border-box; }
        body {
          margin: 0; padding: 20px;
          background: #0B0C10; color: #F5F6FA;
          font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif;
        }
        .card {
          max-width: 540px; margin: 0 auto;
          background: #191C26; border: 1px solid #2E3446;
          border-radius: 20px; padding: 22px;
          box-shadow: 0 12px 32px rgba(0,0,0,0.45);
        }
        h2 { margin: 0 0 6px 0; font-size: 21px; color: #FF9F0A; }
        p.sub { margin: 0 0 14px 0; font-size: 13px; color: #9EA3B0; line-height: 1.45; }
        label { display: block; font-size: 14px; font-weight: 600; margin: 12px 0 6px 0; color: #E2E6F0; }
        textarea, input {
          width: 100%; background: #11131A; color: #fff;
          border: 1px solid #343A4D; border-radius: 12px;
          padding: 12px; font-size: 15px; outline: none;
        }
        textarea:focus, input:focus { border-color: #FF9F0A; }
        button {
          margin-top: 20px; width: 100%;
          background: linear-gradient(135deg, #FF9F0A, #FF7A00);
          color: #fff; font-weight: 700; font-size: 16px;
          border: none; border-radius: 14px; padding: 14px;
          cursor: pointer;
        }
      </style>
    </head>
    <body>
      <div class="card">
        <h2>📺 流光视频 · 多订阅与节点推送</h2>
        <p class="sub">支持添加多个机场订阅（每行粘贴一个 https://、clash://、sub:// 订阅链接，或直接粘贴 vmess:// / vless:// / ss:// / trojan:// / hy2:// 节点链接），发送后将自动加入 Apple TV 订阅池并并发测速。</p>
        \(banner)
        \(subListBox)
        <form method="POST" action="/push">
          <label>1. 订阅备注名称（选填，例如：主力机场 / 专线订阅）</label>
          <input type="text" name="sub_name" placeholder="不填则自动提取域名作为订阅名称" />
          <label>2. 订阅链接或节点直链（支持一次粘贴多个，每行一个）</label>
          <textarea name="sub_url" rows="4" placeholder="在此粘贴 https://... 订阅地址（可多行添加多个订阅）或 vmess:// / ss:// 节点链接"></textarea>
          <label>3. 115 网盘 Cookie（选填）</label>
          <input type="text" name="cookie_115" placeholder="UID=...; CID=...; SEID=..." />
          <label>4. 流光服务端地址（选填）</label>
          <input type="text" name="server_url" placeholder="例如 https://jp2.linsionwinwin.top:8081" />
          <button type="submit">🚀 推送到 Apple TV 订阅列表并测速</button>
        </form>
      </div>
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
    let start = DispatchTime.now()
    let serialQueue = DispatchQueue(label: "com.linsion.tvos.tcpping")
    return await withCheckedContinuation { cont in
      let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
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
      serialQueue.asyncAfter(deadline: .now() + 1.1) {
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

  /// Full 3-stage pipeline:
  /// 1) Checks if the video is already in 115 Cloud Drive (instant switch if found)
  /// 2) Instructs the server to download the video (`POST /api/download`) and monitors real-time progress (`/api/tasks`)
  /// 3) Waits for 115 upload (`Uploading` / `/api/115/upload/:id` / CloudDrive2 sync), then resolves the official 115 domestic CDN direct link locally from Apple TV (`TvLocal115DirectClient`) and invokes `onResolved`!
  func start115AcceleratedPlayback(
    downloadUrl: String,
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

      // Ensure backend server also has our local 115 Cookie so server-side 115 rapid/API upload works
      if TvLocal115DirectClient.shared.hasLocalCookie {
        try? await self.api.login115WithCookie(cookie: TvLocal115DirectClient.shared.savedCookie)
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

      // Step 2: Create or attach to server download task (`POST /api/download`)
      self.accel115StageTitle = "阶段 1/3 · 正在提交服务器高速下载任务..."
      self.accel115DetailText = taskTitle
      self.accel115Progress = 0.10

      var createdTaskId: String? = nil
      do {
        createdTaskId = try await self.api.createDownloadTask(
          url: downloadUrl,
          name: taskTitle,
          headers: headers,
          telegramAccountId: telegramAccountId
        )
      } catch {
        guard !Task.isCancelled else { return }
        self.is115Accelerating = false
        self.showToast("提交服务器下载失败：\(error.localizedDescription)")
        return
      }

      // Step 3: Poll `/api/tasks` until server download & 115 upload complete
      var matchedTask: TvDownloadTask? = nil
      var didTriggerManual115Upload = false

      for pollTick in 0..<600 {
        guard !Task.isCancelled else { return }
        let tasks = await self.api.fetchDownloadTasks()
        self.downloadTasks = tasks

        if let tid = createdTaskId, !tid.isEmpty,
           let byId = tasks.first(where: { $0.id == tid }) {
          matchedTask = byId
        } else if let byNameOrUrl = tasks.first(where: { $0.name == taskTitle || $0.url == downloadUrl }) {
          matchedTask = byNameOrUrl
          createdTaskId = byNameOrUrl.id
        }

        if let t = matchedTask {
          switch t.status {
          case "Pending", "Downloading":
            let pct = max(1.0, min(99.5, t.progress))
            self.accel115StageTitle = "阶段 1/3 · 服务器正在高速下载该视频..."
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
            if !didTriggerManual115Upload {
              didTriggerManual115Upload = true
              // If the server skipped API upload or only moved to local mount, also trigger explicit 115 API upload
              if t.error.lowercased().contains("115") || !t.outputFile.isEmpty {
                self.accel115StageTitle = "阶段 2/3 · 正在同步视频至 115 网盘..."
                self.accel115Progress = 0.76
                self.accel115DetailText = "正在触发 115 秒传 / 接口上传..."
                try? await self.api.uploadTaskTo115(id: t.id)
                if !t.outputFile.isEmpty {
                  try? await self.api.uploadFileTo115(path: t.outputFile)
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                // Re-check if task entered Uploading state
                let refreshed = await self.api.fetchDownloadTasks()
                if let reTask = refreshed.first(where: { $0.id == t.id }), reTask.status == "Uploading" {
                  continue
                }
              }
            }
            break

          case "Failed":
            self.is115Accelerating = false
            self.showToast("服务器下载或上传失败：\(t.error.isEmpty ? "请检查资源链接" : t.error)")
            return

          default:
            break
          }

          if (t.status == "Completed" || t.status == "Duplicate") && didTriggerManual115Upload {
            break
          }
        } else if pollTick >= 4 {
          // Task may have completed and been moved immediately
          break
        }

        try? await Task.sleep(nanoseconds: 1_200_000_000)
      }

      guard !Task.isCancelled else { return }

      // Step 4: Poll local 115 Cloud Drive (`TvLocal115DirectClient`) to get the official 115 domestic CDN direct URL
      self.accel115StageTitle = "阶段 3/3 · 正在从本地连接 115 获取高速直链..."
      self.accel115Progress = 0.92
      var keywords: [String] = []
      if let outPath = matchedTask?.outputFile, !outPath.isEmpty {
        keywords.append((outPath as NSString).lastPathComponent)
      }
      if let tName = matchedTask?.name, !tName.isEmpty {
        keywords.append(tName)
      }
      keywords.append(taskTitle)
      keywords.append(videoName)

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
