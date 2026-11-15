import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'm3u8_ad_remover.dart';

/// Default subscription URL requested by the user.
const String kDefaultLiangxinSubscriptionUrl =
    'https://liangxin.xyz/api/v1/liangxin?OwO=7f2829c9267eb9c6d1f4d4b467a0e9fc';

/// Proxy selection strategy when proxy is enabled.
enum ProxySelectionMode {
  /// User manually locks a specific proxy node.
  manual,

  /// System automatically benchmarks nodes and switches to the fastest reachable node.
  autoFastest,
}

/// Request scenarios across the application that can be routed independently.
enum RequestScenario {
  /// VOD catalog, category browsing, detail & aggregated search APIs
  vodApi,

  /// VOD video stream playback (.m3u8 / .mp4) & ad-stripping segment fetches
  vodStream,

  /// Live TV playlist fetching, health check & live channel playback
  liveStream,

  /// Telegram account sync, chat messages, avatars, media streaming & notifications
  telegram,

  /// Primary backend server APIs (login, settings, downloads, media library, 115)
  backendApi,

  /// Subscription updates, DoH lookups & external webpage video extraction
  externalWeb,
}

extension RequestScenarioMeta on RequestScenario {
  String get label {
    switch (this) {
      case RequestScenario.vodApi:
        return '影视点播目录与搜索';
      case RequestScenario.vodStream:
        return '点播视频流播放';
      case RequestScenario.liveStream:
        return '电视直播源与频道流';
      case RequestScenario.telegram:
        return 'Telegram 消息与媒体';
      case RequestScenario.backendApi:
        return '主服务端控制接口';
      case RequestScenario.externalWeb:
        return '订阅更新与网页嗅探';
    }
  }

  String get subtitle {
    switch (this) {
      case RequestScenario.vodApi:
        return '片源分类列表、影视详情、多站聚合搜索请求';
      case RequestScenario.vodStream:
        return '点播 M3U8/MP4 视频流播放及去广告切片拉取';
      case RequestScenario.liveStream:
        return 'IPTV 节目单拉取、频道测速与直播流播放';
      case RequestScenario.telegram:
        return 'Telegram 会话列表、高清头像、视频播放与实时通知';
      case RequestScenario.backendApi:
        return '主服务器认证、下载工作台、媒体库文件与 115 网盘';
      case RequestScenario.externalWeb:
        return '代理机场订阅更新、DoH 域名解析与外部网页视频嗅探';
    }
  }
}

/// How requests in a specific [RequestScenario] should be routed.
enum ScenarioRouteMode {
  /// Follow global `proxyEnabled` switch (uses active/fastest node when enabled, direct when off).
  followGlobal,

  /// Always connect directly from the client device without any proxy.
  direct,

  /// Always route through the selected/fastest proxy node (even if global switch is off, or when enabled).
  proxyNode,

  /// Route via the backend server relay (`/api/vod/proxy`, `/api/vod/list`, etc.).
  serverRelay,

  /// Smart split-tunneling: overseas/restricted domains use proxy node; domestic/LAN/IPv6 go direct with fallback.
  smartAuto,
}

extension ScenarioRouteModeMeta on ScenarioRouteMode {
  String get label {
    switch (this) {
      case ScenarioRouteMode.followGlobal:
        return '跟随全局开关';
      case ScenarioRouteMode.direct:
        return '强制直连';
      case ScenarioRouteMode.proxyNode:
        return '走代理节点';
      case ScenarioRouteMode.serverRelay:
        return '服务端中转';
      case ScenarioRouteMode.smartAuto:
        return '智能分流';
    }
  }

  String get shortBadge {
    switch (this) {
      case ScenarioRouteMode.followGlobal:
        return '跟随全局';
      case ScenarioRouteMode.direct:
        return '直连';
      case ScenarioRouteMode.proxyNode:
        return '代理节点';
      case ScenarioRouteMode.serverRelay:
        return '服务端中转';
      case ScenarioRouteMode.smartAuto:
        return '智能分流';
    }
  }

  String get description {
    switch (this) {
      case ScenarioRouteMode.followGlobal:
        return '全局代理开启时走当前/最快节点，关闭时直连';
      case ScenarioRouteMode.direct:
        return '始终由本机直接发起网络请求，不经过任何代理';
      case ScenarioRouteMode.proxyNode:
        return '强制通过订阅代理节点（或本场景指定节点）转发';
      case ScenarioRouteMode.serverRelay:
        return '通过后端主服务器代理接口中转请求与视频流';
      case ScenarioRouteMode.smartAuto:
        return '海外/受限域名自动走代理节点，国内 CDN 与局域网直连';
    }
  }
}

/// Per-scenario routing configuration.
class ScenarioRuleConfig {
  final RequestScenario scenario;
  final ScenarioRouteMode mode;

  /// Optional specific proxy node ID bound to this scenario.
  /// If empty/null, uses the global active node (manual selection or auto-fastest).
  final String? specificNodeId;

  const ScenarioRuleConfig({
    required this.scenario,
    this.mode = ScenarioRouteMode.followGlobal,
    this.specificNodeId,
  });

  ScenarioRuleConfig copyWith({
    ScenarioRouteMode? mode,
    String? specificNodeId,
    bool clearSpecificNode = false,
  }) {
    return ScenarioRuleConfig(
      scenario: scenario,
      mode: mode ?? this.mode,
      specificNodeId:
          clearSpecificNode ? null : (specificNodeId ?? this.specificNodeId),
    );
  }

  Map<String, dynamic> toJson() => {
        'scenario': scenario.name,
        'mode': mode.name,
        if (specificNodeId != null && specificNodeId!.isNotEmpty)
          'specificNodeId': specificNodeId,
      };

  factory ScenarioRuleConfig.fromJson(
    RequestScenario scenario,
    Map<String, dynamic> json,
  ) {
    final modeStr = (json['mode'] ?? 'followGlobal').toString();
    final mode = ScenarioRouteMode.values.firstWhere(
      (m) => m.name == modeStr,
      orElse: () => ScenarioRouteMode.followGlobal,
    );
    final nodeId = (json['specificNodeId'] ?? '').toString().trim();
    return ScenarioRuleConfig(
      scenario: scenario,
      mode: mode,
      specificNodeId: nodeId.isEmpty ? null : nodeId,
    );
  }
}

/// Represents a proxy subscription source (e.g. V2Board / Clash / Base64 subscription link).
class ProxySubscription {
  final String id;
  final String name;
  final String url;
  final bool enabled;
  final int autoUpdateHours;
  final int lastUpdatedAtMs;
  final int nodeCount;
  final int? uploadBytes;
  final int? downloadBytes;
  final int? totalBytes;
  final int? expireTimestampSec;
  final String lastError;
  final String customUserAgent;

  const ProxySubscription({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = true,
    this.autoUpdateHours = 12,
    this.lastUpdatedAtMs = 0,
    this.nodeCount = 0,
    this.uploadBytes,
    this.downloadBytes,
    this.totalBytes,
    this.expireTimestampSec,
    this.lastError = '',
    this.customUserAgent = '',
  });

  double? get usedTrafficRatio {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    final used = (uploadBytes ?? 0) + (downloadBytes ?? 0);
    return (used / total).clamp(0.0, 1.0);
  }

  String get formattedTrafficSummary {
    final total = totalBytes;
    if (total == null || total <= 0) return '';
    final used = (uploadBytes ?? 0) + (downloadBytes ?? 0);
    return '${_formatBytes(used)} / ${_formatBytes(total)}';
  }

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const kb = 1024.0;
    const mb = kb * 1024;
    const gb = mb * 1024;
    const tb = gb * 1024;
    if (bytes >= tb) return '${(bytes / tb).toStringAsFixed(2)} TB';
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    return '${(bytes / kb).toStringAsFixed(0)} KB';
  }

  ProxySubscription copyWith({
    String? id,
    String? name,
    String? url,
    bool? enabled,
    int? autoUpdateHours,
    int? lastUpdatedAtMs,
    int? nodeCount,
    int? uploadBytes,
    int? downloadBytes,
    int? totalBytes,
    int? expireTimestampSec,
    String? lastError,
    String? customUserAgent,
  }) {
    return ProxySubscription(
      id: id ?? this.id,
      name: name ?? this.name,
      url: url ?? this.url,
      enabled: enabled ?? this.enabled,
      autoUpdateHours: autoUpdateHours ?? this.autoUpdateHours,
      lastUpdatedAtMs: lastUpdatedAtMs ?? this.lastUpdatedAtMs,
      nodeCount: nodeCount ?? this.nodeCount,
      uploadBytes: uploadBytes ?? this.uploadBytes,
      downloadBytes: downloadBytes ?? this.downloadBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      expireTimestampSec: expireTimestampSec ?? this.expireTimestampSec,
      lastError: lastError ?? this.lastError,
      customUserAgent: customUserAgent ?? this.customUserAgent,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'enabled': enabled,
        'autoUpdateHours': autoUpdateHours,
        'lastUpdatedAtMs': lastUpdatedAtMs,
        'nodeCount': nodeCount,
        if (uploadBytes != null) 'uploadBytes': uploadBytes,
        if (downloadBytes != null) 'downloadBytes': downloadBytes,
        if (totalBytes != null) 'totalBytes': totalBytes,
        if (expireTimestampSec != null)
          'expireTimestampSec': expireTimestampSec,
        'lastError': lastError,
        'customUserAgent': customUserAgent,
      };

  factory ProxySubscription.fromJson(Map<String, dynamic> json) {
    return ProxySubscription(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '代理订阅').toString(),
      url: (json['url'] ?? '').toString(),
      enabled: json['enabled'] != false,
      autoUpdateHours:
          int.tryParse((json['autoUpdateHours'] ?? 12).toString()) ?? 12,
      lastUpdatedAtMs:
          int.tryParse((json['lastUpdatedAtMs'] ?? 0).toString()) ?? 0,
      nodeCount: int.tryParse((json['nodeCount'] ?? 0).toString()) ?? 0,
      uploadBytes: json['uploadBytes'] != null
          ? int.tryParse(json['uploadBytes'].toString())
          : null,
      downloadBytes: json['downloadBytes'] != null
          ? int.tryParse(json['downloadBytes'].toString())
          : null,
      totalBytes: json['totalBytes'] != null
          ? int.tryParse(json['totalBytes'].toString())
          : null,
      expireTimestampSec: json['expireTimestampSec'] != null
          ? int.tryParse(json['expireTimestampSec'].toString())
          : null,
      lastError: (json['lastError'] ?? '').toString(),
      customUserAgent: (json['customUserAgent'] ?? '').toString(),
    );
  }
}

/// Represents an individual proxy node (parsed from a subscription, synced from server, or added manually).
class ProxyNode {
  final String id;
  final String subscriptionId; // 'manual', 'server', or subscription ID
  final String name;
  final String protocol; // ss, ssr, trojan, vmess, vless, socks5, http, https, hysteria2, tuic
  final String server;
  final int port;
  final String username;
  final String password;
  final String cipher;
  final String sni;
  final bool skipCertVerify;
  final String network; // tcp, ws, grpc, h2
  final String wsPath;
  final String wsHost;
  final bool tls;
  final String rawUri;
  final bool enabled;
  final bool favorite;
  /// Real end-to-end proxy tunnel HTTP round-trip latency in ms (`null` = untested, `-1` = timeout/error, `>0` = verified tunnel RTT).
  final int? latencyMs;
  /// Raw entry-hop TCP/TLS handshake ping in ms (for reference only; never used alone to claim tunnel connectivity).
  final int? tcpPingMs;
  /// Measured real proxy tunnel transfer throughput in KB/s (`>0` when verified).
  final int? speedKbps;
  final int lastTestedAtMs;

  const ProxyNode({
    required this.id,
    this.subscriptionId = 'manual',
    required this.name,
    required this.protocol,
    required this.server,
    required this.port,
    this.username = '',
    this.password = '',
    this.cipher = 'aes-256-gcm',
    this.sni = '',
    this.skipCertVerify = true,
    this.network = 'tcp',
    this.wsPath = '',
    this.wsHost = '',
    this.tls = false,
    this.rawUri = '',
    this.enabled = true,
    this.favorite = false,
    this.latencyMs,
    this.tcpPingMs,
    this.speedKbps,
    this.lastTestedAtMs = 0,
  });

  /// Detects informational/fake subscription nodes such as `"剩余流量：..."`, `"套餐到期：..."`, `"官网：..."`.
  bool get isInfoNode {
    final lowerName = name.toLowerCase();
    const infoKeywords = [
      '剩余流量',
      '套餐到期',
      '距离下次重置',
      '过期时间',
      '到期时间',
      '官网',
      '网址',
      '防失联',
      '群组',
      '公告',
      '流量重置',
      '请更新订阅',
    ];
    for (final kw in infoKeywords) {
      if (lowerName.contains(kw)) return true;
    }
    final h = server.trim().toLowerCase();
    if (subscriptionId != 'manual' && subscriptionId != 'server') {
      if (h == '127.0.0.1' || h == '0.0.0.0' || h == 'localhost' || port <= 1) {
        return true;
      }
    }
    return false;
  }

  bool get isReachable => !isInfoNode && latencyMs != null && latencyMs! > 0;
  bool get isTimeout => latencyMs != null && latencyMs! < 0;

  /// Composite ranking score (lower is better) combining real end-to-end tunnel TTFB (`latencyMs`)
  /// and real tunnel transfer throughput (`speedKbps`).
  int get effectiveScore {
    if (!isReachable) return 999999;
    final baseLatency = latencyMs!;
    final kbps = speedKbps ?? 0;
    if (kbps <= 0) return baseLatency;
    // Reward high real throughput (up to -180ms bonus) and penalize congested tunnels (< 150 KB/s)
    if (kbps < 120) {
      return baseLatency + 350;
    }
    final speedBonus = (kbps ~/ 18).clamp(0, 180);
    return (baseLatency - speedBonus).clamp(1, 99999);
  }

  String get speedLabel {
    final kbps = speedKbps;
    if (kbps == null || kbps <= 0) return '';
    if (kbps >= 1024) {
      return '${(kbps / 1024.0).toStringAsFixed(1)} MB/s';
    }
    return '$kbps KB/s';
  }

  String get protocolBadge {
    switch (protocol.toLowerCase()) {
      case 'ss':
      case 'shadowsocks':
        return 'SS';
      case 'ssr':
        return 'SSR';
      case 'trojan':
        return 'Trojan';
      case 'vmess':
        return 'VMess';
      case 'vless':
        return 'VLESS';
      case 'socks5':
      case 'socks':
        return 'SOCKS5';
      case 'http':
        return 'HTTP';
      case 'https':
        return 'HTTPS';
      case 'hysteria2':
      case 'hy2':
        return 'HY2';
      case 'tuic':
        return 'TUIC';
      default:
        return protocol.toUpperCase();
    }
  }

  /// Auto-detects country/region flag from node name or server host.
  String get regionFlag {
    final text = '$name $server'.toUpperCase();
    if (text.contains('香港') ||
        text.contains('HK') ||
        text.contains('HONGKONG') ||
        text.contains('HONG KONG')) {
      return '🇭🇰';
    }
    if (text.contains('日本') ||
        text.contains('JP') ||
        text.contains('JAPAN') ||
        text.contains('TOKYO') ||
        text.contains('OSAKA') ||
        text.contains('东京') ||
        text.contains('大阪')) {
      return '🇯🇵';
    }
    if (text.contains('新加坡') ||
        text.contains('狮城') ||
        text.contains('SG') ||
        text.contains('SINGAPORE')) {
      return '🇸🇬';
    }
    if (text.contains('台湾') ||
        text.contains('台北') ||
        text.contains('TW') ||
        text.contains('TAIWAN')) {
      return '🇹🇼';
    }
    if (text.contains('美国') ||
        text.contains('US') ||
        text.contains('USA') ||
        text.contains('洛杉矶') ||
        text.contains('圣何塞') ||
        text.contains('硅谷') ||
        text.contains('西雅图')) {
      return '🇺🇸';
    }
    if (text.contains('韩国') ||
        text.contains('首尔') ||
        text.contains('KR') ||
        text.contains('KOREA')) {
      return '🇰🇷';
    }
    if (text.contains('英国') ||
        text.contains('伦敦') ||
        text.contains('UK') ||
        text.contains('GB')) {
      return '🇬🇧';
    }
    if (text.contains('德国') ||
        text.contains('法兰克福') ||
        text.contains('DE') ||
        text.contains('GERMANY')) {
      return '🇩🇪';
    }
    if (text.contains('法国') || text.contains('FR') || text.contains('FRANCE')) {
      return '🇫🇷';
    }
    if (text.contains('加拿大') || text.contains('CA') || text.contains('CANADA')) {
      return '🇨🇦';
    }
    if (text.contains('澳大利亚') ||
        text.contains('澳洲') ||
        text.contains('AU') ||
        text.contains('SYDNEY')) {
      return '🇦🇺';
    }
    if (text.contains('俄罗斯') || text.contains('RU') || text.contains('MOSCOW')) {
      return '🇷🇺';
    }
    if (text.contains('印度') || text.contains('IN') || text.contains('MUMBAI')) {
      return '🇮🇳';
    }
    if (text.contains('马来西亚') || text.contains('MY')) {
      return '🇲🇾';
    }
    if (text.contains('泰国') || text.contains('TH')) {
      return '🇹🇭';
    }
    if (text.contains('土耳其') || text.contains('TR')) {
      return '🇹🇷';
    }
    return '🌐';
  }

  String get regionCategory {
    final f = regionFlag;
    switch (f) {
      case '🇭🇰':
        return '香港';
      case '🇯🇵':
        return '日本';
      case '🇸🇬':
        return '新加坡';
      case '🇹🇼':
        return '台湾';
      case '🇺🇸':
        return '美国';
      case '🇰🇷':
        return '韩国';
      default:
        return '其他地区';
    }
  }

  String get displayTitle {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '$regionFlag $server:$port';
    // Avoid doubling the flag if name already contains it
    if (trimmed.contains(regionFlag) && regionFlag != '🌐') {
      return trimmed;
    }
    return '$regionFlag $trimmed';
  }

  String get latencyLabel {
    if (latencyMs == null) return '未测速';
    if (latencyMs! < 0) return '超时';
    final spd = speedLabel;
    return spd.isNotEmpty ? '$latencyMs ms · $spd' : '$latencyMs ms';
  }

  String toShareUri() {
    if (rawUri.trim().isNotEmpty && rawUri.contains('://')) {
      return rawUri.trim();
    }
    final tag = Uri.encodeComponent(name.isEmpty ? '$server:$port' : name);
    switch (protocol.toLowerCase()) {
      case 'ss':
        final userInfo = '${cipher.isEmpty ? "aes-256-gcm" : cipher}:$password';
        final b64 =
            base64Url.encode(utf8.encode(userInfo)).replaceAll('=', '');
        return 'ss://$b64@$server:$port#$tag';
      case 'trojan':
        final pwd = Uri.encodeComponent(password);
        final effectiveSni = sni.isNotEmpty ? sni : server;
        return 'trojan://$pwd@$server:$port?sni=$effectiveSni&allowInsecure=${skipCertVerify ? 1 : 0}#$tag';
      case 'vmess':
        final vmessMap = {
          'v': '2',
          'ps': name,
          'add': server,
          'port': port.toString(),
          'id': password,
          'aid': '0',
          'scy': cipher.isEmpty ? 'auto' : cipher,
          'net': network.isEmpty ? 'tcp' : network,
          'type': 'none',
          'host': wsHost,
          'path': wsPath,
          'tls': tls ? 'tls' : '',
          'sni': sni,
        };
        final b64 = base64Encode(utf8.encode(jsonEncode(vmessMap)));
        return 'vmess://$b64';
      case 'vless':
        final effectiveSni = sni.isNotEmpty ? sni : server;
        return 'vless://${Uri.encodeComponent(password)}@$server:$port?security=${tls ? "tls" : "none"}&sni=$effectiveSni&type=$network#$tag';
      case 'socks5':
        final auth = username.isNotEmpty
            ? '${Uri.encodeComponent(username)}:${Uri.encodeComponent(password)}@'
            : '';
        return 'socks5://$auth$server:$port#$tag';
      case 'http':
      case 'https':
      default:
        final scheme = protocol.toLowerCase() == 'https' ? 'https' : 'http';
        final auth = username.isNotEmpty
            ? '${Uri.encodeComponent(username)}:${Uri.encodeComponent(password)}@'
            : '';
        return '$scheme://$auth$server:$port#$tag';
    }
  }

  ProxyNode copyWith({
    String? id,
    String? subscriptionId,
    String? name,
    String? protocol,
    String? server,
    int? port,
    String? username,
    String? password,
    String? cipher,
    String? sni,
    bool? skipCertVerify,
    String? network,
    String? wsPath,
    String? wsHost,
    bool? tls,
    String? rawUri,
    bool? enabled,
    bool? favorite,
    int? latencyMs,
    int? tcpPingMs,
    int? speedKbps,
    bool clearLatency = false,
    int? lastTestedAtMs,
  }) {
    return ProxyNode(
      id: id ?? this.id,
      subscriptionId: subscriptionId ?? this.subscriptionId,
      name: name ?? this.name,
      protocol: protocol ?? this.protocol,
      server: server ?? this.server,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
      cipher: cipher ?? this.cipher,
      sni: sni ?? this.sni,
      skipCertVerify: skipCertVerify ?? this.skipCertVerify,
      network: network ?? this.network,
      wsPath: wsPath ?? this.wsPath,
      wsHost: wsHost ?? this.wsHost,
      tls: tls ?? this.tls,
      rawUri: rawUri ?? this.rawUri,
      enabled: enabled ?? this.enabled,
      favorite: favorite ?? this.favorite,
      latencyMs: clearLatency ? null : (latencyMs ?? this.latencyMs),
      tcpPingMs: clearLatency ? null : (tcpPingMs ?? this.tcpPingMs),
      speedKbps: clearLatency ? null : (speedKbps ?? this.speedKbps),
      lastTestedAtMs: lastTestedAtMs ?? this.lastTestedAtMs,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'subscriptionId': subscriptionId,
        'name': name,
        'protocol': protocol,
        'server': server,
        'port': port,
        'username': username,
        'password': password,
        'cipher': cipher,
        'sni': sni,
        'skipCertVerify': skipCertVerify,
        'network': network,
        'wsPath': wsPath,
        'wsHost': wsHost,
        'tls': tls,
        'rawUri': rawUri,
        'enabled': enabled,
        'favorite': favorite,
        if (latencyMs != null) 'latencyMs': latencyMs,
        if (tcpPingMs != null) 'tcpPingMs': tcpPingMs,
        if (speedKbps != null) 'speedKbps': speedKbps,
        'lastTestedAtMs': lastTestedAtMs,
      };

  factory ProxyNode.fromJson(Map<String, dynamic> json) {
    return ProxyNode(
      id: (json['id'] ?? '').toString(),
      subscriptionId: (json['subscriptionId'] ?? 'manual').toString(),
      name: (json['name'] ?? '未命名节点').toString(),
      protocol: (json['protocol'] ?? 'http').toString().toLowerCase(),
      server: (json['server'] ?? '').toString(),
      port: int.tryParse((json['port'] ?? 1080).toString()) ?? 1080,
      username: (json['username'] ?? '').toString(),
      password: (json['password'] ?? '').toString(),
      cipher: (json['cipher'] ?? 'aes-256-gcm').toString(),
      sni: (json['sni'] ?? '').toString(),
      skipCertVerify: json['skipCertVerify'] != false,
      network: (json['network'] ?? 'tcp').toString(),
      wsPath: (json['wsPath'] ?? '').toString(),
      wsHost: (json['wsHost'] ?? '').toString(),
      tls: json['tls'] == true,
      rawUri: (json['rawUri'] ?? '').toString(),
      enabled: json['enabled'] != false,
      favorite: json['favorite'] == true,
      latencyMs: json['latencyMs'] != null
          ? int.tryParse(json['latencyMs'].toString())
          : null,
      tcpPingMs: json['tcpPingMs'] != null
          ? int.tryParse(json['tcpPingMs'].toString())
          : null,
      speedKbps: json['speedKbps'] != null
          ? int.tryParse(json['speedKbps'].toString())
          : null,
      lastTestedAtMs:
          int.tryParse((json['lastTestedAtMs'] ?? 0).toString()) ?? 0,
    );
  }
}

/// Multi-format parser for V2Board / Xboard / Clash / Mihomo / Base64 / URI / SIP008 proxy subscriptions.
class ProxySubscriptionParser {
  /// Parse `subscription-userinfo` HTTP header:
  /// e.g. `upload=1024; download=20480; total=107374182400; expire=1893456000`
  static ({
    int? upload,
    int? download,
    int? total,
    int? expire,
  }) parseUserInfoHeader(Map<String, String> headers) {
    String? raw;
    headers.forEach((k, v) {
      if (k.toLowerCase() == 'subscription-userinfo') {
        raw = v;
      }
    });
    if (raw == null || raw!.trim().isEmpty) {
      return (upload: null, download: null, total: null, expire: null);
    }
    int? upload;
    int? download;
    int? total;
    int? expire;
    for (final part in raw!.split(';')) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      final key = part.substring(0, eq).trim().toLowerCase();
      final val = int.tryParse(part.substring(eq + 1).trim());
      if (val == null) continue;
      if (key == 'upload') upload = val;
      if (key == 'download') download = val;
      if (key == 'total') total = val;
      if (key == 'expire') expire = val;
    }
    return (upload: upload, download: download, total: total, expire: expire);
  }

  static String? _tryDecodeBase64Text(String input) {
    final cleaned = input.replaceAll(RegExp(r'\s+'), '');
    if (cleaned.isEmpty) return null;
    try {
      var normalized = cleaned.replaceAll('-', '+').replaceAll('_', '/');
      final mod = normalized.length % 4;
      if (mod > 0) {
        normalized += '=' * (4 - mod);
      }
      final bytes = base64Decode(normalized);
      final text = utf8.decode(bytes, allowMalformed: true).trim();
      if (text.isNotEmpty) return text;
    } catch (_) {}
    return null;
  }

  /// Parse raw subscription body (Base64, Clash YAML, URI list, or SIP008 JSON)
  /// into a list of [ProxyNode]s.
  static List<ProxyNode> parseSubscriptionContent(
    String rawBody, {
    required String subscriptionId,
  }) {
    final trimmed = rawBody.trim();
    if (trimmed.isEmpty) return const [];

    // Reject HTML error pages (e.g. Cloudflare / Laravel 403)
    if (trimmed.startsWith('<!DOCTYPE') ||
        trimmed.toLowerCase().startsWith('<html')) {
      return const [];
    }

    // 1. Check if it's Clash YAML containing `proxies:`
    if (trimmed.contains('proxies:') ||
        RegExp(r'^\s*-\s*\{\s*name\s*:', multiLine: true).hasMatch(trimmed)) {
      final clashNodes = _parseClashYaml(trimmed, subscriptionId);
      if (clashNodes.isNotEmpty) return clashNodes;
    }

    // 2. Check if it's JSON (SIP008 or array of proxy objects)
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      final jsonNodes = _parseJsonProxies(trimmed, subscriptionId);
      if (jsonNodes.isNotEmpty) return jsonNodes;
    }

