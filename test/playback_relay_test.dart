import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:m3u8_client/services/proxy_routing_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const blockSize = 2 * 1024 * 1024;
  final loopback = InternetAddress.loopbackIPv4;

  Future<HttpClientResponse> request(
    HttpClient client,
    Uri url, {
    String method = 'GET',
    String? range,
  }) async {
    final req = await client.openUrl(method, url);
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    return req.close().timeout(const Duration(seconds: 10));
  }

  Future<List<int>> bytes(HttpClientResponse response) =>
      response.expand((chunk) => chunk).toList();

  test(
    'Telegram relay resumes a truncated block and handles suffix, HEAD and invalid ranges',
    () async {
      final origin = await HttpServer.bind(loopback, 0);
      final seenStarts = <int>[];
      const size = 180000;
      const cutoff = 75000;
      origin.listen((req) async {
        final range = req.headers.value(HttpHeaders.rangeHeader)!;
        final start = int.parse(range.split('=')[1].split('-')[0]);
        seenStarts.add(start);
        final length = size - start;
        final socket = await req.response.detachSocket(writeHeaders: false);
        socket.write(
          'HTTP/1.1 206 Partial Content\r\n'
          'Content-Type: video/mp4\r\n'
          'Content-Length: $length\r\n'
          'Content-Range: bytes $start-${size - 1}/$size\r\n'
          'Connection: close\r\n\r\n',
        );
        final end = start == 0 && seenStarts.length == 1 ? cutoff : size;
        socket.add(List<int>.generate(end - start, (i) => (i + start) % 251));
        await socket.flush();
        await socket.close();
        socket.destroy();
      });
      addTearDown(() => origin.close(force: true));
      final bridge = LocalProxyTunnelBridge(resolveDefaultNode: () => null);
      addTearDown(bridge.stop);
      await bridge.ensureStarted();
      final url = Uri.parse(
        bridge.buildStreamRelayUrl(
          targetUrl: 'http://127.0.0.1:${origin.port}/api/telegram/video',
          forceDirect: true,
        ),
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      expect(seenStarts, isEmpty);

      final response = await request(client, url);
      expect(response.statusCode, HttpStatus.ok);
      expect(await bytes(response), List<int>.generate(size, (i) => i % 251));
      expect(seenStarts, [0, cutoff]);

      final suffix = await request(client, url, range: 'bytes=-4');
      expect(suffix.statusCode, HttpStatus.partialContent);
      expect(
        suffix.headers.value(HttpHeaders.contentRangeHeader),
        'bytes ${size - 4}-${size - 1}/$size',
      );
      expect(
        await bytes(suffix),
        List<int>.generate(4, (i) => (size - 4 + i) % 251),
      );

      final head = await request(
        client,
        url,
        method: 'HEAD',
        range: 'bytes=9-12',
      );
      expect(head.statusCode, HttpStatus.partialContent);
      expect(head.contentLength, 4);
      expect(await bytes(head), isEmpty);

      final invalid = await request(client, url, range: 'bytes=$size-');
      expect(invalid.statusCode, HttpStatus.requestedRangeNotSatisfiable);
      expect(
        invalid.headers.value(HttpHeaders.contentRangeHeader),
        'bytes */$size',
      );
      await invalid.drain<void>();
    },
  );

  test(
    'Telegram relay cancels stalled lookahead when the player disconnects',
    () async {
      final origin = await HttpServer.bind(loopback, 0);
      final prefetched = Completer<void>();
      final upstreamClosed = Completer<void>();
      final stalledSockets = <Socket>[];
      const size = blockSize * 12;
      origin.listen((req) async {
        final range = req.headers.value(HttpHeaders.rangeHeader)!;
        final start = int.parse(range.split('=')[1].split('-')[0]);
        final socket = await req.response.detachSocket(writeHeaders: false);
        stalledSockets.add(socket);
        socket.listen(
          null,
          onError: (Object _) {},
          onDone: () {
            socket.destroy();
            if (start == blockSize && !upstreamClosed.isCompleted) {
              upstreamClosed.complete();
            }
          },
        );
        socket.write(
          'HTTP/1.1 206 Partial Content\r\n'
          'Content-Length: $blockSize\r\n'
          'Content-Range: bytes $start-${start + blockSize - 1}/$size\r\n'
          'Connection: close\r\n\r\n',
        );
        socket.add(List<int>.filled(128 * 1024, 9));
        await socket.flush();
        if (start == blockSize && !prefetched.isCompleted) {
          prefetched.complete();
        }
      });
      addTearDown(() async {
        for (final socket in stalledSockets) {
          socket.destroy();
        }
        await origin.close(force: true);
      });
      final bridge = LocalProxyTunnelBridge(resolveDefaultNode: () => null);
      addTearDown(bridge.stop);
      final ports = await Future.wait([
        bridge.ensureStarted(),
        bridge.ensureStarted(),
      ]);
      expect(ports[0], greaterThan(0));
      expect(ports[1], ports[0]);
      final url = Uri.parse(
        bridge.buildStreamRelayUrl(
          targetUrl: 'http://127.0.0.1:${origin.port}/api/telegram/video',
          forceDirect: true,
        ),
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await request(client, url);
      final downstream = response.listen(null, onError: (Object _) {});
      await prefetched.future.timeout(const Duration(seconds: 3));
      await downstream.cancel();
      client.close(force: true);
      await upstreamClosed.future.timeout(const Duration(seconds: 3));
    },
  );

  test(
    'Telegram relay prioritizes an unaligned seek near EOF and cancels old lookahead',
    () async {
      final origin = await HttpServer.bind(loopback, 0);
      final prefetched = Completer<void>();
      final oldLookaheadClosed = Completer<void>();
      final sockets = <Socket>[];
      final starts = <int>[];
      var originalPlaybackClosed = false;
      const size = blockSize * 12;
      const targetBlock = size - blockSize;
      const target = targetBlock + 512 * 1024;
      origin.listen((req) async {
        final range = req.headers.value(HttpHeaders.rangeHeader)!;
        final bounds = range.substring('bytes='.length).split('-');
        final start = int.parse(bounds[0]);
        final end = int.parse(bounds[1]);
        starts.add(start);
        if (start >= targetBlock) {
          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/$size',
          );
          req.response.contentLength = end - start + 1;
          req.response.add(
            List<int>.generate(end - start + 1, (i) => (start + i) % 251),
          );
          await req.response.close();
          return;
        }
        final socket = await req.response.detachSocket(writeHeaders: false);
        sockets.add(socket);
        socket.listen(
          null,
          onError: (Object _) {},
          onDone: () {
            socket.destroy();
            if (start == 0) originalPlaybackClosed = true;
            if (start == blockSize && !oldLookaheadClosed.isCompleted) {
              oldLookaheadClosed.complete();
            }
          },
        );
        socket.write(
          'HTTP/1.1 206 Partial Content\r\n'
          'Content-Length: ${end - start + 1}\r\n'
          'Content-Range: bytes $start-$end/$size\r\n'
          'Connection: close\r\n\r\n',
        );
        socket.add(List<int>.filled(128 * 1024, 9));
        await socket.flush();
        if (start == blockSize && !prefetched.isCompleted) {
          prefetched.complete();
        }
      });
      addTearDown(() async {
        for (final socket in sockets) {
          socket.destroy();
        }
        await origin.close(force: true);
      });

      final bridge = LocalProxyTunnelBridge(resolveDefaultNode: () => null);
      addTearDown(bridge.stop);
      await bridge.ensureStarted();
      final url = Uri.parse(
        bridge.buildStreamRelayUrl(
          targetUrl: 'http://127.0.0.1:${origin.port}/api/telegram/video',
          forceDirect: true,
        ),
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final playback = await request(client, url, range: 'bytes=0-');
      final playbackStream = playback.listen(null, onError: (Object _) {});
      addTearDown(playbackStream.cancel);
      await prefetched.future.timeout(const Duration(seconds: 3));

      final seek = await request(client, url, range: 'bytes=$target-');
      expect(seek.statusCode, HttpStatus.partialContent);
      expect(
        seek.headers.value(HttpHeaders.contentRangeHeader),
        'bytes $target-${size - 1}/$size',
      );
      final data = await bytes(seek).timeout(const Duration(seconds: 3));
      expect(data.length, size - target);
      expect([data.first, data.last], [target % 251, (size - 1) % 251]);
      await oldLookaheadClosed.future.timeout(const Duration(seconds: 3));
      expect(originalPlaybackClosed, isFalse);
      expect(starts.where((start) => start >= targetBlock), [target]);

      final cached = await request(
        client,
        url,
        range: 'bytes=${target + 10}-${target + 13}',
      );
      expect(
        await bytes(cached),
        List<int>.generate(4, (i) => (target + 10 + i) % 251),
      );
      expect(starts.where((start) => start >= targetBlock), [target]);

      final crossing = await request(
        client,
        url,
        range: 'bytes=${target - 2}-${target + 1}',
      );
      expect(
        await bytes(crossing),
        List<int>.generate(4, (i) => (target - 2 + i) % 251),
      );
      final stillCached = await request(
        client,
        url,
        range: 'bytes=${target + 10}-${target + 13}',
      );
      expect(
        await bytes(stillCached),
        List<int>.generate(4, (i) => (target + 10 + i) % 251),
      );
      expect(starts.where((start) => start >= targetBlock), [
        target,
        target - 2,
      ]);
    },
  );

  test(
    'Telegram relay streams sources without byte-range support and isolates headers',
    () async {
      final origin = await HttpServer.bind(loopback, 0);
      addTearDown(() => origin.close(force: true));
      origin.listen((req) async {
        final auth = req.headers.value(HttpHeaders.authorizationHeader);
        final byte = auth == 'first' ? 1 : 2;
        if (req.uri.path.endsWith('/video')) {
          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 0-0/1',
          );
        }
        req.response.contentLength = 1;
        if (req.method != 'HEAD') req.response.add([byte]);
        await req.response.close();
      });

      final bridge = LocalProxyTunnelBridge(resolveDefaultNode: () => null);
      addTearDown(bridge.stop);
      await bridge.ensureStarted();
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      Uri urlFor(String endpoint, String auth) => Uri.parse(
        bridge.buildStreamRelayUrl(
          targetUrl: 'http://127.0.0.1:${origin.port}/api/telegram/$endpoint',
          headers: {HttpHeaders.authorizationHeader: auth},
          forceDirect: true,
        ),
      );

      expect(await bytes(await request(client, urlFor('video', 'first'))), [1]);
      expect(await bytes(await request(client, urlFor('video', 'second'))), [
        2,
      ]);

      final noRangeUrl = urlFor('file-content', 'first');
      final head = await request(client, noRangeUrl, method: 'HEAD');
      expect(head.contentLength, 1);
      expect(await bytes(head), isEmpty);
      final response = await request(client, noRangeUrl, range: 'bytes=0-15');
      expect(response.statusCode, HttpStatus.ok);
      expect(await bytes(response), [1]);
    },
  );

  test(
    'Telegram relay uses the selected scenario node and switches to direct',
    () async {
      Future<ServerSocket> fakeProxy(int byte) async {
        final proxy = await ServerSocket.bind(loopback, 0);
        final sockets = <Socket>{};
        addTearDown(() async {
          for (final socket in sockets.toList()) {
            socket.destroy();
          }
          await proxy.close();
        });
        proxy.listen((socket) {
          sockets.add(socket);
          var input = '';
          var connected = false;
          socket.listen(
            (chunk) {
              input += String.fromCharCodes(chunk);
              while (input.contains('\r\n\r\n')) {
                final end = input.indexOf('\r\n\r\n');
                final header = input.substring(0, end);
                input = input.substring(end + 4);
                if (!connected) {
                  expect(header, startsWith('CONNECT '));
                  connected = true;
                  socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
                  continue;
                }
                socket.write(
                  'HTTP/1.1 206 Partial Content\r\n'
                  'Content-Length: 1\r\nContent-Range: bytes 0-0/1\r\n\r\n',
                );
                socket.add([byte]);
              }
            },
            onError: (Object _) => socket.destroy(),
            onDone: () {
              sockets.remove(socket);
              socket.destroy();
            },
          );
        });
        return proxy;
      }

      SharedPreferences.setMockInitialValues({});
      final a = await fakeProxy(1);
      final b = await fakeProxy(2);
      final origin = await HttpServer.bind(loopback, 0);
      addTearDown(() => origin.close(force: true));
      origin.listen((req) async {
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-0/1');
        req.response.contentLength = 1;
        req.response.add([3]);
        await req.response.close();
      });

      final service = ProxyRoutingService();
      addTearDown(service.dispose);
      await service.initialize();
      for (final entry in {'a': a.port, 'b': b.port}.entries) {
        await service.upsertManualNode(
          ProxyNode(
            id: entry.key,
            name: entry.key,
            protocol: 'http',
            server: '127.0.0.1',
            port: entry.value,
            latencyMs: 10,
          ),
          testLatency: false,
        );
      }
      await service.selectNode('a');
      await service.setProxyEnabled(true);
      const scenario = RequestScenario.telegram;
      final target = 'http://127.0.0.1:${origin.port}/api/telegram/video';
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      Future<List<int>> read() async {
        final url = await service.resolveProxiedStreamUrl(scenario, target);
        return bytes(await request(client, Uri.parse(url)));
      }

      await service.updateScenarioRule(
        scenario,
        mode: ScenarioRouteMode.proxyNode,
        specificNodeId: 'b',
      );
      expect(await read(), [2]);
      await service.updateScenarioRule(
        scenario,
        mode: ScenarioRouteMode.proxyNode,
        specificNodeId: 'a',
      );
      expect(await read(), [1]);
      await service.updateScenarioRule(
        scenario,
        mode: ScenarioRouteMode.direct,
        clearSpecificNode: true,
      );
      expect(await read(), [3]);
    },
  );
}
