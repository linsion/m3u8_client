import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:m3u8_client/main.dart';
import 'package:m3u8_client/models/models.dart';
import 'package:m3u8_client/services/api_client.dart';
import 'package:m3u8_client/services/m3u8_ad_remover.dart';
import 'package:m3u8_client/services/peer_mesh_service.dart';
import 'package:m3u8_client/services/proxy_routing_service.dart';
import 'package:m3u8_client/services/smb_client_service.dart';
import 'package:m3u8_client/services/telegram_notification_service.dart';
import 'package:m3u8_client/services/tv_platform_service.dart';
import 'package:m3u8_client/state/app_state.dart';
import 'package:m3u8_client/ui/screens/downloads_screen.dart';
import 'package:m3u8_client/ui/screens/library_history_screen.dart';
import 'package:m3u8_client/ui/screens/peer_mesh_screen.dart';
import 'package:m3u8_client/ui/screens/proxy_server_screen.dart';
import 'package:m3u8_client/ui/screens/telegram_screen.dart';
import 'package:m3u8_client/ui/theme.dart';
import 'package:m3u8_client/ui/widgets/mobile_edge_swipe_back.dart';
import 'package:m3u8_client/ui/widgets/source_picker_sheet.dart';
import 'package:m3u8_client/ui/widgets/video_115_accelerate_button.dart';
import 'package:m3u8_client/ui/widgets/video_download_speed_badge.dart';
import 'package:m3u8_client/ui/widgets/video_proxy_node_selector.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

class _FakeTelegramApiClient extends ApiClient {
  _FakeTelegramApiClient({Completer<void>? sendCompleter})
      : sendCompleter = sendCompleter ?? (Completer<void>()..complete()),
        super(const ServerConfig());

  final Completer<void> sendCompleter;
  bool sendCompleted = false;

  List<TelegramChat> serverChats = [
    const TelegramChat(
      peer: 'user:1001',
      title: '测试好友',
      kind: '私聊',
      preview: '你好',
      date: 1700000000,
      unread: 0,
      readOnly: false,
      topMessageId: 101,
    ),
    const TelegramChat(
      peer: 'user:1002',
      title: '群组伙伴',
      kind: '私聊',
      preview: '早安',
      date: 1699999000,
      unread: 0,
      readOnly: false,
      topMessageId: 201,
    ),
  ];

  final Map<String, List<TelegramMessage>> serverMessagesByPeer = {
    'user:1001': [
      const TelegramMessage(
        id: 101,
        date: 1700000000,
        sender: '测试好友',
        text: '附带测试文件',
        outgoing: false,
        attachment: TelegramAttachment(
          kind: 'file',
          fileName: 'report_2026.pdf',
          size: 2048,
          mimeType: 'application/pdf',
          url: 'https://example.test/api/telegram/file?id=101',
        ),
      ),
    ],
    'user:1002': [
      const TelegramMessage(
        id: 201,
        date: 1699999000,
        sender: '群组伙伴',
        text: '早安',
        outgoing: false,
      ),
    ],
  };

  @override
  Future<({String activeId, List<TelegramAccount> accounts})>
      fetchTelegramAccounts() async {
    return (
      activeId: 'default',
      accounts: const [
        TelegramAccount(id: 'default', name: '测试账号', username: 'tester'),
      ],
    );
  }

  @override
  Future<TelegramAuthStatus> fetchTelegramStatus([String? accountId]) async {
    return const TelegramAuthStatus(configured: true, authorized: true);
  }

  @override
  Future<List<TelegramFolder>> fetchTelegramFolders([String? accountId]) async {
    return const [TelegramFolder(key: '0', title: '全部会话')];
  }

  @override
  Future<({List<TelegramChat> chats, String nextCursor})> fetchTelegramChats({
    required String accountId,
    String folder = '0',
    String cursor = '',
    int limit = 50,
  }) async {
    return (
      chats: List<TelegramChat>.from(serverChats),
      nextCursor: '',
    );
  }

  int lastFetchOffsetId = 0;
  bool lastFetchMarkRead = false;
  void Function(int percent, String statusText)? activeUploadProgressCallback;
  String lastResolvedLinkUrl = '';
  bool throwOnResolveLink = false;
  String lastSentText = '';
  String lastSentPeer = '';
  int downloadTelegramBytesCount = 0;
  final Map<int, TelegramFilePreview> filePreviewsByMsgId = {};
  final Map<int, Uint8List> rawFileBytesByMsgId = {};

  @override
  Future<TelegramFilePreview> fetchTelegramFilePreview({
    required String accountId,
    required String peer,
    required int messageId,
    String? entry,
  }) async {
    final p = filePreviewsByMsgId[messageId];
    if (p != null) return p;
    throw const ApiException('服务端未内置该格式预览，由客户端解析');
  }

  @override
  Future<Uint8List> downloadTelegramBytes(String url) async {
    downloadTelegramBytesCount++;
    final uri = Uri.tryParse(url);
    final msgId = int.tryParse(uri?.queryParameters['message_id'] ?? '') ?? 0;
    final customBytes = rawFileBytesByMsgId[msgId];
    if (customBytes != null) return customBytes;
    return Uint8List.fromList([0x25, 0x50, 0x44, 0x46]);
  }

  @override
  Future<({List<TelegramMessage> messages, int nextOffset})>
      fetchTelegramMessages({
    required String accountId,
    required String peer,
    int offsetId = 0,
    int limit = 50,
    bool markRead = false,
  }) async {
    lastFetchOffsetId = offsetId;
    lastFetchMarkRead = markRead;
    final all = List<TelegramMessage>.from(
      serverMessagesByPeer[peer] ?? const <TelegramMessage>[],
    );
    if (offsetId > 0) {
      final filtered = all.where((m) => m.id < offsetId).toList();
      final tail = filtered.length > limit
          ? filtered.sublist(filtered.length - limit)
          : filtered;
      return (
        messages: tail,
        nextOffset: tail.isNotEmpty && tail.first.id > 1 ? tail.first.id : 0,
      );
    }
    final tail =
        all.length > limit ? all.sublist(all.length - limit) : all;
    return (
      messages: tail,
      nextOffset: all.length > limit ? tail.first.id : 0,
    );
  }

  @override
  Future<List<TelegramMessage>> sendTelegramFiles({
    required String accountId,
    required String peer,
    required List<TelegramOutgoingFile> files,
    String text = '',
    int replyTo = 0,
    bool asFile = false,
    void Function(int percent, String statusText)? onProgress,
  }) async {
    activeUploadProgressCallback = onProgress;
    onProgress?.call(28, '正在上传 ${files.first.name} (2.8 MB / 10.0 MB · 5.6 MB/s)...');
    await sendCompleter.future;
    onProgress?.call(100, '发送完成');
    sendCompleted = true;
    return [
      TelegramMessage(
        id: 305,
        date: 1700000090,
        sender: '我',
        text: text,
        outgoing: true,
        replyToId: replyTo,
        attachment: TelegramAttachment(
          kind: 'file',
          name: files.first.name,
          fileName: files.first.name,
          size: files.first.size,
          mimeType: files.first.mimeType,
        ),
      ),
    ];
  }

  @override
  Future<
      ({
        TelegramChat chat,
        List<TelegramMessage> messages,
        int nextOffset,
        int messageId,
      })> resolveTelegramLink({
    required String accountId,
    required String url,
  }) async {
    lastResolvedLinkUrl = url;
    if (throwOnResolveLink) {
      throw Exception('当前账号尚未加入该私有频道');
    }
    final chat = serverChats.first;
    final msgs = serverMessagesByPeer[chat.peer] ?? const <TelegramMessage>[];
    return (
      chat: chat,
      messages: msgs,
      nextOffset: 0,
      messageId: msgs.isNotEmpty ? msgs.first.id : 0,
    );
  }

  int nextSentMessageId = 102;
  final List<int> deletedMessageIds = [];

  @override
  Future<void> deleteTelegramMessages({
    required String accountId,
    required String peer,
    required List<int> messageIds,
    bool revoke = true,
  }) async {
    deletedMessageIds.addAll(messageIds);
    final list = serverMessagesByPeer[peer];
    if (list != null) {
      list.removeWhere((m) => messageIds.contains(m.id));
    }
  }

  @override
  Future<TelegramMessage?> sendTelegramTextMessage({
    required String accountId,
    required String peer,
    required String text,
    int replyTo = 0,
  }) async {
    lastSentPeer = peer;
    lastSentText = text;
    await sendCompleter.future;
    sendCompleted = true;
    final id = nextSentMessageId++;
    final msg = TelegramMessage(
      id: id,
      date: 1700000050 + id,
      sender: '我',
      text: text,
      outgoing: true,
      replyToId: replyTo,
    );
    serverMessagesByPeer.putIfAbsent(peer, () => []).add(msg);
    return msg;
  }

  @override
  Future<void> markTelegramChatRead({
    required String accountId,
    required String peer,
    int maxId = 0,
  }) async {}

  @override
  Future<void> sendTelegramTyping({
    required String accountId,
    required String peer,
    required bool active,
  }) async {}

  @override
  Future<bool> verifyConnection() async => true;

  @override
  Future<List<VodSource>> fetchAllVodSources() async => const [];

  @override
  Future<({List<LibraryItem> favorites, List<LibraryItem> history})>
      fetchLibrary() async => (
            favorites: const <LibraryItem>[],
            history: const <LibraryItem>[],
          );

  @override
  Future<List<DownloadTask>> fetchDownloadTasks() async => const [];

  int created115TasksCount = 0;

  @override
  Future<String?> createDownloadTask({
    required String url,
    required String name,
    Map<String, String>? headers,
    String? telegramAccountId,
    Map<String, dynamic>? videoContext,
    bool forceDuplicate = false,
  }) async {
    created115TasksCount++;
    return 'task_115_$created115TasksCount';
  }

  @override
  Future<void> uploadTaskTo115(String id) async {}

  @override
  Future<ServerSettings> fetchServerSettings() async => const ServerSettings({});

  @override
  Future<({List<ProxyServiceConfig> services, List<ProxyRuntimeStatus> statuses})>
      fetchProxyConfig() async => (
            services: const <ProxyServiceConfig>[],
            statuses: const <ProxyRuntimeStatus>[],
          );

  @override
  Future<Map<String, dynamic>> fetch115Status() async => const {'logged_in': false};
}

class _PlaybackIndicatorPlayer extends PlatformPlayer {
  _PlaybackIndicatorPlayer() : super(configuration: const PlayerConfiguration());

  void showPosition(Media media, Duration position, {bool buffering = false}) {
    state = state.copyWith(
      playlist: Playlist([media]),
      position: position,
      buffering: buffering,
    );
    positionController.add(position);
  }
}

