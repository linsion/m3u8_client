import AVFoundation
import AudioToolbox
import CommonCrypto
import CoreMedia
import CryptoKit
import Foundation
import Network
import Security
import VideoToolbox

// MARK: - Real-Time Network Traffic & Proxy Telemetry Monitor (1:1 Match with LocalProxyTunnelBridge + VideoProxyStatsDetailPanel)

final class TvNetworkSpeedMonitor: @unchecked Sendable {
  static let shared = TvNetworkSpeedMonitor()
  private let lock = NSLock()
  private var downstreamSamples: [(timestampMs: Int64, bytes: Int)] = []
  private var upstreamSamples: [(timestampMs: Int64, bytes: Int)] = []
  private var _totalDownstreamBytes: Int64 = 0
  private var _totalUpstreamBytes: Int64 = 0
  private var _activeTunnelConnections: Int = 0
  private var _totalTunnelRequests: Int = 0

  var totalDownstreamBytes: Int64 {
    lock.lock()
    defer { lock.unlock() }
    return _totalDownstreamBytes
  }

  var totalUpstreamBytes: Int64 {
    lock.lock()
    defer { lock.unlock() }
    return _totalUpstreamBytes
  }

  var activeTunnelConnections: Int {
    lock.lock()
    defer { lock.unlock() }
    return _activeTunnelConnections
  }

  var totalTunnelRequests: Int {
    lock.lock()
    defer { lock.unlock() }
    return _totalTunnelRequests
  }

  func incrementTunnelConnection() {
    lock.lock()
    _activeTunnelConnections += 1
    _totalTunnelRequests += 1
    lock.unlock()
  }

  func decrementTunnelConnection() {
    lock.lock()
    if _activeTunnelConnections > 0 {
      _activeTunnelConnections -= 1
    }
    lock.unlock()
  }

  func resetCounters() {
    lock.lock()
    _totalDownstreamBytes = 0
    _totalUpstreamBytes = 0
    _totalTunnelRequests = 0
    downstreamSamples.removeAll()
    upstreamSamples.removeAll()
    lock.unlock()
  }

  func recordDownstreamBytes(_ count: Int) {
    guard count > 0 else { return }
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    lock.lock()
    _totalDownstreamBytes += Int64(count)
    downstreamSamples.append((nowMs, count))
    if downstreamSamples.count > 128 {
      let cutoff = nowMs - 2500
      downstreamSamples.removeAll { $0.timestampMs < cutoff }
    }
    lock.unlock()
  }

  func recordUpstreamBytes(_ count: Int) {
    guard count > 0 else { return }
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    lock.lock()
    _totalUpstreamBytes += Int64(count)
    upstreamSamples.append((nowMs, count))
    if upstreamSamples.count > 128 {
      let cutoff = nowMs - 2500
      upstreamSamples.removeAll { $0.timestampMs < cutoff }
    }
    lock.unlock()
  }

  var recentDownstreamBytesPerSecond: Double {
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    let cutoff = nowMs - 1800
    lock.lock()
    downstreamSamples.removeAll { $0.timestampMs < cutoff }
    var totalBytes = 0
    var earliestMs = nowMs
    for s in downstreamSamples {
      totalBytes += s.bytes
      if s.timestampMs < earliestMs {
        earliestMs = s.timestampMs
      }
    }
    lock.unlock()
    guard totalBytes > 0 else { return 0.0 }
    let spanSec = max(0.45, Double(nowMs - earliestMs) / 1000.0)
    return Double(totalBytes) / spanSec
  }

  var recentUpstreamBytesPerSecond: Double {
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    let cutoff = nowMs - 1800
    lock.lock()
    upstreamSamples.removeAll { $0.timestampMs < cutoff }
    var totalBytes = 0
    var earliestMs = nowMs
    for s in upstreamSamples {
      totalBytes += s.bytes
      if s.timestampMs < earliestMs {
        earliestMs = s.timestampMs
      }
    }
    lock.unlock()
    guard totalBytes > 0 else { return 0.0 }
    let spanSec = max(0.45, Double(nowMs - earliestMs) / 1000.0)
    return Double(totalBytes) / spanSec
  }
}

// MARK: - Local Client Proxy Tunnel Bridge for tvOS (Trojan / VLESS / Shadowsocks AEAD / SOCKS5 / HTTP + Real-Time Exit IP Probe)

struct TvParsedProxyNodeCredentials: Sendable {
  let id: String
  let name: String
  let proto: String
  let host: String
  let port: Int
  var username: String = ""
  var password: String = ""
  var cipher: String = "aes-256-gcm"
  var sni: String = ""
  var tls: Bool = false
  var network: String = "tcp"
  var wsHost: String = ""
  var wsPath: String = "/"
}

struct TvRealTimeProxyIpSnapshot: Sendable {
  let routeLabel: String
  let isUsingProxy: Bool
  let nodeName: String
  let protocolBadge: String
  let entryHostPort: String
  let entryResolvedIp: String
  let exitPublicIp: String
  let exitLocation: String
  let exitIsp: String
  let rttMs: Int
}

final class TvLocalProxyTunnelServer: @unchecked Sendable {
  static let shared = TvLocalProxyTunnelServer()

  private let lock = NSLock()
  private var listener: NWListener?
  private(set) var port: UInt16 = 0
  private let queue = DispatchQueue(label: "tv.liuguang.proxy.tunnel", qos: .userInitiated, attributes: .concurrent)
  private var activeNode: TvSubscriptionNode?
  private var activeCreds: TvParsedProxyNodeCredentials?
  private var lastKnownNode: TvSubscriptionNode?
  private var lastKnownCreds: TvParsedProxyNodeCredentials?
  private var fallbackCredsPool: [TvParsedProxyNodeCredentials] = []
  private var proxyEnabled: Bool = false
  private(set) var configRevision: UInt64 = 0
  private var ipCache: [String: (snapshot: TvRealTimeProxyIpSnapshot, timestampMs: Int64)] = [:]

  private init() {
    startListenerIfNeeded()
  }

  func configure(node: TvSubscriptionNode?, enabled: Bool) {
    startListenerIfNeeded()
    let parsed = node.map { Self.parseCredentials(from: $0) }
    lock.lock()
    let changed = (self.activeNode?.id != node?.id) || (self.proxyEnabled != (enabled && (parsed != nil)))
    self.activeNode = node
    self.activeCreds = parsed
    if let node, let parsed {
      self.lastKnownNode = node
      self.lastKnownCreds = parsed
    }
    self.proxyEnabled = enabled && (parsed != nil)
    if changed {
      self.configRevision &+= 1
    }
    lock.unlock()
    if let h = parsed?.host, !h.isEmpty {
      queue.async {
        _ = Self.resolveRealEntryIpSync(h)
      }
    }
  }

  func seedFallbackNode(_ node: TvSubscriptionNode?, backupNodes: [TvSubscriptionNode] = []) {
    startListenerIfNeeded()
    let parsedPrimary = node.map { Self.parseCredentials(from: $0) }
    var parsedPool: [TvParsedProxyNodeCredentials] = []
    if let p = parsedPrimary {
      parsedPool.append(p)
    }
    for n in backupNodes.prefix(8) where n.isSupportedByClientTunnel {
      let c = Self.parseCredentials(from: n)
      if !c.host.isEmpty && !parsedPool.contains(where: { $0.host == c.host && $0.port == c.port && $0.proto == c.proto }) {
        parsedPool.append(c)
      }
    }
    lock.lock()
    if let node, let parsedPrimary {
      self.lastKnownNode = node
      self.lastKnownCreds = parsedPrimary
    } else if self.lastKnownCreds == nil, let first = parsedPool.first {
      self.lastKnownCreds = first
    }
    if !parsedPool.isEmpty {
      self.fallbackCredsPool = parsedPool
    }
    lock.unlock()
    if let h = parsedPrimary?.host, !h.isEmpty {
      queue.async {
        _ = Self.resolveRealEntryIpSync(h)
      }
    }
  }

  var hasAvailableTunnelNode: Bool {
    lock.lock()
    defer { lock.unlock() }
    return (activeCreds != nil || lastKnownCreds != nil || !fallbackCredsPool.isEmpty) && port > 0
  }

  var currentActiveNode: TvSubscriptionNode? {
    lock.lock()
    defer { lock.unlock() }
    return proxyEnabled ? activeNode : nil
  }

  var isProxyActive: Bool {
    lock.lock()
    defer { lock.unlock() }
    return proxyEnabled && activeCreds != nil && port > 0
  }

  func proxyConnectionDictionary(allowFallbackNode: Bool = false) -> [AnyHashable: Any]? {
    lock.lock()
    let hasCreds = (proxyEnabled && activeCreds != nil) || (allowFallbackNode && (activeCreds != nil || lastKnownCreds != nil || !fallbackCredsPool.isEmpty))
    let p = Int(port)
    lock.unlock()
    guard hasCreds, p > 0 else { return nil }
    return [
      kCFNetworkProxiesHTTPEnable as String: 1,
      kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
      kCFNetworkProxiesHTTPPort as String: p,
      "HTTPSEnable": 1,
      "HTTPSProxy": "127.0.0.1",
      "HTTPSPort": p,
    ]
  }

  func makeProxiedUrlSession(timeoutRequest: TimeInterval = 12, timeoutResource: TimeInterval = 30) -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = timeoutRequest
    cfg.timeoutIntervalForResource = timeoutResource
    cfg.httpMaximumConnectionsPerHost = 24
    cfg.httpShouldSetCookies = true
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    if let dict = proxyConnectionDictionary() {
      cfg.connectionProxyDictionary = dict
    }
    return URLSession(configuration: cfg, delegate: InsecureSessionDelegate(), delegateQueue: nil)
  }

  func startListenerIfNeeded() {
    lock.lock()
    if listener != nil && port > 0 {
      lock.unlock()
      return
    }
    lock.unlock()
    do {
      let params = NWParameters.tcp
      params.allowLocalEndpointReuse = true
      let nwListener = try NWListener(using: params, on: .any)
      nwListener.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        if case .ready = state, let p = nwListener.port?.rawValue, p > 0 {
          self.lock.lock()
          self.port = p
          self.lock.unlock()
        }
      }
      nwListener.newConnectionHandler = { [weak self] conn in
        self?.handleClientConnection(conn)
      }
      nwListener.start(queue: queue)
      lock.lock()
      self.listener = nwListener
      lock.unlock()
    } catch {}
  }

  private func handleClientConnection(_ client: NWConnection) {
    client.start(queue: queue)
    client.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, _, err in
      guard let self, err == nil, let data, !data.isEmpty,
            let headerStr = String(data: data, encoding: .isoLatin1) else {
        client.cancel()
        return
      }
      let lines = headerStr.components(separatedBy: "\r\n")
      guard let firstLine = lines.first else {
        client.cancel()
        return
      }
      let parts = firstLine.components(separatedBy: " ")
      guard parts.count >= 2 else {
        client.cancel()
        return
      }
      let method = parts[0].uppercased()
      let target = parts[1]
      let isConnect = (method == "CONNECT")
      var targetHost = ""
      var targetPort = isConnect ? 443 : 80

      if isConnect {
        let hp = target.components(separatedBy: ":")
        targetHost = hp.first ?? ""
        if hp.count >= 2, let p = Int(hp.last ?? ""), p > 0 {
          targetPort = p
        }
      } else if let u = URL(string: target), let h = u.host, !h.isEmpty {
        targetHost = h
        targetPort = u.port ?? (u.scheme?.lowercased() == "https" ? 443 : 80)
      } else {
        for line in lines.dropFirst() where line.lowercased().hasPrefix("host:") {
          let hVal = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
          let hp = hVal.components(separatedBy: ":")
          targetHost = hp.first ?? ""
          if hp.count >= 2, let p = Int(hp.last ?? ""), p > 0 {
            targetPort = p
          }
          break
        }
      }

      guard !targetHost.isEmpty else {
        client.cancel()
        return
      }

      self.lock.lock()
      let creds = (self.proxyEnabled ? self.activeCreds : nil) ?? self.lastKnownCreds ?? self.fallbackCredsPool.first
      self.lock.unlock()

      if isConnect {
        let established = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
        client.send(content: established, completion: .contentProcessed { sendErr in
          guard sendErr == nil else {
            client.cancel()
            return
          }
          client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { firstPayload, _, _, rxErr in
            guard rxErr == nil, let firstPayload, !firstPayload.isEmpty else {
              client.cancel()
              return
            }
            TvNetworkSpeedMonitor.shared.recordUpstreamBytes(firstPayload.count)
            self.openTunnelAndBridge(
              client: client,
              creds: creds,
              targetHost: targetHost,
              targetPort: targetPort,
              initialPayload: firstPayload
            )
          }
        })
      } else {
        let rewritten = Self.rewriteOriginFormHttpRequest(lines: lines, rawData: data)
        TvNetworkSpeedMonitor.shared.recordUpstreamBytes(rewritten.count)
        self.openTunnelAndBridge(
          client: client,
          creds: creds,
          targetHost: targetHost,
          targetPort: targetPort,
          initialPayload: rewritten
        )
      }
    }
  }

  private static func rewriteOriginFormHttpRequest(lines: [String], rawData: Data) -> Data {
    guard !lines.isEmpty else { return rawData }
    var out = ""
    let parts = lines[0].components(separatedBy: " ")
    if parts.count >= 3, let u = URL(string: parts[1]), u.host != nil {
      let path = u.path.isEmpty ? "/" : u.path
      let query = (u.query != nil && !u.query!.isEmpty) ? "?\(u.query!)" : ""
      out += "\(parts[0]) \(path)\(query) \(parts[2])\r\n"
    } else {
      out += "\(lines[0])\r\n"
    }
    for l in lines.dropFirst() {
      if l.isEmpty { break }
      if l.lowercased().hasPrefix("proxy-connection:") { continue }
      out += "\(l)\r\n"
    }
    out += "\r\n"
    return Data(out.utf8)
  }

  private func openTunnelAndBridge(
    client: NWConnection,
    creds: TvParsedProxyNodeCredentials?,
    targetHost: String,
    targetPort: Int,
    initialPayload: Data
  ) {
    guard let creds else {
      openDirectBridge(client: client, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
      return
    }

    let proto = creds.proto.lowercased()
    if proto == "trojan" {
      openTrojanBridge(client: client, creds: creds, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
    } else if proto == "vless" {
      openVlessBridge(client: client, creds: creds, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
    } else if proto == "ss" || proto == "shadowsocks" {
      openShadowsocksBridge(client: client, creds: creds, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
    } else if proto == "socks5" || proto == "socks" {
      openSocks5Bridge(client: client, creds: creds, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
    } else if proto == "http" || proto == "https" {
      openHttpProxyBridge(client: client, creds: creds, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
    } else {
      openDirectBridge(client: client, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
    }
  }

  private func makeUpstreamConnection(host: String, port: Int, useTls: Bool, sni: String) -> NWConnection {
    let nwHost = NWEndpoint.Host(host)
    let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .https
    if useTls {
      let tlsOptions = NWProtocolTLS.Options()
      let serverName = sni.isEmpty ? host : sni
      sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, serverName)
      sec_protocol_options_set_verify_block(
        tlsOptions.securityProtocolOptions,
        { _, _, completionHandler in completionHandler(true) },
        queue
      )
      let params = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
      return NWConnection(host: nwHost, port: nwPort, using: params)
    } else {
      return NWConnection(host: nwHost, port: nwPort, using: .tcp)
    }
  }

  private func openDirectBridge(
    client: NWConnection,
    targetHost: String,
    targetPort: Int,
    initialPayload: Data
  ) {
    let upstream = makeUpstreamConnection(host: targetHost, port: targetPort, useTls: false, sni: "")
    TvNetworkSpeedMonitor.shared.incrementTunnelConnection()
    upstream.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        upstream.send(content: initialPayload, completion: .contentProcessed { err in
          if err != nil {
            self?.closePair(client: client, upstream: upstream)
            return
          }
          self?.pipeRawBidirectional(client: client, upstream: upstream, stripVlessHeader: false)
        })
      case .failed, .cancelled:
        self?.closePair(client: client, upstream: upstream)
      default:
        break
      }
    }
    upstream.start(queue: queue)
  }

  private static func isProbeOnlyHost(_ targetHost: String) -> Bool {
    let h = targetHost.lowercased()
    return h == "ip-api.com" || h == "www.cloudflare.com" || h == "cp.cloudflare.com" || h == "www.apple.com"
  }

  private func fallbackOrClose(
    client: NWConnection,
    upstream: NWConnection,
    failedCreds: TvParsedProxyNodeCredentials? = nil,
    targetHost: String,
    targetPort: Int,
    initialPayload: Data
  ) {
    if Self.isProbeOnlyHost(targetHost) {
      closePair(client: client, upstream: upstream)
      return
    }
    closePair(client: client, upstream: upstream, countDecrementOnly: true)
    if let failed = failedCreds {
      lock.lock()
      let nextAlt = fallbackCredsPool.first(where: { $0.host != failed.host || $0.port != failed.port })
      if let alt = nextAlt {
        // Rotate pool so dead primary isn't retried first on the very next request
        fallbackCredsPool.removeAll(where: { $0.host == failed.host && $0.port == failed.port })
        fallbackCredsPool.append(failed)
        if lastKnownCreds?.host == failed.host && lastKnownCreds?.port == failed.port {
          lastKnownCreds = alt
        }
      }
      lock.unlock()
      if let alt = nextAlt {
        openTunnelAndBridge(client: client, creds: alt, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
        return
      }
    }
    openDirectBridge(client: client, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
  }

  private func openTrojanBridge(
    client: NWConnection,
    creds: TvParsedProxyNodeCredentials,
    targetHost: String,
    targetPort: Int,
    initialPayload: Data
  ) {
    let sni = creds.sni.isEmpty ? (creds.wsHost.isEmpty ? creds.host : creds.wsHost) : creds.sni
    let connectHost = Self.resolveRealEntryIpSync(creds.host)
    let upstream = makeUpstreamConnection(host: connectHost, port: creds.port, useTls: true, sni: sni)
    TvNetworkSpeedMonitor.shared.incrementTunnelConnection()
    var didFinishHandshakeOrFallback = false
    queue.asyncAfter(deadline: .now() + 2.8) { [weak self] in
      guard let self else { return }
      self.lock.lock()
      let shouldAbort = !didFinishHandshakeOrFallback
      if shouldAbort { didFinishHandshakeOrFallback = true }
      self.lock.unlock()
      if shouldAbort {
        self.fallbackOrClose(client: client, upstream: upstream, failedCreds: creds, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
      }
    }

    let passHash = Self.sha224Hex(creds.password)
    let hostBytes = Array(targetHost.utf8)
    var packet = Data()
    packet.append(contentsOf: passHash.utf8)
    packet.append(contentsOf: [0x0D, 0x0A, 0x01, 0x03, UInt8(hostBytes.count)])
    packet.append(contentsOf: hostBytes)
    packet.append(contentsOf: [UInt8((targetPort >> 8) & 0xFF), UInt8(targetPort & 0xFF), 0x0D, 0x0A])
    packet.append(initialPayload)

    let isWs = (creds.network.lowercased() == "ws")
    let wsHost = creds.wsHost.isEmpty ? sni : creds.wsHost
    let wsPath = creds.wsPath.isEmpty ? "/" : (creds.wsPath.hasPrefix("/") ? creds.wsPath : "/\(creds.wsPath)")

    upstream.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.lock.lock()
        guard !didFinishHandshakeOrFallback else {
          self.lock.unlock()
          return
        }
        didFinishHandshakeOrFallback = true
        self.lock.unlock()
        if isWs {
          self.performWebSocketUpgradeAndPipe(
            client: client,
            upstream: upstream,
            wsHost: wsHost,
            wsPath: wsPath,
            firstTunnelPacket: packet,
            stripVlessHeader: false
          )
        } else {
          upstream.send(content: packet, completion: .contentProcessed { err in
            if err != nil {
              self.closePair(client: client, upstream: upstream)
              return
            }
            self.pipeRawBidirectional(client: client, upstream: upstream, stripVlessHeader: false)
          })
        }
      case .failed:
        self.lock.lock()
        let canFallback = !didFinishHandshakeOrFallback
        if canFallback { didFinishHandshakeOrFallback = true }
        self.lock.unlock()
        if canFallback {
          self.fallbackOrClose(client: client, upstream: upstream, failedCreds: creds, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
        }
      case .cancelled:
        self.closePair(client: client, upstream: upstream)
      default:
        break
      }
    }
    upstream.start(queue: queue)
  }

  private func openVlessBridge(
    client: NWConnection,
    creds: TvParsedProxyNodeCredentials,
    targetHost: String,
    targetPort: Int,
    initialPayload: Data
  ) {
    guard let uuidBytes = Self.parseUuidBytes(creds.password) else {
      if Self.isProbeOnlyHost(targetHost) {
        client.cancel()
      } else {
        openDirectBridge(client: client, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
      }
      return
    }
    let sni = creds.sni.isEmpty ? (creds.wsHost.isEmpty ? creds.host : creds.wsHost) : creds.sni
    let connectHost = Self.resolveRealEntryIpSync(creds.host)
    let upstream = makeUpstreamConnection(host: connectHost, port: creds.port, useTls: creds.tls, sni: sni)
    TvNetworkSpeedMonitor.shared.incrementTunnelConnection()
    var didFinishHandshakeOrFallback = false
    queue.asyncAfter(deadline: .now() + 2.8) { [weak self] in
      guard let self else { return }
      self.lock.lock()
      let shouldAbort = !didFinishHandshakeOrFallback
      if shouldAbort { didFinishHandshakeOrFallback = true }
      self.lock.unlock()
      if shouldAbort {
        self.fallbackOrClose(client: client, upstream: upstream, failedCreds: creds, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
      }
    }

    let hostBytes = Array(targetHost.utf8)
    var packet = Data([0x00])
    packet.append(uuidBytes)
    packet.append(contentsOf: [
      0x00, // addon len 0
      0x01, // TCP
      UInt8((targetPort >> 8) & 0xFF),
      UInt8(targetPort & 0xFF),
      0x02, // Domain
      UInt8(hostBytes.count),
    ])
    packet.append(contentsOf: hostBytes)
    packet.append(initialPayload)

    let isWs = (creds.network.lowercased() == "ws")
    let wsHost = creds.wsHost.isEmpty ? sni : creds.wsHost
    let wsPath = creds.wsPath.isEmpty ? "/" : (creds.wsPath.hasPrefix("/") ? creds.wsPath : "/\(creds.wsPath)")

    upstream.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.lock.lock()
        guard !didFinishHandshakeOrFallback else {
          self.lock.unlock()
          return
        }
        didFinishHandshakeOrFallback = true
        self.lock.unlock()
        if isWs {
          self.performWebSocketUpgradeAndPipe(
            client: client,
            upstream: upstream,
            wsHost: wsHost,
            wsPath: wsPath,
            firstTunnelPacket: packet,
            stripVlessHeader: true
          )
        } else {
          upstream.send(content: packet, completion: .contentProcessed { err in
            if err != nil {
              self.closePair(client: client, upstream: upstream)
              return
            }
            self.pipeRawBidirectional(client: client, upstream: upstream, stripVlessHeader: true)
          })
        }
      case .failed:
        self.lock.lock()
        let canFallback = !didFinishHandshakeOrFallback
        if canFallback { didFinishHandshakeOrFallback = true }
        self.lock.unlock()
        if canFallback {
          self.fallbackOrClose(client: client, upstream: upstream, failedCreds: creds, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
        }
      case .cancelled:
        self.closePair(client: client, upstream: upstream)
      default:
        break
      }
    }
    upstream.start(queue: queue)
  }

  private func openSocks5Bridge(
    client: NWConnection,
    creds: TvParsedProxyNodeCredentials,
    targetHost: String,
    targetPort: Int,
    initialPayload: Data
  ) {
    let connectHost = Self.resolveRealEntryIpSync(creds.host)
    let sni = creds.sni.isEmpty ? creds.host : creds.sni
    let upstream = makeUpstreamConnection(host: connectHost, port: creds.port, useTls: creds.tls, sni: sni)
    TvNetworkSpeedMonitor.shared.incrementTunnelConnection()

    func sendSocks5ConnectRequest() {
      let hostBytes = Array(targetHost.utf8)
      var connReq = Data([0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)])
      connReq.append(contentsOf: hostBytes)
      connReq.append(contentsOf: [UInt8((targetPort >> 8) & 0xFF), UInt8(targetPort & 0xFF)])
      upstream.send(content: connReq, completion: .contentProcessed { [weak self] cErr in
        guard let self, cErr == nil else {
          self?.closePair(client: client, upstream: upstream)
          return
        }
        upstream.receive(minimumIncompleteLength: 4, maximumLength: 64) { cResp, _, _, crErr in
          guard crErr == nil, let cResp, cResp.count >= 4, cResp[1] == 0x00 else {
            self.closePair(client: client, upstream: upstream)
            return
          }
          upstream.send(content: initialPayload, completion: .contentProcessed { pErr in
            guard pErr == nil else {
              self.closePair(client: client, upstream: upstream)
              return
            }
            self.pipeRawBidirectional(client: client, upstream: upstream, stripVlessHeader: false)
          })
        }
      })
    }

    upstream.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        let hasAuth = !creds.username.isEmpty || !creds.password.isEmpty
        let greet = hasAuth ? Data([0x05, 0x02, 0x00, 0x02]) : Data([0x05, 0x01, 0x00])
        upstream.send(content: greet, completion: .contentProcessed { err in
          guard err == nil else {
            self.closePair(client: client, upstream: upstream)
            return
          }
          upstream.receive(minimumIncompleteLength: 2, maximumLength: 16) { resp, _, _, rErr in
            guard rErr == nil, let resp, resp.count >= 2, resp[0] == 0x05 else {
              self.closePair(client: client, upstream: upstream)
              return
            }
            if resp[1] == 0x02 {
              let uBytes = Array(creds.username.utf8)
              let pBytes = Array(creds.password.utf8)
              var authPkt = Data([0x01, UInt8(clamping: uBytes.count)])
              authPkt.append(contentsOf: uBytes.prefix(255))
              authPkt.append(UInt8(clamping: pBytes.count))
              authPkt.append(contentsOf: pBytes.prefix(255))
              upstream.send(content: authPkt, completion: .contentProcessed { aErr in
                guard aErr == nil else {
                  self.closePair(client: client, upstream: upstream)
                  return
                }
                upstream.receive(minimumIncompleteLength: 2, maximumLength: 16) { aResp, _, _, arErr in
                  guard arErr == nil, let aResp, aResp.count >= 2, aResp[1] == 0x00 else {
                    self.closePair(client: client, upstream: upstream)
                    return
                  }
                  sendSocks5ConnectRequest()
                }
              })
            } else if resp[1] == 0x00 {
              sendSocks5ConnectRequest()
            } else {
              self.closePair(client: client, upstream: upstream)
            }
          }
        })
      case .failed:
        self.fallbackOrClose(client: client, upstream: upstream, failedCreds: creds, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
      case .cancelled:
        self.closePair(client: client, upstream: upstream)
      default:
        break
      }
    }
    upstream.start(queue: queue)
  }

  private func openHttpProxyBridge(
    client: NWConnection,
    creds: TvParsedProxyNodeCredentials,
    targetHost: String,
    targetPort: Int,
    initialPayload: Data
  ) {
    let connectHost = Self.resolveRealEntryIpSync(creds.host)
    let sni = creds.sni.isEmpty ? creds.host : creds.sni
    let upstream = makeUpstreamConnection(host: connectHost, port: creds.port, useTls: creds.tls || creds.proto.lowercased() == "https", sni: sni)
    TvNetworkSpeedMonitor.shared.incrementTunnelConnection()
    upstream.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        var connectHeader = "CONNECT \(targetHost):\(targetPort) HTTP/1.1\r\nHost: \(targetHost):\(targetPort)\r\n"
        if !creds.username.isEmpty || !creds.password.isEmpty {
          let rawAuth = "\(creds.username):\(creds.password)"
          let b64 = Data(rawAuth.utf8).base64EncodedString()
          connectHeader += "Proxy-Authorization: Basic \(b64)\r\n"
        }
        connectHeader += "\r\n"
        upstream.send(content: Data(connectHeader.utf8), completion: .contentProcessed { err in
          guard err == nil else {
            self.closePair(client: client, upstream: upstream)
            return
          }
          upstream.receive(minimumIncompleteLength: 12, maximumLength: 4096) { resp, _, _, rErr in
            guard rErr == nil, let resp, let str = String(data: resp, encoding: .isoLatin1), str.contains(" 200 ") else {
              self.closePair(client: client, upstream: upstream)
              return
            }
            upstream.send(content: initialPayload, completion: .contentProcessed { pErr in
              guard pErr == nil else {
                self.closePair(client: client, upstream: upstream)
                return
              }
              self.pipeRawBidirectional(client: client, upstream: upstream, stripVlessHeader: false)
            })
          }
        })
      case .failed:
        self.fallbackOrClose(client: client, upstream: upstream, failedCreds: creds, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
      case .cancelled:
        self.closePair(client: client, upstream: upstream)
      default:
        break
      }
    }
    upstream.start(queue: queue)
  }

  private func openShadowsocksBridge(
    client: NWConnection,
    creds: TvParsedProxyNodeCredentials,
    targetHost: String,
    targetPort: Int,
    initialPayload: Data
  ) {
    let c = creds.cipher.lowercased()
    let isChaCha = c.contains("chacha20")
    let keyLen = isChaCha ? 32 : (c.contains("128") ? 16 : 32)
    let saltLen = keyLen
    let masterKey = Self.evpBytesToKey(password: creds.password, keyLen: keyLen)
    var clientSalt = Data(count: saltLen)
    for i in 0..<saltLen { clientSalt[i] = UInt8.random(in: 0...255) }
    let clientSubkey = Self.hkdfSha1(ikm: masterKey, salt: clientSalt, info: Data("ss-subkey".utf8), outLen: keyLen)

    let hostBytes = Array(targetHost.utf8)
    var plain = Data([0x03, UInt8(hostBytes.count)])
    plain.append(contentsOf: hostBytes)
    plain.append(contentsOf: [UInt8((targetPort >> 8) & 0xFF), UInt8(targetPort & 0xFF)])
    plain.append(initialPayload)

    var clientNonce: UInt64 = 0
    guard let firstEnc = Self.ssAeadPack(plain: plain, subkey: clientSubkey, isChaCha: isChaCha, nonceCounter: &clientNonce) else {
      if Self.isProbeOnlyHost(targetHost) {
        client.cancel()
      } else {
        openDirectBridge(client: client, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
      }
      return
    }
    var firstPacket = clientSalt
    firstPacket.append(firstEnc)

    let connectHost = Self.resolveRealEntryIpSync(creds.host)
    let upstream = makeUpstreamConnection(host: connectHost, port: creds.port, useTls: false, sni: "")
    TvNetworkSpeedMonitor.shared.incrementTunnelConnection()
    upstream.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        upstream.send(content: firstPacket, completion: .contentProcessed { err in
          guard err == nil else {
            self.closePair(client: client, upstream: upstream)
            return
          }
          self.pipeShadowsocksBidirectional(
            client: client,
            upstream: upstream,
            masterKey: masterKey,
            clientSubkey: clientSubkey,
            initialClientNonce: clientNonce,
            saltLen: saltLen,
            keyLen: keyLen,
            isChaCha: isChaCha
          )
        })
      case .failed:
        self.fallbackOrClose(client: client, upstream: upstream, failedCreds: creds, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
      case .cancelled:
        self.closePair(client: client, upstream: upstream)
      default:
        break
      }
    }
    upstream.start(queue: queue)
  }

  private static func encodeMaskedWebSocketBinaryFrame(_ payload: Data) -> Data {
    var frame = Data([0x82]) // FIN + Binary opcode
    let len = payload.count
    if len <= 125 {
      frame.append(UInt8(len) | 0x80)
    } else if len <= 65535 {
      frame.append(126 | 0x80)
      frame.append(UInt8((len >> 8) & 0xFF))
      frame.append(UInt8(len & 0xFF))
    } else {
      frame.append(127 | 0x80)
      let u64 = UInt64(len)
      for shift in stride(from: 56, through: 0, by: -8) {
        frame.append(UInt8((u64 >> shift) & 0xFF))
      }
    }
    let mask: [UInt8] = [
      UInt8.random(in: 0...255),
      UInt8.random(in: 0...255),
      UInt8.random(in: 0...255),
      UInt8.random(in: 0...255),
    ]
    frame.append(contentsOf: mask)
    var masked = Data(count: len)
    payload.withUnsafeBytes { rawPtr in
      guard let src = rawPtr.bindMemory(to: UInt8.self).baseAddress else { return }
      masked.withUnsafeMutableBytes { dstPtr in
        guard let dst = dstPtr.bindMemory(to: UInt8.self).baseAddress else { return }
        for i in 0..<len {
          dst[i] = src[i] ^ mask[i & 3]
        }
      }
    }
    frame.append(masked)
    return frame
  }

  private func performWebSocketUpgradeAndPipe(
    client: NWConnection,
    upstream: NWConnection,
    wsHost: String,
    wsPath: String,
    firstTunnelPacket: Data,
    stripVlessHeader: Bool
  ) {
    var rawKey = Data(count: 16)
    for i in 0..<16 { rawKey[i] = UInt8.random(in: 0...255) }
    let wsKey = rawKey.base64EncodedString()
    let upgradeReq =
      "GET \(wsPath) HTTP/1.1\r\n" +
      "Host: \(wsHost)\r\n" +
      "Upgrade: websocket\r\n" +
      "Connection: Upgrade\r\n" +
      "Sec-WebSocket-Key: \(wsKey)\r\n" +
      "Sec-WebSocket-Version: 13\r\n" +
      "User-Agent: Mozilla/5.0\r\n\r\n"

    upstream.send(content: Data(upgradeReq.utf8), completion: .contentProcessed { [weak self] err in
      guard let self, err == nil else {
        self?.closePair(client: client, upstream: upstream)
        return
      }
      var headerBuf = Data()
      func readUpgradeHeader() {
        upstream.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, isComplete, rErr in
          guard let self, rErr == nil, let chunk, !chunk.isEmpty else {
            self?.closePair(client: client, upstream: upstream)
            return
          }
          headerBuf.append(chunk)
          if let range = headerBuf.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
            let headData = headerBuf.subdata(in: 0..<range.lowerBound)
            let headStr = String(data: headData, encoding: .isoLatin1) ?? ""
            guard headStr.contains(" 101 ") else {
              self.closePair(client: client, upstream: upstream)
              return
            }
            let leftover = headerBuf.subdata(in: range.upperBound..<headerBuf.count)
            let firstWsFrame = Self.encodeMaskedWebSocketBinaryFrame(firstTunnelPacket)
            upstream.send(content: firstWsFrame, completion: .contentProcessed { sErr in
              guard sErr == nil else {
                self.closePair(client: client, upstream: upstream)
                return
              }
              self.pipeWebSocketBidirectional(
                client: client,
                upstream: upstream,
                initialRxBuffer: leftover,
                stripVlessHeader: stripVlessHeader
              )
            })
          } else if headerBuf.count > 16384 || isComplete {
            self.closePair(client: client, upstream: upstream)
          } else {
            readUpgradeHeader()
          }
        }
      }
      readUpgradeHeader()
    })
  }

  private func pipeWebSocketBidirectional(
    client: NWConnection,
    upstream: NWConnection,
    initialRxBuffer: Data,
    stripVlessHeader: Bool
  ) {
    let wsLock = NSLock()
    var rxBuf = initialRxBuffer
    var vlessParsed = !stripVlessHeader
    var vlessBuf = Data()

    func extractFrames() -> Data {
      var extracted = Data()
      while rxBuf.count >= 2 {
        let b0 = rxBuf[rxBuf.startIndex]
        let b1 = rxBuf[rxBuf.startIndex + 1]
        let opcode = b0 & 0x0F
        let isMasked = (b1 & 0x80) != 0
        var payloadLen = Int(b1 & 0x7F)
        var headerLen = 2
        if payloadLen == 126 {
          guard rxBuf.count >= 4 else { break }
          payloadLen = (Int(rxBuf[rxBuf.startIndex + 2]) << 8) | Int(rxBuf[rxBuf.startIndex + 3])
          headerLen = 4
        } else if payloadLen == 127 {
          guard rxBuf.count >= 10 else { break }
          var len64: UInt64 = 0
          for i in 0..<8 {
            len64 = (len64 << 8) | UInt64(rxBuf[rxBuf.startIndex + 2 + i])
          }
          payloadLen = Int(clamping: len64)
          headerLen = 10
        }
        let maskLen = isMasked ? 4 : 0
        let totalFrameLen = headerLen + maskLen + payloadLen
        guard rxBuf.count >= totalFrameLen else { break }
        let payloadStart = rxBuf.startIndex + headerLen + maskLen
        var framePayload = rxBuf.subdata(in: payloadStart..<(payloadStart + payloadLen))
        if isMasked {
          let m0 = rxBuf[rxBuf.startIndex + headerLen]
          let m1 = rxBuf[rxBuf.startIndex + headerLen + 1]
          let m2 = rxBuf[rxBuf.startIndex + headerLen + 2]
          let m3 = rxBuf[rxBuf.startIndex + headerLen + 3]
          let mask = [m0, m1, m2, m3]
          for i in 0..<framePayload.count {
            framePayload[i] ^= mask[i & 3]
          }
        }
        rxBuf.removeSubrange(rxBuf.startIndex..<(rxBuf.startIndex + totalFrameLen))
        if opcode == 0x01 || opcode == 0x02 || opcode == 0x00 {
          if !vlessParsed {
            vlessBuf.append(framePayload)
            if vlessBuf.count >= 2 {
              let addonLen = Int(vlessBuf[1])
              if vlessBuf.count >= 2 + addonLen {
                vlessParsed = true
                extracted.append(vlessBuf.subdata(in: (2 + addonLen)..<vlessBuf.count))
                vlessBuf.removeAll()
              }
            }
          } else {
            extracted.append(framePayload)
          }
        }
      }
      return extracted
    }

    func pumpClientToUpstream() {
      client.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, isComplete, err in
        guard let self else { return }
        if let data, !data.isEmpty {
          TvNetworkSpeedMonitor.shared.recordUpstreamBytes(data.count)
          let wsFrame = Self.encodeMaskedWebSocketBinaryFrame(data)
          upstream.send(content: wsFrame, completion: .contentProcessed { sErr in
            if sErr != nil || isComplete {
              self.closePair(client: client, upstream: upstream)
            } else {
              pumpClientToUpstream()
            }
          })
          return
        }
        if err != nil || isComplete {
          self.closePair(client: client, upstream: upstream)
        }
      }
    }

    func pumpUpstreamToClient() {
      upstream.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, err in
        guard let self else { return }
        if let data, !data.isEmpty {
          TvNetworkSpeedMonitor.shared.recordDownstreamBytes(data.count)
          wsLock.lock()
          rxBuf.append(data)
          let outPlain = extractFrames()
          wsLock.unlock()
          if !outPlain.isEmpty {
            client.send(content: outPlain, completion: .contentProcessed { sErr in
              if sErr != nil || isComplete {
                self.closePair(client: client, upstream: upstream)
              } else {
                pumpUpstreamToClient()
              }
            })
            return
          } else if !isComplete && err == nil {
            pumpUpstreamToClient()
            return
          }
        }
        if err != nil || isComplete {
          self.closePair(client: client, upstream: upstream)
        }
      }
    }

    wsLock.lock()
    let initialPlain = extractFrames()
    wsLock.unlock()
    if !initialPlain.isEmpty {
      client.send(content: initialPlain, completion: .contentProcessed { _ in })
    }
    pumpClientToUpstream()
    pumpUpstreamToClient()
  }

  private func pipeShadowsocksBidirectional(
    client: NWConnection,
    upstream: NWConnection,
    masterKey: Data,
    clientSubkey: Data,
    initialClientNonce: UInt64,
    saltLen: Int,
    keyLen: Int,
    isChaCha: Bool
  ) {
    let stateLock = NSLock()
    var clientNonce = initialClientNonce
    var serverNonce: UInt64 = 0
    var serverSubkey: Data? = nil
    var rxBuf = Data()
    var pendingLen: Int? = nil

    func pumpClientToUpstream() {
      client.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, isComplete, err in
        guard let self else { return }
        if let data, !data.isEmpty {
          TvNetworkSpeedMonitor.shared.recordUpstreamBytes(data.count)
          stateLock.lock()
          let packed = Self.ssAeadPack(plain: data, subkey: clientSubkey, isChaCha: isChaCha, nonceCounter: &clientNonce)
          stateLock.unlock()
          if let packed {
            upstream.send(content: packed, completion: .contentProcessed { sErr in
              if sErr != nil || isComplete {
                self.closePair(client: client, upstream: upstream)
              } else {
                pumpClientToUpstream()
              }
            })
            return
          }
        }
        if err != nil || isComplete {
          self.closePair(client: client, upstream: upstream)
        }
      }
    }

    func pumpUpstreamToClient() {
      upstream.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, err in
        guard let self else { return }
        if let data, !data.isEmpty {
          TvNetworkSpeedMonitor.shared.recordDownstreamBytes(data.count)
          var outPlain = Data()
          var failed = false
          stateLock.lock()
          rxBuf.append(data)
          if serverSubkey == nil, rxBuf.count >= saltLen {
            let srvSalt = rxBuf.subdata(in: 0..<saltLen)
            rxBuf.removeSubrange(0..<saltLen)
            serverSubkey = Self.hkdfSha1(ikm: masterKey, salt: srvSalt, info: Data("ss-subkey".utf8), outLen: keyLen)
          }
          if let sKey = serverSubkey {
            while true {
              if pendingLen == nil {
                guard rxBuf.count >= 18 else { break }
                let encLen = rxBuf.subdata(in: 0..<18)
                guard let decLen = Self.ssAeadOpen(cipherWithTag: encLen, subkey: sKey, isChaCha: isChaCha, nonce: serverNonce) else {
                  failed = true
                  break
                }
                serverNonce += 1
                rxBuf.removeSubrange(0..<18)
                pendingLen = ((Int(decLen[0]) << 8) | Int(decLen[1])) & 0x3FFF
              }
              if let pLen = pendingLen {
                let need = pLen + 16
                guard rxBuf.count >= need else { break }
                let encPayload = rxBuf.subdata(in: 0..<need)
                guard let decPayload = Self.ssAeadOpen(cipherWithTag: encPayload, subkey: sKey, isChaCha: isChaCha, nonce: serverNonce) else {
                  failed = true
                  break
                }
                serverNonce += 1
                rxBuf.removeSubrange(0..<need)
                pendingLen = nil
                outPlain.append(decPayload)
              }
            }
          }
          stateLock.unlock()

          if failed {
            self.closePair(client: client, upstream: upstream)
            return
          }
          if !outPlain.isEmpty {
            client.send(content: outPlain, completion: .contentProcessed { sErr in
              if sErr != nil || isComplete {
                self.closePair(client: client, upstream: upstream)
              } else {
                pumpUpstreamToClient()
              }
            })
            return
          }
          if !isComplete && err == nil {
            pumpUpstreamToClient()
            return
          }
        }
        if err != nil || isComplete {
          self.closePair(client: client, upstream: upstream)
        }
      }
    }

    pumpClientToUpstream()
    pumpUpstreamToClient()
  }

  private func pipeRawBidirectional(
    client: NWConnection,
    upstream: NWConnection,
    stripVlessHeader: Bool
  ) {
    let vlessLock = NSLock()
    var vlessParsed = !stripVlessHeader
    var vlessBuf = Data()

    func pumpClientToUpstream() {
      client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, err in
        guard let self else { return }
        if let data, !data.isEmpty {
          TvNetworkSpeedMonitor.shared.recordUpstreamBytes(data.count)
          upstream.send(content: data, completion: .contentProcessed { sErr in
            if sErr != nil || isComplete {
              self.closePair(client: client, upstream: upstream)
            } else {
              pumpClientToUpstream()
            }
          })
          return
        }
        if err != nil || isComplete {
          self.closePair(client: client, upstream: upstream)
        }
      }
    }

    func pumpUpstreamToClient() {
      upstream.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, err in
        guard let self else { return }
        if let data, !data.isEmpty {
          TvNetworkSpeedMonitor.shared.recordDownstreamBytes(data.count)
          var forwardData = data
          vlessLock.lock()
          if !vlessParsed {
            vlessBuf.append(data)
            if vlessBuf.count >= 2 {
              let addonLen = Int(vlessBuf[1])
              if vlessBuf.count >= 2 + addonLen {
                vlessParsed = true
                forwardData = vlessBuf.subdata(in: (2 + addonLen)..<vlessBuf.count)
                vlessBuf.removeAll()
              } else {
                forwardData = Data()
              }
            } else {
              forwardData = Data()
            }
          }
          vlessLock.unlock()

          if !forwardData.isEmpty {
            client.send(content: forwardData, completion: .contentProcessed { sErr in
              if sErr != nil || isComplete {
                self.closePair(client: client, upstream: upstream)
              } else {
                pumpUpstreamToClient()
              }
            })
            return
          } else if !isComplete && err == nil {
            pumpUpstreamToClient()
            return
          }
        }
        if err != nil || isComplete {
          self.closePair(client: client, upstream: upstream)
        }
      }
    }

    pumpClientToUpstream()
    pumpUpstreamToClient()
  }

  private func closePair(client: NWConnection, upstream: NWConnection, countDecrementOnly: Bool = false) {
    TvNetworkSpeedMonitor.shared.decrementTunnelConnection()
    upstream.stateUpdateHandler = nil
    upstream.cancel()
    if !countDecrementOnly {
      client.cancel()
    }
  }

  // MARK: - Crypto & Node Credential Parser Helpers

  private static func sha224Hex(_ input: String) -> String {
    let data = Data(input.utf8)
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
    data.withUnsafeBytes { ptr in
      _ = CC_SHA224(ptr.baseAddress, CC_LONG(data.count), &digest)
    }
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func parseUuidBytes(_ uuidStr: String) -> Data? {
    let hex = uuidStr.replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard hex.count == 32 else { return nil }
    var out = Data(capacity: 16)
    var idx = hex.startIndex
    for _ in 0..<16 {
      let next = hex.index(idx, offsetBy: 2)
      guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
      out.append(b)
      idx = next
    }
    return out
  }

  private static func evpBytesToKey(password: String, keyLen: Int) -> Data {
    let passBytes = Data(password.utf8)
    var result = Data()
    var prev = Data()
    while result.count < keyLen {
      var input = prev
      input.append(passBytes)
      var md5 = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
      input.withUnsafeBytes { ptr in
        _ = CC_MD5(ptr.baseAddress, CC_LONG(input.count), &md5)
      }
      prev = Data(md5)
      result.append(prev)
    }
    return result.prefix(keyLen)
  }

  private static func hkdfSha1(ikm: Data, salt: Data, info: Data, outLen: Int) -> Data {
    var prk = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    salt.withUnsafeBytes { saltPtr in
      ikm.withUnsafeBytes { ikmPtr in
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), saltPtr.baseAddress, salt.count, ikmPtr.baseAddress, ikm.count, &prk)
      }
    }
    var okm = Data()
    var t = Data()
    var counter: UInt8 = 1
    while okm.count < outLen {
      var msg = t
      msg.append(info)
      msg.append(counter)
      var block = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
      msg.withUnsafeBytes { msgPtr in
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), prk, prk.count, msgPtr.baseAddress, msg.count, &block)
      }
      t = Data(block)
      okm.append(t)
      counter &+= 1
    }
    return okm.prefix(outLen)
  }

  private static func makeSsNonce(_ counter: UInt64) -> Data {
    var n = Data(repeating: 0, count: 12)
    var le = counter.littleEndian
    withUnsafeBytes(of: &le) { ptr in
      for i in 0..<8 { n[i] = ptr[i] }
    }
    return n
  }

  private static func ssAeadEncrypt(plain: Data, subkey: Data, isChaCha: Bool, nonce: UInt64) -> Data? {
    let nonceData = makeSsNonce(nonce)
    let key = SymmetricKey(data: subkey)
    do {
      if isChaCha {
        let chachaNonce = try ChaChaPoly.Nonce(data: nonceData)
        let sealed = try ChaChaPoly.seal(plain, using: key, nonce: chachaNonce)
        var out = Data(sealed.ciphertext)
        out.append(sealed.tag)
        return out
      } else {
        let aesNonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.seal(plain, using: key, nonce: aesNonce)
        var out = Data(sealed.ciphertext)
        out.append(sealed.tag)
        return out
      }
    } catch {
      return nil
    }
  }

  private static func ssAeadOpen(cipherWithTag: Data, subkey: Data, isChaCha: Bool, nonce: UInt64) -> Data? {
    guard cipherWithTag.count >= 16 else { return nil }
    let nonceData = makeSsNonce(nonce)
    let key = SymmetricKey(data: subkey)
    let ct = cipherWithTag.prefix(cipherWithTag.count - 16)
    let tag = cipherWithTag.suffix(16)
    do {
      if isChaCha {
        let chachaNonce = try ChaChaPoly.Nonce(data: nonceData)
        let box = try ChaChaPoly.SealedBox(nonce: chachaNonce, ciphertext: ct, tag: tag)
        return try ChaChaPoly.open(box, using: key)
      } else {
        let aesNonce = try AES.GCM.Nonce(data: nonceData)
        let box = try AES.GCM.SealedBox(nonce: aesNonce, ciphertext: ct, tag: tag)
        return try AES.GCM.open(box, using: key)
      }
    } catch {
      return nil
    }
  }

  private static func ssAeadPack(plain: Data, subkey: Data, isChaCha: Bool, nonceCounter: inout UInt64) -> Data? {
    var out = Data()
    var offset = 0
    while offset < plain.count {
      let end = min(offset + 0x3FFF, plain.count)
      let slice = plain.subdata(in: offset..<end)
      let lenData = Data([UInt8((slice.count >> 8) & 0xFF), UInt8(slice.count & 0xFF)])
      guard let encLen = ssAeadEncrypt(plain: lenData, subkey: subkey, isChaCha: isChaCha, nonce: nonceCounter) else { return nil }
      nonceCounter += 1
      guard let encPayload = ssAeadEncrypt(plain: slice, subkey: subkey, isChaCha: isChaCha, nonce: nonceCounter) else { return nil }
      nonceCounter += 1
      out.append(encLen)
      out.append(encPayload)
      offset = end
    }
    return out
  }

  static func parseCredentials(from node: TvSubscriptionNode) -> TvParsedProxyNodeCredentials {
    let raw = node.rawUri.trimmingCharacters(in: .whitespacesAndNewlines)
    var creds = TvParsedProxyNodeCredentials(
      id: node.id,
      name: node.displayTitle,
      proto: node.type.lowercased(),
      host: node.host,
      port: node.port
    )

    if raw.contains("server:") && raw.contains("port:") {
      // Clash YAML line
      func yamlVal(_ k: String) -> String {
        guard let r = raw.range(of: "\(k):") else { return "" }
        var s = String(raw[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        if let c = s.firstIndex(of: ",") { s = String(s[..<c]) }
        if let b = s.firstIndex(of: "}") { s = String(s[..<b]) }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
      }
      let pw = yamlVal("password")
      let uuid = yamlVal("uuid")
      creds.password = !pw.isEmpty ? pw : uuid
      creds.username = yamlVal("username")
      let cipher = yamlVal("cipher")
      if !cipher.isEmpty { creds.cipher = cipher }
      let sni = yamlVal("sni")
      let servername = yamlVal("servername")
      creds.sni = !sni.isEmpty ? sni : servername
      let tlsStr = yamlVal("tls").lowercased()
      creds.tls = (tlsStr == "true" || tlsStr == "1" || creds.proto == "trojan")
      let net = yamlVal("network")
      if !net.isEmpty { creds.network = net.lowercased() }
      return creds
    }

    guard let schemeRange = raw.range(of: "://") else { return creds }
    let proto = String(raw[..<schemeRange.lowerBound]).lowercased()
    var body = String(raw[schemeRange.upperBound...])
    if let hashIdx = body.firstIndex(of: "#") {
      body = String(body[..<hashIdx])
    }

    if proto == "ss" || proto == "shadowsocks" {
      var queryPart = ""
      if let qIdx = body.firstIndex(of: "?") {
        queryPart = String(body[body.index(after: qIdx)...])
        body = String(body[..<qIdx])
      }
      if !body.contains("@"), let dec = decodeBase64(body), dec.contains("@") {
        body = dec
      }
      if let atIdx = body.lastIndex(of: "@") {
        var userInfo = String(body[..<atIdx])
        if !userInfo.contains(":"), let decUser = decodeBase64(userInfo), decUser.contains(":") {
          userInfo = decUser
        }
        if let colon = userInfo.firstIndex(of: ":") {
          creds.cipher = String(userInfo[..<colon])
          creds.password = String(userInfo[userInfo.index(after: colon)...]).removingPercentEncoding
            ?? String(userInfo[userInfo.index(after: colon)...])
        }
      }
      if !queryPart.isEmpty {
        // Optional plugin params
        _ = queryPart
      }
      return creds
    }

    if let comp = URLComponents(string: raw) {
      let user = (comp.user ?? "").removingPercentEncoding ?? (comp.user ?? "")
      let pass = (comp.password ?? "").removingPercentEncoding ?? (comp.password ?? "")
      if proto == "trojan" || proto == "vless" {
        creds.password = !pass.isEmpty ? pass : user
        creds.tls = (proto == "trojan")
      } else {
        creds.username = user
        creds.password = pass
      }
      for item in comp.queryItems ?? [] {
        let k = item.name.lowercased()
        let v = item.value ?? ""
        switch k {
        case "sni", "peer":
          if !v.isEmpty { creds.sni = v }
        case "security":
          if v.lowercased() == "tls" || v.lowercased() == "reality" || v.lowercased() == "xtls" {
            creds.tls = true
          }
        case "type", "net":
          if !v.isEmpty { creds.network = v.lowercased() }
        case "host":
          if !v.isEmpty { creds.wsHost = v }
        case "path":
          if !v.isEmpty { creds.wsPath = v }
        default:
          break
        }
      }
    }
    return creds
  }

  private static func decodeBase64(_ raw: String) -> String? {
    var padded = raw
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
      .components(separatedBy: .whitespacesAndNewlines)
      .joined()
    guard !padded.isEmpty else { return nil }
    while padded.count % 4 != 0 { padded.append("=") }
    guard let data = Data(base64Encoded: padded, options: .ignoreUnknownCharacters) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static let dnsLock = NSLock()
  private static var realEntryIpCache: [String: (ip: String, expiresAtMs: Int64)] = [:]

  private static func isFakeOrBogusIp(_ ip: String) -> Bool {
    let s = ip.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return true }
    return s.hasPrefix("198.18.") ||
      s.hasPrefix("198.19.") ||
      s.hasPrefix("198.20.") ||
      s.hasPrefix("198.21.") ||
      s.hasPrefix("240.") ||
      s == "0.0.0.0" ||
      s == "255.255.255.255"
  }

  private static func isIpv4Literal(_ s: String) -> Bool {
    let parts = s.components(separatedBy: ".")
    guard parts.count == 4 else { return false }
    for p in parts {
      guard let v = UInt8(p), String(v) == p else { return false }
    }
    return true
  }

  static func resolveRealEntryIpSync(_ host: String) -> String {
    let clean = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return clean }
    if clean == "localhost" { return "127.0.0.1" }
    if isIpv4Literal(clean) || clean.contains(":") {
      return clean
    }

    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    dnsLock.lock()
    if let hit = realEntryIpCache[clean], nowMs < hit.expiresAtMs, !hit.ip.isEmpty {
      dnsLock.unlock()
      return hit.ip
    }
    dnsLock.unlock()

    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 2.0
    cfg.timeoutIntervalForResource = 2.5
    cfg.connectionProxyDictionary = [:]
    let directSession = URLSession(configuration: cfg, delegate: InsecureSessionDelegate(), delegateQueue: nil)
    defer { directSession.finishTasksAndInvalidate() }

    let encHost = clean.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? clean

    // 1. Alibaba Public DoH (223.5.5.5 / 223.6.6.6)
    for dohIp in ["223.5.5.5", "223.6.6.6"] {
      guard let u = URL(string: "https://\(dohIp)/resolve?name=\(encHost)&type=A") else { continue }
      var req = URLRequest(url: u)
      req.setValue("application/dns-json", forHTTPHeaderField: "Accept")
      let sem = DispatchSemaphore(value: 0)
      var resolvedIp: String? = nil
      let task = directSession.dataTask(with: req) { data, resp, err in
        defer { sem.signal() }
        guard err == nil,
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let data,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = dict["Answer"] as? [[String: Any]] else { return }
        for ans in answers {
          let type = (ans["type"] as? Int) ?? 0
          let candidate = (ans["data"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
          if type == 1, isIpv4Literal(candidate), !isFakeOrBogusIp(candidate), !candidate.hasPrefix("127.") {
            resolvedIp = candidate
            break
          }
        }
      }
      task.resume()
      _ = sem.wait(timeout: .now() + 2.2)
      if let ip = resolvedIp {
        dnsLock.lock()
        realEntryIpCache[clean] = (ip, nowMs + 30 * 60 * 1000)
        dnsLock.unlock()
        return ip
      }
    }

    // 2. DNSPod HTTP DNS (119.29.29.29)
    if let u = URL(string: "http://119.29.29.29/d?dn=\(encHost)") {
      let sem = DispatchSemaphore(value: 0)
      var resolvedIp: String? = nil
      let task = directSession.dataTask(with: u) { data, resp, err in
        defer { sem.signal() }
        guard err == nil,
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let data,
              let text = String(data: data, encoding: .utf8) else { return }
        for part in text.components(separatedBy: CharacterSet(charactersIn: ";,")) {
          let candidate = part.trimmingCharacters(in: .whitespacesAndNewlines)
          if isIpv4Literal(candidate), !isFakeOrBogusIp(candidate), !candidate.hasPrefix("127.") {
            resolvedIp = candidate
            break
          }
        }
      }
      task.resume()
      _ = sem.wait(timeout: .now() + 2.0)
      if let ip = resolvedIp {
        dnsLock.lock()
        realEntryIpCache[clean] = (ip, nowMs + 30 * 60 * 1000)
        dnsLock.unlock()
        return ip
      }
    }

    // 3. Fallback to OS DNS only if not a Fake-IP
    let sysIp = resolveHostToIp(clean)
    if isIpv4Literal(sysIp) && !isFakeOrBogusIp(sysIp) {
      dnsLock.lock()
      realEntryIpCache[clean] = (sysIp, nowMs + 5 * 60 * 1000)
      dnsLock.unlock()
      return sysIp
    }
    return clean
  }

  static func resolveRealEntryIp(_ host: String) async -> String {
    await withCheckedContinuation { cont in
      DispatchQueue.global(qos: .userInitiated).async {
        cont.resume(returning: resolveRealEntryIpSync(host))
      }
    }
  }

  private static func resolveHostToIp(_ host: String) -> String {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    hints.ai_family = AF_UNSPEC
    var res: UnsafeMutablePointer<addrinfo>? = nil
    let err = getaddrinfo(host, nil, &hints, &res)
    guard err == 0, let first = res else { return host }
    defer { freeaddrinfo(res) }
    var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    if getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &hostBuf, socklen_t(hostBuf.count), nil, 0, NI_NUMERICHOST) == 0 {
      let ip = String(cString: hostBuf)
      if !ip.isEmpty { return ip }
    }
    return host
  }

  private func cachedIpSnapshot(key: String, nowMs: Int64) -> TvRealTimeProxyIpSnapshot? {
    lock.lock()
    defer { lock.unlock() }
    guard let hit = ipCache[key], nowMs - hit.timestampMs < 25_000 else { return nil }
    return hit.snapshot
  }

  private func storeIpSnapshot(_ snapshot: TvRealTimeProxyIpSnapshot, forKey key: String, nowMs: Int64) {
    lock.lock()
    ipCache[key] = (snapshot, nowMs)
    lock.unlock()
  }

  func probeRealTimeIpInfo(
    node: TvSubscriptionNode?,
    routeMode: TvScenarioRouteMode,
    selectionMode: TvProxySelectionMode,
    forceRefresh: Bool = false
  ) async -> TvRealTimeProxyIpSnapshot {
    let isProxy = (routeMode == .proxyNode && node != nil)
    let isRelay = (routeMode == .serverRelay)
    let cacheKey = isProxy ? "node:\(node!.id)" : (isRelay ? "relay" : "direct")
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

    if !forceRefresh, let cached = cachedIpSnapshot(key: cacheKey, nowMs: nowMs) {
      return cached
    }

    let routeLabel: String = {
      if isProxy {
        return selectionMode == .autoFastest ? "代理加速 · 自动择优" : "代理加速 · 手动锁定"
      }
      if isRelay {
        return "服务端代理中转"
      }
      return "客户端直连模式"
    }()
    let nodeName = isProxy
      ? node!.displayTitle
      : (isRelay ? "主服务端中转 (/api/vod/proxy)" : "本机网络直连 (Direct)")
    let protoBadge = isProxy
      ? node!.type.uppercased()
      : (isRelay ? "HTTP-RELAY" : "DIRECT")
    let entryHostPort = isProxy ? "\(node!.host):\(node!.port)" : "本机网卡直出"
    let resolvedEntryHost = isProxy ? await Self.resolveRealEntryIp(node!.host) : ""
    let entryIp = isProxy ? "\(resolvedEntryHost):\(node!.port)" : "本机直连"

    if isProxy {
      configure(node: node, enabled: true)
    }

    let probeSession = isProxy
      ? makeProxiedUrlSession(timeoutRequest: 5, timeoutResource: 6)
      : {
          let cfg = URLSessionConfiguration.ephemeral
          cfg.timeoutIntervalForRequest = 4.5
          cfg.timeoutIntervalForResource = 5.5
          return URLSession(configuration: cfg, delegate: InsecureSessionDelegate(), delegateQueue: nil)
        }()
    defer { probeSession.finishTasksAndInvalidate() }

    var exitIp = ""
    var exitLoc = ""
    var exitIsp = ""
    var rttMs = isProxy ? (node?.latencyMs ?? 0) : 0

    // 1. Probe ip-api.com (Chinese location & ISP)
    if let u1 = URL(string: "http://ip-api.com/json/?lang=zh-CN&fields=status,country,regionName,city,isp,org,query") {
      let t0 = Date()
      var req = URLRequest(url: u1)
      req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
      if let (data, resp) = try? await probeSession.data(for: req),
         let http = resp as? HTTPURLResponse, http.statusCode == 200,
         let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         (dict["status"] as? String) == "success" {
        rttMs = max(1, Int(Date().timeIntervalSince(t0) * 1000))
        exitIp = (dict["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let country = (dict["country"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let region = (dict["regionName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let city = (dict["city"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if !country.isEmpty { parts.append(country) }
        if !region.isEmpty && region != country { parts.append(region) }
        if !city.isEmpty && city != region { parts.append(city) }
        exitLoc = parts.joined(separator: " · ")
        exitIsp = (dict["isp"] as? String ?? dict["org"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }

    // 2. Fallback to Cloudflare cdn-cgi/trace
    if exitIp.isEmpty, let u2 = URL(string: "https://www.cloudflare.com/cdn-cgi/trace") {
      let t0 = Date()
      if let (data, resp) = try? await probeSession.data(from: u2),
         let http = resp as? HTTPURLResponse, http.statusCode == 200,
         let text = String(data: data, encoding: .utf8) {
        rttMs = max(1, Int(Date().timeIntervalSince(t0) * 1000))
        for line in text.components(separatedBy: "\n") {
          if line.hasPrefix("ip=") {
            exitIp = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
          } else if line.hasPrefix("loc=") {
            exitLoc = String(line.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
          } else if line.hasPrefix("colo=") {
            exitIsp = "Cloudflare \(String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines))"
          }
        }
      }
    }

    let snapshot = TvRealTimeProxyIpSnapshot(
      routeLabel: routeLabel,
      isUsingProxy: isProxy || isRelay,
      nodeName: nodeName,
      protocolBadge: protoBadge,
      entryHostPort: entryHostPort,
      entryResolvedIp: entryIp,
      exitPublicIp: exitIp.isEmpty ? (isProxy ? "代理连接不可用" : "探测超时") : exitIp,
      exitLocation: exitLoc.isEmpty ? (isProxy ? "请切换可用节点或重新测速" : "本地网络") : exitLoc,
      exitIsp: exitIsp,
      rttMs: rttMs
    )
    if !exitIp.isEmpty {
      storeIpSnapshot(snapshot, forKey: cacheKey, nowMs: nowMs)
    }
    return snapshot
  }
}

// MARK: - Multi-Range Local HLS Accelerator Proxy for tvOS AVPlayer
// Solves two root causes of Apple TV live stream stalls:
// 1. Upstream IPTV CDNs throttle single TCP connections to ~110 KB/s (causing 3-4 MB .ts segments to take 28-40s and roll off the 3-segment sliding window).
//    By splitting each .ts segment into 8 parallel HTTP Range requests (HTTP 206), download speed increases 6x-8x (600+ KB/s, finishing in ~3s).
// 2. Upstream GSLB gateways (e.g. openresty 302 redirectors) return `Content-Type: text/html` on redirect and 3-segment sliding windows;
//    serving normalized `application/vnd.apple.mpegurl` and `video/mp2t` from `127.0.0.1` gives AVPlayer instant, stall-free playback.

actor TvHlsSegmentCacheActor {
  struct SegmentEntry {
    let seq: Int
    let infLine: String
    let absoluteUrl: String
  }

  private var generation: Int = 0
  private var gatewayUrl: String = ""
  private var streamUrl: String = ""
  private var headers: [String: String] = [:]
  private var cache: [String: Data] = [:]
  private var cacheOrder: [String] = []
  private var inFlight: [String: Task<Data?, Never>] = [:]
  private var slidingWindow: [SegmentEntry] = []
  private var nextSeqNumber: Int = 1
  private var prefetchTask: Task<Void, Never>? = nil
  private var cachedRewrittenVodPlaylist: String? = nil

  func configureSession(gatewayUrl: String, resolvedUrl: String, headers: [String: String]) -> Int {
    prefetchTask?.cancel()
    prefetchTask = nil
    for (_, t) in inFlight { t.cancel() }
    inFlight.removeAll()
    cache.removeAll()
    cacheOrder.removeAll()
    slidingWindow.removeAll()
    cachedRewrittenVodPlaylist = nil
    nextSeqNumber = 1
    generation &+= 1
    self.gatewayUrl = gatewayUrl
    self.streamUrl = resolvedUrl
    self.headers = headers
    return generation
  }

  func currentConfig() -> (gen: Int, gatewayUrl: String, streamUrl: String, headers: [String: String]) {
    (generation, gatewayUrl, streamUrl, headers)
  }

  func updateStreamUrl(_ newUrl: String, forGen gen: Int) {
    guard gen == generation, !newUrl.isEmpty else { return }
    if self.streamUrl != newUrl {
      self.streamUrl = newUrl
      self.cachedRewrittenVodPlaylist = nil
    }
  }

  func cachedVodPlaylist(forGen gen: Int) -> String? {
    guard gen == generation else { return nil }
    return cachedRewrittenVodPlaylist
  }

  func setCachedVodPlaylist(_ playlist: String, forGen gen: Int) {
    guard gen == generation else { return }
    cachedRewrittenVodPlaylist = playlist
  }

  func mergeSlidingSegments(newSegments: [(inf: String, url: String)], forGen gen: Int) -> [SegmentEntry] {
    guard gen == generation else { return [] }
    for item in newSegments {
      if !slidingWindow.contains(where: { $0.absoluteUrl == item.url }) {
        slidingWindow.append(SegmentEntry(seq: nextSeqNumber, infLine: item.inf, absoluteUrl: item.url))
        nextSeqNumber += 1
      }
    }
    if slidingWindow.count > 6 {
      slidingWindow.removeFirst(slidingWindow.count - 6)
    }
    return slidingWindow
  }

  func cachedData(for url: String, gen: Int) -> Data? {
    guard gen == generation else { return nil }
    return cache[url]
  }

  func setPrefetchTask(_ task: Task<Void, Never>, forGen gen: Int) {
    guard gen == generation else {
      task.cancel()
      return
    }
    prefetchTask?.cancel()
    prefetchTask = task
  }

  func fetchOrJoinSegment(
    url: String,
    gen: Int,
    downloader: @Sendable @escaping (String, [String: String]) async -> Data?
  ) async -> Data? {
    guard gen == generation else { return nil }
    if let hit = cache[url] { return hit }
    if let existing = inFlight[url] {
      return await existing.value
    }
    let hdrs = self.headers
    let task = Task<Data?, Never> {
      await downloader(url, hdrs)
    }
    inFlight[url] = task
    let data = await task.value
    inFlight.removeValue(forKey: url)
    guard gen == generation, let valid = data, !valid.isEmpty else { return data }
    cache[url] = valid
    cacheOrder.append(url)
    if cacheOrder.count > 10 {
      let old = cacheOrder.removeFirst()
      cache.removeValue(forKey: old)
    }
    return valid
  }
}

// MARK: - Zero-Copy Hardware VideoToolbox / AudioToolbox HTTP-FLV Direct Engine (AVSampleBufferDisplayLayer + AVSampleBufferAudioRenderer)
// Bypasses AVPlayer's HLS/MPEG-TS demuxer completely for HTTP-FLV live streams (斗鱼一起看 / 虎牙一起看 / YY轮播),
// feeding H.264/HEVC NALUs and AAC audio packets directly into tvOS hardware decoders with 0ms segment wait!

final class TvDirectFlvHardwareEngine: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  let displayLayer = AVSampleBufferDisplayLayer()
  let audioRenderer = AVSampleBufferAudioRenderer()
  let synchronizer = AVSampleBufferRenderSynchronizer()

  private let lock = NSLock()
  private var buffer = Data()
  private var cursor = 0
  private var headerSkipped = false

  private var videoFormatDesc: CMVideoFormatDescription? = nil
  private var audioFormatDesc: CMAudioFormatDescription? = nil
  private var nalLengthSize: Int = 4
  private var videoCodecId: UInt8 = 0
  private var cachedH264Sps: Data? = nil
  private var cachedH264Pps: Data? = nil
  private var cachedHevcParamSets: [Data] = []

  private var lastVideoRawDtsMs: Int64 = -1
  private var normVideoDtsMs: Int64 = 0
  private var lastAudioRawDtsMs: Int64 = -1
  private var normAudioDtsMs: Int64 = 0
  private var audioSampleRate: Int32 = 48000
  private var nextAudioSamplePts: Int64 = -1
  private var renderedVideoFrameCount: Int = 0
  private var reconnectAttempts: Int = 0
  private var initialGatewayCandidate: (url: URL, headers: [String: String], useProxy: Bool)? = nil

  private var hasStartedSynchronizer = false
  private var hasRenderedFirstVideoFrame = false
  private var lastFrameReceivedAt: Date = Date()

  private var task: URLSessionDataTask?
  private var session: URLSession?
  private var isStopped = true
  private var isPaused = false

  private var candidates: [(url: URL, headers: [String: String], useProxy: Bool)] = []
  private var candidateIndex: Int = 0

  var onFirstFrameRendered: (@Sendable () -> Void)?
  var onAllCandidatesFailed: (@Sendable () -> Void)?

  override init() {
    super.init()
    displayLayer.videoGravity = .resizeAspect
    synchronizer.addRenderer(displayLayer)
    synchronizer.addRenderer(audioRenderer)
  }

  var isActivelyPlaying: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !isStopped && !isPaused && hasRenderedFirstVideoFrame
  }

  var hasRecentFrames: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !isStopped && hasRenderedFirstVideoFrame && Date().timeIntervalSince(lastFrameReceivedAt) < 12.0
  }

  func start(
    primaryUrl: String,
    primaryHeaders: [String: String],
    gatewayUrl: String,
    gatewayHeaders: [String: String],
    serverProxyUrl: String,
    serverAuthHeaders: [String: String],
    forceProxyNode: Bool = false
  ) {
    stop()

    var list: [(url: URL, headers: [String: String], useProxy: Bool)] = []
    let hasProxyNode = TvLocalProxyTunnelServer.shared.hasAvailableTunnelNode
    func addCandidate(_ urlStr: String, _ hdrs: [String: String], _ proxy: Bool) {
      let clean = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !clean.isEmpty, let u = URL(string: clean) else { return }
      if !list.contains(where: { $0.url == u && $0.useProxy == proxy }) {
        list.append((u, hdrs, proxy))
      }
    }

    if forceProxyNode && hasProxyNode {
      addCandidate(primaryUrl, primaryHeaders, true)
      if gatewayUrl != primaryUrl {
        addCandidate(gatewayUrl, gatewayHeaders, true)
      }
      addCandidate(primaryUrl, primaryHeaders, false)
    } else {
      addCandidate(primaryUrl, primaryHeaders, false)
      if gatewayUrl != primaryUrl {
        addCandidate(gatewayUrl, gatewayHeaders, false)
      }
      if hasProxyNode {
        addCandidate(primaryUrl, primaryHeaders, true)
        if gatewayUrl != primaryUrl {
          addCandidate(gatewayUrl, gatewayHeaders, true)
        }
      }
    }

    guard !list.isEmpty else {
      onAllCandidatesFailed?()
      return
    }

    lock.lock()
    self.isStopped = false
    self.isPaused = false
    self.candidates = list
    self.candidateIndex = 0
    self.hasStartedSynchronizer = false
    self.hasRenderedFirstVideoFrame = false
    self.renderedVideoFrameCount = 0
    self.reconnectAttempts = 0
    let gwClean = gatewayUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    if !gwClean.isEmpty, let gwU = URL(string: gwClean) {
      self.initialGatewayCandidate = (gwU, gatewayHeaders, forceProxyNode && hasProxyNode)
    } else {
      self.initialGatewayCandidate = list.first
    }
    self.lastFrameReceivedAt = Date()
    lock.unlock()

    let first = list[0]
    launchCandidate(url: first.url, headers: first.headers, useProxy: first.useProxy, preserveTimeline: false)
  }

  func pause() {
    lock.lock()
    isPaused = true
    lock.unlock()
    synchronizer.rate = 0.0
  }

  func resume() {
    lock.lock()
    let started = hasStartedSynchronizer
    isPaused = false
    lock.unlock()
    if started {
      synchronizer.rate = 1.0
    }
  }

  func stop() {
    lock.lock()
    isStopped = true
    isPaused = false
    let t = task
    let s = session
    task = nil
    session = nil
    buffer.removeAll(keepingCapacity: false)
    cursor = 0
    headerSkipped = false
    videoFormatDesc = nil
    audioFormatDesc = nil
    cachedH264Sps = nil
    cachedH264Pps = nil
    cachedHevcParamSets.removeAll()
    lastVideoRawDtsMs = -1
    normVideoDtsMs = 0
    lastAudioRawDtsMs = -1
    normAudioDtsMs = 0
    nextAudioSamplePts = -1
    renderedVideoFrameCount = 0
    reconnectAttempts = 0
    hasStartedSynchronizer = false
    hasRenderedFirstVideoFrame = false
    lock.unlock()

    t?.cancel()
    s?.invalidateAndCancel()
    synchronizer.rate = 0.0
    displayLayer.flushAndRemoveImage()
    audioRenderer.flush()
  }

  private func launchCandidate(url: URL, headers: [String: String], useProxy: Bool, preserveTimeline: Bool = false) {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = useProxy ? 6.5 : 3.8
    cfg.timeoutIntervalForResource = 7200
    cfg.httpShouldSetCookies = true
    if useProxy, let proxyDict = TvLocalProxyTunnelServer.shared.proxyConnectionDictionary(allowFallbackNode: true) {
      cfg.connectionProxyDictionary = proxyDict
    } else {
      cfg.connectionProxyDictionary = [:]
    }

    let sess = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    for (k, v) in headers where !v.isEmpty {
      req.setValue(v, forHTTPHeaderField: k)
    }
    if req.value(forHTTPHeaderField: "User-Agent") == nil {
      req.setValue("okHttp/Mod-1.5.0.0", forHTTPHeaderField: "User-Agent")
    }
    let t = sess.dataTask(with: req)

    lock.lock()
    guard !isStopped else {
      lock.unlock()
      sess.invalidateAndCancel()
      return
    }
    let oldTask = self.task
    let oldSess = self.session
    self.buffer.removeAll(keepingCapacity: true)
    self.cursor = 0
    self.headerSkipped = false
    self.lastVideoRawDtsMs = -1
    self.lastAudioRawDtsMs = -1
    self.renderedVideoFrameCount = 0
    if !preserveTimeline {
      self.videoFormatDesc = nil
      self.audioFormatDesc = nil
      self.cachedH264Sps = nil
      self.cachedH264Pps = nil
      self.cachedHevcParamSets.removeAll()
      self.normVideoDtsMs = 0
      self.normAudioDtsMs = 0
      self.nextAudioSamplePts = -1
      self.hasStartedSynchronizer = false
    }
    self.task = t
    self.session = sess
    lock.unlock()

    oldTask?.cancel()
    oldSess?.invalidateAndCancel()
    if !preserveTimeline {
      displayLayer.flush()
      audioRenderer.flush()
    }
    t.resume()
  }

  private func advanceCandidateLocked(preserveTimeline: Bool = false) {
    guard !isStopped else { return }
    candidateIndex += 1
    guard candidateIndex < candidates.count else {
      if preserveTimeline, reconnectAttempts < 6, let gw = initialGatewayCandidate {
        reconnectAttempts += 1
        let useProxy = (reconnectAttempts % 2 == 0) && TvLocalProxyTunnelServer.shared.hasAvailableTunnelNode
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) { [weak self] in
          self?.launchCandidate(url: gw.url, headers: gw.headers, useProxy: useProxy, preserveTimeline: true)
        }
        return
      }
      let cb = onAllCandidatesFailed
      DispatchQueue.main.async {
        cb?()
      }
      return
    }
    let next = candidates[candidateIndex]
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.06) { [weak self] in
      self?.launchCandidate(url: next.url, headers: next.headers, useProxy: next.useProxy, preserveTimeline: preserveTimeline)
    }
  }

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

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    var req = request
    lock.lock()
    let curIdx = min(max(0, candidateIndex), max(0, candidates.count - 1))
    let hdrs = candidates.isEmpty ? [:] : candidates[curIdx].headers
    let wasUsingProxy = candidates.isEmpty ? false : candidates[curIdx].useProxy
    lock.unlock()
    for (k, v) in hdrs where !v.isEmpty {
      req.setValue(v, forHTTPHeaderField: k)
    }
    if wasUsingProxy,
       let target = req.url,
       let host = target.host?.lowercased() {
      let rLower = target.absoluteString.lowercased()
      if host.contains("douyucdn") || host.contains("huya.com") || host.contains("yy.com") || rLower.contains(".flv") {
        // Redirected from gateway (mursor.ottiptv.cc) via proxy to a domestic CDN .flv stream:
        // try direct connection to the domestic CDN first, and keep proxy connection to the CDN as the very next fallback!
        completionHandler(nil)
        var followHeaders = hdrs
        if let cookie = response.value(forHTTPHeaderField: "Set-Cookie"), !cookie.isEmpty, followHeaders["Cookie"] == nil {
          followHeaders["Cookie"] = cookie
        }
        lock.lock()
        let insertIdx = min(candidates.count, candidateIndex + 1)
        candidates.insert((target, followHeaders, true), at: insertIdx)
        candidates.insert((target, followHeaders, false), at: insertIdx)
        advanceCandidateLocked()
        lock.unlock()
        return
      }
    }
    completionHandler(req)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
      completionHandler(.cancel)
      lock.lock()
      if dataTask === self.task {
        advanceCandidateLocked()
      }
      lock.unlock()
      return
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    guard !isStopped, task === self.task else {
      lock.unlock()
      return
    }
    // A live HTTP-FLV stream is continuous and should never complete while playing.
    // If it ends early (error != nil or unexpected EOF after a short GOP burst), advance or seamless-reconnect!
    let hadFirstFrame = hasRenderedFirstVideoFrame
    advanceCandidateLocked(preserveTimeline: hadFirstFrame)
    lock.unlock()
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    TvNetworkSpeedMonitor.shared.recordDownstreamBytes(data.count)
    lock.lock()
    defer { lock.unlock() }
    guard !isStopped, dataTask === self.task else { return }
    buffer.append(data)

    if !headerSkipped {
      if buffer.count - cursor >= 13 {
        guard buffer[cursor] == 0x46, buffer[cursor + 1] == 0x4C, buffer[cursor + 2] == 0x56 else {
          dataTask.cancel()
          advanceCandidateLocked()
          return
        }
        let h0 = Int(buffer[cursor + 5]) << 24
        let h1 = Int(buffer[cursor + 6]) << 16
        let h2 = Int(buffer[cursor + 7]) << 8
        let h3 = Int(buffer[cursor + 8])
        let headerOffset = h0 | h1 | h2 | h3
        if headerOffset < 9 || headerOffset > 1024 {
          dataTask.cancel()
          advanceCandidateLocked()
          return
        }
        if buffer.count - cursor >= headerOffset + 4 {
          cursor += headerOffset + 4
          headerSkipped = true
        }
      }
      if !headerSkipped { return }
    }

    while buffer.count - cursor >= 11 {
      let tagType = buffer[cursor]
      let dataSize = (Int(buffer[cursor + 1]) << 16) | (Int(buffer[cursor + 2]) << 8) | Int(buffer[cursor + 3])
      let totalNeeded = 11 + dataSize + 4
      if buffer.count - cursor < totalNeeded { break }
      let dtsLow = (Int(buffer[cursor + 4]) << 16) | (Int(buffer[cursor + 5]) << 8) | Int(buffer[cursor + 6])
      let dtsExt = Int(buffer[cursor + 7]) << 24
      let dtsMs = Int64(dtsLow | dtsExt)
      let body = buffer.subdata(in: (cursor + 11)..<(cursor + 11 + dataSize))
      cursor += totalNeeded
      decodeFlvTagLocked(tagType: tagType, dtsMs: dtsMs, body: body)
    }

    if cursor > 262144 {
      buffer.removeSubrange(0..<cursor)
      cursor = 0
    }
  }

  private static func splitAnnexBNalus(_ data: Data) -> [Data] {
    var nalus: [Data] = []
    let bytes = [UInt8](data)
    let count = bytes.count
    var start = -1
    var i = 0
    while i < count {
      var scLen = 0
      if i + 3 < count && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
        scLen = 4
      } else if i + 2 < count && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
        scLen = 3
      }
      if scLen > 0 {
        if start >= 0 && i > start {
          nalus.append(Data(bytes[start..<i]))
        }
        start = i + scLen
        i += scLen
      } else {
        i += 1
      }
    }
    if start >= 0 && start < count {
      nalus.append(Data(bytes[start..<count]))
    }
    return nalus
  }

  private static func convertAnnexBToLengthPrefixed(_ data: Data) -> Data {
    packLengthPrefixedNalus(splitAnnexBNalus(data))
  }

  private static func packLengthPrefixedNalus(_ nalus: [Data]) -> Data {
    var out = Data()
    for n in nalus where !n.isEmpty {
      let l = n.count
      out.append(UInt8((l >> 24) & 0xFF))
      out.append(UInt8((l >> 16) & 0xFF))
      out.append(UInt8((l >> 8) & 0xFF))
      out.append(UInt8(l & 0xFF))
      out.append(n)
    }
    return out
  }

  private static func splitAvccNalus(_ data: Data, nalLengthSize: Int) -> [Data] {
    var nalus: [Data] = []
    var pos = 0
    while pos + nalLengthSize <= data.count {
      var len = 0
      for i in 0..<nalLengthSize {
        len = (len << 8) | Int(data[pos + i])
      }
      pos += nalLengthSize
      guard len > 0, pos + len <= data.count else { break }
      nalus.append(data.subdata(in: pos..<(pos + len)))
      pos += len
    }
    return nalus
  }

  private static func createH264FormatDesc(sps: Data, pps: Data, nalLengthSize: Int) -> CMVideoFormatDescription? {
    var fmt: CMFormatDescription? = nil
    sps.withUnsafeBytes { spsRaw in
      pps.withUnsafeBytes { ppsRaw in
        guard let p0 = spsRaw.bindMemory(to: UInt8.self).baseAddress,
              let p1 = ppsRaw.bindMemory(to: UInt8.self).baseAddress else { return }
        let ptrs: [UnsafePointer<UInt8>] = [p0, p1]
        let sizes: [Int] = [sps.count, pps.count]
        _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: kCFAllocatorDefault,
          parameterSetCount: 2,
          parameterSetPointers: ptrs,
          parameterSetSizes: sizes,
          nalUnitHeaderLength: Int32(nalLengthSize),
          formatDescriptionOut: &fmt
        )
      }
    }
    return fmt
  }

  private static func createHevcFormatDesc(paramSets: [Data], nalLengthSize: Int) -> CMVideoFormatDescription? {
    guard paramSets.count >= 3 else { return nil }
    var fmt: CMFormatDescription? = nil
    paramSets[0].withUnsafeBytes { r0 in
      paramSets[1].withUnsafeBytes { r1 in
        paramSets[2].withUnsafeBytes { r2 in
          guard let p0 = r0.bindMemory(to: UInt8.self).baseAddress,
                let p1 = r1.bindMemory(to: UInt8.self).baseAddress,
                let p2 = r2.bindMemory(to: UInt8.self).baseAddress else { return }
          let ptrs: [UnsafePointer<UInt8>] = [p0, p1, p2]
          let sizes: [Int] = [paramSets[0].count, paramSets[1].count, paramSets[2].count]
          _ = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: 3,
            parameterSetPointers: ptrs,
            parameterSetSizes: sizes,
            nalUnitHeaderLength: Int32(nalLengthSize),
            extensions: nil,
            formatDescriptionOut: &fmt
          )
        }
      }
    }
    return fmt
  }

  private func decodeFlvTagLocked(tagType: UInt8, dtsMs: Int64, body: Data) {
    guard body.count >= 2 else { return }

    if tagType == 9, body.count >= 5 {
      let frameType = (body[0] >> 4) & 0x0F
      let codecId = body[0] & 0x0F
      guard codecId == 7 || codecId == 12 else { return } // 7 = H.264 (AVC), 12 = H.265 (HEVC)
      self.videoCodecId = codecId
      let pktType = body[1]
      var cts = (Int(body[2]) << 16) | (Int(body[3]) << 8) | Int(body[4])
      if (cts & 0x800000) != 0 { cts -= 0x1000000 }

      if pktType == 0 {
        if codecId == 7, body.count >= 11 {
          nalLengthSize = Int(body[9] & 0x03) + 1
          var pos = 10
          let numSps = Int(body[pos] & 0x1F)
          pos += 1
          var spsList: [Data] = []
          var ppsList: [Data] = []
          for _ in 0..<numSps {
            guard pos + 2 <= body.count else { break }
            let len = (Int(body[pos]) << 8) | Int(body[pos + 1])
            pos += 2
            guard pos + len <= body.count else { break }
            spsList.append(body.subdata(in: pos..<(pos + len)))
            pos += len
          }
          if pos < body.count {
            let numPps = Int(body[pos])
            pos += 1
            for _ in 0..<numPps {
              guard pos + 2 <= body.count else { break }
              let len = (Int(body[pos]) << 8) | Int(body[pos + 1])
              pos += 2
              guard pos + len <= body.count else { break }
              ppsList.append(body.subdata(in: pos..<(pos + len)))
              pos += len
            }
          }
          if let sps = spsList.first, let pps = ppsList.first {
            self.cachedH264Sps = sps
            self.cachedH264Pps = pps
            if let validFmt = Self.createH264FormatDesc(sps: sps, pps: pps, nalLengthSize: nalLengthSize) {
              self.videoFormatDesc = validFmt
            }
          }
        } else if codecId == 12, body.count > 5 {
          let payload = body.subdata(in: 5..<body.count)
          var paramSets: [Data] = []
          if payload.count >= 4 && ((payload[0] == 0 && payload[1] == 0 && payload[2] == 0 && payload[3] == 1) || (payload[0] == 0 && payload[1] == 0 && payload[2] == 1)) {
            nalLengthSize = 4
            for n in Self.splitAnnexBNalus(payload) where !n.isEmpty {
              let nType = (n[0] >> 1) & 0x3F
              if nType == 32 || nType == 33 || nType == 34 {
                paramSets.append(n)
              }
            }
          } else if payload.count >= 23 {
            nalLengthSize = Int(payload[21] & 0x03) + 1
            let numArrays = Int(payload[22])
            var pos = 23
            for _ in 0..<numArrays {
              guard pos + 3 <= payload.count else { break }
              let numNalus = (Int(payload[pos + 1]) << 8) | Int(payload[pos + 2])
              pos += 3
              for _ in 0..<numNalus {
                guard pos + 2 <= payload.count else { break }
                let len = (Int(payload[pos]) << 8) | Int(payload[pos + 1])
                pos += 2
                guard pos + len <= payload.count else { break }
                paramSets.append(payload.subdata(in: pos..<(pos + len)))
                pos += len
              }
            }
          }
          if paramSets.count >= 3 {
            self.cachedHevcParamSets = Array(paramSets.prefix(3))
            if let validFmt = Self.createHevcFormatDesc(paramSets: self.cachedHevcParamSets, nalLengthSize: nalLengthSize) {
              self.videoFormatDesc = validFmt
            }
          }
        }
      } else if pktType == 1, body.count > 5 {
        let isKeyframe = (frameType == 1)
        var rawPayload = body.subdata(in: 5..<body.count)
        let isAnnexB = rawPayload.count >= 4 && ((rawPayload[0] == 0 && rawPayload[1] == 0 && rawPayload[2] == 0 && rawPayload[3] == 1) || (rawPayload[0] == 0 && rawPayload[1] == 0 && rawPayload[2] == 1))
        if isAnnexB || videoFormatDesc == nil || isKeyframe {
          let nalus = isAnnexB ? Self.splitAnnexBNalus(rawPayload) : Self.splitAvccNalus(rawPayload, nalLengthSize: nalLengthSize)
          if codecId == 7 {
            var updated = false
            for n in nalus where !n.isEmpty {
              let nType = n[0] & 0x1F
              if nType == 7 {
                cachedH264Sps = n
                updated = true
              } else if nType == 8 {
                cachedH264Pps = n
                updated = true
              }
            }
            if (updated || videoFormatDesc == nil), let sps = cachedH264Sps, let pps = cachedH264Pps {
              if let validFmt = Self.createH264FormatDesc(sps: sps, pps: pps, nalLengthSize: isAnnexB ? 4 : nalLengthSize) {
                self.videoFormatDesc = validFmt
              }
            }
          } else if codecId == 12 {
            var vps: Data? = cachedHevcParamSets.count >= 1 ? cachedHevcParamSets[0] : nil
            var sps: Data? = cachedHevcParamSets.count >= 2 ? cachedHevcParamSets[1] : nil
            var pps: Data? = cachedHevcParamSets.count >= 3 ? cachedHevcParamSets[2] : nil
            var updated = false
            for n in nalus where !n.isEmpty {
              let nType = (n[0] >> 1) & 0x3F
              if nType == 32 { vps = n; updated = true }
              else if nType == 33 { sps = n; updated = true }
              else if nType == 34 { pps = n; updated = true }
            }
            if (updated || videoFormatDesc == nil), let v = vps, let s = sps, let p = pps {
              cachedHevcParamSets = [v, s, p]
              if let validFmt = Self.createHevcFormatDesc(paramSets: cachedHevcParamSets, nalLengthSize: isAnnexB ? 4 : nalLengthSize) {
                self.videoFormatDesc = validFmt
              }
            }
          }
          if isAnnexB {
            rawPayload = Self.packLengthPrefixedNalus(nalus)
          }
        }
        guard let fmt = videoFormatDesc else { return }

        if lastVideoRawDtsMs < 0 {
          guard isKeyframe else { return }
          lastVideoRawDtsMs = dtsMs
          if hasStartedSynchronizer && normVideoDtsMs > 0 {
            normVideoDtsMs += 40
          } else {
            normVideoDtsMs = 0
          }
        } else {
          var delta = dtsMs - lastVideoRawDtsMs
          if delta <= 0 || delta > 1200 {
            delta = 40
          }
          lastVideoRawDtsMs = dtsMs
          normVideoDtsMs += delta
        }
        let clampedCts = Int64(max(-500, min(1500, cts)))
        let ptsMs = max(0, normVideoDtsMs + clampedCts)

        let framePayload = rawPayload
        let len = framePayload.count
        guard len > 4 else { return }

        var blockBuf: CMBlockBuffer? = nil
        guard CMBlockBufferCreateWithMemoryBlock(
          allocator: kCFAllocatorDefault,
          memoryBlock: nil,
          blockLength: len,
          blockAllocator: kCFAllocatorDefault,
          customBlockSource: nil,
          offsetToData: 0,
          dataLength: len,
          flags: 0,
          blockBufferOut: &blockBuf
        ) == kCMBlockBufferNoErr, let bb = blockBuf else { return }

        framePayload.withUnsafeBytes { rawPtr in
          if let base = rawPtr.baseAddress {
            _ = CMBlockBufferReplaceDataBytes(
              with: base,
              blockBuffer: bb,
              offsetIntoDestination: 0,
              dataLength: len
            )
          }
        }

        var timing = CMSampleTimingInfo(
          duration: CMTime(value: 40, timescale: 1000),
          presentationTimeStamp: CMTime(value: ptsMs, timescale: 1000),
          decodeTimeStamp: CMTime(value: normVideoDtsMs, timescale: 1000)
        )
        var sampleBuf: CMSampleBuffer? = nil
        guard CMSampleBufferCreateReady(
          allocator: kCFAllocatorDefault,
          dataBuffer: bb,
          formatDescription: fmt,
          sampleCount: 1,
          sampleTimingEntryCount: 1,
          sampleTimingArray: &timing,
          sampleSizeEntryCount: 1,
          sampleSizeArray: [len],
          sampleBufferOut: &sampleBuf
        ) == noErr, let sb = sampleBuf else { return }

        if displayLayer.status == .failed {
          displayLayer.flush()
        }
        displayLayer.enqueue(sb)
        renderedVideoFrameCount += 1
        lastFrameReceivedAt = Date()

        if !hasStartedSynchronizer {
          hasStartedSynchronizer = true
          if !isPaused {
            synchronizer.setRate(1.0, time: CMTime(value: 0, timescale: 1000))
          }
        }
        if !hasRenderedFirstVideoFrame {
          hasRenderedFirstVideoFrame = true
          let cb = onFirstFrameRendered
          DispatchQueue.main.async {
            cb?()
          }
        }
      }
    } else if tagType == 8, body.count >= 2 {
      let soundFmt = (body[0] >> 4) & 0x0F
      guard soundFmt == 10 else { return } // AAC
      let pktType = body[1]
      if pktType == 0, body.count >= 4 {
        let asc = body.subdata(in: 2..<body.count)
        let b0 = asc[0], b1 = asc[1]
        let freqIdx = Int(((b0 & 0x07) << 1) | ((b1 >> 7) & 0x01))
        var chanCfg = Int((b1 >> 3) & 0x0F)
        if chanCfg <= 0 || chanCfg > 8 { chanCfg = 2 }
        let sampleRates: [Float64] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let sr = (freqIdx < sampleRates.count) ? sampleRates[freqIdx] : 44100.0
        self.audioSampleRate = Int32(sr)
        var asbd = AudioStreamBasicDescription(
          mSampleRate: sr,
          mFormatID: kAudioFormatMPEG4AAC,
          mFormatFlags: 0,
          mBytesPerPacket: 0,
          mFramesPerPacket: 1024,
          mBytesPerFrame: 0,
          mChannelsPerFrame: UInt32(chanCfg),
          mBitsPerChannel: 0,
          mReserved: 0
        )
        var fmt: CMAudioFormatDescription? = nil
        asc.withUnsafeBytes { rawPtr in
          if let base = rawPtr.baseAddress {
            _ = CMAudioFormatDescriptionCreate(
              allocator: kCFAllocatorDefault,
              asbd: &asbd,
              layoutSize: 0,
              layout: nil,
              magicCookieSize: asc.count,
              magicCookie: base,
              extensions: nil,
              formatDescriptionOut: &fmt
            )
          }
        }
        if let validFmt = fmt {
          self.audioFormatDesc = validFmt
        }
      } else if pktType == 1, body.count > 2, let fmt = audioFormatDesc, lastVideoRawDtsMs >= 0 {
        let sr = max(8000, Int64(audioSampleRate))
        if lastAudioRawDtsMs < 0 {
          lastAudioRawDtsMs = dtsMs
          normAudioDtsMs = normVideoDtsMs
          if nextAudioSamplePts < 0 {
            nextAudioSamplePts = (max(0, normVideoDtsMs) * sr) / 1000
          }
        } else {
          var aDelta = dtsMs - lastAudioRawDtsMs
          if aDelta <= 0 || aDelta > 800 {
            aDelta = 21
          }
          lastAudioRawDtsMs = dtsMs
          normAudioDtsMs += aDelta
          let currentAudioMs = (nextAudioSamplePts * 1000) / sr
          if abs(currentAudioMs - normVideoDtsMs) > 1200 {
            normAudioDtsMs = normVideoDtsMs
            nextAudioSamplePts = (max(0, normVideoDtsMs) * sr) / 1000
          }
        }
        let samplePts = max(0, nextAudioSamplePts)
        nextAudioSamplePts = samplePts + 1024
        let rawAac = body.subdata(in: 2..<body.count)
        let len = rawAac.count
        guard len > 0 else { return }

        var blockBuf: CMBlockBuffer? = nil
        guard CMBlockBufferCreateWithMemoryBlock(
          allocator: kCFAllocatorDefault,
          memoryBlock: nil,
          blockLength: len,
          blockAllocator: kCFAllocatorDefault,
          customBlockSource: nil,
          offsetToData: 0,
          dataLength: len,
          flags: 0,
          blockBufferOut: &blockBuf
        ) == kCMBlockBufferNoErr, let bb = blockBuf else { return }

        rawAac.withUnsafeBytes { rawPtr in
          if let base = rawPtr.baseAddress {
            _ = CMBlockBufferReplaceDataBytes(
              with: base,
              blockBuffer: bb,
              offsetIntoDestination: 0,
              dataLength: len
            )
          }
        }

        var pktDesc = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(len))
        var sampleBuf: CMSampleBuffer? = nil
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
          allocator: kCFAllocatorDefault,
          dataBuffer: bb,
          formatDescription: fmt,
          sampleCount: 1,
          presentationTimeStamp: CMTime(value: samplePts, timescale: audioSampleRate),
          packetDescriptions: &pktDesc,
          sampleBufferOut: &sampleBuf
        ) == noErr, let sb = sampleBuf else { return }

        audioRenderer.enqueue(sb)
      }
    }
  }
}

// MARK: - Real-Time HTTP-FLV to MPEG-TS / HLS Remuxer (for 斗鱼一起看 / 虎牙一起看 / YY轮播 & FLV Live Streams on tvOS AVPlayer)

final class TvFlvToTsRemuxer {
  private var nalLengthSize: Int = 4
  private var spsPpsAnnexB = Data()
  private var adtsProfile: Int = 1
  private var adtsFreqIdx: Int = 4
  private var adtsChanCfg: Int = 2
  private var hasAudioConfig: Bool = false

  private var patCC: UInt8 = 0
  private var pmtCC: UInt8 = 0
  private var videoCC: UInt8 = 0
  private var audioCC: UInt8 = 0

  private(set) var currentSegment = Data()
  private var currentSegmentStartDts: Int64 = -1
  private var lastVideoRawDtsMs: Int64 = -1
  private var normalizedVideoDts90k: Int64 = 90_000
  private var lastAudioRawDtsMs: Int64 = -1
  private var normalizedAudioPts90k: Int64 = 90_000
  private var hasEmittedFirstSegment: Bool = false

  func resetSegment(atDts dts90k: Int64) {
    currentSegment.removeAll(keepingCapacity: true)
    currentSegmentStartDts = dts90k
    currentSegment.append(makePatPacket())
    currentSegment.append(makePmtPacket())
  }

  func feedFlvTag(tagType: UInt8, dtsMs: Int64, body: Data, onSegmentReady: (Data, Double) -> Void) {
    guard body.count >= 2 else { return }

    if tagType == 8 {
      let soundFmt = (body[0] >> 4) & 0x0F
      guard soundFmt == 10 else { return } // AAC
      let pktType = body[1]
      if pktType == 0, body.count >= 4 {
        let b0 = body[2], b1 = body[3]
        let objType = Int((b0 >> 3) & 0x1F)
        adtsFreqIdx = Int(((b0 & 0x07) << 1) | ((b1 >> 7) & 0x01))
        adtsChanCfg = Int((b1 >> 3) & 0x0F)
        if adtsChanCfg == 0 { adtsChanCfg = 2 }
        adtsProfile = (objType == 5 || objType == 29) ? 1 : max(0, min(3, objType - 1))
        hasAudioConfig = true
      } else if pktType == 1, hasAudioConfig, body.count > 2, currentSegmentStartDts >= 0, lastVideoRawDtsMs >= 0 {
        // Normalize audio PTS monotonically and keep it locked within 1.0s of normalizedVideoDts90k
        // (Douyu/Huya SCDN nodes often send stale sequence header timestamps or 31,900,000 ms DTS jumps)
        if lastAudioRawDtsMs < 0 {
          lastAudioRawDtsMs = dtsMs
          normalizedAudioPts90k = normalizedVideoDts90k
        } else {
          var aDeltaMs = dtsMs - lastAudioRawDtsMs
          if aDeltaMs <= 0 || aDeltaMs > 800 {
            aDeltaMs = 21
          }
          lastAudioRawDtsMs = dtsMs
          normalizedAudioPts90k += aDeltaMs * 90
          if abs(normalizedAudioPts90k - normalizedVideoDts90k) > 90_000 {
            normalizedAudioPts90k = normalizedVideoDts90k
          }
        }
        let relDts90k = max(currentSegmentStartDts, normalizedAudioPts90k)
        let rawAac = body.subdata(in: 2..<body.count)
        let frameLen = rawAac.count + 7
        var adts = Data(count: 7)
        adts[0] = 0xFF
        adts[1] = 0xF1
        adts[2] = UInt8(((adtsProfile & 0x03) << 6) | ((adtsFreqIdx & 0x0F) << 2) | ((adtsChanCfg >> 2) & 0x01))
        adts[3] = UInt8(((adtsChanCfg & 0x03) << 6) | ((frameLen >> 11) & 0x03))
        adts[4] = UInt8((frameLen >> 3) & 0xFF)
        adts[5] = UInt8(((frameLen & 0x07) << 5) | 0x1F)
        adts[6] = 0xFC
        var payload = adts
        payload.append(rawAac)
        let pes = makePesPacket(streamId: 0xC0, payload: payload, pts: relDts90k, dts: nil)
        packetizeIntoTs(pid: 0x0101, pes: pes, pcr: nil, isKeyframe: false, cc: &audioCC, into: &currentSegment)
      }
    } else if tagType == 9 {
      let frameType = (body[0] >> 4) & 0x0F
      let codecId = body[0] & 0x0F
      guard codecId == 7, body.count >= 5 else { return } // H.264 / AVC
      let pktType = body[1]
      var cts = (Int(body[2]) << 16) | (Int(body[3]) << 8) | Int(body[4])
      if (cts & 0x800000) != 0 { cts -= 0x1000000 }

      if pktType == 0, body.count >= 11 {
        nalLengthSize = Int(body[9] & 0x03) + 1
        var pos = 10
        var annexB = Data()
        let numSps = Int(body[pos] & 0x1F)
        pos += 1
        for _ in 0..<numSps {
          guard pos + 2 <= body.count else { break }
          let spsLen = (Int(body[pos]) << 8) | Int(body[pos + 1])
          pos += 2
          guard pos + spsLen <= body.count else { break }
          annexB.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
          annexB.append(body.subdata(in: pos..<(pos + spsLen)))
          pos += spsLen
        }
        if pos < body.count {
          let numPps = Int(body[pos])
          pos += 1
          for _ in 0..<numPps {
            guard pos + 2 <= body.count else { break }
            let ppsLen = (Int(body[pos]) << 8) | Int(body[pos + 1])
            pos += 2
            guard pos + ppsLen <= body.count else { break }
            annexB.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            annexB.append(body.subdata(in: pos..<(pos + ppsLen)))
            pos += ppsLen
          }
        }
        if !annexB.isEmpty {
          spsPpsAnnexB = annexB
        }
      } else if pktType == 1, body.count > 5, !spsPpsAnnexB.isEmpty {
        let isKeyframe = (frameType == 1)
        // Normalize video DTS via bounded frame-to-frame deltas so any 31,900,000 ms SCDN timestamp jump
        // or timestamp wraparound is clamped to a clean 40ms (25fps) increment!
        if lastVideoRawDtsMs < 0 {
          guard isKeyframe else { return }
          lastVideoRawDtsMs = dtsMs
          normalizedVideoDts90k = 90_000
        } else {
          var vDeltaMs = dtsMs - lastVideoRawDtsMs
          if vDeltaMs <= 0 || vDeltaMs > 1200 {
            vDeltaMs = 40
          }
          lastVideoRawDtsMs = dtsMs
          normalizedVideoDts90k += vDeltaMs * 90
        }
        let clampedCts = max(-500, min(1500, cts))
        let relDts90k = normalizedVideoDts90k
        let relPts90k = max(0, relDts90k + Int64(clampedCts) * 90)

        if currentSegmentStartDts < 0 {
          guard isKeyframe else { return }
          resetSegment(atDts: relDts90k)
        } else {
          let durSec = Double(relDts90k - currentSegmentStartDts) / 90_000.0
          // Emit the first two TS segments at ~1.0s each so `/flv_live.m3u8` has >= 2 segments ready within ~2.0s
          // (tvOS AVPlayer requires >= 2 segments in a live HLS playlist before entering `.readyToPlay`),
          // and subsequent segments at ~1.6s even when Douyu/Huya uses 8s–10s GOPs.
          let targetSegDur = hasEmittedFirstSegment ? 1.6 : 1.0
          if ((isKeyframe && durSec >= 0.85) || durSec >= targetSegDur) && !currentSegment.isEmpty {
            hasEmittedFirstSegment = true
            onSegmentReady(currentSegment, max(0.5, min(durSec, 6.0)))
            resetSegment(atDts: relDts90k)
          }
        }
        guard currentSegmentStartDts >= 0 else { return }

        var annexB = Data([0x00, 0x00, 0x00, 0x01, 0x09, 0xF0]) // H.264 AUD
        if isKeyframe || currentSegment.count <= 376 {
          annexB.append(spsPpsAnnexB)
        }
        var pos = 5
        var hasVideoNalu = false
        while pos + nalLengthSize <= body.count {
          var naluLen = 0
          for i in 0..<nalLengthSize {
            naluLen = (naluLen << 8) | Int(body[pos + i])
          }
          pos += nalLengthSize
          guard naluLen > 0, pos + naluLen <= body.count else { break }
          let naluType = body[pos] & 0x1F
          if naluType != 9 {
            annexB.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            annexB.append(body.subdata(in: pos..<(pos + naluLen)))
            hasVideoNalu = true
          }
          pos += naluLen
        }
        guard hasVideoNalu else { return }
        let pes = makePesPacket(streamId: 0xE0, payload: annexB, pts: relPts90k, dts: relDts90k)
        packetizeIntoTs(pid: 0x0100, pes: pes, pcr: relDts90k, isKeyframe: isKeyframe, cc: &videoCC, into: &currentSegment)
      }
    }
  }

  private func makePesPacket(streamId: UInt8, payload: Data, pts: Int64, dts: Int64?) -> Data {
    let hasDts = (dts != nil && dts! != pts)
    let ptsDtsFlags: UInt8 = hasDts ? 0xC0 : 0x80
    let headerDataLen: UInt8 = hasDts ? 10 : 5
    let totalPesLen = Int(headerDataLen) + 3 + payload.count
    let pesPacketLen: UInt16 = (streamId == 0xE0 || totalPesLen > 65535) ? 0 : UInt16(totalPesLen)

    var out = Data(capacity: 9 + Int(headerDataLen) + payload.count)
    out.append(contentsOf: [0x00, 0x00, 0x01, streamId])
    out.append(UInt8((pesPacketLen >> 8) & 0xFF))
    out.append(UInt8(pesPacketLen & 0xFF))
    out.append(0x80)
    out.append(ptsDtsFlags)
    out.append(headerDataLen)
    out.append(encodeTimestamp(prefix: hasDts ? 0x30 : 0x20, ts: pts))
    if let d = dts, hasDts {
      out.append(encodeTimestamp(prefix: 0x10, ts: d))
    }
    out.append(payload)
    return out
  }

  private func encodeTimestamp(prefix: UInt8, ts: Int64) -> Data {
    let v = UInt64(ts) & 0x1FFFFFFFF
    var b = Data(count: 5)
    b[0] = prefix | UInt8(((v >> 30) & 0x07) << 1) | 0x01
    b[1] = UInt8((v >> 22) & 0xFF)
    b[2] = UInt8(((v >> 15) & 0x7F) << 1) | 0x01
    b[3] = UInt8((v >> 7) & 0xFF)
    b[4] = UInt8((v & 0x7F) << 1) | 0x01
    return b
  }

  private func packetizeIntoTs(pid: UInt16, pes: Data, pcr: Int64?, isKeyframe: Bool, cc: inout UInt8, into out: inout Data) {
    var offset = 0
    var first = true
    while offset < pes.count {
      var pkt = Data(repeating: 0xFF, count: 188)
      pkt[0] = 0x47
      pkt[1] = (first ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1F)
      pkt[2] = UInt8(pid & 0xFF)

      var headerLen = 4
      var needAdaptation = false
      var adaptFlags: UInt8 = 0
      var pcrBytes: Data? = nil

      if first && (pcr != nil || isKeyframe) {
        needAdaptation = true
        if isKeyframe { adaptFlags |= 0x40 }
        if let pcrVal = pcr {
          adaptFlags |= 0x10
          var pb = Data(count: 6)
          let base = UInt64(max(0, pcrVal)) & 0x1FFFFFFFF
          pb[0] = UInt8((base >> 25) & 0xFF)
          pb[1] = UInt8((base >> 17) & 0xFF)
          pb[2] = UInt8((base >> 9) & 0xFF)
          pb[3] = UInt8((base >> 1) & 0xFF)
          pb[4] = UInt8(((base & 0x01) << 7) | 0x7E)
          pb[5] = 0x00
          pcrBytes = pb
        }
      }

      let minAdaptLen = needAdaptation ? (1 + (pcrBytes?.count ?? 0)) : 0
      let maxPayloadAfterMinAdapt = 188 - 4 - (needAdaptation ? (1 + minAdaptLen) : 0)
      let remainingPes = pes.count - offset

      if remainingPes < maxPayloadAfterMinAdapt {
        needAdaptation = true
        let targetPayload = remainingPes
        let totalAdaptField = 188 - 4 - targetPayload
        let adaptLen = totalAdaptField - 1
        pkt[3] = 0x30 | (cc & 0x0F)
        pkt[4] = UInt8(adaptLen)
        if adaptLen >= 1 {
          pkt[5] = adaptFlags
          if let pb = pcrBytes, adaptLen >= 1 + pb.count {
            pkt.replaceSubrange(6..<(6 + pb.count), with: pb)
          }
        }
        headerLen = 4 + totalAdaptField
      } else if needAdaptation {
        pkt[3] = 0x30 | (cc & 0x0F)
        pkt[4] = UInt8(minAdaptLen)
        pkt[5] = adaptFlags
        if let pb = pcrBytes {
          pkt.replaceSubrange(6..<(6 + pb.count), with: pb)
        }
        headerLen = 4 + 1 + minAdaptLen
      } else {
        pkt[3] = 0x10 | (cc & 0x0F)
        headerLen = 4
      }

      cc = (cc + 1) & 0x0F
      let copyLen = min(188 - headerLen, remainingPes)
      pkt.replaceSubrange(headerLen..<(headerLen + copyLen), with: pes.subdata(in: offset..<(offset + copyLen)))
      offset += copyLen
      first = false
      out.append(pkt)
    }
  }

  private func makePatPacket() -> Data {
    var pkt = Data(repeating: 0xFF, count: 188)
    pkt[0] = 0x47
    pkt[1] = 0x40
    pkt[2] = 0x00
    pkt[3] = 0x10 | (patCC & 0x0F)
    patCC = (patCC + 1) & 0x0F
    pkt[4] = 0x00
    let section: [UInt8] = [
      0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00,
      0x00, 0x01, 0xF0, 0x00
    ]
    let crc = crc32Mpeg2(section)
    pkt.replaceSubrange(5..<(5 + section.count), with: section)
    pkt[5 + section.count] = UInt8((crc >> 24) & 0xFF)
    pkt[6 + section.count] = UInt8((crc >> 16) & 0xFF)
    pkt[7 + section.count] = UInt8((crc >> 8) & 0xFF)
    pkt[8 + section.count] = UInt8(crc & 0xFF)
    return pkt
  }

  private func makePmtPacket() -> Data {
    var pkt = Data(repeating: 0xFF, count: 188)
    pkt[0] = 0x47
    pkt[1] = 0x50
    pkt[2] = 0x00
    pkt[3] = 0x10 | (pmtCC & 0x0F)
    pmtCC = (pmtCC + 1) & 0x0F
    pkt[4] = 0x00
    let section: [UInt8] = [
      0x02, 0xB0, 0x17, 0x00, 0x01, 0xC1, 0x00, 0x00,
      0xE1, 0x00, 0xF0, 0x00,
      0x1B, 0xE1, 0x00, 0xF0, 0x00,
      0x0F, 0xE1, 0x01, 0xF0, 0x00
    ]
    let crc = crc32Mpeg2(section)
    pkt.replaceSubrange(5..<(5 + section.count), with: section)
    pkt[5 + section.count] = UInt8((crc >> 24) & 0xFF)
    pkt[6 + section.count] = UInt8((crc >> 16) & 0xFF)
    pkt[7 + section.count] = UInt8((crc >> 8) & 0xFF)
    pkt[8 + section.count] = UInt8(crc & 0xFF)
    return pkt
  }

  private func crc32Mpeg2(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    for b in bytes {
      crc ^= UInt32(b) << 24
      for _ in 0..<8 {
        if (crc & 0x80000000) != 0 {
          crc = (crc << 1) ^ 0x04C11DB7
        } else {
          crc <<= 1
        }
      }
    }
    return crc
  }
}

final class TvLiveFlvSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()
  private var cursor = 0
  private var headerSkipped = false
  private var remuxer = TvFlvToTsRemuxer()
  private var segments: [(seq: Int, dur: Double, data: Data)] = []
  private var nextSeq = 1
  private var task: URLSessionDataTask?
  private var session: URLSession?
  private var isStopped = false
  private var initialUrl: URL?
  private var initialHeaders: [String: String] = [:]
  private var fallbackUrl: URL?
  private var fallbackHeaders: [String: String] = [:]
  private var retryCount = 0

  func start(
    url: URL,
    headers: [String: String],
    fallbackUrl: URL? = nil,
    fallbackHeaders: [String: String] = [:]
  ) {
    lock.lock()
    self.initialUrl = url
    self.initialHeaders = headers
    self.fallbackUrl = fallbackUrl
    self.fallbackHeaders = fallbackHeaders
    self.retryCount = 0
    lock.unlock()
    launchRequest(url: url, headers: headers)
  }

  private func launchRequest(url: URL, headers: [String: String], forceDirect: Bool = false, forceProxy: Bool = false) {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = forceProxy ? 7.5 : 4.2
    cfg.timeoutIntervalForResource = 7200
    cfg.httpShouldSetCookies = true
    let urlLower = url.absoluteString.lowercased()
    let isDomesticCdn = !forceProxy && (
      forceDirect
      || TvLocalHlsProxyServer.isDomesticOrLocalUrl(urlLower)
      || urlLower.contains("douyucdn")
      || urlLower.contains("douyu")
      || urlLower.contains("huya.com")
      || urlLower.contains("msstatic.com")
      || urlLower.contains("yy.com")
      || urlLower.contains(".flv")
    )
    if forceProxy, let proxyDict = TvLocalProxyTunnelServer.shared.proxyConnectionDictionary(allowFallbackNode: true) {
      cfg.connectionProxyDictionary = proxyDict
    } else if !isDomesticCdn,
              TvLocalProxyTunnelServer.shared.isProxyActive,
              let proxyDict = TvLocalProxyTunnelServer.shared.proxyConnectionDictionary() {
      cfg.connectionProxyDictionary = proxyDict
    }
    let sess = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    for (k, v) in headers where !v.isEmpty {
      req.setValue(v, forHTTPHeaderField: k)
    }
    if req.value(forHTTPHeaderField: "User-Agent") == nil {
      req.setValue("okHttp/Mod-1.5.0.0", forHTTPHeaderField: "User-Agent")
    }
    let t = sess.dataTask(with: req)
    lock.lock()
    guard !isStopped else {
      lock.unlock()
      sess.invalidateAndCancel()
      return
    }
    let oldTask = self.task
    let oldSess = self.session
    self.buffer.removeAll(keepingCapacity: true)
    self.cursor = 0
    self.headerSkipped = false
    self.remuxer = TvFlvToTsRemuxer()
    self.task = t
    self.session = sess
    lock.unlock()
    oldTask?.cancel()
    oldSess?.invalidateAndCancel()
    t.resume()
  }

  private func scheduleRetryLocked() {
    guard !isStopped, retryCount < 4 else { return }
    retryCount += 1
    let attempt = retryCount
    let hasDistinctFallback = (fallbackUrl != nil && fallbackUrl != initialUrl)
    // Attempt 1: If direct connection to initialUrl timed out (e.g. overseas SCDN IP 183.239.202.x:8080 unreachable from local ISP)
    // and we have a client proxy tunnel node available, immediately try initialUrl via the proxy tunnel (1:1 match with Flutter's LocalProxyTunnelBridge)!
    // Attempt 2: Try fallbackUrl (e.g. mursor.ottiptv.cc gateway) directly.
    // Attempt 3: Try fallbackUrl via proxy tunnel (which auto-switches to direct on 301/302 redirect to domestic CDN!).
    // Attempt 4: Final direct retry on initialUrl.
    let nextUrl: URL
    let nextHeaders: [String: String]
    let useProxy: Bool
    let useForceDirect: Bool

    switch attempt {
    case 1:
      if TvLocalProxyTunnelServer.shared.hasAvailableTunnelNode {
        nextUrl = initialUrl ?? fallbackUrl!
        nextHeaders = initialHeaders
        useProxy = true
        useForceDirect = false
      } else if hasDistinctFallback, let fb = fallbackUrl {
        nextUrl = fb
        nextHeaders = fallbackHeaders
        useProxy = false
        useForceDirect = true
      } else if let initUrl = initialUrl {
        nextUrl = initUrl
        nextHeaders = initialHeaders
        useProxy = false
        useForceDirect = true
      } else {
        return
      }
    case 2:
      if hasDistinctFallback, let fb = fallbackUrl {
        nextUrl = fb
        nextHeaders = fallbackHeaders
        useProxy = false
        useForceDirect = true
      } else if let initUrl = initialUrl {
        nextUrl = initUrl
        nextHeaders = initialHeaders
        useProxy = TvLocalProxyTunnelServer.shared.hasAvailableTunnelNode
        useForceDirect = !useProxy
      } else {
        return
      }
    case 3:
      if hasDistinctFallback, let fb = fallbackUrl, TvLocalProxyTunnelServer.shared.hasAvailableTunnelNode {
        nextUrl = fb
        nextHeaders = fallbackHeaders
        useProxy = true
        useForceDirect = false
      } else if let initUrl = initialUrl {
        nextUrl = initUrl
        nextHeaders = initialHeaders
        useProxy = false
        useForceDirect = true
      } else {
        return
      }
    default:
      guard let initUrl = initialUrl else { return }
      nextUrl = initUrl
      nextHeaders = initialHeaders
      useProxy = false
      useForceDirect = true
    }

    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.08) { [weak self] in
      guard let self else { return }
      self.launchRequest(url: nextUrl, headers: nextHeaders, forceDirect: useForceDirect, forceProxy: useProxy)
    }
  }

  func stop() {
    lock.lock()
    isStopped = true
    let t = task
    let s = session
    task = nil
    session = nil
    segments.removeAll()
    buffer.removeAll()
    lock.unlock()
    t?.cancel()
    s?.invalidateAndCancel()
  }

  func snapshotSegments() -> [(seq: Int, dur: Double, data: Data)] {
    lock.lock()
    defer { lock.unlock() }
    return segments
  }

  func segmentData(seq: Int) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return segments.first(where: { $0.seq == seq })?.data
  }

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

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    var req = request
    lock.lock()
    let hdrs = initialHeaders
    lock.unlock()
    for (k, v) in hdrs where !v.isEmpty {
      req.setValue(v, forHTTPHeaderField: k)
    }
    if let redirectedHost = req.url?.host,
       let target = req.url {
      let rLower = target.absoluteString.lowercased()
      if TvLocalHlsProxyServer.isDomesticOrLocalUrl(rLower)
          || redirectedHost.lowercased().contains("douyucdn")
          || redirectedHost.lowercased().contains("huya.com")
          || redirectedHost.lowercased().contains("yy.com")
          || rLower.contains(".flv") {
        // Redirected from gateway (e.g. mursor.ottiptv.cc) to a domestic Douyu/Huya CDN stream:
        // update initialUrl to the resolved CDN URL and connect directly first (with automatic proxy fallback on retry)!
        completionHandler(nil)
        var followHeaders = hdrs
        if let cookie = response.value(forHTTPHeaderField: "Set-Cookie"), !cookie.isEmpty, followHeaders["Cookie"] == nil {
          followHeaders["Cookie"] = cookie
        }
        lock.lock()
        self.initialUrl = target
        self.initialHeaders = followHeaders
        self.retryCount = 0
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
          self?.launchRequest(url: target, headers: followHeaders, forceDirect: true, forceProxy: false)
        }
        return
      }
    }
    completionHandler(req)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
      completionHandler(.cancel)
      lock.lock()
      if dataTask === self.task {
        scheduleRetryLocked()
      }
      lock.unlock()
      return
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard error != nil else { return }
    lock.lock()
    if task === self.task, segments.isEmpty {
      scheduleRetryLocked()
    }
    lock.unlock()
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    TvNetworkSpeedMonitor.shared.recordDownstreamBytes(data.count)
    lock.lock()
    defer { lock.unlock() }
    guard !isStopped, dataTask === self.task else { return }
    buffer.append(data)
    if !headerSkipped {
      if buffer.count - cursor >= 13 {
        guard buffer[cursor] == 0x46, buffer[cursor + 1] == 0x4C, buffer[cursor + 2] == 0x56 else {
          dataTask.cancel()
          scheduleRetryLocked()
          return
        }
        let h0 = Int(buffer[cursor + 5]) << 24
        let h1 = Int(buffer[cursor + 6]) << 16
        let h2 = Int(buffer[cursor + 7]) << 8
        let h3 = Int(buffer[cursor + 8])
        let headerOffset = h0 | h1 | h2 | h3
        if buffer.count - cursor >= headerOffset + 4 {
          cursor += headerOffset + 4
          headerSkipped = true
        }
      }
      if !headerSkipped { return }
    }
    while buffer.count - cursor >= 11 {
      let tagType = buffer[cursor]
      let dataSize = (Int(buffer[cursor + 1]) << 16) | (Int(buffer[cursor + 2]) << 8) | Int(buffer[cursor + 3])
      let totalNeeded = 11 + dataSize + 4
      if buffer.count - cursor < totalNeeded { break }
      let dtsLow = (Int(buffer[cursor + 4]) << 16) | (Int(buffer[cursor + 5]) << 8) | Int(buffer[cursor + 6])
      let dtsExt = Int(buffer[cursor + 7]) << 24
      let dtsMs = Int64(dtsLow | dtsExt)
      let body = buffer.subdata(in: (cursor + 11)..<(cursor + 11 + dataSize))
      cursor += totalNeeded
      remuxer.feedFlvTag(tagType: tagType, dtsMs: dtsMs, body: body) { segData, dur in
        let seq = self.nextSeq
        self.nextSeq += 1
        self.segments.append((seq: seq, dur: dur, data: segData))
        if self.segments.count > 12 {
          self.segments.removeFirst(self.segments.count - 12)
        }
      }
    }
    if cursor > 262144 {
      buffer.removeSubrange(0..<cursor)
      cursor = 0
    }
  }
}

final class TvLocalHlsProxyServer: @unchecked Sendable {
  static let shared = TvLocalHlsProxyServer()

  private var listener: NWListener?
  private(set) var port: UInt16 = 0
  private let queue = DispatchQueue(label: "tv.liuguang.hls.proxy", qos: .userInitiated, attributes: .concurrent)
  private let store = TvHlsSegmentCacheActor()
  private let directUrlSession: URLSession
  private var cachedProxyUrlSession: URLSession? = nil
  private var cachedProxyPort: UInt16 = 0
  private var cachedProxyRevision: UInt64 = 0
  private let sessionLock = NSLock()
  private let flvLock = NSLock()
  private var activeFlvSession: TvLiveFlvSession? = nil
  private var activeFlvGeneration: Int = 0
  private let tgLock = NSLock()
  private var tgHeadersByUrl: [String: [String: String]] = [:]
  private var tgHeaderOrder: [String] = []
  private var tgPlaybackReaderByUrl: [String: UUID] = [:]
  private var tgRangeUnsupported = Set<String>()
  private var tgPassthroughTasks: [String: [UUID: Task<Bool, Never>]] = [:]
  private var tgVideoMetaCache: [String: (totalSize: Int64, contentType: String, headerChunk: Data, stripPrefixBytes: Int)] = [:]
  private var tgMetaOrder: [String] = []
  private var tgMetaInFlight: [String: Task<(totalSize: Int64, contentType: String, headerChunk: Data, stripPrefixBytes: Int)?, Never>] = [:]
  private static let tgBlockSize: Int64 = 2_097_152 // 2 MB block size -> 3.43+ MB/s sustained throughput across 6 workers
  private static let tgMaxCachedBlocks: Int = 36 // 36 x 2 MB = 72 MB shared in-memory LRU stitch cache
  private static let tgMaxConcurrentPrefetchPerUrl = 3
  private static let tgLookaheadBlocks = 8
  private var tgBlockCache: [String: Data] = [:]
  private var tgBlockOrder: [String] = []
  private var tgInFlightBlocks: [String: Task<Data?, Never>] = [:]
  private var tgInFlightIsPrefetch: [String: Bool] = [:]
  private var tgActivePrefetchCountByUrl: [String: Int] = [:]
  private var tgPreferDirectByUrl: [String: Date] = [:]
  private var tgPlayheadBlockByUrl: [String: Int64] = [:]
  private var tgLastAccessByUrl: [String: Date] = [:]
  private var tgActiveBackgroundUrl: String = ""

  private var urlSession: URLSession {
    let isProxyActive = TvLocalProxyTunnelServer.shared.isProxyActive
    let curPort = TvLocalProxyTunnelServer.shared.port
    let curRev = TvLocalProxyTunnelServer.shared.configRevision
    sessionLock.lock()
    defer { sessionLock.unlock() }
    guard isProxyActive else {
      cachedProxyUrlSession?.finishTasksAndInvalidate()
      cachedProxyUrlSession = nil
      return directUrlSession
    }
    if let existing = cachedProxyUrlSession, cachedProxyPort == curPort, cachedProxyRevision == curRev {
      return existing
    }
    cachedProxyUrlSession?.finishTasksAndInvalidate()
    let fresh = TvLocalProxyTunnelServer.shared.makeProxiedUrlSession(timeoutRequest: 10, timeoutResource: 22)
    cachedProxyUrlSession = fresh
    cachedProxyPort = curPort
    cachedProxyRevision = curRev
    return fresh
  }

  nonisolated static func isDomesticOrLocalUrl(_ urlStr: String) -> Bool {
    let lower = urlStr.lowercased()
    return lower.contains("115.com")
      || lower.contains("115cdn")
      || lower.contains("115vod")
      || lower.contains("anxia.com")
      || lower.contains("baidupcs")
      || lower.contains("aliyundrive")
      || lower.contains("alipan")
      || lower.contains("://192.168.")
      || lower.contains("://10.")
      || lower.contains("://172.")
      || lower.contains("://127.0.0.1")
      || lower.contains("://localhost")
      || lower.contains(".local")
  }

  /// Domestic cloud drives (115 / Baidu / Aliyun) and local LAN storage (AList / WebDAV) bind download tickets to domestic/local IP
  /// and must bypass the overseas proxy tunnel (`directUrlSession`).
  private func preferredSession(for targetUrl: String) -> URLSession {
    if Self.isDomesticOrLocalUrl(targetUrl) {
      return directUrlSession
    }
    return urlSession
  }

  private init() {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 10
    cfg.timeoutIntervalForResource = 22
    cfg.httpMaximumConnectionsPerHost = 32
    cfg.httpShouldSetCookies = true
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    self.directUrlSession = URLSession(configuration: cfg, delegate: InsecureSessionDelegate(), delegateQueue: nil)
    startListenerIfNeeded()
  }

  private func startListenerIfNeeded() {
    if let existing = listener {
      if case .ready = existing.state, port > 0 {
        return
      }
      existing.cancel()
      listener = nil
      port = 0
    }
    do {
      let nwListener = try NWListener(using: .tcp, on: .any)
      nwListener.stateUpdateHandler = { [weak self] state in
        switch state {
        case .ready:
          if let p = nwListener.port?.rawValue, p > 0 {
            self?.port = p
          }
        case .failed, .cancelled:
          self?.port = 0
          self?.listener = nil
        default:
          break
        }
      }
      nwListener.newConnectionHandler = { [weak self] conn in
        self?.handleConnection(conn)
      }
      nwListener.start(queue: queue)
      self.listener = nwListener
    } catch {}
  }

  func handleEnterBackground() {
    stopActiveFlvSession()
    listener?.cancel()
    listener = nil
    port = 0
    Task {
      _ = await store.configureSession(gatewayUrl: "", resolvedUrl: "", headers: [:])
    }
  }

  func handleEnterForeground() {
    urlSession.flush {}
    startListenerIfNeeded()
  }

  func prepareProxyPlaylistUrl(gatewayUrl: String, resolvedUrl: String, headers: [String: String]) async -> String? {
    startListenerIfNeeded()
    for _ in 0..<25 {
      if port > 0 { break }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    guard port > 0 else { return nil }
    stopActiveFlvSession()
    let gen = await store.configureSession(gatewayUrl: gatewayUrl, resolvedUrl: resolvedUrl, headers: headers)
    return "http://127.0.0.1:\(port)/live.m3u8?gen=\(gen)"
  }

  func currentUpstreamConfig() async -> (gatewayUrl: String, streamUrl: String, headers: [String: String]) {
    let cfg = await store.currentConfig()
    return (cfg.gatewayUrl, cfg.streamUrl, cfg.headers)
  }

  func prepareFlvProxyPlaylistUrl(
    targetUrl: String,
    headers: [String: String],
    fallbackUrl: String = "",
    fallbackHeaders: [String: String] = [:]
  ) async -> String? {
    startListenerIfNeeded()
    for _ in 0..<25 {
      if port > 0 { break }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    guard port > 0, let u = URL(string: targetUrl) else { return nil }
    let fbUrl = fallbackUrl.isEmpty ? nil : URL(string: fallbackUrl)
    let gen = startNewFlvSession(url: u, headers: headers, fallbackUrl: fbUrl, fallbackHeaders: fallbackHeaders)
    return "http://127.0.0.1:\(port)/flv_live.m3u8?gen=\(gen)"
  }

  /// Creates a relay URL scoped to one playback and its authentication headers.
  func prepareTelegramVideoProxyUrl(
    remoteUrl: String,
    headers: [String: String],
    extHint: String = ".mp4"
  ) -> String {
    startListenerIfNeeded()
    guard port > 0 else { return remoteUrl }
    let playbackId = UUID().uuidString
    let key = "\(remoteUrl)#\(playbackId)"
    var cleanHeaders = headers.filter { !$0.value.isEmpty }
    if remoteUrl.lowercased().contains("115cdn") || remoteUrl.lowercased().contains("115.com") {
      let full115Cookie = TvM115AuthCookieStore.shared.cookieHeader(forUrl: remoteUrl)
      if !full115Cookie.isEmpty {
        cleanHeaders["Cookie"] = full115Cookie
      }
      if cleanHeaders["User-Agent"] == nil {
        cleanHeaders["User-Agent"] = TvM115AuthCookieStore.browserUserAgent
      }
      if cleanHeaders["Referer"] == nil {
        cleanHeaders["Referer"] = "https://115.com/"
      }
    }
    tgLock.lock()
    tgHeadersByUrl[key] = cleanHeaders
    tgHeaderOrder.append(key)
    while tgHeaderOrder.count > 64,
          let index = tgHeaderOrder.firstIndex(where: { tgVideoMetaCache[$0] == nil && tgMetaInFlight[$0] == nil }) {
      tgHeadersByUrl.removeValue(forKey: tgHeaderOrder.remove(at: index))
    }
    tgLock.unlock()
    var cleanExt = extHint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if cleanExt.isEmpty {
      let pathExt = ((URL(string: remoteUrl)?.path ?? "") as NSString).pathExtension.lowercased()
      if !pathExt.isEmpty && pathExt.count <= 5 {
        cleanExt = ".\(pathExt)"
      }
    }
    if cleanExt.isEmpty || !cleanExt.hasPrefix(".") {
      cleanExt = cleanExt.isEmpty ? ".mp4" : ".\(cleanExt)"
    }
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=?#")
    let enc = remoteUrl.addingPercentEncoding(withAllowedCharacters: allowed) ?? remoteUrl
    return "http://127.0.0.1:\(port)/tg_video\(cleanExt)?u=\(enc)&playback=\(playbackId)"
  }

  func releaseTelegramVideoProxyUrl(_ url: URL) {
    guard url.host == "127.0.0.1", url.path.hasPrefix("/tg_video"),
          let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
          let remoteUrl = query.first(where: { $0.name == "u" })?.value,
          let playbackId = query.first(where: { $0.name == "playback" })?.value else { return }
    let key = "\(remoteUrl)#\(playbackId)"
    let prefix = "\(key)#"
    tgLock.lock()
    tgHeadersByUrl.removeValue(forKey: key)
    tgHeaderOrder.removeAll { $0 == key }
    tgPlaybackReaderByUrl.removeValue(forKey: key)
    tgRangeUnsupported.remove(key)
    let passthrough = tgPassthroughTasks.removeValue(forKey: key)
    tgVideoMetaCache.removeValue(forKey: key)
    tgMetaOrder.removeAll { $0 == key }
    let probe = tgMetaInFlight.removeValue(forKey: key)
    var blockTasks: [Task<Data?, Never>] = []
    for blockKey in tgInFlightBlocks.keys.filter({ $0.hasPrefix(prefix) }) {
      if let task = tgInFlightBlocks.removeValue(forKey: blockKey) {
        blockTasks.append(task)
      }
      tgInFlightIsPrefetch.removeValue(forKey: blockKey)
    }
    for blockKey in tgBlockOrder.filter({ $0.hasPrefix(prefix) }) {
      tgBlockCache.removeValue(forKey: blockKey)
    }
    tgBlockOrder.removeAll { $0.hasPrefix(prefix) }
    tgPlayheadBlockByUrl.removeValue(forKey: key)
    tgLastAccessByUrl.removeValue(forKey: key)
    tgActivePrefetchCountByUrl.removeValue(forKey: key)
    tgPreferDirectByUrl.removeValue(forKey: key)
    if tgActiveBackgroundUrl == key { tgActiveBackgroundUrl = "" }
    tgLock.unlock()
    probe?.cancel()
    for task in blockTasks { task.cancel() }
    if let passthrough {
      for task in passthrough.values { task.cancel() }
    }
  }

  private static func inferMediaMimeType(pathOrUrl: String) -> String? {
    let lower = pathOrUrl.lowercased()
    if lower.hasSuffix(".mp3") { return "audio/mpeg" }
    if lower.hasSuffix(".flac") { return "audio/flac" }
    if lower.hasSuffix(".wav") { return "audio/wav" }
    if lower.hasSuffix(".m4a") || lower.hasSuffix(".alac") { return "audio/mp4" }
    if lower.hasSuffix(".aac") { return "audio/aac" }
    if lower.hasSuffix(".ogg") || lower.hasSuffix(".opus") { return "audio/ogg" }
    if lower.hasSuffix(".aiff") || lower.hasSuffix(".aif") { return "audio/aiff" }
    if lower.hasSuffix(".wma") { return "audio/x-ms-wma" }
    if lower.hasSuffix(".ape") { return "audio/x-ape" }
    if lower.hasSuffix(".mp4") || lower.hasSuffix(".m4v") { return "video/mp4" }
    if lower.hasSuffix(".mov") { return "video/quicktime" }
    return nil
  }

  private func getTgHeadersAndMeta(
    for targetUrl: String
  ) -> (headers: [String: String], meta: (totalSize: Int64, contentType: String, headerChunk: Data, stripPrefixBytes: Int)?) {
    tgLock.lock()
    defer { tgLock.unlock() }
    let hdrs = tgHeadersByUrl[targetUrl] ?? [:]
    let meta = tgVideoMetaCache[targetUrl]
    return (hdrs, meta)
  }

  private func storeTgMeta(
    _ resolved: (totalSize: Int64, contentType: String, headerChunk: Data, stripPrefixBytes: Int),
    for targetUrl: String
  ) {
    tgLock.lock()
    defer { tgLock.unlock() }
    guard tgHeadersByUrl[targetUrl] != nil else { return }
    if tgVideoMetaCache[targetUrl] == nil {
      tgMetaOrder.append(targetUrl)
      if tgMetaOrder.count > 24 {
        let old = tgMetaOrder.removeFirst()
        tgVideoMetaCache.removeValue(forKey: old)
      }
    }
    tgVideoMetaCache[targetUrl] = resolved
  }

  /// Normalizes WAV and lossless audio headers for tvOS AVPlayer (`CoreAudio`):
  /// 1) Strips any leading `ID3v2` tag prepended before `RIFF....WAVE` or `fLaC` so `RIFF` starts at byte offset 0.
  /// 2) Auto-detects misnamed `fLaC` or `MP3` files carrying a `.wav` extension and returns their real MIME type.
  /// 3) Fixes bogus `0xFFFFFFFF` / `0` RIFF and `data` chunk sizes in streaming/unfinalized WAV headers.
  /// 4) Converts `WAVE_FORMAT_EXTENSIBLE` (`0xFFFE`) with PCM (`0x0001`) or IEEE Float (`0x0003`) SubFormat GUID to standard PCM/Float (`0x0001`/`0x0003`) so tvOS `AVPlayer` natively decodes 24-bit/32-bit/multi-channel `.wav` files.
  private static func normalizeWavOrAudioHeaderChunk(
    rawChunk: Data,
    rawTotalSize: Int64,
    defaultContentType: String
  ) -> (headerChunk: Data, stripPrefixBytes: Int, effectiveTotalSize: Int64, contentType: String) {
    var bytes = [UInt8](rawChunk)
    var stripPrefix = 0
    var contentType = defaultContentType

    if bytes.count < 16 {
      return (rawChunk, 0, rawTotalSize, contentType)
    }

    // 1. Check for leading ID3v2 tag (`"ID3"`) before `RIFF....WAVE` or `fLaC`
    if bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33 && bytes.count >= 10 {
      let id3Flags = Int(bytes[5])
      let id3Size = ((Int(bytes[6]) & 0x7F) << 21)
        | ((Int(bytes[7]) & 0x7F) << 14)
        | ((Int(bytes[8]) & 0x7F) << 7)
        | (Int(bytes[9]) & 0x7F)
      let footerLen = (id3Flags & 0x10) != 0 ? 10 : 0
      var tagTotal = 10 + id3Size + footerLen
      if tagTotal > 10 && tagTotal + 16 <= bytes.count {
        while tagTotal + 12 < bytes.count && bytes[tagTotal] == 0x00 {
          tagTotal += 1
        }
        if bytes[tagTotal] == 0x52 && bytes[tagTotal + 1] == 0x49 &&
            bytes[tagTotal + 2] == 0x46 && bytes[tagTotal + 3] == 0x46 &&
            bytes[tagTotal + 8] == 0x57 && bytes[tagTotal + 9] == 0x41 &&
            bytes[tagTotal + 10] == 0x56 && bytes[tagTotal + 11] == 0x45 {
          stripPrefix = tagTotal
          bytes = Array(bytes[tagTotal...])
          contentType = "audio/wav"
        } else if bytes[tagTotal] == 0x66 && bytes[tagTotal + 1] == 0x4C &&
            bytes[tagTotal + 2] == 0x61 && bytes[tagTotal + 3] == 0x43 {
          stripPrefix = tagTotal
          bytes = Array(bytes[tagTotal...])
          contentType = "audio/flac"
        }
      }
    }

    let effectiveTotal = max(Int64(bytes.count), rawTotalSize - Int64(stripPrefix))

    // 2. Detect true container magic if a `.wav` file is actually FLAC or MP3
    if bytes.count >= 4 {
      if bytes[0] == 0x66 && bytes[1] == 0x4C && bytes[2] == 0x61 && bytes[3] == 0x43 {
        contentType = "audio/flac"
        return (Data(bytes), stripPrefix, effectiveTotal, contentType)
      }
      if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) ||
          (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) {
        if contentType == "audio/wav" {
          contentType = "audio/mpeg"
        }
        return (Data(bytes), stripPrefix, effectiveTotal, contentType)
      }
    }

    // 3. Inspect and sanitize `RIFF....WAVE` header
    if bytes.count >= 44 &&
        bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
        bytes[8] == 0x57 && bytes[9] == 0x41 && bytes[10] == 0x56 && bytes[11] == 0x45 {
      contentType = "audio/wav"
      let riffChunkSize = UInt32(bytes[4])
        | (UInt32(bytes[5]) << 8)
        | (UInt32(bytes[6]) << 16)
        | (UInt32(bytes[7]) << 24)
      let expectedRiffSize = effectiveTotal > 8
        ? UInt32(clamping: min(effectiveTotal - 8, 0xFFFFFFF0))
        : 0
      if expectedRiffSize > 36 &&
          (riffChunkSize == 0 || riffChunkSize == 0xFFFFFFFF || riffChunkSize == 0x7FFFFFFF) {
        bytes[4] = UInt8(expectedRiffSize & 0xFF)
        bytes[5] = UInt8((expectedRiffSize >> 8) & 0xFF)
        bytes[6] = UInt8((expectedRiffSize >> 16) & 0xFF)
        bytes[7] = UInt8((expectedRiffSize >> 24) & 0xFF)
      }

      var pos = 12
      while pos + 8 <= bytes.count {
        let c0 = bytes[pos]
        let c1 = bytes[pos + 1]
        let c2 = bytes[pos + 2]
        let c3 = bytes[pos + 3]
        let cSize = Int(UInt32(bytes[pos + 4])
          | (UInt32(bytes[pos + 5]) << 8)
          | (UInt32(bytes[pos + 6]) << 16)
          | (UInt32(bytes[pos + 7]) << 24))

        // `fmt ` chunk (`66 6D 74 20`)
        if c0 == 0x66 && c1 == 0x6D && c2 == 0x74 && c3 == 0x20 {
          if pos + 8 + 16 <= bytes.count {
            let formatTag = Int(bytes[pos + 8]) | (Int(bytes[pos + 9]) << 8)
            let channels = Int(bytes[pos + 10]) | (Int(bytes[pos + 11]) << 8)
            let blockAlign = Int(bytes[pos + 20]) | (Int(bytes[pos + 21]) << 8)
            var bitsPerSample = Int(bytes[pos + 22]) | (Int(bytes[pos + 23]) << 8)
            if bitsPerSample == 0 && channels > 0 && blockAlign > 0 {
              bitsPerSample = (blockAlign * 8) / channels
              if bitsPerSample > 0 && bitsPerSample <= 64 {
                bytes[pos + 22] = UInt8(bitsPerSample & 0xFF)
                bytes[pos + 23] = UInt8((bitsPerSample >> 8) & 0xFF)
              }
            }
            // WAVE_FORMAT_EXTENSIBLE (0xFFFE): rewrite wFormatTag to underlying subformat (0x0001 PCM or 0x0003 IEEE Float)
            // so Apple TV's CoreAudio WAVE parser accepts 24-bit/32-bit WAV streams directly
            if formatTag == 0xFFFE && cSize >= 40 && pos + 8 + 40 <= bytes.count {
              let validBits = Int(bytes[pos + 26]) | (Int(bytes[pos + 27]) << 8)
              if validBits == 0 && bitsPerSample > 0 {
                bytes[pos + 26] = UInt8(bitsPerSample & 0xFF)
                bytes[pos + 27] = UInt8((bitsPerSample >> 8) & 0xFF)
              }
              let subFormatTag = Int(bytes[pos + 32]) | (Int(bytes[pos + 33]) << 8)
              if (subFormatTag == 0x0001 || subFormatTag == 0x0003) && channels <= 2 {
                bytes[pos + 8] = UInt8(subFormatTag & 0xFF)
                bytes[pos + 9] = UInt8((subFormatTag >> 8) & 0xFF)
              }
            }
          }
        }

        // `data` chunk (`64 61 74 61`)
        if c0 == 0x64 && c1 == 0x61 && c2 == 0x74 && c3 == 0x61 {
          let dataPayloadOffset = Int64(pos + 8)
          let remainingBytes = effectiveTotal - dataPayloadOffset
          if remainingBytes > 0 &&
              (cSize <= 0 || cSize == -1 || UInt32(bitPattern: Int32(truncatingIfNeeded: cSize)) == 0xFFFFFFFF || UInt32(bitPattern: Int32(truncatingIfNeeded: cSize)) == 0x7FFFFFFF) {
            let fixedDataSize = UInt32(clamping: min(remainingBytes, 0xFFFFFFF0))
            bytes[pos + 4] = UInt8(fixedDataSize & 0xFF)
            bytes[pos + 5] = UInt8((fixedDataSize >> 8) & 0xFF)
            bytes[pos + 6] = UInt8((fixedDataSize >> 16) & 0xFF)
            bytes[pos + 7] = UInt8((fixedDataSize >> 24) & 0xFF)
          }
          break
        }

        if cSize < 0 || cSize > bytes.count { break }
        let step = 8 + cSize + (cSize % 2 == 1 ? 1 : 0)
        if step <= 8 { break }
        pos += step
      }
    }

    return (Data(bytes), stripPrefix, effectiveTotal, contentType)
  }

  private func startNewFlvSession(
    url: URL,
    headers: [String: String],
    fallbackUrl: URL? = nil,
    fallbackHeaders: [String: String] = [:]
  ) -> Int {
    flvLock.lock()
    let old = activeFlvSession
    activeFlvGeneration &+= 1
    let gen = activeFlvGeneration
    let flvSess = TvLiveFlvSession()
    activeFlvSession = flvSess
    flvLock.unlock()
    old?.stop()
    flvSess.start(url: url, headers: headers, fallbackUrl: fallbackUrl, fallbackHeaders: fallbackHeaders)
    return gen
  }

  private func currentFlvSessionSnapshot() -> (TvLiveFlvSession?, Int) {
    flvLock.lock()
    defer { flvLock.unlock() }
    return (activeFlvSession, activeFlvGeneration)
  }

  private func stopActiveFlvSession() {
    flvLock.lock()
    let old = activeFlvSession
    activeFlvSession = nil
    flvLock.unlock()
    old?.stop()
  }

  private func handleConnection(_ conn: NWConnection) {
    conn.start(queue: queue)
    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
      guard let self = self,
            let data = data,
            let reqStr = String(data: data, encoding: .utf8),
            let firstLine = reqStr.components(separatedBy: "\r\n").first else {
        conn.cancel()
        return
      }
      let parts = firstLine.components(separatedBy: " ")
      guard parts.count >= 2 else {
        conn.cancel()
        return
      }
      let method = parts[0].uppercased()
      let pathAndQuery = parts[1]

      var rangeHeader: String? = nil
      for line in reqStr.components(separatedBy: "\r\n") {
        if line.lowercased().hasPrefix("range:") {
          rangeHeader = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
          break
        }
      }

      let reqTask = Task {
        await self.processRequest(method: method, pathAndQuery: pathAndQuery, rangeHeader: rangeHeader, conn: conn)
      }
      conn.stateUpdateHandler = { state in
        switch state {
        case .cancelled, .failed:
          reqTask.cancel()
        default:
          break
        }
      }
    }
  }

  private func processRequest(method: String, pathAndQuery: String, rangeHeader: String?, conn: NWConnection) async {
    let comp = URLComponents(string: "http://127.0.0.1\(pathAndQuery)")
    let path = comp?.path ?? ""
    let genParam = Int(comp?.queryItems?.first(where: { $0.name == "gen" })?.value ?? "")

    if path == "/flv_live.m3u8" {
      let (sess, curFlvGen) = currentFlvSessionSnapshot()
      guard let flvSession = sess, (genParam == nil || genParam == curFlvGen) else {
        sendResponse(conn: conn, status: "404 Not Found", contentType: "text/plain", body: Data(), isHead: method == "HEAD")
        return
      }
    // Wait up to 22 seconds (`220 * 100ms`) for the first 2 segments so that if direct connection times out (4.2s)
      // and switches to the client proxy node fallback, `/flv_live.m3u8` still returns `200 OK` without premature `502 Bad Gateway`!
      for tick in 0..<220 {
        let count = flvSession.snapshotSegments().count
        if count >= 2 || (count >= 1 && tick >= 120) { break }
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      let allSegs = flvSession.snapshotSegments()
      guard !allSegs.isEmpty else {
        sendResponse(conn: conn, status: "502 Bad Gateway", contentType: "text/plain", body: Data(), isHead: method == "HEAD")
        return
      }
      let segs = Array(allSegs.suffix(5))
      let firstSeq = segs.first?.seq ?? 1
      let maxDur = max(2, Int(ceil(segs.map { $0.dur }.max() ?? 2.0)))
      let localPort = self.port
      var m3u8 = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(maxDur)\n#EXT-X-MEDIA-SEQUENCE:\(firstSeq)\n"
      for seg in segs {
        m3u8 += String(format: "#EXTINF:%.3f,\nhttp://127.0.0.1:%d/flv_seg.ts?gen=%d&seq=%d\n", seg.dur, localPort, curFlvGen, seg.seq)
      }
      let body = Data(m3u8.utf8)
      sendResponse(
        conn: conn,
        status: "200 OK",
        contentType: "application/vnd.apple.mpegurl",
        body: body,
        isHead: method == "HEAD"
      )
      return
    }

    if path == "/flv_seg.ts",
       let seqStr = comp?.queryItems?.first(where: { $0.name == "seq" })?.value,
       let seq = Int(seqStr) {
      let (sess, _) = currentFlvSessionSnapshot()
      guard let flvSession = sess, let segData = flvSession.segmentData(seq: seq) else {
        sendResponse(conn: conn, status: "404 Not Found", contentType: "text/plain", body: Data(), isHead: method == "HEAD")
        return
      }
      if let rangeStr = rangeHeader,
         rangeStr.lowercased().hasPrefix("bytes="),
         let (slice, contentRange) = Self.sliceData(segData, rangeSpec: String(rangeStr.dropFirst(6))) {
        sendResponse(
          conn: conn,
          status: "206 Partial Content",
          contentType: "video/mp2t",
          extraHeaders: ["Content-Range: \(contentRange)", "Accept-Ranges: bytes"],
          body: slice,
          isHead: method == "HEAD"
        )
      } else {
        sendResponse(
          conn: conn,
          status: "200 OK",
          contentType: "video/mp2t",
          extraHeaders: ["Accept-Ranges: bytes"],
          body: segData,
          isHead: method == "HEAD"
        )
      }
      return
    }

    if path == "/live.m3u8" {
      let cfg = await store.currentConfig()
      let activeGen = genParam ?? cfg.gen
      guard let m3u8Text = await fetchAndRewritePlaylist(cfg: cfg, activeGen: activeGen) else {
        sendResponse(conn: conn, status: "502 Bad Gateway", contentType: "text/plain", body: Data(), isHead: method == "HEAD")
        return
      }
      let body = Data(m3u8Text.utf8)
      sendResponse(
        conn: conn,
        status: "200 OK",
        contentType: "application/vnd.apple.mpegurl",
        body: body,
        isHead: method == "HEAD"
      )
      return
    }

    if path == "/seg.ts",
       let targetUrl = comp?.queryItems?.first(where: { $0.name == "u" })?.value,
       !targetUrl.isEmpty {
      let cfg = await store.currentConfig()
      let activeGen = genParam ?? cfg.gen
      let sessionRef = self.preferredSession(for: targetUrl)
      let fallbackSessionRef = self.directUrlSession
      let data = await store.fetchOrJoinSegment(url: targetUrl, gen: activeGen) { urlStr, hdrs in
        await Self.downloadSegmentMultiRange(
          urlStr: urlStr,
          headers: hdrs,
          session: sessionRef,
          fallbackDirectSession: fallbackSessionRef
        )
      }
      guard let fullData = data, !fullData.isEmpty else {
        sendResponse(conn: conn, status: "502 Bad Gateway", contentType: "text/plain", body: Data(), isHead: method == "HEAD")
        return
      }

      if let rangeStr = rangeHeader,
         rangeStr.lowercased().hasPrefix("bytes="),
         let (slice, contentRange) = Self.sliceData(fullData, rangeSpec: String(rangeStr.dropFirst(6))) {
        sendResponse(
          conn: conn,
          status: "206 Partial Content",
          contentType: "video/mp2t",
          extraHeaders: ["Content-Range: \(contentRange)", "Accept-Ranges: bytes"],
          body: slice,
          isHead: method == "HEAD"
        )
      } else {
        sendResponse(
          conn: conn,
          status: "200 OK",
          contentType: "video/mp2t",
          extraHeaders: ["Accept-Ranges: bytes"],
          body: fullData,
          isHead: method == "HEAD"
        )
      }
      return
    }

    if path.hasPrefix("/tg_video"),
       let targetUrl = comp?.queryItems?.first(where: { $0.name == "u" })?.value,
       let remoteUrl = URL(string: targetUrl),
       let playbackId = comp?.queryItems?.first(where: { $0.name == "playback" })?.value {
      await streamTelegramVideoChunked(
        targetUrl: "\(targetUrl)#\(playbackId)",
        url: remoteUrl,
        requestPath: path,
        method: method,
        rangeHeader: rangeHeader,
        conn: conn
      )
      return
    }

    sendResponse(conn: conn, status: "404 Not Found", contentType: "text/plain", body: Data(), isHead: method == "HEAD")
  }

  /// Deduplicated 512 KB (`bytes=0-524287`) initial header + metadata probe for Telegram / 115 media streams.
  private func ensureTelegramVideoMeta(
    targetUrl: String,
    url: URL,
    requestPath: String
  ) async -> (totalSize: Int64, contentType: String, headerChunk: Data, stripPrefixBytes: Int)? {
    let hdrs = getTgHeadersAndMeta(for: targetUrl).headers
    let state = lookupOrRegisterTelegramMetaProbe(targetUrl: targetUrl) {
      return Task<(totalSize: Int64, contentType: String, headerChunk: Data, stripPrefixBytes: Int)?, Never> { [weak self] in
        guard let self = self else { return nil }
        let primarySession = self.preferredTelegramOrMediaSession(for: targetUrl)
        for attempt in 0..<3 {
          if Task.isCancelled { return nil }
          var req = URLRequest(url: url)
          req.httpMethod = "GET"
          req.timeoutInterval = (attempt == 0 && primarySession !== self.directUrlSession) ? 7.5 : 15.0
          for (k, v) in hdrs where !v.isEmpty {
            req.setValue(v, forHTTPHeaderField: k)
          }
          // Probe first 512 KB (`bytes=0-524287`) with exclusive bandwidth so startup & MP4 header parsing complete fast
          req.setValue("bytes=0-524287", forHTTPHeaderField: "Range")
          let sess = attempt == 0 ? primarySession : self.directUrlSession
          do {
            guard let (d, h) = try await Self.readMediaHeader(req, session: sess),
                  !d.isEmpty else { continue }
            if attempt > 0 {
              self.markTelegramUrlPreferDirect(targetUrl)
            }
            TvNetworkSpeedMonitor.shared.recordDownstreamBytes(d.count)
            let rawCt = (h.value(forHTTPHeaderField: "Content-Type") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let ct: String
            if rawCt.isEmpty || rawCt.lowercased().contains("octet-stream") || rawCt.lowercased().contains("force-download") {
              ct = Self.inferMediaMimeType(pathOrUrl: requestPath)
                ?? Self.inferMediaMimeType(pathOrUrl: url.path)
                ?? "video/mp4"
            } else {
              ct = rawCt
            }
            var totalSize: Int64 = Int64(d.count)
            if let cr = h.value(forHTTPHeaderField: "Content-Range") ?? h.value(forHTTPHeaderField: "content-range"),
               let slash = cr.lastIndex(of: "/"),
               let parsedTotal = Int64(cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces)),
               parsedTotal > 0 {
              totalSize = parsedTotal
            } else if h.expectedContentLength > Int64(d.count) {
              totalSize = h.expectedContentLength
            }
            let normalized = Self.normalizeWavOrAudioHeaderChunk(
              rawChunk: d,
              rawTotalSize: totalSize,
              defaultContentType: ct
            )
            let resolved = (
              totalSize: normalized.effectiveTotalSize,
              contentType: normalized.contentType,
              headerChunk: normalized.headerChunk,
              stripPrefixBytes: normalized.stripPrefixBytes
            )
            self.storeTgMeta(resolved, for: targetUrl)
            return resolved
          } catch MediaHeaderError.rangeUnsupported {
            self.markMediaRangeUnsupported(targetUrl)
            return nil
          } catch {
            if attempt == 0 && primarySession !== self.directUrlSession {
              self.markTelegramUrlPreferDirect(targetUrl)
            }
          }
          try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return nil
      }
    }
    if let cached = state.cached {
      return cached
    }
    guard let task = state.task else { return nil }
    let res = await task.value
    if state.isCreator {
      clearTelegramMetaInFlight(targetUrl: targetUrl)
    }
    return res
  }

  private enum MediaHeaderError: Error {
    case rangeUnsupported
  }

  private func markMediaRangeUnsupported(_ targetUrl: String) {
    tgLock.lock()
    defer { tgLock.unlock() }
    if tgHeadersByUrl[targetUrl] != nil { tgRangeUnsupported.insert(targetUrl) }
  }

  private static func readMediaHeader(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse)? {
    let (stream, response) = try await session.bytes(for: request)
    if let http = response as? HTTPURLResponse, http.statusCode == 200,
       http.expectedContentLength < 0 || http.expectedContentLength > 524288 {
      stream.task.cancel()
      throw MediaHeaderError.rangeUnsupported
    }
    guard let http = response as? HTTPURLResponse,
          http.statusCode == 206 || http.statusCode == 200,
          http.statusCode != 206 || http.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 0-") == true else {
      stream.task.cancel()
      return nil
    }
    var result = Data()
    result.reserveCapacity(524288)
    for try await byte in stream {
      result.append(byte)
      if result.count == 524288 {
        stream.task.cancel()
        break
      }
    }
    return (result, http)
  }

  private func registerMediaPassthrough(
    targetUrl: String,
    id: UUID,
    makeTask: () -> Task<Bool, Never>
  ) -> Task<Bool, Never>? {
    tgLock.lock()
    defer { tgLock.unlock() }
    guard tgHeadersByUrl[targetUrl] != nil, tgRangeUnsupported.contains(targetUrl) else { return nil }
    let task = makeTask()
    tgPassthroughTasks[targetUrl, default: [:]][id] = task
    return task
  }

  private func clearMediaPassthrough(targetUrl: String, id: UUID) {
    tgLock.lock()
    defer { tgLock.unlock() }
    tgPassthroughTasks[targetUrl]?.removeValue(forKey: id)
  }

  private func streamMediaPassthrough(
    conn: NWConnection,
    request: URLRequest,
    session: URLSession,
    isHead: Bool
  ) async -> Bool {
    guard let (stream, response) = try? await session.bytes(for: request) else { return false }
    defer {
      stream.task.cancel()
    }
    guard let http = response as? HTTPURLResponse,
          (200...299).contains(http.statusCode) || http.statusCode == 416 else { return false }
    var headers = ["HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))"]
    for name in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"] {
      if let value = http.value(forHTTPHeaderField: name) { headers.append("\(name): \(value)") }
    }
    headers.append("Connection: close")
    let encoded = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    if await sendDataAsync(conn: conn, data: encoded), !isHead {
      var buffer = Data()
      buffer.reserveCapacity(65536)
      do {
        for try await byte in stream {
          buffer.append(byte)
          if buffer.count == 65536 {
            guard await sendDataAsync(conn: conn, data: buffer) else { break }
            buffer.removeAll(keepingCapacity: true)
          }
        }
        if !buffer.isEmpty { _ = await sendDataAsync(conn: conn, data: buffer) }
      } catch {
        // Closing the local stream lets AVPlayer reconnect on upstream failure.
      }
    }
    conn.cancel()
    return true
  }

  private func lookupOrRegisterTelegramMetaProbe(
    targetUrl: String,
    makeTask: () -> Task<(totalSize: Int64, contentType: String, headerChunk: Data, stripPrefixBytes: Int)?, Never>
  ) -> (
    cached: (totalSize: Int64, contentType: String, headerChunk: Data, stripPrefixBytes: Int)?,
    task: Task<(totalSize: Int64, contentType: String, headerChunk: Data, stripPrefixBytes: Int)?, Never>?,
    isCreator: Bool
  ) {
    tgLock.lock()
    defer { tgLock.unlock() }
    if let existingMeta = tgVideoMetaCache[targetUrl] {
      return (existingMeta, nil, false)
    }
    guard tgHeadersByUrl[targetUrl] != nil, !tgRangeUnsupported.contains(targetUrl) else { return (nil, nil, false) }
    if let inFlight = tgMetaInFlight[targetUrl] {
      return (nil, inFlight, false)
    }
    let created = makeTask()
    tgMetaInFlight[targetUrl] = created
    return (nil, created, true)
  }

  private func clearTelegramMetaInFlight(targetUrl: String) {
    tgLock.lock()
    tgMetaInFlight.removeValue(forKey: targetUrl)
    tgLock.unlock()
  }

  /// Reads bounded byte ranges and prefetches ahead of the current playback position.
  private func streamTelegramVideoChunked(
    targetUrl: String,
    url u: URL,
    requestPath: String = "/tg_video.mp4",
    method: String,
    rangeHeader: String?,
    conn: NWConnection
  ) async {
    let hdrs = getTgHeadersAndMeta(for: targetUrl).headers
    guard let meta = await ensureTelegramVideoMeta(targetUrl: targetUrl, url: u, requestPath: requestPath),
          meta.totalSize > 0 else {
      let id = UUID()
      if let task = registerMediaPassthrough(targetUrl: targetUrl, id: id, makeTask: {
        Task {
          var request = URLRequest(url: u)
          request.httpMethod = method
          for (name, value) in hdrs { request.setValue(value, forHTTPHeaderField: name) }
          request.setValue(rangeHeader, forHTTPHeaderField: "Range")
          return await self.streamMediaPassthrough(
            conn: conn, request: request,
            session: self.preferredTelegramOrMediaSession(for: targetUrl),
            isHead: method == "HEAD")
        }
      }) {
        let didStream = await task.value
        clearMediaPassthrough(targetUrl: targetUrl, id: id)
        if didStream { return }
      }
      sendResponse(conn: conn, status: "502 Bad Gateway", contentType: "text/plain", body: Data(), isHead: method == "HEAD")
      return
    }

    let allowParallelLookahead = !Self.isDomesticOrLocalUrl(targetUrl) && !meta.contentType.hasPrefix("audio/")

    var reqStart: Int64 = 0
    var reqEnd = meta.totalSize - 1
    let isPartial = rangeHeader != nil
    if let header = rangeHeader {
      guard let range = Self.resolveMediaByteRange(header, size: meta.totalSize) else {
        sendResponse(conn: conn, status: "416 Range Not Satisfiable", contentType: "text/plain",
                     extraHeaders: ["Content-Range: bytes */\(meta.totalSize)"], body: Data(), isHead: method == "HEAD")
        return
      }
      reqStart = range.lowerBound
      reqEnd = range.upperBound
    }
    let contentLen = reqEnd - reqStart + 1
    if method == "HEAD" {
      let hdr = [
        "HTTP/1.1 \(isPartial ? "206 Partial Content" : "200 OK")",
        "Content-Type: \(meta.contentType)",
        "Content-Length: \(contentLen)",
        "Accept-Ranges: bytes",
        isPartial ? "Content-Range: bytes \(reqStart)-\(reqEnd)/\(meta.totalSize)" : nil,
        "Connection: close",
        "\r\n"
      ].compactMap { $0 }.joined(separator: "\r\n")
      conn.send(content: Data(hdr.utf8), completion: .contentProcessed { _ in conn.cancel() })
      return
    }

    let prefetch = allowParallelLookahead && contentLen > Self.tgBlockSize * 2
    let reader = UUID()
    if prefetch { beginTelegramPlaybackRead(targetUrl: targetUrl, reader: reader) }
    defer {
      if prefetch { finishTelegramPlaybackRead(targetUrl: targetUrl, reader: reader) }
    }

    // 2. Fast-path: serve small header/moov probes directly from cached 512 KB headerChunk in 0ms
    if reqEnd < Int64(meta.headerChunk.count) {
      let slice = meta.headerChunk.subdata(in: Int(reqStart)..<(Int(reqEnd) + 1))
      sendResponse(
        conn: conn,
        status: isPartial ? "206 Partial Content" : "200 OK",
        contentType: meta.contentType,
        extraHeaders: isPartial
          ? ["Content-Range: bytes \(reqStart)-\(reqEnd)/\(meta.totalSize)", "Accept-Ranges: bytes"]
          : ["Accept-Ranges: bytes"],
        body: slice,
        isHead: false
      )
      return
    }

    // Stream the requested range from the shared block cache.
    let hdrLines = [
      "HTTP/1.1 \(isPartial ? "206 Partial Content" : "200 OK")",
      "Content-Type: \(meta.contentType)",
      "Content-Length: \(contentLen)",
      "Accept-Ranges: bytes",
      isPartial ? "Content-Range: bytes \(reqStart)-\(reqEnd)/\(meta.totalSize)" : nil,
      "Access-Control-Allow-Origin: *",
      "Connection: close"
    ].compactMap { $0 }
    let hdrPayload = Data((hdrLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    guard await sendDataAsync(conn: conn, data: hdrPayload) else {
      conn.cancel()
      return
    }

    var cursor = reqStart
    // If starting within cached 512 KB headerChunk, flush the cached prefix immediately so AVPlayer starts decoding at 0ms
    if cursor < Int64(meta.headerChunk.count) {
      let cachedEnd = min(reqEnd, Int64(meta.headerChunk.count) - 1)
      let prefixSlice = meta.headerChunk.subdata(in: Int(cursor)..<(Int(cachedEnd) + 1))
      guard await sendDataAsync(conn: conn, data: prefixSlice) else {
        conn.cancel()
        return
      }
      cursor = cachedEnd + 1
    }

    let blockSize = Self.tgBlockSize
    while cursor <= reqEnd {
      let blockIndex = cursor / blockSize
      let blockStart = blockIndex * blockSize
      let blockEnd = min(meta.totalSize - 1, blockStart + blockSize - 1)

      if prefetch && updateTelegramPlayhead(targetUrl: targetUrl, blockIndex: blockIndex, reader: reader) {
        pumpTelegramSlidingWindow(targetUrl: targetUrl, url: u, meta: meta)
      }

      guard let blockData = await getOrFetchTelegramBlock(
        targetUrl: targetUrl,
        url: u,
        headers: hdrs,
        blockIndex: blockIndex,
        meta: meta,
        isPrefetch: false
      ), !blockData.isEmpty else {
        conn.cancel()
        return
      }

      if prefetch {
        pumpTelegramSlidingWindow(targetUrl: targetUrl, url: u, meta: meta)
      }

      let sliceStart = Int(max(0, cursor - blockStart))
      let desiredEnd = min(reqEnd, blockEnd)
      let sliceEnd = min(blockData.count, Int(desiredEnd - blockStart + 1))
      guard sliceStart < sliceEnd else {
        conn.cancel()
        return
      }
      let outSlice = (sliceStart == 0 && sliceEnd == blockData.count)
        ? blockData
        : blockData.subdata(in: sliceStart..<sliceEnd)

      guard await sendDataAsync(conn: conn, data: outSlice) else {
        conn.cancel()
        return
      }
      cursor += Int64(outSlice.count)
    }

    conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
      conn.cancel()
    })
  }

  private static func resolveMediaByteRange(_ header: String, size: Int64) -> ClosedRange<Int64>? {
    guard header.lowercased().hasPrefix("bytes=") else { return nil }
    let fields = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
    guard fields.count == 2 else { return nil }
    if fields[0].isEmpty {
      guard let suffix = Int64(fields[1]), suffix > 0 else { return nil }
      return max(0, size - suffix)...(size - 1)
    }
    guard let start = Int64(fields[0]), start >= 0, start < size,
          let end = fields[1].isEmpty ? size - 1 : Int64(fields[1]), end >= start else { return nil }
    return start...min(size - 1, end)
  }

  private func beginTelegramPlaybackRead(targetUrl: String, reader: UUID) {
    tgLock.lock()
    defer { tgLock.unlock() }
    if tgHeadersByUrl[targetUrl] != nil {
      tgPlaybackReaderByUrl[targetUrl] = reader
    }
  }

  private func finishTelegramPlaybackRead(targetUrl: String, reader: UUID) {
    tgLock.lock()
    defer { tgLock.unlock() }
    guard tgPlaybackReaderByUrl[targetUrl] == reader else { return }
    tgPlaybackReaderByUrl.removeValue(forKey: targetUrl)
    if tgActiveBackgroundUrl == targetUrl { tgActiveBackgroundUrl = "" }
    for (key, task) in tgInFlightBlocks where key.hasPrefix("\(targetUrl)#") && tgInFlightIsPrefetch[key] == true {
      task.cancel()
    }
  }

  private func updateTelegramPlayhead(targetUrl: String, blockIndex: Int64, reader: UUID) -> Bool {
    let prefix = "\(targetUrl)#"
    tgLock.lock()
    defer { tgLock.unlock() }
    guard tgPlaybackReaderByUrl[targetUrl] == reader else { return false }
    tgActiveBackgroundUrl = targetUrl
    tgLastAccessByUrl[targetUrl] = Date()
    tgPlayheadBlockByUrl[targetUrl] = blockIndex
    for (key, task) in tgInFlightBlocks where tgInFlightIsPrefetch[key] == true {
      if !key.hasPrefix(prefix) {
        task.cancel()
      } else if let index = Int64(key.dropFirst(prefix.count)),
                index < blockIndex || index > blockIndex + Int64(Self.tgLookaheadBlocks) {
        task.cancel()
      }
    }
    return true
  }

  private func preferredTelegramOrMediaSession(for targetUrl: String) -> URLSession {
    if Self.isDomesticOrLocalUrl(targetUrl) {
      return directUrlSession
    }
    if targetUrl.contains("/api/telegram/") {
      tgLock.lock()
      let preferDirectAt = tgPreferDirectByUrl[targetUrl]
      tgLock.unlock()
      if let ts = preferDirectAt, Date().timeIntervalSince(ts) < 300 {
        return directUrlSession
      }
    }
    return urlSession
  }

  private func markTelegramUrlPreferDirect(_ targetUrl: String) {
    guard targetUrl.contains("/api/telegram/") else { return }
    tgLock.lock()
    guard tgHeadersByUrl[targetUrl] != nil else {
      tgLock.unlock()
      return
    }
    if tgPreferDirectByUrl.count > 64 {
      tgPreferDirectByUrl.removeAll(keepingCapacity: true)
    }
    tgPreferDirectByUrl[targetUrl] = Date()
    tgLock.unlock()
  }

  /// Keeps a bounded window of completed blocks ahead of the playhead.
  private func pumpTelegramSlidingWindow(
    targetUrl: String,
    url: URL,
    meta: (totalSize: Int64, contentType: String, headerChunk: Data, stripPrefixBytes: Int)
  ) {
    let blockSize = Self.tgBlockSize
    let maxBlockIndex = max(0, (meta.totalSize - 1) / blockSize)

    tgLock.lock()
    guard tgActiveBackgroundUrl == targetUrl else {
      tgLock.unlock()
      return
    }
    let lastAccess = tgLastAccessByUrl[targetUrl] ?? .distantPast
    guard Date().timeIntervalSince(lastAccess) < 35.0 else {
      tgLock.unlock()
      return
    }
    let playhead = tgPlayheadBlockByUrl[targetUrl] ?? 0
    let hdrs = tgHeadersByUrl[targetUrl] ?? [:]

    // Completed blocks remain in the bounded LRU across playhead changes.
    // MP4 audio and video may be read from distant offsets in the same file.
    let playheadKey = "\(targetUrl)#\(playhead)"
    let isPlayheadReady = tgBlockCache[playheadKey] != nil

    var candidates: [Int64] = []
    if !isPlayheadReady && playhead <= maxBlockIndex {
      candidates.append(playhead)
    }
    if playhead + 1 <= maxBlockIndex {
      candidates.append(playhead + 1)
    }
    // While the active playhead block is still downloading, limit background concurrency to 1 extra block (`playhead + 1`)
    // so the playhead block finishes with maximum bandwidth; once playhead is cached, unleash all 6 workers across +40 MB!
    let maxWorkersNow = isPlayheadReady ? Self.tgMaxConcurrentPrefetchPerUrl : 2
    if isPlayheadReady {
      if playhead <= 1 && maxBlockIndex > playhead + 1 {
        candidates.append(maxBlockIndex)
      }
      for offset in 2...Self.tgLookaheadBlocks {
        let idx = playhead + Int64(offset)
        if idx <= maxBlockIndex && idx != maxBlockIndex {
          candidates.append(idx)
        }
      }
    }

    var blocksToLaunch: [Int64] = []
    for idx in candidates {
      let activeCount = tgActivePrefetchCountByUrl[targetUrl] ?? 0
      if activeCount + blocksToLaunch.count >= maxWorkersNow {
        break
      }
      let key = "\(targetUrl)#\(idx)"
      if tgBlockCache[key] == nil && tgInFlightBlocks[key] == nil {
        blocksToLaunch.append(idx)
      }
    }
    tgLock.unlock()

    for idx in blocksToLaunch {
      Task.detached(priority: idx <= playhead + 1 ? .userInitiated : .utility) { [weak self] in
        guard let self = self else { return }
        _ = await self.getOrFetchTelegramBlock(
          targetUrl: targetUrl,
          url: url,
          headers: hdrs,
          blockIndex: idx,
          meta: meta,
          isPrefetch: true
        )
      }
    }
  }

  private func lookupOrRegisterTelegramBlockFetch(
    key: String,
    targetUrl: String,
    isPrefetch: Bool,
    makeTask: () -> Task<Data?, Never>
  ) -> (cached: Data?, task: Task<Data?, Never>?, isCreator: Bool) {
    tgLock.lock()
    defer { tgLock.unlock() }
    guard tgHeadersByUrl[targetUrl] != nil else { return (nil, nil, false) }
    if let cached = tgBlockCache[key] {
      if let pos = tgBlockOrder.firstIndex(of: key) {
        tgBlockOrder.remove(at: pos)
        tgBlockOrder.append(key)
      }
      return (cached, nil, false)
    }
    if let inFlight = tgInFlightBlocks[key] {
      if !isPrefetch && tgInFlightIsPrefetch[key] == true {
        tgInFlightIsPrefetch[key] = false
        tgActivePrefetchCountByUrl[targetUrl] = max(0, (tgActivePrefetchCountByUrl[targetUrl] ?? 1) - 1)
      }
      return (nil, inFlight, false)
    }
    if isPrefetch {
      if tgActiveBackgroundUrl != targetUrl {
        return (nil, nil, false)
      }
      let active = tgActivePrefetchCountByUrl[targetUrl] ?? 0
      if active >= Self.tgMaxConcurrentPrefetchPerUrl {
        return (nil, nil, false)
      }
      tgActivePrefetchCountByUrl[targetUrl] = active + 1
    }
    let created = makeTask()
    tgInFlightBlocks[key] = created
    tgInFlightIsPrefetch[key] = isPrefetch
    return (nil, created, true)
  }

  private func completeTelegramBlockFetch(
    key: String,
    targetUrl: String,
    url: URL,
    meta: (totalSize: Int64, contentType: String, headerChunk: Data, stripPrefixBytes: Int),
    isPrefetch: Bool,
    result: Data?
  ) {
    var shouldPump = false
    tgLock.lock()
    guard tgHeadersByUrl[targetUrl] != nil else {
      tgLock.unlock()
      return
    }
    let wasPrefetch = tgInFlightIsPrefetch[key] ?? isPrefetch
    tgInFlightBlocks.removeValue(forKey: key)
    tgInFlightIsPrefetch.removeValue(forKey: key)
    if wasPrefetch {
      let cur = tgActivePrefetchCountByUrl[targetUrl] ?? 1
      tgActivePrefetchCountByUrl[targetUrl] = max(0, cur - 1)
    }
    if let valid = result, !valid.isEmpty {
      if tgBlockCache[key] == nil {
        tgBlockOrder.append(key)
        while tgBlockOrder.count > Self.tgMaxCachedBlocks {
          // Prefer evicting blocks from inactive URLs first
          if let inactiveIdx = tgBlockOrder.firstIndex(where: { !$0.hasPrefix("\(targetUrl)#") }) {
            let evictedKey = tgBlockOrder.remove(at: inactiveIdx)
            tgBlockCache.removeValue(forKey: evictedKey)
          } else {
            let evictedKey = tgBlockOrder.removeFirst()
            tgBlockCache.removeValue(forKey: evictedKey)
          }
        }
      }
      tgBlockCache[key] = valid
      shouldPump = (tgActiveBackgroundUrl == targetUrl)
    }
    tgLock.unlock()

    // Self-driving continuation: immediately launch the next 2 MB block in the +40 MB window!
    if shouldPump && !Self.isDomesticOrLocalUrl(targetUrl) && !meta.contentType.hasPrefix("audio/") {
      pumpTelegramSlidingWindow(targetUrl: targetUrl, url: url, meta: meta)
    }
  }

  private func getOrFetchTelegramBlock(
    targetUrl: String,
    url: URL,
    headers: [String: String],
    blockIndex: Int64,
    meta: (totalSize: Int64, contentType: String, headerChunk: Data, stripPrefixBytes: Int),
    isPrefetch: Bool,
    retryCancelledPrefetch: Bool = true
  ) async -> Data? {
    let blockSize = Self.tgBlockSize
    let logicalStart = blockIndex * blockSize
    let logicalEnd = min(meta.totalSize - 1, logicalStart + blockSize - 1)
    guard logicalStart <= logicalEnd else { return nil }

    let key = "\(targetUrl)#\(blockIndex)"
    let state = lookupOrRegisterTelegramBlockFetch(
      key: key,
      targetUrl: targetUrl,
      isPrefetch: isPrefetch
    ) {
      Task<Data?, Never> { [weak self] in
        guard let self = self else { return nil }
        var fetchedResult: Data? = nil
        defer {
          self.completeTelegramBlockFetch(
            key: key,
            targetUrl: targetUrl,
            url: url,
            meta: meta,
            isPrefetch: isPrefetch,
            result: Task.isCancelled ? nil : fetchedResult
          )
        }
        let prefixOffset = Int64(meta.stripPrefixBytes)
        let expectedBlockLen = Int(logicalEnd - logicalStart + 1)

        // For Block 0, reuse the already-normalized 512 KB `meta.headerChunk` prefix (`0..<headerChunk.count`)
        if blockIndex == 0 && !meta.headerChunk.isEmpty {
          if meta.headerChunk.count >= expectedBlockLen {
            fetchedResult = meta.headerChunk.subdata(in: 0..<expectedBlockLen)
            return fetchedResult
          }
          let remStart = Int64(meta.headerChunk.count) + prefixOffset
          let remEnd = logicalEnd + prefixOffset
          guard let tailData = await self.fetchTelegramRangeChunk(
            targetUrl: targetUrl,
            url: url,
            headers: headers,
            start: remStart,
            end: remEnd
          ) else {
            return nil
          }
          var combined = Data(capacity: meta.headerChunk.count + tailData.count)
          combined.append(meta.headerChunk)
          combined.append(tailData)
          fetchedResult = combined.count <= expectedBlockLen ? combined : combined.subdata(in: 0..<expectedBlockLen)
          return fetchedResult
        }

        let upStart = logicalStart + prefixOffset
        let upEnd = logicalEnd + prefixOffset
        fetchedResult = await self.fetchTelegramRangeChunk(
          targetUrl: targetUrl,
          url: url,
          headers: headers,
          start: upStart,
          end: upEnd
        )
        return fetchedResult
      }
    }

    if let cached = state.cached {
      return cached
    }
    guard let fetchTask = state.task else {
      return nil
    }
    let result = await fetchTask.value
    if result == nil && !isPrefetch && retryCancelledPrefetch && fetchTask.isCancelled {
      return await getOrFetchTelegramBlock(targetUrl: targetUrl, url: url, headers: headers,
        blockIndex: blockIndex, meta: meta, isPrefetch: false, retryCancelledPrefetch: false)
    }
    return result
  }

  private func fetchTelegramRangeChunk(
    targetUrl: String,
    url: URL,
    headers: [String: String],
    start: Int64,
    end: Int64
  ) async -> Data? {
    let expected = Int(end - start + 1)
    let primarySession = preferredTelegramOrMediaSession(for: targetUrl)
    for attempt in 0..<4 {
      if Task.isCancelled { return nil }
      var req = URLRequest(url: url)
      req.httpMethod = "GET"
      req.timeoutInterval = (attempt == 0 && primarySession !== directUrlSession) ? 7.5 : 18.0
      for (k, v) in headers where !v.isEmpty {
        req.setValue(v, forHTTPHeaderField: k)
      }
      req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
      req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
      let sess = attempt == 0 ? primarySession : directUrlSession
      if let (d, r) = try? await sess.data(for: req),
         let h = r as? HTTPURLResponse,
         h.statusCode == 206,
         h.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(start)-\(end)/") == true,
         d.count == expected {

        if attempt > 0 && primarySession !== directUrlSession {
          markTelegramUrlPreferDirect(targetUrl)
        }
        TvNetworkSpeedMonitor.shared.recordDownstreamBytes(d.count)
        return d
      } else if attempt == 0 && primarySession !== directUrlSession {
        markTelegramUrlPreferDirect(targetUrl)
      }
      try? await Task.sleep(nanoseconds: UInt64((attempt + 1) * 180_000_000))
    }
    return nil
  }

  private func sendDataAsync(conn: NWConnection, data: Data) async -> Bool {
    await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      conn.send(content: data, completion: .contentProcessed { err in
        cont.resume(returning: err == nil)
      })
    }
  }

  private static let directFailedLock = NSLock()
  private static var directFailedHostTimestamps: [String: TimeInterval] = [:]
  private static let directFailedHostTtl: TimeInterval = 600

  private static func hostCacheKey(for url: URL) -> String {
    let host = (url.host ?? "").lowercased()
    if let port = url.port {
      return "\(host):\(port)"
    }
    return host
  }

  private static func isHostMarkedDirectFailed(_ url: URL) -> Bool {
    let key = hostCacheKey(for: url)
    guard !key.isEmpty else { return false }
    directFailedLock.lock()
    defer { directFailedLock.unlock() }
    guard let ts = directFailedHostTimestamps[key] else { return false }
    if Date().timeIntervalSince1970 - ts > directFailedHostTtl {
      directFailedHostTimestamps.removeValue(forKey: key)
      return false
    }
    return true
  }

  private static func markHostDirectFailed(_ url: URL) {
    let key = hostCacheKey(for: url)
    guard !key.isEmpty, !isDomesticOrLocalUrl(url.absoluteString) else { return }
    directFailedLock.lock()
    directFailedHostTimestamps[key] = Date().timeIntervalSince1970
    directFailedLock.unlock()
  }

  private static func clearHostDirectFailed(_ url: URL) {
    let key = hostCacheKey(for: url)
    guard !key.isEmpty else { return }
    directFailedLock.lock()
    directFailedHostTimestamps.removeValue(forKey: key)
    directFailedLock.unlock()
  }

  static func unwrapServerVodProxyLinesInM3u8(_ text: String) -> String {
    guard text.contains("/api/vod/proxy") else { return text }
    func extractInnerUrl(_ raw: String) -> String? {
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.contains("/api/vod/proxy") else { return nil }
      let full = (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"))
        ? trimmed
        : "http://localhost\(trimmed.hasPrefix("/") ? "" : "/")\(trimmed)"
      guard let comp = URLComponents(string: full),
            let inner = comp.queryItems?.first(where: { $0.name == "url" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
            inner.hasPrefix("http://") || inner.hasPrefix("https://") else {
        return nil
      }
      return inner
    }

    let lines = text.components(separatedBy: .newlines)
    var out: [String] = []
    out.reserveCapacity(lines.count)
    for raw in lines {
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty {
        out.append("")
        continue
      }
      if line.hasPrefix("#") {
        if line.contains("/api/vod/proxy"),
           let uriRange = line.range(of: "URI=\"") {
          let afterStart = uriRange.upperBound
          if let endQuote = line[afterStart...].firstIndex(of: "\"") {
            let rawUri = String(line[afterStart..<endQuote])
            if let inner = extractInnerUrl(rawUri) {
              out.append(String(line[..<afterStart]) + inner + String(line[endQuote...]))
              continue
            }
          }
        }
        out.append(line)
      } else {
        out.append(extractInnerUrl(line) ?? line)
      }
    }
    return out.joined(separator: "\n")
  }

  private static func hasDisguisedImageHeaderMagic(_ data: Data) -> Bool {
    guard data.count >= 4 else { return false }
    let b0 = data[data.startIndex]
    let b1 = data[data.startIndex + 1]
    let b2 = data[data.startIndex + 2]
    let b3 = data[data.startIndex + 3]
    if b0 == 0x89 && b1 == 0x50 && b2 == 0x4E && b3 == 0x47 { return true } // PNG
    if b0 == 0xFF && b1 == 0xD8 && b2 == 0xFF { return true } // JPEG
    if b0 == 0x47 && b1 == 0x49 && b2 == 0x46 && b3 == 0x38 { return true } // GIF8
    if b0 == 0x42 && b1 == 0x4D { return true } // BMP
    if b0 == 0x52 && b1 == 0x49 && b2 == 0x46 && b3 == 0x46 { return true } // RIFF/WebP
    if b0 == 0x00 && b1 == 0x00 && b2 == 0x01 && b3 == 0x00 { return true } // ICO
    return false
  }

  static func stripDisguisedTsImageHeader(_ data: Data) -> Data {
    guard data.count >= 377,
          data[data.startIndex] != 0x47,
          hasDisguisedImageHeaderMagic(data) else {
      return data
    }
    let maxScan = min(data.count - 376, 4096)
    let base = data.startIndex
    for i in 1..<maxScan {
      if data[base + i] == 0x47 && data[base + i + 188] == 0x47 && data[base + i + 376] == 0x47 {
        return data.subdata(in: (base + i)..<data.endIndex)
      }
    }
    return data
  }

  private static func buildServerProxyFallbackRequest(
    targetUrl: String,
    headers: [String: String],
    timeout: TimeInterval
  ) -> URLRequest? {
    let rawBase = UserDefaults.standard.string(forKey: "tv_server_url") ?? "https://jp2.linsionwinwin.top:8081"
    let base = TvApiClient.normalizeBaseUrl(rawBase)
    guard !base.isEmpty,
          let target = URL(string: targetUrl),
          let host = target.host?.lowercased(),
          !host.isEmpty,
          host != "127.0.0.1",
          host != "localhost",
          !isDomesticOrLocalUrl(targetUrl) else {
      return nil
    }
    if let baseHost = URL(string: base)?.host?.lowercased(),
       host == baseHost,
       target.path.lowercased().hasPrefix("/api/") {
      return nil
    }
    var cleanHeaders: [String: String] = [:]
    for (k, v) in headers {
      let lower = k.lowercased()
      if lower != "cookie" && lower != "authorization" && lower != "host" && !v.isEmpty {
        cleanHeaders[k] = v
      }
    }
    guard var comp = URLComponents(string: "\(base)/api/vod/proxy") else { return nil }
    var items = [URLQueryItem(name: "url", value: targetUrl)]
    if !cleanHeaders.isEmpty,
       let jsonData = try? JSONSerialization.data(withJSONObject: cleanHeaders) {
      let b64 = jsonData.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
      items.append(URLQueryItem(name: "headers", value: b64))
    }
    comp.queryItems = items
    guard let proxyUrl = comp.url else { return nil }
    var req = URLRequest(url: proxyUrl)
    req.httpMethod = "GET"
    req.timeoutInterval = timeout
    req.setValue(
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
      forHTTPHeaderField: "User-Agent"
    )
    let secret = (UserDefaults.standard.string(forKey: "tv_auth_secret") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !secret.isEmpty {
      let token = secret.hasPrefix("auth_") ? secret : "auth_\(secret)"
      req.setValue("access_token=\(token)", forHTTPHeaderField: "Cookie")
    }
    return req
  }

  private func fetchAndRewritePlaylist(
    cfg: (gen: Int, gatewayUrl: String, streamUrl: String, headers: [String: String]),
    activeGen: Int
  ) async -> String? {
    if let cachedVod = await store.cachedVodPlaylist(forGen: activeGen) {
      return cachedVod
    }
    var activeStreamUrl = cfg.streamUrl
    var playlistFetch = await fetchRawPlaylist(urlStr: activeStreamUrl, headers: cfg.headers)
    if playlistFetch == nil, !cfg.gatewayUrl.isEmpty, cfg.gatewayUrl != activeStreamUrl {
      if let refreshed = await fetchRawPlaylist(urlStr: cfg.gatewayUrl, headers: cfg.headers) {
        playlistFetch = refreshed
        activeStreamUrl = refreshed.finalUrl.absoluteString
        await store.updateStreamUrl(activeStreamUrl, forGen: activeGen)
      }
    }
    guard var (text, finalUrl) = playlistFetch else { return nil }
    text = Self.unwrapServerVodProxyLinesInM3u8(text)

    // If this is a master playlist (#EXT-X-STREAM-INF), follow up to 2 levels of variant media playlists immediately
    let hasSeparateAudioRendition = text.range(
      of: "#EXT-X-MEDIA:[^\\r\\n]*TYPE=AUDIO[^\\r\\n]*URI=\"[^\"]+\"",
      options: [.regularExpression, .caseInsensitive]
    ) != nil
    for _ in 0..<2 where !hasSeparateAudioRendition {
      if !text.contains("#EXT-X-STREAM-INF") { break }
      let mLines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      let variants = mLines.filter { !$0.isEmpty && !$0.hasPrefix("#") }
      guard let bestVariant = variants.last ?? variants.first,
            let variantUrl = URL(string: bestVariant, relativeTo: finalUrl)?.absoluteURL,
            let childFetch = await fetchRawPlaylist(urlStr: variantUrl.absoluteString, headers: cfg.headers) else {
        break
      }
      text = Self.unwrapServerVodProxyLinesInM3u8(childFetch.text)
      finalUrl = childFetch.finalUrl
      await store.updateStreamUrl(finalUrl.absoluteString, forGen: activeGen)
    }

    let shouldFilterAds = (UserDefaults.standard.object(forKey: "tv_ad_filter") as? Bool) ?? true
    if shouldFilterAds && text.contains("#EXT-X-DISCONTINUITY") {
      text = TvApiClient.stripDiscontinuityAdsAndAbsolutize(m3u8Text: text, baseUrl: finalUrl)
    }

    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=?#")
    let localPort = self.port

    let lines = text.components(separatedBy: .newlines)
    var headerLines: [String] = ["#EXTM3U", "#EXT-X-VERSION:3"]
    var targetDurationLine = "#EXT-X-TARGETDURATION:10"
    var parsedSegments: [(inf: String, url: String, discontinuity: Bool, keyLine: String?, mapLine: String?)] = []
    var pendingInf: String? = nil
    var pendingDiscontinuity = false
    var currentKeyLine: String? = nil
    var currentMapLine: String? = nil
    var hasEndListTag = false
    var isExplicitVodTag = false

    for raw in lines {
      let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if t.isEmpty { continue }
      let upper = t.uppercased()
      if upper.hasPrefix("#EXT-X-TARGETDURATION") {
        targetDurationLine = t
      } else if upper.hasPrefix("#EXT-X-PLAYLIST-TYPE:VOD") {
        isExplicitVodTag = true
      } else if upper.hasPrefix("#EXT-X-ENDLIST") {
        hasEndListTag = true
      } else if upper.hasPrefix("#EXT-X-DISCONTINUITY") && !upper.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
        pendingDiscontinuity = true
      } else if upper.hasPrefix("#EXT-X-KEY") {
        currentKeyLine = Self.rewriteAttributeUriThroughProxy(
          in: t,
          baseUrl: finalUrl,
          localPort: localPort,
          activeGen: activeGen,
          allowed: allowed
        )
      } else if upper.hasPrefix("#EXT-X-MAP") {
        currentMapLine = Self.rewriteAttributeUriThroughProxy(
          in: t,
          baseUrl: finalUrl,
          localPort: localPort,
          activeGen: activeGen,
          allowed: allowed
        )
      } else if upper.hasPrefix("#EXTINF") {
        pendingInf = t
      } else if !t.hasPrefix("#") {
        let absSegUrl = URL(string: t, relativeTo: finalUrl)?.absoluteURL.absoluteString ?? t
        parsedSegments.append((
          inf: pendingInf ?? "#EXTINF:10.0,",
          url: absSegUrl,
          discontinuity: pendingDiscontinuity,
          keyLine: currentKeyLine,
          mapLine: currentMapLine
        ))
        pendingInf = nil
        pendingDiscontinuity = false
      }
    }

    // CRITICAL DISTINCTION:
    // - For VOD / finite playlists (`#EXT-X-ENDLIST` or `#EXT-X-PLAYLIST-TYPE:VOD` or >15 segments, such as 115 / AList movies),
    //   we MUST preserve ALL segments in exact sequential order (`0..<count`) and emit `#EXT-X-ENDLIST` so AVPlayer displays the exact full movie duration and plays sequentially!
    // - ONLY for genuine live TV streams (<=15 segments without `#EXT-X-ENDLIST`) do we use the 6-segment live sliding window (`mergeSlidingSegments`).
    let isVodPlaylist = hasEndListTag || isExplicitVodTag || parsedSegments.count > 15
    if isVodPlaylist {
      headerLines.append("#EXT-X-PLAYLIST-TYPE:VOD")
      headerLines.append(targetDurationLine)
      headerLines.append("#EXT-X-MEDIA-SEQUENCE:0")
      var lastEmittedKey: String? = nil
      var lastEmittedMap: String? = nil
      for seg in parsedSegments {
        if seg.discontinuity {
          headerLines.append("#EXT-X-DISCONTINUITY")
        }
        if seg.keyLine != lastEmittedKey {
          if let k = seg.keyLine {
            headerLines.append(k)
          }
          lastEmittedKey = seg.keyLine
        }
        if seg.mapLine != lastEmittedMap {
          if let m = seg.mapLine {
            headerLines.append(m)
          }
          lastEmittedMap = seg.mapLine
        }
        headerLines.append(seg.inf)
        let enc = seg.url.addingPercentEncoding(withAllowedCharacters: allowed) ?? seg.url
        headerLines.append("http://127.0.0.1:\(localPort)/seg.ts?gen=\(activeGen)&u=\(enc)")
      }
      headerLines.append("#EXT-X-ENDLIST")
      let rewritten = headerLines.joined(separator: "\n") + "\n"
      await store.setCachedVodPlaylist(rewritten, forGen: activeGen)
      return rewritten
    }

    if let k = currentKeyLine {
      headerLines.append(k)
    }
    if let m = currentMapLine {
      headerLines.append(m)
    }
    let simpleSegments = parsedSegments.map { (inf: $0.inf, url: $0.url) }
    let window = await store.mergeSlidingSegments(newSegments: simpleSegments, forGen: activeGen)
    guard !window.isEmpty else { return text }

    let firstSeq = window.first?.seq ?? 1
    headerLines.append(targetDurationLine)
    headerLines.append("#EXT-X-MEDIA-SEQUENCE:\(firstSeq)")

    for seg in window {
      headerLines.append(seg.infLine)
      let enc = seg.absoluteUrl.addingPercentEncoding(withAllowedCharacters: allowed) ?? seg.absoluteUrl
      headerLines.append("http://127.0.0.1:\(localPort)/seg.ts?gen=\(activeGen)&u=\(enc)")
    }

    // Sequentially prefetch up to the first 3 segments so 100% of multi-range bandwidth goes to the current segment first
    let urlsToPrefetch = Array(window.prefix(3).map { $0.absoluteUrl })
    let sessionRef = self.preferredSession(for: activeStreamUrl)
    let fallbackSessionRef = self.directUrlSession
    let storeRef = self.store
    let pTask = Task {
      for segUrl in urlsToPrefetch {
        if Task.isCancelled { break }
        if await storeRef.cachedData(for: segUrl, gen: activeGen) != nil { continue }
        _ = await storeRef.fetchOrJoinSegment(url: segUrl, gen: activeGen) { u, h in
          await Self.downloadSegmentMultiRange(
            urlStr: u,
            headers: h,
            session: sessionRef,
            fallbackDirectSession: fallbackSessionRef
          )
        }
      }
    }
    await store.setPrefetchTask(pTask, forGen: activeGen)

    return headerLines.joined(separator: "\n") + "\n"
  }

  private func fetchRawPlaylist(urlStr: String, headers: [String: String]) async -> (text: String, finalUrl: URL)? {
    var effectiveUrlStr = urlStr
    var logicalFinalUrl = URL(string: urlStr)
    var preferServerProxyFirst = false
    if urlStr.contains("/api/vod/proxy"),
       let comp = URLComponents(string: urlStr),
       let inner = comp.queryItems?.first(where: { $0.name == "url" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
       let innerUrl = URL(string: inner),
       inner.hasPrefix("http") {
      effectiveUrlStr = inner
      logicalFinalUrl = innerUrl
      preferServerProxyFirst = true
    }
    guard let u = URL(string: effectiveUrlStr),
          let logicalBase = logicalFinalUrl else { return nil }

    if preferServerProxyFirst {
      if let srvReq = Self.buildServerProxyFallbackRequest(targetUrl: effectiveUrlStr, headers: headers, timeout: 7.5),
         let (data, resp) = try? await directUrlSession.data(for: srvReq),
         let http = resp as? HTTPURLResponse,
         (200..<300).contains(http.statusCode),
         let text = String(data: data, encoding: .utf8),
         text.contains("#EXTM3U") {
        TvNetworkSpeedMonitor.shared.recordDownstreamBytes(data.count)
        return (text, logicalBase)
      }
    }

    var req = URLRequest(url: u)
    req.httpMethod = "GET"
    req.timeoutInterval = 4.8
    for (k, v) in headers where !v.isEmpty {
      req.setValue(v, forHTTPHeaderField: k)
    }
    let sess = preferredSession(for: effectiveUrlStr)
    let skipDirect = (sess === directUrlSession) && Self.isHostMarkedDirectFailed(u)
    if !skipDirect {
      if let (data, resp) = try? await sess.data(for: req),
         let http = resp as? HTTPURLResponse,
         (200..<300).contains(http.statusCode),
         let finalUrl = resp.url,
         let text = String(data: data, encoding: .utf8),
         text.contains("#EXTM3U") {
        if sess === directUrlSession {
          Self.clearHostDirectFailed(u)
        }
        TvNetworkSpeedMonitor.shared.recordDownstreamBytes(data.count)
        return (text, finalUrl)
      }
      if sess === directUrlSession {
        Self.markHostDirectFailed(u)
      }
    }
    // If proxy node failed or blocked the VOD CDN, immediately fall back to directUrlSession
    if sess !== directUrlSession && !Self.isHostMarkedDirectFailed(u) {
      var directReq = req
      directReq.timeoutInterval = 4.8
      if let (data, resp) = try? await directUrlSession.data(for: directReq),
         let http = resp as? HTTPURLResponse,
         (200..<300).contains(http.statusCode),
         let finalUrl = resp.url,
         let text = String(data: data, encoding: .utf8),
         text.contains("#EXTM3U") {
        Self.clearHostDirectFailed(u)
        TvNetworkSpeedMonitor.shared.recordDownstreamBytes(data.count)
        return (text, finalUrl)
      }
      Self.markHostDirectFailed(u)
    }
    // Fallback to backend server `/api/vod/proxy` when direct/proxy is geo-blocked or SSL-reset (e.g. ukzyvod3.ukubf5.com 403 or tsbfask.com:65)
    if let srvReq = Self.buildServerProxyFallbackRequest(targetUrl: effectiveUrlStr, headers: headers, timeout: 8.5),
       let (data, resp) = try? await directUrlSession.data(for: srvReq),
       let http = resp as? HTTPURLResponse,
       (200..<300).contains(http.statusCode),
       let text = String(data: data, encoding: .utf8),
       text.contains("#EXTM3U") {
      TvNetworkSpeedMonitor.shared.recordDownstreamBytes(data.count)
      return (text, logicalBase)
    }
    return nil
  }

  /// Downloads a `.ts` segment using 8 parallel HTTP Range requests (`HTTP 206 Partial Content`) when supported on throttled overseas IPTV CDNs,
  /// while using a direct single-connection GET for domestic 115 / LAN servers that disallow multi-range splitting,
  /// and falling back to `fallbackDirectSession` or backend `/api/vod/proxy` if direct/proxy times out or is blocked by the CDN.
  private static func downloadSegmentMultiRange(
    urlStr: String,
    headers: [String: String],
    session: URLSession,
    fallbackDirectSession: URLSession? = nil
  ) async -> Data? {
    guard let u = URL(string: urlStr) else { return nil }
    let directSession = fallbackDirectSession ?? session

    // Domestic cloud drives (115) & local LAN servers (or when proxy is disabled) are already fast on a single connection and reject 8-way Range splitting on .ts segments
    if TvLocalProxyTunnelServer.shared.isProxyActive && !isDomesticOrLocalUrl(urlStr) {
      var totalLength = 0
      var supportsRange = false
      do {
        var headReq = URLRequest(url: u)
        headReq.httpMethod = "HEAD"
        headReq.timeoutInterval = 2.2
        for (k, v) in headers where !v.isEmpty {
          headReq.setValue(v, forHTTPHeaderField: k)
        }
        let (_, resp) = try await session.data(for: headReq)
        if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
          totalLength = Int(resp.expectedContentLength)
          let acceptRanges = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? http.value(forHTTPHeaderField: "accept-ranges") ?? "").lowercased()
          supportsRange = acceptRanges.contains("bytes")
        }
      } catch {}

      if totalLength > 320_000 && supportsRange {
        let parts = 8
        let chunkSize = (totalLength + parts - 1) / parts
        let multiResult: Data? = await withTaskGroup(of: (Int, Data?)?.self) { group in
          for i in 0..<parts {
            let start = i * chunkSize
            let end = min(totalLength - 1, (i + 1) * chunkSize - 1)
            if start > end { continue }
            group.addTask {
              for attempt in 0..<2 {
                if Task.isCancelled { return nil }
                var rReq = URLRequest(url: u)
                rReq.httpMethod = "GET"
                rReq.timeoutInterval = attempt == 0 ? 4.5 : 6.0
                for (k, v) in headers where !v.isEmpty {
                  rReq.setValue(v, forHTTPHeaderField: k)
                }
                rReq.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                if let (d, r) = try? await session.data(for: rReq),
                   let h = r as? HTTPURLResponse,
                   h.statusCode == 206,
                   d.count == (end - start + 1) {
                  TvNetworkSpeedMonitor.shared.recordDownstreamBytes(d.count)
                  return (i, d)
                }
              }
              return (i, nil)
            }
          }

          var chunks = Array<Data?>(repeating: nil, count: parts)
          for await item in group {
            guard let (idx, d) = item, let validChunk = d else {
              group.cancelAll()
              return nil
            }
            chunks[idx] = validChunk
          }
          var combined = Data(capacity: totalLength)
          for c in chunks {
            guard let c = c else { return nil }
            combined.append(c)
          }
          return combined.count == totalLength ? combined : nil
        }

        if let fastData = multiResult {
          return stripDisguisedTsImageHeader(fastData)
        }
      }
    }

    // Standard single-connection GET (skip direct if this host already failed direct connection)
    var getReq = URLRequest(url: u)
    getReq.httpMethod = "GET"
    getReq.timeoutInterval = 4.8
    for (k, v) in headers where !v.isEmpty {
      getReq.setValue(v, forHTTPHeaderField: k)
    }
    let skipPrimaryDirect = (session === directSession) && isHostMarkedDirectFailed(u)
    if !skipPrimaryDirect {
      if let (d, r) = try? await session.data(for: getReq),
         let h = r as? HTTPURLResponse,
         (200..<300).contains(h.statusCode),
         !d.isEmpty {
        if session === directSession {
          clearHostDirectFailed(u)
        }
        TvNetworkSpeedMonitor.shared.recordDownstreamBytes(d.count)
        return stripDisguisedTsImageHeader(d)
      }
      if session === directSession {
        markHostDirectFailed(u)
      }
    }

    // Fallback to direct connection if proxy tunnel timed out or was rejected by the video CDN
    if let fbSess = fallbackDirectSession, fbSess !== session, !isHostMarkedDirectFailed(u) {
      var directReq = getReq
      directReq.timeoutInterval = 4.8
      if let (d, r) = try? await fbSess.data(for: directReq),
         let h = r as? HTTPURLResponse,
         (200..<300).contains(h.statusCode),
         !d.isEmpty {
        clearHostDirectFailed(u)
        TvNetworkSpeedMonitor.shared.recordDownstreamBytes(d.count)
        return stripDisguisedTsImageHeader(d)
      }
      markHostDirectFailed(u)
    }

    // Fallback to backend server `/api/vod/proxy` when direct/proxy is blocked or SSL-reset (e.g. tsbfask.com:65 or ukzyvod3.ukubf5.com)
    if let srvReq = buildServerProxyFallbackRequest(targetUrl: urlStr, headers: headers, timeout: 9.0),
       let (d, r) = try? await directSession.data(for: srvReq),
       let h = r as? HTTPURLResponse,
       (200..<300).contains(h.statusCode),
       !d.isEmpty {
      TvNetworkSpeedMonitor.shared.recordDownstreamBytes(d.count)
      return stripDisguisedTsImageHeader(d)
    }
    return nil
  }

  private static func rewriteAttributeUriThroughProxy(
    in line: String,
    baseUrl: URL,
    localPort: UInt16,
    activeGen: Int,
    allowed: CharacterSet
  ) -> String {
    guard let uriRange = line.range(of: "URI=\"") else { return line }
    let afterStart = uriRange.upperBound
    guard let endQuote = line[afterStart...].firstIndex(of: "\"") else { return line }
    let rawUri = String(line[afterStart..<endQuote])
    guard let absUri = URL(string: rawUri, relativeTo: baseUrl)?.absoluteURL.absoluteString else { return line }
    let enc = absUri.addingPercentEncoding(withAllowedCharacters: allowed) ?? absUri
    let proxied = "http://127.0.0.1:\(localPort)/seg.ts?gen=\(activeGen)&u=\(enc)"
    return String(line[..<afterStart]) + proxied + String(line[endQuote...])
  }

  private static func sliceData(_ data: Data, rangeSpec: String) -> (Data, String)? {
    let total = data.count
    guard total > 0 else { return nil }
    let parts = rangeSpec.components(separatedBy: "-")
    guard parts.count == 2, let start = Int(parts[0]), start >= 0, start < total else { return nil }
    let end: Int
    if parts[1].isEmpty {
      end = total - 1
    } else if let parsedEnd = Int(parts[1]) {
      end = min(total - 1, parsedEnd)
    } else {
      return nil
    }
    guard start <= end else { return nil }
    let slice = data.subdata(in: start..<(end + 1))
    return (slice, "bytes \(start)-\(end)/\(total)")
  }

  private func sendResponse(
    conn: NWConnection,
    status: String,
    contentType: String,
    extraHeaders: [String] = [],
    body: Data,
    isHead: Bool
  ) {
    var headerLines = [
      "HTTP/1.1 \(status)",
      "Content-Type: \(contentType)",
      "Content-Length: \(body.count)",
      "Access-Control-Allow-Origin: *",
      "Connection: close"
    ]
    headerLines.append(contentsOf: extraHeaders)
    let headerStr = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
    var payload = Data(headerStr.utf8)
    if !isHead && !body.isEmpty {
      payload.append(body)
    }
    conn.send(content: payload, completion: .contentProcessed { _ in
      conn.cancel()
    })
  }
}

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

final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate {
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

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    // Stop at redirect response so caller can inspect Location header without streaming video body
    completionHandler(nil)
  }
}

final class TvApiClient {
  var baseUrl: String
  var authSecret: String
  var preferDirectPlayback: Bool
  let session: URLSession
  let imageSession: URLSession
  let noRedirectSession: URLSession

  init(baseUrl: String, authSecret: String, preferDirectPlayback: Bool = true) {
    self.baseUrl = TvApiClient.normalizeBaseUrl(baseUrl)
    self.authSecret = authSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    self.preferDirectPlayback = preferDirectPlayback
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 14
    config.timeoutIntervalForResource = 45
    config.httpMaximumConnectionsPerHost = 24
    config.httpShouldSetCookies = true
    self.session = URLSession(
      configuration: config,
      delegate: InsecureSessionDelegate(),
      delegateQueue: nil
    )

    let imgConfig = URLSessionConfiguration.default
    imgConfig.timeoutIntervalForRequest = 12
    imgConfig.timeoutIntervalForResource = 28
    imgConfig.httpMaximumConnectionsPerHost = 16
    imgConfig.httpShouldSetCookies = true
    self.imageSession = URLSession(
      configuration: imgConfig,
      delegate: InsecureSessionDelegate(),
      delegateQueue: nil
    )

    let redirConfig = URLSessionConfiguration.ephemeral
    redirConfig.timeoutIntervalForRequest = 2.5
    redirConfig.timeoutIntervalForResource = 3.5
    self.noRedirectSession = URLSession(
      configuration: redirConfig,
      delegate: NoRedirectSessionDelegate(),
      delegateQueue: nil
    )
    _ = TvLocalHlsProxyServer.shared
  }

  func handleEnterBackground() {
    TvLocalHlsProxyServer.shared.handleEnterBackground()
  }

  func handleEnterForeground() {
    session.flush {}
    imageSession.flush {}
    noRedirectSession.flush {}
    TvLocalHlsProxyServer.shared.handleEnterForeground()
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
      "Accept": "application/json",
      "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    ]
    let cookie = cookieHeaderValue
    if !cookie.isEmpty {
      headers["Cookie"] = cookie
    }
    return headers
  }

  func makeEndpointUrl(_ path: String, queryItems: [URLQueryItem] = []) -> URL? {
    let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
    guard var components = URLComponents(string: "\(baseUrl)\(normalizedPath)") else {
      return nil
    }
    if !queryItems.isEmpty {
      components.queryItems = (components.queryItems ?? []) + queryItems
    }
    return components.url
  }

  func buildProxiedImageUrl(_ rawUrl: String) -> String {
    let trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    if trimmed.hasPrefix("/api/vod/image") {
      return "\(baseUrl)\(trimmed)"
    }
    if trimmed.contains("/api/telegram/") {
      return trimmed.hasPrefix("http") ? trimmed : "\(baseUrl)\(trimmed)"
    }
    return makeEndpointUrl("/api/vod/image", queryItems: [URLQueryItem(name: "url", value: trimmed)])?.absoluteString ?? trimmed
  }

  private static let inlineHeaderRegex: NSRegularExpression? = try? NSRegularExpression(
    pattern: "@(Referer|Referrer|User-Agent|UA|Cookie|Origin|Authorization|Accept)=",
    options: [.caseInsensitive]
  )

  private static let cctvMatchRegex: NSRegularExpression? = try? NSRegularExpression(
    pattern: "^CCTV(\\d+\\+?)"
  )

  private var liveChannelListCache: [String: [TvLiveChannel]] = [:]
  private var redirectUrlCache: [String: (url: String, expiresAt: Date)] = [:]

  nonisolated static func splitUrlAndInlineHeaders(_ rawUrl: String) -> (cleanUrl: String, headers: [String: String]) {
    var working = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !working.isEmpty else { return ("", [:]) }

    // Ultra-fast path for standard URLs without inline @Header=, |Header=, or $suffix
    if !working.contains("@") && !working.contains("|") && !working.contains("$") {
      while working.hasSuffix("?") {
        working.removeLast()
      }
      return (working, [:])
    }

    if working.contains("$"), !working.hasPrefix("http") {
      let parts = working.components(separatedBy: "$")
      if let last = parts.last, last.hasPrefix("http") {
        working = last.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }

    var headers: [String: String] = [:]
    func putHeader(_ rawKey: String, _ rawVal: String) {
      let k = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
      let v = (rawVal.removingPercentEncoding ?? rawVal).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !k.isEmpty, !v.isEmpty else { return }
      let lower = k.lowercased()
      if lower == "user-agent" || lower == "ua" {
        headers["User-Agent"] = v
      } else if lower == "referer" || lower == "referrer" {
        headers["Referer"] = v
      } else if lower == "origin" {
        headers["Origin"] = v
      } else if lower == "cookie" {
        headers["Cookie"] = v
      } else {
        headers[k] = v
      }
    }

    if working.contains("@"), let regex = inlineHeaderRegex {
      let nsWorking = working as NSString
      let matches = regex.matches(in: working, range: NSRange(location: 0, length: nsWorking.length))
      if let first = matches.first {
        for (i, m) in matches.enumerated() {
          let key = nsWorking.substring(with: m.range(at: 1))
          let valStart = m.range.location + m.range.length
          let valEnd = (i + 1 < matches.count) ? matches[i + 1].range.location : nsWorking.length
          if valEnd > valStart {
            var val = nsWorking.substring(with: NSRange(location: valStart, length: valEnd - valStart))
            if let pIdx = val.firstIndex(of: "|") {
              val = String(val[..<pIdx])
            }
            putHeader(key, val)
          }
        }
        working = nsWorking.substring(to: first.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }

    if let pipeIdx = working.firstIndex(of: "|") {
      let tail = String(working[working.index(after: pipeIdx)...])
      working = String(working[..<pipeIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
      for kv in tail.components(separatedBy: "&") {
        if let eq = kv.firstIndex(of: "=") {
          putHeader(String(kv[..<eq]), String(kv[kv.index(after: eq)...]))
        }
      }
    }

    if let dollarIdx = working.firstIndex(of: "$"), working.hasPrefix("http") {
      working = String(working[..<dollarIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    while working.hasSuffix("?") {
      working.removeLast()
    }
    return (working, headers)
  }

  func requestJson(
    url: URL,
    method: String = "GET",
    body: Any? = nil,
    extraHeaders: [String: String] = [:],
    includeAuth: Bool = true,
    timeout: TimeInterval = 22
  ) async throws -> Any {
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = timeout
    if includeAuth {
      for (k, v) in authHeaders {
        req.setValue(v, forHTTPHeaderField: k)
      }
    } else {
      req.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
        forHTTPHeaderField: "User-Agent"
      )
      req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
    }
    for (k, v) in extraHeaders {
      req.setValue(v, forHTTPHeaderField: k)
    }
    if let body = body {
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      req.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await session.data(for: req)
    if let http = response as? HTTPURLResponse {
      if http.statusCode == 401 || http.statusCode == 403 {
        throw NSError(
          domain: "TvApiClient",
          code: http.statusCode,
          userInfo: [NSLocalizedDescriptionKey: "登录认证失败 (\(http.statusCode))，请检查服务器地址与访问密码"]
        )
      }
      if http.statusCode < 200 || http.statusCode >= 300 {
        var msg = "请求失败 (HTTP \(http.statusCode))"
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = dict["error"] as? String, !err.isEmpty {
          msg = err
        }
        throw NSError(domain: "TvApiClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
      }
    }
    if data.isEmpty { return [:] as [String: Any] }
    if let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
      return obj
    }
    if let str = String(data: data, encoding: .utf8),
       let brace = str.firstIndex(of: "{"),
       let sliceData = String(str[brace...]).data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: sliceData, options: [.fragmentsAllowed]) {
      return obj
    }
    throw NSError(domain: "TvApiClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "返回数据格式无法解析"])
  }

  func login(password: String) async -> Bool {
    guard let url = makeEndpointUrl("/api/login") else { return false }
    do {
      var req = URLRequest(url: url)
      req.httpMethod = "POST"
      req.timeoutInterval = 12
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      req.httpBody = try JSONSerialization.data(withJSONObject: ["password": password])
      let (_, response) = try await session.data(for: req)
      if let http = response as? HTTPURLResponse, http.statusCode == 200 {
        self.authSecret = password
        return true
      }
      return false
    } catch {
      return false
    }
  }

  // MARK: - 1. VOD Sources / List / Search / Detail

  func fetchVodSources() async throws -> [TvVodSource] {
    var results: [TvVodSource] = []

    if let settingsUrl = makeEndpointUrl("/api/settings"),
       let json = try? await requestJson(url: settingsUrl) as? [String: Any],
       let rawCustom = json["vod_sources"] as? [[String: Any]] {
      for (idx, item) in rawCustom.enumerated() {
        let name = Self.stringValue(item["name"], fallback: "资源站 \(idx + 1)")
        let api = Self.stringValue(item["api"], fallback: Self.stringValue(item["url"])).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !api.isEmpty else { continue }
        results.append(
          TvVodSource(
            id: "custom_\(idx)",
            name: name,
            api: api,
            isTvBox: false,
            customIndex: idx,
            tvboxType: 1,
            tvboxSiteIndex: -1,
            tvboxSourceIndex: -1,
            tvboxSourceName: "",
            searchable: true
          )
        )
      }
    }

    if let tvboxUrl = makeEndpointUrl("/api/tvbox/sites"),
       let rawAny = try? await requestJson(url: tvboxUrl) {
      let rawSites: [[String: Any]]
      if let arr = rawAny as? [[String: Any]] {
        rawSites = arr
      } else if let dict = rawAny as? [String: Any], let arr = dict["sites"] as? [[String: Any]] {
        rawSites = arr
      } else {
        rawSites = []
      }

      for (idx, item) in rawSites.enumerated() {
        let type = Self.intValue(item["type"], fallback: 1)
        let api = Self.stringValue(item["api"]).trimmingCharacters(in: .whitespacesAndNewlines)
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

  private func canDirectCms(_ source: TvVodSource) -> Bool {
    guard preferDirectPlayback, !source.isTvBox else { return false }
    let api = source.api.trimmingCharacters(in: .whitespacesAndNewlines)
    guard api.hasPrefix("http://") || api.hasPrefix("https://") else { return false }
    if api.contains("://127.0.0.1") || api.contains("://localhost") { return false }
    let lower = api.lowercased()
    if lower.hasSuffix(".js") || lower.hasSuffix(".py") || lower.contains("/xml") {
      return false
    }
    return true
  }

  private func makeDirectCmsUrl(_ api: String, params: [URLQueryItem]) -> URL? {
    guard var comp = URLComponents(string: api) else { return nil }
    var existing = (comp.queryItems ?? []).filter { item in
      !(params.contains(where: { $0.name == "ac" }) && item.name == "ac")
    }
    existing.append(contentsOf: params)
    comp.queryItems = existing
    return comp.url
  }

  func fetchVodList(
    source: TvVodSource,
    page: Int = 1,
    typeId: String? = nil
  ) async throws -> TvVodListResponse {
    let cleanTypeId = (typeId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

    if canDirectCms(source) {
      var detailParams = [
        URLQueryItem(name: "ac", value: "detail"),
        URLQueryItem(name: "pg", value: String(page)),
      ]
      if !cleanTypeId.isEmpty {
        detailParams.append(URLQueryItem(name: "t", value: cleanTypeId))
      }
      if let directUrl = makeDirectCmsUrl(source.api, params: detailParams),
         let dict = try? await requestJson(url: directUrl, includeAuth: false, timeout: 6) as? [String: Any],
         let rawList = dict["list"] as? [[String: Any]],
         !rawList.isEmpty {
        var rawClasses = (dict["class"] as? [[String: Any]]) ?? []
        if rawClasses.isEmpty, page == 1, cleanTypeId.isEmpty,
           let listUrl = makeDirectCmsUrl(
             source.api,
             params: [URLQueryItem(name: "ac", value: "list"), URLQueryItem(name: "pg", value: "1")]
           ),
           let classDict = try? await requestJson(url: listUrl, includeAuth: false, timeout: 5) as? [String: Any],
           let fetchedClasses = classDict["class"] as? [[String: Any]] {
          rawClasses = fetchedClasses
        }
        let parsed = Self.parseVodListDict(dict, overrideClasses: rawClasses, source: source, page: page)
        if !parsed.items.isEmpty {
          return parsed
        }
      }
    }

    var query = source.queryItems + [URLQueryItem(name: "pg", value: String(page))]
    if !cleanTypeId.isEmpty {
      query.append(URLQueryItem(name: "t", value: cleanTypeId))
    }
    guard let url = makeEndpointUrl("/api/vod/list", queryItems: query) else {
      return TvVodListResponse(categories: [], items: [], pageCount: 1, resolvedTypeId: nil)
    }

    if let dict = try? await requestJson(url: url, timeout: source.isTvBox ? 28 : 20) as? [String: Any] {
      var parsed = Self.parseVodListDict(dict, overrideClasses: nil, source: source, page: page)
      // Auto-fetch first category if TVBox spider returns empty home list but non-empty categories
      if cleanTypeId.isEmpty && page == 1 && parsed.items.isEmpty && !parsed.categories.isEmpty {
        let firstCatId = parsed.categories[0].typeId
        if !firstCatId.isEmpty {
          let catQuery = source.queryItems + [
            URLQueryItem(name: "pg", value: "1"),
            URLQueryItem(name: "t", value: firstCatId),
          ]
          if let catUrl = makeEndpointUrl("/api/vod/list", queryItems: catQuery),
             let catDict = try? await requestJson(url: catUrl, timeout: 25) as? [String: Any] {
            let catParsed = Self.parseVodListDict(catDict, overrideClasses: nil, source: source, page: 1)
            if !catParsed.items.isEmpty {
              parsed = TvVodListResponse(
                categories: parsed.categories,
                items: catParsed.items,
                pageCount: catParsed.pageCount,
                resolvedTypeId: firstCatId
              )
            }
          }
        }
      }
      if !parsed.items.isEmpty || !parsed.categories.isEmpty {
        return parsed
      }
    }

    // Fallback for TVBox type==1 standard HTTP CMS JSON
    if source.isTvBox && source.tvboxType == 1 && (source.api.hasPrefix("http://") || source.api.hasPrefix("https://")) {
      var detailParams = [
        URLQueryItem(name: "ac", value: "detail"),
        URLQueryItem(name: "pg", value: String(page)),
      ]
      if !cleanTypeId.isEmpty {
        detailParams.append(URLQueryItem(name: "t", value: cleanTypeId))
      }
      if let directUrl = makeDirectCmsUrl(source.api, params: detailParams),
         let dict = try? await requestJson(url: directUrl, includeAuth: false, timeout: 7) as? [String: Any] {
        return Self.parseVodListDict(dict, overrideClasses: nil, source: source, page: page)
      }
    }

    return TvVodListResponse(categories: [], items: [], pageCount: 1, resolvedTypeId: nil)
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
       let dict = try? await requestJson(url: directUrl, includeAuth: false, timeout: 6) as? [String: Any],
       let rawList = dict["list"] as? [[String: Any]],
       !rawList.isEmpty {
      return rawList.compactMap { Self.parseVodItem($0, source: source) }
    }

    let query = source.queryItems + [URLQueryItem(name: "wd", value: trimmed)]
    if let url = makeEndpointUrl("/api/vod/search", queryItems: query),
       let dict = try? await requestJson(url: url, timeout: source.isTvBox ? 22 : 15) as? [String: Any],
       let rawList = dict["list"] as? [[String: Any]],
       !rawList.isEmpty {
      return rawList.compactMap { Self.parseVodItem($0, source: source) }
    }

    if source.isTvBox && source.tvboxType == 1,
       let directUrl = makeDirectCmsUrl(
         source.api,
         params: [
           URLQueryItem(name: "ac", value: "detail"),
           URLQueryItem(name: "wd", value: trimmed),
         ]
       ),
       let dict = try? await requestJson(url: directUrl, includeAuth: false, timeout: 6) as? [String: Any],
       let rawList = dict["list"] as? [[String: Any]] {
      return rawList.compactMap { Self.parseVodItem($0, source: source) }
    }

    return []
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
       let dict = try? await requestJson(url: directUrl, includeAuth: false, timeout: 5) as? [String: Any],
       let rawList = dict["list"] as? [[String: Any]],
       let first = rawList.first {
      let detail = Self.parseVodDetail(first)
      if !detail.playGroups.isEmpty {
        return detail
      }
    }

    let query = source.queryItems + [URLQueryItem(name: "ids", value: vodId)]
    if let url = makeEndpointUrl("/api/vod/detail", queryItems: query),
       let dict = try? await requestJson(url: url, timeout: source.isTvBox ? 28 : 20) as? [String: Any],
       let rawList = dict["list"] as? [[String: Any]],
       let first = rawList.first {
      return Self.parseVodDetail(first)
    }

    if source.isTvBox && source.tvboxType == 1,
       let directUrl = makeDirectCmsUrl(
         source.api,
         params: [
           URLQueryItem(name: "ac", value: "detail"),
           URLQueryItem(name: "ids", value: vodId),
         ]
       ),
       let dict = try? await requestJson(url: directUrl, includeAuth: false, timeout: 6) as? [String: Any],
       let rawList = dict["list"] as? [[String: Any]],
       let first = rawList.first {
      return Self.parseVodDetail(first)
    }

    return nil
  }

  // MARK: - 2. Playback URL Resolution & M3U8 Ad Stripping

  static func isDirectPlayableUrl(_ rawUrl: String) -> Bool {
    let split = splitUrlAndInlineHeaders(rawUrl)
    guard let uri = URL(string: split.cleanUrl),
          let scheme = uri.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
      return false
    }
    let pathLower = uri.path.lowercased()
    if pathLower.hasSuffix(".html") || pathLower.hasSuffix(".htm") || pathLower.hasSuffix(".shtml") {
      return false
    }
    return pathLower.hasSuffix(".m3u8")
      || pathLower.hasSuffix(".mp4")
      || pathLower.hasSuffix(".flv")
      || pathLower.hasSuffix(".ts")
      || pathLower.hasSuffix(".mkv")
      || pathLower.contains(".m3u8/")
      || (uri.query?.lowercased().contains(".m3u8") ?? false)
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
    rawUrl: String,
    forceServerRelay: Bool = false
  ) async -> TvResolvedPlayback {
    let extracted = Self.splitUrlAndInlineHeaders(rawUrl)
    if !forceServerRelay && preferDirectPlayback && Self.isDirectPlayableUrl(rawUrl) {
      var headers: [String: String] = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
      ]
      for (k, v) in extracted.headers { headers[k] = v }
      let proxy = buildServerProxyUrl(targetUrl: extracted.cleanUrl, headers: headers)
      return TvResolvedPlayback(
        directUrl: extracted.cleanUrl,
        serverProxyUrl: proxy,
        headers: headers,
        parseVia: "客户端零延迟直连",
        backendProxyPlayback: false
      )
    }

    let query = source.queryItems + [
      URLQueryItem(name: "flag", value: playFrom),
      URLQueryItem(name: "id", value: rawUrl),
    ]
    if let url = makeEndpointUrl("/api/vod/play", queryItems: query),
       let dict = try? await requestJson(url: url, timeout: source.isTvBox ? 14 : 10) as? [String: Any] {
      var headers: [String: String] = extracted.headers
      let rawHeaderMap = (dict["header"] as? [String: Any]) ?? (dict["headers"] as? [String: Any]) ?? [:]
      for (k, v) in rawHeaderMap {
        let sv = Self.stringValue(v)
        if !sv.isEmpty { headers[k] = sv }
      }

      let rawDirect = Self.stringValue(dict["direct_url"], fallback: Self.stringValue(dict["url"]))
      let splitDirect = Self.splitUrlAndInlineHeaders(rawDirect)
      for (k, v) in splitDirect.headers { headers[k] = v }
      var direct = splitDirect.cleanUrl
      var serverProxy = Self.stringValue(dict["server_proxy_url"], fallback: Self.stringValue(dict["proxy_url"]))

      if serverProxy.hasPrefix("/") {
        serverProxy = "\(baseUrl)\(serverProxy)"
      }
      if direct.isEmpty {
        direct = !serverProxy.isEmpty ? serverProxy : extracted.cleanUrl
      }
      if serverProxy.isEmpty {
        serverProxy = buildServerProxyUrl(targetUrl: direct, headers: headers)
      }

      var backendProxy = forceServerRelay
      if !backendProxy, direct.isEmpty {
        if (dict["force_proxy"] as? Bool) == true {
          backendProxy = true
        } else if let cfg = dict["player_config"] as? [String: Any],
                  (cfg["backend_proxy_playback"] as? Bool) == true {
          backendProxy = true
        }
      }

      return TvResolvedPlayback(
        directUrl: backendProxy ? serverProxy : direct,
        serverProxyUrl: serverProxy,
        headers: headers,
        parseVia: forceServerRelay ? "服务端代理中转" : Self.stringValue(dict["parse_via"], fallback: "服务端解析"),
        backendProxyPlayback: backendProxy
      )
    }

    let fallbackProxy = buildServerProxyUrl(targetUrl: extracted.cleanUrl, headers: extracted.headers)
    return TvResolvedPlayback(
      directUrl: forceServerRelay ? fallbackProxy : extracted.cleanUrl,
      serverProxyUrl: fallbackProxy,
      headers: extracted.headers,
      parseVia: "直连回退",
      backendProxyPlayback: forceServerRelay
    )
  }

  func prepareAdFilteredStreamIfPossible(
    streamUrl: String,
    headers: [String: String],
    enableAdFilter: Bool
  ) async -> String {
    // AVPlayer on tvOS/iOS forbids loading HLS `.m3u8` playlists from `file://` URLs.
    // Discontinuity ad stripping is now performed in-memory inside `TvLocalHlsProxyServer.fetchAndRewritePlaylist`
    // and served over `http://127.0.0.1:<port>/live.m3u8`.
    return streamUrl
  }

  static func stripDiscontinuityAdsAndAbsolutize(m3u8Text: String, baseUrl: URL) -> String {
    let lines = m3u8Text.components(separatedBy: .newlines)
    var headerLines: [String] = []
    struct Block {
      var lines: [String] = []
      var segmentCount: Int = 0
      var durationSum: Double = 0
      var entryKeyLine: String? = nil
    }
    var blocks: [Block] = [Block()]
    var seenFirstSegmentOrDiscontinuity = false
    var activeKeyLine: String? = nil

    for rawLine in lines {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty { continue }
      let upper = line.uppercased()

      if upper.hasPrefix("#EXT-X-DISCONTINUITY") && !upper.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
        seenFirstSegmentOrDiscontinuity = true
        var nextBlock = Block()
        nextBlock.entryKeyLine = activeKeyLine
        blocks.append(nextBlock)
        continue
      }

      if upper.hasPrefix("#EXT-X-KEY") {
        activeKeyLine = line
        seenFirstSegmentOrDiscontinuity = true
        blocks[blocks.count - 1].lines.append(line)
        continue
      }

      if !seenFirstSegmentOrDiscontinuity && line.hasPrefix("#") && !upper.hasPrefix("#EXTINF") {
        headerLines.append(line)
        continue
      }

      seenFirstSegmentOrDiscontinuity = true
      if upper.hasPrefix("#EXTINF:") {
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
    var emittedBlockCount = 0
    for b in nonEmptyBlocks {
      let isLikelyAd = b.segmentCount <= 5 && b.durationSum <= 28.0 && nonEmptyBlocks.count >= 2
      if isLikelyAd { continue }
      if emittedBlockCount > 0 {
        out.append("#EXT-X-DISCONTINUITY")
      }
      let firstHasKey = b.lines.first?.uppercased().hasPrefix("#EXT-X-KEY") == true
      if !firstHasKey, let entryKey = b.entryKeyLine {
        out.append(entryKey)
      }
      out.append(contentsOf: b.lines)
      emittedBlockCount += 1
    }
    if !out.contains(where: { $0.hasPrefix("#EXT-X-ENDLIST") }) {
      out.append("#EXT-X-ENDLIST")
    }
    return out.joined(separator: "\n")
  }

  // MARK: - 3. Live TV Sources & Channels

  func fetchLiveSources() async -> [TvLiveSource] {
    guard let url = makeEndpointUrl("/api/tvbox/lives"),
          let rawAny = try? await requestJson(url: url, timeout: 25) else {
      return []
    }
    let rawLives: [[String: Any]]
    if let arr = rawAny as? [[String: Any]] {
      rawLives = arr
    } else if let dict = rawAny as? [String: Any], let arr = dict["lives"] as? [[String: Any]] {
      rawLives = arr
    } else {
      rawLives = []
    }
    return rawLives.enumerated().map { idx, item in
      TvLiveSource(
        name: Self.stringValue(item["name"], fallback: "直播源 \(idx + 1)"),
        url: Self.stringValue(item["url"]),
        ua: Self.stringValue(item["ua"]),
        origin: Self.stringValue(item["origin"]),
        referer: Self.stringValue(item["referer"]),
        sourceName: Self.stringValue(item["source_name"]),
        sourceIndex: Self.intValue(item["source_index"], fallback: 0),
        liveIndex: Self.intValue(item["live_index"], fallback: idx),
        isCustom: (item["is_custom"] as? Bool) == true
      )
    }
  }

  private func buildCandidateLivePlaylistUrls(_ rawUrl: String) -> [String] {
    let trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    var list: [String] = []
    func addUnique(_ u: String) {
      let c = u.trimmingCharacters(in: .whitespacesAndNewlines)
      if !c.isEmpty && !list.contains(c) {
        list.append(c)
      }
    }

    // Extract canonical raw.githubusercontent.com URL even if wrapped in ghfast.top / gh-proxy.com / ghproxy.net
    var canonicalRawGhUrl: String? = nil
    if let r = trimmed.range(of: "https://raw.githubusercontent.com/", options: .caseInsensitive) {
      canonicalRawGhUrl = String(trimmed[r.lowerBound...])
    } else if let r = trimmed.range(of: "http://raw.githubusercontent.com/", options: .caseInsensitive) {
      canonicalRawGhUrl = "https://" + String(trimmed[r.lowerBound...].dropFirst(7))
    } else if let r = trimmed.range(of: "raw.githubusercontent.com/", options: .caseInsensitive) {
      canonicalRawGhUrl = "https://" + String(trimmed[r.lowerBound...])
    }

    if let rawGh = canonicalRawGhUrl {
      addUnique("https://gh-proxy.com/\(rawGh)")
      addUnique(rawGh)
      addUnique(trimmed)
      addUnique("https://ghfast.top/\(rawGh)")
    } else {
      addUnique(trimmed)
    }
    return list
  }

  /// Races candidate playlist URLs in parallel and returns the first valid M3U/TXT body (1:1 match with _fetchPlaylistTextFastest in api_client.dart)
  private func fetchLivePlaylistText(from candidates: [String], headers: [String: String], timeout: TimeInterval = 7) async -> String? {
    guard !candidates.isEmpty else { return nil }
    let sessionRef = self.session
    return await withTaskGroup(of: String?.self) { group in
      for urlStr in candidates {
        group.addTask {
          guard let directUrl = URL(string: urlStr) else { return nil }
          do {
            var req = URLRequest(url: directUrl)
            req.timeoutInterval = timeout
            for (k, v) in headers {
              req.setValue(v, forHTTPHeaderField: k)
            }
            let (data, response) = try await sessionRef.data(for: req)
            if let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode),
               let body = String(data: data, encoding: .utf8) {
              let clean = body.trimmingCharacters(in: .whitespacesAndNewlines)
              if !clean.isEmpty
                  && !clean.hasPrefix("<!DOCTYPE")
                  && !clean.lowercased().hasPrefix("<html")
                  && (clean.contains("#EXTM3U") || clean.contains("#EXTINF") || clean.contains("#genre#") || clean.contains("://")) {
                return clean
              }
            }
          } catch {}
          return nil
        }
      }
      for await res in group {
        if let valid = res, !valid.isEmpty {
          group.cancelAll()
          return valid
        }
      }
      return nil
    }
  }

  func fetchLiveChannels(source: TvLiveSource, forceRefresh: Bool = false) async -> [TvLiveChannel] {
    if !forceRefresh, let cached = liveChannelListCache[source.id], !cached.isEmpty {
      return cached
    }

    let srcUrl = source.url.trimmingCharacters(in: .whitespacesAndNewlines)
    let isLoopback = srcUrl.contains("://127.0.0.1") || srcUrl.contains("://localhost")
    let isFanmingming = srcUrl.lowercased().contains("fanmingming/live")
      || source.name.lowercased().contains("fanmingming")
      || source.name.uppercased().contains("IPV6")
    let defaultHeaders = source.defaultHeaders

    if !srcUrl.isEmpty && !isLoopback {
      var combinedParts: [String] = []
      if isFanmingming {
        let supUrls = [
          "https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/result.m3u",
          "https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/ipv6/result.m3u",
        ]
        for supUrl in supUrls {
          if let supText = await fetchLivePlaylistText(
            from: buildCandidateLivePlaylistUrls(supUrl),
            headers: defaultHeaders,
            timeout: 5.5
          ), !supText.isEmpty {
            combinedParts.append(supText)
          }
        }
      }
      if let body = await fetchLivePlaylistText(
        from: buildCandidateLivePlaylistUrls(srcUrl),
        headers: defaultHeaders,
        timeout: 6.5
      ), !body.isEmpty {
        combinedParts.append(body)
      }
      if !combinedParts.isEmpty {
        let joinedText = combinedParts.joined(separator: "\n")
        let parsed = await Task.detached(priority: .userInitiated) {
          Self.parseLivePlaylistText(joinedText, defaultHeaders: defaultHeaders)
        }.value
        if !parsed.isEmpty {
          liveChannelListCache[source.id] = parsed
          return parsed
        }
      }
    }

    let query = [
      URLQueryItem(name: "tvbox_source", value: String(source.sourceIndex)),
      URLQueryItem(name: "tvbox_live", value: String(source.liveIndex)),
    ]
    guard let url = makeEndpointUrl("/api/tvbox/live/channels", queryItems: query),
          let rawAny = try? await requestJson(url: url, timeout: 18) else {
      return []
    }

    if let rawList = rawAny as? [[String: Any]] {
      let parsed = rawList.compactMap { item -> TvLiveChannel? in
        let name = Self.stringValue(item["name"], fallback: "未命名频道")
        let group = Self.normalizeLiveGroupName(Self.stringValue(item["group"], fallback: "默认频道"))
        let logo = Self.stringValue(item["logo"])
        let rawUrls = (item["urls"] as? [Any])?.map { Self.stringValue($0) }.filter { !$0.isEmpty } ?? []
        guard !rawUrls.isEmpty else { return nil }
        var headers = defaultHeaders
        if let hMap = item["headers"] as? [String: Any] {
          for (k, v) in hMap {
            let sv = Self.stringValue(v)
            if !sv.isEmpty { headers[k] = sv }
          }
        }
        return TvLiveChannel(
          name: name,
          group: group,
          urls: Self.prioritizeLiveUrlsForAppleTv(rawUrls),
          logo: logo,
          headers: headers
        )
      }
      if !parsed.isEmpty { liveChannelListCache[source.id] = parsed }
      return parsed
    }

    if let dict = rawAny as? [String: Any], let rawGroups = dict["groups"] as? [[String: Any]] {
      var channels: [TvLiveChannel] = []
      for g in rawGroups {
        let groupName = Self.normalizeLiveGroupName(Self.stringValue(g["group"], fallback: "默认频道"))
        let rawChs = (g["channels"] as? [[String: Any]]) ?? []
        for ch in rawChs {
          let name = Self.stringValue(ch["name"], fallback: "未命名频道")
          let logo = Self.stringValue(ch["logo"])
          let urls = (ch["urls"] as? [Any])?.map { Self.stringValue($0) }.filter { !$0.isEmpty } ?? []
          if !urls.isEmpty {
            channels.append(
              TvLiveChannel(
                name: name,
                group: groupName,
                urls: Self.prioritizeLiveUrlsForAppleTv(urls),
                logo: logo,
                headers: defaultHeaders
              )
            )
          }
        }
      }
      if !channels.isEmpty { liveChannelListCache[source.id] = channels }
      return channels
    }
    return []
  }

  /// Prioritizes IPv4 HLS (.m3u8) streams first for Apple TV's AVPlayer, and pushes known dead archived [2409:8087:8:21::18]:6610 URLs to the very end.
  nonisolated static func prioritizeLiveUrlsForAppleTv(_ urls: [String]) -> [String] {
    let hasActiveUrls = urls.contains { !$0.contains("[2409:8087:8:21::18]:6610") }
    let filtered = hasActiveUrls
      ? urls.filter { !$0.contains("[2409:8087:8:21::18]:6610") }
      : urls

    func score(_ raw: String) -> Int {
      if raw.contains("[2409:8087:8:21::18]:6610") { return 99 }
      let lower = raw.lowercased()
      let isIpv6 = lower.contains("://[")
      let isFlv = lower.contains(".flv")
      let isM3u8 = lower.contains(".m3u8")
      // Preserve speed-tested order of all IPv4 .m3u8 URLs from the live playlist
      if !isIpv6 && isM3u8 { return 0 }
      if !isIpv6 && !isFlv { return 1 }
      if isIpv6 && isM3u8 { return 2 }
      if !isIpv6 && isFlv { return 3 }
      return 4
    }
    return filtered.enumerated().sorted { a, b in
      let sa = score(a.element)
      let sb = score(b.element)
      if sa != sb { return sa < sb }
      return a.offset < b.offset
    }.map { $0.element }
  }

  /// Strips emoji prefixes from live group titles (e.g. `📺央视频道` -> `央视频道`) so Guovin and fanmingming groups merge cleanly
  nonisolated static func normalizeLiveGroupName(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "默认分组" }
    let filteredScalars = trimmed.unicodeScalars.filter { scalar in
      if scalar.isASCII { return true }
      let v = scalar.value
      if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x3000...0x303F).contains(v) || (0xFF00...0xFFEF).contains(v) {
        return true
      }
      return false
    }
    let clean = String(String.UnicodeScalarView(filteredScalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    return clean.isEmpty ? trimmed : clean
  }

  /// Normalizes channel names (`CCTV-1`, `CCTV1`, `CCTV-1 综合` -> `CCTV1`) to merge signal lines across playlists (1:1 match with api_client.dart)
  nonisolated static func normalizeChannelMatchKey(_ name: String) -> String {
    let upper = name.uppercased()
      .replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: "_", with: "")
    if upper.hasPrefix("CCTV"),
       let regex = cctvMatchRegex,
       let match = regex.firstMatch(in: upper, range: NSRange(location: 0, length: (upper as NSString).length)) {
      let num = (upper as NSString).substring(with: match.range(at: 1))
      return "CCTV\(num)"
    }
    return upper
  }

  nonisolated static func parseLivePlaylistText(_ content: String, defaultHeaders: [String: String]) -> [TvLiveChannel] {
    let lines = content.components(separatedBy: .newlines)
    let isM3u = content.contains("#EXTM3U") || content.contains("#EXTINF")
    var groupedMap: [String: TvLiveChannel] = [:]
    var matchKeyToOrderedKey: [String: String] = [:]
    var orderedKeys: [String] = []

    func addChannel(name: String, group: String, urls: [String], logo: String, headers: [String: String]) {
      let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "直播频道"
        : name.trimmingCharacters(in: .whitespacesAndNewlines)
      let cleanGroup = normalizeLiveGroupName(group)

      if cleanGroup.contains("更新时间") || cleanGroup.contains("公告") || cleanName.contains("更新时间") {
        return
      }
      if urls.contains(where: { $0.contains("feiyang666999/testvideo") }) {
        return
      }

      var extractedHeaders = headers
      var validUrls: [String] = []
      for raw in urls {
        let split = splitUrlAndInlineHeaders(raw)
        for (hk, hv) in split.headers {
          extractedHeaders[hk] = hv
        }
        let u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if split.cleanUrl.hasPrefix("http://") || split.cleanUrl.hasPrefix("https://") {
          validUrls.append(u)
        }
      }
      guard !validUrls.isEmpty else { return }

      let matchKey = normalizeChannelMatchKey(cleanName)
      let key = matchKeyToOrderedKey[matchKey] ?? "\(cleanGroup)@@\(cleanName)"
      if matchKeyToOrderedKey[matchKey] == nil {
        matchKeyToOrderedKey[matchKey] = key
      }

      if let existing = groupedMap[key] {
        var merged = existing.urls
        for u in validUrls where !merged.contains(u) {
          merged.append(u)
        }
        groupedMap[key] = TvLiveChannel(
          name: existing.name,
          group: existing.group,
          urls: prioritizeLiveUrlsForAppleTv(merged),
          logo: existing.logo.isEmpty ? logo : existing.logo,
          headers: existing.headers.merging(extractedHeaders) { _, new in new }
        )
      } else {
        orderedKeys.append(key)
        groupedMap[key] = TvLiveChannel(
          name: cleanName,
          group: cleanGroup,
          urls: prioritizeLiveUrlsForAppleTv(validUrls),
          logo: logo,
          headers: extractedHeaders
        )
      }
    }

    if isM3u {
      var currentName = "频道"
      var currentGroup = "默认分组"
      var currentLogo = ""
      var currentHeaders = defaultHeaders

      for raw in lines {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { continue }
        if line.hasPrefix("#EXTINF") {
          currentName = line.components(separatedBy: ",").last?.trimmingCharacters(in: .whitespaces) ?? "频道"
          currentGroup = extractAttr(line, key: "group-title") ?? "默认分组"
          currentLogo = extractAttr(line, key: "tvg-logo") ?? ""
          if let ua = extractAttr(line, key: "http-user-agent") ?? extractAttr(line, key: "user-agent"), !ua.isEmpty {
            currentHeaders["User-Agent"] = ua
          }
          if let ref = extractAttr(line, key: "http-referrer") ?? extractAttr(line, key: "referer"), !ref.isEmpty {
            currentHeaders["Referer"] = ref
          }
        } else if line.uppercased().hasPrefix("#EXTVLCOPT:") {
          let opt = String(line.dropFirst(11)).trimmingCharacters(in: .whitespaces)
          if opt.lowercased().hasPrefix("http-user-agent=") {
            currentHeaders["User-Agent"] = String(opt.dropFirst(16)).trimmingCharacters(in: .whitespaces)
          } else if opt.lowercased().hasPrefix("http-referrer=") {
            currentHeaders["Referer"] = String(opt.dropFirst(14)).trimmingCharacters(in: .whitespaces)
          }
        } else if !line.hasPrefix("#") {
          addChannel(name: currentName, group: currentGroup, urls: [line], logo: currentLogo, headers: currentHeaders)
          currentHeaders = defaultHeaders
        }
      }
    } else {
      var currentGroup = "默认分组"
      for raw in lines {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }
        guard let comma = line.firstIndex(of: ",") else { continue }
        let left = String(line[..<comma]).trimmingCharacters(in: .whitespaces)
        let right = String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        if right.lowercased().contains("#genre#") {
          currentGroup = left.isEmpty ? "默认分组" : left
          continue
        }
        let urls = right.components(separatedBy: "#").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        addChannel(name: left, group: currentGroup, urls: urls, logo: "", headers: defaultHeaders)
      }
    }
    return orderedKeys.compactMap { groupedMap[$0] }
  }

  /// Resolves HTTP 301/302/303/307/308 redirects on live `.m3u8` gateway URLs (such as openresty GSLB redirectors)
  /// and verifies that the final endpoint returns a valid `#EXTM3U` playlist before handing it to tvOS AVPlayer.
  private func resolveAndVerifyM3u8Url(initialUrl: String, headers: [String: String], timeout: TimeInterval = 3.2) async -> (finalUrl: String, isVerifiedM3u8: Bool) {
    let now = Date()
    if let cached = redirectUrlCache[initialUrl], cached.expiresAt > now {
      return (cached.url, true)
    }
    guard let startUrl = URL(string: initialUrl),
          let scheme = startUrl.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
      return (initialUrl, false)
    }
    if initialUrl.contains("://[") {
      return (initialUrl, false)
    }

    let lower = initialUrl.lowercased()
    if lower.contains(".m3u8") {
      do {
        var req = URLRequest(url: startUrl)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        for (k, v) in headers where !v.trimmingCharacters(in: .whitespaces).isEmpty {
          req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse,
           (200..<300).contains(http.statusCode),
           let finalUrlStr = response.url?.absoluteString,
           let text = String(data: data, encoding: .utf8),
           text.contains("#EXTM3U") {
          redirectUrlCache[initialUrl] = (finalUrlStr, now.addingTimeInterval(75))
          return (finalUrlStr, true)
        }
      } catch {}
    }

    // Fallback: single-hop Location check via noRedirectSession for non-m3u8 redirectors
    var currentUrl = startUrl
    for _ in 0..<2 {
      do {
        var req = URLRequest(url: currentUrl)
        req.httpMethod = "GET"
        req.timeoutInterval = 2.0
        for (k, v) in headers where !v.trimmingCharacters(in: .whitespaces).isEmpty {
          req.setValue(v, forHTTPHeaderField: k)
        }
        let (_, response) = try await noRedirectSession.data(for: req)
        guard let http = response as? HTTPURLResponse else { break }
        let code = http.statusCode
        if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308),
           let loc = (http.value(forHTTPHeaderField: "Location") ?? http.value(forHTTPHeaderField: "location"))?.trimmingCharacters(in: .whitespacesAndNewlines),
           !loc.isEmpty,
           let nextUrl = URL(string: loc, relativeTo: currentUrl)?.absoluteURL {
          currentUrl = nextUrl
          continue
        }
        break
      } catch {
        break
      }
    }
    return (currentUrl.absoluteString, false)
  }

  /// Resolves a Live TV channel URL for Apple TV (pre-resolving gateway redirects, racing backup lines if the primary gateway is dead, and preparing server proxy fallback).
  func resolveLivePlayback(
    source: TvLiveSource?,
    channel: TvLiveChannel,
    urlIndex: Int,
    forceServerRelay: Bool = false
  ) async -> TvResolvedPlayback {
    let safeIdx = min(max(0, urlIndex), max(0, channel.urls.count - 1))
    var chosenRawUrl = channel.urls.isEmpty ? "" : channel.urls[safeIdx]
    var split = Self.splitUrlAndInlineHeaders(chosenRawUrl)

    func buildHeaders(for inlineHeaders: [String: String], urlHint: String) -> [String: String] {
      let lowerUrl = urlHint.lowercased()
      let isFlvGateway = lowerUrl.contains("ottiptv.cc")
        || lowerUrl.contains("/douyu/")
        || lowerUrl.contains("/huya/")
        || lowerUrl.contains("/yy/")
        || lowerUrl.contains("douyucdn")
      let defaultUa = isFlvGateway ? "okHttp/Mod-1.5.0.0" : "okhttp/3.15"
      var h: [String: String] = ["User-Agent": defaultUa]
      if let src = source {
        for (k, v) in src.defaultHeaders where !v.isEmpty {
          if isFlvGateway && k.lowercased() == "user-agent" && v.lowercased() == "okhttp/3.15" {
            continue
          }
          h[k] = v
        }
      }
      for (k, v) in channel.headers where !v.isEmpty {
        if isFlvGateway && k.lowercased() == "user-agent" && v.lowercased() == "okhttp/3.15" {
          continue
        }
        h[k] = v
      }
      for (k, v) in inlineHeaders where !v.isEmpty { h[k] = v }
      return h
    }

    var mergedHeaders = buildHeaders(for: split.headers, urlHint: split.cleanUrl)
    var directCleanUrl = split.cleanUrl
    let lowerInitial = directCleanUrl.lowercased()
    var isKnownFlvGateway = lowerInitial.contains("/douyu/")
      || lowerInitial.contains("/huya/")
      || lowerInitial.contains("/yy/")
      || lowerInitial.contains("ottiptv.cc")
      || lowerInitial.contains("douyucdn")
      || lowerInitial.contains(".flv")

    // For FLV gateways (e.g. mursor.ottiptv.cc/douyu/...), first try resolving the 301/302 Location directly
    // from the Apple TV's own IP/ISP so Douyu/Huya GSLB assigns a CDN node optimal for the client's network!
    var clientResolvedFlvUrl = ""
    if !forceServerRelay && isKnownFlvGateway && !lowerInitial.contains(".flv") {
      if let gUrl = URL(string: split.cleanUrl) {
        var req = URLRequest(url: gUrl)
        req.httpMethod = "GET"
        req.timeoutInterval = 1.8
        for (k, v) in mergedHeaders where !v.isEmpty {
          req.setValue(v, forHTTPHeaderField: k)
        }
        if let (_, resp) = try? await noRedirectSession.data(for: req),
           let http = resp as? HTTPURLResponse,
           (http.statusCode == 301 || http.statusCode == 302 || http.statusCode == 303 || http.statusCode == 307 || http.statusCode == 308),
           let loc = (http.value(forHTTPHeaderField: "Location") ?? http.value(forHTTPHeaderField: "location"))?.trimmingCharacters(in: .whitespacesAndNewlines),
           !loc.isEmpty,
           let nextUrl = URL(string: loc, relativeTo: gUrl)?.absoluteURL {
          clientResolvedFlvUrl = nextUrl.absoluteString
          directCleanUrl = clientResolvedFlvUrl
        }
        // If direct TLS handshake to mursor.ottiptv.cc was reset/timed out by ISP, resolve the 301/302 Location via the client's local proxy node if available!
        if clientResolvedFlvUrl.isEmpty,
           let proxyDict = TvLocalProxyTunnelServer.shared.proxyConnectionDictionary(allowFallbackNode: true) {
          let pCfg = URLSessionConfiguration.ephemeral
          pCfg.timeoutIntervalForRequest = 2.5
          pCfg.timeoutIntervalForResource = 3.2
          pCfg.connectionProxyDictionary = proxyDict
          let proxiedNoRedir = URLSession(configuration: pCfg, delegate: NoRedirectSessionDelegate(), delegateQueue: nil)
          defer { proxiedNoRedir.finishTasksAndInvalidate() }
          if let (_, resp) = try? await proxiedNoRedir.data(for: req),
             let http = resp as? HTTPURLResponse,
             (http.statusCode == 301 || http.statusCode == 302 || http.statusCode == 303 || http.statusCode == 307 || http.statusCode == 308),
             let loc = (http.value(forHTTPHeaderField: "Location") ?? http.value(forHTTPHeaderField: "location"))?.trimmingCharacters(in: .whitespacesAndNewlines),
             !loc.isEmpty,
             let nextUrl = URL(string: loc, relativeTo: gUrl)?.absoluteURL {
            clientResolvedFlvUrl = nextUrl.absoluteString
            directCleanUrl = clientResolvedFlvUrl
          }
        }
      }
    }

    // If this is a TVBox live source and the URL is a gateway (or Douyu/Huya/YY room link),
    // ask `/api/tvbox/live/play` for the exact headers/UA and resolved URL (as primary when client redirect didn't resolve, or as fallback!).
    let lowerInitialPath = (URL(string: directCleanUrl)?.path ?? "").lowercased()
    let isStandardM3u8OrTs = lowerInitialPath.hasSuffix(".m3u8")
      || lowerInitialPath.hasSuffix(".ts")
      || lowerInitialPath.contains(".m3u8/")
      || lowerInitialPath.contains("/pltv/")
      || directCleanUrl.contains("://[")

    if ((!isStandardM3u8OrTs || isKnownFlvGateway) && clientResolvedFlvUrl.isEmpty) || forceServerRelay {
      let srcIdx = source?.sourceIndex ?? 0
      let liveIdx: Int = {
        if let s = source, !s.isCustom { return s.liveIndex }
        if lowerInitial.contains("/douyu/") { return 5 }
        if lowerInitial.contains("/huya/") { return 4 }
        if lowerInitial.contains("/yy/") { return 6 }
        return 0
      }()
      let query = [
        URLQueryItem(name: "tvbox_source", value: String(srcIdx)),
        URLQueryItem(name: "tvbox_live", value: String(liveIdx)),
        URLQueryItem(name: "url", value: split.cleanUrl),
      ]
      if let endpoint = makeEndpointUrl("/api/tvbox/live/play", queryItems: query),
         let dict = try? await requestJson(url: endpoint, timeout: 5) as? [String: Any] {
        let resolvedDirect = Self.stringValue(dict["direct_url"], fallback: Self.stringValue(dict["url"]))
        if !resolvedDirect.isEmpty && !resolvedDirect.contains("/api/vod/proxy") {
          let s2 = Self.splitUrlAndInlineHeaders(resolvedDirect)
          if !s2.cleanUrl.isEmpty, clientResolvedFlvUrl.isEmpty {
            directCleanUrl = s2.cleanUrl
          }
          for (k, v) in s2.headers where !v.isEmpty { mergedHeaders[k] = v }
        }
        if let hMap = (dict["headers"] as? [String: Any]) ?? (dict["header"] as? [String: Any]) {
          for (k, v) in hMap {
            let sv = Self.stringValue(v)
            if !sv.isEmpty { mergedHeaders[k] = sv }
          }
        }
      }
      if directCleanUrl.lowercased().contains(".flv") || directCleanUrl.lowercased().contains("douyucdn") {
        isKnownFlvGateway = true
      }
    }

    if !forceServerRelay && !directCleanUrl.isEmpty && !isKnownFlvGateway {
      let primaryRes = await resolveAndVerifyM3u8Url(initialUrl: directCleanUrl, headers: mergedHeaders, timeout: 2.8)
      if primaryRes.isVerifiedM3u8 {
        directCleanUrl = primaryRes.finalUrl
      } else if channel.urls.count > 1 {
        // Primary line did not verify as #EXTM3U in 2.8s -> race up to 3 backup lines in parallel so dead GSLB gateways are skipped immediately!
        var candidates: [(idx: Int, cleanUrl: String, headers: [String: String], rawUrl: String)] = []
        for offset in 1..<channel.urls.count {
          let cIdx = (safeIdx + offset) % channel.urls.count
          let cRaw = channel.urls[cIdx]
          let cSplit = Self.splitUrlAndInlineHeaders(cRaw)
          if cSplit.cleanUrl.lowercased().contains(".m3u8") && !cSplit.cleanUrl.contains("://[") {
            candidates.append((cIdx, cSplit.cleanUrl, buildHeaders(for: cSplit.headers, urlHint: cSplit.cleanUrl), cRaw))
            if candidates.count >= 3 { break }
          }
        }
        if !candidates.isEmpty {
          let sessionRef = self.session
          if let winner = await withTaskGroup(of: (finalUrl: String, headers: [String: String], rawUrl: String)?.self) { group -> (finalUrl: String, headers: [String: String], rawUrl: String)? in
            for cand in candidates {
              group.addTask {
                guard let u = URL(string: cand.cleanUrl) else { return nil }
                do {
                  var req = URLRequest(url: u)
                  req.httpMethod = "GET"
                  req.timeoutInterval = 3.2
                  for (k, v) in cand.headers where !v.isEmpty {
                    req.setValue(v, forHTTPHeaderField: k)
                  }
                  let (data, resp) = try await sessionRef.data(for: req)
                  if let http = resp as? HTTPURLResponse,
                     (200..<300).contains(http.statusCode),
                     let finalStr = resp.url?.absoluteString,
                     let text = String(data: data, encoding: .utf8),
                     text.contains("#EXTM3U") {
                    return (finalStr, cand.headers, cand.rawUrl)
                  }
                } catch {}
                return nil
              }
            }
            for await res in group {
              if let valid = res {
                group.cancelAll()
                return valid
              }
            }
            return nil
          } {
            directCleanUrl = winner.finalUrl
            mergedHeaders = winner.headers
            chosenRawUrl = winner.rawUrl
            split = Self.splitUrlAndInlineHeaders(chosenRawUrl)
          } else {
            directCleanUrl = primaryRes.finalUrl
          }
        } else {
          directCleanUrl = primaryRes.finalUrl
        }
      } else {
        directCleanUrl = primaryRes.finalUrl
      }
    }

    let proxyUrl = buildServerProxyUrl(targetUrl: directCleanUrl, headers: mergedHeaders)
    let isFlvStream = isKnownFlvGateway || directCleanUrl.lowercased().contains(".flv")

    if isFlvStream {
      let preferDirectFlv = !forceServerRelay
      let flvTarget = preferDirectFlv ? directCleanUrl : proxyUrl
      // Do NOT pre-open `TvLocalHlsProxyServer.shared.prepareFlvProxyPlaylistUrl` here!
      // `TvDirectFlvHardwareEngine` renders FLV directly via `AVSampleBufferDisplayLayer`, and opening a parallel
      // `TvLiveFlvSession` to the same single-use `wsAuth` Douyu/Huya FLV URL causes the CDN to kick the second connection.
      return TvResolvedPlayback(
        directUrl: flvTarget,
        serverProxyUrl: proxyUrl,
        headers: mergedHeaders,
        parseVia: preferDirectFlv ? "硬件FLV直连" : "服务端代理+硬件FLV",
        backendProxyPlayback: !preferDirectFlv,
        isFlvHardwareStream: true,
        flvPrimaryUrl: flvTarget,
        flvGatewayUrl: split.cleanUrl
      )
    }

    let needsProxyFirst = forceServerRelay
    var finalDirectUrl = directCleanUrl
    var parseViaLabel = "客户端直连"
    if !needsProxyFirst
        && TvLocalProxyTunnelServer.shared.isProxyActive
        && directCleanUrl.lowercased().contains(".m3u8")
        && !directCleanUrl.contains("://[") {
      if let localAcceleratedUrl = await TvLocalHlsProxyServer.shared.prepareProxyPlaylistUrl(
        gatewayUrl: split.cleanUrl,
        resolvedUrl: directCleanUrl,
        headers: mergedHeaders
      ) {
        finalDirectUrl = localAcceleratedUrl
        parseViaLabel = "代理多连接加速"
      }
    }

    return TvResolvedPlayback(
      directUrl: needsProxyFirst ? proxyUrl : finalDirectUrl,
      serverProxyUrl: proxyUrl,
      headers: mergedHeaders,
      parseVia: needsProxyFirst ? "服务端代理中转" : parseViaLabel,
      backendProxyPlayback: needsProxyFirst
    )
  }

  private nonisolated static func extractAttr(_ line: String, key: String) -> String? {
    guard let range = line.range(of: "\(key)=\"", options: .caseInsensitive) else { return nil }
    let sub = line[range.upperBound...]
    guard let endQuote = sub.firstIndex(of: "\"") else { return nil }
    return String(sub[..<endQuote])
  }

  // MARK: - 4. Library (Favorites & History)

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

  func upsertLibraryItem(kind: String, item: TvLibraryItem) async {
    guard let url = makeEndpointUrl("/api/tvbox/library") else { return }
    let payload: [String: Any] = [
      "kind": kind,
      "item": [
        "source": item.source,
        "source_name": item.sourceName,
        "vod_id": item.vodId,
        "title": item.title,
        "poster": item.poster,
        "pic": item.poster,
        "remark": item.remark,
        "episode": item.episode,
        "line": item.line,
        "position": item.position,
        "duration": item.duration,
        "updated": item.updated,
      ],
    ]
    _ = try? await requestJson(url: url, method: "PUT", body: payload)
  }

  func deleteLibraryItem(kind: String, source: String? = nil, vodId: String? = nil) async {
    var query = [URLQueryItem(name: "kind", value: kind)]
    var body: [String: Any] = ["kind": kind]
    if let source = source, !source.isEmpty {
      query.append(URLQueryItem(name: "source", value: source))
      body["source"] = source
    }
    if let vodId = vodId, !vodId.isEmpty {
      query.append(URLQueryItem(name: "vod_id", value: vodId))
      body["vod_id"] = vodId
    }
    if (source == nil || source!.isEmpty) && (vodId == nil || vodId!.isEmpty) {
      query.append(URLQueryItem(name: "clear", value: "1"))
      body["clear"] = true
    }
    guard let url = makeEndpointUrl("/api/tvbox/library", queryItems: query) else { return }
    _ = try? await requestJson(url: url, method: "DELETE", body: body)
  }

  // MARK: - 5. Downloads & Webpage Video Extractor

  func fetchDownloadTasks() async -> [TvDownloadTask] {
    guard let url = makeEndpointUrl("/api/tasks"),
          let rawAny = try? await requestJson(url: url),
          let rawList = rawAny as? [[String: Any]] else {
      return []
    }
    return rawList.map { item in
      TvDownloadTask(
        id: Self.stringValue(item["id"]),
        url: Self.stringValue(item["url"]),
        name: Self.stringValue(item["name"], fallback: "未命名任务"),
        status: Self.stringValue(item["status"], fallback: "Pending"),
        progress: Self.doubleValue(item["progress"], fallback: 0),
        speed: Self.doubleValue(item["speed"], fallback: 0),
        totalSegments: Self.intValue(item["total_segments"], fallback: 0),
        downloadedSegments: Self.intValue(item["downloaded_segments"], fallback: 0),
        urlType: Self.stringValue(item["url_type"], fallback: "m3u8"),
        outputFile: Self.stringValue(item["output_file"]),
        error: Self.stringValue(item["error"])
      )
    }
  }

  @discardableResult
  func createDownloadTask(
    url: String,
    name: String,
    headers: [String: String] = [:],
    telegramAccountId: String? = nil,
    forceDuplicate: Bool = false
  ) async throws -> String? {
    guard let endpoint = makeEndpointUrl("/api/download") else { return nil }
    var payload: [String: Any] = [
      "url": url.trimmingCharacters(in: .whitespacesAndNewlines),
      "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
    ]
    if !headers.isEmpty {
      payload["headers"] = headers
    }
    if let accId = telegramAccountId, !accId.isEmpty {
      payload["telegram_account_id"] = accId
    }
    if forceDuplicate {
      payload["force_duplicate"] = true
    }
    let res = try await requestJson(url: endpoint, method: "POST", body: payload)
    if let dict = res as? [String: Any] {
      let id = Self.stringValue(dict["id"])
      let dupId = Self.stringValue(dict["duplicate_of_task_id"])
      return !dupId.isEmpty ? dupId : (!id.isEmpty ? id : nil)
    }
    return nil
  }

  func retryDownloadTask(id: String) async throws {
    guard let endpoint = makeEndpointUrl("/api/tasks/\(id)/retry") else { return }
    _ = try await requestJson(url: endpoint, method: "POST")
  }

  func deleteDownloadTask(id: String, deleteFiles: Bool = false) async throws {
    guard let endpoint = makeEndpointUrl(
      "/api/tasks/\(id)",
      queryItems: [URLQueryItem(name: "delete_files", value: deleteFiles ? "true" : "false")]
    ) else { return }
    _ = try await requestJson(url: endpoint, method: "DELETE")
  }

  func uploadTaskTo115(id: String) async throws {
    guard let endpoint = makeEndpointUrl("/api/115/upload/\(id)") else { return }
    _ = try await requestJson(url: endpoint, method: "POST")
  }

  func extractWebVideo(urlOrText: String) async throws -> [TvExtractedCandidate] {
    guard let endpoint = makeEndpointUrl("/api/web/extract") else { return [] }
    let rawAny = try await requestJson(
      url: endpoint,
      method: "POST",
      body: ["url": urlOrText.trimmingCharacters(in: .whitespacesAndNewlines)],
      timeout: 40
    )
    guard let dict = rawAny as? [String: Any] else { return [] }
    let rawList = (dict["candidates"] as? [[String: Any]])
      ?? (dict["items"] as? [[String: Any]])
      ?? (dict["videos"] as? [[String: Any]])
      ?? (dict["list"] as? [[String: Any]])
      ?? []
    var result: [TvExtractedCandidate] = rawList.compactMap { item in
      let u = Self.stringValue(item["url"])
      guard !u.isEmpty else { return nil }
      var headers: [String: String] = [:]
      if let hMap = (item["headers"] as? [String: Any]) ?? (item["header"] as? [String: Any]) {
        for (k, v) in hMap {
          let sv = Self.stringValue(v)
          if !sv.isEmpty { headers[k] = sv }
        }
      }
      return TvExtractedCandidate(
        url: u,
        title: Self.stringValue(item["title"], fallback: Self.stringValue(item["name"], fallback: "提取视频")),
        type: Self.stringValue(item["type"], fallback: Self.stringValue(item["url_type"], fallback: "m3u8")),
        headers: headers
      )
    }
    if result.isEmpty, let u = dict["url"] as? String, !u.isEmpty {
      result.append(TvExtractedCandidate(url: u, title: "提取视频", type: "m3u8", headers: [:]))
    }
    return result
  }

  // MARK: - 6. Server Media Library (/api/files) & Multi-Storage (AList / WebDAV / 115 / Local Cache)

  func fetchFiles(path: String = "") async throws -> TvFileListing {
    var query: [URLQueryItem] = []
    if !path.isEmpty {
      query.append(URLQueryItem(name: "path", value: path))
    }
    guard let endpoint = makeEndpointUrl("/api/files", queryItems: query),
          let dict = try await requestJson(url: endpoint) as? [String: Any] else {
      return TvFileListing(path: "", parent: "", root: "/", entries: [])
    }
    let rawEntries = (dict["entries"] as? [[String: Any]]) ?? []
    let entries = rawEntries.map { item in
      TvFileEntry(
        name: Self.stringValue(item["name"]),
        path: Self.stringValue(item["path"]),
        size: Int64(Self.intValue(item["size"], fallback: 0)),
        modTime: Self.stringValue(item["mod_time"]),
        isDir: (item["is_dir"] as? Bool) == true,
        isMp4: (item["is_mp4"] as? Bool) == true,
        ext: Self.stringValue(item["ext"]),
        mountId: "builtin_server",
        sourceKind: .server
      )
    }
    return TvFileListing(
      path: Self.stringValue(dict["path"]),
      parent: Self.stringValue(dict["parent"]),
      root: Self.stringValue(dict["root"], fallback: "/"),
      entries: entries
    )
  }

  func buildFileStreamUrl(path: String) -> String {
    makeEndpointUrl("/api/files/open", queryItems: [URLQueryItem(name: "path", value: path)])?.absoluteString ?? ""
  }

  func buildFileDownloadUrl(path: String) -> String {
    makeEndpointUrl("/api/files/download", queryItems: [URLQueryItem(name: "path", value: path)])?.absoluteString
      ?? buildFileStreamUrl(path: path)
  }

  func fetchFilePreviewText(urlStr: String, headers: [String: String] = [:], maxBytes: Int = 65536) async throws -> String {
    guard let u = URL(string: urlStr) else {
      throw NSError(domain: "TvApiClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的文件预览地址"])
    }
    func buildRequest(withRange: Bool) -> URLRequest {
      var req = URLRequest(url: u)
      req.timeoutInterval = 14
      if withRange {
        req.setValue("bytes=0-\(max(1024, maxBytes - 1))", forHTTPHeaderField: "Range")
      }
      if urlStr.hasPrefix(baseUrl), !authSecret.isEmpty {
        req.setValue("Bearer \(authSecret)", forHTTPHeaderField: "Authorization")
        req.setValue(authSecret, forHTTPHeaderField: "X-Auth-Secret")
      }
      for (k, v) in headers where !v.isEmpty {
        req.setValue(v, forHTTPHeaderField: k)
      }
      return req
    }

    var fetchedData: Data? = nil
    if let (d, resp) = try? await session.data(for: buildRequest(withRange: true)),
       let http = resp as? HTTPURLResponse,
       (200..<300).contains(http.statusCode),
       !d.isEmpty {
      fetchedData = d
    } else {
      let (d, _) = try await session.data(for: buildRequest(withRange: false))
      fetchedData = d
    }

    let data = fetchedData ?? Data()
    let slice = data.count > maxBytes ? data.prefix(maxBytes) : data[...]
    if let utf8 = String(data: Data(slice), encoding: .utf8) {
      return utf8
    }
    if let gbk = String(data: Data(slice), encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) {
      return gbk
    }
    return String(decoding: slice, as: UTF8.self)
  }

  func fetchFilePreviewImageData(urlStr: String, headers: [String: String] = [:]) async -> Data? {
    guard let u = URL(string: urlStr) else { return nil }
    var req = URLRequest(url: u)
    req.timeoutInterval = 18
    if urlStr.hasPrefix(baseUrl), !authSecret.isEmpty {
      req.setValue("Bearer \(authSecret)", forHTTPHeaderField: "Authorization")
      req.setValue(authSecret, forHTTPHeaderField: "X-Auth-Secret")
    }
    for (k, v) in headers where !v.isEmpty {
      req.setValue(v, forHTTPHeaderField: k)
    }
    if let (data, resp) = try? await imageSession.data(for: req),
       let http = resp as? HTTPURLResponse,
       (200..<300).contains(http.statusCode),
       !data.isEmpty {
      return data
    }
    return nil
  }

  func convertFileToMp4(path: String) async throws {
    guard let endpoint = makeEndpointUrl("/api/files/convert") else { return }
    _ = try await requestJson(url: endpoint, method: "POST", body: ["path": path])
  }

  func uploadFileTo115(path: String) async throws {
    guard let endpoint = makeEndpointUrl("/api/files/upload-115") else { return }
    _ = try await requestJson(url: endpoint, method: "POST", body: ["path": path])
  }

  func renameFile(path: String, newName: String) async throws {
    guard let endpoint = makeEndpointUrl("/api/files/rename") else { return }
    _ = try await requestJson(url: endpoint, method: "POST", body: ["path": path, "new_name": newName])
  }

  func createDirectory(parentPath: String, name: String) async throws {
    guard let endpoint = makeEndpointUrl("/api/files/mkdir") else { return }
    _ = try await requestJson(url: endpoint, method: "POST", body: ["path": parentPath, "name": name])
  }

  func deleteFile(path: String) async throws {
    guard let endpoint = makeEndpointUrl("/api/files", queryItems: [URLQueryItem(name: "path", value: path)]) else { return }
    _ = try await requestJson(url: endpoint, method: "DELETE")
  }

  /// Uploads raw file data to the backend server directory:
  /// 1) Tries `POST /api/files/upload?path=<dir>&name=<filename>` or multipart `/api/files/upload`
  /// 2) If backend is an older version without `/api/files/upload`, automatically falls back to saving on Apple TV local HTTP server and triggering `POST /api/download` so the backend server pulls it!
  func uploadDataToServerDirectory(
    fileData: Data,
    fileName: String,
    targetDir: String,
    lanBaseUrl: String? = nil,
    onProgress: @escaping @Sendable (Int64, Int64) -> Void
  ) async throws {
    let totalBytes = Int64(fileData.count)
    onProgress(0, totalBytes)
    if let endpoint = makeEndpointUrl(
      "/api/files/upload",
      queryItems: [
        URLQueryItem(name: "path", value: targetDir),
        URLQueryItem(name: "name", value: fileName)
      ]
    ) {
      let boundary = "----TvUploadBoundary\(Int(Date().timeIntervalSince1970 * 1000))"
      var body = Data()
      body.append(Data("--\(boundary)\r\n".utf8))
      body.append(Data("Content-Disposition: form-data; name=\"path\"\r\n\r\n\(targetDir)\r\n".utf8))
      body.append(Data("--\(boundary)\r\n".utf8))
      body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".utf8))
      body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
      body.append(fileData)
      body.append(Data("\r\n--\(boundary)--\r\n".utf8))

      var req = URLRequest(url: endpoint)
      req.httpMethod = "POST"
      req.timeoutInterval = 300
      req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
      if !authSecret.isEmpty {
        req.setValue("Bearer \(authSecret)", forHTTPHeaderField: "Authorization")
        req.setValue(authSecret, forHTTPHeaderField: "X-Auth-Secret")
      }
      if let (_, resp) = try? await TvStreamingHttpTransfer.shared.upload(
        request: req,
        data: body,
        logicalTotalBytes: totalBytes,
        onProgress: onProgress
      ),
      let http = resp as? HTTPURLResponse,
      (200..<300).contains(http.statusCode) {
        onProgress(totalBytes, totalBytes)
        return
      }
    }

    // Fallback: if `/api/files/upload` is not supported on backend, save to local staging and trigger `/api/download` if LAN reachable
    if let lan = lanBaseUrl, !lan.isEmpty {
      let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
      let pullUrl = "\(lan)/local-cache/\(encodedName)"
      _ = try await createDownloadTask(url: pullUrl, name: fileName)
      onProgress(totalBytes, totalBytes)
      return
    }
    throw NSError(
      domain: "TvApiClient",
      code: -404,
      userInfo: [NSLocalizedDescriptionKey: "当前服务端暂未开启 /api/files/upload 直传接口，文件已自动存入本机离线缓存或请挂载 AList/WebDAV 上传"]
    )
  }

  // MARK: - 7. 115 Cloud Drive & Server Settings & Proxy

  func fetch115Status() async -> [String: Any] {
    guard let endpoint = makeEndpointUrl("/api/115/status"),
          let dict = try? await requestJson(url: endpoint) as? [String: Any] else {
      return [:]
    }
    return dict
  }

  func login115WithCookie(cookie: String) async throws {
    guard let endpoint = makeEndpointUrl("/api/115/login") else { return }
    let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try await requestJson(url: endpoint, method: "POST", body: ["cookies": trimmed, "cookie": trimmed])
  }

  func fetch115QrCode() async throws -> [String: Any] {
    guard let endpoint = makeEndpointUrl("/api/115/qrcode"),
          let dict = try await requestJson(url: endpoint) as? [String: Any] else {
      return [:]
    }
    return dict
  }

  func check115QrCode(token: String) async -> [String: Any] {
    guard let endpoint = makeEndpointUrl("/api/115/check-qrcode", queryItems: [URLQueryItem(name: "token", value: token)]),
          let dict = try? await requestJson(url: endpoint) as? [String: Any] else {
      return [:]
    }
    return dict
  }

  func logout115() async throws {
    guard let endpoint = makeEndpointUrl("/api/115/logout") else { return }
    _ = try await requestJson(url: endpoint, method: "POST")
  }

  func fetchServerSettings() async -> [String: Any] {
    guard let endpoint = makeEndpointUrl("/api/settings"),
          let dict = try? await requestJson(url: endpoint) as? [String: Any] else {
      return [:]
    }
    return dict
  }

  func saveServerSettings(_ settings: [String: Any]) async throws {
    guard let endpoint = makeEndpointUrl("/api/settings") else { return }
    _ = try await requestJson(url: endpoint, method: "POST", body: settings)
  }

  func restartServerService() async throws {
    guard let endpoint = makeEndpointUrl("/api/system/restart") else { return }
    _ = try await requestJson(url: endpoint, method: "POST")
  }

  func fetchProxyConfig() async -> (services: [TvProxyServiceConfig], statuses: [TvProxyRuntimeStatus]) {
    guard let endpoint = makeEndpointUrl("/api/proxy"),
          let dict = try? await requestJson(url: endpoint) as? [String: Any] else {
      return ([], [])
    }
    let rawServices = (dict["services"] as? [[String: Any]]) ?? []
    let rawStatuses = (dict["statuses"] as? [[String: Any]]) ?? []
    let services = rawServices.map { item in
      TvProxyServiceConfig(
        id: Self.stringValue(item["id"]),
        name: Self.stringValue(item["name"]),
        proto: Self.stringValue(item["protocol"], fallback: "http"),
        listenHost: Self.stringValue(item["listen_host"], fallback: "127.0.0.1"),
        port: Self.intValue(item["port"], fallback: 3128),
        enabled: (item["enabled"] as? Bool) == true,
        username: Self.stringValue(item["username"]),
        password: Self.stringValue(item["password"]),
        cipher: Self.stringValue(item["cipher"], fallback: "aes-256-gcm")
      )
    }
    let statuses = rawStatuses.map { item in
      TvProxyRuntimeStatus(
        id: Self.stringValue(item["id"]),
        running: (item["running"] as? Bool) == true || Self.stringValue(item["status"]) == "running",
        address: Self.stringValue(item["address"], fallback: Self.stringValue(item["listen_address"])),
        error: Self.stringValue(item["error"], fallback: Self.stringValue(item["last_error"])),
        activeConnections: Self.intValue(item["active_connections"], fallback: 0),
        totalConnections: Self.intValue(item["total_connections"], fallback: 0)
      )
    }
    return (services, statuses)
  }

  func testProxyService(id: String) async throws {
    guard let endpoint = makeEndpointUrl("/api/proxy/test") else { return }
    _ = try await requestJson(url: endpoint, method: "POST", body: ["id": id])
  }

  struct SubscriptionFetchResult {
    let nodes: [TvSubscriptionNode]
    let uploadBytes: Int64?
    let downloadBytes: Int64?
    let totalBytes: Int64?
    let expireTimestampSec: Int64?
    let error: String?
  }

  func fetchSubscriptionDetail(
    urlStr: String,
    subId: String,
    subName: String
  ) async -> SubscriptionFetchResult {
    let trimmedUrl = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmedUrl) else {
      return SubscriptionFetchResult(
        nodes: [],
        uploadBytes: nil,
        downloadBytes: nil,
        totalBytes: nil,
        expireTimestampSec: nil,
        error: "订阅链接格式无效"
      )
    }

    var candidateSessions: [(sess: URLSession, targetUrl: URL, extraHeaders: [String: String], ua: String)] = []
    if let proxyDict = TvLocalProxyTunnelServer.shared.proxyConnectionDictionary(allowFallbackNode: true) {
      let pCfg = URLSessionConfiguration.ephemeral
      pCfg.timeoutIntervalForRequest = 6.5
      pCfg.timeoutIntervalForResource = 12
      pCfg.connectionProxyDictionary = proxyDict
      let proxiedSess = URLSession(configuration: pCfg, delegate: InsecureSessionDelegate(), delegateQueue: nil)
      candidateSessions.append((proxiedSess, url, [:], "v2rayNG/1.8.19"))
    }
    let dCfg = URLSessionConfiguration.ephemeral
    dCfg.timeoutIntervalForRequest = 5.5
    dCfg.timeoutIntervalForResource = 10
    dCfg.connectionProxyDictionary = [:]
    let directSess = URLSession(configuration: dCfg, delegate: InsecureSessionDelegate(), delegateQueue: nil)
    candidateSessions.append((directSess, url, [:], "v2rayNG/1.8.19"))
    candidateSessions.append((directSess, url, [:], "Clash.Meta/v1.18.1"))

    let rCfg = URLSessionConfiguration.ephemeral
    rCfg.timeoutIntervalForRequest = 10
    rCfg.timeoutIntervalForResource = 16
    rCfg.connectionProxyDictionary = [:]
    let relaySess = URLSession(configuration: rCfg, delegate: InsecureSessionDelegate(), delegateQueue: nil)
    for ua in ["v2rayNG/1.8.19", "Clash.Meta/v1.18.1"] {
      let relayStr = buildServerProxyUrl(targetUrl: trimmedUrl, headers: ["User-Agent": ua])
      if let relayUrl = URL(string: relayStr) {
        var relayHdrs = authHeaders
        if !authSecret.isEmpty {
          relayHdrs["Authorization"] = "Bearer \(authSecret)"
          relayHdrs["X-Auth-Secret"] = authSecret
        }
        candidateSessions.append((relaySess, relayUrl, relayHdrs, ua))
      }
    }

    var uniqueSessionsToClose: [URLSession] = [directSess, relaySess]
    if let first = candidateSessions.first?.sess, first !== directSess && first !== relaySess {
      uniqueSessionsToClose.append(first)
    }
    defer {
      for s in uniqueSessionsToClose {
        s.finishTasksAndInvalidate()
      }
    }

    var lastErr: String = "拉取订阅为空"
    for cand in candidateSessions {
      do {
        var req = URLRequest(url: cand.targetUrl)
        req.timeoutInterval = 10
        req.setValue(cand.ua, forHTTPHeaderField: "User-Agent")
        for (k, v) in cand.extraHeaders where !v.isEmpty {
          req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, resp) = try await cand.sess.data(for: req)
        var upload: Int64? = nil
        var download: Int64? = nil
        var total: Int64? = nil
        var expire: Int64? = nil
        if let http = resp as? HTTPURLResponse {
          for (k, v) in http.allHeaderFields {
            if String(describing: k).lowercased() == "subscription-userinfo" {
              let rawInfo = String(describing: v)
              let parsedInfo = Self.parseSubscriptionUserInfoHeader(rawInfo)
              upload = parsedInfo.upload
              download = parsedInfo.download
              total = parsedInfo.total
              expire = parsedInfo.expire
              break
            }
          }
        }
        guard let rawText = String(data: data, encoding: .utf8), !rawText.isEmpty else { continue }
        let parsed = await Task.detached(priority: .userInitiated) {
          Self.parseSubscriptionText(rawText, subId: subId, subName: subName)
        }.value
        if !parsed.isEmpty {
          return SubscriptionFetchResult(
            nodes: parsed,
            uploadBytes: upload,
            downloadBytes: download,
            totalBytes: total,
            expireTimestampSec: expire,
            error: nil
          )
        }
      } catch {
        lastErr = error.localizedDescription
        continue
      }
    }
    return SubscriptionFetchResult(
      nodes: [],
      uploadBytes: nil,
      downloadBytes: nil,
      totalBytes: nil,
      expireTimestampSec: nil,
      error: lastErr
    )
  }

  func fetchSubscriptionNodes(urlStr: String) async -> [TvSubscriptionNode] {
    let res = await fetchSubscriptionDetail(urlStr: urlStr, subId: "sub_default", subName: "默认订阅")
    return res.nodes
  }

  private nonisolated static func parseSubscriptionUserInfoHeader(_ raw: String) -> (upload: Int64?, download: Int64?, total: Int64?, expire: Int64?) {
    var up: Int64? = nil
    var down: Int64? = nil
    var tot: Int64? = nil
    var exp: Int64? = nil
    for part in raw.components(separatedBy: ";") {
      let kv = part.components(separatedBy: "=")
      guard kv.count == 2 else { continue }
      let key = kv[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let valStr = kv[1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard let val = Int64(valStr) else { continue }
      switch key {
      case "upload": up = val
      case "download": down = val
      case "total": tot = val
      case "expire": exp = val
      default: break
      }
    }
    return (up, down, tot, exp)
  }

  nonisolated static func parseSubscriptionText(
    _ rawText: String,
    subId: String = "manual",
    subName: String = "手动导入"
  ) -> [TvSubscriptionNode] {
    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    var decoded = trimmed
    if !trimmed.contains("://") && !trimmed.contains("proxies:") {
      if let str = decodeBase64Flexible(trimmed) {
        decoded = str
      }
    }

    var nodes: [TvSubscriptionNode] = []
    var seenKeys = Set<String>()

    for rawLine in decoded.components(separatedBy: .newlines) {
      if nodes.count >= 120 { break }
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty || line.hasPrefix("#") { continue }

      // Stop immediately when Clash YAML reaches proxy-groups or rules (avoids iterating 15,000+ rule lines!)
      if line.hasPrefix("proxy-groups:") || line.hasPrefix("rules:") || line.hasPrefix("rule-providers:") {
        break
      }

      if let schemeRange = line.range(of: "://") {
        let proto = String(line[..<schemeRange.lowerBound]).lowercased()
        let bodyAfterScheme = String(line[schemeRange.upperBound...])

        // 1. vmess://base64_json
        if proto == "vmess" {
          let cleanB64 = bodyAfterScheme.components(separatedBy: "#").first ?? bodyAfterScheme
          if let jsonStr = decodeBase64Flexible(cleanB64),
             let jsonData = jsonStr.data(using: .utf8),
             let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            let name = stringValue(dict["ps"], fallback: "VMESS").trimmingCharacters(in: .whitespacesAndNewlines)
            let host = stringValue(dict["add"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let port = intValue(dict["port"], fallback: 0)
            if !host.isEmpty && port > 0 && !isInfoNodeName(name) {
              let dedup = "VMESS_\(host)_\(port)_\(name)"
              if seenKeys.insert(dedup).inserted {
                nodes.append(
                  TvSubscriptionNode(
                    id: "\(subId)_\(nodes.count)_VMESS_\(host)_\(port)",
                    name: name,
                    type: "VMESS",
                    host: host,
                    port: port,
                    subscriptionId: subId,
                    subscriptionName: subName,
                    rawUri: line
                  )
                )
              }
            }
          }
          continue
        }

        // 2. ss://, trojan://, vless://, hy2://, hysteria2://, socks5://, http://
        var name = proto.uppercased()
        if let hashIdx = line.lastIndex(of: "#") {
          let frag = String(line[line.index(after: hashIdx)...])
          name = (frag.removingPercentEncoding ?? frag).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var candidateLine = bodyAfterScheme
        if let hIdx = candidateLine.firstIndex(of: "#") {
          candidateLine = String(candidateLine[..<hIdx])
        }
        if !candidateLine.contains("@"), let decodedSS = decodeBase64Flexible(candidateLine), decodedSS.contains("@") {
          candidateLine = decodedSS
        }

        var hostPortPart = candidateLine
        if let atIdx = candidateLine.lastIndex(of: "@") {
          hostPortPart = String(candidateLine[candidateLine.index(after: atIdx)...])
        }
        if let qIdx = hostPortPart.firstIndex(of: "?") { hostPortPart = String(hostPortPart[..<qIdx]) }
        if let sIdx = hostPortPart.firstIndex(of: "/") { hostPortPart = String(hostPortPart[..<sIdx]) }
        let parts = hostPortPart.components(separatedBy: ":")
        if parts.count >= 2, let p = Int(parts.last ?? ""), p > 0 {
          let host = parts.dropLast().joined(separator: ":")
          let isDummyLocal = (subId != "manual" && subId != "server") &&
            (host == "127.0.0.1" || host == "0.0.0.0" || host == "localhost" || p <= 1)
          if !host.isEmpty && !isDummyLocal && !isInfoNodeName(name) {
            let upProto = proto.uppercased()
            let dedup = "\(upProto)_\(host)_\(p)_\(name)"
            if seenKeys.insert(dedup).inserted {
              nodes.append(
                TvSubscriptionNode(
                  id: "\(subId)_\(nodes.count)_\(upProto)_\(host)_\(p)",
                  name: name,
                  type: upProto,
                  host: host,
                  port: p,
                  subscriptionId: subId,
                  subscriptionName: subName,
                  rawUri: line
                )
              )
            }
          }
        }
      } else if line.contains("server:") && line.contains("port:") {
        // Inline Clash YAML proxy line `{name: ..., server: ..., port: ..., type: ...}`
        let name = extractYamlField(line, key: "name") ?? "节点"
        let server = extractYamlField(line, key: "server") ?? ""
        let port = Int(extractYamlField(line, key: "port") ?? "0") ?? 0
        let type = (extractYamlField(line, key: "type") ?? "PROXY").uppercased()
        let isDummyLocal = (subId != "manual" && subId != "server") &&
          (server == "127.0.0.1" || server == "0.0.0.0" || server == "localhost" || port <= 1)
        if !server.isEmpty && port > 0 && !isDummyLocal && !isInfoNodeName(name) {
          let dedup = "\(type)_\(server)_\(port)_\(name)"
          if seenKeys.insert(dedup).inserted {
            nodes.append(
              TvSubscriptionNode(
                id: "\(subId)_\(nodes.count)_\(type)_\(server)_\(port)",
                name: name,
                type: type,
                host: server,
                port: port,
                subscriptionId: subId,
                subscriptionName: subName,
                rawUri: line
              )
            )
          }
        }
      }
    }
    return nodes
  }

  private nonisolated static func isInfoNodeName(_ name: String) -> Bool {
    let keywords = ["剩余流量", "套餐到期", "官网", "重置", "不支持", "推荐客户端", "防失联", "群组", "公告", "网址", "过期", "到期"]
    for kw in keywords where name.contains(kw) {
      return true
    }
    return false
  }

  private nonisolated static func decodeBase64Flexible(_ raw: String) -> String? {
    var padded = raw
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
      .components(separatedBy: .whitespacesAndNewlines)
      .joined()
    guard !padded.isEmpty else { return nil }
    while padded.count % 4 != 0 { padded.append("=") }
    guard let data = Data(base64Encoded: padded, options: .ignoreUnknownCharacters) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private nonisolated static func extractYamlField(_ line: String, key: String) -> String? {
    guard let r = line.range(of: "\(key):") else { return nil }
    var sub = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    if let comma = sub.firstIndex(of: ",") { sub = String(sub[..<comma]) }
    if let brace = sub.firstIndex(of: "}") { sub = String(sub[..<brace]) }
    return sub.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
  }

  // MARK: - 8. Telegram Full Client API

  func fetchTelegramAccounts() async -> (activeId: String, accounts: [TvTelegramAccount]) {
    guard let url = makeEndpointUrl("/api/telegram/accounts"),
          let dict = try? await requestJson(url: url) as? [String: Any] else {
      return ("default", [])
    }
    let activeId = Self.stringValue(dict["active_id"], fallback: "default")
    let rawList = (dict["accounts"] as? [[String: Any]]) ?? []
    let accounts = rawList.map { item in
      TvTelegramAccount(
        id: Self.stringValue(item["id"], fallback: "default"),
        name: Self.stringValue(item["name"], fallback: "默认账号"),
        username: Self.stringValue(item["username"]),
        userId: Self.stringValue(item["user_id"]),
        avatar: Self.stringValue(item["avatar"], fallback: Self.stringValue(item["photo"]))
      )
    }
    return (activeId, accounts)
  }

  func setActiveTelegramAccount(_ accountId: String) async {
    guard let url = makeEndpointUrl("/api/telegram/accounts/active") else { return }
    _ = try? await requestJson(url: url, method: "POST", body: ["account_id": accountId])
  }

  func createTelegramAccount(name: String) async throws -> TvTelegramAccount {
    guard let url = makeEndpointUrl("/api/telegram/accounts"),
          let dict = try await requestJson(url: url, method: "POST", body: ["name": name]) as? [String: Any] else {
      throw NSError(domain: "TvApiClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "创建账号失败"])
    }
    return TvTelegramAccount(
      id: Self.stringValue(dict["id"], fallback: "default"),
      name: Self.stringValue(dict["name"], fallback: name),
      username: Self.stringValue(dict["username"]),
      userId: Self.stringValue(dict["user_id"]),
      avatar: Self.stringValue(dict["avatar"])
    )
  }

  func fetchTelegramStatus(accountId: String) async -> TvTelegramAuthStatus {
    guard let url = makeEndpointUrl("/api/telegram/status", queryItems: [URLQueryItem(name: "account_id", value: accountId)]),
          let dict = try? await requestJson(url: url, timeout: 30) as? [String: Any] else {
      return TvTelegramAuthStatus()
    }
    return TvTelegramAuthStatus(
      configured: (dict["configured"] as? Bool) == true,
      authorized: (dict["authorized"] as? Bool) == true,
      codeSent: (dict["code_sent"] as? Bool) == true,
      passwordRequired: (dict["password_required"] as? Bool) == true
    )
  }

  func saveTelegramApiConfig(accountId: String, apiId: Int, apiHash: String, proxyUrl: String = "") async throws {
    guard let url = makeEndpointUrl("/api/telegram/config", queryItems: [URLQueryItem(name: "account_id", value: accountId)]) else { return }
    _ = try await requestJson(
      url: url,
      method: "POST",
      body: [
        "api_id": apiId,
        "api_hash": apiHash.trimmingCharacters(in: .whitespacesAndNewlines),
        "proxy_url": proxyUrl.trimmingCharacters(in: .whitespacesAndNewlines),
      ]
    )
  }

  func sendTelegramLoginCode(accountId: String, phone: String) async throws {
    guard let url = makeEndpointUrl("/api/telegram/send-code", queryItems: [URLQueryItem(name: "account_id", value: accountId)]) else { return }
    _ = try await requestJson(url: url, method: "POST", body: ["phone": phone], timeout: 45)
  }

  func submitTelegramLogin(accountId: String, code: String, password: String = "") async throws -> TvTelegramAuthStatus {
    guard let url = makeEndpointUrl("/api/telegram/login", queryItems: [URLQueryItem(name: "account_id", value: accountId)]),
          let dict = try await requestJson(
            url: url,
            method: "POST",
            body: ["code": code, "password": password],
            timeout: 45
          ) as? [String: Any] else {
      return TvTelegramAuthStatus(authorized: true)
    }
    return TvTelegramAuthStatus(
      configured: (dict["configured"] as? Bool) == true,
      authorized: (dict["authorized"] as? Bool) == true,
      codeSent: (dict["code_sent"] as? Bool) == true,
      passwordRequired: (dict["password_required"] as? Bool) == true
    )
  }

  func fetchTelegramFolders(accountId: String) async -> [TvTelegramFolder] {
    guard let url = makeEndpointUrl("/api/telegram/folders", queryItems: [URLQueryItem(name: "account_id", value: accountId)]),
          let dict = try? await requestJson(url: url, timeout: 25) as? [String: Any],
          let raw = dict["folders"] as? [[String: Any]] else {
      return [TvTelegramFolder(key: "0", title: "全部会话", emoji: "")]
    }
    let folders = raw.map { item in
      TvTelegramFolder(
        key: Self.stringValue(item["key"], fallback: "0"),
        title: Self.stringValue(item["title"], fallback: "全部会话"),
        emoji: Self.stringValue(item["emoji"])
      )
    }
    return folders.isEmpty ? [TvTelegramFolder(key: "0", title: "全部会话", emoji: "")] : folders
  }

  func fetchTelegramChats(accountId: String, folder: String = "0", cursor: String = "") async -> (chats: [TvTelegramChat], nextCursor: String) {
    var query = [
      URLQueryItem(name: "account_id", value: accountId),
      URLQueryItem(name: "limit", value: "60"),
    ]
    if folder.hasPrefix("filter:") {
      query.append(URLQueryItem(name: "folder", value: "0"))
      query.append(URLQueryItem(name: "filter_id", value: String(folder.dropFirst(7))))
    } else {
      query.append(URLQueryItem(name: "folder", value: folder))
    }
    if !cursor.isEmpty {
      query.append(URLQueryItem(name: "cursor", value: cursor))
    }
    guard let url = makeEndpointUrl("/api/telegram/chats", queryItems: query),
          let dict = try? await requestJson(url: url, timeout: 35) as? [String: Any] else {
      return ([], "")
    }
    let nextCursor = Self.stringValue(dict["next_cursor"])
    let rawChats = (dict["chats"] as? [[String: Any]]) ?? []
    let chats = rawChats.map { item in
      TvTelegramChat(
        peer: Self.stringValue(item["peer"], fallback: Self.stringValue(item["id"])),
        title: Self.stringValue(item["title"], fallback: "对话"),
        kind: Self.stringValue(item["kind"]),
        preview: Self.stringValue(item["preview"], fallback: Self.stringValue(item["last_message"])),
        avatar: Self.stringValue(item["avatar"], fallback: Self.stringValue(item["photo"])),
        avatarPhotoId: Self.stringValue(item["avatar_photo_id"]),
        avatarDcId: Self.intValue(item["avatar_dc_id"], fallback: 0),
        date: Self.intValue(item["date"], fallback: 0),
        unread: Self.intValue(item["unread"], fallback: Self.intValue(item["unread_count"], fallback: 0)),
        readOnly: (item["read_only"] as? Bool) == true,
        broadcast: (item["broadcast"] as? Bool) == true,
        isSelf: (item["self"] as? Bool) == true,
        isContact: (item["contact"] as? Bool) == true,
        muted: (item["muted"] as? Bool) == true
          || (item["notification_muted"] as? Bool) == true
          || (item["silent"] as? Bool) == true,
        topMessageId: Self.intValue(item["top_message_id"], fallback: 0),
        readOutboxMaxId: Self.intValue(item["read_outbox_max_id"], fallback: 0)
      )
    }
    return (chats, nextCursor)
  }

  func fetchTelegramMessages(accountId: String, peer: String, offsetId: Int = 0) async -> (messages: [TvTelegramMessage], nextOffset: Int) {
    var query = [
      URLQueryItem(name: "peer", value: peer),
      URLQueryItem(name: "offset_id", value: String(offsetId)),
      URLQueryItem(name: "limit", value: "50"),
      URLQueryItem(name: "mark_read", value: "1"),
    ]
    if !accountId.isEmpty {
      query.append(URLQueryItem(name: "account_id", value: accountId))
    }
    guard let url = makeEndpointUrl("/api/telegram/messages", queryItems: query),
          let dict = try? await requestJson(url: url, timeout: 35) as? [String: Any] else {
      return ([], 0)
    }
    let nextOffset = Self.intValue(dict["next_offset"], fallback: 0)
    let rawMsgs = (dict["messages"] as? [[String: Any]]) ?? []
    var messages = rawMsgs.compactMap(Self.parseTelegramMessage)
    messages.sort { $0.id < $1.id }
    return (messages, rawMsgs.isEmpty ? 0 : nextOffset)
  }

  func markTelegramChatRead(accountId: String, peer: String, maxId: Int = 0) async {
    guard let url = makeEndpointUrl("/api/telegram/read", queryItems: [URLQueryItem(name: "account_id", value: accountId)]) else { return }
    var body: [String: Any] = ["peer": peer]
    if maxId > 0 { body["max_id"] = maxId }
    _ = try? await requestJson(url: url, method: "POST", body: body, timeout: 6)
  }

  func sendTelegramTextMessage(accountId: String, peer: String, text: String, replyTo: Int = 0) async throws -> TvTelegramMessage? {
    guard let url = makeEndpointUrl("/api/telegram/send", queryItems: [URLQueryItem(name: "account_id", value: accountId)]) else { return nil }
    let randomHex = String(format: "%016llx", UInt64.random(in: 1...UInt64.max))
    let res = try await requestJson(
      url: url,
      method: "POST",
      body: [
        "peer": peer,
        "text": text,
        "reply_to": replyTo,
        "random_id": randomHex,
      ],
      timeout: 30
    )
    if let dict = res as? [String: Any],
       let msgDict = dict["message"] as? [String: Any] {
      return Self.parseTelegramMessage(msgDict)
    }
    return nil
  }

  func deleteTelegramMessages(accountId: String, peer: String, messageIds: [Int], revoke: Bool = true) async throws {
    guard let url = makeEndpointUrl("/api/telegram/delete-messages", queryItems: [URLQueryItem(name: "account_id", value: accountId)]) else { return }
    _ = try await requestJson(
      url: url,
      method: "POST",
      body: [
        "peer": peer,
        "ids": messageIds,
        "revoke": revoke,
      ],
      timeout: 20
    )
  }

  func fetchTelegramFilePreview(accountId: String, peer: String, messageId: Int) async throws -> TvTelegramFilePreview {
    let items = [
      URLQueryItem(name: "account_id", value: accountId),
      URLQueryItem(name: "peer", value: peer),
      URLQueryItem(name: "message_id", value: String(messageId)),
    ]
    guard let url = makeEndpointUrl("/api/telegram/file-preview", queryItems: items),
          let dict = try await requestJson(url: url, timeout: 25) as? [String: Any] else {
      throw NSError(domain: "TvApiClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法加载文件预览"])
    }
    return TvTelegramFilePreview(
      title: Self.stringValue(dict["name"], fallback: Self.stringValue(dict["title"], fallback: "文件预览")),
      content: Self.stringValue(dict["content"], fallback: Self.stringValue(dict["text"])),
      mimeType: Self.stringValue(dict["mime_type"]),
      size: Int64(Self.intValue(dict["size"], fallback: 0))
    )
  }

  func pressTelegramButton(accountId: String, peer: String, messageId: Int, button: TvTelegramMessageButton) async -> String {
    guard let url = makeEndpointUrl("/api/telegram/button", queryItems: [URLQueryItem(name: "account_id", value: accountId)]) else { return "" }
    let randomHex = String(format: "%016llx", UInt64.random(in: 1...UInt64.max))
    guard let dict = try? await requestJson(
      url: url,
      method: "POST",
      body: [
        "peer": peer,
        "message_id": messageId,
        "row": button.row,
        "column": button.column,
        "token": button.token,
        "random_id": randomHex,
      ],
      timeout: 25
    ) as? [String: Any] else {
      return ""
    }
    return Self.stringValue(dict["notice"], fallback: Self.stringValue(dict["message_text"]))
  }

  func performTelegramConversationAction(accountId: String, peer: String, action: String) async throws {
    guard let url = makeEndpointUrl("/api/telegram/conversation-action", queryItems: [URLQueryItem(name: "account_id", value: accountId)]) else { return }
    _ = try await requestJson(
      url: url,
      method: "POST",
      body: ["peer": peer, "action": action],
      timeout: 30
    )
  }

  func telegramAvatarUrl(accountId: String, peer: String, photoId: String, dcId: Int) -> String {
    let items = [
      URLQueryItem(name: "account_id", value: accountId),
      URLQueryItem(name: "peer", value: peer),
      URLQueryItem(name: "photo_id", value: photoId),
      URLQueryItem(name: "dc_id", value: String(dcId)),
    ]
    return makeEndpointUrl("/api/telegram/avatar", queryItems: items)?.absoluteString ?? ""
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

  func telegramAcceleratedVideoUrl(accountId: String, peer: String, messageId: Int) -> String {
    let raw = telegramVideoUrl(accountId: accountId, peer: peer, messageId: messageId)
    guard !raw.isEmpty else { return "" }
    return TvLocalHlsProxyServer.shared.prepareTelegramVideoProxyUrl(remoteUrl: raw, headers: authHeaders)
  }

  func telegramThumbnailUrl(accountId: String, peer: String, messageId: Int) -> String {
    var items = [
      URLQueryItem(name: "peer", value: peer),
      URLQueryItem(name: "message_id", value: String(messageId)),
    ]
    if !accountId.isEmpty {
      items.append(URLQueryItem(name: "account_id", value: accountId))
    }
    return makeEndpointUrl("/api/telegram/thumbnail", queryItems: items)?.absoluteString ?? ""
  }

  func telegramFileContentUrl(accountId: String, peer: String, messageId: Int) -> String {
    var items = [
      URLQueryItem(name: "peer", value: peer),
      URLQueryItem(name: "message_id", value: String(messageId)),
    ]
    if !accountId.isEmpty {
      items.append(URLQueryItem(name: "account_id", value: accountId))
    }
    return makeEndpointUrl("/api/telegram/file-content", queryItems: items)?.absoluteString ?? ""
  }

  func telegramAcceleratedFileContentUrl(accountId: String, peer: String, messageId: Int) -> String {
    let raw = telegramFileContentUrl(accountId: accountId, peer: peer, messageId: messageId)
    guard !raw.isEmpty else { return "" }
    return TvLocalHlsProxyServer.shared.prepareTelegramVideoProxyUrl(remoteUrl: raw, headers: authHeaders)
  }

  // MARK: - Parsers

  private static func parseTelegramMessage(_ item: [String: Any]) -> TvTelegramMessage? {
    let msgId = intValue(item["id"], fallback: 0)
    guard msgId > 0 else { return nil }
    let text = stringValue(item["text"])
    let date = intValue(item["date"], fallback: 0)
    let sender = stringValue(item["sender"])
    let senderPeer = stringValue(item["sender_peer"], fallback: stringValue(item["from_peer"], fallback: stringValue(item["sender_id"]))).trimmingCharacters(in: .whitespacesAndNewlines)
    let senderAvatar = stringValue(item["sender_avatar"], fallback: stringValue(item["avatar"])).trimmingCharacters(in: .whitespacesAndNewlines)
    let outgoing = (item["outgoing"] as? Bool) == true
    let groupedId = stringValue(item["grouped_id"])
    let replyToId = intValue(item["reply_to_id"], fallback: 0)

    var links: [String] = []
    if let rawLinks = item["links"] as? [Any] {
      for l in rawLinks {
        let s = stringValue(l).trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty && !links.contains(s) { links.append(s) }
      }
    }
    if let rawTextLinks = item["text_links"] as? [[String: Any]] {
      for tl in rawTextLinks {
        let u = stringValue(tl["url"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !u.isEmpty && !links.contains(u) { links.append(u) }
      }
    }

    var parsedAtt: TvTelegramAttachment? = nil
    if let attDict = item["attachment"] as? [String: Any] {
      let att = TvTelegramAttachment(
        kind: stringValue(attDict["kind"], fallback: "file"),
        name: stringValue(attDict["name"]),
        fileName: stringValue(attDict["file_name"]),
        title: stringValue(attDict["title"]),
        performer: stringValue(attDict["performer"]),
        voice: (attDict["voice"] as? Bool) == true,
        size: Int64(intValue(attDict["size"], fallback: 0)),
        mimeType: stringValue(attDict["mime_type"]),
        duration: intValue(attDict["duration"], fallback: 0),
        width: intValue(attDict["width"], fallback: 0),
        height: intValue(attDict["height"], fallback: 0),
        url: stringValue(attDict["url"]),
        thumbnail: stringValue(attDict["thumbnail"]),
        hasThumbnail: (attDict["has_thumbnail"] as? Bool) == true
      )
      if !att.url.isEmpty || att.hasThumbnail || !att.fileName.isEmpty || !att.name.isEmpty || att.size > 0 {
        parsedAtt = att
      }
    }

    var buttonRows: [[TvTelegramMessageButton]] = []
    if let rawBtns = item["buttons"] as? [[[String: Any]]] {
      for (rIdx, row) in rawBtns.enumerated() {
        var parsedRow: [TvTelegramMessageButton] = []
        for (cIdx, cell) in row.enumerated() {
          let label = stringValue(cell["text"], fallback: stringValue(cell["label"]))
          guard !label.isEmpty else { continue }
          let u = stringValue(cell["url"])
          let kind = stringValue(cell["kind"], fallback: u.isEmpty ? "callback" : "url").lowercased()
          let token = stringValue(cell["token"], fallback: stringValue(cell["data"]))
          parsedRow.append(
            TvTelegramMessageButton(row: rIdx, column: cIdx, text: label, kind: kind, url: u, token: token)
          )
        }
        if !parsedRow.isEmpty { buttonRows.append(parsedRow) }
      }
    }

    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && parsedAtt == nil
        && buttonRows.isEmpty
        && links.isEmpty {
      return nil
    }

    return TvTelegramMessage(
      id: msgId,
      date: date,
      sender: sender,
      senderPeer: senderPeer,
      senderAvatar: senderAvatar,
      text: text,
      outgoing: outgoing,
      groupedId: groupedId,
      replyToId: replyToId,
      links: links,
      buttons: buttonRows,
      attachment: parsedAtt
    )
  }

  private static func parseVodListDict(
    _ dict: [String: Any],
    overrideClasses: [[String: Any]]?,
    source: TvVodSource,
    page: Int
  ) -> TvVodListResponse {
    let rawClasses = (overrideClasses != nil && !overrideClasses!.isEmpty)
      ? overrideClasses!
      : ((dict["class"] as? [[String: Any]]) ?? (dict["categories"] as? [[String: Any]]) ?? [])

    var categories: [TvVodCategory] = []
    var seenCatIds = Set<String>()
    for item in rawClasses {
      let tid = stringValue(item["type_id"], fallback: stringValue(item["id"])).trimmingCharacters(in: .whitespacesAndNewlines)
      let tname = stringValue(item["type_name"], fallback: stringValue(item["name"])).trimmingCharacters(in: .whitespacesAndNewlines)
      if !tid.isEmpty && tid.lowercased() != "null" && !tname.isEmpty && !seenCatIds.contains(tid) {
        seenCatIds.insert(tid)
        categories.append(TvVodCategory(typeId: tid, typeName: tname))
      }
    }

    let rawList = (dict["list"] as? [[String: Any]]) ?? []
    var items: [TvVodItem] = []
    for rawItem in rawList {
      if let parsed = parseVodItem(rawItem, source: source) {
        items.append(parsed)
      }
      if rawClasses.isEmpty {
        let tid = stringValue(rawItem["type_id"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let tname = stringValue(rawItem["type_name"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tid.isEmpty && tid.lowercased() != "null" && !tname.isEmpty && !seenCatIds.contains(tid) {
          seenCatIds.insert(tid)
          categories.append(TvVodCategory(typeId: tid, typeName: tname))
        }
      }
    }

    let total = intValue(dict["total"], fallback: items.count)
    var pageCount = intValue(dict["pagecount"], fallback: intValue(dict["page_count"], fallback: 0))
    if pageCount <= 1 {
      if total > items.count && !items.isEmpty {
        let limit = max(1, intValue(dict["limit"], fallback: items.count))
        pageCount = max(page, (total + limit - 1) / limit)
      } else if dict["pagecount"] == nil && items.count >= 15 {
        pageCount = page + 1
      } else if pageCount <= 0 {
        pageCount = 1
      }
    }

    return TvVodListResponse(categories: categories, items: items, pageCount: pageCount, resolvedTypeId: nil)
  }

  private static func parseVodItem(_ item: [String: Any], source: TvVodSource) -> TvVodItem? {
    var vodId = stringValue(item["vod_id"], fallback: stringValue(item["id"])).trimmingCharacters(in: .whitespacesAndNewlines)
    if vodId.lowercased() == "null" { vodId = "" }
    let vodName = stringValue(item["vod_name"], fallback: stringValue(item["name"], fallback: "未命名影片")).trimmingCharacters(in: .whitespacesAndNewlines)
    if vodId.isEmpty && !vodName.isEmpty && vodName != "未命名影片" {
      vodId = "msearch:\(vodName)"
    }
    guard !vodId.isEmpty else { return nil }
    return TvVodItem(
      vodId: vodId,
      vodName: vodName,
      vodPic: stringValue(item["vod_pic"], fallback: stringValue(item["pic"])).trimmingCharacters(in: .whitespacesAndNewlines),
      vodRemarks: stringValue(item["vod_remarks"], fallback: stringValue(item["remarks"])).trimmingCharacters(in: .whitespacesAndNewlines),
      vodYear: stringValue(item["vod_year"], fallback: stringValue(item["year"])).trimmingCharacters(in: .whitespacesAndNewlines),
      typeName: stringValue(item["type_name"]).trimmingCharacters(in: .whitespacesAndNewlines),
      source: source
    )
  }

  private static func parseVodDetail(_ item: [String: Any]) -> TvVodDetail {
    let vodId = stringValue(item["vod_id"], fallback: stringValue(item["id"])).trimmingCharacters(in: .whitespacesAndNewlines)
    let playFrom = stringValue(item["vod_play_from"], fallback: stringValue(item["play_from"]))
    let playUrl = stringValue(
      item["vod_play_url"],
      fallback: stringValue(item["vod_url"], fallback: stringValue(item["play_url"]))
    )
    return TvVodDetail(
      vodId: vodId,
      vodName: stringValue(item["vod_name"], fallback: stringValue(item["name"], fallback: "未命名影片")),
      vodPic: stringValue(item["vod_pic"], fallback: stringValue(item["pic"])),
      vodRemarks: stringValue(item["vod_remarks"]),
      vodYear: stringValue(item["vod_year"]),
      vodArea: stringValue(item["vod_area"]),
      vodActor: stringValue(item["vod_actor"]),
      vodDirector: stringValue(item["vod_director"]),
      vodContent: stringValue(item["vod_content"], fallback: stringValue(item["vod_blurb"]))
        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines),
      typeName: stringValue(item["type_name"], fallback: stringValue(item["vod_type"])),
      playGroups: TvVodDetail.parsePlayGroups(playFrom: playFrom, playUrl: playUrl, fallbackVodId: vodId)
    )
  }

  private static func parseLibraryItem(_ item: [String: Any]) -> TvLibraryItem {
    TvLibraryItem(
      source: stringValue(item["source"]),
      sourceName: stringValue(item["source_name"]),
      vodId: stringValue(item["vod_id"]),
      title: stringValue(item["title"]),
      poster: stringValue(item["poster"], fallback: stringValue(item["pic"])),
      remark: stringValue(item["remark"]),
      episode: stringValue(item["episode"]),
      line: stringValue(item["line"]),
      position: doubleValue(item["position"], fallback: 0),
      duration: doubleValue(item["duration"], fallback: 0),
      updated: Int64(intValue(item["updated"], fallback: intValue(item["updated_at"], fallback: 0)))
    )
  }

  nonisolated static func stringValue(_ any: Any?, fallback: String = "") -> String {
    guard let any = any, !(any is NSNull) else { return fallback }
    if let s = any as? String {
      return (s == "<null>" || s == "null") ? fallback : s
    }
    if let n = any as? NSNumber { return n.stringValue }
    let desc = String(describing: any)
    return (desc == "<null>" || desc == "null") ? fallback : desc
  }

  nonisolated static func intValue(_ any: Any?, fallback: Int = 0) -> Int {
    guard let any = any, !(any is NSNull) else { return fallback }
    if let i = any as? Int { return i }
    if let n = any as? NSNumber { return n.intValue }
    if let s = any as? String, let i = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
      return i
    }
    return fallback
  }

  nonisolated static func doubleValue(_ any: Any?, fallback: Double = 0) -> Double {
    guard let any = any, !(any is NSNull) else { return fallback }
    if let d = any as? Double { return d }
    if let n = any as? NSNumber { return n.doubleValue }
    if let s = any as? String, let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
      return d
    }
    return fallback
  }
}

// MARK: - 8. Official 115 Cloud Drive Local Direct Client (m115 RSA+XOR Crypto + QR Login + Direct Domestic CDN Stream Resolver)

enum TvM115Crypto {
  private static let xorKeySeed: [UInt8] = [
    0xf0, 0xe5, 0x69, 0xae, 0xbf, 0xdc, 0xbf, 0x8a,
    0x1a, 0x45, 0xe8, 0xbe, 0x7d, 0xa6, 0x73, 0xb8,
    0xde, 0x8f, 0xe7, 0xc4, 0x45, 0xda, 0x86, 0xc4,
    0x9b, 0x64, 0x8b, 0x14, 0x6a, 0xb4, 0xf1, 0xaa,
    0x38, 0x01, 0x35, 0x9e, 0x26, 0x69, 0x2c, 0x86,
    0x00, 0x6b, 0x4f, 0xa5, 0x36, 0x34, 0x62, 0xa6,
    0x2a, 0x96, 0x68, 0x18, 0xf2, 0x4a, 0xfd, 0xbd,
    0x6b, 0x97, 0x8f, 0x4d, 0x8f, 0x89, 0x13, 0xb7,
    0x6c, 0x8e, 0x93, 0xed, 0x0e, 0x0d, 0x48, 0x3e,
    0xd7, 0x2f, 0x88, 0xd8, 0xfe, 0xfe, 0x7e, 0x86,
    0x50, 0x95, 0x4f, 0xd1, 0xeb, 0x83, 0x26, 0x34,
    0xdb, 0x66, 0x7b, 0x9c, 0x7e, 0x9d, 0x7a, 0x81,
    0x32, 0xea, 0xb6, 0x33, 0xde, 0x3a, 0xa9, 0x59,
    0x34, 0x66, 0x3b, 0xaa, 0xba, 0x81, 0x60, 0x48,
    0xb9, 0xd5, 0x81, 0x9c, 0xf8, 0x6c, 0x84, 0x77,
    0xff, 0x54, 0x78, 0x26, 0x5f, 0xbe, 0xe8, 0x1e,
    0x36, 0x9f, 0x34, 0x80, 0x5c, 0x45, 0x2c, 0x9b,
    0x76, 0xd5, 0x1b, 0x8f, 0xcc, 0xc3, 0xb8, 0xf5
  ]

  private static let xorClientKey: [UInt8] = [
    0x78, 0x06, 0xad, 0x4c, 0x33, 0x86, 0x5d, 0x18,
    0x4c, 0x01, 0x3f, 0x46
  ]

  // 1024-bit RSA modulus from elevengo/internal/crypto/m115/rsa.go (big-endian 128 bytes)
  private static let rsaModulusBytes: [UInt8] = [
    0x86, 0x86, 0x98, 0x0c, 0x0f, 0x5a, 0x24, 0xc4, 0xb9, 0xd4, 0x30, 0x20, 0xcd, 0x2c, 0x22, 0x70,
    0x3f, 0xf3, 0xf4, 0x50, 0x75, 0x65, 0x29, 0x05, 0x8b, 0x1c, 0xf8, 0x8f, 0x09, 0xb8, 0x60, 0x21,
    0x36, 0x47, 0x71, 0x98, 0xa6, 0xe2, 0x68, 0x31, 0x49, 0x65, 0x9b, 0xd1, 0x22, 0xc3, 0x35, 0x92,
    0xfd, 0xb5, 0xad, 0x47, 0x94, 0x4a, 0xd1, 0xea, 0x4d, 0x36, 0xc6, 0xb1, 0x72, 0xaa, 0xd6, 0x33,
    0x8c, 0x3b, 0xb6, 0xac, 0x62, 0x27, 0x50, 0x2d, 0x01, 0x09, 0x93, 0xac, 0x96, 0x7d, 0x1a, 0xef,
    0x00, 0xf0, 0xc8, 0xe0, 0x38, 0xde, 0x2e, 0x4d, 0x3b, 0xc2, 0xec, 0x36, 0x8a, 0xf2, 0xe9, 0xf1,
    0x0a, 0x6f, 0x1e, 0xda, 0x4f, 0x72, 0x62, 0xf1, 0x36, 0x42, 0x0c, 0x07, 0xc3, 0x31, 0xb8, 0x71,
    0xbf, 0x13, 0x9f, 0x74, 0xf3, 0x01, 0x0e, 0x3c, 0x4f, 0xe5, 0x7d, 0xf3, 0xaf, 0xb7, 0x16, 0x83
  ]

  static func generateKey() -> [UInt8] {
    (0..<16).map { _ in UInt8.random(in: 0...255) }
  }

  static func encode(input: Data, key: [UInt8]) -> String {
    var payload = Array(input)
    xorTransform(&payload, key: xorDeriveKey(seed: key, size: 4))
    payload.reverse()
    xorTransform(&payload, key: xorClientKey)
    var buf = Array(key.prefix(16))
    buf.append(contentsOf: payload)
    let encrypted = rsaEncrypt(buf)
    return Data(encrypted).base64EncodedString()
  }

  static func decode(input: String, key: [UInt8]) -> Data? {
    guard let rawData = Data(base64Encoded: input, options: .ignoreUnknownCharacters) else {
      return nil
    }
    let decrypted = rsaDecrypt(Array(rawData))
    guard decrypted.count > 16 else { return nil }
    let head16 = Array(decrypted[0..<16])
    var output = Array(decrypted[16...])
    xorTransform(&output, key: xorDeriveKey(seed: head16, size: 12))
    output.reverse()
    xorTransform(&output, key: xorDeriveKey(seed: key, size: 4))
    return Data(output)
  }

  private static func xorDeriveKey(seed: [UInt8], size: Int) -> [UInt8] {
    var key = [UInt8](repeating: 0, count: size)
    for i in 0..<size {
      let a = (UInt16(seed[i]) + UInt16(xorKeySeed[size * i])) & 0xff
      key[i] = UInt8(a) ^ xorKeySeed[size * (size - i - 1)]
    }
    return key
  }

  private static func xorTransform(_ data: inout [UInt8], key: [UInt8]) {
    let dataSize = data.count
    let keySize = key.count
    guard keySize > 0 else { return }
    let mod = dataSize % 4
    if mod > 0 {
      for i in 0..<mod {
        data[i] ^= key[i % keySize]
      }
    }
    for i in mod..<dataSize {
      data[i] ^= key[(i - mod) % keySize]
    }
  }

  private static func rsaEncrypt(_ input: [UInt8]) -> [UInt8] {
    let keyLength = 128
    var out: [UInt8] = []
    var cursor = 0
    while cursor < input.count {
      let remain = input.count - cursor
      let sliceSize = min(keyLength - 11, remain)
      let slice = Array(input[cursor..<(cursor + sliceSize)])
      cursor += sliceSize

      let padSize = keyLength - slice.count - 3
      var block = [UInt8](repeating: 0, count: keyLength)
      block[0] = 0
      block[1] = 2
      for i in 0..<padSize {
        block[2 + i] = UInt8.random(in: 1...255)
      }
      block[padSize + 2] = 0
      for i in 0..<slice.count {
        block[padSize + 3 + i] = slice[i]
      }
      out.append(contentsOf: rsaModExp65537(block))
    }
    return out
  }

  private static func rsaDecrypt(_ input: [UInt8]) -> [UInt8] {
    let keyLength = 128
    var out: [UInt8] = []
    var cursor = 0
    while cursor < input.count {
      let sliceSize = min(keyLength, input.count - cursor)
      var slice = Array(input[cursor..<(cursor + sliceSize)])
      cursor += sliceSize
      if slice.count < keyLength {
        slice = [UInt8](repeating: 0, count: keyLength - slice.count) + slice
      }
      let ret = rsaModExp65537(slice)
      // Strip leading zeros and PKCS#1 padding up to the first 0x00 separator after non-zero bytes
      var seenNonZero = false
      var startIdx: Int? = nil
      for (idx, b) in ret.enumerated() {
        if b != 0 {
          seenNonZero = true
        } else if seenNonZero {
          startIdx = idx + 1
          break
        }
      }
      if let s = startIdx, s < ret.count {
        out.append(contentsOf: ret[s...])
      }
    }
    return out
  }

  /// Computes `block ^ 65537 mod rsaModulusBytes` using 128-byte (1024-bit) big-endian arithmetic
  private static func rsaModExp65537(_ block: [UInt8]) -> [UInt8] {
    let mod = bytesToLimbs(rsaModulusBytes)
    let base = bytesToLimbs(block)
    var acc = base
    // 65537 = 2^16 + 1 -> 16 modular squarings + 1 modular multiplication
    for _ in 0..<16 {
      acc = mulMod1024(acc, acc, mod)
    }
    acc = mulMod1024(acc, base, mod)
    return limbsToBytes(acc)
  }

  // Little-endian 32 x UInt32 limbs (limb 0 = least significant 32 bits)
  private static func bytesToLimbs(_ bytes: [UInt8]) -> [UInt32] {
    var padded = bytes
    if padded.count < 128 {
      padded = [UInt8](repeating: 0, count: 128 - padded.count) + padded
    } else if padded.count > 128 {
      padded = Array(padded.suffix(128))
    }
    var limbs = [UInt32](repeating: 0, count: 32)
    for i in 0..<32 {
      let baseIdx = 124 - i * 4
      let w = (UInt32(padded[baseIdx]) << 24)
        | (UInt32(padded[baseIdx + 1]) << 16)
        | (UInt32(padded[baseIdx + 2]) << 8)
        | UInt32(padded[baseIdx + 3])
      limbs[i] = w
    }
    return limbs
  }

  private static func limbsToBytes(_ limbs: [UInt32]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 128)
    for i in 0..<32 {
      let baseIdx = 124 - i * 4
      let w = limbs[i]
      out[baseIdx] = UInt8((w >> 24) & 0xff)
      out[baseIdx + 1] = UInt8((w >> 16) & 0xff)
      out[baseIdx + 2] = UInt8((w >> 8) & 0xff)
      out[baseIdx + 3] = UInt8(w & 0xff)
    }
    return out
  }

  private static func mulMod1024(_ a: [UInt32], _ b: [UInt32], _ mod: [UInt32]) -> [UInt32] {
    var prod = [UInt32](repeating: 0, count: 64)
    for i in 0..<32 {
      var carry: UInt64 = 0
      let ai = UInt64(a[i])
      for j in 0..<32 {
        let sum = UInt64(prod[i + j]) + ai * UInt64(b[j]) + carry
        prod[i + j] = UInt32(truncatingIfNeeded: sum)
        carry = sum >> 32
      }
      prod[i + 32] = UInt32(truncatingIfNeeded: carry)
    }

    // Bitwise shift-and-subtract reduction of 2048-bit `prod` modulo 1024-bit `mod`
    var rem = [UInt32](repeating: 0, count: 33)
    for bitIdx in stride(from: 2047, through: 0, by: -1) {
      let wordIdx = bitIdx >> 5
      let bitOffset = bitIdx & 31
      let inBit = (prod[wordIdx] >> bitOffset) & 1

      var carry = inBit
      for k in 0..<33 {
        let nextCarry = rem[k] >> 31
        rem[k] = (rem[k] << 1) | carry
        carry = nextCarry
      }

      // Compare rem >= mod
      var ge = rem[32] > 0
      if !ge {
        for k in stride(from: 31, through: 0, by: -1) {
          if rem[k] != mod[k] {
            ge = rem[k] > mod[k]
            break
          }
          if k == 0 {
            ge = true
          }
        }
      }

      if ge {
        var borrow: Int64 = 0
        for k in 0..<32 {
          let diff = Int64(rem[k]) - Int64(mod[k]) - borrow
          if diff < 0 {
            rem[k] = UInt32(truncatingIfNeeded: diff + (1 << 32))
            borrow = 1
          } else {
            rem[k] = UInt32(truncatingIfNeeded: diff)
            borrow = 0
          }
        }
        rem[32] = UInt32( max(0, Int64(rem[32]) - borrow) )
      }
    }
    return Array(rem[0..<32])
  }
}

final class TvM115AuthCookieStore: @unchecked Sendable {
  static let shared = TvM115AuthCookieStore()
  static let browserUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 115Browser/27.0.5.7"

  private let lock = NSLock()
  private var cdnAuthCookiesByUrl: [String: String] = [:]
  private var latestCdnAuthCookie: String = ""
  private var pickcodeUrlCache: [String: (url: String, ts: TimeInterval)] = [:]

  func cachedUrl(forPickcode pc: String) -> String? {
    let now = Date().timeIntervalSince1970
    lock.lock()
    defer { lock.unlock() }
    if let hit = pickcodeUrlCache[pc], now - hit.ts < 12.0 {
      return hit.url
    }
    return nil
  }

  func recordResolved(pickcode: String, url: String, authPair: String) {
    lock.lock()
    defer { lock.unlock() }
    if !authPair.isEmpty {
      if cdnAuthCookiesByUrl.count > 128 {
        cdnAuthCookiesByUrl.removeAll(keepingCapacity: true)
      }
      cdnAuthCookiesByUrl[url] = authPair
      latestCdnAuthCookie = authPair
    }
    pickcodeUrlCache[pickcode] = (url, Date().timeIntervalSince1970)
  }

  func cookieHeader(forUrl urlStr: String = "", baseCookie: String? = nil) -> String {
    let base = (baseCookie ?? UserDefaults.standard.string(forKey: "tv_local_115_cookie") ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    lock.lock()
    let extra = cdnAuthCookiesByUrl[urlStr] ?? latestCdnAuthCookie
    lock.unlock()
    guard !extra.isEmpty else { return base }
    if base.contains(extra) { return base }
    return base.isEmpty ? extra : "\(base); \(extra)"
  }
}

@MainActor
final class TvLocal115DirectClient {
  static let shared = TvLocal115DirectClient()

  nonisolated static let browserUserAgent = TvM115AuthCookieStore.browserUserAgent

  private let session: URLSession
  private let defaultsKeyCookie = "tv_local_115_cookie"
  private let defaultsKeyUserName = "tv_local_115_user_name"
  private let defaultsKeyTargetFolderName = "tv_local_115_folder_name"
  private let defaultsKeyTargetFolderCid = "tv_local_115_folder_cid"
  nonisolated static let defaultTargetFolderName = "流光115加速"

  var targetFolderName: String {
    get {
      let raw = (UserDefaults.standard.string(forKey: defaultsKeyTargetFolderName) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      return raw.isEmpty ? Self.defaultTargetFolderName : raw
    }
    set {
      let clean = newValue
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "\\", with: "_")
        .replacingOccurrences(of: ":", with: "_")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let nextName = clean.isEmpty ? Self.defaultTargetFolderName : clean
      if nextName != targetFolderName {
        UserDefaults.standard.set(nextName, forKey: defaultsKeyTargetFolderName)
        UserDefaults.standard.removeObject(forKey: defaultsKeyTargetFolderCid)
      }
    }
  }

  var targetFolderCid: String {
    get {
      (UserDefaults.standard.string(forKey: defaultsKeyTargetFolderCid) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    set {
      UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: defaultsKeyTargetFolderCid)
    }
  }

  /// Finds or creates the designated 115 upload folder (default `/流光115加速`) in 115 root (`cid=0`),
  /// caches its `cid`, and syncs `"eleven_dir_id": cid` to the backend server's `/api/settings`.
  func ensureAccelerationFolderCid(syncToServerApi: TvApiClient? = nil, forceVerify: Bool = false) async -> String {
    guard hasLocalCookie else { return "0" }
    let folderName = targetFolderName
    let cachedCid = targetFolderCid
    if !forceVerify && !cachedCid.isEmpty && cachedCid != "0" {
      if let api = syncToServerApi {
        Task {
          await self.syncFolderCidToServer(api: api, targetCid: cachedCid)
        }
      }
      return cachedCid
    }

    var resolvedCid = ""
    if let listUrl = URL(string: "https://webapi.115.com/files?aid=1&cid=0&o=user_ptime&asc=0&offset=0&limit=115&show_dir=1&format=json"),
       let entries = await fetchFileEntries(from: listUrl) {
      for item in entries {
        let fid = TvApiClient.stringValue(item["fid"], fallback: TvApiClient.stringValue(item["file_id"])).trimmingCharacters(in: .whitespacesAndNewlines)
        let cid = TvApiClient.stringValue(item["cid"], fallback: TvApiClient.stringValue(item["category_id"])).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = TvApiClient.stringValue(item["n"], fallback: TvApiClient.stringValue(item["file_name"])).trimmingCharacters(in: .whitespacesAndNewlines)
        let isDir = (fid.isEmpty || fid == "0") && !cid.isEmpty && cid != "0"
        if isDir && name.lowercased() == folderName.lowercased() {
          resolvedCid = cid
          break
        }
      }
    }

    if resolvedCid.isEmpty, let addUrl = URL(string: "https://webapi.115.com/files/add") {
      var req = URLRequest(url: addUrl)
      req.httpMethod = "POST"
      req.timeoutInterval = 12
      for (k, v) in requestHeaders {
        req.setValue(v, forHTTPHeaderField: k)
      }
      req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      let encName = folderName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? folderName
      req.httpBody = "pid=0&cname=\(encName)".data(using: .utf8)
      if let (data, _) = try? await session.data(for: req),
         let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        let directCid = TvApiClient.stringValue(root["cid"], fallback: TvApiClient.stringValue(root["file_id"])).trimmingCharacters(in: .whitespacesAndNewlines)
        if !directCid.isEmpty && directCid != "0" {
          resolvedCid = directCid
        } else if let dataObj = root["data"] as? [String: Any] {
          let nestedCid = TvApiClient.stringValue(dataObj["cid"], fallback: TvApiClient.stringValue(dataObj["category_id"])).trimmingCharacters(in: .whitespacesAndNewlines)
          if !nestedCid.isEmpty && nestedCid != "0" {
            resolvedCid = nestedCid
          }
        }
      }
    }

    if !resolvedCid.isEmpty && resolvedCid != "0" {
      targetFolderCid = resolvedCid
      if let api = syncToServerApi {
        await syncFolderCidToServer(api: api, targetCid: resolvedCid)
      }
      return resolvedCid
    }
    return !cachedCid.isEmpty ? cachedCid : "0"
  }

  private func syncFolderCidToServer(api: TvApiClient, targetCid: String) async {
    guard !targetCid.isEmpty && targetCid != "0" else { return }
    var settings = await api.fetchServerSettings()
    guard !settings.isEmpty else { return }
    let cur = TvApiClient.stringValue(settings["eleven_dir_id"]).trimmingCharacters(in: .whitespacesAndNewlines)
    if cur != targetCid {
      settings["eleven_dir_id"] = targetCid
      try? await api.saveServerSettings(settings)
    }
  }

  func move115FileToFolder(fid: String, targetCid: String) async {
    guard hasLocalCookie,
          !fid.isEmpty, fid != "0",
          !targetCid.isEmpty, targetCid != "0",
          let moveUrl = URL(string: "https://webapi.115.com/files/move") else { return }
    var req = URLRequest(url: moveUrl)
    req.httpMethod = "POST"
    req.timeoutInterval = 12
    for (k, v) in requestHeaders {
      req.setValue(v, forHTTPHeaderField: k)
    }
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.httpBody = "pid=\(targetCid)&fid[0]=\(fid)&nodup=1".data(using: .utf8)
    _ = try? await session.data(for: req)
  }

  func cookieHeader(forUrl urlStr: String = "") -> String {
    TvM115AuthCookieStore.shared.cookieHeader(forUrl: urlStr, baseCookie: savedCookie)
  }

  func streamHeaders(forUrl urlStr: String = "") -> [String: String] {
    var h: [String: String] = [
      "User-Agent": Self.browserUserAgent,
      "Referer": "https://115.com/"
    ]
    let ck = cookieHeader(forUrl: urlStr)
    if !ck.isEmpty {
      h["Cookie"] = ck
    }
    return h
  }

  private init() {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 18
    cfg.timeoutIntervalForResource = 35
    cfg.httpShouldSetCookies = false
    self.session = URLSession(configuration: cfg, delegate: InsecureSessionDelegate(), delegateQueue: nil)
  }

  var savedCookie: String {
    get {
      (UserDefaults.standard.string(forKey: defaultsKeyCookie) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    set {
      UserDefaults.standard.set(Self.normalizeCookieString(newValue), forKey: defaultsKeyCookie)
    }
  }

  var savedUserName: String {
    get {
      UserDefaults.standard.string(forKey: defaultsKeyUserName) ?? ""
    }
    set {
      UserDefaults.standard.set(newValue, forKey: defaultsKeyUserName)
    }
  }

  var hasLocalCookie: Bool {
    let c = savedCookie
    return c.contains("UID=") && c.contains("CID=") && c.contains("SEID=")
  }

  var requestHeaders: [String: String] {
    var h: [String: String] = [
      "User-Agent": Self.browserUserAgent,
      "Accept": "application/json, text/plain, */*",
      "Referer": "https://115.com/",
      "Origin": "https://115.com"
    ]
    let ck = savedCookie
    if !ck.isEmpty {
      h["Cookie"] = ck
    }
    return h
  }

  static func normalizeCookieString(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    var kvMap: [String: String] = [:]
    var extraPairs: [String] = []
    let coreKeys: Set<String> = ["UID", "CID", "SEID", "KID"]
    for part in trimmed.components(separatedBy: ";") {
      let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
      let kv = p.components(separatedBy: "=")
      if kv.count >= 2 {
        let origK = kv[0].trimmingCharacters(in: .whitespaces)
        let upperK = origK.uppercased()
        let v = kv.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
        if !upperK.isEmpty && !v.isEmpty {
          if coreKeys.contains(upperK) {
            kvMap[upperK] = v
          } else {
            extraPairs.append("\(origK)=\(v)")
          }
        }
      }
    }
    var ordered: [String] = []
    for k in ["UID", "CID", "SEID", "KID"] {
      if let v = kvMap[k], !v.isEmpty {
        ordered.append("\(k)=\(v)")
      }
    }
    ordered.append(contentsOf: extraPairs)
    return ordered.isEmpty ? trimmed : ordered.joined(separator: "; ")
  }

  /// Verifies whether the local 115 Cookie is valid by calling `https://my.115.com/?ct=ajax&ac=nav` directly from Apple TV
  func verifyStatus() async -> (loggedIn: Bool, userName: String) {
    guard hasLocalCookie,
          let u = URL(string: "https://my.115.com/?ct=ajax&ac=nav") else {
      return (false, "")
    }
    var req = URLRequest(url: u)
    req.timeoutInterval = 10
    for (k, v) in requestHeaders {
      req.setValue(v, forHTTPHeaderField: k)
    }
    guard let (data, _) = try? await session.data(for: req),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return (true, savedUserName.isEmpty ? "115 会员" : savedUserName)
    }
    let state = (dict["state"] as? Bool) == true || TvApiClient.intValue(dict["state"]) == 1
    if state, let info = dict["data"] as? [String: Any] {
      let name = TvApiClient.stringValue(info["user_name"], fallback: TvApiClient.stringValue(info["user_id"], fallback: "115 用户"))
      savedUserName = name
      return (true, name)
    }
    return (false, "")
  }

  /// Starts an official 115 QR Code login session directly from Apple TV (`https://qrcodeapi.115.com/api/1.0/web/1.0/token`)
  func startQrCodeSession() async throws -> (uid: String, time: Int64, sign: String, qrContent: String, imageUrl: String) {
    guard let u = URL(string: "https://qrcodeapi.115.com/api/1.0/web/1.0/token") else {
      throw NSError(domain: "TvLocal115", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的二维码请求地址"])
    }
    var req = URLRequest(url: u)
    req.timeoutInterval = 12
    req.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
    let (data, _) = try await session.data(for: req)
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let dataDict = root["data"] as? [String: Any] else {
      throw NSError(domain: "TvLocal115", code: -2, userInfo: [NSLocalizedDescriptionKey: "解析 115 二维码数据失败"])
    }
    let uid = TvApiClient.stringValue(dataDict["uid"])
    let time = Int64(TvApiClient.intValue(dataDict["time"]))
    let sign = TvApiClient.stringValue(dataDict["sign"])
    let qrContent = TvApiClient.stringValue(dataDict["qrcode"], fallback: "https://115.com/scan/dg-\(uid)")
    let imageUrl = "https://qrcodeapi.115.com/api/1.0/web/1.0/qrcode?qrfrom=1&client=0&uid=\(uid)"
    guard !uid.isEmpty, !sign.isEmpty else {
      throw NSError(domain: "TvLocal115", code: -3, userInfo: [NSLocalizedDescriptionKey: "获取 115 二维码 UID 失败"])
    }
    return (uid, time, sign, qrContent, imageUrl)
  }

  /// Polls 115 QR code status (`https://qrcodeapi.115.com/get/status/`) and exchanges for Cookie when status == 2
  func pollQrCodeStatus(uid: String, time: Int64, sign: String) async -> (status: Int, message: String, cookie: String?, userName: String?) {
    var comp = URLComponents(string: "https://qrcodeapi.115.com/get/status/")
    comp?.queryItems = [
      URLQueryItem(name: "uid", value: uid),
      URLQueryItem(name: "time", value: String(time)),
      URLQueryItem(name: "sign", value: sign),
      URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970)))
    ]
    guard let u = comp?.url else {
      return (-1, "二维码轮询地址无效", nil, nil)
    }
    var req = URLRequest(url: u)
    req.timeoutInterval = 30
    req.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
    guard let (data, _) = try? await session.data(for: req),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return (0, "等待手机 115 网盘 App 扫码...", nil, nil)
    }
    let state = TvApiClient.intValue(root["state"], fallback: 1)
    if state == 0 {
      return (-2, "二维码已过期，请刷新二维码", nil, nil)
    }
    let dataDict = (root["data"] as? [String: Any]) ?? [:]
    let status = TvApiClient.intValue(dataDict["status"], fallback: 0)
    switch status {
    case 0:
      return (0, "请使用手机 115 网盘 App 扫描二维码", nil, nil)
    case 1:
      return (1, "✓ 已扫码，请在手机 115 App 上点击「确认登录」", nil, nil)
    case 2:
      if let loginRes = await exchangeQrCodeForCookie(uid: uid) {
        self.savedCookie = loginRes.cookie
        self.savedUserName = loginRes.userName
        return (2, "✓ 115 网盘扫码登录成功！", loginRes.cookie, loginRes.userName)
      }
      return (-1, "扫码成功但获取 Cookie 失败，请重试", nil, nil)
    case -2:
      return (-2, "已取消扫码或二维码已过期", nil, nil)
    default:
      return (status, TvApiClient.stringValue(dataDict["msg"], fallback: "等待扫码确认..."), nil, nil)
    }
  }

  private func exchangeQrCodeForCookie(uid: String) async -> (cookie: String, userName: String)? {
    // Prefer "tv" / "ios" / "android" / "mac" before "web" so Apple TV session does not conflict with Web browsers or AList "web" cookies
    for app in ["tv", "ios", "android", "mac", "web"] {
      guard let u = URL(string: "https://passportapi.115.com/app/1.0/\(app)/1.0/login/qrcode") else { continue }
      var req = URLRequest(url: u)
      req.httpMethod = "POST"
      req.timeoutInterval = 12
      req.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
      req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      let bodyStr = "account=\(uid)&app=\(app)"
      req.httpBody = bodyStr.data(using: .utf8)
      guard let (data, _) = try? await session.data(for: req),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataDict = root["data"] as? [String: Any],
            let cookieDict = dataDict["cookie"] as? [String: Any] else {
        continue
      }
      let uidVal = TvApiClient.stringValue(cookieDict["UID"])
      let cidVal = TvApiClient.stringValue(cookieDict["CID"])
      let seidVal = TvApiClient.stringValue(cookieDict["SEID"])
      let kidVal = TvApiClient.stringValue(cookieDict["KID"])
      guard !uidVal.isEmpty && !cidVal.isEmpty && !seidVal.isEmpty else { continue }
      var parts = ["UID=\(uidVal)", "CID=\(cidVal)", "SEID=\(seidVal)"]
      if !kidVal.isEmpty {
        parts.append("KID=\(kidVal)")
      }
      let userName = TvApiClient.stringValue(
        dataDict["user_name"],
        fallback: TvApiClient.stringValue(dataDict["user_id"], fallback: "115 用户")
      )
      return (parts.joined(separator: "; "), userName)
    }
    return nil
  }

  /// Searches 115 Cloud Drive directly from Apple TV for a video file matching `keywords` and resolves its official 115 domestic CDN direct playback URL.
  func findAndResolveDirectPlayUrl(
    keywords: [String],
    allowNewestRecentFallbackAfter: Date? = nil
  ) async -> (proxyStreamUrl: String, directCdnUrl: String, headers: [String: String], fileName: String)? {
    guard hasLocalCookie else { return nil }

    let accelCid = await ensureAccelerationFolderCid()

    let cleanKeywords = keywords
      .map { Self.cleanMatchToken($0) }
      .filter { !$0.isEmpty }

    var candidateFiles: [[String: Any]] = []
    var seenPickcodes = Set<String>()

    func appendFiles(_ list: [[String: Any]], fromTargetFolder: Bool = false) {
      for item in list {
        let pc = TvApiClient.stringValue(item["pc"], fallback: TvApiClient.stringValue(item["pick_code"]))
        let fid = TvApiClient.stringValue(item["fid"], fallback: TvApiClient.stringValue(item["file_id"]))
        guard !pc.isEmpty, !fid.isEmpty, seenPickcodes.insert(pc).inserted else { continue }
        var copy = item
        if fromTargetFolder {
          copy["_from_target_folder"] = true
        }
        candidateFiles.append(copy)
      }
    }

    // 1. Priority 0ms lookup: List the designated 115 acceleration folder (`/流光115加速`) directly
    // (bypasses 115's search indexing delay so newly uploaded files are found immediately)
    if !accelCid.isEmpty && accelCid != "0",
       let targetUrl = URL(string: "https://webapi.115.com/files?aid=1&cid=\(accelCid)&o=user_ptime&asc=0&offset=0&limit=45&show_dir=1&format=json"),
       let targetEntries = await fetchFileEntries(from: targetUrl) {
      appendFiles(targetEntries, fromTargetFolder: true)
    }

    // 2. Also list newest files in root (`cid=0`) and `/流光115加速` or `/115open` directory sorted by `user_ptime` desc
    if let rootUrl = URL(string: "https://webapi.115.com/files?aid=1&cid=0&o=user_ptime&asc=0&offset=0&limit=50&show_dir=1&format=json"),
       let rootEntries = await fetchFileEntries(from: rootUrl) {
      appendFiles(rootEntries)
      let targetLower = targetFolderName.lowercased()
      for entry in rootEntries {
        let fid = TvApiClient.stringValue(entry["fid"])
        let cid = TvApiClient.stringValue(entry["cid"])
        let name = TvApiClient.stringValue(entry["n"]).lowercased()
        if fid.isEmpty && !cid.isEmpty && cid != accelCid &&
            (name == targetLower || name == "115open" || name.contains("115") || name.contains("download")) {
          if let subUrl = URL(string: "https://webapi.115.com/files?aid=1&cid=\(cid)&o=user_ptime&asc=0&offset=0&limit=40&show_dir=1&format=json"),
             let subEntries = await fetchFileEntries(from: subUrl) {
            appendFiles(subEntries, fromTargetFolder: name == targetLower)
          }
        }
      }
    }

    // 3. Search by keyword via `webapi.115.com/files/search`
    for kw in keywords.prefix(3) {
      let trimmed = kw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      var comp = URLComponents(string: "https://webapi.115.com/files/search")
      comp?.queryItems = [
        URLQueryItem(name: "aid", value: "1"),
        URLQueryItem(name: "cid", value: "0"),
        URLQueryItem(name: "search_value", value: trimmed),
        URLQueryItem(name: "type", value: "4"),
        URLQueryItem(name: "offset", value: "0"),
        URLQueryItem(name: "limit", value: "25"),
        URLQueryItem(name: "format", value: "json"),
        URLQueryItem(name: "show_dir", value: "1")
      ]
      if let u = comp?.url, let list = await fetchFileEntries(from: u) {
        appendFiles(list)
      }
    }

    guard !candidateFiles.isEmpty else { return nil }

    // 4. Match file by normalized name or newest uploaded timestamp
    var matchedItem: [String: Any]? = nil
    for item in candidateFiles {
      let rawName = TvApiClient.stringValue(item["n"], fallback: TvApiClient.stringValue(item["file_name"]))
      let cleanName = Self.cleanMatchToken(rawName)
      guard !cleanName.isEmpty else { continue }
      if cleanKeywords.contains(where: { kw in
        Self.matchesCleanKeyword(cleanName: cleanName, cleanKw: kw)
      }) {
        matchedItem = item
        break
      }
    }

    // Fallback: if we just waited for an upload after `allowNewestRecentFallbackAfter`, pick the newest video uploaded since then
    if matchedItem == nil, let minDate = allowNewestRecentFallbackAfter {
      let minEpoch = Int64(minDate.timeIntervalSince1970) - 90
      for item in candidateFiles {
        let tp = Int64(TvApiClient.intValue(item["tp"], fallback: TvApiClient.intValue(item["te"], fallback: TvApiClient.intValue(item["tu"], fallback: TvApiClient.intValue(item["t"])))))
        let iv = TvApiClient.intValue(item["iv"], fallback: 0)
        let ico = TvApiClient.stringValue(item["ico"]).lowercased()
        let isVideo = iv == 1 || ["mp4", "f4v", "mkv", "ts", "mov", "flv", "avi", "rmvb", "wmv", "webm"].contains(ico)
        if isVideo && tp >= minEpoch {
          matchedItem = item
          break
        }
      }
      if matchedItem == nil {
        for item in candidateFiles {
          guard (item["_from_target_folder"] as? Bool) == true else { continue }
          let iv = TvApiClient.intValue(item["iv"], fallback: 0)
          let ico = TvApiClient.stringValue(item["ico"]).lowercased()
          let isVideo = iv == 1 || ["mp4", "f4v", "mkv", "ts", "mov", "flv", "avi", "rmvb", "wmv", "webm"].contains(ico)
          if isVideo {
            matchedItem = item
            break
          }
        }
      }
    }

    guard let winner = matchedItem else { return nil }
    let pickcode = TvApiClient.stringValue(winner["pc"], fallback: TvApiClient.stringValue(winner["pick_code"]))
    let fid = TvApiClient.stringValue(winner["fid"], fallback: TvApiClient.stringValue(winner["file_id"]))
    let itemCid = TvApiClient.stringValue(winner["cid"], fallback: TvApiClient.stringValue(winner["parent_id"]))
    let fileName = TvApiClient.stringValue(winner["n"], fallback: TvApiClient.stringValue(winner["file_name"], fallback: "115 视频"))
    let ico = TvApiClient.stringValue(winner["ico"]).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    let nameExt = (fileName as NSString).pathExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    let rawExt = !ico.isEmpty ? ".\(ico)" : (!nameExt.isEmpty ? ".\(nameExt)" : ".mp4")
    let needsHlsTranscode = [".f4v", ".flv", ".mkv", ".avi", ".rmvb", ".wmv", ".ts", ".webm", ".iso"].contains(rawExt)
    guard !pickcode.isEmpty else { return nil }

    // If the file landed in 115 root (`cid == 0`, e.g. via CloudDrive2 FUSE mount),
    // automatically move it into the designated folder (`/流光115加速`)
    if (itemCid.isEmpty || itemCid == "0") && !accelCid.isEmpty && accelCid != "0" && !fid.isEmpty {
      Task {
        await self.move115FileToFolder(fid: fid, targetCid: accelCid)
      }
    }

    var hlsUrl: String? = nil
    if needsHlsTranscode {
      hlsUrl = await resolvePickcodeHlsM3u8Url(pickcode: pickcode)
    }

    var directUrl = await resolvePickcodeStreamUrl(pickcode: pickcode)
    if directUrl == nil && hlsUrl == nil {
      hlsUrl = await resolvePickcodeHlsM3u8Url(pickcode: pickcode)
    }
    if directUrl == nil {
      directUrl = hlsUrl
    }
    guard let validDirectUrl = directUrl, !validDirectUrl.isEmpty else {
      return nil
    }

    let hdrs = streamHeaders(forUrl: validDirectUrl)
    var proxiedHlsUrl: String? = nil
    if let hls = hlsUrl, !hls.isEmpty {
      proxiedHlsUrl = await TvLocalHlsProxyServer.shared.prepareProxyPlaylistUrl(
        gatewayUrl: hls,
        resolvedUrl: hls,
        headers: hdrs
      )
    }

    let proxyUrl: String
    let primaryDirectUrl: String
    if needsHlsTranscode, let phls = proxiedHlsUrl, !phls.isEmpty {
      // Non-MP4 containers (.f4v / .flv / .mkv / .avi / .ts): tvOS AVPlayer MUST play the local-proxied 115 HLS .m3u8 transcode stream!
      proxyUrl = phls
      primaryDirectUrl = phls
    } else if validDirectUrl.lowercased().contains(".m3u8") {
      let phls = await TvLocalHlsProxyServer.shared.prepareProxyPlaylistUrl(
        gatewayUrl: validDirectUrl,
        resolvedUrl: validDirectUrl,
        headers: hdrs
      ) ?? validDirectUrl
      proxyUrl = phls
      primaryDirectUrl = phls
    } else {
      proxyUrl = TvLocalHlsProxyServer.shared.prepareTelegramVideoProxyUrl(
        remoteUrl: validDirectUrl,
        headers: hdrs,
        extHint: rawExt
      )
      primaryDirectUrl = validDirectUrl
    }
    return (proxyStreamUrl: proxyUrl, directCdnUrl: primaryDirectUrl, headers: hdrs, fileName: fileName)
  }

  private func fetchFileEntries(from url: URL) async -> [[String: Any]]? {
    var req = URLRequest(url: url)
    req.timeoutInterval = 12
    for (k, v) in requestHeaders {
      req.setValue(v, forHTTPHeaderField: k)
    }
    guard let (data, _) = try? await session.data(for: req),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let arr = root["data"] as? [[String: Any]] else {
      return nil
    }
    return arr
  }

  /// Resolves a 115 `pickcode` to an official 115 domestic CDN direct URL using:
  /// 1) `proapi.115.com/app/chrome/downurl` (m115 encrypted original MP4 direct CDN link)
  /// 2) `webapi.115.com/files/download?pickcode=...`
  /// 3) `webapi.115.com/files/video?pickcode=...`
  func resolvePickcodeStreamUrl(pickcode: String, forceRefresh: Bool = false) async -> String? {
    let cleanPc = pickcode.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanPc.isEmpty else { return nil }
    if !forceRefresh, let hit = TvM115AuthCookieStore.shared.cachedUrl(forPickcode: cleanPc) {
      return hit
    }

    // 1. Primary: `proapi.115.com/app/chrome/downurl` (Original MP4/WAV/FLAC lossless CDN direct link + `auth_cookie`)
    let nowSec = Int(Date().timeIntervalSince1970)
    if let downEndpoint = URL(string: "https://proapi.115.com/app/chrome/downurl?t=\(nowSec)"),
       let paramData = try? JSONSerialization.data(withJSONObject: ["pickcode": cleanPc]) {
      let key = TvM115Crypto.generateKey()
      let encodedData = TvM115Crypto.encode(input: paramData, key: key)
      var allowed = CharacterSet.alphanumerics
      allowed.insert(charactersIn: "-._~")
      let formEncoded = encodedData.addingPercentEncoding(withAllowedCharacters: allowed) ?? encodedData
      var req = URLRequest(url: downEndpoint)
      req.httpMethod = "POST"
      req.timeoutInterval = 12
      for (k, v) in requestHeaders {
        req.setValue(v, forHTTPHeaderField: k)
      }
      req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      req.httpBody = "data=\(formEncoded)".data(using: .utf8)

      if let (respData, resp) = try? await session.data(for: req),
         let root = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
         let encryptedPayload = root["data"] as? String,
         let decryptedData = TvM115Crypto.decode(input: encryptedPayload, key: key),
         let resultDict = try? JSONSerialization.jsonObject(with: decryptedData) as? [String: Any] {
        var setCookiePair = ""
        if let http = resp as? HTTPURLResponse,
           let sc = http.value(forHTTPHeaderField: "Set-Cookie") ?? http.value(forHTTPHeaderField: "set-cookie"),
           let first = sc.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines),
           first.contains("=") {
          setCookiePair = first
        }
        for (_, val) in resultDict {
          if let info = val as? [String: Any] {
            if let urlObj = info["url"] as? [String: Any] {
              let cdnUrl = TvApiClient.stringValue(urlObj["url"])
              if cdnUrl.hasPrefix("http") {
                var authPair = setCookiePair
                if let ac = urlObj["auth_cookie"] as? [String: Any] {
                  let acName = TvApiClient.stringValue(ac["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
                  let acVal = TvApiClient.stringValue(ac["value"]).trimmingCharacters(in: .whitespacesAndNewlines)
                  if !acName.isEmpty && !acVal.isEmpty {
                    authPair = "\(acName)=\(acVal)"
                  }
                }
                TvM115AuthCookieStore.shared.recordResolved(pickcode: cleanPc, url: cdnUrl, authPair: authPair)
                return cdnUrl
              }
            } else if let cdnUrl = info["url"] as? String, cdnUrl.hasPrefix("http") {
              TvM115AuthCookieStore.shared.recordResolved(pickcode: cleanPc, url: cdnUrl, authPair: setCookiePair)
              return cdnUrl
            }
          }
        }
      }
    }

    // 2. Fallback 1: `webapi.115.com/files/download?pickcode=...`
    if let dlUrl = URL(string: "https://webapi.115.com/files/download?pickcode=\(pickcode)") {
      var req = URLRequest(url: dlUrl)
      req.timeoutInterval = 10
      for (k, v) in requestHeaders {
        req.setValue(v, forHTTPHeaderField: k)
      }
      if let (data, _) = try? await session.data(for: req),
         let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        let fileUrl = TvApiClient.stringValue(root["file_url"])
        if fileUrl.hasPrefix("http") {
          return fileUrl
        }
        if let dataObj = root["data"] as? [String: Any] {
          let nestedUrl = TvApiClient.stringValue(dataObj["file_url"], fallback: TvApiClient.stringValue(dataObj["url"]))
          if nestedUrl.hasPrefix("http") {
            return nestedUrl
          }
        }
      }
    }

    // 3. Fallback 2: `webapi.115.com/files/video?pickcode=...`
    if let hlsUrl = await resolvePickcodeHlsM3u8Url(pickcode: pickcode) {
      return hlsUrl
    }

    return nil
  }

  /// Resolves 115's official cloud transcode HLS `.m3u8` stream URL (`webapi.115.com/files/video?pickcode=...`),
  /// essential for playing non-MP4 containers (`.mkv`, `.avi`, `.rmvb`, `.wmv`, `.flv`, `.ts`) on tvOS `AVPlayer`.
  func resolvePickcodeHlsM3u8Url(pickcode: String) async -> String? {
    guard !pickcode.isEmpty,
          let vidUrl = URL(string: "https://webapi.115.com/files/video?pickcode=\(pickcode)") else {
      return nil
    }
    var req = URLRequest(url: vidUrl)
    req.timeoutInterval = 12
    for (k, v) in requestHeaders {
      req.setValue(v, forHTTPHeaderField: k)
    }
    if let (data, _) = try? await session.data(for: req),
       let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      if let urls = (root["video_urls"] as? [[String: Any]]) ?? (root["video_url"] as? [[String: Any]]),
         !urls.isEmpty {
        let sorted = urls.sorted {
          TvApiClient.intValue($0["definition"], fallback: 0) > TvApiClient.intValue($1["definition"], fallback: 0)
        }
        for candidate in sorted {
          let u = TvApiClient.stringValue(candidate["url"])
          if u.hasPrefix("http") {
            return u
          }
        }
      }
      let directVideoUrl = TvApiClient.stringValue(root["video_url"])
      if directVideoUrl.hasPrefix("http") {
        return directVideoUrl
      }
      if let dataDict = root["data"] as? [String: Any] {
        let nested = TvApiClient.stringValue(dataDict["video_url"], fallback: TvApiClient.stringValue(dataDict["url"]))
        if nested.hasPrefix("http") {
          return nested
        }
      }
    }
    return nil
  }

  /// Resolves a full-resolution original image URL for a 115 image file via `webapi.115.com/files/image?pickcode=...`,
  /// falling back to `resolvePickcodeStreamUrl` so Apple TV image preview always displays crystal-clear 4K/original images instead of 100x100 icons.
  func resolvePickcodeImageUrl(pickcode: String) async -> String? {
    guard !pickcode.isEmpty else { return nil }
    if let imgEndpoint = URL(string: "https://webapi.115.com/files/image?pickcode=\(pickcode)") {
      var req = URLRequest(url: imgEndpoint)
      req.timeoutInterval = 12
      for (k, v) in requestHeaders {
        req.setValue(v, forHTTPHeaderField: k)
      }
      if let (data, _) = try? await session.data(for: req),
         let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let dataDict = root["data"] as? [String: Any] {
        for key in ["origin_url", "source_url", "url", "file_url"] {
          let u = TvApiClient.stringValue(dataDict[key])
          if u.hasPrefix("http") {
            return u
          }
        }
      }
    }
    return await resolvePickcodeStreamUrl(pickcode: pickcode)
  }

  func fetch115ImageData(urlStr: String) async -> Data? {
    guard let u = URL(string: urlStr) else { return nil }
    var req = URLRequest(url: u)
    req.timeoutInterval = 18
    for (k, v) in requestHeaders {
      req.setValue(v, forHTTPHeaderField: k)
    }
    if let (data, resp) = try? await session.data(for: req),
       let http = resp as? HTTPURLResponse,
       (200..<300).contains(http.statusCode),
       !data.isEmpty {
      return data
    }
    return nil
  }

  private static func cleanMatchToken(_ raw: String) -> String {
    var s = (raw as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    if let regex = try? NSRegularExpression(pattern: "^tg_\\d+_") {
      let range = NSRange(s.startIndex..<s.endIndex, in: s)
      s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }
    for _ in 0..<3 {
      var stripped = false
      for ext in [".mp4", ".f4v", ".ts", ".mkv", ".mov", ".flv", ".avi", ".rmvb", ".wmv", ".webm", ".m3u8"] {
        if s.lowercased().hasSuffix(ext) {
          s = String(s.dropLast(ext.count))
          stripped = true
        }
      }
      if !stripped { break }
    }
    if let puncRegex = try? NSRegularExpression(pattern: #"[《》【】\[\]\(\)（）\-—_·:\s]+"#) {
      let range = NSRange(s.startIndex..<s.endIndex, in: s)
      s = puncRegex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }
    return s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func matchesCleanKeyword(cleanName: String, cleanKw: String) -> Bool {
    guard !cleanName.isEmpty, !cleanKw.isEmpty else { return false }
    if cleanName == cleanKw || cleanName.contains(cleanKw) || cleanKw.contains(cleanName) {
      return true
    }
    func normEpisodeNum(_ input: String) -> String {
      guard let rx = try? NSRegularExpression(pattern: #"第0*(\d+)[集话期]?"#) else { return input }
      let range = NSRange(input.startIndex..<input.endIndex, in: input)
      return rx.stringByReplacingMatches(in: input, range: range, withTemplate: "$1")
    }
    let n1 = normEpisodeNum(cleanName)
    let n2 = normEpisodeNum(cleanKw)
    if n1 == n2 || n1.contains(n2) || n2.contains(n1) {
      return true
    }
    if let seasonRx = try? NSRegularExpression(pattern: #"第[一二三四五六七八九十\d]+季"#) {
      let s1 = seasonRx.stringByReplacingMatches(in: n1, range: NSRange(n1.startIndex..<n1.endIndex, in: n1), withTemplate: "")
      let s2 = seasonRx.stringByReplacingMatches(in: n2, range: NSRange(n2.startIndex..<n2.endIndex, in: n2), withTemplate: "")
      if s1.count >= 2 && s2.count >= 2 && (s1 == s2 || s1.contains(s2) || s2.contains(s1)) {
        return true
      }
    }
    return false
  }

  // MARK: - 115 Cloud Drive File Manager Directory Browser & File Operations

  private var cidParentMap: [String: String] = ["0": ""]
  private var cidNameMap: [String: String] = ["0": "115根目录"]

  func registerFolder(cid: String, parentCid: String, name: String) {
    guard !cid.isEmpty else { return }
    cidParentMap[cid] = parentCid
    if !name.isEmpty {
      cidNameMap[cid] = name
    }
  }

  func parentCid(for cid: String) -> String {
    if cid.isEmpty || cid == "0" || cid == "/" { return "" }
    return cidParentMap[cid] ?? "0"
  }

  func list115Directory(
    cid: String,
    mountId: String = "builtin_115",
    page: Int = 1,
    perPage: Int = 100
  ) async throws -> TvFileListing {
    guard hasLocalCookie else {
      throw NSError(domain: "TvLocal115", code: 401, userInfo: [NSLocalizedDescriptionKey: "请先扫码或输入 Cookie 登录 115 网盘账号"])
    }
    let cleanCid = (cid.isEmpty || cid == "/") ? "0" : cid
    let safeLimit = max(20, min(115, perPage))
    let offset = max(0, (page - 1) * safeLimit)
    let candidateUrls: [String] = [
      "https://webapi.115.com/files?aid=1&cid=\(cleanCid)&o=user_ptime&asc=0&offset=\(offset)&limit=\(safeLimit)&show_dir=1&format=json",
      "https://aps.115.com/natsort/files.php?aid=1&cid=\(cleanCid)&o=file_name&asc=1&offset=\(offset)&limit=\(safeLimit)&show_dir=1&natsort=1&format=json",
      "https://webapi.115.com/files?aid=1&cid=\(cleanCid)&o=user_ptime&asc=0&offset=\(offset)&limit=40&show_dir=1&format=json",
      "https://proapi.115.com/android/2.0/ufile/files?aid=1&cid=\(cleanCid)&o=user_ptime&asc=0&offset=\(offset)&limit=\(safeLimit)&show_dir=1"
    ]

    var root: [String: Any] = [:]
    var rawItems: [[String: Any]] = []
    var anyStateOk = false

    for urlStr in candidateUrls {
      guard let listUrl = URL(string: urlStr) else { continue }
      var req = URLRequest(url: listUrl)
      req.timeoutInterval = 15
      for (k, v) in requestHeaders {
        req.setValue(v, forHTTPHeaderField: k)
      }
      if let (data, _) = try? await session.data(for: req),
         let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if root.isEmpty {
          root = dict
        }
        let stateVal = dict["state"]
        let isStateOk = (stateVal as? Bool) == true || TvApiClient.intValue(stateVal, fallback: 0) == 1
        let errNo = TvApiClient.intValue(dict["errNo"], fallback: TvApiClient.intValue(dict["errno"], fallback: TvApiClient.intValue(dict["errCode"], fallback: 0)))
        if isStateOk {
          anyStateOk = true
          root = dict
        }
        if let arr = (dict["data"] as? [Any])?.compactMap({ $0 as? [String: Any] }) {
          if !arr.isEmpty {
            root = dict
            rawItems = arr
            anyStateOk = true
            break
          } else if isStateOk && errNo == 0 {
            // Genuinely empty directory with state == true and errNo == 0
            root = dict
            rawItems = []
            break
          }
        }
      }
    }

    if rawItems.isEmpty && !anyStateOk {
      let errNo = TvApiClient.intValue(root["errNo"], fallback: TvApiClient.intValue(root["errno"], fallback: TvApiClient.intValue(root["errCode"], fallback: 0)))
      let errMsg = TvApiClient.stringValue(root["error"], fallback: TvApiClient.stringValue(root["msg"]))
      if errNo == 99 || errNo == 990001 || errMsg.contains("登录") {
        // Clear expired/kicked cookie so UI immediately shows the 115 QR login button
        self.savedCookie = ""
        throw NSError(
          domain: "TvLocal115",
          code: 401,
          userInfo: [NSLocalizedDescriptionKey: "115 网盘登录已过期或被其他设备/AList顶下线，请点击「立即扫码登录 115 网盘」重新授权"]
        )
      }
      if !errMsg.isEmpty {
        throw NSError(
          domain: "TvLocal115",
          code: errNo != 0 ? errNo : -1,
          userInfo: [NSLocalizedDescriptionKey: "115 接口返回：\(errMsg) (code \(errNo))"]
        )
      }
    }

    // Parse 115 path array if returned (`path: [{name: ..., cid: ...}]`)
    var resolvedParent = parentCid(for: cleanCid)
    if let pathArr = (root["path"] as? [Any])?.compactMap({ $0 as? [String: Any] }), !pathArr.isEmpty {
      var prevCid = ""
      for seg in pathArr {
        let scid = TvApiClient.stringValue(seg["cid"], fallback: "0")
        let sname = TvApiClient.stringValue(seg["name"], fallback: "目录")
        if !prevCid.isEmpty && scid != prevCid {
          cidParentMap[scid] = prevCid
        }
        cidNameMap[scid] = sname
        prevCid = scid
      }
      if pathArr.count >= 2 {
        resolvedParent = TvApiClient.stringValue(pathArr[pathArr.count - 2]["cid"], fallback: "0")
      } else if cleanCid != "0" {
        resolvedParent = "0"
      } else {
        resolvedParent = ""
      }
    }

    var entries: [TvFileEntry] = []
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm"

    for item in rawItems {
      let fid = TvApiClient.stringValue(item["fid"], fallback: TvApiClient.stringValue(item["file_id"])).trimmingCharacters(in: .whitespacesAndNewlines)
      let itemCid = TvApiClient.stringValue(item["cid"], fallback: TvApiClient.stringValue(item["category_id"])).trimmingCharacters(in: .whitespacesAndNewlines)
      let hasValidFid = !fid.isEmpty && fid != "0"
      let fcStr = TvApiClient.stringValue(item["fc"]).trimmingCharacters(in: .whitespacesAndNewlines)
      let isDir: Bool
      if fcStr == "0" {
        isDir = true
      } else if fcStr == "1" {
        isDir = false
      } else {
        isDir = !hasValidFid && !itemCid.isEmpty && itemCid != "0"
      }
      let folderCid = hasValidFid ? fid : itemCid
      if isDir && (folderCid.isEmpty || folderCid == "0" || folderCid == cleanCid) {
        continue
      }
      let name = TvApiClient.stringValue(
        item["n"],
        fallback: TvApiClient.stringValue(
          item["ns"],
          fallback: TvApiClient.stringValue(
            item["fn"],
            fallback: TvApiClient.stringValue(item["file_name"], fallback: "未命名")
          )
        )
      )
      let rawSizeStr = TvApiClient.stringValue(item["s"], fallback: TvApiClient.stringValue(item["fs"], fallback: "0"))
      let size = Int64(rawSizeStr) ?? Int64(TvApiClient.intValue(item["s"], fallback: 0))
      let pickcode = TvApiClient.stringValue(item["pc"], fallback: TvApiClient.stringValue(item["pick_code"])).trimmingCharacters(in: .whitespacesAndNewlines)
      let ico = TvApiClient.stringValue(item["ico"]).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
      let nameExt = (name as NSString).pathExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
      let rawExt = !ico.isEmpty ? ico : nameExt
      let is115Video = TvApiClient.intValue(item["iv"], fallback: 0) == 1 || item["vdi"] != nil
      let ext: String
      if isDir {
        ext = ""
      } else if !rawExt.isEmpty {
        ext = ".\(rawExt)"
      } else if is115Video {
        ext = ".mp4"
      } else {
        ext = ""
      }
      let ts = TvApiClient.intValue(item["te"], fallback: TvApiClient.intValue(item["tp"], fallback: TvApiClient.intValue(item["t"], fallback: 0)))
      let modStr = ts > 100000 ? df.string(from: Date(timeIntervalSince1970: TimeInterval(ts))) : TvApiClient.stringValue(item["te"])
      let thumb = TvApiClient.stringValue(item["u"])
      let entryPath = isDir ? folderCid : (hasValidFid ? fid : pickcode)
      if isDir {
        registerFolder(cid: folderCid, parentCid: cleanCid, name: name)
      }
      entries.append(
        TvFileEntry(
          name: name,
          path: entryPath,
          size: size,
          modTime: modStr,
          isDir: isDir,
          isMp4: ext == ".mp4" || (is115Video && ext.isEmpty),
          ext: ext,
          mountId: mountId,
          sourceKind: .cloud115,
          rawDownloadUrl: "",
          thumbUrl: thumb,
          pickcode115: pickcode,
          fid115: isDir ? folderCid : fid,
          cid115: isDir ? folderCid : cleanCid
        )
      )
    }

    let totalCount = max(entries.count, TvApiClient.intValue(root["count"], fallback: entries.count))
    return TvFileListing(
      path: cleanCid,
      parent: cleanCid == "0" ? "" : resolvedParent,
      root: "0",
      entries: entries,
      totalCount: totalCount,
      currentPage: page
    )
  }

  func create115Folder(parentCid: String, name: String) async throws {
    guard hasLocalCookie,
          let u = URL(string: "https://webapi.115.com/files/add") else { return }
    let pid = (parentCid.isEmpty || parentCid == "/") ? "0" : parentCid
    var req = URLRequest(url: u)
    req.httpMethod = "POST"
    req.timeoutInterval = 12
    for (k, v) in requestHeaders {
      req.setValue(v, forHTTPHeaderField: k)
    }
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
    req.httpBody = "pid=\(pid)&cname=\(encodedName)".data(using: .utf8)
    _ = try await session.data(for: req)
  }

  func rename115File(fid: String, newName: String) async throws {
    guard hasLocalCookie,
          let u = URL(string: "https://webapi.115.com/files/batch_rename") else { return }
    var req = URLRequest(url: u)
    req.httpMethod = "POST"
    req.timeoutInterval = 12
    for (k, v) in requestHeaders {
      req.setValue(v, forHTTPHeaderField: k)
    }
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let encodedName = newName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? newName
    req.httpBody = "files_new_name[\(fid)]=\(encodedName)".data(using: .utf8)
    _ = try await session.data(for: req)
  }

  func delete115File(fid: String, parentCid: String) async throws {
    guard hasLocalCookie,
          let u = URL(string: "https://rb.115.com/2.0/rb/delete") else { return }
    let pid = (parentCid.isEmpty || parentCid == "/") ? "0" : parentCid
    var req = URLRequest(url: u)
    req.httpMethod = "POST"
    req.timeoutInterval = 12
    for (k, v) in requestHeaders {
      req.setValue(v, forHTTPHeaderField: k)
    }
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.httpBody = "pid=\(pid)&fid[0]=\(fid)&ignore_warn=1".data(using: .utf8)
    _ = try await session.data(for: req)
  }

  /// Unwraps any local loopback proxy URL (`http://127.0.0.1:<port>/live.m3u8?gen=...` or `http://127.0.0.1:<port>/tg_video.mp4?u=...`),
  /// server proxy URL (`/api/vod/proxy?url=...&headers=...`), or inline TVBox pipe header (`url|User-Agent=...&Referer=...`)
  /// into its real remote upstream URL and merged HTTP headers so the backend server or 115 offline cloud can download it.
  nonisolated static func unwrapDownloadTargetUrlAndHeaders(
    rawUrl: String,
    baseHeaders: [String: String] = [:],
    hlsUpstreamUrl: String = "",
    hlsUpstreamHeaders: [String: String] = [:]
  ) -> (url: String, headers: [String: String]) {
    var currentUrl = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    var mergedHeaders: [String: String] = [:]
    for (k, v) in baseHeaders {
      let tk = k.trimmingCharacters(in: .whitespacesAndNewlines)
      let tv = v.trimmingCharacters(in: .whitespacesAndNewlines)
      if !tk.isEmpty && !tv.isEmpty {
        mergedHeaders[tk] = tv
      }
    }

    for _ in 0..<4 {
      if currentUrl.isEmpty { break }

      // 1. Split inline TVBox pipe headers (`https://...|User-Agent=...&Referer=...`) and strip `$label`
      let split = TvApiClient.splitUrlAndInlineHeaders(currentUrl)
      currentUrl = split.cleanUrl
      for (k, v) in split.headers where !k.isEmpty && !v.isEmpty {
        mergedHeaders[k] = v
      }

      guard let comp = URLComponents(string: currentUrl) else { break }
      let host = (comp.host ?? "").lowercased()
      let path = comp.path

      // 2. Unwrap Apple TV local loopback proxy (`127.0.0.1` / `localhost`)
      if host == "127.0.0.1" || host == "localhost" {
        if let uParam = comp.queryItems?.first(where: { $0.name == "u" || $0.name == "url" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           uParam.hasPrefix("http://") || uParam.hasPrefix("https://") {
          currentUrl = uParam
          continue
        }
        if path == "/live.m3u8" && !hlsUpstreamUrl.isEmpty {
          currentUrl = hlsUpstreamUrl
          for (k, v) in hlsUpstreamHeaders where !k.isEmpty && !v.isEmpty {
            mergedHeaders[k] = v
          }
          continue
        }
      }

      // 3. Unwrap backend `/api/vod/proxy?url=<url>&headers=<base64url_json>`
      if path.hasSuffix("/api/vod/proxy") {
        let innerU = (comp.queryItems?.first(where: { $0.name == "url" })?.value ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let encH = (comp.queryItems?.first(where: { $0.name == "headers" })?.value ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if !encH.isEmpty {
          var b64 = encH
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
          while b64.count % 4 != 0 {
            b64.append("=")
          }
          if let hData = Data(base64Encoded: b64),
             let hDict = try? JSONSerialization.jsonObject(with: hData) as? [String: Any] {
            for (k, v) in hDict {
              let vs = TvApiClient.stringValue(v).trimmingCharacters(in: .whitespacesAndNewlines)
              if !k.isEmpty && !vs.isEmpty {
                mergedHeaders[k] = vs
              }
            }
          }
        }
        mergedHeaders.removeValue(forKey: "Authorization")
        mergedHeaders.removeValue(forKey: "X-Auth-Secret")
        if innerU.hasPrefix("http://") || innerU.hasPrefix("https://") {
          currentUrl = innerU
          continue
        }
      }

      break
    }

    return (currentUrl, mergedHeaders)
  }

  private func extractUidFromCookie() -> String {
    for part in savedCookie.components(separatedBy: ";") {
      let kv = part.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "=")
      if kv.count >= 2 && kv[0].trimmingCharacters(in: .whitespaces).uppercased() == "UID" {
        let rawVal = kv.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
        return rawVal.components(separatedBy: "_").first ?? ""
      }
    }
    return ""
  }

  /// Submits candidate video URLs to 115's official Cloud Offline Download (`离线下载` `lixian.115.com/lixian/?ct=lixian&ac=add_task_url`)
  /// into `/流光115加速` (`wp_path_id = targetFolderCid`) when the overseas backend server cannot download the stream.
  func try115CloudOfflineLixianFallback(
    candidateUrls: [String],
    searchKeywords: [String],
    pipelineStartedAt: Date,
    onProgressUpdate: @escaping (_ stageTitle: String, _ detailText: String, _ progress: Double) -> Void
  ) async -> (proxyStreamUrl: String, directCdnUrl: String, headers: [String: String], fileName: String)? {
    guard hasLocalCookie else { return nil }
    let uid = extractUidFromCookie()
    guard !uid.isEmpty else { return nil }

    var eligibleUrls: [String] = []
    for raw in candidateUrls {
      let u = Self.unwrapDownloadTargetUrlAndHeaders(rawUrl: raw).url
      guard !u.isEmpty else { continue }
      let lower = u.lowercased()
      if lower.contains("127.0.0.1")
          || lower.contains("localhost")
          || lower.contains("/api/telegram/")
          || lower.contains("/api/vod/proxy")
          || lower.contains(".m3u8") {
        continue
      }
      if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("magnet:") || lower.hasPrefix("ed2k://") {
        if !eligibleUrls.contains(u) {
          eligibleUrls.append(u)
        }
      }
    }
    guard !eligibleUrls.isEmpty else { return nil }

    onProgressUpdate(
      "服务器下载受限 · 正在切换 115 官方云端离线下载...",
      "正在向 115 离线下载中心提交视频直链...",
      0.65
    )

    let accelCid = await ensureAccelerationFolderCid()
    var sign = ""
    var timeStr = String(Int(Date().timeIntervalSince1970))
    if let spaceUrl = URL(string: "https://115.com/?ct=offline&ac=space&_=\(timeStr)") {
      var req = URLRequest(url: spaceUrl)
      req.timeoutInterval = 10
      for (k, v) in requestHeaders { req.setValue(v, forHTTPHeaderField: k) }
      if let (data, _) = try? await session.data(for: req),
         let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        sign = TvApiClient.stringValue(dict["sign"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let t = TvApiClient.stringValue(dict["time"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { timeStr = t }
      }
    }

    var addedInfoHash = ""
    var addedName = ""
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")

    for targetUrl in eligibleUrls {
      guard !Task.isCancelled else { return nil }
      let encUrl = targetUrl.addingPercentEncoding(withAllowedCharacters: allowed) ?? targetUrl
      var formParts = [
        "url=\(encUrl)",
        "uid=\(uid)",
        "time=\(timeStr)"
      ]
      if !accelCid.isEmpty && accelCid != "0" {
        formParts.append("wp_path_id=\(accelCid)")
        formParts.append("savepath=")
      }
      if !sign.isEmpty {
        formParts.append("sign=\(sign)")
      }
      let bodyData = formParts.joined(separator: "&").data(using: .utf8)

      for endpoint in [
        "https://lixian.115.com/lixian/?ct=lixian&ac=add_task_url",
        "https://115.com/web/lixian/?ct=lixian&ac=add_task_url"
      ] {
        guard let u = URL(string: endpoint) else { continue }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        for (k, v) in requestHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        if let (data, _) = try? await session.data(for: req),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
          let stateOk = (dict["state"] as? Bool) == true
            || TvApiClient.intValue(dict["state"]) == 1
            || TvApiClient.intValue(dict["errcode"], fallback: -1) == 0
            || TvApiClient.intValue(dict["errno"], fallback: -1) == 0
          let ih = TvApiClient.stringValue(dict["info_hash"]).trimmingCharacters(in: .whitespacesAndNewlines)
          let nm = TvApiClient.stringValue(dict["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
          if stateOk || !ih.isEmpty {
            addedInfoHash = ih
            addedName = nm
            break
          }
        }
      }
      if !addedInfoHash.isEmpty || !addedName.isEmpty { break }
    }

    guard !addedInfoHash.isEmpty || !addedName.isEmpty else { return nil }

    var mergedKeywords: [String] = []
    if !addedName.isEmpty { mergedKeywords.append(addedName) }
    mergedKeywords.append(contentsOf: searchKeywords)

    for _ in 0..<25 {
      guard !Task.isCancelled else { return nil }
      if let resolved = await findAndResolveDirectPlayUrl(
        keywords: mergedKeywords,
        allowNewestRecentFallbackAfter: pipelineStartedAt
      ) {
        return resolved
      }

      if let listUrl = URL(string: "https://lixian.115.com/lixian/?ct=lixian&ac=task_lists") {
        var req = URLRequest(url: listUrl)
        req.timeoutInterval = 10
        for (k, v) in requestHeaders { req.setValue(v, forHTTPHeaderField: k) }
        if let (data, _) = try? await session.data(for: req),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tasks = dict["tasks"] as? [[String: Any]] {
          if let matched = tasks.first(where: { item in
            let ih = TvApiClient.stringValue(item["info_hash"])
            let nm = TvApiClient.stringValue(item["name"])
            return (!addedInfoHash.isEmpty && ih == addedInfoHash) || (!addedName.isEmpty && nm == addedName)
          }) {
            let status = TvApiClient.intValue(matched["status"], fallback: 0)
            let pct = TvApiClient.doubleValue(matched["percentDone"], fallback: TvApiClient.doubleValue(matched["percent"], fallback: 0))
            let fid = TvApiClient.stringValue(matched["file_id"], fallback: TvApiClient.stringValue(matched["delete_file_id"]))
            let name = TvApiClient.stringValue(matched["name"])
            onProgressUpdate(
              "阶段 2/3 · 115 官方云端正在离线下载该视频...",
              String(format: "115 云端离线进度 %.1f%% · %@", pct, name),
              0.68 + (min(100.0, max(0.0, pct)) / 100.0) * 0.22
            )
            if status == -1 { break }
            if (status == 2 || pct >= 100.0) && !fid.isEmpty && fid != "0" && !accelCid.isEmpty && accelCid != "0" {
              Task {
                await self.move115FileToFolder(fid: fid, targetCid: accelCid)
              }
            }
          }
        }
      }

      try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    return nil
  }
}

// MARK: - Streaming Upload & Download Engine with Real-Time Progress Callbacks

final class TvStreamingHttpTransfer: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
  static let shared = TvStreamingHttpTransfer()

  private final class ActiveContext: @unchecked Sendable {
    let onProgress: @Sendable (Int64, Int64) -> Void
    let logicalTotalBytes: Int64
    var expectedBytes: Int64 = 0
    var receivedBytes: Int64 = 0
    var fileHandle: FileHandle?
    var destFileUrl: URL?
    var responseData = Data()
    var response: URLResponse?
    var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    var lastReportTime: TimeInterval = 0

    init(
      logicalTotalBytes: Int64 = 0,
      destFileUrl: URL? = nil,
      onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) {
      self.logicalTotalBytes = logicalTotalBytes
      self.destFileUrl = destFileUrl
      self.onProgress = onProgress
    }
  }

  private let lock = NSLock()
  private var contexts: [Int: ActiveContext] = [:]
  private var activeTasks: [String: URLSessionTask] = [:]
  private lazy var transferSession: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 60
    cfg.timeoutIntervalForResource = 7200
    return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
  }()

  func cancelTransfer(id: String) {
    lock.lock()
    let task = activeTasks.removeValue(forKey: id)
    lock.unlock()
    task?.cancel()
  }

  func upload(
    transferId: String = UUID().uuidString,
    request: URLRequest,
    data: Data,
    logicalTotalBytes: Int64 = 0,
    onProgress: @escaping @Sendable (Int64, Int64) -> Void
  ) async throws -> (Data, URLResponse) {
    let total = logicalTotalBytes > 0 ? logicalTotalBytes : Int64(data.count)
    return try await withCheckedThrowingContinuation { cont in
      let task = transferSession.uploadTask(with: request, from: data)
      let ctx = ActiveContext(logicalTotalBytes: total, onProgress: onProgress)
      ctx.continuation = cont
      lock.lock()
      contexts[task.taskIdentifier] = ctx
      activeTasks[transferId] = task
      lock.unlock()
      task.resume()
    }
  }

  func downloadToFile(
    transferId: String,
    request: URLRequest,
    destinationUrl: URL,
    expectedSizeHint: Int64 = 0,
    onProgress: @escaping @Sendable (Int64, Int64) -> Void
  ) async throws -> URL {
    let fm = FileManager.default
    let parentDir = destinationUrl.deletingLastPathComponent()
    try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
    if fm.fileExists(atPath: destinationUrl.path) {
      try? fm.removeItem(at: destinationUrl)
    }
    fm.createFile(atPath: destinationUrl.path, contents: nil)
    let handle = try FileHandle(forWritingTo: destinationUrl)

    _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse), Error>) in
      let task = transferSession.dataTask(with: request)
      let ctx = ActiveContext(logicalTotalBytes: expectedSizeHint, destFileUrl: destinationUrl, onProgress: onProgress)
      ctx.fileHandle = handle
      ctx.expectedBytes = expectedSizeHint
      ctx.continuation = cont
      lock.lock()
      contexts[task.taskIdentifier] = ctx
      activeTasks[transferId] = task
      lock.unlock()
      task.resume()
    }
    return destinationUrl
  }

  // URLSession Delegates
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64
  ) {
    lock.lock()
    let ctx = contexts[task.taskIdentifier]
    lock.unlock()
    guard let ctx = ctx else { return }
    let total = ctx.logicalTotalBytes > 0 ? ctx.logicalTotalBytes : max(totalBytesExpectedToSend, totalBytesSent)
    let clampedSent = min(total, totalBytesSent)
    let now = Date().timeIntervalSince1970
    if now - ctx.lastReportTime >= 0.12 || clampedSent >= total {
      ctx.lastReportTime = now
      ctx.onProgress(clampedSent, total)
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    lock.lock()
    let ctx = contexts[dataTask.taskIdentifier]
    lock.unlock()
    if let ctx = ctx {
      ctx.response = response
      if response.expectedContentLength > 0 {
        ctx.expectedBytes = response.expectedContentLength
      }
      if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
        completionHandler(.allow)
        return
      }
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    let ctx = contexts[dataTask.taskIdentifier]
    lock.unlock()
    guard let ctx = ctx else { return }
    if let fh = ctx.fileHandle {
      try? fh.write(contentsOf: data)
      ctx.receivedBytes += Int64(data.count)
      let total = max(ctx.expectedBytes, ctx.logicalTotalBytes)
      let now = Date().timeIntervalSince1970
      if now - ctx.lastReportTime >= 0.12 || (total > 0 && ctx.receivedBytes >= total) {
        ctx.lastReportTime = now
        ctx.onProgress(ctx.receivedBytes, total)
      }
    } else {
      ctx.responseData.append(data)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let ctx = contexts.removeValue(forKey: task.taskIdentifier)
    activeTasks = activeTasks.filter { $0.value.taskIdentifier != task.taskIdentifier }
    lock.unlock()
    guard let ctx = ctx else { return }
    try? ctx.fileHandle?.close()
    if let error = error {
      if let dest = ctx.destFileUrl {
        try? FileManager.default.removeItem(at: dest)
      }
      ctx.continuation?.resume(throwing: error)
      return
    }
    let resp = ctx.response ?? task.response ?? URLResponse()
    if let http = resp as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
      if let dest = ctx.destFileUrl {
        try? FileManager.default.removeItem(at: dest)
      }
      let msg = String(data: ctx.responseData, encoding: .utf8) ?? "HTTP \(http.statusCode)"
      ctx.continuation?.resume(
        throwing: NSError(
          domain: "TvStreamingHttpTransfer",
          code: http.statusCode,
          userInfo: [NSLocalizedDescriptionKey: "传输返回 HTTP \(http.statusCode): \(msg.prefix(120))"]
        )
      )
      return
    }
    if ctx.fileHandle != nil {
      let total = max(ctx.receivedBytes, max(ctx.expectedBytes, ctx.logicalTotalBytes))
      ctx.onProgress(ctx.receivedBytes, total)
    }
    ctx.continuation?.resume(returning: (ctx.responseData, resp))
  }

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

// MARK: - AList / OpenList v3 & Standard WebDAV Remote Storage Client

final class TvRemoteStorageClient: @unchecked Sendable {
  static let shared = TvRemoteStorageClient()

  private let session: URLSession
  private let lock = NSLock()
  private var cachedAlistTokens: [String: String] = [:]

  private init() {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 20
    cfg.timeoutIntervalForResource = 120
    self.session = URLSession(configuration: cfg, delegate: InsecureSessionDelegate(), delegateQueue: nil)
  }

  static func normalizePath(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "/" { return "/" }
    var p = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    while p.count > 1 && p.hasSuffix("/") {
      p.removeLast()
    }
    return p
  }

  static func parentPath(of path: String) -> String {
    let norm = normalizePath(path)
    if norm == "/" { return "" }
    let parent = (norm as NSString).deletingLastPathComponent
    return parent.isEmpty ? "/" : parent
  }

  static func joinPath(_ dir: String, _ name: String) -> String {
    let normDir = normalizePath(dir)
    let cleanName = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if normDir == "/" {
      return "/\(cleanName)"
    }
    return "\(normDir)/\(cleanName)"
  }

  private static func cleanBaseUrl(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
      s = "http://\(s)"
    }
    while s.hasSuffix("/") {
      s.removeLast()
    }
    return s
  }

  // MARK: 1. AList / OpenList v3 Protocol

  private func getCachedAlistToken(_ mountId: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return cachedAlistTokens[mountId]
  }

  private func setCachedAlistToken(_ token: String, for mountId: String) {
    lock.lock()
    defer { lock.unlock() }
    cachedAlistTokens[mountId] = token
  }

  func resolveAlistToken(for mount: TvStorageMount, forceRefresh: Bool = false) async throws -> String {
    let explicitToken = mount.token.trimmingCharacters(in: .whitespacesAndNewlines)
    if !explicitToken.isEmpty && !forceRefresh {
      return explicitToken
    }
    if let cached = getCachedAlistToken(mount.id), !cached.isEmpty, !forceRefresh {
      return cached
    }
    let user = mount.username.trimmingCharacters(in: .whitespacesAndNewlines)
    let pass = mount.password
    if user.isEmpty && pass.isEmpty {
      return "" // Guest access
    }
    let base = Self.cleanBaseUrl(mount.baseUrl)
    guard let loginUrl = URL(string: "\(base)/api/auth/login") else {
      throw NSError(domain: "TvAList", code: -1, userInfo: [NSLocalizedDescriptionKey: "AList 地址格式无效"])
    }
    var req = URLRequest(url: loginUrl)
    req.httpMethod = "POST"
    req.timeoutInterval = 15
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: [
      "username": user,
      "password": pass
    ])
    let (data, _) = try await session.data(for: req)
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw NSError(domain: "TvAList", code: -2, userInfo: [NSLocalizedDescriptionKey: "AList 登录响应解析失败"])
    }
    let code = TvApiClient.intValue(root["code"], fallback: 500)
    if code != 200 {
      let msg = TvApiClient.stringValue(root["message"], fallback: "AList 登录失败 (code \(code))")
      throw NSError(domain: "TvAList", code: code, userInfo: [NSLocalizedDescriptionKey: msg])
    }
    let dataDict = (root["data"] as? [String: Any]) ?? [:]
    let token = TvApiClient.stringValue(dataDict["token"])
    setCachedAlistToken(token, for: mount.id)
    return token
  }

  private func alistJsonRequest(
    mount: TvStorageMount,
    endpointPath: String,
    body: [String: Any]
  ) async throws -> [String: Any] {
    let base = Self.cleanBaseUrl(mount.baseUrl)
    guard let url = URL(string: "\(base)\(endpointPath)") else {
      throw NSError(domain: "TvAList", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 AList 接口地址"])
    }
    let token = try await resolveAlistToken(for: mount)
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = 20
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !token.isEmpty {
      req.setValue(token, forHTTPHeaderField: "Authorization")
    }
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, _) = try await session.data(for: req)
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw NSError(domain: "TvAList", code: -2, userInfo: [NSLocalizedDescriptionKey: "无法解析 AList JSON 响应"])
    }
    let code = TvApiClient.intValue(root["code"], fallback: 200)
    if code == 401 && (!mount.username.isEmpty || !mount.password.isEmpty) {
      let freshToken = try await resolveAlistToken(for: mount, forceRefresh: true)
      var retryReq = req
      retryReq.setValue(freshToken, forHTTPHeaderField: "Authorization")
      let (retryData, _) = try await session.data(for: retryReq)
      if let retryRoot = try? JSONSerialization.jsonObject(with: retryData) as? [String: Any] {
        return retryRoot
      }
    }
    if code != 200 {
      let msg = TvApiClient.stringValue(root["message"], fallback: "AList 请求失败 (\(code))")
      throw NSError(domain: "TvAList", code: code, userInfo: [NSLocalizedDescriptionKey: msg])
    }
    return root
  }

  func listAlistDirectory(
    mount: TvStorageMount,
    path: String,
    page: Int = 1,
    perPage: Int = 250
  ) async throws -> TvFileListing {
    let effectivePath = path.isEmpty ? Self.normalizePath(mount.rootPath) : Self.normalizePath(path)
    let safePage = max(1, page)
    let safePerPage = max(50, min(500, perPage))
    let root = try await alistJsonRequest(
      mount: mount,
      endpointPath: "/api/fs/list",
      body: [
        "path": effectivePath,
        "password": "",
        "page": safePage,
        "per_page": safePerPage,
        "refresh": false
      ]
    )
    let dataDict = (root["data"] as? [String: Any]) ?? [:]
    let rawContent = (dataDict["content"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    let totalRemote = TvApiClient.intValue(dataDict["total"], fallback: rawContent.count)
    let base = Self.cleanBaseUrl(mount.baseUrl)
    var entries: [TvFileEntry] = []
    entries.reserveCapacity(min(rawContent.count, safePerPage))

    for item in rawContent.prefix(safePerPage) {
      let name = TvApiClient.stringValue(item["name"])
      guard !name.isEmpty else { continue }
      let isDir = (item["is_dir"] as? Bool) == true
      let sizeStr = TvApiClient.stringValue(item["size"], fallback: "0")
      let size = Int64(sizeStr) ?? Int64(TvApiClient.intValue(item["size"], fallback: 0))
      let rawMod = TvApiClient.stringValue(item["modified"])
      let modTime = rawMod.count > 16 ? String(rawMod.prefix(16)).replacingOccurrences(of: "T", with: " ") : rawMod
      let sign = TvApiClient.stringValue(item["sign"])
      let thumb = TvApiClient.stringValue(item["thumb"])
      let itemPath = Self.joinPath(effectivePath, name)
      let ext = isDir ? "" : ".\((name as NSString).pathExtension.lowercased())"
      var directDownload = ""
      if !isDir {
        let encodedPath = itemPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? itemPath
        directDownload = sign.isEmpty ? "\(base)/d\(encodedPath)" : "\(base)/d\(encodedPath)?sign=\(sign)"
      }
      entries.append(
        TvFileEntry(
          name: name,
          path: itemPath,
          size: size,
          modTime: modTime,
          isDir: isDir,
          isMp4: ext == ".mp4",
          ext: ext,
          mountId: mount.id,
          sourceKind: .alist,
          rawDownloadUrl: directDownload,
          thumbUrl: thumb
        )
      )
    }

    return TvFileListing(
      path: effectivePath,
      parent: Self.parentPath(of: effectivePath),
      root: Self.normalizePath(mount.rootPath),
      entries: entries,
      totalCount: max(totalRemote, entries.count),
      currentPage: safePage
    )
  }

  func resolveAlistDirectUrl(mount: TvStorageMount, path: String, fallbackUrl: String = "") async throws -> String {
    let info = try await resolveAlistStreamInfo(mount: mount, path: path, fallbackUrl: fallbackUrl)
    return info.url
  }

  /// Resolves an AList file's direct stream URL, required upstream HTTP headers (e.g. `115Browser` User-Agent / Cookie from `data["header"]`),
  /// and AList `/d/<path>?sign=...` server proxy fallback URL.
  func resolveAlistStreamInfo(
    mount: TvStorageMount,
    path: String,
    fallbackUrl: String = ""
  ) async throws -> (url: String, headers: [String: String], alistProxyUrl: String) {
    let root = try await alistJsonRequest(
      mount: mount,
      endpointPath: "/api/fs/get",
      body: [
        "path": Self.normalizePath(path),
        "password": ""
      ]
    )
    let dataDict = (root["data"] as? [String: Any]) ?? [:]
    let rawUrl = TvApiClient.stringValue(dataDict["raw_url"])
    let sign = TvApiClient.stringValue(dataDict["sign"])
    let base = Self.cleanBaseUrl(mount.baseUrl)
    let norm = Self.normalizePath(path)
    let encodedPath = norm.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? norm
    let alistProxyUrl: String = {
      if !sign.isEmpty {
        return "\(base)/d\(encodedPath)?sign=\(sign)"
      }
      if !fallbackUrl.isEmpty {
        return fallbackUrl
      }
      return "\(base)/d\(encodedPath)"
    }()

    var extractedHeaders: [String: String] = [:]
    if let hDict = (dataDict["header"] as? [String: Any]) ?? (dataDict["headers"] as? [String: Any]) {
      for (k, v) in hDict {
        if let arr = v as? [Any], !arr.isEmpty {
          let sep = k.lowercased() == "cookie" ? "; " : ", "
          let sv = arr.map { TvApiClient.stringValue($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: sep)
          if !sv.isEmpty { extractedHeaders[k] = sv }
        } else {
          let sv = TvApiClient.stringValue(v)
          if !sv.isEmpty { extractedHeaders[k] = sv }
        }
      }
    }

    let primaryUrl = rawUrl.hasPrefix("http") ? rawUrl : alistProxyUrl
    if primaryUrl.lowercased().contains("115cdn") || primaryUrl.lowercased().contains("115.com") {
      if extractedHeaders["User-Agent"] == nil && extractedHeaders["user-agent"] == nil {
        extractedHeaders["User-Agent"] = TvLocal115DirectClient.browserUserAgent
      }
    }
    return (url: primaryUrl, headers: extractedHeaders, alistProxyUrl: alistProxyUrl)
  }

  func createAlistFolder(mount: TvStorageMount, parentPath: String, name: String) async throws {
    let fullPath = Self.joinPath(parentPath, name)
    _ = try await alistJsonRequest(
      mount: mount,
      endpointPath: "/api/fs/mkdir",
      body: ["path": fullPath]
    )
  }

  func renameAlistEntry(mount: TvStorageMount, path: String, newName: String) async throws {
    _ = try await alistJsonRequest(
      mount: mount,
      endpointPath: "/api/fs/rename",
      body: [
        "path": Self.normalizePath(path),
        "name": newName
      ]
    )
  }

  func deleteAlistEntries(mount: TvStorageMount, dirPath: String, names: [String]) async throws {
    _ = try await alistJsonRequest(
      mount: mount,
      endpointPath: "/api/fs/remove",
      body: [
        "dir": Self.normalizePath(dirPath),
        "names": names
      ]
    )
  }

  func copyOrMoveAlistEntries(
    mount: TvStorageMount,
    srcDir: String,
    dstDir: String,
    names: [String],
    isMove: Bool
  ) async throws {
    _ = try await alistJsonRequest(
      mount: mount,
      endpointPath: isMove ? "/api/fs/move" : "/api/fs/copy",
      body: [
        "src_dir": Self.normalizePath(srcDir),
        "dst_dir": Self.normalizePath(dstDir),
        "names": names
      ]
    )
  }

  func uploadToAlist(
    transferId: String,
    mount: TvStorageMount,
    targetDir: String,
    fileName: String,
    fileData: Data,
    onProgress: @escaping @Sendable (Int64, Int64) -> Void
  ) async throws {
    let base = Self.cleanBaseUrl(mount.baseUrl)
    guard let putUrl = URL(string: "\(base)/api/fs/put") else {
      throw NSError(domain: "TvAList", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 AList 上传地址"])
    }
    let token = try await resolveAlistToken(for: mount)
    let destPath = Self.joinPath(targetDir, fileName)
    let encodedPath = destPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? destPath

    var req = URLRequest(url: putUrl)
    req.httpMethod = "PUT"
    req.timeoutInterval = 3600
    if !token.isEmpty {
      req.setValue(token, forHTTPHeaderField: "Authorization")
    }
    req.setValue(encodedPath, forHTTPHeaderField: "File-Path")
    req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    req.setValue("\(fileData.count)", forHTTPHeaderField: "Content-Length")

    let (respData, _) = try await TvStreamingHttpTransfer.shared.upload(
      transferId: transferId,
      request: req,
      data: fileData,
      logicalTotalBytes: Int64(fileData.count),
      onProgress: onProgress
    )
    if let root = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] {
      let code = TvApiClient.intValue(root["code"], fallback: 200)
      if code != 200 {
        let msg = TvApiClient.stringValue(root["message"], fallback: "AList 上传失败 (\(code))")
        throw NSError(domain: "TvAList", code: code, userInfo: [NSLocalizedDescriptionKey: msg])
      }
    }
  }

  // MARK: 2. Standard WebDAV Protocol (Compatible with AList WebDAV, Synology, Nextcloud, rclone, CloudDrive2)

  func webdavAuthHeaders(for mount: TvStorageMount) -> [String: String] {
    var headers: [String: String] = [:]
    if !mount.username.isEmpty || !mount.password.isEmpty {
      let raw = "\(mount.username):\(mount.password)"
      let b64 = Data(raw.utf8).base64EncodedString()
      headers["Authorization"] = "Basic \(b64)"
    } else if !mount.token.isEmpty {
      headers["Authorization"] = "Bearer \(mount.token)"
    }
    return headers
  }

  func buildWebdavUrl(mount: TvStorageMount, path: String, isDirectory: Bool = false) -> URL? {
    let base = Self.cleanBaseUrl(mount.baseUrl)
    let norm = Self.normalizePath(path)
    let segments = norm.split(separator: "/").map { seg in
      String(seg).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(seg)
    }
    let joined = segments.isEmpty ? "/" : "/\(segments.joined(separator: "/"))"
    let suffix = (isDirectory && !joined.hasSuffix("/")) ? "\(joined)/" : joined
    return URL(string: "\(base)\(suffix)")
  }

  func listWebdavDirectory(mount: TvStorageMount, path: String) async throws -> TvFileListing {
    let effectivePath = path.isEmpty ? Self.normalizePath(mount.rootPath) : Self.normalizePath(path)
    guard let url = buildWebdavUrl(mount: mount, path: effectivePath, isDirectory: true) else {
      throw NSError(domain: "TvWebDAV", code: -1, userInfo: [NSLocalizedDescriptionKey: "WebDAV 地址格式无效"])
    }
    var req = URLRequest(url: url)
    req.httpMethod = "PROPFIND"
    req.timeoutInterval = 20
    req.setValue("1", forHTTPHeaderField: "Depth")
    req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
    for (k, v) in webdavAuthHeaders(for: mount) {
      req.setValue(v, forHTTPHeaderField: k)
    }
    let (data, resp) = try await session.data(for: req)
    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw NSError(domain: "TvWebDAV", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "WebDAV 连接失败 (HTTP \(http.statusCode))"])
    }
    let xmlStr = String(data: data, encoding: .utf8) ?? ""
    let basePathOnServer = URL(string: Self.cleanBaseUrl(mount.baseUrl))?.path ?? ""
    let entries = Self.parseWebdavPropfindXml(
      xml: xmlStr,
      mount: mount,
      currentPath: effectivePath,
      serverBasePrefix: basePathOnServer
    )
    return TvFileListing(
      path: effectivePath,
      parent: Self.parentPath(of: effectivePath),
      root: Self.normalizePath(mount.rootPath),
      entries: entries
    )
  }

  private static func parseWebdavPropfindXml(
    xml: String,
    mount: TvStorageMount,
    currentPath: String,
    serverBasePrefix: String
  ) -> [TvFileEntry] {
    var entries: [TvFileEntry] = []
    let pattern = "<(?:[a-zA-Z0-9]+:)?response[^>]*>([\\s\\S]*?)</(?:[a-zA-Z0-9]+:)?response>"
    guard let respRegex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return entries
    }
    let nsXml = xml as NSString
    let matches = respRegex.matches(in: xml, range: NSRange(location: 0, length: nsXml.length))
    let normCurrent = normalizePath(currentPath)

    func extractTag(_ block: String, tag: String) -> String {
      let p = "<(?:[a-zA-Z0-9]+:)?\(tag)[^>]*>([\\s\\S]*?)</(?:[a-zA-Z0-9]+:)?\(tag)>"
      guard let rx = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
            let m = rx.firstMatch(in: block, range: NSRange(location: 0, length: (block as NSString).length)),
            m.numberOfRanges >= 2 else {
        return ""
      }
      return (block as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    for m in matches where m.numberOfRanges >= 2 {
      let block = nsXml.substring(with: m.range(at: 1))
      let rawHref = extractTag(block, tag: "href")
      guard !rawHref.isEmpty else { continue }
      let decodedHref: String = {
        if let u = URL(string: rawHref) {
          return u.path.removingPercentEncoding ?? u.path
        }
        return rawHref.removingPercentEncoding ?? rawHref
      }()
      var relativePath = decodedHref
      let cleanPrefix = serverBasePrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      if !cleanPrefix.isEmpty {
        let prefixWithSlash = "/\(cleanPrefix)"
        if relativePath.hasPrefix(prefixWithSlash) {
          relativePath = String(relativePath.dropFirst(prefixWithSlash.count))
        }
      }
      let normHrefPath = normalizePath(relativePath)
      if normHrefPath == normCurrent {
        continue // Skip the current folder itself
      }
      let isDir = block.range(of: "collection", options: .caseInsensitive) != nil || decodedHref.hasSuffix("/")
      let displayName = extractTag(block, tag: "displayname").removingPercentEncoding
        ?? (normHrefPath as NSString).lastPathComponent
      let name = displayName.isEmpty ? (normHrefPath as NSString).lastPathComponent : displayName
      guard !name.isEmpty else { continue }
      let sizeStr = extractTag(block, tag: "getcontentlength")
      let size = Int64(sizeStr) ?? 0
      let modTime = extractTag(block, tag: "getlastmodified")
      let ext = isDir ? "" : ".\((name as NSString).pathExtension.lowercased())"
      let directUrl = TvRemoteStorageClient.shared.buildWebdavUrl(mount: mount, path: normHrefPath, isDirectory: isDir)?.absoluteString ?? ""

      entries.append(
        TvFileEntry(
          name: name,
          path: normHrefPath,
          size: size,
          modTime: modTime,
          isDir: isDir,
          isMp4: ext == ".mp4",
          ext: ext,
          mountId: mount.id,
          sourceKind: .webdav,
          rawDownloadUrl: directUrl
        )
      )
    }
    return entries
  }

  func createWebdavFolder(mount: TvStorageMount, parentPath: String, name: String) async throws {
    let fullPath = Self.joinPath(parentPath, name)
    guard let url = buildWebdavUrl(mount: mount, path: fullPath, isDirectory: true) else { return }
    var req = URLRequest(url: url)
    req.httpMethod = "MKCOL"
    req.timeoutInterval = 15
    for (k, v) in webdavAuthHeaders(for: mount) {
      req.setValue(v, forHTTPHeaderField: k)
    }
    _ = try await session.data(for: req)
  }

  func deleteWebdavEntry(mount: TvStorageMount, path: String, isDir: Bool = false) async throws {
    guard let url = buildWebdavUrl(mount: mount, path: path, isDirectory: isDir) else { return }
    var req = URLRequest(url: url)
    req.httpMethod = "DELETE"
    req.timeoutInterval = 15
    for (k, v) in webdavAuthHeaders(for: mount) {
      req.setValue(v, forHTTPHeaderField: k)
    }
    _ = try await session.data(for: req)
  }

  func moveOrCopyWebdavEntry(
    mount: TvStorageMount,
    srcPath: String,
    dstPath: String,
    isMove: Bool
  ) async throws {
    guard let srcUrl = buildWebdavUrl(mount: mount, path: srcPath),
          let dstUrl = buildWebdavUrl(mount: mount, path: dstPath) else { return }
    var req = URLRequest(url: srcUrl)
    req.httpMethod = isMove ? "MOVE" : "COPY"
    req.timeoutInterval = 20
    req.setValue(dstUrl.absoluteString, forHTTPHeaderField: "Destination")
    req.setValue("T", forHTTPHeaderField: "Overwrite")
    for (k, v) in webdavAuthHeaders(for: mount) {
      req.setValue(v, forHTTPHeaderField: k)
    }
    _ = try await session.data(for: req)
  }

  func uploadToWebdav(
    transferId: String,
    mount: TvStorageMount,
    targetDir: String,
    fileName: String,
    fileData: Data,
    onProgress: @escaping @Sendable (Int64, Int64) -> Void
  ) async throws {
    let destPath = Self.joinPath(targetDir, fileName)
    guard let putUrl = buildWebdavUrl(mount: mount, path: destPath) else {
      throw NSError(domain: "TvWebDAV", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 WebDAV 上传地址"])
    }
    var req = URLRequest(url: putUrl)
    req.httpMethod = "PUT"
    req.timeoutInterval = 3600
    for (k, v) in webdavAuthHeaders(for: mount) {
      req.setValue(v, forHTTPHeaderField: k)
    }
    req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    req.setValue("\(fileData.count)", forHTTPHeaderField: "Content-Length")

    _ = try await TvStreamingHttpTransfer.shared.upload(
      transferId: transferId,
      request: req,
      data: fileData,
      logicalTotalBytes: Int64(fileData.count),
      onProgress: onProgress
    )
  }
}

// MARK: - 3. Pure Swift SMB2 (SMB 2.0.2 / 2.1 + NTLMv2 + SRVSVC + Local HTTP Range Proxy) Client for Apple TV

final class TvSmbClient: @unchecked Sendable {
  static let shared = TvSmbClient()

  private let lock = NSLock()
  private var registeredMounts: [String: TvStorageMount] = [:]
  private var listener: NWListener?
  private(set) var proxyPort: UInt16 = 0
  private let proxyQueue = DispatchQueue(label: "tv.liuguang.smb.proxy", qos: .userInitiated, attributes: .concurrent)

  private init() {
    startProxyServerIfNeeded()
  }

  func registerMount(_ mount: TvStorageMount) {
    guard mount.kind == .smb else { return }
    lock.lock()
    registeredMounts[mount.id] = mount
    lock.unlock()
    startProxyServerIfNeeded()
  }

  func getRegisteredMount(_ id: String) -> TvStorageMount? {
    lock.lock()
    defer { lock.unlock() }
    return registeredMounts[id]
  }

  static func parseSmbTarget(mount: TvStorageMount, requestedPath: String) -> (
    host: String,
    port: UInt16,
    share: String,
    relPath: String,
    virtualPath: String
  ) {
    var rawBase = mount.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
    let lower = rawBase.lowercased()
    if lower.hasPrefix("smb://") {
      rawBase = String(rawBase.dropFirst(6))
    } else if lower.hasPrefix("cifs://") {
      rawBase = String(rawBase.dropFirst(7))
    } else if lower.hasPrefix("http://") {
      rawBase = String(rawBase.dropFirst(7))
    } else if lower.hasPrefix("https://") {
      rawBase = String(rawBase.dropFirst(8))
    }
    while rawBase.hasPrefix("/") {
      rawBase.removeFirst()
    }

    if let atRange = rawBase.range(of: "@") {
      let slashRange = rawBase.range(of: "/")
      if slashRange == nil || atRange.lowerBound < slashRange!.lowerBound {
        rawBase = String(rawBase[atRange.upperBound...])
      }
    }

    var hostPort = rawBase
    var baseSubPath = ""
    if let firstSlash = rawBase.firstIndex(of: "/") {
      hostPort = String(rawBase[..<firstSlash])
      baseSubPath = String(rawBase[rawBase.index(after: firstSlash)...])
    }

    var host = hostPort.trimmingCharacters(in: .whitespacesAndNewlines)
    var port: UInt16 = 445
    if host.hasPrefix("["), let closeBracket = host.firstIndex(of: "]") {
      let ipv6 = String(host[host.index(after: host.startIndex)..<closeBracket])
      let rest = String(host[host.index(after: closeBracket)...])
      if rest.hasPrefix(":"), let p = UInt16(rest.dropFirst()) {
        port = p
      }
      host = ipv6
    } else if let colonIdx = host.lastIndex(of: ":") {
      let pStr = String(host[host.index(after: colonIdx)...])
      if let p = UInt16(pStr), p > 0 {
        port = p
        host = String(host[..<colonIdx])
      }
    }

    let reqTrim = requestedPath.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
    let rootTrim = mount.rootPath.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
    var effectiveVirtual = reqTrim.isEmpty ? rootTrim : reqTrim
    if effectiveVirtual.isEmpty { effectiveVirtual = "/" }
    if !effectiveVirtual.hasPrefix("/") { effectiveVirtual = "/\(effectiveVirtual)" }

    let baseSegments = baseSubPath.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let reqSegments = effectiveVirtual.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

    let allSegments: [String]
    if !baseSegments.isEmpty {
      if reqSegments.isEmpty {
        allSegments = baseSegments
      } else if reqSegments[0].lowercased() == baseSegments[0].lowercased() {
        allSegments = reqSegments
      } else {
        allSegments = baseSegments + reqSegments
      }
    } else {
      allSegments = reqSegments
    }

    let normVirtual = allSegments.isEmpty ? "/" : "/\(allSegments.joined(separator: "/"))"
    guard let share = allSegments.first else {
      return (host, port, "", "", "/")
    }
    let relPath = allSegments.count > 1 ? allSegments.dropFirst().joined(separator: "\\") : ""
    return (host, port, share, relPath, normVirtual)
  }

  func buildLocalStreamUrl(mount: TvStorageMount, virtualPath: String, fileNameHint: String? = nil) async -> String {
    registerMount(mount)
    for _ in 0..<25 {
      lock.lock()
      let p = proxyPort
      lock.unlock()
      if p > 0 { break }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return buildLocalStreamUrlSync(mount: mount, virtualPath: virtualPath, fileNameHint: fileNameHint)
  }

  func buildLocalStreamUrlSync(mount: TvStorageMount, virtualPath: String, fileNameHint: String? = nil) -> String {
    registerMount(mount)
    lock.lock()
    let p = proxyPort
    lock.unlock()
    let normPath = TvRemoteStorageClient.normalizePath(virtualPath)
    let rawName = (fileNameHint?.isEmpty == false)
      ? fileNameHint!
      : ((normPath as NSString).lastPathComponent.isEmpty ? "stream.mp4" : (normPath as NSString).lastPathComponent)
    let encName = rawName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "stream.mp4"
    var comps = URLComponents()
    comps.scheme = "http"
    comps.host = "127.0.0.1"
    comps.port = Int(p > 0 ? p : 18089)
    comps.path = "/smb-stream/\(encName)"
    comps.queryItems = [
      URLQueryItem(name: "mount", value: mount.id),
      URLQueryItem(name: "path", value: normPath)
    ]
    return comps.url?.absoluteString ?? "http://127.0.0.1:\(p)/smb-stream"
  }

  private func startProxyServerIfNeeded() {
    lock.lock()
    if listener != nil && proxyPort > 0 {
      lock.unlock()
      return
    }
    lock.unlock()

    do {
      let params = NWParameters.tcp
      params.allowLocalEndpointReuse = true
      let nwListener = try NWListener(using: params, on: .any)
      nwListener.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        if case .ready = state, let p = nwListener.port?.rawValue, p > 0 {
          self.lock.lock()
          self.proxyPort = p
          self.lock.unlock()
        }
      }
      nwListener.newConnectionHandler = { [weak self] conn in
        self?.handleProxyClient(conn)
      }
      nwListener.start(queue: proxyQueue)
      lock.lock()
      self.listener = nwListener
      lock.unlock()
    } catch {}
  }

  private func handleProxyClient(_ client: NWConnection) {
    client.start(queue: proxyQueue)
    client.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, _, err in
      guard let self, err == nil, let data, !data.isEmpty,
            let reqStr = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
        client.cancel()
        return
      }
      Task {
        await self.processProxyHttpRequest(client: client, requestString: reqStr)
      }
    }
  }

  private func processProxyHttpRequest(client: NWConnection, requestString: String) async {
    let lines = requestString.components(separatedBy: "\r\n")
    guard let firstLine = lines.first else {
      client.cancel()
      return
    }
    let parts = firstLine.split(separator: " ")
    guard parts.count >= 2 else {
      client.cancel()
      return
    }
    let method = parts[0].uppercased()
    let rawUri = String(parts[1])
    guard let comps = URLComponents(string: "http://127.0.0.1\(rawUri)"),
          comps.path.hasPrefix("/smb-stream") else {
      await Self.sendRawHttp(client: client, header: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      client.cancel()
      return
    }

    let mountId = comps.queryItems?.first(where: { $0.name == "mount" })?.value ?? ""
    let filePath = comps.queryItems?.first(where: { $0.name == "path" })?.value ?? ""
    guard let mount = getRegisteredMount(mountId), !filePath.isEmpty else {
      await Self.sendRawHttp(client: client, header: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      client.cancel()
      return
    }

    let target = Self.parseSmbTarget(mount: mount, requestedPath: filePath)
    guard !target.host.isEmpty, !target.share.isEmpty, !target.relPath.isEmpty else {
      await Self.sendRawHttp(client: client, header: "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      client.cancel()
      return
    }

    var rangeHeader: String?
    for line in lines.dropFirst() {
      if line.lowercased().hasPrefix("range:") {
        rangeHeader = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        break
      }
    }

    do {
      let conn = try await TvSmb2Session.connectAndAuthenticate(
        host: target.host,
        port: target.port,
        username: mount.username,
        password: mount.password,
        domainHint: mount.token
      )
      var fileId: Data?
      do {
        try await conn.treeConnect(shareName: target.share)
        let opened = try await conn.openFileForRead(relPath: target.relPath)
        fileId = opened.fileId
        let totalSize = opened.fileSize

        var start: Int64 = 0
        var end: Int64 = totalSize > 0 ? (totalSize - 1) : 0
        var isPartial = false
        if let rh = rangeHeader, rh.lowercased().hasPrefix("bytes="), totalSize > 0 {
          let spec = rh.dropFirst(6).split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
          if let dashIdx = spec.firstIndex(of: "-") {
            let sStr = String(spec[..<dashIdx]).trimmingCharacters(in: .whitespaces)
            let eStr = String(spec[spec.index(after: dashIdx)...]).trimmingCharacters(in: .whitespaces)
            if sStr.isEmpty, let suffix = Int64(eStr) {
              start = max(0, totalSize - suffix)
              end = totalSize - 1
              isPartial = true
            } else if let sVal = Int64(sStr) {
              start = sVal
              if let eVal = Int64(eStr) {
                end = min(totalSize - 1, eVal)
              } else {
                end = totalSize - 1
              }
              isPartial = true
            }
          }
        }

        if totalSize > 0 && (start < 0 || start >= totalSize || start > end) {
          let hdr = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(totalSize)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
          await Self.sendRawHttp(client: client, header: hdr)
          try? await conn.closeFile(fileId: opened.fileId)
          conn.close()
          client.cancel()
          return
        }

        let contentLength: Int64 = totalSize > 0 ? (end - start + 1) : 0
        let statusLine = isPartial ? "HTTP/1.1 206 Partial Content" : "HTTP/1.1 200 OK"
        let mime = Self.guessMimeType(target.relPath)
        var hdr = "\(statusLine)\r\nContent-Type: \(mime)\r\nAccept-Ranges: bytes\r\nContent-Length: \(contentLength)\r\n"
        if isPartial && totalSize > 0 {
          hdr += "Content-Range: bytes \(start)-\(end)/\(totalSize)\r\n"
        }
        hdr += "Connection: close\r\n\r\n"
        let hdrOk = await Self.sendRawHttp(client: client, header: hdr)
        if !hdrOk || method == "HEAD" || contentLength <= 0 {
          try? await conn.closeFile(fileId: opened.fileId)
          conn.close()
          client.cancel()
          return
        }

        var offset = start
        var remaining = contentLength
        let chunkSize = Int64(conn.safeReadChunkSize)
        while remaining > 0 {
          let toRead = Int(min(remaining, chunkSize))
          let chunk = try await conn.readFileChunk(fileId: opened.fileId, offset: UInt64(offset), length: UInt32(toRead))
          if chunk.isEmpty { break }
          TvNetworkSpeedMonitor.shared.recordDownstreamBytes(chunk.count)
          let sentOk = await Self.sendRawData(client: client, data: chunk)
          if !sentOk { break }
          offset += Int64(chunk.count)
          remaining -= Int64(chunk.count)
        }
      } catch {}
      if let fid = fileId {
        try? await conn.closeFile(fileId: fid)
      }
      conn.close()
      client.cancel()
    } catch {
      await Self.sendRawHttp(client: client, header: "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      client.cancel()
    }
  }

  private static func sendRawHttp(client: NWConnection, header: String) async -> Bool {
    await sendRawData(client: client, data: Data(header.utf8))
  }

  private static func sendRawData(client: NWConnection, data: Data) async -> Bool {
    await withCheckedContinuation { cont in
      client.send(content: data, completion: .contentProcessed { err in
        cont.resume(returning: err == nil)
      })
    }
  }

  private static func guessMimeType(_ path: String) -> String {
    let lower = path.lowercased()
    if lower.hasSuffix(".mp4") || lower.hasSuffix(".m4v") { return "video/mp4" }
    if lower.hasSuffix(".mkv") { return "video/x-matroska" }
    if lower.hasSuffix(".mov") { return "video/quicktime" }
    if lower.hasSuffix(".ts") { return "video/mp2t" }
    if lower.hasSuffix(".flv") { return "video/x-flv" }
    if lower.hasSuffix(".avi") { return "video/x-msvideo" }
    if lower.hasSuffix(".mp3") { return "audio/mpeg" }
    if lower.hasSuffix(".flac") { return "audio/flac" }
    if lower.hasSuffix(".wav") { return "audio/wav" }
    if lower.hasSuffix(".m4a") || lower.hasSuffix(".aac") { return "audio/mp4" }
    if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") { return "image/jpeg" }
    if lower.hasSuffix(".png") { return "image/png" }
    return "application/octet-stream"
  }

  // MARK: - Directory Listing & File Operations

  func listSmbDirectory(mount: TvStorageMount, path: String) async throws -> TvFileListing {
    registerMount(mount)
    let target = Self.parseSmbTarget(mount: mount, requestedPath: path)
    guard !target.host.isEmpty else {
      throw NSError(domain: "TvSMB", code: -1, userInfo: [NSLocalizedDescriptionKey: "请输入有效的 SMB 服务器 IP 或主机名"])
    }

    let conn = try await TvSmb2Session.connectAndAuthenticate(
      host: target.host,
      port: target.port,
      username: mount.username,
      password: mount.password,
      domainHint: mount.token
    )
    defer { conn.close() }

    if target.share.isEmpty {
      let shares = try await conn.enumerateShares()
      let entries = shares.map { shareName in
        TvFileEntry(
          name: shareName,
          path: "/\(shareName)",
          size: 0,
          modTime: "SMB 共享目录",
          isDir: true,
          isMp4: false,
          ext: "",
          mountId: mount.id,
          sourceKind: .smb
        )
      }
      return TvFileListing(path: "/", parent: "", root: "/", entries: entries)
    }

    try await conn.treeConnect(shareName: target.share)
    let rawEntries = try await conn.queryDirectory(relPath: target.relPath)
    var entries: [TvFileEntry] = []
    for item in rawEntries {
      if item.name == "." || item.name == ".." { continue }
      let itemVirtual = TvRemoteStorageClient.joinPath(target.virtualPath, item.name)
      let ext = item.isDir ? "" : ((item.name as NSString).pathExtension.isEmpty ? "" : ".\((item.name as NSString).pathExtension.lowercased())")
      let directUrl = item.isDir ? "" : buildLocalStreamUrlSync(mount: mount, virtualPath: itemVirtual, fileNameHint: item.name)
      entries.append(
        TvFileEntry(
          name: item.name,
          path: itemVirtual,
          size: item.size,
          modTime: item.modTime,
          isDir: item.isDir,
          isMp4: ext == ".mp4",
          ext: ext,
          mountId: mount.id,
          sourceKind: .smb,
          rawDownloadUrl: directUrl
        )
      )
    }
    return TvFileListing(
      path: target.virtualPath,
      parent: TvRemoteStorageClient.parentPath(of: target.virtualPath),
      root: TvRemoteStorageClient.normalizePath(mount.rootPath),
      entries: entries
    )
  }

  func createSmbFolder(mount: TvStorageMount, parentPath: String, name: String) async throws {
    let fullVirtual = TvRemoteStorageClient.joinPath(parentPath, name)
    let target = Self.parseSmbTarget(mount: mount, requestedPath: fullVirtual)
    guard !target.share.isEmpty, !target.relPath.isEmpty else {
      throw NSError(domain: "TvSMB", code: -1, userInfo: [NSLocalizedDescriptionKey: "请先进入具体的 SMB 共享目录后再新建文件夹"])
    }
    let conn = try await TvSmb2Session.connectAndAuthenticate(
      host: target.host,
      port: target.port,
      username: mount.username,
      password: mount.password,
      domainHint: mount.token
    )
    defer { conn.close() }
    try await conn.treeConnect(shareName: target.share)
    try await conn.createDirectory(relPath: target.relPath)
  }

  func deleteSmbEntry(mount: TvStorageMount, virtualPath: String, isDir: Bool) async throws {
    let target = Self.parseSmbTarget(mount: mount, requestedPath: virtualPath)
    guard !target.share.isEmpty, !target.relPath.isEmpty else {
      throw NSError(domain: "TvSMB", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法删除 SMB 根共享目录"])
    }
    let conn = try await TvSmb2Session.connectAndAuthenticate(
      host: target.host,
      port: target.port,
      username: mount.username,
      password: mount.password,
      domainHint: mount.token
    )
    defer { conn.close() }
    try await conn.treeConnect(shareName: target.share)
    try await conn.deleteEntryRecursive(relPath: target.relPath, isDir: isDir)
  }

  func moveOrCopySmbEntry(
    mount: TvStorageMount,
    srcVirtualPath: String,
    dstVirtualPath: String,
    isMove: Bool
  ) async throws {
    let srcTarget = Self.parseSmbTarget(mount: mount, requestedPath: srcVirtualPath)
    let dstTarget = Self.parseSmbTarget(mount: mount, requestedPath: dstVirtualPath)
    guard !srcTarget.share.isEmpty, !srcTarget.relPath.isEmpty,
          !dstTarget.share.isEmpty, !dstTarget.relPath.isEmpty else {
      throw NSError(domain: "TvSMB", code: -1, userInfo: [NSLocalizedDescriptionKey: "SMB 路径无效，请确认处于共享目录内"])
    }
    let conn = try await TvSmb2Session.connectAndAuthenticate(
      host: srcTarget.host,
      port: srcTarget.port,
      username: mount.username,
      password: mount.password,
      domainHint: mount.token
    )
    defer { conn.close() }
    try await conn.treeConnect(shareName: srcTarget.share)
    if isMove && srcTarget.share.lowercased() == dstTarget.share.lowercased() {
      try await conn.renameEntry(srcRelPath: srcTarget.relPath, dstRelPath: dstTarget.relPath)
      return
    }
    let openedSrc = try await conn.openFileForRead(relPath: srcTarget.relPath)
    let dstId = try await conn.openFileForWrite(relPath: dstTarget.relPath)
    var offset: Int64 = 0
    let chunkSize = Int64(conn.safeWriteChunkSize)
    while offset < openedSrc.fileSize {
      let toRead = Int(min(chunkSize, openedSrc.fileSize - offset))
      let chunk = try await conn.readFileChunk(fileId: openedSrc.fileId, offset: UInt64(offset), length: UInt32(toRead))
      if chunk.isEmpty { break }
      try await conn.writeFileChunk(fileId: dstId, offset: UInt64(offset), data: chunk)
      offset += Int64(chunk.count)
    }
    try? await conn.closeFile(fileId: openedSrc.fileId)
    try? await conn.closeFile(fileId: dstId)
    if isMove {
      try await conn.deleteEntryRecursive(relPath: srcTarget.relPath, isDir: false)
    }
  }

  func uploadToSmb(
    mount: TvStorageMount,
    targetDir: String,
    fileName: String,
    fileData: Data,
    onProgress: @escaping @Sendable (Int64, Int64) -> Void
  ) async throws {
    let fullVirtual = TvRemoteStorageClient.joinPath(targetDir, fileName)
    let target = Self.parseSmbTarget(mount: mount, requestedPath: fullVirtual)
    guard !target.share.isEmpty, !target.relPath.isEmpty else {
      throw NSError(domain: "TvSMB", code: -1, userInfo: [NSLocalizedDescriptionKey: "请先进入具体的 SMB 共享目录后再上传文件"])
    }
    let conn = try await TvSmb2Session.connectAndAuthenticate(
      host: target.host,
      port: target.port,
      username: mount.username,
      password: mount.password,
      domainHint: mount.token
    )
    defer { conn.close() }
    try await conn.treeConnect(shareName: target.share)
    let fileId = try await conn.openFileForWrite(relPath: target.relPath)
    defer {
      Task { try? await conn.closeFile(fileId: fileId) }
    }
    let totalBytes = Int64(fileData.count)
    let chunkSize = conn.safeWriteChunkSize
    var offset = 0
    while offset < fileData.count {
      let end = min(fileData.count, offset + chunkSize)
      let chunk = fileData.subdata(in: offset..<end)
      try await conn.writeFileChunk(fileId: fileId, offset: UInt64(offset), data: chunk)
      offset = end
      onProgress(Int64(offset), totalBytes)
    }
  }
}

private final class TvSmb2Session: @unchecked Sendable {
  let host: String
  let port: UInt16
  private let conn: NWConnection
  private let queue = DispatchQueue(label: "tv.liuguang.smb2.session", qos: .userInitiated)
  private var rxBuffer = Data()

  private var messageId: UInt64 = 0
  private var sessionId: UInt64 = 0
  private var treeId: UInt32 = 0
  private var serverSecurityMode: UInt16 = 0
  private var maxReadSize: Int = 65536
  private var maxWriteSize: Int = 65536
  private var signingKey: Data?

  var safeReadChunkSize: Int { min(maxReadSize, 65536) }
  var safeWriteChunkSize: Int { min(maxWriteSize, 65536) }

  private init(host: String, port: UInt16, conn: NWConnection) {
    self.host = host
    self.port = port
    self.conn = conn
  }

  static func connectAndAuthenticate(
    host: String,
    port: UInt16,
    username: String,
    password: String,
    domainHint: String
  ) async throws -> TvSmb2Session {
    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
      throw NSError(domain: "TvSMB", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 SMB 端口: \(port)"])
    }
    let nwConn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
    let session = TvSmb2Session(host: host, port: port, conn: nwConn)
    try await session.startConnection()
    do {
      try await session.negotiate()
      try await session.authenticate(rawUsername: username, password: password, domainHint: domainHint)
      return session
    } catch {
      session.close()
      throw error
    }
  }

  private func startConnection() async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      let box = NSLock()
      var resumed = false
      conn.stateUpdateHandler = { state in
        switch state {
        case .ready:
          box.lock()
          if !resumed {
            resumed = true
            box.unlock()
            cont.resume()
          } else {
            box.unlock()
          }
        case .failed(let err):
          box.lock()
          if !resumed {
            resumed = true
            box.unlock()
            cont.resume(throwing: err)
          } else {
            box.unlock()
          }
        case .cancelled:
          box.lock()
          if !resumed {
            resumed = true
            box.unlock()
            cont.resume(throwing: NSError(domain: "TvSMB", code: -1, userInfo: [NSLocalizedDescriptionKey: "SMB 连接已取消"]))
          } else {
            box.unlock()
          }
        default:
          break
        }
      }
      conn.start(queue: queue)
    }
  }

  func close() {
    conn.cancel()
  }

  private func sendAndReceive(
    command: UInt16,
    body: Data,
    flags: UInt32 = 0,
    allowMoreProcessing: Bool = false,
    allowNoMoreFiles: Bool = false
  ) async throws -> Data {
    let msgId = messageId
    messageId &+= 1

    var packet = Data(count: 64 + body.count)
    packet[0] = 0xFE
    packet[1] = 0x53
    packet[2] = 0x4D
    packet[3] = 0x42
    packet.setLE16(at: 4, 64)
    packet.setLE16(at: 6, command == 0 ? 0 : 1)
    packet.setLE32(at: 8, 0)
    packet.setLE16(at: 12, command)
    packet.setLE16(at: 14, 32)
    let shouldSign = signingKey != nil && command != 0 && command != 1 && ((serverSecurityMode & 0x03) != 0)
    let effFlags = shouldSign ? (flags | 0x00000008) : flags
    packet.setLE32(at: 16, effFlags)
    packet.setLE32(at: 20, 0)
    packet.setLE64(at: 24, msgId)
    packet.setLE32(at: 32, 0xFEFF)
    packet.setLE32(at: 36, treeId)
    packet.setLE64(at: 40, sessionId)
    packet.replaceSubrange(64..<(64 + body.count), with: body)

    if shouldSign, let key = signingKey {
      let mac = HMAC<SHA256>.authenticationCode(for: packet, using: SymmetricKey(data: key))
      let sig = Data(mac.prefix(16))
      packet.replaceSubrange(48..<64, with: sig)
    }

    var frame = Data(count: 4 + packet.count)
    let len = packet.count
    frame[0] = 0x00
    frame[1] = UInt8((len >> 16) & 0xFF)
    frame[2] = UInt8((len >> 8) & 0xFF)
    frame[3] = UInt8(len & 0xFF)
    frame.replaceSubrange(4..<(4 + len), with: packet)

    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      conn.send(content: frame, completion: .contentProcessed { err in
        if let err {
          cont.resume(throwing: err)
        } else {
          cont.resume()
        }
      })
    }

    while true {
      let resp = try await readOnePacket()
      guard resp.count >= 64 else {
        throw NSError(domain: "TvSMB", code: -1, userInfo: [NSLocalizedDescriptionKey: "SMB2 响应包长度不足"])
      }
      let status = resp.getLE32(at: 8)
      let respFlags = resp.getLE32(at: 16)
      if status == 0x00000103 && (respFlags & 0x00000002) != 0 {
        continue
      }
      let rSess = resp.getLE64(at: 40)
      if rSess != 0 { sessionId = rSess }
      let rTree = resp.getLE32(at: 36)
      if rTree != 0 && command == 0x0003 { treeId = rTree }

      if status == 0x00000000
          || (allowMoreProcessing && status == 0xC0000016)
          || (allowNoMoreFiles && (status == 0x80000006 || status == 0x00000107)) {
        return resp
      }
      throw NSError(domain: "TvSMB", code: Int(status), userInfo: [NSLocalizedDescriptionKey: Self.formatNtStatus(status, command: command)])
    }
  }

  private func readOnePacket() async throws -> Data {
    while true {
      if rxBuffer.count >= 4 {
        let b1 = Int(rxBuffer[rxBuffer.startIndex + 1])
        let b2 = Int(rxBuffer[rxBuffer.startIndex + 2])
        let b3 = Int(rxBuffer[rxBuffer.startIndex + 3])
        let pktLen = (b1 << 16) | (b2 << 8) | b3
        if rxBuffer.count >= 4 + pktLen {
          let start = rxBuffer.startIndex + 4
          let end = start + pktLen
          let pkt = Data(rxBuffer[start..<end])
          rxBuffer.removeSubrange(rxBuffer.startIndex..<end)
          return pkt
        }
      }
      let chunk = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
        conn.receive(minimumIncompleteLength: 1, maximumLength: 131072) { data, _, _, err in
          if let err {
            cont.resume(throwing: err)
          } else if let data, !data.isEmpty {
            cont.resume(returning: data)
          } else {
            cont.resume(throwing: NSError(domain: "TvSMB", code: -1, userInfo: [NSLocalizedDescriptionKey: "SMB 服务器已断开连接"]))
          }
        }
      }
      rxBuffer.append(chunk)
    }
  }

  private func negotiate() async throws {
    var body = Data(count: 40)
    body.setLE16(at: 0, 36)
    body.setLE16(at: 2, 2)
    body.setLE16(at: 4, 0x0001)
    for i in 0..<16 {
      body[12 + i] = UInt8((i * 19 + 0x37) & 0xFF)
    }
    body.setLE16(at: 36, 0x0202)
    body.setLE16(at: 38, 0x0210)

    let resp = try await sendAndReceive(command: 0x0000, body: body)
    if resp.count >= 64 + 48 {
      serverSecurityMode = resp.getLE16(at: 64 + 2)
      let maxR = Int(resp.getLE32(at: 64 + 40))
      let maxW = Int(resp.getLE32(at: 64 + 44))
      if maxR >= 4096 { maxReadSize = min(maxR, 65536) }
      if maxW >= 4096 { maxWriteSize = min(maxW, 65536) }
    }
  }

  private func authenticate(rawUsername: String, password: String, domainHint: String) async throws {
    var user = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
    var domain = domainHint.trimmingCharacters(in: .whitespacesAndNewlines)
    if let backIdx = user.firstIndex(of: "\\") {
      if domain.isEmpty { domain = String(user[..<backIdx]) }
      user = String(user[user.index(after: backIdx)...])
    } else if let atIdx = user.firstIndex(of: "@") {
      if domain.isEmpty { domain = String(user[user.index(after: atIdx)...]) }
      user = String(user[..<atIdx])
    }

    do {
      try await performNtlmSessionSetup(user: user, password: password, domain: domain)
    } catch {
      if user.isEmpty && password.isEmpty {
        sessionId = 0
        signingKey = nil
        try await performNtlmSessionSetup(user: "guest", password: "", domain: domain)
        return
      }
      throw error
    }
  }

  private func performNtlmSessionSetup(user: String, password: String, domain: String) async throws {
    let type1 = TvNtlmHelper.buildType1Message()
    let secOut1 = TvNtlmHelper.wrapSpnegoInit(type1)
    let resp1 = try await sendAndReceive(command: 0x0001, body: buildSessionSetupBody(secOut1), allowMoreProcessing: true)
    if resp1.getLE32(at: 8) == 0x00000000 { return }

    let secOff = Int(resp1.getLE16(at: 64 + 4))
    let secLen = Int(resp1.getLE16(at: 64 + 6))
    guard secLen >= 8, secOff + secLen <= resp1.count else {
      throw NSError(domain: "TvSMB", code: -1, userInfo: [NSLocalizedDescriptionKey: "SMB2 NTLM 质询包无效"])
    }
    let serverSec = resp1.subdata(in: secOff..<(secOff + secLen))
    let usedSpnego = !serverSec.isEmpty && serverSec[0] == 0xA1
    let chall = try TvNtlmHelper.extractType2Challenge(serverSec)

    let auth = TvNtlmHelper.buildType3Message(
      username: user,
      password: password,
      domain: domain,
      serverChallenge: chall.serverChallenge,
      targetInfo: chall.targetInfo,
      negotiateFlags: chall.flags
    )
    let secOut3 = usedSpnego ? TvNtlmHelper.wrapSpnegoResp(auth.type3) : auth.type3
    _ = try await sendAndReceive(command: 0x0001, body: buildSessionSetupBody(secOut3))
    if !user.isEmpty && !password.isEmpty {
      signingKey = auth.sessionBaseKey
    }
  }

  private func buildSessionSetupBody(_ secBuf: Data) -> Data {
    var out = Data(count: 24 + secBuf.count)
    out.setLE16(at: 0, 25)
    out[2] = 0
    out[3] = 0x01
    out.setLE16(at: 12, 64 + 24)
    out.setLE16(at: 14, UInt16(secBuf.count))
    out.replaceSubrange(24..<(24 + secBuf.count), with: secBuf)
    return out
  }

  func treeConnect(shareName: String) async throws {
    let unc = "\\\\\(host)\\\(shareName)"
    let pathBytes = unc.utf16LEData
    var body = Data(count: 8 + pathBytes.count)
    body.setLE16(at: 0, 9)
    body.setLE16(at: 4, 64 + 8)
    body.setLE16(at: 6, UInt16(pathBytes.count))
    body.replaceSubrange(8..<(8 + pathBytes.count), with: pathBytes)
    _ = try await sendAndReceive(command: 0x0003, body: body)
  }

  func enumerateShares() async throws -> [String] {
    try await treeConnect(shareName: "IPC$")
    let pipe = try await createRaw(
      path: "srvsvc",
      desiredAccess: 0x0012019F,
      fileAttributes: 0,
      shareAccess: 0x07,
      createDisposition: 1,
      createOptions: 0
    )
    defer {
      Task { try? await closeFile(fileId: pipe.fileId) }
    }
    let bindPkt = Data([
      0x05, 0x00, 0x0B, 0x03, 0x10, 0x00, 0x00, 0x00,
      0x48, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
      0xB8, 0x10, 0xB8, 0x10, 0x00, 0x00, 0x00, 0x00,
      0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
      0xC8, 0x4F, 0x32, 0x4B, 0x70, 0x16, 0xD3, 0x01,
      0x12, 0x78, 0x5A, 0x47, 0xBF, 0x6E, 0xE1, 0x88,
      0x03, 0x00, 0x00, 0x00,
      0x04, 0x5D, 0x88, 0x8A, 0xEB, 0x1C, 0xC9, 0x11,
      0x9F, 0xE8, 0x08, 0x00, 0x2B, 0x10, 0x48, 0x60,
      0x02, 0x00, 0x00, 0x00
    ])
    try await writeFileChunk(fileId: pipe.fileId, offset: 0, data: bindPkt)
    let bindAck = try await readFileChunk(fileId: pipe.fileId, offset: 0, length: 4096)
    guard bindAck.count >= 24, bindAck[2] == 0x0C else {
      throw NSError(domain: "TvSMB", code: -1, userInfo: [NSLocalizedDescriptionKey: "SMB SRVSVC 共享枚举失败，请直接填写共享目录名（如 /Movies）"])
    }

    let serverUnc = "\\\\\(host)\0"
    let uncBytes = serverUnc.utf16LEData
    let charCount = UInt32(serverUnc.utf16.count)
    var stub = Data()
    func addU32(_ v: UInt32) {
      var le = v.littleEndian
      stub.append(Data(bytes: &le, count: 4))
    }
    addU32(0x00020000)
    addU32(charCount)
    addU32(0)
    addU32(charCount)
    stub.append(uncBytes)
    while (stub.count % 4) != 0 { stub.append(0) }
    addU32(1)
    addU32(1)
    addU32(0x00020004)
    addU32(0)
    addU32(0)
    addU32(0xFFFFFFFF)
    addU32(0x00020008)
    addU32(0)

    var rpcReq = Data(count: 24 + stub.count)
    rpcReq[0] = 5
    rpcReq[1] = 0
    rpcReq[2] = 0
    rpcReq[3] = 0x03
    rpcReq.setLE32(at: 4, 0x10)
    rpcReq.setLE16(at: 8, UInt16(rpcReq.count))
    rpcReq.setLE16(at: 10, 0)
    rpcReq.setLE32(at: 12, 2)
    rpcReq.setLE32(at: 16, UInt32(stub.count))
    rpcReq.setLE16(at: 20, 0)
    rpcReq.setLE16(at: 22, 15)
    rpcReq.replaceSubrange(24..<(24 + stub.count), with: stub)

    try await writeFileChunk(fileId: pipe.fileId, offset: 0, data: rpcReq)
    var rpcStubOut = Data()
    while true {
      let frag = try await readFileChunk(fileId: pipe.fileId, offset: 0, length: 16384)
      guard frag.count >= 24, frag[2] == 0x02 else { break }
      let flags = frag[3]
      let fragLen = min(frag.count, Int(frag.getLE16(at: 8)))
      if fragLen > 24 {
        rpcStubOut.append(frag.subdata(in: 24..<fragLen))
      }
      if (flags & 0x02) != 0 { break }
    }
    return Self.parseNetrShareEnumLevel1(rpcStubOut)
  }

  private static func parseNetrShareEnumLevel1(_ stub: Data) -> [String] {
    guard stub.count >= 24 else { return [] }
    let entriesRead = Int(stub.getLE32(at: 12))
    let arrayPtr = stub.getLE32(at: 16)
    guard entriesRead > 0, arrayPtr != 0, entriesRead <= 2048 else { return [] }
    var pos = 24
    guard pos + entriesRead * 12 <= stub.count else { return [] }

    var headers: [(namePtr: UInt32, type: UInt32, remarkPtr: UInt32)] = []
    for _ in 0..<entriesRead {
      headers.append((stub.getLE32(at: pos), stub.getLE32(at: pos + 4), stub.getLE32(at: pos + 8)))
      pos += 12
    }

    func readNdrString() -> String {
      while (pos % 4) != 0 && pos < stub.count { pos += 1 }
      guard pos + 12 <= stub.count else { return "" }
      let actualCount = Int(stub.getLE32(at: pos + 8))
      pos += 12
      let byteLen = actualCount * 2
      guard byteLen > 0, pos + byteLen <= stub.count else {
        pos = min(stub.count, pos + max(0, byteLen))
        return ""
      }
      let strData = stub.subdata(in: pos..<(pos + byteLen))
      pos += byteLen
      while (pos % 4) != 0 && pos < stub.count { pos += 1 }
      var s = String(data: strData, encoding: .utf16LittleEndian) ?? ""
      if s.hasSuffix("\0") { s.removeLast() }
      return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var shares: [String] = []
    for h in headers {
      let name = h.namePtr != 0 ? readNdrString() : ""
      if h.remarkPtr != 0 { _ = readNdrString() }
      if !name.isEmpty && (h.type & 0x03) == 0 && !name.hasSuffix("$") {
        shares.append(name)
      }
    }
    return shares
  }

  func queryDirectory(relPath: String) async throws -> [(name: String, size: Int64, modTime: String, isDir: Bool)] {
    let cleanRel = relPath.replacingOccurrences(of: "/", with: "\\").trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
    let opened = try await createRaw(
      path: cleanRel,
      desiredAccess: 0x00120089,
      fileAttributes: 0x00000010,
      shareAccess: 0x00000007,
      createDisposition: 1,
      createOptions: 0x00000001
    )
    defer {
      Task { try? await closeFile(fileId: opened.fileId) }
    }
    var entries: [(name: String, size: Int64, modTime: String, isDir: Bool)] = []
    var firstCall = true
    let patternBytes = "*".utf16LEData

    while true {
      var body = Data(count: 32 + patternBytes.count)
      body.setLE16(at: 0, 33)
      body[2] = 0x25
      body[3] = firstCall ? 0x01 : 0x00
      body.replaceSubrange(8..<24, with: opened.fileId)
      body.setLE16(at: 24, 64 + 32)
      body.setLE16(at: 26, UInt16(patternBytes.count))
      body.setLE32(at: 28, 65536)
      body.replaceSubrange(32..<(32 + patternBytes.count), with: patternBytes)
      firstCall = false

      let resp = try await sendAndReceive(command: 0x000E, body: body, allowNoMoreFiles: true)
      if resp.getLE32(at: 8) == 0x80000006 || resp.count < 64 + 8 { break }
      let outOff = Int(resp.getLE16(at: 64 + 2))
      let outLen = Int(resp.getLE32(at: 64 + 4))
      guard outLen > 0, outOff + outLen <= resp.count else { break }

      let dirBuf = resp.subdata(in: outOff..<(outOff + outLen))
      var offset = 0
      while offset + 104 <= dirBuf.count {
        let nextOff = Int(dirBuf.getLE32(at: offset))
        let lastWrite = dirBuf.getLE64(at: offset + 16)
        let eof = Int64(bitPattern: dirBuf.getLE64(at: offset + 40))
        let attr = dirBuf.getLE32(at: offset + 56)
        let nameLen = Int(dirBuf.getLE32(at: offset + 60))
        if nameLen > 0 && offset + 104 + nameLen <= dirBuf.count {
          let nameData = dirBuf.subdata(in: (offset + 104)..<(offset + 104 + nameLen))
          let name = String(data: nameData, encoding: .utf16LittleEndian) ?? ""
          let isDir = (attr & 0x00000010) != 0
          entries.append((name: name, size: max(0, eof), modTime: Self.formatFileTime(lastWrite), isDir: isDir))
        }
        if nextOff == 0 { break }
        offset += nextOff
      }
    }
    return entries
  }

  private static func formatFileTime(_ ft: UInt64) -> String {
    guard ft > 116444736000000000 else { return "" }
    let unixSec = TimeInterval((ft / 10_000_000) - 11644473600)
    let dt = Date(timeIntervalSince1970: unixSec)
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd HH:mm"
    return fmt.string(from: dt)
  }

  func openFileForRead(relPath: String) async throws -> (fileId: Data, fileSize: Int64, isDir: Bool) {
    let cleanRel = relPath.replacingOccurrences(of: "/", with: "\\").trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
    return try await createRaw(
      path: cleanRel,
      desiredAccess: 0x00120089,
      fileAttributes: 0x00000080,
      shareAccess: 0x00000007,
      createDisposition: 1,
      createOptions: 0x00000040
    )
  }

  func openFileForWrite(relPath: String) async throws -> Data {
    let cleanRel = relPath.replacingOccurrences(of: "/", with: "\\").trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
    let res = try await createRaw(
      path: cleanRel,
      desiredAccess: 0x00120196,
      fileAttributes: 0x00000080,
      shareAccess: 0x00000007,
      createDisposition: 5,
      createOptions: 0x00000040
    )
    return res.fileId
  }

  func createDirectory(relPath: String) async throws {
    let cleanRel = relPath.replacingOccurrences(of: "/", with: "\\").trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
    let res = try await createRaw(
      path: cleanRel,
      desiredAccess: 0x00120089,
      fileAttributes: 0x00000010,
      shareAccess: 0x00000007,
      createDisposition: 2,
      createOptions: 0x00000001
    )
    try await closeFile(fileId: res.fileId)
  }

  func deleteEntryRecursive(relPath: String, isDir: Bool) async throws {
    let cleanRel = relPath.replacingOccurrences(of: "/", with: "\\").trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
    if isDir {
      let children = try await queryDirectory(relPath: cleanRel)
      for child in children where child.name != "." && child.name != ".." {
        try await deleteEntryRecursive(relPath: "\(cleanRel)\\\(child.name)", isDir: child.isDir)
      }
    }
    let opened = try await createRaw(
      path: cleanRel,
      desiredAccess: 0x00010080,
      fileAttributes: isDir ? 0x00000010 : 0x00000080,
      shareAccess: 0x00000007,
      createDisposition: 1,
      createOptions: isDir ? 0x00000001 : 0x00000040
    )
    try await setInfo(fileId: opened.fileId, fileInfoClass: 0x0D, infoBuffer: Data([1]))
    try await closeFile(fileId: opened.fileId)
  }

  func renameEntry(srcRelPath: String, dstRelPath: String) async throws {
    let cleanSrc = srcRelPath.replacingOccurrences(of: "/", with: "\\").trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
    let cleanDst = dstRelPath.replacingOccurrences(of: "/", with: "\\").trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
    let opened = try await createRaw(
      path: cleanSrc,
      desiredAccess: 0x00110080,
      fileAttributes: 0,
      shareAccess: 0x00000007,
      createDisposition: 1,
      createOptions: 0
    )
    let dstBytes = cleanDst.utf16LEData
    var infoBuf = Data(count: 20 + dstBytes.count)
    infoBuf[0] = 1
    infoBuf.setLE32(at: 16, UInt32(dstBytes.count))
    infoBuf.replaceSubrange(20..<(20 + dstBytes.count), with: dstBytes)
    try await setInfo(fileId: opened.fileId, fileInfoClass: 0x0A, infoBuffer: infoBuf)
    try await closeFile(fileId: opened.fileId)
  }

  private func setInfo(fileId: Data, fileInfoClass: UInt8, infoBuffer: Data) async throws {
    var body = Data(count: 32 + infoBuffer.count)
    body.setLE16(at: 0, 33)
    body[2] = 0x01
    body[3] = fileInfoClass
    body.setLE32(at: 4, UInt32(infoBuffer.count))
    body.setLE16(at: 8, 64 + 32)
    body.replaceSubrange(16..<32, with: fileId)
    body.replaceSubrange(32..<(32 + infoBuffer.count), with: infoBuffer)
    _ = try await sendAndReceive(command: 0x0011, body: body)
  }

  private func createRaw(
    path: String,
    desiredAccess: UInt32,
    fileAttributes: UInt32,
    shareAccess: UInt32,
    createDisposition: UInt32,
    createOptions: UInt32
  ) async throws -> (fileId: Data, fileSize: Int64, isDir: Bool) {
    let nameBytes = path.isEmpty ? Data() : path.utf16LEData
    let bufBytes = nameBytes.isEmpty ? Data([0]) : nameBytes
    var body = Data(count: 56 + bufBytes.count)
    body.setLE16(at: 0, 57)
    body.setLE32(at: 4, 2)
    body.setLE32(at: 24, desiredAccess)
    body.setLE32(at: 28, fileAttributes)
    body.setLE32(at: 32, shareAccess)
    body.setLE32(at: 36, createDisposition)
    body.setLE32(at: 40, createOptions)
    body.setLE16(at: 44, 64 + 56)
    body.setLE16(at: 46, UInt16(nameBytes.count))
    body.replaceSubrange(56..<(56 + bufBytes.count), with: bufBytes)

    let resp = try await sendAndReceive(command: 0x0005, body: body)
    guard resp.count >= 64 + 80 else {
      throw NSError(domain: "TvSMB", code: -1, userInfo: [NSLocalizedDescriptionKey: "SMB2_CREATE 响应异常"])
    }
    let eof = Int64(bitPattern: resp.getLE64(at: 64 + 48))
    let attr = resp.getLE32(at: 64 + 56)
    let fileId = resp.subdata(in: (64 + 64)..<(64 + 80))
    return (fileId: fileId, fileSize: max(0, eof), isDir: (attr & 0x00000010) != 0)
  }

  func readFileChunk(fileId: Data, offset: UInt64, length: UInt32) async throws -> Data {
    var body = Data(count: 49)
    body.setLE16(at: 0, 49)
    body[2] = 0x50
    body.setLE32(at: 4, length)
    body.setLE64(at: 8, offset)
    body.replaceSubrange(16..<32, with: fileId)

    let resp = try await sendAndReceive(command: 0x0008, body: body, allowNoMoreFiles: true)
    if resp.getLE32(at: 8) == 0x00000107 || resp.count < 64 + 16 {
      return Data()
    }
    let dataOff = Int(resp[64 + 2])
    let dataLen = Int(resp.getLE32(at: 64 + 4))
    guard dataLen > 0, dataOff + dataLen <= resp.count else { return Data() }
    return resp.subdata(in: dataOff..<(dataOff + dataLen))
  }

  func writeFileChunk(fileId: Data, offset: UInt64, data: Data) async throws {
    var body = Data(count: 48 + data.count)
    body.setLE16(at: 0, 49)
    body.setLE16(at: 2, 64 + 48)
    body.setLE32(at: 4, UInt32(data.count))
    body.setLE64(at: 8, offset)
    body.replaceSubrange(16..<32, with: fileId)
    body.replaceSubrange(48..<(48 + data.count), with: data)
    _ = try await sendAndReceive(command: 0x0009, body: body)
  }

  func closeFile(fileId: Data) async throws {
    var body = Data(count: 24)
    body.setLE16(at: 0, 24)
    body.replaceSubrange(8..<24, with: fileId)
    _ = try await sendAndReceive(command: 0x0006, body: body)
  }

  private static func formatNtStatus(_ status: UInt32, command: UInt16) -> String {
    let hex = String(format: "0x%08X", status)
    switch status {
    case 0xC000006D, 0xC000006A, 0xC000006E:
      return "SMB 账号或密码错误 (\(hex))"
    case 0xC0000022:
      return "SMB 权限不足：拒绝访问 (\(hex))"
    case 0xC00000CC:
      return "SMB 共享目录名不存在，请检查共享路径 (\(hex))"
    case 0xC0000034, 0xC000003A:
      return "SMB 指定的文件或目录不存在 (\(hex))"
    default:
      return "SMB 请求失败 (命令 \(command), 状态 \(hex))"
    }
  }
}

private enum TvNtlmHelper {
  static let ntlmSig = Data([0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00])
  static let defaultFlags: UInt32 = 0xA0088215

  static func buildType1Message() -> Data {
    var out = Data(count: 32)
    out.replaceSubrange(0..<8, with: ntlmSig)
    out.setLE32(at: 8, 1)
    out.setLE32(at: 12, defaultFlags)
    return out
  }

  static func extractType2Challenge(_ secBuf: Data) throws -> (serverChallenge: Data, targetInfo: Data, flags: UInt32) {
    guard let range = secBuf.range(of: ntlmSig),
          range.lowerBound + 32 <= secBuf.count else {
      throw NSError(domain: "TvSMB", code: -1, userInfo: [NSLocalizedDescriptionKey: "未找到 NTLMSSP 质询头"])
    }
    let msg = secBuf.subdata(in: range.lowerBound..<secBuf.count)
    let flags = msg.getLE32(at: 20)
    let serverChallenge = msg.subdata(in: 24..<32)
    var targetInfo = Data()
    if msg.count >= 48 {
      let tiLen = Int(msg.getLE16(at: 40))
      let tiOff = Int(msg.getLE32(at: 44))
      if tiLen > 0, tiOff >= 48, tiOff + tiLen <= msg.count {
        targetInfo = msg.subdata(in: tiOff..<(tiOff + tiLen))
      }
    }
    return (serverChallenge, targetInfo, flags)
  }

  static func buildType3Message(
    username: String,
    password: String,
    domain: String,
    serverChallenge: Data,
    targetInfo: Data,
    negotiateFlags: UInt32
  ) -> (type3: Data, sessionBaseKey: Data) {
    let flags = (negotiateFlags & ~UInt32(0x40000000)) | 0x00088205
    let isAnonymous = username.isEmpty && password.isEmpty

    let ntChallengeResp: Data
    let lmChallengeResp: Data
    let sessionBaseKey: Data

    if isAnonymous {
      ntChallengeResp = Data()
      lmChallengeResp = Data([0])
      sessionBaseKey = Data(count: 16)
    } else {
      let ntHash = md4(password.utf16LEData)
      let userDomData = "\(username.uppercased())\(domain)".utf16LEData
      let ntlmv2Key = hmacMd5(key: ntHash, data: userDomData)

      var clientChallenge = Data(count: 8)
      for i in 0..<8 { clientChallenge[i] = UInt8.random(in: 0...255) }

      let unixMs = UInt64(Date().timeIntervalSince1970 * 1000)
      let filetime = (unixMs + 11644473600000) * 10000
      let effTi = targetInfo.isEmpty ? Data([0, 0, 0, 0]) : targetInfo

      var blob = Data(count: 28 + effTi.count + 4)
      blob[0] = 0x01
      blob[1] = 0x01
      blob.setLE64(at: 8, filetime)
      blob.replaceSubrange(16..<24, with: clientChallenge)
      blob.replaceSubrange(28..<(28 + effTi.count), with: effTi)

      var challAndBlob = Data(serverChallenge)
      challAndBlob.append(blob)
      let ntProofStr = hmacMd5(key: ntlmv2Key, data: challAndBlob)

      var ntResp = Data(ntProofStr)
      ntResp.append(blob)
      ntChallengeResp = ntResp

      var challAndClient = Data(serverChallenge)
      challAndClient.append(clientChallenge)
      var lmResp = hmacMd5(key: ntlmv2Key, data: challAndClient)
      lmResp.append(clientChallenge)
      lmChallengeResp = lmResp

      sessionBaseKey = hmacMd5(key: ntlmv2Key, data: ntProofStr)
    }

    let domainBytes = domain.utf16LEData
    let userBytes = username.utf16LEData
    let wsBytes = "APPLETV".utf16LEData

    let headerLen = 64
    let domOff = headerLen
    let userOff = domOff + domainBytes.count
    let wsOff = userOff + userBytes.count
    let lmOff = wsOff + wsBytes.count
    let ntOff = lmOff + lmChallengeResp.count
    let skOff = ntOff + ntChallengeResp.count

    var out = Data(count: skOff)
    out.replaceSubrange(0..<8, with: ntlmSig)
    out.setLE32(at: 8, 3)

    func setSec(_ fieldOff: Int, _ len: Int, _ off: Int) {
      out.setLE16(at: fieldOff, UInt16(len))
      out.setLE16(at: fieldOff + 2, UInt16(len))
      out.setLE32(at: fieldOff + 4, UInt32(off))
    }

    setSec(12, lmChallengeResp.count, lmOff)
    setSec(20, ntChallengeResp.count, ntOff)
    setSec(28, domainBytes.count, domOff)
    setSec(36, userBytes.count, userOff)
    setSec(44, wsBytes.count, wsOff)
    setSec(52, 0, skOff)
    out.setLE32(at: 60, flags)

    out.replaceSubrange(domOff..<userOff, with: domainBytes)
    out.replaceSubrange(userOff..<wsOff, with: userBytes)
    out.replaceSubrange(wsOff..<lmOff, with: wsBytes)
    out.replaceSubrange(lmOff..<ntOff, with: lmChallengeResp)
    out.replaceSubrange(ntOff..<skOff, with: ntChallengeResp)

    return (out, sessionBaseKey)
  }

  private static func asn1Wrap(_ tag: UInt8, _ content: Data) -> Data {
    var out = Data([tag])
    let len = content.count
    if len < 0x80 {
      out.append(UInt8(len))
    } else if len <= 0xFF {
      out.append(contentsOf: [0x81, UInt8(len)])
    } else {
      out.append(contentsOf: [0x82, UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)])
    }
    out.append(content)
    return out
  }

  static func wrapSpnegoInit(_ type1: Data) -> Data {
    let ntlmOid = Data([0x06, 0x0A, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x02, 0x0A])
    let spnegoOid = Data([0x06, 0x06, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x02])
    let mechTypes = asn1Wrap(0xA0, asn1Wrap(0x30, ntlmOid))
    let mechToken = asn1Wrap(0xA2, asn1Wrap(0x04, type1))
    var seqContent = Data(mechTypes)
    seqContent.append(mechToken)
    let negInit = asn1Wrap(0xA0, asn1Wrap(0x30, seqContent))
    var appContent = Data(spnegoOid)
    appContent.append(negInit)
    return asn1Wrap(0x60, appContent)
  }

  static func wrapSpnegoResp(_ type3: Data) -> Data {
    let respTok = asn1Wrap(0xA2, asn1Wrap(0x04, type3))
    return asn1Wrap(0xA1, asn1Wrap(0x30, respTok))
  }

  static func hmacMd5(key: Data, data: Data) -> Data {
    let mac = HMAC<Insecure.MD5>.authenticationCode(for: data, using: SymmetricKey(data: key))
    return Data(mac)
  }

  /// Pure Swift RFC 1320 MD4 implementation
  static func md4(_ input: Data) -> Data {
    let origBitLen = UInt64(input.count * 8)
    let padLen = (56 - ((input.count + 1) % 64) + 64) % 64
    var padded = Data(count: input.count + 1 + padLen + 8)
    padded.replaceSubrange(0..<input.count, with: input)
    padded[input.count] = 0x80
    padded.setLE64(at: padded.count - 8, origBitLen)

    var a: UInt32 = 0x67452301
    var b: UInt32 = 0xEFCDAB89
    var c: UInt32 = 0x98BADCFE
    var d: UInt32 = 0x10325476

    func rotl(_ x: UInt32, _ s: UInt32) -> UInt32 { (x << s) | (x >> (32 - s)) }
    func f(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (~x & z) }
    func g(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (x & z) | (y & z) }
    func h(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x ^ y ^ z }

    var x = [UInt32](repeating: 0, count: 16)
    for offset in stride(from: 0, to: padded.count, by: 64) {
      for i in 0..<16 {
        x[i] = padded.getLE32(at: offset + i * 4)
      }
      let aa = a, bb = b, cc = c, dd = d

      let r1s: [UInt32] = [3, 7, 11, 19]
      for i in 0..<16 {
        let t = a &+ f(b, c, d) &+ x[i]
        a = d; d = c; c = b; b = rotl(t, r1s[i % 4])
      }

      let r2k = [0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15]
      let r2s: [UInt32] = [3, 5, 9, 13]
      for i in 0..<16 {
        let t = a &+ g(b, c, d) &+ x[r2k[i]] &+ 0x5A827999
        a = d; d = c; c = b; b = rotl(t, r2s[i % 4])
      }

      let r3k = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15]
      let r3s: [UInt32] = [3, 9, 11, 15]
      for i in 0..<16 {
        let t = a &+ h(b, c, d) &+ x[r3k[i]] &+ 0x6ED9EBA1
        a = d; d = c; c = b; b = rotl(t, r3s[i % 4])
      }

      a = a &+ aa
      b = b &+ bb
      c = c &+ cc
      d = d &+ dd
    }

    var out = Data(count: 16)
    out.setLE32(at: 0, a)
    out.setLE32(at: 4, b)
    out.setLE32(at: 8, c)
    out.setLE32(at: 12, d)
    return out
  }
}

private extension String {
  var utf16LEData: Data {
    self.data(using: .utf16LittleEndian) ?? Data()
  }
}

private extension Data {
  mutating func setLE16(at offset: Int, _ val: UInt16) {
    self[offset] = UInt8(val & 0xFF)
    self[offset + 1] = UInt8((val >> 8) & 0xFF)
  }

  mutating func setLE32(at offset: Int, _ val: UInt32) {
    self[offset] = UInt8(val & 0xFF)
    self[offset + 1] = UInt8((val >> 8) & 0xFF)
    self[offset + 2] = UInt8((val >> 16) & 0xFF)
    self[offset + 3] = UInt8((val >> 24) & 0xFF)
  }

  mutating func setLE64(at offset: Int, _ val: UInt64) {
    for i in 0..<8 {
      self[offset + i] = UInt8((val >> (i * 8)) & 0xFF)
    }
  }

  func getLE16(at offset: Int) -> UInt16 {
    let i0 = self.startIndex + offset
    return UInt16(self[i0]) | (UInt16(self[i0 + 1]) << 8)
  }

  func getLE32(at offset: Int) -> UInt32 {
    let i0 = self.startIndex + offset
    return UInt32(self[i0])
      | (UInt32(self[i0 + 1]) << 8)
      | (UInt32(self[i0 + 2]) << 16)
      | (UInt32(self[i0 + 3]) << 24)
  }

  func getLE64(at offset: Int) -> UInt64 {
    let i0 = self.startIndex + offset
    var res: UInt64 = 0
    for i in 0..<8 {
      res |= (UInt64(self[i0 + i]) << (i * 8))
    }
    return res
  }
}
