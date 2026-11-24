import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:m3u8_client/models/models.dart';
import 'package:m3u8_client/services/api_client.dart';
import 'package:m3u8_client/services/local_115_direct_service.dart';
import 'package:m3u8_client/services/remote_storage_service.dart';
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

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      client.openUrl(method, _localUri(url));
}

class _AccelerationApi extends ApiClient {
  _AccelerationApi(this.onUpload) : super(const ServerConfig());

  final void Function() onUpload;
  final submissions = <bool>[];
  final uploads = <String>[];
  final convertedFiles = <String>[];
  Map<String, dynamic> savedSettings = {'eleven_dir_id': '10'};

  @override
  Future<Map<String, dynamic>> fetch115Status() async => {'Id': 'test'};

  @override
  Future<ServerSettings> fetchServerSettings() async =>
      ServerSettings(savedSettings);

  @override
  Future<void> saveServerSettings(Map<String, dynamic> settings) async {
    savedSettings = Map<String, dynamic>.from(settings);
  }

  @override
  Future<String?> createDownloadTask({
    required String url,
    required String name,
    Map<String, String>? headers,
    Map<String, dynamic>? videoContext,
    String? telegramAccountId,
    bool forceDuplicate = false,
  }) async {
    submissions.add(forceDuplicate);
    return forceDuplicate ? 'new-task' : 'stale-task';
  }

  @override
  Future<List<DownloadTask>> fetchDownloadTasks() async => const [
    DownloadTask(
      id: 'stale-task',
      url: 'https://example.test/source.mp4',
      name: 'Acceleration episode 1',
      status: 'Duplicate',
      outputFile: 'downloads/Acceleration episode 1.mp4',
    ),
    DownloadTask(
      id: 'new-task',
      url: 'https://example.test/source.mp4',
      name: 'Acceleration episode 1',
      status: 'Completed',
      outputFile: 'downloads/Acceleration episode 1.mp4',
    ),
  ];

  @override
  Future<void> uploadTaskTo115(String id) async {
    uploads.add(id);
    onUpload();
  }
}

class _Mp4ConversionAccelerationApi extends ApiClient {
  _Mp4ConversionAccelerationApi(this.onUpload) : super(const ServerConfig());

  final void Function() onUpload;
  final events = <String>[];
  Map<String, dynamic> savedSettings = {
    'eleven_dir_id': '10',
    'convert_to_mp4': false,
  };
  bool mp4ExistsOnServer = false;

  @override
  Future<Map<String, dynamic>> fetch115Status() async => {'Id': 'test'};

  @override
  Future<ServerSettings> fetchServerSettings() async =>
      ServerSettings(savedSettings);

  @override
  Future<void> saveServerSettings(Map<String, dynamic> settings) async {
    savedSettings = Map<String, dynamic>.from(settings);
    events.add('saveSettings:convert_to_mp4=${settings['convert_to_mp4']}');
  }

  @override
  Future<void> deleteDownloadTask(String id, {bool deleteFiles = false}) async {
    events.add('deleteTask:$id');
  }

  @override
  Future<String?> createDownloadTask({
    required String url,
    required String name,
    Map<String, String>? headers,
    Map<String, dynamic>? videoContext,
    String? telegramAccountId,
    bool forceDuplicate = false,
  }) async {
    events.add('createTask:$url:force=$forceDuplicate');
    if (url.contains('dead-line')) {
      return 'failed-task';
    }
    return 'ts-task';
  }

  @override
  Future<void> retryDownloadTask(String id) async {
    events.add('retryTask:$id');
    throw const ApiException('Not Found', statusCode: HttpStatus.notFound);
  }

  @override
  Future<List<DownloadTask>> fetchDownloadTasks() async => [
    const DownloadTask(
      id: 'failed-task',
      url: 'https://example.test/dead-line.m3u8',
      name: 'Acceleration episode 1',
      status: 'Failed',
      error: 'HTTP 403 Forbidden',
    ),
    DownloadTask(
      id: 'ts-task',
      url: 'https://example.test/backup-line.m3u8',
      name: 'Acceleration episode 1',
      status: 'Completed',
      urlType: 'm3u8',
      outputFile: mp4ExistsOnServer
          ? 'downloads/Acceleration episode 1.mp4'
          : 'downloads/Acceleration episode 1.ts',
    ),
  ];

