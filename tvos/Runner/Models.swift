import Foundation
import SwiftUI

// MARK: - Top-level Navigation Sections

enum TvMainSection: String, CaseIterable, Identifiable {
  case vod = "影视点播"
  case live = "电视直播"
  case telegram = "Telegram"
  case favorites = "收藏历史"
  case downloads = "下载嗅探"
  case mediaLibrary = "媒体库"
  case music = "流光音乐"
  case proxy = "代理加速"
  case settings = "系统设置"

  var id: String { rawValue }

  var iconName: String {
    switch self {
    case .vod: return "play.tv.fill"
    case .live: return "dot.radiowaves.left.and.right"
    case .telegram: return "paperplane.fill"
    case .favorites: return "heart.text.square.fill"
    case .downloads: return "arrow.down.circle.fill"
    case .mediaLibrary: return "externaldrive.fill.badge.play"
    case .music: return "opticaldisc.fill"
    case .proxy: return "network.badge.shield.half.filled"
    case .settings: return "gearshape.fill"
    }
  }
}

// MARK: - Official Telegram Color & Avatar Palette

enum TvTelegramPalette {
  static let folderRailBg = Color(red: 0.055, green: 0.086, blue: 0.129)       // #0E1621
  static let folderRailActive = Color(red: 0.369, green: 0.710, blue: 0.969)   // #5EB5F7
  static let folderRailInactive = Color(red: 0.463, green: 0.549, blue: 0.620) // #768C9E

  static let sidebarBg = Color(red: 0.090, green: 0.129, blue: 0.169)          // #17212B
  static let sidebarHover = Color(red: 0.125, green: 0.169, blue: 0.212)       // #202B36
  static let sidebarSelected = Color(red: 0.169, green: 0.322, blue: 0.471)    // #2B5278
  static let searchFill = Color(red: 0.141, green: 0.184, blue: 0.239)         // #242F3D

  static let chatWallpaperBg = Color(red: 0.055, green: 0.086, blue: 0.129)    // #0E1621
  static let headerBg = Color(red: 0.090, green: 0.129, blue: 0.169)           // #17212B
  static let composeBg = Color(red: 0.090, green: 0.129, blue: 0.169)          // #17212B

  static let bubbleIn = Color(red: 0.094, green: 0.145, blue: 0.200)           // #182533
  static let bubbleOut = Color(red: 0.169, green: 0.322, blue: 0.471)          // #2B5278
  static let bubbleSelected = Color(red: 0.141, green: 0.259, blue: 0.388)     // #244263
  static let datePillBg = Color(red: 0.118, green: 0.173, blue: 0.227).opacity(0.82)

  static let tgBlue = Color(red: 0.322, green: 0.533, blue: 0.757)             // #5288C1
  static let tgBlueBright = Color(red: 0.243, green: 0.600, blue: 0.933)       // #3E99EE
  static let onlineGreen = Color(red: 0.306, green: 0.800, blue: 0.369)        // #4ECC5E
  static let dangerRed = Color(red: 0.898, green: 0.302, blue: 0.259)          // #E54D42

  static let textPrimary = Color(red: 0.961, green: 0.961, blue: 0.961)        // #F5F5F5
  static let textSecondary = Color(red: 0.498, green: 0.569, blue: 0.643)      // #7F91A4
  static let textMuted = Color(red: 0.424, green: 0.471, blue: 0.514)          // #6C7883
  static let borderLine = Color(red: 0.063, green: 0.098, blue: 0.129)         // #101921

  static let avatarGradients: [[Color]] = [
    [Color(red: 1.00, green: 0.53, blue: 0.37), Color(red: 0.90, green: 0.33, blue: 0.29)], // Red-Orange
    [Color(red: 1.00, green: 0.80, blue: 0.42), Color(red: 1.00, green: 0.59, blue: 0.21)], // Amber-Orange
    [Color(red: 0.51, green: 0.69, blue: 1.00), Color(red: 0.40, green: 0.37, blue: 1.00)], // Violet-Indigo
    [Color(red: 0.63, green: 0.87, blue: 0.49), Color(red: 0.27, green: 0.73, blue: 0.40)], // Emerald-Green
    [Color(red: 0.33, green: 0.93, blue: 0.84), Color(red: 0.16, green: 0.79, blue: 0.72)], // Cyan-Teal
    [Color(red: 0.45, green: 0.84, blue: 0.99), Color(red: 0.16, green: 0.62, blue: 0.95)], // Sky-Blue
    [Color(red: 0.88, green: 0.64, blue: 0.95), Color(red: 0.84, green: 0.41, blue: 0.93)], // Pink-Purple
  ]

  static func peerAvatarColors(_ seed: String) -> [Color] {
    var hash = 0
    for scalar in seed.unicodeScalars {
      hash = (hash &* 31) &+ Int(scalar.value)
    }
    let idx = abs(hash) % avatarGradients.count
    return avatarGradients[idx]
  }

  static func peerNameColor(_ seed: String) -> Color {
    peerAvatarColors(seed).last ?? tgBlueBright
  }
}

struct TvEmojiCategory: Identifiable {
  var id: String { title }
  let icon: String
  let title: String
  let items: [String]
  let isTextPhrase: Bool
}

let kTvTelegramEmojiCategories: [TvEmojiCategory] = [
  TvEmojiCategory(
    icon: "😀",
    title: "常用表情",
    items: [
      "😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂", "🙂", "😉",
      "😊", "😇", "🥰", "😍", "🤩", "😘", "😋", "😜", "🤪", "🤗",
      "🤔", "🫡", "🤫", "😏", "😌", "😴", "🥳", "😎", "🧐", "🥺",
      "🥹", "😮", "😳", "😭", "😱", "😤", "😡", "😈", "👻", "🤖"
    ],
    isTextPhrase: false
  ),
  TvEmojiCategory(
    icon: "👋",
    title: "手势互动",
    items: [
      "👍", "👎", "👏", "🙌", "🫶", "🤝", "🙏", "👌", "✌️", "🤞",
      "🤙", "💪", "👋", "🤚", "✋", "👊", "🤛", "🤜", "☝️", "👆",
      "👇", "👈", "👉", "🫡", "✍️", "👀", "🎉", "🎊", "🏆", "🥇"
    ],
    isTextPhrase: false
  ),
  TvEmojiCategory(
    icon: "❤️",
    title: "心形符号",
    items: [
      "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "💔", "❤️‍🔥",
      "💕", "💖", "💘", "🔥", "✨", "🌟", "💫", "💥", "💯", "✅",
      "❌", "⚠️", "🔔", "📢", "💬", "🎬", "📺", "🎧", "🚀", "💎"
    ],
    isTextPhrase: false
  ),
  TvEmojiCategory(
    icon: "✨",
    title: "快捷短语与颜文字",
    items: [
      "收到，谢谢！👍",
      "感谢分享 ❤️",
      "求补档 🙏",
      "清晰度非常棒 🎬",
      "辛苦了！🙏",
      "好的，马上处理 ✅",
      "(づ｡◕‿‿◕｡)づ",
      "¯\\_(ツ)_/¯",
      "(❁´◡`❁)",
      "(≧∇≦)ﾉ",
      "(｡♥‿♥｡)",
      "✧(≖ ◡ ≖✿)"
    ],
    isTextPhrase: true
  )
]

