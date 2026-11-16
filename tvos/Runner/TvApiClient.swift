import Foundation

final class InsecureSessionDelegate: NSObject, URLSessionDelegate {
  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
       let trust = challenge.protectionSpace.serverTrust {
      completionHandler(.useCredential, URLCredential(trust: trust))
    } else {
      completionHandler(.performDefaultHandling, nil)
    }
  }
}

struct TvVodListResponse {
  let categories: [TvVodCategory]
  let items: [TvVodItem]
  let pageCount: Int
}

final class TvApiClient {
  var baseUrl: String
  var authSecret: String
  private let session: URLSession

  init(baseUrl: String, authSecret: String) {
    self.baseUrl = TvApiClient.normalizeBaseUrl(baseUrl)
    self.authSecret = authSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 18
    config.timeoutIntervalForResource = 45
    self.session = URLSession(
      configuration: config,
      delegate: InsecureSessionDelegate(),
      delegateQueue: nil
    )
  }

  static func normalizeBaseUrl(_ raw: String) -> String {
    var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasSuffix("/") {
      trimmed.removeLast()
    }
    return trimmed.isEmpty ? "https://jp2.linsionwinwin.top:8081" : trimmed
  }

  var cookieHeaderValue: String {
    let secret = authSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !secret.isEmpty else { return "" }
    let token = secret.hasPrefix("auth_") ? secret : "auth_\(secret)"
    return "access_token=\(token)"
  }

  var authHeaders: [String: String] {
    var headers: [String: String] = [
      "User-Agent": "Mozilla/5.0 (AppleTV; CPU TVOS 17_0 like Mac OS X) AppleWebKit/605.1.15"
    ]
    let cookie = cookieHeaderValue
    if !cookie.isEmpty {
      headers["Cookie"] = cookie
    }
    return headers
  }

  private func makeEndpointUrl(_ path: String, queryItems: [URLQueryItem] = []) -> URL? {
    let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
    guard var components = URLComponents(string: "\(baseUrl)\(normalizedPath)") else {
      return nil
    }
    if !queryItems.isEmpty {
      components.queryItems = (components.queryItems ?? []) + queryItems
    }
    return components.url
  }

  private func requestJson(
    url: URL,
    method: String = "GET",
    body: [String: Any]? = nil,
    extraHeaders: [String: String] = [:],
    includeAuth: Bool = true
  ) async throws -> Any {
    var req = URLRequest(url: url)
    req.httpMethod = method
    if includeAuth {
      for (k, v) in authHeaders {
        req.setValue(v, forHTTPHeaderField: k)
      }
    } else {
      req.setValue(
        "Mozilla/5.0 (AppleTV; CPU TVOS 17_0 like Mac OS X) AppleWebKit/605.1.15",
        forHTTPHeaderField: "User-Agent"
      )
    }
    for (k, v) in extraHeaders {
      req.setValue(v, forHTTPHeaderField: k)
    }
    if let body = body {
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      req.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await session.data(for: req)
    if let http = response as? HTTPURLResponse, http.statusCode == 401 {
      throw NSError(
        domain: "TvApiClient",
        code: 401,
        userInfo: [NSLocalizedDescriptionKey: "登录凭证已失效或密码错误 (401)"]
      )
    }
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }

  func login(password: String) async -> Bool {
    guard let url = makeEndpointUrl("/api/login") else { return false }
    do {
      var req = URLRequest(url: url)
      req.httpMethod = "POST"
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      req.httpBody = try JSONSerialization.data(withJSONObject: ["password": password])
      let (data, response) = try await session.data(for: req)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        return false
      }
      if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let status = dict["status"] as? String {
        if status == "ok" {
          self.authSecret = password
          return true
        }
      }
      return false
    } catch {
      return false
    }
  }

  // MARK: - VOD Sources