  @override
  Future<FileDirectoryListing> fetchFiles({String path = ''}) async {
    return FileDirectoryListing(
      path: path,
      parent: '',
      root: '/',
      entries: [
        if (mp4ExistsOnServer)
          const FileEntry(
            name: 'Acceleration episode 1.mp4',
            path: 'downloads/Acceleration episode 1.mp4',
            size: 102400,
            modTime: '2026-11-21 23:00:00',
            isDir: false,
            isMp4: true,
            ext: '.mp4',
          ),
      ],
    );
  }

  @override
  Future<void> convertFileToMp4(String filePath) async {
    events.add('convertToMp4:$filePath');
    mp4ExistsOnServer = true;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchServerFileOps() async => const [];

  @override
  Future<void> uploadTaskTo115(String id) async {
    events.add('uploadTaskTo115:$id:mp4Ready=$mp4ExistsOnServer');
    onUpload();
  }
}

void main() {
  const accountCookie = 'UID=test; CID=test; SEID=test';
  late Local115DirectService service;
  final downloadCalls = <String>[];
  final deleteCalls = <Map<String, String>>[];
  final renameCalls = <Map<String, String>>[];
  final copyCalls = <Map<String, String>>[];
  final moveCalls = <Map<String, String>>[];
  String? redirectCookie;
  String? exchangeToken;
  bool showAccelerationFiles = false;
  bool acceleratedCopyExists = false;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({
      'm3u8_local_115_cookie_v1': accountCookie,
      'm3u8_local_115_folder_cid_v1': '10',
      'm3u8_local_115_folder_name_v1': 'Shows.mp4',
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
          path == '/webapi.115.com/files/batch_rename' ||
          path == '/webapi.115.com/files/copy' ||
          path == '/webapi.115.com/files/move';
      final form =
          readForm
              ? Uri.splitQueryString(await utf8.decoder.bind(request).join())
              : const <String, String>{};
      if (!readForm) await request.drain<void>();
      final response = request.response;
      switch (path) {
        case '/webapi.115.com/files/copy':
          copyCalls.add(form);
          response.write('{"state":true}');
        case '/webapi.115.com/files/move':
          moveCalls.add(form);
          response.write('{"state":true}');
        case '/uplb.115.com/3.0/gettoken.php':
          response.write(
            jsonEncode({
              'StatusCode': '200',
              'AccessKeyId': 'STS.TESTKEY',
              'AccessKeySecret': 'test-secret',
              'SecurityToken': 'sts-token-123',
              'Expiration': '2026-12-31T23:59:59Z',
            }),
          );
        case '/fhnfile.oss-cn-shenzhen.aliyuncs.com/test_obj_key':
          response.write(
            jsonEncode({
              'state': true,
              'data': {'pick_code': 'oss_uploaded_pc', 'file_id': '888'},
            }),
          );
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
        case '/example.test/sample.wav':
          response.headers.contentType = ContentType('video', 'mp4');
          response.add(ascii.encode('0000ftypmp42'));
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
                        if (showAccelerationFiles && cid == '10')
                          {
                            'fc': '1',
                            'fid': '30',
                            'pid': '10',
                            'fn': 'Acceleration episode 10.mp4',
                            'pc': 'other-episode',
                          },
                        if (acceleratedCopyExists && cid == '10')
                          {
                            'fc': '1',
                            'fid': '31',
                            'pid': '10',
                            'fn': 'Acceleration episode 1.mp4',
                            'pc': 'uploaded-episode',
                          },
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

  test(
    '115 replaces stale duplicates and only uploads the requested task',
    () async {
      showAccelerationFiles = true;
      final api = _AccelerationApi(() => acceleratedCopyExists = true);
      final errors = <String>[];
      final stream = await service.run115CloudAccelerationPipeline(
        api: api,
        downloadUrl: 'https://example.test/source.mp4',
        videoName: 'Acceleration episode 1',
        onError: errors.add,
      );
      expect(api.submissions, [false, true]);
      expect(api.uploads, ['new-task']);
      expect(api.savedSettings['convert_to_mp4'], isTrue);
      expect(stream?.fileName, 'Acceleration episode 1.mp4');
      expect(errors, isEmpty);
      expect(service.isAccelerating, isFalse);
    },
  );

  test(
    '115 acceleration fails over on server download error, converts TS to MP4 before uploading, and resolves MP4 playback',
    () async {
      showAccelerationFiles = true;
      acceleratedCopyExists = false;
      final api = _Mp4ConversionAccelerationApi(
        () => acceleratedCopyExists = true,
      );
      final errors = <String>[];
      final stream = await service.run115CloudAccelerationPipeline(
        api: api,
        downloadUrl: 'https://example.test/dead-line.m3u8',
        fallbackDownloadUrls: const ['https://example.test/backup-line.m3u8'],
        videoName: 'Acceleration episode 1',
        onError: errors.add,
      );
      expect(api.savedSettings['convert_to_mp4'], isTrue);
      expect(
        api.events,
        containsAllInOrder([
          'saveSettings:convert_to_mp4=true',
          'createTask:https://example.test/dead-line.m3u8:force=false',
          'createTask:https://example.test/backup-line.m3u8:force=true',
          'convertToMp4:downloads/Acceleration episode 1.ts',
          'uploadTaskTo115:ts-task:mp4Ready=true',
        ]),
      );
      expect(stream?.fileName, 'Acceleration episode 1.mp4');
      expect(errors, isEmpty);
      expect(service.isAccelerating, isFalse);
    },
  );

  test(
    '115 uses upstream headers when unwrapping the server playback proxy',
    () {
      final uri = Uri.https('server.test', '/api/vod/proxy', {
        'url': 'https://media.test/episode.m3u8',
        'headers': base64UrlEncode(
          utf8.encode(
            jsonEncode({
              'Authorization': 'Bearer media-token',
              'Referer': 'https://media.test/',
            }),
          ),
        ),
      });
      final result = Local115DirectService.unwrapDownloadTargetUrlAndHeaders(
        uri.toString(),
        {
          'Cookie': 'access_token=server-token',
          'authorization': 'Bearer server',
        },
      );
      expect(result.url, 'https://media.test/episode.m3u8');
      expect(result.headers, {
        'Authorization': 'Bearer media-token',
        'Referer': 'https://media.test/',
      });
    },
  );

  test(
    '115 supports in-drive copy/move and RemoteStorageService routes cloud115 uploads to Local115DirectService instead of server /api/files/upload',
    () async {
      copyCalls.clear();
      moveCalls.clear();
      await service.copyOrMove115Entries(
        fids: const ['20', '30'],
        targetCid: '10',
        isMove: false,
      );
      expect(copyCalls, [
        {'pid': '10', 'fid[0]': '20', 'fid[1]': '30'},
      ]);

      await service.copyOrMove115Entries(
        fids: const ['20'],
        targetCid: '0',
        isMove: true,
      );
      expect(moveCalls, [
        {'pid': '0', 'fid[0]': '20', 'move_notsame': '1'},
      ]);

      // Verify RemoteStorageService.uploadWithProgress for cloud115 routes directly to 115 initupload.php
      // (which returns HTTP 503 in this fixture) rather than calling the server /api/files/upload endpoint!
      const mount115 = StorageMount(
        id: 'builtin_115',
        name: '115网盘',
        kind: StorageSourceKind.cloud115,
        rootPath: '0',
      );
      await expectLater(
        RemoteStorageService.instance.uploadWithProgress(
          targetMount: mount115,
          targetDir: '10',
          fileName: 'TestUpload.mp4',
          rawBytes: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
          isCancelled: () => false,
          onProgress: (_, __, ___) {},
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            contains('115 初始化上传失败（HTTP 503）'),
          ),
        ),
      );

      // Verify when both localFilePath and empty rawBytes (Uint8List(0)) are passed
      // (as macOS native file picker does for >8MB files), it hashes the actual file
      // on disk rather than hashing the empty Uint8List(0)!
      final tmpFile = File(
        '${Directory.systemTemp.path}/test_115_nonempty_${DateTime.now().millisecondsSinceEpoch}.bin',
      );
      await tmpFile.writeAsBytes([10, 20, 30, 40, 50, 60]);
      addTearDown(() async {
        if (await tmpFile.exists()) await tmpFile.delete();
      });
      await expectLater(
        RemoteStorageService.instance.uploadWithProgress(
          targetMount: mount115,
          targetDir: '10',
          fileName: 'LargeFile.dmg',
          localFilePath: tmpFile.path,
          rawBytes: Uint8List(0),
          isCancelled: () => false,
          onProgress: (_, __, ___) {},
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            contains('115 初始化上传失败（HTTP 503）'),
          ),
        ),
      );
    },
  );
}