    // 3. Check if it's plain-text proxy URIs
    if (trimmed.contains('://')) {
      final uriNodes = _parseUriLines(trimmed, subscriptionId);
      if (uriNodes.isNotEmpty) return uriNodes;
    }

    // 4. Try Base64 decoding
    final decoded = _tryDecodeBase64Text(trimmed);
    if (decoded != null && decoded != trimmed) {
      if (decoded.contains('proxies:')) {
        final clashNodes = _parseClashYaml(decoded, subscriptionId);
        if (clashNodes.isNotEmpty) return clashNodes;
      }
      if (decoded.startsWith('{') || decoded.startsWith('[')) {
        final jsonNodes = _parseJsonProxies(decoded, subscriptionId);
        if (jsonNodes.isNotEmpty) return jsonNodes;
      }
      final uriNodes = _parseUriLines(decoded, subscriptionId);
      if (uriNodes.isNotEmpty) return uriNodes;
    }

    return const [];
  }

  static List<ProxyNode> _parseUriLines(
    String content,
    String subscriptionId,
  ) {
    final nodes = <ProxyNode>[];
    final lines = const LineSplitter().convert(content);
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) {
        continue;
      }
      final parsed = parseSingleProxyUri(
        line,
        subscriptionId: subscriptionId,
        indexHint: i,
      );
      if (parsed != null && parsed.server.isNotEmpty && parsed.port > 0) {
        nodes.add(parsed);
      }
    }
    return nodes;
  }

  /// Parse a single proxy URI (`ss://`, `ssr://`, `trojan://`, `vmess://`, `vless://`, `socks5://`, `http://`, `hy2://`, `tuic://`).
  static ProxyNode? parseSingleProxyUri(
    String rawUri, {
    String subscriptionId = 'manual',
    int indexHint = 0,
  }) {
    final trimmed = rawUri.trim();
    final schemeIdx = trimmed.indexOf('://');
    if (schemeIdx <= 0) return null;
    final scheme = trimmed.substring(0, schemeIdx).toLowerCase();

    try {
      switch (scheme) {
        case 'ss':
          return _parseSsUri(trimmed, subscriptionId, indexHint);
        case 'ssr':
          return _parseSsrUri(trimmed, subscriptionId, indexHint);
        case 'vmess':
          return _parseVmessUri(trimmed, subscriptionId, indexHint);
        case 'trojan':
          return _parseTrojanOrVlessUri(
            trimmed,
            protocol: 'trojan',
            subscriptionId: subscriptionId,
            indexHint: indexHint,
          );
        case 'vless':
          return _parseTrojanOrVlessUri(
            trimmed,
            protocol: 'vless',
            subscriptionId: subscriptionId,
            indexHint: indexHint,
          );
        case 'hysteria2':
        case 'hy2':
          return _parseTrojanOrVlessUri(
            trimmed,
            protocol: 'hysteria2',
            subscriptionId: subscriptionId,
            indexHint: indexHint,
          );
        case 'tuic':
          return _parseTrojanOrVlessUri(
            trimmed,
            protocol: 'tuic',
            subscriptionId: subscriptionId,
            indexHint: indexHint,
          );
        case 'socks5':
        case 'socks':
        case 'http':
        case 'https':
          return _parseStandardHttpOrSocksUri(
            trimmed,
            protocol: scheme == 'socks' ? 'socks5' : scheme,
            subscriptionId: subscriptionId,
            indexHint: indexHint,
          );
        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  static ProxyNode? _parseSsUri(
    String uriStr,
    String subscriptionId,
    int indexHint,
  ) {
    var body = uriStr.substring(5).trim();
    String name = '';
    final hashIdx = body.indexOf('#');
    if (hashIdx >= 0) {
      name = Uri.decodeComponent(body.substring(hashIdx + 1).trim());
      body = body.substring(0, hashIdx).trim();
    }
    // Strip optional ?plugin=... query for host/port extraction
    final queryIdx = body.indexOf('?');
    if (queryIdx >= 0) {
      body = body.substring(0, queryIdx).trim();
    }

    String cipher = 'aes-256-gcm';
    String password = '';
    String server = '';
    int port = 0;

    if (body.contains('@')) {
      final atIdx = body.lastIndexOf('@');
      final userPart = body.substring(0, atIdx);
      final hostPart = body.substring(atIdx + 1);
      final decodedUser = _tryDecodeBase64Text(userPart) ??
          Uri.decodeComponent(userPart);
      final colonIdx = decodedUser.indexOf(':');
      if (colonIdx > 0) {
        cipher = decodedUser.substring(0, colonIdx).trim();
        password = decodedUser.substring(colonIdx + 1);
      } else {
        password = decodedUser;
      }
      final hp = _splitHostPort(hostPart);
      server = hp.host;
      port = hp.port;
    } else {
      final decodedAll = _tryDecodeBase64Text(body);
      if (decodedAll == null) return null;
      final atIdx = decodedAll.lastIndexOf('@');
      if (atIdx <= 0) return null;
      final userPart = decodedAll.substring(0, atIdx);
      final hostPart = decodedAll.substring(atIdx + 1);
      final colonIdx = userPart.indexOf(':');
      if (colonIdx > 0) {
        cipher = userPart.substring(0, colonIdx).trim();
        password = userPart.substring(colonIdx + 1);
      }
      final hp = _splitHostPort(hostPart);
      server = hp.host;
      port = hp.port;
    }

    if (server.isEmpty || port <= 0) return null;
    return ProxyNode(
      id: _buildStableNodeId(subscriptionId, 'ss', server, port, name, indexHint),
      subscriptionId: subscriptionId,
      name: name.isNotEmpty ? name : 'SS $server:$port',
      protocol: 'ss',
      server: server,
      port: port,
      password: password,
      cipher: cipher,
      rawUri: uriStr,
    );
  }

  static ProxyNode? _parseSsrUri(
    String uriStr,
    String subscriptionId,
    int indexHint,
  ) {
    final b64 = uriStr.substring(6).trim();
    final decoded = _tryDecodeBase64Text(b64);
    if (decoded == null) return null;
    final parts = decoded.split('/?');
    final mainSegs = parts[0].split(':');
    if (mainSegs.length < 6) return null;
    final server = mainSegs[0].trim();
    final port = int.tryParse(mainSegs[1].trim()) ?? 0;
    final cipher = mainSegs[3].trim();
    final password = _tryDecodeBase64Text(mainSegs[5].trim()) ?? mainSegs[5];
    String name = 'SSR $server:$port';
    if (parts.length > 1) {
      final params = Uri.splitQueryString(parts[1]);
      if (params['remarks'] != null) {
        name = _tryDecodeBase64Text(params['remarks']!) ?? name;
      }
    }
    if (server.isEmpty || port <= 0) return null;
    return ProxyNode(
      id: _buildStableNodeId(subscriptionId, 'ssr', server, port, name, indexHint),
      subscriptionId: subscriptionId,
      name: name,
      protocol: 'ssr',
      server: server,
      port: port,
      password: password,
      cipher: cipher,
      rawUri: uriStr,
    );
  }

  static ProxyNode? _parseVmessUri(
    String uriStr,
    String subscriptionId,
    int indexHint,
  ) {
    final b64 = uriStr.substring(8).trim();
    final decoded = _tryDecodeBase64Text(b64);
    if (decoded == null) return null;
    final json = jsonDecode(decoded);
    if (json is! Map) return null;
    final server = (json['add'] ?? json['server'] ?? '').toString().trim();
    final port = int.tryParse((json['port'] ?? 0).toString()) ?? 0;
    if (server.isEmpty || port <= 0) return null;
    final name = (json['ps'] ?? json['name'] ?? 'VMess $server:$port')
        .toString()
        .trim();
    final uuid = (json['id'] ?? json['uuid'] ?? '').toString().trim();
    final scy = (json['scy'] ?? json['cipher'] ?? 'auto').toString().trim();
    final net = (json['net'] ?? json['network'] ?? 'tcp').toString().trim();
    final tlsStr = (json['tls'] ?? '').toString().toLowerCase();
    final tls = tlsStr == 'tls' || tlsStr == 'true' || tlsStr == '1';
    final sni = (json['sni'] ?? json['host'] ?? '').toString().trim();
    final wsHost = (json['host'] ?? '').toString().trim();
    final wsPath = (json['path'] ?? '').toString().trim();

    return ProxyNode(
      id: _buildStableNodeId(
          subscriptionId, 'vmess', server, port, name, indexHint),
      subscriptionId: subscriptionId,
      name: name,
      protocol: 'vmess',
      server: server,
      port: port,
      password: uuid,
      cipher: scy,
      network: net,
      tls: tls,
      sni: sni,
      wsHost: wsHost,
      wsPath: wsPath,
      rawUri: uriStr,
    );
  }

  static ProxyNode? _parseTrojanOrVlessUri(
    String uriStr, {
    required String protocol,
    required String subscriptionId,
    required int indexHint,
  }) {
    final uri = Uri.tryParse(uriStr);
    if (uri == null || uri.host.isEmpty) return null;
    final server = uri.host;
    final port = uri.hasPort ? uri.port : 443;
    final name = uri.fragment.isNotEmpty
        ? Uri.decodeComponent(uri.fragment)
        : '${protocol.toUpperCase()} $server:$port';
    final password = Uri.decodeComponent(uri.userInfo);
    final qp = uri.queryParameters;
    final sni = (qp['sni'] ?? qp['peer'] ?? qp['servername'] ?? '').trim();
    final allowInsecure =
        qp['allowInsecure'] == '1' || qp['allowInsecure'] == 'true';
    final network = (qp['type'] ?? 'tcp').trim();
    final wsPath = (qp['path'] ?? '').trim();
    final wsHost = (qp['host'] ?? '').trim();
    final security = (qp['security'] ?? 'tls').toLowerCase();

    return ProxyNode(
      id: _buildStableNodeId(
          subscriptionId, protocol, server, port, name, indexHint),
      subscriptionId: subscriptionId,
      name: name,
      protocol: protocol,
      server: server,
      port: port,
      password: password,
      sni: sni,
      skipCertVerify: allowInsecure,
      network: network,
      wsPath: wsPath,
      wsHost: wsHost,
      tls: security != 'none',
      rawUri: uriStr,
    );
  }

  static ProxyNode? _parseStandardHttpOrSocksUri(
    String uriStr, {
    required String protocol,
    required String subscriptionId,
    required int indexHint,
  }) {
    final uri = Uri.tryParse(uriStr);
    if (uri == null || uri.host.isEmpty) return null;
    final server = uri.host;
    final port = uri.hasPort
        ? uri.port
        : (protocol == 'socks5' ? 1080 : (protocol == 'https' ? 443 : 8080));
    final name = uri.fragment.isNotEmpty
        ? Uri.decodeComponent(uri.fragment)
        : '${protocol.toUpperCase()} $server:$port';
    String username = '';
    String password = '';
    if (uri.userInfo.isNotEmpty) {
      final userInfo = uri.userInfo;
      final colon = userInfo.indexOf(':');
      if (colon >= 0) {
        username = Uri.decodeComponent(userInfo.substring(0, colon));
        password = Uri.decodeComponent(userInfo.substring(colon + 1));
      } else {
        username = Uri.decodeComponent(userInfo);
      }
    }
    return ProxyNode(
      id: _buildStableNodeId(
          subscriptionId, protocol, server, port, name, indexHint),
      subscriptionId: subscriptionId,
      name: name,
      protocol: protocol,
      server: server,
      port: port,
      username: username,
      password: password,
      tls: protocol == 'https',
      rawUri: uriStr,
    );
  }

  static ({String host, int port}) _splitHostPort(String raw) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('[')) {
      final closeBracket = trimmed.indexOf(']');
      if (closeBracket > 0) {
        final host = trimmed.substring(1, closeBracket);
        final rest = trimmed.substring(closeBracket + 1);
        final port = rest.startsWith(':')
            ? (int.tryParse(rest.substring(1)) ?? 0)
            : 0;
        return (host: host, port: port);
      }
    }
    final colon = trimmed.lastIndexOf(':');
    if (colon <= 0) return (host: trimmed, port: 0);
    return (
      host: trimmed.substring(0, colon).trim(),
      port: int.tryParse(trimmed.substring(colon + 1).trim()) ?? 0,
    );
  }

  static List<ProxyNode> _parseClashYaml(
    String yamlText,
    String subscriptionId,
  ) {
    final nodes = <ProxyNode>[];
    final lines = const LineSplitter().convert(yamlText);
    bool inProxiesSection = false;
    Map<String, String>? currentBlockItem;

    void flushBlockItem(int indexHint) {
      if (currentBlockItem != null && currentBlockItem!.isNotEmpty) {
        final node = _clashMapToNode(
          currentBlockItem!,
          subscriptionId: subscriptionId,
          indexHint: indexHint,
        );
        if (node != null) nodes.add(node);
        currentBlockItem = null;
      }
    }

    for (var i = 0; i < lines.length; i++) {
      final rawLine = lines[i];
      final trimmed = rawLine.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

      if (RegExp(r'^proxies\s*:').hasMatch(trimmed)) {
        inProxiesSection = true;
        continue;
      }
      if (inProxiesSection &&
          !rawLine.startsWith(' ') &&
          !rawLine.startsWith('\t') &&
          !trimmed.startsWith('-') &&
          trimmed.contains(':')) {
        flushBlockItem(i);
        inProxiesSection = false;
        continue;
      }

      // Inline flow map: `- { name: "HK 01", type: ss, server: 1.2.3.4, port: 8388, ... }`
      final inlineMatch =
          RegExp(r'^-\s*\{(.+)\}\s*$').firstMatch(trimmed);
      if (inlineMatch != null) {
        flushBlockItem(i);
        final map = _parseInlineYamlFlowMap(inlineMatch.group(1)!);
        final node = _clashMapToNode(
          map,
          subscriptionId: subscriptionId,
          indexHint: i,
        );
        if (node != null) nodes.add(node);
        continue;
      }

      if (!inProxiesSection) continue;

      if (trimmed.startsWith('- ')) {
        flushBlockItem(i);
        currentBlockItem = <String, String>{};
        final firstKv = trimmed.substring(2).trim();
        _parseYamlKeyValueInto(firstKv, currentBlockItem!);
      } else if (currentBlockItem != null && trimmed.contains(':')) {
        _parseYamlKeyValueInto(trimmed, currentBlockItem!);
      }
    }
    flushBlockItem(lines.length);
    return nodes;
  }

  static Map<String, String> _parseInlineYamlFlowMap(String inner) {
    final map = <String, String>{};
    final parts = <String>[];
    final sb = StringBuffer();
    bool inSingleQuote = false;
    bool inDoubleQuote = false;
    int braceDepth = 0;

    for (var i = 0; i < inner.length; i++) {
      final ch = inner[i];
      if (ch == "'" && !inDoubleQuote) {
        inSingleQuote = !inSingleQuote;
      } else if (ch == '"' && !inSingleQuote) {
        inDoubleQuote = !inDoubleQuote;
      } else if (!inSingleQuote && !inDoubleQuote) {
        if (ch == '{' || ch == '[') braceDepth++;
        if (ch == '}' || ch == ']') braceDepth--;
        if (ch == ',' && braceDepth == 0) {
          parts.add(sb.toString());
          sb.clear();
          continue;
        }
      }
      sb.write(ch);
    }
    if (sb.isNotEmpty) parts.add(sb.toString());

    for (final p in parts) {
      _parseYamlKeyValueInto(p.trim(), map);
    }
    return map;
  }

  static void _parseYamlKeyValueInto(String line, Map<String, String> target) {
    final colonIdx = line.indexOf(':');
    if (colonIdx <= 0) return;
    final key = line.substring(0, colonIdx).trim();
    var val = line.substring(colonIdx + 1).trim();
    if ((val.startsWith('"') && val.endsWith('"')) ||
        (val.startsWith("'") && val.endsWith("'"))) {
      if (val.length >= 2) {
        val = val.substring(1, val.length - 1);
      }
    }
    target[key] = val;
  }

  static ProxyNode? _clashMapToNode(
    Map<String, String> map, {
    required String subscriptionId,
    required int indexHint,
  }) {
    final name = (map['name'] ?? '').trim();
    final server = (map['server'] ?? '').trim();
    final port = int.tryParse((map['port'] ?? '').trim()) ?? 0;
    if (server.isEmpty || port <= 0) return null;

    var proto = (map['type'] ?? 'ss').trim().toLowerCase();
    if (proto == 'shadowsocks') proto = 'ss';
    if (proto == 'socks') proto = 'socks5';
    if (proto == 'hy2') proto = 'hysteria2';

    final password = (map['password'] ?? map['uuid'] ?? '').trim();
    final username = (map['username'] ?? '').trim();
    final cipher = (map['cipher'] ?? 'aes-256-gcm').trim();
    final sni = (map['sni'] ?? map['servername'] ?? '').trim();
    final skipCert = map['skip-cert-verify'] != 'false';
    final network = (map['network'] ?? 'tcp').trim();
    final tls =
        map['tls'] == 'true' || proto == 'trojan' || proto == 'hysteria2';

    var wsPath = (map['path'] ?? map['ws-path'] ?? '').trim();
    var wsHost = (map['Host'] ?? map['host'] ?? '').trim();
    final wsOpts = (map['ws-opts'] ?? '').trim();
    if (wsOpts.isNotEmpty) {
      final pathMatch = RegExp(r'path\s*:\s*([^,\}\s]+)').firstMatch(wsOpts);
      if (pathMatch != null && wsPath.isEmpty) {
        wsPath = pathMatch.group(1)!.trim().replaceAll('"', '').replaceAll("'", '');
      }
      final hostMatch =
          RegExp(r'Host\s*:\s*([^,\}\s]+)', caseSensitive: false)
              .firstMatch(wsOpts);
      if (hostMatch != null && wsHost.isEmpty) {
        wsHost = hostMatch.group(1)!.trim().replaceAll('"', '').replaceAll("'", '');
      }
    }

    return ProxyNode(
      id: _buildStableNodeId(
          subscriptionId, proto, server, port, name, indexHint),
      subscriptionId: subscriptionId,
      name: name.isNotEmpty ? name : '${proto.toUpperCase()} $server:$port',
      protocol: proto,
      server: server,
      port: port,
      username: username,
      password: password,
      cipher: cipher,
      sni: sni,
      skipCertVerify: skipCert,
      network: network,
      wsPath: wsPath,
      wsHost: wsHost,
      tls: tls,
    );
  }

  static List<ProxyNode> _parseJsonProxies(
    String jsonText,
    String subscriptionId,
  ) {
    final nodes = <ProxyNode>[];
    try {
      final decoded = jsonDecode(jsonText);
      List<dynamic>? list;
      if (decoded is List) {
        list = decoded;
      } else if (decoded is Map) {
        list = (decoded['servers'] ?? decoded['proxies'] ?? decoded['nodes'])
            as List?;
      }
      if (list == null) return const [];
      for (var i = 0; i < list.length; i++) {
        final item = list[i];
        if (item is! Map) continue;
        final server =
            (item['server'] ?? item['host'] ?? item['add'] ?? '').toString().trim();
        final port = int.tryParse(
                (item['server_port'] ?? item['port'] ?? 0).toString()) ??
            0;
        if (server.isEmpty || port <= 0) continue;
        final name =
            (item['remarks'] ?? item['name'] ?? item['ps'] ?? '节点 ${i + 1}')
                .toString()
                .trim();
        final protocol =
            (item['type'] ?? item['protocol'] ?? 'ss').toString().toLowerCase();
        final password =
            (item['password'] ?? item['uuid'] ?? item['id'] ?? '').toString();
        final cipher =
            (item['method'] ?? item['cipher'] ?? 'aes-256-gcm').toString();
        nodes.add(
          ProxyNode(
            id: _buildStableNodeId(
                subscriptionId, protocol, server, port, name, i),
            subscriptionId: subscriptionId,
            name: name,
            protocol: protocol,
            server: server,
            port: port,
            password: password,
            cipher: cipher,
          ),
        );
      }
    } catch (_) {}
    return nodes;
  }

  static String _buildStableNodeId(
    String subId,
    String proto,
    String server,
    int port,
    String name,
    int indexHint,
  ) {
    final raw = '$subId|$proto|$server|$port|$name|$indexHint';
    var hash = 0x811c9dc5;
    for (final code in raw.codeUnits) {
      hash ^= code;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return 'node_${subId}_${hash.toRadixString(16)}';
  }
}

/// Pure-Dart SHA-224 implementation for RFC-compliant Trojan protocol authentication
/// (`hex(SHA224(password)) + "\r\n"`).
class _Sha224 {
  static const List<int> _k = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  static int _rotr(int x, int n) => ((x & 0xffffffff) >>> n) | ((x << (32 - n)) & 0xffffffff);

  static String hexDigest(String input) {
    final msg = utf8.encode(input);
    final bitLen = msg.length * 8;
    final padLen = ((56 - (msg.length + 1) % 64) + 64) % 64;
    final totalLen = msg.length + 1 + padLen + 8;
    final buf = Uint8List(totalLen);
    buf.setRange(0, msg.length, msg);
    buf[msg.length] = 0x80;
    final bd = ByteData.sublistView(buf);
    bd.setUint32(totalLen - 8, (bitLen ~/ 0x100000000) & 0xffffffff, Endian.big);
    bd.setUint32(totalLen - 4, bitLen & 0xffffffff, Endian.big);

    var h0 = 0xc1059ed8;
    var h1 = 0x367cd507;
    var h2 = 0x3070dd17;
    var h3 = 0xf70e5939;
    var h4 = 0xffc00b31;
    var h5 = 0x68581511;
    var h6 = 0x64f98fa7;
    var h7 = 0xbefa4fa4;

    final w = List<int>.filled(64, 0);
    for (var offset = 0; offset < totalLen; offset += 64) {
      for (var i = 0; i < 16; i++) {
        w[i] = bd.getUint32(offset + i * 4, Endian.big);
      }
      for (var i = 16; i < 64; i++) {
        final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ ((w[i - 15] & 0xffffffff) >>> 3);
        final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ ((w[i - 2] & 0xffffffff) >>> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
      }

      var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
      for (var i = 0; i < 64; i++) {
        final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
        final ch = (e & f) ^ ((~e & 0xffffffff) & g);
        final temp1 = (h + s1 + ch + _k[i] + w[i]) & 0xffffffff;
        final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final temp2 = (s0 + maj) & 0xffffffff;

        h = g;
        g = f;
        f = e;
        e = (d + temp1) & 0xffffffff;
        d = c;
        c = b;
        b = a;
        a = (temp1 + temp2) & 0xffffffff;
      }

      h0 = (h0 + a) & 0xffffffff;
      h1 = (h1 + b) & 0xffffffff;
      h2 = (h2 + c) & 0xffffffff;
      h3 = (h3 + d) & 0xffffffff;
      h4 = (h4 + e) & 0xffffffff;
      h5 = (h5 + f) & 0xffffffff;
      h6 = (h6 + g) & 0xffffffff;
      h7 = (h7 + h) & 0xffffffff;
    }

    final words = [h0, h1, h2, h3, h4, h5, h6];
    final sb = StringBuffer();
    for (final word in words) {
      sb.write(word.toUnsigned(32).toRadixString(16).padLeft(8, '0'));
    }
    return sb.toString();
  }
}

/// Pure-Dart cryptographic primitives for Shadowsocks AEAD (`chacha20-ietf-poly1305`,
/// `aes-128-gcm`, `aes-256-gcm`), `EVP_BytesToKey` (MD5), and `HKDF-SHA1` (`ss-subkey`).
class _SsCrypto {
  static final Random _rng = Random.secure();

  static Uint8List randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _rng.nextInt(256);
    }
    return out;
  }

  static int _rotl32(int x, int n) =>
      ((x << n) & 0xffffffff) | ((x & 0xffffffff) >>> (32 - n));

  static Uint8List md5(List<int> input) {
    const s = <int>[
      7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
      5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
      4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
      6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ];
    const k = <int>[
      0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
      0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
      0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
      0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
      0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
      0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
      0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
      0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
      0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
      0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
      0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
      0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
      0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
      0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
      0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
      0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ];

    final bitLen = input.length * 8;
    final padLen = ((56 - (input.length + 1) % 64) + 64) % 64;
    final totalLen = input.length + 1 + padLen + 8;
    final buf = Uint8List(totalLen);
    buf.setRange(0, input.length, input);
    buf[input.length] = 0x80;
    final bd = ByteData.sublistView(buf);
    bd.setUint32(totalLen - 8, bitLen & 0xffffffff, Endian.little);
    bd.setUint32(totalLen - 4, (bitLen ~/ 0x100000000) & 0xffffffff, Endian.little);

    var a0 = 0x67452301;
    var b0 = 0xefcdab89;
    var c0 = 0x98badcfe;
    var d0 = 0x10325476;

    final m = List<int>.filled(16, 0);
    for (var offset = 0; offset < totalLen; offset += 64) {
      for (var i = 0; i < 16; i++) {
        m[i] = bd.getUint32(offset + i * 4, Endian.little);
      }
      var a = a0, b = b0, c = c0, d = d0;
      for (var i = 0; i < 64; i++) {
        int f, g;
        if (i < 16) {
          f = (b & c) | ((~b & 0xffffffff) & d);
          g = i;
        } else if (i < 32) {
          f = (d & b) | ((~d & 0xffffffff) & c);
          g = (5 * i + 1) % 16;
        } else if (i < 48) {
          f = b ^ c ^ d;
          g = (3 * i + 5) % 16;
        } else {
          f = c ^ (b | (~d & 0xffffffff));
          g = (7 * i) % 16;
        }
        final temp = d;
        d = c;
        c = b;
        final sum = (a + f + k[i] + m[g]) & 0xffffffff;
        b = (b + _rotl32(sum, s[i])) & 0xffffffff;
        a = temp;
      }
      a0 = (a0 + a) & 0xffffffff;
      b0 = (b0 + b) & 0xffffffff;
      c0 = (c0 + c) & 0xffffffff;
      d0 = (d0 + d) & 0xffffffff;
    }

    final out = Uint8List(16);
    final outBd = ByteData.sublistView(out);
    outBd.setUint32(0, a0, Endian.little);
    outBd.setUint32(4, b0, Endian.little);
    outBd.setUint32(8, c0, Endian.little);
    outBd.setUint32(12, d0, Endian.little);
    return out;
  }

  /// Standard Shadowsocks `EVP_BytesToKey` password-to-master-key derivation.
  static Uint8List evpBytesToKey(String password, int keyLen) {
    final passBytes = utf8.encode(password);
    final result = <int>[];
    Uint8List? prev;
    while (result.length < keyLen) {
      final blockInput = prev == null ? passBytes : <int>[...prev, ...passBytes];
      prev = md5(blockInput);
      result.addAll(prev);
    }
    return Uint8List.fromList(result.sublist(0, keyLen));
  }

  static Uint8List sha1(List<int> input) {
    final bitLen = input.length * 8;
    final padLen = ((56 - (input.length + 1) % 64) + 64) % 64;
    final totalLen = input.length + 1 + padLen + 8;
    final buf = Uint8List(totalLen);
    buf.setRange(0, input.length, input);
    buf[input.length] = 0x80;
    final bd = ByteData.sublistView(buf);
    bd.setUint32(totalLen - 8, (bitLen ~/ 0x100000000) & 0xffffffff, Endian.big);
    bd.setUint32(totalLen - 4, bitLen & 0xffffffff, Endian.big);

    var h0 = 0x67452301;
    var h1 = 0xefcdab89;
    var h2 = 0x98badcfe;
    var h3 = 0x10325476;
    var h4 = 0xc3d2e1f0;

    final w = List<int>.filled(80, 0);
    for (var offset = 0; offset < totalLen; offset += 64) {
      for (var i = 0; i < 16; i++) {
        w[i] = bd.getUint32(offset + i * 4, Endian.big);
      }
      for (var i = 16; i < 80; i++) {
        w[i] = _rotl32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
      }
      var a = h0, b = h1, c = h2, d = h3, e = h4;
      for (var i = 0; i < 80; i++) {
        int f, k;
        if (i < 20) {
          f = (b & c) | ((~b & 0xffffffff) & d);
          k = 0x5a827999;
        } else if (i < 40) {
          f = b ^ c ^ d;
          k = 0x6ed9eba1;
        } else if (i < 60) {
          f = (b & c) | (b & d) | (c & d);
          k = 0x8f1bbcdc;
        } else {
          f = b ^ c ^ d;
          k = 0xca62c1d6;
        }
        final temp = (_rotl32(a, 5) + f + e + k + w[i]) & 0xffffffff;
        e = d;
        d = c;
        c = _rotl32(b, 30);
        b = a;
        a = temp;
      }
      h0 = (h0 + a) & 0xffffffff;
      h1 = (h1 + b) & 0xffffffff;
      h2 = (h2 + c) & 0xffffffff;
      h3 = (h3 + d) & 0xffffffff;
      h4 = (h4 + e) & 0xffffffff;
    }

    final out = Uint8List(20);
    final outBd = ByteData.sublistView(out);
    outBd.setUint32(0, h0, Endian.big);
    outBd.setUint32(4, h1, Endian.big);
    outBd.setUint32(8, h2, Endian.big);
    outBd.setUint32(12, h3, Endian.big);
    outBd.setUint32(16, h4, Endian.big);
    return out;
  }

  static Uint8List hmacSha1(Uint8List key, List<int> message) {
    var k = key;
    if (k.length > 64) {
      k = sha1(k);
    }
    final ipad = Uint8List(64);
    final opad = Uint8List(64);
    for (var i = 0; i < 64; i++) {
      final b = i < k.length ? k[i] : 0;
      ipad[i] = b ^ 0x36;
      opad[i] = b ^ 0x5c;
    }
    final inner = sha1(<int>[...ipad, ...message]);
    return sha1(<int>[...opad, ...inner]);
  }

  /// HKDF-SHA1 (`ss-subkey`) derivation per Shadowsocks AEAD specification.
  static Uint8List deriveSsSubkey(Uint8List masterKey, Uint8List salt, int keyLen) {
    final prk = hmacSha1(salt, masterKey);
    final info = ascii.encode('ss-subkey');
    final okm = <int>[];
    Uint8List prev = Uint8List(0);
    var counter = 1;
    while (okm.length < keyLen) {
      prev = hmacSha1(prk, <int>[...prev, ...info, counter]);
      okm.addAll(prev);
      counter++;
    }
    return Uint8List.fromList(okm.sublist(0, keyLen));
  }

  static void _chachaQuarterRound(List<int> s, int a, int b, int c, int d) {
    s[a] = (s[a] + s[b]) & 0xffffffff;
    s[d] = _rotl32(s[d] ^ s[a], 16);
    s[c] = (s[c] + s[d]) & 0xffffffff;
    s[b] = _rotl32(s[b] ^ s[c], 12);
    s[a] = (s[a] + s[b]) & 0xffffffff;
    s[d] = _rotl32(s[d] ^ s[a], 8);
    s[c] = (s[c] + s[d]) & 0xffffffff;
    s[b] = _rotl32(s[b] ^ s[c], 7);
  }

  static Uint8List _chacha20Block(Uint8List key, int counter, Uint8List nonce) {
    final state = List<int>.filled(16, 0);
    state[0] = 0x61707865;
    state[1] = 0x3320646e;
    state[2] = 0x79622d32;
    state[3] = 0x6b206574;
    final keyBd = ByteData.sublistView(key);
    for (var i = 0; i < 8; i++) {
      state[4 + i] = keyBd.getUint32(i * 4, Endian.little);
    }
    state[12] = counter & 0xffffffff;
    final nonceBd = ByteData.sublistView(nonce);
    state[13] = nonceBd.getUint32(0, Endian.little);
    state[14] = nonceBd.getUint32(4, Endian.little);
    state[15] = nonceBd.getUint32(8, Endian.little);

    final working = List<int>.from(state);
    for (var i = 0; i < 10; i++) {
      _chachaQuarterRound(working, 0, 4, 8, 12);
      _chachaQuarterRound(working, 1, 5, 9, 13);
      _chachaQuarterRound(working, 2, 6, 10, 14);
      _chachaQuarterRound(working, 3, 7, 11, 15);
      _chachaQuarterRound(working, 0, 5, 10, 15);
      _chachaQuarterRound(working, 1, 6, 11, 12);
      _chachaQuarterRound(working, 2, 7, 8, 13);
      _chachaQuarterRound(working, 3, 4, 9, 14);
    }

    final out = Uint8List(64);
    final outBd = ByteData.sublistView(out);
    for (var i = 0; i < 16; i++) {
      outBd.setUint32(i * 4, (working[i] + state[i]) & 0xffffffff, Endian.little);
    }
    return out;
  }

  static Uint8List _chacha20Xor(
    Uint8List key,
    int initialCounter,
    Uint8List nonce,
    Uint8List input,
  ) {
    final out = Uint8List(input.length);
    var counter = initialCounter;
    for (var offset = 0; offset < input.length; offset += 64) {
      final block = _chacha20Block(key, counter++, nonce);
      final end = min(offset + 64, input.length);
      for (var i = offset; i < end; i++) {
        out[i] = input[i] ^ block[i - offset];
      }
    }
    return out;
  }

  static Uint8List _poly1305Mac(Uint8List msg, Uint8List otk) {
    final rBytes = Uint8List.fromList(otk.sublist(0, 16));
    rBytes[3] &= 15;
    rBytes[7] &= 15;
    rBytes[11] &= 15;
    rBytes[15] &= 15;
    rBytes[4] &= 252;
    rBytes[8] &= 252;
    rBytes[12] &= 252;

    BigInt leBytesToBigInt(List<int> bytes) {
      var res = BigInt.zero;
      for (var i = bytes.length - 1; i >= 0; i--) {
        res = (res << 8) | BigInt.from(bytes[i]);
      }
      return res;
    }

    final r = leBytesToBigInt(rBytes);
    final s = leBytesToBigInt(otk.sublist(16, 32));
    final p = (BigInt.one << 130) - BigInt.from(5);
    var acc = BigInt.zero;

    for (var offset = 0; offset < msg.length; offset += 16) {
      final end = min(offset + 16, msg.length);
      final chunk = <int>[...msg.sublist(offset, end), 0x01];
      final n = leBytesToBigInt(chunk);
      acc = ((acc + n) * r) % p;
    }
    acc = acc + s;
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = (acc & BigInt.from(0xff)).toInt();
      acc = acc >> 8;
    }
    return out;
  }

  static Uint8List chacha20Poly1305Encrypt(
    Uint8List key,
    Uint8List nonce,
    Uint8List plaintext,
  ) {
    final otk = _chacha20Block(key, 0, nonce).sublist(0, 32);
    final ciphertext = _chacha20Xor(key, 1, nonce, plaintext);
    final padLen = (16 - (ciphertext.length % 16)) % 16;
    final macData = Uint8List(ciphertext.length + padLen + 16);
    macData.setRange(0, ciphertext.length, ciphertext);
    final bd = ByteData.sublistView(macData);
    bd.setUint64(ciphertext.length + padLen, 0, Endian.little);
    bd.setUint64(ciphertext.length + padLen + 8, ciphertext.length, Endian.little);
    final tag = _poly1305Mac(macData, otk);
    final out = Uint8List(ciphertext.length + 16);
    out.setRange(0, ciphertext.length, ciphertext);
    out.setRange(ciphertext.length, out.length, tag);
    return out;
  }

  static Uint8List? chacha20Poly1305Decrypt(
    Uint8List key,
    Uint8List nonce,
    Uint8List ciphertextWithTag,
  ) {
    if (ciphertextWithTag.length < 16) return null;
    final ctLen = ciphertextWithTag.length - 16;
    final ciphertext = ciphertextWithTag.sublist(0, ctLen);
    final tag = ciphertextWithTag.sublist(ctLen);
    final otk = _chacha20Block(key, 0, nonce).sublist(0, 32);
    final padLen = (16 - (ciphertext.length % 16)) % 16;
    final macData = Uint8List(ciphertext.length + padLen + 16);
    macData.setRange(0, ciphertext.length, ciphertext);
    final bd = ByteData.sublistView(macData);
    bd.setUint64(ciphertext.length + padLen, 0, Endian.little);
    bd.setUint64(ciphertext.length + padLen + 8, ciphertext.length, Endian.little);
    final expectedTag = _poly1305Mac(macData, otk);
    var diff = 0;
    for (var i = 0; i < 16; i++) {
      diff |= tag[i] ^ expectedTag[i];
    }
    if (diff != 0) return null;
    return _chacha20Xor(key, 1, nonce, ciphertext);
  }

  // ---------------------------------------------------------------------------
  // Pure-Dart AES-128-GCM / AES-192-GCM / AES-256-GCM (NIST SP 800-38D)
  // ---------------------------------------------------------------------------

  static const List<int> _aesSbox = <int>[
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
  ];

  static const List<int> _aesRcon = <int>[
    0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36,
  ];

  static ({Uint8List w, int nr}) _aesExpandKey(Uint8List key) {
    final nk = key.length ~/ 4;
    final nr = nk + 6;
    final totalWords = 4 * (nr + 1);
    final w = Uint8List(totalWords * 4);
    w.setRange(0, key.length, key);

    final temp = Uint8List(4);
    for (var i = nk; i < totalWords; i++) {
      final prevOffset = (i - 1) * 4;
      temp[0] = w[prevOffset];
      temp[1] = w[prevOffset + 1];
      temp[2] = w[prevOffset + 2];
      temp[3] = w[prevOffset + 3];

      if (i % nk == 0) {
        final t = temp[0];
        temp[0] = _aesSbox[temp[1]] ^ _aesRcon[i ~/ nk];
        temp[1] = _aesSbox[temp[2]];
        temp[2] = _aesSbox[temp[3]];
        temp[3] = _aesSbox[t];
      } else if (nk > 6 && i % nk == 4) {
        temp[0] = _aesSbox[temp[0]];
        temp[1] = _aesSbox[temp[1]];
        temp[2] = _aesSbox[temp[2]];
        temp[3] = _aesSbox[temp[3]];
      }

      final nkOffset = (i - nk) * 4;
      final curOffset = i * 4;
      w[curOffset] = w[nkOffset] ^ temp[0];
      w[curOffset + 1] = w[nkOffset + 1] ^ temp[1];
      w[curOffset + 2] = w[nkOffset + 2] ^ temp[2];
      w[curOffset + 3] = w[nkOffset + 3] ^ temp[3];
    }
    return (w: w, nr: nr);
  }

  static int _xtime(int x) => ((x << 1) ^ (((x >> 7) & 1) * 0x1b)) & 0xff;

  static Uint8List _aesEncryptBlock(Uint8List w, int nr, Uint8List block16) {
    final s = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      s[i] = block16[i] ^ w[i];
    }

    for (var round = 1; round < nr; round++) {
      for (var i = 0; i < 16; i++) {
        s[i] = _aesSbox[s[i]];
      }
      // ShiftRows
      final t1 = s[1];
      s[1] = s[5];
      s[5] = s[9];
      s[9] = s[13];
      s[13] = t1;

      final t2 = s[2], t6 = s[6];
      s[2] = s[10];
      s[6] = s[14];
      s[10] = t2;
      s[14] = t6;

      final t15 = s[15];
      s[15] = s[11];
      s[11] = s[7];
      s[7] = s[3];
      s[3] = t15;

      // MixColumns
      for (var c = 0; c < 16; c += 4) {
        final a0 = s[c], a1 = s[c + 1], a2 = s[c + 2], a3 = s[c + 3];
        final t = a0 ^ a1 ^ a2 ^ a3;
        s[c] ^= t ^ _xtime(a0 ^ a1);
        s[c + 1] ^= t ^ _xtime(a1 ^ a2);
        s[c + 2] ^= t ^ _xtime(a2 ^ a3);
        s[c + 3] ^= t ^ _xtime(a3 ^ a0);
      }

      // AddRoundKey
      final rkOffset = round * 16;
      for (var i = 0; i < 16; i++) {
        s[i] ^= w[rkOffset + i];
      }
    }

    // Final Round
    for (var i = 0; i < 16; i++) {
      s[i] = _aesSbox[s[i]];
    }
    final t1 = s[1];
    s[1] = s[5];
    s[5] = s[9];
    s[9] = s[13];
    s[13] = t1;

    final t2 = s[2], t6 = s[6];
    s[2] = s[10];
    s[6] = s[14];
    s[10] = t2;
    s[14] = t6;

    final t15 = s[15];
    s[15] = s[11];
    s[11] = s[7];
    s[7] = s[3];
    s[3] = t15;

    final rkOffset = nr * 16;
    for (var i = 0; i < 16; i++) {
      s[i] ^= w[rkOffset + i];
    }
    return s;
  }

  static Uint8List _ghash(Uint8List h, Uint8List ciphertext) {
    final hBd = ByteData.sublistView(h);
    final h0 = hBd.getUint32(0, Endian.big);
    final h1 = hBd.getUint32(4, Endian.big);
    final h2 = hBd.getUint32(8, Endian.big);
    final h3 = hBd.getUint32(12, Endian.big);

    var y0 = 0, y1 = 0, y2 = 0, y3 = 0;

    void gfMulBlock() {
      var z0 = 0, z1 = 0, z2 = 0, z3 = 0;
      var v0 = h0, v1 = h1, v2 = h2, v3 = h3;
      for (var wIdx = 0; wIdx < 4; wIdx++) {
        final word =
            wIdx == 0 ? y0 : (wIdx == 1 ? y1 : (wIdx == 2 ? y2 : y3));
        for (var bit = 31; bit >= 0; bit--) {
          if ((word & (1 << bit)) != 0) {
            z0 ^= v0;
            z1 ^= v1;
            z2 ^= v2;
            z3 ^= v3;
          }
          final lsb = v3 & 1;
          v3 = ((v3 >>> 1) | ((v2 & 1) << 31)) & 0xffffffff;
          v2 = ((v2 >>> 1) | ((v1 & 1) << 31)) & 0xffffffff;
          v1 = ((v1 >>> 1) | ((v0 & 1) << 31)) & 0xffffffff;
          v0 = (v0 >>> 1) & 0xffffffff;
          if (lsb != 0) {
            v0 ^= 0xe1000000;
          }
        }
      }
      y0 = z0;
      y1 = z1;
      y2 = z2;
      y3 = z3;
    }

    final ctLen = ciphertext.length;
    final fullEnd = ctLen & ~15;
    final ctBd = ByteData.sublistView(ciphertext);
    for (var offset = 0; offset < fullEnd; offset += 16) {
      y0 ^= ctBd.getUint32(offset, Endian.big);
      y1 ^= ctBd.getUint32(offset + 4, Endian.big);
      y2 ^= ctBd.getUint32(offset + 8, Endian.big);
      y3 ^= ctBd.getUint32(offset + 12, Endian.big);
      gfMulBlock();
    }
    if (fullEnd < ctLen) {
      final tail = Uint8List(16);
      for (var i = fullEnd; i < ctLen; i++) {
        tail[i - fullEnd] = ciphertext[i];
      }
      final tailBd = ByteData.sublistView(tail);
      y0 ^= tailBd.getUint32(0, Endian.big);
      y1 ^= tailBd.getUint32(4, Endian.big);
      y2 ^= tailBd.getUint32(8, Endian.big);
      y3 ^= tailBd.getUint32(12, Endian.big);
      gfMulBlock();
    }

    // Length block: 64-bit AAD length (0) || 64-bit ciphertext bit length
    final bitLen = ctLen * 8;
    y2 ^= (bitLen ~/ 0x100000000) & 0xffffffff;
    y3 ^= bitLen & 0xffffffff;
    gfMulBlock();

    final out = Uint8List(16);
    final outBd = ByteData.sublistView(out);
    outBd.setUint32(0, y0, Endian.big);
    outBd.setUint32(4, y1, Endian.big);
    outBd.setUint32(8, y2, Endian.big);
    outBd.setUint32(12, y3, Endian.big);
    return out;
  }

  static Uint8List _aesCtrXor(
    Uint8List w,
    int nr,
    Uint8List nonce12,
    int startCounter,
    Uint8List input,
  ) {
    final out = Uint8List(input.length);
    final cb = Uint8List(16);
    cb.setRange(0, 12, nonce12);
    final cbBd = ByteData.sublistView(cb);
    var counter = startCounter;
    for (var offset = 0; offset < input.length; offset += 16) {
      cbBd.setUint32(12, counter & 0xffffffff, Endian.big);
      counter++;
      final ks = _aesEncryptBlock(w, nr, cb);
      final end = min(offset + 16, input.length);
      for (var i = offset; i < end; i++) {
        out[i] = input[i] ^ ks[i - offset];
      }
    }
    return out;
  }

  static Uint8List aesGcmEncrypt(
    Uint8List key,
    Uint8List nonce,
    Uint8List plaintext,
  ) {
    final expanded = _aesExpandKey(key);
    final h = _aesEncryptBlock(expanded.w, expanded.nr, Uint8List(16));
    final j0 = Uint8List(16)..setRange(0, 12, nonce)..[15] = 1;
    final encJ0 = _aesEncryptBlock(expanded.w, expanded.nr, j0);
    final ciphertext = _aesCtrXor(expanded.w, expanded.nr, nonce, 2, plaintext);
    final ghashTag = _ghash(h, ciphertext);
    final out = Uint8List(ciphertext.length + 16);
    out.setRange(0, ciphertext.length, ciphertext);
    for (var i = 0; i < 16; i++) {
      out[ciphertext.length + i] = ghashTag[i] ^ encJ0[i];
    }
    return out;
  }

  static Uint8List? aesGcmDecrypt(
    Uint8List key,
    Uint8List nonce,
    Uint8List ciphertextWithTag,
  ) {
    if (ciphertextWithTag.length < 16) return null;
    final ctLen = ciphertextWithTag.length - 16;
    final ciphertext = ciphertextWithTag.sublist(0, ctLen);
    final tag = ciphertextWithTag.sublist(ctLen);
    final expanded = _aesExpandKey(key);
    final h = _aesEncryptBlock(expanded.w, expanded.nr, Uint8List(16));
    final j0 = Uint8List(16)..setRange(0, 12, nonce)..[15] = 1;
    final encJ0 = _aesEncryptBlock(expanded.w, expanded.nr, j0);
    final ghashTag = _ghash(h, ciphertext);
    var diff = 0;
    for (var i = 0; i < 16; i++) {
      diff |= tag[i] ^ (ghashTag[i] ^ encJ0[i]);
    }
    if (diff != 0) return null;
    return _aesCtrXor(expanded.w, expanded.nr, nonce, 2, ciphertext);
  }
}

