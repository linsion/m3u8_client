import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'api_client.dart';
import 'cloud115_upload_protocol.dart';
import 'proxy_routing_service.dart';

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
  final bool isTranscoded;

  const Resolved115Stream({
    required this.proxyStreamUrl,
    required this.directCdnUrl,
    required this.headers,
    required this.fileName,
    this.isTranscoded = false,
  });

  Map<String, String> get playbackHeaders =>
      proxyStreamUrl == directCdnUrl ? headers : const {};
}

typedef _ProxyMediaInfo = ({
  int totalSize,
  String contentType,
  Uint8List rawHeaderChunk,
  Uint8List normalizedHeaderChunk,
  int stripPrefixBytes,
  bool supportsRanges,
  int cachedAtMs,
});

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
  Future<void>? _initialization;

  // Acceleration pipeline state
  bool _isAccelerating = false;
  String _stageTitle = '';
  String _detailText = '';
  double _progress = 0.0;
  int _activePipelineId = 0;

  // Local loopback proxy for injecting 115Browser User-Agent + Cookie on all Range requests
  HttpServer? _proxyServer;
  Future<void>? _proxyStarting;
  int _proxyPort = 0;
  bool _needsProxyHealthCheck = false;
  final Map<String, Map<String, String>> _headersByUrl = {};
  late HttpClient _httpClient;

  Local115DirectService._() {
    _httpClient = _createHttpClient();
    unawaited(ensureInitialized());
  }

  static HttpClient _createHttpClient() {
    final hc = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 30)
      ..findProxy = ((_) => 'DIRECT')
      ..badCertificateCallback = (_, __, ___) => true;
    try {
      hc.maxConnectionsPerHost = 12;
    } catch (_) {}
    return hc;
  }

  void _recreateHttpClient() {
    final old = _httpClient;
    _httpClient = _createHttpClient();
    try {
      old.close(force: false);
    } catch (_) {}
  }

  /// Resets pooled HTTP sockets, clears expired stream/header caches, and schedules
  /// a loopback proxy health check when the app resumes from background inactivity.
  void resetAfterBackground({bool clearCaches = true}) {
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      _recreateHttpClient();
    }
    _needsProxyHealthCheck = true;
    if (clearCaches) {
      _pickcodeUrlCache.clear();
      _pickcodeInFlight.clear();
      _proxyMetaCache.clear();
      _proxyMetaInFlight.clear();
      _cdnAuthCookiesByUrl.clear();
      _latestCdnAuthCookie = '';
      _latestCdnAuthCookieAtMs = 0;
    }
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

  Future<void> ensureInitialized() =>
      _initialization ??= _loadSavedState();

  Future<void> _loadSavedState() async {
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
      final root = await list115Directory(cid: '0');
      resolvedCid =
          root.entries
              .where(
                (item) =>
                    item.isDir &&
                    item.name.trim().toLowerCase() == folderName.toLowerCase(),
              )
              .firstOrNull
              ?.cid115 ??
          '';
    } catch (_) {}

    if (resolvedCid.isEmpty) {
      try {
        final addRes = await _postFormJson(
          Uri.parse('https://webapi.115.com/files/add'),
          body: 'pid=0&cname=${Uri.encodeQueryComponent(folderName)}',
          timeout: const Duration(seconds: 12),
        );
        if (addRes is Map<String, dynamic>) {
          final directCid = (addRes['cid'] ?? addRes['file_id'] ?? '')
              .toString()
              .trim();
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
      if (_targetFolderCid != resolvedCid) {
        _targetFolderCid = resolvedCid;
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_prefTargetFolderCidKey, resolvedCid);
        } catch (_) {}
        notifyListeners();
      }
      if (syncToServerApi != null) {
        await _syncFolderCidToServer(syncToServerApi, resolvedCid);
      }
      return resolvedCid;
    }

    return _targetFolderCid.isNotEmpty ? _targetFolderCid : '0';
  }

  Future<void> _syncFolderCidToServer(
    ApiClient api,
    String targetCid, {
    bool throwOnFailure = false,
    bool ensureConvertToMp4 = false,
  }) async {
    if (targetCid.isEmpty || targetCid == '0') return;
    try {
      final settings = await api.fetchServerSettings();
      final map = Map<String, dynamic>.from(settings.raw);
      final cur = (map['eleven_dir_id'] ?? '').toString().trim();
      var changed = false;
      if (cur != targetCid) {
        map['eleven_dir_id'] = targetCid;
        changed = true;
      }
      if (ensureConvertToMp4 && map['convert_to_mp4'] != true) {
        map['convert_to_mp4'] = true;
        changed = true;
      }
      if (changed) {
        await api.saveServerSettings(map);
      }
    } catch (_) {
      if (throwOnFailure) rethrow;
    }
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
    bool searchAccount = true,
    bool preferMp4Only = false,
  }) async {
    await ensureInitialized();
    if (!hasLocalCookie) return null;
    final names = keywords
        .map(_cleanMatchToken)
        .where((name) => name.isNotEmpty)
        .toSet();
    if (names.isEmpty) return null;

    final seenPickcodes = <String>{};
    Future<Resolved115Stream?> resolveMatches(
      Iterable<FileEntry> entries,
    ) async {
      final list = entries.toList();
      for (final name in names) {
        final matched = <FileEntry>[];
        for (final entry in list) {
          if (!entry.isVideo ||
              entry.pickcode115.isEmpty ||
              _cleanMatchToken(entry.name) != name) {
            continue;
          }
          if (preferMp4Only && !entry.isMp4 && entry.normalizedExt != '.mp4') {
            continue;
          }
          matched.add(entry);
        }
        // Always prioritize MP4 over TS/other containers when both exist
        matched.sort((a, b) {
          final aMp4 = (a.isMp4 || a.normalizedExt == '.mp4') ? 0 : 1;
          final bMp4 = (b.isMp4 || b.normalizedExt == '.mp4') ? 0 : 1;
          return aMp4.compareTo(bMp4);
        });
        for (final entry in matched) {
          if (!seenPickcodes.add(entry.pickcode115)) continue;
          final stream = await resolve115VideoPlayback(
            pickcode: entry.pickcode115,
            fileName: entry.name,
            extension: entry.normalizedExt,
          );
          if (stream != null) return stream;
        }
      }
      return null;
    }

    Future<List<FileEntry>> directory(String cid) async {
      try {
        return (await list115Directory(cid: cid, maxPages: 1)).entries;
      } catch (_) {
        return const [];
      }
    }

    List<FileEntry>? root;
    var targetCid = _targetFolderCid;
    if (targetCid.isEmpty || targetCid == '0') {
      root = await directory('0');
      targetCid =
          root
              .where((item) => item.isDir && item.name == targetFolderName)
              .firstOrNull
              ?.cid115 ??
          '';
    }
    if (targetCid.isNotEmpty && targetCid != '0') {
      final stream = await resolveMatches(await directory(targetCid));
      if (stream != null) return stream;
    }

    final rootStream = await resolveMatches(root ?? await directory('0'));
    if (rootStream != null || !searchAccount) return rootStream;

    for (final keyword
        in keywords
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toSet()
            .take(4)) {
      final uri = Uri.https('webapi.115.com', '/files/search', {
        'aid': '1',
        'cid': '0',
        'search_value': keyword,
        'type': '4',
        'limit': '25',
        'show_dir': '0',
      });
      try {
        final result = await _getJson(uri);
        if (result is! Map || result['data'] is! List) continue;
        final entries = (result['data'] as List)
            .whereType<Map<String, dynamic>>()
            .map(
              (raw) => _decode115Entry(
                raw,
                parentCid: (raw['pid'] ?? raw['cid'] ?? raw['parent_id'] ?? '0')
                    .toString(),
                mountId: 'builtin_115',
              ),
            )
            .whereType<FileEntry>();
        final stream = await resolveMatches(entries);
        if (stream != null) return stream;
      } catch (_) {}
    }
    return null;
  }

  Future<Resolved115Stream?> resolve115VideoPlayback({
    required String pickcode,
    required String fileName,
    required String extension,
    bool? useCloudTranscode,
  }) async {
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
    }.contains(extension.toLowerCase());

    final routes = useCloudTranscode == null
        ? [needsHlsTranscode, !needsHlsTranscode]
        : [useCloudTranscode];
    for (final useTranscode in routes) {
      final url = useTranscode
          ? await resolvePickcodeHlsM3u8Url(pickcode)
          : await resolvePickcodeStreamUrl(pickcode, allowVideoFallback: false);
      if (url == null) continue;
      final uri = Uri.parse(url);
      final isHls = useTranscode || _isHlsUrl(uri);
      final headers = requestHeadersForUrl(url);
      if (!await _canOpenVideoSource(uri, headers, isHls: isHls)) continue;
      final relay = await wrapWithLocal115HeaderProxy(
        url,
        headers,
        extHint: isHls ? '.m3u8' : extension,
      );
      return Resolved115Stream(
        proxyStreamUrl: relay,
        directCdnUrl: url,
        headers: headers,
        fileName: fileName,
        isTranscoded: isHls,
      );
    }
    return null;
  }

  Future<bool> _canOpenVideoSource(
    Uri uri,
    Map<String, String> headers, {
    required bool isHls,
  }) async {
    try {
      final response = await _openProxyUpstream(
        uri,
        headers,
        range: isHls ? null : 'bytes=0-4095',
      );
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        await response.listen((_) {}).cancel();
        return false;
      }
      final type = response.headers.contentType?.mimeType ?? '';
      final prefix = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        final count = min(chunk.length, 64 - prefix.length);
        LocalProxyTunnelBridge.recordDownstreamBytes(count);
        prefix.add(chunk.sublist(0, count));
        if (prefix.length >= 64) break;
      }
      if (prefix.isEmpty) return false;
      final text = utf8.decode(prefix.takeBytes(), allowMalformed: true).trimLeft();
      if (isHls) return text.startsWith('#EXTM3U');
      return !type.contains('html') &&
          !type.contains('json') &&
          !text.startsWith('<') &&
          !text.startsWith('#EXTM3U');
    } catch (_) {
      return false;
    }
  }

  /// Resolves 115's official cloud transcode HLS `.m3u8` stream URL (`webapi.115.com/files/video?pickcode=...`),
  /// essential for playing `.f4v`, `.flv`, `.mkv`, `.avi`, `.rmvb`, `.wmv`, `.ts` containers smoothly across all platforms.
  Future<String?> resolvePickcodeHlsM3u8Url(String pickcode) async {
    await ensureInitialized();
    final cleanPc = pickcode.trim();
    if (cleanPc.isEmpty) return null;
    try {
      final vidUri =
          Uri.parse('https://webapi.115.com/files/video?pickcode=$cleanPc');
      final root = await _getJson(vidUri, timeout: const Duration(seconds: 10));
      if (root is Map<String, dynamic>) {
        final data = root['data'];
        return _readMediaUrl(root['video_urls']) ??
            _readMediaUrl(root['video_url']) ??
            _readMediaUrl(data);
      }
    } catch (_) {}
    return null;
  }

  static String? _readMediaUrl(Object? value) {
    if (value is String) {
      final text = value.trim();
      final absolute = text.startsWith('//') ? 'https:$text' : text;
      final uri = Uri.tryParse(absolute);
      if (uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host.isNotEmpty) {
        return absolute;
      }
    } else if (value is List) {
      for (final item in value.reversed) {
        final url = _readMediaUrl(item);
        if (url != null) return url;
      }
    } else if (value is Map) {
      for (final key in const ['video_urls', 'video_url', 'm3u8_url', 'url']) {
        final url = _readMediaUrl(value[key]);
        if (url != null) return url;
      }
    }
    return null;
  }

  static bool _isHlsUrl(Uri uri) => uri.path.toLowerCase().endsWith('.m3u8');

  static bool _is115MediaHost(String host) =>
      const ['115.com', '115cdn.net', '115vod.com'].any(
        (domain) => host == domain || host.endsWith('.$domain'),
      );

  /// Resolves a 115 `pickcode` to an official 115 domestic CDN direct URL using:
  /// 1) `proapi.115.com/app/chrome/downurl` (encrypted original file URL)
  /// 2) `webapi.115.com/files/download?pickcode=...`
  /// 3) `webapi.115.com/files/video?pickcode=...`
  final Map<(String, bool), ({String url, int timestampMs})> _pickcodeUrlCache =
      {};
  final Map<(String, bool), Future<String?>> _pickcodeInFlight = {};
  final Map<String, String> _cdnAuthCookiesByUrl = {};
  String _latestCdnAuthCookie = '';
  int _latestCdnAuthCookieAtMs = 0;

  String get _activeLatestCdnAuthCookie {
    if (_latestCdnAuthCookie.isEmpty) return '';
    final ageMs =
        DateTime.now().millisecondsSinceEpoch - _latestCdnAuthCookieAtMs;
    if (ageMs > 120000) {
      _latestCdnAuthCookie = '';
      _latestCdnAuthCookieAtMs = 0;
      return '';
    }
    return _latestCdnAuthCookie;
  }

  Map<String, String> requestHeadersForUrl(String url) {
    final base = Map<String, String>.from(requestHeaders);
    final extra = _cdnAuthCookiesByUrl[url] ?? _activeLatestCdnAuthCookie;
    if (extra.isNotEmpty) {
      final cur = (base['Cookie'] ?? '').trim();
      if (!cur.contains(extra)) {
        base['Cookie'] = cur.isEmpty ? extra : '$cur; $extra';
      }
    }
    return base;
  }

  Future<String?> resolvePickcodeFromFid(String fid) async {
    await ensureInitialized();
    final cleanFid = fid.trim();
    if (!hasLocalCookie || cleanFid.isEmpty || cleanFid == '0') return null;
    try {
      final info = await _read115FileInfo(cleanFid);
      if (info.pickcode.isNotEmpty) return info.pickcode;
    } catch (_) {}
    return null;
  }

  Future<String?> resolvePickcodeStreamUrl(
    String pickcode, {
    bool forceRefresh = false,
    bool allowVideoFallback = true,
  }) async {
    await ensureInitialized();
    final cleanPc = pickcode.trim();
    if (cleanPc.isEmpty) return null;
    final cacheKey = (cleanPc, allowVideoFallback);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (!forceRefresh) {
      final cached = _pickcodeUrlCache[cacheKey];
      if (cached != null && (nowMs - cached.timestampMs) < 12000) {
        return cached.url;
      }
    } else {
      _pickcodeUrlCache.remove(cacheKey);
      _pickcodeInFlight.remove(cacheKey);
    }
    final inflight = _pickcodeInFlight[cacheKey];
    if (inflight != null) return await inflight;
    final fut = _resolvePickcodeStreamUrlInternal(cleanPc, allowVideoFallback);
    _pickcodeInFlight[cacheKey] = fut;
    try {
      final res = await fut;
      if (res != null && res.isNotEmpty) {
        if (_pickcodeUrlCache.length > 64) {
          _pickcodeUrlCache.clear();
        }
        _pickcodeUrlCache[cacheKey] = (
          url: res,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
        );
      }
      return res;
    } finally {
      _pickcodeInFlight.remove(cacheKey);
    }
  }

  Future<String?> _resolvePickcodeStreamUrlInternal(
    String pickcode,
    bool allowVideoFallback,
  ) async {
    // 1. Primary: `proapi.115.com/app/chrome/downurl`
    try {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final endpoint =
          Uri.parse('https://proapi.115.com/app/chrome/downurl?t=$nowSec');
      final key = M115Crypto.generateKey();
      final paramBytes = utf8.encode(jsonEncode({'pickcode': pickcode}));
      final encodedData = M115Crypto.encode(Uint8List.fromList(paramBytes), key);
      final body = 'data=${Uri.encodeQueryComponent(encodedData)}';
      const timeout = Duration(seconds: 12);
      var response = await _postForm(
        endpoint,
        body: body,
        timeout: timeout,
      );
      if (response.statusCode == HttpStatus.found) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        final uri = location == null ? null : endpoint.resolve(location);
        if (uri != null && uri.scheme == 'https' && _is115MediaHost(uri.host)) {
          // Large files can return the encrypted result via a second GET.
          // It uses the same key as the original POST.
          await response.drain<void>().timeout(timeout);
          final request = await _httpClient.getUrl(uri).timeout(timeout);
          request.followRedirects = false;
          requestHeaders.forEach(request.headers.set);
          response = await request.close().timeout(timeout);
        }
      }
      Object? root;
      if (response.statusCode == HttpStatus.ok) {
        root = await _readJsonResponse(
          response,
          captureAuthCookie: true,
        ).timeout(timeout);
      } else {
        await response.drain<void>().timeout(timeout);
      }
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
                      _latestCdnAuthCookieAtMs =
                          DateTime.now().millisecondsSinceEpoch;
                    }
                  } else {
                    final freshCookie = _activeLatestCdnAuthCookie;
                    if (freshCookie.isNotEmpty) {
                      _cdnAuthCookiesByUrl[cdnUrl] = freshCookie;
                    }
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

    return allowVideoFallback ? resolvePickcodeHlsM3u8Url(pickcode) : null;
  }

  /// Wraps a 115 CDN URL in a local loopback HTTP proxy (`http://127.0.0.1:<port>/115_stream.<ext>?u=...`)
  /// so that every Range request (and any 302 redirect) carries the exact `115Browser` User-Agent and Cookie headers
  /// and exposes the proper audio/video MIME Content-Type for AVPlayer / media_kit.
  Future<String> wrapWithLocal115HeaderProxy(
    String remoteUrl,
    Map<String, String> headers, {
    String extHint = '',
    bool forceRefresh = false,
  }) async {
    if (forceRefresh) {
      _proxyMetaCache.remove(remoteUrl);
      _proxyMetaInFlight.remove(remoteUrl);
    }
    await _ensureLocalProxyStarted();
    if (_proxyPort <= 0) return remoteUrl;
    if (_headersByUrl.length >= 8192 && !_headersByUrl.containsKey(remoteUrl)) {
      _headersByUrl.remove(_headersByUrl.keys.first);
    }
    final mergedHeaders = Map<String, String>.from(headers);
    final authCookie = _cdnAuthCookiesByUrl[remoteUrl] ??
        (_is115MediaHost(Uri.tryParse(remoteUrl)?.host ?? '')
            ? _activeLatestCdnAuthCookie
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

  final _proxyMetaCache = <String, _ProxyMediaInfo>{};
  final _proxyMetaInFlight = <String, Future<_ProxyMediaInfo?>>{};

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

  static final _upstreamContentRange =
      RegExp(r'^bytes (\d+)-(\d+)/(\d+)$', caseSensitive: false);

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
        upstreamReq.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        upstreamReq.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
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
          await upstreamResp.listen((_) {}).cancel();
          await Future<void>.delayed(
            Duration(milliseconds: (attempt + 1) * 200),
          );
          continue;
        }

        var totalSize = upstreamResp.contentLength;
        var bytesToRead = expected;
        if (code == HttpStatus.partialContent) {
          final match = _upstreamContentRange.firstMatch(
            upstreamResp.headers.value(HttpHeaders.contentRangeHeader) ?? '',
          );
          final last = int.tryParse(match?[2] ?? '');
          totalSize = int.tryParse(match?[3] ?? '') ?? 0;
          if (int.tryParse(match?[1] ?? '') != start ||
              last == null ||
              last < start ||
              last > end ||
              totalSize <= last) {
            await upstreamResp.listen((_) {}).cancel();
            continue;
          }
          bytesToRead = last - start + 1;
        } else if (totalSize > 0) {
          bytesToRead = min(expected, totalSize);
        }

        final builder = BytesBuilder(copy: false);
        await for (final chunk in upstreamResp.timeout(
          const Duration(seconds: 18),
        )) {
          if (isCancelled != null && isCancelled()) {
            try {
              final sock = await upstreamResp.detachSocket();
              sock.destroy();
            } catch (_) {}
            return null;
          }
          final remaining = bytesToRead - builder.length;
          final slice = chunk.length <= remaining ? chunk : chunk.sublist(0, remaining);
          LocalProxyTunnelBridge.recordDownstreamBytes(slice.length);
          builder.add(slice);
          if (builder.length == bytesToRead) break;
        }
        final rawBytes = builder.takeBytes();
        if (rawBytes.isEmpty ||
            (code == HttpStatus.partialContent && rawBytes.length != bytesToRead)) {
          continue;
        }
        final ct = (upstreamResp.headers.value('content-type') ?? '').trim();
        return (
          bytes: rawBytes,
          statusCode: code,
          totalSize: totalSize,
          contentType: ct,
        );
      } catch (_) {
        if (isCancelled != null && isCancelled()) return null;
        if (attempt == 0) {
          _recreateHttpClient();
        }
        await Future<void>.delayed(
          Duration(milliseconds: (attempt + 1) * 200),
        );
      }
    }
    return null;
  }

  Future<void> _ensureLocalProxyStarted() async {
    if (_proxyServer != null && _proxyPort > 0) {
      if (!_needsProxyHealthCheck) return;
      _needsProxyHealthCheck = false;
      if (await _isLocalProxyHealthy(_proxyPort)) {
        return;
      }
      final stale = _proxyServer;
      _proxyServer = null;
      _proxyPort = 0;
      try {
        await stale?.close(force: true);
      } catch (_) {}
    }
    return await (_proxyStarting ??= _startLocalProxy().whenComplete(() {
      _proxyStarting = null;
    }));
  }

  Future<bool> _isLocalProxyHealthy(int port) async {
    if (port <= 0) return false;
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 250),
      );
      socket.add(
        ascii.encode(
          'HEAD /__ping__ HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nConnection: close\r\n\r\n',
        ),
      );
      await socket.flush();
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        socket?.destroy();
      } catch (_) {}
    }
  }

  Future<void> _startLocalProxy() async {
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _proxyServer = server;
      _proxyPort = server.port;
      _needsProxyHealthCheck = false;
      server.listen(
        _handleProxyRequest,
        cancelOnError: false,
        onDone: () {
          if (identical(_proxyServer, server)) {
            _proxyServer = null;
            _proxyPort = 0;
          }
        },
        onError: (_) {},
      );
    } catch (_) {}
  }

  Future<_ProxyMediaInfo?> _loadProxyMediaInfo(
    Uri uri,
    Map<String, String> headers,
    String requestPath,
  ) async {
    final probe = await _fetchUpstreamRangeChunk(
      uri: uri,
      customHeaders: headers,
      start: 0,
      end: 262143,
    );
    if (probe == null || probe.totalSize <= 0) return null;
    final normalized = normalizeWavOrAudioHeaderChunk(
      probe.bytes,
      probe.totalSize,
      requestPath,
    );
    final contentType = probe.contentType.toLowerCase();
    final genericType = contentType.isEmpty ||
        contentType.contains('octet-stream') ||
        contentType.contains('force-download');
    return (
      totalSize: probe.totalSize - normalized.stripPrefixBytes,
      contentType: normalized.detectedMimeType ??
          (genericType
              ? _inferMimeTypeFromPath(requestPath) ??
                  _inferMimeTypeFromPath(uri.path.toLowerCase()) ??
                  'application/octet-stream'
              : probe.contentType),
      rawHeaderChunk: probe.bytes,
      normalizedHeaderChunk: normalized.normalizedChunk,
      stripPrefixBytes: normalized.stripPrefixBytes,
      supportsRanges: probe.statusCode == HttpStatus.partialContent,
      cachedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  static final _mediaByteRange =
      RegExp(r'^bytes=(\d*)-(\d*)$', caseSensitive: false);

  static ({int start, int end})? _resolveMediaRange(String? header, int size) {
    if (header == null) return (start: 0, end: size - 1);
    final match = _mediaByteRange.firstMatch(header.trim());
    if (match == null) return null;
    final startText = match[1]!;
    final endText = match[2]!;
    if (startText.isEmpty) {
      final suffix = int.tryParse(endText);
      if (suffix == null || suffix <= 0) return null;
      return (start: max(0, size - suffix), end: size - 1);
    }
    final start = int.tryParse(startText);
    final end = endText.isEmpty ? size - 1 : int.tryParse(endText);
    if (start == null || end == null || start >= size || end < start) {
      return null;
    }
    return (start: start, end: min(end, size - 1));
  }

  Future<HttpClientResponse> _openProxyUpstream(
    Uri uri,
    Map<String, String> headers, {
    String method = 'GET',
    String? range,
  }) async {
    const timeout = Duration(seconds: 15);
    final request = await _httpClient.openUrl(method, uri).timeout(timeout);
    headers.forEach(request.headers.set);
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    return request.close().timeout(
      timeout,
      onTimeout: () {
        request.abort();
        throw TimeoutException('115 upstream response timed out', timeout);
      },
    );
  }

  Future<void> _pipeProxyResource(
    HttpRequest request,
    Uri uri,
    Map<String, String> headers,
  ) async {
    final upstream = await _openProxyUpstream(
      uri,
      headers,
      method: request.method,
      range: request.headers.value(HttpHeaders.rangeHeader),
    );
    final downstream = request.response;
    downstream.statusCode = upstream.statusCode;
    downstream.bufferOutput = false;
    if (upstream.contentLength >= 0) {
      downstream.contentLength = upstream.contentLength;
    }
    for (final name in [
      HttpHeaders.contentTypeHeader,
      HttpHeaders.contentRangeHeader,
      HttpHeaders.acceptRangesHeader,
    ]) {
      final value = upstream.headers.value(name);
      if (value != null) downstream.headers.set(name, value);
    }
    downstream.headers.set('Access-Control-Allow-Origin', '*');
    if (request.method == 'HEAD') {
      await upstream.drain<void>();
      await downstream.close();
    } else {
      await upstream.map((chunk) {
        LocalProxyTunnelBridge.recordDownstreamBytes(chunk.length);
        return chunk;
      }).pipe(downstream);
    }
  }

  Future<void> _streamWithoutUpstreamRanges(
    HttpResponse downstream,
    Uri uri,
    Map<String, String> headers, {
    required int skip,
    required int length,
    required bool Function() isCancelled,
  }) async {
    final source = await _openProxyUpstream(uri, headers);
    if (source.statusCode != HttpStatus.ok) {
      await source.listen((_) {}).cancel();
      return;
    }
    await for (final chunk in source.timeout(const Duration(seconds: 18))) {
      if (isCancelled()) return;
      if (skip >= chunk.length) {
        skip -= chunk.length;
        continue;
      }
      final count = min(length, chunk.length - skip);
      LocalProxyTunnelBridge.recordDownstreamBytes(count);
      downstream.add(chunk.sublist(skip, skip + count));
      await downstream.flush();
      length -= count;
      if (length == 0) return;
      skip = 0;
    }
  }

  Future<void> _serveProxyPlaylist(
    HttpRequest request,
    Uri upstreamUri,
    Map<String, String> headers,
  ) async {
    final upstream = await _openProxyUpstream(upstreamUri, headers);
    if (upstream.statusCode != HttpStatus.ok) {
      await upstream.listen((_) {}).cancel();
      request.response.statusCode = upstream.statusCode;
      await request.response.close();
      return;
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in upstream.timeout(const Duration(seconds: 15))) {
      LocalProxyTunnelBridge.recordDownstreamBytes(chunk.length);
      bytes.add(chunk);
    }
    final playlist = utf8.decode(bytes.takeBytes(), allowMalformed: true).trim();
    if (!playlist.startsWith('#EXTM3U')) {
      request.response.statusCode = HttpStatus.badGateway;
      await request.response.close();
      return;
    }
    final base = upstream.redirects.fold(
      upstreamUri,
      (current, redirect) => current.resolveUri(redirect.location),
    );

    String wrapResource(String reference, {required bool playlist}) {
      final target = base.resolve(reference);
      if (target.scheme != 'http' && target.scheme != 'https') return reference;
      final targetUrl = target.toString();
      final childHeaders = Map<String, String>.from(headers);
      if (target.host != upstreamUri.host &&
          !target.host.endsWith('.${upstreamUri.host}') &&
          !(_is115MediaHost(upstreamUri.host) && _is115MediaHost(target.host))) {
        childHeaders.removeWhere((key, _) {
          final lower = key.toLowerCase();
          return lower == 'authorization' ||
              lower == 'proxy-authorization' ||
              lower == 'cookie';
        });
      }
      _headersByUrl[targetUrl] = childHeaders;
      final ext = playlist || _isHlsUrl(target) ? '.m3u8' : '.resource';
      return 'http://127.0.0.1:$_proxyPort/115_stream$ext?u=${Uri.encodeQueryComponent(targetUrl)}';
    }

    final uriAttr = RegExp(r'URI="([^"]+)"');
    final output = StringBuffer();
    var nextIsPlaylist = false;
    for (final rawLine in const LineSplitter().convert(playlist)) {
      final line = rawLine.trim();
      if (line.startsWith('#')) {
        if (line.startsWith('#EXT-X-STREAM-INF:')) nextIsPlaylist = true;
        final playlistTag = line.startsWith('#EXT-X-MEDIA:') ||
            line.startsWith('#EXT-X-I-FRAME-STREAM-INF:') ||
            line.startsWith('#EXT-X-IMAGE-STREAM-INF:') ||
            line.startsWith('#EXT-X-RENDITION-REPORT:');
        output.writeln(line.replaceAllMapped(uriAttr, (match) {
          return 'URI="${wrapResource(match[1]!, playlist: playlistTag)}"';
        }));
      } else if (line.isNotEmpty) {
        output.writeln(wrapResource(line, playlist: nextIsPlaylist));
        nextIsPlaylist = false;
      }
    }

    final data = utf8.encode(output.toString());
    final response = request.response;
    response.contentLength = data.length;
    response.headers
        .set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl');
    response.headers.set('Access-Control-Allow-Origin', '*');
    if (request.method != 'HEAD') response.add(data);
    await response.close();
  }

  Future<void> _handleProxyRequest(HttpRequest request) async {
    final response = request.response;
    if (request.uri.path == '/__ping__') {
      response.statusCode = HttpStatus.noContent;
      await response.close();
      return;
    }
    final targetUrl = request.uri.queryParameters['u'] ?? '';
    final uri = Uri.tryParse(targetUrl);
    final headers = _headersByUrl[targetUrl];
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        headers == null) {
      response.statusCode = HttpStatus.badRequest;
      await response.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }

    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final path = request.uri.path.toLowerCase();
    try {
      if (path.endsWith('.m3u8') || _isHlsUrl(uri)) {
        await _serveProxyPlaylist(request, uri, headers);
        return;
      }
      if (path.endsWith('.resource') || path.endsWith('.key') ||
          path.endsWith('.ts')) {
        await _pipeProxyResource(request, uri, headers);
        return;
      }

      var meta = _proxyMetaCache[targetUrl];
      if (meta != null &&
          (DateTime.now().millisecondsSinceEpoch - meta.cachedAtMs) > 90000) {
        _proxyMetaCache.remove(targetUrl);
        meta = null;
      }
      if (meta == null) {
        final loading = _proxyMetaInFlight.putIfAbsent(
          targetUrl,
          () => _loadProxyMediaInfo(uri, headers, path),
        );
        try {
          meta = await loading;
        } finally {
          if (identical(_proxyMetaInFlight[targetUrl], loading)) {
            _proxyMetaInFlight.remove(targetUrl);
          }
        }
        if (meta != null) {
          if (!_proxyMetaCache.containsKey(targetUrl) &&
              _proxyMetaCache.length >= 32) {
            _proxyMetaCache.remove(_proxyMetaCache.keys.first);
          }
          _proxyMetaCache[targetUrl] = meta;
        }
      }
      if (meta == null) {
        await _pipeProxyResource(request, uri, headers);
        return;
      }

      final range = _resolveMediaRange(rangeHeader, meta.totalSize);
      if (range == null) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${meta.totalSize}',
        );
        await response.close();
        return;
      }

      response.statusCode = rangeHeader == null
          ? HttpStatus.ok
          : HttpStatus.partialContent;
      response.bufferOutput = false;
      response.contentLength = range.end - range.start + 1;
      response.headers.set(HttpHeaders.contentTypeHeader, meta.contentType);
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set('Access-Control-Allow-Origin', '*');
      if (rangeHeader != null) {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${range.start}-${range.end}/${meta.totalSize}',
        );
      }
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }

      var disconnected = false;
      unawaited(response.done.then<void>(
        (_) => disconnected = true,
        onError: (Object _) => disconnected = true,
      ));

      var cursor = range.start;
      final cached = meta.normalizedHeaderChunk;
      if (cursor < cached.length) {
        final end = min(range.end + 1, cached.length);
        response.add(Uint8List.sublistView(cached, cursor, end));
        await response.flush();
        cursor = end;
      }

      if (cursor <= range.end && !meta.supportsRanges && !disconnected) {
        await _streamWithoutUpstreamRanges(
          response,
          uri,
          headers,
          skip: cursor + meta.stripPrefixBytes,
          length: range.end - cursor + 1,
          isCancelled: () => disconnected,
        );
      } else {
        const chunkSize = 2 * 1024 * 1024;
        while (cursor <= range.end && !disconnected) {
          final rawStart = cursor + meta.stripPrefixBytes;
          final rawEnd =
              min(range.end, cursor + chunkSize - 1) + meta.stripPrefixBytes;
          final chunk = await _fetchUpstreamRangeChunk(
            uri: uri,
            customHeaders: headers,
            start: rawStart,
            end: rawEnd,
            isCancelled: () => disconnected,
          );
          if (chunk == null ||
              chunk.totalSize != meta.totalSize + meta.stripPrefixBytes ||
              disconnected) {
            break;
          }
          response.add(chunk.bytes);
          await response.flush();
          cursor += chunk.bytes.length;
        }
      }

      await response.close();
    } catch (_) {
      try {
        response.statusCode = HttpStatus.badGateway;
      } catch (_) {}
      try {
        await response.close();
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
            final decU = utf8
                .decode(
                  base64Url.decode(base64Url.normalize(encU)),
                  allowMalformed: true,
                )
                .trim();
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
        // Drop headers for the backend before merging the upstream headers.
        mergedHeaders.removeWhere(
          (key, _) => const {
            'authorization',
            'x-auth-secret',
            'cookie',
          }.contains(key.toLowerCase()),
        );
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
    String timeStr = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
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
            final state =
                res['state'] == true ||
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
            final pct =
                double.tryParse(
                  (matchedLixian['percentDone'] ??
                          matchedLixian['percent'] ??
                          0)
                      .toString(),
                ) ??
                0.0;
            final fileId =
                (matchedLixian['file_id'] ??
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

  /// Reuses an exact cloud match or downloads, uploads, and checks the file
  /// produced by the submitted server task.
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
    final cleanName = videoName.replaceAll(RegExp(r'[/\\:]'), '_').trim();
    final taskTitle = cleanName.isEmpty
        ? '115加速_${DateTime.now().millisecondsSinceEpoch}'
        : cleanName;
    bool cancelled() => pipelineId != _activePipelineId;

    void update(String title, String detail, double progress) {
      if (cancelled()) return;
      _stageTitle = title;
      _detailText = detail;
      _progress = progress;
      notifyListeners();
    }

    _isAccelerating = true;
    update('正在 115 网盘查找当前视频', taskTitle, 0.06);

    try {
      if (!hasLocalCookie) {
        throw const ApiException('请先登录 115 网盘账号');
      }
      final lookupNames = <String>{taskTitle, videoName};
      final existing = await findAndResolveDirectPlayUrl(
        keywords: lookupNames.toList(),
        preferMp4Only: true,
      );
      if (cancelled()) return null;
      if (existing != null) return existing;

      final candidates = <String, Map<String, String>>{};
      for (final raw in [downloadUrl, ...fallbackDownloadUrls]) {
        final source = unwrapDownloadTargetUrlAndHeaders(raw, headers);
        final uri = Uri.tryParse(source.url);
        if (uri == null ||
            !const {'http', 'https', 'magnet', 'ed2k'}.contains(uri.scheme) ||
            (const {'http', 'https'}.contains(uri.scheme) &&
                uri.host.isEmpty) ||
            uri.host == 'localhost' ||
            InternetAddress.tryParse(uri.host)?.isLoopback == true) {
          continue;
        }
        candidates.putIfAbsent(source.url, () => source.headers);
      }
      if (candidates.isEmpty) {
        throw const ApiException('当前播放线路没有可供服务端下载的地址');
      }

      var failure = '服务器未完成当前视频的下载';
      var serverReady = false;
      try {
        final folder = await ensureAccelerationFolderCid(forceVerify: true);
        if (cancelled()) return null;
        if (!hasLocalCookie) {
          throw const ApiException('115 登录已过期，请重新登录');
        }
        if (folder == '0') {
          throw ApiException('无法找到或创建 115 加速目录 /$targetFolderName');
        }
        Map<String, dynamic>? account;
        try {
          account = await api.fetch115Status();
        } on ApiException catch (error) {
          if (error.statusCode != HttpStatus.unauthorized) rethrow;
        }
        if (cancelled()) return null;
        final localUid = _extractUidFromCookie();
        if (!hasLocalCookie || localUid.isEmpty) {
          throw const ApiException('115 登录已过期，请重新登录');
        }
        final accountId =
            account?['Id'] ?? account?['user_id'] ?? account?['uid'];
        if (accountId?.toString() != localUid) {
          await api.login115WithCookie(_cookie);
          if (cancelled()) return null;
        }
        await _syncFolderCidToServer(
          api,
          folder,
          throwOnFailure: true,
          ensureConvertToMp4: true,
        );
        serverReady = true;
      } catch (error) {
        failure = '服务端 115 上传准备失败：$error';
      }

      var serverHasVideo = false;
      if (serverReady) {
        final candidateList = candidates.entries.toList();
        for (var cIdx = 0; cIdx < candidateList.length; cIdx++) {
          final candidate = candidateList[cIdx];
          if (cancelled()) return null;
          final lineSuffix = candidateList.length > 1
              ? ' (线路 ${cIdx + 1}/${candidateList.length})'
              : '';
          update(
            cIdx == 0
                ? '阶段 1/3 · 正在提交下载任务'
                : '阶段 1/3 · 当前线路下载出错，正在切换备用线路 (${cIdx + 1}/${candidateList.length})',
            '$taskTitle$lineSuffix',
            0.10,
          );
          var forced = false;
          var retried = false;
          var duplicateRetryPolls = 0;
          var convertRequested = false;
          var convertReady = false;
          var convertPolls = 0;
          var uploadRequested = false;
          var missingPolls = 0;
          var uploadedPolls = 0;
          var candidateCompletedUpload = false;

          // Pre-clean any stale Failed tasks with the same name or URL so the server creates a clean download task
          try {
            final existingTasks = await api.fetchDownloadTasks();
            for (final stale in existingTasks) {
              if (stale.status == 'Failed' &&
                  (stale.url == candidate.key || stale.name == taskTitle)) {
                try {
                  await api.deleteDownloadTask(stale.id, deleteFiles: true);
                } catch (_) {}
              }
            }
          } catch (_) {}
          if (cancelled()) return null;

          Future<String?> submit({required bool force}) {
            return api.createDownloadTask(
              url: candidate.key,
              name: taskTitle,
              headers: candidate.value,
              telegramAccountId: telegramAccountId,
              forceDuplicate: force,
            );
          }

          String? taskId;
          try {
            taskId = await submit(force: cIdx > 0);
            if (cIdx > 0) forced = true;
          } catch (error) {
            failure = '提交下载任务失败：$error';
            continue;
          }
          if (taskId == null) {
            failure = '服务器未返回下载任务 ID';
            continue;
          }

          pollTask:
          for (var poll = 0; poll < 600 && !cancelled(); poll++) {
            DownloadTask? task;
            var listedTasks = false;
            try {
              final tasks = await api.fetchDownloadTasks();
              listedTasks = true;
              task = tasks.where((item) => item.id == taskId).firstOrNull;
              if (task == null) {
                task = tasks
                    .where(
                      (item) =>
                          (item.url == candidate.key ||
                              item.name == taskTitle) &&
                          item.status != 'Failed',
                    )
                    .firstOrNull;
                task ??= tasks
                    .where(
                      (item) =>
                          item.url == candidate.key || item.name == taskTitle,
                    )
                    .firstOrNull;
                if (task != null) {
                  taskId = task.id;
                }
              }
            } catch (error) {
              failure = '获取下载任务失败：$error';
            }
            if (cancelled()) return null;

            if (task == null) {
              if (++missingPolls >= 4) {
                if (listedTasks && !forced) {
                  forced = true;
                  update('阶段 1/3 · 下载任务已不存在，正在重新提交', taskTitle, 0.10);
                  try {
                    final freshId = await submit(force: true);
                    if (cancelled()) return null;
                    if (freshId != null) {
                      taskId = freshId;
                      missingPolls = 0;
                      continue;
                    }
                  } catch (error) {
                    failure = '重新提交下载任务失败：$error';
                    break;
                  }
                }
                if (listedTasks) failure = '服务器未找到已提交的下载任务';
                break;
              }
            } else {
              missingPolls = 0;
              final outputName = task.outputFile
                  .replaceAll('\\', '/')
                  .split('/')
                  .last;
              final mp4OutputPath = _ensureMp4OutputPath(
                task.outputFile,
                fallbackTaskName: task.name.isNotEmpty ? task.name : taskTitle,
              );
              final mp4OutputName = mp4OutputPath
                  .replaceAll('\\', '/')
                  .split('/')
                  .last;
              final taskNames = <String>{
                if (mp4OutputName.isNotEmpty) mp4OutputName,
                if (outputName.isNotEmpty) outputName,
                if (task.name.isNotEmpty) task.name,
                ...lookupNames,
              };
              final progress = task.progress.clamp(0.0, 100.0) / 100;

              if ((task.status == 'Duplicate' || task.status == 'Completed') &&
                  (!convertRequested || convertReady || uploadRequested)) {
                final stream = await findAndResolveDirectPlayUrl(
                  keywords: taskNames.toList(),
                  searchAccount: !uploadRequested || uploadedPolls % 5 == 4,
                  preferMp4Only: true,
                );
                if (cancelled()) return null;
                if (stream != null) return stream;
              }

              try {
                switch (task.status) {
                  case 'Duplicate':
                    if (!forced) {
                      forced = true;
                      update('阶段 1/3 · 115 未找到重复任务的文件，正在重新下载', taskTitle, 0.10);
                      final freshId = await submit(force: true);
                      if (cancelled()) return null;
                      if (freshId != null && freshId != taskId) {
                        taskId = freshId;
                        continue;
                      }
                    }
                    if (!retried) {
                      retried = true;
                      try {
                        await api.retryDownloadTask(task.id);
                      } on ApiException catch (e) {
                        if (e.statusCode == HttpStatus.notFound ||
                            e.statusCode == HttpStatus.methodNotAllowed) {
                          try {
                            await api.deleteDownloadTask(
                              task.id,
                              deleteFiles: true,
                            );
                          } catch (_) {}
                          final freshId = await submit(force: true);
                          if (cancelled()) return null;
                          if (freshId != null) {
                            taskId = freshId;
                            continue;
                          }
                        } else {
                          rethrow;
                        }
                      }
                    } else if (++duplicateRetryPolls >= 4) {
                      failure = '重复任务的文件已不可用，服务器未能重新下载';
                      break pollTask;
                    }
                    break;
                  case 'Completed':
                    final errLower = task.error.toLowerCase();
                    final needsServerMp4Convert = !convertReady &&
                        !uploadRequested &&
                        (_isNonMp4OutputFile(outputName) ||
                            errLower.contains('mp4 conversion failed') ||
                            (outputName.isEmpty && task.urlType == 'm3u8'));

                    if (needsServerMp4Convert) {
                      final tsSourcePath = task.outputFile.trim().isNotEmpty
                          ? task.outputFile.trim()
                          : 'downloads/${task.name.isNotEmpty ? task.name : taskTitle}.ts';
                      if (!convertRequested) {
                        convertRequested = true;
                        update('阶段 1/3 · 下载完成，正在服务端转成 MP4...', task.name, 0.70);
                        final ready = await _ensureServerConvertedToMp4(
                          api: api,
                          task: task,
                          tsSourcePath: tsSourcePath,
                          mp4OutputPath: mp4OutputPath,
                          onUpdate: update,
                          isCancelled: cancelled,
                        );
                        if (cancelled()) return null;
                        if (ready) {
                          convertReady = true;
                        } else {
                          convertPolls = 1;
                          break;
                        }
                      } else {
                        convertPolls++;
                        final ready = await _pollServerMp4ConversionStatus(
                          api: api,
                          task: task,
                          tsSourcePath: tsSourcePath,
                          mp4OutputPath: mp4OutputPath,
                          pollTick: convertPolls,
                          onUpdate: update,
                        );
                        if (cancelled()) return null;
                        if (ready) {
                          convertReady = true;
                        } else if (convertPolls < 90) {
                          break;
                        } else {
                          convertReady = true;
                        }
                      }
                    }

                    update('阶段 3/3 · 正在核对 115 中的当前视频', task.name, 0.92);
                    if (!uploadRequested) {
                      uploadRequested = true;
                      update(
                        '阶段 2/3 · 正在将转码后的 MP4 上传至 115',
                        mp4OutputName.isNotEmpty ? mp4OutputName : task.name,
                        0.76,
                      );
                      try {
                        await api.uploadTaskTo115(task.id);
                      } on ApiException catch (error) {
                        if (!const {
                          HttpStatus.notFound,
                          HttpStatus.methodNotAllowed,
                          HttpStatus.badRequest,
                        }.contains(error.statusCode)) {
                          rethrow;
                        }
                        final uploadPath = mp4OutputPath.isNotEmpty
                            ? mp4OutputPath
                            : task.outputFile;
                        if (uploadPath.isEmpty) rethrow;
                        await api.uploadFileTo115(uploadPath);
                      }
                      candidateCompletedUpload = true;
                    } else if (++uploadedPolls >= 25) {
                      // Final fallback check allowing non-MP4 in case the source was non-remuxable
                      final anyStream = await findAndResolveDirectPlayUrl(
                        keywords: taskNames.toList(),
                        searchAccount: true,
                      );
                      if (cancelled()) return null;
                      if (anyStream != null) return anyStream;

                      final reason = task.error.trim();
                      failure = reason.isEmpty
                          ? '上传后未在 115 网盘找到当前视频'
                          : '115 上传失败：$reason';
                      break pollTask;
                    }
                    break;
                  case 'Uploading':
                    candidateCompletedUpload = true;
                    final pct = task.progress.toStringAsFixed(1);
                    update(
                      '阶段 2/3 · 正在上传 MP4 至 115',
                      '上传进度 $pct% · ${task.name}',
                      0.72 + progress * 0.18,
                    );
                    break;
                  case 'Downloading':
                  case 'Pending':
                    final segDetail = task.totalSegments > 0
                        ? ' · 分片 ${task.downloadedSegments}/${task.totalSegments}'
                        : '';
                    update(
                      '阶段 1/3 · 正在下载视频$lineSuffix',
                      '下载进度 ${task.progress.toStringAsFixed(1)}% · ${task.formattedSpeed}$segDetail',
                      0.10 + progress * 0.58,
                    );
                    break;
                  case 'Converting':
                    convertReady = true;
                    update('阶段 1/3 · 服务器正在转成 MP4', task.name, 0.70);
                    break;
                  case 'Failed':
                    final reason = task.error.trim();
                    failure = reason.isEmpty
                        ? (uploadRequested ? '115 上传失败' : '服务器下载失败')
                        : reason;
                    // If the task actually finished downloading (or only failed during 115 auto-upload),
                    // convert to MP4 and trigger 115 upload instead of discarding the downloaded file!
                    final hasDownloadedOutput = outputName.isNotEmpty ||
                        reason.toLowerCase().contains('download success') ||
                        reason.toLowerCase().contains('115');
                    if (hasDownloadedOutput && !uploadRequested) {
                      final tsSourcePath = task.outputFile.trim().isNotEmpty
                          ? task.outputFile.trim()
                          : 'downloads/${task.name.isNotEmpty ? task.name : taskTitle}.ts';
                      if (!convertReady && _isNonMp4OutputFile(tsSourcePath)) {
                        update('阶段 1/3 · 下载完成，正在服务端转成 MP4...', task.name, 0.70);
                        await _ensureServerConvertedToMp4(
                          api: api,
                          task: task,
                          tsSourcePath: tsSourcePath,
                          mp4OutputPath: mp4OutputPath,
                          onUpdate: update,
                          isCancelled: cancelled,
                        );
                        if (cancelled()) return null;
                        convertReady = true;
                      }
                      uploadRequested = true;
                      update(
                        '阶段 2/3 · 正在将转码后的 MP4 上传至 115',
                        mp4OutputName.isNotEmpty ? mp4OutputName : task.name,
                        0.76,
                      );
                      try {
                        await api.uploadTaskTo115(task.id);
                      } catch (_) {
                        final uploadPath = mp4OutputPath.isNotEmpty
                            ? mp4OutputPath
                            : task.outputFile;
                        if (uploadPath.isNotEmpty) {
                          await api.uploadFileTo115(uploadPath);
                        }
                      }
                      candidateCompletedUpload = true;
                      break;
                    }
                    if (!uploadRequested && !retried && outputName.isEmpty) {
                      retried = true;
                      update('阶段 1/3 · 服务器下载出错，正在自动重试...', reason, 0.12);
                      try {
                        await api.retryDownloadTask(task.id);
                        break;
                      } on ApiException catch (e) {
                        if (e.statusCode == HttpStatus.notFound ||
                            e.statusCode == HttpStatus.methodNotAllowed) {
                          try {
                            await api.deleteDownloadTask(
                              task.id,
                              deleteFiles: true,
                            );
                          } catch (_) {}
                          final freshId = await submit(force: true);
                          if (cancelled()) return null;
                          if (freshId != null && freshId != taskId) {
                            taskId = freshId;
                            continue;
                          }
                        }
                      } catch (_) {}
                    }
                    break pollTask;
                  default:
                    failure = '服务器任务状态无法识别：${task.status}';
                    break pollTask;
                }
              } catch (error) {
                failure = uploadRequested
                    ? '115 上传请求失败：$error'
                    : '重新下载失败：$error';
                break;
              }
            }

            await Future<void>.delayed(const Duration(milliseconds: 1200));
          }
          if (candidateCompletedUpload) {
            serverHasVideo = true;
            break;
          }
        }
      }

      if (cancelled()) return null;
      if (!serverHasVideo) {
        final offline = await _try115CloudOfflineLixianFallback(
          pipelineId: pipelineId,
          candidateUrls: candidates.keys.toList(),
          searchKeywords: lookupNames.toList(),
        );
        if (cancelled()) return null;
        if (offline != null) return offline;
      }
      throw ApiException(failure);
    } catch (error) {
      if (!cancelled()) onError?.call('$error');
      return null;
    } finally {
      if (!cancelled()) {
        _isAccelerating = false;
        notifyListeners();
      }
    }
  }

  static bool _isNonMp4OutputFile(String pathOrName) {
    final clean = pathOrName.trim().toLowerCase();
    if (clean.isEmpty) return false;
    if (clean.endsWith('.mp4')) return false;
    final dot = clean.lastIndexOf('.');
    return dot > 0 && dot < clean.length - 1;
  }

  static String _ensureMp4OutputPath(
    String rawOutputFile, {
    required String fallbackTaskName,
  }) {
    final clean = rawOutputFile.trim();
    if (clean.isEmpty) {
      return 'downloads/$fallbackTaskName.mp4';
    }
    if (clean.toLowerCase().endsWith('.mp4')) return clean;
    final normalized = clean.replaceAll('\\', '/');
    final slashIdx = normalized.lastIndexOf('/');
    final dirPrefix = slashIdx >= 0 ? normalized.substring(0, slashIdx + 1) : '';
    final fileName = slashIdx >= 0
        ? normalized.substring(slashIdx + 1)
        : normalized;
    final dotIdx = fileName.lastIndexOf('.');
    final baseName = dotIdx > 0 ? fileName.substring(0, dotIdx) : fileName;
    return '$dirPrefix$baseName.mp4';
  }

  /// Ensures a downloaded non-MP4 file (e.g. `.ts`) on the server is converted to `.mp4`
  /// before uploading to 115 Cloud Drive.
  Future<bool> _ensureServerConvertedToMp4({
    required ApiClient api,
    required DownloadTask task,
    required String tsSourcePath,
    required String mp4OutputPath,
    required void Function(String title, String detail, double progress)
    onUpdate,
    required bool Function() isCancelled,
  }) async {
    final mp4Name = mp4OutputPath.replaceAll('\\', '/').split('/').last;
    try {
      final dirPath = mp4OutputPath.contains('/')
          ? mp4OutputPath
                .replaceAll('\\', '/')
                .substring(0, mp4OutputPath.replaceAll('\\', '/').lastIndexOf('/'))
          : '';
      for (final checkDir in <String>{if (dirPath.isNotEmpty) dirPath, ''}) {
        try {
          final listing = await api.fetchFiles(path: checkDir);
          final hasMp4 = listing.entries.any(
            (e) =>
                !e.isDir &&
                (e.name.toLowerCase() == mp4Name.toLowerCase() ||
                    e.path.toLowerCase().endsWith(mp4Name.toLowerCase())) &&
                e.size > 0,
          );
          if (hasMp4) return true;
        } catch (_) {}
      }
    } catch (_) {}

    if (isCancelled()) return false;
    try {
      await api.convertFileToMp4(tsSourcePath);
    } on ApiException catch (e) {
      // 409 Conflict means conversion is already running; 400/404 means either already converted or endpoint unavailable
      if (e.statusCode != HttpStatus.conflict) {
        return true;
      }
    } catch (_) {
      return true;
    }

    return _pollServerMp4ConversionStatus(
      api: api,
      task: task,
      tsSourcePath: tsSourcePath,
      mp4OutputPath: mp4OutputPath,
      pollTick: 0,
      onUpdate: onUpdate,
    );
  }

  Future<bool> _pollServerMp4ConversionStatus({
    required ApiClient api,
    required DownloadTask task,
    required String tsSourcePath,
    required String mp4OutputPath,
    required int pollTick,
    required void Function(String title, String detail, double progress)
    onUpdate,
  }) async {
    final tsName = tsSourcePath.replaceAll('\\', '/').split('/').last;
    final mp4Name = mp4OutputPath.replaceAll('\\', '/').split('/').last;

    try {
      final ops = await api.fetchServerFileOps();
      final convertOp = ops.where((op) {
        final type = (op['type'] ?? '').toString().toLowerCase();
        final fn = (op['file_name'] ?? '')
            .toString()
            .replaceAll('\\', '/')
            .split('/')
            .last;
        return type == 'convert' &&
            (fn.toLowerCase() == tsName.toLowerCase() ||
                fn.toLowerCase() == mp4Name.toLowerCase());
      }).firstOrNull;

      if (convertOp != null) {
        final status = (convertOp['status'] ?? '').toString().toLowerCase();
        final pct =
            double.tryParse((convertOp['progress'] ?? 0).toString()) ?? 0.0;
        if (status == 'processing') {
          onUpdate(
            '阶段 1/3 · 服务器正在转成 MP4',
            '转码进度 ${pct.toStringAsFixed(1)}% · ${task.name}',
            0.69 + (pct.clamp(0.0, 100.0) / 100.0) * 0.05,
          );
          return false;
        }
        if (status == 'completed') {
          return true;
        }
        if (status == 'failed') {
          return true;
        }
      }
    } catch (_) {}

    final dirPath = mp4OutputPath.contains('/')
        ? mp4OutputPath
              .replaceAll('\\', '/')
              .substring(0, mp4OutputPath.replaceAll('\\', '/').lastIndexOf('/'))
        : '';
    for (final checkDir in <String>{if (dirPath.isNotEmpty) dirPath, ''}) {
      try {
        final listing = await api.fetchFiles(path: checkDir);
        final hasMp4 = listing.entries.any(
          (e) =>
              !e.isDir &&
              (e.name.toLowerCase() == mp4Name.toLowerCase() ||
                  e.path.toLowerCase().endsWith(mp4Name.toLowerCase())) &&
              e.size > 0,
        );
        if (hasMp4) return true;
      } catch (_) {}
    }

    // Check if the task status itself transitioned to Converting -> Completed
    try {
      final tasks = await api.fetchDownloadTasks();
      final cur = tasks.where((t) => t.id == task.id).firstOrNull;
      if (cur != null) {
        if (cur.status == 'Converting') {
          onUpdate('阶段 1/3 · 服务器正在转成 MP4', task.name, 0.70);
          return false;
        }
        if (cur.outputFile.toLowerCase().endsWith('.mp4')) {
          return true;
        }
      }
    } catch (_) {}

    return pollTick >= 2;
  }

  Future<dynamic> _getJson(
    Uri uri, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    Future<dynamic> fetchOnce() async {
      final req = await _httpClient.getUrl(uri).timeout(timeout);
      requestHeaders.forEach(req.headers.set);
      final resp = await req.close().timeout(timeout);
      return await _readJsonResponse(resp).timeout(timeout);
    }

    try {
      return await fetchOnce();
    } catch (_) {
      _recreateHttpClient();
      return await fetchOnce();
    }
  }

  Future<dynamic> _postFormJson(
    Uri uri, {
    required String body,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final resp = await _postForm(uri, body: body, timeout: timeout);
    return _readJsonResponse(resp).timeout(timeout);
  }

  Future<HttpClientResponse> _postForm(
    Uri uri, {
    required String body,
    required Duration timeout,
  }) async {
    Future<HttpClientResponse> sendOnce() async {
      final req = await _httpClient.postUrl(uri).timeout(timeout);
      requestHeaders.forEach(req.headers.set);
      req.headers.set('Content-Type', 'application/x-www-form-urlencoded');
      final bodyBytes = utf8.encode(body);
      req.contentLength = bodyBytes.length;
      req.add(bodyBytes);
      return req.close().timeout(timeout);
    }

    try {
      return await sendOnce();
    } catch (_) {
      _recreateHttpClient();
      return await sendOnce();
    }
  }

  Future<dynamic> _readJsonResponse(
    HttpClientResponse resp, {
    bool captureAuthCookie = false,
  }) async {
    if (captureAuthCookie) {
      for (final c in resp.cookies) {
        if (c.name.isNotEmpty && c.value.isNotEmpty) {
          _latestCdnAuthCookie = '${c.name}=${c.value}';
          _latestCdnAuthCookieAtMs = DateTime.now().millisecondsSinceEpoch;
        }
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
        final entry = _decode115Entry(item, parentCid: cleanCid, mountId: mountId);
        if (entry == null ||
            !seenEntryKeys.add('${entry.isDir}::${entry.path}::${entry.name}')) {
          continue;
        }
        if (entry.isDir) {
          _cidParentMap[entry.cid115] = cleanCid;
          _cidNameMap[entry.cid115] = entry.name;
        }
        entries.add(entry);
      }
    }

    return FileDirectoryListing(
      path: cleanCid,
      parent: cleanCid == '0' ? '' : resolvedParent,
      root: '0',
      entries: entries,
    );
  }

  FileEntry? _decode115Entry(
    Map<String, dynamic> item, {
    required String parentCid,
    required String mountId,
  }) {
    final fid = (item['fid'] ?? item['file_id'] ?? '').toString().trim();
    final itemCid = (item['cid'] ?? item['category_id'] ?? '')
        .toString()
        .trim();
    final hasValidFid = fid.isNotEmpty && fid != '0';
    // Android uses fid for both files and folders, with fc marking the type.
    // The web listings identify folders by cid and omit fid.
    final isDir = switch (item['fc']?.toString()) {
      '0' => true,
      '1' => false,
      _ => !hasValidFid && itemCid.isNotEmpty && itemCid != '0',
    };
    final folderCid = hasValidFid ? fid : itemCid;
    if (isDir &&
        (folderCid.isEmpty || folderCid == '0' || folderCid == parentCid)) {
      return null;
    }
    final name =
        (item['n'] ?? item['ns'] ?? item['fn'] ?? item['file_name'] ?? '未命名')
            .toString();
    final size =
        int.tryParse(
          (item['s'] ?? item['fs'] ?? item['file_size'] ?? 0).toString(),
        ) ??
        0;
    final pickcode = (item['pc'] ?? item['pick_code'] ?? '').toString().trim();
    final ico = (item['ico'] ?? '').toString().toLowerCase().trim().replaceAll(
      '.',
      '',
    );
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
    final ts =
        int.tryParse((item['te'] ?? item['tp'] ?? item['t'] ?? 0).toString()) ??
        0;
    String modStr = (item['te'] ?? '').toString();
    if (ts > 100000) {
      final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
      modStr =
          '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    final thumb = (item['u'] ?? '').toString();
    final entryPath = isDir ? folderCid : (hasValidFid ? fid : pickcode);
    return FileEntry(
      name: name,
      path: entryPath,
      size: size,
      modTime: modStr,
      isDir: isDir,
      isMp4: !isDir && (ext == '.mp4' || (is115Video && ext.isEmpty)),
      ext: ext,
      mountId: mountId,
      sourceKind: StorageSourceKind.cloud115,
      thumbUrl: thumb,
      pickcode115: pickcode,
      fid115: isDir ? folderCid : fid,
      cid115: isDir ? folderCid : parentCid,
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

  Future<String> rename115File({
    required String fid,
    required String currentName,
    required String newName,
    required bool isDir,
  }) async {
    final id = _validate115FileId(fid);
    if (!isDir && changes115FileSuffix(currentName, newName)) {
      throw const ApiException('115 重命名会保留原文件后缀，请保留原后缀后再保存');
    }
    final result = await _post115FileOperation('/files/batch_rename', {
      'files_new_name[$id]': newName,
    });
    final names = result['data'];
    final savedName = names is Map ? names[id] : null;
    if (savedName is! String || savedName.isEmpty) {
      throw const ApiException('115 未确认保存后的文件名');
    }
    return savedName;
  }

  static bool changes115FileSuffix(String currentName, String newName) =>
      _fileNameSuffix(currentName) != _fileNameSuffix(newName);

  final _replacing115Files = <String>{};

  Future<void> replace115FileSuffix(FileEntry entry, String newName) async {
    await ensureInitialized();
    if (!hasLocalCookie) {
      throw const ApiException('请先登录 115 网盘账号');
    }
    if (entry.sourceKind != StorageSourceKind.cloud115 ||
        entry.isDir ||
        !changes115FileSuffix(entry.name, newName)) {
      throw const ApiException('请选择需要更换后缀的 115 文件');
    }
    if (newName.trim().isEmpty ||
        newName == '.' ||
        newName == '..' ||
        newName.contains(RegExp(r'[/\\\x00-\x1f]'))) {
      throw const ApiException('请输入有效的文件名');
    }
    final id = _validate115FileId(entry.fid115);
    final parentCid = entry.cid115 == '0'
        ? '0'
        : _validate115FileId(entry.cid115);
    if (!_replacing115Files.add(id)) {
      throw const ApiException('该文件正在更换后缀');
    }
    final accountCookie = _cookie;
    try {
      final original = await _read115FileInfo(id);
      if (original.name != entry.name ||
          original.pickcode != entry.pickcode115 ||
          !await _is115FileInDirectory(id, parentCid)) {
        throw const ApiException('115 原件信息已变化，请刷新目录后重试');
      }
      final directory = await list115Directory(cid: parentCid);
      if (directory.entries.any(
        (item) =>
            item.fid115 != id &&
            item.name.toLowerCase() == newName.toLowerCase(),
      )) {
        throw const ApiException('115 目录里已有同名项目');
      }
      if (_cookie != accountCookie) {
        throw const ApiException('115 登录状态已变化，请重试');
      }

      final pickcode = await _copy115FileByHash(
        name: newName,
        parentCid: parentCid,
        fileHash: original.fileHash,
        size: original.size,
        sourcePickcode: original.pickcode,
      );
      FileEntry? newEntry;
      for (var attempt = 0; attempt < 5; attempt++) {
        final refreshed = await list115Directory(cid: parentCid);
        newEntry = refreshed.entries
            .where((item) => !item.isDir && item.pickcode115 == pickcode)
            .firstOrNull;
        if (newEntry != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
      if (newEntry == null ||
          newEntry.fid115.isEmpty ||
          newEntry.fid115 == id) {
        throw const ApiException('115 未能确认新文件已创建，原件已保留');
      }
      final copy = await _read115FileInfo(newEntry.fid115);
      if (copy.name != newName ||
          copy.pickcode != pickcode ||
          copy.size != original.size ||
          copy.fileHash != original.fileHash) {
        throw const ApiException('新文件的名称或内容校验失败，原件已保留');
      }
      if (await _read115FileInfo(id) != original ||
          !await _is115FileInDirectory(id, parentCid) ||
          _cookie != accountCookie) {
        throw const ApiException('原件或登录状态已变化，新文件已创建，原件已保留');
      }
      try {
        await delete115Files(fids: [id], parentCid: parentCid);
      } catch (e) {
        throw ApiException('新文件已校验，原件移入回收站失败：$e');
      }
    } finally {
      _replacing115Files.remove(id);
    }
  }

  Future<({String name, String pickcode, int size, String fileHash})>
  _read115FileInfo(String id) async {
    final root = await _getJson(
      Uri.https('webapi.115.com', '/files/file', {'file_id': id}),
    );
    if (root is Map<String, dynamic> &&
        root['state'] == true &&
        root['data'] is List) {
      for (final item in root['data'] as List) {
        if (item is! Map || item['file_id']?.toString() != id) continue;
        final size = int.tryParse(item['file_size']?.toString() ?? '');
        final name = item['file_name'];
        final pickcode = item['pick_code'];
        final hash = item['sha1']?.toString().toUpperCase() ?? '';
        if (size != null &&
            size >= 0 &&
            name is String &&
            pickcode is String &&
            pickcode.isNotEmpty &&
            RegExp(r'^[0-9A-F]{40}$').hasMatch(hash)) {
          return (name: name, pickcode: pickcode, size: size, fileHash: hash);
        }
      }
    }
    throw const ApiException('无法核对 115 文件的元数据');
  }

  Future<bool> _is115FileInDirectory(String id, String parentCid) async {
    final root = await _getJson(
      Uri.https('proapi.115.com', '/android/2.0/category/get', {
        'aid': '1',
        'cid': id,
      }),
    );
    if (root is! Map || root['file_id']?.toString() != id) return false;
    final paths = root['paths'];
    if (paths is! List || paths.isEmpty) return false;
    final parent = paths.last;
    return parent is Map && parent['file_id']?.toString() == parentCid;
  }

  Future<String> _copy115FileByHash({
    required String name,
    required String parentCid,
    required String fileHash,
    required int size,
    required String sourcePickcode,
  }) async {
    final info = await _getJson(Uri.https('proapi.115.com', '/app/uploadinfo'));
    final userId = info is Map ? info['user_id']?.toString() ?? '' : '';
    final userKey = info is Map ? info['userkey']?.toString() ?? '' : '';
    if (userId.isEmpty || userKey.isEmpty) {
      throw const ApiException('115 未返回上传凭证，原件已保留');
    }

    final protocol = Cloud115UploadProtocol();
    final target = 'U_1_$parentCid';
    final inner = sha1.convert(utf8.encode('$userId$fileHash${target}0'));
    final signature = sha1
        .convert(utf8.encode('$userKey${inner}000000'))
        .toString()
        .toUpperCase();
    final userHash = md5.convert(utf8.encode(userId));
    const appVersion = '27.0.5.7';

    Future<Map<String, dynamic>> initialize({
      String signKey = '',
      String signValue = '',
    }) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final token = md5.convert(
        utf8.encode(
          'Qclm8MGWUv59TnrR0XPg$fileHash$size$signKey$signValue'
          '$userId$now$userHash$appVersion',
        ),
      );
      final form = Uri(
        queryParameters: {
          'appid': '0',
          'appversion': appVersion,
          'userid': userId,
          'filename': name,
          'filesize': size.toString(),
          'fileid': fileHash,
          'target': target,
          'sig': signature,
          't': now.toString(),
          'token': token.toString(),
          if (signKey.isNotEmpty) 'sign_key': signKey,
          if (signValue.isNotEmpty) 'sign_val': signValue,
        },
      ).query;
      final uri = Uri.https('uplb.115.com', '/4.0/initupload.php', {
        'k_ec': protocol.encodeToken(now),
      });
      const timeout = Duration(seconds: 15);
      final request = await _httpClient.postUrl(uri).timeout(timeout);
      request.followRedirects = false;
      requestHeaders.forEach(request.headers.set);
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
      );
      final payload = protocol.encrypt(form);
      request.contentLength = payload.length;
      request.add(payload);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>().timeout(timeout);
        throw ApiException('115 创建新文件失败（HTTP ${response.statusCode}），原件已保留');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        bytes.add(chunk);
        if (bytes.length > 1024 * 1024) {
          throw const ApiException('115 返回了异常的上传响应，原件已保留');
        }
      }
      try {
        return protocol.decodeResponse(bytes.takeBytes());
      } on FormatException {
        throw const ApiException('无法读取 115 上传结果，原件已保留');
      } on RangeError {
        throw const ApiException('115 上传响应不完整，原件已保留');
      }
    }

    var result = await initialize();
    if (result['status']?.toString() == '7') {
      final signKey = result['sign_key']?.toString() ?? '';
      final range = RegExp(r'^(\d+)-(\d+)$')
          .firstMatch(result['sign_check']?.toString() ?? '');
      final start = int.tryParse(range?[1] ?? '');
      final end = int.tryParse(range?[2] ?? '');
      if (signKey.isEmpty ||
          start == null ||
          end == null ||
          end < start ||
          end >= size) {
        throw const ApiException('115 返回了无效的秒传校验范围，原件已保留');
      }
      final hash = await _hash115FileRange(sourcePickcode, start, end, size);
      result = await initialize(signKey: signKey, signValue: hash);
    }
    final pickcode = result['pickcode']?.toString() ?? '';
    if (result['status']?.toString() != '2' ||
        pickcode.isEmpty ||
        pickcode == sourcePickcode) {
      throw const ApiException('115 未能秒传新文件，原件已保留');
    }
    return pickcode;
  }

  Future<String> _hash115FileRange(
    String pickcode,
    int start,
    int end,
    int fileSize,
  ) async {
    final url = await resolvePickcodeStreamUrl(
      pickcode,
      forceRefresh: true,
      allowVideoFallback: false,
    );
    if (url == null) {
      throw const ApiException('无法获取 115 原件的下载地址，原件已保留');
    }
    final response = await _openProxyUpstream(
      Uri.parse(url),
      requestHeadersForUrl(url),
      range: 'bytes=$start-$end',
    );
    if (response.statusCode != HttpStatus.partialContent ||
        response.headers.value(HttpHeaders.contentRangeHeader) !=
            'bytes $start-$end/$fileSize') {
      await response.listen((_) {}).cancel();
      throw const ApiException('115 原件的分段校验请求失败，原件已保留');
    }
    var length = 0;
    final hash = await sha1
        .bind(
          response.timeout(const Duration(seconds: 15)).map((chunk) {
            length += chunk.length;
            return chunk;
          }),
        )
        .first;
    if (length != end - start + 1) {
      throw const ApiException('115 原件的分段校验数据不完整，原件已保留');
    }
    return hash.toString().toUpperCase();
  }

  Future<void> delete115Files({
    required Iterable<String> fids,
    required String parentCid,
  }) async {
    final ids = fids.map(_validate115FileId).toSet().toList();
    if (ids.isEmpty) return;
    final pid = (parentCid.isEmpty || parentCid == '/') ? '0' : parentCid;
    await _post115FileOperation('/rb/delete', {
      'pid': pid,
      for (var i = 0; i < ids.length; i++) 'fid[$i]': ids[i],
    });
  }

  static final _valid115FileId = RegExp(r'^[1-9][0-9]*$');

  static String _validate115FileId(String fid) {
    final id = fid.trim();
    if (!_valid115FileId.hasMatch(id)) {
      throw const ApiException('缺少有效的 115 文件 ID，请刷新目录后重试');
    }
    return id;
  }

  static String _fileNameSuffix(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 && dot < name.length - 1 ? name.substring(dot) : '';
  }

  Future<Map<String, dynamic>> _post115FileOperation(
    String path,
    Map<String, String> parameters,
  ) async {
    await ensureInitialized();
    if (!hasLocalCookie) {
      throw const ApiException('请先登录 115 网盘账号');
    }
    const timeout = Duration(seconds: 12);
    final response = await _postForm(
      Uri.https('webapi.115.com', path),
      body: Uri(queryParameters: parameters).query,
      timeout: timeout,
    );
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().timeout(timeout);
      throw ApiException(
        '115 接口请求失败（HTTP ${response.statusCode}）',
        statusCode: response.statusCode,
      );
    }
    final Object? result;
    try {
      result = await _readJsonResponse(response).timeout(timeout);
    } on FormatException {
      throw const ApiException('115 返回了无法识别的操作结果');
    }
    if (result is! Map<String, dynamic>) {
      throw const ApiException('115 返回了无法识别的操作结果');
    }
    final state = result['state'];
    if (state == true || state.toString() == '1') return result;
    for (final key in const ['error', 'message', 'msg']) {
      final message = result[key]?.toString().trim() ?? '';
      if (message.isNotEmpty) throw ApiException(message);
    }
    throw const ApiException('115 未确认操作成功，请刷新目录检查结果');
  }
}
