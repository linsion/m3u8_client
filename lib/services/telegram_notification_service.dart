import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'api_client.dart';

/// Cross-platform Telegram real-time notification service (macOS, iOS/iPadOS,
/// Android, Android TV, Apple TV, Windows, Linux).
///
/// Connects to `/api/telegram/notification-stream` via SSE and strictly filters
/// out muted chats (`event.notificationMuted`, `chat.muted`, local mute) and
/// silent messages (`message.silent == true`).
class TelegramNotificationService extends ChangeNotifier {
  static const MethodChannel _channel = MethodChannel(
    'com.linsion.m3u8_client/notifications',
  );
  static const String _prefSystemNotifyEnabledKey =
      'm3u8_tg_system_notifications_v1';
  static const String _prefInAppNotifyEnabledKey =
      'm3u8_tg_inapp_notifications_v1';
  static const String _prefNotifySoundEnabledKey =
      'm3u8_tg_notify_sound_v1';
  static const String _prefMutedPeersKey = 'm3u8_tg_muted_peers_v1';
  static const String _prefServerMutedPeersKey =
      'm3u8_tg_server_muted_peers_v1';

  static final RegExp _validPeerRegex = RegExp(
    r'^(user|chat|channel):[1-9]\d*$',
  );
  static final RegExp _rawPeerTitleRegex = RegExp(
    r'^:?(user|chat|channel):\d+$',
    caseSensitive: false,
  );

  final ApiClient Function() _apiProvider;
  final bool Function(String accountId, String peer) _isReadingPeer;
  final String Function(String accountId, String peer) _resolveChatTitle;
  final void Function(String accountId, String peer, int messageId)
      _onOpenNotification;

  final StreamController<TelegramNotificationEvent> _eventController =
      StreamController<TelegramNotificationEvent>.broadcast();

  final Map<String, TelegramAccount> _accountsById = {};
  final Map<String, TelegramNotificationItem> _pendingByKey = {};
  final Map<String, int> _seenMessageTimestamps = {};
  final Set<String> _locallyMutedPeers = {};
  final Set<String> _serverMutedPeers = {};

  bool _systemNotificationsEnabled = true;
  bool _inAppNotificationsEnabled = true;
  bool _soundEnabled = true;
  bool _systemPermissionGranted = false;
  bool _running = false;
  bool _disposed = false;
  String _statusText = '仅提醒未静默会话';

  int _bornMs = DateTime.now().millisecondsSinceEpoch;
  int _generation = 0;
  String _connectedIdsKey = '';
  int _reconnectDelayMs = 0;
  int _lastStreamEventMs = 0;

  HttpClient? _sseHttpClient;
  StreamSubscription<String>? _sseLineSub;
  Timer? _reconnectTimer;
  Timer? _accountsRefreshTimer;
  Timer? _watchdogTimer;

