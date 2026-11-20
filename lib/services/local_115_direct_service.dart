import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'api_client.dart';

/// 1:1 port of `github.com/deadblue/elevengo/internal/crypto/m115`
/// Used to encrypt/decrypt `https://proapi.115.com/app/chrome/downurl` payloads.
class M115Crypto {
  static const List<int> _xorKeySeed = <int>[
    0xf0, 0xe5, 0x69, 0xae, 0xbf, 0xdc, 0xbf, 0x8a,
    0x1a, 0x45, 0xe8, 0xbe, 0x7d, 0xa6, 0x73, 0xb8,
    0xde, 0x8f, 0xe7, 0xc4, 0x45, 0xda, 0x86, 0xc4,
    0x9b, 0x64, 0x8b, 0x14, 0x6a, 0xb4, 0xf1, 0xaa,
    0x38, 0x01, 0x35, 0x9e, 0x26, 0x69, 0x2c, 0x86,
    0x00, 0x6b, 0x4f, 0xa5, 0x36, 0x34, 0x62, 0xa6,
    0x2a, 0x96, 0x68, 0x18, 0xf2, 0x4a, 0xfd, 0xbd,
    0x6b, 0x97, 0x8f, 0x4d, 0x8f, 0x89, 0x13, 0xb7,
    0x6c, 0x8e, 0x93, 0xed, 0x0e, 0x0d, 0x48, 0x3e,
    0xd7, 0x2f, 0x88, 0xd8, 0xfe, 0xfe, 0x7e, 0x86,
    0x50, 0x95, 0x4f, 0xd1, 0xeb, 0x83, 0x26, 0x34,
    0xdb, 0x66, 0x7b, 0x9c, 0x7e, 0x9d, 0x7a, 0x81,
    0x32, 0xea, 0xb6, 0x33, 0xde, 0x3a, 0xa9, 0x59,
    0x34, 0x66, 0x3b, 0xaa, 0xba, 0x81, 0x60, 0x48,
    0xb9, 0xd5, 0x81, 0x9c, 0xf8, 0x6c, 0x84, 0x77,
    0xff, 0x54, 0x78, 0x26, 0x5f, 0xbe, 0xe8, 0x1e,
    0x36, 0x9f, 0x34, 0x80, 0x5c, 0x45, 0x2c, 0x9b,
    0x76, 0xd5, 0x1b, 0x8f, 0xcc, 0xc3, 0xb8, 0xf5,
  ];

  static const List<int> _xorClientKey = <int>[
    0x78, 0x06, 0xad, 0x4c, 0x33, 0x86, 0x5d, 0x18,
    0x4c, 0x01, 0x3f, 0x46,
  ];

  static final BigInt _rsaN = BigInt.parse(
    '8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b86021'
    '36477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad633'
    '8c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f1'
    '0a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683',
    radix: 16,
  );

  static final BigInt _rsaE = BigInt.from(0x10001);
  static const int _keyLength = 128;
  static final Random _rng = Random.secure();

