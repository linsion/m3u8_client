import 'dart:convert';
import 'dart:io';

/// Protects desktop (especially Windows) client configuration from ever being lost
/// across version updates, EXE renames, or non-atomic `shared_preferences.json` writes.
///
/// On Windows, `path_provider_windows` resolves `getApplicationSupportPath()` from
/// the executable's `VERSIONINFO` (`CompanyName\ProductName`) or falls back to the
/// executable filename (`m3u8_client`), which can switch between:
/// - `%APPDATA%\com.linsion\m3u8_client\shared_preferences.json`
/// - `%APPDATA%\com.linsion\LiuguangVideo\shared_preferences.json`
/// - `%APPDATA%\m3u8_client\shared_preferences.json`
/// Additionally, `shared_preferences_windows` uses non-atomic `writeAsStringSync`,
/// which can truncate `shared_preferences.json` if the process is terminated during an update.
class DesktopConfigBackupService {
  DesktopConfigBackupService._();

  static const List<String> _criticalStringKeys = <String>[
    'flutter.m3u8_server_config_v1',
    'flutter.m3u8_115_direct_cookie_v1',
    'flutter.m3u8_115_direct_user_v1',
    'flutter.m3u8_storage_mounts_v1',
    'flutter.m3u8_saved_music_folders_v1',
    'flutter.m3u8_saved_music_playlists_v1',
    'flutter.m3u8_proxy_subscriptions_v2',
    'flutter.m3u8_proxy_nodes_v2',
    'flutter.m3u8_proxy_scenario_rules_v2',
    'flutter.m3u8_ai_api_key_v1',
    'flutter.m3u8_ai_provider_v1',
    'flutter.m3u8_ai_base_url_v1',
    'flutter.m3u8_ai_model_v1',
    'flutter.m3u8_custom_live_sources_v1',
    'flutter.m3u8_selected_vod_source_id_v1',
    'flutter.m3u8_selected_live_source_key_v1',
    'flutter.m3u8_theme_id_v1',
  ];

  /// Candidate `shared_preferences.json` paths that `path_provider_windows` may use.
  static List<File> _candidateActivePrefFiles() {
    if (!Platform.isWindows) return const <File>[];
    final env = Platform.environment;
    final appData = (env['APPDATA'] ?? '').trim();
    if (appData.isEmpty) return const <File>[];

    final exeName = File(Platform.resolvedExecutable)
        .uri
        .pathSegments
        .lastWhere((s) => s.isNotEmpty, orElse: () => 'm3u8_client.exe')
        .replaceAll(RegExp(r'\.exe$', caseSensitive: false), '');

    final dirs = <String>{
      '$appData\\com.linsion\\m3u8_client',
      '$appData\\com.linsion\\LiuguangVideo',
      '$appData\\com.linsion\\$exeName',
      '$appData\\m3u8_client',
      '$appData\\LiuguangVideo',
      '$appData\\$exeName',
    };
    return dirs
        .map((d) => File('$d\\shared_preferences.json'))
        .toList(growable: false);
  }

