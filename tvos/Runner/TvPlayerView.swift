import AVFoundation
import AVKit
import CoreImage.CIFilterBuiltins
import ImageIO
import SwiftUI
import UIKit

// MARK: - Apple tvOS Human Interface Guidelines (HIG) Shared Design Components

/// Crisp QR Code Generator View for tvOS LAN Mobile Input & 115 QR Login (Cached & Equatable so it never flickers on parent rebuilds)
struct TvQRCodeImageView: View, Equatable {
  let content: String
  var size: CGFloat = 200

  private static let sharedCIContext = CIContext()
  @MainActor private static var qrImageCache: [String: UIImage] = [:]

  static func == (lhs: TvQRCodeImageView, rhs: TvQRCodeImageView) -> Bool {
    lhs.content == rhs.content && lhs.size == rhs.size
  }

  var body: some View {
    if let img = Self.cachedOrGenerateQRCode(from: content) {
      Image(uiImage: img)
        .interpolation(.none)
        .resizable()
        .scaledToFit()
        .frame(width: size, height: size)
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    } else {
      ZStack {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .fill(Color.white)
          .frame(width: size + 28, height: size + 28)
        Image(systemName: "qrcode")
          .font(.system(size: size * 0.45))
          .foregroundColor(.black)
      }
    }
  }

  @MainActor
  private static func cachedOrGenerateQRCode(from string: String) -> UIImage? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let hit = qrImageCache[trimmed] {
      return hit
    }
    guard let data = trimmed.data(using: .utf8) else { return nil }
    let filter = CIFilter.qrCodeGenerator()
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let outputImage = filter.outputImage else { return nil }
    let transform = CGAffineTransform(scaleX: 10, y: 10)
    let scaledImage = outputImage.transformed(by: transform)
    guard let cgImage = sharedCIContext.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
    let img = UIImage(cgImage: cgImage)
    if qrImageCache.count > 32 {
      qrImageCache.removeAll(keepingCapacity: true)
    }
    qrImageCache[trimmed] = img
    return img
  }
}

/// Apple TV+ / Infuse style full-screen cinema backdrop
/// Pure GPU-accelerated gradient without expensive 90px live Gaussian blur passes
struct TvAmbientBackdropView: View {
  let imageUrl: String

  var body: some View {
    let screenW = UIScreen.main.bounds.width
    let screenH = UIScreen.main.bounds.height
    let palette = TvThemePalette.current

    ZStack {
      palette.bgPrimary

      RadialGradient(
        colors: [
          palette.accent.opacity(0.15),
          palette.bgElevated.opacity(0.45),
          Color.clear
        ],
        center: .topLeading,
        startRadius: 40,
        endRadius: screenW * 0.70
      )

      LinearGradient(
        colors: [
          palette.bgPrimary.opacity(0.80),
          palette.bgElevated.opacity(0.90),
          palette.bgPrimary
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    }
    .frame(width: screenW, height: screenH)
    .clipped()
    .ignoresSafeArea()
    .allowsHitTesting(false)
  }
}

/// Apple tvOS Liquid Glass Pill Button Style (Dynamic Theme Accent + Soft Scale + Zero Offscreen Shadow When Unfocused)
struct TvApplePillButtonStyle: ButtonStyle {
  var isSelected: Bool = false
  var isPrimary: Bool = false
  var isDestructive: Bool = false
  var compact: Bool = false

  func makeBody(configuration: Configuration) -> some View {
    TvApplePillButtonBody(
      configuration: configuration,
      isSelected: isSelected,
      isPrimary: isPrimary,
      isDestructive: isDestructive,
      compact: compact
    )
  }

  private struct TvApplePillButtonBody: View {
    @Environment(\.isFocused) private var isFocused
    let configuration: Configuration
    let isSelected: Bool
    let isPrimary: Bool
    let isDestructive: Bool
    let compact: Bool

    var body: some View {
      let palette = TvThemePalette.current
      let bgFill: Color = {
        if isFocused {
          if isDestructive { return Color(red: 0.92, green: 0.26, blue: 0.24) }
          if isPrimary { return palette.accentHover }
          return Color.white
        }
        if isDestructive { return Color(red: 0.88, green: 0.26, blue: 0.24).opacity(0.22) }
        if isPrimary { return palette.accent }
        if isSelected { return palette.accent.opacity(0.32) }
        return Color.white.opacity(0.11)
      }()

      let fgColor: Color = {
        if isFocused {
          return (isPrimary || isDestructive) ? .white : Color(red: 0.06, green: 0.08, blue: 0.12)
        }
        if isDestructive { return Color(red: 1.0, green: 0.45, blue: 0.42) }
        if isSelected { return palette.accentHover }
        return .white
      }()

      configuration.label
        .font(.system(size: compact ? 15 : 17, weight: (isFocused || isSelected || isPrimary) ? .semibold : .medium))
        .foregroundColor(fgColor)
        .padding(.horizontal, compact ? 14 : 18)
        .padding(.vertical, compact ? 7 : 9)
        .background(
          Capsule(style: .continuous)
            .fill(bgFill)
        )
        .overlay(
          Capsule(style: .continuous)
            .stroke(
              isFocused
                ? Color.white.opacity(0.92)
                : (isSelected ? palette.accentHover.opacity(0.80) : Color.white.opacity(0.14)),
              lineWidth: isFocused ? 2.0 : 1.0
            )
        )
        .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.03 : 1.0))
    }
  }
}

/// Apple tvOS Glass Surface Card Button Style (Zero Offscreen Shadow / Zero Spring Overhead for High-Density Lists)
struct TvAppleSurfaceButtonStyle: ButtonStyle {
  var isSelected: Bool = false
  var cornerRadius: CGFloat = 14

  func makeBody(configuration: Configuration) -> some View {
    TvAppleSurfaceBody(configuration: configuration, isSelected: isSelected, cornerRadius: cornerRadius)
  }

  private struct TvAppleSurfaceBody: View {
    @Environment(\.isFocused) private var isFocused
    let configuration: Configuration
    let isSelected: Bool
    let cornerRadius: CGFloat

    var body: some View {
      let palette = TvThemePalette.current
      configuration.label
        .background(
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
              isFocused
                ? palette.accent.opacity(0.28)
                : (isSelected ? palette.accent.opacity(0.18) : palette.bgCard.opacity(0.88))
            )
        )
        .overlay(
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(
              isFocused
                ? palette.accentHover
                : (isSelected ? palette.accentHover.opacity(0.68) : Color.white.opacity(0.10)),
              lineWidth: isFocused ? 2.4 : 1.0
            )
        )
        .scaleEffect(configuration.isPressed ? 0.98 : (isFocused ? 1.015 : 1.0))
    }
  }
}

/// Thread-safe in-memory cache & 4-slot concurrent downloader for Telegram inline preview avatars & High-Definition (`/api/telegram/avatar`) avatars
/// (1:1 match with `_TelegramPeerAvatar` in `lib/ui/screens/telegram_screen.dart`)
@MainActor
final class TvTelegramAvatarMemoryCache {
  static let shared = TvTelegramAvatarMemoryCache()
  private let previewCache = NSCache<NSString, UIImage>()
  private let hdCache = NSCache<NSString, UIImage>()
  private let remoteImageCache = NSCache<NSString, UIImage>()
  // Persistent pinned dictionaries that survive tvOS background suspension (unlike NSCache which auto-purges on backgrounding)
  private var pinnedPreviews: [String: UIImage] = [:]
  private var pinnedHdAvatars: [String: UIImage] = [:]
  private var pinnedHdOrder: [String] = []
  private var pinnedRemoteImages: [String: UIImage] = [:]
  private var pinnedRemoteOrder: [String] = []
  private var inFlightTasks: [String: Task<UIImage?, Never>] = [:]
  private var inFlightRemoteTasks: [String: Task<UIImage?, Never>] = [:]
  private var failedHdCooldownUntil: [String: Date] = [:]
  private var failedRemoteUrls: Set<String> = []
  private var downloadQueue: [() -> Void] = []
  private var activeDownloads: Int = 0
  private let maxConcurrentDownloads: Int = 6
  private var remoteDownloadQueue: [() -> Void] = []
  private var activeRemoteDownloads: Int = 0
  private let maxConcurrentRemoteDownloads: Int = 8
  private var avatarSession: URLSession

  private init() {
    previewCache.countLimit = 600
    hdCache.countLimit = 400
    remoteImageCache.countLimit = 400
    self.avatarSession = Self.makeAvatarSession()
  }

  private static func makeAvatarSession() -> URLSession {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 14
    cfg.timeoutIntervalForResource = 22
    cfg.httpMaximumConnectionsPerHost = 8
    cfg.httpShouldSetCookies = true
    return URLSession(
      configuration: cfg,
      delegate: InsecureSessionDelegate(),
      delegateQueue: nil
    )
  }

  /// Cancels any half-open background download tasks and refreshes keep-alive sockets when returning from background
  func handleAppLifecycleTransition(enteringBackground: Bool) {
    for (_, t) in inFlightTasks { t.cancel() }
    inFlightTasks.removeAll()
    downloadQueue.removeAll()
    activeDownloads = 0

    for (_, t) in inFlightRemoteTasks { t.cancel() }
    inFlightRemoteTasks.removeAll()
    remoteDownloadQueue.removeAll()
    activeRemoteDownloads = 0

    if !enteringBackground {
      failedHdCooldownUntil.removeAll()
      avatarSession.flush {}
    }
  }

  func decodePreviewDataUri(_ raw: String) -> UIImage? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("data:image"), let comma = trimmed.firstIndex(of: ",") else {
      return nil
    }
    if let pinned = pinnedPreviews[trimmed] {
      return pinned
    }
    let key = trimmed as NSString
    if let cached = previewCache.object(forKey: key) {
      pinnedPreviews[trimmed] = cached
      return cached
    }
    let b64 = String(trimmed[trimmed.index(after: comma)...])
      .components(separatedBy: .whitespacesAndNewlines)
      .joined()
    guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
          let img = UIImage(data: data) else {
      return nil
    }
    previewCache.setObject(img, forKey: key)
    if pinnedPreviews.count > 400 {
      pinnedPreviews.removeAll(keepingCapacity: true)
    }
    pinnedPreviews[trimmed] = img
    return img
  }

  func cachedHdImage(for url: String) -> UIImage? {
    let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return nil }
    if let pinned = pinnedHdAvatars[clean] {
      return pinned
    }
    if let hit = hdCache.object(forKey: clean as NSString) {
      pinnedHdAvatars[clean] = hit
      return hit
    }
    return nil
  }

  func storeHdImage(_ image: UIImage, for url: String) {
    let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    hdCache.setObject(image, forKey: clean as NSString)
    if pinnedHdAvatars[clean] == nil {
      pinnedHdOrder.append(clean)
      if pinnedHdOrder.count > 220 {
        let old = pinnedHdOrder.removeFirst()
        pinnedHdAvatars.removeValue(forKey: old)
      }
    }
    pinnedHdAvatars[clean] = image
  }

  func cachedRemoteImage(for key: String) -> UIImage? {
    guard !key.isEmpty else { return nil }
    if let pinned = pinnedRemoteImages[key] {
      return pinned
    }
    if let hit = remoteImageCache.object(forKey: key as NSString) {
      pinnedRemoteImages[key] = hit
      return hit
    }
    return nil
  }

  func storeRemoteImage(_ image: UIImage, for key: String) {
    guard !key.isEmpty else { return }
    remoteImageCache.setObject(image, forKey: key as NSString)
    if pinnedRemoteImages[key] == nil {
      pinnedRemoteOrder.append(key)
      if pinnedRemoteOrder.count > 180 {
        let old = pinnedRemoteOrder.removeFirst()
        pinnedRemoteImages.removeValue(forKey: old)
      }
    }
    pinnedRemoteImages[key] = image
  }

  func isRemoteUrlFailed(_ key: String) -> Bool {
    failedRemoteUrls.contains(key)
  }

  func markRemoteUrlFailed(_ key: String) {
    if failedRemoteUrls.count > 1000 { failedRemoteUrls.removeAll() }
    failedRemoteUrls.insert(key)
  }

  /// Deduplicated, 6-slot queued HD avatar fetcher (survives SwiftUI view rebuilds without cancelling in-flight MTProto photo downloads)
  func fetchHdAvatar(hdUrl: String, serverUrl: String, authHeaders: [String: String]) async -> UIImage? {
    let clean = hdUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return nil }
    if let cached = cachedHdImage(for: clean) {
      return cached
    }
    let now = Date()
    if let cooldown = failedHdCooldownUntil[clean], cooldown > now {
      return nil
    }
    if let existingTask = inFlightTasks[clean] {
      return await existingTask.value
    }

    let fullUrlStr = clean.hasPrefix("/") ? "\(serverUrl)\(clean)" : clean
    guard let url = URL(string: fullUrlStr) else {
      return nil
    }

    let sessionRef = self.avatarSession
    let task = Task<UIImage?, Never> { @MainActor in
      await withCheckedContinuation { (slotCont: CheckedContinuation<Void, Never>) in
        if self.activeDownloads < self.maxConcurrentDownloads {
          self.activeDownloads += 1
          slotCont.resume()
        } else {
          self.downloadQueue.append {
            self.activeDownloads += 1
            slotCont.resume()
          }
        }
      }
      defer {
        self.inFlightTasks.removeValue(forKey: clean)
        self.activeDownloads = max(0, self.activeDownloads - 1)
        if !self.downloadQueue.isEmpty && self.activeDownloads < self.maxConcurrentDownloads {
          let next = self.downloadQueue.removeFirst()
          next()
        }
      }

      for attempt in 0..<2 {
        var req = URLRequest(url: url)
        req.timeoutInterval = attempt == 0 ? 15 : 20
        for (k, v) in authHeaders {
          req.setValue(v, forHTTPHeaderField: k)
        }
        if let (data, resp) = try? await sessionRef.data(for: req),
           let http = resp as? HTTPURLResponse {
          if (200..<300).contains(http.statusCode),
             !data.isEmpty,
             let img = UIImage(data: data) {
            self.failedHdCooldownUntil.removeValue(forKey: clean)
            self.storeHdImage(img, for: clean)
            return img
          }
          if http.statusCode == 404 || http.statusCode == 400 {
            self.failedHdCooldownUntil[clean] = Date().addingTimeInterval(45)
            return nil
          }
        }
        if attempt == 0 {
          try? await Task.sleep(nanoseconds: 250_000_000)
        }
      }
      self.failedHdCooldownUntil[clean] = Date().addingTimeInterval(15)
      return nil
    }

    inFlightTasks[clean] = task
    return await task.value
  }
  /// Deduplicated, 8-slot queued remote poster/thumbnail fetcher with off-main-thread ImageIO downsampling
  func fetchRemoteImage(rawUrl: String) async -> UIImage? {
    let trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "<null>" else { return nil }
    if let cached = cachedRemoteImage(for: trimmed) {
      return cached
    }
    if isRemoteUrlFailed(trimmed) {
      return nil
    }
    if trimmed.hasPrefix("data:image"), let img = decodePreviewDataUri(trimmed) {
      storeRemoteImage(img, for: trimmed)
      return img
    }
    if let existing = inFlightRemoteTasks[trimmed] {
      return await existing.value
    }

    guard let appState = TvAppState.shared else { return nil }
    let serverUrl = appState.serverUrl
    let authHeaders = appState.api.authHeaders
    let imageSession = appState.api.imageSession
    let proxyStr = appState.api.buildProxiedImageUrl(
      TvApiClient.splitUrlAndInlineHeaders(trimmed).cleanUrl.hasPrefix("/")
        ? "\(serverUrl)\(TvApiClient.splitUrlAndInlineHeaders(trimmed).cleanUrl)"
        : TvApiClient.splitUrlAndInlineHeaders(trimmed).cleanUrl
    )

    let task = Task<UIImage?, Never> { @MainActor in
      await withCheckedContinuation { (slotCont: CheckedContinuation<Void, Never>) in
        if self.activeRemoteDownloads < self.maxConcurrentRemoteDownloads {
          self.activeRemoteDownloads += 1
          slotCont.resume()
        } else {
          self.remoteDownloadQueue.append {
            self.activeRemoteDownloads += 1
            slotCont.resume()
          }
        }
      }
      defer {
        self.inFlightRemoteTasks.removeValue(forKey: trimmed)
        self.activeRemoteDownloads = max(0, self.activeRemoteDownloads - 1)
        if !self.remoteDownloadQueue.isEmpty && self.activeRemoteDownloads < self.maxConcurrentRemoteDownloads {
          let next = self.remoteDownloadQueue.removeFirst()
          next()
        }
      }

      if Task.isCancelled { return nil }
      let split = TvApiClient.splitUrlAndInlineHeaders(trimmed)
      let cleanUrl = split.cleanUrl.hasPrefix("/")
        ? "\(serverUrl)\(split.cleanUrl)"
        : split.cleanUrl

      if let directUrl = URL(string: cleanUrl) {
        var req = URLRequest(url: directUrl)
        req.timeoutInterval = 7
        if cleanUrl.contains("/api/telegram/") || cleanUrl.contains(serverUrl) {
          for (k, v) in authHeaders {
            req.setValue(v, forHTTPHeaderField: k)
          }
        } else {
          req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
          )
        }
        for (k, v) in split.headers {
          req.setValue(v, forHTTPHeaderField: k)
        }
        if let (data, resp) = try? await imageSession.data(for: req),
           let http = resp as? HTTPURLResponse,
           (200..<300).contains(http.statusCode),
           !data.isEmpty {
          if Task.isCancelled { return nil }
          let decoded = await Task.detached(priority: .utility) {
            Self.decodeAndDownsampleImage(data: data, maxPixelSize: 440)
          }.value
          if let img = decoded {
            self.storeRemoteImage(img, for: trimmed)
            return img
          }
        }
      }

      if Task.isCancelled { return nil }
      if !cleanUrl.contains("/api/telegram/") && !cleanUrl.contains("/api/vod/image"),
         let proxyUrl = URL(string: proxyStr) {
        var req = URLRequest(url: proxyUrl)
        req.timeoutInterval = 8
        for (k, v) in authHeaders {
          req.setValue(v, forHTTPHeaderField: k)
        }
        if let (data, resp) = try? await imageSession.data(for: req),
           let http = resp as? HTTPURLResponse,
           (200..<300).contains(http.statusCode),
           !data.isEmpty {
          if Task.isCancelled { return nil }
          let decoded = await Task.detached(priority: .utility) {
            Self.decodeAndDownsampleImage(data: data, maxPixelSize: 440)
          }.value
          if let img = decoded {
            self.storeRemoteImage(img, for: trimmed)
            return img
          }
        }
      }

      if !Task.isCancelled {
        self.markRemoteUrlFailed(trimmed)
      }
      return nil
    }

    inFlightRemoteTasks[trimmed] = task
    return await task.value
  }

  nonisolated static func decodeAndDownsampleImage(data: Data, maxPixelSize: Int = 460) -> UIImage? {
    let options: [CFString: Any] = [
      kCGImageSourceShouldCache: false
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
      return UIImage(data: data)
    }
    let thumbOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ]
    if let cgImg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
      return UIImage(cgImage: cgImg)
    }
    return UIImage(data: data)
  }
}