// MARK: - VOD Models

struct TvVodSource: Identifiable, Hashable, Codable {
  let id: String
  let name: String
  let api: String
  let isTvBox: Bool
  let customIndex: Int
  let tvboxType: Int
  let tvboxSiteIndex: Int
  let tvboxSourceIndex: Int
  let tvboxSourceName: String
  let searchable: Bool

  var displayName: String {
    if isTvBox {
      return tvboxSourceName.isEmpty ? "[TVBox] \(name)" : "\(name) (\(tvboxSourceName))"
    }
    return name
  }

  var isSpiderSource: Bool {
    api.lowercased().hasPrefix("csp_") || tvboxType == 3
  }

  var librarySourceKey: String {
    isTvBox ? "tvbox:\(tvboxSourceIndex):\(tvboxSiteIndex)" : String(customIndex)
  }

  var queryItems: [URLQueryItem] {
    if isTvBox {
      return [
        URLQueryItem(name: "tvbox", value: String(tvboxSiteIndex)),
        URLQueryItem(name: "tvbox_source", value: String(tvboxSourceIndex)),
      ]
    }
    return [URLQueryItem(name: "source", value: String(customIndex))]
  }
}

struct TvVodCategory: Identifiable, Hashable, Codable {
  var id: String { typeId }
  let typeId: String
  let typeName: String
}

struct TvVodItem: Identifiable, Hashable {
  var id: String { "\(source.id)_\(vodId)" }
  let vodId: String
  let vodName: String
  let vodPic: String
  let vodRemarks: String
  let vodYear: String
  let typeName: String
  let source: TvVodSource
}

struct TvVodListResponse {
  let categories: [TvVodCategory]
  let items: [TvVodItem]
  let pageCount: Int
  let resolvedTypeId: String?
}

struct TvEpisode: Identifiable, Hashable {
  var id: String { "\(groupName)_\(index)_\(title)" }
  let index: Int
  let title: String
  let rawUrl: String
  let groupName: String
}

struct TvPlayGroup: Identifiable, Hashable {
  var id: String { name }
  let name: String
  let episodes: [TvEpisode]
}

struct TvVodDetail: Identifiable, Hashable {
  var id: String { vodId }
  let vodId: String
  let vodName: String
  let vodPic: String
  let vodRemarks: String
  let vodYear: String
  let vodArea: String
  let vodActor: String
  let vodDirector: String
  let vodContent: String
  let typeName: String
  let playGroups: [TvPlayGroup]

  static func parsePlayGroups(playFrom: String, playUrl: String, fallbackVodId: String = "") -> [TvPlayGroup] {
    let trimmedPlayUrl = playUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedPlayUrl.isEmpty {
      if fallbackVodId.hasPrefix("http://")
          || fallbackVodId.hasPrefix("https://")
          || fallbackVodId.hasPrefix("push://") {
        let gName = playFrom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? "默认线路"
          : playFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
          TvPlayGroup(
            name: gName,
            episodes: [TvEpisode(index: 0, title: "正片", rawUrl: fallbackVodId, groupName: gName)]
          )
        ]
      }
      return []
    }

    let fromParts = playFrom.isEmpty
      ? ["默认线路"]
      : playFrom
          .components(separatedBy: "$$$")
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    let urlGroups = trimmedPlayUrl
      .components(separatedBy: "$$$")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

