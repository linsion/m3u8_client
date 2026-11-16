import AVFoundation
import GameController
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    configureAudioSession()
    configureSiriRemote()
    return true
  }

  private func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .moviePlayback, options: [])
      try session.setActive(true)
    } catch {
      NSLog("[tvOS] AVAudioSession setup failed: \(error)")
    }
  }

  private func configureSiriRemote() {
    GCController.shouldMonitorBackgroundEvents = false
    for controller in GCController.controllers() {
      controller.microGamepad?.allowsRotation = false
      controller.microGamepad?.reportsAbsoluteDpadValues = false
    }
  }
}

@main
struct LiuguangTvApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  @StateObject private var appState = TvAppState()

  var body: some Scene {
    WindowGroup {
      TvRootView()
        .environmentObject(appState)
        .preferredColorScheme(.dark)
    }
  }
}

struct TvRootView: View {
  @EnvironmentObject var appState: TvAppState

  var body: some View {
    Group {
      if !appState.isAuthenticated {
        TvLoginView()
      } else {
        TabView {
          TvVodHomeView()
            .tabItem {
              Label("影视点播", systemImage: "film.stack")
            }
          TvLiveView()
            .tabItem {
              Label("电视直播", systemImage: "tv")
            }
          TvLibraryView()
            .tabItem {
              Label("收藏与历史", systemImage: "bookmark.fill")
            }
          TvTelegramView()
            .tabItem {
              Label("Telegram", systemImage: "paperplane.fill")
            }
          TvSettingsView()
            .tabItem {
              Label("设置", systemImage: "gearshape.fill")
            }
        }
        .task {
          if appState.vodSources.isEmpty {
            await appState.bootstrapAll()
          }
        }
      }
    }
    .sheet(item: $appState.selectedDetailItem) { item in
      TvVodDetailSheet(item: item)
        .environmentObject(appState)
    }
    .fullScreenCover(item: $appState.activePlayback) { req in
      TvPlayerModalView(request: req)
        .environmentObject(appState)
    }
  }
}

// MARK: - Login View

struct TvLoginView: View {
  @EnvironmentObject var appState: TvAppState
  @State private var urlInput: String = ""
  @State private var pwdInput: String = ""

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          Color(red: 0.05, green: 0.06, blue: 0.12),
          Color(red: 0.09, green: 0.08, blue: 0.20),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      VStack(spacing: 32) {
        HStack(spacing: 18) {
          Image(systemName: "play.tv.fill")
            .font(.system(size: 58))
            .foregroundColor(.indigo)
          VStack(alignment: .leading, spacing: 6) {
            Text("流光视频 Apple TV")
              .font(.largeTitle)
              .bold()
            Text("原生 tvOS 客户端 · 支持点播去广告 / 电视直播 / 媒体库同步 / Telegram")
              .font(.headline)
              .foregroundColor(.secondary)
          }
        }

        VStack(alignment: .leading, spacing: 20) {
          Text("服务器地址")
            .font(.headline)
          TextField("https://jp2.linsionwinwin.top:8081", text: $urlInput)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

          Text("访问密码")
            .font(.headline)
          SecureField("请输入服务器访问密码", text: $pwdInput)
        }
        .frame(maxWidth: 860)
        .padding(36)
        .background(Color.white.opacity(0.06))
        .cornerRadius(24)

        if let banner = appState.statusBanner {
          Text(banner)
            .foregroundColor(.red)
            .font(.callout)
        }

        Button {
          Task {
            _ = await appState.loginAndBootstrap(url: urlInput, password: pwdInput)
          }
        } label: {
          HStack(spacing: 12) {
            if appState.isBootstrapping {
              ProgressView()
            }
            Text(appState.isBootstrapping ? "正在连接服务器..." : "连接并进入流光视频")
              .font(.title3)
              .bold()
          }
          .padding(.horizontal, 42)
          .padding(.vertical, 16)
        }
        .disabled(appState.isBootstrapping)
      }
      .padding(60)
    }
    .onAppear {
      urlInput = appState.serverUrl
      pwdInput = appState.authSecret
    }
  }
}

// MARK: - VOD Home View

struct TvVodHomeView: View {
  @EnvironmentObject var appState: TvAppState
  @State private var showSourcePicker = false

