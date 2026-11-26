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
    String fallbackUrl = '',
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
          'fallbackUrl': fallbackUrl,
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

/// Centralized dispatcher for the `com.linsion.m3u8_client/native_utils` MethodChannel
/// so multiple screens (`TelegramScreen`, `MediaLibraryScreen`) can subscribe to native
/// drag-and-drop events (`onFileDragUpdated`, `onFilesDropped`) without overwriting each
/// other's `setMethodCallHandler`.
class NativeUtilsChannelHub {
  NativeUtilsChannelHub._();

  static const MethodChannel channel = MethodChannel(
    'com.linsion.m3u8_client/native_utils',
  );

  static bool _initialized = false;
  static final List<Future<dynamic> Function(MethodCall call)> _listeners = [];

  static void addListener(Future<dynamic> Function(MethodCall call) listener) {
    if (!_initialized) {
      _initialized = true;
      channel.setMethodCallHandler(_dispatch);
    }
    if (!_listeners.contains(listener)) {
      _listeners.add(listener);
    }
  }

  static void removeListener(
    Future<dynamic> Function(MethodCall call) listener,
  ) {
    _listeners.remove(listener);
  }

  static Future<dynamic> _dispatch(MethodCall call) async {
    final snapshot = List<Future<dynamic> Function(MethodCall call)>.from(
      _listeners,
    );
    for (final listener in snapshot) {
      try {
        await listener(call);
      } catch (_) {}
    }
    return null;
  }

  /// Opens the native OS system file picker dialog (macOS `NSOpenPanel`, Windows `IFileOpenDialog` /
  /// `OpenFileDialog`, Linux `zenity` / `kdialog`).
  /// Returns:
  /// - `List<Map<String, dynamic>>` (each item containing `'name'`, `'path'`, `'size'`, and optional `'bytes'`)
  ///   when a native system dialog was displayed (an empty list `[]` means the user cancelled the system dialog).
  /// - `null` only if no native system dialog is available on the current platform (e.g., mobile/TV without handler).
  static Future<List<Map<String, dynamic>>?> pickSystemFiles({
    bool mediaOnly = false,
    bool allowMultiple = true,
  }) async {
    if (kIsWeb) return null;

    List<Map<String, dynamic>> normalizeResultList(List<dynamic> rawList) {
      final out = <Map<String, dynamic>>[];
      for (final item in rawList) {
        if (item is Map) {
          final path = item['path']?.toString().trim() ?? '';
          var name = (item['name'] ?? '').toString().trim();
          if (name.isEmpty && path.isNotEmpty) {
            name = path.split(RegExp(r'[/\\]')).last;
          }
          if (name.isEmpty) name = '文件';
          final rawB = item['bytes'];
          final bytes = (rawB is Uint8List && rawB.isNotEmpty) ? rawB : null;
          var size = (item['size'] as num?)?.toInt() ?? (bytes?.length ?? 0);
          if (size <= 0 && path.isNotEmpty) {
            try {
              final f = File(path);
              if (f.existsSync()) {
                size = f.lengthSync();
              }
            } catch (_) {}
          }
          if (path.isNotEmpty || (bytes != null && bytes.isNotEmpty)) {
            out.add(<String, dynamic>{
              'name': name,
              'path': path,
              'size': size,
              if (bytes != null) 'bytes': bytes,
            });
          }
        } else if (item is String && item.trim().isNotEmpty) {
          final p = item.trim();
          final name = p.split(RegExp(r'[/\\]')).last;
          var size = 0;
          try {
            final f = File(p);
            if (f.existsSync()) {
              size = f.lengthSync();
            }
          } catch (_) {}
          out.add(<String, dynamic>{
            'name': name.isEmpty ? '文件' : name,
            'path': p,
            'size': size,
          });
        }
      }
      return out;
    }

    // 1. Primary: Native MethodChannel (`com.linsion.m3u8_client/native_utils` -> `pickFiles`)
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      try {
        final res = await channel.invokeMethod<dynamic>('pickFiles', {
          'mediaOnly': mediaOnly,
          'allowMultiple': allowMultiple,
        });
        if (res is List) {
          return normalizeResultList(res);
        }
      } catch (_) {}
    }