    var groups: [TvPlayGroup] = []
    for (gIdx, rawGroupUrl) in urlGroups.enumerated() where !rawGroupUrl.isEmpty {
      let groupName = (gIdx < fromParts.count && !fromParts[gIdx].isEmpty)
        ? fromParts[gIdx]
        : "线路 \(gIdx + 1)"
      let rawEps = rawGroupUrl
        .components(separatedBy: "#")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      var episodes: [TvEpisode] = []
      for entry in rawEps {
        let dollarRange = entry.range(of: "$")
        let schemeRange = entry.range(of: "://")
        var title: String
        var url: String
        if let dRange = dollarRange, (schemeRange == nil || dRange.lowerBound < schemeRange!.lowerBound) {
          title = String(entry[..<dRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
          url = String(entry[dRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
          title = "第 \(episodes.count + 1) 集"
          url = entry
        }
        if title.isEmpty {
          title = "第 \(episodes.count + 1) 集"
        }
        if !url.isEmpty {
          episodes.append(
            TvEpisode(
              index: episodes.count,
              title: title,
              rawUrl: url,
              groupName: groupName
            )
          )
        }
      }
      if !episodes.isEmpty {
        groups.append(TvPlayGroup(name: groupName, episodes: episodes))
      }
    }

    groups.sort { a, b in
      let aM3u8 = a.name.lowercased().contains("m3u8")
        || a.episodes.contains { $0.rawUrl.lowercased().contains(".m3u8") }
      let bM3u8 = b.name.lowercased().contains("m3u8")
        || b.episodes.contains { $0.rawUrl.lowercased().contains(".m3u8") }
      if aM3u8 && !bM3u8 { return true }
      if !aM3u8 && bM3u8 { return false }
      return false
    }

    return groups
  }
}

struct TvResolvedPlayback: Hashable {
  let directUrl: String
  let serverProxyUrl: String
  let headers: [String: String]
  let parseVia: String
  let backendProxyPlayback: Bool
  var isFlvHardwareStream: Bool = false
  var flvPrimaryUrl: String = ""
  var flvGatewayUrl: String = ""
}

// MARK: - Live TV Models

struct TvLiveSource: Identifiable, Hashable, Codable {
  var id: String { isCustom ? "custom_\(url)" : "tvbox_\(sourceIndex)_\(liveIndex)_\(name)" }
  let name: String
  let url: String
  let ua: String
  let origin: String
  let referer: String
  let sourceName: String
  let sourceIndex: Int
  let liveIndex: Int
  let isCustom: Bool

  var displayName: String {
    sourceName.isEmpty ? name : "\(name) (\(sourceName))"
  }

  var defaultHeaders: [String: String] {
    var h: [String: String] = [
      "User-Agent": ua.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "okhttp/3.15"
        : ua.trimmingCharacters(in: .whitespacesAndNewlines)
    ]
    if !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      h["Origin"] = origin.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if !referer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      h["Referer"] = referer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return h
  }
}

struct TvLiveChannel: Identifiable, Hashable, Codable {
  var id: String { "\(group)@@\(name)" }
  let name: String
  let group: String
  let urls: [String]
  let logo: String
  let headers: [String: String]
}

// MARK: - Library (Favorites & History) Models

struct TvLibraryItem: Identifiable, Hashable, Codable {
  var id: String { "\(source)_\(vodId)" }
  let source: String
  let sourceName: String
  let vodId: String
  let title: String
  let poster: String
  let remark: String
  let episode: String
  let line: String
  let position: Double
  let duration: Double
  let updated: Int64
}

// MARK: - Downloads & Web Extract Models

struct TvDownloadTask: Identifiable, Hashable {
  let id: String
  let url: String
  let name: String
  let status: String
  let progress: Double
  let speed: Double
  let totalSegments: Int
  let downloadedSegments: Int
  let urlType: String
  let outputFile: String
  let error: String

  var isActive: Bool {
    status == "Pending" || status == "Downloading" || status == "Converting" || status == "Uploading"
  }

  var isCompleted: Bool {
    status == "Completed"
  }

  var isFailed: Bool {
    status == "Failed" || status == "Duplicate"
  }

  var statusLabel: String {
    switch status {
    case "Pending": return "等待中"
    case "Downloading": return "下载中"
    case "Converting": return "转码封装中"
    case "Uploading": return "上传 115 中"
    case "Completed": return "已完成"
    case "Failed": return "失败"
    case "Duplicate": return "重复任务"
    default: return status
    }
  }

  var formattedSpeed: String {
    if speed <= 0 { return "0 B/s" }
    if speed < 1024 { return String(format: "%.0f B/s", speed) }
    if speed < 1024 * 1024 { return String(format: "%.1f KB/s", speed / 1024) }
    return String(format: "%.2f MB/s", speed / (1024 * 1024))
  }
}

struct TvExtractedCandidate: Identifiable, Hashable {
  var id: String { url }
  let url: String
  let title: String
  let type: String
  let headers: [String: String]
}

// MARK: - Server Media Library & Multi-Storage File Manager Models

enum TvStorageSourceKind: String, Codable, CaseIterable, Hashable, Identifiable {
  case server = "server"
  case alist = "alist"
  case webdav = "webdav"
  case cloud115 = "cloud115"
  case localCache = "localCache"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .server: return "流光服务端"
    case .alist: return "AList / OpenList"
    case .webdav: return "WebDAV 远程盘"
    case .cloud115: return "115 网盘直连"
    case .localCache: return "本机离线缓存"
    }
  }

  var icon: String {
    switch self {
    case .server: return "externaldrive.fill.badge.wifi"
    case .alist: return "server.rack"
    case .webdav: return "network.badge.shield.half.filled"
    case .cloud115: return "icloud.fill"
    case .localCache: return "appletv.fill"
    }
  }
}

struct TvStorageMount: Identifiable, Codable, Hashable {
  var id: String
  var name: String
  var kind: TvStorageSourceKind
  var baseUrl: String
  var username: String
  var password: String
  var token: String
  var rootPath: String
  var enabled: Bool

  init(
    id: String = UUID().uuidString,
    name: String,
    kind: TvStorageSourceKind,
    baseUrl: String = "",
    username: String = "",
    password: String = "",
    token: String = "",
    rootPath: String = "/",
    enabled: Bool = true
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.baseUrl = baseUrl
    self.username = username
    self.password = password
    self.token = token
    self.rootPath = rootPath.isEmpty ? "/" : rootPath
    self.enabled = enabled
  }

  var isBuiltIn: Bool {
    kind == .server || kind == .cloud115 || kind == .localCache
  }

  var badgeTitle: String {
    switch kind {
    case .server: return "服务端"
    case .alist: return "AList"
    case .webdav: return "WebDAV"
    case .cloud115: return "115网盘"
    case .localCache: return "本机缓存"
    }
  }
}

enum TvFileTransferDirection: String, Codable, Hashable {
  case upload = "upload"
  case download = "download"

  var label: String {
    self == .upload ? "上传" : "下载"
  }

  var icon: String {
    self == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
  }
}

enum TvFileTransferStatus: String, Codable, Hashable {
  case running = "running"
  case completed = "completed"
  case failed = "failed"
  case cancelled = "cancelled"

  var label: String {
    switch self {
    case .running: return "进行中"
    case .completed: return "已完成"
    case .failed: return "失败"
    case .cancelled: return "已取消"
    }
  }
}

struct TvFileTransferTask: Identifiable, Hashable {
  let id: String
  var name: String
  var direction: TvFileTransferDirection
  var sourceLabel: String
  var targetLabel: String
  var totalBytes: Int64
  var transferredBytes: Int64
  var speedBytesPerSec: Double
  var status: TvFileTransferStatus
  var detailMessage: String
  var localSavedPath: String?
  var createdAt: Date

  var progress: Double {
    guard totalBytes > 0 else {
      return status == .completed ? 1.0 : 0.0
    }
    return min(1.0, max(0.0, Double(transferredBytes) / Double(totalBytes)))
  }

  var percentText: String {
    String(format: "%.1f%%", progress * 100.0)
  }

  var formattedSpeed: String {
    guard speedBytesPerSec > 0 else { return "0 KB/s" }
    if speedBytesPerSec < 1024 * 1024 {
      return String(format: "%.1f KB/s", speedBytesPerSec / 1024.0)
    }
    return String(format: "%.2f MB/s", speedBytesPerSec / (1024.0 * 1024.0))
  }

  var formattedBytesProgress: String {
    let cur = Self.formatByteCount(transferredBytes)
    if totalBytes > 0 {
      return "\(cur) / \(Self.formatByteCount(totalBytes))"
    }
    return cur
  }

  static func formatByteCount(_ bytes: Int64) -> String {
    if bytes < 1024 { return "\(max(0, bytes)) B" }
    if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
    if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0)) }
    return String(format: "%.2f GB", Double(bytes) / (1024.0 * 1024.0 * 1024.0))
  }
}

enum TvFileSortOption: String, CaseIterable, Hashable {
  case dateDesc = "dateDesc"
  case nameAsc = "nameAsc"
  case sizeDesc = "sizeDesc"
  case typeAsc = "typeAsc"

  var title: String {
    switch self {
    case .dateDesc: return "按修改时间"
    case .nameAsc: return "按名称 A-Z"
    case .sizeDesc: return "按文件大小"
    case .typeAsc: return "按文件类型"
    }
  }

  var icon: String {
    switch self {
    case .dateDesc: return "clock.arrow.circlepath"
    case .nameAsc: return "textformat.abc"
    case .sizeDesc: return "arrow.up.arrow.down.circle"
    case .typeAsc: return "square.grid.2x2"
    }
  }
}

