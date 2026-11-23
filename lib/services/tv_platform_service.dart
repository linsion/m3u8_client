import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ui/widgets/cloud_music_player.dart';

class TvPlatformInfo {
  final bool isTv;
  final bool hasController;
  final bool supportsAirPlay;
  final String platform;

  const TvPlatformInfo({
    this.isTv = false,
    this.hasController = false,
    this.supportsAirPlay = false,
    this.platform = 'unknown',
  });
}

/// Service for Android TV (Leanback / D-Pad) & Apple TV (tvOS / Siri Remote / AirPlay 2) integration.
class TvPlatformService {
  static const MethodChannel _channel =
      MethodChannel('com.linsion.m3u8_client/tv_platform');

  static Future<TvPlatformInfo> detectPlatformTvInfo() async {
    if (kIsWeb) {
      return const TvPlatformInfo();
    }
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'getPlatformTvInfo',
      );
      if (res != null) {
        return TvPlatformInfo(
          isTv: res['isTv'] == true,
          hasController: res['hasController'] == true,
          supportsAirPlay: res['supportsAirPlay'] == true,
          platform: (res['platform'] ?? 'unknown').toString(),
        );
      }
    } catch (_) {}

    final isApple = !kIsWeb && (Platform.isIOS || Platform.isMacOS);
    return TvPlatformInfo(
      isTv: false,
      hasController: false,
      supportsAirPlay: isApple,
      platform: isApple ? (Platform.isIOS ? 'ios' : 'macos') : 'other',
    );
  }

  /// Opens the native Apple AirPlay 2 route picker (`AVRoutePickerView`) on iOS/iPadOS/macOS/tvOS
  /// to stream directly to an Apple TV.
  static Future<bool> showAirPlayPicker() async {
    try {
      final ok = await _channel.invokeMethod<bool>('showAirPlayPicker');
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  /// Launches the built-in native AndroidX Media3 `ExoPlayer` zero-copy `SurfaceView`
  /// fullscreen player dialog on Android / Android TV for ultra-smooth 50GB+ 4K Blu-ray remux
  /// and high-bitrate live/VOD playback. Returns the playback position (in ms) when closed.
  static Future<({int positionMs, String? error})> openNativeExoPlayer({
    required String streamUrl,
    required String title,
    Map<String, String> headers = const {},
    int startPositionMs = 0,
  }) async {
    if (kIsWeb || !Platform.isAndroid) {
      return (positionMs: startPositionMs, error: 'Unsupported platform');
    }
    unawaited(CloudMusicController.stopAllBackgroundAudioForVideo());
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'openNativeExoPlayer',
        {
          'url': streamUrl,
          'title': title,
          'headers': headers,
          'positionMs': startPositionMs,
        },
      );
      final pos =
          int.tryParse((res?['positionMs'] ?? startPositionMs).toString()) ??
          startPositionMs;
      final err = res?['error']?.toString();
      return (positionMs: pos, error: err);
    } catch (e) {
      return (positionMs: startPositionMs, error: e.toString());
    }
  }

  /// Launches the stream in popular Apple TV / Android TV players (Infuse, VLC, IINA, MX Player).
  static Future<bool> openInTvExternalPlayer(
    String streamUrl, {
    required String playerType,
  }) async {
    final clean = streamUrl.trim();
    if (clean.isEmpty) return false;
    unawaited(CloudMusicController.stopAllBackgroundAudioForVideo());
    final encoded = Uri.encodeComponent(clean);

    Uri? targetUri;
    switch (playerType) {
      case 'infuse':
        // Infuse 7/8 on Apple TV, iOS, iPadOS, macOS
        targetUri = Uri.tryParse(
          'infuse://x-callback-url/play?url=$encoded',
        );
        break;
      case 'vlc':
        // VLC on Apple TV, Android TV, iOS, macOS
        targetUri = Uri.tryParse(
          'vlc-x-callback://x-callback-url/stream?url=$encoded',
        );
        break;
      case 'iina':
        // IINA on macOS
        targetUri = Uri.tryParse(
          'iina://weblink?url=$encoded',
        );
        break;
      case 'potplayer':
        // PotPlayer on Windows
        targetUri = Uri.tryParse('potplayer://$clean');
        break;
      case 'nplayer':
        // nPlayer on iOS / iPadOS / tvOS
        targetUri = Uri.tryParse('nplayer-$clean');
        break;
      default:
        targetUri = Uri.tryParse(clean);
    }

    if (targetUri == null) return false;
    try {
      return await launchUrl(
        targetUri,
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }
}

/// Built-in LAN HTTP & QR Code Remote Input Server for Android TV / TV Mode.
/// Allows scanning a QR code on the TV whenever any input field is focused or active,
/// and typing/pasting text on a phone/PC browser to fill the TV input box immediately.
class TvLanInputService extends ChangeNotifier {
  TvLanInputService._();
  static final TvLanInputService instance = TvLanInputService._();

  static const MethodChannel _qrChannel =
      MethodChannel('com.linsion.m3u8_client/qr_scanner');

  HttpServer? _server;
  String _lanUrl = '';
  Uint8List? _qrPngBytes;
  String _activeFieldLabel = '电视端当前输入框';
  String _activeFieldValue = '';
  void Function(String text, bool submit)? _activeReceiver;

  String get lanUrl => _lanUrl;
  Uint8List? get qrPngBytes => _qrPngBytes;
  String get activeFieldLabel => _activeFieldLabel;
  bool get isRunning => _server != null && _lanUrl.isNotEmpty;

  void bindActiveInput({
    required String label,
    required String currentValue,
    required void Function(String text, bool submit) onReceive,
  }) {
    _activeFieldLabel = label.trim().isEmpty ? '电视端当前输入框' : label.trim();
    _activeFieldValue = currentValue;
    _activeReceiver = onReceive;
    unawaited(ensureStarted());
    notifyListeners();
  }

  void unbindActiveInput() {
    _activeReceiver = null;
    notifyListeners();
  }

  Future<String> ensureStarted() async {
    if (kIsWeb) return '';
    if (_server != null && _lanUrl.isNotEmpty) {
      if (_qrPngBytes == null) {
        _qrPngBytes = await generateQrPng(_lanUrl, size: 320);
        notifyListeners();
      }
      return _lanUrl;
    }
    try {
      HttpServer srv;
      try {
        srv = await HttpServer.bind(InternetAddress.anyIPv4, 18089, shared: true);
      } catch (_) {
        srv = await HttpServer.bind(InternetAddress.anyIPv4, 0, shared: true);
      }
      _server = srv;
      final ip = await _detectLocalLanIp() ?? '127.0.0.1';
      _lanUrl = 'http://$ip:${srv.port}';
      _qrPngBytes = await generateQrPng(_lanUrl, size: 320);
      srv.listen(_handleHttpRequest, onError: (_) {});
      notifyListeners();
      return _lanUrl;
    } catch (_) {
      return '';
    }
  }

  static Future<Uint8List?> generateQrPng(String content, {int size = 320}) async {
    if (content.trim().isEmpty) return null;
    try {
      final res = await _qrChannel.invokeMethod<Uint8List>(
        'generateQrPng',
        {'content': content.trim(), 'size': size},
      );
      return res;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _detectLocalLanIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      String? fallback;
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (!ip.startsWith('169.254.') && ip != '127.0.0.1') {
            if (name.startsWith('wlan') ||
                name.startsWith('en') ||
                name.startsWith('eth')) {
              return ip;
            }
            fallback ??= ip;
          }
        }
      }
      return fallback;
    } catch (_) {
      return null;
    }
  }

  Future<void> _handleHttpRequest(HttpRequest req) async {
    try {
      if (req.method == 'POST' && req.uri.path == '/input') {
        final rawBody = await utf8.decoder.bind(req).join();
        final params = Uri.splitQueryString(rawBody);
        final text = (params['text'] ?? '');
        final action = (params['action'] ?? 'fill');
        if (_activeReceiver != null) {
          _activeReceiver!(text, action == 'submit');
        }
        _activeFieldValue = text;
        notifyListeners();
        final html = _buildHtmlPage(
          banner: '✅ 已成功发送到电视端「$_activeFieldLabel」！',
        );
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write(html);
        await req.response.close();
        return;
      }

      final html = _buildHtmlPage();
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(html);
      await req.response.close();
    } catch (_) {
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  String _buildHtmlPage({String? banner}) {
    final safeLabel = const HtmlEscape().convert(_activeFieldLabel);
    final safeVal = const HtmlEscape().convert(_activeFieldValue);
    final bannerHtml = banner != null
        ? '<div style="background:#14532d;border:1px solid #22c55e;color:#fff;padding:12px 15px;border-radius:12px;margin-bottom:14px;font-weight:600;">$banner</div>'
        : '';
    return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
  <title>流光视频 · 电视端扫码快捷输入助手</title>
  <style>
    * { box-sizing: border-box; }
    body {
      margin: 0; padding: 18px;
      background: #0B0C10; color: #F5F6FA;
      font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif;
    }
    .card {
      max-width: 560px; margin: 0 auto;
      background: #181B24; border: 1px solid #2D3346;
      border-radius: 20px; padding: 20px;
      box-shadow: 0 12px 32px rgba(0,0,0,0.45);
    }
    h2 { margin: 0 0 6px 0; font-size: 19px; color: #38BDF8; }
    p.sub { margin: 0 0 14px 0; font-size: 13px; color: #94A3B8; line-height: 1.45; }
    .tag {
      display: inline-block; background: rgba(56,189,248,0.16);
      color: #38BDF8; border: 1px solid rgba(56,189,248,0.38);
      padding: 4px 10px; border-radius: 999px; font-size: 12px; font-weight: 700;
      margin-bottom: 12px;
    }
    textarea {
      width: 100%; background: #101218; color: #fff;
      border: 1px solid #334155; border-radius: 14px;
      padding: 13px; font-size: 15px; outline: none;
    }
    textarea:focus { border-color: #38BDF8; }
    .btn-row { display: flex; gap: 10px; margin-top: 14px; }
    button {
      flex: 1;
      background: linear-gradient(135deg, #2563EB, #0284C7);
      color: #fff; font-weight: 700; font-size: 15px;
      border: none; border-radius: 14px; padding: 13px;
      cursor: pointer;
    }
    button.sec {
      background: #272B3A; border: 1px solid #3F465E;
    }
  </style>
</head>
<body>
  <div class="card">
    $bannerHtml
    <h2>📱 电视端扫码快捷输入助手</h2>
    <p class="sub">在下方输入或粘贴文字、网址、密码、Cookie、搜索词，点击发送即可实时填入电视当前输入框：</p>
    <div class="tag">当前目标输入框：$safeLabel</div>
    <form method="POST" action="/input">
      <textarea name="text" rows="4" placeholder="在此输入或粘贴要发送到电视的内容..." autofocus>$safeVal</textarea>
      <div class="btn-row">
        <button type="submit" name="action" value="submit">🚀 填入并确认提交</button>
        <button type="submit" name="action" value="fill" class="sec">✏️ 仅填入文本框</button>
      </div>
    </form>
  </div>
</body>
</html>
''';
  }
}
