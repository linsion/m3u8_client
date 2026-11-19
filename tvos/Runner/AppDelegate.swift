import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Custom UIWindow that monitors all Siri Remote touches, swipes, and button presses across root views,
/// sheets, and fullScreenCover modals to immediately wake up auto-hidden video player controls,
/// and intercepts the Menu / Back button (.menu) so pressing Back never exits to the tvOS Home Screen.
final class TvInteractiveWindow: UIWindow {
  var onMenuBackPress: (() -> Void)?
  var onRemoteActivity: (() -> Void)?
  var onLiveFullscreenUpDownPress: ((Int) -> Bool)?
  var onVideoLeftRightSeekPress: ((Int) -> Bool)?
  private var lastTouchActivityTime: CFTimeInterval = 0
  private var touchBeganPoint: CGPoint? = nil

  override func sendEvent(_ event: UIEvent) {
    if let pressesEvent = event as? UIPressesEvent {
      let allPresses = pressesEvent.allPresses
      if allPresses.contains(where: { $0.type == .menu }) {
        if allPresses.contains(where: { $0.type == .menu && $0.phase == .began }) {
          onMenuBackPress?()
        }
        return
      }
      if allPresses.contains(where: { ($0.type == .leftArrow || $0.type == .rightArrow) && $0.phase == .began }) {
        let dir = allPresses.contains(where: { $0.type == .leftArrow && $0.phase == .began }) ? -1 : 1
        if onVideoLeftRightSeekPress?(dir) == true {
          lastTouchActivityTime = CACurrentMediaTime()
          onRemoteActivity?()
          return
        }
      }
      if allPresses.contains(where: { ($0.type == .leftArrow || $0.type == .rightArrow) && $0.phase != .began }) {
        if onVideoLeftRightSeekPress?(0) == true {
          return
        }
      }
      if allPresses.contains(where: { ($0.type == .upArrow || $0.type == .downArrow) && $0.phase == .began }) {
        let delta = allPresses.contains(where: { $0.type == .upArrow && $0.phase == .began }) ? -1 : 1
        _ = onLiveFullscreenUpDownPress?(delta)
      }
      if allPresses.contains(where: { $0.phase == .began }) {
        lastTouchActivityTime = CACurrentMediaTime()
        onRemoteActivity?()
      }
    } else if event.type == .touches {
      if let touches = event.allTouches, let touch = touches.first {
        let loc = touch.location(in: self)
        switch touch.phase {
        case .began:
          touchBeganPoint = loc
        case .moved:
          let start = touchBeganPoint ?? loc
          let dist = hypot(loc.x - start.x, loc.y - start.y)
          let now = CACurrentMediaTime()
          if dist >= 14.0 && (now - lastTouchActivityTime) > 0.15 {
            lastTouchActivityTime = now
            touchBeganPoint = loc
            onRemoteActivity?()
          }
        case .ended, .cancelled:
          touchBeganPoint = nil
        default:
          break
        }
      }
    }
    super.sendEvent(event)
  }

  /// Finds any active vertical UIScrollView on screen that is scrolled down (> 20pt) and scrolls it back to top.
  func scrollFocusedOrMainScrollViewToTop() -> Bool {
    var candidates: [UIScrollView] = []
    if let focusedView = UIFocusSystem.focusSystem(for: self)?.focusedItem as? UIView {
      var cur: UIView? = focusedView
      while let v = cur {
        if let sv = v as? UIScrollView, isScrollableVertical(sv) {
          candidates.append(sv)
        }
        cur = v.superview
      }
    }
    collectVerticalScrollViews(in: self, into: &candidates)

    var didScrollAny = false
    for sv in candidates {
      let topOffset = -sv.adjustedContentInset.top
      if (sv.contentOffset.y - topOffset) > 20.0 {
        sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: topOffset), animated: true)
        didScrollAny = true
      }
    }
    return didScrollAny
  }

  private func isScrollableVertical(_ sv: UIScrollView) -> Bool {
    guard !sv.isHidden, sv.alpha > 0.01, sv.window != nil else { return false }
    var ancestor: UIView? = sv.superview
    while let p = ancestor {
      if p.isHidden || p.alpha <= 0.01 { return false }
      ancestor = p.superview
    }
    let topOffset = -sv.adjustedContentInset.top
    return sv.bounds.height >= 160 && (sv.contentSize.height > sv.bounds.height + 10 || (sv.contentOffset.y - topOffset) > 20.0)
  }

  private func collectVerticalScrollViews(in view: UIView, into list: inout [UIScrollView]) {
    guard !view.isHidden, view.alpha > 0.01 else { return }
    if let sv = view as? UIScrollView, isScrollableVertical(sv), !list.contains(where: { $0 === sv }) {
      list.append(sv)
    }
    for sub in view.subviews {
      collectVerticalScrollViews(in: sub, into: &list)
    }
  }
}

final class TvRootHostingController<Content: View>: UIHostingController<Content> {
  var onMenuBackPress: (() -> Void)?
  var onRemoteActivity: (() -> Void)?

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    if presses.contains(where: { $0.type == .menu }) {
      onMenuBackPress?()
      return
    }
    onRemoteActivity?()
    super.pressesBegan(presses, with: event)
  }

  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    if presses.contains(where: { $0.type == .menu }) {
      return
    }
    super.pressesEnded(presses, with: event)
  }
}

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  let appState = TvAppState()

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    try? AVAudioSession.sharedInstance().setActive(true)

    let window = TvInteractiveWindow(frame: UIScreen.main.bounds)
    let rootView = TvRootView()
      .environmentObject(appState)
      .preferredColorScheme(.dark)
    let hosting = TvRootHostingController(rootView: rootView)

    let handleActivity: () -> Void = { [weak self] in
      Task { @MainActor in
        self?.appState.registerRemoteInteraction()
      }
    }
    let handleMenuBack: () -> Void = { [weak self, weak hosting] in
      Task { @MainActor in
        guard let self = self else { return }
        if self.appState.showMusicFolderPickerSheet {
          if self.appState.musicFolderPickerBackHandler?() == true {
            return
          }
          self.appState.showMusicFolderPickerSheet = false
          return
        }
        if self.appState.activeArchiveMusicBrowserEntry != nil {
          self.appState.activeArchiveMusicBrowserEntry = nil
          return
        }
        if var topPresented = hosting?.presentedViewController {
          while let next = topPresented.presentedViewController {
            topPresented = next
          }
          topPresented.dismiss(animated: true)
          return
        }
        self.appState.handleRemoteMenuBackPress()
      }
    }

    appState.scrollWindowToTopHandler = { [weak window] in
      window?.scrollFocusedOrMainScrollViewToTop() ?? false
    }
    appState.exitApplicationHandler = {
      UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
    }

    window.onRemoteActivity = handleActivity
    window.onMenuBackPress = handleMenuBack
    window.onLiveFullscreenUpDownPress = { [weak self, weak hosting] delta in
      guard let self = self else { return false }
      if hosting?.presentedViewController != nil { return false }
      if self.appState.activePlayback?.isLive == true {
        Task { @MainActor in
          self.appState.triggerLiveFullscreenChannelStep(delta)
        }
        return true
      }
      if self.appState.selectedSection == .live,
         self.appState.liveGuideCollapsed,
         self.appState.activePlayback == nil,
         self.appState.selectedDetailItem == nil,
         self.appState.activeTelegramGallery == nil {
        Task { @MainActor in
          self.appState.triggerLiveFullscreenChannelStep(delta)
        }
        return true
      }
      return false
    }
    window.onVideoLeftRightSeekPress = { [weak self, weak hosting] dir in
      guard let self = self else { return false }
      if hosting?.presentedViewController != nil { return false }
      if let playback = self.appState.activePlayback, !playback.isLive {
        if !self.appState.playerControlsVisible || self.appState.isPlayerScrubberFocused {
          if dir != 0 {
            Task { @MainActor in
              self.appState.triggerVideoDirectSeek(direction: dir)
            }
          }
          return true
        }
      }
      if let gallery = self.appState.activeTelegramGallery, !gallery.mediaMessages.isEmpty {
        if !self.appState.galleryControlsVisible || self.appState.isPlayerScrubberFocused {
          if dir != 0 {
            Task { @MainActor in
              self.appState.triggerVideoDirectSeek(direction: dir)
            }
          }
          return true
        }
      }
      return false
    }
    hosting.onRemoteActivity = handleActivity
    hosting.onMenuBackPress = handleMenuBack

    window.rootViewController = hosting
    self.window = window
    window.makeKeyAndVisible()

    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.appState.handleDidEnterBackground()
      }
    }
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.appState.handleDidBecomeActive()
      }
    }
    return true
  }

  func applicationDidEnterBackground(_ application: UIApplication) {
    appState.handleDidEnterBackground()
  }

  func applicationDidBecomeActive(_ application: UIApplication) {
    appState.handleDidBecomeActive()
  }
}

// MARK: - Root Container (Native Apple tvOS TabView + Ambient Backdrop + Modals)

struct TvRootView: View {
  @EnvironmentObject var appState: TvAppState

  private var hasTopOverlayLayer: Bool {
    appState.selectedDetailItem != nil
      || appState.activePlayback != nil
      || appState.activeTelegramGallery != nil
      || appState.activeTelegramFilePreview != nil
  }

  var body: some View {
    ZStack {
      if !appState.isAuthenticated {
        TvLoginView()
      } else {
        // Layer 0: Base Main Section + Top Navigation Bar (Kept mounted so scroll offsets are 100% preserved!)
        VStack(spacing: 0) {
          if !(appState.selectedSection == .live && appState.liveGuideCollapsed) {
            TvAppleTopNavigationBar(selectedSection: $appState.selectedSection)
              .focusSection()
              .zIndex(20)
          }

          ZStack {
            switch appState.selectedSection {
            case .vod:
              TvVodSectionView()
            case .live:
              TvLiveSectionView()
            case .telegram:
              TvTelegramSectionView()
            case .favorites:
              TvFavoritesHistorySectionView()
            case .downloads:
              TvDownloadsSectionView()
            case .mediaLibrary:
              TvMediaLibrarySectionView()
            case .music:
              TvCloudMusicFullscreenHallView(isStandaloneSection: true)
            case .proxy:
              TvProxySectionView()
            case .settings:
              TvSettingsSectionView()
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .clipped()
        }
        .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
        .clipped()
        .opacity(hasTopOverlayLayer ? 0 : 1)
        .disabled(hasTopOverlayLayer)

        // Layer 1: VOD Detail Page (Kept mounted underneath Fullscreen Player so pressing Back from video player returns to Detail Page instantaneously!)
        if let item = appState.selectedDetailItem {
          TvVodDetailSheetView(item: item)
            .environmentObject(appState)
            .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
            .clipped()
            .opacity(appState.activePlayback != nil ? 0 : 1)
            .disabled(appState.activePlayback != nil)
            .zIndex(50)
        }

        // Layer 2: Telegram Fullscreen Video / Media Gallery
        if let session = appState.activeTelegramGallery {
          TvTelegramGalleryModalView(session: session)
            .environmentObject(appState)
            .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
            .clipped()
            .zIndex(60)
        }

        // Layer 3: Fullscreen VOD / Live Video Player
        if let req = appState.activePlayback {
          TvPlayerModalView(request: req)
            .environmentObject(appState)
            .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
            .clipped()
            .zIndex(70)
        }

        // Layer 4: Telegram Text / File Content Preview
        if let preview = appState.activeTelegramFilePreview {
          TvTelegramFilePreviewSheet(preview: preview)
            .environmentObject(appState)
            .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
            .clipped()
            .zIndex(80)
        }
      }

      // Resolving Stream HUD Overlay
      if appState.isResolvingPlay {
        ZStack {
          Color.black.opacity(0.55).ignoresSafeArea()
          VStack(spacing: 18) {
            ProgressView()
              .scaleEffect(1.5)
            Text("正在解析高清播放地址...")
              .font(.system(size: 22, weight: .semibold))
              .foregroundColor(.white)
          }
          .padding(.horizontal, 44)
          .padding(.vertical, 34)
          .background(.ultraThinMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
          .shadow(color: .black.opacity(0.5), radius: 28, y: 12)
        }
        .zIndex(90)
      }

      // Floating Apple-style Toast Capsule
      if let toast = appState.toastMessage {
        VStack {
          HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
              .foregroundColor(Color(red: 0.30, green: 0.85, blue: 0.48))
            Text(toast)
              .font(.system(size: 20, weight: .semibold))
              .foregroundColor(.white)
          }
          .padding(.horizontal, 28)
          .padding(.vertical, 14)
          .background(.regularMaterial)
          .clipShape(Capsule(style: .continuous))
          .overlay(
            Capsule(style: .continuous)
              .stroke(Color.white.opacity(0.22), lineWidth: 1)
          )
          .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
          .padding(.top, 26)
          Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .zIndex(100)
      }
    }
    .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
    .clipped()
    .background(
      Group {
        if !appState.isAuthenticated {
          TvAmbientBackdropView(imageUrl: "")
        } else if appState.selectedSection == .telegram {
          TvTelegramPalette.chatWallpaperBg.ignoresSafeArea()
        } else {
          TvAmbientBackdropView(imageUrl: appState.ambientBackdropUrl)
        }
      }
    )
    .ignoresSafeArea()
    .onExitCommand {
      appState.handleRemoteMenuBackPress()
    }
    .task {
      if appState.isAuthenticated && appState.vodSources.isEmpty {
        await appState.bootstrapAll()
      }
    }
  }
}

/// Apple tvOS Floating Liquid-Glass Top Capsule Navigation Bar (Follows Apple HIG & Never Disappears)
struct TvAppleTopNavigationBar: View {
  @EnvironmentObject var appState: TvAppState
  @Binding var selectedSection: TvMainSection

  private enum TopBarFocusTarget: Hashable {
    case tab(TvMainSection)
    case themeButton
  }

  @FocusState private var focusedTarget: TopBarFocusTarget?

  var body: some View {
    let theme = appState.activeTheme

    HStack(spacing: 18) {
      // Brand Pill on Left
      HStack(spacing: 10) {
        ZStack {
          Circle()
            .fill(
              LinearGradient(
                colors: [theme.accentHover, theme.accent],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
            .frame(width: 38, height: 38)
          Image(systemName: "play.tv.fill")
            .font(.system(size: 17, weight: .bold))
            .foregroundColor(.white)
        }
        Text("流光视频")
          .font(.system(size: 22, weight: .bold, design: .rounded))
          .foregroundColor(.white)
        Text("v\(appState.appVersion)")
          .font(.system(size: 13, weight: .bold, design: .monospaced))
          .foregroundColor(theme.accentHover)
          .padding(.horizontal, 9)
          .padding(.vertical, 3)
          .background(theme.accent.opacity(0.18))
          .clipShape(Capsule(style: .continuous))
          .overlay(
            Capsule(style: .continuous)
              .stroke(theme.accentHover.opacity(0.45), lineWidth: 1)
          )
      }
      .padding(.leading, 8)

      Spacer()

      // Center Floating Liquid-Glass Capsule Tab Strip
      HStack(spacing: 8) {
        ForEach(TvMainSection.allCases) { sec in
          let isSelected = selectedSection == sec
          Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
              selectedSection = sec
            }
          } label: {
            HStack(spacing: 8) {
              Image(systemName: sec.iconName)
                .font(.system(size: 17, weight: isSelected ? .bold : .medium))
              Text(sec.rawValue)
                .font(.system(size: 19, weight: isSelected ? .bold : .medium))
            }
          }
          .buttonStyle(TvApplePillButtonStyle(isSelected: isSelected, isPrimary: isSelected, compact: true))
          .focused($focusedTarget, equals: .tab(sec))
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.ultraThinMaterial)
      .clipShape(Capsule(style: .continuous))
      .overlay(
        Capsule(style: .continuous)
          .stroke(Color.white.opacity(0.16), lineWidth: 1)
      )
      .shadow(color: .black.opacity(0.35), radius: 18, y: 6)

      Spacer()

      // Right Quick Theme Switcher Pill
      Button {
        appState.cycleTheme()
      } label: {
        HStack(spacing: 8) {
          Circle()
            .fill(theme.accent)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(Color.white.opacity(0.75), lineWidth: 1))
          Text(theme.name)
            .font(.system(size: 16, weight: .semibold))
            .lineLimit(1)
        }
      }
      .buttonStyle(TvApplePillButtonStyle(compact: true))
      .focused($focusedTarget, equals: .themeButton)
    }
    .onChange(of: focusedTarget) { newTarget in
      appState.isTopNavBarFocused = (newTarget != nil)
    }
    .onChange(of: appState.topBarFocusTrigger) { _ in
      appState.isTopNavBarFocused = true
      focusedTarget = .tab(selectedSection)
    }
    .padding(.horizontal, 48)
    .padding(.top, 28)
    .padding(.bottom, 10)
  }
}

// MARK: - Login Screen (Apple tvOS Frosted Glass Card)

struct TvLoginView: View {
  @EnvironmentObject var appState: TvAppState
  @State private var urlInput: String = ""
  @State private var passwordInput: String = ""

  var body: some View {
    VStack(spacing: 30) {
      ZStack {
        Circle()
          .fill(
            LinearGradient(
              colors: [Color(red: 0.22, green: 0.62, blue: 0.98), Color(red: 0.12, green: 0.38, blue: 0.85)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .frame(width: 108, height: 108)
          .shadow(color: Color.blue.opacity(0.45), radius: 24, y: 10)

        Image(systemName: "play.tv.fill")
          .font(.system(size: 48, weight: .bold))
          .foregroundColor(.white)
      }

      VStack(spacing: 8) {
        HStack(spacing: 12) {
          Text("流光视频 · Apple TV")
            .font(.system(size: 42, weight: .bold, design: .rounded))
            .foregroundColor(.white)
          Text(appState.appFullVersion)
            .font(.system(size: 16, weight: .bold, design: .monospaced))
            .foregroundColor(appState.activeTheme.accentHover)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(appState.activeTheme.accent.opacity(0.2))
            .clipShape(Capsule(style: .continuous))
        }
        Text("连接您的流光视频服务端，畅享影视点播、电视直播、Telegram 频道画廊与 115 网盘")
          .font(.system(size: 20))
          .foregroundColor(.white.opacity(0.68))
      }

      VStack(alignment: .leading, spacing: 18) {
        Text("服务器地址")
          .font(.callout)
          .foregroundColor(.white.opacity(0.7))
        TextField("https://jp2.linsionwinwin.top:8081", text: $urlInput)
          .frame(width: 720)

        Text("访问密码")
          .font(.callout)
          .foregroundColor(.white.opacity(0.7))
        SecureField("输入服务端密码", text: $passwordInput)
          .frame(width: 720)
      }
      .padding(34)
      .background(.ultraThinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 28, style: .continuous)
          .stroke(Color.white.opacity(0.16), lineWidth: 1)
      )

      if let err = appState.statusBanner {
        Text(err)
          .font(.callout)
          .foregroundColor(Color(red: 1.0, green: 0.42, blue: 0.40))
      }

      Button {
        Task {
          _ = await appState.loginAndBootstrap(url: urlInput, password: passwordInput)
        }
      } label: {
        HStack(spacing: 12) {
          if appState.isBootstrapping {
            ProgressView()
          } else {
            Image(systemName: "arrow.right.circle.fill")
          }
          Text(appState.isBootstrapping ? "正在连接服务器..." : "连接并进入")
        }
        .frame(width: 340)
      }
      .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
      .disabled(appState.isBootstrapping)
    }
    .padding(56)
    .onAppear {
      urlInput = appState.serverUrl
      passwordInput = appState.authSecret
    }
  }
}

// MARK: - 1. VOD Section View (Apple TV+ Hero Showcase + Native .card Poster Grid)

struct TvVodSectionView: View {
  @EnvironmentObject var appState: TvAppState
  @State private var showSourcePicker = false
  @State private var showSearchSheet = false
  @State private var visibleVodLimit: Int = 60
  @FocusState private var focusedVodTopBtn: Bool

  private let columns = [
    GridItem(.adaptive(minimum: 235, maximum: 275), spacing: 36)
  ]

  var body: some View {
    ScrollViewReader { scrollProxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 30) {
          // 1. Floating Glass Filter & Action Bar
          HStack(spacing: 16) {
            Button {
              showSourcePicker = true
            } label: {
              HStack(spacing: 10) {
                Image(systemName: "server.rack")
                Text(appState.selectedSource?.displayName ?? "选择影视源")
                  .lineLimit(1)
                Image(systemName: "chevron.down")
                  .font(.caption)
              }
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
            .focused($focusedVodTopBtn)

            Button {
              showSearchSheet = true
            } label: {
              Label(
                appState.searchKeyword.isEmpty ? "全网搜索" : "搜索: \(appState.searchKeyword)",
                systemImage: "magnifyingglass"
              )
            }
            .buttonStyle(TvApplePillButtonStyle(isSelected: !appState.searchKeyword.isEmpty, compact: true))

            if !appState.searchKeyword.isEmpty {
              Button {
                appState.searchKeyword = ""
                if let src = appState.selectedSource {
                  Task {
                    await appState.loadVodList(source: src, page: 1, categoryId: appState.selectedCategoryId, resetCategories: false)
                  }
                }
              } label: {
                Label("清除搜索", systemImage: "xmark.circle.fill")
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))
            }

            // Category Horizontal Pills (Synchronized with Expanded Category Drawer)
            ScrollViewReader { catBarProxy in
              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                  Button("推荐首页") {
                    Task { await appState.selectCategory(nil) }
                  }
                  .buttonStyle(TvApplePillButtonStyle(isSelected: appState.selectedCategoryId == nil, compact: true))
                  .id("cat_home")

                  ForEach(appState.categories) { cat in
                    Button(cat.typeName) {
                      Task { await appState.selectCategory(cat.typeId) }
                    }
                    .buttonStyle(TvApplePillButtonStyle(isSelected: appState.selectedCategoryId == cat.typeId, compact: true))
                    .id("cat_\(cat.typeId)")
                  }
                }
                .padding(.vertical, 6)
              }
              .onChange(of: appState.selectedCategoryId) { newCatId in
                let targetId = (newCatId == nil || newCatId?.isEmpty == true) ? "cat_home" : "cat_\(newCatId!)"
                withAnimation(.easeInOut(duration: 0.22)) {
                  catBarProxy.scrollTo(targetId, anchor: .center)
                }
              }
            }

            // "筛选分类 (N) / 收起" Toggle Button (Opens/Closes the Dedicated Category Tab Window — 1:1 Match with vod_home_screen.dart)
            Button {
              withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                appState.vodCategoriesExpanded.toggle()
              }
              if appState.vodCategoriesExpanded && appState.categories.isEmpty && !appState.isLoadingVod,
                 let src = appState.selectedSource {
                Task {
                  await appState.loadVodList(source: src, page: 1, categoryId: appState.selectedCategoryId, resetCategories: true)
                }
              }
            } label: {
              HStack(spacing: 6) {
                Image(systemName: appState.vodCategoriesExpanded ? "chevron.up.circle.fill" : "slider.horizontal.3")
                Text(appState.vodCategoriesExpanded ? "收起" : "筛选分类 (\(appState.categories.count + 1))")
                  .lineLimit(1)
              }
            }
            .buttonStyle(
              TvApplePillButtonStyle(
                isSelected: appState.vodCategoriesExpanded,
                isPrimary: appState.vodCategoriesExpanded,
                compact: true
              )
            )
            .fixedSize(horizontal: true, vertical: false)

            Spacer()

            Button {
              if let src = appState.selectedSource {
                Task {
                  await appState.loadVodList(
                    source: src,
                    page: appState.currentPage,
                    categoryId: appState.selectedCategoryId,
                    resetCategories: false
                  )
                }
              }
            } label: {
              Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
          }
          .padding(.horizontal, 24)
          .padding(.vertical, 14)
          .background(.ultraThinMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
              .stroke(Color.white.opacity(0.12), lineWidth: 1)
          )
          .id("vod_top_anchor")
          .focusSection()

          // 1b. Dedicated Expandable/Collapsible VOD Category Tab Window (全部分类导航 — 1:1 Match with _buildExpandedCategoryDrawer in vod_home_screen.dart)
          if appState.vodCategoriesExpanded {
            TvVodExpandedCategoryDrawerView()
              .environmentObject(appState)
              .transition(.move(edge: .top).combined(with: .opacity))
              .focusSection()
          }

          // 2. Apple TV+ Hero Showcase Banner (for first featured item when browsing)
          if appState.searchKeyword.isEmpty,
             let hero = appState.vodItems.first {
            TvVodHeroBanner(item: hero) {
              appState.selectedDetailItem = hero
            }
            .focusSection()
          }

          // 3. Infinite-Scrolling Poster Grid Content (一边下拉一边自动加载更多)
          if appState.isLoadingVod && appState.vodItems.isEmpty {
            VStack(spacing: 20) {
              ProgressView()
                .scaleEffect(1.5)
              Text("正在加载影片海报...")
                .font(.title3)
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 420)
          } else if appState.vodItems.isEmpty {
            VStack(spacing: 18) {
              Image(systemName: "film.stack")
                .font(.system(size: 64, weight: .light))
                .foregroundColor(.secondary)
              Text(appState.statusBanner ?? "暂无影片数据")
                .font(.title3)
                .foregroundColor(.secondary)
              Button("切换其他影视源") {
                showSourcePicker = true
              }
              .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
            }
            .frame(maxWidth: .infinity, minHeight: 420)
          } else {
            let totalCount = appState.vodItems.count
            let activeSliceCount = min(totalCount, max(60, visibleVodLimit))
            LazyVGrid(columns: columns, spacing: 42) {
              ForEach(0..<activeSliceCount, id: \.self) { idx in
                let item = appState.vodItems[idx]
                TvVodPosterCard(
                  item: item,
                  index: idx,
                  themeId: appState.themeId,
                  action: {
                    appState.selectedDetailItem = item
                  },
                  onFocusedAtIndex: { focusedIdx in
                    let shouldBeScrolled = focusedIdx >= 6
                    if appState.vodIsScrolledDown != shouldBeScrolled {
                      appState.vodIsScrolledDown = shouldBeScrolled
                    }
                    if focusedIdx >= visibleVodLimit - 12 && visibleVodLimit < totalCount {
                      visibleVodLimit = min(totalCount, visibleVodLimit + 48)
                    }
                    if focusedIdx >= totalCount - 12 {
                      Task {
                        await appState.loadMoreVodIfNeeded(currentItem: item)
                      }
                    }
                  }
                )
              }
            }
            .padding(.vertical, 10)
            .focusSection()

            // Seamless Bottom Infinite-Scroll Loading / End Indicator
            HStack(spacing: 14) {
              Spacer()
              if appState.isLoadingMoreVod {
                ProgressView()
                Text("正在为您继续加载更多影片 (已加载 \(appState.vodItems.count) 部)...")
                  .font(.system(size: 18, weight: .medium))
                  .foregroundColor(.white.opacity(0.72))
              } else if visibleVodLimit < totalCount {
                Button("继续显示更多 (\(activeSliceCount)/\(totalCount))") {
                  visibleVodLimit = min(totalCount, visibleVodLimit + 60)
                }
                .buttonStyle(TvApplePillButtonStyle(compact: true))
                .onAppear {
                  visibleVodLimit = min(totalCount, visibleVodLimit + 60)
                }
              } else if appState.hasMoreVodPages && appState.searchKeyword.isEmpty {
                Color.clear
                  .frame(height: 20)
                  .onAppear {
                    Task {
                      await appState.loadMoreVodIfNeeded(currentItem: nil)
                    }
                  }
              } else {
                Text("— 已加载全部 \(appState.vodItems.count) 部影片 —")
                  .font(.system(size: 16))
                  .foregroundColor(.white.opacity(0.42))
              }
              Spacer()
            }
            .padding(.top, 18)
          }
        }
        .padding(.horizontal, 56)
        .padding(.top, 18)
        .padding(.bottom, 60)
      }
      .onChange(of: focusedVodTopBtn) { isTop in
        if isTop && appState.vodIsScrolledDown {
          appState.vodIsScrolledDown = false
        }
      }
      .onChange(of: appState.selectedCategoryId) { _ in
        visibleVodLimit = 60
      }
      .onChange(of: appState.selectedSource?.id) { _ in
        visibleVodLimit = 60
      }
      .onChange(of: appState.vodScrollToTopTrigger) { _ in
        if appState.vodIsScrolledDown {
          appState.vodIsScrolledDown = false
        }
        focusedVodTopBtn = true
        withAnimation(.easeInOut(duration: 0.22)) {
          scrollProxy.scrollTo("vod_top_anchor", anchor: .top)
        }
      }
    }
    .sheet(isPresented: $showSourcePicker) {
      TvSourcePickerSheet(isPresented: $showSourcePicker)
        .environmentObject(appState)
    }
    .sheet(isPresented: $showSearchSheet) {
      TvSearchSheet(isPresented: $showSearchSheet)
        .environmentObject(appState)
    }
  }
}

/// Dedicated Collapsible/Expandable VOD Category Tab Window (`全部分类导航`)
/// 1:1 Match with `_buildExpandedCategoryDrawer` in `lib/ui/screens/vod_home_screen.dart`:
/// - Header Bar with `全部分类导航`, `当前：<分类名>`, Category Filter Input, and `收起 ▲` button
/// - Group Tabs Bar (`全部`, `电影频道`, `剧集剧场`, `动漫 · 综艺 · 纪实`, `更多频道专区`)
/// - Multi-Column Matrix Grid of all Category Tag Buttons
/// - Bottom Full-Width `▲ 点击此处收起分类导航` Bar
struct TvVodExpandedCategoryDrawerView: View {
  @EnvironmentObject var appState: TvAppState
  @State private var showFilterSheet: Bool = false

  private let sectionOrder: [String] = [
    "电影频道",
    "剧集剧场",
    "动漫 · 综艺 · 纪实",
    "更多频道专区"
  ]

  private let matrixColumns = [
    GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 14)
  ]

  private static func classifyCategoryGroup(_ rawName: String) -> String {
    let n = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    if n.range(of: "(电影|动作|喜剧|爱情|科幻|恐怖|剧情|战争|灾难|悬疑|犯罪|奇幻|惊悚|院线|蓝光|4K|粤语片|邵氏|经典片|动画片|微电影)", options: [.regularExpression, .caseInsensitive]) != nil {
      return "电影频道"
    }
    if n.range(of: "(剧|连续|国产|香港|台湾|韩国|日本|欧美|海外|泰国|新马|英美|短剧|爽剧|TVB)", options: [.regularExpression, .caseInsensitive]) != nil {
      return "剧集剧场"
    }
    if n.range(of: "(动漫|动画|番剧|国漫|日漫|美漫|综艺|晚会|真人秀|脱口秀|纪录|纪实|探索|解说|体育|赛事|足球|篮球|音乐|MV|演唱会)", options: [.regularExpression, .caseInsensitive]) != nil {
      return "动漫 · 综艺 · 纪实"
    }
    return "更多频道专区"
  }

  private static func groupSectionIcon(_ groupTitle: String) -> String {
    switch groupTitle {
    case "电影频道":
      return "film.stack.fill"
    case "剧集剧场":
      return "tv.fill"
    case "动漫 · 综艺 · 纪实":
      return "sparkles.tv.fill"
    default:
      return "square.grid.2x2.fill"
    }
  }

  private var activeCategoryLabel: String {
    guard let curId = appState.selectedCategoryId, !curId.isEmpty else {
      return "全部推荐"
    }
    return appState.categories.first(where: { $0.typeId == curId })?.typeName ?? "全部推荐"
  }

  var body: some View {
    let theme = appState.activeTheme
    let categories = appState.categories
    let kw = appState.vodCategoryFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let allGrouped = Dictionary(grouping: categories, by: { Self.classifyCategoryGroup($0.typeName) })

    let availableGroupTabs: [String] = ["全部"] + sectionOrder.filter { !(allGrouped[$0]?.isEmpty ?? true) }
    let effectiveGroupTab = availableGroupTabs.contains(appState.vodCategoryGroupTab)
      ? appState.vodCategoryGroupTab
      : "全部"

    let filteredCategories: [TvVodCategory] = categories.filter { cat in
      let matchKw = kw.isEmpty || cat.typeName.lowercased().contains(kw)
      let matchGrp = effectiveGroupTab == "全部" || Self.classifyCategoryGroup(cat.typeName) == effectiveGroupTab
      return matchKw && matchGrp
    }

    VStack(alignment: .leading, spacing: 0) {
      // 1. Drawer Header Bar (`全部分类导航` + `当前：...` + Filter + `收起 ▲`)
      HStack(spacing: 14) {
        HStack(spacing: 10) {
          ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(theme.accent.opacity(0.20))
              .frame(width: 36, height: 36)
            Image(systemName: "square.grid.2x2.fill")
              .font(.system(size: 17, weight: .bold))
              .foregroundColor(theme.accentHover)
          }

          Text("全部分类导航")
            .font(.system(size: 21, weight: .bold))
            .foregroundColor(.white)

          Text("当前：\(activeCategoryLabel)")
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(theme.accentHover)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
              Capsule(style: .continuous)
                .fill(theme.accent.opacity(0.16))
            )
            .overlay(
              Capsule(style: .continuous)
                .stroke(theme.accentHover.opacity(0.45), lineWidth: 1)
            )
        }

        Spacer()

        if categories.count > 6 {
          Button {
            showFilterSheet = true
          } label: {
            Label(
              kw.isEmpty ? "筛选分类名称..." : "筛选: \(appState.vodCategoryFilterQuery)",
              systemImage: "line.3.horizontal.decrease.circle"
            )
          }
          .buttonStyle(TvApplePillButtonStyle(isSelected: !kw.isEmpty, compact: true))

          if !kw.isEmpty {
            Button {
              appState.vodCategoryFilterQuery = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
          }
        }

        Button {
          withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            appState.vodCategoriesExpanded = false
          }
        } label: {
          Label("收起", systemImage: "chevron.up")
        }
        .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
      }
      .padding(.horizontal, 26)
      .padding(.vertical, 16)
      .background(Color.white.opacity(0.03))
      .focusSection()

      Divider()
        .background(Color.white.opacity(0.12))

      // 2. Category Group Tab Bar (`全部`, `电影频道`, `剧集剧场`, `动漫 · 综艺 · 纪实`, `更多频道专区`)
      if availableGroupTabs.count > 1 {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 12) {
            ForEach(availableGroupTabs, id: \.self) { tabName in
              let isTabSelected = (effectiveGroupTab == tabName)
              let count = tabName == "全部"
                ? (categories.count + 1)
                : (allGrouped[tabName]?.count ?? 0)
              let iconName = tabName == "全部" ? "square.grid.3x3.fill" : Self.groupSectionIcon(tabName)

              Button {
                appState.vodCategoryGroupTab = tabName
              } label: {
                Label("\(tabName) (\(count))", systemImage: iconName)
              }
              .buttonStyle(
                TvApplePillButtonStyle(
                  isSelected: isTabSelected,
                  isPrimary: isTabSelected,
                  compact: true
                )
              )
            }
          }
          .padding(.horizontal, 26)
          .padding(.vertical, 12)
        }
        .background(Color.black.opacity(0.24))
        .focusSection()

        Divider()
          .background(Color.white.opacity(0.10))
      }

      // 3. Multi-Column Matrix Grid of Category Tag Buttons
      ScrollView(.vertical, showsIndicators: true) {
        if filteredCategories.isEmpty && !kw.isEmpty {
          VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
              .font(.system(size: 32))
              .foregroundColor(.secondary)
            Text("未找到匹配「\(appState.vodCategoryFilterQuery)」的分类标签")
              .font(.system(size: 17, weight: .medium))
              .foregroundColor(.secondary)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 36)
        } else {
          LazyVGrid(columns: matrixColumns, spacing: 14) {
            if kw.isEmpty && effectiveGroupTab == "全部" {
              let isAllSelected = (appState.selectedCategoryId == nil || appState.selectedCategoryId?.isEmpty == true)
              Button {
                withAnimation(.easeOut(duration: 0.2)) {
                  appState.vodCategoriesExpanded = false
                }
                Task { await appState.selectCategory(nil) }
              } label: {
                HStack(spacing: 8) {
                  Image(systemName: "flame.fill")
                    .font(.system(size: 15))
                    .foregroundColor(isAllSelected ? theme.accentHover : .orange)
                  Text("全部推荐")
                    .font(.system(size: 16, weight: isAllSelected ? .bold : .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                  Spacer()
                  if isAllSelected {
                    Image(systemName: "checkmark.circle.fill")
                      .font(.system(size: 15))
                      .foregroundColor(Color(red: 0.30, green: 0.85, blue: 0.48))
                  }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
              }
              .buttonStyle(TvAppleSurfaceButtonStyle(isSelected: isAllSelected, cornerRadius: 12))
            }

            ForEach(filteredCategories) { cat in
              let isCatSelected = (appState.selectedCategoryId == cat.typeId)
              Button {
                withAnimation(.easeOut(duration: 0.2)) {
                  appState.vodCategoriesExpanded = false
                }
                Task { await appState.selectCategory(cat.typeId) }
              } label: {
                HStack(spacing: 8) {
                  Circle()
                    .fill(isCatSelected ? theme.accentHover : Color.white.opacity(0.32))
                    .frame(width: 7, height: 7)
                  Text(cat.typeName)
                    .font(.system(size: 16, weight: isCatSelected ? .bold : .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                  Spacer()
                  if isCatSelected {
                    Image(systemName: "checkmark.circle.fill")
                      .font(.system(size: 15))
                      .foregroundColor(Color(red: 0.30, green: 0.85, blue: 0.48))
                  }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
              }
              .buttonStyle(TvAppleSurfaceButtonStyle(isSelected: isCatSelected, cornerRadius: 12))
            }

            if categories.isEmpty && kw.isEmpty {
              Button {
                if !appState.isLoadingVod, let src = appState.selectedSource {
                  Task {
                    await appState.loadVodList(source: src, page: 1, categoryId: nil, resetCategories: true)
                  }
                }
              } label: {
                HStack(spacing: 8) {
                  Image(systemName: "arrow.clockwise")
                  Text(appState.isLoadingVod ? "正在加载分类标签..." : "刷新分类标签")
                    .font(.system(size: 16, weight: .medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
              }
              .buttonStyle(TvAppleSurfaceButtonStyle(isSelected: false, cornerRadius: 12))
            }
          }
          .padding(.horizontal, 26)
          .padding(.vertical, 18)
        }
      }
      .frame(maxHeight: 390)
      .focusSection()

      Divider()
        .background(Color.white.opacity(0.12))

      // 4. Bottom Full-Width Collapse Bar (`点击此处收起分类导航`)
      Button {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
          appState.vodCategoriesExpanded = false
        }
      } label: {
        HStack(spacing: 8) {
          Spacer()
          Image(systemName: "chevron.up.circle.fill")
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(theme.accentHover)
          Text("点击此处收起分类导航")
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(theme.accentHover)
          Spacer()
        }
        .padding(.vertical, 10)
      }
      .buttonStyle(TvAppleSurfaceButtonStyle(isSelected: false, cornerRadius: 12))
      .padding(.horizontal, 26)
      .padding(.vertical, 10)
      .focusSection()
    }
    .background(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .fill(Color(red: 0.06, green: 0.09, blue: 0.14).opacity(0.96))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(theme.accentHover.opacity(0.42), lineWidth: 1.5)
    )
    .shadow(color: .black.opacity(0.58), radius: 26, y: 12)
    .sheet(isPresented: $showFilterSheet) {
      ZStack {
        TvAmbientBackdropView(imageUrl: appState.ambientBackdropUrl)
        VStack(spacing: 28) {
          Text("筛选分类标签名称")
            .font(.largeTitle.bold())
          TextField("输入分类名称（如：动作、科幻、短剧、动漫）...", text: $appState.vodCategoryFilterQuery)
            .frame(width: 680)
          HStack(spacing: 20) {
            if !appState.vodCategoryFilterQuery.isEmpty {
              Button("清空筛选") {
                appState.vodCategoryFilterQuery = ""
                showFilterSheet = false
              }
              .buttonStyle(TvApplePillButtonStyle())
            }
            Button("确定") {
              showFilterSheet = false
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
          }
        }
        .padding(60)
      }
    }
  }
}

/// Apple TV+ Style Featured Hero Showcase Banner (Zero Offscreen Blur Pass)
struct TvVodHeroBanner: View {
  @EnvironmentObject var appState: TvAppState
  let item: TvVodItem
  let onOpenDetail: () -> Void

  var body: some View {
    let palette = appState.activeTheme
    ZStack(alignment: .bottomLeading) {
      LinearGradient(
        colors: [
          palette.bgElevated,
          palette.bgPrimary.opacity(0.92),
          palette.accent.opacity(0.18)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      HStack(alignment: .bottom, spacing: 28) {
        TvRemoteImage(rawUrl: item.vodPic, placeholderIcon: "film", contentMode: .fill)
          .frame(width: 168, height: 242)
          .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
              .stroke(Color.white.opacity(0.22), lineWidth: 1)
          )

        VStack(alignment: .leading, spacing: 14) {
          HStack(spacing: 10) {
            Text("今日焦点推荐")
              .font(.system(size: 15, weight: .bold))
              .foregroundColor(.white)
              .padding(.horizontal, 12)
              .padding(.vertical, 5)
              .background(palette.accent)
              .clipShape(Capsule())

            if !item.vodRemarks.isEmpty {
              Text(item.vodRemarks)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(palette.accentHover)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color(red: 0.06, green: 0.07, blue: 0.10).opacity(0.88))
                .clipShape(Capsule())
                .overlay(
                  Capsule()
                    .stroke(palette.accent.opacity(0.55), lineWidth: 1)
                )
            }

            if !item.typeName.isEmpty {
              Text(item.typeName)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
            }

            if !item.vodYear.isEmpty {
              Text(item.vodYear)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
            }
          }

          Text(item.vodName)
            .font(.system(size: 38, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .lineLimit(1)

          Text("来源：\(item.source.displayName) · 点击立即选集播放或跨站匹配最优高清线路")
            .font(.system(size: 19))
            .foregroundColor(.white.opacity(0.72))
            .lineLimit(1)

          HStack(spacing: 16) {
            Button(action: onOpenDetail) {
              Label("立即播放 / 选集", systemImage: "play.fill")
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
          }
          .padding(.top, 4)
        }

        Spacer()
      }
      .padding(32)
    }
    .frame(height: 306)
    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .stroke(Color.white.opacity(0.15), lineWidth: 1)
    )
  }
}

/// Native Apple TV .card Poster Item (Decoupled from @EnvironmentObject so focus navigation triggers zero global rebuilds, while reacting to themeId changes!)
struct TvVodPosterCard: View {
  @Environment(\.isFocused) private var isFocused
  let item: TvVodItem
  let index: Int
  var themeId: String = TvThemePalette.current.id
  let action: () -> Void
  let onFocusedAtIndex: (Int) -> Void

  var body: some View {
    let palette = TvThemePalette.palette(for: themeId)
    Button(action: action) {
      VStack(alignment: .leading, spacing: 10) {
        ZStack(alignment: .bottomLeading) {
          TvRemoteImage(rawUrl: item.vodPic, placeholderIcon: "film", contentMode: .fill)
            .frame(width: 245, height: 348)
            .clipped()

          LinearGradient(
            colors: [.clear, Color.black.opacity(0.84)],
            startPoint: .center,
            endPoint: .bottom
          )
          .frame(height: 96)

          HStack {
            if !item.vodRemarks.isEmpty {
              Text(item.vodRemarks)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(palette.accentHover)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(red: 0.06, green: 0.07, blue: 0.10).opacity(0.88))
                .clipShape(Capsule())
                .overlay(
                  Capsule()
                    .stroke(palette.accent.opacity(0.55), lineWidth: 1)
                )
            }
            Spacer()
            if !item.vodYear.isEmpty {
              Text(item.vodYear)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.85))
            }
          }
          .padding(12)
        }
        .frame(width: 245, height: 348)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

        VStack(alignment: .leading, spacing: 3) {
          Text(item.vodName)
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(.white)
            .lineLimit(1)

          Text(item.source.displayName)
            .font(.caption)
            .foregroundColor(.white.opacity(0.58))
            .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
      }
      .frame(width: 245)
    }
    .buttonStyle(.card)
    .onChange(of: isFocused) { focused in
      if focused {
        onFocusedAtIndex(index)
      }
    }
  }
}

struct TvSourcePickerSheet: View {
  @EnvironmentObject var appState: TvAppState
  @Binding var isPresented: Bool
  @State private var filterText: String = ""
  @State private var sourceTypeFilter: Int = 0 // 0: 全部, 1: CMS 标准站, 2: TVBox 爬虫站

  private var filteredSources: [TvVodSource] {
    let kw = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return appState.vodSources.filter { src in
      if sourceTypeFilter == 1 && src.isSpiderSource { return false }
      if sourceTypeFilter == 2 && !src.isSpiderSource { return false }
      guard !kw.isEmpty else { return true }
      return src.displayName.lowercased().contains(kw) || src.api.lowercased().contains(kw)
    }
  }

  var body: some View {
    let theme = appState.activeTheme
    let cmsCount = appState.vodSources.filter { !$0.isSpiderSource }.count
    let tvboxCount = appState.vodSources.filter { $0.isSpiderSource }.count

    ZStack {
      TvAmbientBackdropView(imageUrl: appState.ambientBackdropUrl)

      VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 14) {
          Label("切换片源站点 (\(filteredSources.count))", systemImage: "server.rack")
            .font(.system(size: 22, weight: .bold))
            .foregroundColor(.white)

          HStack(spacing: 8) {
            Button("全部 (\(appState.vodSources.count))") { sourceTypeFilter = 0 }
              .buttonStyle(TvApplePillButtonStyle(isSelected: sourceTypeFilter == 0, compact: true))
            Button("标准采集站 (\(cmsCount))") { sourceTypeFilter = 1 }
              .buttonStyle(TvApplePillButtonStyle(isSelected: sourceTypeFilter == 1, compact: true))
            Button("TVBox 站 (\(tvboxCount))") { sourceTypeFilter = 2 }
              .buttonStyle(TvApplePillButtonStyle(isSelected: sourceTypeFilter == 2, compact: true))
          }

          Spacer()

          TextField("搜索站点...", text: $filterText)
            .frame(width: 300)

          Button("关闭") { isPresented = false }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
        }
        .focusSection()

        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 325), spacing: 12)], spacing: 12) {
            ForEach(filteredSources) { src in
              let isSelected = appState.selectedSource?.id == src.id
              let host = URL(string: src.api)?.host ?? (src.isSpiderSource ? src.api : "cms-api")
              Button {
                isPresented = false
                Task { await appState.selectSource(src) }
              } label: {
                HStack(spacing: 10) {
                  Text(src.isSpiderSource ? "TVBox" : "CMS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(src.isSpiderSource ? Color(red: 0.35, green: 0.82, blue: 1.0) : theme.accentHover)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background((src.isSpiderSource ? Color.blue : theme.accent).opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                  VStack(alignment: .leading, spacing: 2) {
                    Text(src.displayName)
                      .font(.system(size: 15, weight: .semibold))
                      .foregroundColor(.white)
                      .lineLimit(1)
                    Text(host)
                      .font(.system(size: 11, design: .monospaced))
                      .foregroundColor(.white.opacity(0.48))
                      .lineLimit(1)
                  }

                  Spacer()

                  if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                      .font(.system(size: 16))
                      .foregroundColor(Color(red: 0.30, green: 0.85, blue: 0.48))
                  }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
              }
              .buttonStyle(TvAppleSurfaceButtonStyle(isSelected: isSelected, cornerRadius: 12))
            }
          }
          .padding(4)
        }
        .focusSection()
      }
      .padding(36)
    }
  }
}

struct TvSearchSheet: View {
  @EnvironmentObject var appState: TvAppState
  @Binding var isPresented: Bool
  @State private var keyword: String = ""

  var body: some View {
    ZStack {
      TvAmbientBackdropView(imageUrl: appState.ambientBackdropUrl)

      VStack(spacing: 30) {
        Text("全网影视搜索")
          .font(.largeTitle.bold())

        TextField("输入片名、主演或导演...", text: $keyword)
          .frame(width: 760)

        Toggle("启用多站并发聚合搜索（同时检索前 18 个可用源）", isOn: $appState.isAggregateSearch)
          .frame(width: 760)

        HStack(spacing: 24) {
          Button("取消") { isPresented = false }
            .buttonStyle(TvApplePillButtonStyle())

          Button {
            appState.searchKeyword = keyword
            isPresented = false
            Task { await appState.performSearch() }
          } label: {
            Label("立即搜索", systemImage: "magnifyingglass")
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
        }
      }
      .padding(60)
    }
    .onAppear {
      keyword = appState.searchKeyword
    }
  }
}

// MARK: - VOD Detail Page (网易爆米花 NetEase Filmly / Infuse Apple TV Cinema Style)

struct TvVodDetailSheetView: View {
  @EnvironmentObject var appState: TvAppState
  let item: TvVodItem

  @State private var activeSource: TvVodSource? = nil
  @State private var detail: TvVodDetail? = nil
  @State private var isLoading = true
  @State private var selectedGroupIndex = 0
  @State private var selectedChunkIndex = 0
  @State private var reverseOrder = false
  @State private var errorMsg: String? = nil
  @State private var alternativeMatches: [TvVodItem] = []
  @State private var isSearchingAlternatives = false
  @FocusState private var focusedDetailTarget: String?

  private let chunkSize = 40
  private let episodeColumns = [
    GridItem(.adaptive(minimum: 155, maximum: 195), spacing: 10)
  ]

  var body: some View {
    let currentSource = activeSource ?? item.source
    let posterUrl = (detail?.vodPic.isEmpty == false) ? detail!.vodPic : item.vodPic
    let showSourceShelf = appState.detailShowSourceShelf
    let downloadMode = appState.detailDownloadMode

    let screenW = UIScreen.main.bounds.width
    let screenH = UIScreen.main.bounds.height

    ZStack {
      // 1. Full-Bleed Cinema Backdrop Stage (Zero Offscreen Blur Pass)
      TvAmbientBackdropView(imageUrl: "")
        .frame(width: screenW, height: screenH)
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)

      ScrollViewReader { scrollProxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 30) {
            if isLoading {
              VStack(spacing: 22) {
                ProgressView()
                  .scaleEffect(1.6)
                Text("正在加载影片详情与高清片源...")
                  .font(.title3)
                  .foregroundColor(.white.opacity(0.75))
              }
              .frame(maxWidth: .infinity, minHeight: 620)
            } else if let d = detail {
              let resumeInfo = appState.lastWatchedEpisode(for: d)

              // 2. Top Hero Section (Left Filmly Metadata & Action Bar + Right Floating 3D Poster)
              HStack(alignment: .top, spacing: 44) {
                VStack(alignment: .leading, spacing: 18) {
                  // Large Title
                  Text(d.vodName)
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.6), radius: 12, y: 4)

                  // 网易爆米花 Metadata Badges Row (Theme-Colored Remark + 4K/M3U8 Tag + Year/Area/Genre)
                  HStack(spacing: 12) {
                    if !d.vodRemarks.isEmpty {
                      Text(d.vodRemarks)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(appState.activeTheme.accentHover)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                          Capsule()
                            .fill(Color(red: 0.06, green: 0.07, blue: 0.10).opacity(0.88))
                        )
                        .overlay(
                          Capsule()
                            .stroke(appState.activeTheme.accent.opacity(0.60), lineWidth: 1.2)
                        )
                    }

                    Text("HD · M3U8")
                      .font(.system(size: 14, weight: .bold, design: .monospaced))
                      .foregroundColor(.white.opacity(0.92))
                      .padding(.horizontal, 10)
                      .padding(.vertical, 5)
                      .background(Color.white.opacity(0.14))
                      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                      .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                          .stroke(Color.white.opacity(0.28), lineWidth: 1)
                      )

                    Text(currentSource.displayName)
                      .font(.system(size: 15, weight: .semibold))
                      .foregroundColor(Color(red: 0.45, green: 0.80, blue: 1.0))
                      .padding(.horizontal, 14)
                      .padding(.vertical, 6)
                      .background(Color(red: 0.20, green: 0.58, blue: 0.96).opacity(0.24))
                      .clipShape(Capsule())

                    if !d.typeName.isEmpty {
                      Text(d.typeName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.82))
                    }

                    if !d.vodYear.isEmpty {
                      Text("· \(d.vodYear)")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                    }

                    if !d.vodArea.isEmpty {
                      Text("· \(d.vodArea)")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                    }
                  }

                  // Cast & Director Metadata
                  VStack(alignment: .leading, spacing: 6) {
                    if !d.vodDirector.isEmpty {
                      HStack(alignment: .top, spacing: 8) {
                        Text("导演：")
                          .font(.system(size: 18, weight: .semibold))
                          .foregroundColor(.white.opacity(0.55))
                        Text(d.vodDirector)
                          .font(.system(size: 18))
                          .foregroundColor(.white.opacity(0.88))
                          .lineLimit(1)
                      }
                    }
                    if !d.vodActor.isEmpty {
                      HStack(alignment: .top, spacing: 8) {
                        Text("主演：")
                          .font(.system(size: 18, weight: .semibold))
                          .foregroundColor(.white.opacity(0.55))
                        Text(d.vodActor)
                          .font(.system(size: 18))
                          .foregroundColor(.white.opacity(0.88))
                          .lineLimit(2)
                      }
                    }
                  }

                  // Story Synopsis
                  Text(d.vodContent.isEmpty ? "暂无剧情简介" : d.vodContent)
                    .font(.system(size: 19))
                    .lineSpacing(5)
                    .foregroundColor(.white.opacity(0.78))
                    .lineLimit(3)
                    .frame(maxWidth: 1060, alignment: .leading)

                  // 3. 网易爆米花 Primary Action Bar
                  HStack(spacing: 16) {
                    if !d.playGroups.isEmpty {
                      let targetGroupIdx = resumeInfo?.groupIndex ?? min(selectedGroupIndex, max(0, d.playGroups.count - 1))
                      let targetEpIdx = resumeInfo?.episodeIndex ?? 0
                      let targetGroup = d.playGroups[targetGroupIdx]
                      if targetEpIdx < targetGroup.episodes.count {
                        let targetEp = targetGroup.episodes[targetEpIdx]
                        let playLabel = resumeInfo != nil
                          ? "继续播放 \(targetEp.title) (\(formatClock(resumeInfo!.savedSec)))"
                          : "立即播放 \(targetEp.title)"

                        Button {
                          // Keep appState.selectedDetailItem intact so pressing Back in the video player returns to this Detail Page!
                          Task {
                            await appState.startEpisodePlayback(
                              source: currentSource,
                              detail: d,
                              groupIndex: targetGroupIdx,
                              episodeIndex: targetEpIdx
                            )
                          }
                        } label: {
                          HStack(spacing: 10) {
                            Image(systemName: "play.fill")
                            Text(playLabel)
                          }
                          .padding(.horizontal, 6)
                        }
                        .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
                        .focused($focusedDetailTarget, equals: "detail_primary_play")
                      }
                    }

                    let fav = appState.isFavorite(source: currentSource, vodId: d.vodId)
                    Button {
                      Task { await appState.toggleFavorite(source: currentSource, detail: d) }
                    } label: {
                      Label(fav ? "已收藏" : "收藏", systemImage: fav ? "star.fill" : "star")
                    }
                    .buttonStyle(TvApplePillButtonStyle(isSelected: fav))

                    Button {
                      withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        appState.detailShowSourceShelf.toggle()
                      }
                      if alternativeMatches.isEmpty && !isSearchingAlternatives {
                        Task { await searchAlternativeSources(title: d.vodName) }
                      }
                    } label: {
                      Label(
                        isSearchingAlternatives
                          ? "正在检索全网源..."
                          : (alternativeMatches.isEmpty ? "跨站换源" : "换源 (\(alternativeMatches.count)个站)"),
                        systemImage: "arrow.triangle.2.circlepath"
                      )
                    }
                    .buttonStyle(TvApplePillButtonStyle(isSelected: showSourceShelf))

                    Button {
                      appState.detailDownloadMode.toggle()
                    } label: {
                      Label(
                        downloadMode ? "转存模式:开" : "选集转存",
                        systemImage: downloadMode ? "arrow.down.circle.fill" : "icloud.and.arrow.down"
                      )
                    }
                    .buttonStyle(TvApplePillButtonStyle(isSelected: downloadMode))

                    Button {
                      appState.selectedDetailItem = nil
                    } label: {
                      Label("返回", systemImage: "xmark")
                    }
                    .buttonStyle(TvApplePillButtonStyle())
                    .focused($focusedDetailTarget, equals: "detail_back_btn")
                  }
                  .padding(.top, 6)
                  .focusSection()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Right Floating 3D Poster Card
                TvRemoteImage(rawUrl: posterUrl, placeholderIcon: "film", contentMode: .fill)
                  .frame(width: 248, height: 356)
                  .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                  .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                      .stroke(Color.white.opacity(0.24), lineWidth: 1.5)
                  )
                  .shadow(color: .black.opacity(0.65), radius: 28, y: 14)
              }
              .id("detail_top_anchor")

              // 4. Cross-Site Alternative Sources Shelf (网易爆米花 多源对比栏 — 紧凑胶囊卡片)
              if showSourceShelf || (!alternativeMatches.isEmpty && d.playGroups.isEmpty) {
                VStack(alignment: .leading, spacing: 10) {
                  HStack {
                    Label("全网多源匹配 (\(alternativeMatches.count) 个可用片源)", systemImage: "server.rack")
                      .font(.system(size: 16, weight: .bold))
                      .foregroundColor(.white)
                    Spacer()
                    if isSearchingAlternatives {
                      ProgressView()
                        .scaleEffect(0.8)
                    }
                  }

                  if alternativeMatches.isEmpty && !isSearchingAlternatives {
                    Text("暂未在其他站点检索到同名片源")
                      .font(.system(size: 14))
                      .foregroundColor(.secondary)
                  } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                      HStack(spacing: 10) {
                        ForEach(alternativeMatches) { alt in
                          let isCur = alt.source.id == currentSource.id
                          Button {
                            Task { await switchDetailTo(alt) }
                          } label: {
                            HStack(spacing: 8) {
                              Image(systemName: isCur ? "checkmark.circle.fill" : "play.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(isCur ? Color(red: 0.30, green: 0.85, blue: 0.48) : appState.activeTheme.accentHover)
                              Text(alt.source.displayName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                              Text(alt.vodRemarks.isEmpty ? "正片" : alt.vodRemarks)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(appState.activeTheme.accentHover)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(appState.activeTheme.accent.opacity(0.16))
                                .clipShape(Capsule())
                                .lineLimit(1)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                          }
                          .buttonStyle(TvAppleSurfaceButtonStyle(isSelected: isCur, cornerRadius: 11))
                        }
                      }
                      .padding(.vertical, 4)
                    }
                  }
                }
                .padding(16)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .focusSection()
              }

              Divider()
                .background(Color.white.opacity(0.12))

              // 5. Play Line Selector & Episode Range Chunks & Compact Episode Link Chips (紧凑选集胶囊区)
              if d.playGroups.isEmpty {
                VStack(spacing: 14) {
                  Text("当前站点未返回可解析的播放线路，请点击上方「换源」切换其他站点播放")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.orange)
                }
                .padding(.vertical, 24)
              } else {
                let safeGroupIdx = min(max(0, selectedGroupIndex), d.playGroups.count - 1)
                let group = d.playGroups[safeGroupIdx]
                let totalEps = group.episodes.count
                let chunkCount = max(1, (totalEps + chunkSize - 1) / chunkSize)
                let safeChunkIdx = min(max(0, selectedChunkIndex), chunkCount - 1)
                let orderedEps = reverseOrder ? Array(group.episodes.reversed()) : group.episodes
                let sliceStart = min(safeChunkIdx * chunkSize, max(0, orderedEps.count))
                let sliceEnd = min(sliceStart + chunkSize, orderedEps.count)
                let visibleEpisodes = Array(orderedEps[sliceStart..<sliceEnd])

                VStack(alignment: .leading, spacing: 14) {
                  // Play Line Tabs + Episode Range Chunks + Sort Order Row
                  HStack(spacing: 12) {
                    Text("播放线路")
                      .font(.system(size: 17, weight: .bold))
                      .foregroundColor(.white)

                    ScrollView(.horizontal, showsIndicators: false) {
                      HStack(spacing: 8) {
                        ForEach(Array(d.playGroups.enumerated()), id: \.offset) { idx, grp in
                          Button {
                            selectedGroupIndex = idx
                            selectedChunkIndex = 0
                          } label: {
                            HStack(spacing: 5) {
                              Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 12))
                              Text("\(grp.name) (\(grp.episodes.count))")
                            }
                          }
                          .buttonStyle(TvApplePillButtonStyle(isSelected: safeGroupIdx == idx, compact: true))
                        }
                      }
                      .padding(.vertical, 4)
                    }

                    Spacer()

                    // Episode Range Chunk Pills (1-40, 41-80, ...) when > 40 episodes
                    if chunkCount > 1 {
                      ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                          ForEach(0..<chunkCount, id: \.self) { cIdx in
                            let startNum = cIdx * chunkSize + 1
                            let endNum = min((cIdx + 1) * chunkSize, totalEps)
                            Button("\(startNum)-\(endNum)") {
                              selectedChunkIndex = cIdx
                            }
                            .buttonStyle(TvApplePillButtonStyle(isSelected: safeChunkIdx == cIdx, compact: true))
                          }
                        }
                        .padding(.vertical, 4)
                      }
                    }

                    if totalEps > 1 {
                      Button {
                        reverseOrder.toggle()
                      } label: {
                        Label(reverseOrder ? "倒序" : "正序", systemImage: "arrow.up.arrow.down")
                      }
                      .buttonStyle(TvApplePillButtonStyle(compact: true))
                    }
                  }
                  .focusSection()

                  // Sleek Compact Episode Link Chips Grid (8–10 columns per row)
                  LazyVGrid(columns: episodeColumns, spacing: 10) {
                    ForEach(Array(visibleEpisodes.enumerated()), id: \.element.id) { sliceIdx, ep in
                      let savedSec = appState.savedPosition(vodId: d.vodId, episodeTitle: ep.title)
                      let isLastWatched = resumeInfo?.episodeTitle == ep.title && resumeInfo?.groupIndex == safeGroupIdx

                      TvFilmlyEpisodeCard(
                        episode: ep,
                        sliceIndex: sliceIdx,
                        groupName: group.name,
                        savedSeconds: savedSec,
                        isLastWatched: isLastWatched,
                        downloadMode: downloadMode
                      ) {
                        if downloadMode {
                          Task {
                            await appState.queueEpisodeDownload(
                              source: currentSource,
                              detail: d,
                              groupName: group.name,
                              episode: ep
                            )
                          }
                        } else {
                          Task {
                            await appState.startEpisodePlayback(
                              source: currentSource,
                              detail: d,
                              groupIndex: safeGroupIdx,
                              episodeIndex: ep.index
                            )
                          }
                        }
                      }
                    }
                  }
                  .focusSection()
                }
              }
            } else {
              VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                  .font(.system(size: 56))
                  .foregroundColor(.orange)
                Text(errorMsg ?? "未能加载剧集详情")
                  .font(.title3)
                  .foregroundColor(.white)
                Button("返回片库") {
                  appState.selectedDetailItem = nil
                }
                .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
              }
              .frame(maxWidth: .infinity, minHeight: 520)
            }
          }
          .padding(.horizontal, 60)
          .padding(.vertical, 44)
        }
        .onChange(of: appState.detailScrollToTopTrigger) { _ in
          withAnimation(.easeInOut(duration: 0.28)) {
            scrollProxy.scrollTo("detail_top_anchor", anchor: .top)
          }
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            focusedDetailTarget = "detail_primary_play"
          }
        }
      }
    }
    .onChange(of: appState.activePlayback == nil) { isPlayerClosed in
      if isPlayerClosed {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
          focusedDetailTarget = "detail_primary_play"
        }
      }
    }
    .task(id: item.id) {
      appState.detailShowSourceShelf = false
      appState.detailDownloadMode = false
      appState.detailIsScrolledDown = false
      activeSource = item.source
      await loadDetail(for: item)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
        focusedDetailTarget = "detail_primary_play"
      }
      if let d = detail, d.playGroups.isEmpty {
        await searchAlternativeSources(title: d.vodName)
      }
    }
  }

  private func loadDetail(for target: TvVodItem) async {
    isLoading = true
    defer { isLoading = false }
    do {
      detail = try await appState.api.fetchVodDetail(source: target.source, vodId: target.vodId)
      if let d = detail, let resume = appState.lastWatchedEpisode(for: d) {
        selectedGroupIndex = resume.groupIndex
        selectedChunkIndex = resume.episodeIndex / chunkSize
      } else {
        selectedGroupIndex = 0
        selectedChunkIndex = 0
      }
    } catch {
      errorMsg = error.localizedDescription
    }
  }

  private func switchDetailTo(_ alt: TvVodItem) async {
    activeSource = alt.source
    await loadDetail(for: alt)
  }

  private func searchAlternativeSources(title: String) async {
    isSearchingAlternatives = true
    defer { isSearchingAlternatives = false }
    let sources = Array(appState.vodSources.filter { $0.searchable }.prefix(8))
    var found: [TvVodItem] = []
    await withTaskGroup(of: [TvVodItem].self) { group in
      for src in sources {
        group.addTask { [api = appState.api] in
          await api.searchVod(source: src, keyword: title)
        }
      }
      for await list in group {
        found.append(contentsOf: list.prefix(2))
      }
    }
    alternativeMatches = found
  }

  private func formatClock(_ sec: Double) -> String {
    let total = Int(max(0, sec))
    let m = total / 60
    let s = total % 60
    return String(format: "%02d:%02d", m, s)
  }
}

/// Sleek Compact Episode Link Chip with Progress Bar & Status Indicator (Decoupled from @EnvironmentObject)
struct TvFilmlyEpisodeCard: View {
  @Environment(\.isFocused) private var isFocused
  let episode: TvEpisode
  let sliceIndex: Int
  let groupName: String
  let savedSeconds: Double
  let isLastWatched: Bool
  let downloadMode: Bool
  let action: () -> Void

  var body: some View {
    let theme = TvThemePalette.current

    Button(action: action) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 6) {
          Text(episode.title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .lineLimit(1)

          Spacer(minLength: 2)

          if downloadMode {
            Image(systemName: "arrow.down.circle.fill")
              .font(.system(size: 12, weight: .bold))
              .foregroundColor(theme.accentHover)
          } else if isLastWatched {
            Text("续播")
              .font(.system(size: 10, weight: .bold))
              .foregroundColor(.black)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Capsule().fill(theme.accentHover))
          } else if savedSeconds > 5 {
            Text("\(Int(savedSeconds) / 60)'")
              .font(.system(size: 11, weight: .semibold, design: .monospaced))
              .foregroundColor(theme.accentHover)
          }
        }

        if savedSeconds > 5 {
          GeometryReader { geo in
            ZStack(alignment: .leading) {
              Capsule()
                .fill(Color.white.opacity(0.14))
              Capsule()
                .fill(theme.accentHover)
                .frame(width: min(geo.size.width, max(12, geo.size.width * min(0.95, savedSeconds / 2400.0))))
            }
          }
          .frame(height: 2.5)
        }
      }
      .padding(.horizontal, 13)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(TvAppleSurfaceButtonStyle(isSelected: isLastWatched || savedSeconds > 5, cornerRadius: 10))
    .onChange(of: isFocused) { focused in
      if focused, let appState = TvAppState.shared {
        let shouldBeScrolled = (sliceIndex >= 10)
        if appState.detailIsScrolledDown != shouldBeScrolled {
          appState.detailIsScrolledDown = shouldBeScrolled
        }
      }
    }
  }
}

// MARK: - 2. Live TV Section View (APTV / UHF / 网易爆米花 Apple TV Live Wall + 3-Stage Auto-Healing Player)

@MainActor
final class TvLiveStreamController: ObservableObject {
  @Published var activeChannel: TvLiveChannel? = nil
  @Published var activeUrlIndex: Int = 0
  @Published var isPlaying: Bool = false
  @Published var isBuffering: Bool = false
  @Published var routeStatusText: String = "准备就绪"
  @Published var errorText: String? = nil
  @Published var usingProxyFallback: Bool = false
  @Published var isUsingDirectFlvEngine: Bool = false
  @Published var lastChannelSwitchBannerAt: Date = .distantPast

  let player = AVPlayer()
  let flvEngine = TvDirectFlvHardwareEngine()
  private var sessionId: Int = 0
  private var triedIndices: Set<Int> = []
  private var attemptStartedAt: Date = .distantFuture
  private var currentBackupProxyUrl: String = ""
  private var currentHeaders: [String: String] = [:]
  private var currentIsProxyAttempt: Bool = false
  private var didAdvanceCurrentAttempt: Bool = false

  func stepChannel(in list: [TvLiveChannel], delta: Int, appState: TvAppState) {
    let pool = list.isEmpty ? appState.liveChannels : list
    guard !pool.isEmpty else { return }
    lastChannelSwitchBannerAt = Date()
    guard let cur = activeChannel,
          let curIdx = pool.firstIndex(where: { $0.id == cur.id }) else {
      let first = pool[0]
      startChannel(first, urlIndex: appState.preferredLiveUrlIndex(for: first), resetTried: true, appState: appState)
      return
    }
    let nextIdx = (curIdx + delta + pool.count) % pool.count
    let nextCh = pool[nextIdx]
    startChannel(nextCh, urlIndex: appState.preferredLiveUrlIndex(for: nextCh), resetTried: true, appState: appState)
  }

  func startChannel(
    _ channel: TvLiveChannel,
    urlIndex: Int = 0,
    resetTried: Bool = true,
    forceProxy: Bool = false,
    appState: TvAppState
  ) {
    guard !channel.urls.isEmpty else { return }
    let safeIdx = min(max(0, urlIndex), channel.urls.count - 1)
    sessionId &+= 1
    let currentSession = sessionId

    activeChannel = channel
    activeUrlIndex = safeIdx
    appState.recordLiveChannelSelection(channel: channel, urlIndex: safeIdx)
    if resetTried {
      triedIndices.removeAll()
    }
    triedIndices.insert(safeIdx)
    isPlaying = false
    isBuffering = true
    errorText = nil
    didAdvanceCurrentAttempt = true
    appState.activateScenarioProxyTunnel(for: .liveStream)
    usingProxyFallback = forceProxy || appState.shouldUseServerRelay(for: .liveStream)
    routeStatusText = "正在连接信号 \(safeIdx + 1)/\(channel.urls.count)..."

    Task {
      let resolved = await appState.api.resolveLivePlayback(
        source: appState.selectedLiveSource,
        channel: channel,
        urlIndex: safeIdx,
        forceServerRelay: usingProxyFallback
      )
      guard currentSession == self.sessionId else { return }

      if resolved.isFlvHardwareStream {
        self.startHardwareFlvStream(
          resolved: resolved,
          channel: channel,
          urlIndex: safeIdx,
          session: currentSession,
          isProxyAttempt: usingProxyFallback,
          appState: appState
        )
        return
      }

      self.isUsingDirectFlvEngine = false
      self.flvEngine.stop()
      let targetUrl = resolved.directUrl.isEmpty ? resolved.serverProxyUrl : resolved.directUrl
      let isLocalHlsProxy = targetUrl.contains("127.0.0.1:")
      let headers: [String: String] = (usingProxyFallback && !isLocalHlsProxy)
        ? appState.api.authHeaders
        : resolved.headers

      self.loadUrlIntoPlayer(
        urlStr: targetUrl,
        backupProxyUrl: resolved.serverProxyUrl,
        headers: headers,
        channel: channel,
        urlIndex: safeIdx,
        session: currentSession,
        isProxyAttempt: usingProxyFallback,
        appState: appState
      )
    }
  }

  private func startHardwareFlvStream(
    resolved: TvResolvedPlayback,
    channel: TvLiveChannel,
    urlIndex: Int,
    session: Int,
    isProxyAttempt: Bool,
    appState: TvAppState
  ) {
    guard session == sessionId else { return }
    player.pause()
    player.replaceCurrentItem(with: nil)

    isUsingDirectFlvEngine = true
    currentBackupProxyUrl = resolved.serverProxyUrl
    currentHeaders = resolved.headers
    currentIsProxyAttempt = isProxyAttempt
    attemptStartedAt = Date()
    didAdvanceCurrentAttempt = false

    let eff = appState.resolveEffectiveRoute(for: .liveStream)
    let routeLabel = isProxyAttempt
      ? "服务端代理中转"
      : appState.buildProxyControlLabel(for: .liveStream, compact: false)
    routeStatusText = "\(routeLabel) · 信号 \(urlIndex + 1)/\(channel.urls.count)"

    flvEngine.onFirstFrameRendered = { [weak self] in
      Task { @MainActor in
        guard let self, session == self.sessionId else { return }
        self.isBuffering = false
        self.isPlaying = true
        self.errorText = nil
      }
    }
    flvEngine.onAllCandidatesFailed = { [weak self, weak appState] in
      Task { @MainActor in
        guard let self, let appState, session == self.sessionId, !self.didAdvanceCurrentAttempt else { return }
        self.didAdvanceCurrentAttempt = true
        self.handleFailureOrAdvance(
          backupProxyUrl: resolved.serverProxyUrl,
          headers: resolved.headers,
          channel: channel,
          urlIndex: urlIndex,
          session: session,
          wasProxyAttempt: isProxyAttempt,
          appState: appState
        )
      }
    }

    let primaryTarget = isProxyAttempt
      ? resolved.serverProxyUrl
      : (resolved.flvPrimaryUrl.isEmpty ? resolved.directUrl : resolved.flvPrimaryUrl)
    let primaryHeaders = isProxyAttempt ? appState.api.authHeaders : resolved.headers
    let gatewayTarget = isProxyAttempt ? "" : resolved.flvGatewayUrl

    flvEngine.start(
      primaryUrl: primaryTarget,
      primaryHeaders: primaryHeaders,
      gatewayUrl: gatewayTarget,
      gatewayHeaders: resolved.headers,
      serverProxyUrl: resolved.serverProxyUrl,
      serverAuthHeaders: appState.api.authHeaders,
      forceProxyNode: (eff == .proxyNode && !isProxyAttempt)
    )
  }

  private func loadUrlIntoPlayer(
    urlStr: String,
    backupProxyUrl: String,
    headers: [String: String],
    channel: TvLiveChannel,
    urlIndex: Int,
    session: Int,
    isProxyAttempt: Bool,
    appState: TvAppState
  ) {
    guard session == sessionId else { return }
    let trimmedUrl = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedUrl: URL? = URL(string: trimmedUrl)
      ?? trimmedUrl.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap { URL(string: $0) }
    guard let url = resolvedUrl else {
      handleFailureOrAdvance(
        backupProxyUrl: backupProxyUrl,
        headers: headers,
        channel: channel,
        urlIndex: urlIndex,
        session: session,
        wasProxyAttempt: isProxyAttempt,
        appState: appState
      )
      return
    }

    currentBackupProxyUrl = backupProxyUrl
    currentHeaders = headers
    currentIsProxyAttempt = isProxyAttempt
    attemptStartedAt = Date()
    didAdvanceCurrentAttempt = false

    let isLocalProxy = trimmedUrl.contains("127.0.0.1:")
    let assetHeaders = (isProxyAttempt && !isLocalProxy) ? appState.api.authHeaders : headers
    let asset = AVURLAsset(url: url, options: isLocalProxy ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": assetHeaders])
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = 2.5

    player.pause()
    player.replaceCurrentItem(with: item)
    player.automaticallyWaitsToMinimizeStalling = true
    player.play()

    let routeLabel = isProxyAttempt
      ? "服务端代理中转"
      : appState.buildProxyControlLabel(for: .liveStream, compact: false)
    let newStatus = "\(routeLabel) · 信号 \(urlIndex + 1)/\(channel.urls.count)"
    if routeStatusText != newStatus {
      routeStatusText = newStatus
    }
  }

  /// Safe MainActor periodic status check (replaces KVO & background Timer closures to prevent AVPlayerItem KVO crashes)
  func pollPlaybackStatus(now: Date, appState: TvAppState) {
    guard let ch = activeChannel, !didAdvanceCurrentAttempt else { return }
    let currentSession = sessionId

    if isUsingDirectFlvEngine {
      if flvEngine.isActivelyPlaying {
        if isBuffering { isBuffering = false }
        if !isPlaying { isPlaying = true }
        if errorText != nil { errorText = nil }
        return
      }
      if !flvEngine.hasRecentFrames && now.timeIntervalSince(attemptStartedAt) >= 20.0 {
        didAdvanceCurrentAttempt = true
        handleFailureOrAdvance(
          backupProxyUrl: currentBackupProxyUrl,
          headers: currentHeaders,
          channel: ch,
          urlIndex: activeUrlIndex,
          session: currentSession,
          wasProxyAttempt: currentIsProxyAttempt,
          appState: appState
        )
      }
      return
    }

    if player.timeControlStatus == .playing && player.rate > 0 {
      if isBuffering { isBuffering = false }
      if !isPlaying { isPlaying = true }
      if errorText != nil { errorText = nil }
      return
    }

    guard let curItem = player.currentItem else { return }
    switch curItem.status {
    case .readyToPlay:
      if isBuffering { isBuffering = false }
      if errorText != nil { errorText = nil }
      if !isPlaying || player.rate == 0 || player.timeControlStatus != .playing {
        isPlaying = true
        player.play()
      }
    case .failed:
      didAdvanceCurrentAttempt = true
      handleFailureOrAdvance(
        backupProxyUrl: currentBackupProxyUrl,
        headers: currentHeaders,
        channel: ch,
        urlIndex: activeUrlIndex,
        session: currentSession,
        wasProxyAttempt: currentIsProxyAttempt,
        appState: appState
      )
    default:
      let hasBufferedRanges = !curItem.loadedTimeRanges.isEmpty
      let timeoutSec: TimeInterval = hasBufferedRanges ? 26.0 : 22.0
      if now.timeIntervalSince(attemptStartedAt) >= timeoutSec {
        didAdvanceCurrentAttempt = true
        handleFailureOrAdvance(
          backupProxyUrl: currentBackupProxyUrl,
          headers: currentHeaders,
          channel: ch,
          urlIndex: activeUrlIndex,
          session: currentSession,
          wasProxyAttempt: currentIsProxyAttempt,
          appState: appState
        )
      }
    }
  }

  private func handleFailureOrAdvance(
    backupProxyUrl: String,
    headers: [String: String],
    channel: TvLiveChannel,
    urlIndex: Int,
    session: Int,
    wasProxyAttempt: Bool,
    appState: TvAppState
  ) {
    guard session == sessionId else { return }

    // Stage 2: Automatically advance to the next untested direct signal URL first (matching lib/ui/screens/live_tv_screen.dart)
    if channel.urls.count > 1 && triedIndices.count < min(channel.urls.count, 6) {
      for offset in 1..<channel.urls.count {
        let candidate = (urlIndex + offset) % channel.urls.count
        if !triedIndices.contains(candidate) {
          routeStatusText = "信号 \(urlIndex + 1) 无响应，自动切换备用信号 \(candidate + 1)/\(channel.urls.count)..."
          startChannel(
            channel,
            urlIndex: candidate,
            resetTried: false,
            forceProxy: false,
            appState: appState
          )
          return
        }
      }
    }

    isBuffering = false
    isPlaying = false
    errorText = "当前频道信号源暂时无法连接，请按【换源】或【代理】重试"
    routeStatusText = "连接失败"
  }

  func stop() {
    sessionId &+= 1
    didAdvanceCurrentAttempt = true
    flvEngine.stop()
    isUsingDirectFlvEngine = false
    player.pause()
    player.replaceCurrentItem(with: nil)
    isPlaying = false
    isBuffering = false
  }

  func suspendForBackground() {
    sessionId &+= 1
    didAdvanceCurrentAttempt = true
    flvEngine.stop()
    player.pause()
    player.replaceCurrentItem(with: nil)
    isPlaying = false
    isBuffering = false
  }

  func resumeAfterForeground(appState: TvAppState) {
    guard let ch = activeChannel else { return }
    attemptStartedAt = Date()
    startChannel(ch, urlIndex: activeUrlIndex, resetTried: true, appState: appState)
  }
}

struct TvLiveSectionView: View {
  @EnvironmentObject var appState: TvAppState
  @StateObject private var liveController = TvLiveStreamController()
  @State private var showLiveSourceSheet: Bool = false
  @State private var showChannelSearchSheet: Bool = false
  @State private var showLiveProxySelectorSheet: Bool = false
  @State private var lastInteractionAt: Date = Date()
  @State private var lastAutoHideAt: Date = .distantPast
  @FocusState private var focusedLiveTarget: LiveFocusTarget?
  private let autoHideTick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

  private enum LiveFocusTarget: Hashable {
    case topSourceBtn
    case videoWindowStage
    case previewFullscreenBtn
    case osdPlayPause
    case osdToggleGuide
  }

  var body: some View {
    let channels = appState.filteredLiveChannels
    let guideCollapsed = appState.liveGuideCollapsed

    ZStack {
      if guideCollapsed {
        // FULLSCREEN MODE: 100% Edge-to-Edge Live Video + Up/Down Channel Zapping + Auto-Hiding OSD
        Color.black.ignoresSafeArea()

        if liveController.activeChannel != nil {
          if liveController.isUsingDirectFlvEngine {
            TvDirectFlvHardwareLayerView(engine: liveController.flvEngine, videoGravity: .resizeAspect)
              .ignoresSafeArea()
              .allowsHitTesting(false)
          } else {
            TvRawAVPlayerLayerView(player: liveController.player, videoGravity: .resizeAspect)
              .ignoresSafeArea()
              .allowsHitTesting(false)
          }
        }

        liveCenterStatusOverlay()

        liveFullscreenStage(channels: channels)
      } else {
        // SPLIT PREVIEW MODE: Left 2-Column Channel Guide (Isolated from liveController!) + Right Framed 16:9 Preview Window
        HStack(spacing: 24) {
          TvLiveGuideDrawerView(
            activeChannelId: liveController.activeChannel?.id,
            isPlaying: liveController.isPlaying,
            onOpenSourcePicker: { showLiveSourceSheet = true },
            onOpenSearchSheet: { showChannelSearchSheet = true },
            onSelectChannel: { ch in
              if liveController.activeChannel?.id == ch.id {
                enterFullscreenMode()
              } else {
                liveController.startChannel(
                  ch,
                  urlIndex: appState.preferredLiveUrlIndex(for: ch),
                  resetTried: true,
                  appState: appState
                )
              }
            },
            onForceProxyChannel: { ch in
              liveController.startChannel(
                ch,
                urlIndex: appState.preferredLiveUrlIndex(for: ch),
                resetTried: true,
                forceProxy: true,
                appState: appState
              )
            },
            onEnterFullscreen: {
              enterFullscreenMode()
            }
          )
          liveSplitPreviewColumn(channels: channels)
        }
        .padding(.horizontal, 42)
        .padding(.vertical, 16)
      }

      if appState.showProxyStatsOverlay {
        VStack {
          HStack {
            Spacer()
            TvVideoProxyStatsOverlayCard(
              scenario: .liveStream,
              onOpenSelector: {
                showLiveProxySelectorSheet = true
              },
              onClose: {
                withAnimation(.easeInOut(duration: 0.2)) {
                  appState.showProxyStatsOverlay = false
                }
              }
            )
            .padding(.trailing, 54)
            .padding(.top, 36)
          }
          Spacer()
        }
      }
    }
    .onChange(of: appState.liveScrollToTopTrigger) { _ in
      focusedLiveTarget = .topSourceBtn
    }
    .onChange(of: appState.pageScrollToTopTrigger) { _ in
      if appState.selectedSection == .live && !appState.liveGuideCollapsed {
        focusedLiveTarget = .topSourceBtn
      }
    }
    .onChange(of: appState.remoteActivityTick) { _ in
      if appState.liveGuideCollapsed {
        wakeLiveControls()
      }
    }
    .onChange(of: appState.liveGuideCollapsed) { collapsed in
      lastInteractionAt = Date()
      if collapsed {
        liveController.lastChannelSwitchBannerAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
          focusedLiveTarget = appState.liveFullscreenControlsVisible ? .osdPlayPause : .videoWindowStage
        }
      } else {
        appState.liveFullscreenControlsVisible = true
      }
    }
    .onChange(of: appState.liveFullscreenControlsVisible) { visible in
      if appState.liveGuideCollapsed {
        if visible {
          lastInteractionAt = Date()
        } else {
          lastAutoHideAt = Date()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
          focusedLiveTarget = visible ? .osdPlayPause : .videoWindowStage
        }
      }
    }
    .onReceive(autoHideTick) { now in
      if appState.isAppInBackground {
        if liveController.isPlaying || liveController.isBuffering {
          liveController.suspendForBackground()
        }
        return
      }
      liveController.pollPlaybackStatus(now: now, appState: appState)
      guard !showLiveSourceSheet && !showChannelSearchSheet && !showLiveProxySelectorSheet else {
        return
      }
      if appState.liveGuideCollapsed {
        let latestActivity = max(lastInteractionAt, appState.lastRemoteActivityAt)
        if appState.liveFullscreenControlsVisible && now.timeIntervalSince(latestActivity) >= 3.5 {
          lastAutoHideAt = now
          withAnimation(.easeInOut(duration: 0.25)) {
            appState.liveFullscreenControlsVisible = false
          }
          focusedLiveTarget = .videoWindowStage
        }
      }
    }
    .onChange(of: appState.foregroundResumeTick) { _ in
      lastInteractionAt = Date()
      if appState.selectedSection == .live && appState.activePlayback == nil {
        liveController.resumeAfterForeground(appState: appState)
      }
    }
    .onPlayPauseCommand {
      wakeLiveControls()
      if liveController.isPlaying {
        if liveController.isUsingDirectFlvEngine {
          liveController.flvEngine.pause()
        } else {
          liveController.player.pause()
        }
        liveController.isPlaying = false
      } else {
        if liveController.isUsingDirectFlvEngine {
          liveController.flvEngine.resume()
        } else {
          liveController.player.play()
        }
        liveController.isPlaying = true
      }
    }
    .onAppear {
      lastInteractionAt = Date()
      appState.liveFullscreenChannelStepHandler = { [weak liveController, weak appState] delta in
        guard let liveController = liveController, let appState = appState else { return }
        liveController.stepChannel(in: appState.filteredLiveChannels, delta: delta, appState: appState)
      }
      if appState.liveSources.isEmpty {
        if liveController.activeChannel == nil, let pref = appState.preferredLiveChannelToStart() {
          liveController.startChannel(pref.channel, urlIndex: pref.urlIndex, resetTried: true, appState: appState)
        }
        Task {
          await appState.loadLiveSources()
          if liveController.activeChannel == nil, let pref = appState.preferredLiveChannelToStart() {
            liveController.startChannel(pref.channel, urlIndex: pref.urlIndex, resetTried: true, appState: appState)
          }
        }
      } else if liveController.activeChannel == nil, let pref = appState.preferredLiveChannelToStart() {
        liveController.startChannel(pref.channel, urlIndex: pref.urlIndex, resetTried: true, appState: appState)
      }
    }
    .onChange(of: appState.liveChannels) { _ in
      if liveController.activeChannel == nil, let pref = appState.preferredLiveChannelToStart() {
        liveController.startChannel(pref.channel, urlIndex: pref.urlIndex, resetTried: true, appState: appState)
      }
    }
    .onDisappear {
      appState.liveFullscreenChannelStepHandler = nil
      liveController.stop()
    }
    .sheet(isPresented: $showLiveSourceSheet) {
      TvLiveSourcePickerSheet(isPresented: $showLiveSourceSheet) {
        if let pref = appState.preferredLiveChannelToStart() {
          liveController.startChannel(pref.channel, urlIndex: pref.urlIndex, resetTried: true, appState: appState)
        }
      }
      .environmentObject(appState)
    }
    .sheet(isPresented: $showChannelSearchSheet) {
      TvLiveSearchSheet(isPresented: $showChannelSearchSheet)
        .environmentObject(appState)
    }
    .sheet(isPresented: $showLiveProxySelectorSheet) {
      TvVideoProxyNodeSelectorSheet(
        isPresented: $showLiveProxySelectorSheet,
        scenario: .liveStream
      ) {
        if let ch = liveController.activeChannel {
          liveController.startChannel(
            ch,
            urlIndex: liveController.activeUrlIndex,
            resetTried: true,
            forceProxy: appState.shouldUseServerRelay(for: .liveStream),
            appState: appState
          )
        }
      }
      .environmentObject(appState)
    }
  }

  @ViewBuilder
  private func liveCenterStatusOverlay() -> some View {
    if liveController.isBuffering {
      VStack(spacing: 14) {
        ProgressView()
          .scaleEffect(1.3)
        Text(liveController.routeStatusText)
          .font(.system(size: 17, weight: .semibold))
          .foregroundColor(.white)
        TvVideoDownloadSpeedBadge(player: liveController.player, isBuffering: true, compact: true)
      }
      .padding(.horizontal, 28)
      .padding(.vertical, 20)
      .background(.ultraThinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
      .allowsHitTesting(false)
    } else if let err = liveController.errorText {
      VStack(spacing: 10) {
        Image(systemName: "antenna.radiowaves.left.and.right.slash")
          .font(.system(size: 34))
          .foregroundColor(.orange)
        Text(err)
          .font(.system(size: 16, weight: .medium))
          .foregroundColor(.white)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 440)
      }
      .padding(22)
      .background(.ultraThinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
      .allowsHitTesting(false)
    }
  }

  // MARK: - Split Preview Right Column (Clean 16:9 Framed Video Preview + Uncluttered Info & Action Bar)

  @ViewBuilder
  private func liveSplitPreviewColumn(channels: [TvLiveChannel]) -> some View {
    let theme = appState.activeTheme
    let isVideoFocused = (focusedLiveTarget == .videoWindowStage)

    VStack(spacing: 18) {
      // 1. Framed 16:9 HD Video Preview Window (Click to enter Fullscreen)
      Button {
        enterFullscreenMode()
      } label: {
        ZStack {
          RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(Color.black)

          if liveController.activeChannel != nil {
            if liveController.isUsingDirectFlvEngine {
              TvDirectFlvHardwareLayerView(engine: liveController.flvEngine, videoGravity: .resizeAspect)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .allowsHitTesting(false)
            } else {
              TvRawAVPlayerLayerView(player: liveController.player, videoGravity: .resizeAspect)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .allowsHitTesting(false)
            }
          }

          liveCenterStatusOverlay()

          // Subtle Top-Left Live Status Pill, Top-Right Real-Time Speed Badge & Bottom-Right Fullscreen Hint
          VStack {
            HStack {
              if let ch = liveController.activeChannel {
                HStack(spacing: 8) {
                  Circle()
                    .fill(liveController.isPlaying ? Color(red: 0.19, green: 0.82, blue: 0.35) : Color.orange)
                    .frame(width: 9, height: 9)
                  Text("LIVE · \(ch.name)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.62))
                .clipShape(Capsule())
              }
              Spacer()
              if liveController.activeChannel != nil {
                TvVideoDownloadSpeedBadge(
                  player: liveController.player,
                  isBuffering: liveController.isBuffering,
                  compact: true
                )
              }
            }
            Spacer()
            if isVideoFocused {
              HStack {
                Spacer()
                HStack(spacing: 8) {
                  Image(systemName: "arrow.up.left.and.arrow.down.right")
                  Text("按确定键进入全屏（全屏时按上下键切台）")
                    .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
              }
            }
          }
          .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 26, style: .continuous)
            .stroke(
              isVideoFocused ? theme.accentHover : Color.white.opacity(0.16),
              lineWidth: isVideoFocused ? 3.5 : 1.0
            )
        )
        .shadow(color: .black.opacity(isVideoFocused ? 0.65 : 0.40), radius: isVideoFocused ? 26 : 16, y: 10)
      }
      .buttonStyle(TvVideoCanvasStageButtonStyle())
      .focused($focusedLiveTarget, equals: .videoWindowStage)
      .focusSection()

      // 2. Clean, Uncluttered Bottom Info & Action Bar below the Preview Window
      if let ch = liveController.activeChannel {
        let chIdx = appState.liveChannelNumber(for: ch.id)
        let isFav = appState.isLiveChannelFavorite(ch)

        HStack(spacing: 18) {
          // Left: Channel Number Badge + Title + Concise Status
          HStack(spacing: 14) {
            Text(String(format: "%03d", chIdx))
              .font(.system(size: 18, weight: .bold, design: .monospaced))
              .foregroundColor(theme.accentHover)
              .padding(.horizontal, 11)
              .padding(.vertical, 7)
              .background(theme.accent.opacity(0.18))
              .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
              Text(ch.name)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)

              Text("\(ch.group) · \(liveController.routeStatusText) · 信号 \(liveController.activeUrlIndex + 1)/\(max(1, ch.urls.count))")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
                .lineLimit(1)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          // Right: Real-Time Speed Badge + 4 Permanent, Fixed-Size Action Buttons (Never Inserted/Removed Dynamically!)
          HStack(spacing: 10) {
            TvVideoDownloadSpeedBadge(
              player: liveController.player,
              isBuffering: liveController.isBuffering,
              compact: true
            )

            Button {
              enterFullscreenMode()
            } label: {
              Label("全屏", systemImage: "arrow.up.left.and.arrow.down.right")
                .lineLimit(1)
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
            .fixedSize(horizontal: true, vertical: false)
            .focused($focusedLiveTarget, equals: .previewFullscreenBtn)

            Button {
              let count = max(1, ch.urls.count)
              let nextIdx = (liveController.activeUrlIndex + 1) % count
              liveController.startChannel(ch, urlIndex: nextIdx, resetTried: true, appState: appState)
            } label: {
              Label("换源 \(liveController.activeUrlIndex + 1)/\(max(1, ch.urls.count))", systemImage: "antenna.radiowaves.left.and.right")
                .lineLimit(1)
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
            .fixedSize(horizontal: true, vertical: false)

            Button {
              showLiveProxySelectorSheet = true
            } label: {
              Label(appState.buildProxyControlLabel(for: .liveStream, compact: true), systemImage: "network")
                .lineLimit(1)
            }
            .buttonStyle(TvApplePillButtonStyle(isSelected: liveController.usingProxyFallback || appState.shouldUseProxyOrRelay(for: .liveStream), compact: true))
            .fixedSize(horizontal: true, vertical: false)

            Button {
              withAnimation(.easeInOut(duration: 0.2)) {
                appState.showProxyStatsOverlay.toggle()
              }
            } label: {
              Label(appState.showProxyStatsOverlay ? "隐藏监控" : "代理监控", systemImage: "waveform.path.ecg.rectangle")
                .lineLimit(1)
            }
            .buttonStyle(TvApplePillButtonStyle(isSelected: appState.showProxyStatsOverlay, compact: true))
            .fixedSize(horizontal: true, vertical: false)

            Button {
              appState.toggleLiveChannelFavorite(ch)
            } label: {
              Label(isFav ? "已收藏" : "收藏", systemImage: isFav ? "star.fill" : "star")
                .lineLimit(1)
            }
            .buttonStyle(TvApplePillButtonStyle(isSelected: isFav, compact: true))
            .fixedSize(horizontal: true, vertical: false)
          }
          .focusSection()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Fullscreen Live TV Stage (Up/Down Buttons Switch Channels Directly + Auto-Hiding Bottom OSD)

  @ViewBuilder
  private func liveFullscreenStage(channels: [TvLiveChannel]) -> some View {
    let theme = appState.activeTheme
    let showChannelSwitchHud = Date().timeIntervalSince(liveController.lastChannelSwitchBannerAt) < 3.5

    ZStack {
      // 1. Top-Left Auto-Hiding Channel Switch HUD Banner (Shows on Up/Down channel switch)
      if (showChannelSwitchHud || appState.liveFullscreenControlsVisible),
         let ch = liveController.activeChannel {
        let chIdx = appState.liveChannelNumber(for: ch.id)
        VStack {
          HStack {
            HStack(spacing: 14) {
              Text(String(format: "%03d", chIdx))
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(theme.accentHover)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(theme.accent.opacity(0.22))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

              VStack(alignment: .leading, spacing: 2) {
                Text(ch.name)
                  .font(.system(size: 20, weight: .bold))
                  .foregroundColor(.white)
                Text("\(ch.group) · 信号 \(liveController.activeUrlIndex + 1)/\(max(1, ch.urls.count)) · ▲▼ 上下键换台")
                  .font(.system(size: 13, weight: .medium))
                  .foregroundColor(.white.opacity(0.72))
              }

              TvVideoDownloadSpeedBadge(
                player: liveController.player,
                isBuffering: liveController.isBuffering,
                compact: true
              )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 18, y: 8)

            Spacer()
          }
          Spacer()
        }
        .padding(.horizontal, 42)
        .padding(.top, 32)
        .allowsHitTesting(false)
      }

      // 2. Interactive Fullscreen Stage or Bottom Floating Control Bar
      if !appState.liveFullscreenControlsVisible {
        Button {
          wakeLiveControls()
        } label: {
          Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(TvVideoCanvasStageButtonStyle())
        .focused($focusedLiveTarget, equals: .videoWindowStage)
        .onMoveCommand { dir in
          switch dir {
          case .up:
            appState.triggerLiveFullscreenChannelStep(-1)
          case .down:
            appState.triggerLiveFullscreenChannelStep(1)
          case .left:
            if let ch = liveController.activeChannel, ch.urls.count > 1 {
              let prevIdx = (liveController.activeUrlIndex - 1 + ch.urls.count) % ch.urls.count
              liveController.startChannel(ch, urlIndex: prevIdx, resetTried: true, appState: appState)
              liveController.lastChannelSwitchBannerAt = Date()
            } else {
              wakeLiveControls()
            }
          case .right:
            if let ch = liveController.activeChannel, ch.urls.count > 1 {
              let nextIdx = (liveController.activeUrlIndex + 1) % ch.urls.count
              liveController.startChannel(ch, urlIndex: nextIdx, resetTried: true, appState: appState)
              liveController.lastChannelSwitchBannerAt = Date()
            } else {
              wakeLiveControls()
            }
          @unknown default:
            wakeLiveControls()
          }
        }
        .focusSection()
      } else if let ch = liveController.activeChannel {
        let isFav = appState.isLiveChannelFavorite(ch)
        VStack {
          Spacer()
          HStack(spacing: 12) {
            Button {
              lastInteractionAt = Date()
              if liveController.isPlaying {
                if liveController.isUsingDirectFlvEngine {
                  liveController.flvEngine.pause()
                } else {
                  liveController.player.pause()
                }
                liveController.isPlaying = false
              } else {
                if liveController.isUsingDirectFlvEngine {
                  liveController.flvEngine.resume()
                } else {
                  liveController.player.play()
                }
                liveController.isPlaying = true
              }
            } label: {
              Label(liveController.isPlaying ? "暂停" : "播放", systemImage: liveController.isPlaying ? "pause.fill" : "play.fill")
                .lineLimit(1)
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
            .fixedSize(horizontal: true, vertical: false)
            .focused($focusedLiveTarget, equals: .osdPlayPause)

            Button {
              withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                appState.liveGuideCollapsed = false
                appState.liveFullscreenControlsVisible = true
              }
            } label: {
              Label("频道列表", systemImage: "sidebar.left")
                .lineLimit(1)
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
            .fixedSize(horizontal: true, vertical: false)
            .focused($focusedLiveTarget, equals: .osdToggleGuide)

            Button {
              lastInteractionAt = Date()
              liveController.stepChannel(in: channels, delta: -1, appState: appState)
            } label: {
              Label("上一台 ▲", systemImage: "chevron.up.circle.fill")
                .lineLimit(1)
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
            .fixedSize(horizontal: true, vertical: false)

            Button {
              lastInteractionAt = Date()
              liveController.stepChannel(in: channels, delta: 1, appState: appState)
            } label: {
              Label("下一台 ▼", systemImage: "chevron.down.circle.fill")
                .lineLimit(1)
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
            .fixedSize(horizontal: true, vertical: false)

            Button {
              lastInteractionAt = Date()
              let count = max(1, ch.urls.count)
              let nextIdx = (liveController.activeUrlIndex + 1) % count
              liveController.startChannel(ch, urlIndex: nextIdx, resetTried: true, appState: appState)
            } label: {
              Label("换源 \(liveController.activeUrlIndex + 1)/\(max(1, ch.urls.count))", systemImage: "antenna.radiowaves.left.and.right")
                .lineLimit(1)
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
            .fixedSize(horizontal: true, vertical: false)

            Button {
              lastInteractionAt = Date()
              showLiveProxySelectorSheet = true
            } label: {
              Label("代理: \(appState.buildProxyControlLabel(for: .liveStream, compact: true)) ▾", systemImage: "network")
                .lineLimit(1)
            }
            .buttonStyle(TvApplePillButtonStyle(isSelected: liveController.usingProxyFallback || appState.shouldUseProxyOrRelay(for: .liveStream), compact: true))
            .fixedSize(horizontal: true, vertical: false)

            Button {
              lastInteractionAt = Date()
              withAnimation(.easeInOut(duration: 0.2)) {
                appState.showProxyStatsOverlay.toggle()
              }
            } label: {
              Label(appState.showProxyStatsOverlay ? "隐藏监控" : "代理监控", systemImage: "waveform.path.ecg.rectangle")
                .lineLimit(1)
            }
            .buttonStyle(TvApplePillButtonStyle(isSelected: appState.showProxyStatsOverlay, compact: true))
            .fixedSize(horizontal: true, vertical: false)

            Button {
              lastInteractionAt = Date()
              appState.toggleLiveChannelFavorite(ch)
            } label: {
              Label(isFav ? "已收藏" : "收藏", systemImage: isFav ? "star.fill" : "star")
                .lineLimit(1)
            }
            .buttonStyle(TvApplePillButtonStyle(isSelected: isFav, compact: true))
            .fixedSize(horizontal: true, vertical: false)

            Button {
              lastInteractionAt = Date()
              Task { await appState.recordLiveChannel(ch, urlIndex: liveController.activeUrlIndex) }
            } label: {
              Label("录制", systemImage: "record.circle")
                .lineLimit(1)
            }
            .buttonStyle(TvApplePillButtonStyle(isDestructive: true, compact: true))
            .fixedSize(horizontal: true, vertical: false)

            TvVideoDownloadSpeedBadge(
              player: liveController.player,
              isBuffering: liveController.isBuffering,
              compact: true
            )
          }
          .padding(.horizontal, 24)
          .padding(.vertical, 16)
          .background(.ultraThinMaterial)
          .clipShape(Capsule(style: .continuous))
          .overlay(
            Capsule(style: .continuous)
              .stroke(Color.white.opacity(0.18), lineWidth: 1)
          )
          .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
          .padding(.bottom, 32)
          .onMoveCommand { dir in
            lastInteractionAt = Date()
            if dir == .up {
              appState.triggerLiveFullscreenChannelStep(-1)
            } else if dir == .down {
              appState.triggerLiveFullscreenChannelStep(1)
            }
          }
          .focusSection()
        }
      }
    }
  }

  private func enterFullscreenMode() {
    lastInteractionAt = Date()
    liveController.lastChannelSwitchBannerAt = Date()
    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
      appState.liveGuideCollapsed = true
      appState.liveFullscreenControlsVisible = false
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      focusedLiveTarget = .videoWindowStage
    }
  }

  private func wakeLiveControls() {
    let now = Date()
    guard now.timeIntervalSince(lastAutoHideAt) > 0.45,
          now.timeIntervalSince(appState.lastControlsManualHideAt) > 0.45 else { return }
    lastInteractionAt = now
    guard appState.liveGuideCollapsed else { return }
    if !appState.liveFullscreenControlsVisible {
      withAnimation(.easeOut(duration: 0.2)) {
        appState.liveFullscreenControlsVisible = true
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        focusedLiveTarget = .osdPlayPause
      }
    }
  }
}

struct TvLiveGuideDrawerView: View {
  @EnvironmentObject var appState: TvAppState
  let activeChannelId: String?
  let isPlaying: Bool
  let onOpenSourcePicker: () -> Void
  let onOpenSearchSheet: () -> Void
  let onSelectChannel: (TvLiveChannel) -> Void
  let onForceProxyChannel: (TvLiveChannel) -> Void
  let onEnterFullscreen: () -> Void

  @State private var visibleChannelLimit: Int = 80
  @FocusState private var focusedTopSourceBtn: Bool

  var body: some View {
    let channels = appState.filteredLiveChannels
    let totalCount = channels.count
    let activeSliceCount = min(totalCount, max(80, visibleChannelLimit))

    VStack(spacing: 14) {
      // Top Source & Search Bar
      HStack(spacing: 10) {
        Button(action: onOpenSourcePicker) {
          HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
            Text(appState.selectedLiveSource?.displayName ?? "选择直播源")
              .lineLimit(1)
            Image(systemName: "chevron.down")
              .font(.caption2)
          }
        }
        .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
        .focused($focusedTopSourceBtn)

        Button(action: onOpenSearchSheet) {
          Label(
            appState.liveSearchKeyword.isEmpty ? "搜索" : appState.liveSearchKeyword,
            systemImage: "magnifyingglass"
          )
          .lineLimit(1)
        }
        .buttonStyle(TvApplePillButtonStyle(isSelected: !appState.liveSearchKeyword.isEmpty, compact: true))
        .fixedSize(horizontal: true, vertical: false)

        if !appState.liveSearchKeyword.isEmpty {
          Button {
            appState.liveSearchKeyword = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))
        }

        Spacer()
      }
      .focusSection()

      Divider()
        .background(Color.white.opacity(0.14))

      if appState.isLoadingLive {
        Spacer()
        ProgressView("正在解析直播频道列表...")
        Spacer()
      } else {
        // 2-Column Split: Group Rail (185pt) + Windowed Channel List
        HStack(spacing: 14) {
          ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 8) {
              ForEach(appState.liveGroups, id: \.self) { grp in
                let isSelected = appState.selectedLiveGroup == grp
                let count = appState.liveGroupCount(grp)
                Button {
                  visibleChannelLimit = 80
                  appState.selectedLiveGroup = grp
                } label: {
                  HStack {
                    Text(grp)
                      .font(.system(size: 18, weight: isSelected ? .bold : .medium))
                      .foregroundColor(.white)
                      .lineLimit(1)
                    Spacer()
                    Text("\(count)")
                      .font(.system(size: 14, weight: .semibold, design: .monospaced))
                      .foregroundColor(.white.opacity(0.65))
                  }
                  .padding(.horizontal, 14)
                  .padding(.vertical, 11)
                }
                .buttonStyle(TvAppleSurfaceButtonStyle(isSelected: isSelected, cornerRadius: 14))
              }
            }
            .padding(4)
          }
          .frame(width: 185)
          .focusSection()

          Rectangle()
            .fill(Color.white.opacity(0.10))
            .frame(width: 1)

          ScrollViewReader { chanProxy in
            ScrollView(.vertical, showsIndicators: false) {
              LazyVStack(spacing: 8) {
                Color.clear.frame(height: 1).id("live_channel_top")
                ForEach(0..<activeSliceCount, id: \.self) { idx in
                  let ch = channels[idx]
                  TvLiveChannelRowView(
                    index: idx,
                    channel: ch,
                    isCurrent: activeChannelId == ch.id,
                    isPlaying: isPlaying && activeChannelId == ch.id,
                    isFav: appState.isLiveChannelFavorite(ch),
                    onSelect: { onSelectChannel(ch) },
                    onToggleFav: { appState.toggleLiveChannelFavorite(ch) },
                    onForceProxy: { onForceProxyChannel(ch) },
                    onFullscreen: onEnterFullscreen,
                    onFocusedAtIndex: { focusedIdx in
                      let shouldBeScrolled = focusedIdx >= 5
                      if appState.liveChannelListScrolledDown != shouldBeScrolled {
                        appState.liveChannelListScrolledDown = shouldBeScrolled
                      }
                      if focusedIdx >= visibleChannelLimit - 16 && visibleChannelLimit < totalCount {
                        visibleChannelLimit = min(totalCount, visibleChannelLimit + 80)
                      }
                    }
                  )
                }
                if visibleChannelLimit < totalCount {
                  Button("继续显示更多频道 (\(activeSliceCount)/\(totalCount))") {
                    visibleChannelLimit = min(totalCount, visibleChannelLimit + 100)
                  }
                  .buttonStyle(TvApplePillButtonStyle(compact: true))
                  .padding(.vertical, 8)
                  .onAppear {
                    visibleChannelLimit = min(totalCount, visibleChannelLimit + 100)
                  }
                }
              }
              .padding(4)
            }
            .onChange(of: appState.liveScrollToTopTrigger) { _ in
              if appState.liveChannelListScrolledDown {
                appState.liveChannelListScrolledDown = false
              }
              focusedTopSourceBtn = true
              withAnimation(.easeInOut(duration: 0.22)) {
                chanProxy.scrollTo("live_channel_top", anchor: .top)
              }
            }
          }
          .frame(maxWidth: .infinity)
          .focusSection()
        }
      }
    }
    .frame(width: 640)
    .padding(22)
    .background(Color(red: 0.06, green: 0.08, blue: 0.13).opacity(0.92))
    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .stroke(Color.white.opacity(0.15), lineWidth: 1)
    )
    .onChange(of: appState.liveSearchKeyword) { _ in
      visibleChannelLimit = 80
    }
    .onChange(of: activeChannelId) { newId in
      if let id = newId {
        let num = appState.liveChannelNumber(for: id)
        if num > visibleChannelLimit {
          visibleChannelLimit = min(totalCount, num + 30)
        }
      }
    }
  }
}

/// Pure, Decoupled Live Channel Row (No @EnvironmentObject observation — 0ms focus navigation in 1,500+ channel lists)
struct TvLiveChannelRowView: View {
  @Environment(\.isFocused) private var isFocused
  let index: Int
  let channel: TvLiveChannel
  let isCurrent: Bool
  let isPlaying: Bool
  let isFav: Bool
  let onSelect: () -> Void
  let onToggleFav: () -> Void
  let onForceProxy: () -> Void
  let onFullscreen: () -> Void
  let onFocusedAtIndex: (Int) -> Void

  var body: some View {
    let theme = TvThemePalette.current

    Button(action: onSelect) {
      HStack(spacing: 12) {
        Text(String(format: "%03d", index + 1))
          .font(.system(size: 15, weight: .bold, design: .monospaced))
          .foregroundColor(isCurrent ? theme.accentHover : .white.opacity(0.55))
          .frame(width: 44, height: 30)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(isCurrent ? theme.accent.opacity(0.24) : Color.white.opacity(0.07))
          )

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(channel.name)
              .font(.system(size: 18, weight: .semibold))
              .foregroundColor(.white)
              .lineLimit(1)
            if isFav {
              Image(systemName: "star.fill")
                .font(.caption2)
                .foregroundColor(.yellow)
            }
          }
          Text("\(channel.group) · \(channel.urls.count) 线")
            .font(.system(size: 13))
            .foregroundColor(.white.opacity(0.55))
            .lineLimit(1)
        }

        Spacer()

        if isCurrent {
          Image(systemName: isPlaying ? "waveform.circle.fill" : "play.circle.fill")
            .font(.system(size: 22))
            .foregroundColor(theme.accentHover)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
    }
    .buttonStyle(TvAppleSurfaceButtonStyle(isSelected: isCurrent, cornerRadius: 15))
    .onChange(of: isFocused) { focused in
      if focused {
        onFocusedAtIndex(index)
      }
    }
    .contextMenu {
      Button(action: onFullscreen) {
        Label("全屏观看", systemImage: "arrow.up.left.and.arrow.down.right")
      }
      Button(action: onToggleFav) {
        Label(isFav ? "取消收藏频道" : "收藏此频道", systemImage: isFav ? "star.slash" : "star.fill")
      }
      Button(action: onForceProxy) {
        Label("使用服务端代理播放", systemImage: "network")
      }
    }
  }
}

struct TvLiveSourcePickerSheet: View {
  @EnvironmentObject var appState: TvAppState
  @Binding var isPresented: Bool
  let onSelected: () -> Void

  var body: some View {
    let theme = appState.activeTheme

    ZStack {
      LinearGradient(
        colors: [Color(red: 0.06, green: 0.08, blue: 0.13), Color(red: 0.03, green: 0.04, blue: 0.07)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      VStack(alignment: .leading, spacing: 18) {
        HStack {
          Label("切换电视直播源 (\(appState.liveSources.count))", systemImage: "antenna.radiowaves.left.and.right")
            .font(.system(size: 22, weight: .bold))
            .foregroundColor(.white)
          Spacer()
          Button("关闭") { isPresented = false }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
        }
        .focusSection()

        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 325), spacing: 12)], spacing: 12) {
            ForEach(appState.liveSources) { src in
              let isSelected = appState.selectedLiveSource?.id == src.id
              Button {
                isPresented = false
                Task {
                  await appState.selectLiveSource(src)
                  onSelected()
                }
              } label: {
                HStack(spacing: 10) {
                  Text(src.isCustom ? "M3U" : "TVBox")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(src.isCustom ? theme.accentHover : Color(red: 0.35, green: 0.82, blue: 1.0))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background((src.isCustom ? theme.accent : Color.blue).opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                  VStack(alignment: .leading, spacing: 2) {
                    Text(src.displayName)
                      .font(.system(size: 15, weight: .semibold))
                      .foregroundColor(.white)
                      .lineLimit(1)
                    Text(src.isCustom ? "自定义直播源" : "TVBox 聚合直播源")
                      .font(.system(size: 11))
                      .foregroundColor(.white.opacity(0.50))
                      .lineLimit(1)
                  }

                  Spacer()

                  if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                      .font(.system(size: 16))
                      .foregroundColor(Color(red: 0.30, green: 0.85, blue: 0.48))
                  }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
              }
              .buttonStyle(TvAppleSurfaceButtonStyle(isSelected: isSelected, cornerRadius: 12))
            }
          }
          .padding(4)
        }
        .focusSection()
      }
      .padding(36)
    }
  }
}

struct TvLiveSearchSheet: View {
  @EnvironmentObject var appState: TvAppState
  @Binding var isPresented: Bool

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color(red: 0.06, green: 0.08, blue: 0.13), Color(red: 0.03, green: 0.04, blue: 0.07)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      VStack(spacing: 28) {
        Text("搜索直播频道")
          .font(.largeTitle.bold())
        TextField("输入频道名称（如 CCTV、湖南卫视、翡翠台）...", text: $appState.liveSearchKeyword)
          .frame(width: 720)
        HStack(spacing: 20) {
          Button("清空关键词") {
            appState.liveSearchKeyword = ""
            isPresented = false
          }
          .buttonStyle(TvApplePillButtonStyle())

          Button("完成") {
            isPresented = false
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
        }
      }
      .padding(60)
    }
  }
}

// MARK: - 3. Official Telegram Client View (1:1 Match with Original App & Official Apple TV Design)

struct TvTelegramSectionView: View {
  @EnvironmentObject var appState: TvAppState
  @State private var composeText: String = ""
  @State private var confirmLeaveChat: TvTelegramChat? = nil
  @State private var showEmojiQuickReplySheet: Bool = false
  @State private var showForwardTargetSheet: Bool = false
  @State private var messagesPendingForward: [TvTelegramMessage] = []
  @State private var showAccountSettingsSheet: Bool = false

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      if !appState.telegramAuthStatus.authorized && !appState.isLoadingTelegram {
        TvTelegramUnauthorizedPlaceholder(onOpenSettings: {
          showAccountSettingsSheet = true
        })
      } else {
        HStack(spacing: 0) {
          if !appState.telegramSidebarCollapsed {
            // 1. Far-Left Vertical Folder & Account Rail (Official Telegram Desktop / macOS / Apple TV style)
            TvTelegramFolderRailView(onOpenAccountSettings: {
              showAccountSettingsSheet = true
            })
            .focusSection()

            // 2. Left Dialogs Sidebar
            TvTelegramDialogsSidebarView(
              onRequestLeaveOrDelete: { chat in
                confirmLeaveChat = chat
              }
            )
            .frame(width: 400)
            .focusSection()

            Rectangle()
              .fill(TvTelegramPalette.borderLine)
              .frame(width: 1)
          }

          // 3. Main Conversation Pane
          TvTelegramConversationPaneView(
            composeText: $composeText,
            onRequestLeaveOrDelete: { chat in
              confirmLeaveChat = chat
            },
            onOpenEmojiSheet: {
              showEmojiQuickReplySheet = true
            },
            onRequestForward: { msgs in
              messagesPendingForward = msgs
              showForwardTargetSheet = true
            }
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .focusSection()

          // 4. Optional Right Chat Info & Shared Media Drawer
          if appState.telegramShowRightInfoPanel, let chat = appState.selectedTelegramChat {
            Rectangle()
              .fill(TvTelegramPalette.borderLine)
              .frame(width: 1)

            TvTelegramRightInfoDrawerView(
              chat: chat,
              onRequestLeaveOrDelete: {
                confirmLeaveChat = chat
              }
            )
            .frame(width: 410)
            .focusSection()
          }
        }
      }

      // 5. Floating Mini-Player PIP Window (when a Telegram video is minimized)
      if let miniChat = appState.miniPlayerChat, let miniMsg = appState.miniPlayerMessage {
        TvTelegramMiniPlayerOverlay(chat: miniChat, message: miniMsg)
          .padding(.trailing, 36)
          .padding(.bottom, 100)
          .zIndex(50)
          .focusSection()
      }
    }
    .background(TvTelegramPalette.chatWallpaperBg)
    .onAppear {
      if appState.telegramChats.isEmpty {
        Task { await appState.loadTelegramAccounts() }
      }
    }
    .alert(
      confirmLeaveChat?.conversationActionLabel ?? "确认操作",
      isPresented: Binding(
        get: { confirmLeaveChat != nil },
        set: { if !$0 { confirmLeaveChat = nil } }
      ),
      presenting: confirmLeaveChat
    ) { chat in
      Button("确认\(chat.conversationActionLabel)", role: .destructive) {
        Task { await appState.performConversationAction(chat: chat) }
      }
      Button("取消", role: .cancel) {}
    } message: { chat in
      Text(
        chat.conversationActionType == "delete_contact"
          ? "确定删除好友「\(chat.title)」？删除后将从联系人列表中移除。"
          : "确定\(chat.conversationActionLabel)「\(chat.title)」？退出后将从会话列表中移除且不再接收新消息。"
      )
    }
    .sheet(isPresented: $showEmojiQuickReplySheet) {
      TvTelegramEmojiAndQuickReplySheet(
        onInsertText: { text in
          composeText += text
        },
        onSendImmediate: { phrase in
          Task { await appState.sendTelegramMessage(text: phrase) }
        }
      )
      .environmentObject(appState)
    }
    .sheet(isPresented: $showForwardTargetSheet) {
      TvTelegramForwardTargetSheet(
        isPresented: $showForwardTargetSheet,
        messagesToForward: messagesPendingForward
      )
      .environmentObject(appState)
    }
    .sheet(isPresented: $showAccountSettingsSheet) {
      TvTelegramAccountConfigSheet(isPresented: $showAccountSettingsSheet)
        .environmentObject(appState)
    }
  }
}

/// 1. Far-Left Vertical Folder & Account Rail (Official Telegram Desktop style)
struct TvTelegramFolderRailView: View {
  @EnvironmentObject var appState: TvAppState
  let onOpenAccountSettings: () -> Void

  private func folderIcon(for folder: TvTelegramFolder) -> String {
    if folder.key == "0" { return "bubble.left.and.bubble.right.fill" }
    if folder.key == "1" { return "archivebox.fill" }
    let t = folder.title.lowercased()
    if t.contains("频道") || t.contains("channel") { return "megaphone.fill" }
    if t.contains("群") || t.contains("group") { return "person.3.fill" }
    if t.contains("影视") || t.contains("视频") || t.contains("媒体") { return "film.fill" }
    if t.contains("机器人") || t.contains("bot") { return "cpu.fill" }
    return "folder.fill"
  }

  var body: some View {
    let activeAcc = appState.telegramAccounts.first(where: { $0.id == appState.activeTelegramAccountId })
      ?? TvTelegramAccount(id: appState.activeTelegramAccountId, name: "账号", username: "", userId: "", avatar: "")

    VStack(spacing: 12) {
      // Active Account Avatar Button
      Button(action: onOpenAccountSettings) {
        VStack(spacing: 6) {
          ZStack(alignment: .bottomTrailing) {
            TvTelegramPeerAvatar(
              peer: activeAcc.id,
              title: activeAcc.name,
              avatarUrl: activeAcc.avatar,
              size: 50,
              fontSize: 18
            )
            Circle()
              .fill(appState.telegramAuthStatus.authorized ? TvTelegramPalette.onlineGreen : Color.orange)
              .frame(width: 14, height: 14)
              .overlay(Circle().stroke(TvTelegramPalette.folderRailBg, lineWidth: 2.5))
          }
          Text(activeAcc.name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .lineLimit(1)
        }
        .padding(.vertical, 8)
        .frame(width: 78)
      }
      .buttonStyle(TvAppleSurfaceButtonStyle(cornerRadius: 16))
      .padding(.top, 12)

      // Multi-account quick switcher if > 1 account
      if appState.telegramAccounts.count > 1 {
        ForEach(appState.telegramAccounts.filter { $0.id != appState.activeTelegramAccountId }) { acc in
          Button {
            Task { await appState.switchTelegramAccount(acc.id) }
          } label: {
            TvTelegramPeerAvatar(
              peer: acc.id,
              title: acc.name,
              avatarUrl: acc.avatar,
              size: 40,
              fontSize: 15
            )
            .padding(6)
          }
          .buttonStyle(TvAppleSurfaceButtonStyle(cornerRadius: 14))
        }
      }

      Divider()
        .background(TvTelegramPalette.borderLine)
        .padding(.horizontal, 12)

      // Vertical Folder Tabs
      ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 10) {
          ForEach(appState.telegramFolders) { folder in
            let isSelected = appState.selectedTelegramFolderKey == folder.key
            Button {
              Task { await appState.switchTelegramFolder(folder.key) }
            } label: {
              VStack(spacing: 6) {
                Image(systemName: folderIcon(for: folder))
                  .font(.system(size: 24, weight: isSelected ? .bold : .regular))
                  .foregroundColor(isSelected ? TvTelegramPalette.folderRailActive : TvTelegramPalette.folderRailInactive)

                Text(folder.title)
                  .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                  .foregroundColor(isSelected ? TvTelegramPalette.folderRailActive : TvTelegramPalette.folderRailInactive)
                  .lineLimit(1)
              }
              .padding(.vertical, 12)
              .padding(.horizontal, 6)
              .frame(width: 80)
              .overlay(
                alignment: .leading,
                content: {
                  if isSelected {
                    RoundedRectangle(cornerRadius: 2)
                      .fill(TvTelegramPalette.folderRailActive)
                      .frame(width: 4, height: 34)
                  }
                }
              )
            }
            .buttonStyle(TvAppleSurfaceButtonStyle(isSelected: isSelected, cornerRadius: 16))
          }
        }
      }

      Spacer()

      // Saved Messages (收藏夹) Quick Button
      Button {
        Task { await appState.selectSavedMessagesChat() }
      } label: {
        VStack(spacing: 4) {
          Image(systemName: "bookmark.fill")
            .font(.system(size: 20))
            .foregroundColor(TvTelegramPalette.folderRailActive)
          Text("收藏夹")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(TvTelegramPalette.folderRailInactive)
        }
        .padding(.vertical, 10)
        .frame(width: 78)
      }
      .buttonStyle(TvAppleSurfaceButtonStyle(cornerRadius: 14))

      // Settings Button
      Button(action: onOpenAccountSettings) {
        Image(systemName: "gearshape.fill")
          .font(.system(size: 22))
          .foregroundColor(TvTelegramPalette.folderRailInactive)
          .frame(width: 78, height: 48)
      }
      .buttonStyle(TvAppleSurfaceButtonStyle(cornerRadius: 14))
      .padding(.bottom, 16)
    }
    .frame(width: 96)
    .background(TvTelegramPalette.folderRailBg)
  }
}

/// 2. Left Dialogs Sidebar (Official Telegram Desktop & macOS style)
struct TvTelegramDialogsSidebarView: View {
  @EnvironmentObject var appState: TvAppState
  let onRequestLeaveOrDelete: (TvTelegramChat) -> Void

  var body: some View {
    let unreadTotal = appState.telegramChats.reduce(0) { $0 + ($1.unread > 0 ? 1 : 0) }

    VStack(spacing: 0) {
      // Top Search & Quick Actions Bar
      HStack(spacing: 10) {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 18))
            .foregroundColor(TvTelegramPalette.textMuted)
          TextField("搜索会话或频道", text: $appState.telegramChatFilter)
            .font(.system(size: 18))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(TvTelegramPalette.searchFill)
        .clipShape(Capsule())

        if unreadTotal > 0 {
          Button {
            Task { await appState.markAllTelegramChatsRead() }
          } label: {
            Image(systemName: "checkmark.circle.badge.questionmark.fill")
              .font(.system(size: 18))
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))
        }

        Button {
          Task {
            await appState.loadTelegramChats(
              accountId: appState.activeTelegramAccountId,
              folder: appState.selectedTelegramFolderKey,
              loadMore: false
            )
          }
        } label: {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 18))
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      .background(TvTelegramPalette.headerBg)

      Rectangle()
        .fill(TvTelegramPalette.borderLine)
        .frame(height: 1)

      // Dialog Rows List
      if appState.isLoadingTelegram && appState.telegramChats.isEmpty {
        Spacer()
        ProgressView("正在同步 Telegram 会话...")
        Spacer()
      } else if appState.filteredTelegramChats.isEmpty {
        Spacer()
        Text("没有匹配的会话")
          .font(.callout)
          .foregroundColor(TvTelegramPalette.textMuted)
        Spacer()
      } else {
        ScrollView {
          LazyVStack(spacing: 6) {
            ForEach(appState.filteredTelegramChats) { chat in
              let isSelected = appState.selectedTelegramChat?.peer == chat.peer
              let isMuted = appState.isPeerMuted(chat)
              let draft = appState.telegramDrafts[appState.draftKey(for: chat)] ?? ""

              Button {
                Task { await appState.selectTelegramChat(chat) }
              } label: {
                HStack(spacing: 14) {
                  TvTelegramPeerAvatar(
                    peer: chat.peer,
                    title: chat.title,
                    avatarUrl: appState.resolvePeerAvatarUrl(for: chat),
                    previewAvatar: chat.avatar,
                    isSelf: chat.isSelf,
                    size: 56,
                    fontSize: 21
                  )

                  VStack(alignment: .leading, spacing: 6) {
                    // Top Line: Type Icon + Title + Mute Icon + Time
                    HStack(spacing: 6) {
                      if chat.broadcast || chat.kind.contains("频道") {
                        Image(systemName: "megaphone.fill")
                          .font(.system(size: 14))
                          .foregroundColor(isSelected ? .white : TvTelegramPalette.textSecondary)
                      } else if chat.peer.hasPrefix("chat:") || chat.peer.hasPrefix("channel:") {
                        Image(systemName: "person.2.fill")
                          .font(.system(size: 14))
                          .foregroundColor(isSelected ? .white : TvTelegramPalette.textSecondary)
                      }

                      Text(chat.title)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(TvTelegramPalette.textPrimary)
                        .lineLimit(1)

                      if isMuted {
                        Image(systemName: "speaker.slash.fill")
                          .font(.system(size: 13))
                          .foregroundColor(isSelected ? .white.opacity(0.7) : TvTelegramPalette.textMuted)
                      }

                      Spacer()

                      Text(chat.formattedDialogTime)
                        .font(.system(size: 14))
                        .foregroundColor(isSelected ? .white.opacity(0.85) : TvTelegramPalette.textMuted)
                    }

                    // Bottom Line: Draft / Preview + Unread Pill Badge
                    HStack(spacing: 8) {
                      if !draft.isEmpty {
                        Text("[草稿] \(draft)")
                          .font(.system(size: 16))
                          .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.42))
                          .lineLimit(1)
                      } else {
                        Text(chat.preview.isEmpty ? (chat.broadcast ? "频道广播" : "点击查看消息") : chat.preview)
                          .font(.system(size: 16))
                          .foregroundColor(isSelected ? .white.opacity(0.82) : TvTelegramPalette.textSecondary)
                          .lineLimit(1)
                      }

                      Spacer()

                      if chat.unread > 0 {
                        Text("\(chat.unread)")
                          .font(.system(size: 14, weight: .bold))
                          .foregroundColor(.white)
                          .padding(.horizontal, 9)
                          .padding(.vertical, 3)
                          .background(
                            Capsule()
                              .fill(isMuted ? TvTelegramPalette.textMuted : TvTelegramPalette.tgBlueBright)
                          )
                      }
                    }
                  }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
              }
              .buttonStyle(TvAppleSurfaceButtonStyle(isSelected: isSelected, cornerRadius: 16))
              .contextMenu {
                if chat.unread > 0 {
                  Button {
                    Task { await appState.markChatAsRead(chat, maxId: chat.topMessageId) }
                  } label: {
                    Label("标记为已读", systemImage: "checkmark.circle")
                  }
                }
                Button {
                  appState.togglePeerMute(chat)
                } label: {
                  Label(isMuted ? "开启通知" : "设为免打扰", systemImage: isMuted ? "bell.fill" : "bell.slash.fill")
                }
                Button {
                  Task {
                    await appState.selectTelegramChat(chat)
                    appState.telegramShowRightInfoPanel = true
                  }
                } label: {
                  Label("查看共享媒体与资料", systemImage: "info.circle")
                }
                if !chat.conversationActionLabel.isEmpty {
                  Button(role: .destructive) {
                    onRequestLeaveOrDelete(chat)
                  } label: {
                    Label(chat.conversationActionLabel, systemImage: "rectangle.portrait.and.arrow.right")
                  }
                }
              }
            }

            if !appState.nextTelegramChatCursor.isEmpty {
              HStack(spacing: 10) {
                Spacer()
                ProgressView()
                Text("正在加载更多会话...")
                  .font(.caption)
                  .foregroundColor(TvTelegramPalette.textMuted)
                Spacer()
              }
              .padding(.vertical, 12)
              .onAppear {
                if !appState.isLoadingTelegram {
                  Task {
                    await appState.loadTelegramChats(
                      accountId: appState.activeTelegramAccountId,
                      folder: appState.selectedTelegramFolderKey,
                      loadMore: true
                    )
                  }
                }
              }
            }
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
        }
      }
    }
    .background(TvTelegramPalette.sidebarBg)
  }
}

/// 3. Official Telegram Main Conversation Pane (Top Header + Pinned Audio Bar + Grouped Message Stream + Compose Bar)
struct TvTelegramConversationPaneView: View {
  @EnvironmentObject var appState: TvAppState
  @Binding var composeText: String
  let onRequestLeaveOrDelete: (TvTelegramChat) -> Void
  let onOpenEmojiSheet: () -> Void
  let onRequestForward: ([TvTelegramMessage]) -> Void

  var body: some View {
    if let chat = appState.selectedTelegramChat {
      let videoCount = appState.cachedTelegramVideoCount
      let photoCount = appState.cachedTelegramPhotoCount
      let musicCount = appState.cachedTelegramMusicCount

      VStack(spacing: 0) {
        // 3a. Official Telegram Top Chat Header Bar
        HStack(spacing: 12) {
          Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
              appState.telegramSidebarCollapsed.toggle()
            }
          } label: {
            Image(systemName: appState.telegramSidebarCollapsed ? "sidebar.left" : "arrow.up.left.and.arrow.down.right")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))

          // Clickable Chat Profile Header -> Toggles Right Info & Shared Media Drawer
          Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
              appState.telegramShowRightInfoPanel.toggle()
            }
          } label: {
            HStack(spacing: 12) {
              TvTelegramPeerAvatar(
                peer: chat.peer,
                title: chat.title,
                avatarUrl: appState.resolvePeerAvatarUrl(for: chat),
                previewAvatar: chat.avatar,
                isSelf: chat.isSelf,
                size: 46,
                fontSize: 18
              )
              VStack(alignment: .leading, spacing: 2) {
                Text(chat.title)
                  .font(.system(size: 20, weight: .bold))
                  .foregroundColor(TvTelegramPalette.textPrimary)
                  .lineLimit(1)
                Text(
                  [
                    chat.kind.isEmpty ? (chat.broadcast ? "频道广播" : "会话") : chat.kind,
                    "\(appState.telegramMessages.count) 条消息",
                    videoCount > 0 ? "\(videoCount) 视频" : nil,
                    photoCount > 0 ? "\(photoCount) 图片" : nil,
                    musicCount > 0 ? "\(musicCount) 音频" : nil
                  ]
                  .compactMap { $0 }
                  .joined(separator: " · ")
                )
                .font(.system(size: 14))
                .foregroundColor(TvTelegramPalette.textSecondary)
                .lineLimit(1)
              }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
          }
          .buttonStyle(TvAppleSurfaceButtonStyle(isSelected: appState.telegramShowRightInfoPanel, cornerRadius: 14))

          Spacer()

          // Quick Media Type Filter Pills
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              mediaFilterPill(key: "all", label: "全部")
              mediaFilterPill(key: "video", label: videoCount > 0 ? "视频 (\(videoCount))" : "视频")
              mediaFilterPill(key: "photo", label: photoCount > 0 ? "图片 (\(photoCount))" : "图片")
              mediaFilterPill(key: "music", label: musicCount > 0 ? "音乐 (\(musicCount))" : "音乐")
              mediaFilterPill(key: "file", label: "文件")
            }
            .padding(.vertical, 4)
          }

          Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
              appState.telegramInChatSearchOpen.toggle()
              if !appState.telegramInChatSearchOpen {
                appState.telegramMessageKeyword = ""
              }
            }
          } label: {
            Image(systemName: "magnifyingglass")
          }
          .buttonStyle(TvApplePillButtonStyle(isSelected: appState.telegramInChatSearchOpen, compact: true))

          Button {
            appState.telegramSelectionMode.toggle()
            if !appState.telegramSelectionMode {
              appState.telegramSelectedMessageIds.removeAll()
            }
          } label: {
            Image(systemName: appState.telegramSelectionMode ? "checkmark.circle.fill" : "checklist")
          }
          .buttonStyle(TvApplePillButtonStyle(isSelected: appState.telegramSelectionMode, compact: true))

          Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
              appState.telegramShowRightInfoPanel.toggle()
            }
          } label: {
            Image(systemName: "sidebar.right")
          }
          .buttonStyle(TvApplePillButtonStyle(isSelected: appState.telegramShowRightInfoPanel, compact: true))

          Button {
            Task { await appState.selectTelegramChat(chat) }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))

          // Leave Channel / Leave Group / Delete Contact Action Button
          if !chat.conversationActionLabel.isEmpty {
            Button {
              onRequestLeaveOrDelete(chat)
            } label: {
              Label(
                chat.conversationActionLabel,
                systemImage: chat.conversationActionType == "delete_contact"
                  ? "person.badge.minus"
                  : "rectangle.portrait.and.arrow.right"
              )
            }
            .buttonStyle(TvApplePillButtonStyle(isDestructive: true, compact: true))
          }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(TvTelegramPalette.headerBg)
        .focusSection()

        Rectangle()
          .fill(TvTelegramPalette.borderLine)
          .frame(height: 1)

        // 3b. Pinned Top Audio / Music Player Bar
        if let audioMsg = appState.playingAudioMessage, let audioChat = appState.playingAudioChat {
          TvTelegramPinnedAudioPlayerBar(chat: audioChat, message: audioMsg)
            .focusSection()
        }

        // 3c. Expandable In-Chat Search Bar
        if appState.telegramInChatSearchOpen {
          HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
              .foregroundColor(TvTelegramPalette.textMuted)
            TextField("搜索当前会话中的消息文本、文件名或歌手...", text: $appState.telegramMessageKeyword)
            if !appState.telegramMessageKeyword.isEmpty {
              Text("匹配 \(appState.filteredTelegramMessages.count) 条")
                .font(.caption)
                .foregroundColor(TvTelegramPalette.textSecondary)
            }
            Button("关闭") {
              appState.telegramMessageKeyword = ""
              appState.telegramInChatSearchOpen = false
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
          }
          .padding(.horizontal, 22)
          .padding(.vertical, 10)
          .background(TvTelegramPalette.headerBg)
          .focusSection()

          Rectangle()
            .fill(TvTelegramPalette.borderLine)
            .frame(height: 1)
        }

        // 3d. Chronological Message Canvas with Album Mosaic Grids & Authentic Bubbles
        ZStack(alignment: .bottomTrailing) {
          TvTelegramWallpaperCanvas()

          if appState.isLoadingTelegram && appState.telegramMessages.isEmpty {
            VStack(spacing: 16) {
              ProgressView()
                .scaleEffect(1.4)
              Text("正在加载会话消息...")
                .foregroundColor(TvTelegramPalette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else if appState.groupedTelegramEntries.isEmpty {
            VStack {
              Text("暂无匹配的消息记录")
                .font(.callout)
                .foregroundColor(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(TvTelegramPalette.datePillBg)
                .clipShape(Capsule())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            ScrollViewReader { proxy in
              ScrollView {
                LazyVStack(spacing: 14) {
                  // Load Older Messages Pill at Top
                  if appState.nextTelegramMessageOffset > 0 {
                    HStack {
                      Spacer()
                      Button {
                        Task { await appState.loadOlderTelegramMessages() }
                      } label: {
                        HStack(spacing: 8) {
                          if appState.isLoadingTelegram {
                            ProgressView()
                          } else {
                            Image(systemName: "clock.arrow.circlepath")
                          }
                          Text(appState.isLoadingTelegram ? "正在加载更早历史消息..." : "加载更早历史消息")
                        }
                      }
                      .buttonStyle(TvApplePillButtonStyle(compact: true))
                      Spacer()
                    }
                    .padding(.vertical, 8)
                  }

                  ForEach(appState.groupedTelegramEntries) { group in
                    VStack(spacing: 12) {
                      if let dateHeader = group.datePillHeader {
                        Text(dateHeader)
                          .font(.system(size: 15, weight: .semibold))
                          .foregroundColor(.white)
                          .padding(.horizontal, 16)
                          .padding(.vertical, 6)
                          .background(TvTelegramPalette.datePillBg)
                          .clipShape(Capsule())
                          .padding(.vertical, 4)
                      }

                      if group.isAlbum {
                        TvTelegramAlbumBubbleView(
                          chat: chat,
                          albumMessages: group.messages,
                          onForward: { onRequestForward(group.messages) },
                          onCopyText: { copied in
                            if !chat.readOnly {
                              composeText = copied
                            }
                            appState.showToast(chat.readOnly ? "已复制相册说明文本" : "已复制文本并填入输入框")
                          }
                        )
                      } else if group.isDocGroup {
                        TvTelegramDocGroupBubbleView(
                          chat: chat,
                          groupMessages: group.messages,
                          onForward: { onRequestForward(group.messages) }
                        )
                      } else {
                        TvTelegramMessageBubbleView(
                          chat: chat,
                          message: group.first,
                          onForward: { onRequestForward([group.first]) },
                          onCopyText: { copied in
                            if !chat.readOnly {
                              composeText = copied
                            }
                            appState.showToast(chat.readOnly ? "已复制消息文本" : "已复制消息文本并填入输入框")
                          }
                        )
                      }
                    }
                    .id(group.id)
                  }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
              }
              .onAppear {
                if let lastId = appState.groupedTelegramEntries.last?.id {
                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    proxy.scrollTo(lastId, anchor: .bottom)
                  }
                }
              }
              .onChange(of: chat.peer) { _ in
                if let lastId = appState.groupedTelegramEntries.last?.id {
                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(.easeOut(duration: 0.25)) {
                      proxy.scrollTo(lastId, anchor: .bottom)
                    }
                  }
                }
              }
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusSection()

        Rectangle()
          .fill(TvTelegramPalette.borderLine)
          .frame(height: 1)

        // 3e. Official Telegram Bottom Compose Bar / Selection Toolbar / Broadcast Footer
        TvTelegramBottomComposeBar(
          chat: chat,
          composeText: $composeText,
          onOpenEmojiSheet: onOpenEmojiSheet,
          onRequestForwardSelected: {
            let selected = appState.telegramMessages.filter {
              appState.telegramSelectedMessageIds.contains($0.id)
            }
            onRequestForward(selected)
          }
        )
        .focusSection()
      }
    } else {
      VStack(spacing: 16) {
        Image(systemName: "paperplane.circle.fill")
          .font(.system(size: 76, weight: .light))
          .foregroundColor(TvTelegramPalette.tgBlueBright.opacity(0.65))
        Text("在左侧选择一个会话开始浏览")
          .font(.title3)
          .foregroundColor(TvTelegramPalette.textSecondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(TvTelegramPalette.chatWallpaperBg)
    }
  }

  private func mediaFilterPill(key: String, label: String) -> some View {
    let active = appState.telegramMediaFilter == key
    return Button(label) {
      appState.telegramMediaFilter = key
    }
    .buttonStyle(TvApplePillButtonStyle(isSelected: active, compact: true))
  }
}

/// Subtle Telegram Dark Pattern Wallpaper
struct TvTelegramWallpaperCanvas: View {
  var body: some View {
    ZStack {
      TvTelegramPalette.chatWallpaperBg
      LinearGradient(
        colors: [
          Color(red: 0.07, green: 0.11, blue: 0.17).opacity(0.55),
          TvTelegramPalette.chatWallpaperBg,
          Color(red: 0.05, green: 0.08, blue: 0.12)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    }
  }
}

/// Pinned Top Audio / Music Player Bar (Matches _buildTopPinnedAudioPlayerBar in telegram_screen.dart)
struct TvTelegramPinnedAudioPlayerBar: View {
  @EnvironmentObject var appState: TvAppState
  let chat: TvTelegramChat
  let message: TvTelegramMessage

  var body: some View {
    let att = message.attachment
    let title = att?.musicTitle ?? "音频播放"
    let subtitle = att?.musicPerformer ?? chat.title
    let ratio = appState.audioDuration > 0
      ? min(max(0, appState.audioPosition / appState.audioDuration), 1.0)
      : 0

    VStack(spacing: 0) {
      HStack(spacing: 14) {
        Button {
          appState.playAdjacentAudioTrack(delta: -1)
        } label: {
          Image(systemName: "backward.fill")
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))

        Button {
          appState.togglePlayAudioMessage(chat: chat, message: message)
        } label: {
          Image(systemName: appState.isAudioPlaying ? "pause.fill" : "play.fill")
        }
        .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))

        Button {
          appState.playAdjacentAudioTrack(delta: 1)
        } label: {
          Image(systemName: "forward.fill")
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(title)
              .font(.system(size: 18, weight: .semibold))
              .foregroundColor(TvTelegramPalette.textPrimary)
              .lineLimit(1)
            Text("— \(subtitle)")
              .font(.system(size: 16))
              .foregroundColor(TvTelegramPalette.textSecondary)
              .lineLimit(1)
          }
          Text("\(formatClock(Int(appState.audioPosition))) / \(formatClock(Int(appState.audioDuration)))")
            .font(.system(size: 14, design: .monospaced))
            .foregroundColor(TvTelegramPalette.textMuted)
        }

        Spacer()

        Button {
          appState.cycleAudioPlayMode()
        } label: {
          Image(
            systemName: appState.audioPlayMode == "repeatOne"
              ? "repeat.1"
              : (appState.audioPlayMode == "shuffle" ? "shuffle" : "repeat")
          )
        }
        .buttonStyle(TvApplePillButtonStyle(isSelected: appState.audioPlayMode != "sequential", compact: true))

        Button(String(format: "%.2gx", appState.audioSpeed)) {
          appState.cycleAudioSpeed()
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))

        Button {
          appState.stopAudioPlayer()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 8)

      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Rectangle()
            .fill(TvTelegramPalette.borderLine)
          Rectangle()
            .fill(TvTelegramPalette.tgBlueBright)
            .frame(width: geo.size.width * ratio)
        }
      }
      .frame(height: 3)
    }
    .background(TvTelegramPalette.headerBg)
  }

  private func formatClock(_ sec: Int) -> String {
    let m = max(0, sec) / 60
    let s = max(0, sec) % 60
    return String(format: "%02d:%02d", m, s)
  }
}

/// Official Telegram Album Mosaic Grid Bubble (for messages sharing `groupedId`)
struct TvTelegramAlbumBubbleView: View {
  @EnvironmentObject var appState: TvAppState
  let chat: TvTelegramChat
  let albumMessages: [TvTelegramMessage]
  let onForward: () -> Void
  var onCopyText: ((String) -> Void)? = nil

  var body: some View {
    let first = albumMessages[0]
    let isOutgoing = first.outgoing && !chat.broadcast
    let senderName = first.sender.isEmpty ? chat.title : first.sender
    let senderColor = TvTelegramPalette.peerNameColor(senderName)
    let captionMsg = albumMessages.first(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? first
    let cols = (albumMessages.count == 2 || albumMessages.count == 4) ? 2 : 3
    let videoCount = albumMessages.filter { $0.isVideo }.count
    let photoCount = albumMessages.count - videoCount
    let badgeText = (videoCount > 0 && photoCount > 0)
      ? "相册 \(albumMessages.count) 项 (\(photoCount)图 · \(videoCount)视频)"
      : (videoCount > 0 ? "视频合集 \(albumMessages.count) 项" : "相册 \(albumMessages.count) 项")

    let useChatPeer = chat.broadcast || chat.peer.hasPrefix("user:") || senderName == chat.title
    let resolvedPeer = !first.senderPeer.isEmpty ? first.senderPeer : (useChatPeer ? chat.peer : senderName)
    let resolvedAvatar = useChatPeer ? appState.resolvePeerAvatarUrl(for: chat) : first.senderAvatar
    let resolvedPreview = !first.senderAvatar.isEmpty ? first.senderAvatar : (useChatPeer ? chat.avatar : "")

    HStack(alignment: .bottom, spacing: 12) {
      if !isOutgoing {
        TvTelegramPeerAvatar(
          peer: resolvedPeer,
          title: senderName,
          avatarUrl: resolvedAvatar,
          previewAvatar: resolvedPreview,
          isSelf: chat.isSelf,
          size: 42,
          fontSize: 16
        )
      } else {
        Spacer(minLength: 120)
      }

      VStack(alignment: .leading, spacing: 10) {
        // Sender & Album Badge Row
        HStack {
          if !isOutgoing {
            Text(senderName)
              .font(.system(size: 16, weight: .semibold))
              .foregroundColor(senderColor)
              .lineLimit(1)
          }
          Spacer()
          Text(badgeText)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(TvTelegramPalette.tgBlueBright)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(TvTelegramPalette.tgBlueBright.opacity(0.16))
            .clipShape(Capsule())
        }

        // Mosaic Thumbnail Grid
        let gridCols = Array(repeating: GridItem(.flexible(), spacing: 8), count: cols)
        LazyVGrid(columns: gridCols, spacing: 8) {
          ForEach(albumMessages) { item in
            Button {
              appState.openTelegramGallery(chat: chat, message: item, albumMessages: albumMessages)
            } label: {
              ZStack(alignment: .bottomLeading) {
                TvRemoteImage(
                  rawUrl: appState.api.telegramThumbnailUrl(
                    accountId: appState.activeTelegramAccountId,
                    peer: chat.peer,
                    messageId: item.id
                  ),
                  placeholderIcon: item.isVideo ? "video.fill" : "photo",
                  contentMode: .fill
                )
                .frame(height: cols == 2 ? 210 : 155)
                .clipped()

                Color.black.opacity(0.18)

                if item.isVideo {
                  ZStack {
                    Circle()
                      .fill(.ultraThinMaterial)
                      .frame(width: 48, height: 48)
                    Image(systemName: "play.fill")
                      .font(.system(size: 20, weight: .bold))
                      .foregroundColor(.white)
                      .offset(x: 2)
                  }
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if let att = item.attachment, att.isVideo && att.duration > 0 {
                  Text(formatDuration(att.duration))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.68))
                    .clipShape(Capsule())
                    .padding(8)
                }
              }
              .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.card)
          }
        }

        // Shared Caption Text
        if !captionMsg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text(captionMsg.text)
            .font(.system(size: 18))
            .foregroundColor(TvTelegramPalette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        }

        // Album Bottom Action Bar
        HStack(spacing: 14) {
          Button {
            appState.openTelegramGallery(chat: chat, message: first, albumMessages: albumMessages)
          } label: {
            Label("全屏画廊浏览 (\(albumMessages.count))", systemImage: "photo.on.rectangle.angled")
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))

          Button {
            Task {
              await appState.batchQueueTelegramDownloads(chat: chat, messages: albumMessages)
            }
          } label: {
            Label("整组转存下载", systemImage: "icloud.and.arrow.down")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))

          if !captionMsg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button {
              onCopyText?(captionMsg.text)
            } label: {
              Label("复制文本", systemImage: "doc.on.doc")
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
          }

          Button(action: onForward) {
            Label("转发", systemImage: "arrowshape.turn.up.right")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))

          Spacer()

          Text(first.formattedBubbleTime)
            .font(.system(size: 14))
            .foregroundColor(TvTelegramPalette.textMuted)
        }
      }
      .padding(18)
      .frame(maxWidth: 820)
      .background(
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .fill(isOutgoing ? TvTelegramPalette.bubbleOut : TvTelegramPalette.bubbleIn)
      )

      if isOutgoing {
        EmptyView()
      } else {
        Spacer(minLength: 80)
      }
    }
  }

  private func formatDuration(_ sec: Int) -> String {
    let m = sec / 60
    let s = sec % 60
    return String(format: "%02d:%02d", m, s)
  }
}

/// Official Telegram Grouped Music / Document Bubble
struct TvTelegramDocGroupBubbleView: View {
  @EnvironmentObject var appState: TvAppState
  let chat: TvTelegramChat
  let groupMessages: [TvTelegramMessage]
  let onForward: () -> Void

  var body: some View {
    let first = groupMessages[0]
    let isOutgoing = first.outgoing && !chat.broadcast
    let senderName = first.sender.isEmpty ? chat.title : first.sender
    let senderColor = TvTelegramPalette.peerNameColor(senderName)
    let allAudio = groupMessages.allSatisfy { $0.isAudio }

    let useChatPeer = chat.broadcast || chat.peer.hasPrefix("user:") || senderName == chat.title
    let resolvedPeer = !first.senderPeer.isEmpty ? first.senderPeer : (useChatPeer ? chat.peer : senderName)
    let resolvedAvatar = useChatPeer ? appState.resolvePeerAvatarUrl(for: chat) : first.senderAvatar
    let resolvedPreview = !first.senderAvatar.isEmpty ? first.senderAvatar : (useChatPeer ? chat.avatar : "")

    HStack(alignment: .bottom, spacing: 12) {
      if !isOutgoing {
        TvTelegramPeerAvatar(
          peer: resolvedPeer,
          title: senderName,
          avatarUrl: resolvedAvatar,
          previewAvatar: resolvedPreview,
          isSelf: chat.isSelf,
          size: 42,
          fontSize: 16
        )
      } else {
        Spacer(minLength: 120)
      }

      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text(senderName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(senderColor)
          Spacer()
          Text(allAudio ? "音频合集 (\(groupMessages.count) 首)" : "文件组 (\(groupMessages.count) 项)")
            .font(.system(size: 13))
            .foregroundColor(TvTelegramPalette.textMuted)
        }

        ForEach(groupMessages) { m in
          if let att = m.attachment {
            TvTelegramAttachmentCardView(chat: chat, message: m, attachment: att)
          }
        }

        HStack(spacing: 12) {
          if allAudio {
            Button {
              appState.togglePlayAudioMessage(chat: chat, message: first, forceRestart: true)
            } label: {
              Label("连播全部 (\(groupMessages.count))", systemImage: "play.circle.fill")
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
          }

          Button(action: onForward) {
            Label("转发", systemImage: "arrowshape.turn.up.right")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))

          Spacer()

          Text(first.formattedBubbleTime)
            .font(.system(size: 14))
            .foregroundColor(TvTelegramPalette.textMuted)
        }
      }
      .padding(18)
      .frame(maxWidth: 740)
      .background(
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .fill(isOutgoing ? TvTelegramPalette.bubbleOut : TvTelegramPalette.bubbleIn)
      )

      if !isOutgoing {
        Spacer(minLength: 80)
      }
    }
  }
}

/// Official Telegram Single Message Bubble (Left Incoming / Right Outgoing + Reply Quote + Rich Media + Bot Buttons)
struct TvTelegramMessageBubbleView: View {
  @EnvironmentObject var appState: TvAppState
  let chat: TvTelegramChat
  let message: TvTelegramMessage
  let onForward: () -> Void
  var onCopyText: ((String) -> Void)? = nil

  var body: some View {
    let isOutgoing = message.outgoing && !chat.broadcast
    let isSelected = appState.telegramSelectedMessageIds.contains(message.id)
    let senderName = message.sender.isEmpty ? chat.title : message.sender
    let senderColor = TvTelegramPalette.peerNameColor(senderName)

    let useChatPeer = chat.broadcast || chat.peer.hasPrefix("user:") || senderName == chat.title
    let resolvedPeer = !message.senderPeer.isEmpty ? message.senderPeer : (useChatPeer ? chat.peer : senderName)
    let resolvedAvatar = useChatPeer ? appState.resolvePeerAvatarUrl(for: chat) : message.senderAvatar
    let resolvedPreview = !message.senderAvatar.isEmpty ? message.senderAvatar : (useChatPeer ? chat.avatar : "")

    HStack(alignment: .bottom, spacing: 12) {
      if !isOutgoing {
        TvTelegramPeerAvatar(
          peer: resolvedPeer,
          title: senderName,
          avatarUrl: resolvedAvatar,
          previewAvatar: resolvedPreview,
          isSelf: chat.isSelf,
          size: 42,
          fontSize: 16
        )
      } else {
        Spacer(minLength: 140)
      }

      VStack(alignment: .leading, spacing: 10) {
        // Sender Name Header
        if !isOutgoing {
          HStack(spacing: 8) {
            Text(senderName)
              .font(.system(size: 16, weight: .semibold))
              .foregroundColor(senderColor)
              .lineLimit(1)
            if chat.broadcast {
              Text("频道")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(TvTelegramPalette.textMuted)
            }
          }
        }

        // Reply Quote Banner (when replying to an earlier message)
        if message.replyToId > 0 {
          let quoted = appState.findMessage(byId: message.replyToId)
          HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
              .fill(TvTelegramPalette.tgBlueBright)
              .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 2) {
              Text(quoted?.sender.isEmpty == false ? quoted!.sender : "引用回复 #\(message.replyToId)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(TvTelegramPalette.tgBlueBright)
                .lineLimit(1)
              Text(quoted?.text.isEmpty == false ? quoted!.text : (quoted?.attachment?.displayName ?? "原消息"))
                .font(.system(size: 14))
                .foregroundColor(TvTelegramPalette.textSecondary)
                .lineLimit(1)
            }
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(TvTelegramPalette.tgBlueBright.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }

        // Media Attachment Card (Video / Photo / Music / Voice / Document)
        if let att = message.attachment {
          TvTelegramAttachmentCardView(chat: chat, message: message, attachment: att)
        }

        // Message Text
        if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text(message.text)
            .font(.system(size: 19))
            .foregroundColor(TvTelegramPalette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        }

        // Inline Bot Keyboard Buttons
        if !message.buttons.isEmpty {
          VStack(spacing: 8) {
            ForEach(Array(message.buttons.enumerated()), id: \.offset) { _, row in
              HStack(spacing: 10) {
                ForEach(row) { btn in
                  Button(btn.text) {
                    Task {
                      let notice = await appState.api.pressTelegramButton(
                        accountId: appState.activeTelegramAccountId,
                        peer: chat.peer,
                        messageId: message.id,
                        button: btn
                      )
                      if !notice.isEmpty {
                        appState.showToast(notice)
                      }
                      await appState.selectTelegramChat(chat)
                    }
                  }
                  .buttonStyle(TvApplePillButtonStyle(compact: true))
                }
              }
            }
          }
        }

        // Bubble Footer: Quick Actions + Timestamp + Outgoing Read Receipt
        HStack(spacing: 12) {
          if appState.telegramSelectionMode {
            Button {
              if isSelected {
                appState.telegramSelectedMessageIds.remove(message.id)
              } else {
                appState.telegramSelectedMessageIds.insert(message.id)
              }
            } label: {
              Label(isSelected ? "已勾选" : "勾选此条", systemImage: isSelected ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(TvApplePillButtonStyle(isSelected: isSelected, compact: true))
          } else {
            if !chat.readOnly {
              Button {
                appState.telegramReplyingTo = message
              } label: {
                Label("回复", systemImage: "arrowshape.turn.up.left")
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))
            }

            if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              Button {
                onCopyText?(message.text)
              } label: {
                Label("复制", systemImage: "doc.on.doc")
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))
            }

            Button(action: onForward) {
              Label("转发", systemImage: "arrowshape.turn.up.right")
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
          }

          Spacer()

          Text(message.formattedBubbleTime)
            .font(.system(size: 14))
            .foregroundColor(isOutgoing ? Color(red: 0.58, green: 0.78, blue: 0.96) : TvTelegramPalette.textMuted)

          if isOutgoing {
            let isRead = appState.isOutgoingMessageRead(chat: chat, message: message)
            Text(isRead ? "✓✓" : "✓")
              .font(.system(size: 14, weight: .bold))
              .foregroundColor(Color(red: 0.42, green: 0.85, blue: 0.98))
          }
        }
      }
      .padding(18)
      .frame(maxWidth: 780, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .fill(
            isSelected
              ? TvTelegramPalette.bubbleSelected
              : (isOutgoing ? TvTelegramPalette.bubbleOut : TvTelegramPalette.bubbleIn)
          )
      )
      .overlay(
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .stroke(isSelected ? TvTelegramPalette.tgBlueBright : Color.white.opacity(0.06), lineWidth: isSelected ? 2 : 1)
      )

      if !isOutgoing {
        Spacer(minLength: 80)
      }
    }
  }
}

/// Rich Attachment Card inside a Telegram Bubble (16:9 Video, High-Res Photo, Music/Voice Player, or Document)
struct TvTelegramAttachmentCardView: View {
  @EnvironmentObject var appState: TvAppState
  let chat: TvTelegramChat
  let message: TvTelegramMessage
  let attachment: TvTelegramAttachment

  var body: some View {
    if attachment.isVisualMedia {
      VStack(alignment: .leading, spacing: 10) {
        Button {
          appState.openTelegramGallery(chat: chat, message: message)
        } label: {
          ZStack(alignment: .topLeading) {
            TvRemoteImage(
              rawUrl: appState.api.telegramThumbnailUrl(
                accountId: appState.activeTelegramAccountId,
                peer: chat.peer,
                messageId: message.id
              ),
              placeholderIcon: attachment.isVideo ? "play.rectangle.fill" : "photo",
              contentMode: .fill
            )
            .frame(width: 520, height: 292)
            .clipped()

            Color.black.opacity(0.18)

            // Centered Frosted Glass Play Icon for Video
            if attachment.isVideo {
              ZStack {
                Circle()
                  .fill(.ultraThinMaterial)
                  .frame(width: 68, height: 68)
                Image(systemName: "play.fill")
                  .font(.system(size: 28, weight: .bold))
                  .foregroundColor(.white)
                  .offset(x: 2)
              }
              .frame(width: 520, height: 292)
            }

            // Top-Left Duration & Size Pill Badge
            HStack(spacing: 6) {
              Image(systemName: attachment.isVideo ? "video.fill" : "photo.fill")
                .font(.caption2)
              if attachment.duration > 0 {
                Text(formatDuration(attachment.duration))
                  .font(.system(size: 14, weight: .bold, design: .monospaced))
              }
              if !attachment.formattedSize.isEmpty {
                Text("· \(attachment.formattedSize)")
                  .font(.system(size: 13, weight: .medium))
              }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.70))
            .clipShape(Capsule())
            .padding(12)
          }
          .frame(width: 520, height: 292)
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.card)

        // Action Strip under Video/Photo
        HStack(spacing: 12) {
          Button {
            appState.openTelegramGallery(chat: chat, message: message)
          } label: {
            Label(attachment.isVideo ? "全屏画廊播放" : "全屏查看图片", systemImage: attachment.isVideo ? "play.fill" : "arrow.up.left.and.arrow.down.right")
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))

          if attachment.isVideo {
            Button {
              appState.openTelegramMiniPlayer(chat: chat, message: message)
            } label: {
              Label("小窗播放", systemImage: "pip.enter")
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
          }

          Button {
            Task { _ = await appState.queueTelegramDownload(chat: chat, message: message) }
          } label: {
            Label("转存下载", systemImage: "icloud.and.arrow.down")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))
        }
      }
    } else if attachment.isAudio {
      let isPlayingThis = appState.playingAudioMessage?.id == message.id && appState.playingAudioChat?.peer == chat.peer && appState.isAudioPlaying
      HStack(spacing: 14) {
        Button {
          appState.togglePlayAudioMessage(chat: chat, message: message)
        } label: {
          Image(systemName: isPlayingThis ? "pause.fill" : "play.fill")
            .font(.system(size: 22, weight: .bold))
        }
        .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))

        VStack(alignment: .leading, spacing: 4) {
          Text(attachment.musicTitle)
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(TvTelegramPalette.textPrimary)
            .lineLimit(1)
          Text(
            [
              attachment.musicPerformer,
              attachment.duration > 0 ? formatDuration(attachment.duration) : nil,
              attachment.formattedSize.isEmpty ? nil : attachment.formattedSize
            ]
            .compactMap { $0 }
            .joined(separator: " · ")
          )
          .font(.system(size: 14))
          .foregroundColor(TvTelegramPalette.textSecondary)
          .lineLimit(1)
        }

        Spacer()

        Button {
          Task { _ = await appState.queueTelegramDownload(chat: chat, message: message) }
        } label: {
          Image(systemName: "icloud.and.arrow.down")
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))
      }
      .padding(14)
      .background(Color.white.opacity(0.06))
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    } else {
      // Document / File Card
      HStack(spacing: 14) {
        ZStack {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(TvTelegramPalette.tgBlueBright.opacity(0.22))
            .frame(width: 52, height: 52)
          Image(systemName: "doc.text.fill")
            .font(.system(size: 24))
            .foregroundColor(TvTelegramPalette.tgBlueBright)
        }

        VStack(alignment: .leading, spacing: 4) {
          Text(attachment.displayName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(TvTelegramPalette.textPrimary)
            .lineLimit(1)
          Text("\(attachment.formattedSize) · \(attachment.mimeType.isEmpty ? "文件" : attachment.mimeType)")
            .font(.system(size: 14))
            .foregroundColor(TvTelegramPalette.textSecondary)
            .lineLimit(1)
        }

        Spacer()

        if attachment.canPreviewText {
          Button {
            Task { await appState.openTelegramFilePreview(chat: chat, message: message) }
          } label: {
            Label("预览内容", systemImage: "doc.text.magnifyingglass")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))
        }

        Button {
          Task { _ = await appState.queueTelegramDownload(chat: chat, message: message) }
        } label: {
          Label("转存下载", systemImage: "icloud.and.arrow.down")
        }
        .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
      }
      .padding(14)
      .background(Color.white.opacity(0.06))
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
  }

  private func formatDuration(_ sec: Int) -> String {
    let h = sec / 3600
    let m = (sec % 3600) / 60
    let s = sec % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%02d:%02d", m, s)
  }
}

/// Official Telegram Bottom Compose Bar / Selection Toolbar / Broadcast Channel Footer
struct TvTelegramBottomComposeBar: View {
  @EnvironmentObject var appState: TvAppState
  let chat: TvTelegramChat
  @Binding var composeText: String
  let onOpenEmojiSheet: () -> Void
  let onRequestForwardSelected: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      // Reply Preview Banner
      if let replyMsg = appState.telegramReplyingTo {
        HStack(spacing: 12) {
          Image(systemName: "arrowshape.turn.up.left.fill")
            .foregroundColor(TvTelegramPalette.tgBlueBright)
          VStack(alignment: .leading, spacing: 2) {
            Text("回复 \(replyMsg.sender.isEmpty ? chat.title : replyMsg.sender)")
              .font(.system(size: 15, weight: .semibold))
              .foregroundColor(TvTelegramPalette.tgBlueBright)
            Text(replyMsg.text.isEmpty ? (replyMsg.attachment?.displayName ?? "媒体消息") : replyMsg.text)
              .font(.system(size: 14))
              .foregroundColor(TvTelegramPalette.textSecondary)
              .lineLimit(1)
          }
          Spacer()
          Button {
            appState.telegramReplyingTo = nil
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(TvTelegramPalette.headerBg)

        Rectangle()
          .fill(TvTelegramPalette.borderLine)
          .frame(height: 1)
      }

      if appState.telegramSelectionMode {
        // Multi-Select Batch Action Toolbar
        let count = appState.telegramSelectedMessageIds.count
        HStack(spacing: 16) {
          Text("已选择 \(count) 条消息")
            .font(.system(size: 19, weight: .bold))
            .foregroundColor(TvTelegramPalette.textPrimary)

          Spacer()

          Button {
            let selected = appState.telegramMessages.filter {
              appState.telegramSelectedMessageIds.contains($0.id)
            }
            Task {
              await appState.batchQueueTelegramDownloads(chat: chat, messages: selected)
            }
          } label: {
            Label("批量转存下载", systemImage: "icloud.and.arrow.down")
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
          .disabled(count == 0)

          Button(action: onRequestForwardSelected) {
            Label("批量转发", systemImage: "arrowshape.turn.up.right")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))
          .disabled(count == 0)

          Button {
            Task { await appState.deleteSelectedTelegramMessages(chat: chat) }
          } label: {
            Label("删除所选", systemImage: "trash")
          }
          .buttonStyle(TvApplePillButtonStyle(isDestructive: true, compact: true))
          .disabled(count == 0)

          Button("取消多选") {
            appState.telegramSelectionMode = false
            appState.telegramSelectedMessageIds.removeAll()
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(TvTelegramPalette.composeBg)
      } else if chat.readOnly {
        // Official Telegram Read-Only Broadcast Channel Footer
        HStack(spacing: 16) {
          Image(systemName: "megaphone.fill")
            .foregroundColor(TvTelegramPalette.tgBlueBright)
          Text("频道广播会话（只读）")
            .font(.system(size: 18, weight: .medium))
            .foregroundColor(TvTelegramPalette.textSecondary)

          Spacer()

          if let firstMedia = appState.telegramMessages.last(where: { $0.isVisualMedia }) {
            Button {
              appState.openTelegramGallery(chat: chat, message: firstMedia)
            } label: {
              Label("打开频道全屏视频画廊", systemImage: "play.rectangle.on.rectangle.fill")
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
          }

          Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
              appState.telegramShowRightInfoPanel.toggle()
            }
          } label: {
            Label(appState.telegramShowRightInfoPanel ? "收起共享媒体墙" : "展开共享媒体墙", systemImage: "square.grid.2x2")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(TvTelegramPalette.composeBg)
      } else {
        // Writable Chat Compose Bar
        HStack(spacing: 14) {
          Button(action: onOpenEmojiSheet) {
            Label("表情与快捷语", systemImage: "face.smiling")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))

          TextField("输入消息内容...", text: $composeText)
            .onChange(of: composeText) { newVal in
              appState.telegramDrafts[appState.draftKey(for: chat)] = newVal
            }

          Button {
            let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            composeText = ""
            Task { await appState.sendTelegramMessage(text: text) }
          } label: {
            Label("发送", systemImage: "paperplane.fill")
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
          .disabled(composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(TvTelegramPalette.composeBg)
      }
    }
  }
}

/// 4. Right Chat Info & Shared Media Drawer (Matches _buildRightChatInfoPanel in telegram_screen.dart)
struct TvTelegramRightInfoDrawerView: View {
  @EnvironmentObject var appState: TvAppState
  let chat: TvTelegramChat
  let onRequestLeaveOrDelete: () -> Void

  private let mediaGridCols = [
    GridItem(.flexible(), spacing: 10),
    GridItem(.flexible(), spacing: 10)
  ]

  var body: some View {
    let isMuted = appState.isPeerMuted(chat)
    let visualItems = appState.telegramMessages.filter {
      if appState.telegramRightPanelTab == "photo" { return $0.isPhoto }
      return $0.isVideo
    }
    let audioItems = appState.telegramMessages.filter { $0.isAudio }
    let fileItems = appState.telegramMessages.filter { $0.attachment != nil && !$0.isVisualMedia && !$0.isAudio }

    VStack(spacing: 16) {
      // Top Header
      HStack {
        Text("会话信息与共享媒体")
          .font(.system(size: 20, weight: .bold))
          .foregroundColor(TvTelegramPalette.textPrimary)
        Spacer()
        Button {
          appState.telegramShowRightInfoPanel = false
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))
      }
      .padding(.horizontal, 20)
      .padding(.top, 16)

      // Profile Summary Card
      VStack(spacing: 10) {
        TvTelegramPeerAvatar(
          peer: chat.peer,
          title: chat.title,
          avatarUrl: appState.resolvePeerAvatarUrl(for: chat),
          previewAvatar: chat.avatar,
          isSelf: chat.isSelf,
          size: 84,
          fontSize: 32
        )
        Text(chat.title)
          .font(.system(size: 22, weight: .bold))
          .foregroundColor(TvTelegramPalette.textPrimary)
          .lineLimit(1)
        Text("\(chat.peer) · \(chat.kind.isEmpty ? (chat.broadcast ? "频道" : "会话") : chat.kind)")
          .font(.system(size: 14))
          .foregroundColor(TvTelegramPalette.textSecondary)
          .lineLimit(1)

        HStack(spacing: 12) {
          Button {
            appState.togglePeerMute(chat)
          } label: {
            Label(isMuted ? "取消静音" : "静音通知", systemImage: isMuted ? "bell.fill" : "bell.slash.fill")
          }
          .buttonStyle(TvApplePillButtonStyle(isSelected: isMuted, compact: true))

          if !chat.conversationActionLabel.isEmpty {
            Button(action: onRequestLeaveOrDelete) {
              Label(chat.conversationActionLabel, systemImage: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(TvApplePillButtonStyle(isDestructive: true, compact: true))
          }
        }
        .padding(.top, 4)
      }
      .padding(.horizontal, 16)

      // Shared Media Tabs
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          drawerTabButton("video", "视频")
          drawerTabButton("photo", "图片")
          drawerTabButton("music", "音乐")
          drawerTabButton("file", "文件")
        }
        .padding(.horizontal, 16)
      }

      Rectangle()
        .fill(TvTelegramPalette.borderLine)
        .frame(height: 1)

      // Shared Media Content
      ScrollView {
        if appState.telegramRightPanelTab == "video" || appState.telegramRightPanelTab == "photo" {
          if visualItems.isEmpty {
            Text("当前暂无\(appState.telegramRightPanelTab == "photo" ? "图片" : "视频")记录")
              .foregroundColor(TvTelegramPalette.textMuted)
              .padding(.top, 40)
          } else {
            LazyVGrid(columns: mediaGridCols, spacing: 10) {
              ForEach(visualItems) { item in
                Button {
                  appState.openTelegramGallery(chat: chat, message: item)
                } label: {
                  ZStack(alignment: .bottomLeading) {
                    TvRemoteImage(
                      rawUrl: appState.api.telegramThumbnailUrl(
                        accountId: appState.activeTelegramAccountId,
                        peer: chat.peer,
                        messageId: item.id
                      ),
                      placeholderIcon: item.isVideo ? "video.fill" : "photo",
                      contentMode: .fill
                    )
                    .frame(height: 112)
                    .clipped()

                    if let dur = item.attachment?.duration, dur > 0 {
                      Text(String(format: "%02d:%02d", dur / 60, dur % 60))
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.72))
                        .clipShape(Capsule())
                        .padding(6)
                    }
                  }
                  .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.card)
              }
            }
            .padding(14)
          }
        } else if appState.telegramRightPanelTab == "music" {
          LazyVStack(spacing: 8) {
            ForEach(audioItems) { item in
              Button {
                appState.togglePlayAudioMessage(chat: chat, message: item)
              } label: {
                HStack {
                  Image(systemName: "music.note")
                    .foregroundColor(TvTelegramPalette.tgBlueBright)
                  Text(item.attachment?.musicTitle ?? "音频")
                    .lineLimit(1)
                  Spacer()
                }
                .padding(12)
              }
              .buttonStyle(TvAppleSurfaceButtonStyle(cornerRadius: 12))
            }
          }
          .padding(14)
        } else {
          LazyVStack(spacing: 8) {
            ForEach(fileItems) { item in
              Button {
                Task { _ = await appState.queueTelegramDownload(chat: chat, message: item) }
              } label: {
                HStack {
                  Image(systemName: "doc.fill")
                    .foregroundColor(TvTelegramPalette.tgBlueBright)
                  Text(item.attachment?.displayName ?? "文件")
                    .lineLimit(1)
                  Spacer()
                  Text(item.attachment?.formattedSize ?? "")
                    .font(.caption2)
                    .foregroundColor(TvTelegramPalette.textMuted)
                }
                .padding(12)
              }
              .buttonStyle(TvAppleSurfaceButtonStyle(cornerRadius: 12))
            }
          }
          .padding(14)
        }
      }
    }
    .background(TvTelegramPalette.sidebarBg)
  }

  private func drawerTabButton(_ key: String, _ title: String) -> some View {
    Button(title) {
      appState.telegramRightPanelTab = key
    }
    .buttonStyle(TvApplePillButtonStyle(isSelected: appState.telegramRightPanelTab == key, compact: true))
  }
}

/// 5. Floating Telegram Mini-Player PIP Overlay
struct TvTelegramMiniPlayerOverlay: View {
  @EnvironmentObject var appState: TvAppState
  let chat: TvTelegramChat
  let message: TvTelegramMessage
  @State private var miniPlayer: AVPlayer = AVPlayer()
  @State private var isMiniPlaying: Bool = true
  @State private var miniStallObserver: NSObjectProtocol? = nil
  @State private var miniEndObserver: NSObjectProtocol? = nil
  private let miniWatchdog = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(spacing: 10) {
      Button {
        miniPlayer.pause()
        appState.closeTelegramMiniPlayer()
        appState.openTelegramGallery(chat: chat, message: message)
      } label: {
        ZStack(alignment: .bottomLeading) {
          Color.black
          TvRawAVPlayerLayerView(player: miniPlayer, videoGravity: .resizeAspect)
          VStack {
            HStack {
              Spacer()
              TvVideoDownloadSpeedBadge(player: miniPlayer, compact: true)
            }
            Spacer()
          }
          .padding(10)
          Text("点击返回全屏播放")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.65))
            .clipShape(Capsule())
            .padding(10)
        }
        .frame(width: 420, height: 236)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      }
      .buttonStyle(.card)

      HStack(spacing: 10) {
        Text(message.attachment?.displayName ?? chat.title)
          .font(.caption.bold())
          .foregroundColor(.white)
          .lineLimit(1)
          .frame(maxWidth: 160, alignment: .leading)

        Spacer()

        Button {
          if isMiniPlaying {
            miniPlayer.pause()
            isMiniPlaying = false
          } else {
            miniPlayer.play()
            isMiniPlaying = true
          }
        } label: {
          Image(systemName: isMiniPlaying ? "pause.fill" : "play.fill")
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))

        Button {
          miniPlayer.pause()
          appState.closeTelegramMiniPlayer()
          appState.openTelegramGallery(chat: chat, message: message)
        } label: {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))

        Button {
          miniPlayer.pause()
          appState.closeTelegramMiniPlayer()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(TvApplePillButtonStyle(isDestructive: true, compact: true))
      }
      .focusSection()
    }
    .padding(14)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(Color.white.opacity(0.22), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.6), radius: 24, y: 12)
    .focusSection()
    .onAppear {
      startMiniStream()
    }
    .onChange(of: message.id) { _ in
      startMiniStream()
    }
    .onReceive(miniWatchdog) { _ in
      guard !appState.isAppInBackground, isMiniPlaying else { return }
      if miniPlayer.timeControlStatus != .playing && miniPlayer.rate == 0 {
        miniPlayer.play()
      }
    }
    .onDisappear {
      if let tok = miniStallObserver {
        NotificationCenter.default.removeObserver(tok)
        miniStallObserver = nil
      }
      if let tok = miniEndObserver {
        NotificationCenter.default.removeObserver(tok)
        miniEndObserver = nil
      }
      miniPlayer.pause()
      miniPlayer.replaceCurrentItem(with: nil)
    }
  }

  private func startMiniStream(resumeAt: Double = 0) {
    if let tok = miniStallObserver {
      NotificationCenter.default.removeObserver(tok)
      miniStallObserver = nil
    }
    if let tok = miniEndObserver {
      NotificationCenter.default.removeObserver(tok)
      miniEndObserver = nil
    }
    let urlStr = appState.api.telegramAcceleratedVideoUrl(
      accountId: appState.activeTelegramAccountId,
      peer: chat.peer,
      messageId: message.id
    )
    guard let url = URL(string: urlStr) else { return }
    let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": appState.api.authHeaders])
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = 30
    miniPlayer.replaceCurrentItem(with: item)
    miniPlayer.automaticallyWaitsToMinimizeStalling = true
    if resumeAt > 0.8 {
      let target = CMTime(seconds: resumeAt, preferredTimescale: 600)
      miniPlayer.seek(to: target) { [weak miniPlayer] _ in
        if self.isMiniPlaying {
          miniPlayer?.play()
        }
      }
    } else if isMiniPlaying {
      miniPlayer.play()
    }

    miniStallObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemPlaybackStalled,
      object: item,
      queue: .main
    ) { _ in
      if self.isMiniPlaying {
        self.miniPlayer.play()
      }
    }

    miniEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { _ in
      let curSec = CMTimeGetSeconds(self.miniPlayer.currentTime())
      let durSec = Double(self.message.attachment?.duration ?? 0)
      if durSec > 6 && curSec.isFinite && curSec > 1 && curSec < durSec - 4 {
        self.startMiniStream(resumeAt: curSec)
      } else {
        self.miniPlayer.seek(to: .zero) { [weak miniPlayer] _ in
          if self.isMiniPlaying {
            miniPlayer?.play()
          }
        }
      }
    }
  }
}

/// Unauthorized Telegram Placeholder Card (Matches _buildUnauthorizedPlaceholder in telegram_screen.dart)
struct TvTelegramUnauthorizedPlaceholder: View {
  @EnvironmentObject var appState: TvAppState
  let onOpenSettings: () -> Void

  var body: some View {
    VStack(spacing: 24) {
      ZStack {
        Circle()
          .fill(
            LinearGradient(
              colors: [Color(red: 0.26, green: 0.68, blue: 0.91), Color(red: 0.13, green: 0.53, blue: 0.80)],
              startPoint: .topTrailing,
              endPoint: .bottomLeading
            )
          )
          .frame(width: 96, height: 96)
        Image(systemName: "paperplane.fill")
          .font(.system(size: 44, weight: .bold))
          .foregroundColor(.white)
      }

      Text(appState.telegramAuthStatus.configured ? "登录您的 Telegram 账号" : "连接 Telegram 会话")
        .font(.system(size: 32, weight: .bold))
        .foregroundColor(TvTelegramPalette.textPrimary)

      Text("配置 API ID / API Hash 并完成验证码登录后，即可像官方客户端一样浏览所有频道与群组、在线流式播放视频或一键转存至服务器。")
        .font(.system(size: 19))
        .foregroundColor(TvTelegramPalette.textSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 680)

      Button(action: onOpenSettings) {
        Label("打开 Telegram 登录与账号配置", systemImage: "person.badge.key.fill")
      }
      .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
    }
    .padding(48)
    .background(TvTelegramPalette.sidebarBg)
    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Emoji, Kaomoji & Quick Reply Picker Sheet for Apple TV Remote
struct TvTelegramEmojiAndQuickReplySheet: View {
  @EnvironmentObject var appState: TvAppState
  @Environment(\.dismiss) private var dismiss
  let onInsertText: (String) -> Void
  let onSendImmediate: (String) -> Void
  @State private var selectedCategoryIdx: Int = 0

  var body: some View {
    let cat = kTvTelegramEmojiCategories[selectedCategoryIdx]

    ZStack {
      TvTelegramPalette.sidebarBg.ignoresSafeArea()

      VStack(alignment: .leading, spacing: 24) {
        HStack {
          Text("表情、颜文字与快捷回复")
            .font(.title2.bold())
          Spacer()
          ForEach(Array(kTvTelegramEmojiCategories.enumerated()), id: \.offset) { idx, c in
            Button("\(c.icon) \(c.title)") {
              selectedCategoryIdx = idx
            }
            .buttonStyle(TvApplePillButtonStyle(isSelected: selectedCategoryIdx == idx, compact: true))
          }
          Button("关闭") { dismiss() }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
        }

        ScrollView {
          if cat.isTextPhrase {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 420), spacing: 18)], spacing: 18) {
              ForEach(cat.items, id: \.self) { phrase in
                HStack(spacing: 10) {
                  Button(phrase) {
                    onInsertText(phrase)
                    dismiss()
                  }
                  .buttonStyle(TvAppleSurfaceButtonStyle(cornerRadius: 14))

                  Button {
                    onSendImmediate(phrase)
                    dismiss()
                  } label: {
                    Image(systemName: "paperplane.fill")
                  }
                  .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
                }
              }
            }
          } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 16)], spacing: 16) {
              ForEach(cat.items, id: \.self) { emoji in
                Button {
                  onInsertText(emoji)
                } label: {
                  Text(emoji)
                    .font(.system(size: 40))
                    .frame(width: 88, height: 76)
                }
                .buttonStyle(TvAppleSurfaceButtonStyle(cornerRadius: 16))
              }
            }
          }
        }
      }
      .padding(48)
    }
  }
}

/// Forward Messages Target Chat Picker Sheet
struct TvTelegramForwardTargetSheet: View {
  @EnvironmentObject var appState: TvAppState
  @Binding var isPresented: Bool
  let messagesToForward: [TvTelegramMessage]

  var body: some View {
    let writableChats = appState.telegramChats.filter { !$0.readOnly }

    ZStack {
      TvTelegramPalette.sidebarBg.ignoresSafeArea()

      VStack(alignment: .leading, spacing: 24) {
        HStack {
          Text("转发 \(messagesToForward.count) 条消息至...")
            .font(.title2.bold())
          Spacer()
          Button("取消") { isPresented = false }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
        }

        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 380, maximum: 460), spacing: 18)], spacing: 18) {
            ForEach(writableChats) { target in
              Button {
                isPresented = false
                Task {
                  await appState.forwardTelegramMessages(messagesToForward, to: target)
                }
              } label: {
                HStack(spacing: 14) {
                  TvTelegramPeerAvatar(
                    peer: target.peer,
                    title: target.title,
                    avatarUrl: appState.resolvePeerAvatarUrl(for: target),
                    previewAvatar: target.avatar,
                    isSelf: target.isSelf,
                    size: 46,
                    fontSize: 18
                  )
                  Text(target.title)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)
                  Spacer()
                  Image(systemName: "paperplane.fill")
                    .foregroundColor(TvTelegramPalette.tgBlueBright)
                }
                .padding(14)
              }
              .buttonStyle(TvAppleSurfaceButtonStyle(cornerRadius: 16))
            }
          }
        }
      }
      .padding(48)
    }
  }
}

/// Inline File Text/Code Preview Sheet (/api/telegram/file-preview)
struct TvTelegramFilePreviewSheet: View {
  @EnvironmentObject var appState: TvAppState
  @Environment(\.dismiss) private var dismiss
  let preview: TvTelegramFilePreview

  var body: some View {
    ZStack {
      TvTelegramPalette.sidebarBg.ignoresSafeArea()

      VStack(alignment: .leading, spacing: 20) {
        HStack {
          Label(preview.title, systemImage: "doc.text.fill")
            .font(.title3.bold())
          Spacer()
          Button("关闭") { dismiss() }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
        }

        ScrollView {
          Text(preview.content.isEmpty ? "（文件内容为空）" : preview.content)
            .font(.system(size: 18, design: .monospaced))
            .foregroundColor(TvTelegramPalette.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(TvTelegramPalette.chatWallpaperBg)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
      }
      .padding(48)
    }
  }
}

/// Telegram Account & API Login Configuration Sheet
struct TvTelegramAccountConfigSheet: View {
  @EnvironmentObject var appState: TvAppState
  @Binding var isPresented: Bool

  @State private var tgApiId: String = ""
  @State private var tgApiHash: String = ""
  @State private var tgPhone: String = ""
  @State private var tgCode: String = ""
  @State private var tgPassword: String = ""
  @State private var newAccountName: String = ""

  var body: some View {
    ZStack {
      TvTelegramPalette.sidebarBg.ignoresSafeArea()

      ScrollView {
        VStack(alignment: .leading, spacing: 26) {
          HStack {
            Label("Telegram 账号管理与 API 登录", systemImage: "paperplane.circle.fill")
              .font(.title2.bold())
            Spacer()
            Button("完成") { isPresented = false }
              .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
          }

          HStack(spacing: 14) {
            ForEach(appState.telegramAccounts) { acc in
              Button(acc.displayLabel) {
                Task { await appState.switchTelegramAccount(acc.id) }
              }
              .buttonStyle(TvApplePillButtonStyle(isSelected: appState.activeTelegramAccountId == acc.id, compact: true))
            }
          }

          HStack(spacing: 16) {
            TextField("新增多账号备注名", text: $newAccountName)
              .frame(width: 400)
            Button("新增账号槽位") {
              guard !newAccountName.isEmpty else { return }
              Task {
                if let created = try? await appState.api.createTelegramAccount(name: newAccountName) {
                  newAccountName = ""
                  await appState.loadTelegramAccounts(preferredId: created.id)
                }
              }
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
          }

          Divider()

          HStack(spacing: 16) {
            TextField("API ID (例如 123456)", text: $tgApiId)
              .frame(width: 320)
            TextField("API Hash", text: $tgApiHash)
              .frame(width: 520)
            Button("保存 API 配置") {
              guard let id = Int(tgApiId), !tgApiHash.isEmpty else { return }
              Task {
                try? await appState.api.saveTelegramApiConfig(
                  accountId: appState.activeTelegramAccountId,
                  apiId: id,
                  apiHash: tgApiHash
                )
                appState.showToast("已保存 Telegram API 配置")
                await appState.loadTelegramAccounts(preferredId: appState.activeTelegramAccountId)
              }
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
          }

          HStack(spacing: 16) {
            TextField("手机号 (+86...)", text: $tgPhone)
              .frame(width: 340)
            Button("发送验证码") {
              guard !tgPhone.isEmpty else { return }
              Task {
                do {
                  try await appState.api.sendTelegramLoginCode(accountId: appState.activeTelegramAccountId, phone: tgPhone)
                  appState.showToast("验证码已发送至您的 Telegram 客户端")
                } catch {
                  appState.showToast("发送失败：\(error.localizedDescription)")
                }
              }
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))

            TextField("验证码", text: $tgCode)
              .frame(width: 220)
            SecureField("两步验证密码 (选填)", text: $tgPassword)
              .frame(width: 280)
            Button("验证并登录") {
              guard !tgCode.isEmpty else { return }
              Task {
                do {
                  _ = try await appState.api.submitTelegramLogin(
                    accountId: appState.activeTelegramAccountId,
                    code: tgCode,
                    password: tgPassword
                  )
                  appState.showToast("Telegram 登录成功！")
                  await appState.loadTelegramAccounts(preferredId: appState.activeTelegramAccountId)
                  isPresented = false
                } catch {
                  appState.showToast("登录失败：\(error.localizedDescription)")
                }
              }
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
          }
        }
        .padding(48)
      }
    }
  }
}

// MARK: - 4. Favorites & Watch History Section View

struct TvFavoritesHistorySectionView: View {
  @EnvironmentObject var appState: TvAppState
  @State private var selectedTab: String = "favorites"
  @FocusState private var focusedFavTop: Bool

  private let columns = [
    GridItem(.adaptive(minimum: 235, maximum: 275), spacing: 36)
  ]

  var body: some View {
    let items = selectedTab == "favorites" ? appState.favorites : appState.history

    ScrollViewReader { scrollProxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 26) {
          HStack(spacing: 16) {
            Button {
              selectedTab = "favorites"
            } label: {
              Label("我的收藏 (\(appState.favorites.count))", systemImage: "heart.fill")
            }
            .buttonStyle(TvApplePillButtonStyle(isSelected: selectedTab == "favorites"))
            .focused($focusedFavTop)

            Button {
              selectedTab = "history"
            } label: {
              Label("观看历史 (\(appState.history.count))", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(TvApplePillButtonStyle(isSelected: selectedTab == "history"))

            Spacer()

            Button {
              Task { await appState.refreshLibrary() }
            } label: {
              Label("同步云端", systemImage: "arrow.clockwise")
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))

            if !items.isEmpty {
              Button {
                Task { await appState.clearLibrary(kind: selectedTab) }
              } label: {
                Label(selectedTab == "favorites" ? "清空收藏" : "清空历史", systemImage: "trash")
              }
              .buttonStyle(TvApplePillButtonStyle(isDestructive: true, compact: true))
            }
          }
          .padding(.horizontal, 24)
          .padding(.vertical, 14)
          .background(.ultraThinMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
          .id("fav_top_anchor")
          .focusSection()

          if items.isEmpty {
            VStack(spacing: 18) {
              Image(systemName: selectedTab == "favorites" ? "heart.slash" : "clock")
                .font(.system(size: 64, weight: .light))
                .foregroundColor(.secondary)
              Text(selectedTab == "favorites" ? "暂无收藏影片" : "暂无观看历史")
                .font(.title3)
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 420)
          } else {
            LazyVGrid(columns: columns, spacing: 40) {
              ForEach(items) { lib in
                Button {
                  if let src = appState.resolveSourceForLibraryItem(lib) {
                    appState.selectedDetailItem = TvVodItem(
                      vodId: lib.vodId,
                      vodName: lib.title,
                      vodPic: lib.poster,
                      vodRemarks: lib.episode.isEmpty ? lib.remark : lib.episode,
                      vodYear: "",
                      typeName: lib.line,
                      source: src
                    )
                  }
                } label: {
                  let remarkLabel = lib.episode.isEmpty ? lib.remark : lib.episode
                  VStack(alignment: .leading, spacing: 8) {
                    ZStack(alignment: .bottomLeading) {
                      TvRemoteImage(rawUrl: lib.poster, placeholderIcon: "film", contentMode: .fill)
                        .frame(width: 245, height: 348)
                        .clipped()

                      LinearGradient(
                        colors: [.clear, Color.black.opacity(0.84)],
                        startPoint: .center,
                        endPoint: .bottom
                      )
                      .frame(height: 96)

                      if !remarkLabel.isEmpty {
                        HStack {
                          Text(remarkLabel)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(appState.activeTheme.accentHover)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color(red: 0.06, green: 0.07, blue: 0.10).opacity(0.88))
                            .clipShape(Capsule())
                            .overlay(
                              Capsule()
                                .stroke(appState.activeTheme.accent.opacity(0.55), lineWidth: 1)
                            )
                          Spacer()
                        }
                        .padding(12)
                      }
                    }
                    .frame(width: 245, height: 348)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    Text(lib.title)
                      .font(.headline)
                      .foregroundColor(.white)
                      .lineLimit(1)

                    Text("\(lib.sourceName) · \(remarkLabel)")
                      .font(.caption)
                      .foregroundColor(appState.activeTheme.accentHover.opacity(0.88))
                      .lineLimit(1)
                  }
                  .frame(width: 245)
                }
                .buttonStyle(.card)
              }
            }
            .focusSection()
          }
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 24)
      }
      .onChange(of: appState.pageScrollToTopTrigger) { _ in
        focusedFavTop = true
        withAnimation(.easeInOut(duration: 0.25)) {
          scrollProxy.scrollTo("fav_top_anchor", anchor: .top)
        }
      }
    }
    .onAppear {
      Task { await appState.refreshLibrary() }
    }
  }
}

// MARK: - 5. Downloads & Web Video Sniffer Section View

struct TvDownloadsSectionView: View {
  @EnvironmentObject var appState: TvAppState
  @State private var newUrl: String = ""
  @State private var newName: String = ""
  @State private var snifferInput: String = ""
  @FocusState private var focusedDlTop: Bool

  var body: some View {
    let theme = appState.activeTheme

    ScrollViewReader { scrollProxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          // Create Task & Web Video Sniffer Card
          VStack(alignment: .leading, spacing: 14) {
            Text("新建下载任务 & 网页视频流嗅探")
              .font(.system(size: 18, weight: .bold))

            HStack(spacing: 12) {
              TextField("输入 M3U8 / MP4 直链地址...", text: $newUrl)
              TextField("任务文件名", text: $newName)
                .frame(width: 280)
              Button {
                guard !newUrl.isEmpty else { return }
                let name = newName.isEmpty ? "TV下载_\(Int(Date().timeIntervalSince1970))" : newName
                Task {
                  try? await appState.api.createDownloadTask(url: newUrl, name: name)
                  newUrl = ""
                  newName = ""
                  appState.showToast("已提交下载任务：\(name)")
                  await appState.refreshDownloadTasks()
                }
              } label: {
                Label("提交下载", systemImage: "arrow.down.circle.fill")
              }
              .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
              .focused($focusedDlTop)
            }

            HStack(spacing: 12) {
              TextField("输入包含视频的网页 URL 或分享文本进行智能嗅探...", text: $snifferInput)
              Button {
                Task { await appState.extractWebVideoCandidates(input: snifferInput) }
              } label: {
                Label(appState.isExtractingWeb ? "嗅探中..." : "网页视频嗅探", systemImage: "wand.and.stars")
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))

              Button {
                Task { await appState.refreshDownloadTasks() }
              } label: {
                Label("刷新队列", systemImage: "arrow.clockwise")
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))
            }

            if !appState.extractedCandidates.isEmpty {
              VStack(alignment: .leading, spacing: 8) {
                Text("嗅探到的 VOD 视频直链 (\(appState.extractedCandidates.count))")
                  .font(.system(size: 14, weight: .bold))
                  .foregroundColor(theme.accentHover)

                ForEach(appState.extractedCandidates) { cand in
                  HStack(spacing: 10) {
                    Text(cand.type.uppercased())
                      .font(.system(size: 11, weight: .bold, design: .monospaced))
                      .foregroundColor(theme.accentHover)
                      .padding(.horizontal, 7)
                      .padding(.vertical, 3)
                      .background(theme.accent.opacity(0.18))
                      .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                    Text(cand.title)
                      .font(.system(size: 14, weight: .semibold))
                      .foregroundColor(.white)
                      .lineLimit(1)

                    Text(cand.url)
                      .font(.system(size: 12, design: .monospaced))
                      .foregroundColor(.white.opacity(0.48))
                      .lineLimit(1)

                    Spacer()

                    Button("直接播放") {
                      appState.playDirectStream(title: cand.title, subtitle: "网页嗅探直连", url: cand.url, headers: cand.headers)
                    }
                    .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))

                    Button("转存下载") {
                      Task {
                        try? await appState.api.createDownloadTask(url: cand.url, name: cand.title, headers: cand.headers)
                        appState.showToast("已加入下载队列：\(cand.title)")
                        await appState.refreshDownloadTasks()
                      }
                    }
                    .buttonStyle(TvApplePillButtonStyle(compact: true))
                  }
                  .padding(.horizontal, 14)
                  .padding(.vertical, 10)
                  .background(theme.bgCard.opacity(0.85))
                  .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                  .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                      .stroke(Color.white.opacity(0.08), lineWidth: 1)
                  )
                }
              }
            }
          }
          .padding(22)
          .background(.ultraThinMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
          .id("dl_top_anchor")
          .focusSection()

          // Task Queue List
          VStack(alignment: .leading, spacing: 10) {
            Text("服务器下载任务列表 (\(appState.downloadTasks.count))")
              .font(.system(size: 17, weight: .bold))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 520, maximum: 860), spacing: 12)], spacing: 12) {
              ForEach(appState.downloadTasks) { task in
                HStack(spacing: 14) {
                  VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                      Text(task.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                      Text(task.statusLabel)
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(task.isCompleted ? Color.green.opacity(0.26) : (task.isFailed ? Color.red.opacity(0.26) : theme.accent.opacity(0.26)))
                        .clipShape(Capsule())
                    }
                    Text(String(format: "进度 %.1f%% · %@ · 分片 %d/%d", task.progress, task.formattedSpeed, task.downloadedSegments, task.totalSegments))
                      .font(.system(size: 12, design: .monospaced))
                      .foregroundColor(.white.opacity(0.58))
                    if !task.error.isEmpty {
                      Text(task.error)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .lineLimit(1)
                    }
                  }

                  Spacer()

                  if task.isCompleted && !task.outputFile.isEmpty {
                    Button("播放") {
                      let url = appState.api.buildFileStreamUrl(path: task.outputFile)
                      appState.playDirectStream(title: task.name, subtitle: "已完成下载任务", url: url, headers: appState.api.authHeaders)
                    }
                    .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))

                    Button("上传115") {
                      Task {
                        try? await appState.api.uploadTaskTo115(id: task.id)
                        appState.showToast("已触发上传 115：\(task.name)")
                        await appState.refreshDownloadTasks()
                      }
                    }
                    .buttonStyle(TvApplePillButtonStyle(compact: true))
                  }

                  if task.isFailed {
                    Button("重试") {
                      Task {
                        try? await appState.api.retryDownloadTask(id: task.id)
                        await appState.refreshDownloadTasks()
                      }
                    }
                    .buttonStyle(TvApplePillButtonStyle(compact: true))
                  }

                  Button("删除") {
                    Task {
                      try? await appState.api.deleteDownloadTask(id: task.id, deleteFiles: false)
                      await appState.refreshDownloadTasks()
                    }
                  }
                  .buttonStyle(TvApplePillButtonStyle(isDestructive: true, compact: true))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                  RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
              }
            }
          }
          .focusSection()
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 20)
      }
      .onChange(of: appState.pageScrollToTopTrigger) { _ in
        focusedDlTop = true
        withAnimation(.easeInOut(duration: 0.25)) {
          scrollProxy.scrollTo("dl_top_anchor", anchor: .top)
        }
      }
    }
    .onAppear {
      Task { await appState.refreshDownloadTasks() }
    }
  }
}

// MARK: - 6. Multi-Storage Enhanced File Manager Section View (Server / AList / WebDAV / 115 / Local Cache)

struct TvMediaLibrarySectionView: View {
  @EnvironmentObject var appState: TvAppState
  @FocusState private var focusedMediaTop: Bool
  @FocusState private var modalInitialFocus: String?

  // Modal Sheets & Interactive Dialogs
  @State private var showMountModal: Bool = false
  @State private var editingMount: TvStorageMount? = nil
  @State private var mountKind: TvStorageSourceKind = .alist
  @State private var mountNameInput: String = ""
  @State private var mountUrlInput: String = ""
  @State private var mountUserInput: String = ""
  @State private var mountPassInput: String = ""
  @State private var mountTokenInput: String = ""
  @State private var mountRootPathInput: String = "/"

  @State private var showTransferDrawer: Bool = false
  @State private var showLanUploadSheet: Bool = false
  @State private var show115QuickLoginSheet: Bool = false
  @State private var showRemoteDownloadModal: Bool = false
  @State private var remoteDownloadUrlInput: String = ""
  @State private var remoteDownloadNameInput: String = ""

  @State private var showNewFolderModal: Bool = false
  @State private var newFolderNameInput: String = ""

  @State private var renamingEntry: TvFileEntry? = nil
  @State private var renameInputText: String = ""

  @State private var actionSheetEntry: TvFileEntry? = nil
  @State private var imagePreviewEntry: TvFileEntry? = nil
  @State private var imagePreviewResolvedUrl: String = ""
  @State private var imagePreviewUiImage: UIImage? = nil
  @State private var isLoadingImagePreview: Bool = false
  @State private var imagePreviewZoomScale: CGFloat = 1.0
  @State private var imagePreviewFillScreen: Bool = false
  @State private var imagePreviewShowHeader: Bool = true
  @State private var textPreviewEntry: TvFileEntry? = nil
  @State private var textPreviewContent: String = ""
  @State private var isLoadingTextPreview: Bool = false

  private var filteredAndSortedEntries: [TvFileEntry] {
    appState.displayedFileEntries
  }

  private var canNavigateUp: Bool {
    let mount = appState.activeStorageMount
    if mount.kind == .cloud115 {
      return !appState.fileListing.path.isEmpty && appState.fileListing.path != "0"
    }
    return !appState.fileListing.path.isEmpty
      && appState.fileListing.path != appState.fileListing.root
      && appState.fileListing.path != "/"
  }

  private func navigateUp() {
    let mount = appState.activeStorageMount
    if mount.kind == .cloud115 {
      if appState.cloud115Breadcrumbs.count >= 2 {
        let prev = appState.cloud115Breadcrumbs[appState.cloud115Breadcrumbs.count - 2]
        Task { await appState.loadFiles(path: prev.cid, folderTitleHint: prev.name) }
      } else {
        Task { await appState.loadFiles(path: "0", folderTitleHint: "115根目录") }
      }
      return
    }
    Task { await appState.loadFiles(path: appState.fileListing.parent) }
  }

  /// Standard File Manager direct click handler:
  /// - Folder -> enters folder immediately
  /// - Video / Audio -> plays immediately
  /// - Image -> opens fullscreen TV image viewer immediately
  /// - Text / Subtitle / M3U / Config -> opens fullscreen text viewer immediately
  /// - Other files -> opens File Action & Detail Sheet
  private func handleDirectItemClick(_ entry: TvFileEntry) {
    if appState.fileMultiSelectMode {
      if appState.fileSelectedPaths.contains(entry.path) {
        appState.fileSelectedPaths.remove(entry.path)
      } else {
        appState.fileSelectedPaths.insert(entry.path)
      }
      return
    }

    if entry.isDir {
      Task { await appState.loadFiles(path: entry.path, folderTitleHint: entry.name) }
      return
    }

    if entry.isStreamableMusicArchive {
      appState.activeArchiveMusicBrowserEntry = entry
      return
    }

    if entry.isPlayableVideo {
      appState.playMediaFile(entry)
      return
    }

    if entry.isImage {
      openImagePreview(entry)
      return
    }

    if entry.isTextPreviewable {
      openTextPreview(entry)
      return
    }

    actionSheetEntry = entry
  }

  private func openImagePreview(_ entry: TvFileEntry) {
    imagePreviewEntry = entry
    imagePreviewResolvedUrl = ""
    imagePreviewUiImage = nil
    imagePreviewZoomScale = 1.0
    imagePreviewFillScreen = false
    imagePreviewShowHeader = true
    isLoadingImagePreview = true
    Task {
      defer { self.isLoadingImagePreview = false }
      if entry.sourceKind == .localCache {
        let localUrl = TvAppState.resolveLocalOfflineUrl(relativePath: entry.path)
        self.imagePreviewResolvedUrl = localUrl.absoluteString
        if let d = try? Data(contentsOf: localUrl), let img = UIImage(data: d) {
          self.imagePreviewUiImage = img
        }
        return
      }
      if entry.sourceKind == .cloud115 {
        if let resolved = try? await appState.resolveFileStreamEndpoint(entry), !resolved.url.isEmpty {
          self.imagePreviewResolvedUrl = resolved.url
          if let data = await TvLocal115DirectClient.shared.fetch115ImageData(urlStr: resolved.url),
             let fullImg = UIImage(data: data) {
            self.imagePreviewUiImage = fullImg
            return
          }
          if let data = await appState.api.fetchFilePreviewImageData(urlStr: resolved.url, headers: resolved.headers),
             let fullImg = UIImage(data: data) {
            self.imagePreviewUiImage = fullImg
            return
          }
        }
        if !entry.thumbUrl.isEmpty, self.imagePreviewUiImage == nil {
          let hdThumb = entry.thumbUrl
            .replacingOccurrences(of: "size=100", with: "size=2048")
            .replacingOccurrences(of: "size=200", with: "size=2048")
            .replacingOccurrences(of: "_100_100", with: "_1920_0")
          if let thumbData = await TvLocal115DirectClient.shared.fetch115ImageData(urlStr: hdThumb),
             let thumbImg = UIImage(data: thumbData) {
            self.imagePreviewUiImage = thumbImg
            return
          }
          if let thumbData = await TvLocal115DirectClient.shared.fetch115ImageData(urlStr: entry.thumbUrl),
             let thumbImg = UIImage(data: thumbData) {
            self.imagePreviewUiImage = thumbImg
          }
        }
        return
      }
      if let resolved = try? await appState.resolveFileStreamEndpoint(entry), !resolved.url.isEmpty {
        self.imagePreviewResolvedUrl = resolved.url
        if let data = await appState.api.fetchFilePreviewImageData(urlStr: resolved.url, headers: resolved.headers),
           let fullImg = UIImage(data: data) {
          self.imagePreviewUiImage = fullImg
          return
        }
      }
      if !entry.thumbUrl.isEmpty, self.imagePreviewUiImage == nil {
        if let thumbData = await appState.api.fetchFilePreviewImageData(urlStr: entry.thumbUrl, headers: [:]),
           let thumbImg = UIImage(data: thumbData) {
          self.imagePreviewUiImage = thumbImg
        }
      }
    }
  }

  private func switchImagePreview(offset: Int) {
    guard let current = imagePreviewEntry else { return }
    let imageEntries = filteredAndSortedEntries.filter { $0.isImage }
    guard imageEntries.count > 1,
          let idx = imageEntries.firstIndex(where: { $0.id == current.id }) else { return }
    let nextIdx = (idx + offset + imageEntries.count) % imageEntries.count
    openImagePreview(imageEntries[nextIdx])
  }

  private func openTextPreview(_ entry: TvFileEntry) {
    textPreviewEntry = entry
    textPreviewContent = ""
    isLoadingTextPreview = true
    Task {
      defer { self.isLoadingTextPreview = false }
      do {
        if entry.sourceKind == .localCache {
          let localUrl = TvAppState.resolveLocalOfflineUrl(relativePath: entry.path)
          let d = try Data(contentsOf: localUrl)
          let slice = d.count > 65536 ? d.prefix(65536) : d[...]
          self.textPreviewContent = String(data: Data(slice), encoding: .utf8) ?? String(decoding: slice, as: UTF8.self)
          return
        }
        let resolved = try await appState.resolveFileStreamEndpoint(entry)
        let txt = try await appState.api.fetchFilePreviewText(urlStr: resolved.url, headers: resolved.headers)
        self.textPreviewContent = txt
      } catch {
        self.textPreviewContent = "读取文件内容失败：\(error.localizedDescription)"
      }
    }
  }

  private func openMountEditor(_ mount: TvStorageMount? = nil, defaultKind: TvStorageSourceKind = .alist) {
    if let m = mount {
      editingMount = m
      mountKind = m.kind
      mountNameInput = m.name
      mountUrlInput = m.baseUrl
      mountUserInput = m.username
      mountPassInput = m.password
      mountTokenInput = m.token
      mountRootPathInput = m.rootPath
    } else {
      editingMount = nil
      mountKind = defaultKind
      mountNameInput = ""
      mountUrlInput = defaultKind == .alist ? "http://192.168.1.10:5244" : "http://192.168.1.10:5244/dav"
      mountUserInput = ""
      mountPassInput = ""
      mountTokenInput = ""
      mountRootPathInput = "/"
    }
    showMountModal = true
  }

  private func iconColor(for entry: TvFileEntry, theme: TvThemePalette) -> Color {
    if entry.isDir { return Color(red: 1.0, green: 0.78, blue: 0.22) }
    if entry.isVideo { return theme.accentHover }
    if entry.isAudio { return Color(red: 0.35, green: 0.85, blue: 0.65) }
    if entry.isImage { return Color(red: 0.85, green: 0.48, blue: 0.98) }
    if entry.isTextPreviewable { return Color(red: 0.42, green: 0.74, blue: 1.0) }
    return Color.white.opacity(0.75)
  }

  var body: some View {
    let theme = appState.activeTheme

    ScrollViewReader { scrollProxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          // 1. Storage Source Mount Switcher Bar (Server / 115 / Local Cache / Mounted AList & WebDAV + Mount Button)
          storageMountSwitcherBar(theme: theme)
            .id("media_top_anchor")
            .focusSection()

          // 1b. Persistent Cloud Hi-Fi Music Dock Bar (browse 115 / AList folders while music plays!)
          if appState.currentCloudMusicTrack != nil {
            TvCloudMusicBottomDockBar()
              .focusSection()
          }

          // 2. Live Upload / Download Real-Time Progress Banner (Always visible when transfers exist)
          if !appState.fileTransferTasks.isEmpty {
            liveTransferProgressBanner(theme: theme)
              .focusSection()
          }

          // 3. Favorites / Bookmarked Directories Quick Strip (if any)
          if !appState.fileFavoritePaths.isEmpty {
            favoriteFoldersStrip(theme: theme)
              .focusSection()
          }

          // 4. Interactive Breadcrumb Path Bar + File Manager Action Toolbar
          breadcrumbAndToolbarCard(theme: theme)
            .focusSection()

          // 5. Filter & Multi-Select / Clipboard Action Bar
          filterAndBatchBar(theme: theme)
            .focusSection()

          // 6. Main File & Folder Browser Area (Direct Click to Open/Play, Long-Press Context Menu, List or Grid)
          mainFileBrowserContent(theme: theme)
            .focusSection()
        }
        .padding(.horizontal, 52)
        .padding(.vertical, 18)
      }
      .onChange(of: appState.pageScrollToTopTrigger) { _ in
        focusedMediaTop = true
        withAnimation(.easeInOut(duration: 0.25)) {
          scrollProxy.scrollTo("media_top_anchor", anchor: .top)
        }
      }
    }
    .sheet(isPresented: $showMountModal) {
      mountEditorModal(theme: theme)
    }
    .sheet(isPresented: $showLanUploadSheet) {
      lanUploadPortalModal(theme: theme)
    }
    .sheet(isPresented: $showTransferDrawer) {
      transferCenterModal(theme: theme)
    }
    .sheet(isPresented: $showRemoteDownloadModal) {
      remoteDownloadModal(theme: theme)
    }
    .sheet(isPresented: $showNewFolderModal) {
      newFolderModal(theme: theme)
    }
    .sheet(item: $renamingEntry) { target in
      renameModal(entry: target, theme: theme)
    }
    .sheet(item: $actionSheetEntry) { target in
      fileActionSheetModal(entry: target, theme: theme)
    }
    .fullScreenCover(item: $imagePreviewEntry) { imgEntry in
      imagePreviewModal(entry: imgEntry, theme: theme)
    }
    .sheet(item: $textPreviewEntry) { txtEntry in
      textPreviewModal(entry: txtEntry, theme: theme)
    }
    .fullScreenCover(isPresented: $appState.showCloudMusicFullscreen) {
      TvCloudMusicFullscreenHallView(isStandaloneSection: false)
        .environmentObject(appState)
    }
    .sheet(isPresented: $appState.showMusicFolderPickerSheet) {
      TvMusicFolderPickerSheet()
        .environmentObject(appState)
    }
    .sheet(item: $appState.activeArchiveMusicBrowserEntry) { archEntry in
      TvArchiveMusicBrowserSheet(archiveEntry: archEntry)
        .environmentObject(appState)
    }
    .sheet(isPresented: $show115QuickLoginSheet) {
      Tv115QuickLoginSheet(
        isPresented: $show115QuickLoginSheet,
        onLoginCompleted: {
          Task {
            await appState.loadFiles(path: "0", folderTitleHint: "115根目录")
          }
        }
      )
      .environmentObject(appState)
    }
    .onAppear {
      appState.startLanInputServer()
      if appState.fileListing.entries.isEmpty {
        let mount = appState.activeStorageMount
        Task {
          await appState.loadFiles(
            path: mount.kind == .cloud115 ? "0" : (mount.kind == .server ? "" : mount.rootPath)
          )
        }
      }
    }
  }

  // MARK: - Subviews

  @ViewBuilder
  private func storageMountSwitcherBar(theme: TvThemePalette) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 12) {
        ForEach(appState.storageMounts) { mount in
          let isSelected = appState.activeStorageMountId == mount.id
          Button {
            appState.switchStorageMount(mount.id)
          } label: {
            HStack(spacing: 8) {
              Image(systemName: mount.kind.icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(isSelected ? .white : theme.accentHover)
              Text(mount.name)
                .font(.system(size: 15, weight: .bold))
              Text(mount.badgeTitle)
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.white.opacity(isSelected ? 0.24 : 0.10))
                .clipShape(Capsule())
            }
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: isSelected, compact: true))
          .contextMenu {
            Button {
              appState.switchStorageMount(mount.id)
            } label: {
              Label("打开此存储源", systemImage: "folder.fill")
            }
            if !mount.isBuiltIn {
              Button {
                openMountEditor(mount)
              } label: {
                Label("编辑挂载配置", systemImage: "slider.horizontal.3")
              }
              Button(role: .destructive) {
                appState.deleteStorageMount(mount.id)
              } label: {
                Label("卸载此存储", systemImage: "trash.fill")
              }
            }
          }
        }

        Button {
          openMountEditor(nil, defaultKind: .alist)
        } label: {
          Label("挂载 AList / WebDAV", systemImage: "plus.circle.fill")
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))
        .focused($focusedMediaTop)

        if !appState.activeStorageMount.isBuiltIn {
          Button {
            openMountEditor(appState.activeStorageMount)
          } label: {
            Label("配置当前挂载", systemImage: "gearshape.fill")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))
        }
      }
      .padding(.horizontal, 4)
      .padding(.vertical, 4)
    }
  }

  @ViewBuilder
  private func liveTransferProgressBanner(theme: TvThemePalette) -> some View {
    let runningCount = appState.activeRunningTransfersCount
    if let topTask = appState.primaryActiveTransferTask {
      Button {
        showTransferDrawer = true
      } label: {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 12) {
            Image(systemName: topTask.direction.icon)
              .font(.system(size: 20, weight: .bold))
              .foregroundColor(topTask.status == .failed ? .red : (topTask.status == .completed ? .green : theme.accentHover))

            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 8) {
                Text("\(topTask.direction.label)\(topTask.status.label)：\(topTask.name)")
                  .font(.system(size: 15, weight: .bold))
                  .foregroundColor(.white)
                  .lineLimit(1)
                if runningCount > 1 {
                  Text("共 \(runningCount) 个任务并发传输中")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(theme.accentHover)
                    .clipShape(Capsule())
                }
              }
              Text("\(topTask.detailMessage) · \(topTask.sourceLabel) → \(topTask.targetLabel)")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.68))
                .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
              Text(topTask.percentText)
                .font(.system(size: 18, weight: .heavy, design: .monospaced))
                .foregroundColor(theme.accentHover)
              Text("\(topTask.formattedBytesProgress) · \(topTask.formattedSpeed)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white.opacity(0.75))
            }

            Text("查看传输队列 (\(appState.fileTransferTasks.count))")
              .font(.system(size: 13, weight: .bold))
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .background(Color.white.opacity(0.14))
              .clipShape(Capsule())
          }

          GeometryReader { geo in
            ZStack(alignment: .leading) {
              Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(height: 8)
              Capsule()
                .fill(
                  LinearGradient(
                    colors: [theme.accent, theme.accentHover],
                    startPoint: .leading,
                    endPoint: .trailing
                  )
                )
                .frame(width: max(8, geo.size.width * topTask.progress), height: 8)
            }
          }
          .frame(height: 8)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
      }
      .buttonStyle(TvAppleSurfaceButtonStyle(cornerRadius: 16))
    }
  }

  @ViewBuilder
  private func favoriteFoldersStrip(theme: TvThemePalette) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 10) {
        Label("常用目录：", systemImage: "star.fill")
          .font(.system(size: 13, weight: .bold))
          .foregroundColor(.yellow)

        ForEach(appState.fileFavoritePaths, id: \.self) { fav in
          let parts = fav.components(separatedBy: "::")
          if parts.count >= 3 {
            let mId = parts[0]
            let title = parts[1]
            let path = parts.dropFirst(2).joined(separator: "::")
            Button {
              if appState.activeStorageMountId != mId {
                appState.activeStorageMountId = mId
              }
              Task { await appState.loadFiles(path: path, folderTitleHint: title) }
            } label: {
              HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                  .foregroundColor(.yellow)
                Text(title)
                  .font(.system(size: 13, weight: .semibold))
              }
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
          }
        }
      }
      .padding(.horizontal, 4)
    }
  }

  @ViewBuilder
  private func breadcrumbAndToolbarCard(theme: TvThemePalette) -> some View {
    let mount = appState.activeStorageMount

    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        // Interactive Breadcrumb Bar
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            if mount.kind == .cloud115 {
              ForEach(Array(appState.cloud115Breadcrumbs.enumerated()), id: \.offset) { idx, crumb in
                if idx > 0 {
                  Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.4))
                }
                Button {
                  Task { await appState.loadFiles(path: crumb.cid, folderTitleHint: crumb.name) }
                } label: {
                  HStack(spacing: 5) {
                    if idx == 0 {
                      Image(systemName: "icloud.fill")
                    }
                    Text(crumb.name)
                      .font(.system(size: 14, weight: .bold))
                  }
                }
                .buttonStyle(TvApplePillButtonStyle(isPrimary: idx == appState.cloud115Breadcrumbs.count - 1, compact: true))
              }
            } else {
              let rawPath = appState.fileListing.path.isEmpty ? "/" : appState.fileListing.path
              let segments = rawPath.split(separator: "/").map(String.init)
              Button {
                Task { await appState.loadFiles(path: mount.kind == .server ? "" : mount.rootPath) }
              } label: {
                HStack(spacing: 5) {
                  Image(systemName: mount.kind.icon)
                  Text(mount.name)
                    .font(.system(size: 14, weight: .bold))
                }
              }
              .buttonStyle(TvApplePillButtonStyle(isPrimary: segments.isEmpty, compact: true))

              ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                Image(systemName: "chevron.right")
                  .font(.system(size: 11, weight: .bold))
                  .foregroundColor(.white.opacity(0.4))
                let partialPath = "/" + segments.prefix(idx + 1).joined(separator: "/")
                Button {
                  Task { await appState.loadFiles(path: partialPath) }
                } label: {
                  Text(seg)
                    .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(TvApplePillButtonStyle(isPrimary: idx == segments.count - 1, compact: true))
              }
            }
          }
        }

        Spacer()

        // Action Toolbar Buttons
        if mount.kind == .cloud115 {
          Button {
            show115QuickLoginSheet = true
          } label: {
            Label(TvLocal115DirectClient.shared.hasLocalCookie ? "115 扫码换号/刷新" : "扫码登录 115", systemImage: "qrcode.viewfinder")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))
        }

        Button {
          appState.toggleFavoriteCurrentDirectory()
        } label: {
          Image(systemName: appState.isCurrentDirectoryFavorited ? "star.fill" : "star")
            .foregroundColor(appState.isCurrentDirectoryFavorited ? .yellow : .white)
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))

        Button {
          appState.startLanInputServer()
          showLanUploadSheet = true
        } label: {
          Label("上传文件", systemImage: "arrow.up.doc.fill")
        }
        .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))

        Button {
          remoteDownloadUrlInput = ""
          remoteDownloadNameInput = ""
          showRemoteDownloadModal = true
        } label: {
          Label("离线下载", systemImage: "arrow.down.circle.fill")
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))

        Button {
          newFolderNameInput = ""
          showNewFolderModal = true
        } label: {
          Label("新建文件夹", systemImage: "folder.badge.plus")
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))

        Button {
          showTransferDrawer = true
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "arrow.up.arrow.down.circle.fill")
            Text("传输进度")
            if !appState.fileTransferTasks.isEmpty {
              Text("\(appState.fileTransferTasks.count)")
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(theme.accent)
                .clipShape(Capsule())
            }
          }
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))

        Button {
          Task { await appState.loadFiles(path: appState.fileListing.path) }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  @ViewBuilder
  private func filterAndBatchBar(theme: TvThemePalette) -> some View {
    HStack(spacing: 10) {
      // Search Box
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundColor(.white.opacity(0.6))
        TextField("搜索当前目录文件或文件夹...", text: $appState.fileSearchKeyword)
          .font(.system(size: 14))
        if !appState.fileSearchKeyword.isEmpty {
          Button {
            appState.fileSearchKeyword = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(.white.opacity(0.6))
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .frame(width: 290)
      .background(Color.white.opacity(0.08))
      .clipShape(Capsule())

      // Category Filter Pills
      ForEach(TvFileCategoryFilter.allCases, id: \.self) { cat in
        let isSel = appState.fileCategoryFilter == cat
        Button {
          appState.fileCategoryFilter = cat
        } label: {
          Text(cat.title)
            .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(TvApplePillButtonStyle(isPrimary: isSel, compact: true))
      }

      let audioEntries = filteredAndSortedEntries.filter { !$0.isDir && $0.isAudio }
      if !audioEntries.isEmpty {
        Button {
          if let first = audioEntries.first {
            appState.playCloudMusicFromDirectory(first, openFullscreen: true)
          }
        } label: {
          Label("播放全部音乐 (\(audioEntries.count))", systemImage: "opticaldisc.fill")
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(theme.accentHover)
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))

        Button {
          if let first = audioEntries.first {
            appState.playCloudMusicFromDirectory(first, openFullscreen: true, shuffle: true)
          }
        } label: {
          Label("随机播放当前音乐", systemImage: "shuffle")
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(theme.accentHover)
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))
      }

      Button {
        appState.showMusicFolderPickerSheet = true
      } label: {
        Label("自选文件夹/压缩包随机播放", systemImage: "folder.badge.plus")
          .font(.system(size: 13, weight: .bold))
          .foregroundColor(theme.accentHover)
      }
      .buttonStyle(TvApplePillButtonStyle(compact: true))

      Spacer()

      // Clipboard Paste Button (when clipboard has copied/cut items)
      if let clip = appState.fileClipboard {
        Button {
          Task { await appState.pasteClipboardToCurrentDirectory() }
        } label: {
          Label(
            "粘贴 \(clip.entries.count) 项到此处",
            systemImage: "doc.on.clipboard.fill"
          )
        }
        .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))

        Button {
          appState.fileClipboard = nil
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))
      }

      // Multi-Select Batch Actions
      if appState.fileMultiSelectMode {
        let selectedEntries = appState.fileListing.entries.filter { appState.fileSelectedPaths.contains($0.path) }
        Button {
          if appState.fileSelectedPaths.count == filteredAndSortedEntries.count {
            appState.fileSelectedPaths.removeAll()
          } else {
            appState.fileSelectedPaths = Set(filteredAndSortedEntries.map(\.path))
          }
        } label: {
          Text(appState.fileSelectedPaths.count == filteredAndSortedEntries.count ? "取消全选" : "全选")
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))

        if !selectedEntries.isEmpty {
          Button {
            for e in selectedEntries where !e.isDir {
              appState.startDownloadFileWithProgress(e)
            }
            appState.fileMultiSelectMode = false
            appState.fileSelectedPaths.removeAll()
          } label: {
            Label("批量下载 (\(selectedEntries.count))", systemImage: "arrow.down.circle.fill")
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))

          Button {
            appState.setClipboard(entries: selectedEntries, operation: .copy)
          } label: {
            Label("复制", systemImage: "doc.on.doc")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))

          Button {
            appState.setClipboard(entries: selectedEntries, operation: .move)
          } label: {
            Label("移动", systemImage: "folder.badge.gearshape")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))

          Button {
            Task { await appState.deleteEntriesInActiveMount(selectedEntries) }
          } label: {
            Label("删除 (\(selectedEntries.count))", systemImage: "trash.fill")
          }
          .buttonStyle(TvApplePillButtonStyle(isDestructive: true, compact: true))
        }
      }

      Button {
        appState.fileMultiSelectMode.toggle()
        if !appState.fileMultiSelectMode {
          appState.fileSelectedPaths.removeAll()
        }
      } label: {
        Label(appState.fileMultiSelectMode ? "退出多选" : "多选", systemImage: "checkmark.circle")
      }
      .buttonStyle(TvApplePillButtonStyle(isPrimary: appState.fileMultiSelectMode, compact: true))

      // Cycle Sort Option
      Button {
        let all = TvFileSortOption.allCases
        let curIdx = all.firstIndex(of: appState.fileSortOption) ?? 0
        appState.fileSortOption = all[(curIdx + 1) % all.count]
      } label: {
        Label(appState.fileSortOption.title, systemImage: appState.fileSortOption.icon)
      }
      .buttonStyle(TvApplePillButtonStyle(compact: true))

      // Toggle List / Grid View
      Button {
        appState.toggleFileViewMode()
      } label: {
        Image(systemName: appState.fileViewIsGrid ? "list.bullet" : "square.grid.3x2.fill")
      }
      .buttonStyle(TvApplePillButtonStyle(compact: true))
    }
  }

  @ViewBuilder
  private func mainFileBrowserContent(theme: TvThemePalette) -> some View {
    let entries = filteredAndSortedEntries
    let visibleEntries = Array(entries.prefix(appState.visibleFileLimit))
    let mount = appState.activeStorageMount

    if appState.isLoadingFiles {
      VStack(spacing: 14) {
        ProgressView()
          .scaleEffect(1.3)
        Text("正在读取「\(mount.name)」目录内容...")
          .font(.system(size: 17, weight: .medium))
          .foregroundColor(.white.opacity(0.75))
      }
      .frame(maxWidth: .infinity, minHeight: 380)
    } else if mount.kind == .cloud115 && !TvLocal115DirectClient.shared.hasLocalCookie {
      VStack(spacing: 16) {
        Image(systemName: "icloud.slash.fill")
          .font(.system(size: 48))
          .foregroundColor(theme.accentHover)
        Text(appState.fileManagerError ?? "尚未登录 115 网盘账号")
          .font(.system(size: 20, weight: .bold))
          .multilineTextAlignment(.center)
        Text("可使用手机 115 App 立即扫码登录（采用 TV 独立通道，不与网页或 AList 顶号），或点击右上角「上传文件」通过手机浏览器推送 115 Cookie")
          .font(.system(size: 14))
          .foregroundColor(.white.opacity(0.65))
          .multilineTextAlignment(.center)
        HStack(spacing: 16) {
          Button {
            show115QuickLoginSheet = true
          } label: {
            Label("立即扫码登录 115 网盘", systemImage: "qrcode.viewfinder")
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: true))

          Button {
            appState.selectedSection = .settings
          } label: {
            Label("前往设置页粘贴 Cookie", systemImage: "gearshape.fill")
          }
          .buttonStyle(TvApplePillButtonStyle())
        }
      }
      .frame(maxWidth: .infinity, minHeight: 380)
    } else if entries.isEmpty {
      VStack(spacing: 16) {
        Image(systemName: appState.fileManagerError != nil ? "exclamationmark.triangle.fill" : "folder.badge.questionmark")
          .font(.system(size: 46))
          .foregroundColor(appState.fileManagerError != nil ? .orange : .white.opacity(0.45))
        Text(appState.fileManagerError ?? "当前目录为空")
          .font(.system(size: 18, weight: .semibold))
          .foregroundColor(.white.opacity(0.85))
          .multilineTextAlignment(.center)
        HStack(spacing: 14) {
          if canNavigateUp {
            Button {
              navigateUp()
            } label: {
              Label("返回上级目录", systemImage: "arrow.turn.left.up")
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
          }

          if mount.kind == .cloud115 {
            Button {
              show115QuickLoginSheet = true
            } label: {
              Label("重新扫码登录 115 网盘", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
          }

          Button {
            Task { await appState.loadFiles(path: appState.fileListing.path) }
          } label: {
            Label("重新加载目录", systemImage: "arrow.clockwise")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))

          Button {
            appState.startLanInputServer()
            showLanUploadSheet = true
          } label: {
            Label("扫码 / 浏览器上传文件", systemImage: "arrow.up.doc.fill")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))

          Button {
            newFolderNameInput = ""
            showNewFolderModal = true
          } label: {
            Label("新建文件夹", systemImage: "folder.badge.plus")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))
        }
      }
      .frame(maxWidth: .infinity, minHeight: 360)
    } else if appState.fileViewIsGrid {
      // Grid View Mode — Windowed rendering (`visibleEntries`) prevents tvOS Focus Engine hang/crash on massive AList/115 folders!
      VStack(alignment: .leading, spacing: 18) {
        let columns = [
          GridItem(.flexible(), spacing: 18),
          GridItem(.flexible(), spacing: 18),
          GridItem(.flexible(), spacing: 18),
          GridItem(.flexible(), spacing: 18),
          GridItem(.flexible(), spacing: 18)
        ]
        LazyVGrid(columns: columns, spacing: 18) {
          if canNavigateUp {
            Button {
              navigateUp()
            } label: {
              VStack(spacing: 10) {
                Image(systemName: "arrow.turn.left.up")
                  .font(.system(size: 32, weight: .bold))
                  .foregroundColor(.yellow)
                  .frame(height: 54)
                Text(".. 返回上级目录")
                  .font(.system(size: 14, weight: .bold))
                  .foregroundColor(.white)
                  .lineLimit(1)
                Text("上级文件夹")
                  .font(.system(size: 11))
                  .foregroundColor(.white.opacity(0.55))
              }
              .frame(maxWidth: .infinity)
              .padding(.vertical, 18)
              .padding(.horizontal, 12)
            }
            .buttonStyle(TvAppleSurfaceButtonStyle(cornerRadius: 16))
          }

          ForEach(visibleEntries) { entry in
            let isChecked = appState.fileSelectedPaths.contains(entry.path)
            Button {
              handleDirectItemClick(entry)
            } label: {
              VStack(spacing: 10) {
                ZStack(alignment: .topTrailing) {
                  Image(systemName: entry.iconName)
                    .font(.system(size: 36))
                    .foregroundColor(iconColor(for: entry, theme: theme))
                    .frame(maxWidth: .infinity, minHeight: 54)

                  if appState.fileMultiSelectMode {
                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                      .font(.system(size: 18, weight: .bold))
                      .foregroundColor(isChecked ? theme.accentHover : .white.opacity(0.45))
                  }
                }

                Text(entry.name)
                  .font(.system(size: 14, weight: .semibold))
                  .foregroundColor(.white)
                  .lineLimit(2)
                  .multilineTextAlignment(.center)
                  .frame(height: 36)

                HStack(spacing: 6) {
                  Text(entry.typeTagText)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
                  if !entry.isDir {
                    Text(entry.formattedSize)
                      .font(.system(size: 11, design: .monospaced))
                      .foregroundColor(.white.opacity(0.6))
                  }
                }
              }
              .frame(maxWidth: .infinity)
              .padding(.vertical, 16)
              .padding(.horizontal, 12)
            }
            .buttonStyle(TvAppleSurfaceButtonStyle(cornerRadius: 16))
            .contextMenu {
              fileContextMenuItems(for: entry)
            }
          }
        }

        paginationFooterBar(totalLoaded: entries.count, visibleCount: visibleEntries.count, theme: theme)
      }
    } else {
      // Standard List View Mode — Windowed rendering (`visibleEntries`) prevents tvOS Focus Engine hang/crash on massive AList/115 folders!
      LazyVStack(spacing: 8) {
        if canNavigateUp {
          Button {
            navigateUp()
          } label: {
            HStack(spacing: 16) {
              Image(systemName: "arrow.turn.left.up")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.yellow)
                .frame(width: 34)

              VStack(alignment: .leading, spacing: 2) {
                Text(".. (返回上级目录)")
                  .font(.system(size: 16, weight: .bold))
                  .foregroundColor(.white)
                Text("点击直接返回上一层文件夹")
                  .font(.system(size: 12))
                  .foregroundColor(.white.opacity(0.55))
              }
              Spacer()
              Text("上级目录")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))
              Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white.opacity(0.35))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
          }
          .buttonStyle(TvAppleSurfaceButtonStyle(cornerRadius: 14))
        }

        ForEach(visibleEntries) { entry in
          let isChecked = appState.fileSelectedPaths.contains(entry.path)
          Button {
            handleDirectItemClick(entry)
          } label: {
            HStack(spacing: 16) {
              if appState.fileMultiSelectMode {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                  .font(.system(size: 20, weight: .bold))
                  .foregroundColor(isChecked ? theme.accentHover : .white.opacity(0.4))
              }

              Image(systemName: entry.iconName)
                .font(.system(size: 22))
                .foregroundColor(iconColor(for: entry, theme: theme))
                .frame(width: 34)

              VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                  .font(.system(size: 16, weight: .semibold))
                  .foregroundColor(.white)
                  .lineLimit(1)

                HStack(spacing: 10) {
                  Text(entry.typeTagText)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(iconColor(for: entry, theme: theme))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Capsule())

                  if !entry.modTime.isEmpty {
                    Text(entry.modTime)
                      .font(.system(size: 12, design: .monospaced))
                      .foregroundColor(.white.opacity(0.52))
                  }

                  Text(entry.isDir ? "点击进入目录 · 长按管理" : (entry.isPlayableVideo ? "点击直接播放 · 长按更多操作" : "点击直接预览/操作 · 长按菜单"))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.38))
                }
              }

              Spacer()

              Text(entry.formattedSize)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.75))

              Image(systemName: entry.isDir ? "chevron.right" : (entry.isPlayableVideo ? "play.circle.fill" : "ellipsis.circle"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(entry.isDir ? .white.opacity(0.4) : theme.accentHover.opacity(0.85))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
          }
          .buttonStyle(TvAppleSurfaceButtonStyle(cornerRadius: 14))
          .contextMenu {
            fileContextMenuItems(for: entry)
          }
        }

        paginationFooterBar(totalLoaded: entries.count, visibleCount: visibleEntries.count, theme: theme)
      }
    }
  }

  @ViewBuilder
  private func paginationFooterBar(totalLoaded: Int, visibleCount: Int, theme: TvThemePalette) -> some View {
    let hasMoreLocal = totalLoaded > visibleCount
    let hasMoreRemote = appState.fileListing.hasMoreRemotePages
    let remoteTotal = max(appState.fileListing.totalCount, totalLoaded)

    if hasMoreLocal || hasMoreRemote {
      HStack(spacing: 16) {
        Text("当前显示 \(visibleCount) 项 · 已拉取 \(totalLoaded) 项\(remoteTotal > totalLoaded ? " / 目录总计 \(remoteTotal) 项" : "")")
          .font(.system(size: 13, weight: .semibold, design: .monospaced))
          .foregroundColor(.white.opacity(0.68))

        Spacer()

        if hasMoreLocal {
          Button {
            appState.visibleFileLimit += 100
          } label: {
            Label("继续展开下 100 项 (剩余 \(totalLoaded - visibleCount) 项)", systemImage: "chevron.down.circle.fill")
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
        }

        if hasMoreRemote {
          Button {
            Task { await appState.loadNextPageOfFiles() }
          } label: {
            HStack(spacing: 8) {
              if appState.isLoadingMoreFiles {
                ProgressView().scaleEffect(0.7)
              }
              Label(
                appState.isLoadingMoreFiles
                  ? "正在加载下一页..."
                  : "加载下一页远程目录 (第 \(appState.fileListing.currentPage + 1) 页)",
                systemImage: "arrow.down.doc.fill"
              )
            }
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: !hasMoreLocal, compact: true))
          .disabled(appState.isLoadingMoreFiles)
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 14)
      .background(.ultraThinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
  }

  @ViewBuilder
  private func fileContextMenuItems(for entry: TvFileEntry) -> some View {
    if entry.isDir {
      Button {
        Task { await appState.loadFiles(path: entry.path, folderTitleHint: entry.name) }
      } label: {
        Label("进入文件夹", systemImage: "folder.fill")
      }
      Button {
        let mount = appState.storageMounts.first(where: { $0.id == entry.mountId }) ?? appState.activeStorageMount
        Task {
          _ = await appState.scanAndPlayMusicFoldersOrArchives(
            sources: [
              TvSavedMusicFolderItem(
                mountId: mount.id,
                mountName: mount.name,
                sourceKind: mount.kind,
                path: entry.path,
                title: entry.name,
                isArchive: false,
                size: 0,
                pickcode115: entry.pickcode115
              )
            ],
            shuffle: true,
            includeSubfolders: true,
            openFullscreen: true
          )
        }
      } label: {
        Label("随机播放此文件夹音乐 (含子目录与压缩包)", systemImage: "shuffle")
      }
      Button {
        let mount = appState.storageMounts.first(where: { $0.id == entry.mountId }) ?? appState.activeStorageMount
        Task {
          _ = await appState.scanAndPlayMusicFoldersOrArchives(
            sources: [
              TvSavedMusicFolderItem(
                mountId: mount.id,
                mountName: mount.name,
                sourceKind: mount.kind,
                path: entry.path,
                title: entry.name,
                isArchive: false,
                size: 0,
                pickcode115: entry.pickcode115
              )
            ],
            shuffle: false,
            includeSubfolders: true,
            openFullscreen: true
          )
        }
      } label: {
        Label("顺序播放此文件夹音乐", systemImage: "opticaldisc.fill")
      }
      Button {
        let mount = appState.storageMounts.first(where: { $0.id == entry.mountId }) ?? appState.activeStorageMount
        appState.toggleSavedMusicFolder(
          TvSavedMusicFolderItem(
            mountId: mount.id,
            mountName: mount.name,
            sourceKind: mount.kind,
            path: entry.path,
            title: entry.name,
            isArchive: false,
            size: 0,
            pickcode115: entry.pickcode115
          )
        )
      } label: {
        Label(
          appState.isMusicFolderSaved(mountId: entry.mountId, path: entry.path) ? "移除常用音乐源" : "存为音乐播放器常用目录",
          systemImage: "star.fill"
        )
      }
    } else {
      if entry.isStreamableMusicArchive {
        Button {
          appState.activeArchiveMusicBrowserEntry = entry
        } label: {
          Label("浏览 / 播放压缩包内音乐", systemImage: "doc.zipper")
        }
        Button {
          Task {
            _ = await appState.playArchiveMusic(archiveEntry: entry, shuffle: true, openFullscreen: true)
          }
        } label: {
          Label("随机播放压缩包内音乐", systemImage: "shuffle")
        }
      }
      if entry.isAudio {
        Button {
          appState.playCloudMusicFromDirectory(entry, openFullscreen: true)
        } label: {
          Label("黑胶音乐厅播放", systemImage: "opticaldisc.fill")
        }
        Button {
          appState.playCloudMusicFromDirectory(entry, openFullscreen: false)
          appState.showToast("🎵 已在顶部常驻音乐栏后台播放：\(entry.name)")
        } label: {
          Label("常驻音乐栏后台播放 (边听边逛)", systemImage: "waveform.circle.fill")
        }
        Button {
          appState.addCloudMusicToQueue(entry, playNext: true)
          appState.showToast("⏭️ 已设为下一首播放：\(entry.name)")
        } label: {
          Label("设为下一首播放", systemImage: "text.insert")
        }
        Button {
          appState.addCloudMusicToQueue(entry, playNext: false)
          appState.showToast("➕ 已加入音乐播放队列：\(entry.name)")
        } label: {
          Label("加入音乐播放队列", systemImage: "text.badge.plus")
        }
      } else if entry.isPlayableVideo {
        Button {
          appState.playMediaFile(entry)
        } label: {
          Label("立即播放", systemImage: "play.fill")
        }
      }
      if entry.isImage {
        Button {
          openImagePreview(entry)
        } label: {
          Label("全屏预览图片", systemImage: "photo.fill")
        }
      }
      if entry.isTextPreviewable {
        Button {
          openTextPreview(entry)
        } label: {
          Label("预览文本 / 字幕内容", systemImage: "doc.text.fill")
        }
      }

      if entry.sourceKind != .localCache {
        Button {
          appState.startDownloadFileWithProgress(entry)
        } label: {
          Label("下载到 Apple TV 本机缓存 (显示进度)", systemImage: "arrow.down.circle.fill")
        }
      }

      if entry.sourceKind == .server {
        Button {
          appState.startUploadServerFileTo115WithProgress(entry)
        } label: {
          Label("上传到 115 网盘 (显示进度)", systemImage: "icloud.and.arrow.up.fill")
        }
        if !entry.isMp4 && entry.isVideo {
          Button {
            Task {
              try? await appState.api.convertFileToMp4(path: entry.path)
              appState.showToast("已提交后台无损转封装 MP4：\(entry.name)")
            }
          } label: {
            Label("无损转封装为 MP4", systemImage: "film.stack")
          }
        }
      }

      // Cross-mount upload to any mounted AList / WebDAV / Server
      ForEach(appState.storageMounts.filter { $0.id != entry.mountId && ($0.kind == .alist || $0.kind == .webdav || $0.kind == .server) }) { targetMount in
        Button {
          appState.startCrossMountUploadWithProgress(
            entry: entry,
            targetMount: targetMount,
            targetDir: targetMount.rootPath
          )
        } label: {
          Label("上传至「\(targetMount.name)」(显示进度)", systemImage: "arrow.up.doc.fill")
        }
      }
    }

    Button {
      renameInputText = entry.name
      renamingEntry = entry
    } label: {
      Label("重命名", systemImage: "pencil")
    }

    Button {
      appState.setClipboard(entries: [entry], operation: .copy)
    } label: {
      Label("复制", systemImage: "doc.on.doc")
    }

    Button {
      appState.setClipboard(entries: [entry], operation: .move)
    } label: {
      Label("剪切 / 移动", systemImage: "folder.badge.gearshape")
    }

    Button {
      actionSheetEntry = entry
    } label: {
      Label("更多属性与操作...", systemImage: "info.circle")
    }

    Button(role: .destructive) {
      Task { await appState.deleteEntriesInActiveMount([entry]) }
    } label: {
      Label("删除", systemImage: "trash.fill")
    }
  }

  // MARK: - Modal Dialogs

  @ViewBuilder
  private func mountEditorModal(theme: TvThemePalette) -> some View {
    ZStack {
      TvAmbientBackdropView(imageUrl: appState.ambientBackdropUrl)
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Label(
            editingMount == nil ? "挂载远程存储 (AList / OpenList / WebDAV)" : "编辑远程存储：\(editingMount?.name ?? "")",
            systemImage: "externaldrive.badge.wifi"
          )
          .font(.system(size: 22, weight: .bold))
          Spacer()
          Button("关闭") {
            showMountModal = false
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))
        }

        HStack(spacing: 12) {
          Text("协议类型：")
            .font(.system(size: 15, weight: .semibold))
          ForEach([TvStorageSourceKind.alist, TvStorageSourceKind.webdav], id: \.self) { k in
            Button {
              mountKind = k
              if mountUrlInput.isEmpty || mountUrlInput == "http://192.168.1.10:5244" || mountUrlInput == "http://192.168.1.10:5244/dav" {
                mountUrlInput = k == .alist ? "http://192.168.1.10:5244" : "http://192.168.1.10:5244/dav"
              }
            } label: {
              Label(k.title, systemImage: k.icon)
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: mountKind == k, compact: true))
            .focused($modalInitialFocus, equals: k == mountKind ? "mount_primary" : nil)
          }
        }

        VStack(alignment: .leading, spacing: 10) {
          TextField("显示名称（例如：家庭 AList / NAS WebDAV / CloudDrive2）", text: $mountNameInput)
            .font(.system(size: 16))
          TextField(
            mountKind == .alist
              ? "AList / OpenList 地址（例如 http://192.168.1.10:5244）"
              : "WebDAV 完整地址（例如 http://192.168.1.10:5244/dav）",
            text: $mountUrlInput
          )
          .font(.system(size: 16))

          HStack(spacing: 14) {
            TextField("用户名（选填，游客留空）", text: $mountUserInput)
              .font(.system(size: 16))
            SecureField("密码（选填）", text: $mountPassInput)
              .font(.system(size: 16))
          }

          HStack(spacing: 14) {
            TextField("默认起始路径（默认 /）", text: $mountRootPathInput)
              .font(.system(size: 16))
            if mountKind == .alist {
              TextField("AList Token（选填，已填账号密码可留空）", text: $mountTokenInput)
                .font(.system(size: 16))
            }
          }
        }

        Text("💡 提示：也可以点击右上角「上传文件」用手机扫码，在手机网页上一键粘贴挂载 AList 或 WebDAV！")
          .font(.system(size: 13))
          .foregroundColor(.white.opacity(0.65))

        HStack(spacing: 16) {
          Button {
            guard !mountUrlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
              appState.showToast("请输入服务器地址")
              return
            }
            let saved = appState.upsertStorageMount(
              id: editingMount?.id,
              name: mountNameInput,
              kind: mountKind,
              baseUrl: mountUrlInput,
              username: mountUserInput,
              password: mountPassInput,
              token: mountTokenInput,
              rootPath: mountRootPathInput
            )
            showMountModal = false
            appState.switchStorageMount(saved.id)
          } label: {
            Label("保存并立即打开", systemImage: "checkmark.circle.fill")
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
          .focused($modalInitialFocus, equals: "mount_save")

          if let edit = editingMount, !edit.isBuiltIn {
            Button(role: .destructive) {
              appState.deleteStorageMount(edit.id)
              showMountModal = false
            } label: {
              Label("卸载此存储", systemImage: "trash.fill")
            }
            .buttonStyle(TvApplePillButtonStyle(isDestructive: true))
          }
        }
      }
      .padding(32)
      .frame(width: 920)
      .background(.regularMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
      .focusSection()
    }
    .onAppear {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
        modalInitialFocus = "mount_save"
      }
    }
    .onExitCommand {
      showMountModal = false
    }
  }

  @ViewBuilder
  private func lanUploadPortalModal(theme: TvThemePalette) -> some View {
    let mount = appState.activeStorageMount
    let curDir = appState.fileListing.path.isEmpty ? mount.rootPath : appState.fileListing.path
    let portalUrl = appState.lanInputUrl.isEmpty ? "http://\(TvAppState.localLanIPv4Address() ?? "127.0.0.1"):18088" : appState.lanInputUrl

    ZStack {
      TvAmbientBackdropView(imageUrl: appState.ambientBackdropUrl)
      HStack(spacing: 32) {
        TvQRCodeImageView(content: portalUrl, size: 220)

        VStack(alignment: .leading, spacing: 14) {
          Label("局域网手机 / 电脑文件上传与下载中心", systemImage: "arrow.up.and.down.square.fill")
            .font(.system(size: 23, weight: .bold))
            .foregroundColor(theme.accentHover)

          Text("1. 使用手机相机/微信扫码，或在电脑浏览器打开：")
            .font(.system(size: 15))
            .foregroundColor(.white.opacity(0.8))

          Text(portalUrl)
            .font(.system(size: 20, weight: .heavy, design: .monospaced))
            .foregroundColor(.yellow)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))

          Text("2. 网页已绑定当前打开的存储与目录：\(mount.name) → \(curDir.isEmpty ? "/" : curDir)")
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white.opacity(0.9))

          Text("3. 选择或拖拽多个文件上传时，手机/电脑端与 Apple TV 屏幕均会实时显示上传进度条、速度 (MB/s) 与已传字节；同时支持将当前目录文件直接下载到手机或电脑！")
            .font(.system(size: 13))
            .foregroundColor(.white.opacity(0.65))
            .fixedSize(horizontal: false, vertical: true)

          if let topTask = appState.primaryActiveTransferTask {
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text("\(topTask.direction.label)进度：\(topTask.name)")
                  .font(.system(size: 14, weight: .bold))
                Spacer()
                Text("\(topTask.percentText) · \(topTask.formattedSpeed)")
                  .font(.system(size: 14, weight: .bold, design: .monospaced))
                  .foregroundColor(theme.accentHover)
              }
              ProgressView(value: topTask.progress)
            }
            .padding(12)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
          }

          HStack(spacing: 14) {
            Button("关闭窗口（后台保持接收上传）") {
              showLanUploadSheet = false
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
            .focused($modalInitialFocus, equals: "lan_close")

            Button("查看传输进度列表") {
              showLanUploadSheet = false
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                showTransferDrawer = true
              }
            }
            .buttonStyle(TvApplePillButtonStyle())
          }
        }
      }
      .padding(34)
      .frame(width: 980)
      .background(.regularMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
      .focusSection()
    }
    .onAppear {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
        modalInitialFocus = "lan_close"
      }
    }
    .onExitCommand {
      showLanUploadSheet = false
    }
  }

  @ViewBuilder
  private func transferCenterModal(theme: TvThemePalette) -> some View {
    ZStack {
      TvAmbientBackdropView(imageUrl: appState.ambientBackdropUrl)
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          Label("文件上传与下载进度中心 (\(appState.fileTransferTasks.count))", systemImage: "arrow.up.arrow.down.circle.fill")
            .font(.system(size: 22, weight: .bold))
          Spacer()
          if !appState.fileTransferTasks.isEmpty {
            Button("清理已完成记录") {
              appState.clearCompletedFileTransfers()
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
          }
          Button("关闭") {
            showTransferDrawer = false
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
          .focused($modalInitialFocus, equals: "transfer_close")
        }

        if appState.fileTransferTasks.isEmpty {
          VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
              .font(.system(size: 42))
              .foregroundColor(.white.opacity(0.4))
            Text("当前暂无上传或下载任务")
              .font(.system(size: 17, weight: .semibold))
              .foregroundColor(.white.opacity(0.7))
          }
          .frame(maxWidth: .infinity, minHeight: 280)
        } else {
          ScrollView {
            VStack(spacing: 12) {
              ForEach(appState.fileTransferTasks) { task in
                VStack(alignment: .leading, spacing: 10) {
                  HStack(spacing: 12) {
                    Image(systemName: task.direction.icon)
                      .font(.system(size: 22, weight: .bold))
                      .foregroundColor(
                        task.status == .completed
                          ? .green
                          : (task.status == .failed ? .red : theme.accentHover)
                      )

                    VStack(alignment: .leading, spacing: 2) {
                      HStack(spacing: 8) {
                        Text("[\(task.direction.label)] \(task.name)")
                          .font(.system(size: 16, weight: .bold))
                          .lineLimit(1)
                        Text(task.status.label)
                          .font(.system(size: 11, weight: .bold))
                          .padding(.horizontal, 8)
                          .padding(.vertical, 2)
                          .background(Color.white.opacity(0.14))
                          .clipShape(Capsule())
                      }
                      Text("\(task.sourceLabel) → \(task.targetLabel) · \(task.detailMessage)")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.68))
                        .lineLimit(1)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                      Text(task.percentText)
                        .font(.system(size: 18, weight: .heavy, design: .monospaced))
                        .foregroundColor(theme.accentHover)
                      Text("\(task.formattedBytesProgress) · \(task.formattedSpeed)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                    }

                    if task.status == .running {
                      Button("取消") {
                        appState.cancelFileTransfer(id: task.id)
                      }
                      .buttonStyle(TvApplePillButtonStyle(isDestructive: true, compact: true))
                    } else if let savedPath = task.localSavedPath, task.status == .completed {
                      Button("立即打开") {
                        showTransferDrawer = false
                        appState.switchStorageMount("builtin_local")
                        Task {
                          await appState.loadFiles(path: TvRemoteStorageClient.parentPath(of: savedPath))
                        }
                      }
                      .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
                    }
                  }

                  GeometryReader { geo in
                    ZStack(alignment: .leading) {
                      Capsule()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 8)
                      Capsule()
                        .fill(
                          task.status == .failed
                            ? Color.red
                            : (task.status == .completed ? Color.green : theme.accentHover)
                        )
                        .frame(width: max(8, geo.size.width * task.progress), height: 8)
                    }
                  }
                  .frame(height: 8)
                }
                .padding(16)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
              }
            }
          }
          .frame(maxHeight: 500)
        }
      }
      .padding(32)
      .frame(width: 980)
      .background(.regularMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
      .focusSection()
    }
    .onAppear {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
        modalInitialFocus = "transfer_close"
      }
    }
    .onExitCommand {
      showTransferDrawer = false
    }
  }

  @ViewBuilder
  private func remoteDownloadModal(theme: TvThemePalette) -> some View {
    ZStack {
      TvAmbientBackdropView(imageUrl: appState.ambientBackdropUrl)
      VStack(alignment: .leading, spacing: 16) {
        Label("新建远程链接离线下载 (支持 HTTP / M3U8 / Magnet 磁力链)", systemImage: "arrow.down.doc.fill")
          .font(.system(size: 21, weight: .bold))
        TextField("粘贴下载链接 (https://... 或 .m3u8 或 magnet:?xt=...)", text: $remoteDownloadUrlInput)
          .font(.system(size: 16))
        TextField("保存文件名（选填，留空自动识别）", text: $remoteDownloadNameInput)
          .font(.system(size: 16))
        HStack(spacing: 14) {
          Button {
            guard !remoteDownloadUrlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            appState.startRemoteUrlDownloadToServerWithProgress(
              url: remoteDownloadUrlInput,
              customName: remoteDownloadNameInput
            )
            showRemoteDownloadModal = false
          } label: {
            Label("开始下载并显示实时进度", systemImage: "arrow.down.circle.fill")
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
          .focused($modalInitialFocus, equals: "remote_dl_start")

          Button("取消") {
            showRemoteDownloadModal = false
          }
          .buttonStyle(TvApplePillButtonStyle())
        }
      }
      .padding(32)
      .frame(width: 820)
      .background(.regularMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
      .focusSection()
    }
    .onAppear {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
        modalInitialFocus = "remote_dl_start"
      }
    }
    .onExitCommand {
      showRemoteDownloadModal = false
    }
  }

  @ViewBuilder
  private func newFolderModal(theme: TvThemePalette) -> some View {
    ZStack {
      TvAmbientBackdropView(imageUrl: appState.ambientBackdropUrl)
      VStack(alignment: .leading, spacing: 16) {
        Label("在「\(appState.activeStorageMount.name)」当前目录新建文件夹", systemImage: "folder.badge.plus")
          .font(.system(size: 21, weight: .bold))
        TextField("输入新文件夹名称", text: $newFolderNameInput)
          .font(.system(size: 16))
        HStack(spacing: 14) {
          Button {
            let name = newFolderNameInput
            showNewFolderModal = false
            Task { await appState.createFolderInActiveMount(name: name) }
          } label: {
            Label("立即创建", systemImage: "checkmark.circle.fill")
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
          .focused($modalInitialFocus, equals: "mkdir_confirm")

          Button("取消") {
            showNewFolderModal = false
          }
          .buttonStyle(TvApplePillButtonStyle())
        }
      }
      .padding(32)
      .frame(width: 720)
      .background(.regularMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
      .focusSection()
    }
    .onAppear {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
        modalInitialFocus = "mkdir_confirm"
      }
    }
    .onExitCommand {
      showNewFolderModal = false
    }
  }

  @ViewBuilder
  private func renameModal(entry: TvFileEntry, theme: TvThemePalette) -> some View {
    ZStack {
      TvAmbientBackdropView(imageUrl: appState.ambientBackdropUrl)
      VStack(alignment: .leading, spacing: 16) {
        Label("重命名：\(entry.name)", systemImage: "pencil.circle.fill")
          .font(.system(size: 21, weight: .bold))
        TextField("输入新名称", text: $renameInputText)
          .font(.system(size: 16))
        HStack(spacing: 14) {
          Button {
            let target = entry
            let newName = renameInputText
            renamingEntry = nil
            Task { await appState.renameEntryInActiveMount(target, newName: newName) }
          } label: {
            Label("保存修改", systemImage: "checkmark.circle.fill")
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
          .focused($modalInitialFocus, equals: "rename_confirm")

          Button("取消") {
            renamingEntry = nil
          }
          .buttonStyle(TvApplePillButtonStyle())
        }
      }
      .padding(32)
      .frame(width: 720)
      .background(.regularMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
      .focusSection()
    }
    .onAppear {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
        modalInitialFocus = "rename_confirm"
      }
    }
    .onExitCommand {
      renamingEntry = nil
    }
  }

  @ViewBuilder
  private func fileActionSheetModal(entry: TvFileEntry, theme: TvThemePalette) -> some View {
    ZStack {
      TvAmbientBackdropView(imageUrl: appState.ambientBackdropUrl)
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 14) {
          Image(systemName: entry.iconName)
            .font(.system(size: 32))
            .foregroundColor(iconColor(for: entry, theme: theme))
          VStack(alignment: .leading, spacing: 4) {
            Text(entry.name)
              .font(.system(size: 20, weight: .bold))
              .lineLimit(2)
            Text("大小：\(entry.formattedSize) · 修改时间：\(entry.modTime.isEmpty ? "--" : entry.modTime) · 路径：\(entry.path)")
              .font(.system(size: 13, design: .monospaced))
              .foregroundColor(.white.opacity(0.65))
              .lineLimit(1)
          }
          Spacer()
          Button("关闭") {
            actionSheetEntry = nil
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))
          .focused($modalInitialFocus, equals: "action_close")
        }

        Divider().background(Color.white.opacity(0.15))

        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
          if entry.isDir {
            Button {
              let target = entry
              actionSheetEntry = nil
              let mount = appState.storageMounts.first(where: { $0.id == target.mountId }) ?? appState.activeStorageMount
              Task {
                _ = await appState.scanAndPlayMusicFoldersOrArchives(
                  sources: [
                    TvSavedMusicFolderItem(
                      mountId: mount.id,
                      mountName: mount.name,
                      sourceKind: mount.kind,
                      path: target.path,
                      title: target.name,
                      isArchive: false,
                      size: 0,
                      pickcode115: target.pickcode115
                    )
                  ],
                  shuffle: true,
                  includeSubfolders: true,
                  openFullscreen: true
                )
              }
            } label: {
              Label("随机播放文件夹音乐 (含子目录/压缩包)", systemImage: "shuffle")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
            .focused($modalInitialFocus, equals: "action_primary")

            Button {
              let target = entry
              actionSheetEntry = nil
              let mount = appState.storageMounts.first(where: { $0.id == target.mountId }) ?? appState.activeStorageMount
              appState.toggleSavedMusicFolder(
                TvSavedMusicFolderItem(
                  mountId: mount.id,
                  mountName: mount.name,
                  sourceKind: mount.kind,
                  path: target.path,
                  title: target.name,
                  isArchive: false,
                  size: 0,
                  pickcode115: target.pickcode115
                )
              )
            } label: {
              Label("存为常用音乐源", systemImage: "star.fill")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TvApplePillButtonStyle())
          }

          if entry.isStreamableMusicArchive {
            Button {
              let target = entry
              actionSheetEntry = nil
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                appState.activeArchiveMusicBrowserEntry = target
              }
            } label: {
              Label("浏览/播放压缩包内音乐", systemImage: "doc.zipper")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
            .focused($modalInitialFocus, equals: "action_primary")

            Button {
              let target = entry
              actionSheetEntry = nil
              Task {
                _ = await appState.playArchiveMusic(archiveEntry: target, shuffle: true, openFullscreen: true)
              }
            } label: {
              Label("随机播放压缩包内音乐", systemImage: "shuffle")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TvApplePillButtonStyle())
          }

          if entry.isAudio {
            Button {
              let target = entry
              actionSheetEntry = nil
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                appState.playCloudMusicFromDirectory(target, openFullscreen: true)
              }
            } label: {
              Label("黑胶音乐厅播放", systemImage: "opticaldisc.fill")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
            .focused($modalInitialFocus, equals: "action_primary")

            Button {
              let target = entry
              actionSheetEntry = nil
              appState.playCloudMusicFromDirectory(target, openFullscreen: false)
              appState.showToast("🎵 已在音乐栏后台播放：\(target.name)")
            } label: {
              Label("常驻音乐栏后台播放", systemImage: "waveform.circle.fill")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TvApplePillButtonStyle())

            Button {
              let target = entry
              actionSheetEntry = nil
              appState.addCloudMusicToQueue(target, playNext: true)
              appState.showToast("⏭️ 已设为下一首播放：\(target.name)")
            } label: {
              Label("设为下一首播放", systemImage: "text.insert")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TvApplePillButtonStyle())

            Button {
              let target = entry
              actionSheetEntry = nil
              appState.addCloudMusicToQueue(target, playNext: false)
              appState.showToast("➕ 已加入音乐播放队列：\(target.name)")
            } label: {
              Label("加入音乐播放队列", systemImage: "text.badge.plus")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TvApplePillButtonStyle())
          } else if entry.isPlayableVideo {
            Button {
              let target = entry
              actionSheetEntry = nil
              appState.playMediaFile(target)
            } label: {
              Label("立即播放音视频", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
            .focused($modalInitialFocus, equals: "action_primary")
          }

          if entry.isImage {
            Button {
              let target = entry
              actionSheetEntry = nil
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                openImagePreview(target)
              }
            } label: {
              Label("全屏查看图片", systemImage: "photo.fill")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
            .focused($modalInitialFocus, equals: "action_primary")
          }

          if entry.isTextPreviewable {
            Button {
              let target = entry
              actionSheetEntry = nil
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                openTextPreview(target)
              }
            } label: {
              Label("查看文本 / 字幕内容", systemImage: "doc.text.fill")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
            .focused($modalInitialFocus, equals: "action_primary")
          }

          if !entry.isDir && entry.sourceKind != .localCache {
            Button {
              let target = entry
              actionSheetEntry = nil
              appState.startDownloadFileWithProgress(target)
            } label: {
              Label("下载到 Apple TV 本机 (显示进度)", systemImage: "arrow.down.circle.fill")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: !entry.isPlayableVideo))
          }

          if !entry.isDir && entry.sourceKind == .server {
            Button {
              let target = entry
              actionSheetEntry = nil
              appState.startUploadServerFileTo115WithProgress(target)
            } label: {
              Label("上传至 115 网盘 (显示进度)", systemImage: "icloud.and.arrow.up.fill")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TvApplePillButtonStyle())

            if !entry.isMp4 && entry.isVideo {
              Button {
                let target = entry
                actionSheetEntry = nil
                Task {
                  try? await appState.api.convertFileToMp4(path: target.path)
                  appState.showToast("已提交后台 MP4 转码：\(target.name)")
                }
              } label: {
                Label("无损转封装为 MP4", systemImage: "film.stack")
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(TvApplePillButtonStyle())
            }
          }

          ForEach(appState.storageMounts.filter { $0.id != entry.mountId && ($0.kind == .alist || $0.kind == .webdav || $0.kind == .server) }) { targetMount in
            if !entry.isDir {
              Button {
                let target = entry
                actionSheetEntry = nil
                appState.startCrossMountUploadWithProgress(
                  entry: target,
                  targetMount: targetMount,
                  targetDir: targetMount.rootPath
                )
              } label: {
                Label("上传至「\(targetMount.name)」(显示进度)", systemImage: "arrow.up.doc.fill")
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(TvApplePillButtonStyle())
            }
          }

          Button {
            let target = entry
            renameInputText = target.name
            actionSheetEntry = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
              renamingEntry = target
            }
          } label: {
            Label("重命名", systemImage: "pencil")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(TvApplePillButtonStyle())

          Button {
            let target = entry
            actionSheetEntry = nil
            appState.setClipboard(entries: [target], operation: .copy)
          } label: {
            Label("复制", systemImage: "doc.on.doc")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(TvApplePillButtonStyle())

          Button {
            let target = entry
            actionSheetEntry = nil
            appState.setClipboard(entries: [target], operation: .move)
          } label: {
            Label("剪切 / 移动", systemImage: "folder.badge.gearshape")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(TvApplePillButtonStyle())

          Button(role: .destructive) {
            let target = entry
            actionSheetEntry = nil
            Task { await appState.deleteEntriesInActiveMount([target]) }
          } label: {
            Label("永久删除", systemImage: "trash.fill")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(TvApplePillButtonStyle(isDestructive: true))
        }
      }
      .padding(32)
      .frame(width: 880)
      .background(.regularMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
      .focusSection()
    }
    .onAppear {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
        if entry.isPlayableVideo || entry.isImage || entry.isTextPreviewable {
          modalInitialFocus = "action_primary"
        } else {
          modalInitialFocus = "action_close"
        }
      }
    }
    .onExitCommand {
      actionSheetEntry = nil
    }
  }

  @ViewBuilder
  private func imagePreviewModal(entry: TvFileEntry, theme: TvThemePalette) -> some View {
    let imageSiblings = filteredAndSortedEntries.filter { $0.isImage }
    let currentImageIndex = imageSiblings.firstIndex(where: { $0.id == entry.id })
    ZStack {
      Color.black.ignoresSafeArea()

      // Full-screen 1920x1080 canvas
      Group {
        if let uiImg = imagePreviewUiImage {
          GeometryReader { geo in
            Group {
              if imagePreviewFillScreen {
                Image(uiImage: uiImg)
                  .resizable()
                  .interpolation(.high)
                  .scaledToFill()
                  .frame(width: geo.size.width, height: geo.size.height)
                  .scaleEffect(imagePreviewZoomScale)
                  .clipped()
              } else {
                Image(uiImage: uiImg)
                  .resizable()
                  .interpolation(.high)
                  .scaledToFit()
                  .frame(width: geo.size.width, height: geo.size.height)
                  .scaleEffect(imagePreviewZoomScale)
              }
            }
            .frame(width: geo.size.width, height: geo.size.height)
          }
          .ignoresSafeArea()
        } else if isLoadingImagePreview {
          VStack(spacing: 16) {
            ProgressView()
              .scaleEffect(1.4)
            Text("正在加载高清原图...")
              .font(.system(size: 20, weight: .semibold))
              .foregroundColor(.white.opacity(0.85))
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !imagePreviewResolvedUrl.isEmpty, let u = URL(string: imagePreviewResolvedUrl) {
          GeometryReader { geo in
            AsyncImage(url: u) { phase in
              switch phase {
              case .success(let image):
                if imagePreviewFillScreen {
                  image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(imagePreviewZoomScale)
                    .clipped()
                } else {
                  image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(imagePreviewZoomScale)
                }
              case .failure:
                Text("图片加载失败")
                  .font(.system(size: 22, weight: .bold))
                  .foregroundColor(.red)
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
              default:
                ProgressView("正在加载高清原图...")
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
              }
            }
          }
          .ignoresSafeArea()
        } else {
          Text("无法读取图片数据")
            .font(.system(size: 22, weight: .bold))
            .foregroundColor(.red)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }

      // Floating top control bar
      VStack {
        if imagePreviewShowHeader {
          HStack(spacing: 12) {
            Image(systemName: "photo.fill")
              .font(.system(size: 18, weight: .bold))
              .foregroundColor(theme.accent)
            Text(entry.name)
              .font(.system(size: 18, weight: .bold))
              .foregroundColor(.white)
              .lineLimit(1)
            if let uiImg = imagePreviewUiImage {
              Text("\(Int(uiImg.size.width * uiImg.scale))×\(Int(uiImg.size.height * uiImg.scale))")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            if let idx = currentImageIndex, imageSiblings.count > 1 {
              Text("\(idx + 1)/\(imageSiblings.count)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.75))
            }
            Text(entry.formattedSize)
              .font(.system(size: 13, design: .monospaced))
              .foregroundColor(.white.opacity(0.6))

            Spacer()

            if imageSiblings.count > 1 {
              Button {
                switchImagePreview(offset: -1)
              } label: {
                Label("上一张", systemImage: "chevron.left")
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))

              Button {
                switchImagePreview(offset: 1)
              } label: {
                Label("下一张", systemImage: "chevron.right")
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))
            }

            Button {
              withAnimation(.easeInOut(duration: 0.18)) {
                imagePreviewFillScreen.toggle()
              }
            } label: {
              Label(
                imagePreviewFillScreen ? "适应屏幕" : "铺满全屏",
                systemImage: imagePreviewFillScreen
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right"
              )
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))

            Button {
              withAnimation(.easeInOut(duration: 0.18)) {
                if imagePreviewZoomScale < 1.4 {
                  imagePreviewZoomScale = 1.5
                } else if imagePreviewZoomScale < 1.9 {
                  imagePreviewZoomScale = 2.0
                } else if imagePreviewZoomScale < 2.9 {
                  imagePreviewZoomScale = 3.0
                } else {
                  imagePreviewZoomScale = 1.0
                }
              }
            } label: {
              Label(
                String(format: "%.1fx 缩放", imagePreviewZoomScale),
                systemImage: "plus.magnifyingglass"
              )
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))

            Button {
              withAnimation(.easeInOut(duration: 0.18)) {
                imagePreviewShowHeader = false
              }
            } label: {
              Label("隐藏顶栏", systemImage: "eye.slash")
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))

            if entry.sourceKind != .localCache {
              Button {
                appState.startDownloadFileWithProgress(entry)
              } label: {
                Label("下载", systemImage: "arrow.down.circle.fill")
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))
            }

            Button("关闭") {
              imagePreviewEntry = nil
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
            .focused($modalInitialFocus, equals: "img_close")
          }
          .padding(.horizontal, 26)
          .padding(.vertical, 14)
          .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
              .fill(Color.black.opacity(0.68))
              .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                  .stroke(Color.white.opacity(0.16), lineWidth: 1)
              )
          )
          .padding(.horizontal, 32)
          .padding(.top, 20)
        } else {
          HStack {
            Spacer()
            Button {
              withAnimation(.easeInOut(duration: 0.18)) {
                imagePreviewShowHeader = true
              }
            } label: {
              Label("显示控制栏", systemImage: "eye")
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
            .focused($modalInitialFocus, equals: "img_close")
          }
          .padding(.horizontal, 32)
          .padding(.top, 20)
        }
        Spacer()
      }
      .focusSection()
    }
    .onAppear {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
        modalInitialFocus = "img_close"
      }
    }
    .onPlayPauseCommand {
      withAnimation(.easeInOut(duration: 0.18)) {
        imagePreviewShowHeader.toggle()
      }
    }
    .onExitCommand {
      imagePreviewEntry = nil
    }
  }

  @ViewBuilder
  private func textPreviewModal(entry: TvFileEntry, theme: TvThemePalette) -> some View {
    ZStack {
      TvAmbientBackdropView(imageUrl: appState.ambientBackdropUrl)
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Label(entry.name, systemImage: "doc.text.fill")
            .font(.system(size: 21, weight: .bold))
          Text(entry.formattedSize)
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(.white.opacity(0.6))
          Spacer()
          if entry.sourceKind != .localCache {
            Button {
              appState.startDownloadFileWithProgress(entry)
            } label: {
              Label("下载到本机", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
          }
          Button("关闭") {
            textPreviewEntry = nil
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
          .focused($modalInitialFocus, equals: "txt_close")
        }

        if isLoadingTextPreview {
          ProgressView("正在读取文件内容...")
            .frame(maxWidth: .infinity, minHeight: 460)
        } else {
          ScrollView {
            Text(textPreviewContent.isEmpty ? "(空文件)" : textPreviewContent)
              .font(.system(size: 15, design: .monospaced))
              .foregroundColor(.white.opacity(0.92))
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(20)
          }
          .frame(maxHeight: 680)
          .background(Color.black.opacity(0.45))
          .clipShape(RoundedRectangle(cornerRadius: 16))
        }
      }
      .padding(34)
      .frame(width: 1320)
      .background(.regularMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
      .focusSection()
    }
    .onAppear {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
        modalInitialFocus = "txt_close"
      }
    }
    .onExitCommand {
      textPreviewEntry = nil
    }
  }
}

// MARK: - 7. Proxy, Multi-Subscription & Scenario Routing Section View (1:1 Match with ProxyServerScreen in lib/ui/screens/proxy_server_screen.dart)

struct TvProxySectionView: View {
  @EnvironmentObject var appState: TvAppState

  // 3 Sub-Navigation Tabs: 0 = 订阅与代理节点, 1 = 分场景路由策略 (6), 2 = 服务端代理监听 (/api/proxy)
  @State private var activeTabIndex: Int = 0

  // Filters & Sorting for Proxy Node Pool
  @State private var selectedSubFilterId: String = "all"
  @State private var categoryFilter: String = "全部"
  @State private var sortMode: String = "latency" // latency, name, default

  // Modals / Sheets
  @State private var showSubEditorSheet: Bool = false
  @State private var editingSubscription: TvProxySubscription? = nil
  @State private var subNameDraft: String = ""
  @State private var subUrlDraft: String = ""
  @State private var subEnabledDraft: Bool = true

  @State private var showPasteNodesSheet: Bool = false
  @State private var pasteNodesDraft: String = ""

  @State private var showAddManualNodeSheet: Bool = false
  @State private var manualNodeName: String = ""
  @State private var manualNodeProto: String = "SOCKS5"
  @State private var manualNodeHost: String = ""
  @State private var manualNodePort: String = "1080"

  @State private var showQrScanSheet: Bool = false
  @State private var pickingNodeForScenario: TvRequestScenario? = nil

  @FocusState private var focusedProxyTop: Bool

  private let regionAndProtoFilters = [
    "全部", "★ 收藏", "🇭🇰 香港", "🇹🇼 台湾", "🇯🇵 日本", "🇸🇬 新加坡", "🇺🇸 美国",
    "VMESS", "VLESS", "SS", "TROJAN", "HY2", "SOCKS5", "HTTP"
  ]

  private var filteredAndSortedNodes: [TvSubscriptionNode] {
    let filtered = appState.subscriptionNodes.filter { n in
      if selectedSubFilterId != "all" && n.subscriptionId != selectedSubFilterId {
        return false
      }
      switch categoryFilter {
      case "全部":
        return true
      case "★ 收藏":
        return n.favorite
      case "🇭🇰 香港":
        return n.regionCategory == "香港"
      case "🇹🇼 台湾":
        return n.regionCategory == "台湾"
      case "🇯🇵 日本":
        return n.regionCategory == "日本"
      case "🇸🇬 新加坡":
        return n.regionCategory == "新加坡"
      case "🇺🇸 美国":
        return n.regionCategory == "美国"
      default:
        return n.type.uppercased() == categoryFilter.uppercased()
      }
    }

    switch sortMode {
    case "name":
      return filtered.sorted { a, b in
        if a.favorite != b.favorite { return a.favorite && !b.favorite }
        return a.name.localizedCompare(b.name) == .orderedAscending
      }
    case "default":
      return filtered
    default:
      return filtered.sorted { a, b in
        if a.favorite != b.favorite { return a.favorite && !b.favorite }
        return (a.latencyMs ?? 9999) < (b.latencyMs ?? 9999)
      }
    }
  }

  var body: some View {
    let theme = appState.activeTheme
    let activeNode = appState.activeProxyNode
    let fastestId = appState.fastestProxyNode?.id

    ScrollViewReader { scrollProxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          // 1. Top Global Proxy Control Bar (Matches _buildTopGlobalProxyBar in proxy_server_screen.dart)
          topGlobalProxyBar(theme: theme, activeNode: activeNode)
            .id("proxy_top_anchor")

          // 2. 3-Tab Sub-Navigation Bar (Matches _buildSubNavigationBar in proxy_server_screen.dart)
          subNavigationBar(theme: theme)

          // 3. Active Tab Content
          if activeTabIndex == 0 {
            subscriptionsAndNodesTab(theme: theme, activeNode: activeNode, fastestId: fastestId)
          } else if activeTabIndex == 1 {
            scenarioRoutingTab(theme: theme)
          } else {
            backendProxyServicesTab(theme: theme)
          }
        }
        .padding(.horizontal, 52)
        .padding(.vertical, 18)
      }
      .onChange(of: appState.pageScrollToTopTrigger) { _ in
        focusedProxyTop = true
        withAnimation(.easeInOut(duration: 0.25)) {
          scrollProxy.scrollTo("proxy_top_anchor", anchor: .top)
        }
      }
    }
    .sheet(isPresented: $showSubEditorSheet) {
      subscriptionEditorSheet(theme: theme)
    }
    .sheet(isPresented: $showPasteNodesSheet) {
      pasteNodesSheet(theme: theme)
    }
    .sheet(isPresented: $showAddManualNodeSheet) {
      manualNodeEditorSheet(theme: theme)
    }
    .sheet(isPresented: $showQrScanSheet) {
      qrCodeFastPushSheet(theme: theme)
    }
    .sheet(item: $pickingNodeForScenario) { sc in
      scenarioNodePickerSheet(scenario: sc, theme: theme)
    }
    .onAppear {
      appState.startLanInputServer()
      if appState.subscriptionNodes.isEmpty {
        Task { await appState.refreshAllSubscriptions(silent: true) }
      }
    }
  }

  // MARK: - 1. Top Global Proxy Control Bar

  @ViewBuilder
  private func topGlobalProxyBar(theme: TvThemePalette, activeNode: TvSubscriptionNode?) -> some View {
    HStack(spacing: 14) {
      // Global Proxy Switch Button (`代理已开启` vs `代理已关闭`)
      Button {
        appState.setProxyEnabled(!appState.proxyEnabled)
      } label: {
        HStack(spacing: 8) {
          Circle()
            .fill(appState.proxyEnabled ? Color(red: 0.19, green: 0.84, blue: 0.45) : Color.white.opacity(0.35))
            .frame(width: 9, height: 9)
          Text(appState.proxyEnabled ? "代理已开启" : "代理已关闭")
            .font(.system(size: 15, weight: .bold))
        }
      }
      .buttonStyle(TvApplePillButtonStyle(isSelected: appState.proxyEnabled, isPrimary: appState.proxyEnabled, compact: true))
      .fixedSize(horizontal: true, vertical: false)
      .focused($focusedProxyTop)

      // Active Node Status Badge (`智能防抖(自动最快) · 🇭🇰 香港 01 · 118 ms`)
      HStack(spacing: 8) {
        Text(appState.proxySelectionMode.badgeTitle)
          .font(.system(size: 11, weight: .bold))
          .foregroundColor(appState.proxySelectionMode == .autoFastest ? Color(red: 0.25, green: 0.85, blue: 0.52) : theme.accentHover)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(
            (appState.proxySelectionMode == .autoFastest ? Color(red: 0.20, green: 0.80, blue: 0.45) : theme.accent).opacity(0.18)
          )
          .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

        if let node = activeNode {
          Text(node.displayTitle)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .lineLimit(1)

          Text(node.formattedLatency)
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundColor(latencyBadgeColor(node.latencyMs))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(latencyBadgeColor(node.latencyMs).opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
          Text("未选择代理节点")
            .font(.system(size: 13))
            .foregroundColor(.white.opacity(0.55))
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.black.opacity(0.30))
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(Color.white.opacity(0.10), lineWidth: 1)
      )

      // Selection Mode Segmented Buttons (`⚡ 自动切换最快` vs `🎯 手动指定代理`)
      ForEach(TvProxySelectionMode.allCases) { mode in
        let isSelected = (appState.proxySelectionMode == mode)
        Button {
          appState.setProxySelectionMode(mode)
        } label: {
          Text(mode.label)
            .lineLimit(1)
        }
        .buttonStyle(TvApplePillButtonStyle(isSelected: isSelected, compact: true))
        .fixedSize(horizontal: true, vertical: false)
      }

      // Quick Action: Retest & Pick Fastest
      Button {
        Task { await appState.testAllNodesLatency() }
      } label: {
        Label(appState.isRefreshingSubscription ? "测速中..." : "测速选优", systemImage: "bolt.horizontal.circle.fill")
          .lineLimit(1)
      }
      .buttonStyle(TvApplePillButtonStyle(compact: true))
      .fixedSize(horizontal: true, vertical: false)

      // Quick Action: Update All Subscriptions
      Button {
        Task { await appState.refreshAllSubscriptions(silent: false) }
      } label: {
        Label("更新全部订阅", systemImage: "arrow.triangle.2.circlepath")
          .lineLimit(1)
      }
      .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
      .fixedSize(horizontal: true, vertical: false)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(Color.white.opacity(0.12), lineWidth: 1)
    )
    .focusSection()
  }

  // MARK: - 2. 3-Tab Sub-Navigation Bar

  @ViewBuilder
  private func subNavigationBar(theme: TvThemePalette) -> some View {
    HStack(spacing: 12) {
      Button {
        activeTabIndex = 0
      } label: {
        Label("订阅与代理节点 (\(appState.subscriptionNodes.count))", systemImage: "globe.asia.australia.fill")
      }
      .buttonStyle(TvApplePillButtonStyle(isSelected: activeTabIndex == 0, isPrimary: activeTabIndex == 0, compact: true))

      Button {
        activeTabIndex = 1
      } label: {
        Label("分场景路由策略 (6)", systemImage: "point.3.connected.trianglepath.dotted")
      }
      .buttonStyle(TvApplePillButtonStyle(isSelected: activeTabIndex == 1, isPrimary: activeTabIndex == 1, compact: true))

      Button {
        activeTabIndex = 2
        Task {
          let backend = await appState.api.fetchProxyConfig()
          appState.backendProxyServices = backend.services
          appState.backendProxyStatuses = backend.statuses
        }
      } label: {
        Label("服务端代理监听 (\(appState.backendProxyServices.count))", systemImage: "server.rack")
      }
      .buttonStyle(TvApplePillButtonStyle(isSelected: activeTabIndex == 2, isPrimary: activeTabIndex == 2, compact: true))

      Spacer()

      // Quick Phone QR Code Input Button
      Button {
        appState.startLanInputServer()
        showQrScanSheet = true
      } label: {
        Label("手机扫码添加多订阅", systemImage: "qrcode.viewfinder")
      }
      .buttonStyle(TvApplePillButtonStyle(compact: true))
    }
    .focusSection()
  }

  // MARK: - Tab 0: Multi-Subscription Management + Proxy Node Pool

  @ViewBuilder
  private func subscriptionsAndNodesTab(
    theme: TvThemePalette,
    activeNode: TvSubscriptionNode?,
    fastestId: String?
  ) -> some View {
    let nodes = filteredAndSortedNodes

    VStack(alignment: .leading, spacing: 18) {
      // Card A: Multi-Subscription Source Management (`代理订阅源管理`)
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 12) {
          Label("代理订阅源管理 (\(appState.subscriptions.count) 个订阅 · 支持启用多个订阅合并节点池)", systemImage: "rss")
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(.white)

          Spacer()

          Button {
            editingSubscription = nil
            subNameDraft = ""
            subUrlDraft = ""
            subEnabledDraft = true
            showSubEditorSheet = true
          } label: {
            Label("新增订阅链接", systemImage: "plus.circle.fill")
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))

          Button {
            pasteNodesDraft = ""
            showPasteNodesSheet = true
          } label: {
            Label("粘贴导入节点", systemImage: "doc.on.clipboard")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))

          Button {
            manualNodeName = ""
            manualNodeHost = ""
            manualNodePort = "1080"
            manualNodeProto = "SOCKS5"
            showAddManualNodeSheet = true
          } label: {
            Label("手动新增单节点", systemImage: "plus.square.on.square")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))

          Button {
            Task { await appState.syncNodesFromBackendServer() }
          } label: {
            Label("同步服务端节点", systemImage: "arrow.triangle.2.circlepath")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))
        }
        .focusSection()

        if appState.subscriptions.isEmpty {
          HStack {
            Spacer()
            Text("尚未添加任何订阅源，可点击右上角「手机扫码添加多订阅」或「新增订阅链接」导入 Clash / V2Ray / Sing-box / Sub 订阅")
              .font(.system(size: 14))
              .foregroundColor(.white.opacity(0.55))
              .padding(.vertical, 16)
            Spacer()
          }
        } else {
          // 2-Column Compact Subscription Cards + Right QR Fast Input Card
          HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 10) {
              ForEach(appState.subscriptions) { sub in
                subscriptionRowCard(sub: sub, theme: theme)
              }
            }
            .frame(maxWidth: .infinity)
            .focusSection()

            // Compact Phone QR Code Card on the right
            VStack(spacing: 10) {
              if !appState.lanInputUrl.isEmpty {
                TvQRCodeImageView(content: appState.lanInputUrl, size: 96)
              } else {
                ProgressView()
                  .frame(width: 112, height: 112)
              }

              Text("📱 手机扫码添加多订阅")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)

              Text("支持一次粘贴多个订阅\n或节点链接一键发送")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.60))
                .multilineTextAlignment(.center)

              if !appState.lanInputUrl.isEmpty {
                Text(appState.lanInputUrl)
                  .font(.system(size: 11, weight: .bold, design: .monospaced))
                  .foregroundColor(theme.accentHover)
                  .padding(.horizontal, 8)
                  .padding(.vertical, 3)
                  .background(theme.accent.opacity(0.16))
                  .clipShape(Capsule())
                  .lineLimit(1)
              }
            }
            .frame(width: 225)
            .padding(14)
            .background(Color.black.opacity(0.28))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.accent.opacity(0.28), lineWidth: 1)
            )
          }
        }
      }
      .padding(18)
      .background(.ultraThinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(Color.white.opacity(0.10), lineWidth: 1)
      )

      // Card B: Proxy Node List with Subscription Filter + Region/Protocol Filter + Sort Controls
      VStack(alignment: .leading, spacing: 12) {
        // Row 1: Title + Subscription Source Filter Pills + Action Buttons
        HStack(spacing: 10) {
          Text("代理节点池 (\(nodes.count)/\(appState.subscriptionNodes.count))")
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(.white)

          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
              Button("全部订阅源") {
                selectedSubFilterId = "all"
              }
              .buttonStyle(TvApplePillButtonStyle(isSelected: selectedSubFilterId == "all", compact: true))

              ForEach(appState.subscriptions) { sub in
                let count = appState.subscriptionNodes.filter { $0.subscriptionId == sub.id }.count
                Button("\(sub.name) (\(count))") {
                  selectedSubFilterId = sub.id
                }
                .buttonStyle(TvApplePillButtonStyle(isSelected: selectedSubFilterId == sub.id, compact: true))
              }

              if appState.subscriptionNodes.contains(where: { $0.subscriptionId == "server" }) {
                Button("流光服务端") {
                  selectedSubFilterId = "server"
                }
                .buttonStyle(TvApplePillButtonStyle(isSelected: selectedSubFilterId == "server", compact: true))
              }

              if appState.subscriptionNodes.contains(where: { $0.subscriptionId == "manual" }) {
                Button("手动导入") {
                  selectedSubFilterId = "manual"
                }
                .buttonStyle(TvApplePillButtonStyle(isSelected: selectedSubFilterId == "manual", compact: true))
              }
            }
            .padding(.vertical, 2)
          }

          Spacer()

          Button {
            sortMode = (sortMode == "latency") ? "name" : ((sortMode == "name") ? "default" : "latency")
          } label: {
            let label = sortMode == "latency" ? "排序: 延迟从低到高" : (sortMode == "name" ? "排序: 按名称" : "排序: 默认顺序")
            Label(label, systemImage: "arrow.up.arrow.down")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))
          .fixedSize(horizontal: true, vertical: false)

          Button {
            appState.removeTimeoutNodes()
          } label: {
            Label("清理超时", systemImage: "sparkles")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))
          .fixedSize(horizontal: true, vertical: false)
        }
        .focusSection()

        // Row 2: Region & Protocol Filter Pills
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(regionAndProtoFilters, id: \.self) { filter in
              Button(filter) {
                categoryFilter = filter
              }
              .buttonStyle(TvApplePillButtonStyle(isSelected: categoryFilter == filter, compact: true))
            }
          }
          .padding(.vertical, 2)
        }
        .focusSection()

        // Row 3: 5-Column Compact Proxy Node Grid
        if nodes.isEmpty {
          HStack {
            Spacer()
            Text(appState.isRefreshingSubscription ? "正在并发拉取多订阅节点并执行 TCP 测速..." : "当前筛选条件下暂无代理节点")
              .font(.system(size: 14))
              .foregroundColor(.white.opacity(0.55))
              .padding(.vertical, 36)
            Spacer()
          }
        } else {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 285, maximum: 335), spacing: 10)], spacing: 10) {
            ForEach(nodes) { node in
              TvProxyNodeCompactCard(
                node: node,
                isSelected: activeNode?.id == node.id,
                isFastest: fastestId == node.id
              ) {
                Task { await appState.selectAndTestProxyNode(node) }
              }
              .contextMenu {
                Button {
                  appState.selectManualNode(node.id)
                } label: {
                  Label("手动锁定此节点", systemImage: "checkmark.circle.fill")
                }
                Button {
                  Task { await appState.testSingleNodeLatency(node.id) }
                } label: {
                  Label("单独重新测速", systemImage: "bolt.horizontal.fill")
                }
                Button {
                  appState.toggleNodeFavorite(node.id)
                } label: {
                  Label(node.favorite ? "取消收藏节点" : "★ 设为收藏节点", systemImage: node.favorite ? "star.slash" : "star.fill")
                }
                Button(role: .destructive) {
                  appState.deleteNode(node.id)
                } label: {
                  Label("删除该节点", systemImage: "trash")
                }
              }
            }
          }
          .focusSection()
        }
      }
      .padding(18)
      .background(.ultraThinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(Color.white.opacity(0.10), lineWidth: 1)
      )
    }
  }

  /// Individual Subscription Card in Multi-Subscription List (Matches _buildSubscriptionsCard in proxy_server_screen.dart)
  @ViewBuilder
  private func subscriptionRowCard(sub: TvProxySubscription, theme: TvThemePalette) -> some View {
    let isUpdating = (appState.updatingSubscriptionId == sub.id)
    let subNodeCount = appState.subscriptionNodes.filter { $0.subscriptionId == sub.id }.count

    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        // Enable/Disable Badge
        Text(sub.enabled ? "已启用" : "已停用")
          .font(.system(size: 11, weight: .bold))
          .foregroundColor(sub.enabled ? Color(red: 0.20, green: 0.86, blue: 0.48) : .white.opacity(0.45))
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background((sub.enabled ? Color(red: 0.20, green: 0.86, blue: 0.48) : Color.white).opacity(0.15))
          .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

        Text(sub.name)
          .font(.system(size: 15, weight: .bold))
          .foregroundColor(.white)
          .lineLimit(1)

        Text("\(max(sub.nodeCount, subNodeCount)) 节点 · \(sub.formattedUpdatedTime)")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(theme.accentHover)
          .lineLimit(1)

        Spacer()

        // Per-subscription Action Buttons
        Button {
          Task { await appState.refreshSubscription(sub.id, silent: false) }
        } label: {
          Label(isUpdating ? "更新中..." : "立即更新", systemImage: "arrow.clockwise")
        }
        .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
        .fixedSize(horizontal: true, vertical: false)

        Button {
          appState.toggleSubscriptionEnabled(sub.id)
        } label: {
          Text(sub.enabled ? "停用" : "启用")
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))
        .fixedSize(horizontal: true, vertical: false)

        Button {
          editingSubscription = sub
          subNameDraft = sub.name
          subUrlDraft = sub.url
          subEnabledDraft = sub.enabled
          showSubEditorSheet = true
        } label: {
          Text("编辑")
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))
        .fixedSize(horizontal: true, vertical: false)

        Button {
          appState.deleteSubscription(sub.id)
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(TvApplePillButtonStyle(isDestructive: true, compact: true))
        .fixedSize(horizontal: true, vertical: false)
      }

      HStack(spacing: 12) {
        Text(sub.maskedUrlSummary)
          .font(.system(size: 12, design: .monospaced))
          .foregroundColor(.white.opacity(0.50))
          .lineLimit(1)

        Spacer()

        if let trafficText = sub.formattedTrafficSummary {
          Text(trafficText)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.72))
            .lineLimit(1)
        }
      }

      if let ratio = sub.usedTrafficRatio {
        GeometryReader { geo in
          ZStack(alignment: .leading) {
            Capsule()
              .fill(Color.white.opacity(0.12))
              .frame(height: 5)
            Capsule()
              .fill(ratio > 0.85 ? Color.red : theme.accentHover)
              .frame(width: max(4, geo.size.width * ratio), height: 5)
          }
        }
        .frame(height: 5)
      }

      if let err = sub.lastError, !err.isEmpty {
        Text("⚠️ 上次更新异常：\(err)")
          .font(.system(size: 11))
          .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.40))
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .background(Color.black.opacity(0.28))
    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .stroke(sub.enabled ? theme.accent.opacity(0.24) : Color.white.opacity(0.08), lineWidth: 1)
    )
  }

  // MARK: - Tab 1: 6-Scenario Routing Strategy (Matches _buildScenarioRoutingTab in proxy_server_screen.dart)

  @ViewBuilder
  private func scenarioRoutingTab(theme: TvThemePalette) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      // 1. One-Click Scenario Preset Bar
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Label("一键场景分流预设（点击即可快速配置下方 6 大业务场景）", systemImage: "wand.and.stars")
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(.white)
          Spacer()
        }

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 10) {
            Button("🚀 推荐智能分流 (海外/TG代理 · 国内直连)") {
              appState.applyScenarioPreset("smart_recommended")
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))

            Button("🔄 全部跟随全局开关") {
              appState.applyScenarioPreset("follow_global")
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))

            Button("✈️ 仅 Telegram 与订阅走代理") {
              appState.applyScenarioPreset("telegram_only")
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))

            Button("🌐 全场景走代理节点") {
              appState.applyScenarioPreset("all_proxy")
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))

            Button("🛡️ 点播与直播走服务端中转") {
              appState.applyScenarioPreset("server_relay")
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
          }
          .padding(.vertical, 4)
        }
      }
      .padding(18)
      .background(.ultraThinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      .focusSection()

      // 2. 6 Individual Scenario Rule Cards
      VStack(spacing: 12) {
        ForEach(TvRequestScenario.allCases) { scenario in
          let rule = appState.rule(for: scenario)
          let effective = appState.resolveEffectiveRoute(for: scenario)
          let boundNode = appState.resolveNode(for: scenario)
          let specificNode = rule.specificNodeId.flatMap { id in
            appState.subscriptionNodes.first(where: { $0.id == id })
          }

          VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
              Image(systemName: scenario.iconName)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(theme.accentHover)
                .frame(width: 30)

              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                  Text(scenario.label)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)

                  Text("当前生效: \(effective.shortBadge)\(effective == .proxyNode && boundNode != nil ? " (\(boundNode!.displayTitle))" : "")")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(effective == .direct ? .white.opacity(0.75) : Color(red: 0.22, green: 0.86, blue: 0.50))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background((effective == .direct ? Color.white : Color(red: 0.22, green: 0.86, blue: 0.50)).opacity(0.15))
                    .clipShape(Capsule())
                }
                Text(scenario.subtitle)
                  .font(.system(size: 12))
                  .foregroundColor(.white.opacity(0.55))
              }

              Spacer()

              // Per-Scenario Specific Node Binding Button
              Button {
                pickingNodeForScenario = scenario
              } label: {
                HStack(spacing: 6) {
                  Image(systemName: "pin.fill")
                    .font(.system(size: 11))
                  Text(specificNode != nil ? "指定节点: \(specificNode!.displayTitle)" : "节点: 跟随全局最优")
                    .lineLimit(1)
                }
              }
              .buttonStyle(TvApplePillButtonStyle(isSelected: specificNode != nil, compact: true))
              .fixedSize(horizontal: true, vertical: false)
            }

            // 5 Route Mode Selection Chips
            HStack(spacing: 8) {
              ForEach(TvScenarioRouteMode.allCases) { mode in
                let isSelected = (rule.mode == mode)
                Button {
                  appState.updateScenarioRule(scenario, mode: mode)
                } label: {
                  Text(mode.label)
                }
                .buttonStyle(TvApplePillButtonStyle(isSelected: isSelected, isPrimary: isSelected, compact: true))
              }
              Spacer()
            }
          }
          .padding(16)
          .background(.ultraThinMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .stroke(Color.white.opacity(0.10), lineWidth: 1)
          )
          .focusSection()
        }
      }
    }
  }

  // MARK: - Tab 2: Server Proxy Listeners (/api/proxy)

  @ViewBuilder
  private func backendProxyServicesTab(theme: TvThemePalette) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("流光主服务端代理监听实例 (/api/proxy)", systemImage: "server.rack")
          .font(.system(size: 16, weight: .bold))
          .foregroundColor(.white)

        Spacer()

        Button {
          Task { await appState.syncNodesFromBackendServer(silent: false) }
        } label: {
          Label("一键导入到客户端节点池并测速", systemImage: "arrow.down.to.line.compact")
        }
        .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
      }
      .focusSection()

      if appState.backendProxyServices.isEmpty {
        Text("服务端当前未配置代理监听实例，或点击上方按钮刷新同步")
          .font(.system(size: 14))
          .foregroundColor(.white.opacity(0.55))
          .padding(.vertical, 32)
      } else {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 420, maximum: 560), spacing: 12)], spacing: 12) {
          ForEach(appState.backendProxyServices) { svc in
            let status = appState.backendProxyStatuses.first(where: { $0.id == svc.id })
            HStack(spacing: 14) {
              VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                  Text(svc.proto.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.accentHover)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(theme.accent.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                  Text(svc.name.isEmpty ? "服务端代理" : svc.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                  Circle()
                    .fill((status?.running ?? svc.enabled) ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                }

                Text("监听端口: \(svc.listenHost):\(svc.port) · 活动连接: \(status?.activeConnections ?? 0) / 累计: \(status?.totalConnections ?? 0)")
                  .font(.system(size: 12, design: .monospaced))
                  .foregroundColor(.white.opacity(0.58))
                  .lineLimit(1)
              }
              Spacer()
            }
            .padding(14)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          }
        }
      }
    }
    .padding(18)
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  // MARK: - Helper Sheets (Add/Edit Subscription, Paste Nodes, Manual Node, QR Scan, Scenario Node Picker)

  @ViewBuilder
  private func subscriptionEditorSheet(theme: TvThemePalette) -> some View {
    ZStack {
      TvAmbientBackdropView(imageUrl: appState.ambientBackdropUrl)
      VStack(spacing: 20) {
        Text(editingSubscription == nil ? "新增代理订阅源" : "编辑代理订阅源")
          .font(.system(size: 24, weight: .bold))
        Text("支持 https://、clash://、sing-box://、shadowrocket://、sub:// 订阅链接自动解析，支持添加多个订阅源")
          .font(.system(size: 14))
          .foregroundColor(.white.opacity(0.65))

        TextField("订阅备注名称（选填，如：主力机场 / 备用专线）", text: $subNameDraft)
          .frame(width: 760)
        TextField("订阅地址 https://... 或 clash://...", text: $subUrlDraft)
          .frame(width: 760)

        HStack(spacing: 16) {
          Button("取消") { showSubEditorSheet = false }
            .buttonStyle(TvApplePillButtonStyle(compact: true))

          Button {
            guard let saved = appState.upsertSubscription(
              id: editingSubscription?.id,
              name: subNameDraft,
              url: subUrlDraft,
              enabled: subEnabledDraft
            ) else { return }
            showSubEditorSheet = false
            Task { await appState.refreshSubscription(saved.id, silent: false) }
          } label: {
            Label("保存并拉取测速", systemImage: "checkmark.circle.fill")
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
        }
      }
      .padding(44)
    }
  }

  @ViewBuilder
  private func pasteNodesSheet(theme: TvThemePalette) -> some View {
    ZStack {
      TvAmbientBackdropView(imageUrl: appState.ambientBackdropUrl)
      VStack(spacing: 20) {
        Text("粘贴导入代理节点链接")
          .font(.system(size: 24, weight: .bold))
        Text("支持 vmess://、vless://、ss://、trojan://、hy2://、socks5:// 节点链接或 Base64 节点文本")
          .font(.system(size: 14))
          .foregroundColor(.white.opacity(0.65))

        TextField("在此粘贴节点链接...", text: $pasteNodesDraft)
          .frame(width: 780)

        HStack(spacing: 16) {
          Button("取消") { showPasteNodesSheet = false }
            .buttonStyle(TvApplePillButtonStyle(compact: true))

          Button {
            let raw = pasteNodesDraft
            showPasteNodesSheet = false
            Task { _ = await appState.importManualNodesFromText(raw) }
          } label: {
            Label("解析导入并测速", systemImage: "bolt.horizontal.circle.fill")
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
        }
      }
      .padding(44)
    }
  }

  @ViewBuilder
  private func manualNodeEditorSheet(theme: TvThemePalette) -> some View {
    let protos = ["SOCKS5", "HTTP", "SS", "VMESS", "VLESS", "TROJAN", "HY2"]
    ZStack {
      TvAmbientBackdropView(imageUrl: appState.ambientBackdropUrl)
      VStack(spacing: 18) {
        Text("手动添加单个代理节点")
          .font(.system(size: 24, weight: .bold))

        HStack(spacing: 8) {
          ForEach(protos, id: \.self) { p in
            Button(p) { manualNodeProto = p }
              .buttonStyle(TvApplePillButtonStyle(isSelected: manualNodeProto == p, compact: true))
          }
        }

        TextField("节点名称（如：香港 IEPL 01）", text: $manualNodeName)
          .frame(width: 680)
        HStack(spacing: 14) {
          TextField("服务器地址 (IP 或域名)", text: $manualNodeHost)
            .frame(width: 480)
          TextField("端口", text: $manualNodePort)
            .frame(width: 180)
        }

        HStack(spacing: 16) {
          Button("取消") { showAddManualNodeSheet = false }
            .buttonStyle(TvApplePillButtonStyle(compact: true))

          Button {
            let p = Int(manualNodePort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1080
            let name = manualNodeName
            let proto = manualNodeProto
            let host = manualNodeHost
            showAddManualNodeSheet = false
            Task {
              await appState.addManualProxyNode(name: name, proto: proto, host: host, port: p)
            }
          } label: {
            Label("添加并测速", systemImage: "checkmark.circle.fill")
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
        }
      }
      .padding(44)
    }
  }

  @ViewBuilder
  private func qrCodeFastPushSheet(theme: TvThemePalette) -> some View {
    ZStack {
      TvAmbientBackdropView(imageUrl: appState.ambientBackdropUrl)
      VStack(spacing: 20) {
        Text("📱 手机扫码添加多订阅与节点")
          .font(.system(size: 26, weight: .bold))
        Text("使用手机相机或浏览器扫描下方二维码，可一次粘贴多个机场订阅链接（每行一个）或节点直链推送到 Apple TV")
          .font(.system(size: 15))
          .foregroundColor(.white.opacity(0.70))
          .multilineTextAlignment(.center)
          .frame(maxWidth: 720)

        if !appState.lanInputUrl.isEmpty {
          TvQRCodeImageView(content: appState.lanInputUrl, size: 220)
          Text(appState.lanInputUrl)
            .font(.system(size: 18, weight: .bold, design: .monospaced))
            .foregroundColor(theme.accentHover)
        } else {
          ProgressView("正在启动局域网快捷输入服务...")
        }

        Button("关闭") { showQrScanSheet = false }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
      }
      .padding(44)
    }
  }

  @ViewBuilder
  private func scenarioNodePickerSheet(scenario: TvRequestScenario, theme: TvThemePalette) -> some View {
    let currentSpecId = appState.rule(for: scenario).specificNodeId
    let nodes = appState.activePoolNodes
    ZStack {
      TvAmbientBackdropView(imageUrl: appState.ambientBackdropUrl)
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          Text("为「\(scenario.label)」绑定专属代理节点")
            .font(.system(size: 22, weight: .bold))
          Spacer()
          Button("跟随全局最优节点") {
            appState.updateScenarioRule(scenario, clearSpecificNode: true)
            pickingNodeForScenario = nil
          }
          .buttonStyle(TvApplePillButtonStyle(isSelected: currentSpecId == nil, isPrimary: currentSpecId == nil, compact: true))

          Button("关闭") { pickingNodeForScenario = nil }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
        }

        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 290, maximum: 350), spacing: 12)], spacing: 12) {
            ForEach(nodes) { node in
              let isSelected = (currentSpecId == node.id)
              TvProxyNodeCompactCard(
                node: node,
                isSelected: isSelected,
                isFastest: appState.fastestProxyNode?.id == node.id
              ) {
                appState.updateScenarioRule(scenario, mode: .proxyNode, specificNodeId: node.id)
                pickingNodeForScenario = nil
                appState.showToast("📌 「\(scenario.label)」已绑定节点：\(node.displayTitle)")
              }
            }
          }
          .padding(4)
        }
      }
      .padding(40)
    }
  }

  private func latencyBadgeColor(_ ms: Int?) -> Color {
    guard let ms = ms else { return .white.opacity(0.45) }
    if ms >= 9999 { return Color(red: 1.0, green: 0.36, blue: 0.34) }
    if ms <= 260 { return Color(red: 0.20, green: 0.84, blue: 0.48) }
    if ms <= 550 { return Color(red: 1.0, green: 0.72, blue: 0.16) }
    return Color(red: 1.0, green: 0.45, blue: 0.26)
  }
}

/// Sleek Compact Proxy Node Card (Decoupled from @EnvironmentObject — Protocol Tag + Region Flag + Title + Latency Badge + Subscription Name + Host:Port)
struct TvProxyNodeCompactCard: View {
  let node: TvSubscriptionNode
  let isSelected: Bool
  let isFastest: Bool
  let action: () -> Void

  private var protocolColor: Color {
    switch node.type.uppercased() {
    case "VMESS": return Color(red: 0.22, green: 0.68, blue: 1.0)
    case "VLESS": return Color(red: 0.62, green: 0.46, blue: 1.0)
    case "TROJAN": return Color(red: 1.0, green: 0.58, blue: 0.18)
    case "SS", "SHADOWSOCKS": return Color(red: 0.18, green: 0.82, blue: 0.58)
    case "HY2", "HYSTERIA2": return Color(red: 0.98, green: 0.36, blue: 0.56)
    default: return TvThemePalette.current.accentHover
    }
  }

  private var latencyColor: Color {
    guard let ms = node.latencyMs else { return .white.opacity(0.45) }
    if ms >= 9999 { return Color(red: 1.0, green: 0.36, blue: 0.34) }
    if ms <= 260 { return Color(red: 0.20, green: 0.84, blue: 0.48) }
    if ms <= 550 { return Color(red: 1.0, green: 0.72, blue: 0.16) }
    return Color(red: 1.0, green: 0.45, blue: 0.26)
  }

  var body: some View {
    let theme = TvThemePalette.current

    Button(action: action) {
      VStack(alignment: .leading, spacing: 6) {
        // Row 1: Protocol Badge + Region Flag & Node Title + Latency Pill
        HStack(spacing: 6) {
          Text(node.type.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(protocolColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(protocolColor.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

          if node.favorite {
            Image(systemName: "star.fill")
              .font(.system(size: 11))
              .foregroundColor(.yellow)
          }

          Text(node.displayTitle)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .lineLimit(1)

          Spacer(minLength: 4)

          Text(node.formattedLatency)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(latencyColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(latencyColor.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }

        // Row 2: Subscription Name · Host:Port + Fastest / Active Badges
        HStack(spacing: 6) {
          Text("\(node.subscriptionName) · \(node.host):\(node.port)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.white.opacity(0.48))
            .lineLimit(1)

          Spacer(minLength: 4)

          if isFastest {
            Text("⚡最快")
              .font(.system(size: 10, weight: .bold))
              .foregroundColor(Color(red: 0.20, green: 0.84, blue: 0.48))
              .padding(.horizontal, 5)
              .padding(.vertical, 1.5)
              .background(Color(red: 0.20, green: 0.84, blue: 0.48).opacity(0.15))
              .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
          }

          if isSelected {
            Text("当前")
              .font(.system(size: 10, weight: .bold))
              .foregroundColor(.black)
              .padding(.horizontal, 5)
              .padding(.vertical, 1.5)
              .background(theme.accentHover)
              .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(TvAppleSurfaceButtonStyle(isSelected: isSelected, cornerRadius: 11))
  }
}

// MARK: - 8. System Settings, Theme Switcher & 115 Cloud Drive Section View

struct TvSettingsSectionView: View {
  @EnvironmentObject var appState: TvAppState

  @State private var urlInput: String = ""
  @State private var secretInput: String = ""
  @State private var adFilter: Bool = true
  @State private var directPlay: Bool = true
  @State private var introSec: Int = 0
  @State private var outroSec: Int = 0
  @State private var cookie115Input: String = ""
  @FocusState private var focusedSettingsTopId: String?

  var body: some View {
    ScrollViewReader { scrollProxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 26) {
          // 1. Original App Theme Color Switcher Card (5 Presets)
          VStack(alignment: .leading, spacing: 18) {
            HStack {
              Label("外观与主题配色（原应用 5 款经典影院主题）", systemImage: "paintpalette.fill")
                .font(.title3.bold())
              Spacer()
              Text("当前版本：\(appState.appFullVersion)")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.92))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(appState.activeTheme.accent.opacity(0.22))
                .clipShape(Capsule(style: .continuous))
                .overlay(
                  Capsule(style: .continuous)
                    .stroke(appState.activeTheme.accentHover.opacity(0.5), lineWidth: 1)
                )
              Text("当前：\(appState.activeTheme.name) · \(appState.activeTheme.subtitle)")
                .font(.callout)
                .foregroundColor(appState.activeTheme.accentHover)
            }

            HStack(spacing: 18) {
              ForEach(TvThemePalette.presets) { preset in
                let isSelected = (appState.themeId == preset.id)
                Button {
                  appState.setTheme(preset.id)
                } label: {
                  VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                      ZStack {
                        Circle()
                          .fill(preset.bgPrimary)
                          .frame(width: 36, height: 36)
                          .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                        Circle()
                          .fill(preset.accent)
                          .frame(width: 20, height: 20)
                      }
                      Text(preset.name)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                      Spacer()
                      if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                          .font(.system(size: 22))
                          .foregroundColor(preset.accentHover)
                      }
                    }

                    Text(preset.subtitle)
                      .font(.system(size: 14, weight: .medium))
                      .foregroundColor(.white.opacity(0.68))
                      .lineLimit(1)
                  }
                  .padding(18)
                  .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(TvAppleSurfaceButtonStyle(isSelected: isSelected, cornerRadius: 18))
                .focused($focusedSettingsTopId, equals: preset.id)
              }
            }
          }
          .padding(28)
          .background(.ultraThinMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
          .id("settings_top_anchor")
          .focusSection()

          // 2. Server & Playback Preferences Card
          VStack(alignment: .leading, spacing: 18) {
            HStack {
              Text("服务器连接与播放器优化")
                .font(.title3.bold())
              Spacer()
              if !appState.lanInputUrl.isEmpty {
                Text("📱 手机扫码快捷配置：\(appState.lanInputUrl)")
                  .font(.caption.monospaced())
                  .foregroundColor(appState.activeTheme.accentHover)
              }
            }

            HStack(spacing: 16) {
              TextField("服务器地址", text: $urlInput)
              SecureField("访问密码", text: $secretInput)
                .frame(width: 360)
            }

            Toggle("启用 M3U8 切片广告智能过滤（自动剥离 #EXT-X-DISCONTINUITY 插播广告）", isOn: $adFilter)
            Toggle("优先客户端直连播放（失败自动无缝回退服务端代理）", isOn: $directPlay)

            HStack(spacing: 20) {
              Button("跳过片头：\(introSec) 秒") {
                introSec = (introSec + 15) % 150
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))

              Button("跳过片尾：\(outroSec) 秒") {
                outroSec = (outroSec + 15) % 180
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))

              Spacer()

              Button("保存并重新加载") {
                appState.saveConfig(
                  newUrl: urlInput,
                  newSecret: secretInput,
                  adFilter: adFilter,
                  directPlayback: directPlay,
                  introSec: introSec,
                  outroSec: outroSec
                )
                appState.showToast("设置已保存")
                Task { await appState.bootstrapAll() }
              }
              .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))

              Button("退出登录") {
                appState.logout()
              }
              .buttonStyle(TvApplePillButtonStyle(isDestructive: true, compact: true))
            }
          }
          .padding(28)
          .background(.ultraThinMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
          .focusSection()

          // 3. 115 Cloud Drive Card
          VStack(alignment: .leading, spacing: 18) {
            HStack {
              Text("115 网盘账号连接")
                .font(.title3.bold())
              Spacer()
              Text(appState.is115LoggedIn ? "已登录 (\(appState.user115Name))" : "未登录")
                .foregroundColor(appState.is115LoggedIn ? .green : .orange)
            }

            HStack(spacing: 16) {
              TextField("粘贴 115 Cookie (UID=...; CID=...; SEID=...)", text: $cookie115Input)
              Button("Cookie 登录") {
                guard !cookie115Input.isEmpty else { return }
                let ck = cookie115Input
                cookie115Input = ""
                Task {
                  await appState.save115Cookie(ck)
                  appState.showToast("已更新本地与服务端 115 Cookie")
                }
              }
              .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))

              Button("获取扫码二维码") {
                Task { await appState.start115QrCode(forceRefresh: true) }
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))

              if !appState.qr115Token.isEmpty {
                Button("刷新状态") {
                  Task { await appState.poll115QrCodeOnce() }
                }
                .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
              }
            }

            if !appState.qr115Content.isEmpty || !appState.qr115ImageUrl.isEmpty {
              HStack(spacing: 24) {
                if !appState.qr115Content.isEmpty {
                  TvQRCodeImageView(content: appState.qr115Content, size: 170)
                } else {
                  TvRemoteImage(rawUrl: appState.qr115ImageUrl, placeholderIcon: "qrcode", contentMode: .fit)
                    .frame(width: 180, height: 180)
                    .background(Color.white)
                    .cornerRadius(16)
                }
                Text(appState.qr115StatusText)
                  .font(.callout)
              }
            }
          }
          .padding(28)
          .background(.ultraThinMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
          .focusSection()

          // 4. App Version & Runtime Info Card
          HStack(spacing: 20) {
            Label("流光视频 Apple TV 原生客户端", systemImage: "appletv.fill")
              .font(.headline)
              .foregroundColor(.white)
            Text(appState.appFullVersion)
              .font(.system(size: 16, weight: .bold, design: .monospaced))
              .foregroundColor(appState.activeTheme.accentHover)
              .padding(.horizontal, 12)
              .padding(.vertical, 5)
              .background(appState.activeTheme.accent.opacity(0.2))
              .clipShape(Capsule(style: .continuous))
            Spacer()
            Text("tvOS \(UIDevice.current.systemVersion) · 本地代理端口 127.0.0.1:\(TvLocalProxyTunnelServer.shared.port) · HLS 加速端口 127.0.0.1:\(TvLocalHlsProxyServer.shared.port)")
              .font(.caption.monospaced())
              .foregroundColor(.white.opacity(0.68))
          }
          .padding(.horizontal, 28)
          .padding(.vertical, 20)
          .background(.ultraThinMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 24)
      }
      .onChange(of: appState.pageScrollToTopTrigger) { _ in
        focusedSettingsTopId = appState.themeId
        withAnimation(.easeInOut(duration: 0.25)) {
          scrollProxy.scrollTo("settings_top_anchor", anchor: .top)
        }
      }
    }
    .onAppear {
      urlInput = appState.serverUrl
      secretInput = appState.authSecret
      adFilter = appState.enableAdFilter
      directPlay = appState.preferDirectPlayback
      introSec = appState.skipIntroSeconds
      outroSec = appState.skipOutroSeconds
      appState.startLanInputServer()
    }
  }
}

// MARK: - 9. Cloud Hi-Fi Music Player Dock & Fullscreen Vinyl Lyrics Hall (115 / AList / WebDAV / Server / Local)

struct TvCloudMusicBottomDockBar: View {
  @EnvironmentObject var appState: TvAppState

  static func formatTime(_ sec: Double) -> String {
    guard sec.isFinite && sec > 0 else { return "00:00" }
    let total = Int(sec)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
      return String(format: "%02d:%02d:%02d", h, m, s)
    }
    return String(format: "%02d:%02d", m, s)
  }

  var body: some View {
    if let track = appState.currentCloudMusicTrack {
      let theme = appState.activeTheme
      let meta = TvAppState.parseCloudTrackMetadata(
        track,
        fallbackArtist: appState.mountDisplayName(for: track)
      )
      let ratio = appState.cloudMusicDuration > 0
        ? min(max(0, appState.cloudMusicPosition / appState.cloudMusicDuration), 1.0)
        : 0
      let lyricLine = appState.currentCloudLyricLineText

      VStack(spacing: 8) {
        HStack(spacing: 14) {
          // Mini Vinyl Disc + Album Cover
          ZStack {
            Circle()
              .fill(
                RadialGradient(
                  colors: [Color(white: 0.22), Color(white: 0.06), Color(white: 0.14)],
                  center: .center,
                  startRadius: 2,
                  endRadius: 26
                )
              )
              .frame(width: 52, height: 52)
              .overlay(
                Circle().stroke(theme.accent.opacity(0.75), lineWidth: 1.5)
              )

            if let img = appState.cloudMusicCoverImage {
              Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 30, height: 30)
                .clipShape(Circle())
            } else {
              Circle()
                .fill(theme.accent)
                .frame(width: 28, height: 28)
                .overlay(
                  Image(systemName: "music.note")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                )
            }
          }

          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
              Text(meta.qualityTag)
                .font(.system(size: 11, weight: .heavy))
                .foregroundColor(theme.accentHover)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(theme.accent.opacity(0.2))
                .clipShape(Capsule())

              Text(meta.title)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
            }

            Text(
              !appState.cloudMusicErrorText.isEmpty
                ? appState.cloudMusicErrorText
                : (!lyricLine.isEmpty
                    ? "♪ \(lyricLine)"
                    : "\(meta.artist) · \(appState.mountDisplayName(for: track)) · \(track.formattedSize)")
            )
            .font(.system(size: 13))
            .foregroundColor(
              !appState.cloudMusicErrorText.isEmpty
                ? .red
                : (!lyricLine.isEmpty ? theme.accentHover : .white.opacity(0.72))
            )
            .lineLimit(1)
          }

          Spacer()

          Text("\(Self.formatTime(appState.cloudMusicPosition)) / \(Self.formatTime(appState.cloudMusicDuration))")
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.78))

          Button {
            appState.stepCloudMusicTrack(delta: -1)
          } label: {
            Image(systemName: "backward.fill")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))

          Button {
            appState.toggleCloudMusicPlayPause()
          } label: {
            if appState.isCloudMusicLoading {
              ProgressView()
            } else {
              Image(systemName: appState.isCloudMusicPlaying ? "pause.fill" : "play.fill")
            }
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))

          Button {
            appState.stepCloudMusicTrack(delta: 1)
          } label: {
            Image(systemName: "forward.fill")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))

          Button {
            appState.cycleCloudMusicPlayMode()
          } label: {
            Label(appState.cloudMusicPlayModeLabel, systemImage: appState.cloudMusicPlayModeIcon)
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))

          Button {
            appState.showCloudMusicFullscreen = true
          } label: {
            Label("黑胶歌词厅 (\(appState.cloudMusicCurrentIndex + 1)/\(appState.cloudMusicQueue.count))", systemImage: "opticaldisc.fill")
              .foregroundColor(theme.accentHover)
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))

          Button {
            appState.stopCloudMusicPlayer()
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(TvApplePillButtonStyle(isDestructive: true, compact: true))
        }

        GeometryReader { geo in
          ZStack(alignment: .leading) {
            Capsule()
              .fill(Color.white.opacity(0.14))
              .frame(height: 5)
            Capsule()
              .fill(theme.accent)
              .frame(width: max(6, geo.size.width * ratio), height: 5)
          }
        }
        .frame(height: 5)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
      .background(
        LinearGradient(
          colors: [
            theme.bgElevated.opacity(0.95),
            theme.bgCard.opacity(0.95)
          ],
          startPoint: .leading,
          endPoint: .trailing
        )
      )
      .overlay(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(theme.accent.opacity(0.45), lineWidth: 1.2)
      )
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
  }
}

struct TvCloudMusicFullscreenHallView: View {
  @EnvironmentObject var appState: TvAppState
  var isStandaloneSection: Bool = false

  @State private var rightPaneTab: Int = 0 // 0 = 实时同步歌词, 1 = 播放队列
  @State private var vinylAngle: Double = 0
  @State private var currentSpeedText: String = "↓ 0 KB/s"
  @FocusState private var initialFocus: String?

  private let spinTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

  var body: some View {
    let theme = appState.activeTheme
    ZStack {
      // Theme-reactive concert hall backdrop
      TvAmbientBackdropView(imageUrl: appState.ambientBackdropUrl)
      LinearGradient(
        colors: [
          theme.bgPrimary.opacity(0.92),
          theme.bgElevated.opacity(0.88),
          theme.bgCard.opacity(0.92)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      if let cover = appState.cloudMusicCoverImage {
        Image(uiImage: cover)
          .resizable()
          .scaledToFill()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .blur(radius: 90)
          .opacity(0.22)
          .ignoresSafeArea()
      }

      if appState.isScanningMusicFolders {
        VStack(spacing: 18) {
          ProgressView()
            .scaleEffect(1.6)
          Text(appState.scanningMusicStatusText.isEmpty ? "正在扫描音乐文件夹与压缩包..." : appState.scanningMusicStatusText)
            .font(.system(size: 22, weight: .bold))
            .foregroundColor(.white)
          Text("支持递归扫描 115 网盘 / AList / WebDAV 子文件夹及 .zip / .tar 压缩包内的音乐")
            .font(.system(size: 16))
            .foregroundColor(.white.opacity(0.65))
        }
      } else if let track = appState.currentCloudMusicTrack {
        let meta = TvAppState.parseCloudTrackMetadata(
          track,
          fallbackArtist: appState.mountDisplayName(for: track)
        )
        let ratio = appState.cloudMusicDuration > 0
          ? min(max(0, appState.cloudMusicPosition / appState.cloudMusicDuration), 1.0)
          : 0

        VStack(spacing: 14) {
          // 1. Top Header Bar
          HStack(spacing: 12) {
            HStack(spacing: 8) {
              Image(systemName: "opticaldisc.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
              Text("流光 Hi-Fi 云端黑胶音乐厅")
                .font(.system(size: 18, weight: .heavy))
                .foregroundColor(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
              LinearGradient(
                colors: [
                  theme.accent,
                  theme.accentHover
                ],
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .clipShape(Capsule())

            Button {
              appState.showMusicFolderPickerSheet = true
            } label: {
              Label("自选文件夹 / 压缩包随机播放", systemImage: "folder.badge.plus")
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))

            if appState.cloudMusicQueue.count > 1 {
              Button {
                appState.shuffleCurrentCloudMusicQueue()
              } label: {
                Label("重新随机打乱 (\(appState.cloudMusicQueue.count)首)", systemImage: "shuffle")
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))
            }

            Text("存储源：\(appState.mountDisplayName(for: track))")
              .font(.system(size: 14, weight: .bold))
              .foregroundColor(theme.accentHover)
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .background(Color.white.opacity(0.08))
              .clipShape(Capsule())

            Text("\(meta.qualityTag) · \(track.formattedSize)")
              .font(.system(size: 14, weight: .bold))
              .foregroundColor(Color(red: 0.98, green: 0.75, blue: 0.14))
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .background(Color(red: 0.96, green: 0.62, blue: 0.04).opacity(0.18))
              .clipShape(Capsule())

            Spacer()

            HStack(spacing: 6) {
              Circle()
                .fill(appState.isCloudMusicPlaying ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
              Text(currentSpeedText)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())

            if !isStandaloneSection {
              Button {
                appState.showCloudMusicFullscreen = false
              } label: {
                Label("收起至音乐栏 (边听边逛目录)", systemImage: "chevron.down.circle.fill")
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))
            }
          }
          .focusSection()

          if !appState.savedMusicFolders.isEmpty {
            savedMusicFoldersQuickStrip()
              .focusSection()
          }

          // 2. Main Concert Hall Content: Left Vinyl Turntable + Right Synchronized Lyrics / Queue
          HStack(spacing: 32) {
            leftVinylTurntablePane(track: track, meta: meta)

            // Right Pane: Synchronized LRC Lyrics & Playlist Queue
            VStack(alignment: .leading, spacing: 14) {
              HStack(spacing: 12) {
                Button {
                  rightPaneTab = 0
                } label: {
                  Label("实时同步歌词", systemImage: "quote.bubble.fill")
                }
                .buttonStyle(TvApplePillButtonStyle(isPrimary: rightPaneTab == 0, compact: true))

                Button {
                  rightPaneTab = 1
                } label: {
                  Label("播放队列 (\(appState.cloudMusicQueue.count))", systemImage: "music.note.list")
                }
                .buttonStyle(TvApplePillButtonStyle(isPrimary: rightPaneTab == 1, compact: true))

                Spacer()

                if rightPaneTab == 0 && !appState.cloudMusicLyricsSource.isEmpty {
                  Text(appState.cloudMusicLyricsSource)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.accentHover)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(theme.accent.opacity(0.18))
                    .clipShape(Capsule())
                }
              }
              .focusSection()

              if rightPaneTab == 0 {
                lyricsPaneView()
                  .focusSection()
              } else {
                playlistQueuePaneView()
                  .focusSection()
              }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(22)
            .background(theme.bgCard.opacity(0.55))
            .overlay(
              RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(theme.accent.opacity(0.22), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
          }
          .frame(maxHeight: .infinity)

          // 3. Bottom Hi-Fi Transport Deck
          VStack(spacing: 12) {
            HStack(spacing: 14) {
              Text(TvCloudMusicBottomDockBar.formatTime(appState.cloudMusicPosition))
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .frame(width: 80, alignment: .leading)

              GeometryReader { geo in
                ZStack(alignment: .leading) {
                  Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: 8)
                  Capsule()
                    .fill(
                      LinearGradient(
                        colors: [
                          theme.accent,
                          theme.accentHover
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                      )
                    )
                    .frame(width: max(8, geo.size.width * ratio), height: 8)
                }
              }
              .frame(height: 8)

              Text(TvCloudMusicBottomDockBar.formatTime(appState.cloudMusicDuration))
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .frame(width: 80, alignment: .trailing)
            }

            HStack(spacing: 16) {
              Button {
                appState.cycleCloudMusicPlayMode()
              } label: {
                Label(appState.cloudMusicPlayModeLabel, systemImage: appState.cloudMusicPlayModeIcon)
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))

              Button {
                appState.cycleCloudMusicSpeed()
              } label: {
                Text(String(format: "倍速 %.2gx", appState.cloudMusicSpeed))
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))

              Spacer()

              Button {
                appState.seekCloudMusicRelative(delta: -10)
              } label: {
                Label("-10秒", systemImage: "gobackward.10")
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))

              Button {
                appState.stepCloudMusicTrack(delta: -1)
              } label: {
                Label("上一首", systemImage: "backward.fill")
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))

              Button {
                appState.toggleCloudMusicPlayPause()
              } label: {
                Label(
                  appState.isCloudMusicPlaying ? "暂停" : "播放",
                  systemImage: appState.isCloudMusicPlaying ? "pause.fill" : "play.fill"
                )
                .font(.system(size: 18, weight: .heavy))
                .padding(.horizontal, 12)
              }
              .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
              .focused($initialFocus, equals: "music_play_pause")

              Button {
                appState.stepCloudMusicTrack(delta: 1)
              } label: {
                Label("下一首", systemImage: "forward.fill")
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))

              Button {
                appState.seekCloudMusicRelative(delta: 10)
              } label: {
                Label("+10秒", systemImage: "goforward.10")
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))

              Spacer()

              Button {
                rightPaneTab = (rightPaneTab == 0) ? 1 : 0
              } label: {
                Label(
                  rightPaneTab == 0 ? "查看队列 (\(appState.cloudMusicQueue.count))" : "查看同步歌词",
                  systemImage: rightPaneTab == 0 ? "music.note.list" : "quote.bubble.fill"
                )
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))

              Button {
                appState.stopCloudMusicPlayer()
              } label: {
                Label("停止退出", systemImage: "stop.fill")
              }
              .buttonStyle(TvApplePillButtonStyle(isDestructive: true, compact: true))
            }
          }
          .padding(.horizontal, 26)
          .padding(.vertical, 16)
          .background(.ultraThinMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
          .focusSection()
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 24)
      } else {
        standaloneEmptyMusicLauncher()
      }
    }
    .sheet(isPresented: $appState.showMusicFolderPickerSheet) {
      TvMusicFolderPickerSheet()
        .environmentObject(appState)
    }
    .sheet(item: $appState.activeArchiveMusicBrowserEntry) { archEntry in
      TvArchiveMusicBrowserSheet(archiveEntry: archEntry)
        .environmentObject(appState)
    }
    .onReceive(spinTimer) { _ in
      if appState.isCloudMusicPlaying {
        vinylAngle = (vinylAngle + 0.9).truncatingRemainder(dividingBy: 360.0)
      }
      let bps = TvNetworkSpeedMonitor.shared.recentDownstreamBytesPerSecond
      if bps >= 1024 * 1024 {
        currentSpeedText = String(format: "↓ %.2f MB/s", bps / (1024.0 * 1024.0))
      } else if bps > 512 {
        currentSpeedText = String(format: "↓ %.0f KB/s", bps / 1024.0)
      } else {
        currentSpeedText = "↓ 0 KB/s"
      }
    }
    .onAppear {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        initialFocus = "music_play_pause"
      }
    }
    .onPlayPauseCommand {
      appState.toggleCloudMusicPlayPause()
    }
    .onExitCommand {
      if !isStandaloneSection {
        appState.showCloudMusicFullscreen = false
      }
    }
  }

  @ViewBuilder
  private func savedMusicFoldersQuickStrip() -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 10) {
        Label("常用音乐源:", systemImage: "star.fill")
          .font(.system(size: 13, weight: .bold))
          .foregroundColor(.yellow)

        Button {
          Task {
            _ = await appState.scanAndPlayMusicFoldersOrArchives(
              sources: appState.savedMusicFolders,
              shuffle: true,
              openFullscreen: false
            )
          }
        } label: {
          Label("全部随机播放 (\(appState.savedMusicFolders.count))", systemImage: "shuffle")
        }
        .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))

        ForEach(appState.savedMusicFolders) { item in
          Button {
            Task {
              _ = await appState.scanAndPlayMusicFoldersOrArchives(
                sources: [item],
                shuffle: true,
                openFullscreen: false
              )
            }
          } label: {
            Label("\(item.mountName): \(item.title)", systemImage: item.isArchive ? "doc.zipper" : "folder.fill")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))
        }
      }
      .padding(.vertical, 2)
    }
  }

  @ViewBuilder
  private func standaloneEmptyMusicLauncher() -> some View {
    let theme = appState.activeTheme
    VStack(spacing: 24) {
      ZStack {
        Circle()
          .fill(
            RadialGradient(
              colors: [
                theme.accent,
                theme.accent.opacity(0.45),
                theme.bgElevated
              ],
              center: .center,
              startRadius: 10,
              endRadius: 80
            )
          )
          .frame(width: 140, height: 140)
          .overlay(Circle().stroke(theme.accentHover.opacity(0.65), lineWidth: 2.5))
        Image(systemName: "opticaldisc.fill")
          .font(.system(size: 68, weight: .bold))
          .foregroundColor(.white)
      }

      Text("流光 Hi-Fi 云端音乐播放器")
        .font(.system(size: 32, weight: .heavy))
        .foregroundColor(.white)

      Text("支持 115 网盘直连 · AList / OpenList · WebDAV · Apple TV 本机缓存\n支持直接读取 .zip / .tar 压缩包内的无损音乐（免整包下载），支持自选多文件夹一键随机播放")
        .font(.system(size: 17))
        .foregroundColor(.white.opacity(0.72))
        .multilineTextAlignment(.center)
        .lineSpacing(6)

      HStack(spacing: 18) {
        Button {
          appState.showMusicFolderPickerSheet = true
        } label: {
          Label("自选文件夹 / 压缩包随机播放", systemImage: "shuffle")
            .font(.system(size: 19, weight: .heavy))
            .padding(.horizontal, 14)
        }
        .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
        .focused($initialFocus, equals: "music_play_pause")

        if !appState.savedMusicFolders.isEmpty {
          Button {
            Task {
              _ = await appState.scanAndPlayMusicFoldersOrArchives(
                sources: appState.savedMusicFolders,
                shuffle: true,
                openFullscreen: false
              )
            }
          } label: {
            Label("一键随机播放常用音乐源 (\(appState.savedMusicFolders.count)个)", systemImage: "star.fill")
              .font(.system(size: 18, weight: .bold))
          }
          .buttonStyle(TvApplePillButtonStyle())
        }
      }
      .focusSection()

      if !appState.savedMusicFolders.isEmpty {
        savedMusicFoldersQuickStrip()
          .padding(.horizontal, 60)
          .focusSection()
      }
    }
    .padding(48)
  }

  private static func spectrumBarHeight(isPlaying: Bool, tick: Int, index: Int) -> CGFloat {
    guard isPlaying else { return 6 }
    let t = Double(tick)
    let idx = Double(index)
    let w1 = abs(sin(t * 0.65 + idx * 0.55))
    let w2 = abs(cos(t * 0.42 - idx * 0.35))
    let combined = 0.55 * w1 + 0.45 * w2
    return CGFloat(6.0 + 30.0 * combined)
  }

  @ViewBuilder
  private func leftVinylTurntablePane(
    track: TvFileEntry,
    meta: (title: String, artist: String, qualityTag: String)
  ) -> some View {
    let theme = appState.activeTheme
    let tick = Int(appState.cloudMusicPosition * 5.5)
    VStack(spacing: 18) {
      ZStack {
        Circle()
          .fill(theme.accent.opacity(appState.isCloudMusicPlaying ? 0.24 : 0.07))
          .frame(width: 390, height: 390)
          .blur(radius: 28)

        ZStack {
          Circle()
            .fill(
              AngularGradient(
                colors: [
                  Color(white: 0.07),
                  Color(white: 0.18),
                  Color(white: 0.07),
                  Color(white: 0.18),
                  Color(white: 0.07)
                ],
                center: .center
              )
            )
            .frame(width: 350, height: 350)
            .overlay(Circle().stroke(theme.accent.opacity(0.35), lineWidth: 3))
            .shadow(color: .black.opacity(0.75), radius: 24)

          Circle().stroke(Color.white.opacity(0.07), lineWidth: 1).frame(width: 300, height: 300)
          Circle().stroke(Color.white.opacity(0.07), lineWidth: 1).frame(width: 258, height: 258)
          Circle().stroke(Color.white.opacity(0.07), lineWidth: 1).frame(width: 216, height: 216)

          if let cover = appState.cloudMusicCoverImage {
            Image(uiImage: cover)
              .resizable()
              .scaledToFill()
              .frame(width: 168, height: 168)
              .clipShape(Circle())
              .overlay(
                Circle().stroke(theme.accent.opacity(0.75), lineWidth: 3)
              )
          } else {
            Circle()
              .fill(
                LinearGradient(
                  colors: [
                    theme.accent,
                    theme.accentHover,
                    theme.bgElevated
                  ],
                  startPoint: .topLeading,
                  endPoint: .bottomTrailing
                )
              )
              .frame(width: 168, height: 168)
              .overlay(
                Image(systemName: "music.quarternote.3")
                  .font(.system(size: 56, weight: .bold))
                  .foregroundColor(.white.opacity(0.9))
              )
              .overlay(
                Circle().stroke(theme.accent.opacity(0.75), lineWidth: 3)
              )
          }

          Circle()
            .fill(theme.bgPrimary)
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 2))
        }
        .rotationEffect(.degrees(vinylAngle))

        VStack(alignment: .trailing, spacing: 0) {
          HStack {
            Spacer()
            ZStack(alignment: .topTrailing) {
              Circle()
                .fill(Color(white: 0.25))
                .frame(width: 32, height: 32)
                .overlay(
                  Circle()
                    .fill(theme.accent)
                    .frame(width: 14, height: 14)
                )
              RoundedRectangle(cornerRadius: 3)
                .fill(Color(white: 0.85))
                .frame(width: 6, height: 135)
                .offset(x: -13, y: 16)
                .rotationEffect(.degrees(appState.isCloudMusicPlaying ? 24 : 4), anchor: .top)
                .animation(.easeInOut(duration: 0.45), value: appState.isCloudMusicPlaying)
            }
          }
          Spacer()
        }
        .frame(width: 390, height: 370)
      }

      VStack(spacing: 6) {
        Text(meta.title)
          .font(.system(size: 26, weight: .heavy))
          .foregroundColor(.white)
          .multilineTextAlignment(.center)
          .lineLimit(2)

        Text("\(meta.artist) · \(appState.cloudMusicSubtitle.isEmpty ? track.formattedSize : appState.cloudMusicSubtitle)")
          .font(.system(size: 16, weight: .medium))
          .foregroundColor(.white.opacity(0.72))
          .lineLimit(1)
      }

      HStack(alignment: .bottom, spacing: 5) {
        ForEach(0..<24, id: \.self) { i in
          let barH = Self.spectrumBarHeight(isPlaying: appState.isCloudMusicPlaying, tick: tick, index: i)
          Capsule()
            .fill(
              LinearGradient(
                colors: [
                  theme.accent,
                  theme.accentHover
                ],
                startPoint: .bottom,
                endPoint: .top
              )
            )
            .frame(width: 5, height: barH)
            .animation(.easeOut(duration: 0.15), value: tick)
        }
      }
      .frame(height: 38)
    }
    .frame(width: 520)
  }

  @ViewBuilder
  private func lyricsPaneView() -> some View {
    let theme = appState.activeTheme
    if appState.isCloudMusicLoadingLyrics {
      VStack(spacing: 14) {
        ProgressView()
          .scaleEffect(1.3)
        Text("正在匹配同目录 .lrc 歌词与 LRCLIB 云端同步歌词...")
          .font(.system(size: 16))
          .foregroundColor(.white.opacity(0.7))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if appState.cloudMusicLyrics.isEmpty {
      VStack(spacing: 14) {
        Image(systemName: "quote.bubble")
          .font(.system(size: 48))
          .foregroundColor(.white.opacity(0.28))
        Text("当前曲目暂无同步歌词")
          .font(.system(size: 20, weight: .bold))
          .foregroundColor(.white.opacity(0.8))
        Text("自动支持加载 115 / AList 同目录下的同名 .lrc 歌词文件，或从 LRCLIB 匹配云端同步歌词")
          .font(.system(size: 14))
          .foregroundColor(.white.opacity(0.5))
          .multilineTextAlignment(.center)
          .padding(.horizontal, 36)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      let activeIdx = appState.activeCloudLyricIndex
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 10) {
            ForEach(Array(appState.cloudMusicLyrics.enumerated()), id: \.element.id) { idx, line in
              let isCurrent = (idx == activeIdx)
              Button {
                appState.seekCloudMusic(to: line.timeSeconds)
              } label: {
                HStack(spacing: 14) {
                  Text(TvCloudMusicBottomDockBar.formatTime(line.timeSeconds))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(
                      isCurrent
                        ? theme.accentHover
                        : .white.opacity(0.32)
                    )
                    .frame(width: 62, alignment: .leading)

                  Text(line.text)
                    .font(.system(size: isCurrent ? 23 : 17, weight: isCurrent ? .heavy : .medium))
                    .foregroundColor(
                      isCurrent
                        ? theme.accentHover
                        : .white.opacity(0.62)
                    )
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                  RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isCurrent ? theme.accent.opacity(0.18) : Color.clear)
                )
              }
              .buttonStyle(.plain)
              .id(idx)
            }
          }
          .padding(.vertical, 90)
        }
        .onChange(of: activeIdx) { newIdx in
          guard newIdx >= 0 else { return }
          withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(newIdx, anchor: .center)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func playlistQueuePaneView() -> some View {
    let theme = appState.activeTheme
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 8) {
          ForEach(Array(appState.cloudMusicQueue.enumerated()), id: \.offset) { idx, item in
            let isCurrent = (idx == appState.cloudMusicCurrentIndex)
            let meta = TvAppState.parseCloudTrackMetadata(
              item,
              fallbackArtist: appState.mountDisplayName(for: item)
            )
            HStack(spacing: 12) {
              Button {
                appState.playCloudMusicQueueIndex(idx)
              } label: {
                HStack(spacing: 12) {
                  if isCurrent {
                    Image(systemName: "waveform")
                      .font(.system(size: 18, weight: .bold))
                      .foregroundColor(theme.accentHover)
                      .frame(width: 32)
                  } else {
                    Text(String(format: "%02d", idx + 1))
                      .font(.system(size: 14, weight: .bold, design: .monospaced))
                      .foregroundColor(.white.opacity(0.5))
                      .frame(width: 32)
                  }

                  VStack(alignment: .leading, spacing: 3) {
                    Text(meta.title)
                      .font(.system(size: 16, weight: isCurrent ? .heavy : .semibold))
                      .foregroundColor(isCurrent ? theme.accentHover : .white)
                      .lineLimit(1)
                    Text("\(meta.artist) · \(appState.mountDisplayName(for: item)) · \(item.formattedSize)")
                      .font(.system(size: 12))
                      .foregroundColor(.white.opacity(0.6))
                      .lineLimit(1)
                  }

                  Spacer()

                  Text(meta.qualityTag)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.accentHover)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                  RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isCurrent ? theme.accent.opacity(0.22) : Color.white.opacity(0.04))
                )
              }
              .buttonStyle(.plain)

              Button {
                appState.removeCloudMusicTrackAt(idx)
              } label: {
                Image(systemName: "trash")
                  .font(.system(size: 14))
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))
            }
            .id("queue_\(idx)")
          }
        }
        .padding(.vertical, 6)
      }
      .onAppear {
        if appState.cloudMusicCurrentIndex >= 0 {
          proxy.scrollTo("queue_\(appState.cloudMusicCurrentIndex)", anchor: .center)
        }
      }
    }
  }
}

// MARK: - Multi-Source Music Folder & Archive Picker Sheet (自选文件夹 / 压缩包随机播放)

struct TvMusicFolderPickerSheet: View {
  @EnvironmentObject var appState: TvAppState
  @State private var selectedMount: TvStorageMount? = nil
  @State private var currentPath: String = ""
  @State private var currentTitle: String = "根目录"
  @State private var breadcrumbs: [(path: String, title: String)] = []
  @State private var entries: [TvFileEntry] = []
  @State private var isLoading: Bool = false
  @State private var errorText: String? = nil
  @State private var includeSubfolders: Bool = true
  @State private var selectedItems: [TvSavedMusicFolderItem] = []

  @discardableResult
  private func stepBackFolderIfPossible() -> Bool {
    guard breadcrumbs.count >= 2 else { return false }
    let parent = breadcrumbs[breadcrumbs.count - 2]
    loadDirectory(path: parent.path, title: parent.title)
    return true
  }

  var body: some View {
    let theme = appState.activeTheme
    ZStack {
      TvAmbientBackdropView(imageUrl: appState.ambientBackdropUrl)
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label("自选音乐文件夹 / 压缩包随机播放", systemImage: "folder.badge.plus")
            .font(.system(size: 24, weight: .heavy))
            .foregroundColor(theme.accentHover)
          Spacer()
          if breadcrumbs.count >= 2 {
            Button {
              _ = stepBackFolderIfPossible()
            } label: {
              Label("返回上级", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
          }
          Button("关闭窗口") {
            appState.showMusicFolderPickerSheet = false
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))
        }

        // 1. Storage Mount Switcher
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 10) {
            ForEach(appState.storageMounts) { m in
              let isSel = (selectedMount?.id == m.id)
              Button {
                selectMount(m)
              } label: {
                Label(m.name, systemImage: m.kind.icon)
              }
              .buttonStyle(TvApplePillButtonStyle(isPrimary: isSel, compact: true))
            }
          }
        }
        .focusSection()

        // 2. Saved Music Folders Strip
        if !appState.savedMusicFolders.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              Label("常用音乐源:", systemImage: "star.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.yellow)
              ForEach(appState.savedMusicFolders) { fav in
                let checked = isItemSelected(fav)
                Button {
                  toggleItem(fav)
                } label: {
                  Label("\(fav.mountName): \(fav.title)", systemImage: checked ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(TvApplePillButtonStyle(isPrimary: checked, compact: true))
              }
            }
          }
          .focusSection()
        }

        // 3. Breadcrumbs & Add Current Folder
        HStack(spacing: 10) {
          if breadcrumbs.count >= 2 {
            Button {
              _ = stepBackFolderIfPossible()
            } label: {
              Label("上级", systemImage: "chevron.left")
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
          }
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
              ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { idx, c in
                if idx > 0 {
                  Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                }
                Button(c.title) {
                  loadDirectory(path: c.path, title: c.title)
                }
                .buttonStyle(TvApplePillButtonStyle(isPrimary: idx == breadcrumbs.count - 1, compact: true))
              }
            }
          }
          Spacer()
          if let m = selectedMount {
            let curItem = currentDirAsSavedItem(mount: m)
            Button {
              toggleItem(curItem)
            } label: {
              Label(isItemSelected(curItem) ? "已选当前目录" : "勾选当前目录", systemImage: isItemSelected(curItem) ? "checkmark.square.fill" : "plus.square")
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: isItemSelected(curItem), compact: true))

            Button {
              appState.toggleSavedMusicFolder(curItem)
            } label: {
              Image(systemName: appState.isMusicFolderSaved(mountId: m.id, path: curItem.path) ? "star.fill" : "star")
                .foregroundColor(.yellow)
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
          }
        }
        .focusSection()

        // 4. Directory & Archive List
        Group {
          if isLoading {
            VStack(spacing: 12) {
              ProgressView()
              Text("正在加载目录...")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else if let err = errorText {
            VStack(spacing: 12) {
              Text(err)
                .foregroundColor(.red)
              Button("重试") {
                loadDirectory(path: currentPath, title: currentTitle)
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            ScrollView {
              LazyVStack(spacing: 8) {
                ForEach(entries) { entry in
                  directoryEntryRow(entry: entry, theme: theme)
                }
              }
              .padding(.vertical, 6)
            }
          }
        }
        .frame(maxHeight: 410)
        .padding(12)
        .background(Color.black.opacity(0.26))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .focusSection()

        // 5. Bottom Action Bar
        HStack(spacing: 14) {
          if breadcrumbs.count >= 2 {
            Button {
              _ = stepBackFolderIfPossible()
            } label: {
              Label("返回上级目录 (按遥控返回键)", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
          }

          Button {
            includeSubfolders.toggle()
          } label: {
            Label(
              "自动递归子目录与 .zip / .tar 压缩包",
              systemImage: includeSubfolders ? "checkmark.square.fill" : "square"
            )
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))

          Spacer()

          Button {
            let targets = effectiveTargetSources()
            guard !targets.isEmpty else { return }
            appState.showMusicFolderPickerSheet = false
            Task {
              _ = await appState.scanAndPlayMusicFoldersOrArchives(
                sources: targets,
                shuffle: false,
                includeSubfolders: includeSubfolders,
                openFullscreen: true
              )
            }
          } label: {
            Label("顺序播放", systemImage: "play.fill")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))

          Button {
            let targets = effectiveTargetSources()
            guard !targets.isEmpty else { return }
            appState.showMusicFolderPickerSheet = false
            Task {
              _ = await appState.scanAndPlayMusicFoldersOrArchives(
                sources: targets,
                shuffle: true,
                includeSubfolders: includeSubfolders,
                openFullscreen: true
              )
            }
          } label: {
            Label(
              selectedItems.isEmpty ? "随机播放当前目录全部音乐" : "随机播放所选 (\(selectedItems.count))",
              systemImage: "shuffle"
            )
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: true))
        }
        .focusSection()
      }
      .padding(32)
      .frame(width: 1180)
      .background(.regularMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
    .onAppear {
      appState.musicFolderPickerBackHandler = {
        stepBackFolderIfPossible()
      }
      let m = appState.activeStorageMount
      selectMount(m, initialPathOverride: appState.fileListing.path)
    }
    .onDisappear {
      appState.musicFolderPickerBackHandler = nil
    }
    .onExitCommand {
      if !stepBackFolderIfPossible() {
        appState.showMusicFolderPickerSheet = false
      }
    }
  }

  @ViewBuilder
  private func directoryEntryRow(entry: TvFileEntry, theme: TvThemePalette) -> some View {
    if let mount = selectedMount {
      let item = TvSavedMusicFolderItem(
        mountId: mount.id,
        mountName: mount.name,
        sourceKind: mount.kind,
        path: entry.path,
        title: entry.name,
        isArchive: entry.isStreamableMusicArchive,
        size: entry.size,
        pickcode115: entry.pickcode115
      )
      let isSelectable = entry.isDir || entry.isStreamableMusicArchive
      let checked = isSelectable && isItemSelected(item)

      HStack(spacing: 12) {
        Button {
          if entry.isDir {
            loadDirectory(path: entry.path, title: entry.name)
          } else if entry.isStreamableMusicArchive {
            toggleItem(item)
          }
        } label: {
          HStack(spacing: 12) {
            Image(systemName: entry.iconName)
              .font(.system(size: 18, weight: .bold))
              .foregroundColor(
                entry.isDir
                  ? .yellow
                  : (entry.isStreamableMusicArchive ? .orange : theme.accentHover)
              )
            Text(entry.name)
              .font(.system(size: 16, weight: .semibold))
              .foregroundColor(.white)
              .lineLimit(1)
            Spacer()
            Text(
              entry.isDir
                ? "点击进入子目录"
                : (entry.isStreamableMusicArchive ? "音乐压缩包 · \(entry.formattedSize)" : "音频 · \(entry.formattedSize)")
            )
            .font(.system(size: 13))
            .foregroundColor(.white.opacity(0.6))
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
        }
        .buttonStyle(.plain)

        if isSelectable {
          Button {
            toggleItem(item)
          } label: {
            Label(checked ? "已选" : "勾选", systemImage: checked ? "checkmark.circle.fill" : "plus.circle")
          }
          .buttonStyle(TvApplePillButtonStyle(isPrimary: checked, compact: true))

          Button {
            appState.toggleSavedMusicFolder(item)
          } label: {
            Image(systemName: appState.isMusicFolderSaved(mountId: mount.id, path: entry.path) ? "star.fill" : "star")
              .foregroundColor(.yellow)
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))
        }
      }
    }
  }

  private func selectMount(_ mount: TvStorageMount, initialPathOverride: String? = nil) {
    selectedMount = mount
    let root: String
    switch mount.kind {
    case .server: root = ""
    case .cloud115: root = "0"
    default: root = mount.rootPath
    }
    let startPath = (initialPathOverride != nil && !initialPathOverride!.isEmpty) ? initialPathOverride! : root
    breadcrumbs = [(root, mount.name)]
    if startPath != root {
      breadcrumbs.append((startPath, startPath))
    }
    loadDirectory(path: startPath, title: mount.name, pushCrumb: false)
  }

  private func loadDirectory(path: String, title: String, pushCrumb: Bool = true) {
    guard let mount = selectedMount else { return }
    isLoading = true
    errorText = nil
    currentPath = path
    currentTitle = title
    if pushCrumb {
      if let idx = breadcrumbs.firstIndex(where: { $0.path == path }) {
        breadcrumbs = Array(breadcrumbs.prefix(idx + 1))
      } else {
        breadcrumbs.append((path, title))
      }
    }
    Task {
      do {
        var list = try await appState.listDirectoryForMount(mount: mount, path: path)
        list = list.filter { $0.isDir || $0.isAudio || $0.isStreamableMusicArchive }
        self.entries = list
        self.isLoading = false
      } catch {
        self.errorText = error.localizedDescription
        self.isLoading = false
      }
    }
  }

  private func currentDirAsSavedItem(mount: TvStorageMount) -> TvSavedMusicFolderItem {
    TvSavedMusicFolderItem(
      mountId: mount.id,
      mountName: mount.name,
      sourceKind: mount.kind,
      path: currentPath,
      title: currentTitle,
      isArchive: false,
      size: 0,
      pickcode115: ""
    )
  }

  private func isItemSelected(_ item: TvSavedMusicFolderItem) -> Bool {
    selectedItems.contains { $0.mountId == item.mountId && $0.path == item.path }
  }

  private func toggleItem(_ item: TvSavedMusicFolderItem) {
    if let idx = selectedItems.firstIndex(where: { $0.mountId == item.mountId && $0.path == item.path }) {
      selectedItems.remove(at: idx)
    } else {
      selectedItems.append(item)
    }
  }

  private func effectiveTargetSources() -> [TvSavedMusicFolderItem] {
    if !selectedItems.isEmpty { return selectedItems }
    if let m = selectedMount { return [currentDirAsSavedItem(mount: m)] }
    return []
  }
}

// MARK: - Archive (.zip / .cbz / .tar) Inner Music Browser Sheet (压缩包音乐直读浏览器)

struct TvArchiveMusicBrowserSheet: View {
  @EnvironmentObject var appState: TvAppState
  let archiveEntry: TvFileEntry

  @State private var audioEntries: [TvFileEntry] = []
  @State private var allEntries: [TvFileEntry] = []
  @State private var isLoading: Bool = true
  @State private var errorText: String? = nil

  var body: some View {
    let theme = appState.activeTheme
    ZStack {
      TvAmbientBackdropView(imageUrl: appState.ambientBackdropUrl)
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Label("压缩包音乐直读：\(archiveEntry.name)", systemImage: "doc.zipper")
            .font(.system(size: 24, weight: .heavy))
            .foregroundColor(theme.accentHover)
            .lineLimit(1)
          Spacer()
          Button("关闭") {
            appState.activeArchiveMusicBrowserEntry = nil
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))
        }

        if isLoading {
          VStack(spacing: 14) {
            ProgressView()
            Text("正在通过 HTTP Range 读取压缩包中央目录...")
              .font(.system(size: 16))
              .foregroundColor(.white.opacity(0.75))
          }
          .frame(maxWidth: .infinity, minHeight: 360)
        } else if let err = errorText {
          VStack(spacing: 12) {
            Text("读取压缩包失败：\(err)")
              .foregroundColor(.red)
            Button("重试") {
              inspect()
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
          }
          .frame(maxWidth: .infinity, minHeight: 360)
        } else if audioEntries.isEmpty {
          VStack(spacing: 12) {
            Image(systemName: "music.note")
              .font(.system(size: 46))
              .foregroundColor(.white.opacity(0.35))
            Text("该压缩包内未发现可播放的音频文件（共 \(allEntries.count) 个其他条目）")
              .font(.system(size: 17))
              .foregroundColor(.white.opacity(0.75))
          }
          .frame(maxWidth: .infinity, minHeight: 360)
        } else {
          HStack(spacing: 12) {
            Text("共发现 \(audioEntries.count) 首音频（按需 HTTP Range 流式解压播放，无需下载整包）")
              .font(.system(size: 14, weight: .bold))
              .foregroundColor(theme.accentHover)
            Spacer()
            Button {
              let target = archiveEntry
              appState.activeArchiveMusicBrowserEntry = nil
              Task {
                _ = await appState.playArchiveMusic(archiveEntry: target, shuffle: false, openFullscreen: true)
              }
            } label: {
              Label("顺序播放全部", systemImage: "play.fill")
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))

            Button {
              let target = archiveEntry
              appState.activeArchiveMusicBrowserEntry = nil
              Task {
                _ = await appState.playArchiveMusic(archiveEntry: target, shuffle: true, openFullscreen: true)
              }
            } label: {
              Label("随机播放全部", systemImage: "shuffle")
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
          }
          .focusSection()

          ScrollView {
            LazyVStack(spacing: 8) {
              ForEach(Array(audioEntries.enumerated()), id: \.element.id) { idx, track in
                let meta = TvAppState.parseCloudTrackMetadata(track)
                Button {
                  let target = archiveEntry
                  appState.activeArchiveMusicBrowserEntry = nil
                  Task {
                    _ = await appState.playArchiveMusic(
                      archiveEntry: target,
                      shuffle: false,
                      startWithInnerTrack: track,
                      openFullscreen: true
                    )
                  }
                } label: {
                  HStack(spacing: 12) {
                    Text(String(format: "%02d", idx + 1))
                      .font(.system(size: 14, weight: .bold, design: .monospaced))
                      .foregroundColor(.white.opacity(0.55))
                      .frame(width: 34)
                    Image(systemName: "waveform.circle.fill")
                      .font(.system(size: 20))
                      .foregroundColor(theme.accentHover)
                    VStack(alignment: .leading, spacing: 3) {
                      Text(meta.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                      Text("\(track.archiveInnerPath) · \(track.formattedSize)")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                    }
                    Spacer()
                    Text(meta.qualityTag)
                      .font(.system(size: 12, weight: .bold))
                      .foregroundColor(theme.accentHover)
                      .padding(.horizontal, 10)
                      .padding(.vertical, 4)
                      .background(Color.white.opacity(0.08))
                      .clipShape(Capsule())
                  }
                  .padding(.horizontal, 14)
                  .padding(.vertical, 10)
                  .background(Color.white.opacity(0.05))
                  .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
              }
            }
          }
          .frame(maxHeight: 420)
          .focusSection()
        }
      }
      .padding(32)
      .frame(width: 1080)
      .background(.regularMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
    .onAppear {
      inspect()
    }
  }

  private func inspect() {
    isLoading = true
    errorText = nil
    Task {
      do {
        let all = try await appState.inspectArchiveEntries(archiveEntry)
        self.allEntries = all
        self.audioEntries = all.filter { $0.isAudio }
        self.isLoading = false
      } catch {
        self.errorText = error.localizedDescription
        self.isLoading = false
      }
    }
  }
}