/// Abstract bi-directional upstream proxy tunnel (supporting raw TCP/TLS sockets
/// as well as encrypted framed streams like Shadowsocks AEAD).
class _UpstreamTunnel {
  final void Function(List<int> data) send;
  final Stream<Uint8List> stream;
  final void Function() close;

  const _UpstreamTunnel({
    required this.send,
    required this.stream,
    required this.close,
  });
}

/// Local loopback HTTP proxy bridge (`127.0.0.1:<ephemeralPort>`) that allows
/// Dart `HttpClient` and `media_kit` (`libmpv`) to transparently tunnel through
/// HTTP, HTTPS, SOCKS5, Trojan (with SNI), VLESS (WS/TCP), and Shadowsocks AEAD proxy nodes,
/// and provides a pooled keep-alive local HLS/media relay (`/__m3u8_proxy__/...`).
class LocalProxyTunnelBridge {
  ServerSocket? _serverSocket;
  final ProxyNode? Function() _resolveDefaultNode;
  final List<ProxyNode> Function()? _resolveFallbackNodes;
  final void Function(String nodeId, {required bool success, int? rttMs})?
      _onNodeFeedback;

  final Map<String, HttpClient> _streamRelayClientsByNodeId =
      <String, HttpClient>{};
  HttpClient? _directRelayHttpClient;

  /// Multi-connection concurrent HLS segment prefetching & parallel chunk state.
  static const int maxConcurrentPrefetchWorkers = 4;
  static const int prefetchLookaheadCount = 4;
  static const int _maxPrefetchCacheSegments = 20;
  static const int _maxPrefetchCacheBytes = 40 * 1024 * 1024;
  static const int _parallelRangeChunkConnections = 3;
  static const int _parallelRangeThresholdBytes = 1536 * 1024;

  List<String> _playlistSegmentUrls = <String>[];
  final Map<String, int> _playlistSegmentIndexMap = <String, int>{};
  final LinkedHashMap<String, ({Uint8List bytes, String contentType, int timestampMs})>
      _prefetchedSegmentCache =
      LinkedHashMap<String, ({Uint8List bytes, String contentType, int timestampMs})>();
  int _prefetchedCacheTotalBytes = 0;
  final Map<String, Future<({Uint8List bytes, String contentType})?>>
      _inFlightSegmentFetches =
      <String, Future<({Uint8List bytes, String contentType})?>>{};
  final Queue<
      ({
        String url,
        Map<String, String> headers,
        bool forceDirect,
        List<ProxyNode> candidateNodes,
      })> _pendingPrefetchQueue = Queue();
  int _activePrefetchWorkers = 0;

  int get prefetchedSegmentCount => _prefetchedSegmentCache.length;
  int get activePrefetchWorkerCount => _activePrefetchWorkers;

  LocalProxyTunnelBridge({
    required ProxyNode? Function() resolveDefaultNode,
    List<ProxyNode> Function()? resolveFallbackNodes,
    void Function(String nodeId, {required bool success, int? rttMs})?
        onNodeFeedback,
  })  : _resolveDefaultNode = resolveDefaultNode,
        _resolveFallbackNodes = resolveFallbackNodes,
        _onNodeFeedback = onNodeFeedback;

  int get port => _serverSocket?.port ?? 0;
  bool get isRunning => _serverSocket != null;

  static final List<({int timestampMs, int bytes})> _downstreamSamples = [];

  static void recordDownstreamBytes(int bytes) {
    if (bytes <= 0) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _downstreamSamples.add((timestampMs: nowMs, bytes: bytes));
    if (_downstreamSamples.length > 512) {
      final cutoff = nowMs - 2000;
      _downstreamSamples.removeWhere((s) => s.timestampMs < cutoff);
    }
  }

  /// Returns the real-time downstream transfer speed (in bytes/sec) across
  /// active local proxy tunnels and `/__m3u8_proxy__` stream relays over the last 1.5s.
  static double get recentDownstreamBytesPerSecond {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final cutoff = nowMs - 1500;
    _downstreamSamples.removeWhere((s) => s.timestampMs < cutoff);
    if (_downstreamSamples.isEmpty) return 0.0;
    var totalBytes = 0;
    for (final s in _downstreamSamples) {
      totalBytes += s.bytes;
    }
    return totalBytes / 1.5;
  }

  static String _stripAdsInBackgroundIsolate(Map<String, String> payload) {
    final text = payload['text'] ?? '';
    final baseUri = Uri.tryParse(payload['baseUri'] ?? '') ?? Uri();
    return M3u8AdRemover.stripAdsFromMediaPlaylist(
      text,
      baseUri: baseUri,
    ).cleanedM3u8;
  }

  /// Builds a local HTTP stream relay URL (`http://127.0.0.1:<port>/__m3u8_proxy__/...`)
  /// so `libmpv` can play HLS `.m3u8` / `.ts` / `.mp4` streams over plain local HTTP
  /// while [LocalProxyTunnelBridge] fetches, pools, and concurrently prefetches
  /// upstream segments across multiple parallel connections.
  String buildStreamRelayUrl({
    required String targetUrl,
    Map<String, String> headers = const {},
    bool cleanM3u8Ads = false,
    bool forceDirect = false,
  }) {
    final p = port;
    if (p <= 0) return targetUrl;
    final encodedUrl = base64Url.encode(utf8.encode(targetUrl));
    final cleanHeaders = <String, String>{};
    headers.forEach((k, v) {
      if (k.trim().isNotEmpty && v.trim().isNotEmpty) {
        cleanHeaders[k.trim()] = v.trim();
      }
    });
    final encodedHeaders = cleanHeaders.isEmpty
        ? ''
        : base64Url.encode(utf8.encode(jsonEncode(cleanHeaders)));
    final lower = targetUrl.toLowerCase();
    String suffix = 'stream.bin';
    if (lower.contains('.m3u8')) {
      suffix = 'playlist.m3u8';
    } else if (lower.contains('.ts')) {
      suffix = 'segment.ts';
    } else if (lower.contains('.mp4') ||
        lower.contains('/api/telegram/video')) {
      suffix = 'video.mp4';
    } else if (lower.contains('.key')) {
      suffix = 'enc.key';
    }
    final qp = StringBuffer('u=$encodedUrl');
    if (encodedHeaders.isNotEmpty) {
      qp.write('&h=$encodedHeaders');
    }
    if (cleanM3u8Ads) {
      qp.write('&clean=1');
    }
    if (forceDirect) {
      qp.write('&direct=1');
    }
    return 'http://127.0.0.1:$p/__m3u8_proxy__/$suffix?${qp.toString()}';
  }