/// Official Telegram Peer Avatar View (1:1 Match with _TelegramPeerAvatar in lib/ui/screens/telegram_screen.dart:
/// Shows instant 0ms inline base64 preview or gradient initials, then seamlessly upgrades to crisp HD /api/telegram/avatar!)
struct TvTelegramPeerAvatar: View {
  @EnvironmentObject var appState: TvAppState
  let peer: String
  let title: String
  var avatarUrl: String = ""
  var previewAvatar: String = ""
  var isSelf: Bool = false
  var size: CGFloat = 52
  var fontSize: CGFloat = 20

  @State private var loadedHdImage: UIImage? = nil
  @State private var loadedHdUrl: String = ""

  private var initials: String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "TG" }
    let chars = Array(trimmed)
    if chars.count >= 2, chars[0].isASCII && chars[1].isASCII {
      return String(chars.prefix(2)).uppercased()
    }
    return String(chars.prefix(1)).uppercased()
  }

  var body: some View {
    let regVersion = appState.telegramAvatarRegistryVersion
    let colors = TvTelegramPalette.peerAvatarColors(peer.isEmpty ? title : peer)
    let hdUrl = appState.resolvePeerHdAvatarUrl(peer: peer, title: title, explicit: avatarUrl)
    let resolvedPrev = appState.resolvePeerPreviewAvatar(peer: peer, title: title, explicit: previewAvatar.isEmpty ? avatarUrl : previewAvatar)
    let previewRaw = (!previewAvatar.isEmpty && previewAvatar.hasPrefix("data:image/")) ? previewAvatar : resolvedPrev
    let validLoadedHd = (!hdUrl.isEmpty && loadedHdUrl == hdUrl) ? loadedHdImage : nil
    let activeHdImage = TvTelegramAvatarMemoryCache.shared.cachedHdImage(for: hdUrl) ?? validLoadedHd
    let previewImage = activeHdImage == nil ? TvTelegramAvatarMemoryCache.shared.decodePreviewDataUri(previewRaw) : nil

    ZStack {
      if isSelf || peer == "self" || peer.hasPrefix("self:") || title.hasPrefix("收藏夹") {
        Circle()
          .fill(
            LinearGradient(
              colors: [Color(red: 0.35, green: 0.75, blue: 0.98), Color(red: 0.18, green: 0.55, blue: 0.92)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
        Image(systemName: "bookmark.fill")
          .font(.system(size: fontSize, weight: .bold))
          .foregroundColor(.white)
      } else if let hdImg = activeHdImage {
        Image(uiImage: hdImg)
          .renderingMode(.original)
          .interpolation(.high)
          .antialiased(true)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: size, height: size)
          .clipShape(Circle())
      } else if let prevImg = previewImage {
        Image(uiImage: prevImg)
          .renderingMode(.original)
          .interpolation(.high)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: size, height: size)
          .clipShape(Circle())
      } else {
        Circle()
          .fill(
            LinearGradient(
              colors: colors,
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
        Text(initials)
          .font(.system(size: fontSize, weight: .bold, design: .rounded))
          .foregroundColor(.white)
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .id(activeHdImage != nil ? "hd_\(hdUrl)" : "prev_\(peer)_\(title)_\(!previewRaw.isEmpty)")
    .task(id: "\(peer)|\(title)|\(hdUrl)|\(regVersion)") {
      await fetchHdAvatarIfNeeded(hdUrl: hdUrl)
    }
  }

  private func fetchHdAvatarIfNeeded(hdUrl: String) async {
    let clean = hdUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else {
      loadedHdImage = nil
      loadedHdUrl = ""
      return
    }
    if let cached = TvTelegramAvatarMemoryCache.shared.cachedHdImage(for: clean) {
      if loadedHdUrl != clean || loadedHdImage == nil {
        loadedHdImage = cached
        loadedHdUrl = clean
      }
      return
    }
    if let img = await TvTelegramAvatarMemoryCache.shared.fetchHdAvatar(
      hdUrl: clean,
      serverUrl: appState.serverUrl,
      authHeaders: appState.api.authHeaders
    ) {
      self.loadedHdImage = img
      self.loadedHdUrl = clean
    }
  }
}

// MARK: - Smart Remote Image Loader (Zero @EnvironmentObject Dependency + Background ImageIO Downsampling & Pre-Decoding)

struct TvRemoteImage: View, Equatable {
  let rawUrl: String
  var placeholderIcon: String = "film"
  var contentMode: ContentMode = .fill

  static func == (lhs: TvRemoteImage, rhs: TvRemoteImage) -> Bool {
    lhs.rawUrl == rhs.rawUrl && lhs.placeholderIcon == rhs.placeholderIcon && lhs.contentMode == rhs.contentMode
  }

  @State private var loadedImage: UIImage? = nil
  @State private var loadedForUrl: String = ""

  var body: some View {
    let trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    let activeImage = TvTelegramAvatarMemoryCache.shared.cachedRemoteImage(for: trimmed)
      ?? ((loadedForUrl == trimmed) ? loadedImage : nil)

    ZStack {
      if let img = activeImage {
        Image(uiImage: img)
          .resizable()
          .aspectRatio(contentMode: contentMode)
      } else {
        Color.white.opacity(0.06)
        Image(systemName: placeholderIcon)
          .font(.system(size: 26, weight: .light))
          .foregroundColor(.white.opacity(0.32))
      }
    }
    .clipped()
    .task(id: rawUrl) {
      await loadImage()
    }
  }

  private func loadImage() async {
    let trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "<null>" else {
      loadedImage = nil
      return
    }
    if let cached = TvTelegramAvatarMemoryCache.shared.cachedRemoteImage(for: trimmed) {
      if loadedForUrl != trimmed || loadedImage == nil {
        loadedImage = cached
        loadedForUrl = trimmed
      }
      return
    }
    if let img = await TvTelegramAvatarMemoryCache.shared.fetchRemoteImage(rawUrl: trimmed) {
      self.loadedImage = img
      self.loadedForUrl = trimmed
    }
  }
}

// MARK: - Real-Time Video Download Speed Badge (1:1 Port of VideoDownloadSpeedBadge in lib/ui/widgets/video_download_speed_badge.dart)

struct TvVideoDownloadSpeedBadge: View {
  let player: AVPlayer
  var isBuffering: Bool = false
  var compact: Bool = false

  @State private var smoothedBytesPerSec: Double = 0.0
  @State private var lastSampleTimeMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
  @State private var lastAccessLogBytes: Int64 = -1
  @State private var lastBufferSec: Double = 0.0
  @State private var lastPlaySec: Double = 0.0
  private let sampleTimer = Timer.publish(every: 0.9, on: .main, in: .common).autoconnect()

  static func formatBytesPerSecond(_ bytesPerSecond: Double, includeArrow: Bool = true) -> String {
    let prefix = includeArrow ? "↓ " : ""
    guard bytesPerSecond.isFinite, bytesPerSecond > 512 else {
      return "\(prefix)0 KB/s"
    }
    let kb = 1024.0
    let mb = 1024.0 * 1024.0
    if bytesPerSecond >= mb {
      let val = bytesPerSecond / mb
      return val >= 10
        ? String(format: "%@%.1f MB/s", prefix, val)
        : String(format: "%@%.2f MB/s", prefix, val)
    }
    let kbVal = bytesPerSecond / kb
    return kbVal >= 10
      ? String(format: "%@%.0f KB/s", prefix, kbVal)
      : String(format: "%@%.1f KB/s", prefix, kbVal)
  }

  var body: some View {
    let palette = TvThemePalette.current
    let label = Self.formatBytesPerSecond(smoothedBytesPerSec, includeArrow: true)
    let isActiveSpeed = smoothedBytesPerSec > 1024

    HStack(spacing: compact ? 5 : 7) {
      Image(systemName: "speedometer")
        .font(.system(size: compact ? 13 : 15, weight: .semibold))
        .foregroundColor(
          isActiveSpeed
            ? Color(red: 0.19, green: 0.82, blue: 0.35)
            : palette.accentHover
        )

      Text(label)
        .font(.system(size: compact ? 14 : 16, weight: .semibold, design: .monospaced))
        .foregroundColor(.white)
        .lineLimit(1)
    }
    .padding(.horizontal, compact ? 11 : 14)
    .padding(.vertical, compact ? 5 : 7)
    .background(
      Capsule(style: .continuous)
        .fill(Color(red: 0.04, green: 0.07, blue: 0.11).opacity(0.84))
    )
    .overlay(
      Capsule(style: .continuous)
        .stroke(
          isBuffering
            ? palette.accentHover.opacity(0.78)
            : Color.white.opacity(0.18),
          lineWidth: 1.0
        )
    )
    .fixedSize(horizontal: true, vertical: false)
    .allowsHitTesting(false)
    .onAppear {
      lastSampleTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
      sampleCurrentSpeed()
    }
    .onReceive(sampleTimer) { _ in
      sampleCurrentSpeed()
    }
  }

  private func sampleCurrentSpeed() {
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    let elapsedSec = min(max(Double(nowMs - lastSampleTimeMs) / 1000.0, 0.2), 5.0)
    lastSampleTimeMs = nowMs

    let isPlaying = (player.timeControlStatus == .playing || player.rate > 0 || TvNetworkSpeedMonitor.shared.recentDownstreamBytesPerSecond > 1024)
    let isWaiting = (player.timeControlStatus == .waitingToPlayAtSpecifiedRate || isBuffering)

    var curPosSec = player.currentTime().seconds
    if !curPosSec.isFinite || curPosSec < 0 { curPosSec = 0 }

    var curBufferSec = curPosSec
    var accessLogDeltaRate = 0.0
    var observedBitrateBytesPerSec = 0.0
    var mediaBitrateBytesPerSec = 0.0
    var videoWidth: CGFloat = 0

    if let curItem = player.currentItem {
      videoWidth = curItem.presentationSize.width
      if let firstRange = curItem.loadedTimeRanges.first?.timeRangeValue {
        let endSec = CMTimeGetSeconds(firstRange.start) + CMTimeGetSeconds(firstRange.duration)
        if endSec.isFinite && endSec > curBufferSec {
          curBufferSec = endSec
        }
      }

      if let events = curItem.accessLog()?.events, !events.isEmpty {
        let totalTransferred = events.reduce(Int64(0)) { acc, ev in
          acc + max(0, ev.numberOfBytesTransferred)
        }
        var bytesChanged = false
        if totalTransferred > 0 {
          if lastAccessLogBytes >= 0 && totalTransferred > lastAccessLogBytes {
            accessLogDeltaRate = Double(totalTransferred - lastAccessLogBytes) / elapsedSec
            bytesChanged = true
          }
          lastAccessLogBytes = totalTransferred
        }
        if let lastEv = events.last {
          if (bytesChanged || isWaiting), lastEv.observedBitrate.isFinite, lastEv.observedBitrate > 0 {
            let obsBytes = lastEv.observedBitrate / 8.0
            if obsBytes < 120 * 1024 * 1024 {
              observedBitrateBytesPerSec = obsBytes
            }
          }
          let vBit = lastEv.averageVideoBitrate.isFinite && lastEv.averageVideoBitrate > 0 ? lastEv.averageVideoBitrate : 0
          let aBit = lastEv.averageAudioBitrate.isFinite && lastEv.averageAudioBitrate > 0 ? lastEv.averageAudioBitrate : 0
          if vBit + aBit > 0 {
            mediaBitrateBytesPerSec = (vBit + aBit) / 8.0
          } else if lastEv.indicatedBitrate.isFinite && lastEv.indicatedBitrate > 0 {
            mediaBitrateBytesPerSec = lastEv.indicatedBitrate / 8.0
          }
        }
      }
    }

    let deltaBufferSec = curBufferSec - lastBufferSec
    let deltaPlaySec = curPosSec - lastPlaySec
    lastBufferSec = curBufferSec
    lastPlaySec = curPosSec

    let proxyRate = (isPlaying || isWaiting) ? TvNetworkSpeedMonitor.shared.recentDownstreamBytesPerSecond : 0.0

    var measured = proxyRate
    if accessLogDeltaRate > measured { measured = accessLogDeltaRate }
    if observedBitrateBytesPerSec > measured && measured <= 0 {
      measured = observedBitrateBytesPerSec
    }

    // When HLS segments download in bursts, between segment fetches while buffer or playback is advancing:
    if measured <= 0 && (isPlaying || isWaiting) {
      let effectiveStreamRate: Double
      if mediaBitrateBytesPerSec > 16384 {
        effectiveStreamRate = mediaBitrateBytesPerSec
      } else if videoWidth >= 1920 {
        effectiveStreamRate = 420 * 1024.0
      } else if videoWidth >= 1280 {
        effectiveStreamRate = 260 * 1024.0
      } else {
        effectiveStreamRate = 185 * 1024.0
      }

      if deltaBufferSec > 0.15 {
        measured = min(max(deltaBufferSec / elapsedSec, 0.4), 6.0) * effectiveStreamRate
      } else if isPlaying && deltaPlaySec > 0.1 {
        if mediaBitrateBytesPerSec > 0 {
          measured = mediaBitrateBytesPerSec
        } else if smoothedBytesPerSec > 32 * 1024 {
          measured = smoothedBytesPerSec * 0.72
        } else {
          measured = effectiveStreamRate * 0.85
        }
      }
    }

    let nextSmoothed: Double
    if measured > 0 {
      nextSmoothed = smoothedBytesPerSec <= 1024
        ? measured
        : (smoothedBytesPerSec * 0.42 + measured * 0.58)
    } else if isPlaying || isWaiting {
      let decayed = smoothedBytesPerSec * 0.55
      nextSmoothed = decayed < 1024 ? 0.0 : decayed
    } else {
      nextSmoothed = 0.0
    }

    if abs(nextSmoothed - smoothedBytesPerSec) > 512 || (nextSmoothed == 0 && smoothedBytesPerSec != 0) {
      smoothedBytesPerSec = nextSmoothed
    }
  }
}

// MARK: - Real-Time Proxy IP & Inbound/Outbound Traffic Statistics Overlay Card (1:1 Match with VideoProxyStatsDetailPanel)

struct TvVideoProxyStatsOverlayCard: View {
  @EnvironmentObject var appState: TvAppState
  let scenario: TvRequestScenario
  let onOpenSelector: () -> Void
  let onClose: () -> Void

  @State private var isProbingIp: Bool = false
  @State private var snapshot = TvRealTimeProxyIpSnapshot(
    routeLabel: "检测中...",
    isUsingProxy: false,
    nodeName: "-",
    protocolBadge: "-",
    entryHostPort: "-",
    entryResolvedIp: "解析中...",
    exitPublicIp: "探测中...",
    exitLocation: "",
    exitIsp: "",
    rttMs: 0
  )
  @State private var inSpeed: Double = 0
  @State private var outSpeed: Double = 0
  @State private var totalIn: Int64 = 0
  @State private var totalOut: Int64 = 0
  @State private var activeConns: Int = 0
  @State private var totalReqs: Int = 0
  private let tickTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

  private static func formatSpeed(_ bytesPerSec: Double) -> String {
    guard bytesPerSec.isFinite, bytesPerSec > 0 else { return "0 B/s" }
    let kb = 1024.0
    let mb = kb * 1024.0
    if bytesPerSec >= mb {
      return String(format: "%.2f MB/s", bytesPerSec / mb)
    }
    if bytesPerSec >= kb {
      return String(format: "%.1f KB/s", bytesPerSec / kb)
    }
    return String(format: "%.0f B/s", bytesPerSec)
  }

  private static func formatBytes(_ bytes: Int64) -> String {
    if bytes <= 0 { return "0 B" }
    let kb = 1024.0
    let mb = kb * 1024.0
    let gb = mb * 1024.0
    let d = Double(bytes)
    if d >= gb {
      return String(format: "%.2f GB", d / gb)
    }
    if d >= mb {
      return String(format: "%.2f MB", d / mb)
    }
    if d >= kb {
      return String(format: "%.1f KB", d / kb)
    }
    return "\(bytes) B"
  }

  var body: some View {
    let statusColor = snapshot.isUsingProxy
      ? Color(red: 0.20, green: 0.83, blue: 0.60)
      : Color(red: 0.98, green: 0.75, blue: 0.14)

    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Circle()
          .fill(statusColor)
          .frame(width: 10, height: 10)
          .shadow(color: statusColor.opacity(0.75), radius: 6)

        Text("代理实时 IP 与流量监控")
          .font(.system(size: 18, weight: .bold))
          .foregroundColor(.white)

        Spacer()

        Button {
          Task { await refreshTelemetry(force: true) }
        } label: {
          HStack(spacing: 5) {
            if isProbingIp {
              ProgressView()
                .scaleEffect(0.6)
            } else {
              Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .bold))
            }
            Text("刷新IP")
              .font(.system(size: 13, weight: .semibold))
          }
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))

        Button {
          onOpenSelector()
        } label: {
          Label("切换节点", systemImage: "network")
            .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))

        Button {
          onClose()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 14, weight: .bold))
        }
        .buttonStyle(TvApplePillButtonStyle(isDestructive: true, compact: true))
      }

      Divider()
        .background(Color.white.opacity(0.14))

      VStack(alignment: .leading, spacing: 6) {
        infoRow(
          label: "当前模式",
          value: snapshot.routeLabel,
          color: statusColor,
          badge: snapshot.protocolBadge
        )
        infoRow(
          label: "生效节点",
          value: snapshot.nodeName,
          color: .white,
          badge: snapshot.rttMs > 0 ? "\(snapshot.rttMs)ms" : nil
        )
        infoRow(
          label: "入口节点IP",
          value: snapshot.entryResolvedIp,
          color: .white.opacity(0.82),
          monospaced: true
        )
        infoRow(
          label: "实时出口IP",
          value: snapshot.exitPublicIp,
          color: Color(red: 0.22, green: 0.74, blue: 0.97),
          monospaced: true
        )
        if !snapshot.exitLocation.isEmpty || !snapshot.exitIsp.isEmpty {
          let locText = [snapshot.exitLocation, snapshot.exitIsp]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
          infoRow(
            label: "IP 归属地",
            value: locText,
            color: .white.opacity(0.78)
          )
        }
      }

      VStack(spacing: 8) {
        HStack(spacing: 14) {
          metricBox(
            title: "↓ 实时入站速率",
            value: Self.formatSpeed(inSpeed),
            color: Color(red: 0.20, green: 0.83, blue: 0.60)
          )
          Divider()
            .frame(height: 36)
            .background(Color.white.opacity(0.14))
          metricBox(
            title: "↑ 实时出站速率",
            value: Self.formatSpeed(outSpeed),
            color: Color(red: 0.38, green: 0.65, blue: 0.98)
          )
        }
        Divider()
          .background(Color.white.opacity(0.12))
        HStack(spacing: 14) {
          metricBox(
            title: "⬇️ 累计入站流量",
            value: Self.formatBytes(totalIn),
            color: .white
          )
          Divider()
            .frame(height: 36)
            .background(Color.white.opacity(0.14))
          metricBox(
            title: "⬆️ 累计出站流量",
            value: Self.formatBytes(totalOut),
            color: .white
          )
        }
      }
      .padding(12)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(Color.white.opacity(0.06))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(Color.white.opacity(0.10), lineWidth: 1)
      )

      HStack {
        Text("活跃隧道: \(activeConns) · 累计请求: \(totalReqs)")
          .font(.system(size: 13, weight: .medium))
          .foregroundColor(.white.opacity(0.60))
        Spacer()
        Button("清零统计") {
          TvNetworkSpeedMonitor.shared.resetCounters()
          sampleTrafficCounters()
        }
        .buttonStyle(TvApplePillButtonStyle(compact: true))
      }
    }
    .padding(18)
    .frame(width: 520)
    .background(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(Color(red: 0.05, green: 0.08, blue: 0.13).opacity(0.94))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(statusColor.opacity(0.55), lineWidth: 1.5)
    )
    .shadow(color: .black.opacity(0.65), radius: 22, y: 10)
    .focusSection()
    .task(id: "\(appState.proxyEnabled)|\(appState.selectedProxyNodeId)|\(appState.rule(for: scenario).mode.rawValue)|\(appState.rule(for: scenario).specificNodeId ?? "")") {
      sampleTrafficCounters()
      await refreshTelemetry(force: false)
    }
    .onReceive(tickTimer) { _ in
      sampleTrafficCounters()
    }
  }

  private func sampleTrafficCounters() {
    let mon = TvNetworkSpeedMonitor.shared
    inSpeed = mon.recentDownstreamBytesPerSecond
    outSpeed = mon.recentUpstreamBytesPerSecond
    totalIn = mon.totalDownstreamBytes
    totalOut = mon.totalUpstreamBytes
    activeConns = mon.activeTunnelConnections
    totalReqs = mon.totalTunnelRequests
  }

  private func refreshTelemetry(force: Bool) async {
    isProbingIp = true
    let eff = appState.resolveEffectiveRoute(for: scenario)
    let node = appState.resolveNode(for: scenario)
    let info = await TvLocalProxyTunnelServer.shared.probeRealTimeIpInfo(
      node: node,
      routeMode: eff,
      selectionMode: appState.proxySelectionMode,
      forceRefresh: force
    )
    snapshot = info
    isProbingIp = false
  }

  @ViewBuilder
  private func infoRow(
    label: String,
    value: String,
    color: Color,
    badge: String? = nil,
    monospaced: Bool = false
  ) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .font(.system(size: 14, weight: .medium))
        .foregroundColor(.white.opacity(0.58))
        .frame(width: 90, alignment: .leading)
      Text(value)
        .font(.system(size: 14, weight: .semibold, design: monospaced ? .monospaced : .default))
        .foregroundColor(color)
        .lineLimit(1)
      Spacer(minLength: 4)
      if let badge, !badge.isEmpty {
        Text(badge)
          .font(.system(size: 12, weight: .bold, design: .monospaced))
          .foregroundColor(.white.opacity(0.85))
          .padding(.horizontal, 8)
          .padding(.vertical, 2)
          .background(Capsule().fill(Color.white.opacity(0.12)))
      }
    }
  }

  @ViewBuilder
  private func metricBox(title: String, value: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(.white.opacity(0.58))
      Text(value)
        .font(.system(size: 17, weight: .bold, design: .monospaced))
        .foregroundColor(color)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - VOD & Live TV Fullscreen Player Modal (Pure SwiftUI OSD over TvRawAVPlayerLayerView — 100% Siri Remote Focusable)

struct TvPlayerModalView: View {
  @EnvironmentObject var appState: TvAppState
  let request: TvPlaybackRequest

  private enum PlayerFocusField: Hashable {
    case scrubber
    case playPause
    case showControlsStage
  }

  @FocusState private var focusedField: PlayerFocusField?
  @State private var player: AVPlayer = AVPlayer()
  @State private var flvEngine: TvDirectFlvHardwareEngine = TvDirectFlvHardwareEngine()
  @State private var isUsingDirectFlvEngine: Bool = false
  @State private var isPlaying: Bool = true
  @State private var userWantsToPlay: Bool = true
  @State private var isBuffering: Bool = true
  @State private var positionSec: Double = 0
  @State private var durationSec: Double = 0
  @State private var bufferedSec: Double = 0
  @State private var playbackRate: Float = 1.0
  @State private var aspectFill: Bool = false
  @State private var usingServerProxy: Bool = false
  @State private var using115Direct: Bool = false
  @State private var active115StreamUrl: String = ""
  @State private var active115Headers: [String: String] = [:]
  @State private var show115LoginSheet: Bool = false
  @State private var showProxySelectorSheet: Bool = false
  @State private var didFallbackToProxy: Bool = false
  @State private var didPerformResumeSeek: Bool = false
  @State private var didTriggerOutroSkip: Bool = false
  @State private var streamStartedAt: Date = Date()
  @State private var lastProgressAdvanceAt: Date = Date()
  @State private var lastObservedPos: Double = 0
  @State private var lastStallRecoveryAt: Date = .distantPast
  @State private var timeObserverToken: Any? = nil
  @State private var endObserverToken: NSObjectProtocol? = nil
  @State private var stallObserverToken: NSObjectProtocol? = nil
  @State private var failObserverToken: NSObjectProtocol? = nil
  @State private var lastInteractionAt: Date = Date()
  @State private var lastAutoHideAt: Date = .distantPast
  @State private var lastManualSeekAt: Date = .distantPast
  @State private var lastSeekDeltaSec: Int = 0
  private let autoHideTick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

  @ViewBuilder
  private var playerCanvasZStack: some View {
    let showOverlayBar = appState.playerControlsVisible
    let showSeekHud = !request.isLive && Date().timeIntervalSince(lastManualSeekAt) < 1.2

    ZStack {
      Color.black.ignoresSafeArea()

      // 1. Video Layer (Does NOT hijack Siri Remote focus, allowing all overlay buttons to be focused!)
      if isUsingDirectFlvEngine {
        TvDirectFlvHardwareLayerView(
          engine: flvEngine,
          videoGravity: aspectFill ? .resizeAspectFill : .resizeAspect
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
      } else {
        TvRawAVPlayerLayerView(
          player: player,
          videoGravity: aspectFill ? .resizeAspectFill : .resizeAspect
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
      }

      // Buffering, 115 Cloud Acceleration Progress, or Seek HUD
      if appState.is115Accelerating {
        Tv115AccelerationOverlayCard(
          stageTitle: appState.accel115StageTitle,
          detailText: appState.accel115DetailText,
          progress: appState.accel115Progress,
          onCancel: {
            appState.cancel115Acceleration()
          }
        )
      } else if showSeekHud {
        HStack(spacing: 12) {
          Image(systemName: lastSeekDeltaSec >= 0 ? "goforward.10" : "gobackward.10")
            .font(.system(size: 28, weight: .bold))
            .foregroundColor(Color(red: 0.35, green: 0.78, blue: 1.0))
          Text("\(lastSeekDeltaSec >= 0 ? "快进" : "快退") · \(formatClock(positionSec)) / \(formatClock(durationSec))")
            .font(.system(size: 22, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial)
        .clipShape(Capsule(style: .continuous))
        .allowsHitTesting(false)
      } else if isBuffering {
        VStack(spacing: 14) {
          ProgressView()
            .scaleEffect(1.5)
          Text(using115Direct ? "正在通过本地直连 115 高速缓冲视频..." : (usingServerProxy ? "正在通过服务端代理缓冲视频..." : "正在缓冲高清视频流..."))
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(.white)
          TvVideoDownloadSpeedBadge(player: player, isBuffering: true)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 24)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .allowsHitTesting(false)
      }

      if showOverlayBar {
        VStack {
          // 2. Top Floating Glass Header Bar (.focusSection() so pressing Up from bottom bar reaches it)
          HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
              Text(request.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
              Text(request.subtitle)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white.opacity(0.70))
                .lineLimit(1)
            }
            .frame(maxWidth: 640, alignment: .leading)

            Spacer()

            if !request.isLive,
               let source = request.vodSource,
               let detail = request.vodDetail,
               request.playGroupIndex < detail.playGroups.count {
              let group = detail.playGroups[request.playGroupIndex]

              if detail.playGroups.count > 1 {
                Button {
                  let nextGroup = (request.playGroupIndex + 1) % detail.playGroups.count
                  let targetEp = min(request.episodeIndex, max(0, detail.playGroups[nextGroup].episodes.count - 1))
                  Task {
                    await appState.startEpisodePlayback(
                      source: source,
                      detail: detail,
                      groupIndex: nextGroup,
                      episodeIndex: targetEp
                    )
                  }
                } label: {
                  Label("换线路: \(group.name)", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(TvApplePillButtonStyle(compact: true))
              }
            }

            if request.isLive, let ch = request.liveChannel, ch.urls.count > 1 {
              Button {
                let nextIdx = (request.liveUrlIndex + 1) % ch.urls.count
                appState.playLiveChannel(ch, urlIndex: nextIdx)
              } label: {
                Label("信号 \(request.liveUrlIndex + 1)/\(ch.urls.count)", systemImage: "antenna.radiowaves.left.and.right")
              }
              .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
            }

            let playerScenario: TvRequestScenario = request.isLive ? .liveStream : .vodStream
            TvVideoDownloadSpeedBadge(player: player, isBuffering: isBuffering, compact: true)

            if !request.isLive {
              Button {
                handle115AccelerateButtonTap()
              } label: {
                Label(
                  using115Direct ? "⚡ 115直连中" : (appState.is115Accelerating ? "⚡ 115加速中..." : "⚡ 115加速播放"),
                  systemImage: using115Direct ? "checkmark.icloud.fill" : "bolt.horizontal.icloud.fill"
                )
              }
              .buttonStyle(
                TvApplePillButtonStyle(
                  isSelected: using115Direct || appState.is115Accelerating,
                  isPrimary: using115Direct,
                  compact: true
                )
              )
            }

            Button {
              showProxySelectorSheet = true
            } label: {
              Label(
                "代理: \(appState.buildProxyControlLabel(for: playerScenario, compact: true)) ▾",
                systemImage: "network"
              )
            }
            .buttonStyle(
              TvApplePillButtonStyle(
                isSelected: usingServerProxy || appState.shouldUseProxyOrRelay(for: playerScenario),
                compact: true
              )
            )

            Button {
              withAnimation(.easeInOut(duration: 0.2)) {
                appState.showProxyStatsOverlay.toggle()
              }
            } label: {
              Label(appState.showProxyStatsOverlay ? "隐藏监控" : "代理监控", systemImage: "waveform.path.ecg.rectangle")
            }
            .buttonStyle(
              TvApplePillButtonStyle(
                isSelected: appState.showProxyStatsOverlay,
                compact: true
              )
            )

            Button {
              aspectFill.toggle()
            } label: {
              Label(aspectFill ? "画面:铺满" : "画面:适应", systemImage: "viewfinder")
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))

            Button {
              cleanupPlayer()
              appState.activePlayback = nil
            } label: {
              Label(appState.selectedDetailItem != nil ? "返回详情页" : "返回", systemImage: "xmark")
            }
            .buttonStyle(TvApplePillButtonStyle(isDestructive: true, compact: true))
          }
          .padding(.horizontal, 32)
          .padding(.vertical, 16)
          .background(.ultraThinMaterial)
          .clipShape(Capsule(style: .continuous))
          .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 1))
          .padding(.horizontal, 48)
          .padding(.top, 26)
          .shadow(color: .black.opacity(0.45), radius: 22, y: 8)
          .focusSection()

          Spacer()

          // Optional In-Player Episode Drawer (when user clicks 「选集」 inside fullscreen player)
          if appState.playerShowEpisodeDrawer,
             !request.isLive,
             let source = request.vodSource,
             let detail = request.vodDetail,
             request.playGroupIndex < detail.playGroups.count {
            let group = detail.playGroups[request.playGroupIndex]
            VStack(alignment: .leading, spacing: 10) {
              HStack {
                Label("选集列表 · \(group.name) (共 \(group.episodes.count) 集)", systemImage: "list.and.film")
                  .font(.system(size: 18, weight: .bold))
                  .foregroundColor(.white)
                Spacer()
                Button("收起选集") {
                  appState.playerShowEpisodeDrawer = false
                }
                .buttonStyle(TvApplePillButtonStyle(compact: true))
              }
              ScrollViewReader { epProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                  HStack(spacing: 12) {
                    ForEach(group.episodes) { ep in
                      let isCur = ep.index == request.episodeIndex
                      Button(ep.title) {
                        appState.playerShowEpisodeDrawer = false
                        Task {
                          await appState.startEpisodePlayback(
                            source: source,
                            detail: detail,
                            groupIndex: request.playGroupIndex,
                            episodeIndex: ep.index
                          )
                        }
                      }
                      .buttonStyle(TvApplePillButtonStyle(isSelected: isCur, isPrimary: isCur, compact: true))
                      .id(ep.index)
                    }
                  }
                  .padding(.vertical, 6)
                }
                .onAppear {
                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    epProxy.scrollTo(request.episodeIndex, anchor: .center)
                  }
                }
              }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .frame(maxWidth: 1520)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.bottom, 10)
            .focusSection()
          }

          // 3. Bottom Floating Cinema Control Dock (.focusSection() & auto-focused on appear)
          VStack(spacing: 16) {
            if !request.isLive {
              // Interactive Focusable Progress Bar Scrubber (Left/Right arrow seeks -10s/+10s directly!)
              Button {
                togglePlayPause()
              } label: {
                HStack(spacing: 18) {
                  Text(formatClock(positionSec))
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 92, alignment: .leading)

                  GeometryReader { geo in
                    let playRatio = durationSec > 0 ? min(max(0, positionSec / durationSec), 1.0) : 0
                    let bufRatio = durationSec > 0 ? min(max(playRatio, bufferedSec / durationSec), 1.0) : 0
                    let trackW = max(1, geo.size.width)
                    let isScrubberFocused = (focusedField == .scrubber)
                    ZStack(alignment: .leading) {
                      Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(height: isScrubberFocused ? 12 : 8)
                      Capsule()
                        .fill(Color.white.opacity(0.45))
                        .frame(width: trackW * bufRatio, height: isScrubberFocused ? 12 : 8)
                      Capsule()
                        .fill(isScrubberFocused ? Color(red: 0.35, green: 0.78, blue: 1.0) : Color(red: 0.20, green: 0.60, blue: 0.96))
                        .frame(width: trackW * playRatio, height: isScrubberFocused ? 12 : 8)
                      Circle()
                        .fill(Color.white)
                        .frame(width: isScrubberFocused ? 26 : 20, height: isScrubberFocused ? 26 : 20)
                        .shadow(color: .black.opacity(0.55), radius: 6, y: 2)
                        .offset(x: max(0, min(trackW - 22, trackW * playRatio - 11)))
                    }
                    .frame(maxHeight: .infinity)
                  }
                  .frame(height: 26)

                  Text(formatClock(durationSec))
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.75))
                    .frame(width: 92, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                  RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(focusedField == .scrubber ? Color.white.opacity(0.12) : Color.clear)
                )
              }
              .buttonStyle(TvVideoCanvasStageButtonStyle())
              .focused($focusedField, equals: .scrubber)
              .onMoveCommand { dir in
                wakeUpControls()
                if dir == .left {
                  appState.isPlayerScrubberFocused = true
                  seekRelative(-10)
                } else if dir == .right {
                  appState.isPlayerScrubberFocused = true
                  seekRelative(10)
                } else if dir == .down {
                  appState.isPlayerScrubberFocused = false
                  focusedField = .playPause
                } else if dir == .up {
                  appState.isPlayerScrubberFocused = false
                }
              }
              .focusSection()
            }

            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 14) {
                Button {
                  togglePlayPause()
                } label: {
                  Label(isPlaying ? "暂停" : "播放", systemImage: isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
                .focused($focusedField, equals: .playPause)

                if request.isLive {
                  Button {
                    appState.stepActiveLivePlaybackChannel(delta: -1)
                  } label: {
                    Label("上一台 (▲)", systemImage: "chevron.up.circle.fill")
                  }
                  .buttonStyle(TvApplePillButtonStyle(compact: true))

                  Button {
                    appState.stepActiveLivePlaybackChannel(delta: 1)
                  } label: {
                    Label("下一台 (▼)", systemImage: "chevron.down.circle.fill")
                  }
                  .buttonStyle(TvApplePillButtonStyle(compact: true))
                }

                if !request.isLive {
                  Button {
                    seekRelative(-15)
                  } label: {
                    Label("快退15s", systemImage: "gobackward.15")
                  }
                  .buttonStyle(TvApplePillButtonStyle(compact: true))

                  Button {
                    seekRelative(15)
                  } label: {
                    Label("快进15s", systemImage: "goforward.15")
                  }
                  .buttonStyle(TvApplePillButtonStyle(compact: true))

                  Button {
                    handle115AccelerateButtonTap()
                  } label: {
                    Label(
                      using115Direct ? "⚡ 115直连中" : (appState.is115Accelerating ? "取消115加速" : "⚡ 115加速播放"),
                      systemImage: using115Direct ? "checkmark.icloud.fill" : "bolt.horizontal.icloud.fill"
                    )
                  }
                  .buttonStyle(
                    TvApplePillButtonStyle(
                      isSelected: using115Direct || appState.is115Accelerating,
                      isPrimary: using115Direct,
                      compact: true
                    )
                  )
                }

                if !request.isLive,
                   let source = request.vodSource,
                   let detail = request.vodDetail,
                   request.playGroupIndex < detail.playGroups.count {
                  let group = detail.playGroups[request.playGroupIndex]

                  if request.episodeIndex > 0 {
                    Button {
                      Task {
                        await appState.startEpisodePlayback(
                          source: source,
                          detail: detail,
                          groupIndex: request.playGroupIndex,
                          episodeIndex: request.episodeIndex - 1
                        )
                      }
                    } label: {
                      Label("上一集", systemImage: "backward.end.fill")
                    }
                    .buttonStyle(TvApplePillButtonStyle(compact: true))
                  }

                  if request.episodeIndex + 1 < group.episodes.count {
                    Button {
                      Task {
                        await appState.startEpisodePlayback(
                          source: source,
                          detail: detail,
                          groupIndex: request.playGroupIndex,
                          episodeIndex: request.episodeIndex + 1
                        )
                      }
                    } label: {
                      Label("下一集", systemImage: "forward.end.fill")
                    }
                    .buttonStyle(TvApplePillButtonStyle(compact: true))
                  }

                  if group.episodes.count > 1 {
                    Button {
                      withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        appState.playerShowEpisodeDrawer.toggle()
                      }
                    } label: {
                      Label("选集 (\(request.episodeIndex + 1)/\(group.episodes.count))", systemImage: "list.and.film")
                    }
                    .buttonStyle(TvApplePillButtonStyle(isSelected: appState.playerShowEpisodeDrawer, compact: true))
                  }
                }

                if !request.isLive {
                  Button {
                    let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]
                    let idx = rates.firstIndex(of: playbackRate) ?? 1
                    playbackRate = rates[(idx + 1) % rates.count]
                    if isPlaying {
                      player.rate = playbackRate
                    }
                  } label: {
                    Label(String(format: "倍速 %.2gx", playbackRate), systemImage: "speedometer")
                  }
                  .buttonStyle(TvApplePillButtonStyle(compact: true))
                }

                Button {
                  withAnimation(.easeInOut(duration: 0.22)) {
                    appState.playerControlsVisible = false
                  }
                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    focusedField = .showControlsStage
                  }
                } label: {
                  Label("隐藏控制栏", systemImage: "eye.slash.fill")
                }
                .buttonStyle(TvApplePillButtonStyle(compact: true))

                Button {
                  cleanupPlayer()
                  appState.activePlayback = nil
                } label: {
                  Label(appState.selectedDetailItem != nil ? "返回详情页" : "退出播放", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(TvApplePillButtonStyle(isDestructive: true, compact: true))

                TvVideoDownloadSpeedBadge(player: player, isBuffering: isBuffering, compact: true)
              }
              .padding(.vertical, 6)
            }
            .focusSection()
          }
          .padding(.horizontal, 32)
          .padding(.vertical, 20)
          .frame(maxWidth: 1520)
          .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
              .fill(Color(red: 0.06, green: 0.08, blue: 0.12).opacity(0.92))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
              .stroke(Color.white.opacity(0.16), lineWidth: 1)
          )
          .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
          .padding(.bottom, 28)
          .focusSection()
        }
      } else {
        // When controls are auto-hidden, the screen is 100% clean video.
        // Pressing Select toggles Play/Pause & wakes controls; Left/Right seeks & wakes controls!
        Button {
          wakeUpControls()
          togglePlayPause()
        } label: {
          Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(TvVideoCanvasStageButtonStyle())
        .focused($focusedField, equals: .showControlsStage)
        .onMoveCommand { dir in
          if request.isLive {
            if dir == .up {
              appState.stepActiveLivePlaybackChannel(delta: -1)
              return
            } else if dir == .down {
              appState.stepActiveLivePlaybackChannel(delta: 1)
              return
            }
          }
          wakeUpControls()
          if !request.isLive {
            if dir == .left {
              seekRelative(-10)
            } else if dir == .right {
              seekRelative(10)
            }
          }
        }
      }

      if appState.showProxyStatsOverlay {
        let playerScenario: TvRequestScenario = request.isLive ? .liveStream : .vodStream
        VStack {
          HStack {
            Spacer()
            TvVideoProxyStatsOverlayCard(
              scenario: playerScenario,
              onOpenSelector: {
                showProxySelectorSheet = true
              },
              onClose: {
                withAnimation(.easeInOut(duration: 0.2)) {
                  appState.showProxyStatsOverlay = false
                }
              }
            )
            .padding(.trailing, 54)
            .padding(.top, showOverlayBar ? 118 : 36)
          }
          Spacer()
        }
      }
    }
  }

  var body: some View {
    playerCanvasZStack
    .onMoveCommand { dir in
      if request.isLive {
        if dir == .up {
          appState.stepActiveLivePlaybackChannel(delta: -1)
        } else if dir == .down {
          appState.stepActiveLivePlaybackChannel(delta: 1)
        }
      } else {
        appState.isPlayerScrubberFocused = (focusedField == .scrubber || focusedField == .showControlsStage || focusedField == nil)
      }
      wakeUpControls()
    }
    .onChange(of: appState.remoteActivityTick) { _ in
      wakeUpControls()
    }
    .onChange(of: appState.playerControlsVisible) { visible in
      if visible {
        lastInteractionAt = Date()
        appState.isPlayerScrubberFocused = !request.isLive
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
          focusedField = request.isLive ? .playPause : .scrubber
        }
      } else {
        lastAutoHideAt = Date()
        appState.isPlayerScrubberFocused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
          focusedField = .showControlsStage
        }
      }
    }
    .onReceive(autoHideTick) { now in
      guard !appState.isAppInBackground else { return }
      // 1. Poll AVPlayerItem or TvDirectFlvHardwareEngine status on MainActor without KVO / captured struct snapshots
      if isUsingDirectFlvEngine {
        if flvEngine.isActivelyPlaying {
          if isBuffering { isBuffering = false }
          if !isPlaying && userWantsToPlay { isPlaying = true }
        }
      } else if let curItem = player.currentItem {
        switch curItem.status {
        case .readyToPlay:
          if !didPerformResumeSeek {
            didPerformResumeSeek = true
            if request.resumeSeconds > 3 && !request.isLive && positionSec < 2 {
              let target = CMTime(seconds: request.resumeSeconds, preferredTimescale: 600)
              player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            if userWantsToPlay {
              if request.isLive {
                player.play()
              } else {
                player.playImmediately(atRate: playbackRate)
              }
            }
          } else if userWantsToPlay && request.isLive {
            if player.timeControlStatus != .playing && player.rate == 0 {
              player.play()
            } else if isBuffering && player.timeControlStatus == .playing && player.rate > 0 {
              isBuffering = false
            }
          } else if userWantsToPlay && !request.isLive {
            let stalledFor = now.timeIntervalSince(lastProgressAdvanceAt)
            if stalledFor >= 2.8 && (player.timeControlStatus != .playing || player.rate == 0) {
              isBuffering = true
              if stalledFor < 8.5 {
                if curItem.isPlaybackLikelyToKeepUp {
                  player.playImmediately(atRate: playbackRate)
                } else {
                  player.play()
                }
              } else if now.timeIntervalSince(lastStallRecoveryAt) >= 8.5 {
                lastStallRecoveryAt = now
                lastProgressAdvanceAt = now
                let savedPos = positionSec
                let currentUrl = (using115Direct && !active115StreamUrl.isEmpty)
                  ? active115StreamUrl
                  : ((usingServerProxy && !request.backupProxyUrl.isEmpty) ? request.backupProxyUrl : request.streamUrl)
                startPlayerItem(urlStr: currentUrl, resumeAt: savedPos)
              }
            } else if isBuffering && player.timeControlStatus == .playing && player.rate > 0 {
              isBuffering = false
            }
          } else if isBuffering {
            isBuffering = false
          }
        case .failed:
          if !didFallbackToProxy,
             !request.backupProxyUrl.isEmpty,
             request.backupProxyUrl != request.streamUrl,
             !request.backupProxyUrl.contains("/api/vod/proxy") {
            didFallbackToProxy = true
            startPlayerItem(urlStr: request.backupProxyUrl, resumeAt: positionSec)
          } else {
            isBuffering = false
          }
        default:
          let timeoutLimit: TimeInterval = request.isLive ? 12.0 : 8.5
          if !didFallbackToProxy,
             !request.backupProxyUrl.isEmpty,
             request.backupProxyUrl != request.streamUrl,
             !request.backupProxyUrl.contains("/api/vod/proxy"),
             now.timeIntervalSince(streamStartedAt) >= timeoutLimit {
            didFallbackToProxy = true
            startPlayerItem(urlStr: request.backupProxyUrl)
          }
        }
      }

      // 2. Auto-hide controls after 3.5s of remote inactivity
      let latestActivity = max(lastInteractionAt, appState.lastRemoteActivityAt)
      if appState.playerControlsVisible
          && !appState.playerShowEpisodeDrawer
          && !showProxySelectorSheet
          && !show115LoginSheet
          && !appState.is115Accelerating
          && now.timeIntervalSince(latestActivity) >= 3.5 {
        lastAutoHideAt = now
        withAnimation(.easeInOut(duration: 0.25)) {
          appState.playerControlsVisible = false
        }
        focusedField = .showControlsStage
      }
    }
    .sheet(isPresented: $show115LoginSheet) {
      Tv115QuickLoginSheet(
        isPresented: $show115LoginSheet,
        onLoginCompleted: {
          trigger115CloudAcceleration()
        }
      )
      .environmentObject(appState)
    }
    .sheet(isPresented: $showProxySelectorSheet) {
      let sc: TvRequestScenario = request.isLive ? .liveStream : .vodStream
      TvVideoProxyNodeSelectorSheet(
        isPresented: $showProxySelectorSheet,
        scenario: sc
      ) {
        appState.activateScenarioProxyTunnel(for: sc)
        if request.isLive, let ch = request.liveChannel {
          appState.playLiveChannel(ch, urlIndex: request.liveUrlIndex)
        } else {
          let shouldRelay = appState.shouldUseServerRelay(for: sc)
          usingServerProxy = shouldRelay
          loadCurrentStream(forceProxy: shouldRelay, resumeAt: positionSec)
        }
      }
      .environmentObject(appState)
    }
    .onPlayPauseCommand {
      wakeUpControls()
      togglePlayPause()
    }
    .onAppear {
      lastInteractionAt = Date()
      appState.playerControlsVisible = true
      appState.playerShowEpisodeDrawer = false
      appState.isPlayerScrubberFocused = !request.isLive
      appState.videoDirectSeekHandler = { dir in
        guard !request.isLive else { return }
        wakeUpControls()
        focusedField = .scrubber
        appState.isPlayerScrubberFocused = true
        seekRelative(Double(dir) * 10)
      }
      loadCurrentStream(forceProxy: false)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
        focusedField = request.isLive ? .playPause : .scrubber
      }
    }
    .onChange(of: appState.foregroundResumeTick) { _ in
      streamStartedAt = Date()
      lastInteractionAt = Date()
      if isPlaying && player.rate == 0 {
        player.playImmediately(atRate: playbackRate)
      }
    }
    .onChange(of: request.id) { _ in
      usingServerProxy = false
      using115Direct = false
      active115StreamUrl = ""
      active115Headers = [:]
      appState.cancel115Acceleration()
      lastInteractionAt = Date()
      appState.isPlayerScrubberFocused = !request.isLive
      loadCurrentStream(forceProxy: false)
      wakeUpControls()
    }
    .onDisappear {
      appState.videoDirectSeekHandler = nil
      appState.cancel115Acceleration()
      cleanupPlayer()
    }
  }

  private func wakeUpControls() {
    let now = Date()
    guard now.timeIntervalSince(lastAutoHideAt) > 0.45,
          now.timeIntervalSince(appState.lastControlsManualHideAt) > 0.45 else { return }
    lastInteractionAt = now
    let wasHidden = !appState.playerControlsVisible
    if wasHidden {
      appState.isPlayerScrubberFocused = !request.isLive
      withAnimation(.easeOut(duration: 0.2)) {
        appState.playerControlsVisible = true
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        focusedField = request.isLive ? .playPause : .scrubber
      }
    }
  }

  private func handle115AccelerateButtonTap() {
    if appState.is115Accelerating {
      appState.cancel115Acceleration()
      appState.showToast("已取消 115 云端加速任务")
      return
    }
    if !TvLocal115DirectClient.shared.hasLocalCookie {
      show115LoginSheet = true
      return
    }
    trigger115CloudAcceleration()
  }

  private func trigger115CloudAcceleration() {
    guard !request.isLive else { return }
    let targetDownloadUrl = request.streamUrl
    var episodeTitle = request.title
    if let detail = request.vodDetail,
       request.playGroupIndex < detail.playGroups.count {
      let grp = detail.playGroups[request.playGroupIndex]
      if request.episodeIndex < grp.episodes.count {
        episodeTitle = "\(detail.vodName) - \(grp.episodes[request.episodeIndex].title)"
      }
    }
    appState.start115AcceleratedPlayback(
      downloadUrl: targetDownloadUrl,
      videoName: episodeTitle,
      headers: request.headers
    ) { proxyStreamUrl, directCdnUrl, headers115, _ in
      let savedPos = self.positionSec
      self.using115Direct = true
      self.active115StreamUrl = proxyStreamUrl
      self.active115Headers = headers115
      self.startPlayerItem(urlStr: proxyStreamUrl, resumeAt: savedPos, overrideHeaders: headers115, fallbackDirect115Url: directCdnUrl)
    }
  }

  private func loadCurrentStream(forceProxy: Bool, resumeAt: Double? = nil) {
    let sc: TvRequestScenario = request.isLive ? .liveStream : .vodStream
    appState.activateScenarioProxyTunnel(for: sc)
    let eff = appState.resolveEffectiveRoute(for: sc)
    let isLocalLoopbackStream = request.streamUrl.contains("127.0.0.1:") || request.streamUrl.hasPrefix("file://")
    let useRelay = forceProxy || (eff == .serverRelay && !isLocalLoopbackStream)
    didFallbackToProxy = useRelay
    usingServerProxy = useRelay
    didPerformResumeSeek = false
    didTriggerOutroSkip = false
    using115Direct = false
    active115StreamUrl = ""
    active115Headers = [:]
    isBuffering = true
    let baseTargetUrl = (useRelay && !request.backupProxyUrl.isEmpty)
      ? request.backupProxyUrl
      : request.streamUrl

    if request.isFlvHardwareStream {
      cleanupPlayer()
      isUsingDirectFlvEngine = true
      isBuffering = true
      userWantsToPlay = true
      isPlaying = true
      flvEngine.onFirstFrameRendered = {
        Task { @MainActor in
          self.isBuffering = false
          self.isPlaying = true
        }
      }
      flvEngine.onAllCandidatesFailed = {
        Task { @MainActor in
          self.isBuffering = false
        }
      }
      let primaryTarget = useRelay
        ? request.backupProxyUrl
        : (request.flvPrimaryUrl.isEmpty ? baseTargetUrl : request.flvPrimaryUrl)
      let primaryHeaders = useRelay ? appState.api.authHeaders : request.headers
      let gatewayTarget = useRelay ? "" : request.flvGatewayUrl
      flvEngine.start(
        primaryUrl: primaryTarget,
        primaryHeaders: primaryHeaders,
        gatewayUrl: gatewayTarget,
        gatewayHeaders: request.headers,
        serverProxyUrl: request.backupProxyUrl,
        serverAuthHeaders: appState.api.authHeaders,
        forceProxyNode: (eff == .proxyNode && !useRelay)
      )
      return
    }
    isUsingDirectFlvEngine = false

    if eff == .proxyNode
        && !baseTargetUrl.contains("127.0.0.1:")
        && !TvLocalHlsProxyServer.isDomesticOrLocalUrl(baseTargetUrl) {
      if baseTargetUrl.lowercased().contains(".m3u8") {
        Task {
          if let proxiedHls = await TvLocalHlsProxyServer.shared.prepareProxyPlaylistUrl(
            gatewayUrl: baseTargetUrl,
            resolvedUrl: baseTargetUrl,
            headers: request.headers
          ) {
            self.startPlayerItem(urlStr: proxiedHls, resumeAt: resumeAt)
          } else {
            self.startPlayerItem(urlStr: baseTargetUrl, resumeAt: resumeAt)
          }
        }
        return
      } else if baseTargetUrl.contains("/api/telegram/") {
        let proxiedMp4 = TvLocalHlsProxyServer.shared.prepareTelegramVideoProxyUrl(
          remoteUrl: baseTargetUrl,
          headers: request.headers
        )
        startPlayerItem(urlStr: proxiedMp4, resumeAt: resumeAt)
        return
      }
    }
    startPlayerItem(urlStr: baseTargetUrl, resumeAt: resumeAt)
  }

  private func startPlayerItem(
    urlStr: String,
    resumeAt: Double? = nil,
    overrideHeaders: [String: String]? = nil,
    fallbackDirect115Url: String? = nil
  ) {
    cleanupPlayer()
    guard let url = URL(string: urlStr) else {
      isBuffering = false
      return
    }
    streamStartedAt = Date()
    lastProgressAdvanceAt = Date()
    didPerformResumeSeek = false
    isBuffering = true
    userWantsToPlay = true
    isPlaying = true

    var options: [String: Any] = [:]
    let effectiveHeaders = overrideHeaders ?? (using115Direct ? active115Headers : request.headers)
    let isLocalLoopback = urlStr.contains("127.0.0.1:")
    if !effectiveHeaders.isEmpty && !url.isFileURL && !isLocalLoopback {
      options["AVURLAssetHTTPHeaderFieldsKey"] = effectiveHeaders
    }
    let asset = AVURLAsset(url: url, options: options)
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = request.isLive ? 2.5 : 45

    player.replaceCurrentItem(with: item)
    player.automaticallyWaitsToMinimizeStalling = true
    let initialSeek = resumeAt ?? (!request.isLive && request.resumeSeconds > 3 ? request.resumeSeconds : 0)
    if initialSeek > 1 && !request.isLive {
      didPerformResumeSeek = true
      let target = CMTime(seconds: initialSeek, preferredTimescale: 600)
      player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] _ in
        player?.playImmediately(atRate: playbackRate)
      }
    } else if request.isLive {
      player.play()
    } else {
      player.playImmediately(atRate: playbackRate)
    }

    let skipOutroSec = Double(appState.skipOutroSeconds)
    let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
    timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
      let sec = CMTimeGetSeconds(time)
      if sec.isFinite && sec >= 0 {
        if Date().timeIntervalSince(self.lastManualSeekAt) >= 0.85 {
          self.positionSec = sec
        }
        if abs(sec - self.lastObservedPos) > 0.12 {
          self.lastObservedPos = sec
          self.lastProgressAdvanceAt = Date()
          self.isBuffering = false
        }
      }
      if let curItem = self.player.currentItem {
        let dur = CMTimeGetSeconds(curItem.duration)
        if dur.isFinite && dur > 0 {
          self.durationSec = dur
        }
        if let timeRange = curItem.loadedTimeRanges.first?.timeRangeValue {
          let bufEnd = CMTimeGetSeconds(CMTimeAdd(timeRange.start, timeRange.duration))
          if bufEnd.isFinite && bufEnd > 0 {
            self.bufferedSec = bufEnd
          }
        }
        if !self.request.isLive && sec > 3 {
          self.recordProgress(pos: sec, dur: self.durationSec)
          if skipOutroSec > 0,
             self.durationSec > skipOutroSec + 30,
             sec >= self.durationSec - skipOutroSec,
             !self.didTriggerOutroSkip {
            self.didTriggerOutroSkip = true
            self.handleEndedOrNext()
          }
        }
      }
      self.isPlaying = self.userWantsToPlay
    }

    endObserverToken = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { _ in
      if !self.request.isLive && self.durationSec > 10 && self.positionSec > 2 && self.positionSec < self.durationSec - 5 {
        // Premature EOF caused by upstream connection drop — seamlessly reload and resume at positionSec
        let savedPos = self.positionSec
        let currentUrl = (self.using115Direct && !self.active115StreamUrl.isEmpty)
          ? self.active115StreamUrl
          : ((self.usingServerProxy && !self.request.backupProxyUrl.isEmpty) ? self.request.backupProxyUrl : self.request.streamUrl)
        self.startPlayerItem(urlStr: currentUrl, resumeAt: savedPos)
        return
      }
      self.handleEndedOrNext()
    }

    stallObserverToken = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemPlaybackStalled,
      object: item,
      queue: .main
    ) { _ in
      guard self.userWantsToPlay else { return }
      self.isBuffering = true
      self.player.play()
    }

    failObserverToken = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime,
      object: item,
      queue: .main
    ) { _ in
      guard self.userWantsToPlay, !self.request.isLive else { return }
      let savedPos = self.positionSec
      let currentUrl = (self.using115Direct && !self.active115StreamUrl.isEmpty)
        ? self.active115StreamUrl
        : ((self.usingServerProxy && !self.request.backupProxyUrl.isEmpty) ? self.request.backupProxyUrl : self.request.streamUrl)
      self.startPlayerItem(urlStr: currentUrl, resumeAt: savedPos)
    }
  }

  private func recordProgress(pos: Double, dur: Double) {
    guard !request.isLive,
          let detail = request.vodDetail,
          request.playGroupIndex < detail.playGroups.count else { return }
    let group = detail.playGroups[request.playGroupIndex]
    guard request.episodeIndex < group.episodes.count else { return }
    let ep = group.episodes[request.episodeIndex]
    appState.recordPlaybackProgress(
      source: request.vodSource,
      detail: detail,
      groupName: group.name,
      episodeTitle: ep.title,
      position: pos,
      duration: dur
    )
  }

  private func togglePlayPause() {
    if isUsingDirectFlvEngine {
      if userWantsToPlay && isPlaying {
        userWantsToPlay = false
        isPlaying = false
        flvEngine.pause()
      } else {
        userWantsToPlay = true
        isPlaying = true
        flvEngine.resume()
      }
      return
    }
    if userWantsToPlay && player.rate > 0 {
      userWantsToPlay = false
      isPlaying = false
      player.pause()
    } else {
      userWantsToPlay = true
      isPlaying = true
      lastProgressAdvanceAt = Date()
      if request.isLive {
        player.play()
      } else {
        player.playImmediately(atRate: playbackRate)
      }
    }
  }

  private func seekRelative(_ delta: Double) {
    lastInteractionAt = Date()
    lastManualSeekAt = Date()
    lastProgressAdvanceAt = Date()
    lastSeekDeltaSec = Int(delta)
    let maxDur = durationSec > 0 ? durationSec : max(0, positionSec + delta + 3600)
    let target = min(maxDur, max(0, positionSec + delta))
    positionSec = target
    player.currentItem?.cancelPendingSeeks()
    let tol = CMTime(seconds: 1.2, preferredTimescale: 600)
    player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol) { [weak player] _ in
      if self.userWantsToPlay {
        player?.playImmediately(atRate: self.playbackRate)
      }
    }
  }

  private func cleanupPlayer() {
    flvEngine.stop()
    isUsingDirectFlvEngine = false
    if let token = timeObserverToken {
      player.removeTimeObserver(token)
      timeObserverToken = nil
    }
    if let endToken = endObserverToken {
      NotificationCenter.default.removeObserver(endToken)
      endObserverToken = nil
    }
    if let stallToken = stallObserverToken {
      NotificationCenter.default.removeObserver(stallToken)
      stallObserverToken = nil
    }
    if let failToken = failObserverToken {
      NotificationCenter.default.removeObserver(failToken)
      failObserverToken = nil
    }
    player.pause()
    player.replaceCurrentItem(with: nil)
  }

  private func handleEndedOrNext() {
    guard !request.isLive,
          let source = request.vodSource,
          let detail = request.vodDetail,
          request.playGroupIndex < detail.playGroups.count else { return }
    let group = detail.playGroups[request.playGroupIndex]
    let nextIndex = request.episodeIndex + 1
    if nextIndex < group.episodes.count {
      Task {
        await appState.startEpisodePlayback(
          source: source,
          detail: detail,
          groupIndex: request.playGroupIndex,
          episodeIndex: nextIndex
        )
      }
    }
  }

  private func formatClock(_ seconds: Double) -> String {
    let total = Int(max(0, seconds))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
      return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%02d:%02d", m, s)
  }
}