  func fetchVodSources() async throws -> [TvVodSource] {
    var results: [TvVodSource] = []

    if let settingsUrl = makeEndpointUrl("/api/settings"),
       let json = try? await requestJson(url: settingsUrl) as? [String: Any],
       let rawCustom = json["vod_sources"] as? [[String: Any]] {
      for (idx, item) in rawCustom.enumerated() {
        let name = Self.stringValue(item["name"], fallback: "源 \(idx + 1)")
        let api = Self.stringValue(item["url"])
        results.append(
          TvVodSource(
            id: "custom_\(idx)",
            name: name,
            api: api,
            isTvBox: false,
            customIndex: idx,
            tvboxType: 1,
            tvboxSiteIndex: -1,
            tvboxSourceIndex: 0,
            tvboxSourceName: "",
            searchable: true
          )
        )
      }
    }

    if let tvboxUrl = makeEndpointUrl("/api/tvbox/sites"),
       let json = try? await requestJson(url: tvboxUrl) as? [String: Any],
       let rawSites = json["sites"] as? [[String: Any]] {
      for (idx, item) in rawSites.enumerated() {
        let type = Self.intValue(item["type"], fallback: 1)
        let api = Self.stringValue(item["api"])
        guard (type == 0 || type == 1 || type == 3 || type == 4), !api.isEmpty else { continue }
        let siteIndex = Self.intValue(item["site_index"], fallback: idx)
        let sourceIndex = Self.intValue(item["source_index"], fallback: 0)
        let name = Self.stringValue(item["name"], fallback: "TVBox 站点")
        let sourceName = Self.stringValue(item["source_name"])
        let searchable = Self.intValue(item["searchable"], fallback: 1) != 0
        results.append(
          TvVodSource(
            id: "tvbox_\(sourceIndex)_\(siteIndex)",
            name: name,
            api: api,
            isTvBox: true,
            customIndex: -1,
            tvboxType: type,
            tvboxSiteIndex: siteIndex,
            tvboxSourceIndex: sourceIndex,
            tvboxSourceName: sourceName,
            searchable: searchable
          )
        )
      }
    }

    return results
  }

  // MARK: - VOD List / Search / Detail

  private func canDirectCms(_ source: TvVodSource) -> Bool {
    guard source.api.hasPrefix("http://") || source.api.hasPrefix("https://") else { return false }
    if !source.isTvBox { return true }
    return source.tvboxType == 0 || source.tvboxType == 1
  }

  private func makeDirectCmsUrl(_ api: String, params: [URLQueryItem]) -> URL? {
    guard var comp = URLComponents(string: api) else { return nil }
    comp.queryItems = (comp.queryItems ?? []) + params
    return comp.url
  }

  func fetchVodList(
    source: TvVodSource,
    page: Int = 1,
    typeId: String? = nil
  ) async throws -> TvVodListResponse {
    if canDirectCms(source) {
      var detailParams = [
        URLQueryItem(name: "ac", value: "detail"),
        URLQueryItem(name: "pg", value: String(page)),
      ]
      if let typeId = typeId, !typeId.isEmpty {
        detailParams.append(URLQueryItem(name: "t", value: typeId))
      }
      if let directUrl = makeDirectCmsUrl(source.api, params: detailParams),
         let dict = try? await requestJson(url: directUrl, includeAuth: false) as? [String: Any],
         let rawList = dict["list"] as? [[String: Any]],
         !rawList.isEmpty {
        var rawClasses = (dict["class"] as? [[String: Any]]) ?? []
        if rawClasses.isEmpty, page == 1, (typeId == nil || typeId!.isEmpty),
           let listUrl = makeDirectCmsUrl(
             source.api,
             params: [URLQueryItem(name: "ac", value: "list"), URLQueryItem(name: "pg", value: "1")]
           ),
           let classDict = try? await requestJson(url: listUrl, includeAuth: false) as? [String: Any],
           let fetchedClasses = classDict["class"] as? [[String: Any]] {
          rawClasses = fetchedClasses
        }
        return Self.parseVodListDict(dict, overrideClasses: rawClasses, source: source)
      }
    }

    var query = source.queryItems + [URLQueryItem(name: "pg", value: String(page))]
    if let typeId = typeId, !typeId.isEmpty {
      query.append(URLQueryItem(name: "t", value: typeId))
    }
    guard let url = makeEndpointUrl("/api/vod/list", queryItems: query),
          let dict = try await requestJson(url: url) as? [String: Any] else {
      return TvVodListResponse(categories: [], items: [], pageCount: 1)
    }
    return Self.parseVodListDict(dict, overrideClasses: nil, source: source)
  }