  Future<int> ensureStarted() async {
    if (_serverSocket != null) return _serverSocket!.port;
    try {
      _serverSocket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        shared: true,
      );
      _serverSocket!.listen(
        _handleClientSocket,
        onError: (_) {},
        cancelOnError: false,
      );
      return _serverSocket!.port;
    } catch (_) {
      return 0;
    }
  }

  Future<void> stop() async {
    final s = _serverSocket;
    _serverSocket = null;
    _pendingPrefetchQueue.clear();
    _inFlightSegmentFetches.clear();
    _prefetchedSegmentCache.clear();
    _prefetchedCacheTotalBytes = 0;
    for (final hc in _streamRelayClientsByNodeId.values) {
      try {
        hc.close(force: true);
      } catch (_) {}
    }
    _streamRelayClientsByNodeId.clear();
    try {
      _directRelayHttpClient?.close(force: true);
    } catch (_) {}
    _directRelayHttpClient = null;
    try {
      await s?.close();
    } catch (_) {}
  }

  HttpClient _getOrCreateDirectRelayHttpClient() {
    if (_directRelayHttpClient != null) {
      return _directRelayHttpClient!;
    }
    final hc = HttpClient()
      ..idleTimeout = const Duration(seconds: 45)
      ..maxConnectionsPerHost = 12
      ..badCertificateCallback = (cert, host, port) => true;
    _directRelayHttpClient = hc;
    return hc;
  }

  HttpClient _getOrCreateStreamRelayHttpClient(ProxyNode node) {
    final existing = _streamRelayClientsByNodeId[node.id];
    if (existing != null) {
      return existing;
    }
    if (_streamRelayClientsByNodeId.length >= 6) {
      final oldestKey = _streamRelayClientsByNodeId.keys.first;
      final removed = _streamRelayClientsByNodeId.remove(oldestKey);
      try {
        removed?.close(force: false);
      } catch (_) {}
    }

    final hc = HttpClient()
      ..idleTimeout = const Duration(seconds: 45)
      ..maxConnectionsPerHost = 8
      ..badCertificateCallback = (cert, host, port) => true;

    hc.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
      final isHttps = uri.scheme == 'https';
      final targetPort = uri.hasPort ? uri.port : (isHttps ? 443 : 80);
      final socketFuture = _openPooledProxySocket(
        node: node,
        targetHost: uri.host,
        targetPort: targetPort,
        isHttps: isHttps,
        timeout: const Duration(milliseconds: 7000),
      );
      return ConnectionTask.fromSocket(socketFuture, () {});
    };

    _streamRelayClientsByNodeId[node.id] = hc;
    return hc;
  }

  static Future<Socket> _openPooledProxySocket({
    required ProxyNode node,
    required String targetHost,
    required int targetPort,
    required bool isHttps,
    required Duration timeout,
  }) async {
    final proto = node.protocol.toLowerCase();
    if (proto == 'trojan' && node.network.toLowerCase() != 'ws') {
      final rawSocket = await Socket.connect(
        node.server,
        node.port,
        timeout: timeout,
      );
      try {
        rawSocket.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {}
      final sni = node.sni.isNotEmpty
          ? node.sni
          : (node.wsHost.isNotEmpty ? node.wsHost : node.server);
      final tlsSocket = await SecureSocket.secure(
        rawSocket,
        host: sni,
        onBadCertificate: (_) => true,
      ).timeout(timeout);

      final hashHex = _Sha224.hexDigest(node.password);
      final hostBytes = utf8.encode(targetHost);
      final trojanHeader = <int>[
        ...latin1.encode(hashHex),
        0x0d,
        0x0a,
        0x01,
        0x03,
        hostBytes.length,
        ...hostBytes,
        (targetPort >> 8) & 0xff,
        targetPort & 0xff,
        0x0d,
        0x0a,
      ];
      tlsSocket.add(trojanHeader);
      if (isHttps) {
        return SecureSocket.secure(
          tlsSocket,
          host: targetHost,
          onBadCertificate: (_) => true,
        ).timeout(timeout);
      }
      return tlsSocket;
    }

    final tunnel = await _openUpstreamTunnel(
      node: node,
      targetHost: targetHost,
      targetPort: targetPort,
      isConnect: true,
      rawHttpHeaderLines: const [],
      initialBodyBytes: const [],
      timeout: timeout,
    );
    if (tunnel == null) {
      throw SocketException('Failed to open proxy tunnel via ${node.name}');
    }

    final pairServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(
      pairServer.first.then((srvSide) {
        try {
          srvSide.setOption(SocketOption.tcpNoDelay, true);
        } catch (_) {}
        srvSide.listen(
          (d) => tunnel.send(d),
          onDone: () {
            tunnel.close();
            try {
              pairServer.close();
            } catch (_) {}
          },
          onError: (_) {
            tunnel.close();
            try {
              pairServer.close();
            } catch (_) {}
          },
        );
        tunnel.stream.listen(
          (d) {
            try {
              srvSide.add(d);
            } catch (_) {}
          },
          onDone: () {
            try {
              srvSide.destroy();
            } catch (_) {}
            try {
              pairServer.close();
            } catch (_) {}
          },
          onError: (_) {
            try {
              srvSide.destroy();
            } catch (_) {}
            try {
              pairServer.close();
            } catch (_) {}
          },
        );
      }),
    );

    final clientSide = await Socket.connect(
      InternetAddress.loopbackIPv4,
      pairServer.port,
      timeout: timeout,
    );
    try {
      clientSide.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    if (isHttps) {
      return SecureSocket.secure(
        clientSide,
        host: targetHost,
        onBadCertificate: (_) => true,
      ).timeout(timeout);
    }
    return clientSide;
  }

  Future<void> _handleStreamRelayRequest({
    required Socket client,
    required String targetStr,
    required List<String> rawHttpHeaderLines,
    required void Function() cleanup,
  }) async {
    try {
      final reqUri = Uri.tryParse(
        targetStr.startsWith('http')
            ? targetStr
            : 'http://127.0.0.1$targetStr',
      );
      final encodedUrl =
          reqUri?.queryParameters['u'] ?? reqUri?.queryParameters['url'] ?? '';
      if (encodedUrl.isEmpty) {
        client.add(latin1.encode('HTTP/1.1 400 Bad Request\r\n\r\n'));
        await client.flush();
        cleanup();
        return;
      }

      final targetUrl = utf8.decode(
        base64Url.decode(base64Url.normalize(encodedUrl)),
        allowMalformed: true,
      );
      final targetUri = Uri.tryParse(targetUrl);
      if (targetUri == null || targetUri.host.isEmpty) {
        client.add(latin1.encode('HTTP/1.1 400 Bad Request\r\n\r\n'));
        await client.flush();
        cleanup();
        return;
      }

      final customHeaders = <String, String>{};
      final encodedHeaders = reqUri?.queryParameters['h'] ?? '';
      if (encodedHeaders.isNotEmpty) {
        try {
          final decodedJson = utf8.decode(
            base64Url.decode(base64Url.normalize(encodedHeaders)),
            allowMalformed: true,
          );
          final map = jsonDecode(decodedJson);
          if (map is Map) {
            map.forEach((k, v) {
              if (k != null && v != null) {
                customHeaders[k.toString()] = v.toString();
              }
            });
          }
        } catch (_) {}
      }

      String? rangeHeader;
      for (final line in rawHttpHeaderLines.skip(1)) {
        if (line.toLowerCase().startsWith('range:')) {
          rangeHeader = line.substring(6).trim();
          break;
        }
      }

      final cleanAds = reqUri?.queryParameters['clean'] == '1';
      final forceDirect = reqUri?.queryParameters['direct'] == '1';
      final candidateNodes = <ProxyNode>[];
      if (!forceDirect) {
        final primary = _resolveDefaultNode();
        if (primary != null) {
          candidateNodes.add(primary);
        }
        final fallbacks = _resolveFallbackNodes?.call() ?? const <ProxyNode>[];
        for (final fb in fallbacks) {
          if (!candidateNodes.any((n) => n.id == fb.id)) {
            candidateNodes.add(fb);
            if (candidateNodes.length >= 3) break;
          }
        }
      }

      Future<void> finishClientResponse() async {
        try {
          await client.flush();
          await client.close();
        } catch (_) {}
        cleanup();
      }

      if (!forceDirect && candidateNodes.isEmpty) {
        client.add(latin1.encode('HTTP/1.1 502 Bad Gateway\r\n\r\n'));
        await finishClientResponse();
        return;
      }

      // 1. If this request is for a known playlist segment in direct mode,
      // trigger multi-connection concurrent prefetching immediately.
      // In proxy mode (!forceDirect), we defer lookahead prefetch until after
      // the current segment opens/streams so seg[0] gets 100% exclusive proxy
      // bandwidth for instant first-frame rendering!
      final segIndex = _playlistSegmentIndexMap[targetUrl];
      if (segIndex != null && forceDirect) {
        _scheduleLookaheadPrefetch(
          fromIndex: segIndex + 1,
          count: prefetchLookaheadCount,
          customHeaders: customHeaders,
          forceDirect: forceDirect,
          candidateNodes: candidateNodes,
        );
      }

      // 2. Check if this segment was already prefetched into memory by our
      // concurrent background worker threads, or is currently in-flight!
      if (rangeHeader == null || rangeHeader.isEmpty) {
        final cached = _prefetchedSegmentCache[targetUrl];
        if (cached != null) {
          if (segIndex != null && !forceDirect) {
            _scheduleLookaheadPrefetch(
              fromIndex: segIndex + 1,
              count: 4,
              customHeaders: customHeaders,
              forceDirect: forceDirect,
              candidateNodes: candidateNodes,
            );
          }
          final respHeader = StringBuffer()
            ..write('HTTP/1.1 200 OK\r\n')
            ..write('Content-Type: ${cached.contentType}\r\n')
            ..write('Content-Length: ${cached.bytes.length}\r\n')
            ..write('X-MultiThread-Cache: HIT\r\n')
            ..write('Access-Control-Allow-Origin: *\r\n')
            ..write('Connection: close\r\n\r\n');
          client.add(latin1.encode(respHeader.toString()));
          client.add(cached.bytes);
          await finishClientResponse();
          return;
        }

        final inFlight = _inFlightSegmentFetches[targetUrl];
        if (inFlight != null) {
          final awaited = await inFlight;
          if (awaited != null) {
            if (segIndex != null && !forceDirect) {
              _scheduleLookaheadPrefetch(
                fromIndex: segIndex + 1,
                count: 2,
                customHeaders: customHeaders,
                forceDirect: forceDirect,
                candidateNodes: candidateNodes,
              );
            }
            final respHeader = StringBuffer()
              ..write('HTTP/1.1 200 OK\r\n')
              ..write('Content-Type: ${awaited.contentType}\r\n')
              ..write('Content-Length: ${awaited.bytes.length}\r\n')
              ..write('X-MultiThread-Cache: INFLIGHT-HIT\r\n')
              ..write('Access-Control-Allow-Origin: *\r\n')
              ..write('Connection: close\r\n\r\n');
            client.add(latin1.encode(respHeader.toString()));
            client.add(awaited.bytes);
            await finishClientResponse();
            return;
          }
        }
      }

      Future<({HttpClientResponse resp, Uri finalUri, HttpClient hc})?>
          tryOpenDirect(
        Uri uri, {
        String? activeRange,
        Duration timeout = const Duration(milliseconds: 3200),
      }) async {
        for (var attempt = 0; attempt < 2; attempt++) {
          try {
            final hc = _getOrCreateDirectRelayHttpClient();
            final req = await hc.getUrl(uri).timeout(timeout);
            req.headers.set(
              'User-Agent',
              customHeaders['User-Agent'] ??
                  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
            );
            req.headers.set('Accept', '*/*');
            customHeaders.forEach((k, v) {
              if (k.toLowerCase() != 'host') {
                req.headers.set(k, v);
              }
            });
            if (activeRange != null && activeRange.isNotEmpty) {
              req.headers.set('Range', activeRange);
            }
            final resp = await req.close().timeout(timeout);
            if (resp.statusCode >= 200 && resp.statusCode < 400) {
              return (resp: resp, finalUri: uri, hc: hc);
            }
            await resp.drain<void>().timeout(
                  const Duration(milliseconds: 600),
                  onTimeout: () {},
                );
            return null;
          } catch (_) {}
        }
        return null;
      }

      Future<({HttpClientResponse resp, Uri finalUri, HttpClient hc})?>
          tryOpenWithNode(
        ProxyNode node,
        Uri uri, {
        String? activeRange,
        Duration timeout = const Duration(milliseconds: 4200),
      }) async {
        for (var attempt = 0; attempt < 2; attempt++) {
          final sw = Stopwatch()..start();
          try {
            final hc = _getOrCreateStreamRelayHttpClient(node);
            final req = await hc.getUrl(uri).timeout(timeout);
            req.headers.set(
              'User-Agent',
              customHeaders['User-Agent'] ??
                  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
            );
            req.headers.set('Accept', '*/*');
            customHeaders.forEach((k, v) {
              if (k.toLowerCase() != 'host') {
                req.headers.set(k, v);
              }
            });
            if (activeRange != null && activeRange.isNotEmpty) {
              req.headers.set('Range', activeRange);
            }
            final resp = await req.close().timeout(timeout);
            sw.stop();
            if (resp.statusCode >= 200 && resp.statusCode < 400) {
              _onNodeFeedback?.call(
                node.id,
                success: true,
                rttMs: sw.elapsedMilliseconds,
              );
              winningNodeForSession = node;
              return (resp: resp, finalUri: uri, hc: hc);
            }
            await resp.drain<void>().timeout(
                  const Duration(milliseconds: 600),
                  onTimeout: () {},
                );
            _onNodeFeedback?.call(node.id, success: false);
            return null;
          } catch (_) {
            if (attempt == 1) {
              _onNodeFeedback?.call(node.id, success: false);
            }
          }
        }
        return null;
      }

      Future<({HttpClientResponse resp, Uri finalUri, HttpClient hc})?>
          openTargetUri(
        Uri uri, {
        ProxyNode? preferredNode,
        String? overrideRange,
      }) async {
        final activeRange = overrideRange ?? rangeHeader;
        if (forceDirect) {
          final directRes = await tryOpenDirect(uri, activeRange: activeRange);
          if (directRes != null) return directRes;
          // If direct connection failed and user has a default proxy node configured,
          // automatically try the proxy node so blocked overseas streams still play!
          final fallbackNode = _resolveDefaultNode();
          if (fallbackNode != null) {
            return tryOpenWithNode(
              fallbackNode,
              uri,
              activeRange: activeRange,
              timeout: const Duration(milliseconds: 3500),
            );
          }
          return null;
        }

        final nodesToTry = preferredNode != null
            ? <ProxyNode>[
                preferredNode,
                ...candidateNodes.where((n) => n.id != preferredNode.id),
              ]
            : candidateNodes;

        // Happy-Eyeballs fast race when opening a stream for the first time:
        // if primary node takes > 1100ms, race the second candidate node in parallel!
        if (winningNodeForSession == null && nodesToTry.length >= 2) {
          final winnerCompleter = Completer<
              ({HttpClientResponse resp, Uri finalUri, HttpClient hc})?>();
          var pendingCount = 2;
          Timer? staggerTimer;

          void handleCandidateResult(
            ({HttpClientResponse resp, Uri finalUri, HttpClient hc})? res,
          ) {
            pendingCount--;
            if (res != null && !winnerCompleter.isCompleted) {
              staggerTimer?.cancel();
              winnerCompleter.complete(res);
              return;
            }
            if (res != null && winnerCompleter.isCompleted) {
              // Drain losing parallel response cleanly
              unawaited(
                res.resp.drain<void>().timeout(
                      const Duration(milliseconds: 500),
                      onTimeout: () {},
                    ),
              );
            }
            if (pendingCount <= 0 && !winnerCompleter.isCompleted) {
              winnerCompleter.complete(null);
            }
          }

          unawaited(
            tryOpenWithNode(
              nodesToTry[0],
              uri,
              activeRange: activeRange,
            ).then(handleCandidateResult),
          );
          staggerTimer = Timer(const Duration(milliseconds: 1100), () {
            if (!winnerCompleter.isCompleted) {
              unawaited(
                tryOpenWithNode(
                  nodesToTry[1],
                  uri,
                  activeRange: activeRange,
                ).then(handleCandidateResult),
              );
            } else {
              pendingCount--;
            }
          });

          final raced = await winnerCompleter.future;
          staggerTimer.cancel();
          if (raced != null) return raced;

          for (final node in nodesToTry.skip(2)) {
            final res = await tryOpenWithNode(
              node,
              uri,
              activeRange: activeRange,
            );
            if (res != null) return res;
          }
          return null;
        }

        for (final node in nodesToTry) {
          final res = await tryOpenWithNode(
            node,
            uri,
            activeRange: activeRange,
          );
          if (res != null) return res;
        }
        return null;
      }

      final opened = await openTargetUri(targetUri);
      if (opened == null) {
        client.add(latin1.encode('HTTP/1.1 502 Bad Gateway\r\n\r\n'));
        await finishClientResponse();
        return;
      }

      final resp = opened.resp;
      var currentUri = opened.finalUri;
      final mime = resp.headers.contentType?.mimeType.toLowerCase() ?? '';
      final isLikelyM3u8 =
          (resp.contentLength <= 0 || resp.contentLength <= 2 * 1024 * 1024) &&
          (currentUri.path.toLowerCase().endsWith('.m3u8') ||
              (reqUri?.path.toLowerCase().endsWith('.m3u8') ?? false) ||
              mime.contains('mpegurl') ||
              mime.contains('m3u'));

      Uint8List? preBufferedBinaryChunk;
      StreamIterator<List<int>>? activeStreamIterator;

      if (isLikelyM3u8 && resp.statusCode == 200) {
        final m3u8Buf = BytesBuilder(copy: false);
        var verifiedM3u8Header = false;
        var abortedAsBinaryStream = false;
        final iter = StreamIterator<List<int>>(
          resp.timeout(const Duration(seconds: 8)),
        );
        try {
          while (await iter.moveNext()) {
            final chunk = iter.current;
            if (chunk.isEmpty) continue;
            m3u8Buf.add(chunk);
            recordDownstreamBytes(chunk.length);
            if (!verifiedM3u8Header && m3u8Buf.length >= 7) {
              final sample = m3u8Buf.toBytes();
              final headLen = sample.length > 256 ? 256 : sample.length;
              final headText =
                  utf8.decode(sample.sublist(0, headLen), allowMalformed: true).trimLeft();
              if (headText.startsWith('#EXTM3U') || headText.startsWith('#EXT')) {
                verifiedM3u8Header = true;
              } else {
                abortedAsBinaryStream = true;
                break;
              }
            }
            if (m3u8Buf.length > 2 * 1024 * 1024) {
              abortedAsBinaryStream = true;
              break;
            }
          }
        } catch (_) {
          if (!verifiedM3u8Header) {
            abortedAsBinaryStream = true;
          }
        }

        if (!abortedAsBinaryStream && m3u8Buf.length > 0) {
          final rawBytes = m3u8Buf.takeBytes();
          var text = utf8.decode(rawBytes, allowMalformed: true);
          if (text.contains('#EXTM3U')) {
            // Resolve Master Playlist (`#EXT-X-STREAM-INF`) on the same warm keep-alive connection!
            for (var depth = 0; depth < 2; depth++) {
              if (!text.contains('#EXT-X-STREAM-INF')) break;
              final variantUri =
                  M3u8AdRemover.extractBestVariantUri(text, currentUri);
              if (variantUri == null) break;
              final nextOpened = await openTargetUri(
                variantUri,
                preferredNode: winningNodeForSession,
              );
              if (nextOpened == null) break;
              final nextBuf = BytesBuilder(copy: false);
              var nextTooLarge = false;
              await for (final b
                  in nextOpened.resp.timeout(const Duration(seconds: 8))) {
                if (b.isEmpty) continue;
                nextBuf.add(b);
                recordDownstreamBytes(b.length);
                if (nextBuf.length > 2 * 1024 * 1024) {
                  nextTooLarge = true;
                  break;
                }
              }
              if (nextTooLarge) break;
              final nextBytes = nextBuf.takeBytes();
              final nextText = utf8.decode(nextBytes, allowMalformed: true);
              if (!nextText.contains('#EXTM3U')) break;
              currentUri = variantUri;
              text = nextText;
            }

            if (cleanAds && text.contains('#EXTINF')) {
              if (text.length > 20000) {
                text = await compute(
                  LocalProxyTunnelBridge._stripAdsInBackgroundIsolate,
                  <String, String>{
                    'text': text,
                    'baseUri': currentUri.toString(),
                  },
                );
              } else {
                final stripped = M3u8AdRemover.stripAdsFromMediaPlaylist(
                  text,
                  baseUri: currentUri,
                );
                text = stripped.cleanedM3u8;
              }
            }

            final rewrittenM3u8 = _rewriteM3u8PlaylistThroughRelay(
              text,
              baseUri: currentUri,
              headers: customHeaders,
              cleanAds: cleanAds,
              forceDirect: forceDirect,
              candidateNodes: candidateNodes,
            );
            final outBytes = utf8.encode(rewrittenM3u8);
            final respHeader = StringBuffer()
              ..write('HTTP/1.1 200 OK\r\n')
              ..write(
                  'Content-Type: application/vnd.apple.mpegurl; charset=utf-8\r\n')
              ..write('Content-Length: ${outBytes.length}\r\n')
              ..write('Access-Control-Allow-Origin: *\r\n')
              ..write('Cache-Control: no-cache\r\n')
              ..write('Connection: close\r\n\r\n');
            client.add(latin1.encode(respHeader.toString()));
            client.add(outBytes);
            await finishClientResponse();
            return;
          } else {
            preBufferedBinaryChunk = rawBytes;
            activeStreamIterator = iter;
          }
        } else {
          preBufferedBinaryChunk = m3u8Buf.takeBytes();
          activeStreamIterator = iter;
        }
      }

      // Stream binary segment (.ts, .m4s, .mp4, .key) directly to libmpv
      final contentTypeStr = resp.headers.value('content-type') ?? 'video/mp2t';
      final statusReason = resp.statusCode == 206 ? 'Partial Content' : 'OK';
      final respHeader = StringBuffer()
        ..write('HTTP/1.1 ${resp.statusCode} $statusReason\r\n')
        ..write('Content-Type: $contentTypeStr\r\n');
      if (resp.contentLength >= 0) {
        respHeader.write('Content-Length: ${resp.contentLength}\r\n');
      }
      final contentRange = resp.headers.value('content-range');
      if (contentRange != null) {
        respHeader.write('Content-Range: $contentRange\r\n');
      }
      final acceptRanges = resp.headers.value('accept-ranges');
      if (acceptRanges != null) {
        respHeader.write('Accept-Ranges: $acceptRanges\r\n');
      }
      respHeader
        ..write('Access-Control-Allow-Origin: *\r\n')
        ..write('Connection: close\r\n\r\n');
      client.add(latin1.encode(respHeader.toString()));

      var clientClosed = false;
      unawaited(
        client.done.then(
          (_) => clientClosed = true,
          onError: (_) => clientClosed = true,
        ),
      );

      final shouldCacheSegment = (rangeHeader == null || rangeHeader.isEmpty) &&
          resp.statusCode == 200 &&
          segIndex != null &&
          resp.contentLength > 0 &&
          resp.contentLength <= 8 * 1024 * 1024;
      final segmentAccumulator =
          shouldCacheSegment ? BytesBuilder(copy: false) : null;
      var lookaheadTriggeredForProxySeg = false;
      var streamedBytes = 0;

      bool handleDownstreamChunk(List<int> chunk) {
        if (chunk.isEmpty) return true;
        recordDownstreamBytes(chunk.length);
        streamedBytes += chunk.length;
        try {
          client.add(chunk);
        } catch (_) {
          clientClosed = true;
          unawaited(
            resp.detachSocket().then((s) => s.destroy(), onError: (_) {}),
          );
          return false;
        }
        if (segmentAccumulator != null &&
            segmentAccumulator.length + chunk.length <= 8 * 1024 * 1024) {
          segmentAccumulator.add(chunk);
        }
        if (!forceDirect &&
            segIndex != null &&
            !lookaheadTriggeredForProxySeg &&
            (streamedBytes >= 192 * 1024 ||
                (resp.contentLength > 0 &&
                    streamedBytes * 2 >= resp.contentLength))) {
          lookaheadTriggeredForProxySeg = true;
          _scheduleLookaheadPrefetch(
            fromIndex: segIndex + 1,
            count: 4,
            customHeaders: customHeaders,
            forceDirect: forceDirect,
            candidateNodes: candidateNodes,
          );
        }
        return true;
      }

      if (preBufferedBinaryChunk != null && preBufferedBinaryChunk.isNotEmpty) {
        handleDownstreamChunk(preBufferedBinaryChunk);
      }

      if (activeStreamIterator != null) {
        while (!clientClosed && await activeStreamIterator.moveNext()) {
          if (!handleDownstreamChunk(activeStreamIterator.current)) {
            break;
          }
        }
        if (clientClosed) {
          unawaited(
            resp.detachSocket().then((s) => s.destroy(), onError: (_) {}),
          );
        }
      } else {
        await for (final chunk in resp.timeout(const Duration(seconds: 45))) {
          if (clientClosed) {
            unawaited(
              resp.detachSocket().then((s) => s.destroy(), onError: (_) {}),
            );
            break;
          }
          if (!handleDownstreamChunk(chunk)) {
            break;
          }
        }
      }
      if (!clientClosed &&
          !forceDirect &&
          segIndex != null &&
          !lookaheadTriggeredForProxySeg) {
        _scheduleLookaheadPrefetch(
          fromIndex: segIndex + 1,
          count: 2,
          customHeaders: customHeaders,
          forceDirect: forceDirect,
          candidateNodes: candidateNodes,
        );
      }
      if (!clientClosed &&
          segmentAccumulator != null &&
          segmentAccumulator.length > 0) {
        _storePrefetchedSegment(
          targetUrl,
          segmentAccumulator.takeBytes(),
          contentTypeStr,
        );
      }
      await finishClientResponse();
    } catch (_) {
      cleanup();
    }
  }

  ProxyNode? winningNodeForSession;

  void _registerPlaylistSegments(List<String> segmentUrls) {
    if (segmentUrls.isEmpty) return;
    _playlistSegmentUrls = segmentUrls;
    _playlistSegmentIndexMap.clear();
    for (var i = 0; i < segmentUrls.length; i++) {
      _playlistSegmentIndexMap.putIfAbsent(segmentUrls[i], () => i);
    }
  }

  void _storePrefetchedSegment(
    String url,
    Uint8List bytes,
    String contentType,
  ) {
    if (bytes.isEmpty || bytes.length > 10 * 1024 * 1024) return;
    final existing = _prefetchedSegmentCache.remove(url);
    if (existing != null) {
      _prefetchedCacheTotalBytes -= existing.bytes.length;
    }
    while ((_prefetchedSegmentCache.length >= _maxPrefetchCacheSegments ||
            _prefetchedCacheTotalBytes + bytes.length > _maxPrefetchCacheBytes) &&
        _prefetchedSegmentCache.isNotEmpty) {
      final oldestKey = _prefetchedSegmentCache.keys.first;
      final removed = _prefetchedSegmentCache.remove(oldestKey);
      if (removed != null) {
        _prefetchedCacheTotalBytes -= removed.bytes.length;
      }
    }
    _prefetchedSegmentCache[url] = (
      bytes: bytes,
      contentType: contentType,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
    );
    _prefetchedCacheTotalBytes += bytes.length;
  }

  void _scheduleLookaheadPrefetch({
    required int fromIndex,
    required int count,
    required Map<String, String> customHeaders,
    required bool forceDirect,
    required List<ProxyNode> candidateNodes,
  }) {
    if (_playlistSegmentUrls.isEmpty || fromIndex < 0) return;
    final endExclusive = min(_playlistSegmentUrls.length, fromIndex + count);
    for (var i = fromIndex; i < endExclusive; i++) {
      final segUrl = _playlistSegmentUrls[i];
      if (_prefetchedSegmentCache.containsKey(segUrl) ||
          _inFlightSegmentFetches.containsKey(segUrl) ||
          _pendingPrefetchQueue.any((item) => item.url == segUrl)) {
        continue;
      }
      if (_pendingPrefetchQueue.length >= maxConcurrentPrefetchWorkers * 2) {
        _pendingPrefetchQueue.removeFirst();
      }
      _pendingPrefetchQueue.addLast((
        url: segUrl,
        headers: Map<String, String>.from(customHeaders),
        forceDirect: forceDirect,
        candidateNodes: List<ProxyNode>.from(candidateNodes),
      ));
    }
    _pumpPrefetchWorkers();
  }

  void _pumpPrefetchWorkers() {
    while (_activePrefetchWorkers < maxConcurrentPrefetchWorkers &&
        _pendingPrefetchQueue.isNotEmpty &&
        _serverSocket != null) {
      final task = _pendingPrefetchQueue.removeFirst();
      if (_prefetchedSegmentCache.containsKey(task.url) ||
          _inFlightSegmentFetches.containsKey(task.url)) {
        continue;
      }
      _activePrefetchWorkers++;
      final future = _prefetchSingleSegment(
        url: task.url,
        customHeaders: task.headers,
        forceDirect: task.forceDirect,
        candidateNodes: task.candidateNodes,
      );
      _inFlightSegmentFetches[task.url] = future;
      unawaited(
        future.whenComplete(() {
          _inFlightSegmentFetches.remove(task.url);
          if (_activePrefetchWorkers > 0) {
            _activePrefetchWorkers--;
          }
          _pumpPrefetchWorkers();
        }),
      );
    }
  }

  Future<({Uint8List bytes, String contentType})?> _prefetchSingleSegment({
    required String url,
    required Map<String, String> customHeaders,
    required bool forceDirect,
    required List<ProxyNode> candidateNodes,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty || _serverSocket == null) return null;

    Future<HttpClientResponse?> openPrefetchRequest({
      String? byteRange,
    }) async {
      if (forceDirect) {
        try {
          final hc = _getOrCreateDirectRelayHttpClient();
          final req = await hc.getUrl(uri).timeout(
                const Duration(milliseconds: 6500),
              );
          req.headers.set(
            'User-Agent',
            customHeaders['User-Agent'] ??
                'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
          );
          req.headers.set('Accept', '*/*');
          customHeaders.forEach((k, v) {
            if (k.toLowerCase() != 'host') {
              req.headers.set(k, v);
            }
          });
          if (byteRange != null) {
            req.headers.set('Range', byteRange);
          }
          final resp = await req.close().timeout(
                const Duration(milliseconds: 6500),
              );
          if (resp.statusCode >= 200 && resp.statusCode < 300) {
            return resp;
          }
          await resp.drain<void>().timeout(
                const Duration(milliseconds: 800),
                onTimeout: () {},
              );
        } catch (_) {}
        return null;
      }

      final nodes = winningNodeForSession != null
          ? <ProxyNode>[
              winningNodeForSession!,
              ...candidateNodes.where((n) => n.id != winningNodeForSession!.id),
            ]
          : candidateNodes;
      for (final node in nodes) {
        try {
          final hc = _getOrCreateStreamRelayHttpClient(node);
          final req = await hc.getUrl(uri).timeout(
                const Duration(milliseconds: 6500),
              );
          req.headers.set(
            'User-Agent',
            customHeaders['User-Agent'] ??
                'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
          );
          req.headers.set('Accept', '*/*');
          customHeaders.forEach((k, v) {
            if (k.toLowerCase() != 'host') {
              req.headers.set(k, v);
            }
          });
          if (byteRange != null) {
            req.headers.set('Range', byteRange);
          }
          final resp = await req.close().timeout(
                const Duration(milliseconds: 6500),
              );
          if (resp.statusCode >= 200 && resp.statusCode < 300) {
            return resp;
          }
          await resp.drain<void>().timeout(
                const Duration(milliseconds: 800),
                onTimeout: () {},
              );
        } catch (_) {}
      }
      return null;
    }

    try {
      final resp = await openPrefetchRequest();
      if (resp == null) return null;
      final contentType = resp.headers.value('content-type') ?? 'video/mp2t';
      final totalLen = resp.contentLength;
      final acceptRanges =
          resp.headers.value('accept-ranges')?.toLowerCase() ?? '';

      // If segment is large (>= 1.5MB) and server advertises byte-range support,
      // split the remaining bytes across multiple concurrent Range connections!
      if (totalLen >= _parallelRangeThresholdBytes &&
          totalLen <= 10 * 1024 * 1024 &&
          acceptRanges.contains('bytes')) {
        await resp.drain<void>().timeout(
              const Duration(milliseconds: 300),
              onTimeout: () {},
            );
        final chunkSize =
            (totalLen / _parallelRangeChunkConnections).ceil();
        final futures = <Future<Uint8List?>>[];
        for (var part = 0; part < _parallelRangeChunkConnections; part++) {
          final start = part * chunkSize;
          if (start >= totalLen) break;
          final end = min(totalLen - 1, start + chunkSize - 1);
          futures.add(() async {
            final partResp = await openPrefetchRequest(
              byteRange: 'bytes=$start-$end',
            );
            if (partResp == null || partResp.statusCode != 206) return null;
            final bb = BytesBuilder(copy: false);
            await for (final chunk
                in partResp.timeout(const Duration(seconds: 12))) {
              if (chunk.isNotEmpty) {
                recordDownstreamBytes(chunk.length);
                bb.add(chunk);
              }
            }
            return bb.takeBytes();
          }());
        }
        final parts = await Future.wait(futures);
        if (parts.every((p) => p != null)) {
          final combined = BytesBuilder(copy: false);
          for (final p in parts) {
            combined.add(p!);
          }
          final bytes = combined.takeBytes();
          if (bytes.length == totalLen) {
            _storePrefetchedSegment(url, bytes, contentType);
            return (bytes: bytes, contentType: contentType);
          }
        }
      }

      if (totalLen > 10 * 1024 * 1024) {
        await resp.drain<void>().timeout(
              const Duration(milliseconds: 500),
              onTimeout: () {},
            );
        return null;
      }

      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp.timeout(const Duration(seconds: 12))) {
        if (chunk.isNotEmpty) {
          recordDownstreamBytes(chunk.length);
          builder.add(chunk);
          if (builder.length > 10 * 1024 * 1024) {
            return null;
          }
        }
      }
      final bytes = builder.takeBytes();
      if (bytes.isEmpty) return null;
      _storePrefetchedSegment(url, bytes, contentType);
      return (bytes: bytes, contentType: contentType);
    } catch (_) {
      return null;
    }
  }

  String _rewriteM3u8PlaylistThroughRelay(
    String content, {
    required Uri baseUri,
    required Map<String, String> headers,
    required bool cleanAds,
    bool forceDirect = false,
    List<ProxyNode> candidateNodes = const <ProxyNode>[],
  }) {
    final uriAttrRegex = RegExp(r'URI="([^"]+)"');
    final lines = const LineSplitter().convert(content);
    final sb = StringBuffer();
    final discoveredSegments = <String>[];
    final isMediaPlaylist = content.contains('#EXTINF');

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        if (line.contains('URI="')) {
          final rewrittenTag = line.replaceAllMapped(uriAttrRegex, (m) {
            final rawUri = m.group(1) ?? '';
            if (rawUri.isEmpty) return m.group(0)!;
            final abs = baseUri.resolve(rawUri).toString();
            final relayed = buildStreamRelayUrl(
              targetUrl: abs,
              headers: headers,
              forceDirect: forceDirect,
            );
            return 'URI="$relayed"';
          });
          sb.writeln(rewrittenTag);
        } else {
          sb.writeln(line);
        }
      } else {
        final abs = baseUri.resolve(line).toString();
        if (isMediaPlaylist && !abs.toLowerCase().contains('.m3u8')) {
          discoveredSegments.add(abs);
        }
        final relayed = buildStreamRelayUrl(
          targetUrl: abs,
          headers: headers,
          cleanM3u8Ads: cleanAds,
          forceDirect: forceDirect,
        );
        sb.writeln(relayed);
      }
    }

    if (discoveredSegments.isNotEmpty) {
      _registerPlaylistSegments(discoveredSegments);
      if (forceDirect) {
        // In direct mode, immediately launch multi-connection concurrent prefetching
        // for the initial segments so the player gets instant zero-wait segment hits.
        _scheduleLookaheadPrefetch(
          fromIndex: 0,
          count: prefetchLookaheadCount,
          customHeaders: headers,
          forceDirect: forceDirect,
          candidateNodes: candidateNodes,
        );
      }
      // In proxy mode (!forceDirect), do NOT pre-occupy seg[0] in _inFlightSegmentFetches
      // before libmpv requests seg[0]; let libmpv stream seg[0] chunk-by-chunk directly
      // with 100% exclusive proxy bandwidth so the first video frame renders immediately!
    }

    return sb.toString();
  }

  Future<void> _handleClientSocket(Socket client) async {
    try {
      client.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}

    final headerBuffer = <int>[];
    final postHeaderQueue = <Uint8List>[];
    bool headerParsed = false;
    bool tunnelReady = false;
    _UpstreamTunnel? activeUpstream;
    Completer<Uint8List?>? firstPayloadWaiter;
    StreamSubscription<Uint8List>? clientSub;

    void cleanup() {
      clientSub?.cancel();
      activeUpstream?.close();
      try {
        client.destroy();
      } catch (_) {}
    }

    // Single-subscription listener on `client` (never call `client.listen` twice!)
    clientSub = client.listen(
      (chunk) {
        if (chunk.isEmpty) return;
        if (tunnelReady && activeUpstream != null) {
          try {
            activeUpstream!.send(chunk);
          } catch (_) {}
          return;
        }
        if (headerParsed) {
          final copy = Uint8List.fromList(chunk);
          if (firstPayloadWaiter != null && !firstPayloadWaiter!.isCompleted) {
            firstPayloadWaiter!.complete(copy);
          } else {
            postHeaderQueue.add(copy);
          }
          return;
        }

        headerBuffer.addAll(chunk);
        final headerEnd = _findHeaderEnd(headerBuffer);
        if (headerEnd < 0) {
          if (headerBuffer.length > 32768) cleanup();
          return;
        }

        headerParsed = true;
        final headerBytes = headerBuffer.sublist(0, headerEnd);
        final remainingBytes =
            Uint8List.fromList(headerBuffer.sublist(headerEnd));
        headerBuffer.clear();

        unawaited(
          _establishAndBridgeClient(
            client: client,
            headerBytes: headerBytes,
            remainingBytes: remainingBytes,
            postHeaderQueue: postHeaderQueue,
            waitForFirstClientPayload: () {
              if (postHeaderQueue.isNotEmpty) {
                return Future.value(postHeaderQueue.removeAt(0));
              }
              firstPayloadWaiter = Completer<Uint8List?>();
              return firstPayloadWaiter!.future.timeout(
                const Duration(milliseconds: 1500),
                onTimeout: () => null,
              );
            },
            onUpstreamReady: (upstream) {
              activeUpstream = upstream;
              for (final queued in postHeaderQueue) {
                try {
                  upstream.send(queued);
                } catch (_) {}
              }
              postHeaderQueue.clear();
              tunnelReady = true;
            },
            cleanup: cleanup,
          ),
        );
      },
      onError: (_) => cleanup(),
      onDone: () {
        if (firstPayloadWaiter != null && !firstPayloadWaiter!.isCompleted) {
          firstPayloadWaiter!.complete(null);
        }
        activeUpstream?.close();
      },
    );
  }

  Future<void> _establishAndBridgeClient({
    required Socket client,
    required List<int> headerBytes,
    required Uint8List remainingBytes,
    required List<Uint8List> postHeaderQueue,
    required Future<Uint8List?> Function() waitForFirstClientPayload,
    required void Function(_UpstreamTunnel upstream) onUpstreamReady,
    required void Function() cleanup,
  }) async {
    final headerText = latin1.decode(headerBytes, allowInvalid: true);
    final lines = headerText.split('\r\n');
    if (lines.isEmpty) {
      cleanup();
      return;
    }

    final firstLineParts = lines.first.split(' ');
    if (firstLineParts.length < 2) {
      cleanup();
      return;
    }
    final method = firstLineParts[0].toUpperCase();
    final targetStr = firstLineParts[1];

    // Check if this is a local HLS / media stream relay request (`/__m3u8_proxy__/...`)
    if (method != 'CONNECT' && targetStr.contains('/__m3u8_proxy__/')) {
      await _handleStreamRelayRequest(
        client: client,
        targetStr: targetStr,
        rawHttpHeaderLines: lines,
        cleanup: cleanup,
      );
      return;
    }

    String targetHost = '';
    int targetPort = 80;
    final isConnect = method == 'CONNECT';

    if (isConnect) {
      final hp = ProxySubscriptionParser._splitHostPort(targetStr);
      targetHost = hp.host;
      targetPort = hp.port > 0 ? hp.port : 443;
    } else {
      final uri = Uri.tryParse(targetStr);
      if (uri != null && uri.host.isNotEmpty) {
        targetHost = uri.host;
        targetPort = uri.hasPort
            ? uri.port
            : (uri.scheme == 'https' ? 443 : 80);
      } else {
        for (final l in lines.skip(1)) {
          if (l.toLowerCase().startsWith('host:')) {
            final hp = ProxySubscriptionParser._splitHostPort(
              l.substring(5).trim(),
            );
            targetHost = hp.host;
            targetPort = hp.port > 0 ? hp.port : 80;
            break;
          }
        }
      }
    }

    if (targetHost.isEmpty) {
      cleanup();
      return;
    }

    try {
      Uint8List initialClientPayload = remainingBytes;
      if (isConnect) {
        // Immediately acknowledge CONNECT so libmpv / HttpClient sends its TLS ClientHello
        client.add(
          latin1.encode('HTTP/1.1 200 Connection Established\r\n\r\n'),
        );
        if (initialClientPayload.isEmpty) {
          final awaited = await waitForFirstClientPayload();
          if (awaited != null && awaited.isNotEmpty) {
            initialClientPayload = awaited;
          }
        }
      }

      final primaryNode = _resolveDefaultNode();
      _UpstreamTunnel? verifiedTunnel;
      Uint8List? firstUpstreamChunk;

      // Helper to open a proxy node tunnel AND verify that the first response byte arrives
      Future<({_UpstreamTunnel tunnel, Uint8List firstChunk})?>
          tryNodeWithFirstByteVerification(ProxyNode node) async {
        final sw = Stopwatch()..start();
        _UpstreamTunnel? candidate;
        try {
          candidate = await _openUpstreamTunnel(
            node: node,
            targetHost: targetHost,
            targetPort: targetPort,
            isConnect: isConnect,
            rawHttpHeaderLines: lines,
            initialBodyBytes: initialClientPayload,
            timeout: const Duration(milliseconds: 6500),
          );
          if (candidate == null) {
            _onNodeFeedback?.call(node.id, success: false);
            return null;
          }

          // Wait for first response chunk from upstream to prove the tunnel is alive
          final firstChunkCompleter = Completer<Uint8List?>();
          final extraChunks = <Uint8List>[];
          final forwardController = StreamController<Uint8List>();

          candidate.stream.listen(
            (chunk) {
              if (chunk.isEmpty) return;
              if (!firstChunkCompleter.isCompleted) {
                firstChunkCompleter.complete(chunk);
              } else if (!forwardController.isClosed) {
                forwardController.add(chunk);
              }
            },
            onDone: () {
              if (!firstChunkCompleter.isCompleted) {
                firstChunkCompleter.complete(null);
              }
              if (!forwardController.isClosed) {
                forwardController.close();
              }
            },
            onError: (Object e) {
              if (!firstChunkCompleter.isCompleted) {
                firstChunkCompleter.complete(null);
              }
              if (!forwardController.isClosed) {
                forwardController.close();
              }
            },
          );

          final firstChunk = await firstChunkCompleter.future.timeout(
            const Duration(milliseconds: 6500),
            onTimeout: () => null,
          );

          if (firstChunk == null || firstChunk.isEmpty) {
            candidate.close();
            await forwardController.close();
            _onNodeFeedback?.call(node.id, success: false);
            return null;
          }

          // Reject Trojan decoy HTTP 400 responses when client sent a TLS ClientHello (0x16 0x03)
          final isTlsClientHello = isConnect &&
              initialClientPayload.length >= 3 &&
              initialClientPayload[0] == 0x16 &&
              initialClientPayload[1] == 0x03;
          if (isTlsClientHello &&
              firstChunk[0] != 0x16 &&
              firstChunk[0] != 0x14 &&
              firstChunk[0] != 0x15) {
            candidate.close();
            await forwardController.close();
            _onNodeFeedback?.call(node.id, success: false);
            return null;
          }

          sw.stop();
          _onNodeFeedback?.call(
            node.id,
            success: true,
            rttMs: sw.elapsedMilliseconds,
          );

          for (final extra in extraChunks) {
            forwardController.add(extra);
          }
          final wrapped = _UpstreamTunnel(
            send: candidate.send,
            stream: forwardController.stream,
            close: () {
              candidate?.close();
              if (!forwardController.isClosed) {
                forwardController.close();
              }
            },
          );
          return (tunnel: wrapped, firstChunk: firstChunk);
        } catch (_) {
          candidate?.close();
          _onNodeFeedback?.call(node.id, success: false);
          return null;
        }
      }

      if (primaryNode != null) {
        final res = await tryNodeWithFirstByteVerification(primaryNode);
        if (res != null) {
          verifiedTunnel = res.tunnel;
          firstUpstreamChunk = res.firstChunk;
        } else {
          final fallbacks = _resolveFallbackNodes?.call() ?? const <ProxyNode>[];
          for (final backupNode in fallbacks) {
            if (backupNode.id != primaryNode.id && !backupNode.isTimeout) {
              final backupRes =
                  await tryNodeWithFirstByteVerification(backupNode);
              if (backupRes != null) {
                verifiedTunnel = backupRes.tunnel;
                firstUpstreamChunk = backupRes.firstChunk;
                break;
              }
            }
          }
        }
      }

      // If proxy node(s) failed or timed out, replay onto direct connection as last resort
      if (verifiedTunnel == null) {
        verifiedTunnel = await _openDirectFallbackTunnel(
          targetHost: targetHost,
          targetPort: targetPort,
          isConnect: isConnect,
          rawHttpHeaderLines: lines,
          initialBodyBytes: initialClientPayload,
        );
        if (verifiedTunnel == null) {
          cleanup();
          return;
        }
        if (isConnect && initialClientPayload.isNotEmpty) {
          verifiedTunnel.send(initialClientPayload);
        }
      }

      onUpstreamReady(verifiedTunnel);
      if (firstUpstreamChunk != null && firstUpstreamChunk.isNotEmpty) {
        recordDownstreamBytes(firstUpstreamChunk.length);
        client.add(firstUpstreamChunk);
      }

      verifiedTunnel.stream.listen(
        (data) {
          try {
            recordDownstreamBytes(data.length);
            client.add(data);
          } catch (_) {}
        },
        onDone: () {
          try {
            client.destroy();
          } catch (_) {}
        },
        onError: (_) {
          try {
            client.destroy();
          } catch (_) {}
        },
      );
    } catch (_) {
      cleanup();
    }
  }

  static _UpstreamTunnel _wrapRawSocketBuffered(
    Socket socket, {
    List<int>? initialUnreadBytes,
  }) {
    final controller = StreamController<Uint8List>();
    if (initialUnreadBytes != null && initialUnreadBytes.isNotEmpty) {
      controller.add(Uint8List.fromList(initialUnreadBytes));
    }
    socket.listen(
      (chunk) {
        if (!controller.isClosed && chunk.isNotEmpty) {
          controller.add(chunk);
        }
      },
      onDone: () {
        if (!controller.isClosed) controller.close();
      },
      onError: (_) {
        if (!controller.isClosed) controller.close();
      },
    );
    return _UpstreamTunnel(
      send: (d) => socket.add(d),
      stream: controller.stream,
      close: () {
        try {
          socket.destroy();
        } catch (_) {}
        if (!controller.isClosed) controller.close();
      },
    );
  }

  static int _findHeaderEnd(List<int> buf) {
    for (var i = 0; i <= buf.length - 4; i++) {
      if (buf[i] == 13 &&
          buf[i + 1] == 10 &&
          buf[i + 2] == 13 &&
          buf[i + 3] == 10) {
        return i + 4;
      }
    }
    return -1;
  }

  Future<_UpstreamTunnel?> _openDirectFallbackTunnel({
    required String targetHost,
    required int targetPort,
    required bool isConnect,
    required List<String> rawHttpHeaderLines,
    required List<int> initialBodyBytes,
  }) async {
    try {
      final directSocket = await Socket.connect(
        targetHost,
        targetPort,
        timeout: const Duration(milliseconds: 2800),
      );
      try {
        directSocket.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {}
      final tunnel = _wrapRawSocketBuffered(directSocket);
      if (!isConnect) {
        final rewrittenHeader =
            _rewriteOriginFormHttpRequest(rawHttpHeaderLines);
        directSocket.add(latin1.encode(rewrittenHeader));
        if (initialBodyBytes.isNotEmpty) {
          directSocket.add(initialBodyBytes);
        }
      }
      return tunnel;
    } catch (_) {
      return null;
    }
  }

  static Future<_UpstreamTunnel?> _openUpstreamTunnel({
    required ProxyNode node,
    required String targetHost,
    required int targetPort,
    required bool isConnect,
    required List<String> rawHttpHeaderLines,
    required List<int> initialBodyBytes,
    Duration timeout = const Duration(milliseconds: 5500),
  }) async {
    if (node.isInfoNode) return null;
    final proto = node.protocol.toLowerCase();
    if (proto == 'trojan') {
      return _connectTrojanUpstream(
        node: node,
        targetHost: targetHost,
        targetPort: targetPort,
        isConnect: isConnect,
        rawHttpHeaderLines: rawHttpHeaderLines,
        initialBodyBytes: initialBodyBytes,
        timeout: timeout,
      );
    }
    if (proto == 'vless') {
      return _connectVlessUpstream(
        node: node,
        targetHost: targetHost,
        targetPort: targetPort,
        isConnect: isConnect,
        rawHttpHeaderLines: rawHttpHeaderLines,
        initialBodyBytes: initialBodyBytes,
        timeout: timeout,
      );
    }
    if (proto == 'ss' || proto == 'shadowsocks') {
      return _connectShadowsocksUpstream(
        node: node,
        targetHost: targetHost,
        targetPort: targetPort,
        isConnect: isConnect,
        rawHttpHeaderLines: rawHttpHeaderLines,
        initialBodyBytes: initialBodyBytes,
        timeout: timeout,
      );
    }
    if (proto == 'socks5' || proto == 'socks') {
      return _connectSocks5Upstream(
        node: node,
        targetHost: targetHost,
        targetPort: targetPort,
        isConnect: isConnect,
        rawHttpHeaderLines: rawHttpHeaderLines,
        initialBodyBytes: initialBodyBytes,
        timeout: timeout,
      );
    }
    if (proto == 'http' || proto == 'https') {
      return _connectHttpProxyUpstream(
        node: node,
        targetHost: targetHost,
        targetPort: targetPort,
        isConnect: isConnect,
        rawHttpHeaderLines: rawHttpHeaderLines,
        initialBodyBytes: initialBodyBytes,
        timeout: timeout,
      );
    }
    return null;
  }

  static Future<_UpstreamTunnel?> _connectHttpProxyUpstream({
    required ProxyNode node,
    required String targetHost,
    required int targetPort,
    required bool isConnect,
    required List<String> rawHttpHeaderLines,
    required List<int> initialBodyBytes,
    required Duration timeout,
  }) async {
    final rawSocket = await Socket.connect(
      node.server,
      node.port,
      timeout: timeout,
    );
    try {
      rawSocket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}

    final Socket socket;
    if (node.protocol.toLowerCase() == 'https' || node.tls) {
      final sni = node.sni.isNotEmpty ? node.sni : node.server;
      socket = await SecureSocket.secure(
        rawSocket,
        host: sni,
        onBadCertificate: (_) => true,
      ).timeout(timeout);
    } else {
      socket = rawSocket;
    }

    String? authHeader;
    if (node.username.isNotEmpty || node.password.isNotEmpty) {
      final creds =
          base64Encode(utf8.encode('${node.username}:${node.password}'));
      authHeader = 'Proxy-Authorization: Basic $creds';
    }

    if (isConnect) {
      final connectReq = StringBuffer()
        ..write('CONNECT $targetHost:$targetPort HTTP/1.1\r\n')
        ..write('Host: $targetHost:$targetPort\r\n');
      if (authHeader != null) connectReq.write('$authHeader\r\n');
      connectReq.write('\r\n');
      socket.add(latin1.encode(connectReq.toString()));

      final respBuf = <int>[];
      final completer = Completer<bool>();
      final outController = StreamController<Uint8List>();
      var handshakeDone = false;

      socket.listen(
        (chunk) {
          if (handshakeDone) {
            if (!outController.isClosed && chunk.isNotEmpty) {
              outController.add(chunk);
            }
            return;
          }
          respBuf.addAll(chunk);
          final end = _findHeaderEnd(respBuf);
          if (end >= 0) {
            handshakeDone = true;
            final statusLine =
                latin1.decode(respBuf.sublist(0, end), allowInvalid: true).split('\r\n').first;
            final ok = statusLine.contains(' 200 ');
            if (ok && respBuf.length > end) {
              outController.add(Uint8List.fromList(respBuf.sublist(end)));
            }
            if (!completer.isCompleted) {
              completer.complete(ok);
            }
          }
        },
        onError: (_) {
          if (!completer.isCompleted) completer.complete(false);
          if (!outController.isClosed) outController.close();
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(false);
          if (!outController.isClosed) outController.close();
        },
      );
      final ok = await completer.future.timeout(
        timeout,
        onTimeout: () => false,
      );
      if (!ok) {
        socket.destroy();
        if (!outController.isClosed) await outController.close();
        return null;
      }
      if (initialBodyBytes.isNotEmpty) {
        socket.add(initialBodyBytes);
      }
      return _UpstreamTunnel(
        send: (d) => socket.add(d),
        stream: outController.stream,
        close: () {
          try {
            socket.destroy();
          } catch (_) {}
          if (!outController.isClosed) outController.close();
        },
      );
    } else {
      final tunnel = _wrapRawSocketBuffered(socket);
      final sb = StringBuffer();
      for (var i = 0; i < rawHttpHeaderLines.length; i++) {
        final l = rawHttpHeaderLines[i];
        if (l.isEmpty) continue;
        sb.write('$l\r\n');
        if (i == 0 && authHeader != null) {
          sb.write('$authHeader\r\n');
        }
      }
      sb.write('\r\n');
      socket.add(latin1.encode(sb.toString()));
      if (initialBodyBytes.isNotEmpty) {
        socket.add(initialBodyBytes);
      }
      return tunnel;
    }
  }

  static Future<_UpstreamTunnel?> _connectSocks5Upstream({
    required ProxyNode node,
    required String targetHost,
    required int targetPort,
    required bool isConnect,
    required List<String> rawHttpHeaderLines,
    required List<int> initialBodyBytes,
    required Duration timeout,
  }) async {
    final rawSocket = await Socket.connect(
      node.server,
      node.port,
      timeout: timeout,
    );
    try {
      rawSocket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}

    final rxBuffer = <int>[];
    final outController = StreamController<Uint8List>();
    var handshakeFinished = false;
    Completer<void>? waiter;

    rawSocket.listen(
      (chunk) {
        if (handshakeFinished) {
          if (!outController.isClosed && chunk.isNotEmpty) {
            outController.add(chunk);
          }
          return;
        }
        rxBuffer.addAll(chunk);
        if (waiter != null && !waiter!.isCompleted) {
          waiter!.complete();
        }
      },
      onDone: () {
        if (waiter != null && !waiter!.isCompleted) {
          waiter!.completeError(StateError('EOF'));
        }
        if (!outController.isClosed) outController.close();
      },
      onError: (Object e) {
        if (waiter != null && !waiter!.isCompleted) {
          waiter!.completeError(e);
        }
        if (!outController.isClosed) outController.close();
      },
    );

    Future<Uint8List> readExactBytes(int count) async {
      while (rxBuffer.length < count) {
        waiter = Completer<void>();
        await waiter!.future.timeout(timeout);
      }
      final res = Uint8List.fromList(rxBuffer.sublist(0, count));
      rxBuffer.removeRange(0, count);
      return res;
    }

    final hasAuth = node.username.isNotEmpty || node.password.isNotEmpty;
    rawSocket.add(
      hasAuth ? const [0x05, 0x02, 0x00, 0x02] : const [0x05, 0x01, 0x00],
    );
    final greetingResp = await readExactBytes(2);
    if (greetingResp[0] != 0x05) {
      rawSocket.destroy();
      return null;
    }
    if (greetingResp[1] == 0x02) {
      final uBytes = utf8.encode(node.username);
      final pBytes = utf8.encode(node.password);
      rawSocket.add([0x01, uBytes.length, ...uBytes, pBytes.length, ...pBytes]);
      final authResp = await readExactBytes(2);
      if (authResp[1] != 0x00) {
        rawSocket.destroy();
        return null;
      }
    } else if (greetingResp[1] != 0x00) {
      rawSocket.destroy();
      return null;
    }

    final hostBytes = utf8.encode(targetHost);
    final req = <int>[
      0x05,
      0x01, // CONNECT
      0x00,
      0x03, // Domain name
      hostBytes.length,
      ...hostBytes,
      (targetPort >> 8) & 0xff,
      targetPort & 0xff,
    ];
    rawSocket.add(req);
    final connResp = await readExactBytes(4);
    if (connResp[1] != 0x00) {
      rawSocket.destroy();
      return null;
    }
    final atyp = connResp[3];
    if (atyp == 0x01) {
      await readExactBytes(6); // 4B IPv4 + 2B port
    } else if (atyp == 0x04) {
      await readExactBytes(18); // 16B IPv6 + 2B port
    } else if (atyp == 0x03) {
      final lenByte = await readExactBytes(1);
      await readExactBytes(lenByte[0] + 2);
    }

    handshakeFinished = true;
    if (rxBuffer.isNotEmpty) {
      outController.add(Uint8List.fromList(rxBuffer));
      rxBuffer.clear();
    }

    if (!isConnect) {
      final rewritten = _rewriteOriginFormHttpRequest(rawHttpHeaderLines);
      rawSocket.add(latin1.encode(rewritten));
    }
    if (initialBodyBytes.isNotEmpty) {
      rawSocket.add(initialBodyBytes);
    }
    return _UpstreamTunnel(
      send: (d) => rawSocket.add(d),
      stream: outController.stream,
      close: () {
        try {
          rawSocket.destroy();
        } catch (_) {}
        if (!outController.isClosed) outController.close();
      },
    );
  }

  static Future<_UpstreamTunnel?> _connectTrojanUpstream({
    required ProxyNode node,
    required String targetHost,
    required int targetPort,
    required bool isConnect,
    required List<String> rawHttpHeaderLines,
    required List<int> initialBodyBytes,
    required Duration timeout,
  }) async {
    final sni = node.sni.isNotEmpty
        ? node.sni
        : (node.wsHost.isNotEmpty ? node.wsHost : node.server);

    final hashHex = _Sha224.hexDigest(node.password);
    final hostBytes = utf8.encode(targetHost);
    final trojanHeader = <int>[
      ...latin1.encode(hashHex),
      0x0d,
      0x0a,
      0x01, // CONNECT command
      0x03, // Domain ATYP
      hostBytes.length,
      ...hostBytes,
      (targetPort >> 8) & 0xff,
      targetPort & 0xff,
      0x0d,
      0x0a,
    ];

    if (!isConnect) {
      final rewritten = _rewriteOriginFormHttpRequest(rawHttpHeaderLines);
      trojanHeader.addAll(latin1.encode(rewritten));
    }
    if (initialBodyBytes.isNotEmpty) {
      trojanHeader.addAll(initialBodyBytes);
    }

    if (node.network.toLowerCase() == 'ws') {
      final hc = HttpClient()
        ..connectionTimeout = timeout
        ..badCertificateCallback = (cert, host, port) => true;
      hc.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
        final raw = await Socket.connect(
          node.server,
          node.port,
          timeout: timeout,
        );
        try {
          raw.setOption(SocketOption.tcpNoDelay, true);
        } catch (_) {}
        if (node.tls || uri.scheme == 'wss') {
          final tls = await SecureSocket.secure(
            raw,
            host: sni,
            onBadCertificate: (_) => true,
          ).timeout(timeout);
          return ConnectionTask.fromSocket(Future.value(tls), () {});
        }
        return ConnectionTask.fromSocket(Future.value(raw), () {});
      };

      final wsScheme = node.tls ? 'wss' : 'ws';
      final wsHostHeader = node.wsHost.isNotEmpty ? node.wsHost : sni;
      final normalizedPath = node.wsPath.isEmpty
          ? '/'
          : (node.wsPath.startsWith('/') ? node.wsPath : '/${node.wsPath}');
      final wsUrl = '$wsScheme://$wsHostHeader:${node.port}$normalizedPath';

      final ws = await WebSocket.connect(
        wsUrl,
        headers: {'Host': wsHostHeader},
        customClient: hc,
      ).timeout(timeout);

      ws.add(Uint8List.fromList(trojanHeader));
      final outController = StreamController<Uint8List>();
      ws.listen(
        (dynamic msg) {
          final List<int> bytes = msg is List<int>
              ? msg
              : (msg is String ? latin1.encode(msg) : const <int>[]);
          if (bytes.isNotEmpty && !outController.isClosed) {
            outController.add(Uint8List.fromList(bytes));
          }
        },
        onDone: () {
          if (!outController.isClosed) outController.close();
          hc.close(force: true);
        },
        onError: (_) {
          if (!outController.isClosed) outController.close();
          hc.close(force: true);
        },
      );

      return _UpstreamTunnel(
        send: (d) {
          if (d.isEmpty) return;
          try {
            ws.add(Uint8List.fromList(d));
          } catch (_) {}
        },
        stream: outController.stream,
        close: () {
          try {
            ws.close();
          } catch (_) {}
          hc.close(force: true);
          if (!outController.isClosed) outController.close();
        },
      );
    }

    final rawSocket = await Socket.connect(
      node.server,
      node.port,
      timeout: timeout,
    );
    try {
      rawSocket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}

    final tlsSocket = await SecureSocket.secure(
      rawSocket,
      host: sni,
      onBadCertificate: (_) => true,
    ).timeout(timeout);
    final tunnel = _wrapRawSocketBuffered(tlsSocket);
    tlsSocket.add(trojanHeader);
    return tunnel;
  }

  static Uint8List? _parseUuidBytes(String uuid) {
    final hex = uuid.replaceAll('-', '').trim();
    if (hex.length != 32) return null;
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      final byteVal = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (byteVal == null) return null;
      out[i] = byteVal;
    }
    return out;
  }

  static Future<_UpstreamTunnel?> _connectVlessUpstream({
    required ProxyNode node,
    required String targetHost,
    required int targetPort,
    required bool isConnect,
    required List<String> rawHttpHeaderLines,
    required List<int> initialBodyBytes,
    required Duration timeout,
  }) async {
    final uuidBytes = _parseUuidBytes(node.password);
    if (uuidBytes == null) return null;

    final hostBytes = utf8.encode(targetHost);
    final vlessHeader = <int>[
      0x00, // VLESS version 0
      ...uuidBytes,
      0x00, // Addons length 0
      0x01, // Command: TCP (1)
      (targetPort >> 8) & 0xff,
      targetPort & 0xff,
      0x02, // Address type: Domain (2) in VLESS
      hostBytes.length,
      ...hostBytes,
    ];

    if (!isConnect) {
      final rewritten = _rewriteOriginFormHttpRequest(rawHttpHeaderLines);
      vlessHeader.addAll(latin1.encode(rewritten));
    }
    if (initialBodyBytes.isNotEmpty) {
      vlessHeader.addAll(initialBodyBytes);
    }

    final sni = node.sni.isNotEmpty
        ? node.sni
        : (node.wsHost.isNotEmpty ? node.wsHost : node.server);

    if (node.network.toLowerCase() == 'ws') {
      final hc = HttpClient()
        ..connectionTimeout = timeout
        ..badCertificateCallback = (cert, host, port) => true;
      hc.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
        final raw = await Socket.connect(
          node.server,
          node.port,
          timeout: timeout,
        );
        try {
          raw.setOption(SocketOption.tcpNoDelay, true);
        } catch (_) {}
        if (node.tls || uri.scheme == 'wss') {
          final tls = await SecureSocket.secure(
            raw,
            host: sni,
            onBadCertificate: (_) => true,
          ).timeout(timeout);
          return ConnectionTask.fromSocket(Future.value(tls), () {});
        }
        return ConnectionTask.fromSocket(Future.value(raw), () {});
      };

      final wsScheme = node.tls ? 'wss' : 'ws';
      final wsHostHeader = node.wsHost.isNotEmpty ? node.wsHost : sni;
      final normalizedPath = node.wsPath.isEmpty
          ? '/'
          : (node.wsPath.startsWith('/') ? node.wsPath : '/${node.wsPath}');
      final wsUrl = '$wsScheme://$wsHostHeader:${node.port}$normalizedPath';

      final ws = await WebSocket.connect(
        wsUrl,
        headers: {'Host': wsHostHeader},
        customClient: hc,
      ).timeout(timeout);

      ws.add(Uint8List.fromList(vlessHeader));

      final outController = StreamController<Uint8List>();
      var vlessRespHeaderParsed = false;
      final rxBuf = <int>[];

      ws.listen(
        (dynamic msg) {
          final List<int> bytes = msg is List<int>
              ? msg
              : (msg is String ? latin1.encode(msg) : const <int>[]);
          if (bytes.isEmpty) return;
          if (vlessRespHeaderParsed) {
            if (!outController.isClosed) {
              outController.add(Uint8List.fromList(bytes));
            }
            return;
          }
          rxBuf.addAll(bytes);
          if (rxBuf.length < 2) return;
          final addonLen = rxBuf[1];
          if (rxBuf.length < 2 + addonLen) return;
          vlessRespHeaderParsed = true;
          final payload = rxBuf.sublist(2 + addonLen);
          rxBuf.clear();
          if (payload.isNotEmpty && !outController.isClosed) {
            outController.add(Uint8List.fromList(payload));
          }
        },
        onDone: () {
          if (!outController.isClosed) outController.close();
          hc.close(force: true);
        },
        onError: (_) {
          if (!outController.isClosed) outController.close();
          hc.close(force: true);
        },
      );

      return _UpstreamTunnel(
        send: (d) {
          if (d.isEmpty) return;
          try {
            ws.add(Uint8List.fromList(d));
          } catch (_) {}
        },
        stream: outController.stream,
        close: () {
          try {
            ws.close();
          } catch (_) {}
          hc.close(force: true);
          if (!outController.isClosed) outController.close();
        },
      );
    } else {
      final rawSocket = await Socket.connect(
        node.server,
        node.port,
        timeout: timeout,
      );
      try {
        rawSocket.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {}
      final Socket socket = node.tls
          ? await SecureSocket.secure(
              rawSocket,
              host: sni,
              onBadCertificate: (_) => true,
            ).timeout(timeout)
          : rawSocket;

      socket.add(Uint8List.fromList(vlessHeader));

      final outController = StreamController<Uint8List>();
      var vlessRespHeaderParsed = false;
      final rxBuf = <int>[];

      socket.listen(
        (chunk) {
          if (chunk.isEmpty) return;
          if (vlessRespHeaderParsed) {
            if (!outController.isClosed) {
              outController.add(chunk);
            }
            return;
          }
          rxBuf.addAll(chunk);
          if (rxBuf.length < 2) return;
          final addonLen = rxBuf[1];
          if (rxBuf.length < 2 + addonLen) return;
          vlessRespHeaderParsed = true;
          final payload = rxBuf.sublist(2 + addonLen);
          rxBuf.clear();
          if (payload.isNotEmpty && !outController.isClosed) {
            outController.add(Uint8List.fromList(payload));
          }
        },
        onDone: () {
          if (!outController.isClosed) outController.close();
        },
        onError: (_) {
          if (!outController.isClosed) outController.close();
        },
      );

      return _UpstreamTunnel(
        send: (d) => socket.add(d),
        stream: outController.stream,
        close: () {
          try {
            socket.destroy();
          } catch (_) {}
          if (!outController.isClosed) outController.close();
        },
      );
    }
  }

  static ({bool supported, bool isAesGcm, int keyLen, int saltLen})
      _resolveSsCipherSpec(String cipher) {
    final c = cipher.toLowerCase().trim();
    if (c.contains('chacha20')) {
      return (supported: true, isAesGcm: false, keyLen: 32, saltLen: 32);
    }
    if (c.contains('aes-128-gcm') || c.contains('128-gcm')) {
      return (supported: true, isAesGcm: true, keyLen: 16, saltLen: 16);
    }
    if (c.contains('aes-192-gcm') || c.contains('192-gcm')) {
      return (supported: true, isAesGcm: true, keyLen: 24, saltLen: 24);
    }
    if (c.contains('aes-256-gcm') || c.contains('256-gcm') || c.isEmpty) {
      return (supported: true, isAesGcm: true, keyLen: 32, saltLen: 32);
    }
    return (supported: false, isAesGcm: false, keyLen: 0, saltLen: 0);
  }

  static Future<_UpstreamTunnel?> _connectShadowsocksUpstream({
    required ProxyNode node,
    required String targetHost,
    required int targetPort,
    required bool isConnect,
    required List<String> rawHttpHeaderLines,
    required List<int> initialBodyBytes,
    required Duration timeout,
  }) async {
    final spec = _resolveSsCipherSpec(node.cipher);
    if (!spec.supported) {
      return null;
    }

    final rawSocket = await Socket.connect(
      node.server,
      node.port,
      timeout: timeout,
    );
    try {
      rawSocket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}

    final keyLen = spec.keyLen;
    final saltLen = spec.saltLen;
    final isAesGcm = spec.isAesGcm;
    final masterKey = _SsCrypto.evpBytesToKey(node.password, keyLen);
    final clientSalt = _SsCrypto.randomBytes(saltLen);
    final clientSubkey =
        _SsCrypto.deriveSsSubkey(masterKey, clientSalt, keyLen);
    var clientNonceCounter = 0;

    Uint8List nextNonce(int counter) {
      final n = Uint8List(12);
      final bd = ByteData.sublistView(n);
      bd.setUint32(0, counter & 0xffffffff, Endian.little);
      bd.setUint32(4, (counter ~/ 0x100000000) & 0xffffffff, Endian.little);
      return n;
    }

    Uint8List aeadEncrypt(Uint8List subkey, int nonceIdx, Uint8List plain) {
      return isAesGcm
          ? _SsCrypto.aesGcmEncrypt(subkey, nextNonce(nonceIdx), plain)
          : _SsCrypto.chacha20Poly1305Encrypt(
              subkey,
              nextNonce(nonceIdx),
              plain,
            );
    }

    Uint8List? aeadDecrypt(
      Uint8List subkey,
      int nonceIdx,
      Uint8List cipherWithTag,
    ) {
      return isAesGcm
          ? _SsCrypto.aesGcmDecrypt(subkey, nextNonce(nonceIdx), cipherWithTag)
          : _SsCrypto.chacha20Poly1305Decrypt(
              subkey,
              nextNonce(nonceIdx),
              cipherWithTag,
            );
    }

    Uint8List packAeadChunk(List<int> plain) {
      final out = <int>[];
      for (var offset = 0; offset < plain.length; offset += 0x3fff) {
        final end = min(offset + 0x3fff, plain.length);
        final slice = Uint8List.fromList(plain.sublist(offset, end));
        final lenBytes = Uint8List(2)
          ..[0] = (slice.length >> 8) & 0xff
          ..[1] = slice.length & 0xff;
        final encLen = aeadEncrypt(
          clientSubkey,
          clientNonceCounter++,
          lenBytes,
        );
        final encPayload = aeadEncrypt(
          clientSubkey,
          clientNonceCounter++,
          slice,
        );
        out.addAll(encLen);
        out.addAll(encPayload);
      }
      return Uint8List.fromList(out);
    }

    final hostBytes = utf8.encode(targetHost);
    final targetAddrPayload = <int>[
      0x03, // ATYP Domain
      hostBytes.length,
      ...hostBytes,
      (targetPort >> 8) & 0xff,
      targetPort & 0xff,
    ];
    if (!isConnect) {
      final rewritten = _rewriteOriginFormHttpRequest(rawHttpHeaderLines);
      targetAddrPayload.addAll(latin1.encode(rewritten));
    }
    if (initialBodyBytes.isNotEmpty) {
      targetAddrPayload.addAll(initialBodyBytes);
    }

    final firstPacket = <int>[
      ...clientSalt,
      ...packAeadChunk(targetAddrPayload),
    ];
    rawSocket.add(firstPacket);

    // Buffered single-subscription stream so zero decrypted chunks are dropped!
    final outController = StreamController<Uint8List>();
    final rxBuf = <int>[];
    Uint8List? serverSubkey;
    var serverNonceCounter = 0;
    int? pendingPayloadLen;

    rawSocket.listen(
      (chunk) {
        rxBuf.addAll(chunk);
        if (serverSubkey == null) {
          if (rxBuf.length < saltLen) return;
          final srvSalt = Uint8List.fromList(rxBuf.sublist(0, saltLen));
          rxBuf.removeRange(0, saltLen);
          serverSubkey = _SsCrypto.deriveSsSubkey(masterKey, srvSalt, keyLen);
        }
        while (true) {
          if (pendingPayloadLen == null) {
            if (rxBuf.length < 2 + 16) break;
            final encLen = Uint8List.fromList(rxBuf.sublist(0, 18));
            final decLen = aeadDecrypt(
              serverSubkey!,
              serverNonceCounter++,
              encLen,
            );
            if (decLen == null) {
              rawSocket.destroy();
              if (!outController.isClosed) outController.close();
              return;
            }
            rxBuf.removeRange(0, 18);
            pendingPayloadLen = ((decLen[0] << 8) | decLen[1]) & 0x3fff;
          }
          final need = pendingPayloadLen! + 16;
          if (rxBuf.length < need) break;
          final encPayload = Uint8List.fromList(rxBuf.sublist(0, need));
          rxBuf.removeRange(0, need);
          final decPayload = aeadDecrypt(
            serverSubkey!,
            serverNonceCounter++,
            encPayload,
          );
          pendingPayloadLen = null;
          if (decPayload == null) {
            rawSocket.destroy();
            if (!outController.isClosed) outController.close();
            return;
          }
          if (!outController.isClosed) {
            outController.add(decPayload);
          }
        }
      },
      onDone: () {
        if (!outController.isClosed) outController.close();
      },
      onError: (_) {
        if (!outController.isClosed) outController.close();
      },
    );

    return _UpstreamTunnel(
      send: (d) {
        if (d.isEmpty) return;
        rawSocket.add(packAeadChunk(d));
      },
      stream: outController.stream,
      close: () {
        try {
          rawSocket.destroy();
        } catch (_) {}
        if (!outController.isClosed) {
          outController.close();
        }
      },
    );
  }

  /// Performs a real end-to-end proxy tunnel HTTP & throughput benchmark:
  /// 1. Measures raw entry TCP/TLS handshake (`tcpPingMs`).
  /// 2. Opens an actual upstream proxy tunnel through [node] to a fast HTTP target
  ///    (`www.apple.com:80/library/test/success.html` or `cp.cloudflare.com:80/generate_204`),
  ///    sends a real HTTP request, verifies that a valid `HTTP/1.` response comes back
  ///    through the proxy tunnel (`latencyMs`), and calculates the effective tunnel
  ///    transfer throughput (`speedKbps`).
  static Future<({int latencyMs, int tcpPingMs, int speedKbps})>
      probeNodeRealSpeed(ProxyNode node) async {
    if (node.isInfoNode) {
      return (latencyMs: -1, tcpPingMs: -1, speedKbps: 0);
    }

    // 1. Measure raw TCP handshake to entry server
    int tcpPing = -1;
    final tcpSw = Stopwatch()..start();
    try {
      final s = await Socket.connect(
        node.server,
        node.port,
        timeout: const Duration(milliseconds: 2200),
      );
      tcpSw.stop();
      tcpPing = tcpSw.elapsedMilliseconds.clamp(1, 9999);
      s.destroy();
    } catch (_) {
      return (latencyMs: -1, tcpPingMs: -1, speedKbps: 0);
    }

    // 2. Check if this node's protocol & cipher are supported by LocalProxyTunnelBridge
    final proto = node.protocol.toLowerCase();
    final canVerifyTunnelNatively = proto == 'http' ||
        proto == 'https' ||
        proto == 'socks5' ||
        proto == 'socks' ||
        proto == 'trojan' ||
        proto == 'vless' ||
        ((proto == 'ss' || proto == 'shadowsocks') &&
            _resolveSsCipherSpec(node.cipher).supported);

    if (!canVerifyTunnelNatively) {
      return (latencyMs: -1, tcpPingMs: tcpPing, speedKbps: 0);
    }

    // 3. Real end-to-end HTTP probe through the proxy tunnel!
    const probeTargets = [
      (host: 'www.apple.com', path: '/library/test/success.html'),
      (host: 'cp.cloudflare.com', path: '/generate_204'),
    ];

    for (final target in probeTargets) {
      _UpstreamTunnel? tunnel;
      try {
        final totalSw = Stopwatch()..start();
        final reqLines = <String>[
          'GET http://${target.host}${target.path} HTTP/1.1',
          'Host: ${target.host}',
          'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)',
          'Accept: */*',
          'Connection: close',
        ];
        tunnel = await _openUpstreamTunnel(
          node: node,
          targetHost: target.host,
          targetPort: 80,
          isConnect: false,
          rawHttpHeaderLines: reqLines,
          initialBodyBytes: const [],
          timeout: const Duration(milliseconds: 3500),
        );
        if (tunnel == null) continue;

        final c = Completer<({int ttfbMs, int totalMs, int totalBytes})?>();
        int? ttfbMs;
        int rxBytes = 0;
        final rxHeader = <int>[];
        bool validHttp = false;

        final sub = tunnel.stream.listen(
          (chunk) {
            if (chunk.isEmpty) return;
            ttfbMs ??= totalSw.elapsedMilliseconds.clamp(1, 9999);
            rxBytes += chunk.length;
            if (!validHttp && rxHeader.length < 64) {
              rxHeader.addAll(chunk.take(64 - rxHeader.length));
              final prefix = latin1.decode(rxHeader, allowInvalid: true);
              if (prefix.startsWith('HTTP/1.0 ') ||
                  prefix.startsWith('HTTP/1.1 ')) {
                // Reject 400/403/502 decoy error responses from broken Trojan/HTTP nodes
                final firstLine = prefix.split('\r\n').first;
                if (firstLine.contains(' 200 ') ||
                    firstLine.contains(' 204 ') ||
                    firstLine.contains(' 301 ') ||
                    firstLine.contains(' 302 ')) {
                  validHttp = true;
                  if ((firstLine.contains(' 204 ') || rxBytes >= 120) &&
                      !c.isCompleted) {
                    totalSw.stop();
                    c.complete((
                      ttfbMs: ttfbMs!,
                      totalMs: totalSw.elapsedMilliseconds.clamp(1, 9999),
                      totalBytes: max(rxBytes, 512),
                    ));
                  }
                } else {
                  if (!c.isCompleted) c.complete(null);
                }
              }
            }
          },
          onDone: () {
            totalSw.stop();
            if (!c.isCompleted) {
              if (validHttp && ttfbMs != null) {
                c.complete((
                  ttfbMs: ttfbMs!,
                  totalMs: totalSw.elapsedMilliseconds.clamp(1, 9999),
                  totalBytes: max(rxBytes, 512),
                ));
              } else {
                c.complete(null);
              }
            }
          },
          onError: (_) {
            if (!c.isCompleted) c.complete(null);
          },
        );

        final res = await c.future.timeout(
          const Duration(milliseconds: 3500),
          onTimeout: () => null,
        );
        await sub.cancel();
        tunnel.close();

        if (res != null) {
          final effectiveRtt = res.ttfbMs;
          final estimatedKbps =
              ((180000 ~/ max(effectiveRtt, 25)) + (res.totalBytes * 8 ~/ max(res.totalMs, 10)))
                  .clamp(64, 25600);
          return (
            latencyMs: effectiveRtt,
            tcpPingMs: tcpPing,
            speedKbps: estimatedKbps,
          );
        }
      } catch (_) {
        tunnel?.close();
      }
    }

    // Tunnel failed to deliver valid HTTP response -> mark node unreachable (-1)
    return (latencyMs: -1, tcpPingMs: tcpPing, speedKbps: 0);
  }

  static String _rewriteOriginFormHttpRequest(List<String> lines) {
    final sb = StringBuffer();
    if (lines.isNotEmpty) {
      final parts = lines.first.split(' ');
      if (parts.length >= 3) {
        final uri = Uri.tryParse(parts[1]);
        final pathAndQuery = (uri != null && uri.host.isNotEmpty)
            ? '${uri.path.isEmpty ? "/" : uri.path}${uri.hasQuery ? "?${uri.query}" : ""}'
            : parts[1];
        sb.write('${parts[0]} $pathAndQuery ${parts[2]}\r\n');
      } else {
        sb.write('${lines.first}\r\n');
      }
      for (final l in lines.skip(1)) {
        if (l.isEmpty) continue;
        if (l.toLowerCase().startsWith('proxy-connection:')) continue;
        sb.write('$l\r\n');
      }
    }
    sb.write('\r\n');
    return sb.toString();
  }
}

