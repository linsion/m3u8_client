import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:m3u8_client/services/local_115_direct_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  SharedPreferences.setMockInitialValues({});
  final service = Local115DirectService.instance;

  Future<HttpClientResponse> fetch(
    HttpClient client,
    String url, {
    String method = 'GET',
    String? range,
  }) async {
    final request = await client.openUrl(method, Uri.parse(url));
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    return request.close().timeout(const Duration(seconds: 5));
  }

  Future<List<int>> collect(HttpClientResponse response) =>
      response.expand((chunk) => chunk).toList();

  test(
    '115 relays independent seek requests for a WAV larger than 50 MiB',
    () async {
      const mib = 1024 * 1024;
      const size = 60 * mib + 44;
      const firstStart = 51 * mib + 13;
      const tailLength = 4096;
      final firstInFlight = Completer<void>();
      final continueFirst = Completer<void>();
      final upstreamStarts = <int>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        if (!continueFirst.isCompleted) continueFirst.complete();
        await server.close(force: true);
      });
      server.listen((request) async {
        final spec = request.headers.value(HttpHeaders.rangeHeader)!;
        final bounds = spec.substring(6).split('-');
        final start = int.parse(bounds.first);
        final end = int.parse(bounds.last);
        upstreamStarts.add(start);
        if (start == firstStart) {
          firstInFlight.complete();
          await continueFirst.future;
        }
        final data = Uint8List.fromList(
          List.generate(end - start + 1, (index) => (start + index) % 251),
        );
        if (start == 0) {
          data.setRange(0, 4, ascii.encode('RIFF'));
          data.setRange(8, 16, ascii.encode('WAVEfmt '));
          data.setRange(36, 40, ascii.encode('data'));
          final wav = ByteData.sublistView(data);
          wav.setUint32(4, size - 8, Endian.little);
          wav.setUint32(16, 16, Endian.little);
          wav.setUint32(40, size - 44, Endian.little);
        }
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$size',
        );
        request.response.contentLength = data.length;
        request.response.add(data);
        await request.response.close();
      });
      final url = await service.wrapWithLocal115HeaderProxy(
        'http://127.0.0.1:${server.port}/audio',
        {},
        extHint: '.wav',
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final first = fetch(
        client,
        url,
        range: 'bytes=$firstStart-${firstStart + 31}',
      );
      await firstInFlight.future.timeout(const Duration(seconds: 3));
      final tail = await fetch(client, url, range: 'bytes=-$tailLength');
      expect(tail.statusCode, HttpStatus.partialContent);
      expect(tail.headers.contentType?.mimeType, 'audio/wav');
      expect(
        tail.headers.value(HttpHeaders.contentRangeHeader),
        'bytes ${size - tailLength}-${size - 1}/$size',
      );
      expect(
        await collect(tail),
        List.generate(tailLength, (i) => (size - tailLength + i) % 251),
      );
      continueFirst.complete();
      expect(
        await collect(await first),
        List.generate(32, (i) => (firstStart + i) % 251),
      );
      expect(upstreamStarts, [0, firstStart, size - tailLength]);

      final head = await fetch(client, url, method: 'HEAD', range: 'bytes=-8');
      expect(head.contentLength, 8);
      expect(await collect(head), isEmpty);
      final invalid = await fetch(client, url, range: 'bytes=$size-');
      expect(invalid.statusCode, HttpStatus.requestedRangeNotSatisfiable);
      expect(
        invalid.headers.value(HttpHeaders.contentRangeHeader),
        'bytes */$size',
      );
      await invalid.drain<void>();
    },
  );

  test('115 can serve a tail read when the source ignores Range', () async {
    final original = Uint8List.fromList(
      List.generate(300 * 1024, (index) => index % 251),
    );
    final seenRanges = <String?>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      seenRanges.add(request.headers.value(HttpHeaders.rangeHeader));
      request.response.contentLength = original.length;
      request.response.add(original);
      await request.response.close();
    });
    final url = await service.wrapWithLocal115HeaderProxy(
      'http://127.0.0.1:${server.port}/source',
      {},
      extHint: '.mkv',
    );
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final tail = await fetch(client, url, range: 'bytes=-32');
    expect(tail.statusCode, HttpStatus.partialContent);
    expect(await collect(tail), original.sublist(original.length - 32));
    expect(seenRanges, ['bytes=0-262143', null]);
  });

  test(
    '115 HLS rewrites redirected master, audio and ranged init resources',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final fetched = <String>[];
      server.listen((request) async {
        final path = request.uri.path;
        fetched.add(path);
        final response = request.response;
        if (path == '/play') {
          await response.redirect(Uri.parse('/streams/master'));
          return;
        }
        if (path == '/streams/master') {
          response.write(
            '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="main",URI="audio"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=300000,AUDIO="audio"\n'
            'video\n',
          );
        } else if (path == '/streams/audio' || path == '/streams/video') {
          response.write(
            '#EXTM3U\n'
            '#EXT-X-MAP:URI="blob",BYTERANGE="4@4"\n'
            '#EXTINF:3,\n'
            'blob\n'
            '#EXT-X-ENDLIST\n',
          );
        } else if (path == '/streams/blob' &&
            request.headers.value(HttpHeaders.rangeHeader) == 'bytes=4-7') {
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 4-7/12');
          response.contentLength = 4;
          response.add([4, 5, 6, 7]);
        } else {
          response.statusCode = HttpStatus.notFound;
        }
        await response.close();
      });
      final url = await service.wrapWithLocal115HeaderProxy(
        'http://127.0.0.1:${server.port}/play',
        {},
        extHint: '.m3u8',
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      Future<String> getPlaylist(String url) async =>
          utf8.decode(await collect(await fetch(client, url)));
      final master = await getPlaylist(url);
      final audioUrl = RegExp(r'URI="([^"]+)"').firstMatch(master)![1]!;
      final videoUrl = master.trimRight().split('\n').last;
      expect(Uri.parse(audioUrl).path, endsWith('.m3u8'));
      expect(Uri.parse(videoUrl).path, endsWith('.m3u8'));
      expect(await getPlaylist(audioUrl), contains('#EXTINF:3'));
      final video = await getPlaylist(videoUrl);
      final initUrl = RegExp(r'URI="([^"]+)"').firstMatch(video)![1]!;
      final init = await fetch(client, initUrl, range: 'bytes=4-7');
      expect(init.statusCode, HttpStatus.partialContent);
      expect(
        init.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 4-7/12',
      );
      expect(await collect(init), [4, 5, 6, 7]);
      expect(fetched, [
        '/play',
        '/streams/master',
        '/streams/audio',
        '/streams/video',
        '/streams/blob',
      ]);
    },
  );

  test(
    'resetAfterBackground clears stale header cache and verifies loopback proxy health',
    () async {
      var probeCount = 0;
      final payload = Uint8List.fromList(
        List.generate(4096, (index) => (index + 7) % 251),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        probeCount++;
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 0-${payload.length - 1}/${payload.length}',
        );
        request.response.contentLength = payload.length;
        request.response.add(payload);
        await request.response.close();
      });

      final remoteUrl = 'http://127.0.0.1:${server.port}/track.flac';
      final proxyUrl1 = await service.wrapWithLocal115HeaderProxy(
        remoteUrl,
        const {},
        extHint: '.flac',
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final resp1 = await fetch(client, proxyUrl1, range: 'bytes=0-31');
      expect(resp1.statusCode, HttpStatus.partialContent);
      expect(await collect(resp1), payload.sublist(0, 32));
      expect(probeCount, 1);

      // Simulate returning from long background inactivity
      service.resetAfterBackground();
      expect(service.getCachedRawHeaderBytes(remoteUrl), isNull);

      final proxyUrl2 = await service.wrapWithLocal115HeaderProxy(
        remoteUrl,
        const {},
        extHint: '.flac',
      );
      final resp2 = await fetch(client, proxyUrl2, range: 'bytes=0-31');
      expect(resp2.statusCode, HttpStatus.partialContent);
      expect(await collect(resp2), payload.sublist(0, 32));
      expect(probeCount, 2);
    },
  );
}
