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

  String _cookie = '';
  String _userName = '';
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
        if (_cookie.isNotEmpty) 'Cookie': _cookie,
      };

  Future<void> ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _cookie = normalizeCookieString(prefs.getString(_prefCookieKey) ?? '');
      _userName = prefs.getString(_prefUserNameKey) ?? '';
      notifyListeners();
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

    final cleanKeywords = keywords
        .map(_cleanMatchToken)
        .where((s) => s.isNotEmpty)
        .toList();

    final candidateFiles = <Map<String, dynamic>>[];
    final seenPickcodes = <String>{};

    void appendFiles(List<dynamic>? rawList) {
      if (rawList == null) return;
      for (final item in rawList) {
        if (item is! Map<String, dynamic>) continue;
        final pc = (item['pc'] ?? item['pick_code'] ?? '').toString().trim();
        final fid = (item['fid'] ?? item['file_id'] ?? '').toString().trim();
        if (pc.isNotEmpty && fid.isNotEmpty && seenPickcodes.add(pc)) {
          candidateFiles.add(item);
        }
      }
    }

    // 1. Search by keyword via `webapi.115.com/files/search`
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

    // 2. Also list newest files in root (`cid=0`) and `/115open` directory sorted by `user_ptime` desc
    try {
      final rootUri = Uri.parse(
        'https://webapi.115.com/files?aid=1&cid=0&o=user_ptime&asc=0&offset=0&limit=40&show_dir=1&format=json',
      );
      final root = await _getJson(rootUri, timeout: const Duration(seconds: 12));
      if (root is Map<String, dynamic> && root['data'] is List) {
        final rootEntries = root['data'] as List;
        appendFiles(rootEntries);
        for (final entry in rootEntries) {
          if (entry is! Map<String, dynamic>) continue;
          final fid = (entry['fid'] ?? '').toString();
          final cid = (entry['cid'] ?? '').toString();
          final name = (entry['n'] ?? '').toString().toLowerCase();
          if (fid.isEmpty &&
              cid.isNotEmpty &&
              (name == '115open' ||
                  name.contains('115') ||
                  name.contains('download'))) {
            final subUri = Uri.parse(
              'https://webapi.115.com/files?aid=1&cid=$cid&o=user_ptime&asc=0&offset=0&limit=40&show_dir=1&format=json',
            );
            final subRoot =
                await _getJson(subUri, timeout: const Duration(seconds: 12));
            if (subRoot is Map<String, dynamic> && subRoot['data'] is List) {
              appendFiles(subRoot['data'] as List);
            }
          }
        }
      }
    } catch (_) {}

    if (candidateFiles.isEmpty) return null;

    // 3. Match file by name or newest uploaded timestamp
    Map<String, dynamic>? matchedItem;
    for (final item in candidateFiles) {
      final rawName = (item['n'] ?? item['file_name'] ?? '').toString();
      final cleanName = _cleanMatchToken(rawName);
      if (cleanName.isEmpty) continue;
      if (cleanKeywords.any((kw) =>
          cleanName == kw || cleanName.contains(kw) || kw.contains(cleanName))) {
        matchedItem = item;
        break;
      }
    }

    if (matchedItem == null && allowNewestRecentFallbackAfter != null) {
      final minEpoch =
          (allowNewestRecentFallbackAfter.millisecondsSinceEpoch ~/ 1000) - 30;
      for (final item in candidateFiles) {
        final tp = int.tryParse(
              (item['tp'] ?? item['te'] ?? item['t'] ?? 0).toString(),
            ) ??
            0;
        final iv = int.tryParse((item['iv'] ?? 0).toString()) ?? 0;
        final ico = (item['ico'] ?? '').toString().toLowerCase();
        final isVideo = iv == 1 ||
            const {'mp4', 'mkv', 'ts', 'mov', 'flv', 'avi', 'webm'}
                .contains(ico);
        if (isVideo && tp >= minEpoch) {
          matchedItem = item;
          break;
        }
      }
    }

    if (matchedItem == null) return null;
    final pickcode =
        (matchedItem['pc'] ?? matchedItem['pick_code'] ?? '').toString().trim();
    final fileName =
        (matchedItem['n'] ?? matchedItem['file_name'] ?? '115 视频').toString();
    if (pickcode.isEmpty) return null;

    final directUrl = await resolvePickcodeStreamUrl(pickcode);
    if (directUrl == null || directUrl.isEmpty) return null;

    final headers = <String, String>{
      'User-Agent': browserUserAgent,
      'Cookie': _cookie,
    };
    final proxyUrl = directUrl.toLowerCase().contains('.m3u8')
        ? directUrl
        : await wrapWithLocal115HeaderProxy(directUrl, headers);

    return Resolved115Stream(
      proxyStreamUrl: proxyUrl,
      directCdnUrl: directUrl,
      headers: headers,
      fileName: fileName,
    );
  }

  /// Resolves a 115 `pickcode` to an official 115 domestic CDN direct URL using:
  /// 1) `proapi.115.com/app/chrome/downurl` (m115 encrypted original MP4 direct CDN link)
  /// 2) `webapi.115.com/files/download?pickcode=...`
  /// 3) `webapi.115.com/files/video?pickcode=...`
  Future<String?> resolvePickcodeStreamUrl(String pickcode) async {
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
                final cdnUrl = (val['url']['url'] ?? '').toString().trim();
                if (cdnUrl.startsWith('http')) {
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
    _headersByUrl[remoteUrl] = Map<String, String>.from(headers);
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
    final rangeHeader = req.headers.value('range') ?? req.headers.value('Range');

    try {
      final upstreamReq = await _httpClient.openUrl(req.method, uri);
      upstreamReq.followRedirects = true;
      upstreamReq.maxRedirects = 5;
      customHeaders.forEach((k, v) {
        if (v.isNotEmpty) {
          upstreamReq.headers.set(k, v);
        }
      });
      if (rangeHeader != null && rangeHeader.isNotEmpty) {
        upstreamReq.headers.set('Range', rangeHeader);
      }
      final upstreamResp = await upstreamReq.close();
      req.response.statusCode = upstreamResp.statusCode;
      req.response.bufferOutput = false;

      for (final headerName in const [
        'content-type',
        'content-length',
        'content-range',
        'accept-ranges',
        'etag',
        'last-modified',
      ]) {
        final val = upstreamResp.headers.value(headerName);
        if (val != null && val.isNotEmpty) {
          req.response.headers.set(headerName, val);
        }
      }
      final upstreamCt =
          (upstreamResp.headers.value('content-type') ?? '').toLowerCase();
      if (upstreamCt.isEmpty ||
          upstreamCt.contains('octet-stream') ||
          upstreamCt.contains('application/force-download')) {
        final inferred = _inferMimeTypeFromPath(req.uri.path.toLowerCase()) ??
            _inferMimeTypeFromPath(uri.path.toLowerCase());
        if (inferred != null) {
          req.response.headers.set('content-type', inferred);
        }
      }
      req.response.headers.set('Access-Control-Allow-Origin', '*');

      if (req.method.toUpperCase() == 'HEAD') {
        await req.response.close();
        return;
      }

      await upstreamResp.pipe(req.response);
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

  /// Full 3-stage pipeline:
  /// 1) Checks if the video is already in 115 Cloud Drive (instant switch if found)
  /// 2) Instructs the server to download the video (`POST /api/download`) and monitors real-time progress (`/api/tasks`)
  /// 3) Waits for 115 upload (`Uploading` / `/api/115/upload/:id` / CloudDrive2 sync), then resolves the official 115 domestic CDN direct link locally
  Future<Resolved115Stream?> run115CloudAccelerationPipeline({
    required ApiClient api,
    required String downloadUrl,
    required String videoName,
    Map<String, String> headers = const {},
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

    // Ensure backend server also has our local 115 Cookie so server-side 115 rapid/API upload works
    if (hasLocalCookie) {
      try {
        await api.login115WithCookie(_cookie);
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

    // Step 2: Create or attach to server download task (`POST /api/download`)
    _stageTitle = '阶段 1/3 · 正在提交服务器高速下载任务...';
    _detailText = taskTitle;
    _progress = 0.10;
    notifyListeners();

    try {
      await api.createDownloadTask(
        url: downloadUrl,
        name: taskTitle,
        headers: headers,
        telegramAccountId: telegramAccountId,
      );
    } catch (e) {
      if (pipelineId != _activePipelineId) return null;
      _isAccelerating = false;
      notifyListeners();
      onError?.call('提交服务器下载失败：$e');
      return null;
    }

    // Step 3: Poll `/api/tasks` until server download & 115 upload complete
    String? matchedTaskId;
    String matchedOutputFile = '';
    String matchedTaskName = taskTitle;
    bool didTriggerManual115Upload = false;

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
        for (final t in tasks) {
          if (t.name == taskTitle || t.url == downloadUrl) {
            matchedTask = t;
            matchedTaskId = t.id;
            break;
          }
        }
      }

      if (matchedTask != null) {
        matchedOutputFile = matchedTask.outputFile;
        matchedTaskName = matchedTask.name;
        final status = matchedTask.status as String;
        final prog = (matchedTask.progress as double).clamp(1.0, 99.5);

        if (status == 'Pending' || status == 'Downloading') {
          _stageTitle = '阶段 1/3 · 服务器正在高速下载该视频...';
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
          if (!didTriggerManual115Upload) {
            didTriggerManual115Upload = true;
            final errStr = (matchedTask.error as String).toLowerCase();
            if (errStr.contains('115') || matchedOutputFile.isNotEmpty) {
              _stageTitle = '阶段 2/3 · 正在同步视频至 115 网盘...';
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
          _isAccelerating = false;
          notifyListeners();
          final err = (matchedTask.error as String).isEmpty
              ? '请检查视频源链接'
              : matchedTask.error;
          onError?.call('服务器下载或上传失败：$err');
          return null;
        }
      } else if (pollTick >= 4) {
        break;
      }

      await Future<void>.delayed(const Duration(milliseconds: 1200));
    }

    if (pipelineId != _activePipelineId) return null;

    // Step 4: Poll local 115 Cloud Drive to get the official 115 domestic CDN direct URL
    _stageTitle = '阶段 3/3 · 正在从本地连接 115 获取高速直链...';
    _progress = 0.92;
    notifyListeners();

    final keywords = <String>[
      if (matchedOutputFile.isNotEmpty)
        matchedOutputFile.split('/').last,
      if (matchedTaskName.isNotEmpty) matchedTaskName,
      taskTitle,
      videoName,
    ];

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
    final bytes = await resp.fold<List<int>>(<int>[], (acc, b) => acc..addAll(b));
    final text = utf8.decode(bytes, allowMalformed: true).trim();
    if (text.isEmpty) return null;
    return jsonDecode(text);
  }

  static String _cleanMatchToken(String raw) {
    var s = raw.split('/').last.trim();
    s = s.replaceFirst(RegExp(r'^tg_\d+_'), '');
    for (final ext in const ['.mp4', '.ts', '.mkv', '.mov', '.flv', '.m3u8']) {
      while (s.toLowerCase().endsWith(ext)) {
        s = s.substring(0, s.length - ext.length);
      }
    }
    return s.toLowerCase().trim();
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
  }) async {
    await ensureInitialized();
    if (!hasLocalCookie) {
      throw const ApiException('请先扫码或使用 Cookie 登录 115 网盘账号');
    }
    final cleanCid = (cid.isEmpty || cid == '/') ? '0' : cid;
    final candidateUrls = <String>[
      'https://webapi.115.com/files?aid=1&cid=$cleanCid&o=user_ptime&asc=0&offset=0&limit=100&show_dir=1&format=json',
      'https://aps.115.com/natsort/files.php?aid=1&cid=$cleanCid&o=file_name&asc=1&offset=0&limit=100&show_dir=1&natsort=1&format=json',
      'https://webapi.115.com/files?aid=1&cid=$cleanCid&o=user_ptime&asc=0&offset=0&limit=40&show_dir=1&format=json',
      'https://proapi.115.com/android/2.0/ufile/files?aid=1&cid=$cleanCid&o=user_ptime&asc=0&offset=0&limit=100&show_dir=1',
    ];

    Map<String, dynamic>? root;
    List<dynamic>? rawItems;
    bool anyStateOk = false;
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
          if (res['data'] is List) {
            final arr = res['data'] as List;
            if (arr.isNotEmpty) {
              root = res;
              rawItems = arr;
              anyStateOk = true;
              break;
            } else if (isStateOk && errNo == 0) {
              root = res;
              rawItems = const [];
              break;
            }
          }
        }
      } catch (_) {}
    }

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