/// Central manager for Proxy Master Switch, Subscription Management,
/// Manual vs Auto-Fastest Node Switching, and Scenario-based Request Routing.
class ProxyRoutingService extends ChangeNotifier {
  static const _prefProxyEnabledKey = 'm3u8_proxy_enabled_v1';
  static const _prefSelectionModeKey = 'm3u8_proxy_selection_mode_v1';
  static const _prefSelectedNodeIdKey = 'm3u8_proxy_selected_node_id_v1';
  static const _prefSubscriptionsKey = 'm3u8_proxy_subscriptions_v1';
  static const _prefNodesKey = 'm3u8_proxy_nodes_v1';
  static const _prefScenarioRulesKey = 'm3u8_proxy_scenario_rules_v1';
  static const _prefAutoCheckMinutesKey = 'm3u8_proxy_auto_check_minutes_v1';

  bool _proxyEnabled = false;
  ProxySelectionMode _selectionMode = ProxySelectionMode.autoFastest;
  String? _selectedNodeId;
  List<ProxySubscription> _subscriptions = [];
  List<ProxyNode> _nodes = [];
  Map<RequestScenario, ScenarioRuleConfig> _scenarioRules = {
    for (final s in RequestScenario.values)
      s: ScenarioRuleConfig(scenario: s, mode: ScenarioRouteMode.followGlobal),
  };