// MARK: - Official Telegram Fullscreen Gallery Player (1:1 Match with Original App & Apple TV Design)

struct TvTelegramGalleryModalView: View {
  @EnvironmentObject var appState: TvAppState
  let session: TvTelegramGallerySession

  private enum GalleryFocusField: Hashable {
    case scrubber
    case playPause
    case prevItem
    case restoreControls
  }

  @FocusState private var galleryFocus: GalleryFocusField?
  @State private var currentIndex: Int = 0
  @State private var player: AVPlayer = AVPlayer()
  @State private var isPlaying: Bool = false
  @State private var userWantsToPlay: Bool = true
  @State private var isBuffering: Bool = false
  @State private var isMuted: Bool = false
  @State private var positionSec: Double = 0
  @State private var durationSec: Double = 0
  @State private var bufferedSec: Double = 0
  @State private var playbackRate: Float = 1.0
  @State private var aspectFill: Bool = false
  @State private var showProxySelectorSheet: Bool = false
  @State private var show115LoginSheet: Bool = false
  @State private var using115Direct: Bool = false
  @State private var active115StreamUrl: String = ""
  @State private var active115Headers: [String: String] = [:]
  @State private var didFallbackToDirectUrl: Bool = false

  // Movable & Hideable Progress Bar + Video Title Small Window states
  @State private var captionHidden: Bool = false
  @State private var controlsPositionPreset: Int = 0 // 0: 底部默认, 1: 中部悬浮, 2: 顶部避字幕
  @State private var captionPositionPreset: Int = 0  // 0: 进度条上方居中, 1: 顶部居中, 2: 左上角, 3: 右上角
  @State private var timeObserverToken: Any? = nil
  @State private var endObserverToken: NSObjectProtocol? = nil
  @State private var stallObserverToken: NSObjectProtocol? = nil
  @State private var failObserverToken: NSObjectProtocol? = nil
  @State private var lastProgressAdvanceAt: Date = Date()
  @State private var lastObservedPos: Double = 0
  @State private var lastStallRecoveryAt: Date = .distantPast
  @State private var lastInteractionAt: Date = Date()
  @State private var lastAutoHideAt: Date = .distantPast
  @State private var lastManualSeekAt: Date = .distantPast
  @State private var lastSeekDeltaSec: Int = 0
  private let autoHideTick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

