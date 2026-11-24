import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'tv_platform_service.dart';

class PeerDeviceNode {
  final String deviceId;
  final String deviceName;
  final String platform;
  final String host;
  final int port;
  final bool isTv;
  final int activeTabIndex;
  final String activeTabName;
  final String nowPlayingTitle;
  final bool isPlaying;
  final bool supportsDesktopCapture;
  final DateTime lastSeenAt;
  final bool isManual;
  final bool isLanReachable;
  final List<String> candidateIps;

  const PeerDeviceNode({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.host,
    required this.port,
    this.isTv = false,
    this.activeTabIndex = 0,
    this.activeTabName = '影视片库',
    this.nowPlayingTitle = '',
    this.isPlaying = false,
    this.supportsDesktopCapture = false,
    required this.lastSeenAt,
    this.isManual = false,
    this.isLanReachable = true,
    this.candidateIps = const [],
  });

  bool get isOnline => DateTime.now().difference(lastSeenAt).inSeconds < 25;

  String get connectionModeLabel =>
      isLanReachable ? '局域网直连' : '跨网云端互通';

  String get baseUrl => 'http://$host:$port';

  String get wsUrl => 'ws://$host:$port/api/peer/ws';

  String get platformLabel {
    switch (platform.toLowerCase()) {
      case 'macos':
        return 'macOS';
      case 'ios':
        return 'iOS / iPadOS';
      case 'android':
        return isTv ? 'Android TV' : 'Android';
      case 'windows':
        return 'Windows';
      case 'linux':
        return 'Linux';
      case 'tvos':
        return 'Apple TV';
      default:
        return platform;
    }
  }

  PeerDeviceNode copyWith({
    String? deviceName,
    String? platform,
    String? host,
    int? port,
    bool? isTv,
    int? activeTabIndex,
    String? activeTabName,
    String? nowPlayingTitle,
    bool? isPlaying,
    bool? supportsDesktopCapture,
    DateTime? lastSeenAt,
    bool? isManual,
    bool? isLanReachable,
    List<String>? candidateIps,
  }) {
    return PeerDeviceNode(
      deviceId: deviceId,
      deviceName: deviceName ?? this.deviceName,
      platform: platform ?? this.platform,
      host: host ?? this.host,
      port: port ?? this.port,
      isTv: isTv ?? this.isTv,
      activeTabIndex: activeTabIndex ?? this.activeTabIndex,
      activeTabName: activeTabName ?? this.activeTabName,
      nowPlayingTitle: nowPlayingTitle ?? this.nowPlayingTitle,
      isPlaying: isPlaying ?? this.isPlaying,
      supportsDesktopCapture:
          supportsDesktopCapture ?? this.supportsDesktopCapture,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      isManual: isManual ?? this.isManual,
      isLanReachable: isLanReachable ?? this.isLanReachable,
      candidateIps: candidateIps ?? this.candidateIps,
    );
  }

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'platform': platform,
        'host': host,
        'port': port,
        'isTv': isTv,
        'activeTabIndex': activeTabIndex,
        'activeTabName': activeTabName,
        'nowPlayingTitle': nowPlayingTitle,
        'isPlaying': isPlaying,
        'supportsDesktopCapture': supportsDesktopCapture,
        'lastSeenAtMs': lastSeenAt.millisecondsSinceEpoch,
        'isManual': isManual,
        'isLanReachable': isLanReachable,
        'candidateIps': candidateIps,
      };

  factory PeerDeviceNode.fromJson(
    Map<String, dynamic> json, {
    String? fallbackHost,
    bool? isManualOverride,
    bool? isLanReachableOverride,
  }) {
    final hostRaw = (json['host'] ?? '').toString().trim();
    final effectiveHost = (fallbackHost != null &&
            fallbackHost.isNotEmpty &&
            (hostRaw.isEmpty || hostRaw == '127.0.0.1' || hostRaw == '0.0.0.0'))
        ? fallbackHost
        : (hostRaw.isNotEmpty ? hostRaw : (fallbackHost ?? '127.0.0.1'));
    final rawIps = json['candidateIps'];
    final ips = rawIps is List
        ? rawIps.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList()
        : const <String>[];
    return PeerDeviceNode(
      deviceId: (json['deviceId'] ?? '').toString(),
      deviceName: (json['deviceName'] ?? '流光客户端').toString(),
      platform: (json['platform'] ?? 'unknown').toString(),
      host: effectiveHost,
      port: int.tryParse((json['port'] ?? 18190).toString()) ?? 18190,
      isTv: json['isTv'] == true,
      activeTabIndex:
          int.tryParse((json['activeTabIndex'] ?? 0).toString()) ?? 0,
      activeTabName: (json['activeTabName'] ?? '影视片库').toString(),
      nowPlayingTitle: (json['nowPlayingTitle'] ?? '').toString(),
      isPlaying: json['isPlaying'] == true,
      supportsDesktopCapture: json['supportsDesktopCapture'] == true,
      lastSeenAt: DateTime.fromMillisecondsSinceEpoch(
        int.tryParse((json['lastSeenAtMs'] ?? 0).toString()) ??
            DateTime.now().millisecondsSinceEpoch,
      ),
      isManual: isManualOverride ?? (json['isManual'] == true),
      isLanReachable:
          isLanReachableOverride ?? (json['isLanReachable'] != false),
      candidateIps: ips,
    );
  }
}

class PeerChatMessage {
  final String id;
  final String senderId;
  final String senderName;
  final String senderPlatform;
  final String targetId; // 'all' or specific peer deviceId
  final String text;
  final String type; // 'text', 'file', 'media_cast', 'clipboard'
  final String fileName;
  final int fileSize;
  final String localFilePath;
  final String remoteDownloadUrl;
  final String mediaUrl;
  final DateTime timestamp;
  final bool isOutgoing;

  const PeerChatMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    this.senderPlatform = 'unknown',
    this.targetId = 'all',
    required this.text,
    this.type = 'text',
    this.fileName = '',
    this.fileSize = 0,
    this.localFilePath = '',
    this.remoteDownloadUrl = '',
    this.mediaUrl = '',
    required this.timestamp,
    this.isOutgoing = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'senderId': senderId,
        'senderName': senderName,
        'senderPlatform': senderPlatform,
        'targetId': targetId,
        'text': text,
        'type': type,
        'fileName': fileName,
        'fileSize': fileSize,
        'localFilePath': localFilePath,
        'remoteDownloadUrl': remoteDownloadUrl,
        'mediaUrl': mediaUrl,
        'timestampMs': timestamp.millisecondsSinceEpoch,
        'isOutgoing': isOutgoing,
      };

  factory PeerChatMessage.fromJson(
    Map<String, dynamic> json, {
    bool? isOutgoingOverride,
  }) {
    return PeerChatMessage(
      id: (json['id'] ?? '').toString(),
      senderId: (json['senderId'] ?? '').toString(),
      senderName: (json['senderName'] ?? '未知设备').toString(),
      senderPlatform: (json['senderPlatform'] ?? 'unknown').toString(),
      targetId: (json['targetId'] ?? 'all').toString(),
      text: (json['text'] ?? '').toString(),
      type: (json['type'] ?? 'text').toString(),
      fileName: (json['fileName'] ?? '').toString(),
      fileSize: int.tryParse((json['fileSize'] ?? 0).toString()) ?? 0,
      localFilePath: (json['localFilePath'] ?? '').toString(),
      remoteDownloadUrl: (json['remoteDownloadUrl'] ?? '').toString(),
      mediaUrl: (json['mediaUrl'] ?? '').toString(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        int.tryParse((json['timestampMs'] ?? 0).toString()) ??
            DateTime.now().millisecondsSinceEpoch,
      ),
      isOutgoing: isOutgoingOverride ?? (json['isOutgoing'] == true),
    );
  }
}

class PeerFileTransferTask {
  final String id;
  final String peerId;
  final String peerName;
  final String fileName;
  final int totalBytes;
  int transferredBytes;
  double speedBytesPerSec;
  final bool isUpload;
  String status; // 'transferring', 'completed', 'failed', 'cancelled'
  String savedPath;
  String? error;
  final DateTime createdAt;
  bool isCancelled;

  PeerFileTransferTask({
    required this.id,
    required this.peerId,
    required this.peerName,
    required this.fileName,
    required this.totalBytes,
    this.transferredBytes = 0,
    this.speedBytesPerSec = 0,
    required this.isUpload,
    this.status = 'transferring',
    this.savedPath = '',
    this.error,
    required this.createdAt,
    this.isCancelled = false,
  });

  double get progress {
    if (totalBytes <= 0) return status == 'completed' ? 1.0 : 0.0;
    return (transferredBytes / totalBytes).clamp(0.0, 1.0);
  }
}

class PeerSharedFileItem {
  final String name;
  final String relativePath;
  final int size;
  final DateTime modifiedAt;

  const PeerSharedFileItem({
    required this.name,
    required this.relativePath,
    required this.size,
    required this.modifiedAt,
  });

  bool get isVideo {
    final lower = name.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.avi') ||
        lower.endsWith('.flv') ||
        lower.endsWith('.ts') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.m4v') ||
        lower.endsWith('.rmvb');
  }

  bool get isAudio {
    final lower = name.toLowerCase();
    return lower.endsWith('.mp3') ||
        lower.endsWith('.flac') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.m4a') ||
        lower.endsWith('.aac') ||
        lower.endsWith('.ogg') ||
        lower.endsWith('.ape');
  }

  bool get isImage {
    final lower = name.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp') ||
        lower.endsWith('.heic');
  }

