import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3u8_client/models/models.dart';
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
}