  private let gridColumns = [
    GridItem(.adaptive(minimum: 250, maximum: 300), spacing: 36)
  ]

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 22) {
        // Top Toolbar: Source Picker + Search Bar + Pagination
        HStack(spacing: 20) {
          Button {
            showSourcePicker = true
          } label: {
            HStack(spacing: 10) {
              Image(systemName: "server.rack")
              Text(appState.selectedSource?.displayName ?? "选择影视源")
                .lineLimit(1)
            }
          }

          TextField("输入片名搜索...", text: $appState.searchKeyword)
            .frame(maxWidth: 460)
            .onSubmit {
              Task { await appState.performSearch() }
            }

          Button {
            Task { await appState.performSearch() }
          } label: {
            Label("搜索", systemImage: "magnifyingglass")
          }

          Toggle("聚合搜索", isOn: $appState.isAggregateSearch)
            .frame(width: 220)

          Spacer()

          if appState.totalPages > 1 {
            HStack(spacing: 14) {
              Button {
                guard let src = appState.selectedSource, appState.currentPage > 1 else { return }
                Task {
                  await appState.loadVodList(
                    source: src,
                    page: appState.currentPage - 1,
                    categoryId: appState.selectedCategoryId,
                    resetCategories: false
                  )
                }
              } label: {
                Image(systemName: "chevron.left")
              }
              .disabled(appState.currentPage <= 1 || appState.isLoadingVod)

              Text("\(appState.currentPage) / \(appState.totalPages)")
                .font(.callout)
                .monospacedDigit()

              Button {
                guard let src = appState.selectedSource, appState.currentPage < appState.totalPages else { return }
                Task {
                  await appState.loadVodList(
                    source: src,
                    page: appState.currentPage + 1,
                    categoryId: appState.selectedCategoryId,
                    resetCategories: false
                  )
                }
              } label: {
                Image(systemName: "chevron.right")
              }
              .disabled(appState.currentPage >= appState.totalPages || appState.isLoadingVod)
            }
          }
        }

        // Category Strip
        if !appState.categories.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
              Button {
                Task { await appState.selectCategory(nil) }
              } label: {
                Text("全部")
                  .fontWeight(appState.selectedCategoryId == nil ? .bold : .regular)
              }

              ForEach(appState.categories) { cat in
                Button {
                  Task { await appState.selectCategory(cat.typeId) }
                } label: {
                  Text(cat.typeName)
                    .fontWeight(appState.selectedCategoryId == cat.typeId ? .bold : .regular)
                }
              }
            }
            .padding(.vertical, 6)
          }
        }

        // Content Grid
        if appState.isLoadingVod || appState.isBootstrapping {
          Spacer()
          HStack {
            Spacer()
            ProgressView("正在加载影片...")
              .font(.title3)
            Spacer()
          }
          Spacer()
        } else if appState.vodItems.isEmpty {
          Spacer()
          HStack {
            Spacer()
            VStack(spacing: 16) {
              Image(systemName: "film")
                .font(.system(size: 56))
                .foregroundColor(.secondary)
              Text(appState.statusBanner ?? "暂无影片数据，请切换影视源或重试")
                .foregroundColor(.secondary)
              if let src = appState.selectedSource {
                Button("重新加载") {
                  Task {
                    await appState.loadVodList(
                      source: src,
                      page: 1,
                      categoryId: appState.selectedCategoryId,
                      resetCategories: true
                    )
                  }
                }
              }
            }
            Spacer()
          }
          Spacer()
        } else {
          ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 44) {
              ForEach(appState.vodItems) { item in
                Button {
                  if item.isSearchJumpItem {
                    appState.searchKeyword = item.vodName
                    Task { await appState.performSearch() }
                  } else {
                    appState.selectedDetailItem = item
                  }
                } label: {
                  TvPosterCard(
                    title: item.vodName,
                    subtitle: item.vodRemarks.isEmpty ? item.typeName : item.vodRemarks,
                    badge: item.source?.name ?? "",
                    picUrl: item.vodPic
                  )
                }
                .buttonStyle(.card)
              }
            }
            .padding(.vertical, 20)
          }
        }
      }
      .padding(.horizontal, 48)
      .padding(.top, 24)
      .sheet(isPresented: $showSourcePicker) {
        TvSourcePickerSheet(isPresented: $showSourcePicker)
          .environmentObject(appState)
      }
    }
  }
}