enum TvFileCategoryFilter: String, CaseIterable, Hashable {
  case all = "all"
  case video = "video"
  case audio = "audio"
  case image = "image"
  case document = "document"

  var title: String {
    switch self {
    case .all: return "全部"
    case .video: return "视频"
    case .audio: return "音频"
    case .image: return "图片"
    case .document: return "字幕/文档"
    }
  }
}

enum TvFileClipboardOperation: String, Hashable {
  case copy = "copy"
  case move = "move"
}

struct TvFileClipboardItem: Hashable {
  let mountId: String
  let sourceDirectory: String
  let entries: [TvFileEntry]
  let operation: TvFileClipboardOperation
}

struct TvSavedMusicFolderItem: Codable, Identifiable, Hashable {
  var id: String { "\(mountId)::\(path)" }
  var mountId: String
  var mountName: String
  var sourceKind: TvStorageSourceKind
  var path: String
  var title: String
  var isArchive: Bool
  var size: Int64
  var pickcode115: String
}

struct TvFileEntry: Identifiable, Hashable {
  var id: String { "\(mountId)::\(path)" }
  let name: String
  let path: String
  let size: Int64
  let modTime: String
  let isDir: Bool
  let isMp4: Bool
  let ext: String
  var mountId: String = "builtin_server"
  var sourceKind: TvStorageSourceKind = .server
  var rawDownloadUrl: String = ""
  var thumbUrl: String = ""
  var pickcode115: String = ""
  var fid115: String = ""
  var cid115: String = ""

  var archiveContainerPath: String = ""
  var archiveContainerName: String = ""
  var archiveInnerPath: String = ""
  var archiveOffset: Int64 = 0
  var archiveCompressedSize: Int64 = 0
  var archiveCompressionMethod: Int = 0

  var isInsideArchive: Bool {
    !archiveContainerPath.isEmpty
  }

  var isStreamableMusicArchive: Bool {
    if isDir { return false }
    let e = normalizedExt
    return [".zip", ".cbz", ".tar"].contains(e)
  }

  var normalizedExt: String {
    let lower = ext.lowercased()
    if !lower.isEmpty {
      return lower.hasPrefix(".") ? lower : ".\(lower)"
    }
    let ns = (name as NSString).pathExtension.lowercased()
    return ns.isEmpty ? "" : ".\(ns)"
  }

  var isVideo: Bool {
    if isDir { return false }
    let e = normalizedExt
    return isMp4 || [".mp4", ".mkv", ".ts", ".m3u8", ".mov", ".flv", ".webm", ".avi", ".rmvb", ".wmv", ".m4v", ".iso"].contains(e)
  }

  var isAudio: Bool {
    if isDir { return false }
    let e = normalizedExt
    return [".mp3", ".m4a", ".flac", ".wav", ".aac", ".ogg", ".ape", ".alac", ".opus", ".wma", ".dsf", ".dff", ".aiff", ".aif", ".amr", ".mid"].contains(e)
  }

  var isPlayableVideo: Bool {
    isVideo || isAudio
  }

  var isImage: Bool {
    if isDir { return false }
    let e = normalizedExt
    return [".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".heic", ".tiff"].contains(e)
  }

  var isTextPreviewable: Bool {
    if isDir { return false }
    let e = normalizedExt
    return [".txt", ".srt", ".ass", ".ssa", ".vtt", ".lrc", ".json", ".yaml", ".yml", ".m3u", ".m3u8", ".xml", ".nfo", ".log", ".md", ".conf", ".ini", ".sh", ".py", ".js", ".csv"].contains(e)
  }

  var isArchive: Bool {
    if isDir { return false }
    let e = normalizedExt
    return [".zip", ".cbz", ".rar", ".7z", ".tar", ".gz", ".bz2", ".xz"].contains(e)
  }

  var iconName: String {
    if isDir { return "folder.fill" }
    if isVideo { return "film.fill" }
    if isAudio { return "waveform.circle.fill" }
    if isImage { return "photo.fill" }
    if isTextPreviewable { return "doc.text.fill" }
    if isArchive { return "doc.zipper" }
    return "doc.fill"
  }

  var typeTagText: String {
    if isDir { return "文件夹" }
    let clean = normalizedExt.replacingOccurrences(of: ".", with: "").uppercased()
    if !clean.isEmpty {
      return isInsideArchive ? "\(clean) · 压缩包" : clean
    }
    if isVideo { return "VIDEO" }
    if isAudio { return "AUDIO" }
    if isImage { return "IMAGE" }
    return "FILE"
  }

  var formattedSize: String {
    if isDir { return "文件夹" }
    if size <= 0 { return "--" }
    if size < 1024 { return "\(size) B" }
    if size < 1024 * 1024 { return String(format: "%.1f KB", Double(size) / 1024.0) }
    if size < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(size) / (1024.0 * 1024.0)) }
    return String(format: "%.2f GB", Double(size) / (1024.0 * 1024.0 * 1024.0))
  }
}

struct TvFileListing: Hashable {
  let path: String
  let parent: String
  let root: String
  var entries: [TvFileEntry]
  var totalCount: Int = 0
  var currentPage: Int = 1

  var hasMoreRemotePages: Bool {
    totalCount > entries.count
  }
}

struct TvCloudLrcLine: Identifiable, Hashable {
  let id = UUID()
  let timeSeconds: Double
  let text: String
}

// MARK: - Telegram Models

struct TvTelegramAccount: Identifiable, Hashable {
  let id: String
  let name: String
  let username: String
  let userId: String
  let avatar: String

  var displayLabel: String {
    if !username.isEmpty { return "\(name) (@\(username))" }
    if !userId.isEmpty && userId != "0" { return "\(name) (\(userId))" }
    return name
  }
}

struct TvTelegramAuthStatus: Hashable {
  var configured: Bool = false
  var authorized: Bool = false
  var codeSent: Bool = false
  var passwordRequired: Bool = false
}

struct TvTelegramFolder: Identifiable, Hashable {
  var id: String { key }
  let key: String
  let title: String
  let emoji: String

  var displayTitle: String {
    emoji.isEmpty ? title : "\(emoji) \(title)"
  }
}

struct TvTelegramChat: Identifiable, Hashable {
  var id: String { peer }
  let peer: String
  let title: String
  let kind: String
  let preview: String
  let avatar: String
  let avatarPhotoId: String
  let avatarDcId: Int
  let date: Int
  let unread: Int
  let readOnly: Bool
  let broadcast: Bool
  let isSelf: Bool
  let isContact: Bool
  let muted: Bool
  let topMessageId: Int
  let readOutboxMaxId: Int

