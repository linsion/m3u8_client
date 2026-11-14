import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3u8_client/main.dart';
import 'package:m3u8_client/models/models.dart';
import 'package:m3u8_client/services/api_client.dart';
import 'package:m3u8_client/services/m3u8_ad_remover.dart';
import 'package:m3u8_client/services/proxy_routing_service.dart';
import 'package:m3u8_client/services/telegram_notification_service.dart';
import 'package:m3u8_client/state/app_state.dart';
import 'package:m3u8_client/ui/screens/proxy_server_screen.dart';
import 'package:m3u8_client/ui/theme.dart';
import 'package:m3u8_client/ui/widgets/video_download_speed_badge.dart';
import 'package:m3u8_client/ui/widgets/video_proxy_node_selector.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

void main() {
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
    HttpOverrides.global = null;
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
    socksServer.listen((Socket client) async {
      final rx = <int>[];
      var stage = 0;
      Socket? upstream;
      client.listen((chunk) async {
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
            upstream = await Socket.connect(host, port);
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
      });
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

    final svc = ProxyRoutingService();
    await svc.initialize();
    await svc.setProxyEnabled(false); // Even in Direct mode, VOD M3U8 uses multi-connection relay

    final m3u8Url = 'http://127.0.0.1:$originPort/vod/index.m3u8';
    final relayedUrl = await svc.resolveProxiedStreamUrl(
      RequestScenario.vodStream,
      m3u8Url,
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
      if (svc.localBridgePrefetchedSegmentCount >= 4) break;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(svc.localBridgePrefetchedSegmentCount, greaterThanOrEqualTo(4));
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
    svc.dispose();
    await originServer.close(force: true);
  });

  test('resolveVodPlayback resolves direct TVBox m3u8 in 0ms and probeVodStreamPlayableFast detects playability',
      () async {
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
}