struct TvSourcePickerSheet: View {
  @EnvironmentObject var appState: TvAppState
  @Binding var isPresented: Bool

  private let columns = [
    GridItem(.adaptive(minimum: 340, maximum: 420), spacing: 24)
  ]

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVGrid(columns: columns, spacing: 24) {
          ForEach(appState.vodSources) { src in
            Button {
              isPresented = false
              Task { await appState.selectSource(src) }
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 6) {
                  Text(src.displayName)
                    .font(.headline)
                    .lineLimit(1)
                  Text(src.isTvBox ? "TVBox 站点" : "自定义 CMS 源")
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                Spacer()
                if appState.selectedSource?.id == src.id {
                  Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                }
              }
              .padding(20)
            }
          }
        }
        .padding(48)
      }
      .navigationTitle("切换影视源 (\(appState.vodSources.count))")
    }
  }
}

// MARK: - Poster Card

struct TvPosterCard: View {
  let title: String
  let subtitle: String
  let badge: String
  let picUrl: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ZStack(alignment: .topTrailing) {
        AsyncImage(url: URL(string: picUrl)) { phase in
          switch phase {
          case .success(let image):
            image
              .resizable()
              .scaledToFill()
          default:
            ZStack {
              Color.white.opacity(0.08)
              Image(systemName: "film")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            }
          }
        }
        .frame(width: 260, height: 360)
        .clipped()
        .cornerRadius(16)

        if !badge.isEmpty {
          Text(badge)
            .font(.caption2)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.75))
            .cornerRadius(8)
            .padding(10)
        }
      }

      Text(title)
        .font(.headline)
        .lineLimit(1)
        .frame(width: 260, alignment: .leading)

      if !subtitle.isEmpty {
        Text(subtitle)
          .font(.caption)
          .foregroundColor(.secondary)
          .lineLimit(1)
          .frame(width: 260, alignment: .leading)
      }
    }
  }
}

// MARK: - VOD Detail & Episode Selector Sheet

struct TvVodDetailSheet: View {
  @EnvironmentObject var appState: TvAppState
  let item: TvVodItem

  @State private var detail: TvVodDetail? = nil
  @State private var isLoading = true
  @State private var errorText: String? = nil
  @State private var selectedGroupIndex: Int = 0

  private let epColumns = [
    GridItem(.adaptive(minimum: 210, maximum: 260), spacing: 20)
  ]

  private var activeSource: TvVodSource? {
    item.source ?? appState.selectedSource ?? appState.vodSources.first
  }