  private static let hhmmFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm"
    return fmt
  }()

  private static let mmddFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.dateFormat = "MM/dd"
    return fmt
  }()

  var hasSharpAvatar: Bool {
    !avatarPhotoId.isEmpty
      && avatarPhotoId != "0"
      && avatarPhotoId != "<null>"
      && avatarDcId > 0
      && avatarDcId <= 10
  }

  /// True whenever the peer either has explicit `photo_id`+`dc_id` OR has a non-empty inline avatar preview on a valid `user:`/`chat:`/`channel:` peer.
  var canRequestHdAvatar: Bool {
    if hasSharpAvatar { return true }
    let cleanAvatar = avatar.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanAvatar.isEmpty && cleanAvatar != "<null>" else { return false }
    return peer.hasPrefix("user:") || peer.hasPrefix("chat:") || peer.hasPrefix("channel:")
  }

  var conversationActionType: String {
    if peer.hasPrefix("channel:") || peer.hasPrefix("chat:") {
      return "leave"
    }
    if peer.hasPrefix("user:") && !isSelf {
      return "delete_contact"
    }
    return ""
  }

  var conversationActionLabel: String {
    if peer.hasPrefix("channel:") {
      return (broadcast || kind.contains("频道")) ? "退出频道" : "退出超级群"
    }
    if peer.hasPrefix("chat:") {
      return "退出群组"
    }
    if peer.hasPrefix("user:") && !isSelf {
      return "删除好友"
    }
    return ""
  }

  var formattedDialogTime: String {
    guard date > 0 else { return "" }
    let dt = Date(timeIntervalSince1970: TimeInterval(date))
    let cal = Calendar.current
    if cal.isDateInToday(dt) {
      return Self.hhmmFormatter.string(from: dt)
    }
    if cal.isDateInYesterday(dt) {
      return "昨天"
    }
    let daysAgo = cal.dateComponents([.day], from: dt, to: Date()).day ?? 99
    if daysAgo >= 0 && daysAgo < 7 {
      let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
      let wd = cal.component(.weekday, from: dt)
      if wd >= 1 && wd <= 7 {
        return weekdays[wd - 1]
      }
    }
    return Self.mmddFormatter.string(from: dt)
  }
}

struct TvTelegramAttachment: Hashable {
  let kind: String
  let name: String
  let fileName: String
  let title: String
  let performer: String
  let voice: Bool
  let size: Int64
  let mimeType: String
  let duration: Int
  let width: Int
  let height: Int
  let url: String
  let thumbnail: String
  let hasThumbnail: Bool

  var displayName: String {
    if !fileName.isEmpty { return fileName }
    if !name.isEmpty { return name }
    if !title.isEmpty { return title }
    return "媒体文件"
  }

  var isVideo: Bool {
    let k = kind.lowercased()
    if k == "video" { return true }
    if mimeType.lowercased().hasPrefix("video/") { return true }
    let lower = displayName.lowercased()
    return lower.hasSuffix(".mp4")
      || lower.hasSuffix(".mkv")
      || lower.hasSuffix(".mov")
      || lower.hasSuffix(".webm")
      || lower.hasSuffix(".m4v")
      || lower.hasSuffix(".ts")
  }

  var isPhoto: Bool {
    let k = kind.lowercased()
    if k == "photo" || k == "image" { return true }
    if mimeType.lowercased().hasPrefix("image/") { return true }
    let lower = displayName.lowercased()
    return lower.hasSuffix(".jpg")
      || lower.hasSuffix(".jpeg")
      || lower.hasSuffix(".png")
      || lower.hasSuffix(".webp")
      || lower.hasSuffix(".gif")
  }

  var isAudio: Bool {
    let k = kind.lowercased()
    if k == "audio" || k == "voice" { return true }
    if mimeType.lowercased().hasPrefix("audio/") { return true }
    let lower = displayName.lowercased()
    return lower.hasSuffix(".mp3")
      || lower.hasSuffix(".m4a")
      || lower.hasSuffix(".aac")
      || lower.hasSuffix(".ogg")
      || lower.hasSuffix(".opus")
      || lower.hasSuffix(".wav")
      || lower.hasSuffix(".flac")
  }

  var isVoiceMessage: Bool {
    if !isAudio { return false }
    if voice || kind.lowercased() == "voice" { return true }
    if !title.trimmingCharacters(in: .whitespaces).isEmpty
        || !performer.trimmingCharacters(in: .whitespaces).isEmpty {
      return false
    }
    let m = mimeType.lowercased()
    let lower = displayName.lowercased()
    if m.contains("ogg") || m.contains("opus") || lower.hasSuffix(".ogg") || lower.hasSuffix(".opus") {
      if fileName.isEmpty || lower.hasPrefix("audio_") || lower.hasPrefix("voice") {
        return true
      }
    }
    return false
  }

  var isMusic: Bool {
    isAudio && !isVoiceMessage
  }

  var musicTitle: String {
    let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !clean.isEmpty { return clean }
    let raw = !fileName.isEmpty ? fileName : name
    if raw.isEmpty { return isVoiceMessage ? "语音消息" : "未知曲目" }
    let withoutExt = (raw as NSString).deletingPathExtension
    if let range = withoutExt.range(of: " - ") {
      let sub = String(withoutExt[range.upperBound...]).trimmingCharacters(in: .whitespaces)
      if !sub.isEmpty { return sub }
    }
    return withoutExt.isEmpty ? raw : withoutExt
  }

  var musicPerformer: String {
    let clean = performer.trimmingCharacters(in: .whitespacesAndNewlines)
    if !clean.isEmpty { return clean }
    let raw = !fileName.isEmpty ? fileName : name
    if !raw.isEmpty {
      let withoutExt = (raw as NSString).deletingPathExtension
      if let range = withoutExt.range(of: " - ") {
        let artist = String(withoutExt[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        if !artist.isEmpty { return artist }
      }
    }
    return isVoiceMessage ? "语音消息" : "未知艺术家"
  }

  var isVisualMedia: Bool {
    isVideo || isPhoto
  }

  var canPreviewText: Bool {
    let lower = displayName.lowercased()
    let m = mimeType.lowercased()
    if m.hasPrefix("text/") || m == "application/json" || m == "application/xml" {
      return true
    }
    for ext in [".txt", ".log", ".md", ".json", ".xml", ".csv", ".yaml", ".yml", ".srt", ".ass", ".vtt", ".m3u", ".m3u8", ".html", ".py", ".js", ".ts", ".sh"] {
      if lower.hasSuffix(ext) { return true }
    }
    return false
  }

  var formattedSize: String {
    if size <= 0 { return "" }
    if size < 1024 { return "\(size) B" }
    if size < 1024 * 1024 { return String(format: "%.1f KB", Double(size) / 1024.0) }
    if size < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(size) / (1024.0 * 1024.0)) }
    return String(format: "%.2f GB", Double(size) / (1024.0 * 1024.0 * 1024.0))
  }
}

