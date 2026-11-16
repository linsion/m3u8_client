import Foundation
import SwiftUI

@MainActor
final class TvAppState: ObservableObject {
  @Published var serverUrl: String
  @Published var authSecret: String
  @Published var enableAdFilter: Bool
  @Published var isAuthenticated: Bool = false
  @Published var isBootstrapping: Bool = false
  @Published var statusBanner: String? = nil

  // VOD
  @Published var vodSources: [TvVodSource] = []
  @Published var selectedSource: TvVodSource? = nil
  @Published var categories: [TvVodCategory] = []
  @Published var selectedCategoryId: String? = nil
  @Published var vodItems: [TvVodItem] = []
  @Published var currentPage: Int = 1
  @Published var totalPages: Int = 1
  @Published var isLoadingVod: Bool = false
  @Published var searchKeyword: String = ""
  @Published var isAggregateSearch: Bool = true

  // Detail & Active Playback
  @Published var selectedDetailItem: TvVodItem? = nil
  @Published var activePlayback: TvPlaybackRequest? = nil
  @Published var isResolvingPlay: Bool = false

  // Live TV
  @Published var liveSources: [TvLiveSource] = []
  @Published var selectedLiveSource: TvLiveSource? = nil
  @Published var liveChannels: [TvLiveChannel] = []
  @Published var selectedLiveGroup: String = "全部"
  @Published var isLoadingLive: Bool = false

  // Library
  @Published var favorites: [TvLibraryItem] = []
  @Published var history: [TvLibraryItem] = []

  // Telegram
  @Published var telegramAccounts: [TvTelegramAccount] = []
  @Published var activeTelegramAccountId: String = ""
  @Published var telegramChats: [TvTelegramChat] = []
  @Published var selectedTelegramChat: TvTelegramChat? = nil
  @Published var telegramMessages: [TvTelegramMessage] = []
  @Published var isLoadingTelegram: Bool = false

  private let defaults = UserDefaults.standard
  private var localProgress: [String: Double] = [:]

  var api: TvApiClient

