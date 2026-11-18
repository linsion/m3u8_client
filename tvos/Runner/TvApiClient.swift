import CommonCrypto
import CryptoKit
import Foundation
import Network
import Security

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
  private var proxyEnabled: Bool = false
  private var ipCache: [String: (snapshot: TvRealTimeProxyIpSnapshot, timestampMs: Int64)] = [:]

  private init() {
    startListenerIfNeeded()
  }

  func configure(node: TvSubscriptionNode?, enabled: Bool) {
    startListenerIfNeeded()
    let parsed = node.map { Self.parseCredentials(from: $0) }
    lock.lock()
    self.activeNode = node
    self.activeCreds = parsed
    self.proxyEnabled = enabled && (parsed != nil)
    lock.unlock()
    if let h = parsed?.host, !h.isEmpty {
      queue.async {
        _ = Self.resolveRealEntryIpSync(h)
      }
    }
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

  func proxyConnectionDictionary() -> [AnyHashable: Any]? {
    lock.lock()
    let active = proxyEnabled && activeCreds != nil
    let p = Int(port)
    lock.unlock()
    guard active, p > 0 else { return nil }
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
      let creds = self.proxyEnabled ? self.activeCreds : nil
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
    targetHost: String,
    targetPort: Int,
    initialPayload: Data
  ) {
    if Self.isProbeOnlyHost(targetHost) {
      closePair(client: client, upstream: upstream)
    } else {
      closePair(client: client, upstream: upstream, countDecrementOnly: true)
      openDirectBridge(client: client, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
    }
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
        self.fallbackOrClose(client: client, upstream: upstream, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
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
        self.fallbackOrClose(client: client, upstream: upstream, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
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
        self.fallbackOrClose(client: client, upstream: upstream, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
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
        self.fallbackOrClose(client: client, upstream: upstream, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
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
        self.fallbackOrClose(client: client, upstream: upstream, targetHost: targetHost, targetPort: targetPort, initialPayload: initialPayload)
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

  func configureSession(gatewayUrl: String, resolvedUrl: String, headers: [String: String]) -> Int {
    prefetchTask?.cancel()
    prefetchTask = nil
    for (_, t) in inFlight { t.cancel() }
    inFlight.removeAll()
    cache.removeAll()
    cacheOrder.removeAll()
    slidingWindow.removeAll()
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
    self.streamUrl = newUrl
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
  private var baseDts90k: Int64 = -1

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
      } else if pktType == 1, hasAudioConfig, body.count > 2, currentSegmentStartDts >= 0, baseDts90k >= 0 {
        let relDts90k = max(currentSegmentStartDts, dtsMs * 90 - baseDts90k + 90_000)
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
        let rawDts90k = dtsMs * 90
        // Initialize baseDts90k ONLY on the first real video keyframe (sequence headers often have dtsMs=0 while live frames start at 46,000,000+ ms)
        if baseDts90k < 0 {
          guard isKeyframe else { return }
          baseDts90k = rawDts90k
        } else if rawDts90k < baseDts90k {
          baseDts90k = rawDts90k
        }
        let relDts90k = max(0, rawDts90k - baseDts90k) + 90_000
        let relPts90k = max(0, relDts90k + Int64(cts) * 90)

        if currentSegmentStartDts < 0 {
          guard isKeyframe else { return }
          resetSegment(atDts: relDts90k)
        } else {
          let durSec = Double(relDts90k - currentSegmentStartDts) / 90_000.0
          // Emit ~2.0s TS segments even when Douyu/Huya Together-Watch uses 8s–10s GOPs so AVPlayer starts playback in ~1.5s without timing out
          if ((isKeyframe && durSec >= 1.2) || durSec >= 2.0) && !currentSegment.isEmpty {
            onSegmentReady(currentSegment, durSec)
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

  private func launchRequest(url: URL, headers: [String: String]) {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 14
    cfg.timeoutIntervalForResource = 7200
    cfg.httpShouldSetCookies = true
    if let proxyDict = TvLocalProxyTunnelServer.shared.proxyConnectionDictionary() {
      cfg.connectionProxyDictionary = proxyDict
    }
    let sess = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    for (k, v) in headers where !v.isEmpty {
      req.setValue(v, forHTTPHeaderField: k)
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
    self.task = t
    self.session = sess
    lock.unlock()
    oldTask?.cancel()
    oldSess?.invalidateAndCancel()
    t.resume()
  }

  private func scheduleRetryLocked() {
    guard !isStopped, retryCount < 2 else { return }
    retryCount += 1
    let attempt = retryCount
    let useFallback = (attempt >= 2 && fallbackUrl != nil && fallbackUrl != initialUrl)
    guard let nextUrl = useFallback ? fallbackUrl : initialUrl else { return }
    let nextHeaders = useFallback ? fallbackHeaders : initialHeaders
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) { [weak self] in
      guard let self else { return }
      self.launchRequest(url: nextUrl, headers: nextHeaders)
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
    let ua = initialHeaders["User-Agent"] ?? initialHeaders["user-agent"] ?? ""
    lock.unlock()
    if !ua.isEmpty {
      req.setValue(ua, forHTTPHeaderField: "User-Agent")
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
        if self.segments.count > 8 {
          self.segments.removeFirst(self.segments.count - 8)
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
  private let sessionLock = NSLock()
  private let flvLock = NSLock()
  private var activeFlvSession: TvLiveFlvSession? = nil
  private var activeFlvGeneration: Int = 0
  private let tgLock = NSLock()
  private var tgAuthHeaders: [String: String] = [:]
  private var tgHeadersByUrl: [String: [String: String]] = [:]
  private var tgVideoMetaCache: [String: (totalSize: Int64, contentType: String, headerChunk: Data)] = [:]
  private var tgMetaOrder: [String] = []

  private var urlSession: URLSession {
    guard TvLocalProxyTunnelServer.shared.isProxyActive else {
      return directUrlSession
    }
    let curPort = TvLocalProxyTunnelServer.shared.port
    sessionLock.lock()
    defer { sessionLock.unlock() }
    if let existing = cachedProxyUrlSession, cachedProxyPort == curPort {
      return existing
    }
    cachedProxyUrlSession?.finishTasksAndInvalidate()
    let fresh = TvLocalProxyTunnelServer.shared.makeProxiedUrlSession(timeoutRequest: 10, timeoutResource: 22)
    cachedProxyUrlSession = fresh
    cachedProxyPort = curPort
    return fresh
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

  /// Prepares a local 127.0.0.1 resilient chunked MP4 proxy URL (`/tg_video.mp4`) for `/api/telegram/video`, `/api/telegram/file-content`, and 115 CDN direct streams.
  /// Fetches upstream video in bounded 2 MB (`2_097_152` byte) HTTP Range requests with 4x automatic retries and 1-chunk lookahead prefetching,
  /// preventing single-request 100-300 MB HTTP connections from timing out or stalling mid-video on Apple TV.
  func prepareTelegramVideoProxyUrl(remoteUrl: String, headers: [String: String]) -> String {
    startListenerIfNeeded()
    tgLock.lock()
    var cleanHeaders: [String: String] = [:]
    for (k, v) in headers where !v.isEmpty {
      cleanHeaders[k] = v
      if remoteUrl.contains("/api/telegram/") {
        tgAuthHeaders[k] = v
      }
    }
    if !cleanHeaders.isEmpty {
      if tgHeadersByUrl.count > 64 {
        tgHeadersByUrl.removeAll(keepingCapacity: true)
      }
      tgHeadersByUrl[remoteUrl] = cleanHeaders
    }
    tgLock.unlock()
    guard port > 0 else { return remoteUrl }
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=?#")
    let enc = remoteUrl.addingPercentEncoding(withAllowedCharacters: allowed) ?? remoteUrl
    return "http://127.0.0.1:\(port)/tg_video.mp4?u=\(enc)"
  }

  private func getTgHeadersAndMeta(
    for targetUrl: String
  ) -> (headers: [String: String], meta: (totalSize: Int64, contentType: String, headerChunk: Data)?) {
    tgLock.lock()
    defer { tgLock.unlock() }
    let hdrs = tgHeadersByUrl[targetUrl] ?? tgAuthHeaders
    let meta = tgVideoMetaCache[targetUrl]
    return (hdrs, meta)
  }

  private func storeTgMeta(
    _ resolved: (totalSize: Int64, contentType: String, headerChunk: Data),
    for targetUrl: String
  ) {
    tgLock.lock()
    defer { tgLock.unlock() }
    if tgVideoMetaCache[targetUrl] == nil {
      tgMetaOrder.append(targetUrl)
      if tgMetaOrder.count > 24 {
        let old = tgMetaOrder.removeFirst()
        tgVideoMetaCache.removeValue(forKey: old)
      }
    }
    tgVideoMetaCache[targetUrl] = resolved
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

      Task {
        await self.processRequest(method: method, pathAndQuery: pathAndQuery, rangeHeader: rangeHeader, conn: conn)
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
      for _ in 0..<120 {
        if !flvSession.snapshotSegments().isEmpty { break }
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      let segs = flvSession.snapshotSegments()
      guard !segs.isEmpty else {
        sendResponse(conn: conn, status: "502 Bad Gateway", contentType: "text/plain", body: Data(), isHead: method == "HEAD")
        return
      }
      let firstSeq = segs.first?.seq ?? 1
      let maxDur = Int(ceil(segs.map { $0.dur }.max() ?? 10.0)) + 1
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
      let sessionRef = self.urlSession
      let data = await store.fetchOrJoinSegment(url: targetUrl, gen: activeGen) { urlStr, hdrs in
        await Self.downloadSegmentMultiRange(urlStr: urlStr, headers: hdrs, session: sessionRef)
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

    if path == "/tg_video.mp4",
       let targetUrl = comp?.queryItems?.first(where: { $0.name == "u" })?.value,
       !targetUrl.isEmpty {
      await streamTelegramVideoChunked(
        targetUrl: targetUrl,
        method: method,
        rangeHeader: rangeHeader,
        conn: conn
      )
      return
    }

    sendResponse(conn: conn, status: "404 Not Found", contentType: "text/plain", body: Data(), isHead: method == "HEAD")
  }

  /// Streams a remote Telegram video (`/api/telegram/video`) over local loopback in bounded 2 MB (`2_097_152` byte) chunks
  /// with 4x automatic retry per chunk, 256 KB header caching, and 1-chunk lookahead prefetching.
  private func streamTelegramVideoChunked(
    targetUrl: String,
    method: String,
    rangeHeader: String?,
    conn: NWConnection
  ) async {
    guard let u = URL(string: targetUrl) else {
      sendResponse(conn: conn, status: "400 Bad Request", contentType: "text/plain", body: Data(), isHead: method == "HEAD")
      return
    }

    let snapshot = getTgHeadersAndMeta(for: targetUrl)
    let hdrs = snapshot.headers
    var meta = snapshot.meta

    // 1. Probe and cache first 256 KB (`bytes=0-262143`) + total file size so AVPlayer's initial `bytes=0-1` and `moov` probes complete in 0ms
    if meta == nil {
      for attempt in 0..<3 {
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        req.timeoutInterval = attempt == 0 ? 15.0 : 20.0
        for (k, v) in hdrs where !v.isEmpty {
          req.setValue(v, forHTTPHeaderField: k)
        }
        req.setValue("bytes=0-262143", forHTTPHeaderField: "Range")
        if let (d, r) = try? await urlSession.data(for: req),
           let h = r as? HTTPURLResponse,
           (h.statusCode == 206 || h.statusCode == 200),
           !d.isEmpty {
          TvNetworkSpeedMonitor.shared.recordDownstreamBytes(d.count)
          let ct = h.value(forHTTPHeaderField: "Content-Type") ?? "video/mp4"
          var totalSize: Int64 = Int64(d.count)
          if let cr = h.value(forHTTPHeaderField: "Content-Range") ?? h.value(forHTTPHeaderField: "content-range"),
             let slash = cr.lastIndex(of: "/"),
             let parsedTotal = Int64(cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces)),
             parsedTotal > 0 {
            totalSize = parsedTotal
          } else if h.expectedContentLength > Int64(d.count) {
            totalSize = h.expectedContentLength
          }
          let resolved = (totalSize: totalSize, contentType: ct, headerChunk: d)
          storeTgMeta(resolved, for: targetUrl)
          meta = resolved
          break
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
      }
    }

    guard let meta = meta, meta.totalSize > 0 else {
      sendResponse(conn: conn, status: "502 Bad Gateway", contentType: "text/plain", body: Data(), isHead: method == "HEAD")
      return
    }

    var reqStart: Int64 = 0
    var reqEnd: Int64 = meta.totalSize - 1
    var isPartial = false
    if let rStr = rangeHeader, rStr.lowercased().hasPrefix("bytes=") {
      isPartial = true
      let spec = String(rStr.dropFirst(6)).trimmingCharacters(in: .whitespaces)
      let parts = spec.components(separatedBy: "-")
      if parts.count == 2 {
        if let s = Int64(parts[0]), s >= 0, s < meta.totalSize {
          reqStart = s
        }
        if !parts[1].isEmpty, let e = Int64(parts[1]) {
          reqEnd = min(meta.totalSize - 1, e)
        }
      }
    }
    if reqStart > reqEnd {
      sendResponse(conn: conn, status: "416 Range Not Satisfiable", contentType: "text/plain", body: Data(), isHead: true)
      return
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

    // 2. Fast-path: serve small header/moov probes directly from cached 256 KB headerChunk in 0ms
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

    // 3. Stream large playback range in bounded 2 MB (`2_097_152` byte) chunks with 1-chunk lookahead & 4x retry per chunk
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
    // If starting within cached headerChunk, flush the cached prefix immediately so AVPlayer starts decoding at 0ms
    if cursor < Int64(meta.headerChunk.count) {
      let cachedEnd = min(reqEnd, Int64(meta.headerChunk.count) - 1)
      let prefixSlice = meta.headerChunk.subdata(in: Int(cursor)..<(Int(cachedEnd) + 1))
      guard await sendDataAsync(conn: conn, data: prefixSlice) else {
        conn.cancel()
        return
      }
      cursor = cachedEnd + 1
    }

    let chunkSize: Int64 = 2_097_152 // 2 MB per upstream Range request
    var nextPrefetch: Task<Data?, Never>? = nil
    var nextPrefetchRange: (Int64, Int64)? = nil

    while cursor <= reqEnd {
      let cStart = cursor
      let cEnd = min(reqEnd, cStart + chunkSize - 1)

      let currentTask: Task<Data?, Never>
      if let pf = nextPrefetch,
         let pfRange = nextPrefetchRange,
         pfRange.0 == cStart && pfRange.1 == cEnd {
        currentTask = pf
      } else {
        nextPrefetch?.cancel()
        currentTask = Task {
          await self.fetchTelegramRangeChunk(url: u, headers: hdrs, start: cStart, end: cEnd)
        }
      }

      // Pipeline lookahead: start fetching the next 2 MB chunk while sending current chunk to AVPlayer
      let nextStart = cEnd + 1
      if nextStart <= reqEnd {
        let nextEnd = min(reqEnd, nextStart + chunkSize - 1)
        nextPrefetchRange = (nextStart, nextEnd)
        nextPrefetch = Task {
          await self.fetchTelegramRangeChunk(url: u, headers: hdrs, start: nextStart, end: nextEnd)
        }
      } else {
        nextPrefetch = nil
        nextPrefetchRange = nil
      }

      guard let chunkData = await currentTask.value, !chunkData.isEmpty else {
        nextPrefetch?.cancel()
        conn.cancel()
        return
      }

      guard await sendDataAsync(conn: conn, data: chunkData) else {
        nextPrefetch?.cancel()
        conn.cancel()
        return
      }
      cursor += Int64(chunkData.count)
    }

    conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
      conn.cancel()
    })
  }

  private func fetchTelegramRangeChunk(
    url: URL,
    headers: [String: String],
    start: Int64,
    end: Int64
  ) async -> Data? {
    let expected = Int(end - start + 1)
    for attempt in 0..<4 {
      if Task.isCancelled { return nil }
      var req = URLRequest(url: url)
      req.httpMethod = "GET"
      req.timeoutInterval = attempt == 0 ? 16.0 : 22.0
      for (k, v) in headers where !v.isEmpty {
        req.setValue(v, forHTTPHeaderField: k)
      }
      req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
      if let (d, r) = try? await urlSession.data(for: req),
         let h = r as? HTTPURLResponse,
         (h.statusCode == 206 || h.statusCode == 200),
         !d.isEmpty {
        TvNetworkSpeedMonitor.shared.recordDownstreamBytes(d.count)
        if d.count == expected {
          return d
        } else if d.count > expected {
          return d.subdata(in: 0..<expected)
        } else if attempt >= 2 {
          return d
        }
      }
      try? await Task.sleep(nanoseconds: UInt64((attempt + 1) * 250_000_000))
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

  private func fetchAndRewritePlaylist(
    cfg: (gen: Int, gatewayUrl: String, streamUrl: String, headers: [String: String]),
    activeGen: Int
  ) async -> String? {
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

    // If this is a master playlist (#EXT-X-STREAM-INF), follow the first variant media playlist immediately
    if text.contains("#EXT-X-STREAM-INF") {
      let lines = text.components(separatedBy: .newlines)
      if let variantLine = lines.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
         let variantUrl = URL(string: variantLine, relativeTo: finalUrl)?.absoluteURL,
         let childFetch = await fetchRawPlaylist(urlStr: variantUrl.absoluteString, headers: cfg.headers) {
        text = childFetch.text
        finalUrl = childFetch.finalUrl
        await store.updateStreamUrl(finalUrl.absoluteString, forGen: activeGen)
      }
    }

    let lines = text.components(separatedBy: .newlines)
    var headerLines: [String] = ["#EXTM3U", "#EXT-X-VERSION:3"]
    var targetDurationLine = "#EXT-X-TARGETDURATION:10"
    var parsedSegments: [(inf: String, url: String)] = []
    var pendingInf: String? = nil

    for raw in lines {
      let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if t.isEmpty { continue }
      if t.uppercased().hasPrefix("#EXT-X-TARGETDURATION") {
        targetDurationLine = t
      } else if t.uppercased().hasPrefix("#EXT-X-KEY") || t.uppercased().hasPrefix("#EXT-X-MAP") {
        headerLines.append(Self.rewriteAttributeUri(in: t, baseUrl: finalUrl))
      } else if t.uppercased().hasPrefix("#EXTINF") {
        pendingInf = t
      } else if !t.hasPrefix("#") {
        let absSegUrl = URL(string: t, relativeTo: finalUrl)?.absoluteURL.absoluteString ?? t
        parsedSegments.append((inf: pendingInf ?? "#EXTINF:10.0,", url: absSegUrl))
        pendingInf = nil
      }
    }

    let window = await store.mergeSlidingSegments(newSegments: parsedSegments, forGen: activeGen)
    guard !window.isEmpty else { return text }

    let firstSeq = window.first?.seq ?? 1
    headerLines.append(targetDurationLine)
    headerLines.append("#EXT-X-MEDIA-SEQUENCE:\(firstSeq)")

    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=?#")
    let localPort = self.port

    for seg in window {
      headerLines.append(seg.infLine)
      let enc = seg.absoluteUrl.addingPercentEncoding(withAllowedCharacters: allowed) ?? seg.absoluteUrl
      headerLines.append("http://127.0.0.1:\(localPort)/seg.ts?gen=\(activeGen)&u=\(enc)")
    }

    // Sequentially prefetch up to the first 3 segments so 100% of multi-range bandwidth goes to the current segment first
    let urlsToPrefetch = Array(window.prefix(3).map { $0.absoluteUrl })
    let sessionRef = self.urlSession
    let storeRef = self.store
    let pTask = Task {
      for segUrl in urlsToPrefetch {
        if Task.isCancelled { break }
        if await storeRef.cachedData(for: segUrl, gen: activeGen) != nil { continue }
        _ = await storeRef.fetchOrJoinSegment(url: segUrl, gen: activeGen) { u, h in
          await Self.downloadSegmentMultiRange(urlStr: u, headers: h, session: sessionRef)
        }
      }
    }
    await store.setPrefetchTask(pTask, forGen: activeGen)

    return headerLines.joined(separator: "\n") + "\n"
  }

  private func fetchRawPlaylist(urlStr: String, headers: [String: String]) async -> (text: String, finalUrl: URL)? {
    guard let u = URL(string: urlStr) else { return nil }
    var req = URLRequest(url: u)
    req.httpMethod = "GET"
    req.timeoutInterval = 4.0
    for (k, v) in headers where !v.isEmpty {
      req.setValue(v, forHTTPHeaderField: k)
    }
    guard let (data, resp) = try? await urlSession.data(for: req),
          let http = resp as? HTTPURLResponse,
          (200..<300).contains(http.statusCode),
          let finalUrl = resp.url,
          let text = String(data: data, encoding: .utf8),
          text.contains("#EXTM3U") else {
      return nil
    }
    return (text, finalUrl)
  }

  /// Downloads a `.ts` segment using 8 parallel HTTP Range requests (`HTTP 206 Partial Content`) when supported,
  /// multiplying per-connection throttled CDN speeds (110 KB/s -> 650+ KB/s) so 3-4 MB HD segments finish in ~3s.
  private static func downloadSegmentMultiRange(
    urlStr: String,
    headers: [String: String],
    session: URLSession
  ) async -> Data? {
    guard let u = URL(string: urlStr) else { return nil }

    var totalLength = 0
    var supportsRange = false
    do {
      var headReq = URLRequest(url: u)
      headReq.httpMethod = "HEAD"
      headReq.timeoutInterval = 2.5
      for (k, v) in headers where !v.isEmpty {
        headReq.setValue(v, forHTTPHeaderField: k)
      }
      let (_, resp) = try await session.data(for: headReq)
      if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
        totalLength = Int(resp.expectedContentLength)
        let acceptRanges = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? http.value(forHTTPHeaderField: "accept-ranges") ?? "").lowercased()
        supportsRange = acceptRanges.contains("bytes") || totalLength > 300_000
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
              rReq.timeoutInterval = attempt == 0 ? 5.5 : 7.0
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
        return fastData
      }
    }

    // Fallback: standard single-connection GET
    var getReq = URLRequest(url: u)
    getReq.httpMethod = "GET"
    getReq.timeoutInterval = 12
    for (k, v) in headers where !v.isEmpty {
      getReq.setValue(v, forHTTPHeaderField: k)
    }
    if let (d, r) = try? await session.data(for: getReq),
       let h = r as? HTTPURLResponse,
       (200..<300).contains(h.statusCode),
       !d.isEmpty {
      TvNetworkSpeedMonitor.shared.recordDownstreamBytes(d.count)
      return d
    }
    return nil
  }

  private static func rewriteAttributeUri(in line: String, baseUrl: URL) -> String {
    guard let uriRange = line.range(of: "URI=\"") else { return line }
    let afterStart = uriRange.upperBound
    guard let endQuote = line[afterStart...].firstIndex(of: "\"") else { return line }
    let rawUri = String(line[afterStart..<endQuote])
    guard let absUri = URL(string: rawUri, relativeTo: baseUrl)?.absoluteURL.absoluteString else { return line }
    return String(line[..<afterStart]) + absUri + String(line[endQuote...])
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

      var backendProxy = (dict["force_proxy"] as? Bool) == true || forceServerRelay
      if let cfg = dict["player_config"] as? [String: Any], (cfg["backend_proxy_playback"] as? Bool) == true {
        backendProxy = true
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
    guard enableAdFilter,
          streamUrl.lowercased().contains(".m3u8"),
          !streamUrl.contains("/api/vod/proxy"),
          let url = URL(string: streamUrl) else {
      return streamUrl
    }

    do {
      var req = URLRequest(url: url)
      req.timeoutInterval = 5
      for (k, v) in headers {
        req.setValue(v, forHTTPHeaderField: k)
      }
      if req.value(forHTTPHeaderField: "User-Agent") == nil {
        req.setValue(
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
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
        let (bytes, response) = try await noRedirectSession.bytes(for: req)
        bytes.task.cancel()
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
      let defaultUa = (lowerUrl.contains("ottiptv.cc") || lowerUrl.contains("/douyu/") || lowerUrl.contains("/huya/") || lowerUrl.contains("/yy/"))
        ? "okHttp/Mod-1.5.0.0"
        : "okhttp/3.15"
      var h: [String: String] = ["User-Agent": defaultUa]
      if let src = source {
        for (k, v) in src.defaultHeaders where !v.isEmpty { h[k] = v }
      }
      for (k, v) in channel.headers where !v.isEmpty { h[k] = v }
      for (k, v) in inlineHeaders where !v.isEmpty { h[k] = v }
      return h
    }

    var mergedHeaders = buildHeaders(for: split.headers, urlHint: split.cleanUrl)
    var directCleanUrl = split.cleanUrl
    let lowerInitial = directCleanUrl.lowercased()
    let isKnownFlvGateway = lowerInitial.contains("/douyu/")
      || lowerInitial.contains("/huya/")
      || lowerInitial.contains("/yy/")
      || lowerInitial.contains(".flv")

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

    let lowerPath = (URL(string: directCleanUrl)?.path ?? "").lowercased()
    let isAlreadyMediaStream = isKnownFlvGateway
      || lowerPath.hasSuffix(".m3u8")
      || lowerPath.hasSuffix(".ts")
      || lowerPath.hasSuffix(".flv")
      || lowerPath.contains(".m3u8/")
      || lowerPath.contains("/pltv/")
      || directCleanUrl.contains("://[")

    // If it's a non-media gateway URL (e.g. .php?id=...) or forceServerRelay is requested for non-FLV streams, check /api/tvbox/live/play
    if !isKnownFlvGateway && (!isAlreadyMediaStream || forceServerRelay), let src = source, !src.isCustom {
      let query = [
        URLQueryItem(name: "tvbox_source", value: String(src.sourceIndex)),
        URLQueryItem(name: "tvbox_live", value: String(src.liveIndex)),
        URLQueryItem(name: "url", value: split.cleanUrl),
      ]
      if let endpoint = makeEndpointUrl("/api/tvbox/live/play", queryItems: query),
         let dict = try? await requestJson(url: endpoint, timeout: 6) as? [String: Any] {
        let resolvedDirect = Self.stringValue(dict["direct_url"], fallback: Self.stringValue(dict["url"]))
        if !resolvedDirect.isEmpty {
          let s2 = Self.splitUrlAndInlineHeaders(resolvedDirect)
          if !s2.cleanUrl.isEmpty { directCleanUrl = s2.cleanUrl }
          for (k, v) in s2.headers where !v.isEmpty { mergedHeaders[k] = v }
        }
        if let hMap = (dict["headers"] as? [String: Any]) ?? (dict["header"] as? [String: Any]) {
          for (k, v) in hMap {
            let sv = Self.stringValue(v)
            if !sv.isEmpty { mergedHeaders[k] = sv }
          }
        }
      }
    }

    let proxyUrl = buildServerProxyUrl(targetUrl: split.cleanUrl, headers: mergedHeaders)
    let isFlvStream = isKnownFlvGateway || directCleanUrl.lowercased().contains(".flv")

    if isFlvStream {
      let preferDirectFlv = !forceServerRelay
      let flvTarget = preferDirectFlv ? split.cleanUrl : proxyUrl
      let flvHeaders = preferDirectFlv ? mergedHeaders : authHeaders
      let flvFallback = preferDirectFlv ? proxyUrl : split.cleanUrl
      let flvFallbackHeaders = preferDirectFlv ? authHeaders : mergedHeaders
      if let localFlvHlsUrl = await TvLocalHlsProxyServer.shared.prepareFlvProxyPlaylistUrl(
        targetUrl: flvTarget,
        headers: flvHeaders,
        fallbackUrl: flvFallback,
        fallbackHeaders: flvFallbackHeaders
      ) {
        return TvResolvedPlayback(
          directUrl: localFlvHlsUrl,
          serverProxyUrl: localFlvHlsUrl,
          headers: mergedHeaders,
          parseVia: preferDirectFlv ? "本地FLV实时转封装" : "服务端代理+FLV转封装",
          backendProxyPlayback: !preferDirectFlv
        )
      }
    }

    let needsProxyFirst = forceServerRelay
    var finalDirectUrl = directCleanUrl
    var parseViaLabel = "客户端直连"
    if !needsProxyFirst && directCleanUrl.lowercased().contains(".m3u8") && !directCleanUrl.contains("://[") {
      if let localAcceleratedUrl = await TvLocalHlsProxyServer.shared.prepareProxyPlaylistUrl(
        gatewayUrl: split.cleanUrl,
        resolvedUrl: directCleanUrl,
        headers: mergedHeaders
      ) {
        finalDirectUrl = localAcceleratedUrl
        parseViaLabel = "本地多连接加速"
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

  // MARK: - 6. Server Media Library (/api/files)

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
        ext: Self.stringValue(item["ext"])
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
    guard let url = URL(string: urlStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return SubscriptionFetchResult(
        nodes: [],
        uploadBytes: nil,
        downloadBytes: nil,
        totalBytes: nil,
        expireTimestampSec: nil,
        error: "订阅链接格式无效"
      )
    }

    var lastErr: String = "拉取订阅为空"
    for ua in ["v2rayNG/1.8.19", "Clash.Meta/v1.18.1", "ClashforWindows/0.20.39"] {
      do {
        var req = URLRequest(url: url)
        req.timeoutInterval = 14
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
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

@MainActor
final class TvLocal115DirectClient {
  static let shared = TvLocal115DirectClient()

  static let browserUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 115Browser/27.0.5.7"

  private let session: URLSession
  private let defaultsKeyCookie = "tv_local_115_cookie"
  private let defaultsKeyUserName = "tv_local_115_user_name"

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
      "Accept": "application/json, text/plain, */*"
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
    for part in trimmed.components(separatedBy: ";") {
      let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
      let kv = p.components(separatedBy: "=")
      if kv.count >= 2 {
        let k = kv[0].trimmingCharacters(in: .whitespaces).uppercased()
        let v = kv.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
        if !k.isEmpty && !v.isEmpty {
          kvMap[k] = v
        }
      }
    }
    var ordered: [String] = []
    for k in ["UID", "CID", "SEID", "KID"] {
      if let v = kvMap[k], !v.isEmpty {
        ordered.append("\(k)=\(v)")
      }
    }
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
    for app in ["web", "tv", "mac", "ios", "android"] {
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

    let cleanKeywords = keywords
      .map { Self.cleanMatchToken($0) }
      .filter { !$0.isEmpty }

    var candidateFiles: [[String: Any]] = []
    var seenPickcodes = Set<String>()

    func appendFiles(_ list: [[String: Any]]) {
      for item in list {
        let pc = TvApiClient.stringValue(item["pc"], fallback: TvApiClient.stringValue(item["pick_code"]))
        let fid = TvApiClient.stringValue(item["fid"], fallback: TvApiClient.stringValue(item["file_id"]))
        guard !pc.isEmpty, !fid.isEmpty, seenPickcodes.insert(pc).inserted else { continue }
        candidateFiles.append(item)
      }
    }

    // 1. Search by keyword via `webapi.115.com/files/search`
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

    // 2. Also list newest files in root (`cid=0`) and `/115open` directory sorted by `user_ptime` desc
    if let rootUrl = URL(string: "https://webapi.115.com/files?aid=1&cid=0&o=user_ptime&asc=0&offset=0&limit=40&show_dir=1&format=json"),
       let rootEntries = await fetchFileEntries(from: rootUrl) {
      appendFiles(rootEntries)
      // If there is a `115open` folder (used by CloudDrive2 on the server), also inspect inside it!
      for entry in rootEntries {
        let fid = TvApiClient.stringValue(entry["fid"])
        let cid = TvApiClient.stringValue(entry["cid"])
        let name = TvApiClient.stringValue(entry["n"]).lowercased()
        if fid.isEmpty && !cid.isEmpty && (name == "115open" || name.contains("115") || name.contains("download")) {
          if let subUrl = URL(string: "https://webapi.115.com/files?aid=1&cid=\(cid)&o=user_ptime&asc=0&offset=0&limit=40&show_dir=1&format=json"),
             let subEntries = await fetchFileEntries(from: subUrl) {
            appendFiles(subEntries)
          }
        }
      }
    }

    guard !candidateFiles.isEmpty else { return nil }

    // 3. Match file by name or newest uploaded timestamp
    var matchedItem: [String: Any]? = nil
    for item in candidateFiles {
      let rawName = TvApiClient.stringValue(item["n"], fallback: TvApiClient.stringValue(item["file_name"]))
      let cleanName = Self.cleanMatchToken(rawName)
      guard !cleanName.isEmpty else { continue }
      if cleanKeywords.contains(where: { kw in
        cleanName == kw || cleanName.contains(kw) || kw.contains(cleanName)
      }) {
        matchedItem = item
        break
      }
    }

    // Fallback: if we just waited for an upload after `allowNewestRecentFallbackAfter`, pick the newest video uploaded since then
    if matchedItem == nil, let minDate = allowNewestRecentFallbackAfter {
      let minEpoch = Int64(minDate.timeIntervalSince1970) - 30
      for item in candidateFiles {
        let tp = Int64(TvApiClient.intValue(item["tp"], fallback: TvApiClient.intValue(item["te"], fallback: TvApiClient.intValue(item["t"]))))
        let iv = TvApiClient.intValue(item["iv"], fallback: 0)
        let ico = TvApiClient.stringValue(item["ico"]).lowercased()
        let isVideo = iv == 1 || ["mp4", "mkv", "ts", "mov", "flv", "avi", "webm"].contains(ico)
        if isVideo && tp >= minEpoch {
          matchedItem = item
          break
        }
      }
    }

    guard let winner = matchedItem else { return nil }
    let pickcode = TvApiClient.stringValue(winner["pc"], fallback: TvApiClient.stringValue(winner["pick_code"]))
    let fileName = TvApiClient.stringValue(winner["n"], fallback: TvApiClient.stringValue(winner["file_name"], fallback: "115 视频"))
    guard !pickcode.isEmpty else { return nil }

    guard let directUrl = await resolvePickcodeStreamUrl(pickcode: pickcode) else {
      return nil
    }

    let hdrs: [String: String] = [
      "User-Agent": Self.browserUserAgent,
      "Cookie": savedCookie
    ]
    let proxyUrl: String
    if directUrl.lowercased().contains(".m3u8") {
      proxyUrl = directUrl
    } else {
      proxyUrl = TvLocalHlsProxyServer.shared.prepareTelegramVideoProxyUrl(remoteUrl: directUrl, headers: hdrs)
    }
    return (proxyStreamUrl: proxyUrl, directCdnUrl: directUrl, headers: hdrs, fileName: fileName)
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
  func resolvePickcodeStreamUrl(pickcode: String) async -> String? {
    // 1. Primary: `proapi.115.com/app/chrome/downurl` (Original MP4 lossless CDN direct link)
    let nowSec = Int(Date().timeIntervalSince1970)
    if let downEndpoint = URL(string: "https://proapi.115.com/app/chrome/downurl?t=\(nowSec)"),
       let paramData = try? JSONSerialization.data(withJSONObject: ["pickcode": pickcode]) {
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

      if let (respData, _) = try? await session.data(for: req),
         let root = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
         let encryptedPayload = root["data"] as? String,
         let decryptedData = TvM115Crypto.decode(input: encryptedPayload, key: key),
         let resultDict = try? JSONSerialization.jsonObject(with: decryptedData) as? [String: Any] {
        for (_, val) in resultDict {
          if let info = val as? [String: Any],
             let urlObj = info["url"] as? [String: Any] {
            let cdnUrl = TvApiClient.stringValue(urlObj["url"])
            if cdnUrl.hasPrefix("http") {
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
      }
    }

    // 3. Fallback 2: `webapi.115.com/files/video?pickcode=...`
    if let vidUrl = URL(string: "https://webapi.115.com/files/video?pickcode=\(pickcode)") {
      var req = URLRequest(url: vidUrl)
      req.timeoutInterval = 10
      for (k, v) in requestHeaders {
        req.setValue(v, forHTTPHeaderField: k)
      }
      if let (data, _) = try? await session.data(for: req),
         let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        let directVideoUrl = TvApiClient.stringValue(root["video_url"])
        if directVideoUrl.hasPrefix("http") {
          return directVideoUrl
        }
        if let urls = root["video_url"] as? [[String: Any]],
           let best = urls.last {
          let u = TvApiClient.stringValue(best["url"])
          if u.hasPrefix("http") {
            return u
          }
        }
      }
    }

    return nil
  }

  private static func cleanMatchToken(_ raw: String) -> String {
    var s = (raw as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    if let regex = try? NSRegularExpression(pattern: "^tg_\\d+_") {
      let range = NSRange(s.startIndex..<s.endIndex, in: s)
      s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }
    for ext in [".mp4", ".ts", ".mkv", ".mov", ".flv", ".m3u8"] {
      while s.lowercased().hasSuffix(ext) {
        s = String(s.dropLast(ext.count))
      }
    }
    return s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