  private var currentMessage: TvTelegramMessage {
    let list = session.mediaMessages
    guard !list.isEmpty else {
      return TvTelegramMessage(
        id: 0,
        date: 0,
        sender: "",
        senderAvatar: "",
        text: "",
        outgoing: false,
        groupedId: "",
        replyToId: 0,
        links: [],
        buttons: [],
        attachment: nil
      )
    }
    return list[min(max(0, currentIndex), list.count - 1)]
  }

  private var parsedCaptionTitleAndDesc: (title: String, desc: String) {
    let raw = currentMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.isEmpty {
      let fallback = currentMessage.attachment?.displayName ?? session.chat.title
      return (fallback, session.chat.title)
    }
    let lines = raw
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let title = lines.first ?? (currentMessage.attachment?.displayName ?? session.chat.title)
    let rest = lines.dropFirst().joined(separator: " · ")
    return (title, rest.isEmpty ? "简介：\(session.chat.title)" : (rest.hasPrefix("简介") ? rest : "简介：\(rest)"))
  }

  private var controlsVerticalOffset: CGFloat {
    switch controlsPositionPreset {
    case 1: return -260
    case 2: return -540
    default: return 0
    }
  }

  private var captionAlignment: Alignment {
    switch captionPositionPreset {
    case 1: return .top
    case 2: return .topLeading
    case 3: return .topTrailing
    default: return .bottom
    }
  }