  static Uint8List generateKey() {
    final key = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      key[i] = _rng.nextInt(256);
    }
    return key;
  }

  static String encode(Uint8List input, Uint8List key) {
    final payload = Uint8List.fromList(input);
    _xorTransform(payload, _xorDeriveKey(key, 4));
    _reverseBytes(payload);
    _xorTransform(payload, Uint8List.fromList(_xorClientKey));

    final buf = Uint8List(16 + payload.length);
    buf.setRange(0, 16, key);
    buf.setRange(16, 16 + payload.length, payload);

    final encrypted = _rsaEncrypt(buf);
    return base64Encode(encrypted);
  }

  static Uint8List? decode(String input, Uint8List key) {
    try {
      final raw = base64Decode(input.trim());
      final decrypted = _rsaDecrypt(raw);
      if (decrypted.length <= 16) return null;
      final head16 = Uint8List.sublistView(decrypted, 0, 16);
      final output = Uint8List.fromList(decrypted.sublist(16));
      _xorTransform(output, _xorDeriveKey(head16, 12));
      _reverseBytes(output);
      _xorTransform(output, _xorDeriveKey(key, 4));
      return output;
    } catch (_) {
      return null;
    }
  }

  static Uint8List _xorDeriveKey(Uint8List seed, int size) {
    final key = Uint8List(size);
    for (var i = 0; i < size; i++) {
      final a = (seed[i] + _xorKeySeed[size * i]) & 0xff;
      key[i] = a ^ _xorKeySeed[size * (size - i - 1)];
    }
    return key;
  }

  static void _xorTransform(Uint8List data, Uint8List key) {
    final dataSize = data.length;
    final keySize = key.length;
    if (keySize == 0) return;
    final mod = dataSize % 4;
    if (mod > 0) {
      for (var i = 0; i < mod; i++) {
        data[i] ^= key[i % keySize];
      }
    }
    for (var i = mod; i < dataSize; i++) {
      data[i] ^= key[(i - mod) % keySize];
    }
  }

  static void _reverseBytes(Uint8List data) {
    for (int i = 0, j = data.length - 1; i < j; i++, j--) {
      final tmp = data[i];
      data[i] = data[j];
      data[j] = tmp;
    }
  }

  static Uint8List _rsaEncrypt(Uint8List input) {
    final out = BytesBuilder(copy: false);
    var offset = 0;
    while (offset < input.length) {
      final remain = input.length - offset;
      final sliceSize = min(_keyLength - 11, remain);
      final slice = Uint8List.sublistView(input, offset, offset + sliceSize);
      offset += sliceSize;

      final padSize = _keyLength - sliceSize - 3;
      final buf = Uint8List(_keyLength);
      buf[0] = 0;
      buf[1] = 2;
      for (var i = 0; i < padSize; i++) {
        buf[2 + i] = (_rng.nextInt(0xff) + 1) & 0xff;
      }
      buf[padSize + 2] = 0;
      buf.setRange(padSize + 3, _keyLength, slice);

      final msg = _bytesToBigInt(buf);
      final ret = _bigIntToBytes(msg.modPow(_rsaE, _rsaN), _keyLength);
      out.add(ret);
    }
    return out.toBytes();
  }

  static Uint8List _rsaDecrypt(Uint8List input) {
    final out = BytesBuilder(copy: false);
    var offset = 0;
    while (offset < input.length) {
      final sliceSize = min(_keyLength, input.length - offset);
      final slice = Uint8List.sublistView(input, offset, offset + sliceSize);
      offset += sliceSize;

      final msg = _bytesToBigInt(slice);
      final ret = _bigIntToBytes(msg.modPow(_rsaE, _rsaN), 0);
      for (var i = 0; i < ret.length; i++) {
        if (ret[i] == 0 && i != 0) {
          if (i + 1 < ret.length) {
            out.add(Uint8List.sublistView(ret, i + 1));
          }
          break;
        }
      }
    }
    return out.toBytes();
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b & 0xff);
    }
    return result;
  }

  static Uint8List _bigIntToBytes(BigInt value, int minLength) {
    var hex = value.toRadixString(16);
    if (hex.length.isOdd) {
      hex = '0$hex';
    }
    final byteCount = hex.length ~/ 2;
    final totalLen = max(minLength, byteCount);
    final out = Uint8List(totalLen);
    final padOffset = totalLen - byteCount;
    for (var i = 0; i < byteCount; i++) {
      out[padOffset + i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

class Resolved115Stream {
  final String proxyStreamUrl;
  final String directCdnUrl;
  final Map<String, String> headers;
  final String fileName;

  const Resolved115Stream({
    required this.proxyStreamUrl,
    required this.directCdnUrl,
    required this.headers,
    required this.fileName,
  });
}

/// Manages local 115 Cloud Drive QR/Cookie authentication, direct domestic CDN URL resolution,
/// local loopback HTTP header injection proxy, and the 3-stage "Server Download -> 115 Upload -> Local 115 Direct Play" pipeline.
class Local115DirectService extends ChangeNotifier {
  static final Local115DirectService instance = Local115DirectService._();

  static const String browserUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 115Browser/27.0.5.7';

  static const String _prefCookieKey = 'm3u8_local_115_cookie_v1';
  static const String _prefUserNameKey = 'm3u8_local_115_username_v1';
  static const String _prefTargetFolderNameKey = 'm3u8_local_115_folder_name_v1';
  static const String _prefTargetFolderCidKey = 'm3u8_local_115_folder_cid_v1';
  static const String defaultTargetFolderName = '流光115加速';

  String _cookie = '';
  String _userName = '';
  String _targetFolderName = defaultTargetFolderName;
  String _targetFolderCid = '';
  bool _initialized = false;

  // Acceleration pipeline state
  bool _isAccelerating = false;
  String _stageTitle = '';
  String _detailText = '';
  double _progress = 0.0;
  int _activePipelineId = 0;

  // Local loopback proxy for injecting 115Browser User-Agent + Cookie on all Range requests
  HttpServer? _proxyServer;
  int _proxyPort = 0;
  final Map<String, Map<String, String>> _headersByUrl = {};
  late final HttpClient _httpClient;

  Local115DirectService._() {
    _httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 30)
      ..findProxy = ((_) => 'DIRECT')
      ..badCertificateCallback = (_, __, ___) => true;
    unawaited(ensureInitialized());
  }

  String get savedCookie => _cookie;
  String get savedUserName => _userName;
  String get targetFolderName =>
      _targetFolderName.trim().isEmpty ? defaultTargetFolderName : _targetFolderName.trim();
  String get targetFolderCid => _targetFolderCid;
  bool get hasLocalCookie =>
      _cookie.contains('UID=') &&
      _cookie.contains('CID=') &&
      _cookie.contains('SEID=');

  bool get isAccelerating => _isAccelerating;
  String get stageTitle => _stageTitle;
  String get detailText => _detailText;
  double get progress => _progress;

  Map<String, String> get requestHeaders => <String, String>{
        'User-Agent': browserUserAgent,
        'Accept': 'application/json, text/plain, */*',
        'Referer': 'https://115.com/',
        'Origin': 'https://115.com',
        if (_cookie.isNotEmpty) 'Cookie': _cookie,
      };

  Future<void> ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _cookie = normalizeCookieString(prefs.getString(_prefCookieKey) ?? '');
      _userName = prefs.getString(_prefUserNameKey) ?? '';
      final savedFolder = (prefs.getString(_prefTargetFolderNameKey) ?? '').trim();
      _targetFolderName =
          savedFolder.isEmpty ? defaultTargetFolderName : savedFolder;
      _targetFolderCid = (prefs.getString(_prefTargetFolderCidKey) ?? '').trim();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setTargetFolderName(
    String folderName, {
    ApiClient? syncToServerApi,
  }) async {
    await ensureInitialized();
    final clean = folderName
        .replaceAll('/', '_')
        .replaceAll('\\', '_')
        .replaceAll(':', '_')
        .trim();
    final nextName = clean.isEmpty ? defaultTargetFolderName : clean;
    if (nextName != _targetFolderName) {
      _targetFolderName = nextName;
      _targetFolderCid = '';
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefTargetFolderNameKey, _targetFolderName);
        await prefs.remove(_prefTargetFolderCidKey);
      } catch (_) {}
      notifyListeners();
    }
    if (hasLocalCookie) {
      await ensureAccelerationFolderCid(
        syncToServerApi: syncToServerApi,
        forceVerify: true,
      );
    }
  }

  /// Finds or creates the designated 115 upload folder (default `/流光115加速`) in 115 root (`cid=0`),
  /// caches its `cid`, and syncs `"eleven_dir_id": cid` to the backend server's `/api/settings`.
  Future<String> ensureAccelerationFolderCid({
    ApiClient? syncToServerApi,
    bool forceVerify = false,
  }) async {
    await ensureInitialized();
    if (!hasLocalCookie) return '0';
    final folderName = targetFolderName;

    if (!forceVerify &&
        _targetFolderCid.isNotEmpty &&
        _targetFolderCid != '0') {
      if (syncToServerApi != null) {
        unawaited(_syncFolderCidToServer(syncToServerApi, _targetFolderCid));
      }
      return _targetFolderCid;
    }

    String resolvedCid = '';
    try {
      final listUri = Uri.parse(
        'https://webapi.115.com/files?aid=1&cid=0&o=user_ptime&asc=0&offset=0&limit=115&show_dir=1&format=json',
      );
      final root = await _getJson(listUri, timeout: const Duration(seconds: 12));
      if (root is Map<String, dynamic> && root['data'] is List) {
        for (final item in root['data'] as List) {
          if (item is! Map<String, dynamic>) continue;
          final fid = (item['fid'] ?? item['file_id'] ?? '').toString().trim();
          final cid =
              (item['cid'] ?? item['category_id'] ?? '').toString().trim();
          final name =
              (item['n'] ?? item['ns'] ?? item['file_name'] ?? '').toString().trim();
          final isDir = (fid.isEmpty || fid == '0') &&
              cid.isNotEmpty &&
              cid != '0';
          if (isDir && name.toLowerCase() == folderName.toLowerCase()) {
            resolvedCid = cid;
            break;
          }
        }
      }
    } catch (_) {}

    if (resolvedCid.isEmpty) {
      try {
        final addRes = await _postFormJson(
          Uri.parse('https://webapi.115.com/files/add'),
          body: 'pid=0&cname=${Uri.encodeQueryComponent(folderName)}',
          timeout: const Duration(seconds: 12),
        );
        if (addRes is Map<String, dynamic>) {
          final directCid =
              (addRes['cid'] ?? addRes['file_id'] ?? '').toString().trim();
          if (directCid.isNotEmpty && directCid != '0') {
            resolvedCid = directCid;
          } else if (addRes['data'] is Map<String, dynamic>) {
            final d = addRes['data'] as Map<String, dynamic>;
            final nestedCid =
                (d['cid'] ?? d['category_id'] ?? d['file_id'] ?? '')
                    .toString()
                    .trim();
            if (nestedCid.isNotEmpty && nestedCid != '0') {
              resolvedCid = nestedCid;
            }
          }
        }
      } catch (_) {}
    }

    if (resolvedCid.isNotEmpty && resolvedCid != '0') {
      _targetFolderCid = resolvedCid;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefTargetFolderCidKey, resolvedCid);
      } catch (_) {}
      notifyListeners();
      if (syncToServerApi != null) {
        await _syncFolderCidToServer(syncToServerApi, resolvedCid);
      }
      return resolvedCid;
    }

    return _targetFolderCid.isNotEmpty ? _targetFolderCid : '0';
  }

  Future<void> _syncFolderCidToServer(ApiClient api, String targetCid) async {
    if (targetCid.isEmpty || targetCid == '0') return;
    try {
      final settings = await api.fetchServerSettings();
      final map = Map<String, dynamic>.from(settings.raw);
      final cur = (map['eleven_dir_id'] ?? '').toString().trim();
      if (cur != targetCid) {
        map['eleven_dir_id'] = targetCid;
        await api.saveServerSettings(map);
      }
    } catch (_) {}
  }

  Future<void> move115FileToFolder({
    required String fid,
    required String targetCid,
  }) async {
    if (!hasLocalCookie ||
        fid.isEmpty ||
        fid == '0' ||
        targetCid.isEmpty ||
        targetCid == '0') {
      return;
    }
    try {
      await _postFormJson(
        Uri.parse('https://webapi.115.com/files/move'),
        body:
            'pid=${Uri.encodeQueryComponent(targetCid)}&fid[0]=${Uri.encodeQueryComponent(fid)}&nodup=1',
        timeout: const Duration(seconds: 12),
      );
    } catch (_) {}
  }

  static String normalizeCookieString(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final kvMap = <String, String>{};
    for (final part in trimmed.split(';')) {
      final p = part.trim();
      final eq = p.indexOf('=');
      if (eq > 0) {
        final k = p.substring(0, eq).trim().toUpperCase();
        final v = p.substring(eq + 1).trim();
        if (k.isNotEmpty && v.isNotEmpty) {
          kvMap[k] = v;
        }
      }
    }
    final ordered = <String>[];
    for (final k in const ['UID', 'CID', 'SEID', 'KID']) {
      final v = kvMap[k];
      if (v != null && v.isNotEmpty) {
        ordered.add('$k=$v');
      }
    }
    return ordered.isEmpty ? trimmed : ordered.join('; ');
  }

  Future<void> saveCookie(
    String rawCookie, {
    String? userName,
    ApiClient? syncToServerApi,
  }) async {
    await ensureInitialized();
    final normalized = normalizeCookieString(rawCookie);
    _cookie = normalized;
    if (userName != null && userName.isNotEmpty) {
      _userName = userName;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefCookieKey, _cookie);
      if (_userName.isNotEmpty) {
        await prefs.setString(_prefUserNameKey, _userName);
      }
    } catch (_) {}
    if (syncToServerApi != null && _cookie.isNotEmpty) {
      try {
        await syncToServerApi.login115WithCookie(_cookie);
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> clearCookie({ApiClient? syncToServerApi}) async {
    _cookie = '';
    _userName = '';
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefCookieKey);
      await prefs.remove(_prefUserNameKey);
    } catch (_) {}
    if (syncToServerApi != null) {
      try {
        await syncToServerApi.logout115();
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Verifies whether the local 115 Cookie is valid against `https://my.115.com/?ct=ajax&ac=nav`
  Future<({bool loggedIn, String userName})> verifyStatus() async {
    await ensureInitialized();
    if (!hasLocalCookie) {
      return (loggedIn: false, userName: '');
    }
    try {
      final data = await _getJson(
        Uri.parse('https://my.115.com/?ct=ajax&ac=nav'),
        timeout: const Duration(seconds: 10),
      );
      if (data is Map<String, dynamic>) {
        final state = data['state'] == true || data['state'] == 1;
        if (state) {
          final info = data['data'];
          if (info is Map<String, dynamic>) {
            final name = (info['user_name'] ?? info['user_id'] ?? '115 用户').toString();
            _userName = name;
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString(_prefUserNameKey, name);
            notifyListeners();
            return (loggedIn: true, userName: name);
          }
          return (
            loggedIn: true,
            userName: _userName.isEmpty ? '115 用户' : _userName,
          );
        }
        return (loggedIn: false, userName: '');
      }
    } catch (_) {}
    return (
      loggedIn: hasLocalCookie,
      userName: _userName.isEmpty ? '115 用户' : _userName,
    );
  }

  // Cached active QR session so opening/rebuilding the login dialog never refreshes the QR code prematurely
  ({
    String uid,
    int time,
    String sign,
    String qrContent,
    String imageUrl,
  })? _cachedQrSession;
  DateTime _cachedQrSessionAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Starts an official 115 QR Code login session directly from the local device
  Future<({
    String uid,
    int time,
    String sign,
    String qrContent,
    String imageUrl,
  })> startQrCodeSession({bool forceRefresh = false}) async {
    await ensureInitialized();
    if (!forceRefresh &&
        _cachedQrSession != null &&
        DateTime.now().difference(_cachedQrSessionAt) <
            const Duration(seconds: 180)) {
      return _cachedQrSession!;
    }
    final root = await _getJson(
      Uri.parse('https://qrcodeapi.115.com/api/1.0/web/1.0/token'),
      timeout: const Duration(seconds: 12),
    );
    if (root is! Map<String, dynamic> || root['data'] is! Map<String, dynamic>) {
      throw const ApiException('解析 115 二维码数据失败');
    }
    final data = root['data'] as Map<String, dynamic>;
    final uid = (data['uid'] ?? '').toString().trim();
    final time = int.tryParse((data['time'] ?? 0).toString()) ?? 0;
    final sign = (data['sign'] ?? '').toString().trim();
    final qrContent = (data['qrcode'] ?? 'https://115.com/scan/dg-$uid').toString();
    final imageUrl =
        'https://qrcodeapi.115.com/api/1.0/web/1.0/qrcode?qrfrom=1&client=0&uid=$uid';
    if (uid.isEmpty || sign.isEmpty) {
      throw const ApiException('获取 115 二维码 UID 失败');
    }
    final session = (
      uid: uid,
      time: time,
      sign: sign,
      qrContent: qrContent,
      imageUrl: imageUrl,
    );
    _cachedQrSession = session;
    _cachedQrSessionAt = DateTime.now();
    return session;
  }

  void invalidateCachedQrSession() {
    _cachedQrSession = null;
    _cachedQrSessionAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// Polls 115 QR code status (`https://qrcodeapi.115.com/get/status/`) and exchanges for Cookie when status == 2
  Future<({
    int status,
    String message,
    String? cookie,
    String? userName,
  })> pollQrCodeStatus({
    required String uid,
    required int time,
    required String sign,
    ApiClient? syncToServerApi,
  }) async {
    final uri = Uri.parse('https://qrcodeapi.115.com/get/status/').replace(
      queryParameters: <String, String>{
        'uid': uid,
        'time': time.toString(),
        'sign': sign,
        '_': (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
      },
    );
    try {
      final root = await _getJson(
        uri,
        timeout: const Duration(seconds: 30),
      );
      if (root is! Map<String, dynamic>) {
        return (
          status: 0,
          message: '请使用手机 115 网盘 App 扫描二维码',
          cookie: null,
          userName: null,
        );
      }
      final state = int.tryParse((root['state'] ?? 1).toString()) ?? 1;
      if (state == 0) {
        return (
          status: -2,
          message: '二维码已过期，请点击刷新二维码',
          cookie: null,
          userName: null,
        );
      }
      final data = (root['data'] is Map<String, dynamic>)
          ? (root['data'] as Map<String, dynamic>)
          : const <String, dynamic>{};
      final status = int.tryParse((data['status'] ?? 0).toString()) ?? 0;
      switch (status) {
        case 0:
          return (
            status: 0,
            message: '请使用手机 115 网盘 App 扫描二维码',
            cookie: null,
            userName: null,
          );
        case 1:
          return (
            status: 1,
            message: '✓ 已扫码，请在手机 115 App 上点击「确认登录」',
            cookie: null,
            userName: null,
          );
        case 2:
          final exchanged = await _exchangeQrCodeForCookie(uid);
          if (exchanged != null) {
            await saveCookie(
              exchanged.cookie,
              userName: exchanged.userName,
              syncToServerApi: syncToServerApi,
            );
            return (
              status: 2,
              message: '✓ 115 网盘扫码登录成功！',
              cookie: exchanged.cookie,
              userName: exchanged.userName,
            );
          }
          return (
            status: -1,
            message: '扫码成功但提取 Cookie 失败，请重试',
            cookie: null,
            userName: null,
          );
        case -2:
          return (
            status: -2,
            message: '已取消扫码或二维码已过期',
            cookie: null,
            userName: null,
          );
        default:
          return (
            status: status,
            message: (data['msg'] ?? '等待扫码确认...').toString(),
            cookie: null,
            userName: null,
          );
      }
    } catch (_) {
      return (
        status: 0,
        message: '等待手机 115 网盘 App 扫码...',
        cookie: null,
        userName: null,
      );
    }
  }

  Future<({String cookie, String userName})?> _exchangeQrCodeForCookie(
    String uid,
  ) async {
    for (final app in const ['tv', 'ios', 'android', 'mac', 'web']) {
      try {
        final uri = Uri.parse(
          'https://passportapi.115.com/app/1.0/$app/1.0/login/qrcode',
        );
        final root = await _postFormJson(
          uri,
          body: 'account=${Uri.encodeQueryComponent(uid)}&app=$app',
          timeout: const Duration(seconds: 12),
        );
        if (root is! Map<String, dynamic>) continue;
        final data = root['data'];
        if (data is! Map<String, dynamic>) continue;
        final cookieMap = data['cookie'];
        if (cookieMap is! Map<String, dynamic>) continue;
        final uidVal = (cookieMap['UID'] ?? '').toString().trim();
        final cidVal = (cookieMap['CID'] ?? '').toString().trim();
        final seidVal = (cookieMap['SEID'] ?? '').toString().trim();
        final kidVal = (cookieMap['KID'] ?? '').toString().trim();
        if (uidVal.isEmpty || cidVal.isEmpty || seidVal.isEmpty) continue;
        final parts = <String>[
          'UID=$uidVal',
          'CID=$cidVal',
          'SEID=$seidVal',
          if (kidVal.isNotEmpty) 'KID=$kidVal',
        ];
        final userName =
            (data['user_name'] ?? data['user_id'] ?? '115 用户').toString();
        return (cookie: parts.join('; '), userName: userName);
      } catch (_) {}
    }
    return null;
  }

  /// Searches 115 Cloud Drive directly from the local device for a video file matching [keywords]
  /// and resolves its official 115 domestic CDN direct playback URL.
  Future<Resolved115Stream?> findAndResolveDirectPlayUrl({
    required List<String> keywords,
    DateTime? allowNewestRecentFallbackAfter,
  }) async {
    await ensureInitialized();
    if (!hasLocalCookie) return null;

    final accelCid = await ensureAccelerationFolderCid();

    final cleanKeywords = keywords
        .map(_cleanMatchToken)
        .where((s) => s.isNotEmpty)
        .toList();

    final candidateFiles = <Map<String, dynamic>>[];
    final seenPickcodes = <String>{};

    void appendFiles(List<dynamic>? rawList, {bool fromTargetFolder = false}) {
      if (rawList == null) return;
      for (final item in rawList) {
        if (item is! Map<String, dynamic>) continue;
        final pc = (item['pc'] ?? item['pick_code'] ?? '').toString().trim();
        final fid = (item['fid'] ?? item['file_id'] ?? '').toString().trim();
        if (pc.isNotEmpty && fid.isNotEmpty && seenPickcodes.add(pc)) {
          final copy = Map<String, dynamic>.from(item);
          if (fromTargetFolder) {
            copy['_from_target_folder'] = true;
          }
          candidateFiles.add(copy);
        }
      }
    }

    // 1. Priority 0ms lookup: List the designated 115 acceleration folder (`/流光115加速`) directly
    // (bypasses 115's search indexing delay so newly uploaded files are found immediately)
    if (accelCid.isNotEmpty && accelCid != '0') {
      try {
        final targetUri = Uri.parse(
          'https://webapi.115.com/files?aid=1&cid=$accelCid&o=user_ptime&asc=0&offset=0&limit=45&show_dir=1&format=json',
        );
        final targetRoot =
            await _getJson(targetUri, timeout: const Duration(seconds: 12));
        if (targetRoot is Map<String, dynamic> && targetRoot['data'] is List) {
          appendFiles(
            targetRoot['data'] as List,
            fromTargetFolder: true,
          );
        }
      } catch (_) {}
    }

    // 2. Also list newest files in root (`cid=0`) and `/流光115加速` or `/115open` directory sorted by `user_ptime` desc
    try {
      final rootUri = Uri.parse(
        'https://webapi.115.com/files?aid=1&cid=0&o=user_ptime&asc=0&offset=0&limit=50&show_dir=1&format=json',
      );
      final root = await _getJson(rootUri, timeout: const Duration(seconds: 12));
      if (root is Map<String, dynamic> && root['data'] is List) {
        final rootEntries = root['data'] as List;
        appendFiles(rootEntries);
        final targetLower = targetFolderName.toLowerCase();
        for (final entry in rootEntries) {
          if (entry is! Map<String, dynamic>) continue;
          final fid = (entry['fid'] ?? '').toString();
          final cid = (entry['cid'] ?? '').toString();
          final name = (entry['n'] ?? '').toString().toLowerCase();
          if (fid.isEmpty &&
              cid.isNotEmpty &&
              cid != accelCid &&
              (name == targetLower ||
                  name == '115open' ||
                  name.contains('115') ||
                  name.contains('download'))) {
            final subUri = Uri.parse(
              'https://webapi.115.com/files?aid=1&cid=$cid&o=user_ptime&asc=0&offset=0&limit=40&show_dir=1&format=json',
            );
            final subRoot =
                await _getJson(subUri, timeout: const Duration(seconds: 12));
            if (subRoot is Map<String, dynamic> && subRoot['data'] is List) {
              appendFiles(
                subRoot['data'] as List,
                fromTargetFolder: name == targetLower,
              );
            }
          }
        }
      }
    } catch (_) {}

    // 3. Search by keyword via `webapi.115.com/files/search`
    for (final kw in keywords.take(3)) {
      final trimmed = kw.trim();
      if (trimmed.isEmpty) continue;
      final uri = Uri.parse('https://webapi.115.com/files/search').replace(
        queryParameters: <String, String>{
          'aid': '1',
          'cid': '0',
          'search_value': trimmed,
          'type': '4',
          'offset': '0',
          'limit': '25',
          'format': 'json',
          'show_dir': '1',
        },
      );
      try {
        final root = await _getJson(uri, timeout: const Duration(seconds: 12));
        if (root is Map<String, dynamic> && root['data'] is List) {
          appendFiles(root['data'] as List);
        }
      } catch (_) {}
    }

    if (candidateFiles.isEmpty) return null;

    // 4. Match file by normalized name or newest uploaded timestamp
    Map<String, dynamic>? matchedItem;
    for (final item in candidateFiles) {
      final rawName = (item['n'] ?? item['file_name'] ?? '').toString();
      final cleanName = _cleanMatchToken(rawName);
      if (cleanName.isEmpty) continue;
      if (cleanKeywords.any((kw) => _matchesCleanKeyword(cleanName, kw))) {
        matchedItem = item;
        break;
      }
    }

    if (matchedItem == null && allowNewestRecentFallbackAfter != null) {
      final minEpoch =
          (allowNewestRecentFallbackAfter.millisecondsSinceEpoch ~/ 1000) - 90;
      for (final item in candidateFiles) {
        final tp = int.tryParse(
              (item['tp'] ?? item['te'] ?? item['tu'] ?? item['t'] ?? 0)
                  .toString(),
            ) ??
            0;
        final iv = int.tryParse((item['iv'] ?? 0).toString()) ?? 0;
        final ico = (item['ico'] ?? '').toString().toLowerCase();
        final isVideo = iv == 1 ||
            const {
              'mp4',
              'f4v',
              'mkv',
              'ts',
              'mov',
              'flv',
              'avi',
              'rmvb',
              'wmv',
              'webm',
            }.contains(ico);
        if (isVideo && tp >= minEpoch) {
          matchedItem = item;
          break;
        }
      }
      // If uploaded via 115 Rapid Upload (秒传) into the designated acceleration folder (`/流光115加速`),
      // 115 may preserve the original rapid-upload timestamp; fall back to the top video in `/流光115加速`
      if (matchedItem == null) {
        for (final item in candidateFiles) {
          if (item['_from_target_folder'] != true) continue;
          final iv = int.tryParse((item['iv'] ?? 0).toString()) ?? 0;
          final ico = (item['ico'] ?? '').toString().toLowerCase();
          final isVideo = iv == 1 ||
              const {
                'mp4',
                'f4v',
                'mkv',
                'ts',
                'mov',
                'flv',
                'avi',
                'rmvb',
                'wmv',
                'webm',
              }.contains(ico);
          if (isVideo) {
            matchedItem = item;
            break;
          }
        }
      }
    }

    if (matchedItem == null) return null;
    final pickcode =
        (matchedItem['pc'] ?? matchedItem['pick_code'] ?? '').toString().trim();
    final fid =
        (matchedItem['fid'] ?? matchedItem['file_id'] ?? '').toString().trim();
    final itemCid =
        (matchedItem['cid'] ?? matchedItem['parent_id'] ?? '').toString().trim();
    final fileName =
        (matchedItem['n'] ?? matchedItem['file_name'] ?? '115 视频').toString();
    if (pickcode.isEmpty) return null;

    // If the file landed in 115 root (`cid == 0`, e.g. via CloudDrive2 FUSE mount),
    // automatically move it into the designated folder (`/流光115加速`)
    if ((itemCid.isEmpty || itemCid == '0') &&
        accelCid.isNotEmpty &&
        accelCid != '0' &&
        fid.isNotEmpty) {
      unawaited(move115FileToFolder(fid: fid, targetCid: accelCid));
    }

    final ico = (matchedItem['ico'] ?? '').toString().trim().toLowerCase();
    final nameLower = fileName.toLowerCase();
    final dotIdx = nameLower.lastIndexOf('.');
    final rawExt = ico.isNotEmpty
        ? '.$ico'
        : (dotIdx > 0 ? nameLower.substring(dotIdx) : '.mp4');
    final needsHlsTranscode = const {
      '.f4v',
      '.flv',
      '.mkv',
      '.avi',
      '.rmvb',
      '.wmv',
      '.ts',
      '.webm',
      '.iso',
    }.contains(rawExt);

    String? hlsUrl;
    if (needsHlsTranscode) {
      hlsUrl = await resolvePickcodeHlsM3u8Url(pickcode);
    }

    var directUrl = await resolvePickcodeStreamUrl(pickcode);
    if ((directUrl == null || directUrl.isEmpty) && hlsUrl == null) {
      hlsUrl = await resolvePickcodeHlsM3u8Url(pickcode);
    }
    directUrl ??= hlsUrl;
    if (directUrl == null || directUrl.isEmpty) return null;

    final headers = requestHeadersForUrl(directUrl);
    final String proxyUrl;
    if (needsHlsTranscode && hlsUrl != null && hlsUrl.isNotEmpty) {
      proxyUrl = await wrapWithLocal115HeaderProxy(
        hlsUrl,
        headers,
        extHint: '.m3u8',
      );
    } else if (directUrl.toLowerCase().contains('.m3u8')) {
      proxyUrl = await wrapWithLocal115HeaderProxy(
        directUrl,
        headers,
        extHint: '.m3u8',
      );
    } else {
      proxyUrl = await wrapWithLocal115HeaderProxy(
        directUrl,
        headers,
        extHint: rawExt.isNotEmpty ? rawExt : '.mp4',
      );
    }

    return Resolved115Stream(
      proxyStreamUrl: proxyUrl,
      directCdnUrl: directUrl,
      headers: headers,
      fileName: fileName,
    );
  }

  /// Resolves 115's official cloud transcode HLS `.m3u8` stream URL (`webapi.115.com/files/video?pickcode=...`),
  /// essential for playing `.f4v`, `.flv`, `.mkv`, `.avi`, `.rmvb`, `.wmv`, `.ts` containers smoothly across all platforms.
  Future<String?> resolvePickcodeHlsM3u8Url(String pickcode) async {
    final cleanPc = pickcode.trim();
    if (cleanPc.isEmpty) return null;
    try {
      final vidUri =
          Uri.parse('https://webapi.115.com/files/video?pickcode=$cleanPc');
      final root = await _getJson(vidUri, timeout: const Duration(seconds: 10));
      if (root is Map<String, dynamic>) {
        final listCandidate = root['video_urls'] ?? root['video_url'];
        if (listCandidate is List && listCandidate.isNotEmpty) {
          final last = listCandidate.last;
          if (last is Map<String, dynamic>) {
            final u = (last['url'] ?? '').toString().trim();
            if (u.startsWith('http')) {
              return u;
            }
          }
        }
        final directVideoUrl = (root['video_url'] ?? '').toString().trim();
        if (directVideoUrl.startsWith('http')) {
          return directVideoUrl;
        }
        final dataObj = root['data'];
        if (dataObj is Map<String, dynamic>) {
          final nested =
              (dataObj['video_url'] ?? dataObj['url'] ?? '').toString().trim();
          if (nested.startsWith('http')) {
            return nested;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Resolves a 115 `pickcode` to an official 115 domestic CDN direct URL using:
  /// 1) `proapi.115.com/app/chrome/downurl` (m115 encrypted original MP4 direct CDN link)
  /// 2) `webapi.115.com/files/download?pickcode=...`
  /// 3) `webapi.115.com/files/video?pickcode=...`
  final Map<String, ({String url, int timestampMs})> _pickcodeUrlCache = {};
  final Map<String, Future<String?>> _pickcodeInFlight = {};
  final Map<String, String> _cdnAuthCookiesByUrl = {};
  String _latestCdnAuthCookie = '';

  Map<String, String> requestHeadersForUrl(String url) {
    final base = Map<String, String>.from(requestHeaders);
    final extra = _cdnAuthCookiesByUrl[url] ?? _latestCdnAuthCookie;
    if (extra.isNotEmpty) {
      final cur = (base['Cookie'] ?? '').trim();
      if (!cur.contains(extra)) {
        base['Cookie'] = cur.isEmpty ? extra : '$cur; $extra';
      }
    }
    return base;
  }

  Future<String?> resolvePickcodeStreamUrl(
    String pickcode, {
    bool forceRefresh = false,
  }) async {
    final cleanPc = pickcode.trim();
    if (cleanPc.isEmpty) return null;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (!forceRefresh) {
      final cached = _pickcodeUrlCache[cleanPc];
      if (cached != null && (nowMs - cached.timestampMs) < 12000) {
        return cached.url;
      }
      final inflight = _pickcodeInFlight[cleanPc];
      if (inflight != null) {
        return await inflight;
      }
    }
    final fut = _resolvePickcodeStreamUrlInternal(cleanPc);
    _pickcodeInFlight[cleanPc] = fut;
    try {
      final res = await fut;
      if (res != null && res.isNotEmpty) {
        if (_pickcodeUrlCache.length > 64) {
          _pickcodeUrlCache.clear();
        }
        _pickcodeUrlCache[cleanPc] = (
          url: res,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
        );
      }
      return res;
    } finally {
      _pickcodeInFlight.remove(cleanPc);
    }
  }

  Future<String?> _resolvePickcodeStreamUrlInternal(String pickcode) async {
    // 1. Primary: `proapi.115.com/app/chrome/downurl`
    try {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final endpoint =
          Uri.parse('https://proapi.115.com/app/chrome/downurl?t=$nowSec');
      final key = M115Crypto.generateKey();
      final paramBytes = utf8.encode(jsonEncode({'pickcode': pickcode}));
      final encodedData = M115Crypto.encode(Uint8List.fromList(paramBytes), key);
      final body = 'data=${Uri.encodeQueryComponent(encodedData)}';
      final root = await _postFormJson(
        endpoint,
        body: body,
        timeout: const Duration(seconds: 12),
      );
      if (root is Map<String, dynamic> && root['data'] is String) {
        final decrypted = M115Crypto.decode(root['data'] as String, key);
        if (decrypted != null) {
          final decodedMap = jsonDecode(utf8.decode(decrypted, allowMalformed: true));
          if (decodedMap is Map<String, dynamic>) {
            for (final val in decodedMap.values) {
              if (val is Map<String, dynamic> && val['url'] is Map<String, dynamic>) {
                final urlObj = val['url'] as Map<String, dynamic>;
                final cdnUrl = (urlObj['url'] ?? '').toString().trim();
                if (cdnUrl.startsWith('http')) {
                  final authCookie = urlObj['auth_cookie'];
                  if (authCookie is Map) {
                    final acName = (authCookie['name'] ?? '').toString().trim();
                    final acVal = (authCookie['value'] ?? '').toString().trim();
                    if (acName.isNotEmpty && acVal.isNotEmpty) {
                      final pair = '$acName=$acVal';
                      if (_cdnAuthCookiesByUrl.length > 128) {
                        _cdnAuthCookiesByUrl.clear();
                      }
                      _cdnAuthCookiesByUrl[cdnUrl] = pair;
                      _latestCdnAuthCookie = pair;
                    }
                  } else if (_latestCdnAuthCookie.isNotEmpty) {
                    _cdnAuthCookiesByUrl[cdnUrl] = _latestCdnAuthCookie;
                  }
                  return cdnUrl;
                }
              }
            }
          }
        }
      }
    } catch (_) {}

    // 2. Fallback 1: `webapi.115.com/files/download?pickcode=...`
    try {
      final dlUri =
          Uri.parse('https://webapi.115.com/files/download?pickcode=$pickcode');
      final root = await _getJson(dlUri, timeout: const Duration(seconds: 10));
      if (root is Map<String, dynamic>) {
        final fileUrl = (root['file_url'] ?? '').toString().trim();
        if (fileUrl.startsWith('http')) {
          return fileUrl;
        }
        final dataObj = root['data'];
        if (dataObj is Map<String, dynamic>) {
          final nestedUrl =
              (dataObj['file_url'] ?? dataObj['url'] ?? '').toString().trim();
          if (nestedUrl.startsWith('http')) {
            return nestedUrl;
          }
        }
      }
    } catch (_) {}

    // 3. Fallback 2: `webapi.115.com/files/video?pickcode=...`
    try {
      final vidUri =
          Uri.parse('https://webapi.115.com/files/video?pickcode=$pickcode');
      final root = await _getJson(vidUri, timeout: const Duration(seconds: 10));
      if (root is Map<String, dynamic>) {
        final listCandidate = root['video_urls'] ?? root['video_url'];
        if (listCandidate is List && listCandidate.isNotEmpty) {
          final last = listCandidate.last;
          if (last is Map<String, dynamic>) {
            final u = (last['url'] ?? '').toString().trim();
            if (u.startsWith('http')) {
              return u;
            }
          }
        }
        final directVideoUrl = (root['video_url'] ?? '').toString().trim();
        if (directVideoUrl.startsWith('http')) {
          return directVideoUrl;
        }
      }
    } catch (_) {}

    return null;
  }

  /// Wraps a 115 CDN URL in a local loopback HTTP proxy (`http://127.0.0.1:<port>/115_stream.<ext>?u=...`)
  /// so that every Range request (and any 302 redirect) carries the exact `115Browser` User-Agent and Cookie headers
  /// and exposes the proper audio/video MIME Content-Type for AVPlayer / media_kit.
  Future<String> wrapWithLocal115HeaderProxy(
    String remoteUrl,
    Map<String, String> headers, {
    String extHint = '',
  }) async {
    await _ensureLocalProxyStarted();
    if (_proxyPort <= 0) return remoteUrl;
    if (_headersByUrl.length > 64) {
      _headersByUrl.clear();
    }
    final mergedHeaders = Map<String, String>.from(headers);
    final authCookie = _cdnAuthCookiesByUrl[remoteUrl] ??
        ((remoteUrl.contains('115cdn') || remoteUrl.contains('115.com'))
            ? _latestCdnAuthCookie
            : '');
    if (authCookie.isNotEmpty) {
      final curCookie =
          (mergedHeaders['Cookie'] ?? mergedHeaders['cookie'] ?? '').trim();
      if (!curCookie.contains(authCookie)) {
        mergedHeaders['Cookie'] =
            curCookie.isEmpty ? authCookie : '$curCookie; $authCookie';
      }
    }
    _headersByUrl[remoteUrl] = mergedHeaders;
    String cleanExt = extHint.trim().toLowerCase();
    if (cleanExt.isEmpty) {
      final pathPart = Uri.tryParse(remoteUrl)?.path.toLowerCase() ?? '';
      final dot = pathPart.lastIndexOf('.');
      if (dot > 0 && pathPart.length - dot <= 6) {
        cleanExt = pathPart.substring(dot);
      }
    }
    if (cleanExt.isEmpty || !cleanExt.startsWith('.')) {
      cleanExt = cleanExt.isEmpty ? '.mp4' : '.$cleanExt';
    }
    final enc = Uri.encodeQueryComponent(remoteUrl);
    return 'http://127.0.0.1:$_proxyPort/115_stream$cleanExt?u=$enc';
  }

  static String? _inferMimeTypeFromPath(String pathLower) {
    if (pathLower.endsWith('.mp3')) return 'audio/mpeg';
    if (pathLower.endsWith('.flac')) return 'audio/flac';
    if (pathLower.endsWith('.wav') || pathLower.endsWith('.wave')) {
      return 'audio/wav';
    }
    if (pathLower.endsWith('.ape') || pathLower.endsWith('.mac')) {
      return 'audio/x-ape';
    }
    if (pathLower.endsWith('.m4a') || pathLower.endsWith('.alac')) {
      return 'audio/mp4';
    }
    if (pathLower.endsWith('.aac')) return 'audio/aac';
    if (pathLower.endsWith('.ogg') ||
        pathLower.endsWith('.oga') ||
        pathLower.endsWith('.opus')) {
      return 'audio/ogg';
    }
    if (pathLower.endsWith('.aiff') ||
        pathLower.endsWith('.aif') ||
        pathLower.endsWith('.aifc')) {
      return 'audio/aiff';
    }
    if (pathLower.endsWith('.wma')) return 'audio/x-ms-wma';
    if (pathLower.endsWith('.dsf')) return 'audio/x-dsf';
    if (pathLower.endsWith('.dff')) return 'audio/x-dff';
    if (pathLower.endsWith('.wv')) return 'audio/x-wavpack';
    if (pathLower.endsWith('.tta')) return 'audio/x-tta';
    if (pathLower.endsWith('.tak')) return 'audio/x-tak';
    if (pathLower.endsWith('.mka')) return 'audio/x-matroska';
    if (pathLower.endsWith('.mp4') || pathLower.endsWith('.m4v')) {
      return 'video/mp4';
    }
    if (pathLower.endsWith('.mov')) return 'video/quicktime';
    return null;
  }

  final Map<
      String,
      ({
        int totalSize,
        String contentType,
        Uint8List rawHeaderChunk,
        Uint8List normalizedHeaderChunk,
        int stripPrefixBytes,
      })> _proxyMetaCache = {};

  Uint8List? getCachedRawHeaderBytes(String remoteUrl) {
    return _proxyMetaCache[remoteUrl]?.rawHeaderChunk;
  }

  /// Normalizes WAV headers that have:
  /// 1) Leading ID3v2 tags before `RIFF....WAVE` (which breaks strict WAVE demuxers/AVPlayer)
  /// 2) `WAVE_FORMAT_EXTENSIBLE` (`0xFFFE`) with standard PCM (`0x0001`) or IEEE Float (`0x0003`) subformat GUID
  /// 3) Bogus `0xFFFFFFFF` RIFF/data chunk sizes when total file size is known
  static ({
    Uint8List normalizedChunk,
    int stripPrefixBytes,
    String? detectedMimeType,
  }) normalizeWavOrAudioHeaderChunk(
    Uint8List raw,
    int rawTotalSize,
    String requestPathLower,
  ) {
    if (raw.length < 16) {
      return (
        normalizedChunk: raw,
        stripPrefixBytes: 0,
        detectedMimeType: null,
      );
    }

    int offset = 0;
    // Check if file starts with an ID3v2 tag (`ID3\x02` / `ID3\x03` / `ID3\x04`)
    if (raw[0] == 0x49 &&
        raw[1] == 0x44 &&
        raw[2] == 0x33 &&
        raw.length >= 10) {
      final id3Size = ((raw[6] & 0x7F) << 21) |
          ((raw[7] & 0x7F) << 14) |
          ((raw[8] & 0x7F) << 7) |
          (raw[9] & 0x7F);
      final hasFooter = (raw[5] & 0x10) != 0;
      final afterId3 = 10 + id3Size + (hasFooter ? 10 : 0);
      if (afterId3 + 12 <= raw.length) {
        // Check if `RIFF....WAVE` or `fLaC` follows the leading ID3v2 tag!
        if (raw[afterId3] == 0x52 &&
            raw[afterId3 + 1] == 0x49 &&
            raw[afterId3 + 2] == 0x46 &&
            raw[afterId3 + 3] == 0x46 &&
            raw[afterId3 + 8] == 0x57 &&
            raw[afterId3 + 9] == 0x41 &&
            raw[afterId3 + 10] == 0x56 &&
            raw[afterId3 + 11] == 0x45) {
          offset = afterId3;
        } else if (raw[afterId3] == 0x66 &&
            raw[afterId3 + 1] == 0x4C &&
            raw[afterId3 + 2] == 0x61 &&
            raw[afterId3 + 3] == 0x43) {
          offset = afterId3;
        }
      }
    }

    final view = offset > 0
        ? Uint8List.fromList(raw.sublist(offset))
        : Uint8List.fromList(raw);
    final effectiveTotal = max(0, rawTotalSize - offset);

    // Detect actual container magic bytes (handles `.flac` or `.mp3` files misnamed as `.wav`)
    if (view.length >= 4) {
      if (view[0] == 0x66 &&
          view[1] == 0x4C &&
          view[2] == 0x61 &&
          view[3] == 0x43) {
        return (
          normalizedChunk: view,
          stripPrefixBytes: offset,
          detectedMimeType: 'audio/flac',
        );
      }
      if (view[0] == 0x4D &&
          view[1] == 0x41 &&
          view[2] == 0x43 &&
          view[3] == 0x20) {
        return (
          normalizedChunk: view,
          stripPrefixBytes: offset,
          detectedMimeType: 'audio/x-ape',
        );
      }
      if ((view[0] == 0x49 && view[1] == 0x44 && view[2] == 0x33) ||
          (view[0] == 0xFF && (view[1] & 0xE0) == 0xE0)) {
        return (
          normalizedChunk: view,
          stripPrefixBytes: offset,
          detectedMimeType: 'audio/mpeg',
        );
      }
    }

    // Check `RIFF....WAVE`
    if (view.length >= 44 &&
        view[0] == 0x52 &&
        view[1] == 0x49 &&
        view[2] == 0x46 &&
        view[3] == 0x46 &&
        view[8] == 0x57 &&
        view[9] == 0x41 &&
        view[10] == 0x56 &&
        view[11] == 0x45) {
      final bd = ByteData.sublistView(view);
      final riffChunkSize = bd.getUint32(4, Endian.little);
      if (effectiveTotal > 8 &&
          (riffChunkSize == 0 ||
              riffChunkSize == 0xFFFFFFFF ||
              riffChunkSize > effectiveTotal)) {
        bd.setUint32(
          4,
          min(0xFFFFFFFE, effectiveTotal - 8),
          Endian.little,
        );
      }

      int pos = 12;
      while (pos + 8 <= view.length && pos < 4096) {
        final c0 = view[pos];
        final c1 = view[pos + 1];
        final c2 = view[pos + 2];
        final c3 = view[pos + 3];
        final chunkSize = bd.getUint32(pos + 4, Endian.little);

        // `fmt ` chunk
        if (c0 == 0x66 && c1 == 0x6D && c2 == 0x74 && c3 == 0x20) {
          if (pos + 8 + chunkSize <= view.length && chunkSize >= 16) {
            final audioFormat = bd.getUint16(pos + 8, Endian.little);
            // If `WAVE_FORMAT_EXTENSIBLE` (0xFFFE) and chunkSize >= 40, inspect SubFormat GUID
            if (audioFormat == 0xFFFE &&
                chunkSize >= 40 &&
                pos + 8 + 40 <= view.length) {
              final subFormatTag = bd.getUint16(pos + 8 + 24, Endian.little);
              // Standard KSDATAFORMAT_SUBTYPE_PCM (0x0001) or IEEE_FLOAT (0x0003) tail:
              // 00 00 10 00 80 00 00 AA 00 38 9B 71
              if ((subFormatTag == 0x0001 || subFormatTag == 0x0003) &&
                  view[pos + 8 + 28] == 0x10 &&
                  view[pos + 8 + 30] == 0x80 &&
                  view[pos + 8 + 35] == 0x38 &&
                  view[pos + 8 + 36] == 0x9B &&
                  view[pos + 8 + 37] == 0x71) {
                // Keep WAVE_FORMAT_EXTENSIBLE valid or ensure validBitsPerSample is non-zero
                final bitsPerSample = bd.getUint16(pos + 8 + 14, Endian.little);
                final validBits = bd.getUint16(pos + 8 + 18, Endian.little);
                if (validBits == 0 && bitsPerSample > 0) {
                  bd.setUint16(pos + 8 + 18, bitsPerSample, Endian.little);
                }
              }
            }
          }
        }

        // `data` chunk
        if (c0 == 0x64 && c1 == 0x61 && c2 == 0x74 && c3 == 0x61) {
          final dataStart = pos + 8;
          if (effectiveTotal > dataStart &&
              (chunkSize == 0 ||
                  chunkSize == 0xFFFFFFFF ||
                  dataStart + chunkSize > effectiveTotal)) {
            bd.setUint32(
              pos + 4,
              min(0xFFFFFFFE, effectiveTotal - dataStart),
              Endian.little,
            );
          }
          break;
        }

        if (chunkSize == 0 && c0 == 0 && c1 == 0) break;
        final padded = chunkSize + (chunkSize.isOdd ? 1 : 0);
        pos += 8 + padded;
      }

      return (
        normalizedChunk: view,
        stripPrefixBytes: offset,
        detectedMimeType: 'audio/wav',
      );
    }

    return (
      normalizedChunk: view,
      stripPrefixBytes: offset,
      detectedMimeType: null,
    );
  }

  Future<({Uint8List bytes, int statusCode, int totalSize, String contentType})?>
      _fetchUpstreamRangeChunk({
    required Uri uri,
    required Map<String, String> customHeaders,
    required int start,
    required int end,
    bool Function()? isCancelled,
  }) async {
    final expected = end - start + 1;
    for (int attempt = 0; attempt < 3; attempt++) {
      if (isCancelled != null && isCancelled()) return null;
      try {
        final upstreamReq = await _httpClient
            .openUrl('GET', uri)
            .timeout(Duration(seconds: attempt == 0 ? 15 : 22));
        upstreamReq.followRedirects = true;
        upstreamReq.maxRedirects = 5;
        customHeaders.forEach((k, v) {
          if (v.isNotEmpty) {
            upstreamReq.headers.set(k, v);
          }
        });
        upstreamReq.headers.set('Range', 'bytes=$start-$end');
        final upstreamResp = await upstreamReq
            .close()
            .timeout(Duration(seconds: attempt == 0 ? 18 : 25));
        if (isCancelled != null && isCancelled()) {
          try {
            final sock = await upstreamResp.detachSocket();
            sock.destroy();
          } catch (_) {}
          return null;
        }
        final code = upstreamResp.statusCode;
        if (code != HttpStatus.partialContent &&
            !(start == 0 && code == HttpStatus.ok)) {
          await upstreamResp.drain<void>().catchError((_) {});
          await Future<void>.delayed(
            Duration(milliseconds: (attempt + 1) * 200),
          );
          continue;
        }

        int totalSize = 0;
        final cr = upstreamResp.headers.value('content-range') ??
            upstreamResp.headers.value('Content-Range') ??
            '';
        final slash = cr.lastIndexOf('/');
        if (slash > 0) {
          totalSize = int.tryParse(cr.substring(slash + 1).trim()) ?? 0;
        }
        if (totalSize <= 0 && upstreamResp.contentLength > 0 && code == 200) {
          totalSize = upstreamResp.contentLength;
        }

        final builder = BytesBuilder(copy: false);
        await for (final chunk in upstreamResp) {
          if (isCancelled != null && isCancelled()) {
            try {
              final sock = await upstreamResp.detachSocket();
              sock.destroy();
            } catch (_) {}
            return null;
          }
          builder.add(chunk);
          if (builder.length >= expected) break;
        }
        final rawBytes = builder.takeBytes();
        if (rawBytes.isEmpty) continue;
        final sliced = rawBytes.length > expected
            ? Uint8List.sublistView(rawBytes, 0, expected)
            : rawBytes;
        final ct = (upstreamResp.headers.value('content-type') ?? '').trim();
        return (
          bytes: sliced,
          statusCode: code,
          totalSize: totalSize > 0 ? totalSize : sliced.length,
          contentType: ct,
        );
      } catch (_) {
        if (isCancelled != null && isCancelled()) return null;
        await Future<void>.delayed(
          Duration(milliseconds: (attempt + 1) * 200),
        );
      }
    }
    return null;
  }

  final Map<String, int> _activeStreamGenByUrl = {};

  Future<void> _ensureLocalProxyStarted() async {
    if (_proxyServer != null && _proxyPort > 0) return;
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _proxyServer = server;
      _proxyPort = server.port;
      server.listen(_handleProxyRequest, cancelOnError: false);
    } catch (_) {}
  }

  Future<void> _handleProxyRequest(HttpRequest req) async {
    final targetUrl = req.uri.queryParameters['u'] ?? '';
    final uri = Uri.tryParse(targetUrl);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      req.response.statusCode = HttpStatus.badRequest;
      await req.response.close();
      return;
    }

    final customHeaders = _headersByUrl[targetUrl] ?? requestHeaders;
    final rangeHeader =
        req.headers.value('range') ?? req.headers.value('Range');
    final reqPathLower = req.uri.path.toLowerCase();

    try {
      // 0. If this is an HLS `.m3u8` playlist (e.g. 115's official cloud transcode `https://115.com/api/video/m3u8/<pickcode>.m3u8`),
      // fetch the playlist with 115 Cookie & User-Agent, follow any master `#EXT-X-STREAM-INF` variant, and rewrite all `.ts` segment URLs
      // through this local 127.0.0.1 proxy so `libmpv` / `AVPlayer` can fetch every segment with the required 115 Cookie & User-Agent!
      if (reqPathLower.endsWith('.m3u8') ||
          uri.path.toLowerCase().endsWith('.m3u8')) {
        var currentM3u8Uri = uri;
        String? m3u8Text;
        for (var depth = 0; depth < 3; depth++) {
          final upReq = await _httpClient
              .getUrl(currentM3u8Uri)
              .timeout(const Duration(seconds: 12));
          customHeaders.forEach(upReq.headers.set);
          final upResp =
              await upReq.close().timeout(const Duration(seconds: 12));
          for (final c in upResp.cookies) {
            if (c.name.isNotEmpty && c.value.isNotEmpty) {
              _latestCdnAuthCookie = '${c.name}=${c.value}';
            }
          }
          if (upResp.statusCode < 200 || upResp.statusCode >= 400) break;
          final rawBytes = await upResp.fold<List<int>>(
            <int>[],
            (acc, b) => acc..addAll(b),
          );
          final text = utf8.decode(rawBytes, allowMalformed: true).trim();
          if (!text.contains('#EXTM3U')) break;
          m3u8Text = text;
          if (!text.contains('#EXT-X-STREAM-INF')) break;
          final lines = text
              .split(RegExp(r'\r?\n'))
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty && !l.startsWith('#'))
              .toList();
          if (lines.isEmpty) break;
          currentM3u8Uri = currentM3u8Uri.resolve(lines.last);
        }

        if (m3u8Text == null || m3u8Text.isEmpty) {
          req.response.statusCode = HttpStatus.badGateway;
          await req.response.close();
          return;
        }

        final uriAttrRegex = RegExp(r'URI="([^"]+)"');
        final outLines = <String>[];
        for (final rawLine in m3u8Text.split(RegExp(r'\r?\n'))) {
          final line = rawLine.trim();
          if (line.isEmpty) continue;
          if (line.startsWith('#')) {
            if (line.contains('URI="')) {
              final rewrittenTag = line.replaceAllMapped(uriAttrRegex, (m) {
                final rawAttr = m.group(1) ?? '';
                if (rawAttr.isEmpty) return m.group(0)!;
                final abs = currentM3u8Uri.resolve(rawAttr).toString();
                _headersByUrl[abs] = customHeaders;
                final enc = Uri.encodeQueryComponent(abs);
                return 'URI="http://127.0.0.1:$_proxyPort/115_stream.key?u=$enc"';
              });
              outLines.add(rewrittenTag);
            } else {
              outLines.add(line);
            }
          } else {
            final abs = currentM3u8Uri.resolve(line).toString();
            _headersByUrl[abs] = customHeaders;
            final enc = Uri.encodeQueryComponent(abs);
            final ext = abs.toLowerCase().contains('.m3u8') ? '.m3u8' : '.ts';
            outLines.add('http://127.0.0.1:$_proxyPort/115_stream$ext?u=$enc');
          }
        }
        final outBytes = utf8.encode('${outLines.join('\n')}\n');
        req.response.statusCode = HttpStatus.ok;
        req.response.contentLength = outBytes.length;
        req.response.headers
            .set('content-type', 'application/vnd.apple.mpegurl; charset=utf-8');
        req.response.headers.set('Access-Control-Allow-Origin', '*');
        req.response.add(outBytes);
        await req.response.close();
        return;
      }

      if (reqPathLower.endsWith('.ts') || reqPathLower.endsWith('.key')) {
        final upReq =
            await _httpClient.getUrl(uri).timeout(const Duration(seconds: 15));
        customHeaders.forEach(upReq.headers.set);
        if (rangeHeader != null && rangeHeader.isNotEmpty) {
          upReq.headers.set('Range', rangeHeader);
        }
        final upResp = await upReq.close().timeout(const Duration(seconds: 15));
        req.response.statusCode = upResp.statusCode;
        if (upResp.contentLength > 0) {
          req.response.contentLength = upResp.contentLength;
        }
        req.response.headers.set(
          'content-type',
          reqPathLower.endsWith('.ts')
              ? 'video/mp2t'
              : 'application/octet-stream',
        );
        req.response.headers.set('Access-Control-Allow-Origin', '*');
        await upResp.pipe(req.response);
        return;
      }

      // 1. Probe and cache first 256 KB (`bytes=0-262143`) + total file size so rapid WAV/FLAC/APE header probes
      // and trailing metadata seeks never open concurrent conflicting full-file connections to 115 CDN.
      var meta = _proxyMetaCache[targetUrl];
      if (meta == null) {
        final probe = await _fetchUpstreamRangeChunk(
          uri: uri,
          customHeaders: customHeaders,
          start: 0,
          end: 262143,
        );
        if (probe != null && probe.bytes.isNotEmpty) {
          final norm = normalizeWavOrAudioHeaderChunk(
            probe.bytes,
            probe.totalSize,
            reqPathLower,
          );
          final rawCt = probe.contentType.toLowerCase();
          String ct;
          if (norm.detectedMimeType != null) {
            ct = norm.detectedMimeType!;
          } else if (rawCt.isEmpty ||
              rawCt.contains('octet-stream') ||
              rawCt.contains('force-download')) {
            ct = _inferMimeTypeFromPath(reqPathLower) ??
                _inferMimeTypeFromPath(uri.path.toLowerCase()) ??
                'application/octet-stream';
          } else {
            ct = probe.contentType;
          }
          final effectiveTotal = max(
            norm.normalizedChunk.length,
            probe.totalSize - norm.stripPrefixBytes,
          );
          meta = (
            totalSize: effectiveTotal,
            contentType: ct,
            rawHeaderChunk: probe.bytes,
            normalizedHeaderChunk: norm.normalizedChunk,
            stripPrefixBytes: norm.stripPrefixBytes,
          );
          if (_proxyMetaCache.length > 32) {
            _proxyMetaCache.clear();
          }
          _proxyMetaCache[targetUrl] = meta;
        }
      }

      if (meta == null || meta.totalSize <= 0) {
        req.response.statusCode = HttpStatus.badGateway;
        await req.response.close();
        return;
      }

      int reqStart = 0;
      int reqEnd = meta.totalSize - 1;
      bool isPartial = false;
      if (rangeHeader != null &&
          rangeHeader.toLowerCase().startsWith('bytes=')) {
        isPartial = true;
        final spec = rangeHeader.substring(6).trim();
        final parts = spec.split('-');
        if (parts.length == 2) {
          final s = int.tryParse(parts[0].trim());
          if (s != null && s >= 0 && s < meta.totalSize) {
            reqStart = s;
          }
          if (parts[1].trim().isNotEmpty) {
            final e = int.tryParse(parts[1].trim());
            if (e != null) {
              reqEnd = min(meta.totalSize - 1, e);
            }
          }
        }
      }

      if (reqStart > reqEnd) {
        req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await req.response.close();
        return;
      }

      final contentLen = reqEnd - reqStart + 1;
      req.response.statusCode =
          isPartial ? HttpStatus.partialContent : HttpStatus.ok;
      req.response.bufferOutput = false;
      req.response.contentLength = contentLen;
      req.response.headers.set('content-type', meta.contentType);
      req.response.headers.set('accept-ranges', 'bytes');
      if (isPartial) {
        req.response.headers.set(
          'content-range',
          'bytes $reqStart-$reqEnd/${meta.totalSize}',
        );
      }
      req.response.headers.set('Access-Control-Allow-Origin', '*');

      if (req.method.toUpperCase() == 'HEAD') {
        await req.response.close();
        return;
      }

      // 2. Fast-path: serve small header probes directly from cached 256 KB normalizedHeaderChunk in 0ms
      if (reqEnd < meta.normalizedHeaderChunk.length) {
        req.response.add(
          Uint8List.sublistView(
            meta.normalizedHeaderChunk,
            reqStart,
            reqEnd + 1,
          ),
        );
        await req.response.close();
        return;
      }

      var cursor = reqStart;
      if (cursor < meta.normalizedHeaderChunk.length) {
        final cachedEnd = min(reqEnd, meta.normalizedHeaderChunk.length - 1);
        req.response.add(
          Uint8List.sublistView(
            meta.normalizedHeaderChunk,
            cursor,
            cachedEnd + 1,
          ),
        );
        await req.response.flush();
        cursor = cachedEnd + 1;
      }

      // 3. Supersede any previous active streaming loop on the same targetUrl (e.g. when libmpv aborts initial bytes=0-
      // to seek to the tail `moov` atom of a tail-moov MP4 or WAV file), and stream sequentially in 2 MB chunks
      final myStreamGen = (_activeStreamGenByUrl[targetUrl] ?? 0) + 1;
      _activeStreamGenByUrl[targetUrl] = myStreamGen;
      bool clientDisconnected = false;
      unawaited(
        req.response.done.then(
          (_) => clientDisconnected = true,
          onError: (_) => clientDisconnected = true,
        ),
      );
      bool isStreamCancelled() =>
          clientDisconnected || _activeStreamGenByUrl[targetUrl] != myStreamGen;

      const int chunkSize = 2097152;
      while (cursor <= reqEnd && !isStreamCancelled()) {
        final cStart = cursor;
        final cEnd = min(reqEnd, cStart + chunkSize - 1);
        final rawStart = cStart + meta.stripPrefixBytes;
        final rawEnd = cEnd + meta.stripPrefixBytes;

        final chunkRes = await _fetchUpstreamRangeChunk(
          uri: uri,
          customHeaders: customHeaders,
          start: rawStart,
          end: rawEnd,
          isCancelled: isStreamCancelled,
        );
        if (chunkRes == null || chunkRes.bytes.isEmpty || isStreamCancelled()) {
          break;
        }
        req.response.add(chunkRes.bytes);
        await req.response.flush();
        cursor += chunkRes.bytes.length;
      }

      await req.response.close();
    } catch (_) {
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  void cancelAcceleration() {
    _activePipelineId++;
    _isAccelerating = false;
    _stageTitle = '';
    _detailText = '';
    _progress = 0.0;
    notifyListeners();
  }

  /// Unwraps any local loopback proxy URL (`127.0.0.1:<port>/__m3u8_proxy__/...` or `127.0.0.1:<port>/115_stream...`),
  /// server proxy URL (`/api/vod/proxy?url=...&headers=...`), or inline TVBox pipe header (`url|User-Agent=...&Referer=...`)
  /// into its real remote upstream URL and merged HTTP headers so the backend server or 115 offline cloud can download it.
  static ({String url, Map<String, String> headers})
      unwrapDownloadTargetUrlAndHeaders(
    String rawUrl, [
    Map<String, String> baseHeaders = const {},
  ]) {
    var currentUrl = rawUrl.trim();
    final mergedHeaders = <String, String>{};
    baseHeaders.forEach((k, v) {
      if (k.trim().isNotEmpty && v.trim().isNotEmpty) {
        mergedHeaders[k.trim()] = v.trim();
      }
    });

    for (var depth = 0; depth < 4; depth++) {
      if (currentUrl.isEmpty) break;

      // 1. Strip inline TVBox pipe headers (`https://...|User-Agent=...&Referer=...`)
      final pipeIdx = currentUrl.indexOf('|');
      if (pipeIdx > 0) {
        final headerPart = currentUrl.substring(pipeIdx + 1).trim();
        currentUrl = currentUrl.substring(0, pipeIdx).trim();
        for (final pair in headerPart.split('&')) {
          final eq = pair.indexOf('=');
          if (eq > 0) {
            final hk = Uri.decodeComponent(pair.substring(0, eq).trim());
            final hv = Uri.decodeComponent(pair.substring(eq + 1).trim());
            if (hk.isNotEmpty && hv.isNotEmpty) {
              mergedHeaders[hk] = hv;
            }
          }
        }
      }

      // Strip `$label` suffix if present on an episode URL
      final dollarIdx = currentUrl.indexOf('\$');
      if (dollarIdx > 0 && currentUrl.startsWith('http')) {
        final beforeDollar = currentUrl.substring(0, dollarIdx).trim();
        if (beforeDollar.contains('://')) {
          currentUrl = beforeDollar;
        }
      }

      final uri = Uri.tryParse(currentUrl);
      if (uri == null) break;

      // 2. Unwrap local `__m3u8_proxy__` relay URL (`u=<base64url>&h=<base64url_json>`)
      if (uri.path.contains('/__m3u8_proxy__/')) {
        final encU =
            uri.queryParameters['u'] ?? uri.queryParameters['url'] ?? '';
        final encH = uri.queryParameters['h'] ?? '';
        if (encH.isNotEmpty) {
          try {
            final hJson = utf8.decode(
              base64Url.decode(base64Url.normalize(encH)),
              allowMalformed: true,
            );
            final hMap = jsonDecode(hJson);
            if (hMap is Map) {
              hMap.forEach((k, v) {
                final ks = k.toString().trim();
                final vs = (v ?? '').toString().trim();
                if (ks.isNotEmpty && vs.isNotEmpty) {
                  mergedHeaders[ks] = vs;
                }
              });
            }
          } catch (_) {}
        }
        if (encU.isNotEmpty) {
          try {
            final decU = utf8.decode(
              base64Url.decode(base64Url.normalize(encU)),
              allowMalformed: true,
            ).trim();
            if (decU.isNotEmpty && decU != currentUrl) {
              currentUrl = decU;
              continue;
            }
          } catch (_) {}
          if (encU.startsWith('http://') || encU.startsWith('https://')) {
            currentUrl = encU;
            continue;
          }
        }
      }

      // 3. Unwrap local `127.0.0.1` / `localhost` proxy URLs with `?u=<url>` or `?url=<url>`
      if (uri.host == '127.0.0.1' || uri.host == 'localhost') {
        final innerU =
            (uri.queryParameters['u'] ?? uri.queryParameters['url'] ?? '')
                .trim();
        if (innerU.startsWith('http://') || innerU.startsWith('https://')) {
          currentUrl = innerU;
          continue;
        }
      }

      // 4. Unwrap backend `/api/vod/proxy?url=<url>&headers=<base64url_json>`
      if (uri.path.endsWith('/api/vod/proxy')) {
        final innerU = (uri.queryParameters['url'] ?? '').trim();
        final encH = (uri.queryParameters['headers'] ?? '').trim();
        if (encH.isNotEmpty) {
          try {
            final hJson = utf8.decode(
              base64Url.decode(base64Url.normalize(encH)),
              allowMalformed: true,
            );
            final hMap = jsonDecode(hJson);
            if (hMap is Map) {
              hMap.forEach((k, v) {
                final ks = k.toString().trim();
                final vs = (v ?? '').toString().trim();
                if (ks.isNotEmpty && vs.isNotEmpty) {
                  mergedHeaders[ks] = vs;
                }
              });
            }
          } catch (_) {}
        }
        // Remove backend server auth headers when unwrapping to a third-party VOD CDN URL
        mergedHeaders.remove('Authorization');
        mergedHeaders.remove('X-Auth-Secret');
        if (innerU.startsWith('http://') || innerU.startsWith('https://')) {
          currentUrl = innerU;
          continue;
        }
      }

      break;
    }

    return (url: currentUrl, headers: mergedHeaders);
  }

  String _extractUidFromCookie() {
    for (final part in _cookie.split(';')) {
      final kv = part.trim().split('=');
      if (kv.length >= 2 && kv[0].trim().toUpperCase() == 'UID') {
        final rawUid = kv.sublist(1).join('=').trim();
        return rawUid.split('_').first.trim();
      }
    }
    return '';
  }

  /// Submits a URL to 115's official Cloud Offline Download (`离线下载` `lixian.115.com/lixian/?ct=lixian&ac=add_task_url`)
  /// targeting `/流光115加速` (`wp_path_id = targetFolderCid`) and polls for completion if the backend server download fails.
  Future<Resolved115Stream?> _try115CloudOfflineLixianFallback({
    required int pipelineId,
    required List<String> candidateUrls,
    required List<String> searchKeywords,
    required DateTime pipelineStartedAt,
  }) async {
    if (!hasLocalCookie) return null;
    final uid = _extractUidFromCookie();
    if (uid.isEmpty) return null;

    final eligibleUrls = <String>[];
    for (final raw in candidateUrls) {
      final u = unwrapDownloadTargetUrlAndHeaders(raw).url.trim();
      if (u.isEmpty) continue;
      final lower = u.toLowerCase();
      if (lower.contains('127.0.0.1') ||
          lower.contains('localhost') ||
          lower.contains('/api/telegram/') ||
          lower.contains('/api/vod/proxy') ||
          lower.contains('.m3u8')) {
        continue;
      }
      if (lower.startsWith('http://') ||
          lower.startsWith('https://') ||
          lower.startsWith('magnet:') ||
          lower.startsWith('ed2k://')) {
        if (!eligibleUrls.contains(u)) {
          eligibleUrls.add(u);
        }
      }
    }
    if (eligibleUrls.isEmpty) return null;

    _stageTitle = '服务器下载受限 · 正在切换 115 官方云端离线下载...';
    _detailText = '正在向 115 离线下载中心提交视频直链...';
    _progress = 0.65;
    notifyListeners();

    final accelCid = await ensureAccelerationFolderCid();
    String sign = '';
    String timeStr =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    try {
      final spaceRes = await _getJson(
        Uri.parse('https://115.com/?ct=offline&ac=space&_=$timeStr'),
        timeout: const Duration(seconds: 10),
      );
      if (spaceRes is Map<String, dynamic>) {
        sign = (spaceRes['sign'] ?? '').toString().trim();
        final t = (spaceRes['time'] ?? '').toString().trim();
        if (t.isNotEmpty) timeStr = t;
      }
    } catch (_) {}

    String addedInfoHash = '';
    String addedName = '';

    for (final targetUrl in eligibleUrls) {
      if (pipelineId != _activePipelineId) return null;
      final formParts = <String>[
        'url=${Uri.encodeQueryComponent(targetUrl)}',
        'uid=${Uri.encodeQueryComponent(uid)}',
        if (accelCid.isNotEmpty && accelCid != '0') ...[
          'wp_path_id=${Uri.encodeQueryComponent(accelCid)}',
          'savepath=',
        ],
        if (sign.isNotEmpty) 'sign=${Uri.encodeQueryComponent(sign)}',
        'time=${Uri.encodeQueryComponent(timeStr)}',
      ];
      final bodyStr = formParts.join('&');

      for (final endpoint in const [
        'https://lixian.115.com/lixian/?ct=lixian&ac=add_task_url',
        'https://115.com/web/lixian/?ct=lixian&ac=add_task_url',
      ]) {
        try {
          final res = await _postFormJson(
            Uri.parse(endpoint),
            body: bodyStr,
            timeout: const Duration(seconds: 12),
          );
          if (res is Map<String, dynamic>) {
            final state = res['state'] == true ||
                res['state'] == 1 ||
                res['errcode'] == 0 ||
                res['errno'] == 0;
            final infoHash = (res['info_hash'] ?? '').toString().trim();
            final name = (res['name'] ?? '').toString().trim();
            if (state || infoHash.isNotEmpty) {
              addedInfoHash = infoHash;
              addedName = name;
              break;
            }
          }
        } catch (_) {}
      }
      if (addedInfoHash.isNotEmpty || addedName.isNotEmpty) break;
    }

    if (addedInfoHash.isEmpty && addedName.isEmpty) {
      return null;
    }

    final mergedKeywords = <String>[
      if (addedName.isNotEmpty) addedName,
      ...searchKeywords,
    ];

    for (var poll = 0; poll < 25; poll++) {
      if (pipelineId != _activePipelineId) return null;

      // 1. Check if 115 offline task already completed (often 0.5s instant cloud hit!)
      final resolved = await findAndResolveDirectPlayUrl(
        keywords: mergedKeywords,
        allowNewestRecentFallbackAfter: pipelineStartedAt,
      );
      if (pipelineId != _activePipelineId) return null;
      if (resolved != null) {
        return resolved;
      }

      // 2. Query 115 offline task list progress (`lixian.115.com/lixian/?ct=lixian&ac=task_lists`)
      try {
        final listRes = await _getJson(
          Uri.parse('https://lixian.115.com/lixian/?ct=lixian&ac=task_lists'),
          timeout: const Duration(seconds: 10),
        );
        if (listRes is Map<String, dynamic> && listRes['tasks'] is List) {
          final tasks = listRes['tasks'] as List;
          Map<String, dynamic>? matchedLixian;
          for (final item in tasks) {
            if (item is Map<String, dynamic>) {
              final ih = (item['info_hash'] ?? '').toString().trim();
              final nm = (item['name'] ?? '').toString().trim();
              if ((addedInfoHash.isNotEmpty && ih == addedInfoHash) ||
                  (addedName.isNotEmpty && nm == addedName)) {
                matchedLixian = item;
                break;
              }
            }
          }
          if (matchedLixian != null) {
            final status =
                int.tryParse((matchedLixian['status'] ?? 0).toString()) ?? 0;
            final pct = double.tryParse(
                  (matchedLixian['percentDone'] ??
                          matchedLixian['percent'] ??
                          0)
                      .toString(),
                ) ??
                0.0;
            final fileId = (matchedLixian['file_id'] ??
                    matchedLixian['delete_file_id'] ??
                    '')
                .toString()
                .trim();
            _stageTitle = '阶段 2/3 · 115 官方云端正在离线下载该视频...';
            _progress = 0.68 + (pct.clamp(0.0, 100.0) / 100.0) * 0.22;
            _detailText =
                '115 云端离线进度 ${pct.toStringAsFixed(1)}% · ${matchedLixian['name'] ?? ''}';
            notifyListeners();

            if (status == -1) {
              break; // Offline task failed on 115
            }
            if ((status == 2 || pct >= 100.0) &&
                fileId.isNotEmpty &&
                fileId != '0') {
              if (accelCid.isNotEmpty && accelCid != '0') {
                unawaited(
                  move115FileToFolder(fid: fileId, targetCid: accelCid),
                );
              }
            }
          }
        }
      } catch (_) {}

      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }

    return null;
  }

  /// Full 3-stage pipeline with automatic URL unwrapping, stale-failed-task recovery,
  /// multi-line candidate failover, and 115 official Cloud Offline Download (`离线下载`) fallback:
  /// 1) Checks if the video is already in 115 Cloud Drive (`/流光115加速` priority, instant switch if found)
  /// 2) Unwraps any local loopback (`127.0.0.1`) / `/api/vod/proxy` / inline header URL, instructs the server to download (`POST /api/download`),
  ///    automatically retries or switches to backup candidate URLs if a line fails on the server, and falls back to 115 Cloud Offline Download if all server lines fail
  /// 3) Waits for 115 upload (`Uploading` / `/api/115/upload/:id` / CloudDrive2 sync), then resolves the official 115 domestic CDN direct link locally
  Future<Resolved115Stream?> run115CloudAccelerationPipeline({
    required ApiClient api,
    required String downloadUrl,
    required String videoName,
    Map<String, String> headers = const {},
    List<String> fallbackDownloadUrls = const [],
    String? telegramAccountId,
    void Function(String errorMessage)? onError,
  }) async {
    await ensureInitialized();
    final pipelineId = ++_activePipelineId;
    final cleanName = videoName
        .replaceAll('/', '_')
        .replaceAll(':', '_')
        .trim();
    final taskTitle = cleanName.isEmpty
        ? '115加速_${DateTime.now().millisecondsSinceEpoch ~/ 1000}'
        : cleanName;

    _isAccelerating = true;
    _stageTitle = '正在检索 115 网盘是否已存在该视频...';
    _detailText = taskTitle;
    _progress = 0.06;
    notifyListeners();

    final pipelineStartedAt = DateTime.now();

    // Ensure backend server also has our local 115 Cookie and designated target folder (`eleven_dir_id`)
    if (hasLocalCookie) {
      try {
        await api.login115WithCookie(_cookie);
      } catch (_) {}
      try {
        await ensureAccelerationFolderCid(syncToServerApi: api);
      } catch (_) {}
    }

    // Step 1: Fast-check if the video already exists in the user's 115 Cloud Drive
    final existing = await findAndResolveDirectPlayUrl(
      keywords: [taskTitle, videoName],
    );
    if (pipelineId != _activePipelineId) return null;
    if (existing != null) {
      _progress = 1.0;
      _isAccelerating = false;
      notifyListeners();
      return existing;
    }

    // Build ordered, deduplicated list of unwrapped candidate upstream URLs + headers
    final candidates = <({String url, Map<String, String> headers})>[];
    final seenUrls = <String>{};

    void addCandidate(String rawU, Map<String, String> baseH) {
      final unwrapped = unwrapDownloadTargetUrlAndHeaders(rawU, baseH);
      final u = unwrapped.url.trim();
      if (u.isEmpty) return;
      // Never send a local 127.0.0.1 / file:// loopback URL to the remote backend server!
      if (u.contains('://127.0.0.1') ||
          u.contains('://localhost') ||
          u.startsWith('file://')) {
        return;
      }
      if (seenUrls.add(u)) {
        candidates.add((url: u, headers: unwrapped.headers));
      }
    }

    addCandidate(downloadUrl, headers);
    for (final fb in fallbackDownloadUrls) {
      addCandidate(fb, headers);
    }

    if (candidates.isEmpty) {
      _isAccelerating = false;
      notifyListeners();
      onError?.call('无法提取有效的远程视频源链接（当前为本地环回地址），请切换线路后重试');
      return null;
    }

    String? matchedTaskId;
    String matchedOutputFile = '';
    String matchedTaskName = taskTitle;
    String lastServerFailureReason = '';
    bool serverDownloadSucceeded = false;

    // Step 2 & 3: Try each candidate URL on the backend server (with automatic cleanup/retry of stale Failed tasks)
    for (var cIdx = 0; cIdx < candidates.length; cIdx++) {
      if (pipelineId != _activePipelineId) return null;
      final candidate = candidates[cIdx];
      final lineLabel = candidates.length > 1
          ? ' (线路 ${cIdx + 1}/${candidates.length})'
          : '';

      _stageTitle = cIdx == 0
          ? '阶段 1/3 · 正在提交服务器高速下载任务...'
          : '阶段 1/3 · 当前线路下载失败，正在自动切换备用线路 (${cIdx + 1}/${candidates.length})...';
      _detailText = '$taskTitle$lineLabel';
      _progress = 0.10;
      notifyListeners();

      // Pre-clean any stale Failed task with the same name or URL so `/api/download` doesn't attach to an old Failed task
      try {
        final existingTasks = await api.fetchDownloadTasks();
        for (final t in existingTasks) {
          if ((t.name == taskTitle || t.url == candidate.url) &&
              t.status == 'Failed') {
            try {
              await api.deleteDownloadTask(t.id, deleteFiles: true);
            } catch (_) {}
          }
        }
      } catch (_) {}

      String? createdTaskId;
      try {
        createdTaskId = await api.createDownloadTask(
          url: candidate.url,
          name: taskTitle,
          headers: candidate.headers,
          telegramAccountId: telegramAccountId,
          forceDuplicate: cIdx > 0,
        );
      } catch (e) {
        lastServerFailureReason = '$e';
        continue;
      }

      matchedTaskId = createdTaskId;
      bool didTriggerManual115Upload = false;
      bool didRetryFailedTaskOnce = false;
      bool candidateFailed = false;

      for (var pollTick = 0; pollTick < 600; pollTick++) {
        if (pipelineId != _activePipelineId) return null;
        List<dynamic> tasks = const [];
        try {
          tasks = await api.fetchDownloadTasks();
        } catch (_) {}
        if (pipelineId != _activePipelineId) return null;

        dynamic matchedTask;
        if (matchedTaskId != null && matchedTaskId.isNotEmpty) {
          for (final t in tasks) {
            if (t.id == matchedTaskId) {
              matchedTask = t;
              break;
            }
          }
        }
        if (matchedTask == null) {
          // Prefer non-Failed task matching url or name
          for (final t in tasks) {
            if ((t.url == candidate.url || t.name == taskTitle) &&
                t.status != 'Failed') {
              matchedTask = t;
              matchedTaskId = t.id;
              break;
            }
          }
          if (matchedTask == null) {
            for (final t in tasks) {
              if (t.url == candidate.url || t.name == taskTitle) {
                matchedTask = t;
                matchedTaskId = t.id;
                break;
              }
            }
          }
        }

        if (matchedTask != null) {
          matchedOutputFile = matchedTask.outputFile;
          matchedTaskName = matchedTask.name;
          final status = matchedTask.status as String;
          final prog = (matchedTask.progress as double).clamp(1.0, 99.5);

          if (status == 'Pending' || status == 'Downloading') {
            _stageTitle = '阶段 1/3 · 服务器正在高速下载该视频$lineLabel...';
            _progress = 0.10 + (prog / 100.0) * 0.58;
            final segInfo = matchedTask.totalSegments > 0
                ? ' · 分片 ${matchedTask.downloadedSegments}/${matchedTask.totalSegments}'
                : '';
            _detailText =
                '下载进度 ${prog.toStringAsFixed(1)}% · 速度 ${matchedTask.formattedSpeed}$segInfo';
            notifyListeners();
          } else if (status == 'Converting') {
            _stageTitle = '阶段 1/3 · 服务器正在无损转封装 MP4...';
            _progress = 0.70;
            _detailText = '即将自动上传至 115 网盘';
            notifyListeners();
          } else if (status == 'Uploading') {
            _stageTitle = '阶段 2/3 · 服务器正在上传视频至 115 网盘...';
            _progress = 0.72 + (prog / 100.0) * 0.18;
            _detailText =
                '上传 115 进度 ${prog.toStringAsFixed(1)}% · ${matchedTask.name}';
            notifyListeners();
          } else if (status == 'Completed' || status == 'Duplicate') {
            serverDownloadSucceeded = true;
            final quickCheckKeywords = <String>[
              if (matchedOutputFile.isNotEmpty)
                matchedOutputFile.split('/').last,
              if (matchedTaskName.isNotEmpty) matchedTaskName,
              taskTitle,
              videoName,
            ];
            final alreadyIn115 = await findAndResolveDirectPlayUrl(
              keywords: quickCheckKeywords,
              allowNewestRecentFallbackAfter: pipelineStartedAt,
            );
            if (pipelineId != _activePipelineId) return null;
            if (alreadyIn115 != null) {
              _progress = 1.0;
              _isAccelerating = false;
              notifyListeners();
              return alreadyIn115;
            }

            if (!didTriggerManual115Upload) {
              didTriggerManual115Upload = true;
              final errStr = (matchedTask.error as String).toLowerCase();
              if (errStr.contains('115') || matchedOutputFile.isNotEmpty) {
                _stageTitle =
                    '阶段 2/3 · 正在同步视频至 115 网盘 (/$targetFolderName)...';
                _progress = 0.76;
                _detailText = '正在触发 115 秒传 / 接口上传...';
                notifyListeners();
                try {
                  await api.uploadTaskTo115(matchedTask.id);
                } catch (_) {}
                if (matchedOutputFile.isNotEmpty) {
                  try {
                    await api.uploadFileTo115(matchedOutputFile);
                  } catch (_) {}
                }
                await Future<void>.delayed(const Duration(milliseconds: 1200));
                try {
                  final refreshed = await api.fetchDownloadTasks();
                  final reTask = refreshed
                      .where((x) => x.id == matchedTask.id)
                      .firstOrNull;
                  if (reTask != null && reTask.status == 'Uploading') {
                    continue;
                  }
                } catch (_) {}
              }
            }
            break;
          } else if (status == 'Failed') {
            final errText = (matchedTask.error as String).trim();
            lastServerFailureReason =
                errText.isEmpty ? '视频源连接被拒绝或超时' : errText;

            // Check if the file actually finished downloading (`outputFile` exists or error is only a 115 upload warning)
            if (matchedOutputFile.isNotEmpty && !didTriggerManual115Upload) {
              didTriggerManual115Upload = true;
              _stageTitle =
                  '阶段 2/3 · 正在重新上传视频至 115 网盘 (/$targetFolderName)...';
              _progress = 0.76;
              _detailText = '正在触发 115 秒传 / 接口上传...';
              notifyListeners();
              try {
                await api.uploadTaskTo115(matchedTask.id);
              } catch (_) {}
              try {
                await api.uploadFileTo115(matchedOutputFile);
              } catch (_) {}
              await Future<void>.delayed(const Duration(milliseconds: 1500));
              final postUpload = await findAndResolveDirectPlayUrl(
                keywords: [
                  matchedOutputFile.split('/').last,
                  matchedTaskName,
                  taskTitle,
                  videoName,
                ],
                allowNewestRecentFallbackAfter: pipelineStartedAt,
              );
              if (pipelineId != _activePipelineId) return null;
              if (postUpload != null) {
                _progress = 1.0;
                _isAccelerating = false;
                notifyListeners();
                return postUpload;
              }
            }

            // If this is the first failure on pollTick <= 1 (e.g. attached to a stale task or transient hiccup), retry once on server
            if (!didRetryFailedTaskOnce && cIdx == candidates.length - 1) {
              didRetryFailedTaskOnce = true;
              _stageTitle = '阶段 1/3 · 服务器下载遇到波动，正在自动重试...';
              _detailText = lastServerFailureReason;
              notifyListeners();
              try {
                await api.retryDownloadTask(matchedTask.id);
                await Future<void>.delayed(const Duration(milliseconds: 1500));
                continue;
              } catch (_) {}
            }

            candidateFailed = true;
            break;
          }
        } else if (pollTick >= 4) {
          serverDownloadSucceeded = true;
          break;
        }

        await Future<void>.delayed(const Duration(milliseconds: 1200));
      }

      if (serverDownloadSucceeded && !candidateFailed) {
        break;
      }
    }

    if (pipelineId != _activePipelineId) return null;

    final keywords = <String>[
      if (matchedOutputFile.isNotEmpty)
        matchedOutputFile.split('/').last,
      if (matchedTaskName.isNotEmpty) matchedTaskName,
      taskTitle,
      videoName,
    ];

    // If all server download candidates failed, try 115 Official Cloud Offline Download (`离线下载` `add_task_url`)
    // and check if the file is already available in 115 Cloud Drive!
    if (!serverDownloadSucceeded) {
      final lixianResolved = await _try115CloudOfflineLixianFallback(
        pipelineId: pipelineId,
        candidateUrls: candidates.map((c) => c.url).toList(),
        searchKeywords: keywords,
        pipelineStartedAt: pipelineStartedAt,
      );
      if (pipelineId != _activePipelineId) return null;
      if (lixianResolved != null) {
        _progress = 1.0;
        _isAccelerating = false;
        notifyListeners();
        return lixianResolved;
      }

      // One final check in 115 Cloud Drive in case a background sync or existing file matched
      final finalCheck = await findAndResolveDirectPlayUrl(
        keywords: keywords,
        allowNewestRecentFallbackAfter: pipelineStartedAt,
      );
      if (pipelineId != _activePipelineId) return null;
      if (finalCheck != null) {
        _progress = 1.0;
        _isAccelerating = false;
        notifyListeners();
        return finalCheck;
      }

      _isAccelerating = false;
      notifyListeners();
      final errDetail = lastServerFailureReason.isEmpty
          ? '当前视频源防盗链限制了海外服务器下载，建议切换其他播放线路后再试'
          : lastServerFailureReason;
      onError?.call('服务器下载失败：$errDetail');
      return null;
    }

    // Step 4: Poll local 115 Cloud Drive to get the official 115 domestic CDN direct URL
    _stageTitle = '阶段 3/3 · 正在从本地连接 115 获取高速直链...';
    _progress = 0.92;
    notifyListeners();

    for (var attempt = 0; attempt < 25; attempt++) {
      if (pipelineId != _activePipelineId) return null;
      _detailText = attempt == 0
          ? '正在通过本地网络请求 115 官方直链...'
          : '正在等待 115 网盘完成文件索引 (${attempt + 1}/25)...';
      notifyListeners();

      final resolved115 = await findAndResolveDirectPlayUrl(
        keywords: keywords,
        allowNewestRecentFallbackAfter: pipelineStartedAt,
      );
      if (pipelineId != _activePipelineId) return null;
      if (resolved115 != null) {
        _progress = 1.0;
        _isAccelerating = false;
        notifyListeners();
        return resolved115;
      }

      if (matchedTaskId != null && matchedTaskId.isNotEmpty) {
        try {
          final tasks = await api.fetchDownloadTasks();
          final t = tasks.where((x) => x.id == matchedTaskId).firstOrNull;
          if (t != null && t.status == 'Uploading') {
            final upPct = t.progress.clamp(1.0, 99.5);
            _stageTitle = '阶段 2/3 · 服务器正在上传视频至 115 网盘...';
            _progress = 0.72 + (upPct / 100.0) * 0.20;
            _detailText =
                '上传 115 进度 ${upPct.toStringAsFixed(1)}% · ${t.name}';
            notifyListeners();
          }
        } catch (_) {}
      }

      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }

    if (pipelineId != _activePipelineId) return null;
    _isAccelerating = false;
    notifyListeners();
    onError?.call('暂未在 115 网盘中找到已上传文件，请确认 115 账号已登录且空间充足');
    return null;
  }

  Future<dynamic> _getJson(
    Uri uri, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final req = await _httpClient.getUrl(uri).timeout(timeout);
    requestHeaders.forEach(req.headers.set);
    final resp = await req.close().timeout(timeout);
    for (final c in resp.cookies) {
      if (c.name.isNotEmpty && c.value.isNotEmpty) {
        _latestCdnAuthCookie = '${c.name}=${c.value}';
      }
    }
    final bytes = await resp.fold<List<int>>(<int>[], (acc, b) => acc..addAll(b));
    final text = utf8.decode(bytes, allowMalformed: true).trim();
    if (text.isEmpty) return null;
    return jsonDecode(text);
  }

  Future<dynamic> _postFormJson(
    Uri uri, {
    required String body,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final req = await _httpClient.postUrl(uri).timeout(timeout);
    requestHeaders.forEach(req.headers.set);
    req.headers.set('Content-Type', 'application/x-www-form-urlencoded');
    final bodyBytes = utf8.encode(body);
    req.contentLength = bodyBytes.length;
    req.add(bodyBytes);
    final resp = await req.close().timeout(timeout);
    for (final c in resp.cookies) {
      if (c.name.isNotEmpty && c.value.isNotEmpty) {
        _latestCdnAuthCookie = '${c.name}=${c.value}';
      }
    }
    final bytes = await resp.fold<List<int>>(<int>[], (acc, b) => acc..addAll(b));
    final text = utf8.decode(bytes, allowMalformed: true).trim();
    if (text.isEmpty) return null;
    return jsonDecode(text);
  }

  static String _cleanMatchToken(String raw) {
    var s = raw.split('/').last.trim();
    s = s.replaceFirst(RegExp(r'^tg_\d+_'), '');
    for (var pass = 0; pass < 3; pass++) {
      var stripped = false;
      for (final ext in const [
        '.mp4',
        '.f4v',
        '.ts',
        '.mkv',
        '.mov',
        '.flv',
        '.avi',
        '.rmvb',
        '.wmv',
        '.webm',
        '.m3u8',
      ]) {
        if (s.toLowerCase().endsWith(ext)) {
          s = s.substring(0, s.length - ext.length);
          stripped = true;
        }
      }
      if (!stripped) break;
    }
    s = s.replaceAll(RegExp(r'[《》【】\[\]\(\)（）\-—_·:\s]+'), '');
    return s.toLowerCase().trim();
  }

  static bool _matchesCleanKeyword(String cleanName, String cleanKw) {
    if (cleanName.isEmpty || cleanKw.isEmpty) return false;
    if (cleanName == cleanKw ||
        cleanName.contains(cleanKw) ||
        cleanKw.contains(cleanName)) {
      return true;
    }
    // Also match when VOD detail title is "有五个姐姐的我第06集" vs 115 file "有五个姐姐的我第二季6"
    String normEpisodeNum(String input) {
      return input.replaceAllMapped(
        RegExp(r'第0*(\d+)[集话期]?'),
        (m) => m.group(1) ?? '',
      );
    }

    final n1 = normEpisodeNum(cleanName);
    final n2 = normEpisodeNum(cleanKw);
    if (n1 == n2 || n1.contains(n2) || n2.contains(n1)) {
      return true;
    }
    // Strip "第X季" if one side has season and the other doesn't
    final s1 = n1.replaceAll(RegExp(r'第[一二三四五六七八九十\d]+季'), '');
    final s2 = n2.replaceAll(RegExp(r'第[一二三四五六七八九十\d]+季'), '');
    if (s1.length >= 2 &&
        s2.length >= 2 &&
        (s1 == s2 || s1.contains(s2) || s2.contains(s1))) {
      return true;
    }
    return false;
  }

  // MARK: - 115 Cloud Drive Directory Browser & File Operations for Multi-Storage File Manager

  final Map<String, String> _cidParentMap = {'0': ''};
  final Map<String, String> _cidNameMap = {'0': '115根目录'};

  String parentCidFor(String cid) {
    if (cid.isEmpty || cid == '0' || cid == '/') return '';
    return _cidParentMap[cid] ?? '0';
  }

  Future<FileDirectoryListing> list115Directory({
    required String cid,
    String mountId = 'builtin_115',
    int maxPages = 15,
  }) async {
    await ensureInitialized();
    if (!hasLocalCookie) {
      throw const ApiException('请先扫码或使用 Cookie 登录 115 网盘账号');
    }
    final cleanCid = (cid.isEmpty || cid == '/') ? '0' : cid;
    const pageLimit = 115;

    Map<String, dynamic>? root;
    final allRawItems = <dynamic>[];
    bool anyStateOk = false;

    for (var page = 0; page < maxPages; page++) {
      final offset = page * pageLimit;
      final candidateUrls = <String>[
        'https://webapi.115.com/files?aid=1&cid=$cleanCid&o=user_ptime&asc=0&offset=$offset&limit=$pageLimit&show_dir=1&format=json',
        'https://aps.115.com/natsort/files.php?aid=1&cid=$cleanCid&o=file_name&asc=1&offset=$offset&limit=$pageLimit&show_dir=1&natsort=1&format=json',
        'https://proapi.115.com/android/2.0/ufile/files?aid=1&cid=$cleanCid&o=user_ptime&asc=0&offset=$offset&limit=$pageLimit&show_dir=1',
      ];

      List<dynamic>? pageItems;
      int totalCount = 0;
      for (final urlStr in candidateUrls) {
        try {
          final res = await _getJson(
            Uri.parse(urlStr),
            timeout: const Duration(seconds: 15),
          );
          if (res is Map<String, dynamic>) {
            root ??= res;
            final stateVal = res['state'];
            final isStateOk = stateVal == true ||
                (int.tryParse((stateVal ?? 0).toString()) ?? 0) == 1;
            final errNo = int.tryParse(
                  (res['errNo'] ?? res['errno'] ?? res['errCode'] ?? 0)
                      .toString(),
                ) ??
                0;
            if (isStateOk) {
              anyStateOk = true;
              root = res;
            }
            totalCount = int.tryParse((res['count'] ?? 0).toString()) ?? 0;
            if (res['data'] is List) {
              final arr = res['data'] as List;
              if (arr.isNotEmpty) {
                root = res;
                pageItems = arr;
                anyStateOk = true;
                break;
              } else if (isStateOk && errNo == 0) {
                root = res;
                pageItems = const [];
                break;
              }
            }
          }
        } catch (_) {}
      }

      if (pageItems == null || pageItems.isEmpty) {
        break;
      }
      allRawItems.addAll(pageItems);
      if (pageItems.length < 40 ||
          (totalCount > 0 && allRawItems.length >= totalCount)) {
        break;
      }
    }

    final List<dynamic>? rawItems = allRawItems.isEmpty ? null : allRawItems;

    if ((rawItems == null || rawItems.isEmpty) && !anyStateOk && root != null) {
      final errNo = int.tryParse(
            (root['errNo'] ?? root['errno'] ?? root['errCode'] ?? 0).toString(),
          ) ??
          0;
      final errMsg = (root['error'] ?? root['msg'] ?? '').toString().trim();
      if (errNo == 99 || errNo == 990001 || errMsg.contains('登录')) {
        await clearCookie();
        throw const ApiException('115 网盘登录已过期或被其他设备/AList顶下线，请重新扫码登录');
      }
      if (errMsg.isNotEmpty) {
        throw ApiException('115 接口返回：$errMsg (code $errNo)');
      }
    }

    if (root == null) {
      return FileDirectoryListing(
        path: cleanCid,
        parent: parentCidFor(cleanCid),
        root: '0',
        entries: const [],
      );
    }

    var resolvedParent = parentCidFor(cleanCid);
    final pathArr = root['path'];
    if (pathArr is List && pathArr.isNotEmpty) {
      var prevCid = '';
      for (final seg in pathArr) {
        if (seg is Map<String, dynamic>) {
          final scid = (seg['cid'] ?? '0').toString();
          final sname = (seg['name'] ?? '目录').toString();
          if (prevCid.isNotEmpty && scid != prevCid) {
            _cidParentMap[scid] = prevCid;
          }
          _cidNameMap[scid] = sname;
          prevCid = scid;
        }
      }
      if (pathArr.length >= 2) {
        final pen = pathArr[pathArr.length - 2];
        if (pen is Map<String, dynamic>) {
          resolvedParent = (pen['cid'] ?? '0').toString();
        }
      } else if (cleanCid != '0') {
        resolvedParent = '0';
      } else {
        resolvedParent = '';
      }
    }

    final entries = <FileEntry>[];
    final seenEntryKeys = <String>{};
    if (rawItems != null) {
      for (final item in rawItems) {
        if (item is! Map<String, dynamic>) continue;
        final fid = (item['fid'] ?? '').toString().trim();
        final itemCid = (item['cid'] ?? '').toString().trim();
        final hasValidFid = fid.isNotEmpty && fid != '0';
        final isDir = !hasValidFid && itemCid.isNotEmpty && itemCid != '0';
        final name = (item['n'] ?? item['ns'] ?? item['fn'] ?? '未命名').toString();
        final size = int.tryParse((item['s'] ?? item['fs'] ?? 0).toString()) ?? 0;
        final pickcode =
            (item['pc'] ?? item['pick_code'] ?? '').toString().trim();
        final ico = (item['ico'] ?? '').toString().toLowerCase().trim().replaceAll('.', '');
        final is115Video =
            (int.tryParse((item['iv'] ?? 0).toString()) ?? 0) == 1 ||
            item['vdi'] != null;
        String ext = '';
        if (!isDir) {
          final dot = name.lastIndexOf('.');
          if (dot > 0 && dot < name.length - 1) {
            ext = name.substring(dot).toLowerCase();
          } else if (ico.isNotEmpty) {
            ext = '.$ico';
          } else if (is115Video) {
            ext = '.mp4';
          }
        }
        final ts = int.tryParse(
              (item['te'] ?? item['tp'] ?? item['t'] ?? 0).toString(),
            ) ??
            0;
        String modStr = (item['te'] ?? '').toString();
        if (ts > 100000) {
          final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
          modStr =
              '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
              '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
        }
        final thumb = (item['u'] ?? '').toString();
        final entryPath = isDir ? itemCid : (hasValidFid ? fid : pickcode);
        if (!seenEntryKeys.add('${isDir ? "D" : "F"}::$entryPath::$name')) {
          continue;
        }
        if (isDir) {
          _cidParentMap[itemCid] = cleanCid;
          _cidNameMap[itemCid] = name;
        }
        entries.add(
          FileEntry(
            name: name,
            path: entryPath,
            size: size,
            modTime: modStr,
            isDir: isDir,
            isMp4: ext == '.mp4' || (is115Video && ext.isEmpty),
            ext: ext,
            mountId: mountId,
            sourceKind: StorageSourceKind.cloud115,
            thumbUrl: thumb,
            pickcode115: pickcode,
            fid115: isDir ? itemCid : fid,
            cid115: isDir ? itemCid : cleanCid,
          ),
        );
      }
    }

    return FileDirectoryListing(
      path: cleanCid,
      parent: cleanCid == '0' ? '' : resolvedParent,
      root: '0',
      entries: entries,
    );
  }

  Future<void> create115Folder({
    required String parentCid,
    required String name,
  }) async {
    await ensureInitialized();
    if (!hasLocalCookie) return;
    final pid = (parentCid.isEmpty || parentCid == '/') ? '0' : parentCid;
    final body =
        'pid=${Uri.encodeQueryComponent(pid)}&cname=${Uri.encodeQueryComponent(name)}';
    await _postFormJson(
      Uri.parse('https://webapi.115.com/files/add'),
      body: body,
    );
  }

  Future<void> rename115File({
    required String fid,
    required String newName,
  }) async {
    await ensureInitialized();
    if (!hasLocalCookie) return;
    final body =
        'files_new_name[$fid]=${Uri.encodeQueryComponent(newName)}';
    await _postFormJson(
      Uri.parse('https://webapi.115.com/files/batch_rename'),
      body: body,
    );
  }

  Future<void> delete115File({
    required String fid,
    required String parentCid,
  }) async {
    await ensureInitialized();
    if (!hasLocalCookie) return;
    final pid = (parentCid.isEmpty || parentCid == '/') ? '0' : parentCid;
    final body =
        'pid=${Uri.encodeQueryComponent(pid)}&fid[0]=${Uri.encodeQueryComponent(fid)}&ignore_warn=1';
    await _postFormJson(
      Uri.parse('https://rb.115.com/2.0/rb/delete'),
      body: body,
    );
  }
}