  factory PeerSharedFileItem.fromJson(Map<String, dynamic> json) {
    return PeerSharedFileItem(
      name: (json['name'] ?? '').toString(),
      relativePath: (json['relativePath'] ?? '').toString(),
      size: int.tryParse((json['size'] ?? 0).toString()) ?? 0,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(
        int.tryParse((json['modifiedAtMs'] ?? 0).toString()) ??
            DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'relativePath': relativePath,
        'size': size,
        'modifiedAtMs': modifiedAt.millisecondsSinceEpoch,
      };
}

class _IncomingWanChunkedFile {
  final PeerFileTransferTask task;
  final File targetFile;
  final IOSink sink;
  final int startedAtMs;
  int lastNotifyMs = 0;

  _IncomingWanChunkedFile({
    required this.task,
    required this.targetFile,
    required this.sink,
    required this.startedAtMs,
  });
}

class _FragmentAssemblyBuffer {
  final int total;
  final Map<int, String> parts = {};
  final int createdAtMs = DateTime.now().millisecondsSinceEpoch;

  _FragmentAssemblyBuffer(this.total);
}

/// Service enabling peer-to-peer / cross-client & cross-network (LAN + WAN Cloud Tunnel):
/// 1. Automatic LAN discovery (UDP broadcast + HTTP probe) & Cross-Network Cloud Tunnel discovery (MQTT-over-WebSocket encrypted room)
/// 2. Live Desktop & App Screen streaming (`显示桌面` / `应用画面`) across LAN and WAN
/// 3. Remote Mouse / Touch / Scroll / Keyboard / D-Pad / Media playback control (`远程控制`)
/// 4. High-speed file transfer & remote shared folder browsing/streaming (`传输文件`, via LAN direct, Server Storage relay, or WAN encrypted chunked tunnel)
/// 5. Instant messaging & toast notifications across clients (`发送消息`)
class PeerMeshService extends ChangeNotifier {
  PeerMeshService._();
  static final PeerMeshService instance = PeerMeshService._();

  static const int defaultHttpPort = 18190;
  static const int discoveryUdpPort = 18191;

  static const _prefDeviceIdKey = 'm3u8_peer_device_id_v1';
  static const _prefDeviceNameKey = 'm3u8_peer_device_name_v1';
  static const _prefManualPeersKey = 'm3u8_peer_manual_hosts_v1';
  static const _prefChatHistoryKey = 'm3u8_peer_chat_history_v1';
  static const _prefAllowRemoteControlKey = 'm3u8_peer_allow_control_v1';
  static const _prefAllowDesktopCaptureKey = 'm3u8_peer_allow_desktop_v1';
  static const _prefWanEnabledKey = 'm3u8_peer_wan_enabled_v1';
  static const _prefPairingCodeKey = 'm3u8_peer_wan_pairing_code_v1';
  static const _prefCustomPairingCodeSetKey =
      'm3u8_peer_wan_custom_code_set_v1';

  static const List<String> _wanBrokerUrls = <String>[
    'wss://broker.emqx.io:8084/mqtt',
    'wss://broker.hivemq.com:8884/mqtt',
    'wss://test.mosquitto.org:8081/mqtt',
    'ws://broker.emqx.io:8083/mqtt',
  ];

  /// Global RepaintBoundary key attached to the root of the Flutter app in `main.dart`
  /// so any client (iOS, Android, macOS, Windows, Linux, TV) can stream its live app screen
  /// without requiring OS-level Screen Recording permissions.
  final GlobalKey rootRepaintBoundaryKey =
      GlobalKey(debugLabel: 'PeerMeshRootRepaintBoundary');

  bool _initialized = false;
  String _deviceId = '';
  String _deviceName = '';
  String _localIp = '127.0.0.1';
  List<String> _allLocalIps = const ['127.0.0.1'];
  int _listenPort = defaultHttpPort;
  bool _allowRemoteControl = true;
  bool _allowDesktopCapture = true;
  bool _isPeerScreenActive = false;
  int _unreadMessageCount = 0;

  // Cross-Network (WAN) Cloud Tunnel State
  bool _wanEnabled = true;
  String _pairingCode = 'LG8888';
  bool _hasCustomPairingCode = false;
  WebSocket? _wanWs;
  bool _isWanConnected = false;
  bool _wanConnecting = false;
  int _wanBrokerIndex = 0;
  String _activeWanBroker = '';
  Timer? _wanPingTimer;
  Timer? _wanReconnectTimer;
  final BytesBuilder _mqttRxBuffer = BytesBuilder(copy: false);
  int _mqttPacketIdCounter = 1;
  final Map<String, Completer<Map<String, dynamic>>> _pendingWanRpcs = {};
  final Map<String, _FragmentAssemblyBuffer> _wanFragBuffers = {};
  final Map<String, _IncomingWanChunkedFile> _incomingWanFiles = {};

  HttpServer? _httpServer;
  RawDatagramSocket? _udpSocket;
  Timer? _announceTimer;
  Timer? _healthCheckTimer;
  final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..idleTimeout = const Duration(seconds: 15);

  final Map<String, PeerDeviceNode> _peers = {};
  final List<String> _peerDiscoveryOrder = [];
  final Set<String> _manualHostPorts = {};
  final List<PeerChatMessage> _messages = [];
  final List<PeerFileTransferTask> _transfers = [];
  final List<PeerChatMessage> _pendingToastMessages = [];

  // Callbacks wired from AppState / MainShell
  ApiClient? Function()? getServerApi;
  int Function()? getActiveTabIndex;
  String Function()? getActiveTabName;
  String Function()? getNowPlayingTitle;
  bool Function()? getIsPlaying;
  bool Function()? getIsTvMode;
  void Function(int tabIndex)? onRemoteSelectTab;
  void Function(String action, Map<String, dynamic> payload)?
      onRemoteCommandReceived;

  // Virtual cursor state for in-app screen stream overlay
  Offset? _lastRemoteCursorNormalized;
  DateTime? _lastRemoteCursorAt;
  int _pointerIdCounter = 900;

  String get deviceId => _deviceId;
  String get deviceName => _deviceName;
  String get localIp => _localIp;
  List<String> get allLocalIps => _allLocalIps;
  int get listenPort => _listenPort;
  String get localEndpoint => '$_localIp:$_listenPort';
  String get localHttpUrl => 'http://$_localIp:$_listenPort';
  bool get isRunning => _httpServer != null;
  bool get allowRemoteControl => _allowRemoteControl;
  bool get allowDesktopCapture => _allowDesktopCapture;
  bool get wanEnabled => _wanEnabled;
  String get pairingCode => _pairingCode;
  bool get isWanConnected => _isWanConnected;
  String get activeWanBroker => _activeWanBroker;
  int get unreadMessageCount => _unreadMessageCount;
  Offset? get lastRemoteCursorNormalized {
    if (_lastRemoteCursorNormalized == null || _lastRemoteCursorAt == null) {
      return null;
    }
    if (DateTime.now().difference(_lastRemoteCursorAt!).inSeconds > 6) {
      return null;
    }
    return _lastRemoteCursorNormalized;
  }

  List<PeerDeviceNode> get peers {
    final list = _peers.values.toList();
    list.sort((a, b) {
      final idxA = _peerDiscoveryOrder.indexOf(a.deviceId);
      final idxB = _peerDiscoveryOrder.indexOf(b.deviceId);
      if (idxA >= 0 && idxB >= 0 && idxA != idxB) {
        return idxA.compareTo(idxB);
      }
      if (idxA >= 0 && idxB < 0) return -1;
      if (idxB >= 0 && idxA < 0) return 1;
      return a.deviceId.compareTo(b.deviceId);
    });
    return list;
  }

  void _upsertPeerNode(PeerDeviceNode node, {bool forceNotify = false}) {
    if (node.deviceId.isEmpty || node.deviceId == _deviceId) return;
    final existing = _peers[node.deviceId];
    if (!_peerDiscoveryOrder.contains(node.deviceId)) {
      _peerDiscoveryOrder.add(node.deviceId);
    }
    _peers[node.deviceId] = node;
    final visibleChanged = existing == null ||
        forceNotify ||
        existing.isOnline != node.isOnline ||
        existing.deviceName != node.deviceName ||
        existing.platform != node.platform ||
        existing.host != node.host ||
        existing.port != node.port ||
        existing.isLanReachable != node.isLanReachable ||
        existing.isManual != node.isManual ||
        existing.isTv != node.isTv ||
        existing.activeTabName != node.activeTabName ||
        existing.nowPlayingTitle != node.nowPlayingTitle ||
        existing.isPlaying != node.isPlaying;
    if (visibleChanged) {
      notifyListeners();
    }
  }

  List<PeerChatMessage> get messages => List.unmodifiable(_messages);
  List<PeerFileTransferTask> get transfers => List.unmodifiable(_transfers);
  List<PeerChatMessage> get pendingToastMessages =>
      List.unmodifiable(_pendingToastMessages);

  String get currentPlatformName {
    if (kIsWeb) return 'web';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  bool get supportsNativeDesktopCapture {
    if (kIsWeb) return false;
    return Platform.isMacOS ||
        Platform.isWindows ||
        Platform.isLinux ||
        Platform.isAndroid;
  }

  /// Derives a deterministic 6-character pairing code from the user's connected
  /// server URL & password so all devices logged into the same account/server
  /// automatically share the same cross-network pairing room without manual setup.
  static String deriveDefaultPairingCode({
    required String serverBaseUrl,
    required String serverSecret,
  }) {
    final cleanUrl = serverBaseUrl
        .trim()
        .toLowerCase()
        .replaceFirst(RegExp(r'/+$'), '');
    final seed = 'liuguang_wan_room_v1|$cleanUrl|${serverSecret.trim()}';
    final digest = sha256.convert(utf8.encode(seed)).toString().toUpperCase();
    return 'LG-${digest.substring(0, 6)}';
  }

  Future<void> syncDefaultPairingCodeFromServer({
    required String serverBaseUrl,
    required String serverSecret,
  }) async {
    if (_hasCustomPairingCode) return;
    final derived = deriveDefaultPairingCode(
      serverBaseUrl: serverBaseUrl,
      serverSecret: serverSecret,
    );
    if (derived != _pairingCode) {
      _pairingCode = derived;
      notifyListeners();
      if (_initialized &&
          _wanEnabled &&
          !(Platform.environment.containsKey('FLUTTER_TEST'))) {
        await _reconnectWanBus();
      }
    }
  }

  Future<void> setPairingCode(String newCode) async {
    final clean = newCode.trim().toUpperCase();
    if (clean.isEmpty) return;
    _pairingCode = clean;
    _hasCustomPairingCode = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefPairingCodeKey, _pairingCode);
      await prefs.setBool(_prefCustomPairingCodeSetKey, true);
    } catch (_) {}
    if (_wanEnabled && !(Platform.environment.containsKey('FLUTTER_TEST'))) {
      await _reconnectWanBus();
    }
  }

  Future<void> resetPairingCodeToAccountDefault({
    required String serverBaseUrl,
    required String serverSecret,
  }) async {
    _hasCustomPairingCode = false;
    _pairingCode = deriveDefaultPairingCode(
      serverBaseUrl: serverBaseUrl,
      serverSecret: serverSecret,
    );
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefPairingCodeKey);
      await prefs.setBool(_prefCustomPairingCodeSetKey, false);
    } catch (_) {}
    if (_wanEnabled && !(Platform.environment.containsKey('FLUTTER_TEST'))) {
      await _reconnectWanBus();
    }
  }

  Future<void> setWanEnabled(bool enabled) async {
    if (_wanEnabled == enabled) return;
    _wanEnabled = enabled;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefWanEnabledKey, enabled);
    } catch (_) {}
    if (enabled) {
      if (!(Platform.environment.containsKey('FLUTTER_TEST'))) {
        unawaited(_connectWanBus());
      }
    } else {
      await _disconnectWanBus();
    }
  }

  Future<void> ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      _deviceId = (prefs.getString(_prefDeviceIdKey) ?? '').trim();
      if (_deviceId.isEmpty) {
        final rand = Random.secure();
        final hex = List.generate(
          12,
          (_) => rand.nextInt(16).toRadixString(16),
        ).join();
        _deviceId = 'peer_${DateTime.now().millisecondsSinceEpoch}_$hex';
        await prefs.setString(_prefDeviceIdKey, _deviceId);
      }

      _deviceName = (prefs.getString(_prefDeviceNameKey) ?? '').trim();
      if (_deviceName.isEmpty) {
        _deviceName = _buildDefaultDeviceName();
        await prefs.setString(_prefDeviceNameKey, _deviceName);
      }

      _allowRemoteControl = prefs.getBool(_prefAllowRemoteControlKey) ?? true;
      _allowDesktopCapture = prefs.getBool(_prefAllowDesktopCaptureKey) ?? true;
      _wanEnabled = prefs.getBool(_prefWanEnabledKey) ?? true;
      _hasCustomPairingCode =
          prefs.getBool(_prefCustomPairingCodeSetKey) ?? false;
      final savedCode = (prefs.getString(_prefPairingCodeKey) ?? '').trim();
      if (_hasCustomPairingCode && savedCode.isNotEmpty) {
        _pairingCode = savedCode;
      }

      final savedManual = prefs.getStringList(_prefManualPeersKey) ?? const [];
      _manualHostPorts.addAll(savedManual.where((e) => e.trim().isNotEmpty));

      final savedChats = prefs.getString(_prefChatHistoryKey) ?? '';
      if (savedChats.isNotEmpty) {
        try {
          final decoded = jsonDecode(savedChats);
          if (decoded is List) {
            for (final item in decoded) {
              if (item is Map<String, dynamic>) {
                _messages.add(PeerChatMessage.fromJson(item));
              } else if (item is Map) {
                _messages.add(
                  PeerChatMessage.fromJson(Map<String, dynamic>.from(item)),
                );
              }
            }
          }
        } catch (_) {}
      }
    } catch (_) {
      if (_deviceId.isEmpty) {
        _deviceId = 'peer_${DateTime.now().millisecondsSinceEpoch}';
      }
      if (_deviceName.isEmpty) {
        _deviceName = _buildDefaultDeviceName();
      }
    }

    final isFlutterTest =
        !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');
    if (isFlutterTest) {
      notifyListeners();
      return;
    }

    final ips = await _detectAllLocalIps();
    _allLocalIps = ips.isEmpty ? const ['127.0.0.1'] : ips;
    _localIp = _allLocalIps.first;
    await _startHttpServer();
    await _startUdpDiscovery();
    if (_wanEnabled) {
      unawaited(_connectWanBus());
    }

    _announceTimer?.cancel();
    _announceTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => unawaited(_broadcastPresence()),
    );
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(
      const Duration(seconds: 7),
      (_) => unawaited(_probeKnownPeers()),
    );

    unawaited(_broadcastPresence());
    unawaited(_probeKnownPeers());
    notifyListeners();
  }

  String _buildDefaultDeviceName() {
    String host = '';
    try {
      host = Platform.localHostname.trim();
      if (host.endsWith('.local')) {
        host = host.substring(0, host.length - 6);
      }
    } catch (_) {}
    final plat = switch (currentPlatformName) {
      'macos' => 'Mac',
      'ios' => 'iPhone/iPad',
      'android' => (getIsTvMode?.call() == true) ? 'Android TV' : 'Android',
      'windows' => 'Windows PC',
      'linux' => 'Linux PC',
      _ => '流光终端',
    };
    if (host.isNotEmpty && host.toLowerCase() != 'localhost') {
      return '$host ($plat)';
    }
    return '流光客户端 ($plat)';
  }

  void setPeerScreenActive(bool active) {
    _isPeerScreenActive = active;
    if (active && _unreadMessageCount > 0) {
      _unreadMessageCount = 0;
      _pendingToastMessages.clear();
      notifyListeners();
    }
  }

  void dismissToastMessage(String messageId) {
    _pendingToastMessages.removeWhere((m) => m.id == messageId);
    notifyListeners();
  }

  void dismissAllToastMessages() {
    if (_pendingToastMessages.isEmpty) return;
    _pendingToastMessages.clear();
    notifyListeners();
  }

  Future<void> setDeviceName(String newName) async {
    final clean = newName.trim();
    if (clean.isEmpty || clean == _deviceName) return;
    _deviceName = clean;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefDeviceNameKey, _deviceName);
    } catch (_) {}
    unawaited(_broadcastPresence());
  }

  Future<void> setAllowRemoteControl(bool allow) async {
    if (_allowRemoteControl == allow) return;
    _allowRemoteControl = allow;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefAllowRemoteControlKey, allow);
    } catch (_) {}
  }

  Future<void> setAllowDesktopCapture(bool allow) async {
    if (_allowDesktopCapture == allow) return;
    _allowDesktopCapture = allow;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefAllowDesktopCaptureKey, allow);
    } catch (_) {}
  }

  // ===========================================================================
  // Cross-Network (WAN) Encrypted MQTT-over-WebSocket Cloud Tunnel
  // ===========================================================================

  String get _wanRoomTopicHash {
    return sha256
        .convert(utf8.encode('liuguang_wan_topic_v1:$_pairingCode'))
        .toString()
        .substring(0, 20);
  }

  Uint8List get _wanEncryptionKeyBytes {
    return Uint8List.fromList(
      sha256.convert(utf8.encode('liuguang_wan_aes_key_v1:$_pairingCode')).bytes,
    );
  }

  String get _wanBroadcastTopic => 'liuguang/mesh/$_wanRoomTopicHash/broadcast';
  String get _wanMyInboxTopic =>
      'liuguang/mesh/$_wanRoomTopicHash/peer/$_deviceId';
  String _wanPeerInboxTopic(String targetDeviceId) =>
      'liuguang/mesh/$_wanRoomTopicHash/peer/$targetDeviceId';

  /// Encrypts a UTF-8 JSON string using a SHA-256 CTR keystream + 4-byte HMAC tag.
  static Uint8List encryptWanPayload(String jsonText, Uint8List key32) {
    final plain = utf8.encode(jsonText);
    final rand = Random.secure();
    final nonce = Uint8List.fromList(
      List<int>.generate(8, (_) => rand.nextInt(256)),
    );
    final cipher = Uint8List(plain.length);
    int offset = 0;
    int blockIdx = 0;
    while (offset < plain.length) {
      final blockSeed = BytesBuilder(copy: false)
        ..add(key32)
        ..add(nonce)
        ..add([
          (blockIdx >> 24) & 0xFF,
          (blockIdx >> 16) & 0xFF,
          (blockIdx >> 8) & 0xFF,
          blockIdx & 0xFF,
        ]);
      final ks = sha256.convert(blockSeed.takeBytes()).bytes;
      final n = min(ks.length, plain.length - offset);
      for (int i = 0; i < n; i++) {
        cipher[offset + i] = plain[offset + i] ^ ks[i];
      }
      offset += n;
      blockIdx++;
    }
    final macInput = BytesBuilder(copy: false)
      ..add(key32)
      ..add(nonce)
      ..add(cipher);
    final tag = sha256.convert(macInput.takeBytes()).bytes.sublist(0, 4);
    final out = BytesBuilder(copy: false)
      ..add(nonce)
      ..add(tag)
      ..add(cipher);
    return out.takeBytes();
  }

  /// Decrypts and authenticates an encrypted WAN packet. Returns null if tampered or wrong key.
  static String? decryptWanPayload(Uint8List packet, Uint8List key32) {
    if (packet.length < 12) return null;
    final nonce = Uint8List.sublistView(packet, 0, 8);
    final tag = Uint8List.sublistView(packet, 8, 12);
    final cipher = Uint8List.sublistView(packet, 12);
    final macInput = BytesBuilder(copy: false)
      ..add(key32)
      ..add(nonce)
      ..add(cipher);
    final expectedTag = sha256.convert(macInput.takeBytes()).bytes;
    for (int i = 0; i < 4; i++) {
      if (tag[i] != expectedTag[i]) return null;
    }
    final plain = Uint8List(cipher.length);
    int offset = 0;
    int blockIdx = 0;
    while (offset < cipher.length) {
      final blockSeed = BytesBuilder(copy: false)
        ..add(key32)
        ..add(nonce)
        ..add([
          (blockIdx >> 24) & 0xFF,
          (blockIdx >> 16) & 0xFF,
          (blockIdx >> 8) & 0xFF,
          blockIdx & 0xFF,
        ]);
      final ks = sha256.convert(blockSeed.takeBytes()).bytes;
      final n = min(ks.length, cipher.length - offset);
      for (int i = 0; i < n; i++) {
        plain[offset + i] = cipher[offset + i] ^ ks[i];
      }
      offset += n;
      blockIdx++;
    }
    return utf8.decode(plain, allowMalformed: true);
  }

  Future<void> _reconnectWanBus() async {
    await _disconnectWanBus();
    if (_wanEnabled) {
      await _connectWanBus();
    }
  }

  Future<void> _disconnectWanBus() async {
    _wanReconnectTimer?.cancel();
    _wanReconnectTimer = null;
    _wanPingTimer?.cancel();
    _wanPingTimer = null;
    _isWanConnected = false;
    _activeWanBroker = '';
    final ws = _wanWs;
    _wanWs = null;
    _mqttRxBuffer.clear();
    if (ws != null) {
      try {
        await ws.close();
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> _connectWanBus() async {
    if (kIsWeb || !_wanEnabled || _wanConnecting || _isWanConnected) return;
    _wanConnecting = true;
    try {
      for (int attempt = 0; attempt < _wanBrokerUrls.length; attempt++) {
        if (!_wanEnabled) break;
        final idx = (_wanBrokerIndex + attempt) % _wanBrokerUrls.length;
        final url = _wanBrokerUrls[idx];
        try {
          final ws = await WebSocket.connect(
            url,
            protocols: const ['mqtt'],
          ).timeout(const Duration(seconds: 6));
          _wanBrokerIndex = idx;
          _wanWs = ws;
          _activeWanBroker = Uri.parse(url).host;
          _mqttRxBuffer.clear();

          ws.listen(
            _onWanWsData,
            onDone: _onWanWsDisconnected,
            onError: (_) => _onWanWsDisconnected(),
            cancelOnError: false,
          );

          final clientId =
              'lg_${_deviceId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')}_${Random().nextInt(9999)}';
          ws.add(_buildMqttConnectPacket(clientId));
          return;
        } catch (_) {}
      }
      _scheduleWanReconnect();
    } finally {
      _wanConnecting = false;
    }
  }

  void _onWanWsDisconnected() {
    _wanPingTimer?.cancel();
    _wanPingTimer = null;
    final wasConnected = _isWanConnected;
    _isWanConnected = false;
    _wanWs = null;
    _mqttRxBuffer.clear();
    if (wasConnected) {
      notifyListeners();
    }
    if (_wanEnabled) {
      _wanBrokerIndex = (_wanBrokerIndex + 1) % _wanBrokerUrls.length;
      _scheduleWanReconnect();
    }
  }

  void _scheduleWanReconnect() {
    _wanReconnectTimer?.cancel();
    if (!_wanEnabled) return;
    _wanReconnectTimer = Timer(
      const Duration(seconds: 4),
      () => unawaited(_connectWanBus()),
    );
  }

  void _onWanWsData(dynamic data) {
    List<int>? chunk;
    if (data is Uint8List) {
      chunk = data;
    } else if (data is List<int>) {
      chunk = data;
    } else if (data is String) {
      chunk = utf8.encode(data);
    }
    if (chunk == null || chunk.isEmpty) return;
    _mqttRxBuffer.add(chunk);
    _processMqttRxBuffer();
  }

  void _processMqttRxBuffer() {
    var bytes = _mqttRxBuffer.takeBytes();
    int cursor = 0;
    while (cursor < bytes.length) {
      if (bytes.length - cursor < 2) break;
      final headerByte = bytes[cursor];
      final packetType = (headerByte >> 4) & 0x0F;

      // Decode MQTT variable-length Remaining Length
      int multiplier = 1;
      int remainingLength = 0;
      int lenCursor = cursor + 1;
      bool lenComplete = false;
      while (lenCursor < bytes.length) {
        final encodedByte = bytes[lenCursor++];
        remainingLength += (encodedByte & 127) * multiplier;
        if ((encodedByte & 128) == 0) {
          lenComplete = true;
          break;
        }
        multiplier *= 128;
        if (multiplier > 128 * 128 * 128) {
          // Malformed packet; reset buffer
          return;
        }
      }
      if (!lenComplete) break;
      final packetEnd = lenCursor + remainingLength;
      if (bytes.length < packetEnd) break;

      final body = Uint8List.sublistView(bytes, lenCursor, packetEnd);
      cursor = packetEnd;

      if (packetType == 2) {
        // CONNACK
        _isWanConnected = true;
        notifyListeners();
        final ws = _wanWs;
        if (ws != null) {
          ws.add(
            _buildMqttSubscribePacket(
              ++_mqttPacketIdCounter,
              [_wanBroadcastTopic, _wanMyInboxTopic],
            ),
          );
        }
        _wanPingTimer?.cancel();
        _wanPingTimer = Timer.periodic(const Duration(seconds: 22), (_) {
          final active = _wanWs;
          if (active != null && active.readyState == WebSocket.open) {
            active.add(Uint8List.fromList(const [0xC0, 0x00]));
          }
        });
        unawaited(_broadcastPresence(requestReply: true));
      } else if (packetType == 3) {
        // PUBLISH
        if (body.length >= 2) {
          final topicLen = (body[0] << 8) | body[1];
          int payloadStart = 2 + topicLen;
          final qos = (headerByte >> 1) & 0x03;
          if (qos > 0) {
            payloadStart += 2;
          }
          if (payloadStart <= body.length) {
            final payloadBytes = Uint8List.sublistView(body, payloadStart);
            _handleIncomingWanEncryptedBytes(payloadBytes);
          }
        }
      }
    }
    if (cursor < bytes.length) {
      _mqttRxBuffer.add(Uint8List.sublistView(bytes, cursor));
    }
  }

  static Uint8List _encodeMqttRemainingLength(int length) {
    final out = <int>[];
    var x = length;
    do {
      var encodedByte = x % 128;
      x = x ~/ 128;
      if (x > 0) {
        encodedByte |= 128;
      }
      out.add(encodedByte);
    } while (x > 0);
    return Uint8List.fromList(out);
  }

  static Uint8List _encodeMqttUtf8String(String s) {
    final utf8Bytes = utf8.encode(s);
    final out = BytesBuilder(copy: false);
    out.add([(utf8Bytes.length >> 8) & 0xFF, utf8Bytes.length & 0xFF]);
    out.add(utf8Bytes);
    return out.takeBytes();
  }

  static Uint8List _buildMqttConnectPacket(
    String clientId, {
    int keepAliveSec = 45,
  }) {
    final body = BytesBuilder(copy: false);
    body.add(_encodeMqttUtf8String('MQTT'));
    body.add(const [0x04]); // Protocol Level 4 (MQTT 3.1.1)
    body.add(const [0x02]); // Clean Session
    body.add([(keepAliveSec >> 8) & 0xFF, keepAliveSec & 0xFF]);
    body.add(_encodeMqttUtf8String(clientId));
    final bodyBytes = body.takeBytes();
    final packet = BytesBuilder(copy: false);
    packet.add(const [0x10]);
    packet.add(_encodeMqttRemainingLength(bodyBytes.length));
    packet.add(bodyBytes);
    return packet.takeBytes();
  }

  static Uint8List _buildMqttSubscribePacket(
    int packetId,
    List<String> topics,
  ) {
    final body = BytesBuilder(copy: false);
    body.add([(packetId >> 8) & 0xFF, packetId & 0xFF]);
    for (final t in topics) {
      body.add(_encodeMqttUtf8String(t));
      body.add(const [0x00]); // QoS 0
    }
    final bodyBytes = body.takeBytes();
    final packet = BytesBuilder(copy: false);
    packet.add(const [0x82]);
    packet.add(_encodeMqttRemainingLength(bodyBytes.length));
    packet.add(bodyBytes);
    return packet.takeBytes();
  }

  static Uint8List _buildMqttPublishPacket(
    String topic,
    Uint8List payloadBytes,
  ) {
    final body = BytesBuilder(copy: false);
    body.add(_encodeMqttUtf8String(topic));
    body.add(payloadBytes);
    final bodyBytes = body.takeBytes();
    final packet = BytesBuilder(copy: false);
    packet.add(const [0x30]); // PUBLISH QoS 0
    packet.add(_encodeMqttRemainingLength(bodyBytes.length));
    packet.add(bodyBytes);
    return packet.takeBytes();
  }

  void _publishWanJson(String topic, Map<String, dynamic> map) {
    final ws = _wanWs;
    if (ws == null || !_isWanConnected || ws.readyState != WebSocket.open) {
      return;
    }
    final jsonStr = jsonEncode(map);
    final key = _wanEncryptionKeyBytes;
    // Fragment large messages (> 24 KB) so public MQTT brokers never drop them
    const maxChunkChars = 24000;
    if (jsonStr.length <= maxChunkChars) {
      final encrypted = encryptWanPayload(jsonStr, key);
      ws.add(_buildMqttPublishPacket(topic, encrypted));
      return;
    }
    final fragId =
        'fg_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(99999)}';
    final total = (jsonStr.length + maxChunkChars - 1) ~/ maxChunkChars;
    for (int i = 0; i < total; i++) {
      final start = i * maxChunkChars;
      final end = min(start + maxChunkChars, jsonStr.length);
      final partJson = jsonEncode({
        '_fragId': fragId,
        '_fragIdx': i,
        '_fragTotal': total,
        '_fragPart': jsonStr.substring(start, end),
      });
      final encrypted = encryptWanPayload(partJson, key);
      ws.add(_buildMqttPublishPacket(topic, encrypted));
    }
  }

  void _handleIncomingWanEncryptedBytes(Uint8List encryptedBytes) {
    try {
      final jsonStr = decryptWanPayload(encryptedBytes, _wanEncryptionKeyBytes);
      if (jsonStr == null || !jsonStr.startsWith('{')) return;
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map<String, dynamic>) return;

      // Check if this is a fragment of a larger WAN packet
      if (decoded.containsKey('_fragId')) {
        final fragId = (decoded['_fragId'] ?? '').toString();
        final idx = int.tryParse((decoded['_fragIdx'] ?? 0).toString()) ?? 0;
        final total =
            int.tryParse((decoded['_fragTotal'] ?? 1).toString()) ?? 1;
        final part = (decoded['_fragPart'] ?? '').toString();
        if (fragId.isEmpty || total <= 0 || total > 512) return;

        final nowMs = DateTime.now().millisecondsSinceEpoch;
        _wanFragBuffers.removeWhere((_, v) => nowMs - v.createdAtMs > 30000);
        final buf = _wanFragBuffers.putIfAbsent(
          fragId,
          () => _FragmentAssemblyBuffer(total),
        );
        buf.parts[idx] = part;
        if (buf.parts.length == total) {
          _wanFragBuffers.remove(fragId);
          final sb = StringBuffer();
          for (int i = 0; i < total; i++) {
            sb.write(buf.parts[i] ?? '');
          }
          final fullDecoded = jsonDecode(sb.toString());
          if (fullDecoded is Map<String, dynamic>) {
            unawaited(_handleIncomingWanEnvelope(fullDecoded));
          }
        }
        return;
      }

      unawaited(_handleIncomingWanEnvelope(decoded));
    } catch (_) {}
  }

  Future<void> _handleIncomingWanEnvelope(Map<String, dynamic> map) async {
    final senderId = (map['senderId'] ?? map['deviceId'] ?? '').toString();
    if (senderId.isEmpty || senderId == _deviceId) return;

    final kind = (map['wanKind'] ?? '').toString();
    if (kind == 'presence') {
      final existing = _peers[senderId];
      final lanStillFresh = existing != null &&
          existing.isLanReachable &&
          DateTime.now().difference(existing.lastSeenAt).inSeconds < 40;
      final node = PeerDeviceNode.fromJson(
        map,
        isManualOverride: existing?.isManual,
        isLanReachableOverride: lanStillFresh,
      ).copyWith(
        host: lanStillFresh ? existing.host : null,
        port: lanStillFresh ? existing.port : null,
        isLanReachable: lanStillFresh,
        lastSeenAt: DateTime.now(),
      );
      _upsertPeerNode(node);

      // If not yet LAN-reachable, probe the peer's advertised candidate IPs
      // (including Tailscale 100.x.x.x / ZeroTier / subnet IPs) in background!
      if (!lanStillFresh) {
        for (final ip in <String>{node.host, ...node.candidateIps}) {
          if (ip.isNotEmpty && ip != '127.0.0.1') {
            unawaited(_probeSingleEndpoint('$ip:${node.port}'));
          }
        }
      }
      if (map['requestReply'] == true) {
        _publishWanJson(_wanPeerInboxTopic(senderId), {
          'wanKind': 'presence',
          'requestReply': false,
          ..._buildLocalNodeInfoMap(),
        });
      }
      return;
    }

    if (kind == 'rpc_resp') {
      final reqId = (map['reqId'] ?? '').toString();
      final completer = _pendingWanRpcs.remove(reqId);
      if (completer != null && !completer.isCompleted) {
        completer.complete(map);
      }
      return;
    }

    if (kind == 'rpc_req') {
      final reqId = (map['reqId'] ?? '').toString();
      final rpc = (map['rpc'] ?? '').toString();
      final replyTopic = _wanPeerInboxTopic(senderId);

      switch (rpc) {
        case 'get_screen':
          final mode = (map['mode'] ?? 'auto').toString();
          final maxWidth =
              int.tryParse((map['maxWidth'] ?? 1280).toString()) ?? 1280;
          final quality =
              int.tryParse((map['quality'] ?? 68).toString()) ?? 68;
          final frame = await captureLocalScreenFrame(
            mode: mode,
            maxWidth: maxWidth,
            quality: quality,
          );
          if (frame != null) {
            _publishWanJson(replyTopic, {
              'wanKind': 'rpc_resp',
              'senderId': _deviceId,
              'reqId': reqId,
              'ok': true,
              'bytesB64': base64Encode(frame.bytes),
              'mode': frame.actualMode,
              'width': frame.width,
              'height': frame.height,
            });
          } else {
            _publishWanJson(replyTopic, {
              'wanKind': 'rpc_resp',
              'senderId': _deviceId,
              'reqId': reqId,
              'ok': false,
            });
          }
          break;

        case 'control':
          final payload = map['payload'] is Map<String, dynamic>
              ? map['payload'] as Map<String, dynamic>
              : (map['payload'] is Map
                  ? Map<String, dynamic>.from(map['payload'] as Map)
                  : <String, dynamic>{});
          final res = await _executeIncomingControlCommand(payload);
          _publishWanJson(replyTopic, {
            'wanKind': 'rpc_resp',
            'senderId': _deviceId,
            'reqId': reqId,
            ...res,
          });
          break;

        case 'list_files':
          final files = await _listLocalSharedFiles();
          _publishWanJson(replyTopic, {
            'wanKind': 'rpc_resp',
            'senderId': _deviceId,
            'reqId': reqId,
            'ok': true,
            'files': files.map((f) => f.toJson()).toList(),
          });
          break;

        case 'pull_file_request':
          final relPath = (map['relativePath'] ?? '').toString();
          unawaited(
            _streamLocalSharedFileOverWanToPeer(
              targetPeerId: senderId,
              targetPeerName: (map['senderName'] ?? '远程设备').toString(),
              relativePath: relPath,
              transferId: (map['transferId'] ?? reqId).toString(),
            ),
          );
          _publishWanJson(replyTopic, {
            'wanKind': 'rpc_resp',
            'senderId': _deviceId,
            'reqId': reqId,
            'ok': true,
          });
          break;
      }
      return;
    }

    if (kind == 'chat') {
      final rawMsg = map['message'];
      if (rawMsg is Map) {
        final msg = PeerChatMessage.fromJson(
          Map<String, dynamic>.from(rawMsg),
          isOutgoingOverride: false,
        );
        if (msg.targetId == 'all' || msg.targetId == _deviceId) {
          _appendChatMessage(msg, isIncoming: true);
        }
      }
      return;
    }

    if (kind == 'file_wan_start') {
      final tfId = (map['transferId'] ?? '').toString();
      final fileName = (map['fileName'] ?? '跨网接收文件.bin').toString();
      final totalBytes =
          int.tryParse((map['totalBytes'] ?? 0).toString()) ?? 0;
      final senderName = (map['senderName'] ?? '跨网设备').toString();
      if (tfId.isEmpty) return;

      final saveDir = await getPeerDownloadsDirectory();
      final targetFile = await _resolveUniqueSaveFile(saveDir, fileName);
      final existingTask =
          _transfers.where((t) => t.id == tfId).firstOrNull;
      final task = existingTask ??
          PeerFileTransferTask(
            id: tfId,
            peerId: senderId,
            peerName: senderName,
            fileName: targetFile.uri.pathSegments.last,
            totalBytes: totalBytes,
            isUpload: false,
            savedPath: targetFile.path,
            createdAt: DateTime.now(),
          );
      if (existingTask == null) {
        _transfers.insert(0, task);
      } else {
        task.savedPath = targetFile.path;
      }
      _incomingWanFiles[tfId] = _IncomingWanChunkedFile(
        task: task,
        targetFile: targetFile,
        sink: targetFile.openWrite(),
        startedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      notifyListeners();
      return;
    }

    if (kind == 'file_wan_chunk') {
      final tfId = (map['transferId'] ?? '').toString();
      final state = _incomingWanFiles[tfId];
      if (state == null) return;
      final b64 = (map['dataB64'] ?? '').toString();
      if (b64.isNotEmpty) {
        final chunk = base64Decode(b64);
        state.sink.add(chunk);
        state.task.transferredBytes += chunk.length;
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs - state.lastNotifyMs >= 120) {
          state.lastNotifyMs = nowMs;
          final elapsedSec =
              ((nowMs - state.startedAtMs) / 1000.0).clamp(0.05, 86400.0);
          state.task.speedBytesPerSec =
              state.task.transferredBytes / elapsedSec;
          notifyListeners();
        }
      }
      return;
    }

    if (kind == 'file_wan_end') {
      final tfId = (map['transferId'] ?? '').toString();
      final state = _incomingWanFiles.remove(tfId);
      if (state == null) return;
      try {
        await state.sink.flush();
        await state.sink.close();
      } catch (_) {}
      state.task.status = 'completed';
      final savedName = state.targetFile.uri.pathSegments.last;
      _appendChatMessage(
        PeerChatMessage(
          id: tfId,
          senderId: senderId,
          senderName: state.task.peerName,
          targetId: _deviceId,
          text: '收到跨网传输文件：$savedName',
          type: 'file',
          fileName: savedName,
          fileSize: state.task.transferredBytes,
          localFilePath: state.targetFile.path,
          timestamp: DateTime.now(),
          isOutgoing: false,
        ),
        isIncoming: true,
      );
      notifyListeners();
      return;
    }
  }

  Future<Map<String, dynamic>?> _sendWanRpcRequest(
    String targetDeviceId,
    Map<String, dynamic> requestMap, {
    Duration timeout = const Duration(seconds: 7),
  }) async {
    if (!_isWanConnected || _wanWs == null) return null;
    final reqId =
        'rpc_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(99999)}';
    final completer = Completer<Map<String, dynamic>>();
    _pendingWanRpcs[reqId] = completer;
    _publishWanJson(_wanPeerInboxTopic(targetDeviceId), {
      'wanKind': 'rpc_req',
      'senderId': _deviceId,
      'senderName': _deviceName,
      'reqId': reqId,
      ...requestMap,
    });
    try {
      return await completer.future.timeout(timeout);
    } catch (_) {
      _pendingWanRpcs.remove(reqId);
      return null;
    }
  }

  // ===========================================================================
  // Local HTTP & UDP Discovery
  // ===========================================================================

  Future<void> _startHttpServer() async {
    if (kIsWeb || _httpServer != null) return;
    HttpServer? server;
    for (final candidatePort in [
      defaultHttpPort,
      defaultHttpPort + 1,
      defaultHttpPort + 2,
      0,
    ]) {
      try {
        server = await HttpServer.bind(
          InternetAddress.anyIPv4,
          candidatePort,
          shared: true,
        );
        break;
      } catch (_) {}
    }
    if (server == null) return;
    _httpServer = server;
    _listenPort = server.port;
    server.listen(
      _handleHttpRequest,
      onError: (_) {},
      cancelOnError: false,
    );
  }

  Future<void> _startUdpDiscovery() async {
    if (kIsWeb || _udpSocket != null) return;
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryUdpPort,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      _udpSocket = socket;
      socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = socket.receive();
          if (dg != null) {
            _handleIncomingUdpDatagram(dg);
          }
        }
      }, onError: (_) {});
    } catch (_) {
      try {
        final socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          0,
        );
        socket.broadcastEnabled = true;
        _udpSocket = socket;
      } catch (_) {}
    }
  }

  Map<String, dynamic> _buildLocalNodeInfoMap() {
    return {
      'magic': 'LIUGUANG_PEER_V1',
      'deviceId': _deviceId,
      'deviceName': _deviceName,
      'platform': currentPlatformName,
      'host': _localIp,
      'candidateIps': _allLocalIps,
      'port': _listenPort,
      'isTv': getIsTvMode?.call() ?? false,
      'activeTabIndex': getActiveTabIndex?.call() ?? 0,
      'activeTabName': getActiveTabName?.call() ?? '影视片库',
      'nowPlayingTitle': getNowPlayingTitle?.call() ?? '',
      'isPlaying': getIsPlaying?.call() ?? false,
      'supportsDesktopCapture':
          supportsNativeDesktopCapture && _allowDesktopCapture,
      'allowRemoteControl': _allowRemoteControl,
      'lastSeenAtMs': DateTime.now().millisecondsSinceEpoch,
    };
  }

  Future<void> _broadcastPresence({bool requestReply = false}) async {
    final ips = await _detectAllLocalIps();
    if (ips.isNotEmpty) {
      _allLocalIps = ips;
      if (ips.first != _localIp) {
        _localIp = ips.first;
        notifyListeners();
      }
    }
    final infoMap = _buildLocalNodeInfoMap();

    // 1. LAN UDP Broadcast
    final sock = _udpSocket;
    if (sock != null) {
      final payloadBytes = utf8.encode(jsonEncode(infoMap));
      final targets = <String>{'255.255.255.255'};
      for (final ip in _allLocalIps) {
        final parts = ip.split('.');
        if (parts.length == 4 && parts[0] != '127') {
          targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
        }
      }
      for (final targetIp in targets) {
        try {
          sock.send(
            payloadBytes,
            InternetAddress(targetIp),
            discoveryUdpPort,
          );
        } catch (_) {}
      }
    }

    // 2. Cross-Network WAN Cloud Tunnel Presence Broadcast
    if (_wanEnabled && _isWanConnected) {
      _publishWanJson(_wanBroadcastTopic, {
        'wanKind': 'presence',
        'requestReply': requestReply,
        ...infoMap,
      });
    }
  }

  void _handleIncomingUdpDatagram(Datagram dg) {
    try {
      final text = utf8.decode(dg.data, allowMalformed: true).trim();
      if (!text.startsWith('{')) return;
      final rawMap = jsonDecode(text);
      if (rawMap is! Map<String, dynamic>) return;
      if (rawMap['magic'] != 'LIUGUANG_PEER_V1') return;
      final map = (rawMap['node'] is Map<String, dynamic>)
          ? rawMap['node'] as Map<String, dynamic>
          : rawMap;
      final peerId = (map['deviceId'] ?? '').toString().trim();
      if (peerId.isEmpty || peerId == _deviceId) return;

      final senderIp = dg.address.address;
      final node = PeerDeviceNode.fromJson(
        map,
        fallbackHost: senderIp,
        isManualOverride: _peers[peerId]?.isManual,
        isLanReachableOverride: true,
      ).copyWith(
        host: senderIp,
        isLanReachable: true,
        lastSeenAt: DateTime.now(),
      );
      _upsertPeerNode(node);
    } catch (_) {}
  }

  Future<void> refreshDiscoveryNow() async {
    if (_wanEnabled && !_isWanConnected) {
      unawaited(_connectWanBus());
    }
    await _broadcastPresence(requestReply: true);
    await _probeKnownPeers();
  }

  Future<void> _probeKnownPeers() async {
    final endpoints = <String, String?>{};
    for (final hp in _manualHostPorts) {
      endpoints[hp] = null;
    }
    for (final entry in _peers.entries) {
      if (entry.value.isLanReachable || entry.value.isManual) {
        endpoints['${entry.value.host}:${entry.value.port}'] = entry.key;
      }
    }
    for (final entry in endpoints.entries) {
      unawaited(_probeSingleEndpoint(entry.key, isManual: entry.value == null));
    }
  }

  Future<PeerDeviceNode?> _probeSingleEndpoint(
    String hostPort, {
    bool isManual = false,
  }) async {
    final clean = hostPort
        .trim()
        .replaceFirst(RegExp(r'^https?://'), '')
        .split('/')
        .first;
    if (clean.isEmpty) return null;
    String host = clean;
    int port = defaultHttpPort;
    final colonIdx = clean.lastIndexOf(':');
    if (colonIdx > 0) {
      host = clean.substring(0, colonIdx).trim();
      port = int.tryParse(clean.substring(colonIdx + 1).trim()) ??
          defaultHttpPort;
    }
    if (host.isEmpty) return null;

    try {
      final uri = Uri.parse('http://$host:$port/api/peer/info');
      final req = await _httpClient
          .getUrl(uri)
          .timeout(const Duration(seconds: 3));
      final resp = await req.close().timeout(const Duration(seconds: 3));
      if (resp.statusCode != HttpStatus.ok) {
        await resp.drain<void>();
        return null;
      }
      final body = await utf8.decoder.bind(resp).join();
      final rawDecoded = jsonDecode(body);
      if (rawDecoded is! Map<String, dynamic>) return null;
      final decoded = (rawDecoded['node'] is Map<String, dynamic>)
          ? rawDecoded['node'] as Map<String, dynamic>
          : rawDecoded;
      final peerId = (decoded['deviceId'] ?? '').toString().trim();
      if (peerId.isEmpty || peerId == _deviceId) return null;
      final existing = _peers[peerId];
      final node = PeerDeviceNode.fromJson(
        decoded,
        fallbackHost: host,
        isManualOverride: isManual || (existing?.isManual ?? false),
        isLanReachableOverride: true,
      ).copyWith(
        host: host,
        port: port,
        isLanReachable: true,
        lastSeenAt: DateTime.now(),
      );
      _upsertPeerNode(node, forceNotify: isManual);
      return node;
    } catch (_) {
      return null;
    }
  }

  /// Manually adds a peer client by IP (or `IP:Port` / `http://IP:Port`).
  Future<PeerDeviceNode?> addManualPeer(String hostOrUrl) async {
    var clean = hostOrUrl
        .trim()
        .replaceFirst(RegExp(r'^https?://'), '')
        .split('/')
        .first
        .trim();
    if (clean.isEmpty) return null;
    if (!clean.contains(':')) {
      clean = '$clean:$defaultHttpPort';
    }
    final node = await _probeSingleEndpoint(clean, isManual: true);
    if (node != null) {
      _manualHostPorts.add('${node.host}:${node.port}');
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(
          _prefManualPeersKey,
          _manualHostPorts.toList(),
        );
      } catch (_) {}
    }
    return node;
  }

  Future<void> removePeer(String peerId) async {
    final removed = _peers.remove(peerId);
    if (removed != null) {
      _manualHostPorts.remove('${removed.host}:${removed.port}');
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(
          _prefManualPeersKey,
          _manualHostPorts.toList(),
        );
      } catch (_) {}
      notifyListeners();
    }
  }

  // ===========================================================================
  // Screen Capture (OS Full Desktop + In-App RepaintBoundary)
  // ===========================================================================

  Future<Map<String, bool>> checkMacDesktopPermissions({
    bool prompt = false,
  }) async {
    if (kIsWeb || (!Platform.isMacOS && !Platform.isAndroid)) {
      return const {'screenCapture': true, 'accessibility': true};
    }
    try {
      final res = await NativeUtilsChannelHub.channel
          .invokeMapMethod<String, dynamic>(
        prompt ? 'requestDesktopPermissions' : 'checkDesktopPermissions',
      );
      return {
        'screenCapture': res?['screenCapture'] == true,
        'accessibility': res?['accessibility'] == true,
      };
    } catch (_) {
      return const {'screenCapture': false, 'accessibility': false};
    }
  }

  /// Captures a screen frame in either `'desktop'` (full OS desktop / full device screen) or `'app'` (Flutter window) mode.
  Future<({
    Uint8List bytes,
    String mimeType,
    String actualMode,
    int width,
    int height,
  })?> captureLocalScreenFrame({
    String mode = 'auto',
    int maxWidth = 1280,
    int quality = 72,
  }) async {
    final wantDesktop = (mode == 'desktop' || mode == 'auto') &&
        _allowDesktopCapture &&
        supportsNativeDesktopCapture;

    if (wantDesktop && !kIsWeb && (Platform.isMacOS || Platform.isAndroid)) {
      try {
        final res = await NativeUtilsChannelHub.channel
            .invokeMapMethod<String, dynamic>(
          'captureDesktopScreenJpeg',
          {
            'maxWidth': maxWidth,
            'quality': quality,
          },
        );
        final rawBytes = res?['bytes'];
        if (rawBytes is Uint8List && rawBytes.isNotEmpty) {
          final w = int.tryParse((res?['width'] ?? 1280).toString()) ?? 1280;
          final h = int.tryParse((res?['height'] ?? 720).toString()) ?? 720;
          return (
            bytes: rawBytes,
            mimeType: 'image/jpeg',
            actualMode: 'desktop',
            width: w,
            height: h,
          );
        }
      } catch (_) {}
    }

    if (wantDesktop && !kIsWeb && Platform.isWindows) {
      final winFrame = await _captureWindowsDesktopScreen(
        maxWidth: maxWidth,
        quality: quality,
      );
      if (winFrame != null) return winFrame;
    }

    if (wantDesktop && !kIsWeb && Platform.isLinux) {
      final linuxFrame = await _captureLinuxDesktopScreen(
        maxWidth: maxWidth,
        quality: quality,
      );
      if (linuxFrame != null) return linuxFrame;
    }

    return _captureAppRepaintBoundaryFrame(maxWidth: maxWidth);
  }

  Future<({
    Uint8List bytes,
    String mimeType,
    String actualMode,
    int width,
    int height,
  })?> _captureWindowsDesktopScreen({
    int maxWidth = 1280,
    int quality = 72,
  }) async {
    try {
      final tmpPath =
          '${Directory.systemTemp.path}\\lg_win_desk_$pid.jpg';
      final script = '''
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
\$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
\$bmp = New-Object System.Drawing.Bitmap(\$b.Width, \$b.Height)
\$g = [System.Drawing.Graphics]::FromImage(\$bmp)
\$g.CopyFromScreen(\$b.Location, [System.Drawing.Point]::Empty, \$b.Size)
\$cur = [System.Windows.Forms.Cursor]::Position
\$pen = New-Object System.Drawing.Pen([System.Drawing.Color]::Cyan, 3)
\$g.DrawEllipse(\$pen, \$cur.X - 7, \$cur.Y - 7, 14, 14)
\$g.Dispose()
\$scale = [Math]::Min(1.0, $maxWidth.0 / \$b.Width)
\$dw = [int](\$b.Width * \$scale)
\$dh = [int](\$b.Height * \$scale)
\$out = New-Object System.Drawing.Bitmap(\$bmp, \$dw, \$dh)
\$bmp.Dispose()
\$codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { \$_.MimeType -eq 'image/jpeg' }
\$ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
\$ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]$quality)
\$out.Save('$tmpPath', \$codec, \$ep)
\$out.Dispose()
Write-Output "\$dw,\$dh"
''';
      final res = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-Command', script],
      ).timeout(const Duration(seconds: 3));
      final f = File(tmpPath);
      if (res.exitCode == 0 && await f.exists()) {
        final bytes = await f.readAsBytes();
        try {
          await f.delete();
        } catch (_) {}
        if (bytes.isNotEmpty) {
          final parts = res.stdout.toString().trim().split(',');
          final w = parts.isNotEmpty ? (int.tryParse(parts[0]) ?? 1280) : 1280;
          final h = parts.length > 1 ? (int.tryParse(parts[1]) ?? 720) : 720;
          return (
            bytes: bytes,
            mimeType: 'image/jpeg',
            actualMode: 'desktop',
            width: w,
            height: h,
          );
        }
      }
    } catch (_) {}
    return null;
  }

  Future<({
    Uint8List bytes,
    String mimeType,
    String actualMode,
    int width,
    int height,
  })?> _captureLinuxDesktopScreen({
    int maxWidth = 1280,
    int quality = 72,
  }) async {
    final tmpPath = '${Directory.systemTemp.path}/lg_linux_desk_$pid.jpg';
    for (final cmd in <List<String>>[
      ['scrot', '-o', '-q', '$quality', tmpPath],
      ['grim', '-t', 'jpeg', '-q', '$quality', tmpPath],
      ['import', '-window', 'root', '-resize', '${maxWidth}x', '-quality', '$quality', tmpPath],
    ]) {
      try {
        final res = await Process.run(cmd.first, cmd.sublist(1))
            .timeout(const Duration(seconds: 2));
        final f = File(tmpPath);
        if (res.exitCode == 0 && await f.exists()) {
          final bytes = await f.readAsBytes();
          try {
            await f.delete();
          } catch (_) {}
          if (bytes.isNotEmpty) {
            return (
              bytes: bytes,
              mimeType: 'image/jpeg',
              actualMode: 'desktop',
              width: maxWidth,
              height: (maxWidth * 9) ~/ 16,
            );
          }
        }
      } catch (_) {}
    }
    return null;
  }

  Future<({
    Uint8List bytes,
    String mimeType,
    String actualMode,
    int width,
    int height,
  })?> _captureAppRepaintBoundaryFrame({int maxWidth = 1280}) async {
    try {
      final ctx = rootRepaintBoundaryKey.currentContext;
      if (ctx == null) return null;
      final renderObj = ctx.findRenderObject();
      if (renderObj is! RenderRepaintBoundary) return null;
      final logicalSize = renderObj.size;
      if (logicalSize.width <= 0 || logicalSize.height <= 0) return null;

      final targetWidth = maxWidth.clamp(480, 1920).toDouble();
      final pixelRatio = (targetWidth / logicalSize.width).clamp(0.5, 1.5);
      final image = await renderObj.toImage(pixelRatio: pixelRatio);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final w = image.width;
      final h = image.height;
      image.dispose();
      if (byteData == null) return null;
      return (
        bytes: byteData.buffer.asUint8List(),
        mimeType: 'image/png',
        actualMode: 'app',
        width: w,
        height: h,
      );
    } catch (_) {
      return null;
    }
  }

  /// Fetches a live screen frame from a remote [peer] via LAN direct or Cross-Network WAN Tunnel.
  Future<({
    Uint8List bytes,
    String captureMode,
    int width,
    int height,
  })?> fetchRemoteScreenFrame(
    PeerDeviceNode peer, {
    String mode = 'auto',
    int maxWidth = 1280,
    int quality = 72,
  }) async {
    if (peer.isLanReachable) {
      try {
        final uri = Uri.parse(
          '${peer.baseUrl}/api/peer/screen?mode=$mode&maxWidth=$maxWidth&quality=$quality&t=${DateTime.now().millisecondsSinceEpoch}',
        );
        final req = await _httpClient
            .getUrl(uri)
            .timeout(const Duration(seconds: 3));
        final resp = await req.close().timeout(const Duration(seconds: 3));
        if (resp.statusCode == HttpStatus.ok) {
          final builder = BytesBuilder(copy: false);
          await for (final chunk in resp.timeout(const Duration(seconds: 5))) {
            builder.add(chunk);
          }
          final bytes = builder.takeBytes();
          if (bytes.isNotEmpty) {
            final actualMode =
                resp.headers.value('x-capture-mode') ?? mode;
            final w =
                int.tryParse(resp.headers.value('x-screen-width') ?? '') ??
                    1280;
            final h =
                int.tryParse(resp.headers.value('x-screen-height') ?? '') ??
                    720;
            return (
              bytes: bytes,
              captureMode: actualMode,
              width: w,
              height: h,
            );
          }
        } else {
          await resp.drain<void>();
        }
      } catch (_) {}
    }

    // Fallback or Cross-Network WAN Cloud Tunnel
    if (_isWanConnected) {
      final wanResp = await _sendWanRpcRequest(
        peer.deviceId,
        {
          'rpc': 'get_screen',
          'mode': mode,
          'maxWidth': min(maxWidth, 1280),
          'quality': min(quality, 68),
        },
        timeout: const Duration(seconds: 8),
      );
      if (wanResp != null && wanResp['ok'] == true) {
        final b64 = (wanResp['bytesB64'] ?? '').toString();
        if (b64.isNotEmpty) {
          final bytes = base64Decode(b64);
          final actualMode = (wanResp['mode'] ?? mode).toString();
          final w =
              int.tryParse((wanResp['width'] ?? 1280).toString()) ?? 1280;
          final h =
              int.tryParse((wanResp['height'] ?? 720).toString()) ?? 720;
          return (
            bytes: bytes,
            captureMode: actualMode,
            width: w,
            height: h,
          );
        }
      }
    }
    return null;
  }

  // ===========================================================================
  // Remote Control Injection (Receiving & Sending Mouse/Touch/Key/Media/Tab)
  // ===========================================================================

  Future<bool> sendRemoteControlCommand(
    PeerDeviceNode peer,
    Map<String, dynamic> payload,
  ) async {
    final fullPayload = {
      ...payload,
      'senderId': _deviceId,
      'senderName': _deviceName,
    };
    if (peer.isLanReachable) {
      try {
        final uri = Uri.parse('${peer.baseUrl}/api/peer/control');
        final req = await _httpClient
            .postUrl(uri)
            .timeout(const Duration(seconds: 3));
        req.headers.contentType = ContentType.json;
        final bodyBytes = utf8.encode(jsonEncode(fullPayload));
        req.contentLength = bodyBytes.length;
        req.add(bodyBytes);
        final resp = await req.close().timeout(const Duration(seconds: 3));
        await resp.drain<void>();
        if (resp.statusCode == HttpStatus.ok) return true;
      } catch (_) {}
    }
    if (_isWanConnected) {
      final wanResp = await _sendWanRpcRequest(
        peer.deviceId,
        {
          'rpc': 'control',
          'payload': fullPayload,
        },
        timeout: const Duration(seconds: 5),
      );
      return wanResp != null && wanResp['ok'] == true;
    }
    return false;
  }

  Future<String?> fetchRemoteClipboardText(PeerDeviceNode peer) async {
    if (peer.isLanReachable) {
      try {
        final uri = Uri.parse('${peer.baseUrl}/api/peer/control');
        final req = await _httpClient
            .postUrl(uri)
            .timeout(const Duration(seconds: 3));
        req.headers.contentType = ContentType.json;
        final bodyBytes = utf8.encode(jsonEncode({
          'action': 'get_clipboard',
          'senderId': _deviceId,
          'senderName': _deviceName,
        }));
        req.contentLength = bodyBytes.length;
        req.add(bodyBytes);
        final resp = await req.close().timeout(const Duration(seconds: 3));
        if (resp.statusCode == HttpStatus.ok) {
          final text = await utf8.decoder.bind(resp).join();
          final decoded = jsonDecode(text);
          if (decoded is Map) {
            return (decoded['clipboard'] ?? '').toString();
          }
        } else {
          await resp.drain<void>();
        }
      } catch (_) {}
    }
    if (_isWanConnected) {
      final wanResp = await _sendWanRpcRequest(
        peer.deviceId,
        {
          'rpc': 'control',
          'payload': {
            'action': 'get_clipboard',
            'senderId': _deviceId,
            'senderName': _deviceName,
          },
        },
      );
      if (wanResp != null && wanResp['ok'] == true) {
        return (wanResp['clipboard'] ?? '').toString();
      }
    }
    return null;
  }

  Future<Map<String, dynamic>> _executeIncomingControlCommand(
    Map<String, dynamic> payload,
  ) async {
    if (!_allowRemoteControl) {
      return {'ok': false, 'error': '对方设备已关闭远程控制权限'};
    }
    final action = (payload['action'] ?? '').toString().trim();
    switch (action) {
      case 'mouse':
        await _injectLocalPointerOrDesktopMouse(payload);
        return {'ok': true};

      case 'key':
        final keyName = (payload['key'] ?? '').toString().trim().toLowerCase();
        final targetMode = (payload['targetMode'] ?? 'app').toString();
        await _injectLocalKeyAction(keyName, targetMode: targetMode);
        return {'ok': true};

      case 'text':
        final text = (payload['text'] ?? '').toString();
        final submit = payload['submit'] == true;
        final targetMode = (payload['targetMode'] ?? 'app').toString();
        await _injectLocalTextInput(
          text,
          submit: submit,
          targetMode: targetMode,
        );
        return {'ok': true};

      case 'switch_tab':
        final tabIdx = int.tryParse((payload['tabIndex'] ?? 0).toString()) ?? 0;
        onRemoteSelectTab?.call(tabIdx);
        return {'ok': true};

      case 'cast_media':
      case 'media_command':
        onRemoteCommandReceived?.call(action, payload);
        return {'ok': true};

      case 'set_clipboard':
        final text = (payload['text'] ?? '').toString();
        await Clipboard.setData(ClipboardData(text: text));
        return {'ok': true};

      case 'get_clipboard':
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        return {'ok': true, 'clipboard': data?.text ?? ''};

      default:
        onRemoteCommandReceived?.call(action, payload);
        return {'ok': true};
    }
  }

  Future<void> _injectLocalPointerOrDesktopMouse(
    Map<String, dynamic> payload,
  ) async {
    final type = (payload['type'] ?? 'tap').toString();
    final nx = (double.tryParse((payload['nx'] ?? 0.5).toString()) ?? 0.5)
        .clamp(0.0, 1.0);
    final ny = (double.tryParse((payload['ny'] ?? 0.5).toString()) ?? 0.5)
        .clamp(0.0, 1.0);
    final deltaX =
        double.tryParse((payload['deltaX'] ?? 0).toString()) ?? 0.0;
    final deltaY =
        double.tryParse((payload['deltaY'] ?? 0).toString()) ?? 0.0;
    final targetMode = (payload['targetMode'] ?? 'app').toString();

    _lastRemoteCursorNormalized = Offset(nx, ny);
    _lastRemoteCursorAt = DateTime.now();
    notifyListeners();

    final useOsDesktopControl =
        (targetMode == 'desktop' || targetMode == 'auto') &&
            _allowDesktopCapture &&
            supportsNativeDesktopCapture;

    if (useOsDesktopControl &&
        !kIsWeb &&
        (Platform.isMacOS || Platform.isAndroid)) {
      try {
        final ok = await NativeUtilsChannelHub.channel.invokeMethod<bool>(
          'injectDesktopMouseEvent',
          {
            'type': type,
            'nx': nx,
            'ny': ny,
            'deltaX': deltaX.round(),
            'deltaY': deltaY.round(),
          },
        );
        if (ok == true) return;
      } catch (_) {}
    }

    if (useOsDesktopControl && !kIsWeb && Platform.isWindows) {
      if (await _injectWindowsDesktopMouse(
        type: type,
        nx: nx,
        ny: ny,
        deltaY: deltaY.round(),
      )) {
        return;
      }
    }

    if (useOsDesktopControl && !kIsWeb && Platform.isLinux) {
      if (await _injectLinuxDesktopMouse(
        type: type,
        nx: nx,
        ny: ny,
        deltaY: deltaY.round(),
      )) {
        return;
      }
    }

    final ctx = rootRepaintBoundaryKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    final renderObj = ctx.findRenderObject();
    if (renderObj is! RenderBox || !renderObj.hasSize) return;
    final size = renderObj.size;
    final pos = Offset(nx * size.width, ny * size.height);
    final now = Duration(milliseconds: DateTime.now().millisecondsSinceEpoch);
    final binding = WidgetsBinding.instance;

    switch (type) {
      case 'tap':
        final p = ++_pointerIdCounter;
        binding.handlePointerEvent(
          PointerAddedEvent(timeStamp: now, position: pos, pointer: p),
        );
        binding.handlePointerEvent(
          PointerDownEvent(timeStamp: now, position: pos, pointer: p),
        );
        await Future<void>.delayed(const Duration(milliseconds: 35));
        binding.handlePointerEvent(
          PointerUpEvent(
            timeStamp: now + const Duration(milliseconds: 35),
            position: pos,
            pointer: p,
          ),
        );
        break;

      case 'double_tap':
        for (int i = 0; i < 2; i++) {
          final p = ++_pointerIdCounter;
          final t = now + Duration(milliseconds: i * 90);
          binding.handlePointerEvent(
            PointerDownEvent(timeStamp: t, position: pos, pointer: p),
          );
          await Future<void>.delayed(const Duration(milliseconds: 25));
          binding.handlePointerEvent(
            PointerUpEvent(
              timeStamp: t + const Duration(milliseconds: 25),
              position: pos,
              pointer: p,
            ),
          );
          if (i == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
        break;

      case 'right_click':
        final p = ++_pointerIdCounter;
        binding.handlePointerEvent(
          PointerDownEvent(
            timeStamp: now,
            position: pos,
            pointer: p,
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 35));
        binding.handlePointerEvent(
          PointerUpEvent(
            timeStamp: now + const Duration(milliseconds: 35),
            position: pos,
            pointer: p,
            kind: PointerDeviceKind.mouse,
          ),
        );
        break;

      case 'down':
        final p = ++_pointerIdCounter;
        binding.handlePointerEvent(
          PointerDownEvent(timeStamp: now, position: pos, pointer: p),
        );
        break;

      case 'drag':
        binding.handlePointerEvent(
          PointerMoveEvent(
            timeStamp: now,
            position: pos,
            pointer: _pointerIdCounter,
            delta: Offset(deltaX, deltaY),
          ),
        );
        break;

      case 'up':
        binding.handlePointerEvent(
          PointerUpEvent(
            timeStamp: now,
            position: pos,
            pointer: _pointerIdCounter,
          ),
        );
        break;

      case 'scroll':
        binding.handlePointerEvent(
          PointerScrollEvent(
            timeStamp: now,
            position: pos,
            scrollDelta: Offset(-deltaX, -deltaY),
            kind: PointerDeviceKind.mouse,
          ),
        );
        break;
    }
  }

  Future<bool> _injectWindowsDesktopMouse({
    required String type,
    required double nx,
    required double ny,
    required int deltaY,
  }) async {
    try {
      final script = '''
Add-Type -AssemblyName System.Windows.Forms
Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern void mouse_event(int dwFlags, int dx, int dy, int cButtons, int dwExtraInfo);' -Name WinMouse -Namespace Win32
\$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
\$x = [int](\$b.Width * $nx)
\$y = [int](\$b.Height * $ny)
[System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(\$x, \$y)
switch ('$type') {
  'tap' { [Win32.WinMouse]::mouse_event(0x0002, 0, 0, 0, 0); [Win32.WinMouse]::mouse_event(0x0004, 0, 0, 0, 0) }
  'double_tap' { [Win32.WinMouse]::mouse_event(0x0002, 0, 0, 0, 0); [Win32.WinMouse]::mouse_event(0x0004, 0, 0, 0, 0); Start-Sleep -Milliseconds 40; [Win32.WinMouse]::mouse_event(0x0002, 0, 0, 0, 0); [Win32.WinMouse]::mouse_event(0x0004, 0, 0, 0, 0) }
  'right_click' { [Win32.WinMouse]::mouse_event(0x0008, 0, 0, 0, 0); [Win32.WinMouse]::mouse_event(0x0010, 0, 0, 0, 0) }
  'down' { [Win32.WinMouse]::mouse_event(0x0002, 0, 0, 0, 0) }
  'up' { [Win32.WinMouse]::mouse_event(0x0004, 0, 0, 0, 0) }
  'scroll' { [Win32.WinMouse]::mouse_event(0x0800, 0, 0, ${deltaY * 4}, 0) }
}
''';
      final res = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-Command', script],
      ).timeout(const Duration(seconds: 2));
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _injectLinuxDesktopMouse({
    required String type,
    required double nx,
    required double ny,
    required int deltaY,
  }) async {
    try {
      final geom = await Process.run('xdotool', ['getdisplaygeometry']);
      final parts = geom.stdout.toString().trim().split(RegExp(r'\s+'));
      final w = parts.isNotEmpty ? (int.tryParse(parts[0]) ?? 1920) : 1920;
      final h = parts.length > 1 ? (int.tryParse(parts[1]) ?? 1080) : 1080;
      final x = (nx * w).round();
      final y = (ny * h).round();
      final args = <String>['mousemove', '$x', '$y'];
      if (type == 'tap') {
        args.addAll(['click', '1']);
      } else if (type == 'double_tap') {
        args.addAll(['click', '--repeat', '2', '1']);
      } else if (type == 'right_click') {
        args.addAll(['click', '3']);
      } else if (type == 'down') {
        args.addAll(['mousedown', '1']);
      } else if (type == 'up') {
        args.addAll(['mouseup', '1']);
      } else if (type == 'scroll') {
        args.addAll(['click', deltaY < 0 ? '5' : '4']);
      }
      final res = await Process.run('xdotool', args);
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _injectLocalKeyAction(
    String keyName, {
    String targetMode = 'app',
  }) async {
    final useOsDesktopControl =
        (targetMode == 'desktop' || targetMode == 'auto') &&
            _allowDesktopCapture &&
            supportsNativeDesktopCapture;

    if (useOsDesktopControl &&
        !kIsWeb &&
        (Platform.isMacOS || Platform.isAndroid)) {
      try {
        final handled = await NativeUtilsChannelHub.channel.invokeMethod<bool>(
          'injectDesktopKeyEvent',
          {'key': keyName},
        );
        if (handled == true) return;
      } catch (_) {}
    }

    if (useOsDesktopControl && !kIsWeb && Platform.isWindows) {
      if (await _injectWindowsDesktopKey(keyName: keyName)) return;
    }

    if (useOsDesktopControl && !kIsWeb && Platform.isLinux) {
      if (await _injectLinuxDesktopKey(keyName: keyName)) return;
    }

    final primary = FocusManager.instance.primaryFocus;
    switch (keyName) {
      case 'up':
        primary?.focusInDirection(TraversalDirection.up);
        break;
      case 'down':
        primary?.focusInDirection(TraversalDirection.down);
        break;
      case 'left':
        primary?.focusInDirection(TraversalDirection.left);
        break;
      case 'right':
        primary?.focusInDirection(TraversalDirection.right);
        break;
      case 'ok':
      case 'enter':
        final ctx = primary?.context;
        if (ctx != null && ctx.mounted) {
          final activateAction = Actions.maybeFind<ActivateIntent>(ctx);
          if (activateAction != null &&
              activateAction.isEnabled(const ActivateIntent())) {
            Actions.invoke(ctx, const ActivateIntent());
            return;
          }
          final buttonAction = Actions.maybeFind<ButtonActivateIntent>(ctx);
          if (buttonAction != null &&
              buttonAction.isEnabled(const ButtonActivateIntent())) {
            Actions.invoke(ctx, const ButtonActivateIntent());
            return;
          }
        }
        onRemoteCommandReceived?.call('key_action', {'key': 'enter'});
        break;
      case 'back':
      case 'escape':
        onRemoteCommandReceived?.call('key_action', {'key': 'back'});
        break;
      case 'home':
        onRemoteSelectTab?.call(0);
        break;
      case 'backspace':
      case 'delete':
        final editable =
            primary?.context?.findAncestorStateOfType<EditableTextState>();
        if (editable != null && editable.mounted) {
          final text = editable.textEditingValue.text;
          if (text.isNotEmpty) {
            final next = text.substring(0, text.length - 1);
            editable.userUpdateTextEditingValue(
              TextEditingValue(
                text: next,
                selection: TextSelection.collapsed(offset: next.length),
              ),
              SelectionChangedCause.keyboard,
            );
          }
        }
        break;
      default:
        onRemoteCommandReceived?.call('key_action', {'key': keyName});
        break;
    }
  }

  Future<bool> _injectWindowsDesktopKey({
    String keyName = '',
    String text = '',
  }) async {
    try {
      String sendKeyStr = text;
      if (sendKeyStr.isEmpty) {
        sendKeyStr = switch (keyName.toLowerCase()) {
          'enter' || 'ok' => '{ENTER}',
          'back' || 'escape' || 'esc' => '{ESC}',
          'tab' => '{TAB}',
          'space' || 'play_pause' => ' ',
          'backspace' => '{BACKSPACE}',
          'delete' || 'del' => '{DELETE}',
          'up' => '{UP}',
          'down' => '{DOWN}',
          'left' => '{LEFT}',
          'right' => '{RIGHT}',
          'home' => '{HOME}',
          'end' => '{END}',
          'pageup' => '{PGUP}',
          'pagedown' => '{PGDN}',
          'ctrl+c' || 'cmd+c' => '^c',
          'ctrl+v' || 'cmd+v' => '^v',
          'ctrl+x' || 'cmd+x' => '^x',
          'ctrl+a' || 'cmd+a' => '^a',
          'ctrl+z' || 'cmd+z' => '^z',
          'alt+tab' || 'cmd+tab' => '%{TAB}',
          'alt+f4' || 'cmd+q' => '%{F4}',
          _ => keyName,
        };
      }
      if (keyName == 'show_desktop' || keyName == 'win+d') {
        final res = await Process.run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          '(New-Object -ComObject Shell.Application).ToggleDesktop()',
        ]).timeout(const Duration(seconds: 2));
        return res.exitCode == 0;
      }
      final escaped = sendKeyStr.replaceAll("'", "''");
      final res = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.SendKeys]::SendWait('$escaped')",
      ]).timeout(const Duration(seconds: 2));
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _injectLinuxDesktopKey({
    String keyName = '',
    String text = '',
  }) async {
    try {
      if (text.isNotEmpty) {
        final res = await Process.run('xdotool', ['type', '--', text]);
        return res.exitCode == 0;
      }
      final xKey = switch (keyName.toLowerCase()) {
        'enter' || 'ok' => 'Return',
        'back' || 'escape' || 'esc' => 'Escape',
        'tab' => 'Tab',
        'space' || 'play_pause' => 'space',
        'backspace' => 'BackSpace',
        'delete' || 'del' => 'Delete',
        'up' => 'Up',
        'down' => 'Down',
        'left' => 'Left',
        'right' => 'Right',
        'ctrl+c' || 'cmd+c' => 'ctrl+c',
        'ctrl+v' || 'cmd+v' => 'ctrl+v',
        'ctrl+a' || 'cmd+a' => 'ctrl+a',
        'ctrl+z' || 'cmd+z' => 'ctrl+z',
        'alt+tab' || 'cmd+tab' => 'alt+Tab',
        'show_desktop' || 'win+d' => 'super+d',
        _ => keyName,
      };
      final res = await Process.run('xdotool', ['key', xKey]);
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _injectLocalTextInput(
    String text, {
    bool submit = false,
    String targetMode = 'app',
  }) async {
    if (text.isEmpty) return;
    final useOsDesktopControl =
        (targetMode == 'desktop' || targetMode == 'auto') &&
            _allowDesktopCapture &&
            supportsNativeDesktopCapture;

    if (useOsDesktopControl &&
        !kIsWeb &&
        (Platform.isMacOS || Platform.isAndroid)) {
      try {
        final ok = await NativeUtilsChannelHub.channel.invokeMethod<bool>(
          'injectDesktopKeyEvent',
          {'text': text},
        );
        if (submit) {
          await NativeUtilsChannelHub.channel.invokeMethod<bool>(
            'injectDesktopKeyEvent',
            {'key': 'enter'},
          );
        }
        if (ok == true) return;
      } catch (_) {}
    }

    if (useOsDesktopControl && !kIsWeb && Platform.isWindows) {
      if (await _injectWindowsDesktopKey(text: text)) {
        if (submit) await _injectWindowsDesktopKey(keyName: 'enter');
        return;
      }
    }

    if (useOsDesktopControl && !kIsWeb && Platform.isLinux) {
      if (await _injectLinuxDesktopKey(text: text)) {
        if (submit) await _injectLinuxDesktopKey(keyName: 'enter');
        return;
      }
    }

    final primary = FocusManager.instance.primaryFocus;
    final editable =
        primary?.context?.findAncestorStateOfType<EditableTextState>();
    if (editable != null && editable.mounted) {
      editable.userUpdateTextEditingValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ),
        SelectionChangedCause.keyboard,
      );
      if (submit) {
        try {
          editable.widget.onSubmitted?.call(text);
        } catch (_) {}
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    onRemoteCommandReceived?.call('text_input', {
      'text': text,
      'submit': submit,
    });
  }

  // ===========================================================================
  // Instant Messaging Between Clients (`发送消息`, LAN + Cross-Network WAN)
  // ===========================================================================

  Future<bool> sendChatMessage({
    PeerDeviceNode? targetPeer,
    required String text,
    String type = 'text',
    String mediaUrl = '',
  }) async {
    final cleanText = text.trim();
    if (cleanText.isEmpty && mediaUrl.isEmpty) return false;

    final msg = PeerChatMessage(
      id: 'msg_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(9999)}',
      senderId: _deviceId,
      senderName: _deviceName,
      senderPlatform: currentPlatformName,
      targetId: targetPeer?.deviceId ?? 'all',
      text: cleanText,
      type: type,
      mediaUrl: mediaUrl,
      timestamp: DateTime.now(),
      isOutgoing: true,
    );

    _appendChatMessage(msg, isIncoming: false);

    final targets = targetPeer != null
        ? <PeerDeviceNode>[targetPeer]
        : peers.where((p) => p.isOnline).toList();

    bool anySuccess = false;
    for (final peer in targets) {
      if (peer.isLanReachable) {
        try {
          final uri = Uri.parse('${peer.baseUrl}/api/peer/message');
          final req = await _httpClient
              .postUrl(uri)
              .timeout(const Duration(seconds: 3));
          req.headers.contentType = ContentType.json;
          final bodyBytes = utf8.encode(jsonEncode(msg.toJson()));
          req.contentLength = bodyBytes.length;
          req.add(bodyBytes);
          final resp = await req.close().timeout(const Duration(seconds: 3));
          await resp.drain<void>();
          if (resp.statusCode == HttpStatus.ok) {
            anySuccess = true;
            continue;
          }
        } catch (_) {}
      }
      if (_isWanConnected) {
        _publishWanJson(_wanPeerInboxTopic(peer.deviceId), {
          'wanKind': 'chat',
          'senderId': _deviceId,
          'message': msg.toJson(),
        });
        anySuccess = true;
      }
    }

    if (targetPeer == null && _isWanConnected) {
      _publishWanJson(_wanBroadcastTopic, {
        'wanKind': 'chat',
        'senderId': _deviceId,
        'message': msg.toJson(),
      });
      anySuccess = true;
    }

    return anySuccess || targets.isEmpty;
  }

  void _appendChatMessage(PeerChatMessage msg, {required bool isIncoming}) {
    if (_messages.any((m) => m.id == msg.id)) return;
    _messages.add(msg);
    if (_messages.length > 300) {
      _messages.removeRange(0, _messages.length - 300);
    }
    if (isIncoming && !_isPeerScreenActive) {
      _unreadMessageCount++;
      _pendingToastMessages.insert(0, msg);
      if (_pendingToastMessages.length > 4) {
        _pendingToastMessages.removeRange(4, _pendingToastMessages.length);
      }
    }
    notifyListeners();
    unawaited(_persistChatHistory());
  }

  Future<void> clearChatHistory() async {
    _messages.clear();
    _pendingToastMessages.clear();
    _unreadMessageCount = 0;
    notifyListeners();
    await _persistChatHistory();
  }

  Future<void> _persistChatHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final tail = _messages.length > 120
          ? _messages.sublist(_messages.length - 120)
          : _messages;
      await prefs.setString(
        _prefChatHistoryKey,
        jsonEncode(tail.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  // ===========================================================================
  // File Transfer & Shared Folder Browsing (`传输文件`, LAN + Cross-Network WAN)
  // ===========================================================================

  Future<Directory> getPeerDownloadsDirectory() async {
    if (!kIsWeb && Platform.environment.containsKey('FLUTTER_TEST')) {
      return Directory.systemTemp;
    }
    try {
      if (!kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
        final dl = await getDownloadsDirectory();
        if (dl != null) {
          final dir = Directory('${dl.path}${Platform.pathSeparator}流光互联接收');
          if (!await dir.exists()) {
            await dir.create(recursive: true);
          }
          return dir;
        }
      }
      final doc = await getApplicationDocumentsDirectory();
      final dir = Directory('${doc.path}${Platform.pathSeparator}流光互联接收');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    } catch (_) {
      final dir = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}liuguang_peer_files',
      );
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }
  }

  /// Sends a local file (or byte buffer) to [peer] via LAN Direct HTTP or Cross-Network WAN Encrypted Tunnel.
  Future<PeerFileTransferTask> sendFileToPeer({
    required PeerDeviceNode peer,
    required String fileName,
    String? localFilePath,
    Uint8List? rawBytes,
  }) async {
    File? fileObj;
    int totalBytes = rawBytes?.length ?? 0;
    if (localFilePath != null && localFilePath.isNotEmpty) {
      fileObj = File(localFilePath);
      if (await fileObj.exists()) {
        totalBytes = await fileObj.length();
      }
    }
    final cleanName = fileName.trim().isEmpty ? '传输文件.bin' : fileName.trim();
    final task = PeerFileTransferTask(
      id: 'tf_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(9999)}',
      peerId: peer.deviceId,
      peerName: peer.deviceName,
      fileName: cleanName,
      totalBytes: totalBytes,
      isUpload: true,
      savedPath: localFilePath ?? '',
      createdAt: DateTime.now(),
    );
    _transfers.insert(0, task);
    notifyListeners();

    final startedAtMs = DateTime.now().millisecondsSinceEpoch;
    try {
      if (totalBytes <= 0 && (rawBytes == null || rawBytes.isEmpty)) {
        throw Exception('待发送文件为空或不存在');
      }

      if (peer.isLanReachable) {
        final uri = Uri.parse('${peer.baseUrl}/api/peer/file-upload');
        final req = await _httpClient
            .postUrl(uri)
            .timeout(const Duration(seconds: 10));
        req.bufferOutput = false;
        req.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/octet-stream',
        );
        req.headers.set('X-File-Name', Uri.encodeComponent(cleanName));
        req.headers.set('X-File-Size', totalBytes.toString());
        req.headers.set('X-Sender-Id', _deviceId);
        req.headers.set('X-Sender-Name', Uri.encodeComponent(_deviceName));
        req.headers.set('X-Sender-Platform', currentPlatformName);
        req.headers.set('X-Transfer-Id', task.id);
        req.contentLength = totalBytes;

        Stream<List<int>> sourceStream;
        if (fileObj != null) {
          sourceStream = fileObj.openRead();
        } else {
          sourceStream = Stream<List<int>>.fromIterable([rawBytes!]);
        }

        int lastNotifyMs = 0;
        final trackedStream = sourceStream.transform<List<int>>(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleData: (chunk, sink) {
              if (task.isCancelled) {
                sink.addError(Exception('已取消文件传输'));
                return;
              }
              sink.add(chunk);
              task.transferredBytes += chunk.length;
              final nowMs = DateTime.now().millisecondsSinceEpoch;
              if (nowMs - lastNotifyMs >= 120 ||
                  task.transferredBytes >= totalBytes) {
                lastNotifyMs = nowMs;
                final elapsedSec =
                    ((nowMs - startedAtMs) / 1000.0).clamp(0.05, 86400.0);
                task.speedBytesPerSec = task.transferredBytes / elapsedSec;
                notifyListeners();
              }
            },
          ),
        );

        await req.addStream(trackedStream);
        final resp = await req.close();
        final respBody = await utf8.decoder.bind(resp).join();
        if (resp.statusCode != HttpStatus.ok) {
          throw Exception('HTTP ${resp.statusCode}: $respBody');
        }
      } else if (_isWanConnected) {
        // Cross-Network Encrypted WAN Chunked File Transfer
        await _sendFileOverWanTunnel(
          peer: peer,
          task: task,
          cleanName: cleanName,
          totalBytes: totalBytes,
          fileObj: fileObj,
          rawBytes: rawBytes,
          startedAtMs: startedAtMs,
        );
      } else {
        throw Exception('当前与对方处于不同网络且跨网云端通道未连接');
      }

      task.status = 'completed';
      task.transferredBytes = totalBytes;
      _appendChatMessage(
        PeerChatMessage(
          id: task.id,
          senderId: _deviceId,
          senderName: _deviceName,
          senderPlatform: currentPlatformName,
          targetId: peer.deviceId,
          text: '已发送文件：$cleanName (${peer.connectionModeLabel})',
          type: 'file',
          fileName: cleanName,
          fileSize: totalBytes,
          localFilePath: localFilePath ?? '',
          timestamp: DateTime.now(),
          isOutgoing: true,
        ),
        isIncoming: false,
      );
      notifyListeners();
      return task;
    } catch (e) {
      task.status = task.isCancelled ? 'cancelled' : 'failed';
      task.error = e.toString();
      notifyListeners();
      return task;
    }
  }

  Future<void> _sendFileOverWanTunnel({
    required PeerDeviceNode peer,
    required PeerFileTransferTask task,
    required String cleanName,
    required int totalBytes,
    required File? fileObj,
    required Uint8List? rawBytes,
    required int startedAtMs,
  }) async {
    final topic = _wanPeerInboxTopic(peer.deviceId);
    _publishWanJson(topic, {
      'wanKind': 'file_wan_start',
      'senderId': _deviceId,
      'senderName': _deviceName,
      'transferId': task.id,
      'fileName': cleanName,
      'totalBytes': totalBytes,
    });

    const chunkSize = 16384; // 16 KB binary -> ~22 KB Base64 per MQTT frame
    final buffer = BytesBuilder(copy: false);
    int lastNotifyMs = 0;

    Future<void> flushSlice(Uint8List slice) async {
      if (task.isCancelled) {
        throw Exception('已取消文件传输');
      }
      _publishWanJson(topic, {
        'wanKind': 'file_wan_chunk',
        'senderId': _deviceId,
        'transferId': task.id,
        'dataB64': base64Encode(slice),
      });
      task.transferredBytes += slice.length;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - lastNotifyMs >= 120 || task.transferredBytes >= totalBytes) {
        lastNotifyMs = nowMs;
        final elapsedSec =
            ((nowMs - startedAtMs) / 1000.0).clamp(0.05, 86400.0);
        task.speedBytesPerSec = task.transferredBytes / elapsedSec;
        notifyListeners();
      }
      await Future<void>.delayed(const Duration(milliseconds: 12));
    }

    if (fileObj != null) {
      await for (final chunk in fileObj.openRead()) {
        buffer.add(chunk);
        while (buffer.length >= chunkSize) {
          final current = buffer.takeBytes();
          await flushSlice(Uint8List.sublistView(current, 0, chunkSize));
          if (current.length > chunkSize) {
            buffer.add(Uint8List.sublistView(current, chunkSize));
          }
        }
      }
    } else if (rawBytes != null) {
      buffer.add(rawBytes);
    }

    final remaining = buffer.takeBytes();
    int offset = 0;
    while (offset < remaining.length) {
      final end = min(offset + chunkSize, remaining.length);
      await flushSlice(Uint8List.sublistView(remaining, offset, end));
      offset = end;
    }

    _publishWanJson(topic, {
      'wanKind': 'file_wan_end',
      'senderId': _deviceId,
      'transferId': task.id,
    });
  }

  Future<void> _streamLocalSharedFileOverWanToPeer({
    required String targetPeerId,
    required String targetPeerName,
    required String relativePath,
    required String transferId,
  }) async {
    final cleanRel = relativePath.trim();
    if (cleanRel.isEmpty ||
        cleanRel.contains('..') ||
        cleanRel.contains('/') ||
        cleanRel.contains('\\')) {
      return;
    }
    final dir = await getPeerDownloadsDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}$cleanRel');
    if (!await file.exists()) return;
    final totalBytes = await file.length();
    final dummyPeer = PeerDeviceNode(
      deviceId: targetPeerId,
      deviceName: targetPeerName,
      platform: 'remote',
      host: '127.0.0.1',
      port: defaultHttpPort,
      lastSeenAt: DateTime.now(),
      isLanReachable: false,
    );
    final dummyTask = PeerFileTransferTask(
      id: transferId,
      peerId: targetPeerId,
      peerName: targetPeerName,
      fileName: cleanRel,
      totalBytes: totalBytes,
      isUpload: true,
      savedPath: file.path,
      createdAt: DateTime.now(),
    );
    await _sendFileOverWanTunnel(
      peer: dummyPeer,
      task: dummyTask,
      cleanName: cleanRel,
      totalBytes: totalBytes,
      fileObj: file,
      rawBytes: null,
      startedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Lists shared/received files on a remote [peer] via LAN Direct or Cross-Network WAN Tunnel.
  Future<List<PeerSharedFileItem>> fetchRemoteSharedFiles(
    PeerDeviceNode peer,
  ) async {
    if (peer.isLanReachable) {
      try {
        final uri = Uri.parse('${peer.baseUrl}/api/peer/files');
        final req = await _httpClient
            .getUrl(uri)
            .timeout(const Duration(seconds: 4));
        final resp = await req.close().timeout(const Duration(seconds: 4));
        if (resp.statusCode == HttpStatus.ok) {
          final body = await utf8.decoder.bind(resp).join();
          final decoded = jsonDecode(body);
          if (decoded is Map && decoded['files'] is List) {
            return (decoded['files'] as List)
                .whereType<Map>()
                .map(
                  (e) =>
                      PeerSharedFileItem.fromJson(Map<String, dynamic>.from(e)),
                )
                .toList();
          }
        } else {
          await resp.drain<void>();
        }
      } catch (_) {}
    }
    if (_isWanConnected) {
      final wanResp = await _sendWanRpcRequest(
        peer.deviceId,
        {'rpc': 'list_files'},
      );
      if (wanResp != null && wanResp['files'] is List) {
        return (wanResp['files'] as List)
            .whereType<Map>()
            .map(
              (e) => PeerSharedFileItem.fromJson(Map<String, dynamic>.from(e)),
            )
            .toList();
      }
    }
    return const [];
  }

  String buildRemoteFileStreamUrl(
    PeerDeviceNode peer,
    PeerSharedFileItem item,
  ) {
    return '${peer.baseUrl}/api/peer/file-download?path=${Uri.encodeQueryComponent(item.relativePath)}';
  }

  /// Downloads a file from a remote [peer]'s shared folder to local `流光互联接收` (supports LAN & Cross-Network WAN).
  Future<PeerFileTransferTask> downloadFileFromPeer({
    required PeerDeviceNode peer,
    required PeerSharedFileItem item,
  }) async {
    final task = PeerFileTransferTask(
      id: 'dl_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(9999)}',
      peerId: peer.deviceId,
      peerName: peer.deviceName,
      fileName: item.name,
      totalBytes: item.size,
      isUpload: false,
      createdAt: DateTime.now(),
    );
    _transfers.insert(0, task);
    notifyListeners();

    if (!peer.isLanReachable && _isWanConnected) {
      await _sendWanRpcRequest(
        peer.deviceId,
        {
          'rpc': 'pull_file_request',
          'relativePath': item.relativePath,
          'transferId': task.id,
        },
      );
      return task;
    }

    final startedAtMs = DateTime.now().millisecondsSinceEpoch;
    IOSink? sink;
    try {
      final uri = Uri.parse(buildRemoteFileStreamUrl(peer, item));
      final req = await _httpClient
          .getUrl(uri)
          .timeout(const Duration(seconds: 12));
      final resp = await req.close().timeout(const Duration(seconds: 12));
      if (resp.statusCode != HttpStatus.ok &&
          resp.statusCode != HttpStatus.partialContent) {
        await resp.drain<void>();
        throw Exception('HTTP ${resp.statusCode}');
      }

      final saveDir = await getPeerDownloadsDirectory();
      final targetFile = await _resolveUniqueSaveFile(saveDir, item.name);
      sink = targetFile.openWrite();

      int lastNotifyMs = 0;
      await for (final chunk in resp) {
        if (task.isCancelled) {
          throw Exception('已取消下载');
        }
        sink.add(chunk);
        task.transferredBytes += chunk.length;
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs - lastNotifyMs >= 120) {
          lastNotifyMs = nowMs;
          final elapsedSec =
              ((nowMs - startedAtMs) / 1000.0).clamp(0.05, 86400.0);
          task.speedBytesPerSec = task.transferredBytes / elapsedSec;
          notifyListeners();
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;

      task.savedPath = targetFile.path;
      task.status = 'completed';
      notifyListeners();
      return task;
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      task.status = task.isCancelled ? 'cancelled' : 'failed';
      task.error = e.toString();
      notifyListeners();
      return task;
    }
  }

  Future<File> _resolveUniqueSaveFile(Directory dir, String rawName) async {
    final safeName = rawName
        .replaceAll(RegExp(r'[/\\:\x00-\x1f]'), '_')
        .trim();
    final baseName = safeName.isEmpty
        ? 'file_${DateTime.now().millisecondsSinceEpoch}'
        : safeName;
    var candidate = File('${dir.path}${Platform.pathSeparator}$baseName');
    if (!await candidate.exists()) return candidate;
    final dot = baseName.lastIndexOf('.');
    final stem = dot > 0 ? baseName.substring(0, dot) : baseName;
    final ext = dot > 0 ? baseName.substring(dot) : '';
    for (int i = 1; i < 1000; i++) {
      candidate = File('${dir.path}${Platform.pathSeparator}${stem}_$i$ext');
      if (!await candidate.exists()) return candidate;
    }
    return candidate;
  }

  // ===========================================================================
  // Local HTTP Server Request Handler
  // ===========================================================================

  Future<void> _handleHttpRequest(HttpRequest req) async {
    req.response.headers.set('Access-Control-Allow-Origin', '*');
    req.response.headers.set(
      'Access-Control-Allow-Methods',
      'GET, POST, OPTIONS',
    );
    req.response.headers.set(
      'Access-Control-Allow-Headers',
      'Content-Type, X-File-Name, X-File-Size, X-Sender-Id, X-Sender-Name, X-Sender-Platform, X-Transfer-Id, Range',
    );
    if (req.method == 'OPTIONS') {
      req.response.statusCode = HttpStatus.noContent;
      await req.response.close();
      return;
    }

    final path = req.uri.path;
    try {
      if (path == '/api/peer/ws' &&
          WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        _handlePeerWebSocket(ws);
        return;
      }

      if (req.method == 'GET' && path == '/api/peer/info') {
        final info = _buildLocalNodeInfoMap();
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(info));
        await req.response.close();
        return;
      }

      if (req.method == 'GET' && path == '/api/peer/screen') {
        final mode = req.uri.queryParameters['mode'] ?? 'auto';
        final maxWidth =
            int.tryParse(req.uri.queryParameters['maxWidth'] ?? '') ?? 1280;
        final quality =
            int.tryParse(req.uri.queryParameters['quality'] ?? '') ?? 72;
        final frame = await captureLocalScreenFrame(
          mode: mode,
          maxWidth: maxWidth,
          quality: quality,
        );
        if (frame == null) {
          req.response.statusCode = HttpStatus.serviceUnavailable;
          await req.response.close();
          return;
        }
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.set(HttpHeaders.contentTypeHeader, frame.mimeType);
        req.response.headers.set('X-Capture-Mode', frame.actualMode);
        req.response.headers.set('X-Screen-Width', frame.width.toString());
        req.response.headers.set('X-Screen-Height', frame.height.toString());
        req.response.headers.set('Cache-Control', 'no-store');
        req.response.contentLength = frame.bytes.length;
        req.response.add(frame.bytes);
        await req.response.close();
        return;
      }

      if (req.method == 'POST' && path == '/api/peer/control') {
        final rawBody = await utf8.decoder.bind(req).join();
        final payload = jsonDecode(rawBody) as Map<String, dynamic>;
        final result = await _executeIncomingControlCommand(payload);
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(result));
        await req.response.close();
        return;
      }

      if (req.method == 'POST' && path == '/api/peer/message') {
        final rawBody = await utf8.decoder.bind(req).join();
        final decoded = jsonDecode(rawBody) as Map<String, dynamic>;
        final senderIp = req.connectionInfo?.remoteAddress.address;
        final msg = PeerChatMessage.fromJson(decoded, isOutgoingOverride: false);
        _appendChatMessage(msg, isIncoming: true);
        if (senderIp != null &&
            msg.senderId.isNotEmpty &&
            msg.senderId != _deviceId &&
            !_peers.containsKey(msg.senderId)) {
          unawaited(_probeSingleEndpoint('$senderIp:$defaultHttpPort'));
        }
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'ok': true}));
        await req.response.close();
        return;
      }

      if (req.method == 'POST' && path == '/api/peer/file-upload') {
        await _handleIncomingFileUploadRequest(req);
        return;
      }

      if (req.method == 'GET' && path == '/api/peer/files') {
        final files = await _listLocalSharedFiles();
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'ok': true,
            'files': files.map((f) => f.toJson()).toList(),
          }));
        await req.response.close();
        return;
      }

      if ((req.method == 'GET' || req.method == 'HEAD') &&
          path == '/api/peer/file-download') {
        await _handleSharedFileDownloadRequest(req);
        return;
      }

      final html = _buildWebConsoleHtml();
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(html);
      await req.response.close();
    } catch (e) {
      try {
        req.response
          ..statusCode = HttpStatus.internalServerError
          ..write(e.toString());
        await req.response.close();
      } catch (_) {}
    }
  }

  void _handlePeerWebSocket(WebSocket ws) {
    Timer? streamTimer;
    bool streamingFrame = false;
    String streamMode = 'auto';
    int streamMaxWidth = 1280;
    int streamQuality = 70;
    int streamFps = 5;

    void startLoop() {
      streamTimer?.cancel();
      final intervalMs = (1000 ~/ streamFps.clamp(1, 15)).clamp(65, 1000);
      streamTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) async {
        if (streamingFrame || ws.readyState != WebSocket.open) return;
        streamingFrame = true;
        try {
          final frame = await captureLocalScreenFrame(
            mode: streamMode,
            maxWidth: streamMaxWidth,
            quality: streamQuality,
          );
          if (frame != null && ws.readyState == WebSocket.open) {
            ws.add(jsonEncode({
              'event': 'screen_frame',
              'mode': frame.actualMode,
              'mimeType': frame.mimeType,
              'width': frame.width,
              'height': frame.height,
              'data': base64Encode(frame.bytes),
            }));
          }
        } catch (_) {
        } finally {
          streamingFrame = false;
        }
      });
    }

    ws.listen(
      (data) async {
        try {
          if (data is! String) return;
          final map = jsonDecode(data);
          if (map is! Map<String, dynamic>) return;
          final cmd = (map['cmd'] ?? map['action'] ?? '').toString();
          if (cmd == 'start_stream') {
            streamMode = (map['mode'] ?? 'auto').toString();
            streamMaxWidth =
                int.tryParse((map['maxWidth'] ?? 1280).toString()) ?? 1280;
            streamQuality =
                int.tryParse((map['quality'] ?? 70).toString()) ?? 70;
            streamFps = int.tryParse((map['fps'] ?? 5).toString()) ?? 5;
            startLoop();
          } else if (cmd == 'stop_stream') {
            streamTimer?.cancel();
            streamTimer = null;
          } else {
            final res = await _executeIncomingControlCommand(map);
            if (ws.readyState == WebSocket.open) {
              ws.add(jsonEncode({'event': 'control_ack', ...res}));
            }
          }
        } catch (_) {}
      },
      onDone: () {
        streamTimer?.cancel();
      },
      onError: (_) {
        streamTimer?.cancel();
      },
    );
  }

  Future<void> _handleIncomingFileUploadRequest(HttpRequest req) async {
    final rawNameHeader = req.headers.value('x-file-name') ?? '';
    final fileName = Uri.decodeComponent(
      rawNameHeader.isNotEmpty ? rawNameHeader : '接收文件.bin',
    );
    final totalBytes =
        int.tryParse(req.headers.value('x-file-size') ?? '') ??
            (req.contentLength > 0 ? req.contentLength : 0);
    final senderId = req.headers.value('x-sender-id') ?? 'remote';
    final senderName = Uri.decodeComponent(
      req.headers.value('x-sender-name') ?? '远程客户端',
    );
    final senderPlatform = req.headers.value('x-sender-platform') ?? 'unknown';
    final transferId = req.headers.value('x-transfer-id') ??
        'in_${DateTime.now().millisecondsSinceEpoch}';

    final saveDir = await getPeerDownloadsDirectory();
    final targetFile = await _resolveUniqueSaveFile(saveDir, fileName);

    final task = PeerFileTransferTask(
      id: transferId,
      peerId: senderId,
      peerName: senderName,
      fileName: targetFile.uri.pathSegments.last,
      totalBytes: totalBytes,
      isUpload: false,
      savedPath: targetFile.path,
      createdAt: DateTime.now(),
    );
    _transfers.insert(0, task);
    notifyListeners();

    final startedAtMs = DateTime.now().millisecondsSinceEpoch;
    final sink = targetFile.openWrite();
    int lastNotifyMs = 0;
    try {
      await for (final chunk in req) {
        sink.add(chunk);
        task.transferredBytes += chunk.length;
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs - lastNotifyMs >= 120) {
          lastNotifyMs = nowMs;
          final elapsedSec =
              ((nowMs - startedAtMs) / 1000.0).clamp(0.05, 86400.0);
          task.speedBytesPerSec = task.transferredBytes / elapsedSec;
          notifyListeners();
        }
      }
      await sink.flush();
      await sink.close();

      task.status = 'completed';
      final savedName = targetFile.uri.pathSegments.last;
      _appendChatMessage(
        PeerChatMessage(
          id: transferId,
          senderId: senderId,
          senderName: senderName,
          senderPlatform: senderPlatform,
          targetId: _deviceId,
          text: '收到文件：$savedName',
          type: 'file',
          fileName: savedName,
          fileSize: task.transferredBytes,
          localFilePath: targetFile.path,
          timestamp: DateTime.now(),
          isOutgoing: false,
        ),
        isIncoming: true,
      );
      notifyListeners();

      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'ok': true,
          'savedPath': targetFile.path,
          'size': task.transferredBytes,
        }));
      await req.response.close();
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      task.status = 'failed';
      task.error = e.toString();
      notifyListeners();
      req.response
        ..statusCode = HttpStatus.internalServerError
        ..write(jsonEncode({'ok': false, 'error': e.toString()}));
      await req.response.close();
    }
  }

  Future<List<PeerSharedFileItem>> _listLocalSharedFiles() async {
    final result = <PeerSharedFileItem>[];
    final dir = await getPeerDownloadsDirectory();
    if (!await dir.exists()) return result;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File) {
        try {
          final stat = await entity.stat();
          final name = entity.uri.pathSegments.last;
          if (name.startsWith('.')) continue;
          result.add(
            PeerSharedFileItem(
              name: name,
              relativePath: name,
              size: stat.size,
              modifiedAt: stat.modified,
            ),
          );
        } catch (_) {}
      }
    }
    result.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return result;
  }

  Future<void> _handleSharedFileDownloadRequest(HttpRequest req) async {
    final rel = (req.uri.queryParameters['path'] ?? '').trim();
    if (rel.isEmpty ||
        rel.contains('..') ||
        rel.contains('/') ||
        rel.contains('\\')) {
      req.response.statusCode = HttpStatus.badRequest;
      await req.response.close();
      return;
    }
    final dir = await getPeerDownloadsDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}$rel');
    if (!await file.exists()) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final totalSize = await file.length();
    final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
    int start = 0;
    int end = totalSize > 0 ? totalSize - 1 : 0;
    bool isPartial = false;

    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final parts = rangeHeader.substring(6).split('-');
      final s = int.tryParse(parts[0].trim());
      final e = parts.length > 1 ? int.tryParse(parts[1].trim()) : null;
      if (s != null && s >= 0 && s < totalSize) {
        start = s;
        end = (e != null && e >= s && e < totalSize) ? e : totalSize - 1;
        isPartial = true;
      }
    }

    final contentLength = totalSize == 0 ? 0 : (end - start + 1);
    req.response.statusCode =
        isPartial ? HttpStatus.partialContent : HttpStatus.ok;
    req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    req.response.headers.set(
      HttpHeaders.contentTypeHeader,
      _inferMimeType(rel),
    );
    req.response.headers.set(
      'Content-Disposition',
      'inline; filename="${Uri.encodeComponent(rel)}"',
    );
    if (isPartial) {
      req.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$totalSize',
      );
    }
    req.response.contentLength = contentLength;
    if (req.method == 'HEAD' || contentLength <= 0) {
      await req.response.close();
      return;
    }
    await req.response.addStream(file.openRead(start, end + 1));
    await req.response.close();
  }

  static String _inferMimeType(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.mp4') || lower.endsWith('.m4v')) return 'video/mp4';
    if (lower.endsWith('.mkv')) return 'video/x-matroska';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.ts')) return 'video/mp2t';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.flac')) return 'audio/flac';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    return 'application/octet-stream';
  }

  /// Detects all local IPv4 addresses, prioritizing LAN (`en*`, `wlan*`, `eth*`)
  /// and also including Tailscale (`100.x.x.x`), ZeroTier (`zt*`), and VPN interfaces.
  static Future<List<String>> _detectAllLocalIps() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final primary = <String>[];
      final secondary = <String>[];
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (!ip.startsWith('169.254.') && ip != '127.0.0.1') {
            if (name.startsWith('en') ||
                name.startsWith('wlan') ||
                name.startsWith('eth') ||
                name.startsWith('wi-fi')) {
              if (!primary.contains(ip)) primary.add(ip);
            } else {
              if (!secondary.contains(ip)) secondary.add(ip);
            }
          }
        }
      }
      return [...primary, ...secondary];
    } catch (_) {
      return const [];
    }
  }

  String _buildWebConsoleHtml() {
    final safeName = const HtmlEscape().convert(_deviceName);
    return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
  <title>$safeName · 流光设备互联远程控制台</title>
  <style>
    * { box-sizing: border-box; }
    body {
      margin: 0; padding: 14px;
      background: #0B0D13; color: #F1F5F9;
      font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif;
    }
    .wrap { max-width: 1080px; margin: 0 auto; }
    .header {
      display: flex; align-items: center; justify-content: space-between;
      background: #161923; border: 1px solid #2A3042;
      padding: 12px 16px; border-radius: 14px; margin-bottom: 12px;
    }
    .screen-box {
      background: #050608; border: 1px solid #2A3042;
      border-radius: 14px; overflow: hidden; text-align: center;
      position: relative; margin-bottom: 12px;
    }
    #screenImg { width: 100%; max-height: 72vh; object-fit: contain; cursor: crosshair; display: block; margin: 0 auto; }
    .toolbar {
      display: flex; flex-wrap: wrap; gap: 8px;
      background: #161923; border: 1px solid #2A3042;
      padding: 12px; border-radius: 14px; margin-bottom: 12px;
    }
    button, select, input[type="text"] {
      background: #232838; color: #F8FAFC;
      border: 1px solid #384159; border-radius: 10px;
      padding: 8px 12px; font-size: 13px; font-weight: 600;
    }
    button:hover { background: #0284C7; border-color: #38BDF8; cursor: pointer; }
    .flex-grow { flex: 1; min-width: 180px; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="header">
      <div>
        <strong style="font-size:16px;color:#38BDF8;">🖥️ $safeName · 远程桌面与互联中心</strong>
        <div style="font-size:12px;color:#94A3B8;margin-top:2px;">点击下方画面即可直接远程操控，支持发送文字、快捷键、消息与传输文件</div>
      </div>
      <div>
        <select id="modeSel" onchange="refreshScreen()">
          <option value="auto">自动画面 (桌面/应用)</option>
          <option value="desktop">系统全桌面</option>
          <option value="app">应用内画面</option>
        </select>
      </div>
    </div>
    <div class="screen-box">
      <img id="screenImg" src="/api/peer/screen?mode=auto" alt="远程画面加载中..." onclick="onScreenClick(event)" />
    </div>
    <div class="toolbar">
      <button onclick="sendKey('up')">⬆️ 上</button>
      <button onclick="sendKey('down')">⬇️ 下</button>
      <button onclick="sendKey('left')">⬅️ 左</button>
      <button onclick="sendKey('right')">➡️ 右</button>
      <button onclick="sendKey('enter')">⏎ 确定</button>
      <button onclick="sendKey('back')">🔙 返回</button>
      <button onclick="sendKey('space')">⏯️ 播放/暂停</button>
      <button onclick="sendKey('home')">🏠 首页</button>
    </div>
    <div class="toolbar">
      <input type="text" id="textInp" class="flex-grow" placeholder="输入远程文字或发送聊天消息..." />
      <button onclick="sendRemoteText()">⌨️ 填入远程输入框</button>
      <button onclick="sendChatMsg()">💬 发送聊天消息</button>
    </div>
  </div>
  <script>
    const img = document.getElementById('screenImg');
    const modeSel = document.getElementById('modeSel');
    function refreshScreen() {
      const m = modeSel.value;
      img.src = '/api/peer/screen?mode=' + m + '&t=' + Date.now();
    }
    setInterval(refreshScreen, 450);
    function onScreenClick(e) {
      const rect = img.getBoundingClientRect();
      const nx = Math.max(0, Math.min(1, (e.clientX - rect.left) / Math.max(1, rect.width)));
      const ny = Math.max(0, Math.min(1, (e.clientY - rect.top) / Math.max(1, rect.height)));
      fetch('/api/peer/control', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({action: 'mouse', type: 'tap', nx: nx, ny: ny, targetMode: modeSel.value === 'desktop' ? 'desktop' : 'app'})
      }).then(() => setTimeout(refreshScreen, 80));
    }
    function sendKey(k) {
      fetch('/api/peer/control', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({action: 'key', key: k, targetMode: modeSel.value === 'desktop' ? 'desktop' : 'app'})
      }).then(() => setTimeout(refreshScreen, 80));
    }
    function sendRemoteText() {
      const val = document.getElementById('textInp').value;
      if (!val) return;
      fetch('/api/peer/control', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({action: 'text', text: val, submit: true, targetMode: modeSel.value === 'desktop' ? 'desktop' : 'app'})
      });
    }
    function sendChatMsg() {
      const val = document.getElementById('textInp').value;
      if (!val) return;
      fetch('/api/peer/message', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({id: 'web_' + Date.now(), senderId: 'web_browser', senderName: '网页端控制台', text: val, type: 'text', timestampMs: Date.now()})
      }).then(() => { document.getElementById('textInp').value = ''; alert('消息已发送'); });
    }
  </script>
</body>
</html>
''';
  }
}