  @ViewBuilder
  private var galleryCanvasZStack: some View {
    let list = session.mediaMessages
    let msg = currentMessage
    let isVideo = msg.isVideo || msg.isAudio
    let captionInfo = parsedCaptionTitleAndDesc
    let controlsHidden = !appState.galleryControlsVisible

    ZStack {
      Color.black.ignoresSafeArea()

      // 1. Main Fullscreen Video or Photo Stage
      if isVideo {
        TvRawAVPlayerLayerView(
          player: player,
          videoGravity: aspectFill ? .resizeAspectFill : .resizeAspect
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)

        if appState.is115Accelerating {
          Tv115AccelerationOverlayCard(
            stageTitle: appState.accel115StageTitle,
            detailText: appState.accel115DetailText,
            progress: appState.accel115Progress,
            onCancel: {
              appState.cancel115Acceleration()
            }
          )
        } else if isBuffering {
          HStack(spacing: 12) {
            ProgressView()
            Text(using115Direct ? "正在通过本地直连 115 高速缓冲视频..." : "正在加速缓冲视频分片...")
              .font(.system(size: 18, weight: .semibold))
              .foregroundColor(.white)
            TvVideoDownloadSpeedBadge(player: player, isBuffering: true, compact: true)
          }
          .padding(.horizontal, 24)
          .padding(.vertical, 14)
          .background(.ultraThinMaterial)
          .clipShape(Capsule(style: .continuous))
          .allowsHitTesting(false)
        }
      } else {
        TvRemoteImage(
          rawUrl: appState.api.telegramFileContentUrl(
            accountId: session.accountId,
            peer: session.chat.peer,
            messageId: msg.id
          ),
          placeholderIcon: "photo",
          contentMode: aspectFill ? .fill : .fit
        )
        .ignoresSafeArea()
      }

      // 2. Top Floating Glass Header Bar
      if !controlsHidden {
        VStack {
          HStack(spacing: 16) {
            TvTelegramPeerAvatar(
              peer: session.chat.peer,
              title: session.chat.title,
              avatarUrl: appState.resolvePeerAvatarUrl(for: session.chat),
              isSelf: session.chat.isSelf,
              size: 44,
              fontSize: 18
            )

            VStack(alignment: .leading, spacing: 2) {
              Text("\(currentIndex + 1) / \(list.count) · \(msg.attachment?.displayName ?? session.chat.title)")
                .font(.system(size: 21, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
              Text("\(session.chat.title) · \(msg.formattedDate)\(msg.attachment?.formattedSize.isEmpty == false ? " · \(msg.attachment!.formattedSize)" : "")")
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.68))
                .lineLimit(1)
            }

            Spacer()

            if isVideo {
              TvVideoDownloadSpeedBadge(player: player, isBuffering: isBuffering, compact: true)

              Button {
                handle115AccelerateButtonTap()
              } label: {
                Label(
                  using115Direct ? "⚡ 115直连中" : (appState.is115Accelerating ? "取消115加速" : "⚡ 115加速播放"),
                  systemImage: using115Direct ? "checkmark.icloud.fill" : "bolt.horizontal.icloud.fill"
                )
              }
              .buttonStyle(
                TvApplePillButtonStyle(
                  isSelected: using115Direct || appState.is115Accelerating,
                  isPrimary: using115Direct,
                  compact: true
                )
              )

              Button {
                cleanupPlayer()
                let targetChat = session.chat
                let targetMsg = msg
                appState.activeTelegramGallery = nil
                appState.openTelegramMiniPlayer(chat: targetChat, message: targetMsg)
              } label: {
                Label("小窗播放", systemImage: "pip.enter")
              }
              .buttonStyle(TvApplePillButtonStyle(compact: true))
            }

            Button {
              Task {
                _ = await appState.queueTelegramDownload(chat: session.chat, message: msg)
              }
            } label: {
              Label("转存下载", systemImage: "icloud.and.arrow.down")
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))

            Button {
              cleanupPlayer()
              appState.activeTelegramGallery = nil
            } label: {
              Label("关闭", systemImage: "xmark")
            }
            .buttonStyle(TvApplePillButtonStyle(isDestructive: true, compact: true))
          }
          .padding(.horizontal, 28)
          .padding(.vertical, 14)
          .background(.ultraThinMaterial)
          .clipShape(Capsule(style: .continuous))
          .padding(.horizontal, 48)
          .padding(.top, 24)
          .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
          .focusSection()

          Spacer()
        }
      }

      // 3. Movable & Hideable Video Title Small Window when placed at Top / Top-Left / Top-Right
      if !controlsHidden && !captionHidden && captionPositionPreset != 0 {
        VStack {
          HStack {
            if captionPositionPreset == 3 { Spacer() }
            captionSmallWindowCard(title: captionInfo.title, desc: captionInfo.desc)
            if captionPositionPreset == 2 { Spacer() }
          }
          .padding(.horizontal, 60)
          .padding(.top, 118)
          Spacer()
        }
        .allowsHitTesting(false)
      }

      // 4. Bottom Floating Stack: Video Title Small Window + Movable Progress Control Bar + Total Video Thumbnail Strip
      VStack(spacing: 14) {
        Spacer()

        // 4a. Video Title & Intro Small Window (韵母攻略6 / 简介：黄豆短剧 style from screenshot)
        if !controlsHidden && !captionHidden && captionPositionPreset == 0 {
          captionSmallWindowCard(title: captionInfo.title, desc: captionInfo.desc)
            .allowsHitTesting(false)
        }

        if !controlsHidden {
          VStack(spacing: 12) {
            // 4b. Main Rounded Dark Control Bar (exact match with user screenshot)
            VStack(spacing: 14) {
              // Drag / Move Position Hint Header + Quick Position/Hide Toggles
              HStack(spacing: 12) {
                Image(systemName: "circle.grid.2x3.fill")
                  .font(.system(size: 16))
                  .foregroundColor(.white.opacity(0.55))
                Text("可任意移动或隐藏进度条与标题小窗口位置")
                  .font(.system(size: 16, weight: .medium))
                  .foregroundColor(.white.opacity(0.60))

                Spacer()

                Button {
                  withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    controlsPositionPreset = (controlsPositionPreset + 1) % 3
                  }
                } label: {
                  Label(
                    controlsPositionPreset == 0 ? "进度条:底部" : (controlsPositionPreset == 1 ? "进度条:居中" : "进度条:顶部"),
                    systemImage: "arrow.up.and.down.circle"
                  )
                }
                .buttonStyle(TvApplePillButtonStyle(compact: true))

                Button {
                  withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    captionPositionPreset = (captionPositionPreset + 1) % 4
                  }
                } label: {
                  Label("移动标题窗", systemImage: "macwindow.on.rectangle")
                }
                .buttonStyle(TvApplePillButtonStyle(compact: true))

                Button {
                  withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    captionHidden.toggle()
                  }
                } label: {
                  Label(captionHidden ? "显示标题窗" : "隐藏标题窗", systemImage: captionHidden ? "eye" : "eye.slash")
                }
                .buttonStyle(TvApplePillButtonStyle(compact: true))

                Button {
                  withAnimation(.easeInOut(duration: 0.22)) {
                    appState.galleryControlsVisible = false
                  }
                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    galleryFocus = .restoreControls
                  }
                } label: {
                  Label("隐藏控制栏", systemImage: "chevron.down.circle")
                }
                .buttonStyle(TvApplePillButtonStyle(compact: true))
              }
              .focusSection()

              // Interactive Focusable Progress Scrubber Row (00:11 [====O----------] 03:01)
              if isVideo {
                Button {
                  togglePlayPause()
                } label: {
                  HStack(spacing: 18) {
                    Text(formatClock(positionSec))
                      .font(.system(size: 20, weight: .bold, design: .monospaced))
                      .foregroundColor(.white)
                      .frame(width: 82, alignment: .leading)

                    GeometryReader { geo in
                      let playRatio = durationSec > 0 ? min(max(0, positionSec / durationSec), 1.0) : 0
                      let bufRatio = durationSec > 0 ? min(max(playRatio, bufferedSec / durationSec), 1.0) : 0
                      let trackW = max(1, geo.size.width)
                      let isScrubberFocused = (galleryFocus == .scrubber)
                      ZStack(alignment: .leading) {
                        Capsule()
                          .fill(Color.white.opacity(0.22))
                          .frame(height: isScrubberFocused ? 12 : 8)
                        Capsule()
                          .fill(Color.white.opacity(0.45))
                          .frame(width: trackW * bufRatio, height: isScrubberFocused ? 12 : 8)
                        Capsule()
                          .fill(isScrubberFocused ? Color(red: 0.35, green: 0.78, blue: 1.0) : Color(red: 0.16, green: 0.58, blue: 0.96))
                          .frame(width: trackW * playRatio, height: isScrubberFocused ? 12 : 8)
                        Circle()
                          .fill(Color.white)
                          .frame(width: isScrubberFocused ? 26 : 20, height: isScrubberFocused ? 26 : 20)
                          .shadow(color: .black.opacity(0.55), radius: 5, y: 2)
                          .offset(x: max(0, min(trackW - 22, trackW * playRatio - 11)))
                      }
                      .frame(maxHeight: .infinity)
                    }
                    .frame(height: 26)

                    Text(formatClock(durationSec))
                      .font(.system(size: 20, weight: .medium, design: .monospaced))
                      .foregroundColor(.white.opacity(0.78))
                      .frame(width: 82, alignment: .trailing)
                  }
                  .padding(.horizontal, 12)
                  .padding(.vertical, 6)
                  .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                      .fill(galleryFocus == .scrubber ? Color.white.opacity(0.12) : Color.clear)
                  )
                }
                .buttonStyle(TvVideoCanvasStageButtonStyle())
                .focused($galleryFocus, equals: .scrubber)
                .onMoveCommand { dir in
                  wakeUpGalleryControls()
                  if dir == .left {
                    appState.isPlayerScrubberFocused = true
                    seekRelative(-5)
                  } else if dir == .right {
                    appState.isPlayerScrubberFocused = true
                    seekRelative(5)
                  } else if dir == .down {
                    appState.isPlayerScrubberFocused = false
                    galleryFocus = .playPause
                  } else if dir == .up {
                    appState.isPlayerScrubberFocused = false
                  }
                }
                .focusSection()
              }