  func searchVod(source: TvVodSource, keyword: String) async -> [TvVodItem] {
    let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    if canDirectCms(source),
       let directUrl = makeDirectCmsUrl(
         source.api,
         params: [
           URLQueryItem(name: "ac", value: "detail"),
           URLQueryItem(name: "wd", value: trimmed),
         ]
       ),
       let dict = try? await requestJson(url: directUrl, includeAuth: false) as? [String: Any],
       let rawList = dict["list"] as? [[String: Any]],
       !rawList.isEmpty {
      return rawList.map { Self.parseVodItem($0, source: source) }
    }

    let query = source.queryItems + [URLQueryItem(name: "wd", value: trimmed)]
    guard let url = makeEndpointUrl("/api/vod/search", queryItems: query),
          let dict = try? await requestJson(url: url) as? [String: Any],
          let rawList = dict["list"] as? [[String: Any]] else {
      return []
    }
    return rawList.map { Self.parseVodItem($0, source: source) }
  }

  func fetchVodDetail(source: TvVodSource, vodId: String) async throws -> TvVodDetail? {
    if canDirectCms(source),
       let directUrl = makeDirectCmsUrl(
         source.api,
         params: [
           URLQueryItem(name: "ac", value: "detail"),
           URLQueryItem(name: "ids", value: vodId),
         ]
       ),
       let dict = try? await requestJson(url: directUrl, includeAuth: false) as? [String: Any],
       let rawList = dict["list"] as? [[String: Any]],
       let first = rawList.first {
      let detail = Self.parseVodDetail(first)
      if !detail.playGroups.isEmpty {
        return detail
      }
    }

    let query = source.queryItems + [URLQueryItem(name: "ids", value: vodId)]
    guard let url = makeEndpointUrl("/api/vod/detail", queryItems: query),
          let dict = try await requestJson(url: url) as? [String: Any],
          let rawList = dict["list"] as? [[String: Any]],
          let first = rawList.first else {
      return nil
    }
    return Self.parseVodDetail(first)
  }

  // MARK: - Playback URL Resolution & M3U8 Ad Stripping