void main() {
  testWidgets('115 playback turns green only after its media starts', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final platform = _PlaybackIndicatorPlayer();
    final player = Player(platformPlayer: platform);
    final focus = FocusNode();
    final api = ApiClient(const ServerConfig());
    final normal = Media('https://example.test/original.mp4');
    final accelerated = Media(
      'http://127.0.0.1:41415/115_stream.mp4',
      start: const Duration(seconds: 12),
    );
    Future<void> showButton(String? url) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Video115AccelerateButton(
            api: api,
            player: player,
            selected115Url: url,
            focusNode: focus,
            downloadUrlBuilder: () => normal.uri,
            videoNameBuilder: () => 'Video',
            onResolved: (_) {},
          ),
        ),
      ),
    );
    final status = find.text('115 播放中');

    platform.showPosition(normal, const Duration(seconds: 12));
    await showButton(accelerated.uri);
    expect(status, findsNothing);
    platform.showPosition(accelerated, const Duration(seconds: 12), buffering: true);
    await tester.pump();
    expect(status, findsNothing);
    platform.showPosition(accelerated, const Duration(milliseconds: 12300));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(status).style?.color, const Color(0xFF6EE7B7));

    focus.requestFocus();
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(status).style?.color, const Color(0xFF6EE7B7));
    await showButton(null);
    expect(status, findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    focus.dispose();
    await player.dispose();
  });

  test('VodDetail.parsePlayGroups parses multi-line CMS play urls accurately', () {
    final groups = VodDetail.parsePlayGroups(
      r'hnzym3u8$$$hnm3u8',
      r'第01集$https://example.com/1.m3u8#第02集$https://example.com/2.m3u8$$$第01集$https://example.com/b1.m3u8',
    );
    expect(groups.length, 2);
    expect(groups.first.name, 'hnzym3u8');
    expect(groups.first.episodes.length, 2);
    expect(groups.first.episodes.first.title, '第01集');
    expect(groups.first.episodes.first.rawUrl, 'https://example.com/1.m3u8');
  });

  test('ApiClient.parseLivePlaylistText parses M3U and TVBox TXT playlists', () {
    final api = ApiClient(const ServerConfig());
    const m3u = '''
#EXTM3U
#EXTINF:-1 tvg-name="CCTV1" group-title="央视频道",CCTV-1综合
http://example.com/cctv1_a.m3u8
#EXTINF:-1 tvg-name="CCTV1" group-title="央视频道",CCTV-1综合
http://example.com/cctv1_b.m3u8
#EXTINF:-1 group-title="一起看",周星星
https://live.ottiptv.cc/huya/11342412
''';
    final channels = api.parseLivePlaylistText(
      m3u,
      defaultHeaders: const {'User-Agent': 'okHttp/Mod-1.5.0.0'},
    );
    expect(channels.length, 2);
    expect(channels.first.name, 'CCTV-1综合');
    expect(channels.first.group, '央视频道');
    expect(channels.first.urls.length, 2);
    expect(channels.last.headers['User-Agent'], 'okHttp/Mod-1.5.0.0');

    const txt = '''
卫视频道,#genre#
湖南卫视,http://example.com/hn1.m3u8#http://[2409:8087:7000:20:1000::22]:6060/yinhe/2/ch00000090990000001155/index.m3u8?\$IPV6
''';
    final txtChannels = api.parseLivePlaylistText(txt);
    expect(txtChannels.length, 1);
    expect(txtChannels.first.group, '卫视频道');
    expect(txtChannels.first.name, '湖南卫视');
    expect(txtChannels.first.urls.length, 2);
    expect(
      txtChannels.first.urls.last,
      'http://[2409:8087:7000:20:1000::22]:6060/yinhe/2/ch00000090990000001155/index.m3u8',
    );
  });

  testWidgets('MainShell requires password login when unauthenticated',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final appState = AppState();
    await tester.pumpWidget(M3u8VideoClientApp(appState: appState));
    expect(find.text('登录进入'), findsOneWidget);
  });

  test('AppState.initialize restores saved password without re-prompting',
      () async {
    SharedPreferences.setMockInitialValues({
      'm3u8_server_config_v1': jsonEncode(
        const ServerConfig(
          baseUrl: 'https://jp2.linsionwinwin.top:8081',
          authMode: AuthMode.password,
          secret: 'saved_pwd_123',
        ).toJson(),
      ),
    });
    final appState = AppState();
    await appState.initialize();
    expect(appState.isAuthenticated, isTrue);
    expect(appState.serverConfig.secret, 'saved_pwd_123');
    appState.dispose();
  });

  test('ApiClient.resolveVodPlayback resolves direct m3u8 URLs locally in 0ms',
      () async {
    final api = ApiClient(const ServerConfig(preferDirectPlayback: true));
    const src = VodSource(
      id: 'cms_0',
      name: '测试源',
      api: 'https://example.com/api.php/provide/vod/',
    );
    final resolved = await api.resolveVodPlayback(
      src,
      playGroup: 'm3u8',
      episodeUrl: 'https://cdn.example.com/2026/index.m3u8',
    );
    expect(resolved.directUrl, 'https://cdn.example.com/2026/index.m3u8');
    expect(resolved.backendProxyPlayback, isFalse);
  });

  test('AppState.setThemeId updates VideoPlatformTheme palette and persists',
      () async {
    SharedPreferences.setMockInitialValues({});
    final appState = AppState();
    await appState.initialize();
    expect(appState.themeId, 'ocean_dark');

    await appState.setThemeId('cinema_red');
    expect(appState.themeId, 'cinema_red');
    expect(VideoPlatformTheme.currentPalette.id, 'cinema_red');

    await appState.setThemeId('daylight_clean');
    expect(VideoPlatformTheme.isDark, isFalse);
    appState.dispose();
  });

  test('M3u8AdRemover.stripAdsFromMediaPlaylist strips discontinuity ad blocks',
      () {
    const sampleM3u8 = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
0001.ts
#EXTINF:10.0,
0002.ts
#EXTINF:10.0,
0003.ts
#EXTINF:10.0,
0004.ts
#EXTINF:10.0,
0005.ts
#EXTINF:10.0,
0006.ts
#EXTINF:10.0,
0007.ts
#EXTINF:10.0,
0008.ts
#EXTINF:10.0,
0009.ts
#EXTINF:10.0,
0010.ts
#EXT-X-DISCONTINUITY
#EXTINF:5.0,
https://ad-cdn.example.org/promo/ad01.ts
#EXTINF:5.0,
https://ad-cdn.example.org/promo/ad02.ts
#EXTINF:5.0,
https://ad-cdn.example.org/promo/ad03.ts
#EXT-X-DISCONTINUITY
#EXTINF:10.0,
0011.ts
#EXTINF:10.0,
0012.ts
#EXT-X-ENDLIST
''';
    final res = M3u8AdRemover.stripAdsFromMediaPlaylist(
      sampleM3u8,
      baseUri: Uri.parse('https://vod.example.com/2026/ep1/index.m3u8'),
    );
    expect(res.removedSegments, 3);
    expect(res.removedSeconds, 15.0);
    expect(res.cleanedM3u8.contains('ad-cdn.example.org'), isFalse);
    expect(
      res.cleanedM3u8.contains('https://vod.example.com/2026/ep1/0001.ts'),
      isTrue,
    );
    expect(
      res.cleanedM3u8.contains('https://vod.example.com/2026/ep1/0012.ts'),
      isTrue,
    );
  });

  testWidgets('TerminalView cursor coordinates match active input row and column',
      (WidgetTester tester) async {
    final terminal = Terminal(maxLines: 1000);
    final viewKey = GlobalKey<TerminalViewState>();
    terminal.write('流光交互式系统终端\r\n');
    terminal.write('第二行说明文字\r\n');
    terminal.write('[root@instance data]# ls -la');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 400,
            child: TerminalView(
              terminal,
              key: viewKey,
              cursorType: TerminalCursorType.verticalBar,
              alwaysShowCursor: true,
              textScaler: TextScaler.noScaling,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final state = viewKey.currentState!;
    final rect = state.cursorRect;
    final cell = state.renderTerminal.cellSize;
    expect(terminal.buffer.cursorY, 2);
    expect(terminal.buffer.cursorX, 28);
    expect(rect.left, closeTo(28 * cell.width, 0.5));
    expect(rect.top, closeTo((2 * cell.height).truncateToDouble(), 1.0));
  });

  test('AppState.clearLibraryKind clears history and progress across restarts',
      () async {
    SharedPreferences.setMockInitialValues({});
    final state1 = AppState();
    await state1.initialize();

    const src = VodSource(
      id: 'custom_0',
      name: '测试源',
      api: 'https://example.com/api.php/provide/vod/',
      isTvBox: false,
      customIndex: 0,
    );
    const detail = VodDetail(vodId: '1001', vodName: '测试影片');

    await state1.recordWatchHistory(
      source: src,
      detail: detail,
      episodeTitle: '第1集',
      lineName: 'm3u8',
      positionSeconds: 120,
      durationSeconds: 1200,
    );
    await state1.saveVodProgress(
      sourceKey: src.id,
      vodId: detail.vodId,
      groupIndex: 0,
      episodeIndex: 0,
      episodeName: '第1集',
      positionSeconds: 120,
      durationSeconds: 1200,
    );
    expect(state1.history.length, 1);
    expect(state1.getVodProgress(src.id, detail.vodId), isNotNull);

    await state1.clearLibraryKind('history');
    expect(state1.history, isEmpty);
    expect(state1.getVodProgress(src.id, detail.vodId), isNull);

    // Simulate app restart
    final state2 = AppState();
    await state2.initialize();
    expect(state2.history, isEmpty);
    expect(state2.getVodProgress(src.id, detail.vodId), isNull);
  });

  test('TelegramChat, TelegramAccount, and TelegramMessage parse and preserve avatar and HD photo info',
      () {
    const sampleDataUri = 'data:image/jpeg;base64,/9j/4AAQSkZJRg==';
    final chat = TelegramChat.fromJson({
      'peer': 'channel:2616447968',
      'title': '节点通告',
      'kind': '频道',
      'avatar': sampleDataUri,
      'avatar_photo_id': '6260266222834357099',
      'avatar_dc_id': 5,
      'unread': 3,
    });
    expect(chat.avatar, sampleDataUri);
    expect(chat.avatarPhotoId, '6260266222834357099');
    expect(chat.avatarDcId, 5);
    expect(chat.hasSharpAvatar, isTrue);

    final updated = chat.copyWith(unread: 0);
    expect(updated.avatar, sampleDataUri);
    expect(updated.avatarPhotoId, '6260266222834357099');
    expect(updated.avatarDcId, 5);
    expect(updated.hasSharpAvatar, isTrue);
    expect(updated.unread, 0);

    final client = ApiClient(
      const ServerConfig(baseUrl: 'https://jp2.linsionwinwin.top:8081'),
    );
    final hdUrl = client.buildTelegramAvatarUrl(
      accountId: 'default',
      peer: chat.peer,
      photoId: chat.avatarPhotoId,
      dcId: chat.avatarDcId,
    );
    expect(
      hdUrl,
      'https://jp2.linsionwinwin.top:8081/api/telegram/avatar?account_id=default&peer=channel%3A2616447968&photo_id=6260266222834357099&dc_id=5',
    );

    final account = TelegramAccount.fromJson({
      'id': 'default',
      'name': 'Fly',
      'user_id': 8327940121,
      'avatar': sampleDataUri,
    });
    expect(account.avatar, sampleDataUri);

    final msg = TelegramMessage.fromJson({
      'id': 42,
      'sender': 'Telegram',
      'sender_avatar': sampleDataUri,
      'text': 'Hello',
      'silent': true,
    });
    expect(msg.senderAvatar, sampleDataUri);
    expect(msg.silent, isTrue);
  });

  test('TelegramNotificationService notifies unmuted messages and suppresses muted or silent ones',
      () async {
    SharedPreferences.setMockInitialValues({});
    final api = ApiClient(
      const ServerConfig(baseUrl: 'https://jp2.linsionwinwin.top:8081'),
    );
    String activeReadingPeer = '';
    final service = TelegramNotificationService(
      apiProvider: () => api,
      isReadingPeer: (accId, peer) =>
          accId == 'default' && peer == activeReadingPeer,
      resolveChatTitle: (accId, peer) => peer == 'channel:1001' ? '影视更新频道' : '',
      onOpenNotification: (_, __, ___) {},
    );
    await service.setSystemNotificationsEnabled(false);

    const acc = TelegramAccount(
      id: 'default',
      name: '主账号',
      userId: '888888',
    );
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // 1. Normal unmuted incoming message -> should notify
    service.handleNotificationEventForTest(
      acc,
      TelegramNotificationEvent.fromJson({
        'account_id': 'default',
        'peer': 'channel:1001',
        'new_message': true,
        'notification_muted': false,
        'message': {
          'id': 101,
          'date': nowSec,
          'sender': '小编',
          'text': '4K 新片已发布',
          'outgoing': false,
          'silent': false,
        },
      }),
    );
    expect(service.totalUnreadNotificationCount, 1);
    expect(service.pendingNotifications.first.title, '影视更新频道');
    expect(service.pendingNotifications.first.preview, '小编：4K 新片已发布');

    // 2. Silent message (`silent: true`) -> must NOT notify or increment count
    service.handleNotificationEventForTest(
      acc,
      TelegramNotificationEvent.fromJson({
        'account_id': 'default',
        'peer': 'channel:2002',
        'chat_title': '静默推送群',
        'new_message': true,
        'notification_muted': false,
        'message': {
          'id': 202,
          'date': nowSec,
          'sender': 'Bot',
          'text': '这条是静默消息',
          'outgoing': false,
          'silent': true,
        },
      }),
    );
    expect(service.totalUnreadNotificationCount, 1);
    expect(
      service.pendingNotifications.any((n) => n.peer == 'channel:2002'),
      isFalse,
    );

    // 3. Muted chat (`notification_muted: true`) -> must NOT notify and must dismiss existing pending for that peer
    service.handleNotificationEventForTest(
      acc,
      TelegramNotificationEvent.fromJson({
        'account_id': 'default',
        'peer': 'channel:3003',
        'chat_title': '已静音大群',
        'new_message': true,
        'notification_muted': true,
        'message': {
          'id': 303,
          'date': nowSec,
          'sender': 'UserA',
          'text': '静音群消息不应提醒',
          'outgoing': false,
          'silent': false,
        },
      }),
    );
    expect(
      service.pendingNotifications.any((n) => n.peer == 'channel:3003'),
      isFalse,
    );

    // 4. Local mute toggle on channel:1001 -> dismisses existing and blocks future notifications
    await service.toggleLocalPeerMute('default', 'channel:1001');
    expect(service.totalUnreadNotificationCount, 0);
    service.handleNotificationEventForTest(
      acc,
      TelegramNotificationEvent.fromJson({
        'account_id': 'default',
        'peer': 'channel:1001',
        'new_message': true,
        'notification_muted': false,
        'message': {
          'id': 102,
          'date': nowSec,
          'sender': '小编',
          'text': '第二条消息',
          'outgoing': false,
          'silent': false,
        },
      }),
    );
    expect(service.totalUnreadNotificationCount, 0);

    // 5. Currently reading peer -> does not notify
    activeReadingPeer = 'user:5005';
    service.handleNotificationEventForTest(
      acc,
      TelegramNotificationEvent.fromJson({
        'account_id': 'default',
        'peer': 'user:5005',
        'chat_title': 'Alice',
        'new_message': true,
        'notification_muted': false,
        'message': {
          'id': 501,
          'date': nowSec,
          'sender': 'Alice',
          'text': '正在阅读中的会话不弹窗',
          'outgoing': false,
          'silent': false,
        },
      }),
    );
    expect(service.totalUnreadNotificationCount, 0);
    service.dispose();
  });

  test('ProxySubscriptionParser parses Base64, Clash YAML, and URI subscriptions',
      () {
    final ssUser = base64Url.encode(utf8.encode('aes-256-gcm:pass123')).replaceAll('=', '');
    final vmessJson = base64Encode(
      utf8.encode(
        jsonEncode({
          'v': '2',
          'ps': '日本 IPLC 01',
          'add': 'jp1.liangxin.xyz',
          'port': '443',
          'id': '11111111-2222-3333-4444-555555555555',
          'net': 'ws',
          'tls': 'tls',
          'sni': 'jp1.liangxin.xyz',
        }),
      ),
    );
    final rawUriList = [
      'ss://$ssUser@hk1.liangxin.xyz:8388#%E9%A6%99%E6%B8%AF%20BGP%2001',
      'trojan://secretpass@sg1.liangxin.xyz:443?sni=sg1.liangxin.xyz&allowInsecure=1#%E6%96%B0%E5%8A%A0%E5%9D%A1%2001',
      'vmess://$vmessJson',
      'socks5://user:pwd@127.0.0.1:1080#%E6%9C%AC%E5%9C%B0SOCKS5',
    ].join('\n');

    final b64Payload = base64Encode(utf8.encode(rawUriList));
    final parsedFromB64 = ProxySubscriptionParser.parseSubscriptionContent(
      b64Payload,
      subscriptionId: 'sub_liangxin_default',
    );
    expect(parsedFromB64.length, 4);
    expect(parsedFromB64[0].protocol, 'ss');
    expect(parsedFromB64[0].name, '香港 BGP 01');
    expect(parsedFromB64[0].regionFlag, '🇭🇰');
    expect(parsedFromB64[1].protocol, 'trojan');
    expect(parsedFromB64[1].regionFlag, '🇸🇬');
    expect(parsedFromB64[2].protocol, 'vmess');
    expect(parsedFromB64[2].regionFlag, '🇯🇵');
    expect(parsedFromB64[3].protocol, 'socks5');

    const clashYaml = '''
proxies:
  - { name: "🇭🇰 香港 IEPL 01", type: ss, server: hk.liangxin.xyz, port: 8388, cipher: aes-256-gcm, password: " secret " }
  - name: "🇺🇸 美国 GIA 02"
    type: trojan
    server: us.liangxin.xyz
    port: 443
    password: "trojan_password"
    sni: us.liangxin.xyz
''';
    final parsedFromClash = ProxySubscriptionParser.parseSubscriptionContent(
      clashYaml,
      subscriptionId: 'sub_liangxin_default',
    );
    expect(parsedFromClash.length, 2);
    expect(parsedFromClash[0].protocol, 'ss');
    expect(parsedFromClash[0].server, 'hk.liangxin.xyz');
    expect(parsedFromClash[1].protocol, 'trojan');
    expect(parsedFromClash[1].server, 'us.liangxin.xyz');

    final userInfo = ProxySubscriptionParser.parseUserInfoHeader({
      'Subscription-Userinfo':
          'upload=1073741824; download=4294967296; total=107374182400; expire=1893456000',
    });
    expect(userInfo.upload, 1073741824);
    expect(userInfo.download, 4294967296);
    expect(userInfo.total, 107374182400);
    expect(userInfo.expire, 1893456000);
  });

  test('ProxyRoutingService supports enable toggle, liangxin subscription, manual vs autoFastest, and scenario routing',
      () async {
    SharedPreferences.setMockInitialValues({});
    final proxySvc = ProxyRoutingService();
    await proxySvc.initialize();

    // 1. Default liangxin.xyz subscription is pre-configured
    expect(proxySvc.subscriptions, isNotEmpty);
    expect(
      proxySvc.subscriptions.first.url,
      kDefaultLiangxinSubscriptionUrl,
    );
    expect(proxySvc.proxyEnabled, isFalse);

    // 2. Import 3 nodes with different latencies
    await proxySvc.upsertManualNode(
      const ProxyNode(
        id: 'node_hk_slow',
        name: '香港节点 A',
        protocol: 'http',
        server: '10.0.0.1',
        port: 8080,
        latencyMs: 260,
      ),
      testLatency: false,
    );
    await proxySvc.upsertManualNode(
      const ProxyNode(
        id: 'node_jp_fast',
        name: '日本节点 B',
        protocol: 'http',
        server: '10.0.0.2',
        port: 8080,
        latencyMs: 38,
      ),
      testLatency: false,
    );
    await proxySvc.upsertManualNode(
      const ProxyNode(
        id: 'node_sg_mid',
        name: '新加坡节点 C',
        protocol: 'http',
        server: '10.0.0.3',
        port: 8080,
        latencyMs: 95,
      ),
      testLatency: false,
    );

    // 3. In autoFastest mode, fastestNode and activeNode automatically resolve to 38ms Japan node
    await proxySvc.setSelectionMode(ProxySelectionMode.autoFastest);
    expect(proxySvc.fastestNode?.id, 'node_jp_fast');
    expect(proxySvc.activeNode?.id, 'node_jp_fast');

    // 4. Switch to manual mode and lock Singapore node
    await proxySvc.selectNode('node_sg_mid', switchToManual: true);
    expect(proxySvc.selectionMode, ProxySelectionMode.manual);
    expect(proxySvc.activeNode?.id, 'node_sg_mid');

    // 5. When proxyEnabled is false, followGlobal scenarios route via direct
    expect(
      proxySvc.resolveEffectiveRoute(RequestScenario.vodApi),
      ScenarioRouteMode.direct,
    );

    // 6. Enable proxy master switch -> followGlobal scenarios now route via proxyNode
    await proxySvc.setProxyEnabled(true);
    expect(proxySvc.proxyEnabled, isTrue);
    expect(
      proxySvc.resolveEffectiveRoute(RequestScenario.vodApi),
      ScenarioRouteMode.proxyNode,
    );
    expect(
      proxySvc.resolveFindProxyDirective(
        RequestScenario.vodApi,
        Uri.parse('https://cms.example.com/api.php/provide/vod/'),
      ),
      'PROXY 10.0.0.3:8080; DIRECT',
    );

    // 7. Scenario-specific routing rules & dedicated node per scenario
    await proxySvc.updateScenarioRule(
      RequestScenario.liveStream,
      mode: ScenarioRouteMode.direct,
    );
    await proxySvc.updateScenarioRule(
      RequestScenario.telegram,
      mode: ScenarioRouteMode.proxyNode,
      specificNodeId: 'node_jp_fast',
    );
    await proxySvc.updateScenarioRule(
      RequestScenario.vodStream,
      mode: ScenarioRouteMode.smartAuto,
    );

    expect(
      proxySvc.resolveEffectiveRoute(RequestScenario.liveStream),
      ScenarioRouteMode.direct,
    );
    expect(
      proxySvc.resolveNodeForScenario(RequestScenario.telegram)?.id,
      'node_jp_fast',
    );
    // Smart mode: domestic .cn bypasses proxy, overseas domain uses proxy
    expect(
      proxySvc.resolveEffectiveRoute(
        RequestScenario.vodStream,
        targetUri: Uri.parse('https://cdn.qq.com/stream.m3u8'),
      ),
      ScenarioRouteMode.direct,
    );
    expect(
      proxySvc.resolveEffectiveRoute(
        RequestScenario.vodStream,
        targetUri: Uri.parse('https://raw.githubusercontent.com/demo/live.m3u8'),
      ),
      ScenarioRouteMode.proxyNode,
    );

    proxySvc.dispose();
  });

  testWidgets('ProxyServerScreen renders subscriptions and saves subscription dialog cleanly',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final appState = AppState();
    await appState.proxyService.initialize();
    await appState.setThemeId('daylight_clean');

    await tester.pumpWidget(
      MaterialApp(
        theme: VideoPlatformTheme.buildTheme(),
        home: Scaffold(
          body: ProxyServerScreen(appState: appState),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('代理订阅源管理'), findsOneWidget);
    expect(find.text('1 个订阅'), findsOneWidget);
    expect(find.textContaining('良心云'), findsWidgets);

    // Open 新增订阅链接 dialog, focus & enter a 2nd subscription URL, and save
    await tester.tap(find.text('新增订阅链接'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final textFields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.tap(textFields.at(0));
    await tester.pump();
    await tester.enterText(textFields.at(0), '备用机场订阅');
    await tester.tap(textFields.at(1));
    await tester.pump();
    await tester.enterText(textFields.at(1), 'https://example.com/sub2');
    await tester.pump();

    await tester.tap(find.text('保存并拉取订阅'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('2 个订阅'), findsOneWidget);
    expect(find.text('备用机场订阅'), findsOneWidget);
    expect(find.text('https://example.com/sub2'), findsOneWidget);

    // Simulate desktop mouse hover & click on the edit subscription icon button
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await tester.pump();

    final editBtn = find.byIcon(Icons.edit_outlined).first;
    await mouse.moveTo(tester.getCenter(editBtn));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(editBtn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final editSaveBtn = find.text('保存并拉取订阅');
    await mouse.moveTo(tester.getCenter(editSaveBtn));
    await tester.pump();
    await tester.tap(editSaveBtn);
    await tester.pump();
    await mouse.moveTo(const Offset(200, 200));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('2 个订阅'), findsOneWidget);
    expect(find.text('备用机场订阅'), findsOneWidget);

    await mouse.removePointer();
    appState.dispose();
  });

  test('ProxyNode filters info nodes and fastestNode ranks by real tunnel effectiveScore', () async {
    SharedPreferences.setMockInitialValues({});
    final svc = ProxyRoutingService();
    await svc.initialize();

    // Fake informational node with misleading 5ms ping must never be chosen
    await svc.upsertManualNode(
      const ProxyNode(
        id: 'node_info_fake',
        name: '剩余流量：888 GB',
        protocol: 'ss',
        server: '1.1.1.1',
        port: 443,
        latencyMs: 5,
        tcpPingMs: 5,
        speedKbps: 5000,
      ),
      testLatency: false,
    );

    // Relay node with low entry TCP ping (15ms) but congested outbound tunnel (850ms, 30 KB/s)
    await svc.upsertManualNode(
      const ProxyNode(
        id: 'node_congested_relay',
        name: '香港中转-拥塞节点',
        protocol: 'trojan',
        server: '2.2.2.2',
        port: 443,
        tcpPingMs: 15,
        latencyMs: 850,
        speedKbps: 30,
      ),
      testLatency: false,
    );

    // Fast real tunnel node (180ms tunnel TTFB, 2400 KB/s throughput)
    await svc.upsertManualNode(
      const ProxyNode(
        id: 'node_real_fast',
        name: '日本BGP-高速节点',
        protocol: 'ss',
        server: '3.3.3.3',
        port: 8388,
        tcpPingMs: 42,
        latencyMs: 180,
        speedKbps: 2400,
      ),
      testLatency: false,
    );

    await svc.setSelectionMode(ProxySelectionMode.autoFastest);
    expect(svc.nodes.firstWhere((n) => n.id == 'node_info_fake').isInfoNode, isTrue);
    expect(svc.fastestNode?.id, 'node_real_fast');
    expect(svc.activeNode?.id, 'node_real_fast');
    expect(svc.fastestNode?.speedLabel, '2.3 MB/s');

    svc.dispose();
  });

  test('Sticky autoFastest keeps current smooth node and only switches when lagging or stalled', () async {
    SharedPreferences.setMockInitialValues({});
    final svc = ProxyRoutingService();
    await svc.initialize();

    // Node A: currently smooth & healthy (120ms, 1500 KB/s)
    await svc.upsertManualNode(
      const ProxyNode(
        id: 'node_smooth_current',
        name: '新加坡-稳定节点A',
        protocol: 'ss',
        server: '10.10.0.1',
        port: 8388,
        tcpPingMs: 35,
        latencyMs: 120,
        speedKbps: 1500,
      ),
      testLatency: false,
    );

    await svc.setSelectionMode(ProxySelectionMode.autoFastest);
    // Lock onto node_smooth_current in autoFastest mode
    await svc.selectNode('node_smooth_current', switchToManual: false);
    expect(svc.selectionMode, ProxySelectionMode.autoFastest);
    expect(svc.activeNode?.id, 'node_smooth_current');

    // Node B arrives with an even faster score (45ms, 3800 KB/s)
    await svc.upsertManualNode(
      const ProxyNode(
        id: 'node_faster_candidate',
        name: '日本-超快节点B',
        protocol: 'ss',
        server: '10.10.0.2',
        port: 8388,
        tcpPingMs: 20,
        latencyMs: 45,
        speedKbps: 3800,
      ),
      testLatency: false,
    );

    // fastestNode is Node B, but activeNode MUST stay on Node A because Node A is smooth (not lagging)!
    expect(svc.fastestNode?.id, 'node_faster_candidate');
    expect(svc.activeNode?.id, 'node_smooth_current');

    // Now simulate playback lag / buffering on the current node -> immediately fails over to Node B!
    await svc.reportActiveNodeLag(reason: '视频缓冲卡顿');
    expect(svc.activeNode?.id, 'node_faster_candidate');

    svc.dispose();
  });

  test('LocalProxyTunnelBridge /__m3u8_proxy__ HLS stream relay resolves M3U8 and streams TS segments via pooled proxy client',
      () async {
    final prevHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevHttpOverrides);
    // 1. Start a mock origin HLS server
    final originServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final originPort = originServer.port;
    originServer.listen((HttpRequest req) async {
      if (req.uri.path == '/master.m3u8') {
        req.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
        req.response.write(
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000000\n/sub/index.m3u8\n',
        );
        await req.response.close();
      } else if (req.uri.path == '/sub/index.m3u8') {
        req.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
        req.response.write(
          '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\nseg001.ts\n#EXT-X-ENDLIST\n',
        );
        await req.response.close();
      } else if (req.uri.path == '/sub/seg001.ts') {
        req.response.headers.contentType = ContentType('video', 'mp2t');
        req.response.add(List<int>.filled(1024, 0x47));
        await req.response.close();
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    });

    // 2. Start a mock SOCKS5 proxy node that forwards to originServer
    final socksServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final activeSocksSockets = <Socket>[];
    socksServer.listen((Socket client) async {
      activeSocksSockets.add(client);
      final rx = <int>[];
      var stage = 0;
      Socket? upstream;
      client.listen(
        (chunk) async {
          try {
            if (stage == 2 && upstream != null) {
              upstream!.add(chunk);
              return;
            }
            rx.addAll(chunk);
            if (stage == 0 && rx.length >= 3) {
              rx.clear();
              stage = 1;
              client.add(const [0x05, 0x00]);
            } else if (stage == 1 && rx.length >= 7) {
              final hostLen = rx[4];
              if (rx.length >= 5 + hostLen + 2) {
                final host = utf8.decode(rx.sublist(5, 5 + hostLen));
                final port = (rx[5 + hostLen] << 8) | rx[5 + hostLen + 1];
                rx.removeRange(0, 5 + hostLen + 2);
                try {
                  upstream = await Socket.connect(host, port);
                  activeSocksSockets.add(upstream!);
                } catch (_) {
                  client.destroy();
                  return;
                }
                stage = 2;
                client.add(const [0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0, 0]);
                if (rx.isNotEmpty) {
                  upstream!.add(List<int>.from(rx));
                  rx.clear();
                }
                upstream!.listen(
                  (d) => client.add(d),
                  onDone: () => client.destroy(),
                  onError: (_) => client.destroy(),
                );
              }
            }
          } catch (_) {
            client.destroy();
          }
        },
        onError: (_) => client.destroy(),
      );
    });

    SharedPreferences.setMockInitialValues({});
    final svc = ProxyRoutingService();
    await svc.initialize();
    await svc.upsertManualNode(
      ProxyNode(
        id: 'node_local_socks',
        name: '本地测试SOCKS5',
        protocol: 'socks5',
        server: '127.0.0.1',
        port: socksServer.port,
        latencyMs: 1120, // > 950ms should still be considered healthy and locked!
        speedKbps: 500,
      ),
      testLatency: false,
    );
    await svc.setSelectionMode(ProxySelectionMode.autoFastest);
    await svc.setProxyEnabled(true);

    expect(svc.isNodeHealthyAndSmooth(svc.activeNode!), isTrue);
    expect(svc.selectedNodeId, 'node_local_socks');

    final masterUrl = 'http://127.0.0.1:$originPort/master.m3u8';
    final relayedUrl = await svc.resolveProxiedStreamUrl(
      RequestScenario.vodStream,
      masterUrl,
      headers: const {'Referer': 'https://vod.example.com/'},
      cleanM3u8Ads: true,
    );
    expect(relayedUrl, contains('/__m3u8_proxy__/playlist.m3u8'));

    // Fetch the relayed M3U8 playlist
    final hc = HttpClient();
    final m3u8Req = await hc.getUrl(Uri.parse(relayedUrl));
    final m3u8Resp = await m3u8Req.close();
    expect(m3u8Resp.statusCode, 200);
    final m3u8Text = await utf8.decoder.bind(m3u8Resp).join();
    expect(m3u8Text, contains('#EXTINF:4.0,'));
    expect(m3u8Text, contains('/__m3u8_proxy__/segment.ts'));

    // Extract the rewritten segment URL and fetch it through the relay
    final segLine = m3u8Text
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.startsWith('http://127.0.0.1:'));
    final segReq = await hc.getUrl(Uri.parse(segLine));
    final segResp = await segReq.close();
    expect(segResp.statusCode, 200);
    final segBytes =
        await segResp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    expect(segBytes.length, 1024);
    expect(segBytes.first, 0x47);

    hc.close(force: true);
    svc.dispose();
    for (final s in activeSocksSockets) {
      s.destroy();
    }
    await socksServer.close();
    await originServer.close(force: true);
  });

  test('TelegramMessage parses selection/inline buttons and TelegramChat tracks readOutboxMaxId for sent files',
      () {
    // 1. Parse message with 2D inline keyboard buttons (callback, url, text, unsupported)
    final msg = TelegramMessage.fromJson({
      'id': 801,
      'date': 1700000100,
      'sender': 'ResourceBot',
      'text': '请选择清晰度或打开链接：',
      'outgoing': false,
      'reply_to_id': 799,
      'text_links': [
        {'offset': 0, 'length': 5, 'url': 'https://t.me/example_channel/12'},
      ],
      'buttons': [
        [
          {'text': '🎬 4K HDR', 'kind': 'callback', 'token': 'cb_4k'},
          {'text': '📺 1080P', 'kind': 'callback', 'token': 'cb_1080p'},
        ],
        [
          {
            'text': '🔗 打开直链',
            'kind': 'url',
            'url': 'https://example.com/dl'
          },
          {'text': '下一页', 'kind': 'text', 'token': 'txt_next'},
          {'text': '支付按钮', 'kind': 'buy'},
        ],
      ],
    });

    expect(msg.id, 801);
    expect(msg.replyToId, 799);
    expect(msg.links, contains('https://t.me/example_channel/12'));
    expect(msg.hasButtons, isTrue);
    expect(msg.buttons.length, 2);
    expect(msg.buttons[0].length, 2);
    expect(msg.buttons[0][0].text, '🎬 4K HDR');
    expect(msg.buttons[0][0].kind, 'callback');
    expect(msg.buttons[0][0].token, 'cb_4k');
    expect(msg.buttons[0][0].isInteractive, isTrue);
    expect(msg.buttons[0][0].isSupported, isTrue);

    expect(msg.buttons[1][0].isUrl, isTrue);
    expect(msg.buttons[1][0].url, 'https://example.com/dl');
    expect(msg.buttons[1][1].kind, 'text');
    expect(msg.buttons[1][1].isInteractive, isTrue);
    expect(msg.buttons[1][2].isSupported, isFalse);

    // 2. Parse button callback action response with updated message
    final actionRes = TelegramButtonActionResult.fromJson({
      'notice': '已切换至 4K HDR 资源列表',
      'alert': true,
      'url': 'https://t.me/example_channel/99',
      'message': {
        'id': 801,
        'date': 1700000105,
        'sender': 'ResourceBot',
        'text': '已选择：🎬 4K HDR',
        'buttons': [
          [
            {'text': '✅ 4K HDR (当前)', 'kind': 'callback', 'token': 'cb_4k'},
          ],
        ],
      },
    });
    expect(actionRes.notice, '已切换至 4K HDR 资源列表');
    expect(actionRes.alert, isTrue);
    expect(actionRes.url, 'https://t.me/example_channel/99');
    expect(actionRes.message?.text, '已选择：🎬 4K HDR');
    expect(actionRes.message?.buttons.first.first.text, '✅ 4K HDR (当前)');

    // 3. Sent file message without text caption + read_outbox_max_id tracking
    final sentFileMsg = TelegramMessage.fromJson({
      'id': 950,
      'date': 1700000200,
      'text': '',
      'outgoing': true,
      'attachment': {
        'kind': 'file',
        'file_name': 'archive_2026.zip',
        'size': 10485760,
        'mime_type': 'application/zip',
      },
    });
    expect(sentFileMsg.outgoing, isTrue);
    expect(sentFileMsg.text, isEmpty);
    expect(sentFileMsg.attachment?.displayName, 'archive_2026.zip');

    // Before recipient reads (read_outbox_max_id = 900 < 950)
    final chatUnread = TelegramChat.fromJson({
      'peer': 'user:12345',
      'title': 'Alice',
      'read_outbox_max_id': 900,
    });
    expect(chatUnread.readOutboxMaxId, 900);
    expect(sentFileMsg.id <= chatUnread.readOutboxMaxId, isFalse);

    // After SSE read_outbox_max_id update (read_outbox_max_id = 950 >= 950)
    final sseEvent = TelegramNotificationEvent.fromJson({
      'account_id': 'default',
      'peer': 'user:12345',
      'read_outbox_max_id': 950,
    });
    expect(sseEvent.readOutboxMaxId, 950);
    final chatRead = chatUnread.copyWith(
      readOutboxMaxId: sseEvent.readOutboxMaxId,
    );
    expect(sentFileMsg.id <= chatRead.readOutboxMaxId, isTrue);
  });

  test('TelegramAttachment parses official music metadata vs voice messages and builds file-content URL', () {
    // 1. Music track with explicit ID3 title & performer
    final musicWithId3 = TelegramAttachment.fromJson({
      'kind': 'audio',
      'file_name': 'track01.mp3',
      'title': '夜曲',
      'performer': '周杰伦',
      'duration': 226,
      'size': 9437184,
      'mime_type': 'audio/mpeg',
      'has_thumbnail': true,
    });
    expect(musicWithId3.isAudio, isTrue);
    expect(musicWithId3.isMusic, isTrue);
    expect(musicWithId3.isVoiceMessage, isFalse);
    expect(musicWithId3.musicTitle, '夜曲');
    expect(musicWithId3.musicPerformer, '周杰伦');
    expect(musicWithId3.hasThumbnail, isTrue);

    // 2. Music file without ID3 tags but with "Artist - Title.flac" filename
    final musicFromFilename = TelegramAttachment.fromJson({
      'kind': 'file',
      'file_name': '陈奕迅 - 富士山下.flac',
      'duration': 259,
      'size': 28311552,
      'mime_type': 'audio/flac',
    });
    expect(musicFromFilename.isAudio, isTrue);
    expect(musicFromFilename.isMusic, isTrue);
    expect(musicFromFilename.isVoiceMessage, isFalse);
    expect(musicFromFilename.musicTitle, '富士山下');
    expect(musicFromFilename.musicPerformer, '陈奕迅');

    // 3. Telegram voice note (.ogg without title/performer)
    final voiceNote = TelegramAttachment.fromJson({
      'kind': 'audio',
      'file_name': 'audio_2026-11-14_13-20-00.ogg',
      'duration': 12,
      'size': 49152,
      'mime_type': 'audio/ogg',
    });
    expect(voiceNote.isAudio, isTrue);
    expect(voiceNote.isVoiceMessage, isTrue);
    expect(voiceNote.isMusic, isFalse);

    // 4. Streaming endpoint URL (/api/telegram/file-content)
    final client = ApiClient(
      const ServerConfig(baseUrl: 'https://jp2.linsionwinwin.top:8081'),
    );
    expect(
      client.buildTelegramFileContentUrl(
        accountId: 'default',
        peer: 'channel:10086',
        messageId: 512,
      ),
      'https://jp2.linsionwinwin.top:8081/api/telegram/file-content?account_id=default&peer=channel%3A10086&message_id=512',
    );
  });

  test('TVBox spider items, inline @Referer headers, and fallback categories parse accurately', () {
    // 1. TVBox recommendation item with `vod_id: null` (e.g. `csp_DouDouGuard`)
    final doudouResp = VodListResponse.fromJson({
      'code': 0,
      'list': [
        {
          'vod_id': null,
          'vod_name': '后会友期',
          'vod_pic':
              'https://img3.doubanio.com/view/photo/s_ratio_poster/public/p2936933522.jpg@Referer=https://api.douban.com/@User-Agent=Mozilla/5.0',
          'vod_remarks': '豆瓣 8.4',
        },
      ],
      'class': [
        {'type_id': '热播电影', 'type_name': '热播电影'},
        {'type_id': '热播剧集', 'type_name': '热播剧集'},
      ],
    });
    expect(doudouResp.items.length, 1);
    expect(doudouResp.items.first.vodId, 'msearch:后会友期');
    expect(doudouResp.items.first.isSearchJumpItem, isTrue);
    expect(doudouResp.categories.length, 2);

    // 2. Inline `@Referer=` and `@User-Agent=` header extraction
    final split = ApiClient.splitTvboxUrlAndHeaders(
      doudouResp.items.first.vodPic,
    );
    expect(
      split.cleanUrl,
      'https://img3.doubanio.com/view/photo/s_ratio_poster/public/p2936933522.jpg',
    );
    expect(split.headers['Referer'], 'https://api.douban.com/');
    expect(split.headers['User-Agent'], 'Mozilla/5.0');

    // 3. Fallback category extraction when `class` is omitted on direct `ac=detail`
    final detailOnlyResp = VodListResponse.fromJson({
      'code': 1,
      'list': [
        {
          'vod_id': 1001,
          'vod_name': '测试动作片',
          'type_id': 6,
          'type_name': '动作片',
        },
        {
          'vod_id': 1002,
          'vod_name': '测试欧美剧',
          'type_id': 15,
          'type_name': '欧美剧',
        },
      ],
    });
    expect(detailOnlyResp.categories.length, 2);
    expect(detailOnlyResp.categories.first.typeName, '动作片');
    expect(detailOnlyResp.categories.last.typeName, '欧美剧');

    // 4. VodDetail.parsePlayGroups preserves raw URLs that contain `$` after `://`
    final groups = VodDetail.parsePlayGroups(
      '专线',
      r'第01集$https://cdn.example.com/v1/play$hd.m3u8#https://cdn.example.com/v1/ep2$sd.m3u8',
    );
    expect(groups.length, 1);
    expect(groups.first.episodes.length, 2);
    expect(groups.first.episodes[0].title, '第01集');
    expect(
      groups.first.episodes[0].rawUrl,
      r'https://cdn.example.com/v1/play$hd.m3u8',
    );
    expect(groups.first.episodes[1].title, '第 2 集');
    expect(
      groups.first.episodes[1].rawUrl,
      r'https://cdn.example.com/v1/ep2$sd.m3u8',
    );
  });

  test('VideoDownloadSpeedBadge formats download speed and LocalProxyTunnelBridge tracks downstream throughput', () {
    expect(VideoDownloadSpeedBadge.formatBytesPerSecond(0), '↓ 0 KB/s');
    expect(VideoDownloadSpeedBadge.formatBytesPerSecond(512 * 1024), '↓ 512 KB/s');
    expect(
      VideoDownloadSpeedBadge.formatBytesPerSecond(2.5 * 1024 * 1024),
      '↓ 2.50 MB/s',
    );
    expect(
      VideoDownloadSpeedBadge.formatBytesPerSecond(15.4 * 1024 * 1024),
      '↓ 15.4 MB/s',
    );

    LocalProxyTunnelBridge.recordDownstreamBytes(300 * 1024);
    expect(
      LocalProxyTunnelBridge.recentDownstreamBytesPerSecond,
      greaterThan(100 * 1024),
    );
  });

  testWidgets('VideoProxyNodeSelector dropdown switches proxy nodes and direct mode on video playback screen',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final svc = ProxyRoutingService();
    await svc.initialize();
    await svc.upsertManualNode(
      const ProxyNode(
        id: 'node_jp_1',
        name: '日本高速节点01',
        protocol: 'vless',
        server: '127.0.0.1',
        port: 10001,
        latencyMs: 58,
      ),
      testLatency: false,
    );
    await svc.upsertManualNode(
      const ProxyNode(
        id: 'node_sg_2',
        name: '新加坡专线节点02',
        protocol: 'ss',
        server: '127.0.0.1',
        port: 10002,
        latencyMs: 85,
      ),
      testLatency: false,
    );

    String? lastSwitchNotice;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: VideoProxyNodeSelector(
              proxyService: svc,
              scenario: RequestScenario.vodStream,
              onProxyChanged: (msg) => lastSwitchNotice = msg,
            ),
          ),
        ),
      ),
    );

    // Initially proxy is disabled -> shows "代理: 直连"
    expect(find.text('代理: 直连'), findsOneWidget);

    // Open dropdown menu and select "新加坡专线节点02"
    await tester.tap(find.byType(VideoProxyNodeSelector));
    await tester.pumpAndSettle();
    expect(find.textContaining('日本高速节点01'), findsWidgets);
    expect(find.textContaining('新加坡专线节点02'), findsOneWidget);

    await tester.tap(find.textContaining('新加坡专线节点02'));
    await tester.pumpAndSettle();

    expect(svc.proxyEnabled, isTrue);
    expect(svc.activeNode?.id, 'node_sg_2');
    expect(lastSwitchNotice, contains('新加坡专线节点02'));
    expect(find.textContaining('新加坡专线节点02'), findsOneWidget);

    svc.dispose();
  });

  test('LocalProxyTunnelBridge concurrently prefetches HLS segments across multiple connections',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prevHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevHttpOverrides);
    final fetchedSegmentsOnOrigin = <String>[];
    final originServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final originPort = originServer.port;

    originServer.listen((HttpRequest req) async {
      if (req.uri.path == '/vod/index.m3u8') {
        req.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
        req.response.write(
          '#EXTM3U\n'
          '#EXT-X-VERSION:3\n'
          '#EXT-X-TARGETDURATION:4\n'
          '#EXTINF:4.0,\n'
          'seg_0.ts\n'
          '#EXTINF:4.0,\n'
          'seg_1.ts\n'
          '#EXTINF:4.0,\n'
          'seg_2.ts\n'
          '#EXTINF:4.0,\n'
          'seg_3.ts\n'
          '#EXTINF:4.0,\n'
          'seg_4.ts\n'
          '#EXT-X-ENDLIST\n',
        );
        await req.response.close();
        return;
      }
      if (req.uri.path.endsWith('.ts')) {
        fetchedSegmentsOnOrigin.add(req.uri.path);
        final payload = List<int>.filled(2048, 0x47);
        req.response.headers.contentType = ContentType('video', 'mp2t');
        req.response.contentLength = payload.length;
        req.response.add(payload);
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });

    final bridge = LocalProxyTunnelBridge(resolveDefaultNode: () => null);
    addTearDown(bridge.stop);
    expect(await bridge.ensureStarted(), greaterThan(0));

    final m3u8Url = 'http://127.0.0.1:$originPort/vod/index.m3u8';
    final relayedUrl = bridge.buildStreamRelayUrl(
      targetUrl: m3u8Url,
      forceDirect: true,
    );
    expect(relayedUrl, contains('/__m3u8_proxy__/playlist.m3u8'));
    expect(relayedUrl, contains('direct=1'));

    final hc = HttpClient();
    final m3u8Req = await hc.getUrl(Uri.parse(relayedUrl));
    final m3u8Resp = await m3u8Req.close();
    expect(m3u8Resp.statusCode, 200);
    final m3u8Text = await utf8.decoder.bind(m3u8Resp).join();
    final segUrls = m3u8Text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.startsWith('http://127.0.0.1:'))
        .toList();
    expect(segUrls.length, 5);

    // Wait briefly for the 4 concurrent prefetch workers to finish downloading seg_0..seg_3
    for (var i = 0; i < 20; i++) {
      if (bridge.prefetchedSegmentCount >= 4) break;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(bridge.prefetchedSegmentCount, greaterThanOrEqualTo(4));
    expect(fetchedSegmentsOnOrigin.length, greaterThanOrEqualTo(4));

    // Request seg_0 from the local relay -> should be served immediately from memory cache!
    final seg0Req = await hc.getUrl(Uri.parse(segUrls[0]));
    final seg0Resp = await seg0Req.close();
    expect(seg0Resp.statusCode, 200);
    expect(seg0Resp.headers.value('x-multithread-cache'), 'HIT');
    final seg0Bytes =
        await seg0Resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    expect(seg0Bytes.length, 2048);

    hc.close(force: true);
    await originServer.close(force: true);
  });

  test('resolveVodPlayback resolves direct TVBox m3u8 in 0ms and probeVodStreamPlayableFast detects playability',
      () async {
    final prevHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevHttpOverrides);
    final originServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    originServer.listen((HttpRequest req) async {
      if (req.uri.path == '/fast/stream.m3u8') {
        req.response.statusCode = 200;
        req.response.write('#EXTM3U\n');
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });

    final api = ApiClient(
      ServerConfig(
        baseUrl: 'http://127.0.0.1:${originServer.port}',
        preferDirectPlayback: true,
      ),
    );
    const tvboxSource = VodSource(
      id: 'tvbox_0_2',
      name: '玩偶哥哥',
      api: 'csp_WoGG',
      isTvBox: true,
      tvboxSiteIndex: 2,
      tvboxSourceIndex: 0,
      tvboxType: 3, // Spider source whose detail already returned a direct .m3u8 URL
    );

    final streamUrl =
        'http://127.0.0.1:${originServer.port}/fast/stream.m3u8@Referer=https://example.com/';
    final sw = Stopwatch()..start();
    final resolved = await api.resolveVodPlayback(
      tvboxSource,
      playGroup: '线路1',
      episodeUrl: streamUrl,
    );
    sw.stop();

    expect(sw.elapsedMilliseconds, lessThan(30));
    expect(
      resolved.directUrl,
      'http://127.0.0.1:${originServer.port}/fast/stream.m3u8',
    );
    expect(resolved.headers['Referer'], 'https://example.com/');

    final fastOk = await api.probeVodStreamPlayableFast(
      resolved.directUrl,
      resolved.headers,
    );
    expect(fastOk.ok, isTrue);

    final deadProbe = await api.probeVodStreamPlayableFast(
      'http://127.0.0.1:${originServer.port}/dead/404.m3u8',
      const {},
    );
    expect(deadProbe.ok, isFalse);

    await originServer.close(force: true);
  });

  testWidgets('MobileEdgeSwipeBack triggers onBack when swiping right from left edge and ignores center swipes',
      (WidgetTester tester) async {
    int backCount = 0;
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: MobileEdgeSwipeBack(
          onBack: () => backCount++,
          child: const Scaffold(
            body: Center(child: Text('Test Content')),
          ),
        ),
      ),
    );

    // 1. Swiping from center (x = 180) should NOT trigger back
    await tester.timedDragFrom(
      const Offset(180, 400),
      const Offset(120, 0),
      const Duration(milliseconds: 180),
    );
    await tester.pumpAndSettle();
    expect(backCount, 0);

    // 2. Swiping right from left edge (x = 12 -> +100px) SHOULD trigger back
    await tester.timedDragFrom(
      const Offset(12, 400),
      const Offset(100, 0),
      const Duration(milliseconds: 180),
    );
    await tester.pumpAndSettle();
    expect(backCount, 1);
  });

  test('TelegramChat computes conversationActionType and conversationActionLabel accurately',
      () {
    final channelChat = TelegramChat.fromJson(const {
      'peer': 'channel:100123',
      'title': '测试频道',
      'kind': '频道',
      'broadcast': true,
    });
    expect(channelChat.conversationActionType, 'leave');
    expect(channelChat.conversationActionLabel, '退出频道');

    final supergroupChat = TelegramChat.fromJson(const {
      'peer': 'channel:100456',
      'title': '测试超级群',
      'kind': '超级群',
      'broadcast': false,
    });
    expect(supergroupChat.conversationActionType, 'leave');
    expect(supergroupChat.conversationActionLabel, '退出超级群');

    final groupChat = TelegramChat.fromJson(const {
      'peer': 'chat:789',
      'title': '普通群组',
      'kind': '群组',
    });
    expect(groupChat.conversationActionType, 'leave');
    expect(groupChat.conversationActionLabel, '退出群组');

    final friendChat = TelegramChat.fromJson(const {
      'peer': 'user:42',
      'title': '好友A',
      'contact': true,
      'self': false,
    });
    expect(friendChat.conversationActionType, 'delete_contact');
    expect(friendChat.conversationActionLabel, '删除好友');

    final selfChat = TelegramChat.fromJson(const {
      'peer': 'user:1',
      'title': '收藏夹',
      'self': true,
    });
    expect(selfChat.conversationActionType, '');
    expect(selfChat.conversationActionLabel, '');
  });

  test('ProxyRoutingService switches nodes immediately for existing relay URLs and forces direct when proxy is disabled',
      () async {
    final prevHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevHttpOverrides);
    final originServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final originPort = originServer.port;
    originServer.listen((HttpRequest req) async {
      if (req.uri.path == '/live/index.m3u8') {
        req.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
        req.response.write(
          '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\nseg01.ts\n#EXT-X-ENDLIST\n',
        );
        await req.response.close();
      } else if (req.uri.path == '/live/seg01.ts') {
        req.response.headers.contentType = ContentType('video', 'mp2t');
        req.response.add(List<int>.filled(512, 0x47));
        await req.response.close();
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    });

    var socks1Hits = 0;
    var socks2Hits = 0;
    final activeTestSockets = <Socket>[];

    Future<ServerSocket> startMockSocks(void Function() onHit) async {
      final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      srv.listen((Socket client) async {
        activeTestSockets.add(client);
        final rx = <int>[];
        var stage = 0;
        Socket? upstream;
        client.listen(
          (chunk) async {
            try {
              if (stage == 2 && upstream != null) {
                upstream!.add(chunk);
                return;
              }
              rx.addAll(chunk);
              if (stage == 0 && rx.length >= 3) {
                rx.clear();
                stage = 1;
                client.add(const [0x05, 0x00]);
              } else if (stage == 1 && rx.length >= 7) {
                final hostLen = rx[4];
                if (rx.length >= 5 + hostLen + 2) {
                  final host = utf8.decode(rx.sublist(5, 5 + hostLen));
                  final port = (rx[5 + hostLen] << 8) | rx[5 + hostLen + 1];
                  rx.removeRange(0, 5 + hostLen + 2);
                  onHit();
                  try {
                    upstream = await Socket.connect(host, port);
                    activeTestSockets.add(upstream!);
                  } catch (_) {
                    client.destroy();
                    return;
                  }
                  stage = 2;
                  client.add(const [0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0, 0]);
                  if (rx.isNotEmpty) {
                    upstream!.add(List<int>.from(rx));
                    rx.clear();
                  }
                  upstream!.listen(
                    (d) => client.add(d),
                    onDone: () => client.destroy(),
                    onError: (_) => client.destroy(),
                  );
                }
              }
            } catch (_) {
              client.destroy();
            }
          },
          onError: (_) => client.destroy(),
        );
      });
      return srv;
    }

    final socks1 = await startMockSocks(() => socks1Hits++);
    final socks2 = await startMockSocks(() => socks2Hits++);

    SharedPreferences.setMockInitialValues({});
    final svc = ProxyRoutingService();
    await svc.initialize();
    await svc.upsertManualNode(
      ProxyNode(
        id: 'node_socks_1',
        name: '节点1',
        protocol: 'socks5',
        server: '127.0.0.1',
        port: socks1.port,
        latencyMs: 60,
        speedKbps: 1200,
      ),
      testLatency: false,
    );
    await svc.upsertManualNode(
      ProxyNode(
        id: 'node_socks_2',
        name: '节点2',
        protocol: 'socks5',
        server: '127.0.0.1',
        port: socks2.port,
        latencyMs: 45,
        speedKbps: 2000,
      ),
      testLatency: false,
    );

    // 1. Lock node_socks_1 via scenario rule + manual selection (simulating VideoProxyNodeSelector)
    await svc.setProxyEnabled(true);
    await svc.updateScenarioRule(
      RequestScenario.vodStream,
      mode: ScenarioRouteMode.proxyNode,
      specificNodeId: 'node_socks_1',
    );
    await svc.selectNode('node_socks_1', switchToManual: true);

    final playlistUrl = 'http://127.0.0.1:$originPort/live/index.m3u8';
    final relayedPlaylistUrl = await svc.resolveProxiedStreamUrl(
      RequestScenario.vodStream,
      playlistUrl,
    );
    expect(relayedPlaylistUrl, contains('nid=node_socks_1'));

    final hc = HttpClient();
    final m3u8Req = await hc.getUrl(Uri.parse(relayedPlaylistUrl));
    final m3u8Resp = await m3u8Req.close();
    final m3u8Text = await utf8.decoder.bind(m3u8Resp).join();
    expect(socks1Hits, greaterThanOrEqualTo(1));
    expect(socks2Hits, 0);

    final segUrlWithOldNid = m3u8Text
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.startsWith('http://127.0.0.1:'));
    expect(segUrlWithOldNid, contains('nid=node_socks_1'));

    // 2. Switch to node_socks_2 -> even existing segment URLs with `nid=node_socks_1`
    // MUST immediately route through node_socks_2 instead of staying on node_socks_1!
    final socks1BeforeSwitch = socks1Hits;
    await svc.selectNode('node_socks_2', switchToManual: true);
    expect(
      svc.resolveNodeForScenario(RequestScenario.vodStream)?.id,
      'node_socks_2',
    );

    final segReq2 = await hc.getUrl(Uri.parse(segUrlWithOldNid));
    final segResp2 = await segReq2.close();
    expect(segResp2.statusCode, 200);
    await segResp2.drain<void>();
    expect(socks2Hits, greaterThanOrEqualTo(1));
    expect(socks1Hits, socks1BeforeSwitch);

    // 3. Switch to autoFastest mode -> clears specificNodeId locks so fastestNode takes effect
    await svc.setSelectionMode(ProxySelectionMode.autoFastest);
    expect(
      svc.scenarioRules[RequestScenario.vodStream]?.specificNodeId,
      isNull,
    );
    expect(
      svc.resolveNodeForScenario(RequestScenario.vodStream)?.id,
      'node_socks_2',
    );

    // 4. Turn OFF global proxy -> existing `/__m3u8_proxy__/` URLs MUST immediately
    // connect DIRECT without hitting either proxy node!
    await svc.setProxyEnabled(false);
    final socks1BeforeOff = socks1Hits;
    final socks2BeforeOff = socks2Hits;

    final segReqDirect = await hc.getUrl(Uri.parse(segUrlWithOldNid));
    final segRespDirect = await segReqDirect.close();
    expect(segRespDirect.statusCode, 200);
    final directBytes =
        await segRespDirect.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    expect(directBytes.length, 512);
    expect(socks1Hits, socks1BeforeOff);
    expect(socks2Hits, socks2BeforeOff);

    hc.close(force: true);
    svc.dispose();
    for (final s in activeTestSockets) {
      s.destroy();
    }
    await socks1.close();
    await socks2.close();
    await originServer.close(force: true);
  });

  test('Direct VOD M3U8 routes through local multi-thread prefetch relay and awaits in-flight segments cleanly',
      () async {
    final prevHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevHttpOverrides);
    var seg0FetchCount = 0;
    final originServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final originPort = originServer.port;
    originServer.listen((HttpRequest req) async {
      if (req.uri.path == '/vod/direct.m3u8') {
        req.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
        req.response.write(
          '#EXTM3U\n'
          '#EXT-X-VERSION:3\n'
          '#EXT-X-TARGETDURATION:4\n'
          '#EXTINF:4.0,\n'
          'seg_0.ts\n'
          '#EXTINF:4.0,\n'
          'seg_1.ts\n'
          '#EXT-X-ENDLIST\n',
        );
        await req.response.close();
        return;
      }
      if (req.uri.path == '/vod/seg_0.ts') {
        seg0FetchCount++;
        // Simulate a 320ms network transfer (previously timed out at 180ms and caused duplicate fetch!)
        await Future<void>.delayed(const Duration(milliseconds: 320));
        final payload = List<int>.filled(4096, 0x47);
        req.response.headers.contentType = ContentType('video', 'mp2t');
        req.response.contentLength = payload.length;
        req.response.add(payload);
        await req.response.close();
        return;
      }
      if (req.uri.path == '/vod/seg_1.ts') {
        final payload = List<int>.filled(4096, 0x47);
        req.response.headers.contentType = ContentType('video', 'mp2t');
        req.response.contentLength = payload.length;
        req.response.add(payload);
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });

    SharedPreferences.setMockInitialValues({});
    final svc = ProxyRoutingService();
    await svc.initialize();
    expect(svc.proxyEnabled, isFalse);

    final rawM3u8Url = 'http://127.0.0.1:$originPort/vod/direct.m3u8';
    // Even with proxy disabled (direct mode), VOD M3U8 with remote host routes through local relay
    // Test with localhost replacement via buildStreamRelayUrl + resolveProxiedStreamUrl on external domain
    final externalM3u8 = 'https://cdn.qq.com/vod/index.m3u8';
    final relayedExternal = await svc.resolveProxiedStreamUrl(
      RequestScenario.vodStream,
      externalM3u8,
      cleanM3u8Ads: true,
    );
    expect(relayedExternal, contains('/__m3u8_proxy__/playlist.m3u8'));
    expect(relayedExternal, contains('direct=1'));

    final bridge = LocalProxyTunnelBridge(resolveDefaultNode: () => null);
    addTearDown(bridge.stop);
    await bridge.ensureStarted();
    final localRelayed = bridge.buildStreamRelayUrl(
      targetUrl: rawM3u8Url,
      forceDirect: true,
    );

    final hc = HttpClient();
    final m3u8Req = await hc.getUrl(Uri.parse(localRelayed));
    final m3u8Resp = await m3u8Req.close();
    final m3u8Text = await utf8.decoder.bind(m3u8Resp).join();
    final segUrls = m3u8Text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.startsWith('http://127.0.0.1:'))
        .toList();
    expect(segUrls.length, 2);

    // Wait 70ms so the initial prefetch timer starts fetching seg_0 in-flight
    await Future<void>.delayed(const Duration(milliseconds: 70));

    // Request seg_0 while it is in-flight (320ms duration) -> should await the in-flight fetch
    // and return `INFLIGHT-HIT` without opening a duplicate download!
    final seg0Req = await hc.getUrl(Uri.parse(segUrls[0]));
    final seg0Resp = await seg0Req.close();
    expect(seg0Resp.statusCode, 200);
    expect(seg0Resp.headers.value('x-multithread-cache'), anyOf('INFLIGHT-HIT', 'HIT'));
    final seg0Bytes =
        await seg0Resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    expect(seg0Bytes.length, 4096);
    expect(seg0FetchCount, 1);

    hc.close(force: true);
    svc.dispose();
    await originServer.close(force: true);
  });

  testWidgets(
      'TelegramScreen optimistic send shows message immediately before background send completes and saved local files show clickable directory path',
      (WidgetTester tester) async {
    final sendCompleter = Completer<void>();
    final fakeApi = _FakeTelegramApiClient(sendCompleter: sendCompleter);

    SharedPreferences.setMockInitialValues({
      'm3u8_tg_saved_local_paths_v1': jsonEncode({
        'default|user:1001|101': '/Users/tester/Downloads/report_2026.pdf',
      }),
    });

    final appState = AppState(customApi: fakeApi);
    appState.updateTelegramReadingContext(
      isTelegramViewActive: true,
      isAppForeground: true,
    );

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(1280, 800)),
          child: Scaffold(
            body: TelegramScreen(appState: appState),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('测试好友'), findsWidgets);
    if (find.text('report_2026.pdf').evaluate().isEmpty) {
      await tester.tap(find.text('测试好友').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('report_2026.pdf'), findsOneWidget);

    // 1. Verify the downloaded local file path and "打开目录" button are displayed on the message bubble!
    expect(
      find.text('/Users/tester/Downloads/report_2026.pdf'),
      findsOneWidget,
    );
    expect(find.text('打开目录'), findsOneWidget);

    // 2. Enter text in the compose input and click Send -> should IMMEDIATELY clear input
    // and display the optimistic message bubble with '发送中...' before the network call finishes!
    final composeFinder = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          (w.decoration?.hintText?.contains('撰写消息') ?? false),
    );
    expect(composeFinder, findsOneWidget);

    await tester.enterText(composeFinder, '这是一条乐观发送的测试消息');
    await tester.pump();

    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();

    // Immediately after tapping Send (0ms elapsed, background request still in flight):
    expect(fakeApi.sendCompleted, isFalse);
    final composeWidget = tester.widget<TextField>(composeFinder);
    expect(composeWidget.controller?.text, isEmpty);
    expect(find.text('这是一条乐观发送的测试消息'), findsWidgets);
    expect(find.text('发送中...'), findsOneWidget);

    // Complete the background network send -> optimistic status transitions to '已发送'
    sendCompleter.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(fakeApi.sendCompleted, isTrue);
    expect(find.text('这是一条乐观发送的测试消息'), findsWidgets);
    expect(find.text('发送中...'), findsNothing);
    expect(find.text('已发送'), findsOneWidget);

    // 3. Verify "删除好友" / "退出群组" is NOT shown in the bottom send bar and is collapsed by default in the top header
    expect(find.text('删除好友'), findsNothing);
    expect(find.byTooltip('展开删除好友'), findsOneWidget);

    await tester.tap(find.byTooltip('展开删除好友'));
    await tester.pump();
    expect(find.text('删除好友'), findsOneWidget);
    expect(find.byTooltip('折叠删除好友'), findsOneWidget);

    await tester.tap(find.byTooltip('折叠删除好友'));
    await tester.pump();
    expect(find.text('删除好友'), findsNothing);

    appState.dispose();
  });

  testWidgets(
      'TelegramScreen receives incoming messages in real time via SSE even when account userId is empty and via fast live polling',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final fakeApi = _FakeTelegramApiClient();

    final appState = AppState(customApi: fakeApi);
    appState.updateTelegramReadingContext(
      isTelegramViewActive: true,
      isAppForeground: true,
    );

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(1280, 800)),
          child: Scaffold(
            body: TelegramScreen(appState: appState),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    // 1. Even though TelegramAccount.userId is empty (''), 'default' account MUST be registered
    // in TelegramNotificationService so the SSE notification stream connects immediately.
    await appState.telegramNotifications.refreshAccountsAndConnect();
    expect(
      appState.telegramNotifications.registeredAccountIdsForTesting,
      contains('default'),
    );

    // 2. Inject a real-time SSE message frame for the active chat ('user:1001')
    final ssePayload = jsonEncode({
      'type': 'new_message',
      'account_id': 'default',
      'peer': 'user:1001',
      'chat_title': '测试好友',
      'new_message': true,
      'message_id': 105,
      'message': {
        'id': 105,
        'date': 1700000100,
        'sender': '测试好友',
        'text': 'SSE实时推送的新消息立即到达',
        'outgoing': false,
      },
      'chat': {
        'peer': 'user:1001',
        'title': '测试好友',
        'kind': '私聊',
        'preview': 'SSE实时推送的新消息立即到达',
        'date': 1700000100,
        'unread': 0,
        'top_message_id': 105,
      },
    });
    appState.telegramNotifications.injectSseEventForTesting(
      'update',
      ssePayload,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('SSE实时推送的新消息立即到达'), findsWidgets);

    // 3. Simulate a message arriving on the server without an embedded SSE message payload
    // and verify the 2.2s fast polling timer picks it up automatically.
    fakeApi.serverMessagesByPeer['user:1001']!.add(
      const TelegramMessage(
        id: 106,
        date: 1700000200,
        sender: '测试好友',
        text: '高频轮询兜底同步的新消息',
        outgoing: false,
      ),
    );
    await tester.pump(const Duration(milliseconds: 2300));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('高频轮询兜底同步的新消息'), findsWidgets);

    // 4. Inject a real-time SSE message with raw 'user:1001' / ':user:1001' sender and verify
    // it immediately resolves to the real username ('测试好友') without ever displaying 'user:1001'
    final rawSenderSsePayload = jsonEncode({
      'type': 'new_message',
      'account_id': 'default',
      'peer': 'user:1001',
      'chat_title': 'user:1001',
      'new_message': true,
      'message_id': 107,
      'message': {
        'id': 107,
        'date': 1700000300,
        'sender': ':user:1001',
        'text': '短消息更新不带用户实体',
        'outgoing': false,
      },
    });
    appState.telegramNotifications.injectSseEventForTesting(
      'update',
      rawSenderSsePayload,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('短消息更新不带用户实体'), findsWidgets);
    expect(find.text('user:1001'), findsNothing);
    expect(find.text(':user:1001'), findsNothing);
    expect(find.text('测试好友'), findsWidgets);

    // 5. Inject a missed call / service message ('[服务消息]' in 1-on-1 user chat) and verify
    // it renders as a Call Card ('未接来电 / 语音通话') and updates the chat preview
    final missedCallSsePayload = jsonEncode({
      'type': 'new_message',
      'account_id': 'default',
      'peer': 'user:1001',
      'chat_title': 'user:1001',
      'new_message': true,
      'message_id': 108,
      'message': {
        'id': 108,
        'date': 1700000400,
        'sender': '',
        'text': '[服务消息]',
        'outgoing': false,
      },
    });
    appState.telegramNotifications.injectSseEventForTesting(
      'update',
      missedCallSsePayload,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.textContaining('未接来电'), findsWidgets);

    appState.dispose();
  });

  testWidgets(
      'PlayerVolumeControl and VideoDownloadSpeedBadge render visibly and adjust volume / mute state interactively',
      (WidgetTester tester) async {
    final fakePlayer = _FakeMediaKitPlayer(initialVolume: 80.0);
    addTearDown(fakePlayer.dispose);

    LocalProxyTunnelBridge.recordDownstreamBytes(512 * 1024);

    double? callbackVolume;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                VideoDownloadSpeedBadge(
                  player: fakePlayer,
                  compact: true,
                ),
                const SizedBox(width: 8),
                PlayerVolumeControl(
                  player: fakePlayer,
                  compact: true,
                  showPercentage: true,
                  onVolumeChanged: (val) => callbackVolume = val,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // 1. Speed badge and volume control (80%) are both visible
    expect(find.byType(VideoDownloadSpeedBadge), findsOneWidget);
    expect(find.byType(PlayerVolumeControl), findsOneWidget);
    expect(find.text('80%'), findsOneWidget);
    expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);

    // 2. Tap mute button -> mutes to 0%
    await tester.tap(find.byIcon(Icons.volume_up_rounded));
    await tester.pump();
    expect(fakePlayer.currentVolume, 0.0);
    expect(callbackVolume, 0.0);
    expect(find.text('0%'), findsOneWidget);
    expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);

    // 3. Tap unmute button -> restores previous 80% volume
    await tester.tap(find.byIcon(Icons.volume_off_rounded));
    await tester.pump();
    expect(fakePlayer.currentVolume, 80.0);
    expect(callbackVolume, 80.0);
    expect(find.text('80%'), findsOneWidget);

    // 4. Floating speed badge supports hiding (collapsing), restoring, and closing
    expect(find.byIcon(Icons.remove_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.remove_rounded));
    await tester.pump();
    expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    await tester.pump();
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    expect(find.byIcon(Icons.speed_rounded), findsNothing);
  });

  test(
      'TVBox link parser and stream relay handle dollar URLs, stringified headers, multi-quality lists, MacCMS player_aaaa, 302 redirected extensionless M3U8s, and disguised image-bed TS segments',
      () async {
    final prevHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevHttpOverrides);

    // 1. splitTvboxUrlAndHeaders preserves '$' inside URL path/query while stripping title prefix and live comment labels
    final dollarInPath = ApiClient.splitTvboxUrlAndHeaders(
      r'正片$//cdn.example.com/v1/play$hd.m3u8?a=1&amp;b=2$3#{"User-Agent":"TVBox/1.0","Referer":"https://ref.example.com/"}',
    );
    expect(
      dollarInPath.cleanUrl,
      r'https://cdn.example.com/v1/play$hd.m3u8?a=1&b=2$3',
    );
    expect(dollarInPath.headers['User-Agent'], 'TVBox/1.0');
    expect(dollarInPath.headers['Referer'], 'https://ref.example.com/');

    final liveCommentSuffix = ApiClient.splitTvboxUrlAndHeaders(
      r'http://[2409:8087:1::1]/ott/1.m3u8$IPV6|User-Agent=okhttp/3.15',
    );
    expect(liveCommentSuffix.cleanUrl, 'http://[2409:8087:1::1]/ott/1.m3u8');
    expect(liveCommentSuffix.headers['User-Agent'], 'okhttp/3.15');

    // 2. ResolvedPlayback.fromJson parses stringified JSON headers and multi-quality URL lists
    final multiQualityResolved = ResolvedPlayback.fromJson({
      'parse': 0,
      'url': [
        '4K臻彩',
        '//cdn.example.com/4k/index.m3u8?token=1&amp;k=2',
        '1080P',
        'https://cdn.example.com/1080p/index.m3u8',
      ],
      'header': '{"User-Agent":"Mozilla/5.0","Referer":"https://spider.example.com/"}',
    });
    expect(
      multiQualityResolved.directUrl,
      'https://cdn.example.com/4k/index.m3u8?token=1&k=2',
    );
    expect(multiQualityResolved.headers['User-Agent'], 'Mozilla/5.0');
    expect(
      multiQualityResolved.headers['Referer'],
      'https://spider.example.com/',
    );

    // 3. VodDetail.fromJson supports custom vod_play_note delimiter and newline-separated episodes
    final customNoteDetail = VodDetail.fromJson({
      'vod_id': '8899',
      'vod_name': '测试剧集',
      'vod_play_from': r'极速专线$$备用专线',
      'vod_play_note': r'$$',
      'vod_play_url':
          '第1集\$https://cdn.example.com/ep1.m3u8\n第2集\$https://cdn.example.com/ep2.m3u8\$\$第1集\$https://bak.example.com/ep1.m3u8',
    });
    expect(customNoteDetail.playGroups.length, 2);
    expect(customNoteDetail.playGroups[0].episodes.length, 2);
    expect(
      customNoteDetail.playGroups[0].episodes[1].rawUrl,
      'https://cdn.example.com/ep2.m3u8',
    );

    // 3b. VodDetail.parsePlayGroups prioritizes direct .m3u8 play groups over HTML /share/ play groups
    final shareVsM3u8Groups = VodDetail.parsePlayGroups(
      r'hnm3u8$$$hnzym3u8',
      r'第01集$https://hn.bfvvs.com/play/12345/share/abc#第02集$https://hn.bfvvs.com/play/12346/share/def$$$第01集$https://hn.bfvvs.com/play/12345/index.m3u8#第02集$https://hn.bfvvs.com/play/12346/index.m3u8',
    );
    expect(shareVsM3u8Groups.length, 2);
    expect(shareVsM3u8Groups.first.name, 'hnzym3u8');
    expect(
      shareVsM3u8Groups.first.episodes.first.rawUrl,
      'https://hn.bfvvs.com/play/12345/index.m3u8',
    );

    // 4. Mock server for wrapper unwrapping, MacCMS player_aaaa encrypt:2, 302 redirected extensionless M3U8, and PNG-disguised TS segment
    final originServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = originServer.port;
    addTearDown(() => originServer.close(force: true));

    // Create a 3-packet MPEG-TS payload (3 * 188 = 564 bytes, each starting with 0x47)
    // prepended with an 8-byte fake PNG signature (89 50 4E 47 0D 0A 1A 0A)
    final fakePngHeader = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    final realTsPayload = List<int>.generate(
      188 * 3,
      (i) => (i % 188 == 0) ? 0x47 : (i & 0xFF),
    );
    final disguisedSegmentBytes = <int>[...fakePngHeader, ...realTsPayload];

    originServer.listen((HttpRequest req) async {
      if (req.uri.path == '/vodplay/1001-1-1.html') {
        final targetM3u8 = 'http://127.0.0.1:$port/tvbox/redirect_entry';
        final enc2 = base64.encode(utf8.encode(Uri.encodeComponent(targetM3u8)));
        req.response.headers.contentType = ContentType.html;
        req.response.write(
          '<html><body><script>var player_aaaa={"flag":"play","encrypt":2,"url":"$enc2"};</script></body></html>',
        );
        await req.response.close();
        return;
      }
      if (req.uri.path == '/tvbox/redirect_entry') {
        req.response.statusCode = HttpStatus.found;
        req.response.headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:$port/hls/2026/extensionless_stream?token=ok',
        );
        await req.response.close();
        return;
      }
      if (req.uri.path == '/hls/2026/extensionless_stream') {
        // Extensionless M3U8 with UTF-8 BOM, text/plain Content-Type, relative AES-128 key, and relative .jpg disguised segment.
        // Simulate VOD CDNs (like hn.bfvvs.com / senlin / ffzy) that return 206 Partial Content whenever Range is forwarded.
        if (req.headers.value(HttpHeaders.rangeHeader) != null) {
          req.response.statusCode = HttpStatus.partialContent;
        }
        req.response.headers.contentType = ContentType.text;
        req.response.write(
          '\uFEFF#EXTM3U\n'
          '#EXT-X-VERSION:3\n'
          '#EXT-X-TARGETDURATION:4\n'
          '#EXT-X-KEY:METHOD=AES-128,URI="enc.key",IV=0x00000000000000000000000000000000\n'
          '#EXTINF:4.0,\n'
          'disguised_seg01.jpg\n'
          '#EXT-X-ENDLIST\n',
        );
        await req.response.close();
        return;
      }
      if (req.uri.path == '/hls/2026/enc.key') {
        req.response.headers.contentType =
            ContentType('application', 'octet-stream');
        req.response.add(List<int>.filled(16, 0x41));
        await req.response.close();
        return;
      }
      if (req.uri.path == '/hls/2026/disguised_seg01.jpg') {
        req.response.headers.contentType = ContentType('image', 'png');
        req.response.contentLength = disguisedSegmentBytes.length;
        req.response.add(disguisedSegmentBytes);
        await req.response.close();
        return;
      }
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    });

    final api = ApiClient(
      ServerConfig(
        baseUrl: 'http://127.0.0.1:$port',
        preferDirectPlayback: true,
      ),
    );
    const tvboxSource = VodSource(
      id: 'tvbox_0_1',
      name: '测试TVBox源',
      api: 'csp_Test',
      isTvBox: true,
      tvboxSiteIndex: 1,
      tvboxSourceIndex: 0,
      tvboxType: 3,
    );

    // 4a. Wrapper URL (`?url=http://...m3u8`) is unwrapped in 0ms instead of feeding HTML wrapper to libmpv
    final wrappedResolved = await api.resolveVodPlayback(
      tvboxSource,
      playGroup: '线路1',
      episodeUrl:
          'https://player.example.com/dplayer/?url=http://127.0.0.1:$port/direct/video.m3u8',
    );
    expect(
      wrappedResolved.directUrl,
      'http://127.0.0.1:$port/direct/video.m3u8',
    );
    expect(wrappedResolved.headers['Referer'], 'https://player.example.com/');

    // 4b. MacCMS HTML page (`/vodplay/1001-1-1.html`) with `player_aaaa` (`encrypt: 2`)
    // is automatically decrypted & resolved on the client when `/api/vod/play` returns 404
    final htmlResolved = await api.resolveVodPlayback(
      tvboxSource,
      playGroup: '线路1',
      episodeUrl: 'http://127.0.0.1:$port/vodplay/1001-1-1.html',
    );
    expect(
      htmlResolved.directUrl,
      'http://127.0.0.1:$port/tvbox/redirect_entry',
    );

    // 4c. Route the resolved redirect_entry through LocalProxyTunnelBridge:
    // It should follow the 302 redirect to `/hls/2026/extensionless_stream`, recognize `\uFEFF#EXTM3U`,
    // resolve relative `disguised_seg01.jpg` against `/hls/2026/`, rewrite it to `/__m3u8_proxy__/segment.ts`,
    // and strip the 8-byte fake PNG header so the segment starts with `0x47`!
    final bridge = LocalProxyTunnelBridge(resolveDefaultNode: () => null);
    addTearDown(bridge.stop);
    await bridge.ensureStarted();

    final relayedMaster = bridge.buildStreamRelayUrl(
      targetUrl: htmlResolved.directUrl,
      headers: htmlResolved.headers,
      forceDirect: true,
    );

    final hc = HttpClient();
    addTearDown(() => hc.close(force: true));
    final m3u8Req = await hc.getUrl(Uri.parse(relayedMaster));
    // Simulate libmpv / Lavf always sending `Range: bytes=0-`
    m3u8Req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
    final m3u8Resp = await m3u8Req.close();
    expect(m3u8Resp.statusCode, 200);
    final m3u8Text = await utf8.decoder.bind(m3u8Resp).join();
    expect(m3u8Text, contains('#EXTINF:4.0,'));
    expect(m3u8Text, contains('/__m3u8_proxy__/enc.key?'));
    expect(m3u8Text, contains('/__m3u8_proxy__/segment.ts?'));

    final keyLine = m3u8Text
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.startsWith('#EXT-X-KEY:'));
    final keyUrl = RegExp(r'URI="([^"]+)"').firstMatch(keyLine)!.group(1)!;
    final keyReq = await hc.getUrl(Uri.parse(keyUrl));
    keyReq.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
    final keyResp = await keyReq.close();
    expect(keyResp.statusCode, 200);
    final keyBytes =
        await keyResp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    expect(keyBytes.length, 16);

    final segRelayUrl = m3u8Text
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.startsWith('http://127.0.0.1:'));
    final segReq = await hc.getUrl(Uri.parse(segRelayUrl));
    segReq.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
    final segResp = await segReq.close();
    expect(segResp.statusCode, 200);
    expect(segResp.headers.contentType?.mimeType, 'video/mp2t');
    final segBytes =
        await segResp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    expect(segBytes.length, realTsPayload.length);
    expect(segBytes[0], 0x47);
    expect(segBytes[188], 0x47);
    expect(segBytes[376], 0x47);
  });

  testWidgets(
      'MainShell preserves previous screen state when visiting Proxy or Settings and returns via back button',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    SharedPreferences.setMockInitialValues({});
    final appState = AppState(customApi: _FakeTelegramApiClient());
    await appState.proxyService.initialize();
    await appState.updateServerConfig(
      const ServerConfig(
        baseUrl: 'https://127.0.0.1:59999',
        authMode: AuthMode.none,
      ),
    );
    addTearDown(appState.dispose);

    await tester.pumpWidget(M3u8VideoClientApp(appState: appState));
    await tester.pump(const Duration(milliseconds: 100));

    // Switch to Tab 2 (下载工作台)
    appState.onNavigateToTab?.call(2);
    await tester.pump(const Duration(milliseconds: 100));

    // Enter text in the Download screen's URL input field to verify state preservation
    final downloadTextFields = find.descendant(
      of: find.byType(DownloadsScreen),
      matching: find.byType(TextField),
    );
    expect(downloadTextFields, findsWidgets);
    await tester.enterText(
      downloadTextFields.first,
      'https://example.com/preserved_task.m3u8',
    );
    await tester.pump();
    expect(find.text('https://example.com/preserved_task.m3u8'), findsOneWidget);

    // Navigate to Proxy screen (Tab 6)
    appState.onNavigateToTab?.call(6);
    await tester.pump(const Duration(milliseconds: 100));

    // Verify Proxy screen shows the "返回 下载工作台" button and DownloadsScreen is still alive (offstage)
    final proxyBackBtn = find.byKey(const ValueKey('proxy_back_to_previous_btn'));
    expect(proxyBackBtn, findsOneWidget);
    expect(find.text('返回 下载工作台'), findsOneWidget);
    expect(
      find.byType(DownloadsScreen, skipOffstage: false),
      findsOneWidget,
    );

    // Click "返回 下载工作台" button on Proxy screen
    await tester.tap(proxyBackBtn);
    await tester.pump(const Duration(milliseconds: 100));

    // Verify we returned to DownloadsScreen and our typed text was preserved!
    expect(find.byType(DownloadsScreen), findsOneWidget);
    expect(find.text('https://example.com/preserved_task.m3u8'), findsOneWidget);

    // Navigate to Settings screen (Tab 8)
    appState.onNavigateToTab?.call(8);
    await tester.pump(const Duration(milliseconds: 100));

    final settingsBackBtn =
        find.byKey(const ValueKey('settings_back_to_previous_btn'));
    expect(settingsBackBtn, findsOneWidget);
    expect(find.text('返回 下载工作台'), findsOneWidget);

    // Click "返回 下载工作台" button on Settings screen
    await tester.tap(settingsBackBtn);
    await tester.pump(const Duration(milliseconds: 100));

    // Verify we returned to DownloadsScreen and our typed text is still preserved!
    expect(find.byType(DownloadsScreen), findsOneWidget);
    expect(find.text('https://example.com/preserved_task.m3u8'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'SourcePickerDialog renders redesigned source cards with latency speed test, sorting, and pin support',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 840);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    const sources = <VodSource>[
      VodSource(
        id: 'custom_0',
        name: '量子资源',
        api: 'https://cj.lziapi.com/api.php/provide/vod/',
        isTvBox: false,
        customIndex: 0,
      ),
      VodSource(
        id: 'tvbox_0_1',
        name: '玩偶哥哥',
        api: 'csp_WoggGuard',
        isTvBox: true,
        tvboxType: 3,
        tvboxSiteIndex: 1,
        tvboxSourceIndex: 0,
        tvboxSourceName: '饭太硬',
      ),
    ];

    VodSource? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: VideoPlatformTheme.buildTheme(),
        home: Scaffold(
          body: SourcePickerDialog(
            sources: sources,
            selectedSource: sources.first,
            onSelect: (s) => picked = s,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('切换片源站点'), findsOneWidget);
    expect(find.text('共 2 个站点'), findsOneWidget);
    expect(find.text('量子资源'), findsOneWidget);
    expect(find.text('玩偶哥哥'), findsOneWidget);
    expect(find.text('当前使用'), findsOneWidget);
    expect(find.text('CMS JSON'), findsOneWidget);
    expect(find.text('Spider JAR'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('source_picker_batch_test_btn')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('source_picker_sort_speed_btn')),
      findsOneWidget,
    );

    // Trigger single-source speed test on the first card
    final speedButtons = find.text('点击测速');
    expect(speedButtons, findsNWidgets(2));
    await tester.tap(speedButtons.first);
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('160ms'), findsOneWidget);
    expect(find.text('极速'), findsOneWidget);

    // Tap the fastest pick button
    final pickFastestBtn =
        find.byKey(const ValueKey('source_picker_pick_fastest_btn'));
    expect(pickFastestBtn, findsOneWidget);
    await tester.tap(pickFastestBtn);
    await tester.pumpAndSettle();
    expect(picked?.id, 'custom_0');
  });

  testWidgets('SourcePickerDialog mobile compact layout has zero overflow and clickable buttons',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    const sources = <VodSource>[
      VodSource(
        id: 'custom_0',
        name: '量子资源',
        api: 'https://cj.lziapi.com/api.php/provide/vod/',
        isTvBox: false,
        customIndex: 0,
      ),
      VodSource(
        id: 'tvbox_0_1',
        name: '玩偶哥哥',
        api: 'csp_WoggGuard',
        isTvBox: true,
        tvboxType: 3,
        tvboxSiteIndex: 1,
        tvboxSourceIndex: 0,
        tvboxSourceName: '饭太硬',
      ),
    ];

    VodSource? mobilePicked;
    await tester.pumpWidget(
      MaterialApp(
        theme: VideoPlatformTheme.buildTheme(),
        home: Scaffold(
          body: SourcePickerDialog(
            sources: sources,
            selectedSource: sources.first,
            onSelect: (s) => mobilePicked = s,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Tap sort button on mobile
    await tester.tap(find.byKey(const ValueKey('source_picker_sort_speed_btn')));
    await tester.pumpAndSettle();
    expect(find.text('已按速度排序'), findsOneWidget);

    // Tap the second source card on mobile
    await tester.tap(find.text('玩偶哥哥'));
    await tester.pumpAndSettle();
    expect(mobilePicked?.id, 'tvbox_0_1');
  });

  testWidgets('watchHistoryEnabled toggle disables watch history and progress recording',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final appState = AppState(customApi: _FakeTelegramApiClient());
    addTearDown(appState.dispose);

    expect(appState.watchHistoryEnabled, isTrue);

    const testSource = VodSource(
      id: 'source_1',
      name: '测试源',
      api: 'https://example.com/api.php/provide/vod/',
    );
    const detail1 = VodDetail(
      vodId: 'vod_101',
      vodName: '测试电影A',
      vodPic: 'https://example.com/a.jpg',
      typeName: '科幻',
      vodRemarks: 'HD',
    );
    await appState.recordWatchHistory(
      source: testSource,
      detail: detail1,
      episodeTitle: '第1集',
      lineName: 'hnm3u8',
      positionSeconds: 120,
      durationSeconds: 3600,
    );
    expect(appState.history.length, 1);

    // Turn off watch history recording
    await appState.setWatchHistoryEnabled(false);
    expect(appState.watchHistoryEnabled, isFalse);

    const detail2 = VodDetail(
      vodId: 'vod_202',
      vodName: '无痕观看电影B',
      vodPic: 'https://example.com/b.jpg',
      typeName: '动作',
      vodRemarks: '4K',
    );
    await appState.recordWatchHistory(
      source: testSource,
      detail: detail2,
      episodeTitle: '第1集',
      lineName: 'hnm3u8',
      positionSeconds: 300,
      durationSeconds: 5400,
    );
    await appState.saveVodProgress(
      sourceKey: testSource.librarySourceKey,
      vodId: 'vod_202',
      groupIndex: 0,
      episodeIndex: 0,
      episodeName: '第1集',
      positionSeconds: 300,
      durationSeconds: 5400,
    );

    // Neither history nor getVodProgress should record detail2 while disabled
    expect(appState.history.length, 1);
    expect(appState.history.first.vodId, 'vod_101');
    expect(
      appState.getVodProgress(testSource.librarySourceKey, 'vod_202'),
      isNull,
    );

    // Render LibraryHistoryScreen and verify the incognito banner & quick toggle button
    await tester.pumpWidget(
      MaterialApp(
        theme: VideoPlatformTheme.buildTheme(),
        home: Scaffold(
          body: LibraryHistoryScreen(appState: appState),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('记录已关闭'), findsOneWidget);
    expect(
      find.textContaining('当前已关闭观看历史记录（无痕观看模式）'),
      findsOneWidget,
    );

    // Click '重新开启' in the banner
    await tester.tap(find.text('重新开启'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(appState.watchHistoryEnabled, isTrue);
    expect(find.text('记录已开启'), findsOneWidget);
  });

  test(
    'LocalProxyTunnelBridge.unwrapServerVodProxyLinesInM3u8 unwraps server proxy URLs in playlists and keys',
    () {
      const wrappedM3u8 = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-KEY:METHOD=AES-128,URI="/api/vod/proxy?url=https%3A%2F%2Ftsbfask.com%3A65%2F20261121%2Fkey.key&headers=abc"
#EXTINF:3.0,
/api/vod/proxy?url=https%3A%2F%2Fukzyvod3.ukubf5.com%2F20261121%2Fseg001.ts&headers=abc
''';
      final unwrapped =
          LocalProxyTunnelBridge.unwrapServerVodProxyLinesInM3u8(wrappedM3u8);
      expect(
        unwrapped,
        contains('URI="https://tsbfask.com:65/20261121/key.key"'),
      );
      expect(
        unwrapped,
        contains('https://ukzyvod3.ukubf5.com/20261121/seg001.ts'),
      );
      expect(unwrapped.contains('/api/vod/proxy'), isFalse);
    },
  );

  test(
    'SmbClientService.sniffContainerMimeType detects Matroska/RMVB disguised inside .mp4 files',
    () {
      // Matroska EBML magic header: 1A 45 DF A3 (as in 69号特工詹森之丹麦馅饼 1973 中文字幕.mp4)
      final mkvHeader = Uint8List.fromList([
        0x1A, 0x45, 0xDF, 0xA3, 0xA3, 0x42, 0x86, 0x81,
        0x01, 0x42, 0xF7, 0x81, 0x01, 0x42, 0xF2, 0x81,
      ]);
      expect(
        SmbClientService.sniffContainerMimeType(mkvHeader),
        'video/x-matroska',
      );

      // Standard MP4 ftyp box at offset 4
      final mp4Header = Uint8List.fromList([
        0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
        0x69, 0x73, 0x6F, 0x6D, 0x00, 0x00, 0x02, 0x00,
      ]);
      expect(
        SmbClientService.sniffContainerMimeType(mp4Header),
        'video/mp4',
      );
    },
  );

  testWidgets(
    'TelegramScreen displays official Group Members count in header and renders Group Members drawer tab',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      SharedPreferences.setMockInitialValues({});
      final fakeApi = _FakeTelegramApiClient();
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      fakeApi.serverChats = [
        TelegramChat(
          peer: 'channel:9001',
          title: '流光4K影迷交流群',
          kind: '超级群',
          preview: '大家晚上好',
          date: nowSec,
          unread: 0,
          readOnly: false,
          broadcast: false,
          topMessageId: 503,
        ),
      ];
      fakeApi.serverMessagesByPeer['channel:9001'] = [
        TelegramMessage(
          id: 501,
          date: nowSec - 60,
          sender: '阿杰',
          text: '求推荐一部丹麦老电影',
          outgoing: false,
        ),
        TelegramMessage(
          id: 502,
          date: nowSec - 30,
          sender: '林夕',
          text: '69号特工詹森已经修复可以正常播放了',
          outgoing: false,
        ),
        TelegramMessage(
          id: 503,
          date: nowSec - 10,
          sender: '我',
          text: '收到！',
          outgoing: true,
        ),
      ];

      final appState = AppState(customApi: fakeApi);
      addTearDown(appState.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: VideoPlatformTheme.buildTheme(),
          home: Scaffold(
            body: TelegramScreen(appState: appState),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      // Refresh the chat list so the newly configured group chat replaces any static session cache
      await tester.tap(find.byIcon(Icons.refresh_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      // Header subtitle and action button show 3 group members (阿杰, 林夕, 测试账号/我)
      expect(find.textContaining('3 位成员'), findsWidgets);
      expect(find.text('成员 (3)'), findsOneWidget);

      // Click the '成员 (3)' button in the top header to open the official Group Info & Members panel
      await tester.tap(find.text('成员 (3)'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('群组资料与成员'), findsOneWidget);
      expect(find.text('共享媒体 (0)'), findsOneWidget);
      expect(find.text('阿杰'), findsWidgets);
      expect(find.text('林夕'), findsWidgets);
    },
  );

  testWidgets(
    'PeerMeshScreen renders remote desktop, remote control, file transfer, and chat tabs',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      SharedPreferences.setMockInitialValues({});
      final appState = AppState();
      addTearDown(appState.dispose);

      final node = PeerDeviceNode.fromJson(
        {
          'deviceId': 'peer_test_mac',
          'deviceName': '书房 Mac mini',
          'platform': 'macos',
          'host': '192.168.1.66',
          'port': 18190,
          'isTv': false,
          'activeTabIndex': 0,
          'activeTabName': '影视片库',
          'nowPlayingTitle': '星际穿越 4K',
          'isPlaying': true,
          'supportsDesktopCapture': true,
          'lastSeenAtMs': DateTime.now().millisecondsSinceEpoch,
        },
      );
      expect(node.deviceName, '书房 Mac mini');
      expect(node.platformLabel, 'macOS');
      expect(node.isOnline, isTrue);
      expect(node.connectionModeLabel, '局域网直连');

      final wanNode = node.copyWith(isLanReachable: false);
      expect(wanNode.connectionModeLabel, '跨网云端互通');

      final code1 = PeerMeshService.deriveDefaultPairingCode(
        serverBaseUrl: 'https://jp2.linsionwinwin.top:8081/',
        serverSecret: 'my_secret',
      );
      final code2 = PeerMeshService.deriveDefaultPairingCode(
        serverBaseUrl: 'https://jp2.linsionwinwin.top:8081',
        serverSecret: 'my_secret',
      );
      expect(code1, equals(code2));
      expect(code1, startsWith('LG-'));

      final key32 = Uint8List.fromList(List<int>.generate(32, (i) => i + 7));
      const sampleJson =
          '{"wanKind":"presence","deviceName":"5G 手机客户端","platform":"ios"}';
      final encrypted = PeerMeshService.encryptWanPayload(sampleJson, key32);
      final decrypted = PeerMeshService.decryptWanPayload(encrypted, key32);
      expect(decrypted, equals(sampleJson));

      final wrongKey = Uint8List.fromList(List<int>.generate(32, (i) => i + 9));
      expect(PeerMeshService.decryptWanPayload(encrypted, wrongKey), isNull);

      final chatMsg = PeerChatMessage.fromJson({
        'id': 'msg_1',
        'senderId': 'peer_test_mac',
        'senderName': '书房 Mac mini',
        'senderPlatform': 'macos',
        'targetId': 'all',
        'text': '测试跨端消息与视频链接 https://example.com/live.m3u8',
        'type': 'text',
        'timestampMs': DateTime.now().millisecondsSinceEpoch,
      });
      expect(chatMsg.senderName, '书房 Mac mini');
      expect(chatMsg.text, contains('https://example.com/live.m3u8'));

      await tester.pumpWidget(
        MaterialApp(
          theme: VideoPlatformTheme.buildTheme('midnight_cyan'),
          home: PeerMeshScreen(appState: appState),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('显示桌面 & 远控画面'), findsOneWidget);
      expect(find.text('遥控播控 & 投屏'), findsOneWidget);
      expect(find.text('传输文件 & 远端库'), findsOneWidget);
      expect(find.text('发送消息 & 聊天'), findsOneWidget);

      await tester.tap(find.text('传输文件 & 远端库'));
      await tester.pump();
      expect(find.textContaining('文件传输队列'), findsOneWidget);

      await tester.tap(find.text('发送消息 & 聊天'));
      await tester.pump();
      expect(find.text('发送'), findsOneWidget);
    },
  );

  testWidgets(
    'TelegramScreen resolves quote replies (including off-screen messages & self sender), jumps to quoted message on tap, keeps pinned chats stable, preserves notifications when unfocused, and handles Telegram links in-app',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      SharedPreferences.setMockInitialValues({});
      final fakeApi = _FakeTelegramApiClient();
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      // Configure 2 pinned chats at the top and 1 unpinned active group below them
      fakeApi.serverChats = [
        TelegramChat(
          peer: 'channel:7001',
          title: '置顶群组A',
          kind: '超级群',
          preview: '置顶内容1',
          date: nowSec - 300,
          unread: 0,
          pinned: true,
          topMessageId: 100,
        ),
        TelegramChat(
          peer: 'user:7002',
          title: '置顶好友B',
          kind: '私聊',
          preview: '置顶内容2',
          date: nowSec - 400,
          unread: 0,
          pinned: true,
          topMessageId: 200,
        ),
        TelegramChat(
          peer: 'channel:7003',
          title: '普通讨论群C',
          kind: '超级群',
          preview: '最新讨论',
          date: nowSec - 10,
          unread: 0,
          pinned: false,
          topMessageId: 360,
        ),
      ];

      // Create 55 messages in channel:7003 so message #301 is outside the initial 50-message window (311..360)
      final groupMessages = <TelegramMessage>[
        TelegramMessage(
          id: 301,
          date: nowSec - 600,
          sender: '收藏夹',
          text: '这是很早之前发送的一条原消息内容_301',
          outgoing: true,
        ),
        for (int id = 302; id <= 359; id++)
          TelegramMessage(
            id: id,
            date: nowSec - (365 - id),
            sender: '群友_$id',
            text: '普通历史消息 #$id',
            outgoing: false,
          ),
        // Message #360 replies to #301 (which is older than the initial 50 messages!)
        TelegramMessage(
          id: 360,
          date: nowSec - 2,
          sender: '小王',
          text: '我引用回复一下301号消息',
          outgoing: false,
          replyToId: 301,
          links: const ['https://t.me/c/7003/301'],
        ),
      ];
      fakeApi.serverMessagesByPeer['channel:7003'] = groupMessages;

      final appState = AppState(customApi: fakeApi);
      await appState.telegramNotifications.setSystemNotificationsEnabled(false);
      appState.updateTelegramReadingContext(
        isTelegramViewActive: true,
        isAppForeground: true,
      );
      addTearDown(appState.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: VideoPlatformTheme.buildTheme(),
          home: Scaffold(
            body: TelegramScreen(appState: appState),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      // Refresh so our fakeApi chats replace any static session cache
      await tester.tap(find.byIcon(Icons.refresh_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 1. Verify pinned chats are rendered above unpinned chat
      final pinAPos = tester.getTopLeft(find.text('置顶群组A').first);
      final pinBPos = tester.getTopLeft(find.text('置顶好友B').first);
      final unpinnedCPos = tester.getTopLeft(find.text('普通讨论群C').first);
      expect(pinAPos.dy, lessThan(pinBPos.dy));
      expect(pinBPos.dy, lessThan(unpinnedCPos.dy));

      // 2. Inject a real-time SSE message for unpinned chat 'channel:7003'
      // and verify it NEVER jumps above '置顶群组A' or '置顶好友B'!
      appState.telegramNotifications.injectSseEventForTesting(
        'update',
        jsonEncode({
          'type': 'new_message',
          'account_id': 'default',
          'peer': 'channel:7003',
          'chat_title': '普通讨论群C',
          'new_message': true,
          'notification_muted': false,
          'message_id': 361,
          'message': {
            'id': 361,
            'date': nowSec + 5,
            'sender': '小李',
            'text': '新来的普通群消息',
            'outgoing': false,
          },
        }),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));

      final pinAPosAfter = tester.getTopLeft(find.text('置顶群组A').first);
      final pinBPosAfter = tester.getTopLeft(find.text('置顶好友B').first);
      final unpinnedCPosAfter = tester.getTopLeft(find.text('普通讨论群C').first);
      expect(pinAPosAfter.dy, lessThan(pinBPosAfter.dy));
      expect(pinBPosAfter.dy, lessThan(unpinnedCPosAfter.dy));

      // 3. Open '普通讨论群C' and verify message #360 automatically fetches off-screen replied-to message #301,
      // displays its original content ('这是很早之前发送的一条原消息内容_301'), and resolves outgoing '收藏夹' sender to '回复 测试账号'!
      await tester.tap(find.text('普通讨论群C').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 60));

      expect(find.text('我引用回复一下301号消息'), findsOneWidget);
      expect(
        find.textContaining('这是很早之前发送的一条原消息内容_301'),
        findsWidgets,
      );
      expect(find.text('回复 测试账号'), findsOneWidget);
      expect(find.text('回复 收藏夹'), findsNothing);

      // 4. Tap the reply quote banner -> jumps to and loads/highlights message #301 in the conversation
      final quoteBannerFinder = find.byKey(
        const ValueKey('tg_reply_quote_channel:7003_360_301'),
      );
      expect(quoteBannerFinder, findsOneWidget);
      await tester.tap(quoteBannerFinder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        find.text('这是很早之前发送的一条原消息内容_301'),
        findsWidgets,
      );

      // 5. Simulate window losing focus (`isAppForeground: false`) while 'channel:7003' is open:
      // Incoming SSE message MUST create a notification and MUST NOT be auto-dismissed by _onRealtimeNotificationEvent!
      appState.updateTelegramReadingContext(isAppForeground: false);
      appState.telegramNotifications.injectSseEventForTesting(
        'update',
        jsonEncode({
          'type': 'new_message',
          'account_id': 'default',
          'peer': 'channel:7003',
          'chat_title': '普通讨论群C',
          'new_message': true,
          'notification_muted': false,
          'message_id': 362,
          'message': {
            'id': 362,
            'date': nowSec + 15,
            'sender': '小张',
            'text': '后台窗口收到的重要通知消息',
            'outgoing': false,
            'silent': false,
          },
        }),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        appState.telegramNotifications.totalUnreadNotificationCount,
        greaterThanOrEqualTo(1),
      );
      expect(
        appState.telegramNotifications.pendingNotifications.any(
          (n) =>
              n.peer == 'channel:7003' &&
              n.preview.contains('后台窗口收到的重要通知消息'),
        ),
        isTrue,
      );

      // 6. Verify a single silent message does NOT permanently mute the group for subsequent normal messages
      appState.telegramNotifications.injectSseEventForTesting(
        'update',
        jsonEncode({
          'type': 'new_message',
          'account_id': 'default',
          'peer': 'channel:7003',
          'chat_title': '普通讨论群C',
          'new_message': true,
          'notification_muted': false,
          'message_id': 363,
          'message': {
            'id': 363,
            'date': nowSec + 20,
            'sender': 'Bot',
            'text': '单条静默消息',
            'outgoing': false,
            'silent': true,
          },
        }),
      );
      expect(
        appState.telegramNotifications
            .isServerPeerMuted('default', 'channel:7003'),
        isFalse,
      );

      // Clean up pending highlight timer before ending test
      await tester.pump(const Duration(milliseconds: 2700));
    },
  );

  testWidgets(
    'TelegramScreen renders inline clickable text_links and labeled corresponding link chips for message contents and auto-triggers bot /start parameters',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      SharedPreferences.setMockInitialValues({});
      final fakeApi = _FakeTelegramApiClient();
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      fakeApi.serverChats = [
        TelegramChat(
          peer: 'user:8512861139',
          title: 'fjxgjjbot',
          kind: '机器人',
          preview: '/start',
          date: nowSec - 20,
          unread: 0,
          readOnly: false,
          topMessageId: 801,
        ),
        TelegramChat(
          peer: 'channel:2246105365',
          title: '漫画与短剧资源频道',
          kind: '频道',
          preview: '【Zking】剑星同人Ⅲ',
          date: nowSec - 5,
          unread: 0,
          broadcast: true,
          readOnly: true,
          topMessageId: 17926,
        ),
      ];

      final msg1 = TelegramMessage.fromJson({
        'id': 17925,
        'date': nowSec - 10,
        'sender': '漫画与短剧资源频道',
        'text':
            '【Zking】剑星同人Ⅲ\n标签: #3d #Zking #剑星同人\n\n[点我进入在线观看]\n\nPDF原档下载 (点击跳转)\n\n原档压缩包下载 (点击跳转)',
        'outgoing': false,
        'text_links': [
          {
            'offset': 35,
            'length': 10,
            'url': 'https://telegra.ph/Zking剑星同人--目录-11-25',
          },
          {
            'offset': 47,
            'length': 14,
            'url':
                'https://t.me/fjxgjjbot?start=6ead51bd-2962-4f13-8a80-b12a483eafc3',
          },
          {
            'offset': 63,
            'length': 14,
            'url':
                'https://t.me/fjxgjjbot?start=f8dff6db-3ad1-4398-b490-a001695c0db2',
          },
        ],
        'links': [
          'https://telegra.ph/Zking剑星同人--目录-11-25',
          'https://t.me/fjxgjjbot?start=6ead51bd-2962-4f13-8a80-b12a483eafc3',
          'https://t.me/fjxgjjbot?start=f8dff6db-3ad1-4398-b490-a001695c0db2',
        ],
      });

      final msg2 = TelegramMessage.fromJson({
        'id': 17926,
        'date': nowSec - 5,
        'sender': '漫画与短剧资源频道',
        'text': '母上攻略 第二季5\n\n目录 导航首页\n\n传送门 第二季4\n\n简介：黄豆版\n\n#母上攻略 #AI短剧',
        'outgoing': false,
        'text_links': [
          {
            'offset': 11,
            'length': 2,
            'url': 'https://t.me/jinqinzhiyuan/30',
          },
          {
            'offset': 20,
            'length': 3,
            'url': 'https://t.me/muzizhiyuan/487',
          },
        ],
      });

      expect(msg1.textLinks.length, 3);
      expect(msg2.textLinks.length, 2);

      fakeApi.serverMessagesByPeer['channel:2246105365'] = [msg1, msg2];
      fakeApi.serverMessagesByPeer['user:8512861139'] = [
        TelegramMessage(
          id: 801,
          date: nowSec - 20,
          sender: 'fjxgjjbot',
          text: '欢迎使用资源分发机器人',
          outgoing: false,
        ),
      ];

      final appState = AppState(customApi: fakeApi);
      await appState.telegramNotifications.setSystemNotificationsEnabled(false);
      appState.updateTelegramReadingContext(
        isTelegramViewActive: true,
        isAppForeground: true,
      );
      addTearDown(appState.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: VideoPlatformTheme.buildTheme(),
          home: Scaffold(
            body: TelegramScreen(appState: appState),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byIcon(Icons.refresh_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Open '漫画与短剧资源频道'
      await tester.tap(find.text('漫画与短剧资源频道').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      // 1. Verify labeled link chips show the corresponding content text + target hint
      expect(
        find.textContaining('点我进入在线观看 · telegra.ph'),
        findsOneWidget,
      );
      expect(
        find.textContaining('PDF原档下载 (点击跳转) · @fjxgjjbot'),
        findsOneWidget,
      );
      expect(
        find.textContaining('原档压缩包下载 (点击跳转) · @fjxgjjbot'),
        findsOneWidget,
      );
      expect(
        find.textContaining('目录 导航首页 · @jinqinzhiyuan/30'),
        findsOneWidget,
      );
      expect(
        find.textContaining('传送门 第二季4 · @muzizhiyuan/487'),
        findsOneWidget,
      );

      // 2. Tap 'PDF原档下载 (点击跳转) · @fjxgjjbot' chip -> resolves bot link and automatically sends '/start 6ead51bd-2962-4f13-8a80-b12a483eafc3'
      final pdfBotChip =
          find.byKey(const ValueKey('tg_msg_link_chip_17925_1'));
      expect(pdfBotChip, findsOneWidget);
      await tester.tap(pdfBotChip);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));

      expect(
        fakeApi.lastResolvedLinkUrl,
        'https://t.me/fjxgjjbot?start=6ead51bd-2962-4f13-8a80-b12a483eafc3',
      );
      expect(fakeApi.lastSentPeer, 'user:8512861139');
      expect(
        fakeApi.lastSentText,
        '/start 6ead51bd-2962-4f13-8a80-b12a483eafc3',
      );
      await tester.pump(const Duration(seconds: 8));
    },
  );

  testWidgets(
    'TelegramScreen local file download does not show bottom SnackBar, updates icon to check_circle_rounded, and clicking again opens location instead of re-downloading',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      SharedPreferences.setMockInitialValues({});
      final fakeApi = _FakeTelegramApiClient();
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      fakeApi.serverChats = [
        TelegramChat(
          peer: 'user:1888',
          title: '下载测试会话',
          kind: '私聊',
          preview: '附带测试文件',
          date: nowSec,
          unread: 0,
          readOnly: false,
          topMessageId: 109,
        ),
      ];
      fakeApi.serverMessagesByPeer['user:1888'] = [
        TelegramMessage(
          id: 109,
          date: nowSec,
          sender: '下载测试会话',
          text: '附带测试文件',
          outgoing: false,
          attachment: const TelegramAttachment(
            kind: 'file',
            fileName: 'report_2026.pdf',
            size: 2048,
            mimeType: 'application/pdf',
            url: 'https://example.test/api/telegram/file?id=109',
          ),
        ),
      ];
      final appState = AppState(customApi: fakeApi);
      await appState.telegramNotifications.setSystemNotificationsEnabled(false);
      appState.updateTelegramReadingContext(
        isTelegramViewActive: true,
        isAppForeground: true,
      );
      addTearDown(appState.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: VideoPlatformTheme.buildTheme(),
          home: Scaffold(
            body: TelegramScreen(appState: appState),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byIcon(Icons.refresh_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text('下载测试会话').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Verify the file card 'report_2026.pdf' is visible with its download button
      expect(find.text('report_2026.pdf'), findsOneWidget);
      final dlBtn = find.byTooltip('下载保存到本机电脑');
      expect(dlBtn, findsOneWidget);
      expect(fakeApi.downloadTelegramBytesCount, 0);

      // Tap the local download button
      await tester.tap(dlBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 1. Download executed once
      expect(fakeApi.downloadTelegramBytesCount, 1);

      // 2. No bottom SnackBar toast is popped up
      expect(find.byType(SnackBar), findsNothing);

      // 3. The download icon has switched to the green success check icon (Icons.check_circle_rounded)
      expect(
        find.byKey(const ValueKey('file_l_true_false')),
        findsOneWidget,
      );
      final iconWidget = tester.widget<Icon>(
        find.byKey(const ValueKey('file_l_true_false')),
      );
      expect(iconWidget.icon, Icons.check_circle_rounded);

      // 4. Tapping the success icon button again opens the file location and does NOT re-download
      final openBtn = find.ancestor(
        of: find.byKey(const ValueKey('file_l_true_false')),
        matching: find.byType(IconButton),
      );
      expect(openBtn, findsOneWidget);
      await tester.tap(openBtn);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(fakeApi.downloadTelegramBytesCount, 1);
    },
  );

  testWidgets(
    'TelegramScreen file preview supports common formats including CSV table view, JSON formatting, PDF, Office/Archive, and local byte fallback',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      SharedPreferences.setMockInitialValues({});
      final fakeApi = _FakeTelegramApiClient();
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      fakeApi.serverChats = [
        TelegramChat(
          peer: 'user:1999',
          title: '多格式文件预览会话',
          kind: '私聊',
          preview: '常见文件格式预览测试',
          date: nowSec,
          unread: 0,
          readOnly: false,
          topMessageId: 2203,
        ),
      ];
      fakeApi.serverMessagesByPeer['user:1999'] = [
        TelegramMessage(
          id: 2201,
          date: nowSec - 20,
          sender: '多格式文件预览会话',
          text: '财务报表 CSV',
          outgoing: false,
          attachment: const TelegramAttachment(
            kind: 'file',
            fileName: 'finance_2026.csv',
            size: 1024,
            mimeType: 'text/csv',
            url: 'https://example.test/api/telegram/file?id=2201',
          ),
        ),
        TelegramMessage(
          id: 2202,
          date: nowSec - 10,
          sender: '多格式文件预览会话',
          text: '服务端未解析的 Dart 源码文件',
          outgoing: false,
          attachment: const TelegramAttachment(
            kind: 'file',
            fileName: 'player_engine.dart',
            size: 512,
            mimeType: 'application/octet-stream',
            url: 'https://example.test/api/telegram/file?id=2202',
          ),
        ),
        TelegramMessage(
          id: 2203,
          date: nowSec,
          sender: '多格式文件预览会话',
          text: 'Excel 表格与 PDF 文档',
          outgoing: false,
          attachment: const TelegramAttachment(
            kind: 'file',
            fileName: 'manual_guide.pdf',
            size: 4096,
            mimeType: 'application/pdf',
            url: 'https://example.test/api/telegram/file?id=2203',
          ),
        ),
      ];

      fakeApi.filePreviewsByMsgId[2201] = const TelegramFilePreview(
        name: 'finance_2026.csv',
        size: 1024,
        encoding: 'UTF-8',
        kind: 'text',
        text: '季度,营收,增长率\n2026-Q1,1280万,+18.5%\n2026-Q2,1560万,+21.8%',
      );
      fakeApi.rawFileBytesByMsgId[2202] = Uint8List.fromList(
        utf8.encode('void initPlayerEngine() {\n  print("Hello Telegram Preview");\n}'),
      );
      fakeApi.rawFileBytesByMsgId[2203] = Uint8List.fromList(
        latin1.encode(
          '%PDF-1.4\n1 0 obj << /Type /Page >> endobj\nstream\n(Telegram PDF Inline Preview Text) Tj\nendstream\n',
        ),
      );

      final appState = AppState(customApi: fakeApi);
      await appState.telegramNotifications.setSystemNotificationsEnabled(false);
      appState.updateTelegramReadingContext(
        isTelegramViewActive: true,
        isAppForeground: true,
      );
      addTearDown(appState.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: VideoPlatformTheme.buildTheme(),
          home: Scaffold(
            body: TelegramScreen(appState: appState),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byIcon(Icons.refresh_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text('多格式文件预览会话').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // All 3 files show '点击预览' and preview icon button
      expect(find.text('finance_2026.csv'), findsOneWidget);
      expect(find.text('player_engine.dart'), findsOneWidget);
      expect(find.text('manual_guide.pdf'), findsOneWidget);
      expect(find.byTooltip('在线预览文件内容'), findsNWidgets(3));

      // 1. Tap 'finance_2026.csv' to open interactive DataTable CSV preview
      await tester.tap(find.text('finance_2026.csv'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(DataTable), findsOneWidget);
      expect(find.text('2026-Q1'), findsOneWidget);
      expect(find.text('1560万'), findsOneWidget);
      // Close dialog
      await tester.tap(find.byIcon(Icons.close_rounded).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 2. Tap 'player_engine.dart' -> server throws, client fallback downloads bytes and decodes UTF-8 code
      await tester.tap(find.text('player_engine.dart'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('DART'), findsOneWidget);
      expect(
        find.textContaining('Hello Telegram Preview'),
        findsOneWidget,
      );
      await tester.tap(find.byIcon(Icons.close_rounded).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 3. Tap 'manual_guide.pdf' -> client fallback extracts PDF text stream and page summary
      await tester.tap(find.text('manual_guide.pdf'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('PDF'), findsOneWidget);
      expect(
        find.textContaining('Telegram PDF Inline Preview Text'),
        findsOneWidget,
      );
      await tester.tap(find.byIcon(Icons.close_rounded).last);
      await tester.pump();
    },
  );

  testWidgets(
    'PeerMeshScreen File Transfer always displays 打开接收文件夹 and invokes native pickFiles on 选择文件发送',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});

      const nativeChannel = MethodChannel('com.linsion.m3u8_client/native_utils');
      int pickFilesCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, (MethodCall call) async {
        if (call.method == 'pickFiles') {
          pickFilesCalls++;
          return <Map<String, dynamic>>[];
        }
        if (call.method == 'revealFileInFinder') {
          return true;
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativeChannel, null);
      });

      final appState = AppState();
      addTearDown(appState.dispose);

      // Inject a synthetic LAN peer so the File Transfer tab renders active controls
      PeerMeshService.instance.upsertPeerForTesting(
        PeerDeviceNode(
          deviceId: 'peer_win_test',
          deviceName: 'Windows-Workstation',
          platform: 'windows',
          host: '192.168.1.88',
          port: 9529,
          lastSeenAt: DateTime.now(),
          isLanReachable: true,
        ),
      );
      addTearDown(() {
        PeerMeshService.instance.removePeerForTesting('peer_win_test');
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: VideoPlatformTheme.buildTheme(),
          home: Scaffold(
            body: PeerMeshScreen(appState: appState),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Switch to 传输文件 & 远端库 tab
      await tester.tap(find.text('传输文件 & 远端库'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Verify 打开接收文件夹 button is always present (both top bar and transfer queue header)
      expect(find.text('打开接收文件夹'), findsWidgets);
      expect(find.text('选择文件发送'), findsOneWidget);

      // Tap 选择文件发送 -> should invoke native system file picker ('pickFiles')
      await tester.tap(find.text('选择文件发送'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(pickFilesCalls, 1);
    },
  );

  testWidgets(
    'DownloadsScreen and TelegramScreen display 115云下载 across download entry points',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});

      final fakeApi = _FakeTelegramApiClient();
      fakeApi.serverChats = [
        const TelegramChat(
          peer: 'user:1998',
          title: '115云下载会话',
          kind: '私聊',
          preview: '分享一个文档附件',
          date: 1700001600,
          unread: 0,
          readOnly: false,
          topMessageId: 2301,
        ),
      ];
      fakeApi.serverMessagesByPeer['user:1998'] = [
        const TelegramMessage(
          id: 2301,
          date: 1700001600,
          sender: '115云下载会话',
          outgoing: false,
          text: '分享一个文档附件与直链 https://example.com/video_demo.mp4',
          links: ['https://example.com/video_demo.mp4'],
          attachment: TelegramAttachment(
            kind: 'file',
            name: 'archive_bundle.zip',
            fileName: 'archive_bundle.zip',
            size: 4096,
            mimeType: 'application/zip',
            url: 'https://example.com/archive_bundle.zip',
          ),
        ),
      ];

      final appState = AppState(customApi: fakeApi);
      await appState.telegramNotifications.setSystemNotificationsEnabled(false);
      addTearDown(appState.dispose);

      // 1. Verify DownloadsScreen create task dialog & batch import dialog include 115云下载 / 批量115云下载
      await tester.pumpWidget(
        MaterialApp(
          theme: VideoPlatformTheme.buildTheme(),
          home: Scaffold(
            body: DownloadsScreen(appState: appState),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text('新建 / 嗅探'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('115云下载'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      await tester.tap(find.text('批量导入'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('批量115云下载'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // 2. Verify TelegramScreen file card displays 115云下载 button
      await tester.pumpWidget(
        MaterialApp(
          theme: VideoPlatformTheme.buildTheme(),
          home: Scaffold(
            body: TelegramScreen(appState: appState),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byIcon(Icons.refresh_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text('115云下载会话').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('archive_bundle.zip'), findsOneWidget);
      expect(find.byTooltip('115云下载'), findsWidgets);

      // 3. Verify message link chip has 115云下载 button and clicking it transitions to 已存115 ✓
      final link115Btn = find.byKey(const ValueKey('tg_msg_link_115_2301_0'));
      expect(link115Btn, findsOneWidget);
      expect(
        find.descendant(of: link115Btn, matching: find.text('115云下载')),
        findsOneWidget,
      );

      await tester.tap(link115Btn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.descendant(of: link115Btn, matching: find.text('已存115 ✓')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: link115Btn,
          matching: find.byIcon(Icons.check_circle_rounded),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'PeerMeshScreen Remote Desktop defaults to full system desktop capture with 显示系统桌面 and 自动隐藏远端本应用',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});

      const nativeChannel = MethodChannel('com.linsion.m3u8_client/native_utils');
      int captureCalls = 0;
      int minimizeCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, (MethodCall call) async {
        if (call.method == 'captureDesktopScreenJpeg') {
          captureCalls++;
          return <String, dynamic>{
            'bytes': Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9]),
            'width': 1920,
            'height': 1080,
          };
        }
        if (call.method == 'minimizeAppWindow') {
          minimizeCalls++;
          return true;
        }
        if (call.method == 'checkDesktopPermissions') {
          return <String, dynamic>{
            'screenCapture': true,
            'accessibility': true,
          };
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativeChannel, null);
      });

      final frame = await PeerMeshService.instance.captureLocalScreenFrame(
        mode: 'desktop',
      );
      expect(captureCalls, 1);
      expect(frame, isNotNull);
      expect(frame!.actualMode, 'desktop');
      expect(frame.width, 1920);
      expect(frame.height, 1080);

      final minOk = await PeerMeshService.instance.minimizeLocalAppWindow();
      expect(minOk, isTrue);
      expect(minimizeCalls, 1);

      final appState = AppState();
      addTearDown(appState.dispose);

      PeerMeshService.instance.upsertPeerForTesting(
        PeerDeviceNode(
          deviceId: 'peer_rdp_test',
          deviceName: 'Remote-Desktop-PC',
          platform: 'windows',
          host: '192.168.1.99',
          port: 18190,
          lastSeenAt: DateTime.now(),
          isLanReachable: true,
        ),
      );
      addTearDown(() {
        PeerMeshService.instance.removePeerForTesting('peer_rdp_test');
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: VideoPlatformTheme.buildTheme(),
          home: Scaffold(
            body: PeerMeshScreen(appState: appState),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('显示系统桌面'), findsOneWidget);
      expect(find.text('自动隐藏远端本应用'), findsOneWidget);
      expect(find.text('🖥️ 控制整个系统桌面/设备'), findsOneWidget);
    },
  );

  testWidgets(
    'TelegramScreen supports voice message recording & sending, speech-to-text input, and in-app voice call console',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});

      const nativeChannel = MethodChannel('com.linsion.m3u8_client/native_utils');
      int startRecordCalls = 0;
      int stopRecordCalls = 0;
      int sttCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, (MethodCall call) async {
        if (call.method == 'startVoiceRecording') {
          startRecordCalls++;
          return <String, dynamic>{
            'ok': true,
            'path': '/tmp/voice_test.m4a',
            'mimeType': 'audio/mp4',
          };
        }
        if (call.method == 'stopVoiceRecording') {
          stopRecordCalls++;
          final wavBytes =
              NativeUtilsChannelHub.buildValidPcmWavBytes(durationSeconds: 3);
          return <String, dynamic>{
            'ok': true,
            'path': '/tmp/voice_test.wav',
            'name': 'voice_2026-11-26_09-30-00.wav',
            'mimeType': 'audio/wav',
            'duration': 3,
            'size': wavBytes.length,
            'bytes': wavBytes,
          };
        }
        if (call.method == 'cancelVoiceRecording') {
          return true;
        }
        if (call.method == 'recognizeVoiceToText') {
          sttCalls++;
          return <String, dynamic>{
            'ok': true,
            'text': '你好，这是语音转文字测试内容',
          };
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativeChannel, null);
      });

      final fakeApi = _FakeTelegramApiClient();
      fakeApi.serverChats = [
        const TelegramChat(
          peer: 'user:3001',
          title: '语音通话与语音发送好友',
          kind: '私聊',
          preview: '在线可通话',
          date: 1700002000,
          unread: 0,
          readOnly: false,
          topMessageId: 3101,
        ),
      ];
      fakeApi.serverMessagesByPeer['user:3001'] = [
        const TelegramMessage(
          id: 3101,
          date: 1700002000,
          sender: '语音通话与语音发送好友',
          outgoing: false,
          text: '我们可以语音聊天或直接打语音电话',
        ),
      ];

      final appState = AppState(customApi: fakeApi);
      await appState.telegramNotifications.setSystemNotificationsEnabled(false);
      addTearDown(appState.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: VideoPlatformTheme.buildTheme(),
          home: Scaffold(
            body: TelegramScreen(appState: appState),
          ),
        ),
      );
      for (int i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.tap(find.byIcon(Icons.refresh_rounded).first);
      for (int i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.tap(find.text('语音通话与语音发送好友').first);
      for (int i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // 1. Test Voice-to-Text (`语音转文字`)
      final voiceBtn = find.byKey(const ValueKey('tg_voice_record_btn'));
      expect(voiceBtn, findsOneWidget);
      await tester.tap(voiceBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));

      expect(startRecordCalls, 1);
      expect(
        find.byKey(const ValueKey('tg_voice_recording_bar')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('tg_voice_to_text_btn')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(sttCalls, 1);
      expect(find.text('你好，这是语音转文字测试内容'), findsWidgets);

      // 2. Test Voice Message Recording & Direct Sending (`发送语音`)
      await tester.tap(voiceBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(startRecordCalls, 2);

      await tester.tap(find.byKey(const ValueKey('tg_send_voice_btn')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      expect(stopRecordCalls, 2);

      // 3. Test In-App Telegram Voice Call Console (`发起 Telegram 语音通话`)
      final callBtn = find.byKey(const ValueKey('tg_voice_call_btn'));
      expect(callBtn, findsOneWidget);
      await tester.tap(callBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.byKey(const ValueKey('tg_voice_call_dialog')),
        findsOneWidget,
      );
      expect(find.text('Telegram 实时语音通话'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('tg_call_push_chunk_btn')),
        findsOneWidget,
      );

      // Hang up the call
      await tester.tap(find.byKey(const ValueKey('tg_call_hangup_btn')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const ValueKey('tg_voice_call_dialog')), findsNothing);
    },
  );

  testWidgets(
    'TelegramScreen supports editing already-sent outgoing messages in place (only 1 message, not 2) and @mention autocomplete in compose box',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final fakeApi = _FakeTelegramApiClient();
      fakeApi.nextSentMessageId = 5200;
      fakeApi.serverChats = const [
        TelegramChat(
          peer: 'chat:5001',
          title: '技术讨论群',
          kind: '群组',
          preview: '大家下午好',
          date: 1700003000,
          unread: 0,
          readOnly: false,
          topMessageId: 5102,
        ),
      ];
      fakeApi.serverMessagesByPeer['chat:5001'] = [
        const TelegramMessage(
          id: 5101,
          date: 1700002900,
          sender: '张工程师',
          outgoing: false,
          text: '请问新版客户端什么时候发布？',
        ),
        const TelegramMessage(
          id: 5102,
          date: 1700003000,
          sender: '我',
          outgoing: true,
          text: '预计今天下午三点发布初版',
        ),
      ];

      final appState = AppState(customApi: fakeApi);
      await appState.telegramNotifications.setSystemNotificationsEnabled(false);
      addTearDown(appState.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: VideoPlatformTheme.buildTheme(),
          home: Scaffold(
            body: TelegramScreen(appState: appState),
          ),
        ),
      );
      for (int i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.tap(find.byIcon(Icons.refresh_rounded).first);
      for (int i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.tap(find.text('技术讨论群').first);
      for (int i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text('预计今天下午三点发布初版'), findsWidgets);

      // 1. Click "编辑" on the already-sent outgoing message (id: 5102)
      final editBtn = find.byKey(const ValueKey('tg_msg_edit_btn_5102'));
      expect(editBtn, findsOneWidget);
      await tester.tap(editBtn);
      await tester.pump();

      // Verify editing banner appears and compose box is pre-filled with original message text
      expect(
        find.byKey(const ValueKey('tg_editing_message_banner')),
        findsOneWidget,
      );
      final composeField = find.byKey(const ValueKey('tg_compose_text_field'));
      expect(composeField, findsOneWidget);
      expect(
        tester.widget<TextField>(composeField).controller?.text,
        '预计今天下午三点发布初版',
      );

      // Modify the text and click the Send / Save Edit button
      await tester.enterText(composeField, '预计今天下午五点正式发布新版');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tg_send_message_btn')));
      for (int i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Verify the editing banner closed, old message 5102 was revoked, and ONLY 1 updated message is shown (old text is gone!)
      expect(
        find.byKey(const ValueKey('tg_editing_message_banner')),
        findsNothing,
      );
      expect(fakeApi.deletedMessageIds, contains(5102));
      expect(find.text('预计今天下午三点发布初版'), findsNothing);
      expect(find.text('预计今天下午五点正式发布新版'), findsWidgets);
      expect(find.text('已编辑'), findsOneWidget);

      // 2. Test @mention autocomplete in the compose input box
      await tester.tap(find.byKey(const ValueKey('tg_compose_mention_btn')));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('tg_mention_autocomplete_bar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tg_mention_item_张工程师')),
        findsOneWidget,
      );

      // Select "@张工程师" from the mention popup
      await tester.tap(find.byKey(const ValueKey('tg_mention_item_张工程师')));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('tg_mention_autocomplete_bar')),
        findsNothing,
      );
      expect(
        tester.widget<TextField>(composeField).controller?.text,
        '@张工程师 ',
      );

      // Also test typing "@张" directly in the input box triggers @mention autocomplete
      await tester.enterText(composeField, '你好 @张');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('tg_mention_autocomplete_bar')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('tg_mention_item_张工程师')));
      await tester.pump();
      expect(
        tester.widget<TextField>(composeField).controller?.text,
        '你好 @张工程师 ',
      );
    },
  );

  testWidgets(
    'TelegramScreen renders AnimatedSticker.tgs Lottie vector stickers, interactive preview dialog, and compose TGS sticker picker',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final fakeApi = _FakeTelegramApiClient();
      final presetTgsBytes = TelegramBuiltinTgsStickers.presets.first.tgsBytes;
      final parsedComp =
          TelegramTgsLottieComposition.tryParseBytes(presetTgsBytes);
      expect(parsedComp, isNotNull);
      expect(parsedComp!.hasDrawableShapes, isTrue);

      fakeApi.rawFileBytesByMsgId[6101] = presetTgsBytes;
      fakeApi.serverChats = const [
        TelegramChat(
          peer: 'user:6001',
          title: '表情包测试好友',
          kind: '私聊',
          preview: '[动态贴纸]',
          date: 1700004000,
          unread: 0,
          readOnly: false,
          topMessageId: 6101,
        ),
      ];
      fakeApi.serverMessagesByPeer['user:6001'] = [
        TelegramMessage(
          id: 6101,
          date: 1700004000,
          sender: '表情包测试好友',
          outgoing: false,
          text: '',
          attachment: TelegramAttachment(
            kind: 'file',
            name: 'AnimatedSticker.tgs',
            fileName: 'AnimatedSticker.tgs',
            mimeType: 'application/x-tgsticker',
            size: presetTgsBytes.length,
            url: 'https://example.test/api/telegram/file?message_id=6101',
          ),
        ),
      ];

      final appState = AppState(customApi: fakeApi);
      await appState.telegramNotifications.setSystemNotificationsEnabled(false);
      addTearDown(appState.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: VideoPlatformTheme.buildTheme(),
          home: Scaffold(
            body: TelegramScreen(appState: appState),
          ),
        ),
      );
      for (int i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.tap(find.byIcon(Icons.refresh_rounded).first);
      for (int i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.tap(find.text('表情包测试好友').first);
      for (int i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // 1. Verify AnimatedSticker.tgs renders as an animated sticker card in the chat bubble
      expect(
        find.byKey(const ValueKey('tg_sticker_card_6101')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tg_animated_sticker_view_6101')),
        findsOneWidget,
      );
      expect(find.text('动态贴纸 · AnimatedSticker.tgs'), findsOneWidget);

      // 2. Tap zoom button to open the interactive AnimatedSticker.tgs preview dialog
      await tester.tap(find.byKey(const ValueKey('tg_sticker_zoom_btn_6101')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      expect(
        find.byKey(const ValueKey('tg_sticker_preview_dialog')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tg_sticker_dialog_play_pause_btn')),
        findsOneWidget,
      );

      // Close preview dialog
      await tester.tap(find.byIcon(Icons.close_rounded).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.byKey(const ValueKey('tg_sticker_preview_dialog')),
        findsNothing,
      );

      // 3. Open the Emoji & Sticker Panel and switch to the "✨ 贴纸" (AnimatedSticker.tgs) tab
      await tester.tap(
        find.byIcon(Icons.sentiment_satisfied_alt_rounded).first,
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('tg_emoji_tab_tgs_stickers')),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('tg_animated_stickers_grid')),
        findsOneWidget,
      );
      final thumbsUpPreset = find.byKey(
        const ValueKey('tg_builtin_tgs_sticker_thumbs_up'),
      );
      expect(thumbsUpPreset, findsOneWidget);

      // Tap the preset animated TGS sticker to send it
      await tester.tap(thumbsUpPreset);
      for (int i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(fakeApi.sendCompleted, isTrue);
    },
  );
}

class _FakePlayerStream implements PlayerStream {
  _FakePlayerStream(this.volume);

  @override
  final Stream<double> volume;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMediaKitPlayer implements Player {
  _FakeMediaKitPlayer({double initialVolume = 100.0})
      : currentVolume = initialVolume {
    _state = PlayerState(volume: initialVolume);
    _stream = _FakePlayerStream(_volumeController.stream);
  }

  double currentVolume;
  late PlayerState _state;
  late final PlayerStream _stream;
  final StreamController<double> _volumeController =
      StreamController<double>.broadcast();

  @override
  PlayerState get state => _state;

  @override
  PlayerStream get stream => _stream;

  @override
  PlatformPlayer? get platform => null;

  @override
  Future<void> setVolume(double volume) async {
    currentVolume = volume;
    _state = _state.copyWith(volume: volume);
    if (!_volumeController.isClosed) {
      _volumeController.add(volume);
    }
  }

  @override
  Future<void> dispose() async {
    await _volumeController.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