              // Main Pill Buttons Control Row (Matches screenshot 100%)
              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                  if isVideo {
                    Button {
                      togglePlayPause()
                    } label: {
                      Label(isPlaying ? "暂停" : "播放", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(TvApplePillButtonStyle(isPrimary: true, compact: true))
                    .focused($galleryFocus, equals: .playPause)

                    Button {
                      seekRelative(-5)
                    } label: {
                      Label("快退5s", systemImage: "gobackward.5")
                    }
                    .buttonStyle(TvApplePillButtonStyle(compact: true))

                    Button {
                      seekRelative(5)
                    } label: {
                      Label("快进5s", systemImage: "goforward.5")
                    }
                    .buttonStyle(TvApplePillButtonStyle(compact: true))

                    Button {
                      handle115AccelerateButtonTap()
                    } label: {
                      Label(
                        using115Direct ? "⚡ 115直连中" : (appState.is115Accelerating ? "取消115加速" : "⚡ 115加速播放"),
                        systemImage: using115Direct ? "checkmark.icloud.fill" : "bolt.horizontal.icloud.fill"
                      )
                    }
                    .buttonStyle(
                      TvApplePillButtonStyle(
                        isSelected: using115Direct || appState.is115Accelerating,
                        isPrimary: using115Direct,
                        compact: true
                      )
                    )
                  }

                  if list.count > 1 {
                    Button {
                      selectItem(currentIndex - 1)
                    } label: {
                      Label("上一项", systemImage: "backward.end.fill")
                    }
                    .buttonStyle(TvApplePillButtonStyle(compact: true))
                    .focused($galleryFocus, equals: .prevItem)

                    Button {
                      selectItem(currentIndex + 1)
                    } label: {
                      Label("下一项", systemImage: "forward.end.fill")
                    }
                    .buttonStyle(TvApplePillButtonStyle(compact: true))
                  }

                  if isVideo {
                    Button {
                      cycleRate()
                    } label: {
                      Label(String(format: "%.1fx", playbackRate), systemImage: "speedometer")
                    }
                    .buttonStyle(TvApplePillButtonStyle(compact: true))
                  }

                  Button {
                    aspectFill.toggle()
                  } label: {
                    Label(aspectFill ? "铺满" : "适应", systemImage: "viewfinder")
                  }
                  .buttonStyle(TvApplePillButtonStyle(compact: true))

                  Button {
                    showProxySelectorSheet = true
                  } label: {
                    Label("代理: \(appState.buildProxyControlLabel(for: .telegram, compact: true)) ▾", systemImage: "network")
                  }
                  .buttonStyle(TvApplePillButtonStyle(isSelected: appState.shouldUseProxyOrRelay(for: .telegram), compact: true))

                  Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                      appState.showProxyStatsOverlay.toggle()
                    }
                  } label: {
                    Label(appState.showProxyStatsOverlay ? "隐藏监控" : "代理监控", systemImage: "waveform.path.ecg.rectangle")
                  }
                  .buttonStyle(TvApplePillButtonStyle(isSelected: appState.showProxyStatsOverlay, compact: true))