struct TvTelegramMessageButton: Identifiable, Hashable {
  var id: String { "\(row)_\(column)_\(text)_\(token)" }
  let row: Int
  let column: Int
  let text: String
  let kind: String
  let url: String
  let token: String
}

struct TvTelegramMessage: Identifiable, Hashable {
  private static let fullDateFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.dateFormat = "MM-dd HH:mm"
    return fmt
  }()

  private static let bubbleTimeFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm"
    return fmt
  }()

  private static let monthDayPillFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.dateFormat = "M月d日"
    return fmt
  }()

  private static let yearMonthDayPillFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy年M月d日"
    return fmt
  }()

  let id: Int
  let date: Int
  let sender: String
  let senderPeer: String
  let senderAvatar: String
  let text: String
  let outgoing: Bool
  let groupedId: String
  let replyToId: Int
  let links: [String]
  let buttons: [[TvTelegramMessageButton]]
  let attachment: TvTelegramAttachment?

  init(
    id: Int,
    date: Int,
    sender: String,
    senderPeer: String = "",
    senderAvatar: String,
    text: String,
    outgoing: Bool,
    groupedId: String,
    replyToId: Int,
    links: [String],
    buttons: [[TvTelegramMessageButton]],
    attachment: TvTelegramAttachment?
  ) {
    self.id = id
    self.date = date
    self.sender = sender
    self.senderPeer = senderPeer
    self.senderAvatar = senderAvatar
    self.text = text
    self.outgoing = outgoing
    self.groupedId = groupedId
    self.replyToId = replyToId
    self.links = links
    self.buttons = buttons
    self.attachment = attachment
  }

  var isVideo: Bool { attachment?.isVideo ?? false }
  var isPhoto: Bool { attachment?.isPhoto ?? false }
  var isAudio: Bool { attachment?.isAudio ?? false }
  var isMusic: Bool { attachment?.isMusic ?? false }
  var isVisualMedia: Bool { attachment?.isVisualMedia ?? false }
  var hasButtons: Bool { buttons.contains { !$0.isEmpty } }

  var formattedDate: String {
    guard date > 0 else { return "" }
    let dt = Date(timeIntervalSince1970: TimeInterval(date))
    return Self.fullDateFormatter.string(from: dt)
  }

  var formattedBubbleTime: String {
    guard date > 0 else { return "" }
    let dt = Date(timeIntervalSince1970: TimeInterval(date))
    return Self.bubbleTimeFormatter.string(from: dt)
  }

  var formattedDatePill: String {
    guard date > 0 else { return "" }
    let dt = Date(timeIntervalSince1970: TimeInterval(date))
    let cal = Calendar.current
    if cal.isDateInToday(dt) { return "今天" }
    if cal.isDateInYesterday(dt) { return "昨天" }
    if cal.component(.year, from: dt) == cal.component(.year, from: Date()) {
      return Self.monthDayPillFormatter.string(from: dt)
    } else {
      return Self.yearMonthDayPillFormatter.string(from: dt)
    }
  }
}

struct TvTelegramMessageGroup: Identifiable, Hashable {
  var id: Int { first.id }
  let messages: [TvTelegramMessage]
  let datePillHeader: String?

  var first: TvTelegramMessage { messages[0] }
  var isAlbum: Bool { messages.count > 1 && (first.attachment?.isVisualMedia ?? false) }
  var isDocGroup: Bool { messages.count > 1 && !(first.attachment?.isVisualMedia ?? false) }
}

struct TvTelegramFilePreview: Identifiable, Hashable {
  let id = UUID()
  let title: String
  let content: String
  let mimeType: String
  let size: Int64
}

// MARK: - Playback Request Models

struct TvPlaybackRequest: Identifiable, Hashable {
  let id = UUID()
  let title: String
  let subtitle: String
  let streamUrl: String
  let backupProxyUrl: String
  let headers: [String: String]
  let resumeSeconds: Double
  let isLive: Bool
  let vodSource: TvVodSource?
  let vodDetail: TvVodDetail?
  let playGroupIndex: Int
  let episodeIndex: Int
  let liveChannel: TvLiveChannel?
  let liveUrlIndex: Int
  var isFlvHardwareStream: Bool = false
  var flvPrimaryUrl: String = ""
  var flvGatewayUrl: String = ""
}

struct TvTelegramGallerySession: Identifiable, Hashable {
  let id = UUID()
  let accountId: String
  let chat: TvTelegramChat
  let mediaMessages: [TvTelegramMessage]
  let initialIndex: Int
}

// MARK: - Proxy & Routing Models (1:1 Match with ProxyRoutingService & ProxyServerScreen in Flutter/macOS/Android)

enum TvRouteMode: String, CaseIterable, Identifiable, Codable {
  case direct = "direct"
  case serverRelay = "serverRelay"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .direct: return "客户端直连"
    case .serverRelay: return "服务器代理中转"
    }
  }
}

/// Global proxy node selection strategy (`autoFastest` vs `manual`)
enum TvProxySelectionMode: String, CaseIterable, Identifiable, Codable {
  case autoFastest = "autoFastest"
  case manual = "manual"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .autoFastest: return "⚡ 自动切换最快"
    case .manual: return "🎯 手动指定代理"
    }
  }

  var badgeTitle: String {
    switch self {
    case .autoFastest: return "智能防抖(自动最快)"
    case .manual: return "手动锁定"
    }
  }
}

/// 6 Request Scenarios matching `RequestScenario` in `lib/services/proxy_routing_service.dart`
enum TvRequestScenario: String, CaseIterable, Identifiable, Codable, Hashable {
  case vodApi = "vodApi"
  case vodStream = "vodStream"
  case liveStream = "liveStream"
  case telegram = "telegram"
  case backendApi = "backendApi"
  case externalWeb = "externalWeb"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .vodApi: return "影视点播目录与搜索"
    case .vodStream: return "点播视频流播放"
    case .liveStream: return "电视直播源与频道流"
    case .telegram: return "Telegram 消息与媒体"
    case .backendApi: return "主服务端控制接口"
    case .externalWeb: return "订阅更新与网页嗅探"
    }
  }

  var subtitle: String {
    switch self {
    case .vodApi: return "CMS 资源站分类列表、搜索、详情接口请求"
    case .vodStream: return "M3U8 / MP4 点播视频流分片请求与播放"
    case .liveStream: return "IPTV 直播源列表拉取与直播流播放"
    case .telegram: return "Telegram 频道消息、缩略图与视频流请求"
    case .backendApi: return "连接流光主服务端 /api/* 接口"
    case .externalWeb: return "机场订阅更新、网页视频嗅探等外部请求"
    }
  }

  var iconName: String {
    switch self {
    case .vodApi: return "magnifyingglass.circle.fill"
    case .vodStream: return "play.tv.fill"
    case .liveStream: return "dot.radiowaves.left.and.right"
    case .telegram: return "paperplane.fill"
    case .backendApi: return "server.rack"
    case .externalWeb: return "globe"
    }
  }
}