  private static func extractDirectMediaAndHeaders(_ rawUrl: String) -> (url: String, headers: [String: String]) {
    var urlPart = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    var headers: [String: String] = [:]

    if urlPart.contains("$"), !urlPart.hasPrefix("http") {
      let parts = urlPart.components(separatedBy: "$")
      if let last = parts.last, last.hasPrefix("http") {
        urlPart = last.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }

    if let pipeIdx = urlPart.firstIndex(of: "|") {
      let tail = String(urlPart[urlPart.index(after: pipeIdx)...])
      urlPart = String(urlPart[..<pipeIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
      for kv in tail.components(separatedBy: "&") {
        if let eq = kv.firstIndex(of: "=") {
          let k = String(kv[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
          let v = String(kv[kv.index(after: eq)...]).removingPercentEncoding
            ?? String(kv[kv.index(after: eq)...])
          if !k.isEmpty && !v.isEmpty {
            headers[k] = v
          }
        }
      }
    }

    if urlPart.contains("@") {
      let segments = urlPart.components(separatedBy: "@")
      urlPart = segments[0].trimmingCharacters(in: .whitespacesAndNewlines)
      for seg in segments.dropFirst() {
        if let eq = seg.firstIndex(of: "=") {
          let k = String(seg[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
          let v = String(seg[seg.index(after: eq)...]).removingPercentEncoding
            ?? String(seg[seg.index(after: eq)...])
          if !k.isEmpty && !v.isEmpty {
            headers[k] = v
          }
        }
      }
    }

    return (urlPart, headers)
  }

  private static func isDirectPlayableUrl(_ url: String) -> Bool {
    guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return false }
    let lower = url.lowercased()
    return lower.contains(".m3u8")
      || lower.contains(".mp4")
      || lower.contains(".flv")
      || lower.contains(".mkv")
      || lower.contains("/m3u8/")
  }

  func buildServerProxyUrl(targetUrl: String, headers: [String: String] = [:]) -> String {
    guard var comp = URLComponents(string: "\(baseUrl)/api/vod/proxy") else { return targetUrl }
    var items = [URLQueryItem(name: "url", value: targetUrl)]
    if !headers.isEmpty,
       let jsonData = try? JSONSerialization.data(withJSONObject: headers) {
      let b64 = jsonData.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
      items.append(URLQueryItem(name: "headers", value: b64))
    }
    comp.queryItems = items
    return comp.url?.absoluteString ?? targetUrl
  }

  func resolvePlayback(
    source: TvVodSource,
    playFrom: String,
    rawUrl: String
  ) async -> TvResolvedPlayback {
    let extracted = Self.extractDirectMediaAndHeaders(rawUrl)
    if Self.isDirectPlayableUrl(extracted.url) {
      let proxy = buildServerProxyUrl(targetUrl: extracted.url, headers: extracted.headers)
      return TvResolvedPlayback(
        directUrl: extracted.url,
        serverProxyUrl: proxy,
        headers: extracted.headers,
        parseVia: "direct-fast"
      )
    }

    let query = source.queryItems + [
      URLQueryItem(name: "flag", value: playFrom),
      URLQueryItem(name: "id", value: rawUrl),
    ]
    if let url = makeEndpointUrl("/api/vod/play", queryItems: query),
       let dict = try? await requestJson(url: url) as? [String: Any] {
      var headers: [String: String] = extracted.headers
      if let rawHeaders = dict["headers"] as? [String: Any] {
        for (k, v) in rawHeaders {
          let sv = Self.stringValue(v)
          if !sv.isEmpty { headers[k] = sv }
        }
      }
      var direct = Self.stringValue(dict["direct_url"])
      var serverProxy = Self.stringValue(dict["server_proxy_url"])
      let proxyUrl = Self.stringValue(dict["proxy_url"])

      if serverProxy.hasPrefix("/") {
        serverProxy = "\(baseUrl)\(serverProxy)"
      }
      if direct.isEmpty {
        if proxyUrl.hasPrefix("http") {
          direct = proxyUrl
        } else if !serverProxy.isEmpty {
          direct = serverProxy
        } else {
          direct = extracted.url
        }
      }
      if serverProxy.isEmpty {
        serverProxy = buildServerProxyUrl(targetUrl: direct, headers: headers)
      }
      return TvResolvedPlayback(
        directUrl: direct,
        serverProxyUrl: serverProxy,
        headers: headers,
        parseVia: Self.stringValue(dict["parse_via"], fallback: "server")
      )
    }

    let fallbackProxy = buildServerProxyUrl(targetUrl: extracted.url, headers: extracted.headers)
    return TvResolvedPlayback(
      directUrl: extracted.url,
      serverProxyUrl: fallbackProxy,
      headers: extracted.headers,
      parseVia: "fallback"
    )
  }

  /// Strips `#EXT-X-DISCONTINUITY` ad blocks when possible; falls back to original stream URL if encrypted or multi-variant.
  func prepareAdFilteredStreamIfPossible(
    streamUrl: String,
    headers: [String: String],
    enableAdFilter: Bool
  ) async -> String {
    guard enableAdFilter,
          streamUrl.lowercased().contains(".m3u8"),
          !streamUrl.contains("/api/vod/proxy"),
          let url = URL(string: streamUrl) else {
      return streamUrl
    }

    do {
      var req = URLRequest(url: url)
      req.timeoutInterval = 6
      for (k, v) in headers {
        req.setValue(v, forHTTPHeaderField: k)
      }
      if req.value(forHTTPHeaderField: "User-Agent") == nil {
        req.setValue(
          "Mozilla/5.0 (AppleTV; CPU TVOS 17_0 like Mac OS X) AppleWebKit/605.1.15",
          forHTTPHeaderField: "User-Agent"
        )
      }
      let (data, response) = try await session.data(for: req)
      guard let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let text = String(data: data, encoding: .utf8),
            text.contains("#EXTM3U") else {
        return streamUrl
      }

      // Master playlist or encrypted HLS: let AVPlayer load remote URL directly so relative keys/playlists resolve with cookies/headers
      if text.contains("#EXT-X-STREAM-INF") || text.contains("#EXT-X-KEY") {
        return streamUrl
      }
      guard text.contains("#EXT-X-DISCONTINUITY") else {
        return streamUrl
      }

      let cleaned = Self.stripDiscontinuityAdsAndAbsolutize(m3u8Text: text, baseUrl: url)
      let tempFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("tv_clean_\(UUID().uuidString).m3u8")
      try cleaned.write(to: tempFile, atomically: true, encoding: .utf8)
      return tempFile.absoluteString
    } catch {
      return streamUrl
    }
  }

  private static func stripDiscontinuityAdsAndAbsolutize(m3u8Text: String, baseUrl: URL) -> String {
    let lines = m3u8Text.components(separatedBy: .newlines)
    var headerLines: [String] = []
    struct Block {
      var lines: [String] = []
      var segmentCount: Int = 0
      var durationSum: Double = 0
    }
    var blocks: [Block] = [Block()]
    var seenFirstSegmentOrDiscontinuity = false

    for rawLine in lines {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty { continue }

      if line.hasPrefix("#EXT-X-DISCONTINUITY") {
        seenFirstSegmentOrDiscontinuity = true
        blocks.append(Block())
        continue
      }

      if !seenFirstSegmentOrDiscontinuity && line.hasPrefix("#") && !line.hasPrefix("#EXTINF") {
        headerLines.append(line)
        continue
      }

      seenFirstSegmentOrDiscontinuity = true
      if line.hasPrefix("#EXTINF:") {
        let numPart = line
          .replacingOccurrences(of: "#EXTINF:", with: "")
          .components(separatedBy: ",")
          .first ?? "0"
        let dur = Double(numPart.trimmingCharacters(in: .whitespaces)) ?? 0
        blocks[blocks.count - 1].durationSum += dur
        blocks[blocks.count - 1].lines.append(line)
      } else if line.hasPrefix("#") {
        blocks[blocks.count - 1].lines.append(line)
      } else {
        let absUrl = URL(string: line, relativeTo: baseUrl)?.absoluteURL.absoluteString ?? line
        blocks[blocks.count - 1].segmentCount += 1
        blocks[blocks.count - 1].lines.append(absUrl)
      }
    }

    let nonEmptyBlocks = blocks.filter { $0.segmentCount > 0 }
    guard nonEmptyBlocks.count > 1 else {
      return m3u8Text
    }

    var out: [String] = headerLines
    for (idx, b) in nonEmptyBlocks.enumerated() {
      // Heuristic: short discontinuity blocks (<= 5 segments and <= 28 seconds) surrounded by main content are ad inserts
      let isLikelyAd = b.segmentCount <= 5 && b.durationSum <= 28.0 && nonEmptyBlocks.count >= 2
      if isLikelyAd { continue }
      if idx > 0 {
        out.append("#EXT-X-DISCONTINUITY")
      }
      out.append(contentsOf: b.lines)
    }
    if !out.contains(where: { $0.hasPrefix("#EXT-X-ENDLIST") }) {
      out.append("#EXT-X-ENDLIST")
    }
    return out.joined(separator: "\n")
  }

  // MARK: - Live TV

  func fetchLiveSources() async -> [TvLiveSource] {
    guard let url = makeEndpointUrl("/api/tvbox/lives"),
          let dict = try? await requestJson(url: url) as? [String: Any],
          let rawLives = dict["lives"] as? [[String: Any]] else {
      return []
    }
    return rawLives.enumerated().map { idx, item in
      TvLiveSource(
        name: Self.stringValue(item["name"], fallback: "直播源 \(idx + 1)"),
        url: Self.stringValue(item["url"]),
        ua: Self.stringValue(item["ua"]),
        sourceIndex: Self.intValue(item["source_index"], fallback: 0),
        liveIndex: Self.intValue(item["live_index"], fallback: idx)
      )
    }
  }

  func fetchLiveChannels(source: TvLiveSource) async -> [TvLiveChannel] {
    if source.url.hasPrefix("http://") || source.url.hasPrefix("https://"),
       let directUrl = URL(string: source.url) {
      do {
        var req = URLRequest(url: directUrl)
        req.timeoutInterval = 12
        req.setValue(
          source.ua.isEmpty
            ? "Mozilla/5.0 (AppleTV; CPU TVOS 17_0 like Mac OS X)"
            : source.ua,
          forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse,
           (200..<300).contains(http.statusCode),
           let body = String(data: data, encoding: .utf8) {
          let parsed = Self.parseLiveText(body, defaultUa: source.ua)
          if !parsed.isEmpty {
            return parsed
          }
        }
      } catch {}
    }

    let query = [
      URLQueryItem(name: "tvbox_source", value: String(source.sourceIndex)),
      URLQueryItem(name: "tvbox_live", value: String(source.liveIndex)),
    ]
    guard let url = makeEndpointUrl("/api/tvbox/live/channels", queryItems: query),
          let dict = try? await requestJson(url: url) as? [String: Any],
          let rawGroups = dict["groups"] as? [[String: Any]] else {
      return []
    }

    var channels: [TvLiveChannel] = []
    for g in rawGroups {
      let groupName = Self.stringValue(g["group"], fallback: "默认频道")
      let rawChs = (g["channels"] as? [[String: Any]]) ?? []
      for ch in rawChs {
        let name = Self.stringValue(ch["name"], fallback: "未命名频道")
        let logo = Self.stringValue(ch["logo"])
        let urls = (ch["urls"] as? [Any])?.map { Self.stringValue($0) }.filter { !$0.isEmpty } ?? []
        var headers: [String: String] = [:]
        if !source.ua.isEmpty {
          headers["User-Agent"] = source.ua
        }
        if !urls.isEmpty {
          channels.append(
            TvLiveChannel(name: name, group: groupName, urls: urls, logo: logo, headers: headers)
          )
        }
      }
    }
    return channels
  }

  private static func parseLiveText(_ content: String, defaultUa: String) -> [TvLiveChannel] {
    var headers: [String: String] = [:]
    if !defaultUa.isEmpty {
      headers["User-Agent"] = defaultUa
    }
    let lines = content.components(separatedBy: .newlines)
    if content.contains("#EXTM3U") || content.contains("#EXTINF") {
      var channels: [TvLiveChannel] = []
      var currentName = "频道"
      var currentGroup = "直播"
      var currentLogo = ""

      for raw in lines {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { continue }
        if line.hasPrefix("#EXTINF") {
          currentName = line.components(separatedBy: ",").last?.trimmingCharacters(in: .whitespaces) ?? "频道"
          currentGroup = Self.extractAttr(line, key: "group-title") ?? "直播"
          currentLogo = Self.extractAttr(line, key: "tvg-logo") ?? ""
        } else if !line.hasPrefix("#"), line.hasPrefix("http") {
          channels.append(
            TvLiveChannel(
              name: currentName,
              group: currentGroup,
              urls: [line],
              logo: currentLogo,
              headers: headers
            )
          )
        }
      }
      return channels
    } else {
      var channels: [TvLiveChannel] = []
      var currentGroup = "直播"
      for raw in lines {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }
        if line.hasSuffix(",#genre#") {
          currentGroup = line.replacingOccurrences(of: ",#genre#", with: "")
          continue
        }
        if let comma = line.firstIndex(of: ",") {
          let name = String(line[..<comma]).trimmingCharacters(in: .whitespaces)
          let urlField = String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
          let urls = urlField.components(separatedBy: "#").filter { $0.hasPrefix("http") }
          if !name.isEmpty && !urls.isEmpty {
            channels.append(
              TvLiveChannel(
                name: name,
                group: currentGroup,
                urls: urls,
                logo: "",
                headers: headers
              )
            )
          }
        }
      }
      return channels
    }
  }

  private static func extractAttr(_ line: String, key: String) -> String? {
    guard let range = line.range(of: "\(key)=\"") else { return nil }
    let sub = line[range.upperBound...]
    guard let endQuote = sub.firstIndex(of: "\"") else { return nil }
    return String(sub[..<endQuote])
  }

  // MARK: - Library (Favorites & History)

  func fetchLibrary() async -> (favorites: [TvLibraryItem], history: [TvLibraryItem]) {
    guard let url = makeEndpointUrl("/api/tvbox/library"),
          let dict = try? await requestJson(url: url) as? [String: Any] else {
      return ([], [])
    }
    let favRaw = (dict["favorites"] as? [[String: Any]]) ?? []
    let histRaw = (dict["history"] as? [[String: Any]]) ?? []
    return (
      favRaw.map(Self.parseLibraryItem),
      histRaw.map(Self.parseLibraryItem)
    )
  }

  func updateLibrary(kind: String, action: String = "upsert", item: TvLibraryItem) async {
    guard let url = makeEndpointUrl("/api/tvbox/library") else { return }
    let payload: [String: Any] = [
      "kind": kind,
      "action": action,
      "item": [
        "source": item.source,
        "source_name": item.sourceName,
        "vod_id": item.vodId,
        "title": item.title,
        "pic": item.pic,
        "episode": item.episode,
        "line": item.line,
        "position": item.position,
        "duration": item.duration,
        "updated_at": item.updatedAt,
      ],
    ]
    _ = try? await requestJson(url: url, method: "PUT", body: payload)
  }

  // MARK: - Telegram

  func fetchTelegramAccounts() async -> (activeId: String, accounts: [TvTelegramAccount]) {
    guard let url = makeEndpointUrl("/api/telegram/accounts"),
          let dict = try? await requestJson(url: url) as? [String: Any] else {
      return ("", [])
    }
    let activeId = Self.stringValue(dict["active_id"])
    let rawList = (dict["accounts"] as? [[String: Any]]) ?? []
    let accounts = rawList.map { item in
      TvTelegramAccount(
        id: Self.stringValue(item["id"]),
        name: Self.stringValue(item["name"], fallback: Self.stringValue(item["phone"], fallback: "账号")),
        phone: Self.stringValue(item["phone"])
      )
    }
    return (activeId, accounts)
  }

  func fetchTelegramChats(accountId: String) async -> [TvTelegramChat] {
    var query = [
      URLQueryItem(name: "folder", value: "0"),
      URLQueryItem(name: "limit", value: "60"),
    ]
    if !accountId.isEmpty {
      query.append(URLQueryItem(name: "account_id", value: accountId))
    }
    guard let url = makeEndpointUrl("/api/telegram/chats", queryItems: query),
          let dict = try? await requestJson(url: url) as? [String: Any],
          let rawChats = dict["chats"] as? [[String: Any]] else {
      return []
    }
    return rawChats.map { item in
      TvTelegramChat(
        peer: Self.stringValue(item["peer"], fallback: Self.stringValue(item["id"])),
        title: Self.stringValue(item["title"], fallback: "对话"),
        lastMessage: Self.stringValue(item["last_message"]),
        unreadCount: Self.intValue(item["unread_count"], fallback: 0)
      )
    }
  }

  func fetchTelegramMessages(accountId: String, peer: String) async -> [TvTelegramMessage] {
    var query = [
      URLQueryItem(name: "peer", value: peer),
      URLQueryItem(name: "offset_id", value: "0"),
      URLQueryItem(name: "limit", value: "50"),
      URLQueryItem(name: "mark_read", value: "1"),
    ]
    if !accountId.isEmpty {
      query.append(URLQueryItem(name: "account_id", value: accountId))
    }
    guard let url = makeEndpointUrl("/api/telegram/messages", queryItems: query),
          let dict = try? await requestJson(url: url) as? [String: Any],
          let rawMsgs = dict["messages"] as? [[String: Any]] else {
      return []
    }
    return rawMsgs.map { item in
      let mediaType = Self.stringValue(item["media_type"]).lowercased()
      let hasVideo = (item["has_video"] as? Bool) == true || mediaType == "video"
      let hasPhoto = (item["has_photo"] as? Bool) == true || mediaType == "photo"
      return TvTelegramMessage(
        id: Self.intValue(item["id"], fallback: 0),
        text: Self.stringValue(item["text"]),
        date: Self.stringValue(item["date"]),
        isVideo: hasVideo,
        isPhoto: hasPhoto,
        fileName: Self.stringValue(item["file_name"], fallback: "视频 #\(Self.intValue(item["id"], fallback: 0))"),
        fileSize: Self.stringValue(item["file_size_str"], fallback: Self.stringValue(item["file_size"])),
        duration: Self.intValue(item["duration"], fallback: 0)
      )
    }
  }

  func telegramVideoUrl(accountId: String, peer: String, messageId: Int) -> String {
    var items = [
      URLQueryItem(name: "peer", value: peer),
      URLQueryItem(name: "message_id", value: String(messageId)),
    ]
    if !accountId.isEmpty {
      items.append(URLQueryItem(name: "account_id", value: accountId))
    }
    return makeEndpointUrl("/api/telegram/video", queryItems: items)?.absoluteString ?? ""
  }

  // MARK: - Parsers

  private static func parseVodListDict(
    _ dict: [String: Any],
    overrideClasses: [[String: Any]]?,
    source: TvVodSource
  ) -> TvVodListResponse {
    let rawClasses = (overrideClasses != nil && !overrideClasses!.isEmpty)
      ? overrideClasses!
      : ((dict["class"] as? [[String: Any]]) ?? [])
    let categories = rawClasses.compactMap { item -> TvVodCategory? in
      let tid = stringValue(item["type_id"])
      let tname = stringValue(item["type_name"])
      guard !tid.isEmpty && !tname.isEmpty else { return nil }
      return TvVodCategory(typeId: tid, typeName: tname)
    }
    let rawList = (dict["list"] as? [[String: Any]]) ?? []
    let items = rawList.map { parseVodItem($0, source: source) }
    let pageCount = max(1, intValue(dict["pagecount"], fallback: 1))
    return TvVodListResponse(categories: categories, items: items, pageCount: pageCount)
  }

  private static func parseVodItem(_ item: [String: Any], source: TvVodSource) -> TvVodItem {
    TvVodItem(
      vodId: stringValue(item["vod_id"]),
      vodName: stringValue(item["vod_name"], fallback: "未命名影片"),
      vodPic: stringValue(item["vod_pic"]),
      vodRemarks: stringValue(item["vod_remarks"]),
      vodYear: stringValue(item["vod_year"]),
      typeName: stringValue(item["type_name"]),
      source: source
    )
  }

  private static func parseVodDetail(_ item: [String: Any]) -> TvVodDetail {
    let playFrom = stringValue(item["vod_play_from"])
    let playUrl = stringValue(item["vod_play_url"])
    return TvVodDetail(
      vodId: stringValue(item["vod_id"]),
      vodName: stringValue(item["vod_name"], fallback: "未命名影片"),
      vodPic: stringValue(item["vod_pic"]),
      vodRemarks: stringValue(item["vod_remarks"]),
      vodYear: stringValue(item["vod_year"]),
      vodArea: stringValue(item["vod_area"]),
      vodActor: stringValue(item["vod_actor"]),
      vodDirector: stringValue(item["vod_director"]),
      vodContent: stringValue(item["vod_content"])
        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      typeName: stringValue(item["type_name"]),
      playGroups: TvVodDetail.parsePlayGroups(playFrom: playFrom, playUrl: playUrl)
    )
  }

  private static func parseLibraryItem(_ item: [String: Any]) -> TvLibraryItem {
    TvLibraryItem(
      source: stringValue(item["source"]),
      sourceName: stringValue(item["source_name"]),
      vodId: stringValue(item["vod_id"]),
      title: stringValue(item["title"]),
      pic: stringValue(item["pic"]),
      episode: stringValue(item["episode"]),
      line: stringValue(item["line"]),
      position: doubleValue(item["position"], fallback: 0),
      duration: doubleValue(item["duration"], fallback: 0),
      updatedAt: Int64(intValue(item["updated_at"], fallback: 0))
    )
  }

  static func stringValue(_ any: Any?, fallback: String = "") -> String {
    guard let any = any else { return fallback }
    if let s = any as? String { return s }
    if let n = any as? NSNumber { return n.stringValue }
    return String(describing: any)
  }

  static func intValue(_ any: Any?, fallback: Int = 0) -> Int {
    guard let any = any else { return fallback }
    if let i = any as? Int { return i }
    if let n = any as? NSNumber { return n.intValue }
    if let s = any as? String, let i = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
      return i
    }
    return fallback
  }

  static func doubleValue(_ any: Any?, fallback: Double = 0) -> Double {
    guard let any = any else { return fallback }
    if let d = any as? Double { return d }
    if let n = any as? NSNumber { return n.doubleValue }
    if let s = any as? String, let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
      return d
    }
    return fallback
  }
}
