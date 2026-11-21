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
    final tracks = [_track('Blue Sky'), _track('Evening Walk')];
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
      'Evening Walk.mp3',
    ]);

    await tester.tap(find.text('播放列表'));
    await tester.pumpAndSettle();
    expect(find.text('Blue Sky'), findsWidgets);
    expect(find.text('Evening Walk'), findsOneWidget);

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
      'Evening Walk.mp3',
    ]);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('m3u8_active_music_playlist_id_v1'), created.id);
    final saved =
        jsonDecode(prefs.getString('m3u8_saved_music_playlists_v1')!) as List;
    expect(saved.last['tracks'], isEmpty);

    await controller.switchAndPlayPlaylist('default_playlist', autoPlay: false);
    await tester.pumpAndSettle();
    expect(controller.queue, hasLength(2));

    await tester.tap(find.byTooltip('曲目操作').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('从列表移除'));
    await tester.pumpAndSettle();
    expect(controller.queue.single.name, 'Blue Sky.mp3');

    await controller.switchAndPlayPlaylist(created.id);
    await controller.refreshAvailableMounts();
    await tester.pumpAndSettle();
    expect(controller.activePlaylistId, created.id);
    expect(controller.queue, isEmpty);
    expect(controller.savedPlaylists.first.tracks.single.name, 'Blue Sky.mp3');
    expect(tester.takeException(), isNull);
  });
}