  var body: some View {
    NavigationStack {
      Group {
        if isLoading {
          ProgressView("正在加载影片详情与选集...")
            .font(.title3)
        } else if let detail = detail {
          ScrollView {
            VStack(alignment: .leading, spacing: 34) {
              // Header info
              HStack(alignment: .top, spacing: 40) {
                AsyncImage(url: URL(string: detail.vodPic.isEmpty ? item.vodPic : detail.vodPic)) { phase in
                  if case .success(let img) = phase {
                    img.resizable().scaledToFill()
                  } else {
                    ZStack {
                      Color.white.opacity(0.08)
                      Image(systemName: "film").font(.largeTitle)
                    }
                  }
                }
                .frame(width: 300, height: 420)
                .clipped()
                .cornerRadius(20)

                VStack(alignment: .leading, spacing: 16) {
                  Text(detail.vodName)
                    .font(.largeTitle)
                    .bold()

                  HStack(spacing: 16) {
                    if !detail.vodYear.isEmpty {
                      Text(detail.vodYear).foregroundColor(.secondary)
                    }
                    if !detail.vodArea.isEmpty {
                      Text(detail.vodArea).foregroundColor(.secondary)
                    }
                    if !detail.typeName.isEmpty {
                      Text(detail.typeName).foregroundColor(.secondary)
                    }
                    if !detail.vodRemarks.isEmpty {
                      Text(detail.vodRemarks).foregroundColor(.indigo)
                    }
                  }
                  .font(.headline)

                  if !detail.vodActor.isEmpty {
                    Text("主演：\(detail.vodActor)")
                      .font(.subheadline)
                      .foregroundColor(.secondary)
                      .lineLimit(2)
                  }

                  if !detail.vodContent.isEmpty {
                    Text(detail.vodContent)
                      .font(.body)
                      .foregroundColor(.secondary)
                      .lineLimit(5)
                  }

                  HStack(spacing: 24) {
                    if let src = activeSource,
                       selectedGroupIndex < detail.playGroups.count,
                       !detail.playGroups[selectedGroupIndex].episodes.isEmpty {
                      Button {
                        Task {
                          await appState.startEpisodePlayback(
                            source: src,
                            detail: detail,
                            groupIndex: selectedGroupIndex,
                            episodeIndex: 0
                          )
                        }
                      } label: {
                        Label(
                          appState.isResolvingPlay ? "正在解析播放地址..." : "立即播放",
                          systemImage: "play.fill"
                        )
                      }
                      .disabled(appState.isResolvingPlay)
                    }

                    if let src = activeSource {
                      let fav = appState.isFavorite(source: src, vodId: detail.vodId)
                      Button {
                        Task { await appState.toggleFavorite(source: src, detail: detail) }
                      } label: {
                        Label(
                          fav ? "已收藏" : "加入收藏",
                          systemImage: fav ? "star.fill" : "star"
                        )
                      }
                    }
                  }
                  .padding(.top, 10)
                }
              }

              // Play group tabs
              if !detail.playGroups.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                  Text("播放线路")
                    .font(.title3)
                    .bold()

                  ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                      ForEach(Array(detail.playGroups.enumerated()), id: \.offset) { idx, group in
                        Button {
                          selectedGroupIndex = idx
                        } label: {
                          Text("\(group.name) (\(group.episodes.count))")
                            .fontWeight(selectedGroupIndex == idx ? .bold : .regular)
                        }
                      }
                    }
                    .padding(.vertical, 6)
                  }
                }

                // Episodes grid
                if selectedGroupIndex < detail.playGroups.count {
                  let group = detail.playGroups[selectedGroupIndex]
                  VStack(alignment: .leading, spacing: 16) {
                    Text("选集列表 (\(group.episodes.count))")
                      .font(.title3)
                      .bold()

                    LazyVGrid(columns: epColumns, spacing: 20) {
                      ForEach(group.episodes) { ep in
                        Button {
                          guard let src = activeSource else { return }
                          Task {
                            await appState.startEpisodePlayback(
                              source: src,
                              detail: detail,
                              groupIndex: selectedGroupIndex,
                              episodeIndex: ep.index
                            )
                          }
                        } label: {
                          HStack {
                            Text(ep.title)
                              .lineLimit(1)
                            Spacer()
                            if appState.savedPosition(vodId: detail.vodId, episodeTitle: ep.title) > 5 {
                              Image(systemName: "clock.fill")
                                .font(.caption)
                                .foregroundColor(.indigo)
                            }
                          }
                          .frame(maxWidth: .infinity)
                        }
                        .disabled(appState.isResolvingPlay)
                      }
                    }
                  }
                }
              } else {
                Text("当前源未返回可播放剧集")
                  .foregroundColor(.secondary)
              }
            }
            .padding(54)
          }
        } else {
          VStack(spacing: 20) {
            Text(errorText ?? "无法获取详情")
              .foregroundColor(.secondary)
            Button("重试") {
              Task { await loadDetail() }
            }
          }
        }
      }
      .task {
        await loadDetail()
      }
    }
  }

  private func loadDetail() async {
    guard let src = activeSource else {
      errorText = "未找到可用影视源"
      isLoading = false
      return
    }
    isLoading = true
    defer { isLoading = false }
    do {
      self.detail = try await appState.api.fetchVodDetail(source: src, vodId: item.vodId)
      if self.detail == nil {
        errorText = "该影片暂无详情数据"
      }
    } catch {
      errorText = error.localizedDescription
    }
  }
}

// MARK: - Live TV View

struct TvLiveView: View {
  @EnvironmentObject var appState: TvAppState