  TelegramNotificationService({
    required ApiClient Function() apiProvider,
    required bool Function(String accountId, String peer) isReadingPeer,
    required String Function(String accountId, String peer) resolveChatTitle,
    required void Function(String accountId, String peer, int messageId)
        onOpenNotification,
  })  : _apiProvider = apiProvider,
        _isReadingPeer = isReadingPeer,
        _resolveChatTitle = resolveChatTitle,
        _onOpenNotification = onOpenNotification {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  Stream<TelegramNotificationEvent> get eventStream => _eventController.stream;

  @visibleForTesting
  List<String> get registeredAccountIdsForTesting =>
      _accountsById.keys.toList(growable: false);

  @visibleForTesting
  void injectSseEventForTesting(String eventType, String rawData) =>
      _handleSseFrame(eventType, rawData);

  bool get systemNotificationsEnabled => _systemNotificationsEnabled;
  bool get inAppNotificationsEnabled => _inAppNotificationsEnabled;
  bool get soundEnabled => _soundEnabled;
  bool get systemPermissionGranted => _systemPermissionGranted;
  bool get isRunning => _running;
  String get statusText => _statusText;

  List<TelegramNotificationItem> get pendingNotifications {
    final items = _pendingByKey.values.toList();
    items.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    return items;
  }

  int get totalUnreadNotificationCount {
    int sum = 0;
    for (final item in _pendingByKey.values) {
      sum += item.count;
    }
    return sum;
  }

  String _peerKey(String accountId, String peer) => '$accountId|$peer';
  String _pendingKey(String accountId, String peer) => '$accountId\n$peer';

  bool isPeerMuted(String accountId, String peer) {
    final key = _peerKey(accountId, peer);
    return _locallyMutedPeers.contains(key) || _serverMutedPeers.contains(key);
  }

  bool isServerPeerMuted(String accountId, String peer) {
    return _serverMutedPeers.contains(_peerKey(accountId, peer));
  }

  void recordServerChatMuteState(
    String accountId,
    String peer,
    bool muted,
  ) {
    if (peer.trim().isEmpty) return;
    final key = _peerKey(accountId, peer);
    bool changed = false;
    if (muted) {
      changed = _serverMutedPeers.add(key);
      dismissByPeer(accountId, peer);
    } else {
      changed = _serverMutedPeers.remove(key);
    }
    if (changed) {
      notifyListeners();
      if (!Platform.environment.containsKey('FLUTTER_TEST')) {
        unawaited(
          SharedPreferences.getInstance().then((prefs) {
            prefs.setStringList(
              _prefServerMutedPeersKey,
              _serverMutedPeers.toList(),
            );
          }).catchError((_) {}),
        );
      }
    }
  }

  Future<void> toggleLocalPeerMute(String accountId, String peer) async {
    final key = _peerKey(accountId, peer);
    if (_locallyMutedPeers.contains(key)) {
      _locallyMutedPeers.remove(key);
    } else {
      _locallyMutedPeers.add(key);
      dismissByPeer(accountId, peer);
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _prefMutedPeersKey,
        _locallyMutedPeers.toList(),
      );
    } catch (_) {}
  }

