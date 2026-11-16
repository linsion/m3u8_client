import Foundation

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
    if isTvBox && !tvboxSourceName.isEmpty {
      return "\(name) (\(tvboxSourceName))"
    }
    return name
  }

  var librarySourceKey: String {
    isTvBox ? "tvbox_\(tvboxSiteIndex)" : "custom_\(customIndex)"
  }

  var queryItems: [URLQueryItem] {
    if isTvBox {
      return [
        URLQueryItem(name: "api", value: api),
        URLQueryItem(name: "tvbox_type", value: String(tvboxType)),
        URLQueryItem(name: "tvbox_site", value: String(tvboxSiteIndex)),
        URLQueryItem(name: "tvbox_source", value: String(tvboxSourceIndex)),
      ]
    }
    return [URLQueryItem(name: "src", value: String(customIndex))]
  }
}

struct TvVodCategory: Identifiable, Hashable {
  var id: String { typeId }
  let typeId: String
  let typeName: String
}

struct TvVodItem: Identifiable, Hashable {
  var id: String { "\(source?.id ?? "default")_\(vodId)_\(vodName)" }
  let vodId: String
  let vodName: String
  let vodPic: String
  let vodRemarks: String
  let vodYear: String
  let typeName: String
  let source: TvVodSource?

  var isSearchJumpItem: Bool {
    vodId.hasPrefix("msearch:")
  }
}

struct TvEpisode: Identifiable, Hashable {
  var id: String { "\(groupName)_\(index)_\(rawUrl)" }
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

  static func parsePlayGroups(playFrom: String, playUrl: String) -> [TvPlayGroup] {
    let fromParts = playFrom
      .components(separatedBy: "$$$")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    let urlGroups = playUrl
      .components(separatedBy: "$$$")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

    var groups: [TvPlayGroup] = []
    for (gIdx, rawGroupUrl) in urlGroups.enumerated() where !rawGroupUrl.isEmpty {
      let groupName = (gIdx < fromParts.count && !fromParts[gIdx].isEmpty)
        ? fromParts[gIdx]
        : "线路\(gIdx + 1)"
      let rawEps = rawGroupUrl
        .components(separatedBy: "#")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      var episodes: [TvEpisode] = []
      for (eIdx, entry) in rawEps.enumerated() {
        if let dollarIdx = entry.firstIndex(of: "$") {
          let title = String(entry[..<dollarIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
          let url = String(entry[entry.index(after: dollarIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
          if !url.isEmpty {
            episodes.append(
              TvEpisode(
                index: eIdx,
                title: title.isEmpty ? "第\(eIdx + 1)集" : title,
                rawUrl: url,
                groupName: groupName
              )
            )
          }
        } else {
          episodes.append(
            TvEpisode(
              index: eIdx,
              title: "第\(eIdx + 1)集",
              rawUrl: entry,
              groupName: groupName
            )
          )
        }
      }
      if !episodes.isEmpty {
        groups.append(TvPlayGroup(name: groupName, episodes: episodes))
      }
    }
    return groups
  }
}

struct TvResolvedPlayback: Hashable {
  let directUrl: String
  let serverProxyUrl: String
  let headers: [String: String]
  let parseVia: String
}

struct TvLiveSource: Identifiable, Hashable, Codable {
  var id: String { "\(sourceIndex)_\(liveIndex)_\(name)" }
  let name: String
  let url: String
  let ua: String
  let sourceIndex: Int
  let liveIndex: Int
}

struct TvLiveChannel: Identifiable, Hashable {
  var id: String { "\(group)@@\(name)" }
  let name: String
  let group: String
  let urls: [String]
  let logo: String
  let headers: [String: String]
}

struct TvLibraryItem: Identifiable, Hashable, Codable {
  var id: String { "\(source)_\(vodId)" }
  let source: String
  let sourceName: String
  let vodId: String
  let title: String
  let pic: String
  let episode: String
  let line: String
  let position: Double
  let duration: Double
  let updatedAt: Int64
}

struct TvTelegramAccount: Identifiable, Hashable {
  let id: String
  let name: String
  let phone: String
}

struct TvTelegramChat: Identifiable, Hashable {
  var id: String { peer }
  let peer: String
  let title: String
  let lastMessage: String
  let unreadCount: Int
}

struct TvTelegramMessage: Identifiable, Hashable {
  let id: Int
  let text: String
  let date: String
  let isVideo: Bool
  let isPhoto: Bool
  let fileName: String
  let fileSize: String
  let duration: Int
}

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
}