  bool _isUpdatingSubscriptions = false;
  String? _updatingSubscriptionId;
  bool _isTestingNodes = false;
  String? _testingNodeId;
  String _lastStatusMessage = '';
  bool _lastStatusIsError = false;
  int _autoCheckIntervalMinutes = 10;
  Timer? _autoFastestTimer;
  bool _disposed = false;

  late final LocalProxyTunnelBridge _localBridge;
  final Map<String, LocalProxyTunnelBridge> _nodeBridges = {};
  final Map<String, int> _nodeFailureStreaks = {};
  int _lastAutoSwitchTimestampMs = 0;

  ProxyRoutingService() {
    _localBridge = LocalProxyTunnelBridge(
      resolveDefaultNode: () => activeNode,
      resolveFallbackNodes: () => _nodes
          .where((n) => n.enabled && !n.isInfoNode && n.isReachable)
          .toList()
        ..sort((a, b) => a.effectiveScore.compareTo(b.effectiveScore)),
      onNodeFeedback: _handleNodeRuntimeFeedback,
    );
  }

  /// Returns true if [node] is currently reachable and not failing consecutively.
  /// Used in `autoFastest` mode so we stay locked on the current working IP
  /// and NEVER jump around unless the current IP actually fails repeatedly.
  bool isNodeHealthyAndSmooth(ProxyNode node) {
    if (!node.enabled || node.isInfoNode || node.isTimeout) return false;
    final streak = _nodeFailureStreaks[node.id] ?? 0;
    if (streak >= 4) return false;
    final lat = node.latencyMs;
    if (lat == null || lat <= 0) return false;
    return true;
  }