/// 5 Scenario Route Modes matching `ScenarioRouteMode` in `lib/services/proxy_routing_service.dart`
enum TvScenarioRouteMode: String, CaseIterable, Identifiable, Codable, Hashable {
  case followGlobal = "followGlobal"
  case direct = "direct"
  case proxyNode = "proxyNode"
  case serverRelay = "serverRelay"
  case smartAuto = "smartAuto"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .followGlobal: return "跟随全局开关"
    case .direct: return "强制直连"
    case .proxyNode: return "走代理节点"
    case .serverRelay: return "服务端中转"
    case .smartAuto: return "智能分流"
    }
  }

  var shortBadge: String {
    switch self {
    case .followGlobal: return "跟随全局"
    case .direct: return "直连"
    case .proxyNode: return "代理节点"
    case .serverRelay: return "服务端中转"
    case .smartAuto: return "智能分流"
    }
  }

  var description: String {
    switch self {
    case .followGlobal: return "当顶部全局代理开启时走当前选中代理节点，关闭时直连"
    case .direct: return "始终使用本地网络直连，不经过任何代理"
    case .proxyNode: return "始终通过指定（或全局最快）代理节点转发"
    case .serverRelay: return "通过流光服务端 /api/vod/proxy 反向代理中转"
    case .smartAuto: return "国内域名直连，海外/受限域名自动走最低延迟代理节点"
    }
  }
}

/// Per-scenario routing rule config matching `ScenarioRuleConfig`
struct TvScenarioRuleConfig: Codable, Hashable {
  let scenario: TvRequestScenario
  var mode: TvScenarioRouteMode
  var specificNodeId: String?

  init(scenario: TvRequestScenario, mode: TvScenarioRouteMode = .followGlobal, specificNodeId: String? = nil) {
    self.scenario = scenario
    self.mode = mode
    self.specificNodeId = specificNodeId
  }
}

/// Multi-subscription model matching `ProxySubscription` in `lib/services/proxy_routing_service.dart`
struct TvProxySubscription: Identifiable, Codable, Hashable {
  let id: String
  var name: String
  var url: String
  var enabled: Bool
  var autoUpdateHours: Int
  var lastUpdatedAtMs: Int64?
  var nodeCount: Int
  var uploadBytes: Int64?
  var downloadBytes: Int64?
  var totalBytes: Int64?
  var expireTimestampSec: Int64?
  var lastError: String?

  init(
    id: String = "sub_\(Int64(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(4))",
    name: String,
    url: String,
    enabled: Bool = true,
    autoUpdateHours: Int = 24,
    lastUpdatedAtMs: Int64? = nil,
    nodeCount: Int = 0,
    uploadBytes: Int64? = nil,
    downloadBytes: Int64? = nil,
    totalBytes: Int64? = nil,
    expireTimestampSec: Int64? = nil,
    lastError: String? = nil
  ) {
    self.id = id
    self.name = name
    self.url = url
    self.enabled = enabled
    self.autoUpdateHours = autoUpdateHours
    self.lastUpdatedAtMs = lastUpdatedAtMs
    self.nodeCount = nodeCount
    self.uploadBytes = uploadBytes
    self.downloadBytes = downloadBytes
    self.totalBytes = totalBytes
    self.expireTimestampSec = expireTimestampSec
    self.lastError = lastError
  }

  var usedTrafficRatio: Double? {
    guard let total = totalBytes, total > 0 else { return nil }
    let used = (uploadBytes ?? 0) + (downloadBytes ?? 0)
    return min(max(0.0, Double(used) / Double(total)), 1.0)
  }

  var formattedTrafficSummary: String? {
    guard let total = totalBytes, total > 0 else { return nil }
    let used = (uploadBytes ?? 0) + (downloadBytes ?? 0)
    var text = "已用 \(Self.formatBytes(used)) / \(Self.formatBytes(total))"
    if let exp = expireTimestampSec, exp > 0 {
      let dt = Date(timeIntervalSince1970: TimeInterval(exp))
      let fmt = DateFormatter()
      fmt.dateFormat = "yyyy-MM-dd"
      text += " · 到期 \(fmt.string(from: dt))"
    }
    return text
  }

  var formattedUpdatedTime: String {
    guard let ms = lastUpdatedAtMs, ms > 0 else { return "从未更新" }
    let dt = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
    let fmt = DateFormatter()
    fmt.dateFormat = "MM-dd HH:mm"
    return "\(fmt.string(from: dt)) 更新"
  }

  var maskedUrlSummary: String {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "未设置地址" }
    guard let u = URL(string: trimmed), let host = u.host else {
      return trimmed.count > 44 ? "\(trimmed.prefix(40))..." : trimmed
    }
    let path = u.path.isEmpty ? "/" : u.path
    return "\(u.scheme ?? "https")://\(host)\(path)"
  }

  static func formatBytes(_ bytes: Int64) -> String {
    if bytes <= 0 { return "0 B" }
    let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
    if gb >= 1024.0 {
      return String(format: "%.2f TB", gb / 1024.0)
    }
    if gb >= 1.0 {
      return String(format: "%.1f GB", gb)
    }
    let mb = Double(bytes) / (1024.0 * 1024.0)
    return String(format: "%.0f MB", mb)
  }
}

struct TvProxyServiceConfig: Identifiable, Hashable {
  let id: String
  let name: String
  let proto: String
  let listenHost: String
  let port: Int
  let enabled: Bool
  let username: String
  let password: String
  let cipher: String
}

struct TvProxyRuntimeStatus: Identifiable, Hashable {
  let id: String
  let running: Bool
  let address: String
  let error: String
  let activeConnections: Int
  let totalConnections: Int
}

struct TvSubscriptionNode: Identifiable, Codable, Hashable {
  let id: String
  var name: String
  var type: String
  var host: String
  var port: Int
  var subscriptionId: String
  var subscriptionName: String
  var favorite: Bool
  var rawUri: String
  var latencyMs: Int? = nil

  init(
    id: String? = nil,
    name: String,
    type: String,
    host: String,
    port: Int,
    subscriptionId: String = "manual",
    subscriptionName: String = "手动导入",
    favorite: Bool = false,
    rawUri: String = "",
    latencyMs: Int? = nil
  ) {
    self.id = id ?? "\(subscriptionId)_\(type)_\(host)_\(port)_\(name)"
    self.name = name
    self.type = type
    self.host = host
    self.port = port
    self.subscriptionId = subscriptionId
    self.subscriptionName = subscriptionName
    self.favorite = favorite
    self.rawUri = rawUri
    self.latencyMs = latencyMs
  }