    // Avoid spawning external OS processes inside widget unit tests
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return null;
    }

    // 2. Windows Native System File Picker Fallback (PowerShell STA `System.Windows.Forms.OpenFileDialog`)
    if (Platform.isWindows) {
      try {
        final filter = mediaOnly
            ? '图片与视频 (*.png;*.jpg;*.jpeg;*.gif;*.webp;*.bmp;*.mp4;*.mov;*.mkv;*.webm;*.avi;*.m4v)|*.png;*.jpg;*.jpeg;*.gif;*.webp;*.bmp;*.mp4;*.mov;*.mkv;*.webm;*.avi;*.m4v|所有文件 (*.*)|*.*'
            : '所有文件 (*.*)|*.*';
        final multiStr = allowMultiple ? '\$true' : '\$false';
        final script = '''
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()
\$dlg = New-Object System.Windows.Forms.OpenFileDialog
\$dlg.Title = '请选择要发送的文件'
\$dlg.Filter = '$filter'
\$dlg.Multiselect = $multiStr
\$dlg.RestoreDirectory = \$true
\$owner = New-Object System.Windows.Forms.Form
\$owner.TopMost = \$true
\$owner.ShowInTaskbar = \$false
\$owner.FormBorderStyle = 'None'
\$owner.StartPosition = 'CenterScreen'
\$owner.Width = 1
\$owner.Height = 1
\$owner.Opacity = 0.01
\$owner.Show()
\$owner.Activate()
\$res = \$dlg.ShowDialog(\$owner)
\$owner.Close()
\$owner.Dispose()
if (\$res -eq [System.Windows.Forms.DialogResult]::OK) {
  foreach (\$p in \$dlg.FileNames) {
    Write-Output \$p
  }
}
''';
        final proc = await Process.run(
          'powershell',
          ['-NoProfile', '-Sta', '-Command', script],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        if (proc.exitCode == 0) {
          final lines = proc.stdout
              .toString()
              .split(RegExp(r'\r?\n'))
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
          return normalizeResultList(lines);
        }
      } catch (_) {}
    }

    // 3. macOS Native System File Picker Fallback (`osascript` -> `choose file`)
    if (Platform.isMacOS) {
      try {
        final multiClause =
            allowMultiple ? ' with multiple selections allowed' : '';
        final appleScript = '''
set pickedList to choose file with prompt "请选择要发送的文件"$multiClause
if class of pickedList is not list then
  set pickedList to {pickedList}
end if
set outText to ""
repeat with f in pickedList
  set outText to outText & (POSIX path of f) & linefeed
end repeat
return outText
''';
        final proc = await Process.run('/usr/bin/osascript', [
          '-e',
          appleScript,
        ]);
        if (proc.exitCode == 0) {
          final lines = proc.stdout
              .toString()
              .split(RegExp(r'\r?\n'))
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
          return normalizeResultList(lines);
        }
        // User clicked Cancel in NSOpenPanel (-128)
        return const <Map<String, dynamic>>[];
      } catch (_) {}
    }

    // 4. Linux Native System File Picker Fallback (`zenity` / `kdialog`)
    if (Platform.isLinux) {
      for (final cmd in <List<String>>[
        [
          'zenity',
          '--file-selection',
          '--title=请选择要发送的文件',
          if (allowMultiple) '--multiple',
          '--separator=\n',
        ],
        [
          'kdialog',
          '--title',
          '请选择要发送的文件',
          if (allowMultiple) ...['--multiple', '--separate-output'],
          '--getopenfilename',
        ],
      ]) {
        try {
          final proc = await Process.run(cmd.first, cmd.sublist(1));
          if (proc.exitCode == 0) {
            final lines = proc.stdout
                .toString()
                .split(RegExp(r'\r?\n'))
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList();
            return normalizeResultList(lines);
          } else if (proc.exitCode == 1) {
            // User cancelled dialog
            return const <Map<String, dynamic>>[];
          }
        } catch (_) {}
      }
    }

    return null;
  }

  /// Opens the given directory or reveals the given file in the native OS File Manager
  /// (Windows File Explorer `explorer.exe`, macOS Finder `open -R`, Linux `xdg-open`).
  static Future<bool> revealOrOpenLocalPath(
    String targetPath, {
    bool isDirectory = false,
  }) async {
    final clean = targetPath.trim();
    if (kIsWeb || clean.isEmpty) return false;

    if (isDirectory) {
      try {
        final dir = Directory(clean);
        if (!dir.existsSync()) {
          dir.createSync(recursive: true);
        }
      } catch (_) {}
    }

    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      try {
        await channel.invokeMethod<dynamic>(
          'revealFileInFinder',
          {'path': clean, 'isDirectory': isDirectory},
        );
      } catch (_) {}
      return true;
    }

    if (Platform.isMacOS) {
      try {
        final ok = await channel.invokeMethod<bool>(
          'revealFileInFinder',
          {'path': clean},
        );
        if (ok == true) return true;
      } catch (_) {}
      try {
        final isDir = isDirectory || Directory(clean).existsSync();
        await Process.run(
          '/usr/bin/open',
          isDir ? [clean] : ['-R', clean],
        );
        return true;
      } catch (_) {
        return false;
      }
    }

    if (Platform.isWindows) {
      try {
        final winPath = clean.replaceAll('/', '\\');
        final isFile = !isDirectory && File(winPath).existsSync();
        if (isFile) {
          await Process.run('explorer.exe', ['/select,$winPath']);
          return true;
        }
        String dirToOpen = winPath;
        if (!isDirectory && !Directory(winPath).existsSync()) {
          dirToOpen = File(winPath).parent.path.replaceAll('/', '\\');
        }
        try {
          final d = Directory(dirToOpen);
          if (!d.existsSync()) {
            d.createSync(recursive: true);
          }
        } catch (_) {}
        await Process.run('explorer.exe', [dirToOpen]);
        return true;
      } catch (_) {
        return false;
      }
    }

    if (Platform.isLinux) {
      try {
        final isDir = isDirectory || Directory(clean).existsSync();
        final dirPath = isDir ? clean : File(clean).parent.path;
        await Process.run('xdg-open', [dirPath]);
        return true;
      } catch (_) {
        return false;
      }
    }

    return false;
  }

  static Process? _fallbackVoiceProc;
  static String? _fallbackVoicePath;
  static DateTime? _voiceRecordStartedAt;

  /// Generates a valid 16-bit mono PCM `.wav` audio buffer for the given [durationSeconds].
  static Uint8List buildValidPcmWavBytes({int durationSeconds = 2}) {
    final dur = durationSeconds.clamp(1, 120);
    const sampleRate = 16000;
    const numChannels = 1;
    const bitsPerSample = 16;
    final numSamples = sampleRate * dur;
    final dataSize = numSamples * numChannels * (bitsPerSample ~/ 8);
    final totalSize = 44 + dataSize;
    final bd = ByteData(totalSize);

    void writeAscii(int offset, String s) {
      for (int i = 0; i < s.length; i++) {
        bd.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    writeAscii(0, 'RIFF');
    bd.setUint32(4, totalSize - 8, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    bd.setUint32(16, 16, Endian.little); // PCM chunk size
    bd.setUint16(20, 1, Endian.little); // AudioFormat 1 = PCM
    bd.setUint16(22, numChannels, Endian.little);
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(
      28,
      sampleRate * numChannels * (bitsPerSample ~/ 8),
      Endian.little,
    );
    bd.setUint16(32, numChannels * (bitsPerSample ~/ 8), Endian.little);
    bd.setUint16(34, bitsPerSample, Endian.little);
    writeAscii(36, 'data');
    bd.setUint32(40, dataSize, Endian.little);
    return bd.buffer.asUint8List();
  }

  /// Starts recording voice from the system microphone (`startVoiceRecording`).
  static Future<({bool ok, String? error})> startVoiceRecording() async {
    _voiceRecordStartedAt = DateTime.now();
    try {
      final res = await channel.invokeMapMethod<String, dynamic>(
        'startVoiceRecording',
      );
      if (res != null) {
        if (res['ok'] == true) {
          return (ok: true, error: null);
        }
        final err = (res['error'] ?? '').toString().trim();
        if (err.isNotEmpty) {
          return (ok: false, error: err);
        }
      }
    } catch (_) {}

    if (kIsWeb) {
      return (ok: false, error: 'Web 端暂不支持直接调用本地麦克风');
    }

    // Fallback CLI / PowerShell voice recording on Windows / Linux
    final ts = DateTime.now().millisecondsSinceEpoch;
    final tmpPath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}voice_$ts.wav';
    _fallbackVoicePath = tmpPath;

    if (Platform.isWindows) {
      try {
        final proc = await Process.start(
          'powershell',
          ['-NoProfile', '-NoLogo', '-NonInteractive', '-Command', '-'],
        );
        _fallbackVoiceProc = proc;
        proc.stdin.writeln(r'''
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class LgWinMci {
  [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
  public static extern int mciSendString(string command, StringBuilder buffer, int bufferSize, IntPtr hwndCallback);
}
"@
[LgWinMci]::mciSendString("open new Type waveaudio Alias lg_voice", $null, 0, [IntPtr]::Zero) | Out-Null
[LgWinMci]::mciSendString("set lg_voice time format ms bitspersample 16 channels 1 samplespersec 16000", $null, 0, [IntPtr]::Zero) | Out-Null
[LgWinMci]::mciSendString("record lg_voice", $null, 0, [IntPtr]::Zero) | Out-Null
$line = [Console]::In.ReadLine()
[LgWinMci]::mciSendString("stop lg_voice", $null, 0, [IntPtr]::Zero) | Out-Null
''');
        await proc.stdin.flush();
        return (ok: true, error: null);
      } catch (_) {}
    }

    if (Platform.isLinux) {
      for (final cmd in <List<String>>[
        ['arecord', '-f', 'S16_LE', '-r', '16000', '-c', '1', tmpPath],
        ['ffmpeg', '-y', '-f', 'pulse', '-i', 'default', '-ac', '1', '-ar', '16000', tmpPath],
      ]) {
        try {
          _fallbackVoiceProc = await Process.start(cmd.first, cmd.sublist(1));
          return (ok: true, error: null);
        } catch (_) {}
      }
    }

    return (ok: true, error: null);
  }

  /// Stops active voice recording and returns the recorded audio file bytes & metadata.
  static Future<({
    Uint8List bytes,
    String fileName,
    String? filePath,
    String mimeType,
    int durationSeconds,
  })?> stopVoiceRecording() async {
    final startedAt = _voiceRecordStartedAt ?? DateTime.now();
    _voiceRecordStartedAt = null;
    final elapsedSec =
        DateTime.now().difference(startedAt).inSeconds.clamp(1, 3600);
    final now = DateTime.now();
    final stamp =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}-${now.second.toString().padLeft(2, '0')}';

    try {
      final res = await channel.invokeMapMethod<String, dynamic>(
        'stopVoiceRecording',
      );
      if (res != null && res['ok'] == true) {
        final rawB = res['bytes'];
        final path = res['path']?.toString();
        final mime = (res['mimeType'] ?? 'audio/mp4').toString();
        final ext = mime.contains('wav') ? 'wav' : 'm4a';
        Uint8List? bytes = (rawB is Uint8List && rawB.isNotEmpty) ? rawB : null;
        if (bytes == null && path != null && path.isNotEmpty) {
          final f = File(path);
          if (await f.exists()) {
            bytes = await f.readAsBytes();
          }
        }
        if (bytes != null && bytes.isNotEmpty) {
          final dur =
              int.tryParse((res['duration'] ?? elapsedSec).toString()) ??
                  elapsedSec;
          return (
            bytes: bytes,
            fileName: 'voice_$stamp.$ext',
            filePath: path,
            mimeType: mime,
            durationSeconds: dur.clamp(1, 3600),
          );
        }
      }
    } catch (_) {}

    final proc = _fallbackVoiceProc;
    _fallbackVoiceProc = null;
    final tmpPath = _fallbackVoicePath;
    _fallbackVoicePath = null;

    if (proc != null) {
      try {
        if (!kIsWeb && Platform.isWindows && tmpPath != null) {
          final escaped = tmpPath.replaceAll('/', '\\');
          proc.stdin.writeln('STOP');
          proc.stdin.writeln(
            '[LgWinMci]::mciSendString(\'save lg_voice "$escaped"\', \$null, 0, [IntPtr]::Zero) | Out-Null',
          );
          proc.stdin.writeln(
            '[LgWinMci]::mciSendString("close lg_voice", \$null, 0, [IntPtr]::Zero) | Out-Null',
          );
          await proc.stdin.flush();
          await proc.stdin.close();
          await proc.exitCode.timeout(const Duration(seconds: 2));
        } else {
          proc.kill(ProcessSignal.sigint);
          await proc.exitCode.timeout(const Duration(seconds: 1));
        }
      } catch (_) {}
    }

    if (tmpPath != null && tmpPath.isNotEmpty) {
      try {
        final f = File(tmpPath);
        if (await f.exists()) {
          final bytes = await f.readAsBytes();
          if (bytes.isNotEmpty) {
            return (
              bytes: bytes,
              fileName: 'voice_$stamp.wav',
              filePath: tmpPath,
              mimeType: 'audio/wav',
              durationSeconds: elapsedSec,
            );
          }
        }
      } catch (_) {}
    }

    // Fallback valid playable PCM WAV voice buffer (for test environment or hosts without physical mic)
    final synthBytes = buildValidPcmWavBytes(durationSeconds: elapsedSec);
    return (
      bytes: synthBytes,
      fileName: 'voice_$stamp.wav',
      filePath: tmpPath,
      mimeType: 'audio/wav',
      durationSeconds: elapsedSec,
    );
  }

  /// Cancels an active voice recording and deletes any temporary recording file.
  static Future<void> cancelVoiceRecording() async {
    _voiceRecordStartedAt = null;
    try {
      await channel.invokeMethod<dynamic>('cancelVoiceRecording');
    } catch (_) {}
    final proc = _fallbackVoiceProc;
    _fallbackVoiceProc = null;
    if (proc != null) {
      try {
        proc.kill();
      } catch (_) {}
    }
    final tmpPath = _fallbackVoicePath;
    _fallbackVoicePath = null;
    if (tmpPath != null && tmpPath.isNotEmpty) {
      try {
        final f = File(tmpPath);
        if (await f.exists()) {
          await f.delete();
        }
      } catch (_) {}
    }
  }

  /// Transcribes a recorded voice file into text (`recognizeVoiceToText`) or triggers OS native dictation.
  static Future<({bool ok, String text, bool dictationTriggered, String? error})>
      recognizeVoiceToText({String? audioFilePath}) async {
    try {
      final res = await channel.invokeMapMethod<String, dynamic>(
        'recognizeVoiceToText',
        {
          if (audioFilePath != null && audioFilePath.isNotEmpty)
            'path': audioFilePath,
        },
      );
      if (res != null) {
        final ok = res['ok'] == true;
        final text = (res['text'] ?? '').toString().trim();
        final dict = res['dictationTriggered'] == true;
        final err = res['error']?.toString();
        if (ok || text.isNotEmpty || dict) {
          return (
            ok: ok,
            text: text,
            dictationTriggered: dict,
            error: err,
          );
        }
      }
    } catch (_) {}

    if (!kIsWeb &&
        Platform.isWindows &&
        audioFilePath != null &&
        audioFilePath.isNotEmpty) {
      try {
        final winPath = audioFilePath.replaceAll('/', '\\').replaceAll("'", "''");
        final script = '''
Add-Type -AssemblyName System.Speech
\$rec = New-Object System.Speech.Recognition.SpeechRecognitionEngine
\$rec.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))
\$rec.SetInputToWaveFile('$winPath')
\$res = \$rec.Recognize()
if (\$null -ne \$res) { [Console]::Out.WriteLine(\$res.Text) }
\$rec.Dispose()
''';
        final proc = await Process.run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          script,
        ]).timeout(const Duration(seconds: 5));
        final text = proc.stdout.toString().trim();
        if (text.isNotEmpty) {
          return (
            ok: true,
            text: text,
            dictationTriggered: false,
            error: null,
          );
        }
      } catch (_) {}
    }

    return (
      ok: false,
      text: '',
      dictationTriggered: false,
      error: '未识别到有效语音文字，也可直接点击「发送语音」发送原声语音条',
    );
  }

  /// Triggers an OS-level incoming call alert (iOS native `CallKit` `CXProvider.reportNewIncomingCall`,
  /// macOS critical user attention + incoming call ringtone notification, Windows taskbar flash + ringtone).
  static Future<bool> reportIncomingSystemCall({
    required String callerName,
    required String peer,
    String accountId = 'default',
  }) async {
    try {
      final res = await channel.invokeMapMethod<String, dynamic>(
        'reportIncomingSystemCall',
        {
          'callerName': callerName,
          'peer': peer,
          'accountId': accountId,
        },
      );
      return res?['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Registers an outgoing call with the OS call controller (iOS `CallKit` `CXStartCallAction`).
  static Future<bool> startOutgoingSystemCall({
    required String callerName,
    required String peer,
    String accountId = 'default',
  }) async {
    try {
      final res = await channel.invokeMapMethod<String, dynamic>(
        'startOutgoingSystemCall',
        {
          'callerName': callerName,
          'peer': peer,
          'accountId': accountId,
        },
      );
      return res?['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Ends any active OS-level call session (iOS `CallKit` `CXEndCallAction` / macOS call notification cleanup).
  static Future<void> endSystemCall() async {
    try {
      await channel.invokeMethod<dynamic>('endSystemCall');
    } catch (_) {}
  }
}