  init() {
    let savedUrl = UserDefaults.standard.string(forKey: "tv_server_url") ?? "https://jp2.linsionwinwin.top:8081"
    let savedSecret = UserDefaults.standard.string(forKey: "tv_auth_secret") ?? ""
    let savedAdFilter = UserDefaults.standard.object(forKey: "tv_ad_filter") as? Bool ?? true
    self.serverUrl = savedUrl
    self.authSecret = savedSecret
    self.enableAdFilter = savedAdFilter
    self.localProgress = (UserDefaults.standard.dictionary(forKey: "tv_watch_progress") as? [String: Double]) ?? [:]
    self.api = TvApiClient(baseUrl: savedUrl, authSecret: savedSecret)
    self.isAuthenticated = !savedSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func saveConfig(newUrl: String, newSecret: String, adFilter: Bool) {
    let normalized = TvApiClient.normalizeBaseUrl(newUrl)
    let trimmedSecret = newSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    self.serverUrl = normalized
    self.authSecret = trimmedSecret
    self.enableAdFilter = adFilter
    defaults.set(normalized, forKey: "tv_server_url")
    defaults.set(trimmedSecret, forKey: "tv_auth_secret")
    defaults.set(adFilter, forKey: "tv_ad_filter")
    self.api = TvApiClient(baseUrl: normalized, authSecret: trimmedSecret)
  }

  func loginAndBootstrap(url: String, password: String) async -> Bool {
    isBootstrapping = true
    statusBanner = nil
    let normalized = TvApiClient.normalizeBaseUrl(url)
    let trimmedPwd = password.trimmingCharacters(in: .whitespacesAndNewlines)
    let client = TvApiClient(baseUrl: normalized, authSecret: trimmedPwd)
    let ok = await client.login(password: trimmedPwd)
    if ok {
      saveConfig(newUrl: normalized, newSecret: trimmedPwd, adFilter: enableAdFilter)
      isAuthenticated = true
      await bootstrapAll()
      isBootstrapping = false
      return true
    } else {
      // Allow testing direct connection even if /api/login is bypassed by cookie
      self.api = client
      if let sources = try? await client.fetchVodSources(), !sources.isEmpty {
        saveConfig(newUrl: normalized, newSecret: trimmedPwd, adFilter: enableAdFilter)
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
    }
  }

  func selectSource(_ source: TvVodSource) async {
    selectedSource = source
    defaults.set(source.id, forKey: "tv_selected_source_id")
    selectedCategoryId = nil
    searchKeyword = ""
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
    isLoadingVod = true
    defer { isLoadingVod = false }
    do {
      let res = try await api.fetchVodList(source: source, page: page, typeId: categoryId)
      if resetCategories || (categories.isEmpty && !res.categories.isEmpty) {
        self.categories = res.categories
      }
      self.vodItems = res.items
      self.currentPage = page
      self.totalPages = max(1, res.pageCount)
      self.statusBanner = nil
    } catch {
      self.statusBanner = "获取影片列表失败: \(error.localizedDescription)"
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
      self.currentPage = 1
      self.totalPages = 1
      return
    }

    let searchableSources = Array(vodSources.filter { $0.searchable }.prefix(14))
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
    self.currentPage = 1
    self.totalPages = 1
  }

  // MARK: - Playback & Progress

  func progressKey(vodId: String, episodeTitle: String) -> String {
    "\(vodId)@@\(episodeTitle)"
  }

  func savedPosition(vodId: String, episodeTitle: String) -> Double {
    localProgress[progressKey(vodId: vodId, episodeTitle: episodeTitle)] ?? 0
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
      pic: detail.vodPic,
      episode: episodeTitle,
      line: groupName,
      position: position,
      duration: max(duration, position),
      updatedAt: Int64(Date().timeIntervalSince1970)
    )
    if let idx = history.firstIndex(where: { $0.id == item.id }) {
      history[idx] = item
    } else {
      history.insert(item, at: 0)
    }
    Task {
      await api.updateLibrary(kind: "history", action: "upsert", item: item)
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

    let resolved = await api.resolvePlayback(
      source: source,
      playFrom: group.name,
      rawUrl: ep.rawUrl
    )
    let finalStream = await api.prepareAdFilteredStreamIfPossible(
      streamUrl: resolved.directUrl,
      headers: resolved.headers,
      enableAdFilter: enableAdFilter
    )
    var mergedHeaders = resolved.headers
    if finalStream.contains(serverUrl), !api.cookieHeaderValue.isEmpty {
      mergedHeaders["Cookie"] = api.cookieHeaderValue
    }

    let resumeSec = savedPosition(vodId: detail.vodId, episodeTitle: ep.title)
    self.activePlayback = TvPlaybackRequest(
      title: detail.vodName,
      subtitle: "\(group.name) · \(ep.title)",
      streamUrl: finalStream,
      backupProxyUrl: resolved.serverProxyUrl,
      headers: mergedHeaders,
      resumeSeconds: resumeSec,
      isLive: false,
      vodSource: source,
      vodDetail: detail,
      playGroupIndex: groupIndex,
      episodeIndex: episodeIndex
    )
  }

  // MARK: - Favorites & History

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
      pic: detail.vodPic,
      episode: detail.vodRemarks,
      line: detail.playGroups.first?.name ?? "",
      position: 0,
      duration: 0,
      updatedAt: Int64(Date().timeIntervalSince1970)
    )
    if isFavorite(source: source, vodId: detail.vodId) {
      favorites.removeAll(where: { $0.vodId == detail.vodId })
      await api.updateLibrary(kind: "favorites", action: "remove", item: item)
    } else {
      favorites.insert(item, at: 0)
      await api.updateLibrary(kind: "favorites", action: "upsert", item: item)
    }
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

  // MARK: - Live TV

  var liveGroups: [String] {
    var seen = Set<String>()
    var list: [String] = ["全部"]
    for ch in liveChannels {
      if !seen.contains(ch.group) {
        seen.insert(ch.group)
        list.append(ch.group)
      }
    }
    return list
  }

  var filteredLiveChannels: [TvLiveChannel] {
    if selectedLiveGroup == "全部" {
      return liveChannels
    }
    return liveChannels.filter { $0.group == selectedLiveGroup }
  }

  func loadLiveSources() async {
    let sources = await api.fetchLiveSources()
    self.liveSources = sources
    if let first = sources.first {
      await selectLiveSource(first)
    }
  }

  func selectLiveSource(_ source: TvLiveSource) async {
    selectedLiveSource = source
    selectedLiveGroup = "全部"
    isLoadingLive = true
    defer { isLoadingLive = false }
    self.liveChannels = await api.fetchLiveChannels(source: source)
  }

  func playLiveChannel(_ channel: TvLiveChannel, urlIndex: Int = 0) {
    guard !channel.urls.isEmpty else { return }
    let rawUrl = channel.urls[min(max(0, urlIndex), channel.urls.count - 1)]
    let proxy = api.buildServerProxyUrl(targetUrl: rawUrl, headers: channel.headers)
    self.activePlayback = TvPlaybackRequest(
      title: channel.name,
      subtitle: "电视直播 · \(channel.group)",
      streamUrl: rawUrl,
      backupProxyUrl: proxy,
      headers: channel.headers,
      resumeSeconds: 0,
      isLive: true,
      vodSource: nil,
      vodDetail: nil,
      playGroupIndex: 0,
      episodeIndex: 0
    )
  }

  // MARK: - Telegram

  func loadTelegramAccounts() async {
    let res = await api.fetchTelegramAccounts()
    self.telegramAccounts = res.accounts
    let targetId = !res.activeId.isEmpty ? res.activeId : (res.accounts.first?.id ?? "")
    self.activeTelegramAccountId = targetId
    if !targetId.isEmpty || !res.accounts.isEmpty {
      await loadTelegramChats(accountId: targetId)
    }
  }

  func loadTelegramChats(accountId: String) async {
    isLoadingTelegram = true
    defer { isLoadingTelegram = false }
    self.activeTelegramAccountId = accountId
    self.telegramChats = await api.fetchTelegramChats(accountId: accountId)
    if let first = telegramChats.first {
      await selectTelegramChat(first)
    }
  }

  func selectTelegramChat(_ chat: TvTelegramChat) async {
    selectedTelegramChat = chat
    isLoadingTelegram = true
    defer { isLoadingTelegram = false }
    self.telegramMessages = await api.fetchTelegramMessages(
      accountId: activeTelegramAccountId,
      peer: chat.peer
    )
  }

  func playTelegramVideo(chat: TvTelegramChat, message: TvTelegramMessage) {
    let streamUrl = api.telegramVideoUrl(
      accountId: activeTelegramAccountId,
      peer: chat.peer,
      messageId: message.id
    )
    guard !streamUrl.isEmpty else { return }
    self.activePlayback = TvPlaybackRequest(
      title: message.fileName.isEmpty ? chat.title : message.fileName,
      subtitle: "Telegram · \(chat.title)",
      streamUrl: streamUrl,
      backupProxyUrl: streamUrl,
      headers: api.authHeaders,
      resumeSeconds: 0,
      isLive: false,
      vodSource: nil,
      vodDetail: nil,
      playGroupIndex: 0,
      episodeIndex: 0
    )
  }
}