                  if isVideo {
                    Button {
                      isMuted.toggle()
                      player.isMuted = isMuted
                    } label: {
                      Label(isMuted ? "取消静音" : "静音", systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .buttonStyle(TvApplePillButtonStyle(isSelected: isMuted, compact: true))

                    // Visual Volume Indicator Bar (100% / 0%)
                    HStack(spacing: 8) {
                      ZStack(alignment: .leading) {
                        Capsule()
                          .fill(Color.white.opacity(0.22))
                          .frame(width: 72, height: 6)
                        Capsule()
                          .fill(Color(red: 0.24, green: 0.65, blue: 0.98))
                          .frame(width: isMuted ? 0 : 72, height: 6)
                        Circle()
                          .fill(Color.white)
                          .frame(width: 14, height: 14)
                          .offset(x: isMuted ? 0 : 58)
                      }
                      Text(isMuted ? "0%" : "100%")
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.leading, 4)

                    TvVideoDownloadSpeedBadge(player: player, isBuffering: isBuffering, compact: true)
                  }
                }
                .padding(.vertical, 6)
              }
              .focusSection()
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .frame(maxWidth: 1560)
            .background(
              RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.07, green: 0.09, blue: 0.13).opacity(0.92))
            )
            .overlay(
              RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
            .offset(y: controlsVerticalOffset)

            // 4c. Bottom Total Video Preview Thumbnail Strip (最下面的总视频自动定位预览条 - exact match with screenshot 2)
            if list.count > 1 {
              ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                  HStack(spacing: 14) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { idx, item in
                      TvGalleryBottomThumbnailButton(
                        accountId: session.accountId,
                        peer: session.chat.peer,
                        item: item,
                        index: idx,
                        isActive: idx == currentIndex
                      ) {
                        selectItem(idx)
                      }
                      .id(idx)
                    }
                  }
                  .padding(.horizontal, 22)
                  .padding(.vertical, 12)
                }
                .frame(maxWidth: 1560, maxHeight: 116)
                .background(
                  RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(red: 0.06, green: 0.08, blue: 0.12).opacity(0.90))
                )
                .overlay(
                  RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .focusSection()
                .onAppear {
                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeInOut(duration: 0.28)) {
                      proxy.scrollTo(currentIndex, anchor: .center)
                    }
                  }
                }
                .onChange(of: currentIndex) { newIdx in
                  withAnimation(.easeInOut(duration: 0.28)) {
                    proxy.scrollTo(newIdx, anchor: .center)
                  }
                }
              }
            }
          }
        } else {
          // 100% invisible full-screen wake button when controls are auto-hidden
          Button {
            wakeUpGalleryControls()
            if isVideo { togglePlayPause() }
          } label: {
            Color.clear
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .contentShape(Rectangle())
          }
          .buttonStyle(TvVideoCanvasStageButtonStyle())
          .focused($galleryFocus, equals: .restoreControls)
          .onMoveCommand { dir in
            wakeUpGalleryControls()
            if isVideo {
              if dir == .left {
                seekRelative(-5)
              } else if dir == .right {
                seekRelative(5)
              }
            }
          }
        }
      }
      .padding(.bottom, 22)

      if appState.showProxyStatsOverlay {
        VStack {
          HStack {
            Spacer()
            TvVideoProxyStatsOverlayCard(
              scenario: .telegram,
              onOpenSelector: {
                showProxySelectorSheet = true
              },
              onClose: {
                withAnimation(.easeInOut(duration: 0.2)) {
                  appState.showProxyStatsOverlay = false
                }
              }
            )
            .padding(.trailing, 54)
            .padding(.top, !controlsHidden ? 114 : 36)
          }
          Spacer()
        }
      }
    }
  }

  var body: some View {
    let isVideo = currentMessage.isVideo || currentMessage.isAudio
    galleryCanvasZStack
    .onMoveCommand { _ in
      appState.isPlayerScrubberFocused = (galleryFocus == .scrubber || galleryFocus == .restoreControls || galleryFocus == nil)
      wakeUpGalleryControls()
    }
    .onChange(of: appState.remoteActivityTick) { _ in
      wakeUpGalleryControls()
    }
    .onChange(of: appState.galleryControlsVisible) { visible in
      if visible {
        lastInteractionAt = Date()
        let isVid = currentMessage.isVideo || currentMessage.isAudio
        appState.isPlayerScrubberFocused = isVid
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
          galleryFocus = isVid ? .scrubber : .prevItem
        }
      } else {
        lastAutoHideAt = Date()
        appState.isPlayerScrubberFocused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
          galleryFocus = .restoreControls
        }
      }
    }
    .onReceive(autoHideTick) { now in
      guard !appState.isAppInBackground else { return }

      // 1. Active Telegram Video Stall & Interruption Auto-Healing Watchdog
      let isVid = currentMessage.isVideo || currentMessage.isAudio
      if isVid && userWantsToPlay, let curItem = player.currentItem {
        switch curItem.status {
        case .failed:
          if now.timeIntervalSince(lastStallRecoveryAt) >= 2.5 {
            lastStallRecoveryAt = now
            resumeCurrentMediaFromStall(at: positionSec, preferDirectFallback: !didFallbackToDirectUrl)
          }
        case .readyToPlay:
          let stalledFor = now.timeIntervalSince(lastProgressAdvanceAt)
          if stalledFor >= 2.2 && (player.timeControlStatus != .playing || player.rate == 0) {
            isBuffering = true
            if stalledFor < 7.5 {
              if curItem.isPlaybackLikelyToKeepUp {
                player.playImmediately(atRate: playbackRate)
              } else {
                player.play()
              }
            } else if now.timeIntervalSince(lastStallRecoveryAt) >= 7.5 {
              lastStallRecoveryAt = now
              resumeCurrentMediaFromStall(at: positionSec, preferDirectFallback: false)
            }
          } else if isBuffering && player.timeControlStatus == .playing && player.rate > 0 {
            isBuffering = false
          }
        default:
          let stalledFor = now.timeIntervalSince(lastProgressAdvanceAt)
          if stalledFor >= 8.5 && now.timeIntervalSince(lastStallRecoveryAt) >= 8.0 {
            lastStallRecoveryAt = now
            resumeCurrentMediaFromStall(at: positionSec, preferDirectFallback: !didFallbackToDirectUrl)
          }
        }
      }

      // 2. Auto-hide controls after 3.5s of remote inactivity
      let latestActivity = max(lastInteractionAt, appState.lastRemoteActivityAt)
      if appState.galleryControlsVisible
          && !showProxySelectorSheet
          && !show115LoginSheet
          && !appState.is115Accelerating
          && now.timeIntervalSince(latestActivity) >= 3.5 {
        lastAutoHideAt = now
        withAnimation(.easeInOut(duration: 0.25)) {
          appState.galleryControlsVisible = false
        }
        galleryFocus = .restoreControls
      }
    }
    .sheet(isPresented: $show115LoginSheet) {
      Tv115QuickLoginSheet(
        isPresented: $show115LoginSheet,
        onLoginCompleted: {
          trigger115CloudAcceleration()
        }
      )
      .environmentObject(appState)
    }
    .sheet(isPresented: $showProxySelectorSheet) {
      TvVideoProxyNodeSelectorSheet(
        isPresented: $showProxySelectorSheet,
        scenario: .telegram
      ) {
        appState.activateScenarioProxyTunnel(for: .telegram)
        if isVideo {
          loadCurrentMedia(resumeAt: positionSec)
        }
      }
      .environmentObject(appState)
    }
    .onPlayPauseCommand {
      wakeUpGalleryControls()
      if isVideo { togglePlayPause() }
    }
    .onAppear {
      lastInteractionAt = Date()
      appState.galleryControlsVisible = true
      currentIndex = min(max(0, session.initialIndex), max(0, session.mediaMessages.count - 1))
      appState.isPlayerScrubberFocused = isVideo
      appState.videoDirectSeekHandler = { dir in
        let isVid = currentMessage.isVideo || currentMessage.isAudio
        guard isVid else { return }
        wakeUpGalleryControls()
        galleryFocus = .scrubber
        appState.isPlayerScrubberFocused = true
        seekRelative(Double(dir) * 5)
      }
      loadCurrentMedia()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
        galleryFocus = isVideo ? .scrubber : .prevItem
      }
    }
    .onChange(of: appState.foregroundResumeTick) { _ in
      lastInteractionAt = Date()
      lastProgressAdvanceAt = Date()
      if userWantsToPlay && player.rate == 0 {
        player.playImmediately(atRate: playbackRate)
      }
    }
    .onDisappear {
      appState.videoDirectSeekHandler = nil
      appState.cancel115Acceleration()
      cleanupPlayer()
    }
  }

  private func wakeUpGalleryControls() {
    let now = Date()
    guard now.timeIntervalSince(lastAutoHideAt) > 0.45,
          now.timeIntervalSince(appState.lastControlsManualHideAt) > 0.45 else { return }
    lastInteractionAt = now
    let wasHidden = !appState.galleryControlsVisible
    if wasHidden {
      let isVid = currentMessage.isVideo || currentMessage.isAudio
      appState.isPlayerScrubberFocused = isVid
      withAnimation(.easeOut(duration: 0.2)) {
        appState.galleryControlsVisible = true
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        galleryFocus = isVid ? .scrubber : .prevItem
      }
    }
  }

  @ViewBuilder
  private func captionSmallWindowCard(title: String, desc: String) -> some View {
    VStack(spacing: 6) {
      Text(title)
        .font(.system(size: 22, weight: .bold))
        .foregroundColor(.white)
        .lineLimit(1)
      Text(desc)
        .font(.system(size: 18, weight: .medium))
        .foregroundColor(.white.opacity(0.86))
        .lineLimit(2)
    }
    .multilineTextAlignment(.center)
    .padding(.horizontal, 28)
    .padding(.vertical, 14)
    .frame(minWidth: 260, maxWidth: 680)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color(red: 0.09, green: 0.11, blue: 0.15).opacity(0.88))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(Color.white.opacity(0.18), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
  }

  private func selectItem(_ newIdx: Int) {
    let list = session.mediaMessages
    guard !list.isEmpty else { return }
    currentIndex = (newIdx + list.count) % list.count
    didFallbackToDirectUrl = false
    using115Direct = false
    active115StreamUrl = ""
    active115Headers = [:]
    appState.cancel115Acceleration()
    loadCurrentMedia()
  }

  private func handle115AccelerateButtonTap() {
    if appState.is115Accelerating {
      appState.cancel115Acceleration()
      appState.showToast("已取消 115 云端加速任务")
      return
    }
    if !TvLocal115DirectClient.shared.hasLocalCookie {
      show115LoginSheet = true
      return
    }
    trigger115CloudAcceleration()
  }

  private func trigger115CloudAcceleration() {
    let msg = currentMessage
    guard msg.isVideo || msg.isAudio else { return }
    let downloadUrl = msg.isVideo
      ? appState.api.telegramVideoUrl(accountId: session.accountId, peer: session.chat.peer, messageId: msg.id)
      : appState.api.telegramFileContentUrl(accountId: session.accountId, peer: session.chat.peer, messageId: msg.id)
    let rawTitle = msg.attachment?.displayName ?? ""
    let cleanPeer = session.chat.peer.replacingOccurrences(of: ":", with: "_")
    let videoName = rawTitle.isEmpty ? "telegram_\(cleanPeer)_\(msg.id).mp4" : rawTitle

    appState.start115AcceleratedPlayback(
      downloadUrl: downloadUrl,
      videoName: videoName,
      headers: appState.api.authHeaders,
      telegramAccountId: session.accountId
    ) { proxyStreamUrl, _, headers115, _ in
      let savedPos = self.positionSec
      self.using115Direct = true
      self.active115StreamUrl = proxyStreamUrl
      self.active115Headers = headers115
      self.loadCurrentMedia(resumeAt: savedPos, useDirectRemoteUrl: false, custom115Url: proxyStreamUrl, custom115Headers: headers115)
    }
  }

  private func resumeCurrentMediaFromStall(at savedPosition: Double, preferDirectFallback: Bool = false) {
    if using115Direct, !active115StreamUrl.isEmpty {
      loadCurrentMedia(resumeAt: savedPosition, useDirectRemoteUrl: false, custom115Url: active115StreamUrl, custom115Headers: active115Headers)
      return
    }
    if preferDirectFallback {
      didFallbackToDirectUrl = true
    }
    loadCurrentMedia(resumeAt: savedPosition, useDirectRemoteUrl: didFallbackToDirectUrl)
  }

  private func loadCurrentMedia(
    resumeAt: Double? = nil,
    useDirectRemoteUrl: Bool = false,
    custom115Url: String? = nil,
    custom115Headers: [String: String]? = nil
  ) {
    cleanupPlayer()
    appState.activateScenarioProxyTunnel(for: .telegram)
    let msg = currentMessage
    guard msg.isVideo || msg.isAudio else {
      isPlaying = false
      userWantsToPlay = false
      isBuffering = false
      positionSec = 0
      durationSec = 0
      bufferedSec = 0
      return
    }

    let streamUrl: String
    if let c115 = custom115Url, !c115.isEmpty {
      streamUrl = c115
    } else if useDirectRemoteUrl {
      streamUrl = msg.isVideo
        ? appState.api.telegramVideoUrl(accountId: session.accountId, peer: session.chat.peer, messageId: msg.id)
        : appState.api.telegramFileContentUrl(accountId: session.accountId, peer: session.chat.peer, messageId: msg.id)
    } else {
      streamUrl = msg.isVideo
        ? appState.api.telegramAcceleratedVideoUrl(accountId: session.accountId, peer: session.chat.peer, messageId: msg.id)
        : appState.api.telegramAcceleratedFileContentUrl(accountId: session.accountId, peer: session.chat.peer, messageId: msg.id)
    }
    guard let url = URL(string: streamUrl) else { return }

    let options: [String: Any] = [
      "AVURLAssetHTTPHeaderFieldsKey": custom115Headers ?? appState.api.authHeaders
    ]
    let asset = AVURLAsset(url: url, options: options)
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = 30
    if durationSec <= 0 || resumeAt == nil {
      durationSec = Double(msg.attachment?.duration ?? 0)
    }
    let initialSeek = max(0, resumeAt ?? 0)
    positionSec = initialSeek
    lastObservedPos = initialSeek
    lastProgressAdvanceAt = Date()
    bufferedSec = initialSeek
    isBuffering = true
    userWantsToPlay = true
    isPlaying = true

    player.replaceCurrentItem(with: item)
    player.automaticallyWaitsToMinimizeStalling = true
    player.isMuted = isMuted
    if initialSeek > 0.8 {
      let target = CMTime(seconds: initialSeek, preferredTimescale: 600)
      let tol = CMTime(seconds: 0.5, preferredTimescale: 600)
      player.seek(to: target, toleranceBefore: tol, toleranceAfter: tol) { [weak player] _ in
        player?.playImmediately(atRate: self.playbackRate)
      }
    } else {
      player.playImmediately(atRate: playbackRate)
    }

    let interval = CMTime(seconds: 0.4, preferredTimescale: 600)
    timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
      let sec = CMTimeGetSeconds(time)
      if sec.isFinite && sec >= 0 {
        if Date().timeIntervalSince(self.lastManualSeekAt) >= 0.85 {
          self.positionSec = sec
        }
        if abs(sec - self.lastObservedPos) > 0.12 {
          self.lastObservedPos = sec
          self.lastProgressAdvanceAt = Date()
          self.isBuffering = false
        }
      }
      if let curItem = self.player.currentItem {
        let dur = CMTimeGetSeconds(curItem.duration)
        if dur.isFinite && dur > 0 {
          self.durationSec = dur
        }
        if let timeRange = curItem.loadedTimeRanges.first?.timeRangeValue {
          let bufEnd = CMTimeGetSeconds(CMTimeAdd(timeRange.start, timeRange.duration))
          if bufEnd.isFinite && bufEnd > 0 {
            self.bufferedSec = bufEnd
          }
        }
      }
      self.isPlaying = self.userWantsToPlay
    }

    endObserverToken = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { _ in
      // Guard against premature EOF when an upstream HTTP range closes early mid-video (matches telegram_screen.dart lines 15705-15725)
      if self.durationSec > 6 && self.positionSec > 1 && self.positionSec < self.durationSec - 4 {
        self.resumeCurrentMediaFromStall(at: self.positionSec)
        return
      }
      if self.session.mediaMessages.count > 1 {
        self.selectItem(self.currentIndex + 1)
      } else {
        self.positionSec = 0
        self.lastObservedPos = 0
        self.lastProgressAdvanceAt = Date()
        self.player.seek(to: .zero) { [weak player] _ in
          if self.userWantsToPlay {
            player?.playImmediately(atRate: self.playbackRate)
          }
        }
      }
    }

    stallObserverToken = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemPlaybackStalled,
      object: item,
      queue: .main
    ) { _ in
      guard self.userWantsToPlay else { return }
      self.isBuffering = true
      self.player.play()
    }

    failObserverToken = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime,
      object: item,
      queue: .main
    ) { _ in
      guard self.userWantsToPlay else { return }
      self.resumeCurrentMediaFromStall(at: self.positionSec, preferDirectFallback: !self.didFallbackToDirectUrl)
    }
  }

  private func togglePlayPause() {
    if userWantsToPlay && player.rate > 0 {
      userWantsToPlay = false
      isPlaying = false
      isBuffering = false
      player.pause()
    } else {
      userWantsToPlay = true
      isPlaying = true
      lastProgressAdvanceAt = Date()
      player.playImmediately(atRate: playbackRate)
    }
  }

  private func seekRelative(_ delta: Double) {
    lastInteractionAt = Date()
    lastManualSeekAt = Date()
    lastProgressAdvanceAt = Date()
    lastSeekDeltaSec = Int(delta)
    let maxDur = durationSec > 0 ? durationSec : max(0, positionSec + delta + 3600)
    let target = min(maxDur, max(0, positionSec + delta))
    positionSec = target
    player.currentItem?.cancelPendingSeeks()
    let tol = CMTime(seconds: 1.2, preferredTimescale: 600)
    player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol) { [weak player] _ in
      if self.userWantsToPlay {
        player?.playImmediately(atRate: self.playbackRate)
      }
    }
  }

  private func cycleRate() {
    let rates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    let idx = rates.firstIndex(of: playbackRate) ?? 2
    playbackRate = rates[(idx + 1) % rates.count]
    if userWantsToPlay {
      player.rate = playbackRate
    }
  }

  private func cleanupPlayer() {
    if let token = timeObserverToken {
      player.removeTimeObserver(token)
      timeObserverToken = nil
    }
    if let endToken = endObserverToken {
      NotificationCenter.default.removeObserver(endToken)
      endObserverToken = nil
    }
    if let stallToken = stallObserverToken {
      NotificationCenter.default.removeObserver(stallToken)
      stallObserverToken = nil
    }
    if let failToken = failObserverToken {
      NotificationCenter.default.removeObserver(failToken)
      failObserverToken = nil
    }
    player.pause()
    player.replaceCurrentItem(with: nil)
  }

  private func formatClock(_ seconds: Double) -> String {
    let total = Int(max(0, seconds))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
      return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%02d:%02d", m, s)
  }
}

/// Square rounded video preview thumbnail item in the bottom gallery strip (matches screenshot 2)
private struct TvGalleryBottomThumbnailButton: View {
  @EnvironmentObject var appState: TvAppState
  @Environment(\.isFocused) private var isFocused
  let accountId: String
  let peer: String
  let item: TvTelegramMessage
  let index: Int
  let isActive: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        TvRemoteImage(
          rawUrl: appState.api.telegramThumbnailUrl(
            accountId: accountId,
            peer: peer,
            messageId: item.id
          ),
          placeholderIcon: item.isVideo ? "video.fill" : "photo",
          contentMode: .fill
        )
        .frame(width: 88, height: 88)
        .clipped()