  void _ensureAutoSelectedNodeLocked() {
    if (_selectionMode != ProxySelectionMode.autoFastest) return;
    final enabledNodes =
        _nodes.where((n) => n.enabled && !n.isInfoNode).toList();
    if (enabledNodes.isEmpty) return;

    ProxyNode? currentSelected;
    if (_selectedNodeId != null && _selectedNodeId!.isNotEmpty) {
      for (final n in enabledNodes) {
        if (n.id == _selectedNodeId) {
          currentSelected = n;
          break;
        }
      }
    }
    if (currentSelected != null && isNodeHealthyAndSmooth(currentSelected)) {
      return;
    }
    final fastest = fastestNode;
    if (fastest != null) {
      _selectedNodeId = fastest.id;
    } else if (currentSelected == null) {
      _selectedNodeId = enabledNodes.first.id;
    }
  }

  void _handleNodeRuntimeFeedback(
    String nodeId, {
    required bool success,
    int? rttMs,
  }) {
    if (_disposed) return;
    final idx = _nodes.indexWhere((n) => n.id == nodeId);
    if (idx < 0) return;
    final current = _nodes[idx];
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    if (!success) {
      final streak = (_nodeFailureStreaks[nodeId] ?? 0) + 1;
      _nodeFailureStreaks[nodeId] = streak;

      // Require 4 consecutive genuine connection failures AND a 15-second cooldown
      // before marking the node unreachable and switching to a backup node.
      final cooldownElapsed = _lastAutoSwitchTimestampMs == 0 ||
          (nowMs - _lastAutoSwitchTimestampMs >= 15000);
      if (streak >= 4 && cooldownElapsed) {
        _nodes[idx] = current.copyWith(
          latencyMs: -1,
          speedKbps: 0,
          lastTestedAtMs: nowMs,
        );
        if (_selectionMode == ProxySelectionMode.autoFastest &&
            (_selectedNodeId == null || _selectedNodeId == nodeId)) {
          final nextFastest = fastestNode;
          if (nextFastest != null && nextFastest.id != nodeId) {
            _selectedNodeId = nextFastest.id;
            _lastAutoSwitchTimestampMs = nowMs;
            _lastStatusIsError = false;
            _lastStatusMessage =
                '当前节点「${current.displayTitle}」连续连接失败，已自动切换至「${nextFastest.displayTitle}」';
          }
        }
        notifyListeners();
      }
    } else {
      _nodeFailureStreaks[nodeId] = 0;
      // Do NOT mutate `latencyMs` or call `notifyListeners()` if the node already has
      // a valid positive latency! Mutating latency on every HTTP request causes the
      // node list UI and `fastestNode` ranking to jump around continuously.
      if (current.latencyMs == null || current.latencyMs! <= 0) {
        _nodes[idx] = current.copyWith(
          latencyMs: (rttMs ?? 350).clamp(1, 9999),
          lastTestedAtMs: nowMs,
        );
        _ensureAutoSelectedNodeLocked();
        notifyListeners();
      } else {
        _ensureAutoSelectedNodeLocked();
      }
    }
  }

  /// Reports that video playback or streaming is stalling/buffering on the current proxy node.
  /// In `autoFastest` mode, marks the current node as lagging and switches to the next
  /// fastest healthy node (with a 15-second cooldown to prevent rapid oscillation).
  Future<ProxyNode?> reportActiveNodeLag({
    String reason = '视频缓冲卡顿',
  }) async {
    final current = activeNode;
    if (current == null) return null;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_lastAutoSwitchTimestampMs > 0 &&
        nowMs - _lastAutoSwitchTimestampMs < 15000) {
      return current;
    }

    final idx = _nodes.indexWhere((n) => n.id == current.id);
    if (idx >= 0) {
      _nodeFailureStreaks[current.id] = 4;
      _nodes[idx] = _nodes[idx].copyWith(
        latencyMs: -1,
        speedKbps: 0,
        lastTestedAtMs: nowMs,
      );
    }