  var regionFlag: String {
    let lower = "\(name) \(host)".lowercased()
    if lower.contains("香港") || lower.contains("hk") || lower.contains("hongkong") || lower.contains("hong kong") {
      return "🇭🇰"
    }
    if lower.contains("台湾") || lower.contains("tw") || lower.contains("taiwan") || lower.contains("台北") {
      return "🇹🇼"
    }
    if lower.contains("日本") || lower.contains("jp") || lower.contains("japan") || lower.contains("东京") || lower.contains("大阪") {
      return "🇯🇵"
    }
    if lower.contains("新加坡") || lower.contains("sg") || lower.contains("singapore") || lower.contains("狮城") {
      return "🇸🇬"
    }
    if lower.contains("美国") || lower.contains("us") || lower.contains("united states") || lower.contains("洛杉矶") || lower.contains("圣何塞") || lower.contains("西雅图") {
      return "🇺🇸"
    }
    if lower.contains("韩国") || lower.contains("kr") || lower.contains("korea") || lower.contains("首尔") {
      return "🇰🇷"
    }
    if lower.contains("英国") || lower.contains("uk") || lower.contains("london") {
      return "🇬🇧"
    }
    if lower.contains("德国") || lower.contains("de") || lower.contains("frankfurt") {
      return "🇩🇪"
    }
    return "🌐"
  }

  var regionCategory: String {
    switch regionFlag {
    case "🇭🇰": return "香港"
    case "🇹🇼": return "台湾"
    case "🇯🇵": return "日本"
    case "🇸🇬": return "新加坡"
    case "🇺🇸": return "美国"
    case "🇰🇷": return "韩国"
    default: return "其他"
    }
  }

  var displayTitle: String {
    let flag = regionFlag
    if name.contains(flag) { return name }
    return "\(flag) \(name)"
  }

  var formattedLatency: String {
    guard let ms = latencyMs else { return "待测速" }
    if ms >= 9999 || ms < 0 { return "超时" }
    return "\(ms) ms"
  }

  var isSupportedByClientTunnel: Bool {
    let p = type.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    let rawLower = rawUri.lowercased()
    if subscriptionId != "manual" && subscriptionId != "server" {
      if host == "127.0.0.1" || host == "0.0.0.0" || host == "localhost" || port <= 1 {
        return false
      }
    }
    if p == "trojan" || p == "socks5" || p == "socks" || p == "http" || p == "https" {
      return true
    }
    if p == "vless" {
      if rawLower.contains("security=reality") || rawLower.contains("pbk=") {
        return false
      }
      return true
    }
    if p == "ss" || p == "shadowsocks" {
      return true
    }
    return false
  }

  var isAvailable: Bool {
    guard isSupportedByClientTunnel, let ms = latencyMs else { return false }
    return ms > 0 && ms < 9000
  }
}

// MARK: - App Theme Palettes (1:1 Match with Original App VideoPlatformTheme.presets)

struct TvThemePalette: Identifiable, Hashable {
  let id: String
  let name: String
  let subtitle: String
  let bgPrimary: Color
  let bgElevated: Color
  let bgCard: Color
  let accent: Color
  let accentHover: Color
  let badgeHot: Color

  static let presets: [TvThemePalette] = [
    TvThemePalette(
      id: "ocean_dark",
      name: "爆米花暗黑",
      subtitle: "网易爆米花同款影院黑金配色",
      bgPrimary: Color(red: 0.043, green: 0.047, blue: 0.063), // #0B0C10
      bgElevated: Color(red: 0.071, green: 0.078, blue: 0.110), // #12141C
      bgCard: Color(red: 0.098, green: 0.110, blue: 0.149), // #191C26
      accent: Color(red: 1.000, green: 0.624, blue: 0.039), // #FF9F0A
      accentHover: Color(red: 1.000, green: 0.702, blue: 0.251), // #FFB340
      badgeHot: Color(red: 1.000, green: 0.361, blue: 0.220) // #FF5C38
    ),
    TvThemePalette(
      id: "amber_gold",
      name: "深空蓝",
      subtitle: "经典暗黑蓝青配色",
      bgPrimary: Color(red: 0.059, green: 0.063, blue: 0.078), // #0F1014
      bgElevated: Color(red: 0.090, green: 0.094, blue: 0.118), // #17181E
      bgCard: Color(red: 0.114, green: 0.122, blue: 0.153), // #1D1F27
      accent: Color(red: 0.000, green: 0.682, blue: 0.925), // #00AEEC
      accentHover: Color(red: 0.149, green: 0.745, blue: 1.000), // #26BEFF
      badgeHot: Color(red: 1.000, green: 0.361, blue: 0.220)
    ),
    TvThemePalette(
      id: "cinema_red",
      name: "剧院红",
      subtitle: "沉浸式纯黑影院风格",
      bgPrimary: Color(red: 0.043, green: 0.043, blue: 0.051), // #0B0B0D
      bgElevated: Color(red: 0.078, green: 0.078, blue: 0.094), // #141418
      bgCard: Color(red: 0.106, green: 0.106, blue: 0.129), // #1B1B21
      accent: Color(red: 0.898, green: 0.133, blue: 0.180), // #E5222E
      accentHover: Color(red: 1.000, green: 0.231, blue: 0.278), // #FF3B47
      badgeHot: Color(red: 1.000, green: 0.478, blue: 0.161)
    ),
    TvThemePalette(
      id: "jade_night",
      name: "翡翠绿",
      subtitle: "低疲劳夜间护眼暗色",
      bgPrimary: Color(red: 0.047, green: 0.067, blue: 0.059), // #0C110F
      bgElevated: Color(red: 0.075, green: 0.102, blue: 0.090), // #131A17
      bgCard: Color(red: 0.102, green: 0.137, blue: 0.122), // #1A231F
      accent: Color(red: 0.078, green: 0.722, blue: 0.400), // #14B866
      accentHover: Color(red: 0.173, green: 0.820, blue: 0.494), // #2CD17E
      badgeHot: Color(red: 1.000, green: 0.392, blue: 0.220)
    ),
    TvThemePalette(
      id: "daylight_clean",
      name: "晴空白",
      subtitle: "清爽日间冰川蓝银风格",
      bgPrimary: Color(red: 0.110, green: 0.145, blue: 0.200), // #1C2533
      bgElevated: Color(red: 0.155, green: 0.200, blue: 0.270), // #273345
      bgCard: Color(red: 0.200, green: 0.255, blue: 0.340), // #334157
      accent: Color(red: 0.000, green: 0.650, blue: 0.920), // #00A6EB
      accentHover: Color(red: 0.220, green: 0.780, blue: 1.000), // #38C7FF
      badgeHot: Color(red: 1.000, green: 0.322, blue: 0.169)
    )
  ]

  static var current: TvThemePalette = presets[0]

  static func palette(for id: String) -> TvThemePalette {
    presets.first(where: { $0.id == id }) ?? presets[0]
  }
}