  Future<void> initializeAndStart() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _systemNotificationsEnabled =
          prefs.getBool(_prefSystemNotifyEnabledKey) ?? true;
      _inAppNotificationsEnabled =
          prefs.getBool(_prefInAppNotifyEnabledKey) ?? true;
      _soundEnabled = prefs.getBool(_prefNotifySoundEnabledKey) ?? true;
      final savedMuted = prefs.getStringList(_prefMutedPeersKey);
      if (savedMuted != null) {
        _locallyMutedPeers
          ..clear()
          ..addAll(savedMuted);
      }
      final savedServerMuted = prefs.getStringList(_prefServerMutedPeersKey);
      if (savedServerMuted != null) {
        _serverMutedPeers
          ..clear()
          ..addAll(savedServerMuted);
      }
    } catch (_) {}

    if (_disposed) return;
    await _checkAndRequestNativePermission(interactive: _systemNotificationsEnabled);
    if (_disposed) return;
    start();
  }

  Future<bool> _checkAndRequestNativePermission({
    bool interactive = false,
  }) async {
    if (kIsWeb) return false;
    if (Platform.isLinux || Platform.isWindows) {
      _systemPermissionGranted = true;
      _updateStatusLabel();
      return true;
    }
    try {
      final hasPerm =
          await _channel.invokeMethod<bool>('getPermissionStatus') ?? false;
      if (hasPerm) {
        _systemPermissionGranted = true;
        _updateStatusLabel();
        return true;
      }
      if (interactive) {
        final granted =
            await _channel.invokeMethod<bool>('requestPermission') ?? false;
        _systemPermissionGranted = granted;
        _updateStatusLabel();
        return granted;
      }
    } catch (_) {}
    _updateStatusLabel();
    return _systemPermissionGranted;
  }

  void _updateStatusLabel() {
    if (!_systemNotificationsEnabled && !_inAppNotificationsEnabled) {
      _statusText = '已暂停所有消息提醒';
    } else if (_systemNotificationsEnabled && _systemPermissionGranted) {
      _statusText = '仅提醒未静默会话 · 系统及应用内';
    } else {
      _statusText = '仅提醒未静默会话 · 应用内横幅';
    }
    notifyListeners();
  }

  Future<void> setSystemNotificationsEnabled(bool enabled) async {
    _systemNotificationsEnabled = enabled;
    if (enabled) {
      await _checkAndRequestNativePermission(interactive: true);
    } else {
      _updateStatusLabel();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefSystemNotifyEnabledKey, enabled);
    } catch (_) {}
  }

  Future<void> setInAppNotificationsEnabled(bool enabled) async {
    _inAppNotificationsEnabled = enabled;
    if (!enabled) {
      _pendingByKey.clear();
      _syncNativeBadgeCount();
    }
    _updateStatusLabel();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefInAppNotifyEnabledKey, enabled);
    } catch (_) {}
  }

  Future<void> setSoundEnabled(bool enabled) async {
    _soundEnabled = enabled;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefNotifySoundEnabledKey, enabled);
    } catch (_) {}
  }

  void start() {
    if (_running) return;
    _running = true;
    _bornMs = DateTime.now().millisecondsSinceEpoch;
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _checkConnectionsWatchdog(),
    );
    _updateStatusLabel();
    unawaited(refreshAccountsAndConnect());
  }

  /// Ensure the specified [accountId] is registered and its SSE stream is actively connected.
  void registerActiveAccountId(String accountId) {
    final clean = accountId.trim();
    if (clean.isEmpty) return;
    if (!_accountsById.containsKey(clean)) {
      _accountsById[clean] = TelegramAccount(id: clean, name: 'Telegram');
    }
    if (!_running) {
      return;
    }
    final validIds = _accountsById.keys.toList()..sort();
    final sortedIdsKey = validIds.join(',');
    if (sortedIdsKey != _connectedIdsKey || _sseLineSub == null) {
      _connectSseStream(sortedIdsKey);
    }
  }

  void stop() {
    _running = false;
    _generation++;
    _accountsRefreshTimer?.cancel();
    _watchdogTimer?.cancel();
    _reconnectTimer?.cancel();
    _closeActiveSseStream();
    _connectedIdsKey = '';
    _accountsById.clear();
    _pendingByKey.clear();
    _dismissAllNativeNotifications();
    notifyListeners();
  }

  Future<void> refreshAccountsAndConnect() async {
    final currentGen = ++_generation;
    _accountsRefreshTimer?.cancel();

    try {
      final accData = await _apiProvider().fetchTelegramAccounts();
      if (_disposed || currentGen != _generation) return;

      var validAccounts = accData.accounts
          .where((a) => a.userId.isNotEmpty && a.userId != '0')
          .toList();
      if (validAccounts.isEmpty && accData.accounts.isNotEmpty) {
        validAccounts = accData.accounts
            .where((a) => a.id.trim().isNotEmpty)
            .toList();
      }
      final validIds = validAccounts.map((a) => a.id).toSet();
      if (accData.activeId.trim().isNotEmpty) {
        validIds.add(accData.activeId.trim());
      }
      if (validIds.isEmpty) {
        validIds.add('default');
      }

      _accountsById.removeWhere((id, _) => !validIds.contains(id));
      for (final acc in validAccounts) {
        _accountsById[acc.id] = acc;
      }
      for (final id in validIds) {
        _accountsById.putIfAbsent(
          id,
          () => TelegramAccount(id: id, name: 'Telegram'),
        );
      }

      final removedKeys = _pendingByKey.entries
          .where((e) => !validIds.contains(e.value.accountId))
          .map((e) => e.key)
          .toList();
      for (final k in removedKeys) {
        dismiss(k);
      }

      if (!_running) return;
      final sortedIdsKey = (validIds.toList()..sort()).join(',');
      if (sortedIdsKey != _connectedIdsKey || _sseLineSub == null) {
        _connectSseStream(sortedIdsKey);
      }
      _updateStatusLabel();
    } catch (_) {
      if (_running && currentGen == _generation) {
        if (_sseLineSub == null) {
          final fallbackKey =
              _connectedIdsKey.isNotEmpty ? _connectedIdsKey : 'default';
          _connectSseStream(fallbackKey);
        }
        _statusText = '消息提醒连接重试中...';
        notifyListeners();
      }
    } finally {
      if (_running && currentGen == _generation) {
        _accountsRefreshTimer = Timer(
          const Duration(seconds: 30),
          refreshAccountsAndConnect,
        );
      }
    }
  }

  void _checkConnectionsWatchdog() {
    if (!_running) return;
    reconcileReadingState();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_connectedIdsKey.isNotEmpty &&
        _reconnectTimer == null &&
        (_sseLineSub == null ||
            (_lastStreamEventMs > 0 && nowMs - _lastStreamEventMs > 28000))) {
      _connectSseStream(_connectedIdsKey, previousDelayMs: _reconnectDelayMs);
    }
  }

  /// Records server mute state from a [chats] snapshot without generating
  /// synthetic notifications (since `/api/telegram/notification-stream` is the
  /// authoritative source of Telegram's per-peer `notification_muted` setting).
  void syncChatsForNotifications(String accountId, List<TelegramChat> chats) {
    if (_disposed || chats.isEmpty) return;
    final cleanAcc = accountId.trim().isNotEmpty ? accountId.trim() : 'default';
    for (final chat in chats) {
      if (!_validPeerRegex.hasMatch(chat.peer)) continue;
      if (chat.muted) {
        recordServerChatMuteState(cleanAcc, chat.peer, true);
      }
    }
  }

  void _closeActiveSseStream() {
    _sseLineSub?.cancel();
    _sseLineSub = null;
    try {
      _sseHttpClient?.close(force: true);
    } catch (_) {}
    _sseHttpClient = null;
  }

  void _connectSseStream(String idsKey, {int previousDelayMs = 0}) {
    _closeActiveSseStream();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _connectedIdsKey = idsKey;

    if (!_running || idsKey.isEmpty) return;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _lastStreamEventMs = nowMs;
    _reconnectDelayMs = previousDelayMs;

    void scheduleRetry() {
      if (!_running || _connectedIdsKey != idsKey) return;
      _closeActiveSseStream();
      _reconnectTimer?.cancel();
      final nextDelay = _reconnectDelayMs <= 0
          ? 1200
          : (_reconnectDelayMs * 2).clamp(1200, 12000);
      _reconnectDelayMs = nextDelay;
      _reconnectTimer = Timer(Duration(milliseconds: nextDelay), () {
        _reconnectTimer = null;
        if (_running && _connectedIdsKey == idsKey) {
          _connectSseStream(idsKey, previousDelayMs: nextDelay);
        }
      });
    }

    unawaited(() async {
      try {
        final api = _apiProvider();
        final uri = api.buildTelegramNotificationStreamUri(idsKey.split(','));
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 12)
          ..findProxy = ((Uri u) => api.buildProxyDirectiveForUri(u))
          ..badCertificateCallback = (_, __, ___) => true;
        _sseHttpClient = client;

        final req = await client.getUrl(uri);
        req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
        req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
        api.authHeaders.forEach((k, v) {
          req.headers.set(k, v);
        });

        final resp = await req.close();
        if (!_running || _sseHttpClient != client) {
          client.close(force: true);
          return;
        }
        if (resp.statusCode != 200) {
          scheduleRetry();
          return;
        }

        String currentEvent = 'message';
        final dataBuffer = StringBuffer();

        _sseLineSub = resp
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
          (line) {
            if (!_running || _sseHttpClient != client) return;
            _lastStreamEventMs = DateTime.now().millisecondsSinceEpoch;

            if (line.isEmpty) {
              // Dispatch accumulated SSE frame
              final rawData = dataBuffer.toString().trim();
              final eventType = currentEvent;
              currentEvent = 'message';
              dataBuffer.clear();
              _handleSseFrame(eventType, rawData);
              return;
            }
            if (line.startsWith(':')) return;
            if (line.startsWith('event:')) {
              currentEvent = line.substring(6).trim();
            } else if (line.startsWith('data:')) {
              if (dataBuffer.isNotEmpty) dataBuffer.write('\n');
              dataBuffer.write(line.substring(5).trim());
            }
          },
          onError: (_) => scheduleRetry(),
          onDone: scheduleRetry,
          cancelOnError: true,
        );
      } catch (_) {
        scheduleRetry();
      }
    }());
  }

  void _handleSseFrame(String eventType, String rawData) {
    if (eventType == 'ready') {
      _reconnectDelayMs = 0;
      _updateStatusLabel();
      return;
    }
    if (eventType == 'heartbeat') {
      return;
    }
    if (eventType == 'account-error') {
      _statusText = '部分账号消息连接重试中';
      notifyListeners();
      return;
    }
    if ((eventType != 'update' && eventType != 'message') || rawData.isEmpty) {
      return;
    }

    try {
      final decoded = jsonDecode(rawData);
      if (decoded is! Map<String, dynamic>) return;
      final event = TelegramNotificationEvent.fromJson(decoded);
      _eventController.add(event);

      final account = _accountsById[event.accountId] ??
          TelegramAccount(id: event.accountId, name: 'Telegram');
      _receiveUpdateEvent(account, event);
    } catch (_) {
      // Malformed frame never stops subsequent notifications
    }
  }

  @visibleForTesting
  void handleNotificationEventForTest(
    TelegramAccount account,
    TelegramNotificationEvent event,
  ) {
    _receiveUpdateEvent(account, event);
  }

  void _receiveUpdateEvent(
    TelegramAccount account,
    TelegramNotificationEvent event,
  ) {
    if (_validPeerRegex.hasMatch(event.peer) &&
        (event.notificationSettingsChanged ||
            event.newMessage ||
            event.notificationMuted)) {
      recordServerChatMuteState(
        account.id,
        event.peer,
        event.notificationMuted,
      );
    }

    if (event.notificationSettingsChanged) {
      final keysToRemove = _pendingByKey.entries
          .where(
            (e) =>
                e.value.accountId == account.id &&
                (event.peer.isEmpty || e.value.peer == event.peer),
          )
          .map((e) => e.key)
          .toList();
      for (final k in keysToRemove) {
        dismiss(k);
      }
    }

    final key = _pendingKey(account.id, event.peer);
    if (event.readMaxId > 0) {
      final existing = _pendingByKey[key];
      if (existing != null && existing.message.id <= event.readMaxId) {
        dismiss(key);
      }
    }

    final message = event.message;
    if (!event.newMessage || !_validPeerRegex.hasMatch(event.peer)) {
      return;
    }
    if (message == null || message.id <= 0) {
      if (!event.notificationMuted &&
          !isPeerMuted(account.id, event.peer) &&
          !_isReadingPeer(account.id, event.peer) &&
          !Platform.environment.containsKey('FLUTTER_TEST')) {
        unawaited(_fetchAndNotifyMissingMessagePayload(account, event));
      }
      return;
    }
    if (message.outgoing) {
      return;
    }

    // Ignore Telegram's historical catch-up batch on initial subscription
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (message.date > 0 && message.date * 1000 < _bornMs - 30000) {
      return;
    }

    // Deduplicate seen message IDs
    final uniqueId = '$key\n${message.id}';
    if (_seenMessageTimestamps.containsKey(uniqueId)) {
      return;
    }
    _seenMessageTimestamps[uniqueId] = nowMs;
    if (_seenMessageTimestamps.length > 5000) {
      final cutoff = nowMs - 86400000;
      _seenMessageTimestamps.removeWhere((_, ts) => ts < cutoff);
      while (_seenMessageTimestamps.length > 5000) {
        _seenMessageTimestamps.remove(_seenMessageTimestamps.keys.first);
      }
    }

    // Strictly do NOT notify for muted chats or silent messages ("那些静默的不要通知")
    if (event.notificationMuted) {
      recordServerChatMuteState(account.id, event.peer, true);
      dismiss(key);
      return;
    }
    if (message.silent) {
      if (event.peer.startsWith('channel:') || event.peer.startsWith('chat:')) {
        recordServerChatMuteState(account.id, event.peer, true);
      }
      return;
    }
    if (isPeerMuted(account.id, event.peer)) {
      return;
    }

    // Do not notify if the user is actively reading this exact conversation
    if (_isReadingPeer(account.id, event.peer)) {
      dismiss(key);
      return;
    }

    final resolvedTitle = _resolveChatTitle(account.id, event.peer).trim();
    final rawTitle = resolvedTitle.isNotEmpty
        ? resolvedTitle
        : (event.chatTitle.trim().isNotEmpty
            ? event.chatTitle.trim()
            : (message.sender.trim().isNotEmpty
                ? message.sender.trim()
                : 'Telegram 新消息'));
    final title = _rawPeerTitleRegex.hasMatch(rawTitle)
        ? 'Telegram 新消息'
        : rawTitle;

    final isPrivateChat = event.peer.startsWith('user:');
    final resolvedMsgPreview =
        message.resolvedPreviewText(isPrivateUserChat: isPrivateChat).trim();
    final contentText = (resolvedMsgPreview.isNotEmpty &&
            !resolvedMsgPreview.startsWith('[暂不支持'))
        ? resolvedMsgPreview
        : (message.attachment?.displayName.isNotEmpty == true
            ? '[${message.attachment!.isVideo ? "视频" : (message.attachment!.isPhoto ? "图片" : "文件")}] ${message.attachment!.displayName}'
            : '收到一条新消息');

    var senderClean = message.sender.trim();
    if (_rawPeerTitleRegex.hasMatch(senderClean)) {
      final resolvedSender = _resolveChatTitle(
        account.id,
        TelegramChat.normalizePeerIdentifier(senderClean),
      ).trim();
      senderClean = _rawPeerTitleRegex.hasMatch(resolvedSender)
          ? ''
          : resolvedSender;
    }
    final senderPrefix = (senderClean.isNotEmpty &&
            senderClean != title &&
            !_rawPeerTitleRegex.hasMatch(senderClean))
        ? '$senderClean：'
        : '';

    final combinedPreview = '$senderPrefix$contentText';
    final preview = combinedPreview.characters.take(180).toString();
    final count = (_pendingByKey[key]?.count ?? 0) + 1;

    final item = TelegramNotificationItem(
      key: key,
      accountId: account.id,
      accountName: account.name.isNotEmpty ? account.name : 'Telegram',
      peer: event.peer,
      title: title,
      preview: preview,
      message: message,
      count: count,
      updatedAtMs: nowMs,
    );

    if (_inAppNotificationsEnabled) {
      _pendingByKey.remove(key);
      _pendingByKey[key] = item;
      while (_pendingByKey.length > 100) {
        _pendingByKey.remove(_pendingByKey.keys.first);
      }
      _syncNativeBadgeCount();
      notifyListeners();
    }

    if (_systemNotificationsEnabled) {
      unawaited(_presentNativeSystemNotification(item));
    }
  }

  Future<void> _fetchAndNotifyMissingMessagePayload(
    TelegramAccount account,
    TelegramNotificationEvent event,
  ) async {
    try {
      final res = await _apiProvider().fetchTelegramMessages(
        accountId: account.id,
        peer: event.peer,
        offsetId: 0,
        limit: 1,
      );
      if (!_running || _disposed || res.messages.isEmpty) return;
      final latest = res.messages.last;
      if (latest.outgoing || latest.id <= 0) return;
      _receiveUpdateEvent(
        account,
        TelegramNotificationEvent(
          accountId: account.id,
          peer: event.peer,
          chatTitle: event.chatTitle,
          newMessage: true,
          notificationMuted: event.notificationMuted,
          message: latest,
        ),
      );
    } catch (_) {}
  }

  void reconcileReadingState() {
    final toDismiss = <String>[];
    for (final entry in _pendingByKey.entries) {
      if (_isReadingPeer(entry.value.accountId, entry.value.peer)) {
        toDismiss.add(entry.key);
      }
    }
    for (final key in toDismiss) {
      dismiss(key);
    }
  }

  void dismissByPeer(String accountId, String peer) {
    dismiss(_pendingKey(accountId, peer));
  }

  void dismiss(String key) {
    final removed = _pendingByKey.remove(key);
    if (removed != null) {
      _syncNativeBadgeCount();
      notifyListeners();
    }
    if (!kIsWeb && !Platform.isLinux && !Platform.isWindows) {
      unawaited(
        _channel
            .invokeMethod('dismissNotification', {'key': key})
            .catchError((_) {}),
      );
    }
  }

  void dismissAll() {
    if (_pendingByKey.isEmpty) return;
    _pendingByKey.clear();
    _dismissAllNativeNotifications();
    notifyListeners();
  }

  void openNotification(String key) {
    final item = _pendingByKey[key];
    if (item == null) return;
    dismiss(key);
    _onOpenNotification(item.accountId, item.peer, item.message.id);
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onNotificationTapped') {
      final args = call.arguments;
      if (args is Map) {
        final key = (args['key'] ?? '').toString();
        final accountId = (args['accountId'] ?? 'default').toString();
        final peer = (args['peer'] ?? '').toString();
        final messageId =
            int.tryParse((args['messageId'] ?? 0).toString()) ?? 0;
        if (key.isNotEmpty) {
          dismiss(key);
        } else if (peer.isNotEmpty) {
          dismissByPeer(accountId, peer);
        }
        if (peer.isNotEmpty) {
          _onOpenNotification(accountId, peer, messageId);
        }
      }
    }
  }

  void _syncNativeBadgeCount() {
    if (kIsWeb || Platform.isLinux || Platform.isWindows) return;
    final total = totalUnreadNotificationCount;
    unawaited(
      _channel
          .invokeMethod('setBadgeCount', {'count': total})
          .catchError((_) {}),
    );
  }

  void _dismissAllNativeNotifications() {
    if (kIsWeb || Platform.isLinux || Platform.isWindows) return;
    unawaited(
      _channel.invokeMethod('dismissAllNotifications').catchError((_) {}),
    );
  }

  Future<void> _presentNativeSystemNotification(
    TelegramNotificationItem item,
  ) async {
    if (kIsWeb) return;
    final headerTitle = item.count > 1
        ? '${item.accountName} · ${item.count} 条新消息'
        : item.accountName;

    if (Platform.isLinux) {
      try {
        await Process.run('notify-send', [
          '--app-name=流光视频',
          '--icon=telegram',
          '$headerTitle · ${item.title}',
          item.preview,
        ]);
      } catch (_) {}
      return;
    }

    if (Platform.isWindows) {
      try {
        final safeTitle =
            '$headerTitle · ${item.title}'.replaceAll("'", "''");
        final safeBody = item.preview.replaceAll("'", "''");
        final psScript = '''
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
\$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
\$xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$safeTitle</text><text>$safeBody</text></binding></visual></toast>")
\$toast = [Windows.UI.Notifications.ToastNotification]::new(\$xml)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('流光视频').Show(\$toast)
''';
        await Process.run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          psScript,
        ]);
      } catch (_) {}
      return;
    }

    try {
      await _channel.invokeMethod('showNotification', {
        'key': item.key,
        'title': item.title,
        'subtitle': headerTitle,
        'body': item.preview,
        'accountId': item.accountId,
        'peer': item.peer,
        'messageId': item.message.id,
        'playSound': _soundEnabled,
      });
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
    stop();
    _eventController.close();
    super.dispose();
  }
}