  /// Dedicated atomic backup files in `%LOCALAPPDATA%`, `%USERPROFILE%`, and next to the executable.
  static List<File> _dedicatedBackupFiles() {
    if (!Platform.isWindows) return const <File>[];
    final env = Platform.environment;
    final result = <File>[];
    final localAppData = (env['LOCALAPPDATA'] ?? '').trim();
    final userProfile = (env['USERPROFILE'] ?? '').trim();
    if (localAppData.isNotEmpty) {
      result.add(
        File(
          '$localAppData\\com.linsion\\m3u8_client\\shared_preferences_backup.json',
        ),
      );
    }
    if (userProfile.isNotEmpty) {
      result.add(
        File('$userProfile\\.liuguang_video\\shared_preferences_backup.json'),
      );
    }
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      if (exeDir.isNotEmpty) {
        result.add(File('$exeDir\\data\\shared_preferences_backup.json'));
      }
    } catch (_) {}
    return result;
  }

  static Map<String, dynamic>? _tryReadJsonMap(File file) {
    try {
      if (!file.existsSync()) return null;
      final content = file.readAsStringSync().trim();
      if (content.isEmpty) return null;
      final decoded = jsonDecode(content);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return null;
  }

  static bool _hasValidServerSecret(Map<String, dynamic> map) {
    final raw = map['flutter.m3u8_server_config_v1'];
    if (raw is! String || raw.trim().isEmpty) return false;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final secret = (decoded['secret'] ?? '').toString().trim();
        final baseUrl = (decoded['baseUrl'] ?? '').toString().trim();
        final authMode = (decoded['authMode'] ?? '').toString().trim();
        return secret.isNotEmpty ||
            (baseUrl.isNotEmpty && authMode == 'none');
      }
    } catch (_) {}
    return false;
  }

  static bool _hasNonEmptyKey(Map<String, dynamic> map, String key) {
    final v = map[key];
    if (v == null) return false;
    if (v is String) {
      final t = v.trim();
      return t.isNotEmpty && t != '[]' && t != '{}';
    }
    if (v is List) return v.isNotEmpty;
    if (v is Map) return v.isNotEmpty;
    return true;
  }

  /// Scores how complete a preferences map is so a richer backup is preferred
  /// over an empty or freshly-reset preferences file.
  static int _scoreConfigMap(Map<String, dynamic> map) {
    if (map.isEmpty) return 0;
    int score = map.length;
    if (_hasValidServerSecret(map)) {
      score += 5000;
    } else if (_hasNonEmptyKey(map, 'flutter.m3u8_server_config_v1')) {
      score += 1000;
    }
    if (_hasNonEmptyKey(map, 'flutter.m3u8_115_direct_cookie_v1')) {
      score += 1500;
    }
    if (_hasNonEmptyKey(map, 'flutter.m3u8_storage_mounts_v1')) {
      score += 800;
    }
    if (_hasNonEmptyKey(map, 'flutter.m3u8_saved_music_playlists_v1') ||
        _hasNonEmptyKey(map, 'flutter.m3u8_saved_music_folders_v1')) {
      score += 600;
    }
    if (_hasNonEmptyKey(map, 'flutter.m3u8_ai_api_key_v1')) {
      score += 500;
    }
    if (_hasNonEmptyKey(map, 'flutter.m3u8_custom_live_sources_v1')) {
      score += 400;
    }
    final subs = map['flutter.m3u8_proxy_subscriptions_v2'];
    if (subs is String &&
        subs.isNotEmpty &&
        !subs.contains('sub_liangxin_default')) {
      score += 400;
    } else if (subs is String && subs.length > 260) {
      score += 300;
    }
    return score;
  }

  static void _atomicWriteJson(File target, String encodedJson) {
    try {
      final parent = target.parent;
      if (!parent.existsSync()) {
        parent.createSync(recursive: true);
      }
      final tmp = File('${target.path}.tmp');
      tmp.writeAsStringSync(encodedJson, flush: true);
      if (target.existsSync()) {
        try {
          target.deleteSync();
        } catch (_) {}
      }
      tmp.renameSync(target.path);
    } catch (_) {
      try {
        target.writeAsStringSync(encodedJson, flush: true);
      } catch (_) {}
    }
  }

  /// Must be called in `main()` BEFORE `SharedPreferences.getInstance()` is invoked.
  /// Restores and merges any configuration from `%APPDATA%\com.linsion\m3u8_client`,
  /// `%APPDATA%\com.linsion\LiuguangVideo`, and backup files so updates never lose settings.
  static Future<void> ensureRestoredBeforeInit() async {
    if (!Platform.isWindows) return;
    try {
      final activeFiles = _candidateActivePrefFiles();
      final backupFiles = _dedicatedBackupFiles();
      final allFiles = <File>[...activeFiles, ...backupFiles];

      final validMaps = <({File file, Map<String, dynamic> map, int score, DateTime mtime})>[];
      for (final f in allFiles) {
        final map = _tryReadJsonMap(f);
        if (map != null && map.isNotEmpty) {
          DateTime mtime = DateTime.fromMillisecondsSinceEpoch(0);
          try {
            mtime = f.lastModifiedSync();
          } catch (_) {}
          validMaps.add((
            file: f,
            map: map,
            score: _scoreConfigMap(map),
            mtime: mtime,
          ));
        }
      }

      if (validMaps.isEmpty) return;

      // Sort by highest completeness score first, then by most recent modification time.
      validMaps.sort((a, b) {
        final hasAuthA = _hasValidServerSecret(a.map);
        final hasAuthB = _hasValidServerSecret(b.map);
        if (hasAuthA != hasAuthB) {
          return hasAuthB ? 1 : -1;
        }
        if ((a.score - b.score).abs() >= 400) {
          return b.score.compareTo(a.score);
        }
        final timeCmp = b.mtime.compareTo(a.mtime);
        if (timeCmp != 0) return timeCmp;
        return b.score.compareTo(a.score);
      });

      // Start from the lowest-priority maps and overlay higher-priority maps,
      // while ensuring a non-empty critical key (like server password or 115 cookie)
      // is never overwritten by an empty one.
      final merged = <String, dynamic>{};
      for (final entry in validMaps.reversed) {
        entry.map.forEach((key, value) {
          if (value == null) return;
          if (key == 'flutter.m3u8_server_config_v1') {
            if (_hasValidServerSecret(merged) &&
                !_hasValidServerSecret(entry.map)) {
              return;
            }
          } else if (_criticalStringKeys.contains(key)) {
            if (_hasNonEmptyKey(merged, key) &&
                !_hasNonEmptyKey(entry.map, key)) {
              return;
            }
          }
          merged[key] = value;
        });
      }

      if (merged.isEmpty) return;
      final encoded = jsonEncode(merged);

      // Write the merged configuration to all active candidate paths so whichever
      // subdirectory `path_provider_windows` selects (`m3u8_client` or `LiuguangVideo`),
      // it immediately loads the complete configuration.
      for (final f in activeFiles) {
        _atomicWriteJson(f, encoded);
      }
      if (_scoreConfigMap(merged) >= 1000) {
        for (final b in backupFiles) {
          _atomicWriteJson(b, encoded);
        }
      }
    } catch (_) {}
  }

  /// Syncs the current active `shared_preferences.json` across both
  /// `%APPDATA%\com.linsion\m3u8_client` and `%APPDATA%\com.linsion\LiuguangVideo`
  /// as well as dedicated backup locations.
  static Future<void> syncBackupNow() async {
    if (!Platform.isWindows) return;
    try {
      final activeFiles = _candidateActivePrefFiles();
      Map<String, dynamic>? latestMap;
      DateTime latestTime = DateTime.fromMillisecondsSinceEpoch(0);

      for (final f in activeFiles) {
        final map = _tryReadJsonMap(f);
        if (map != null && map.isNotEmpty) {
          DateTime mtime = DateTime.fromMillisecondsSinceEpoch(0);
          try {
            mtime = f.lastModifiedSync();
          } catch (_) {}
          if (latestMap == null || mtime.isAfter(latestTime)) {
            latestMap = map;
            latestTime = mtime;
          }
        }
      }

      if (latestMap == null || latestMap.isEmpty) return;

      // Merge with existing backups so we never lose critical keys if one file was partial
      final backupFiles = _dedicatedBackupFiles();
      for (final b in [...activeFiles, ...backupFiles]) {
        final existing = _tryReadJsonMap(b);
        if (existing != null) {
          for (final key in _criticalStringKeys) {
            if (!_hasNonEmptyKey(latestMap, key) &&
                _hasNonEmptyKey(existing, key)) {
              latestMap[key] = existing[key];
            }
          }
          if (!_hasValidServerSecret(latestMap) &&
              _hasValidServerSecret(existing)) {
            latestMap['flutter.m3u8_server_config_v1'] =
                existing['flutter.m3u8_server_config_v1'];
          }
        }
      }

      final encoded = jsonEncode(latestMap);
      for (final f in activeFiles) {
        _atomicWriteJson(f, encoded);
      }
      if (_scoreConfigMap(latestMap) >= 1000) {
        for (final b in backupFiles) {
          _atomicWriteJson(b, encoded);
        }
      }
    } catch (_) {}
  }
}