  private let columns = [
    GridItem(.adaptive(minimum: 320, maximum: 380), spacing: 28)
  ]

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 24) {
        // Live Source Selector
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 16) {
            ForEach(appState.liveSources) { src in
              Button {
                Task { await appState.selectLiveSource(src) }
              } label: {
                Label(src.name, systemImage: "dot.radiowaves.left.and.right")
                  .fontWeight(appState.selectedLiveSource?.id == src.id ? .bold : .regular)
              }
            }
          }
          .padding(.vertical, 6)
        }

        // Channel Group Selector
        if appState.liveGroups.count > 1 {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
              ForEach(appState.liveGroups, id: \.self) { groupName in
                Button {
                  appState.selectedLiveGroup = groupName
                } label: {
                  Text(groupName)
                    .fontWeight(appState.selectedLiveGroup == groupName ? .bold : .regular)
                }
              }
            }
            .padding(.vertical, 6)
          }
        }

        if appState.isLoadingLive {
          Spacer()
          HStack {
            Spacer()
            ProgressView("正在加载直播频道...")
            Spacer()
          }
          Spacer()
        } else if appState.filteredLiveChannels.isEmpty {
          Spacer()
          HStack {
            Spacer()
            VStack(spacing: 16) {
              Image(systemName: "tv.slash")
                .font(.system(size: 52))
                .foregroundColor(.secondary)
              Text("暂无直播频道")
                .foregroundColor(.secondary)
              Button("刷新直播源") {
                Task { await appState.loadLiveSources() }
              }
            }
            Spacer()
          }
          Spacer()
        } else {
          ScrollView {
            LazyVGrid(columns: columns, spacing: 28) {
              ForEach(appState.filteredLiveChannels) { ch in
                Button {
                  appState.playLiveChannel(ch)
                } label: {
                  HStack(spacing: 18) {
                    Image(systemName: "play.tv.fill")
                      .font(.title2)
                      .foregroundColor(.indigo)
                    VStack(alignment: .leading, spacing: 6) {
                      Text(ch.name)
                        .font(.headline)
                        .lineLimit(1)
                      Text("\(ch.group) · \(ch.urls.count) 条线路")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    Spacer()
                  }
                  .padding(20)
                }
              }
            }
            .padding(.vertical, 16)
          }
        }
      }
      .padding(.horizontal, 48)
      .padding(.top, 24)
    }
  }
}

// MARK: - Library (Favorites & History) View

struct TvLibraryView: View {
  @EnvironmentObject var appState: TvAppState
  @State private var mode: Int = 0

  private let gridColumns = [
    GridItem(.adaptive(minimum: 250, maximum: 300), spacing: 36)
  ]

  var activeItems: [TvLibraryItem] {
    mode == 0 ? appState.history : appState.favorites
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 24) {
        HStack(spacing: 20) {
          Button {
            mode = 0
          } label: {
            Label("观看历史 (\(appState.history.count))", systemImage: "clock.fill")
          }

          Button {
            mode = 1
          } label: {
            Label("我的收藏 (\(appState.favorites.count))", systemImage: "star.fill")
          }

          Spacer()

          Button {
            Task { await appState.refreshLibrary() }
          } label: {
            Label("同步云端", systemImage: "arrow.triangle.2.circlepath")
          }
        }

        if activeItems.isEmpty {
          Spacer()
          HStack {
            Spacer()
            Text(mode == 0 ? "暂无观看历史" : "暂无收藏影片")
              .foregroundColor(.secondary)
            Spacer()
          }
          Spacer()
        } else {
          ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 44) {
              ForEach(activeItems) { libItem in
                Button {
                  let resolvedSrc = appState.resolveSourceForLibraryItem(libItem)
                  appState.selectedDetailItem = TvVodItem(
                    vodId: libItem.vodId,
                    vodName: libItem.title,
                    vodPic: libItem.pic,
                    vodRemarks: libItem.episode,
                    vodYear: "",
                    typeName: libItem.line,
                    source: resolvedSrc
                  )
                } label: {
                  TvPosterCard(
                    title: libItem.title,
                    subtitle: libItem.episode.isEmpty ? libItem.line : "\(libItem.line) · \(libItem.episode)",
                    badge: libItem.sourceName,
                    picUrl: libItem.pic
                  )
                }
                .buttonStyle(.card)
              }
            }
            .padding(.vertical, 20)
          }
        }
      }
      .padding(.horizontal, 48)
      .padding(.top, 24)
    }
  }
}

// MARK: - Telegram View

struct TvTelegramView: View {
  @EnvironmentObject var appState: TvAppState

  var videoMessages: [TvTelegramMessage] {
    appState.telegramMessages.filter { $0.isVideo }
  }

