import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:m3u8_client/services/api_client.dart';
import 'package:m3u8_client/services/local_115_direct_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FixtureApiClient extends Fake implements HttpClient {
  _FixtureApiClient(this.client, this.port);

  final HttpClient client;
  final int port;

  @override
  set connectionTimeout(Duration? value) => client.connectionTimeout = value;

  @override
  set idleTimeout(Duration value) => client.idleTimeout = value;

  @override
  set findProxy(String Function(Uri)? callback) => client.findProxy = callback;

  @override
  set badCertificateCallback(
    bool Function(X509Certificate, String, int)? callback,
  ) {
    client.badCertificateCallback = callback;
  }

  Uri _localUri(Uri uri) => uri.replace(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: port,
    path: '/${uri.host}${uri.path}',
  );

  @override
  Future<HttpClientRequest> postUrl(Uri url) => client.postUrl(_localUri(url));

  @override
  Future<HttpClientRequest> getUrl(Uri url) => client.getUrl(_localUri(url));
}

void main() {
  const accountCookie = 'UID=test; CID=test; SEID=test';
  late Local115DirectService service;
  final downloadCalls = <String>[];
  final deleteCalls = <Map<String, String>>[];
  final renameCalls = <Map<String, String>>[];
  String? redirectCookie;
  String? exchangeToken;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({
      'm3u8_local_115_cookie_v1': accountCookie,
    });
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    server.listen((request) async {
      final path = request.uri.path;
      final cid = request.uri.queryParameters['cid'];
      final readForm =
          path == '/webapi.115.com/rb/delete' ||
          path == '/webapi.115.com/files/batch_rename';
      final form =
          readForm
              ? Uri.splitQueryString(await utf8.decoder.bind(request).join())
              : const <String, String>{};
      if (!readForm) await request.drain<void>();
      final response = request.response;
      switch (path) {
        case '/proapi.115.com/app/chrome/downurl':
          downloadCalls.add('${request.method} $path');
          response.statusCode = HttpStatus.found;
          response.headers.set(
            HttpHeaders.locationHeader,
            'https://dl.115cdn.net/files/dl302?t=signed',
          );
        case '/dl.115cdn.net/files/dl302':
          downloadCalls.add('${request.method} $path');
          redirectCookie = request.headers.value(HttpHeaders.cookieHeader);
          exchangeToken = request.uri.queryParameters['t'];
          response.write('{"state":false}');
        case '/webapi.115.com/files/download':
          downloadCalls.add('${request.method} $path');
          response.write('{"file_url":"https://example.test/sample.wav"}');
        case '/webapi.115.com/rb/delete':
          deleteCalls.add(form);
          response.write(
            form.containsValue('99')
                ? '{"state":false,"error":"文件不存在"}'
                : '{"state":true}',
          );
        case '/webapi.115.com/files/batch_rename':
          renameCalls.add(form);
          response.write('{"state":true,"data":{"20":"音轨 + 01.mp4"}}');
        case '/webapi.115.com/files/file':
          response.write(
            jsonEncode({
              'state': true,
              'data': [
                {
                  'file_id': '20',
                  'file_name': 'Clip.mp4',
                  'pick_code': 'clip',
                  'file_size': '1200000',
                  'sha1': '0' * 40,
                },
              ],
            }),
          );
        case '/proapi.115.com/android/2.0/category/get':
          response.write('{"file_id":"20","paths":[{"file_id":"0"}]}');
        case '/proapi.115.com/app/uploadinfo':
          response.write('{"state":true,"user_id":123,"userkey":"fixture"}');
        case '/uplb.115.com/4.0/initupload.php':
          response.statusCode = HttpStatus.serviceUnavailable;
        case '/webapi.115.com/files' when cid == '100':
          response.write(
            jsonEncode({
              'state': true,
              'data': [
                {'cid': '101', 'pid': '100', 'n': 'Web folder'},
                {
                  'fid': '102',
                  'cid': '100',
                  'n': 'Web file.flac',
                  'pc': 'flac',
                },
              ],
            }),
          );
        case '/proapi.115.com/android/2.0/ufile/files':
          response.write(
            jsonEncode({
              'state': true,
              'data':
                  cid == '0'
                      ? [
                        {'fc': 0, 'fid': '10', 'pid': '0', 'fn': 'Shows.mp4'},
                        {
                          'fc': '1',
                          'fid': '20',
                          'pid': '0',
                          'fn': 'Clip.mp4',
                          'pc': 'clip',
                        },
                      ]
                      : [
                        {'fc': '0', 'fid': '11', 'pid': '10', 'fn': 'Season 1'},
                      ],
            }),
          );
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
    service = HttpOverrides.runZoned(
      () => Local115DirectService.instance,
      createHttpClient: (_) => _FixtureApiClient(client, server.port),
    );
  });

  test(
    '115 download resolution reads the signed 302 exchange with a GET',
    () async {
      final resolved = await service.resolvePickcodeStreamUrl(
        'sample',
        allowVideoFallback: false,
      );

      expect(downloadCalls, [
        'POST /proapi.115.com/app/chrome/downurl',
        'GET /dl.115cdn.net/files/dl302',
        'GET /webapi.115.com/files/download',
      ]);
      expect(redirectCookie, accountCookie);
      expect(exchangeToken, 'signed');
      expect(resolved, 'https://example.test/sample.wav');
    },
  );

  test(
    '115 opens Android folders using their fid and tracks their parent',
    () async {
      final root = await service.list115Directory(cid: '0');
      final folder = root.entries.first;
      final file = root.entries.last;
      expect(folder.isDir, isTrue);
      expect(folder.isPlayableVideo, isFalse);
      expect(folder.path, '10');
      expect(folder.cid115, '10');
      expect(folder.fid115, '10');
      expect(file.isDir, isFalse);
      expect(file.isPlayableVideo, isTrue);
      expect(file.pickcode115, 'clip');
      expect(file.path, '20');
      expect(file.cid115, '0');

      final child = await service.list115Directory(cid: folder.path);
      expect(child.path, '10');
      expect(child.parent, '0');
      expect(child.entries.single.path, '11');
      expect(child.entries.single.isDir, isTrue);
      expect(service.parentCidFor('11'), '10');
    },
  );

  test('115 still distinguishes legacy web folders and files', () async {
    final listing = await service.list115Directory(cid: '100');
    final folder = listing.entries.first;
    final file = listing.entries.last;
    expect(folder.isDir, isTrue);
    expect(folder.path, '101');
    expect(service.parentCidFor('101'), '100');
    expect(file.isDir, isFalse);
    expect(file.isAudio, isTrue);
    expect(file.cid115, '100');
  });

  test(
    '115 sends the selected IDs to the recycle endpoint in one request',
    () async {
      deleteCalls.clear();
      await service.delete115Files(fids: ['20', '21'], parentCid: '/');
      expect(deleteCalls, [
        {'pid': '0', 'fid[0]': '20', 'fid[1]': '21'},
      ]);
      await expectLater(
        service.delete115Files(fids: ['20', '0'], parentCid: '0'),
        throwsA(isA<ApiException>()),
      );
      expect(deleteCalls, hasLength(1));
      await expectLater(
        service.delete115Files(fids: ['99'], parentCid: '10'),
        throwsA(
          isA<ApiException>().having((e) => e.message, 'message', '文件不存在'),
        ),
      );
    },
  );

  test(
    '115 regular rename encodes the complete name and returns the saved name',
    () async {
      final saved = await service.rename115File(
        fid: '20',
        currentName: 'Clip.mp4',
        newName: '音轨 + 01.mp4',
        isDir: false,
      );
      expect(renameCalls.single, {'files_new_name[20]': '音轨 + 01.mp4'});
      expect(saved, '音轨 + 01.mp4');
      await expectLater(
        service.rename115File(
          fid: '20',
          currentName: 'Clip.mp4',
          newName: 'Clip.mkv',
          isDir: false,
        ),
        throwsA(isA<ApiException>()),
      );
      expect(renameCalls, hasLength(1));
    },
  );

  test(
    '115 keeps the original if creation of the renamed copy fails',
    () async {
      deleteCalls.clear();
      final root = await service.list115Directory(cid: '0');
      final source = root.entries.singleWhere((item) => item.fid115 == '20');
      await expectLater(
        service.replace115FileSuffix(source, 'Clip.mkv'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            contains('HTTP 503'),
          ),
        ),
      );
      expect(deleteCalls, isEmpty);
    },
  );
}
