import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

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

  /// Launches the stream in popular Apple TV / Android TV players (Infuse, VLC, IINA, MX Player).
  static Future<bool> openInTvExternalPlayer(
    String streamUrl, {
    required String playerType,
  }) async {
    final clean = streamUrl.trim();
    if (clean.isEmpty) return false;
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
