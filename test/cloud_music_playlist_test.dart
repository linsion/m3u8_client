import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3u8_client/models/models.dart';
import 'package:m3u8_client/state/app_state.dart';
import 'package:m3u8_client/ui/widgets/cloud_music_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

FileEntry _track(String name) => FileEntry(
  name: '$name.mp3',
  path: '/$name.mp3',
  size: 1024,
  modTime: '',
  isDir: false,
  isMp4: false,
  ext: '.mp3',
);

void main() {
  testWidgets('mobile playlists support search and independent empty lists', (
    tester,
  ) async {
    final tracks = [_track('Blue Sky'), _track('Artist - Evening Walk')];
    SharedPreferences.setMockInitialValues({
      'm3u8_default_music_queue_v1': jsonEncode(
        tracks.map((track) => track.toJson()).toList(),
      ),
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);

    final controller = CloudMusicController();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: CloudMusicHallBody(
            controller: controller,
            isStandalonePage: true,
          ),
        ),
        builder:
            (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.25)),
              child: child!,
            ),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.queue.map((track) => track.name), [
      'Blue Sky.mp3',
      'Artist - Evening Walk.mp3',
    ]);

    await tester.tap(find.text('播放列表'));
    await tester.pumpAndSettle();
    expect(find.text('Blue Sky'), findsWidgets);
    expect(find.text('Evening Walk'), findsOneWidget);
    expect(find.text('02'), findsOneWidget);
    expect(find.text('MP3'), findsNWidgets(2));
    expect(
      find.text('Artist · 流光服务端 · ${tracks.last.formattedSize}'),
      findsOneWidget,
    );

    tester.view.viewInsets = const FakeViewPadding(bottom: 285);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'evening');
    await tester.pumpAndSettle();
    expect(find.text('Evening Walk'), findsOneWidget);
    expect(find.text('Blue Sky'), findsNothing);

    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();
    expect(find.text('Blue Sky'), findsWidgets);

    await tester.tap(find.text('列表管理'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    await tester.tap(find.text('新建列表'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '  通勤音乐  ');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    final created = controller.activePlaylist!;
    expect(created.name, '通勤音乐');
    expect(controller.queue, isEmpty);
    expect(controller.currentTrack, isNull);
    expect(find.text('此列表还没有歌曲'), findsOneWidget);
    expect(find.text('添加音乐'), findsOneWidget);
    expect(controller.savedPlaylists.first.tracks.map((track) => track.name), [
      'Blue Sky.mp3',
      'Artist - Evening Walk.mp3',
    ]);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('m3u8_active_music_playlist_id_v1'), created.id);
    final saved =
        jsonDecode(prefs.getString('m3u8_saved_music_playlists_v1')!) as List;
    expect(saved.last['tracks'], isEmpty);

    await controller.switchAndPlayPlaylist('default_playlist', autoPlay: false);
    await tester.pumpAndSettle();
    expect(controller.queue, hasLength(2));

    await tester.tap(find.byTooltip('从队列移除').last);
    await tester.pumpAndSettle();
    expect(controller.queue.single.name, 'Blue Sky.mp3');

    await controller.switchAndPlayPlaylist(created.id);
    await controller.refreshAvailableMounts();
    await tester.pumpAndSettle();
    expect(controller.activePlaylistId, created.id);
    expect(controller.queue, isEmpty);
    expect(controller.savedPlaylists.first.tracks.single.name, 'Blue Sky.mp3');

    // Verify saved playlist playback after long background inactivity
    var resolveCount = 0;
    CloudMusicController(
      endpointResolver: (entry) async {
        resolveCount++;
        return (
          url: 'file:///tmp/test_${resolveCount}_${entry.name}',
          headers: const <String, String>{},
          subtitle: '测试音源 #$resolveCount',
        );
      },
    );

    await controller.switchAndPlayPlaylist(
      'default_playlist',
      autoPlay: false,
    );
    await tester.pumpAndSettle();
    expect(controller.queue.single.name, 'Blue Sky.mp3');

    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    controller.markResumedFromBackground(
      backgroundDuration: const Duration(minutes: 30),
    );
    expect(controller.needsFreshOpenAfterBackground, isTrue);

    // 1. Tapping the already-active saved playlist in 列表管理 after background resume must trigger playback
    final beforeTapCount = resolveCount;
    await tester.tap(find.text('列表管理'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('默认播放列表'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(resolveCount, greaterThan(beforeTapCount));
    expect(controller.activeStreamUrl, contains('Blue Sky.mp3'));

    // 2. Simulate another long background period, then tap the current track in the saved playlist queue
    final beforeQueueTapCount = resolveCount;
    final previousStreamUrl = controller.activeStreamUrl;
    controller.markResumedFromBackground(
      backgroundDuration: const Duration(minutes: 45),
    );
    expect(controller.needsFreshOpenAfterBackground, isTrue);

    await controller.playQueueIndex(0);
    await tester.pump(const Duration(milliseconds: 200));
    expect(resolveCount, greaterThan(beforeQueueTapCount));
    expect(controller.needsFreshOpenAfterBackground, isFalse);
    expect(controller.activeStreamUrl, isNotEmpty);
    expect(controller.activeStreamUrl, isNot(previousStreamUrl));

    await controller.stopAndClose();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Music module searches specified directory by artist or keywords to create playlist and AI categorizes directory tracks into playlists with configured AI API key',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final appState = AppState();
      addTearDown(appState.dispose);

      // 1. Verify setting and persisting AI API Key in AppState (as used by SettingsScreen)
      await appState.saveAiConfig(
        provider: 'deepseek',
        apiKey: 'sk-test-music-ai-key-123456',
        baseUrl: 'https://api.deepseek.com/v1',
        model: 'deepseek-chat',
      );
      expect(appState.hasAiApiKey, isTrue);
      expect(appState.aiApiKey, 'sk-test-music-ai-key-123456');
      expect(appState.effectiveAiProvider, 'deepseek');
      expect(appState.effectiveAiModel, 'deepseek-chat');

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('m3u8_ai_api_key_v1'),
        'sk-test-music-ai-key-123456',
      );

      // 2. Set up fake directory tree for a specified music directory (/华语精选)
      final controller = CloudMusicController(appState: appState);
      controller.customDirectoryLister = (mount, path) async {
        if (path == '/华语精选') {
          return const [
            FileEntry(
              name: '周杰伦',
              path: '/华语精选/周杰伦',
              size: 0,
              modTime: '',
              isDir: true,
              isMp4: false,
              ext: '',
            ),
            FileEntry(
              name: '陈奕迅 - 富士山下 (粤语经典).flac',
              path: '/华语精选/陈奕迅 - 富士山下 (粤语经典).flac',
              size: 32000000,
              modTime: '',
              isDir: false,
              isMp4: false,
              ext: '.flac',
            ),
            FileEntry(
              name: '陈奕迅 - 浮夸 (粤语Live).flac',
              path: '/华语精选/陈奕迅 - 浮夸 (粤语Live).flac',
              size: 35000000,
              modTime: '',
              isDir: false,
              isMp4: false,
              ext: '.flac',
            ),
            FileEntry(
              name: 'Beyond - 海阔天空 (粤语摇滚).flac',
              path: '/华语精选/Beyond - 海阔天空 (粤语摇滚).flac',
              size: 38000000,
              modTime: '',
              isDir: false,
              isMp4: false,
              ext: '.flac',
            ),
          ];
        }
        if (path == '/华语精选/周杰伦') {
          return const [
            FileEntry(
              name: '01. 七里香.flac',
              path: '/华语精选/周杰伦/01. 七里香.flac',
              size: 29000000,
              modTime: '',
              isDir: false,
              isMp4: false,
              ext: '.flac',
            ),
            FileEntry(
              name: '02. 夜曲.flac',
              path: '/华语精选/周杰伦/02. 夜曲.flac',
              size: 27000000,
              modTime: '',
              isDir: false,
              isMp4: false,
              ext: '.flac',
            ),
          ];
        }
        return const [];
      };
      addTearDown(() {
        controller.customDirectoryLister = null;
        controller.customAiCompletionHandler = null;
      });

      const targetDir = SavedMusicFolderItem(
        mountId: 'builtin_server',
        mountName: '流光服务端',
        sourceKind: StorageSourceKind.server,
        path: '/华语精选',
        title: '华语精选',
      );

      // 3. Test searching the specified directory by artist name ('周杰伦') and creating a new playlist
      final jayPlaylist = await controller.searchSourcesAndCreatePlaylist(
        sources: const [targetDir],
        query: '周杰伦',
        playlistName: '周杰伦专场',
        autoPlay: false,
      );
      expect(jayPlaylist, isNotNull);
      expect(jayPlaylist!.name, '周杰伦专场');
      expect(
        jayPlaylist.tracks.map((t) => t.name).toList(),
        ['01. 七里香.flac', '02. 夜曲.flac'],
      );
      expect(controller.activePlaylistId, jayPlaylist.id);

      // 4. Test searching the specified directory by keyword ('粤语') via CloudMusicSmartPlaylistDialog UI
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: CloudMusicSmartPlaylistDialog(
              controller: controller,
              initialSources: const [targetDir],
              initialTab: 0,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, '输入指定人名 (歌手) 或关键词'),
        '粤语',
      );
      await tester.pump();
      await tester.tap(find.text('在指定目录中查找歌曲'));
      await tester.pumpAndSettle();

      // Should find the 3 Cantonese songs in /华语精选
      expect(find.textContaining('共找到 3 首匹配歌曲'), findsOneWidget);
      expect(find.text('富士山下 (粤语经典)'), findsOneWidget);
      expect(find.text('浮夸 (粤语Live)'), findsOneWidget);
      expect(find.text('海阔天空 (粤语摇滚)'), findsOneWidget);

      await tester.tap(find.text('新建播放列表 (3 首)'));
      await tester.pumpAndSettle();

      expect(controller.activePlaylistName, '粤语');
      expect(controller.queue.length, 3);

      // 5. Test AI analysis on the specified directory to automatically categorize and generate playlists
      String capturedAiPrompt = '';
      controller.customAiCompletionHandler = (prompt) async {
        capturedAiPrompt = prompt;
        return '''
```json
{
  "playlists": [
    {
      "name": "AI · 粤语经典金曲",
      "description": "陈奕迅与Beyond粤语代表作",
      "track_ids": [0, 1, 2]
    },
    {
      "name": "AI · 周杰伦华语流行",
      "description": "周杰伦经典主打歌",
      "track_ids": [3, 4]
    }
  ]
}
```
''';
      };

      final aiCreated = await controller.analyzeSourcesAndCreatePlaylistsWithAi(
        sources: const [targetDir],
        dimension: 'genre',
        customInstruction: '按粤语经典与周杰伦华语流行分类',
      );
      expect(capturedAiPrompt, contains('按粤语经典与周杰伦华语流行分类'));
      expect(aiCreated.length, 2);
      expect(aiCreated[0].name, 'AI · 粤语经典金曲');
      expect(aiCreated[0].tracks.length, 3);
      expect(aiCreated[1].name, 'AI · 周杰伦华语流行');
      expect(aiCreated[1].tracks.length, 2);
    },
  );

  testWidgets(
    'Mobile (375x812) CloudMusicSmartPlaylistDialog renders both Keyword and AI tabs without layout overflow',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final appState = AppState();
      addTearDown(appState.dispose);

      await appState.saveAiConfig(
        provider: 'deepseek',
        apiKey: 'sk-mobile-test-key',
        baseUrl: 'https://api.deepseek.com/v1',
        model: 'deepseek-chat',
      );

      final controller = CloudMusicController(appState: appState);
      controller.customDirectoryLister = (mount, path) async {
        return const [
          FileEntry(
            name: '陈奕迅 - 富士山下.flac',
            path: '/华语精选/陈奕迅 - 富士山下.flac',
            size: 32000000,
            modTime: '',
            isDir: false,
            isMp4: false,
            ext: '.flac',
          ),
          FileEntry(
            name: '周杰伦 - 七里香.flac',
            path: '/华语精选/周杰伦 - 七里香.flac',
            size: 29000000,
            modTime: '',
            isDir: false,
            isMp4: false,
            ext: '.flac',
          ),
        ];
      };
      controller.customAiCompletionHandler = (prompt) async {
        return '''
{
  "playlists": [
    {
      "name": "AI · 华语金曲精选",
      "description": "陈奕迅与周杰伦代表作",
      "track_ids": [0, 1]
    }
  ]
}
''';
      };
      addTearDown(() {
        controller.customDirectoryLister = null;
        controller.customAiCompletionHandler = null;
      });

      const targetDir = SavedMusicFolderItem(
        mountId: 'builtin_server',
        mountName: '流光服务端',
        sourceKind: StorageSourceKind.server,
        path: '/华语精选',
        title: '华语精选',
      );

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(375, 812);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: CloudMusicSmartPlaylistDialog(
              controller: controller,
              initialSources: const [targetDir],
              initialTab: 1,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Toggle inline AI API Key configuration panel on mobile screen
      await tester.tap(find.text('配置 Key'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Run AI preview analysis on mobile screen
      await tester.tap(find.text('AI 分析目录并预览分类'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('AI · 华语金曲精选'), findsOneWidget);

      // Switch to Tab 0 (搜人名/关键词建表) on mobile screen
      await tester.tap(find.text('搜人名/关键词建表'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