  var body: some View {
    NavigationStack {
      HStack(spacing: 32) {
        // Left Column: Chats
        VStack(alignment: .leading, spacing: 18) {
          HStack {
            Text("Telegram 频道/对话")
              .font(.title3)
              .bold()
            Spacer()
            Button {
              Task { await appState.loadTelegramAccounts() }
            } label: {
              Image(systemName: "arrow.clockwise")
            }
          }

          if appState.telegramChats.isEmpty {
            Spacer()
            Text("暂无已登录的 Telegram 会话")
              .foregroundColor(.secondary)
            Spacer()
          } else {
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(appState.telegramChats) { chat in
                  Button {
                    Task { await appState.selectTelegramChat(chat) }
                  } label: {
                    VStack(alignment: .leading, spacing: 6) {
                      Text(chat.title)
                        .font(.headline)
                        .lineLimit(1)
                      if !chat.lastMessage.isEmpty {
                        Text(chat.lastMessage)
                          .font(.caption)
                          .foregroundColor(.secondary)
                          .lineLimit(1)
                      }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                  }
                }
              }
            }
          }
        }
        .frame(width: 480)

        // Right Column: Videos in Selected Chat
        VStack(alignment: .leading, spacing: 18) {
          Text(appState.selectedTelegramChat?.title ?? "视频消息")
            .font(.title3)
            .bold()

          if appState.isLoadingTelegram {
            Spacer()
            HStack {
              Spacer()
              ProgressView("正在读取消息...")
              Spacer()
            }
            Spacer()
          } else if videoMessages.isEmpty {
            Spacer()
            HStack {
              Spacer()
              Text("当前会话暂无可直接播放的视频消息")
                .foregroundColor(.secondary)
              Spacer()
            }
            Spacer()
          } else {
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(videoMessages) { msg in
                  Button {
                    if let chat = appState.selectedTelegramChat {
                      appState.playTelegramVideo(chat: chat, message: msg)
                    }
                  } label: {
                    HStack(spacing: 20) {
                      Image(systemName: "play.rectangle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.indigo)
                      VStack(alignment: .leading, spacing: 6) {
                        Text(msg.text.isEmpty ? msg.fileName : msg.text)
                          .font(.headline)
                          .lineLimit(2)
                        HStack(spacing: 16) {
                          if !msg.fileSize.isEmpty {
                            Text(msg.fileSize)
                          }
                          if msg.duration > 0 {
                            Text("\(msg.duration) 秒")
                          }
                          if !msg.date.isEmpty {
                            Text(msg.date)
                          }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                      }
                      Spacer()
                    }
                    .padding(18)
                  }
                }
              }
            }
          }
        }
      }
      .padding(.horizontal, 48)
      .padding(.top, 24)
    }
  }
}

// MARK: - Settings View

struct TvSettingsView: View {
  @EnvironmentObject var appState: TvAppState
  @State private var urlInput: String = ""
  @State private var secretInput: String = ""
  @State private var adFilterToggle: Bool = true
  @State private var savedToast: Bool = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          Text("流光视频 Apple TV 设置")
            .font(.largeTitle)
            .bold()

          VStack(alignment: .leading, spacing: 18) {
            Text("后端服务器地址")
              .font(.headline)
            TextField("https://jp2.linsionwinwin.top:8081", text: $urlInput)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()

            Text("访问密码 / Token")
              .font(.headline)
            SecureField("访问密码", text: $secretInput)

            Toggle("启用 M3U8 切片广告智能过滤 (#EXT-X-DISCONTINUITY)", isOn: $adFilterToggle)
          }
          .padding(32)
          .background(Color.white.opacity(0.06))
          .cornerRadius(20)

          HStack(spacing: 24) {
            Button {
              appState.saveConfig(
                newUrl: urlInput,
                newSecret: secretInput,
                adFilter: adFilterToggle
              )
              savedToast = true
              Task {
                await appState.bootstrapAll()
              }
            } label: {
              Label("保存并刷新数据", systemImage: "checkmark.circle.fill")
            }

            Button(role: .destructive) {
              appState.logout()
            } label: {
              Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
            }
          }

          if savedToast {
            Text("✓ 已保存设置并重新同步数据源")
              .foregroundColor(.green)
          }
        }
        .frame(maxWidth: 960, alignment: .leading)
        .padding(54)
      }
      .onAppear {
        urlInput = appState.serverUrl
        secretInput = appState.authSecret
        adFilterToggle = appState.enableAdFilter
      }
    }
  }
}