        Color.black.opacity(isActive ? 0.10 : 0.28)

        if item.isVideo {
          Circle()
            .fill(Color.white.opacity(0.92))
            .frame(width: 30, height: 30)
            .overlay(
              Image(systemName: "play.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Color(red: 0.08, green: 0.10, blue: 0.14))
                .offset(x: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
        }
      }
      .frame(width: 88, height: 88)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(
            isFocused
              ? Color.white
              : (isActive ? Color(red: 0.24, green: 0.62, blue: 0.98) : Color.white.opacity(0.16)),
            lineWidth: (isFocused || isActive) ? 3.2 : 1.0
          )
      )
      .scaleEffect(isFocused ? 1.08 : (isActive ? 1.03 : 1.0))
      .shadow(color: .black.opacity((isFocused || isActive) ? 0.5 : 0.2), radius: (isFocused || isActive) ? 12 : 4)
      .animation(.spring(response: 0.25, dampingFraction: 0.78), value: isFocused)
    }
    .buttonStyle(.plain)
  }
}

struct TvRawAVPlayerLayerView: UIViewRepresentable {
  let player: AVPlayer
  let videoGravity: AVLayerVideoGravity

  func makeUIView(context: Context) -> PlayerUIView {
    let view = PlayerUIView()
    view.playerLayer.player = player
    view.playerLayer.videoGravity = videoGravity
    return view
  }

  func updateUIView(_ uiView: PlayerUIView, context: Context) {
    uiView.playerLayer.player = player
    uiView.playerLayer.videoGravity = videoGravity
  }

  final class PlayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
  }
}

struct TvDirectFlvHardwareLayerView: UIViewRepresentable {
  let engine: TvDirectFlvHardwareEngine
  let videoGravity: AVLayerVideoGravity

  func makeUIView(context: Context) -> FlvHardwareUIView {
    let view = FlvHardwareUIView()
    view.attach(engine: engine, videoGravity: videoGravity)
    return view
  }

  func updateUIView(_ uiView: FlvHardwareUIView, context: Context) {
    uiView.attach(engine: engine, videoGravity: videoGravity)
  }

  final class FlvHardwareUIView: UIView {
    private weak var attachedLayer: AVSampleBufferDisplayLayer?

    func attach(engine: TvDirectFlvHardwareEngine, videoGravity: AVLayerVideoGravity) {
      let dl = engine.displayLayer
      dl.videoGravity = videoGravity
      if attachedLayer !== dl || dl.superlayer !== self.layer {
        dl.removeFromSuperlayer()
        self.layer.addSublayer(dl)
        attachedLayer = dl
      }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      dl.frame = self.bounds
      CATransaction.commit()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      guard let dl = attachedLayer else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      dl.frame = self.bounds
      CATransaction.commit()
    }
  }
}

struct TvVideoCanvasStageButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.99 : 1.0)
  }
}

// MARK: - Unified In-Player Proxy Node & Route Selector Sheet (1:1 Match with VideoProxyNodeSelector in lib/ui/widgets/video_proxy_node_selector.dart)

struct TvVideoProxyNodeSelectorSheet: View {
  @EnvironmentObject var appState: TvAppState
  @Binding var isPresented: Bool
  let scenario: TvRequestScenario
  let onRouteChanged: () -> Void

  var body: some View {
    let theme = appState.activeTheme
    let effective = appState.resolveEffectiveRoute(for: scenario)
    let rule = appState.rule(for: scenario)
    let activeNode = appState.resolveNode(for: scenario)
    let sortedNodes = appState.activePoolNodes.sorted { a, b in
      if a.favorite != b.favorite { return a.favorite && !b.favorite }
      return (a.latencyMs ?? 9999) < (b.latencyMs ?? 9999)
    }

    ZStack {
      LinearGradient(
        colors: [Color(red: 0.06, green: 0.08, blue: 0.13), Color(red: 0.03, green: 0.04, blue: 0.07)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      VStack(alignment: .leading, spacing: 20) {
        // Header
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
              Image(systemName: "network.badge.shield.half.filled")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(theme.accentHover)
              Text("\(scenario.label) · 代理线路与节点切换")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
            }
            Text("当前生效策略：\(effective.label)\(activeNode != nil && effective == .proxyNode ? " · \(activeNode!.displayTitle) (\(activeNode!.formattedLatency))" : "")")
              .font(.system(size: 14, weight: .medium))
              .foregroundColor(theme.accentHover)
          }

          Spacer()

          Button {
            Task { await appState.testAllNodesLatency() }
          } label: {
            Label(appState.isRefreshingSubscription ? "正在测速..." : "重测全部延迟", systemImage: "bolt.horizontal.circle.fill")
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))

          Button("关闭") {
            isPresented = false
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))
        }
        .focusSection()

        // 3 Core Route Strategy Cards (`直连播放`, `自动择优(最快节点)`, `服务端代理中转`)
        HStack(spacing: 14) {
          let isDirect = (effective == .direct)
          Button {
            appState.applyInPlayerProxyChoice(scenario: scenario, choice: "direct")
            isPresented = false
            onRouteChanged()
          } label: {
            HStack(spacing: 12) {
              Image(systemName: isDirect ? "checkmark.circle.fill" : "globe")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(isDirect ? Color(red: 0.25, green: 0.85, blue: 0.50) : .white.opacity(0.75))
              VStack(alignment: .leading, spacing: 3) {
                Text("直连播放（不走代理）")
                  .font(.system(size: 16, weight: .bold))
                  .foregroundColor(.white)
                Text("本地网络直接请求视频源")
                  .font(.system(size: 12))
                  .foregroundColor(.white.opacity(0.55))
              }
              Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
          }
          .buttonStyle(TvAppleSurfaceButtonStyle(isSelected: isDirect, cornerRadius: 14))

          let isAutoFastest = (effective == .proxyNode && rule.specificNodeId == nil && appState.proxySelectionMode == .autoFastest)
          let fastestLabel = appState.fastestProxyNode.map { "\($0.displayTitle) · \($0.formattedLatency)" } ?? "自动选择最低延迟节点"
          Button {
            appState.applyInPlayerProxyChoice(scenario: scenario, choice: "auto_fastest")
            isPresented = false
            onRouteChanged()
          } label: {
            HStack(spacing: 12) {
              Image(systemName: isAutoFastest ? "checkmark.circle.fill" : "bolt.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(isAutoFastest ? Color(red: 0.25, green: 0.85, blue: 0.50) : Color.yellow)
              VStack(alignment: .leading, spacing: 3) {
                Text("自动择优（最低延迟节点）")
                  .font(.system(size: 16, weight: .bold))
                  .foregroundColor(.white)
                Text(fastestLabel)
                  .font(.system(size: 12))
                  .foregroundColor(.white.opacity(0.65))
                  .lineLimit(1)
              }
              Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
          }
          .buttonStyle(TvAppleSurfaceButtonStyle(isSelected: isAutoFastest, cornerRadius: 14))

          let isServerRelay = (effective == .serverRelay)
          Button {
            appState.applyInPlayerProxyChoice(scenario: scenario, choice: "server_relay")
            isPresented = false
            onRouteChanged()
          } label: {
            HStack(spacing: 12) {
              Image(systemName: isServerRelay ? "checkmark.circle.fill" : "server.rack")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(isServerRelay ? Color(red: 0.25, green: 0.85, blue: 0.50) : Color(red: 0.35, green: 0.78, blue: 1.0))
              VStack(alignment: .leading, spacing: 3) {
                Text("服务端代理中转")
                  .font(.system(size: 16, weight: .bold))
                  .foregroundColor(.white)
                Text("通过主服务端 /api/vod/proxy 加速")
                  .font(.system(size: 12))
                  .foregroundColor(.white.opacity(0.55))
              }
              Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
          }
          .buttonStyle(TvAppleSurfaceButtonStyle(isSelected: isServerRelay, cornerRadius: 14))
        }
        .focusSection()

        Divider()
          .background(Color.white.opacity(0.14))

        // Specific Proxy Nodes Grid
        HStack {
          Text("指定代理节点（共 \(sortedNodes.count) 个可用节点，来自 \(max(1, appState.subscriptions.filter(\.enabled).count)) 个启用订阅）")
            .font(.system(size: 15, weight: .bold))
            .foregroundColor(.white.opacity(0.85))
          Spacer()
        }

        if sortedNodes.isEmpty {
          VStack(spacing: 12) {
            Text("当前暂无订阅代理节点，可先选择上方「服务端代理中转」或前往「代理与订阅」页面扫码添加订阅")
              .font(.system(size: 15))
              .foregroundColor(.white.opacity(0.60))
          }
          .frame(maxWidth: .infinity, minHeight: 220)
        } else {
          ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 295, maximum: 350), spacing: 12)], spacing: 12) {
              ForEach(sortedNodes) { node in
                let isSelectedNode = (effective == .proxyNode && activeNode?.id == node.id)
                let latColor: Color = {
                  guard let ms = node.latencyMs else { return .white.opacity(0.45) }
                  if ms >= 9999 { return Color(red: 1.0, green: 0.36, blue: 0.34) }
                  if ms <= 260 { return Color(red: 0.20, green: 0.84, blue: 0.48) }
                  if ms <= 550 { return Color(red: 1.0, green: 0.72, blue: 0.16) }
                  return Color(red: 1.0, green: 0.45, blue: 0.26)
                }()

                Button {
                  appState.applyInPlayerProxyChoice(scenario: scenario, choice: "node:\(node.id)")
                  isPresented = false
                  onRouteChanged()
                } label: {
                  VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                      Text(node.type.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.accentHover)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.accent.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                      Text(node.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                      Spacer(minLength: 4)

                      Text(node.formattedLatency)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(latColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(latColor.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }

                    HStack(spacing: 6) {
                      Text("\(node.subscriptionName) · \(node.host):\(node.port)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.48))
                        .lineLimit(1)

                      Spacer(minLength: 4)

                      if isSelectedNode {
                        Image(systemName: "checkmark.circle.fill")
                          .font(.system(size: 13))
                          .foregroundColor(Color(red: 0.25, green: 0.85, blue: 0.50))
                      }
                    }
                  }
                  .padding(.horizontal, 12)
                  .padding(.vertical, 10)
                }
                .buttonStyle(TvAppleSurfaceButtonStyle(isSelected: isSelectedNode, cornerRadius: 11))
              }
            }
            .padding(4)
          }
          .focusSection()
        }
      }
      .padding(40)
    }
  }
}

// MARK: - In-Player 115 Cloud Acceleration HUD & Quick QR/Cookie Login Sheet

struct Tv115AccelerationOverlayCard: View {
  let stageTitle: String
  let detailText: String
  let progress: Double
  let onCancel: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      HStack(spacing: 12) {
        ProgressView()
          .scaleEffect(1.2)
        Text(stageTitle.isEmpty ? "⚡ 正在通过服务器下载并转存至 115 网盘..." : stageTitle)
          .font(.system(size: 21, weight: .bold))
          .foregroundColor(.white)
          .lineLimit(1)
      }

      GeometryReader { geo in
        let w = max(1, geo.size.width)
        let ratio = min(max(0.03, progress), 1.0)
        ZStack(alignment: .leading) {
          Capsule()
            .fill(Color.white.opacity(0.18))
            .frame(height: 10)
          Capsule()
            .fill(
              LinearGradient(
                colors: [Color(red: 0.20, green: 0.65, blue: 1.0), Color(red: 0.25, green: 0.88, blue: 0.58)],
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .frame(width: w * ratio, height: 10)
        }
      }
      .frame(width: 520, height: 10)

      HStack(spacing: 16) {
        Text(detailText)
          .font(.system(size: 16, weight: .medium, design: .monospaced))
          .foregroundColor(.white.opacity(0.82))
          .lineLimit(1)

        Spacer()

        Button(action: onCancel) {
          Label("取消加速", systemImage: "xmark.circle.fill")
        }
        .buttonStyle(TvApplePillButtonStyle(isDestructive: true, compact: true))
      }
      .frame(width: 520)
    }
    .padding(.horizontal, 34)
    .padding(.vertical, 24)
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 26, style: .continuous)
        .stroke(Color.white.opacity(0.20), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
  }
}

struct Tv115QuickLoginSheet: View {
  @EnvironmentObject var appState: TvAppState
  @Binding var isPresented: Bool
  let onLoginCompleted: () -> Void
  @State private var cookieInput: String = ""
  @State private var didRequestInitialQr: Bool = false

  var body: some View {
    let theme = appState.activeTheme
    ZStack {
      LinearGradient(
        colors: [Color(red: 0.06, green: 0.08, blue: 0.13), Color(red: 0.03, green: 0.04, blue: 0.07)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      VStack(spacing: 24) {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("⚡ 登录 115 网盘开启「云端下载 + 本地直连 115 播放」")
              .font(.system(size: 26, weight: .bold))
              .foregroundColor(.white)
            Text("使用手机 115 网盘 App 扫描下方二维码，扫码确认后将自动启动「服务器高速下载 → 上传 115 → 本地直连 115 播放」")
              .font(.system(size: 16))
              .foregroundColor(.white.opacity(0.70))
          }
          Spacer()
          Button("关闭") {
            isPresented = false
          }
          .buttonStyle(TvApplePillButtonStyle(compact: true))
        }
        .focusSection()

        HStack(spacing: 36) {
          // Left: QR Code Card
          VStack(spacing: 14) {
            if !appState.qr115Content.isEmpty {
              TvQRCodeImageView(content: appState.qr115Content, size: 220)
            } else if !appState.qr115ImageUrl.isEmpty {
              TvRemoteImage(rawUrl: appState.qr115ImageUrl, placeholderIcon: "qrcode", contentMode: .fit)
                .frame(width: 220, height: 220)
                .background(Color.white)
                .cornerRadius(20)
            } else {
              ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                  .fill(Color.white.opacity(0.08))
                  .frame(width: 240, height: 240)
                ProgressView("正在加载二维码...")
              }
            }

            Text(appState.qr115StatusText.isEmpty ? "请使用手机 115 App 扫码登录" : appState.qr115StatusText)
              .font(.system(size: 16, weight: .semibold))
              .foregroundColor(theme.accentHover)
              .multilineTextAlignment(.center)
              .frame(maxWidth: 320)

            Button {
              Task {
                await appState.start115QrCode(forceRefresh: true) {
                  isPresented = false
                  onLoginCompleted()
                }
              }
            } label: {
              Label("刷新二维码", systemImage: "arrow.clockwise")
            }
            .buttonStyle(TvApplePillButtonStyle(compact: true))
          }
          .padding(28)
          .background(Color.white.opacity(0.06))
          .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
          .focusSection()

          // Right: Cookie Input & LAN Phone Push Hint
          VStack(alignment: .leading, spacing: 18) {
            Text("方式二：粘贴 115 Cookie 登录")
              .font(.system(size: 20, weight: .bold))
              .foregroundColor(.white)

            Text("包含 UID=...; CID=...; SEID=... 的 115 浏览器 Cookie 字符串：")
              .font(.system(size: 15))
              .foregroundColor(.white.opacity(0.68))

            TextField("UID=...; CID=...; SEID=...", text: $cookieInput)

            Button {
              let trimmed = cookieInput.trimmingCharacters(in: .whitespacesAndNewlines)
              guard !trimmed.isEmpty else { return }
              Task {
                await appState.save115Cookie(trimmed)
                if TvLocal115DirectClient.shared.hasLocalCookie {
                  isPresented = false
                  onLoginCompleted()
                }
              }
            } label: {
              Label("保存 Cookie 并立即开始 115 加速", systemImage: "bolt.horizontal.icloud.fill")
            }
            .buttonStyle(TvApplePillButtonStyle(isPrimary: true))

            if !appState.lanInputUrl.isEmpty {
              Divider()
                .background(Color.white.opacity(0.14))
              Text("💡 也可在手机浏览器访问局域网助手直接粘贴 Cookie：\(appState.lanInputUrl)")
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(theme.accentHover)
            }
          }
          .padding(28)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.white.opacity(0.06))
          .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
          .focusSection()
        }
      }
      .padding(48)
    }
    .onAppear {
      appState.startLanInputServer()
      guard !didRequestInitialQr else { return }
      didRequestInitialQr = true
      Task {
        await appState.start115QrCode(forceRefresh: false) {
          isPresented = false
          onLoginCompleted()
        }
      }
    }
  }
}