    if (_selectionMode == ProxySelectionMode.autoFastest) {
      final nextFastest = fastestNode;
      if (nextFastest != null && nextFastest.id != current.id) {
        _selectedNodeId = nextFastest.id;
        _lastAutoSwitchTimestampMs = nowMs;
        _lastStatusIsError = false;
        _lastStatusMessage =
            '检测到$reason，已从「${current.displayTitle}」切换至「${nextFastest.displayTitle}」';
        notifyListeners();
        await _persistNodes();
        return nextFastest;
      }
    }
    notifyListeners();
    return activeNode;
  }

  Future<int> _ensureBridgeForNode(ProxyNode node) async {
    if (node.id == activeNode?.id) {
      return _localBridge.ensureStarted();
    }
    var bridge = _nodeBridges[node.id];
    if (bridge == null) {
      bridge = LocalProxyTunnelBridge(
        resolveDefaultNode: () => _nodes.firstWhere(
          (n) => n.id == node.id,
          orElse: () => node,
        ),
        resolveFallbackNodes: () => _nodes
            .where((n) => n.enabled && !n.isInfoNode && n.isReachable)
            .toList()
          ..sort((a, b) => a.effectiveScore.compareTo(b.effectiveScore)),
        onNodeFeedback: _handleNodeRuntimeFeedback,
      );
      _nodeBridges[node.id] = bridge;
    }
    return bridge.ensureStarted();
  }

  int _getBridgePortForNode(ProxyNode node) {
    if (node.id == activeNode?.id && _localBridge.port > 0) {
      return _localBridge.port;
    }
    final specific = _nodeBridges[node.id];
    if (specific != null && specific.port > 0) {
      return specific.port;
    }
    // Kick off async start for next request and fall back to default bridge port
    unawaited(_ensureBridgeForNode(node));
    return _localBridge.port;
  }

  // Getters
  bool get proxyEnabled => _proxyEnabled;
  ProxySelectionMode get selectionMode => _selectionMode;
  String? get selectedNodeId => _selectedNodeId;
  List<ProxySubscription> get subscriptions => List.unmodifiable(_subscriptions);
  List<ProxyNode> get nodes => List.unmodifiable(_nodes);
  Map<RequestScenario, ScenarioRuleConfig> get scenarioRules =>
      Map.unmodifiable(_scenarioRules);
  bool get isUpdatingSubscriptions => _isUpdatingSubscriptions;
  String? get updatingSubscriptionId => _updatingSubscriptionId;
  bool get isTestingNodes => _isTestingNodes;
  String? get testingNodeId => _testingNodeId;
  String get lastStatusMessage => _lastStatusMessage;
  bool get lastStatusIsError => _lastStatusIsError;
  int get autoCheckIntervalMinutes => _autoCheckIntervalMinutes;
  int get localBridgePort => _localBridge.port;

  /// Returns the fastest reachable enabled node ranked by real tunnel
  /// `effectiveScore` (combining real HTTP tunnel TTFB and transfer throughput).
  ProxyNode? get fastestNode {
    final candidates =
        _nodes.where((n) => n.enabled && n.isReachable).toList();
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => a.effectiveScore.compareTo(b.effectiveScore));
    return candidates.first;
  }

  /// Returns the currently active global proxy node based on [_selectionMode].
  /// In [ProxySelectionMode.autoFastest], keeps the currently locked [_selectedNodeId]
  /// as long as it is healthy and smooth (`isNodeHealthyAndSmooth`), and only switches
  /// to [fastestNode] when the current node is unset, lagging, or unreachable.
  ProxyNode? get activeNode {
    final enabledNodes =
        _nodes.where((n) => n.enabled && !n.isInfoNode).toList();
    if (enabledNodes.isEmpty) {
      final fallbackAll = _nodes.where((n) => n.enabled).toList();
      return fallbackAll.isEmpty ? null : fallbackAll.first;
    }

    ProxyNode? currentSelected;
    if (_selectedNodeId != null && _selectedNodeId!.isNotEmpty) {
      for (final n in enabledNodes) {
        if (n.id == _selectedNodeId) {
          currentSelected = n;
          break;
        }
      }
    }

    if (_selectionMode == ProxySelectionMode.manual) {
      return currentSelected ?? fastestNode ?? enabledNodes.first;
    }

    // In autoFastest mode: stay locked on `currentSelected` if it is healthy!
    if (currentSelected != null && isNodeHealthyAndSmooth(currentSelected)) {
      return currentSelected;
    }

    // Lock `_selectedNodeId` to `fastestNode` so it does not float when `currentSelected` was dead/unset.
    final next = fastestNode ?? currentSelected ?? enabledNodes.first;
    if (_selectedNodeId != next.id) {
      _selectedNodeId = next.id;
    }
    return next;
  }

  /// Returns the effective proxy node for a given [RequestScenario] when routed via proxy.
  ProxyNode? resolveNodeForScenario(RequestScenario scenario) {
    final rule = _scenarioRules[scenario];
    if (rule?.specificNodeId != null && rule!.specificNodeId!.isNotEmpty) {
      for (final n in _nodes) {
        if (n.id == rule.specificNodeId && n.enabled) {
          return n;
        }
      }
    }
    return activeNode;
  }

  /// Resolves the effective route action (`direct`, `proxyNode`, `serverRelay`)
  /// for a request under [scenario] targeting [targetUri].
  ScenarioRouteMode resolveEffectiveRoute(
    RequestScenario scenario, {
    Uri? targetUri,
  }) {
    final rule = _scenarioRules[scenario] ??
        ScenarioRuleConfig(scenario: scenario);

    if (rule.mode == ScenarioRouteMode.serverRelay) {
      return ScenarioRouteMode.serverRelay;
    }
    if (!_proxyEnabled) {
      return ScenarioRouteMode.direct;
    }

    switch (rule.mode) {
      case ScenarioRouteMode.direct:
        return ScenarioRouteMode.direct;
      case ScenarioRouteMode.serverRelay:
        return ScenarioRouteMode.serverRelay;
      case ScenarioRouteMode.proxyNode:
      case ScenarioRouteMode.followGlobal:
        return resolveNodeForScenario(scenario) != null
            ? ScenarioRouteMode.proxyNode
            : ScenarioRouteMode.direct;
      case ScenarioRouteMode.smartAuto:
        if (targetUri != null && _shouldBypassProxyInSmartMode(targetUri)) {
          return ScenarioRouteMode.direct;
        }
        return resolveNodeForScenario(scenario) != null
            ? ScenarioRouteMode.proxyNode
            : ScenarioRouteMode.direct;
    }
  }

  bool _shouldBypassProxyInSmartMode(Uri uri) {
    final host = uri.host.toLowerCase().trim();
    if (host.isEmpty) return true;
    if (host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host.contains(':')) {
      // Loopback or IPv6 literal streams go direct
      return true;
    }
    if (RegExp(r'^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)')
        .hasMatch(host)) {
      return true;
    }
    // Common overseas/restricted domains that benefit from proxy
    const proxyKeywords = [
      'telegram',
      't.me',
      'telegra.ph',
      'githubusercontent.com',
      'github.com',
      'google',
      'youtube',
      'youtu.be',
      'liangxin.xyz',
      'TMDB',
      'themoviedb.org',
      'jav',
      'missav',
      'pornhub',
      'xvideos',
      'twitter.com',
      'x.com',
      'discord',
      'cloudflare',
    ];
    for (final kw in proxyKeywords) {
      if (host.contains(kw.toLowerCase())) {
        return false; // Use proxy
      }
    }
    if (host.endsWith('.cn') ||
        host.endsWith('.qq.com') ||
        host.endsWith('.iqiyi.com') ||
        host.endsWith('.youku.com') ||
        host.endsWith('.mgtv.com') ||
        host.endsWith('.bilibili.com') ||
        host.endsWith('.115.com') ||
        host.endsWith('.baidupcs.com') ||
        host.endsWith('.aliyundrive.com')) {
      return true; // Domestic CDNs go direct
    }
    return false;
  }

  int get localBridgePrefetchedSegmentCount =>
      _localBridge.prefetchedSegmentCount;

  /// Resolves a video stream URL into a local HTTP stream relay URL
  /// (`http://127.0.0.1:<port>/__m3u8_proxy__/playlist.m3u8?...`) when [scenario]
  /// is routed via a client proxy node, or in direct mode for VOD M3U8 streams so
  /// [LocalProxyTunnelBridge] can concurrently prefetch `.ts` segments across
  /// multiple parallel connections (`maxConcurrentPrefetchWorkers = 4`).
  Future<String> resolveProxiedStreamUrl(
    RequestScenario scenario,
    String streamUrl, {
    Map<String, String> headers = const {},
    bool cleanM3u8Ads = false,
  }) async {
    final trimmed = streamUrl.trim();
    if (trimmed.isEmpty) return trimmed;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return trimmed;
    }
    if (uri.path.contains('/__m3u8_proxy__/')) {
      return trimmed;
    }
    final effective = resolveEffectiveRoute(scenario, targetUri: uri);
    if (effective != ScenarioRouteMode.proxyNode) {
      if (scenario == RequestScenario.vodStream &&
          trimmed.toLowerCase().contains('.m3u8') &&
          !uri.path.toLowerCase().startsWith('/api/vod/proxy')) {
        final directPort = await _localBridge.ensureStarted();
        if (directPort > 0) {
          return _localBridge.buildStreamRelayUrl(
            targetUrl: trimmed,
            headers: headers,
            cleanM3u8Ads: cleanM3u8Ads,
            forceDirect: true,
          );
        }
      }
      return trimmed;
    }
    final node = resolveNodeForScenario(scenario);
    if (node == null) return trimmed;

    final bridge = (node.id == activeNode?.id)
        ? _localBridge
        : (_nodeBridges[node.id] ?? _localBridge);
    final port = await _ensureBridgeForNode(node);
    if (port <= 0) return trimmed;

    return bridge.buildStreamRelayUrl(
      targetUrl: trimmed,
      headers: headers,
      cleanM3u8Ads: cleanM3u8Ads,
    );
  }

  /// Returns an `http://127.0.0.1:<port>` proxy URL for `media_kit` (`libmpv`)
  /// `http-proxy` property when the scenario should use a proxy node, or `''` for direct.
  /// Always routes through [LocalProxyTunnelBridge] so that if the active proxy node
  /// stalls or fails, `LocalProxyTunnelBridge` automatically switches to a backup node
  /// or falls back to direct connection without interrupting video playback.
  Future<String> resolvePlayerHttpProxyUrl(
    RequestScenario scenario, {
    Uri? streamUri,
  }) async {
    if (streamUri != null &&
        (streamUri.path.contains('/__m3u8_proxy__/') ||
            streamUri.host == '127.0.0.1' ||
            streamUri.host == 'localhost')) {
      return '';
    }
    final effective = resolveEffectiveRoute(scenario, targetUri: streamUri);
    if (effective != ScenarioRouteMode.proxyNode) {
      return '';
    }
    final node = resolveNodeForScenario(scenario);
    if (node == null) return '';

    final port = await _ensureBridgeForNode(node);
    if (port > 0) {
      return 'http://127.0.0.1:$port';
    }
    if (node.protocol == 'http' &&
        node.username.isEmpty &&
        node.password.isEmpty) {
      return 'http://${node.server}:${node.port}';
    }
    return '';
  }

  /// Returns the `HttpClient.findProxy` string (`PROXY host:port` or `DIRECT`)
  /// for a given [RequestScenario] and [uri].
  String resolveFindProxyDirective(RequestScenario scenario, Uri uri) {
    if (uri.host == '127.0.0.1' || uri.host == 'localhost') {
      return 'DIRECT';
    }
    final effective = resolveEffectiveRoute(scenario, targetUri: uri);
    if (effective != ScenarioRouteMode.proxyNode) {
      return 'DIRECT';
    }
    final node = resolveNodeForScenario(scenario);
    if (node == null) return 'DIRECT';

    if (node.protocol == 'http' &&
        node.username.isEmpty &&
        node.password.isEmpty) {
      return 'PROXY ${node.server}:${node.port}; DIRECT';
    }
    final bridgePort = _getBridgePortForNode(node);
    if (bridgePort > 0) {
      return 'PROXY 127.0.0.1:$bridgePort; DIRECT';
    }
    return 'DIRECT';
  }

  /// Initialize persisted proxy subscriptions, nodes, selection mode, and scenario rules.
  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _proxyEnabled = prefs.getBool(_prefProxyEnabledKey) ?? false;
      final modeStr = prefs.getString(_prefSelectionModeKey) ?? 'autoFastest';
      _selectionMode = ProxySelectionMode.values.firstWhere(
        (m) => m.name == modeStr,
        orElse: () => ProxySelectionMode.autoFastest,
      );
      _selectedNodeId = prefs.getString(_prefSelectedNodeIdKey);
      _autoCheckIntervalMinutes =
          prefs.getInt(_prefAutoCheckMinutesKey) ?? 10;

      final rawSubs = prefs.getString(_prefSubscriptionsKey);
      if (rawSubs != null && rawSubs.isNotEmpty) {
        final decoded = jsonDecode(rawSubs);
        if (decoded is List) {
          _subscriptions = decoded
              .whereType<Map<String, dynamic>>()
              .map(ProxySubscription.fromJson)
              .toList();
        }
      }

      // Ensure the default liangxin.xyz subscription is always pre-configured
      // if no subscriptions exist yet.
      if (_subscriptions.isEmpty) {
        _subscriptions = [
          const ProxySubscription(
            id: 'sub_liangxin_default',
            name: '良心云订阅 (liangxin.xyz)',
            url: kDefaultLiangxinSubscriptionUrl,
            enabled: true,
            autoUpdateHours: 12,
          ),
        ];
        await _saveSubscriptionsToPrefs(prefs);
      }

      final rawNodes = prefs.getString(_prefNodesKey);
      if (rawNodes != null && rawNodes.isNotEmpty) {
        final decoded = jsonDecode(rawNodes);
        if (decoded is List) {
          _nodes = decoded
              .whereType<Map<String, dynamic>>()
              .map(ProxyNode.fromJson)
              .toList();
        }
      }

      final rawRules = prefs.getString(_prefScenarioRulesKey);
      if (rawRules != null && rawRules.isNotEmpty) {
        final decoded = jsonDecode(rawRules);
        if (decoded is Map) {
          for (final s in RequestScenario.values) {
            final item = decoded[s.name];
            if (item is Map) {
              _scenarioRules[s] = ScenarioRuleConfig.fromJson(
                s,
                Map<String, dynamic>.from(item),
              );
            }
          }
        }
      }
    } catch (_) {}

    _ensureAutoSelectedNodeLocked();
    if (_proxyEnabled) {
      await _localBridge.ensureStarted();
      _configureAutoFastestTimer();
    }
    notifyListeners();
  }

  void _configureAutoFastestTimer() {
    _autoFastestTimer?.cancel();
    if (!_proxyEnabled ||
        _selectionMode != ProxySelectionMode.autoFastest ||
        _autoCheckIntervalMinutes <= 0) {
      return;
    }
    _autoFastestTimer = Timer.periodic(
      Duration(minutes: _autoCheckIntervalMinutes),
      (_) {
        if (_proxyEnabled && _selectionMode == ProxySelectionMode.autoFastest) {
          final current = activeNode;
          if (current == null || !isNodeHealthyAndSmooth(current)) {
            testAllNodesLatency(silent: true);
          }
        }
      },
    );
  }

  /// Enable or disable the global proxy master switch.
  Future<void> setProxyEnabled(bool enabled) async {
    _proxyEnabled = enabled;
    if (enabled) {
      await _localBridge.ensureStarted();
      _configureAutoFastestTimer();
      // If autoFastest is selected and no node has been benchmarked yet, trigger speed test
      if (_selectionMode == ProxySelectionMode.autoFastest &&
          fastestNode == null &&
          _nodes.isNotEmpty) {
        unawaited(testAllNodesLatency(silent: true));
      }
      _lastStatusMessage = _selectionMode == ProxySelectionMode.autoFastest
          ? '已开启代理（自动切换到最快代理节点）'
          : '已开启代理（当前节点：${activeNode?.displayTitle ?? "未选择"}）';
    } else {
      _autoFastestTimer?.cancel();
      _lastStatusMessage = '已关闭全局代理，请求将按默认直连或场景独立规则执行';
    }
    _lastStatusIsError = false;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefProxyEnabledKey, enabled);
    } catch (_) {}
  }

  /// Switch between `manual` and `autoFastest` proxy selection modes.
  Future<void> setSelectionMode(ProxySelectionMode mode) async {
    _selectionMode = mode;
    _configureAutoFastestTimer();
    if (mode == ProxySelectionMode.autoFastest) {
      final fastest = fastestNode;
      if (fastest != null) {
        _selectedNodeId = fastest.id;
        _lastStatusMessage =
            '已切换为「自动最快代理」：当前最快 ${fastest.displayTitle} (${fastest.latencyMs} ms)';
      } else if (_nodes.isNotEmpty) {
        _lastStatusMessage = '已切换为「自动最快代理」，正在并发测速选优...';
        unawaited(testAllNodesLatency(silent: true));
      } else {
        _lastStatusMessage = '已切换为「自动最快代理」，请先更新订阅或导入节点';
      }
    } else {
      _lastStatusMessage =
          '已切换为「手动选择代理」：当前锁定 ${activeNode?.displayTitle ?? "未选择"}';
    }
    _lastStatusIsError = false;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefSelectionModeKey, mode.name);
      if (_selectedNodeId != null) {
        await prefs.setString(_prefSelectedNodeIdKey, _selectedNodeId!);
      }
    } catch (_) {}
  }

  /// Manually select a proxy node (and optionally switch to manual mode).
  Future<void> selectNode(
    String nodeId, {
    bool switchToManual = true,
  }) async {
    _selectedNodeId = nodeId;
    if (switchToManual) {
      _selectionMode = ProxySelectionMode.manual;
      _configureAutoFastestTimer();
    }
    await _localBridge.ensureStarted();
    final node = activeNode;
    _lastStatusIsError = false;
    final speedSuffix =
        (node != null && node.speedLabel.isNotEmpty) ? ' · ${node.speedLabel}' : '';
    _lastStatusMessage = node != null
        ? '已切换代理节点：${node.displayTitle} (${node.protocolBadge}$speedSuffix)'
        : '已更新选中节点';
    notifyListeners();
    // Verify real tunnel connectivity & throughput in background if untested
    if (node != null && (node.latencyMs == null || node.latencyMs! <= 0)) {
      unawaited(testSingleNodeLatency(node.id));
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefSelectedNodeIdKey, nodeId);
      if (switchToManual) {
        await prefs.setString(
          _prefSelectionModeKey,
          ProxySelectionMode.manual.name,
        );
      }
    } catch (_) {}
  }

  /// Update routing rule for a specific [RequestScenario].
  Future<void> updateScenarioRule(
    RequestScenario scenario, {
    ScenarioRouteMode? mode,
    String? specificNodeId,
    bool clearSpecificNode = false,
  }) async {
    final current =
        _scenarioRules[scenario] ?? ScenarioRuleConfig(scenario: scenario);
    final updated = current.copyWith(
      mode: mode,
      specificNodeId: specificNodeId,
      clearSpecificNode: clearSpecificNode,
    );
    _scenarioRules[scenario] = updated;
    if (updated.mode == ScenarioRouteMode.proxyNode ||
        updated.mode == ScenarioRouteMode.smartAuto ||
        updated.mode == ScenarioRouteMode.followGlobal) {
      await _localBridge.ensureStarted();
      final specific = resolveNodeForScenario(scenario);
      if (specific != null) {
        await _ensureBridgeForNode(specific);
      }
    }
    _lastStatusIsError = false;
    _lastStatusMessage =
        '已更新「${scenario.label}」路由策略为：${updated.mode.label}';
    notifyListeners();
    await _persistScenarioRules();
  }

  /// Apply a one-click scenario routing preset across all scenarios.
  Future<void> applyScenarioPreset(String presetId) async {
    switch (presetId) {
      case 'smart_recommended':
        _scenarioRules = {
          RequestScenario.vodApi: const ScenarioRuleConfig(
            scenario: RequestScenario.vodApi,
            mode: ScenarioRouteMode.smartAuto,
          ),
          RequestScenario.vodStream: const ScenarioRuleConfig(
            scenario: RequestScenario.vodStream,
            mode: ScenarioRouteMode.smartAuto,
          ),
          RequestScenario.liveStream: const ScenarioRuleConfig(
            scenario: RequestScenario.liveStream,
            mode: ScenarioRouteMode.direct,
          ),
          RequestScenario.telegram: const ScenarioRuleConfig(
            scenario: RequestScenario.telegram,
            mode: ScenarioRouteMode.proxyNode,
          ),
          RequestScenario.backendApi: const ScenarioRuleConfig(
            scenario: RequestScenario.backendApi,
            mode: ScenarioRouteMode.direct,
          ),
          RequestScenario.externalWeb: const ScenarioRuleConfig(
            scenario: RequestScenario.externalWeb,
            mode: ScenarioRouteMode.proxyNode,
          ),
        };
        _lastStatusMessage =
            '已应用「推荐智能分流预设」：Telegram/订阅走代理，点播智能分流，直播与主控直连';
        break;
      case 'all_proxy':
        for (final s in RequestScenario.values) {
          _scenarioRules[s] = ScenarioRuleConfig(
            scenario: s,
            mode: ScenarioRouteMode.proxyNode,
          );
        }
        _lastStatusMessage = '已应用「全场景强制代理」：所有场景请求均通过代理节点转发';
        break;
      case 'follow_global':
        for (final s in RequestScenario.values) {
          _scenarioRules[s] = ScenarioRuleConfig(
            scenario: s,
            mode: ScenarioRouteMode.followGlobal,
          );
        }
        _lastStatusMessage = '已应用「全部跟随全局开关」';
        break;
      case 'telegram_only':
        for (final s in RequestScenario.values) {
          _scenarioRules[s] = ScenarioRuleConfig(
            scenario: s,
            mode: (s == RequestScenario.telegram ||
                    s == RequestScenario.externalWeb)
                ? ScenarioRouteMode.proxyNode
                : ScenarioRouteMode.direct,
          );
        }
        _lastStatusMessage = '已应用「仅 Telegram 与外部嗅探走代理」，其余场景全部直连';
        break;
      case 'server_relay':
        _scenarioRules = {
          RequestScenario.vodApi: const ScenarioRuleConfig(
            scenario: RequestScenario.vodApi,
            mode: ScenarioRouteMode.serverRelay,
          ),
          RequestScenario.vodStream: const ScenarioRuleConfig(
            scenario: RequestScenario.vodStream,
            mode: ScenarioRouteMode.serverRelay,
          ),
          RequestScenario.liveStream: const ScenarioRuleConfig(
            scenario: RequestScenario.liveStream,
            mode: ScenarioRouteMode.serverRelay,
          ),
          RequestScenario.telegram: const ScenarioRuleConfig(
            scenario: RequestScenario.telegram,
            mode: ScenarioRouteMode.followGlobal,
          ),
          RequestScenario.backendApi: const ScenarioRuleConfig(
            scenario: RequestScenario.backendApi,
            mode: ScenarioRouteMode.direct,
          ),
          RequestScenario.externalWeb: const ScenarioRuleConfig(
            scenario: RequestScenario.externalWeb,
            mode: ScenarioRouteMode.followGlobal,
          ),
        };
        _lastStatusMessage = '已应用「服务端中转优先预设」：点播与直播均通过主服务器中转';
        break;
    }
    _lastStatusIsError = false;
    await _localBridge.ensureStarted();
    notifyListeners();
    await _persistScenarioRules();
  }

  /// Add or update a subscription URL.
  Future<ProxySubscription> upsertSubscription({
    String? id,
    required String name,
    required String url,
    bool enabled = true,
    int autoUpdateHours = 12,
    String customUserAgent = '',
  }) async {
    final cleanUrl = url.trim();
    final cleanName = name.trim().isEmpty ? '代理订阅' : name.trim();
    final targetId = (id != null && id.isNotEmpty)
        ? id
        : 'sub_${DateTime.now().millisecondsSinceEpoch}';

    final idx = _subscriptions.indexWhere((s) => s.id == targetId || s.url == cleanUrl);
    ProxySubscription sub;
    if (idx >= 0) {
      sub = _subscriptions[idx].copyWith(
        name: cleanName,
        url: cleanUrl,
        enabled: enabled,
        autoUpdateHours: autoUpdateHours,
        customUserAgent: customUserAgent,
      );
      _subscriptions[idx] = sub;
    } else {
      sub = ProxySubscription(
        id: targetId,
        name: cleanName,
        url: cleanUrl,
        enabled: enabled,
        autoUpdateHours: autoUpdateHours,
        customUserAgent: customUserAgent,
      );
      _subscriptions.add(sub);
    }
    notifyListeners();
    await _persistSubscriptions();
    return sub;
  }

  /// Delete a subscription and all nodes belonging to it.
  Future<void> deleteSubscription(String subscriptionId) async {
    _subscriptions.removeWhere((s) => s.id == subscriptionId);
    _nodes.removeWhere((n) => n.subscriptionId == subscriptionId);
    if (_selectedNodeId != null &&
        !_nodes.any((n) => n.id == _selectedNodeId)) {
      _selectedNodeId = activeNode?.id;
    }
    _lastStatusIsError = false;
    _lastStatusMessage = '已删除订阅及其关联节点';
    notifyListeners();
    await _persistSubscriptions();
    await _persistNodes();
  }

  /// Fetch and parse a single [ProxySubscription] from its remote URL.
  /// Tries multiple popular proxy client User-Agents and fallback flags (`&flag=clash`, `&flag=v2ray`).
  Future<int> refreshSubscription(
    String subscriptionId, {
    Future<String?> Function(String url)? serverFetchFallback,
  }) async {
    final subIdx = _subscriptions.indexWhere((s) => s.id == subscriptionId);
    if (subIdx < 0) return 0;
    final sub = _subscriptions[subIdx];

    _isUpdatingSubscriptions = true;
    _updatingSubscriptionId = subscriptionId;
    _lastStatusIsError = false;
    _lastStatusMessage = '正在拉取订阅「${sub.name}」...';
    notifyListeners();

    final ioClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
    final client = IOClient(ioClient);

    try {
      final baseUri = Uri.parse(sub.url.trim());
      final customUa = sub.customUserAgent.trim();
      final attempts = <({Uri uri, String ua})>[
        (
          uri: baseUri,
          ua: customUa.isNotEmpty ? customUa : 'v2rayNG/1.8.19',
        ),
        (
          uri: baseUri.queryParameters.containsKey('flag')
              ? baseUri
              : baseUri.replace(
                  queryParameters: {...baseUri.queryParameters, 'flag': 'clash'},
                ),
          ua: customUa.isNotEmpty ? customUa : 'Clash.Meta/v1.18.0',
        ),
      ];

      List<ProxyNode> parsedNodes = const [];
      Map<String, String> lastHeaders = const {};
      String lastHttpError = '';

      for (final attempt in attempts) {
        try {
          final resp = await client
              .get(
                attempt.uri,
                headers: {
                  'User-Agent': attempt.ua,
                  'Accept': '*/*',
                },
              )
              .timeout(const Duration(seconds: 8));

          lastHeaders = resp.headers;
          final body =
              utf8.decode(resp.bodyBytes, allowMalformed: true).trim();

          if (resp.statusCode >= 200 && resp.statusCode < 300) {
            final nodes = ProxySubscriptionParser.parseSubscriptionContent(
              body,
              subscriptionId: subscriptionId,
            );
            if (nodes.isNotEmpty) {
              parsedNodes = nodes;
              break;
            }
          } else {
            final lower = body.toLowerCase();
            if (lower.contains('token is error')) {
              lastHttpError =
                  'HTTP ${resp.statusCode}: 订阅 Token 无效或已过期 (token is error)';
              break;
            } else if (resp.statusCode == 403) {
              lastHttpError =
                  'HTTP 403: 订阅源拒绝访问或 Token 已失效（也可点击「粘贴导入节点」直接导入）';
            } else {
              lastHttpError = 'HTTP ${resp.statusCode}';
            }
          }
        } catch (e) {
          lastHttpError = e.toString().replaceAll('\n', ' ');
        }
      }

      // Optional fallback via backend server if direct client fetch was blocked
      if (parsedNodes.isEmpty && serverFetchFallback != null) {
        try {
          final fallbackText = await serverFetchFallback(sub.url.trim());
          if (fallbackText != null && fallbackText.isNotEmpty) {
            parsedNodes = ProxySubscriptionParser.parseSubscriptionContent(
              fallbackText,
              subscriptionId: subscriptionId,
            );
          }
        } catch (_) {}
      }

      if (parsedNodes.isEmpty) {
        final errText = lastHttpError.isNotEmpty
            ? lastHttpError
            : '未能从订阅响应中解析出有效代理节点';
        _subscriptions[subIdx] = sub.copyWith(
          lastError: errText,
          lastUpdatedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
        _lastStatusIsError = true;
        _lastStatusMessage =
            '更新「${sub.name}」失败：$errText（可使用「粘贴导入」或检查订阅地址）';
        await _persistSubscriptions();
        return 0;
      }

      final userInfo = ProxySubscriptionParser.parseUserInfoHeader(lastHeaders);
      _mergeSubscriptionNodes(subscriptionId, parsedNodes);

      final updatedSub = sub.copyWith(
        lastUpdatedAtMs: DateTime.now().millisecondsSinceEpoch,
        nodeCount: parsedNodes.length,
        uploadBytes: userInfo.upload ?? sub.uploadBytes,
        downloadBytes: userInfo.download ?? sub.downloadBytes,
        totalBytes: userInfo.total ?? sub.totalBytes,
        expireTimestampSec: userInfo.expire ?? sub.expireTimestampSec,
        lastError: '',
      );
      _subscriptions[subIdx] = updatedSub;
      _lastStatusIsError = false;
      _lastStatusMessage =
          '订阅「${sub.name}」更新成功：共解析 ${parsedNodes.length} 个代理节点，正在自动测速...';

      await _persistSubscriptions();
      await _persistNodes();
      notifyListeners();

      // Automatically benchmark newly fetched nodes
      unawaited(testAllNodesLatency(silent: true));
      return parsedNodes.length;
    } finally {
      client.close();
      _isUpdatingSubscriptions = false;
      _updatingSubscriptionId = null;
      notifyListeners();
    }
  }

  /// Refresh all enabled subscriptions.
  Future<int> refreshAllSubscriptions() async {
    int total = 0;
    for (final s in _subscriptions.where((s) => s.enabled).toList()) {
      total += await refreshSubscription(s.id);
    }
    return total;
  }

  /// Import nodes from pasted raw text (Base64, Clash YAML, or `ss://`/`trojan://`/`vmess://` URI links).
  Future<int> importNodesFromRawText(
    String rawText, {
    String targetSubscriptionId = 'sub_liangxin_default',
  }) async {
    final parsed = ProxySubscriptionParser.parseSubscriptionContent(
      rawText,
      subscriptionId: targetSubscriptionId,
    );
    if (parsed.isEmpty) {
      _lastStatusIsError = true;
      _lastStatusMessage =
          '未识别到有效节点，支持粘贴 Base64 订阅内容、Clash YAML 或 ss:///trojan:///vmess:///vless:///socks5:// 节点链接';
      notifyListeners();
      return 0;
    }

    _mergeSubscriptionNodes(targetSubscriptionId, parsed, appendMode: true);
    final subIdx =
        _subscriptions.indexWhere((s) => s.id == targetSubscriptionId);
    if (subIdx >= 0) {
      final countForSub =
          _nodes.where((n) => n.subscriptionId == targetSubscriptionId).length;
      _subscriptions[subIdx] = _subscriptions[subIdx].copyWith(
        nodeCount: countForSub,
        lastUpdatedAtMs: DateTime.now().millisecondsSinceEpoch,
        lastError: '',
      );
      await _persistSubscriptions();
    }
    await _persistNodes();
    _lastStatusIsError = false;
    _lastStatusMessage = '成功导入 ${parsed.length} 个代理节点，正在自动测速...';
    notifyListeners();
    unawaited(testAllNodesLatency(silent: true));
    return parsed.length;
  }

  /// Sync self-hosted proxy services configured on the backend (`/api/proxy`)
  /// into the client proxy node pool so they can be used immediately.
  Future<int> syncNodesFromServerServices(
    List<ProxyServiceConfig> services,
    String serverBaseUrl,
  ) async {
    final serverUri = Uri.tryParse(serverBaseUrl);
    final fallbackHost = (serverUri != null && serverUri.host.isNotEmpty)
        ? serverUri.host
        : '127.0.0.1';

    final synced = <ProxyNode>[];
    for (var i = 0; i < services.length; i++) {
      final s = services[i];
      if (!s.enabled) continue;
      final lh = s.listenHost.trim();
      final host = (lh.isEmpty ||
              lh == '0.0.0.0' ||
              lh == '::' ||
              lh == '127.0.0.1' ||
              lh == 'localhost')
          ? fallbackHost
          : lh;

      synced.add(
        ProxyNode(
          id: 'server_proxy_${s.id}',
          subscriptionId: 'server',
          name: s.name.isNotEmpty ? '服务端 · ${s.name}' : '服务端 ${s.protocolLabel}:${s.port}',
          protocol: s.protocol,
          server: host,
          port: s.port,
          username: s.username,
          password: s.password,
          cipher: s.cipher,
          sni: host,
          skipCertVerify: true,
          tls: s.protocol == 'trojan',
        ),
      );
    }

    _mergeSubscriptionNodes('server', synced);
    await _persistNodes();
    _lastStatusIsError = false;
    _lastStatusMessage = synced.isNotEmpty
        ? '已从服务端同步 ${synced.length} 个自建代理节点，正在测速...'
        : '服务端暂无已启用的代理监听服务';
    notifyListeners();
    if (synced.isNotEmpty) {
      unawaited(testAllNodesLatency(silent: true));
    }
    return synced.length;
  }

  void _mergeSubscriptionNodes(
    String subscriptionId,
    List<ProxyNode> incoming, {
    bool appendMode = false,
  }) {
    final existingByKey = <String, ProxyNode>{};
    for (final n in _nodes) {
      if (n.subscriptionId == subscriptionId) {
        existingByKey['${n.protocol}|${n.server}|${n.port}|${n.name}'] = n;
      }
    }

    final mergedForSub = <ProxyNode>[
      if (appendMode)
        ..._nodes.where((n) => n.subscriptionId == subscriptionId),
    ];

    for (final node in incoming) {
      final key = '${node.protocol}|${node.server}|${node.port}|${node.name}';
      final prev = existingByKey[key];
      final resolvedNode = prev != null
          ? node.copyWith(
              id: prev.id,
              enabled: prev.enabled,
              favorite: prev.favorite,
              latencyMs: prev.latencyMs,
              tcpPingMs: prev.tcpPingMs,
              speedKbps: prev.speedKbps,
              lastTestedAtMs: prev.lastTestedAtMs,
            )
          : node;
      final existingIdx = mergedForSub.indexWhere(
        (e) =>
            '${e.protocol}|${e.server}|${e.port}|${e.name}' == key ||
            e.id == resolvedNode.id,
      );
      if (existingIdx >= 0) {
        mergedForSub[existingIdx] = resolvedNode;
      } else {
        mergedForSub.add(resolvedNode);
      }
    }

    _nodes = [
      ..._nodes.where((n) => n.subscriptionId != subscriptionId),
      ...mergedForSub,
    ];

    if (_selectedNodeId == null ||
        !_nodes.any((n) => n.id == _selectedNodeId)) {
      _selectedNodeId = activeNode?.id;
    }
  }

  /// Manually add or update a single [ProxyNode].
  Future<void> upsertManualNode(
    ProxyNode node, {
    bool testLatency = true,
  }) async {
    final idx = _nodes.indexWhere((n) => n.id == node.id);
    if (idx >= 0) {
      _nodes[idx] = node;
    } else {
      _nodes.insert(0, node);
    }
    _selectedNodeId ??= node.id;
    _lastStatusIsError = false;
    _lastStatusMessage = '已保存代理节点：${node.displayTitle}';
    notifyListeners();
    await _persistNodes();
    if (testLatency) {
      unawaited(testSingleNodeLatency(node.id));
    }
  }

  /// Toggle favorite/pin status of a node.
  Future<void> toggleNodeFavorite(String nodeId) async {
    final idx = _nodes.indexWhere((n) => n.id == nodeId);
    if (idx < 0) return;
    _nodes[idx] = _nodes[idx].copyWith(favorite: !_nodes[idx].favorite);
    notifyListeners();
    await _persistNodes();
  }

  /// Toggle enabled status of a node.
  Future<void> toggleNodeEnabled(String nodeId, bool enabled) async {
    final idx = _nodes.indexWhere((n) => n.id == nodeId);
    if (idx < 0) return;
    _nodes[idx] = _nodes[idx].copyWith(enabled: enabled);
    notifyListeners();
    await _persistNodes();
  }

  /// Delete a single node.
  Future<void> deleteNode(String nodeId) async {
    _nodes.removeWhere((n) => n.id == nodeId);
    if (_selectedNodeId == nodeId) {
      _selectedNodeId = activeNode?.id;
    }
    notifyListeners();
    await _persistNodes();
  }

  /// Remove all unreachable/timeout nodes.
  Future<int> removeUnreachableNodes() async {
    final before = _nodes.length;
    _nodes.removeWhere((n) => n.isTimeout);
    final removed = before - _nodes.length;
    if (_selectedNodeId != null &&
        !_nodes.any((n) => n.id == _selectedNodeId)) {
      _selectedNodeId = activeNode?.id;
    }
    _lastStatusIsError = false;
    _lastStatusMessage = '已清理 $removed 个超时失效节点';
    notifyListeners();
    await _persistNodes();
    return removed;
  }

  /// Benchmark a single proxy node's real end-to-end tunnel latency and transfer speed.
  Future<int> testSingleNodeLatency(String nodeId) async {
    final idx = _nodes.indexWhere((n) => n.id == nodeId);
    if (idx < 0) return -1;
    final node = _nodes[idx];

    _testingNodeId = nodeId;
    notifyListeners();

    final metrics = await _measureNodeMetrics(node);
    final updatedIdx = _nodes.indexWhere((n) => n.id == nodeId);
    if (updatedIdx >= 0) {
      _nodes[updatedIdx] = _nodes[updatedIdx].copyWith(
        latencyMs: metrics.latencyMs,
        tcpPingMs: metrics.tcpPingMs,
        speedKbps: metrics.speedKbps,
        lastTestedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
    }
    _testingNodeId = null;

    if (metrics.latencyMs > 0) {
      _nodeFailureStreaks[nodeId] = 0;
    }

    if (_selectionMode == ProxySelectionMode.autoFastest) {
      final current = _selectedNodeId != null
          ? _nodes.where((n) => n.id == _selectedNodeId).firstOrNull
          : null;
      if (current == null || !isNodeHealthyAndSmooth(current)) {
        final fastest = fastestNode;
        if (fastest != null) {
          _selectedNodeId = fastest.id;
        }
      }
    }
    notifyListeners();
    await _persistNodes();
    return metrics.latencyMs;
  }

  /// Benchmark all enabled proxy nodes concurrently with real end-to-end tunnel HTTP
  /// probing. In [ProxySelectionMode.autoFastest], keeps the current node if it is
  /// healthy and smooth (`isNodeHealthyAndSmooth`), and only switches to [fastestNode]
  /// when no node is selected yet or the current node is lagging/timeout.
  Future<void> testAllNodesLatency({bool silent = false}) async {
    if (_isTestingNodes || _nodes.isEmpty) return;
    _isTestingNodes = true;
    if (!silent) {
      _lastStatusIsError = false;
      _lastStatusMessage =
          '正在对 ${_nodes.length} 个代理节点执行真实隧道连通性与带宽测速...';
    }
    notifyListeners();

    try {
      const batchSize = 8;
      for (var i = 0; i < _nodes.length; i += batchSize) {
        if (_disposed) return;
        final batch = _nodes.skip(i).take(batchSize).toList();
        final results = await Future.wait(
          batch.map((n) async => MapEntry(n.id, await _measureNodeMetrics(n))),
        );
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        for (final entry in results) {
          final idx = _nodes.indexWhere((n) => n.id == entry.key);
          if (idx >= 0) {
            if (entry.value.latencyMs > 0) {
              _nodeFailureStreaks[entry.key] = 0;
            }
            _nodes[idx] = _nodes[idx].copyWith(
              latencyMs: entry.value.latencyMs,
              tcpPingMs: entry.value.tcpPingMs,
              speedKbps: entry.value.speedKbps,
              lastTestedAtMs: nowMs,
            );
          }
        }
        // Only auto-select during batch progress if no healthy node is currently locked
        if (_selectionMode == ProxySelectionMode.autoFastest) {
          final current = _selectedNodeId != null
              ? _nodes.where((n) => n.id == _selectedNodeId).firstOrNull
              : null;
          if (current == null || !isNodeHealthyAndSmooth(current)) {
            final currentFastest = fastestNode;
            if (currentFastest != null) {
              _selectedNodeId = currentFastest.id;
            }
          }
        }
        notifyListeners();
      }

      final fastest = fastestNode;
      if (_selectionMode == ProxySelectionMode.autoFastest && fastest != null) {
        final current = _selectedNodeId != null
            ? _nodes.where((n) => n.id == _selectedNodeId).firstOrNull
            : null;
        if (current != null && isNodeHealthyAndSmooth(current)) {
          // Keep current smooth node — do NOT switch unnecessarily!
          if (!silent) {
            _lastStatusIsError = false;
            final curSpeed =
                current.speedLabel.isNotEmpty ? ' · ${current.speedLabel}' : '';
            _lastStatusMessage =
                '测速完成：当前节点「${current.displayTitle}」(${current.latencyMs} ms$curSpeed) 稳定流畅，保持不切换（备选最快：${fastest.displayTitle}）';
          }
        } else {
          _selectedNodeId = fastest.id;
          if (!silent) {
            _lastStatusIsError = false;
            final speedTag =
                fastest.speedLabel.isNotEmpty ? ' · ${fastest.speedLabel}' : '';
            _lastStatusMessage =
                '真实隧道测速完成，已切换到可用最快节点：${fastest.displayTitle} (${fastest.latencyMs} ms$speedTag)';
          }
        }
      } else if (!silent) {
        final reachableCount = _nodes.where((n) => n.isReachable).length;
        _lastStatusIsError = reachableCount == 0;
        final speedTag = (fastest != null && fastest.speedLabel.isNotEmpty)
            ? ' · ${fastest.speedLabel}'
            : '';
        _lastStatusMessage = reachableCount > 0
            ? '真实隧道测速完成：$reachableCount / ${_nodes.length} 个节点可用，最优 ${fastest?.displayTitle ?? ""} (${fastest?.latencyMs ?? "-"} ms$speedTag)'
            : '真实隧道测速完成：所有节点均无法完成端到端代理请求，请检查网络或更新订阅';
      }
      await _persistNodes();
    } finally {
      _isTestingNodes = false;
      notifyListeners();
    }
  }

  /// Measures a proxy node's real end-to-end tunnel HTTP latency (`latencyMs`),
  /// entry TCP ping (`tcpPingMs`), and effective payload throughput (`speedKbps`).
  Future<({int latencyMs, int tcpPingMs, int speedKbps})> _measureNodeMetrics(
    ProxyNode node,
  ) async {
    return LocalProxyTunnelBridge.probeNodeRealSpeed(node);
  }

  Future<void> _persistSubscriptions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _saveSubscriptionsToPrefs(prefs);
    } catch (_) {}
  }

  Future<void> _saveSubscriptionsToPrefs(SharedPreferences prefs) async {
    await prefs.setString(
      _prefSubscriptionsKey,
      jsonEncode(_subscriptions.map((s) => s.toJson()).toList()),
    );
  }

  Future<void> _persistNodes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefNodesKey,
        jsonEncode(_nodes.map((n) => n.toJson()).toList()),
      );
      if (_selectedNodeId != null && _selectedNodeId!.isNotEmpty) {
        await prefs.setString(_prefSelectedNodeIdKey, _selectedNodeId!);
      }
    } catch (_) {}
  }

  Future<void> _persistScenarioRules() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = <String, dynamic>{};
      _scenarioRules.forEach((k, v) {
        map[k.name] = v.toJson();
      });
      await prefs.setString(_prefScenarioRulesKey, jsonEncode(map));
    } catch (_) {}
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _autoFastestTimer?.cancel();
    _localBridge.stop();
    for (final b in _nodeBridges.values) {
      b.stop();
    }
    _nodeBridges.clear();
    super.dispose();
  }
}
