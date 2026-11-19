import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/models.dart';
import '../../services/api_client.dart';
import '../../services/local_115_direct_service.dart';
import '../../services/remote_storage_service.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets/cloud_music_player.dart';
import '../widgets/mobile_edge_swipe_back.dart';
import '../widgets/video_115_accelerate_button.dart';
import '../widgets/video_download_speed_badge.dart';

class MediaLibraryScreen extends StatefulWidget {
  final AppState appState;

  const MediaLibraryScreen({
    super.key,
    required this.appState,
  });

  @override
  State<MediaLibraryScreen> createState() => _MediaLibraryScreenState();
}

class _MediaLibraryScreenState extends State<MediaLibraryScreen> {
  static const String _prefBookmarksKey = 'm3u8_media_folder_bookmarks_v2';
  static const String _prefMountsKey = 'm3u8_storage_mounts_v1';
  static const String _prefGridViewKey = 'm3u8_media_grid_view_v1';
  static const MethodChannel _nativeUtilsChannel = MethodChannel(
    'com.linsion.m3u8_client/native_utils',
  );

  // Built-in + Custom AList / OpenList / WebDAV Storage Mounts
  List<StorageMount> _mounts = const [];
  String _activeMountId = 'builtin_server';

  // Active Directory State
  FileDirectoryListing? _listing;
  bool _isLoading = false;
  String? _loadError;
  List<({String cid, String name})> _cloud115Breadcrumbs = [
    (cid: '0', name: '115根目录'),
  ];

  // Filter, Sort, View Mode & Selection State
  String _searchFilter = '';
  String _sortMode = 'time_desc'; // 'time_desc', 'size_desc', 'name_asc', 'type_asc'
  String _categoryFilter = 'all'; // 'all', 'video', 'audio', 'image', 'doc'
  bool _isGridView = false;
  bool _multiSelectMode = false;
  final Set<String> _selectedPaths = {};
  FileClipboardItem? _clipboard;
  List<String> _bookmarkedRecords = []; // Format: "<mountId>::<title>::<path>"
  bool _isDraggingFilesOverManager = false;

  // Real-time Upload & Download Transfer Tasks Queue
  final List<FileTransferTask> _transferTasks = [];

  final TextEditingController _searchController = TextEditingController();
  late final CloudMusicController _musicController = CloudMusicController(
    endpointResolver: _resolveEntryEndpoint,
    appState: widget.appState,
  );

  StorageMount get _activeMount {
    for (final m in _mounts) {
      if (m.id == _activeMountId) return m;
    }
    return _mounts.isNotEmpty
        ? _mounts.first
        : const StorageMount(
            id: 'builtin_server',
            name: '流光服务端',
            kind: StorageSourceKind.server,
            rootPath: '/',
          );
  }

  List<StorageMount> _buildBuiltInMounts() {
    return [
      const StorageMount(
        id: 'builtin_server',
        name: '流光服务端',
        kind: StorageSourceKind.server,
        rootPath: '/',
      ),
      const StorageMount(
        id: 'builtin_115',
        name: '115 网盘直连',
        kind: StorageSourceKind.cloud115,
        rootPath: '0',
      ),
      StorageMount(
        id: 'builtin_local',
        name: '本机离线目录',
        kind: StorageSourceKind.localCache,
        rootPath: RemoteStorageService.defaultLocalDownloadsRoot(),
      ),
    ];
  }

  @override
  void initState() {
    super.initState();
    _mounts = _buildBuiltInMounts();
    _nativeUtilsChannel.setMethodCallHandler(_handleNativeDropMethodCall);
    _initPrefsAndLoad();
  }

  @override
  void dispose() {
    _searchController.dispose();
    if (widget.appState.activeChildBackHandler == _handleBackPress) {
      widget.appState.activeChildBackHandler = null;
    }
    super.dispose();
  }

  Future<void> _initPrefsAndLoad() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedBookmarks = prefs.getStringList(_prefBookmarksKey);
      final savedGrid = prefs.getBool(_prefGridViewKey) ?? false;
      final savedMountsRaw = prefs.getString(_prefMountsKey);
      final customMounts = <StorageMount>[];
      if (savedMountsRaw != null && savedMountsRaw.isNotEmpty) {
        final decoded = jsonDecode(savedMountsRaw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              final m = StorageMount.fromJson(item);
              if (!m.isBuiltIn) customMounts.add(m);
            }
          }
        }
      }
      if (mounted) {
        setState(() {
          _mounts = [..._buildBuiltInMounts(), ...customMounts];
          if (savedBookmarks != null) _bookmarkedRecords = savedBookmarks;
          _isGridView = savedGrid;
        });
      }
    } catch (_) {}
    await Local115DirectService.instance.ensureInitialized();
    await _loadDirectory('');
  }

  Future<void> _persistCustomMounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final custom =
          _mounts.where((m) => !m.isBuiltIn).map((m) => m.toJson()).toList();
      await prefs.setString(_prefMountsKey, jsonEncode(custom));
    } catch (_) {}
  }

  Future<dynamic> _handleNativeDropMethodCall(MethodCall call) async {
    if (!mounted) return null;
    if (call.method == 'onFileDragUpdated') {
      final args = call.arguments;
      final active = args is Map && args['active'] == true;
      if (_isDraggingFilesOverManager != active) {
        setState(() => _isDraggingFilesOverManager = active);
      }
      return null;
    }
    if (call.method == 'onFilesDropped') {
      if (_isDraggingFilesOverManager) {
        setState(() => _isDraggingFilesOverManager = false);
      }
      final rawList = call.arguments;
      if (rawList is List) {
        for (final item in rawList) {
          if (item is Map) {
            final name = (item['name'] ?? '上传文件').toString();
            final path = item['path']?.toString();
            final bytes = item['bytes'] is Uint8List
                ? item['bytes'] as Uint8List
                : null;
            if ((path != null && path.isNotEmpty) ||
                (bytes != null && bytes.isNotEmpty)) {
              unawaited(
                _startUploadFileWithProgress(
                  fileName: name,
                  localFilePath: path,
                  rawBytes: bytes,
                  sourceLabel: '桌面拖拽上传',
                ),
              );
            }
          }
        }
      }
      return null;
    }
    return null;
  }

  bool _handleBackPress() {
    if (!mounted) return false;
    if (_multiSelectMode) {
      setState(() {
        _multiSelectMode = false;
        _selectedPaths.clear();
      });
      return true;
    }
    if (_searchFilter.isNotEmpty) {
      setState(() {
        _searchFilter = '';
        _searchController.clear();
      });
      return true;
    }
    if (_categoryFilter != 'all') {
      setState(() => _categoryFilter = 'all');
      return true;
    }
    if (_canNavigateUp) {
      _navigateUp();
      return true;
    }
    return false;
  }

  bool get _canNavigateUp {
    final mount = _activeMount;
    final curPath = _listing?.path ?? '';
    if (mount.kind == StorageSourceKind.cloud115) {
      return curPath.isNotEmpty && curPath != '0';
    }
    if (mount.kind == StorageSourceKind.localCache) {
      if (curPath.isEmpty) return false;
      final dir = Directory(curPath);
      return dir.parent.path != dir.path;
    }
    final root = _listing?.root ?? '/';
    return curPath.isNotEmpty && curPath != root && curPath != '/';
  }

  void _navigateUp() {
    final mount = _activeMount;
    if (mount.kind == StorageSourceKind.cloud115) {
      if (_cloud115Breadcrumbs.length >= 2) {
        final prev = _cloud115Breadcrumbs[_cloud115Breadcrumbs.length - 2];
        _loadDirectory(prev.cid, folderTitleHint: prev.name);
      } else {
        _loadDirectory('0', folderTitleHint: '115根目录');
      }
      return;
    }
    if (mount.kind == StorageSourceKind.localCache) {
      final cur = _listing?.path ?? mount.rootPath;
      final parent = Directory(cur).parent.path;
      _loadDirectory(parent);
      return;
    }
    _loadDirectory(_listing?.parent ?? '');
  }

  Future<void> _switchMount(String mountId) async {
    final target = _mounts.where((m) => m.id == mountId).firstOrNull;
    if (target == null) return;
    setState(() {
      _activeMountId = target.id;
      _multiSelectMode = false;
      _selectedPaths.clear();
      _searchFilter = '';
      _searchController.clear();
      _loadError = null;
      if (target.kind == StorageSourceKind.cloud115) {
        _cloud115Breadcrumbs = [(cid: '0', name: '115根目录')];
      }
    });
    final initialPath = switch (target.kind) {
      StorageSourceKind.server => '',
      StorageSourceKind.cloud115 => '0',
      _ => target.rootPath,
    };
    await _loadDirectory(initialPath);
  }

  Future<void> _loadDirectory(String path, {String? folderTitleHint}) async {
    if (!mounted) return;
    final mount = _activeMount;
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      FileDirectoryListing result;
      switch (mount.kind) {
        case StorageSourceKind.server:
          result = await widget.appState.api.fetchFiles(path: path);
          break;
        case StorageSourceKind.alist:
          result =
              await RemoteStorageService.instance.listAlistDirectory(mount, path);
          break;
        case StorageSourceKind.webdav:
          result = await RemoteStorageService.instance
              .listWebdavDirectory(mount, path);
          break;
        case StorageSourceKind.cloud115:
          final targetCid = (path.isEmpty || path == '/') ? '0' : path;
          result = await Local115DirectService.instance.list115Directory(
            cid: targetCid,
            mountId: mount.id,
          );
          if (targetCid == '0') {
            _cloud115Breadcrumbs = [(cid: '0', name: '115根目录')];
          } else {
            final idx =
                _cloud115Breadcrumbs.indexWhere((c) => c.cid == targetCid);
            if (idx >= 0) {
              _cloud115Breadcrumbs = _cloud115Breadcrumbs.sublist(0, idx + 1);
            } else {
              _cloud115Breadcrumbs.add((
                cid: targetCid,
                name: folderTitleHint ?? '目录 $targetCid',
              ));
            }
          }
          break;
        case StorageSourceKind.localCache:
          result = await _listLocalFileSystem(
            path.trim().isEmpty ? mount.rootPath : path,
          );
          break;
      }
      if (!mounted) return;
      setState(() {
        _listing = result;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<FileDirectoryListing> _listLocalFileSystem(String rawDirPath) async {
    final targetPath = rawDirPath.trim().isEmpty
        ? RemoteStorageService.defaultLocalDownloadsRoot()
        : rawDirPath;
    final dir = Directory(targetPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final entities = await dir.list(followLinks: false).toList();
    final entries = <FileEntry>[];

    for (final entity in entities) {
      final name = entity.path
          .split(RegExp(r'[/\\]'))
          .where((s) => s.isNotEmpty)
          .lastOrNull ??
          '';
      if (name.isEmpty || name.startsWith('.')) continue;
      try {
        final stat = await entity.stat();
        final isDir = stat.type == FileSystemEntityType.directory;
        String ext = '';
        if (!isDir) {
          final dot = name.lastIndexOf('.');
          if (dot > 0) ext = name.substring(dot).toLowerCase();
        }
        final dt = stat.modified;
        final modTime =
            '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
            '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
        entries.add(
          FileEntry(
            name: name,
            path: entity.path,
            size: isDir ? 0 : stat.size,
            modTime: modTime,
            isDir: isDir,
            isMp4: ext == '.mp4',
            ext: ext,
            mountId: 'builtin_local',
            sourceKind: StorageSourceKind.localCache,
            rawDownloadUrl: Uri.file(entity.path).toString(),
          ),
        );
      } catch (_) {}
    }

    return FileDirectoryListing(
      path: dir.path,
      parent: dir.parent.path == dir.path ? '' : dir.parent.path,
      root: RemoteStorageService.defaultLocalDownloadsRoot(),
      entries: entries,
    );
  }

  // ===========================================================================
  // Direct Click & Media Resolution Across All 5 Storage Sources
  // ===========================================================================

  Future<({String url, Map<String, String> headers, String subtitle})>
      _resolveEntryEndpoint(FileEntry entry) async {
    final mount = _mounts.where((m) => m.id == entry.mountId).firstOrNull ??
        _activeMount;
    switch (entry.sourceKind) {
      case StorageSourceKind.server:
        return (
          url: widget.appState.api.buildFileStreamUrl(entry.path),
          headers: widget.appState.api.authHeaders,
          subtitle: '流光服务端 · ${entry.formattedSize}',
        );
      case StorageSourceKind.alist:
        final url = await RemoteStorageService.instance.resolveAlistDirectUrl(
          mount,
          entry.path,
          fallbackUrl: entry.rawDownloadUrl,
        );
        return (
          url: url,
          headers: const <String, String>{},
          subtitle: '${mount.name} · ${entry.formattedSize}',
        );
      case StorageSourceKind.webdav:
        final url = RemoteStorageService.instance
            .buildWebdavUri(mount, entry.path)
            .toString();
        final headers = RemoteStorageService.instance.webdavAuthHeaders(mount);
        return (
          url: url,
          headers: headers,
          subtitle: '${mount.name} · ${entry.formattedSize}',
        );
      case StorageSourceKind.cloud115:
        if (entry.pickcode115.isEmpty) {
          throw const ApiException('缺少 115 pickcode');
        }
        final directUrl = await Local115DirectService.instance
            .resolvePickcodeStreamUrl(entry.pickcode115);
        if (directUrl == null || directUrl.isEmpty) {
          throw const ApiException('无法解析 115 直链，请确认 115 登录状态');
        }
        final headers = Local115DirectService.instance.requestHeaders;
        return (
          url: directUrl,
          headers: headers,
          subtitle: '115 网盘原画直连 · ${entry.formattedSize}',
        );
      case StorageSourceKind.localCache:
        return (
          url: entry.path,
          headers: const <String, String>{},
          subtitle: '本机离线目录 · ${entry.formattedSize}',
        );
    }
  }

  /// Standard File Manager direct click:
  /// - Folder -> enters folder immediately
  /// - Video / Audio -> plays immediately
  /// - Image -> opens image viewer immediately
  /// - Text / Subtitle / Config / M3U8 -> opens text viewer immediately
  /// - Other files -> opens File Action & Detail Sheet
  Future<void> _handleDirectEntryClick(
    FileEntry entry, {
    bool inMiniPlayer = false,
  }) async {
    if (_multiSelectMode) {
      setState(() {
        if (_selectedPaths.contains(entry.path)) {
          _selectedPaths.remove(entry.path);
        } else {
          _selectedPaths.add(entry.path);
        }
      });
      return;
    }

    if (entry.isDir) {
      await _loadDirectory(entry.path, folderTitleHint: entry.name);
      return;
    }

    if (entry.isStreamableMusicArchive) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => CloudArchiveMusicBrowserDialog(
          archiveEntry: entry,
          controller: _musicController,
          onOpenFullscreenHall: _showCloudMusicFullscreenModal,
        ),
      );
      return;
    }

    if (entry.isAudio) {
      final rawEntries = _listing?.entries ?? const <FileEntry>[];
      final sortedEntries = _getFilteredAndSortedEntries(rawEntries);
      await _musicController.playFromDirectory(
        targetTrack: entry,
        directoryEntries: sortedEntries.isNotEmpty ? sortedEntries : rawEntries,
        mounts: _mounts,
      );
      if (!mounted) return;
      if (inMiniPlayer) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🎵 已在底部音乐栏播放：${entry.name}（可边听边浏览目录）'),
            duration: const Duration(seconds: 2),
          ),
        );
      } else {
        await _showCloudMusicFullscreenModal();
      }
      return;
    }

    if (entry.isPlayableVideo) {
      if (_musicController.isPlaying) {
        unawaited(_musicController.togglePlayPause());
      }
      try {
        final resolved = await _resolveEntryEndpoint(entry);
        String playUrl = resolved.url;
        Map<String, String> playHeaders = resolved.headers;
        if (entry.sourceKind == StorageSourceKind.cloud115 &&
            !playUrl.toLowerCase().contains('.m3u8')) {
          playUrl = await Local115DirectService.instance
              .wrapWithLocal115HeaderProxy(
                playUrl,
                playHeaders,
                extHint: entry.normalizedExt,
              );
          playHeaders = const {};
        }
        if (!mounted) return;
        if (inMiniPlayer) {
          widget.appState.startMiniPlayer(
            MiniPlayerSession(
              title: entry.name,
              subtitle: resolved.subtitle,
              streamUrl: playUrl,
              headers: playHeaders,
            ),
          );
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已开启「${entry.name}」小窗悬浮播放'),
              duration: const Duration(seconds: 2),
            ),
          );
          return;
        }
        await showDialog<void>(
          context: context,
          builder: (_) => _MediaFilePlayerDialog(
            api: widget.appState.api,
            title: entry.name,
            streamUrl: playUrl,
            headers: playHeaders,
            onEnterMiniPlayer: (posSec) {
              widget.appState.startMiniPlayer(
                MiniPlayerSession(
                  title: entry.name,
                  subtitle: resolved.subtitle,
                  streamUrl: playUrl,
                  headers: playHeaders,
                  initialPositionSeconds: posSec,
                ),
              );
            },
          ),
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('播放失败：$e')),
          );
        }
      }
      return;
    }

    if (entry.isImage) {
      try {
        final resolved = await _resolveEntryEndpoint(entry);
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (_) => _MediaImagePreviewDialog(
            title: entry.name,
            imageUrl: resolved.url,
            headers: resolved.headers,
            isLocalFile: entry.sourceKind == StorageSourceKind.localCache,
          ),
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('图片预览失败：$e')),
          );
        }
      }
      return;
    }

    if (entry.isTextPreviewable) {
      await _showTextFilePreview(entry);
      return;
    }

    await _showFileActionSheet(entry);
  }

  Future<void> _showCloudMusicFullscreenModal() async {
    if (!mounted || !_musicController.hasActiveSession) return;
    await showDialog<void>(
      context: context,
      builder: (_) => CloudMusicFullscreenModal(
        controller: _musicController,
      ),
    );
  }

  Future<void> _showTextFilePreview(FileEntry entry) async {
    try {
      String content;
      if (entry.sourceKind == StorageSourceKind.localCache) {
        final f = File(entry.path);
        final bytes = await f.openRead(0, 256 * 1024).fold<List<int>>(
          <int>[],
          (acc, chunk) => acc..addAll(chunk),
        );
        content = utf8.decode(bytes, allowMalformed: true);
      } else {
        final resolved = await _resolveEntryEndpoint(entry);
        final uri = Uri.parse(resolved.url);
        final client = HttpClient()
          ..badCertificateCallback = (_, __, ___) => true;
        try {
          final req = await client.getUrl(uri);
          resolved.headers.forEach(req.headers.set);
          req.headers.set('Range', 'bytes=0-${256 * 1024 - 1}');
          final resp = await req.close();
          final bytes = await resp.fold<List<int>>(
            <int>[],
            (acc, chunk) {
              if (acc.length < 256 * 1024) acc.addAll(chunk);
              return acc;
            },
          );
          content = utf8.decode(bytes, allowMalformed: true);
        } finally {
          client.close(force: true);
        }
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: VideoPlatformTheme.bgElevated,
          title: Row(
            children: [
              const Icon(Icons.description_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: content));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制文件内容到剪贴板')),
                  );
                },
                icon: const Icon(Icons.copy_rounded, size: 14),
                label: const Text('复制'),
              ),
            ],
          ),
          content: SizedBox(
            width: 760,
            height: 480,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: VideoPlatformTheme.bgCard,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: VideoPlatformTheme.borderSubtle),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  content.isEmpty ? '（空文件）' : content,
                  style: TextStyle(
                    fontFamily: Platform.isMacOS ? 'Menlo' : 'Consolas',
                    fontSize: 12.5,
                    height: 1.4,
                    color: VideoPlatformTheme.textPrimary,
                  ),
                ),
              ),
            ),
          ),
          actions: [
            if (entry.sourceKind != StorageSourceKind.localCache)
              TextButton.icon(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _startDownloadFileWithProgress(entry);
                },
                icon: const Icon(Icons.download_rounded, size: 16),
                label: const Text('下载到本机'),
              ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('读取文本预览失败：$e')),
        );
      }
    }
  }

  // ===========================================================================
  // Upload & Download Engine with Real-Time Progress Display
  // ===========================================================================

  int get _runningTransfersCount =>
      _transferTasks.where((t) => t.status == FileTransferStatus.running).length;

  FileTransferTask? get _primaryActiveTransfer {
    for (final t in _transferTasks) {
      if (t.status == FileTransferStatus.running) return t;
    }
    return _transferTasks.isNotEmpty ? _transferTasks.first : null;
  }

  /// Downloads any file from Server / AList / WebDAV / 115 to local `~/Downloads` with real-time progress bar & speed
  Future<void> _startDownloadFileWithProgress(
    FileEntry entry, {
    String? customTargetDir,
  }) async {
    if (entry.isDir) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂不支持直接整目录下载，请进入目录选择文件')),
      );
      return;
    }
    final sourceMount =
        _mounts.where((m) => m.id == entry.mountId).firstOrNull ?? _activeMount;
    final targetDir =
        customTargetDir ?? RemoteStorageService.defaultLocalDownloadsRoot();
    final safeName = entry.name.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
    final outPath = RemoteStorageService.joinLocalPath(targetDir, safeName);

    bool cancelled = false;
    final task = FileTransferTask(
      id: 'dl_${DateTime.now().millisecondsSinceEpoch}_${entry.name.hashCode}',
      name: entry.name,
      direction: FileTransferDirection.download,
      sourceLabel: sourceMount.name,
      targetLabel: '本机 Downloads',
      totalBytes: entry.size > 0 ? entry.size : 0,
      detailMessage: '正在解析下载直链...',
      onCancel: () => cancelled = true,
    );

    setState(() {
      _transferTasks.insert(0, task);
    });

    try {
      String dlUrl;
      Map<String, String> headers;
      if (entry.sourceKind == StorageSourceKind.server) {
        dlUrl = widget.appState.api.buildFileDownloadUrl(entry.path);
        headers = widget.appState.api.authHeaders;
      } else {
        final resolved = await _resolveEntryEndpoint(entry);
        dlUrl = resolved.url;
        headers = resolved.headers;
      }

      await RemoteStorageService.instance.downloadStreamWithProgress(
        uri: Uri.parse(dlUrl),
        headers: headers,
        destinationPath: outPath,
        expectedSizeHint: entry.size,
        isCancelled: () => cancelled,
        onProgress: (received, total, speed) {
          if (!mounted) return;
          setState(() {
            task.transferredBytes = received;
            if (total > 0) task.totalBytes = total;
            task.speedBytesPerSec = speed;
            task.detailMessage = '正在高速下载至本机...';
          });
        },
      );

      if (!mounted) return;
      setState(() {
        task.status = FileTransferStatus.completed;
        if (task.totalBytes <= 0) task.totalBytes = task.transferredBytes;
        task.transferredBytes = task.totalBytes;
        task.detailMessage = '✓ 已保存至 $outPath';
        task.localSavedPath = outPath;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('✅ 下载完成：$outPath')),
      );
      if (_activeMount.kind == StorageSourceKind.localCache) {
        await _loadDirectory(_listing?.path ?? _activeMount.rootPath);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        task.status =
            cancelled ? FileTransferStatus.cancelled : FileTransferStatus.failed;
        task.speedBytesPerSec = 0;
        task.detailMessage = cancelled ? '已取消下载' : '下载失败：$e';
      });
      if (!cancelled) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('⚠️ 下载失败：$e')),
        );
      }
    }
  }

  /// Picks local files via Native File Picker (or cross-platform fallback) and uploads them to the current directory with real-time progress
  Future<void> _pickAndUploadFilesToCurrentMount() async {
    final filesToUpload =
        <({String name, String? path, Uint8List? bytes, int size})>[];

    if (Platform.isMacOS || Platform.isWindows) {
      try {
        final rawList = await _nativeUtilsChannel.invokeMethod<dynamic>(
          'pickFiles',
          {'mediaOnly': false},
        );
        if (rawList is List) {
          for (final item in rawList) {
            if (item is Map) {
              final name = (item['name'] ?? '文件').toString();
              final path = item['path']?.toString();
              final bytes = item['bytes'] is Uint8List
                  ? item['bytes'] as Uint8List
                  : null;
              final size =
                  (item['size'] as num?)?.toInt() ?? (bytes?.length ?? 0);
              if ((path != null && path.isNotEmpty) ||
                  (bytes != null && bytes.isNotEmpty)) {
                filesToUpload.add((
                  name: name,
                  path: path,
                  bytes: bytes,
                  size: size,
                ));
              }
            }
          }
        }
      } catch (_) {}
    }

    if (filesToUpload.isEmpty) {
      if (!mounted) return;
      final selectedPaths = await showDialog<List<String>>(
        context: context,
        builder: (_) => const _LocalFileUploadPickerDialog(),
      );
      if (!mounted || selectedPaths == null || selectedPaths.isEmpty) return;
      for (final p in selectedPaths) {
        final f = File(p);
        if (await f.exists()) {
          final len = await f.length();
          final name = p.split(RegExp(r'[/\\]')).last;
          filesToUpload.add((name: name, path: p, bytes: null, size: len));
        }
      }
    }

    for (final f in filesToUpload) {
      await _startUploadFileWithProgress(
        fileName: f.name,
        localFilePath: f.path,
        rawBytes: f.bytes,
        expectedSize: f.size,
      );
    }
  }

  Future<void> _startUploadFileWithProgress({
    required String fileName,
    String? localFilePath,
    Uint8List? rawBytes,
    int expectedSize = 0,
    StorageMount? overrideTargetMount,
    String? overrideTargetDir,
    String sourceLabel = '本机文件',
  }) async {
    final targetMount = overrideTargetMount ?? _activeMount;
    final targetDir =
        overrideTargetDir ?? (_listing?.path ?? targetMount.rootPath);
    int totalSize = expectedSize > 0 ? expectedSize : (rawBytes?.length ?? 0);
    if (totalSize <= 0 && localFilePath != null && localFilePath.isNotEmpty) {
      try {
        totalSize = await File(localFilePath).length();
      } catch (_) {}
    }

    bool cancelled = false;
    final task = FileTransferTask(
      id: 'up_${DateTime.now().millisecondsSinceEpoch}_${fileName.hashCode}',
      name: fileName,
      direction: FileTransferDirection.upload,
      sourceLabel: sourceLabel,
      targetLabel: '${targetMount.name} (${targetDir.isEmpty ? "/" : targetDir})',
      totalBytes: totalSize,
      detailMessage: '正在准备上传数据流...',
      onCancel: () => cancelled = true,
    );

    setState(() {
      _transferTasks.insert(0, task);
    });

    try {
      await RemoteStorageService.instance.uploadWithProgress(
        targetMount: targetMount,
        targetDir: targetDir,
        fileName: fileName,
        localFilePath: localFilePath,
        rawBytes: rawBytes,
        serverApi: widget.appState.api,
        isCancelled: () => cancelled,
        onProgress: (sent, total, speed) {
          if (!mounted) return;
          setState(() {
            task.transferredBytes = sent;
            if (total > 0) task.totalBytes = total;
            task.speedBytesPerSec = speed;
            task.detailMessage = '正在上传至 ${targetMount.name}...';
          });
        },
      );

      if (!mounted) return;
      setState(() {
        task.status = FileTransferStatus.completed;
        if (task.totalBytes <= 0) task.totalBytes = task.transferredBytes;
        task.transferredBytes = task.totalBytes;
        task.detailMessage = '✓ 已成功上传至 ${targetMount.name}';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('✅ 上传成功：$fileName')),
      );
      if (_activeMount.id == targetMount.id) {
        await _loadDirectory(_listing?.path ?? targetMount.rootPath);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        task.status =
            cancelled ? FileTransferStatus.cancelled : FileTransferStatus.failed;
        task.speedBytesPerSec = 0;
        task.detailMessage = cancelled ? '已取消上传' : '上传失败：$e';
      });
      if (!cancelled) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('⚠️ 上传失败：$e')),
        );
      }
    }
  }

  /// Uploads a server file to 115 Cloud Drive (`/api/files/upload-115`) while tracking real-time upload progress in `_transferTasks`
  Future<void> _startUploadServerFileTo115WithProgress(FileEntry entry) async {
    final totalBytes = entry.size > 0 ? entry.size : 100;
    bool cancelled = false;
    final task = FileTransferTask(
      id: 'up115_${DateTime.now().millisecondsSinceEpoch}',
      name: entry.name,
      direction: FileTransferDirection.upload,
      sourceLabel: '流光服务端',
      targetLabel: '115 网盘',
      totalBytes: totalBytes,
      detailMessage: '正在提交 115 网盘上传任务...',
      onCancel: () => cancelled = true,
    );

    setState(() {
      _transferTasks.insert(0, task);
    });

    final startMs = DateTime.now().millisecondsSinceEpoch;
    try {
      if (Local115DirectService.instance.hasLocalCookie) {
        try {
          await widget.appState.api.login115WithCookie(
            Local115DirectService.instance.savedCookie,
          );
        } catch (_) {}
      }
      await widget.appState.api.uploadFileTo115(entry.path);

      bool finished = false;
      for (int tick = 0; tick < 180; tick++) {
        if (cancelled) throw const ApiException('用户已取消');
        await Future<void>.delayed(const Duration(seconds: 1));
        final tasks = await widget.appState.api.fetchDownloadTasks();
        final match = tasks.where((t) {
          return t.outputFile == entry.path ||
              t.name.contains(entry.name) ||
              entry.name.contains(t.name);
        }).firstOrNull;

        if (match != null) {
          if (match.status == 'Uploading') {
            final pct = match.progress.clamp(2.0, 99.0);
            final sent = (totalBytes * (pct / 100.0)).round();
            final elapsedSec =
                ((DateTime.now().millisecondsSinceEpoch - startMs) / 1000.0)
                    .clamp(0.5, 86400.0);
            if (mounted) {
              setState(() {
                task.transferredBytes = sent;
                task.speedBytesPerSec =
                    match.speed > 0 ? match.speed : (sent / elapsedSec);
                task.detailMessage =
                    '正在上传至 115 网盘 (${pct.toStringAsFixed(1)}%)';
              });
            }
            continue;
          } else if (match.status == 'Failed') {
            throw ApiException(
              match.error.isEmpty ? '115 上传失败' : match.error,
            );
          }
        }

        if (tick >= 2 && Local115DirectService.instance.hasLocalCookie) {
          final found = await Local115DirectService.instance
              .findAndResolveDirectPlayUrl(keywords: [entry.name]);
          if (found != null) {
            finished = true;
            break;
          }
        }

        final simRatio = ((tick + 1) * 0.16).clamp(0.05, 0.92);
        final simSent = (totalBytes * simRatio).round();
        final elapsedSec =
            ((DateTime.now().millisecondsSinceEpoch - startMs) / 1000.0)
                .clamp(0.5, 86400.0);
        if (mounted) {
          setState(() {
            task.transferredBytes = simSent;
            task.speedBytesPerSec = simSent / elapsedSec;
            task.detailMessage = '服务端正在同步至 115 网盘...';
          });
        }
        if (tick >= 5 && !tasks.any((t) => t.status == 'Uploading')) {
          finished = true;
          break;
        }
      }

      if (finished && mounted) {
        final elapsedSec =
            ((DateTime.now().millisecondsSinceEpoch - startMs) / 1000.0)
                .clamp(0.5, 86400.0);
        setState(() {
          task.transferredBytes = totalBytes;
          task.speedBytesPerSec = totalBytes / elapsedSec;
          task.status = FileTransferStatus.completed;
          task.detailMessage = '✓ 已成功上传至 115 网盘';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✅ 已上传至 115 网盘：${entry.name}')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        task.status =
            cancelled ? FileTransferStatus.cancelled : FileTransferStatus.failed;
        task.speedBytesPerSec = 0;
        task.detailMessage = '上传 115 失败：$e';
      });
    }
  }

  /// Cross-mount transfer: downloads from source mount to temp file, then uploads to `targetMount` with live progress
  Future<void> _startCrossMountUploadWithProgress({
    required FileEntry entry,
    required StorageMount targetMount,
    required String targetDir,
  }) async {
    if (entry.sourceKind == StorageSourceKind.localCache) {
      await _startUploadFileWithProgress(
        fileName: entry.name,
        localFilePath: entry.path,
        expectedSize: entry.size,
        overrideTargetMount: targetMount,
        overrideTargetDir: targetDir,
        sourceLabel: '本机离线目录',
      );
      return;
    }

    final srcMount =
        _mounts.where((m) => m.id == entry.mountId).firstOrNull ?? _activeMount;
    final tmpPath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}xup_${DateTime.now().millisecondsSinceEpoch}_${entry.name.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_')}';

    bool cancelled = false;
    final task = FileTransferTask(
      id: 'xup_${DateTime.now().millisecondsSinceEpoch}',
      name: entry.name,
      direction: FileTransferDirection.upload,
      sourceLabel: srcMount.name,
      targetLabel: '${targetMount.name} ($targetDir)',
      totalBytes: entry.size,
      detailMessage: '阶段 1/2 · 正在读取源文件数据...',
      onCancel: () => cancelled = true,
    );
    setState(() {
      _transferTasks.insert(0, task);
    });

    try {
      final resolved = await _resolveEntryEndpoint(entry);
      await RemoteStorageService.instance.downloadStreamWithProgress(
        uri: Uri.parse(resolved.url),
        headers: resolved.headers,
        destinationPath: tmpPath,
        expectedSizeHint: entry.size,
        isCancelled: () => cancelled,
        onProgress: (rec, tot, spd) {
          if (!mounted) return;
          setState(() {
            task.transferredBytes = rec ~/ 2;
            if (tot > 0) task.totalBytes = tot;
            task.speedBytesPerSec = spd;
            task.detailMessage = '阶段 1/2 · 正在拉取源文件...';
          });
        },
      );

      await RemoteStorageService.instance.uploadWithProgress(
        targetMount: targetMount,
        targetDir: targetDir,
        fileName: entry.name,
        localFilePath: tmpPath,
        serverApi: widget.appState.api,
        isCancelled: () => cancelled,
        onProgress: (sent, tot, spd) {
          if (!mounted) return;
          setState(() {
            task.transferredBytes = (tot ~/ 2) + (sent ~/ 2);
            if (tot > 0) task.totalBytes = tot;
            task.speedBytesPerSec = spd;
            task.detailMessage = '阶段 2/2 · 正在上传至 ${targetMount.name}...';
          });
        },
      );

      try {
        await File(tmpPath).delete();
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        task.status = FileTransferStatus.completed;
        task.transferredBytes = task.totalBytes;
        task.detailMessage = '✓ 已成功跨源上传至 ${targetMount.name}';
      });
      if (_activeMount.id == targetMount.id) {
        await _loadDirectory(_listing?.path ?? targetMount.rootPath);
      }
    } catch (e) {
      try {
        await File(tmpPath).delete();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        task.status =
            cancelled ? FileTransferStatus.cancelled : FileTransferStatus.failed;
        task.speedBytesPerSec = 0;
        task.detailMessage = '跨源上传失败：$e';
      });
    }
  }

  // ===========================================================================
  // Unified File Management Operations (Mkdir / Rename / Delete / Copy / Move)
  // ===========================================================================

  Future<void> _createFolderInActiveMount(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final mount = _activeMount;
    final curDir = _listing?.path ?? mount.rootPath;
    try {
      switch (mount.kind) {
        case StorageSourceKind.server:
          await widget.appState.api.createDirectory(_listing?.path ?? '', trimmed);
          break;
        case StorageSourceKind.alist:
          await RemoteStorageService.instance
              .createAlistFolder(mount, curDir, trimmed);
          break;
        case StorageSourceKind.webdav:
          await RemoteStorageService.instance
              .createWebdavFolder(mount, curDir, trimmed);
          break;
        case StorageSourceKind.cloud115:
          await Local115DirectService.instance
              .create115Folder(parentCid: curDir, name: trimmed);
          break;
        case StorageSourceKind.localCache:
          final dirPath = RemoteStorageService.joinLocalPath(curDir, trimmed);
          await Directory(dirPath).create(recursive: true);
          break;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✓ 已新建文件夹：$trimmed')),
        );
      }
      await _loadDirectory(_listing?.path ?? '');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('新建文件夹失败：$e')),
        );
      }
    }
  }

  Future<void> _renameEntryInActiveMount(
    FileEntry entry,
    String newName,
  ) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == entry.name) return;
    final mount =
        _mounts.where((m) => m.id == entry.mountId).firstOrNull ?? _activeMount;
    try {
      switch (mount.kind) {
        case StorageSourceKind.server:
          await widget.appState.api.renameFile(entry.path, trimmed);
          break;
        case StorageSourceKind.alist:
          await RemoteStorageService.instance
              .renameAlistEntry(mount, entry.path, trimmed);
          break;
        case StorageSourceKind.webdav:
          final parent = RemoteStorageService.parentPathOf(entry.path);
          final dst = RemoteStorageService.joinPath(
            parent.isEmpty ? '/' : parent,
            trimmed,
          );
          await RemoteStorageService.instance.moveOrCopyWebdavEntry(
            mount: mount,
            srcPath: entry.path,
            dstPath: dst,
            isMove: true,
          );
          break;
        case StorageSourceKind.cloud115:
          await Local115DirectService.instance.rename115File(
            fid: entry.fid115.isEmpty ? entry.path : entry.fid115,
            newName: trimmed,
          );
          break;
        case StorageSourceKind.localCache:
          final parentDir = File(entry.path).parent.path;
          final dstPath = RemoteStorageService.joinLocalPath(parentDir, trimmed);
          if (entry.isDir) {
            await Directory(entry.path).rename(dstPath);
          } else {
            await File(entry.path).rename(dstPath);
          }
          break;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✓ 已重命名为：$trimmed')),
        );
      }
      await _loadDirectory(_listing?.path ?? '');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('重命名失败：$e')),
        );
      }
    }
  }

  Future<void> _deleteEntriesInActiveMount(List<FileEntry> entries) async {
    if (entries.isEmpty) return;
    final mount = _activeMount;
    final curDir = _listing?.path ?? mount.rootPath;
    try {
      switch (mount.kind) {
        case StorageSourceKind.server:
          for (final e in entries) {
            await widget.appState.api.deleteFile(e.path);
          }
          break;
        case StorageSourceKind.alist:
          await RemoteStorageService.instance.deleteAlistEntries(
            mount,
            curDir,
            entries.map((e) => e.name).toList(),
          );
          break;
        case StorageSourceKind.webdav:
          for (final e in entries) {
            await RemoteStorageService.instance
                .deleteWebdavEntry(mount, e.path, isDir: e.isDir);
          }
          break;
        case StorageSourceKind.cloud115:
          for (final e in entries) {
            await Local115DirectService.instance.delete115File(
              fid: e.fid115.isEmpty ? e.path : e.fid115,
              parentCid: curDir,
            );
          }
          break;
        case StorageSourceKind.localCache:
          for (final e in entries) {
            if (e.isDir) {
              await Directory(e.path).delete(recursive: true);
            } else {
              await File(e.path).delete();
            }
          }
          break;
      }
      if (mounted) {
        setState(() {
          _multiSelectMode = false;
          _selectedPaths.clear();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('🗑️ 已删除 ${entries.length} 个项目')),
        );
      }
      await _loadDirectory(_listing?.path ?? '');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败：$e')),
        );
      }
    }
  }

  void _setClipboard(List<FileEntry> entries, {required bool isMove}) {
    if (entries.isEmpty) return;
    final mount = _activeMount;
    setState(() {
      _clipboard = FileClipboardItem(
        mountId: mount.id,
        sourceDirectory: _listing?.path ?? mount.rootPath,
        entries: entries,
        isMove: isMove,
      );
      _multiSelectMode = false;
      _selectedPaths.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '📋 已${isMove ? "剪切" : "复制"} ${entries.length} 个项目，进入目标目录后点击「粘贴到此处」',
        ),
      ),
    );
  }

  Future<void> _pasteClipboardToCurrentDirectory() async {
    final clip = _clipboard;
    if (clip == null) return;
    final dstMount = _activeMount;
    final dstDir = _listing?.path ?? dstMount.rootPath;

    if (clip.mountId == dstMount.id) {
      try {
        switch (dstMount.kind) {
          case StorageSourceKind.alist:
            await RemoteStorageService.instance.copyOrMoveAlistEntries(
              mount: dstMount,
              srcDir: clip.sourceDirectory,
              dstDir: dstDir,
              names: clip.entries.map((e) => e.name).toList(),
              isMove: clip.isMove,
            );
            setState(() => _clipboard = null);
            await _loadDirectory(dstDir);
            return;
          case StorageSourceKind.webdav:
            for (final e in clip.entries) {
              final dstPath = RemoteStorageService.joinPath(dstDir, e.name);
              await RemoteStorageService.instance.moveOrCopyWebdavEntry(
                mount: dstMount,
                srcPath: e.path,
                dstPath: dstPath,
                isMove: clip.isMove,
              );
            }
            setState(() => _clipboard = null);
            await _loadDirectory(dstDir);
            return;
          case StorageSourceKind.localCache:
            for (final e in clip.entries) {
              final dstPath = RemoteStorageService.joinLocalPath(dstDir, e.name);
              if (clip.isMove) {
                if (e.isDir) {
                  await Directory(e.path).rename(dstPath);
                } else {
                  await File(e.path).rename(dstPath);
                }
              } else if (!e.isDir) {
                await File(e.path).copy(dstPath);
              }
            }
            setState(() => _clipboard = null);
            await _loadDirectory(dstDir);
            return;
          default:
            break;
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('粘贴失败：$e')),
          );
        }
        return;
      }
    }

    // Cross-mount paste via streaming download/upload with progress!
    final files = clip.entries.where((e) => !e.isDir).toList();
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('跨存储源暂仅支持复制/上传文件')),
      );
      return;
    }
    setState(() => _clipboard = null);
    for (final entry in files) {
      if (dstMount.kind == StorageSourceKind.localCache) {
        unawaited(_startDownloadFileWithProgress(entry, customTargetDir: dstDir));
      } else {
        unawaited(
          _startCrossMountUploadWithProgress(
            entry: entry,
            targetMount: dstMount,
            targetDir: dstDir,
          ),
        );
      }
    }
  }

  // ===========================================================================
  // Bookmarks, Filtering & Sorting
  // ===========================================================================

  bool get _isCurrentDirBookmarked {
    final mount = _activeMount;
    final curPath = _listing?.path ?? mount.rootPath;
    return _bookmarkedRecords.any((rec) {
      final parts = rec.split('::');
      return parts.length >= 3 &&
          parts[0] == mount.id &&
          parts.sublist(2).join('::') == curPath;
    });
  }

  Future<void> _toggleCurrentDirBookmark() async {
    final mount = _activeMount;
    final curPath = _listing?.path ?? mount.rootPath;
    final title = switch (mount.kind) {
      StorageSourceKind.cloud115 =>
        _cloud115Breadcrumbs.lastOrNull?.name ?? '115目录',
      _ => curPath
              .split(RegExp(r'[/\\]'))
              .where((s) => s.isNotEmpty)
              .lastOrNull ??
          mount.name,
    };
    setState(() {
      final idx = _bookmarkedRecords.indexWhere((rec) {
        final parts = rec.split('::');
        return parts.length >= 3 &&
            parts[0] == mount.id &&
            parts.sublist(2).join('::') == curPath;
      });
      if (idx >= 0) {
        _bookmarkedRecords.removeAt(idx);
      } else {
        _bookmarkedRecords.insert(0, '${mount.id}::$title::$curPath');
      }
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefBookmarksKey, _bookmarkedRecords);
    } catch (_) {}
  }

  List<FileEntry> _getFilteredAndSortedEntries(List<FileEntry> raw) {
    final kw = _searchFilter.trim().toLowerCase();
    final filtered = raw.where((e) {
      if (kw.isNotEmpty && !e.name.toLowerCase().contains(kw)) {
        return false;
      }
      if (e.isDir) return true;
      switch (_categoryFilter) {
        case 'video':
          return e.isVideo;
        case 'audio':
          return e.isAudio;
        case 'image':
          return e.isImage;
        case 'doc':
          return e.isTextPreviewable || e.isArchive;
        case 'all':
        default:
          return true;
      }
    }).toList();

    filtered.sort((a, b) {
      if (a.isDir != b.isDir) {
        return a.isDir ? -1 : 1;
      }
      switch (_sortMode) {
        case 'size_desc':
          return b.size.compareTo(a.size);
        case 'name_asc':
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case 'type_asc':
          final cmp = a.normalizedExt.compareTo(b.normalizedExt);
          return cmp != 0
              ? cmp
              : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case 'time_desc':
        default:
          return b.modTime.compareTo(a.modTime);
      }
    });
    return filtered;
  }

  // ===========================================================================
  // Dialogs: Mount AList/WebDAV, Transfer Center, Remote Download, Action Sheet
  // ===========================================================================

  Future<void> _showMountStorageDialog({StorageMount? existing}) async {
    var kind = existing?.kind ?? StorageSourceKind.alist;
    if (kind != StorageSourceKind.alist && kind != StorageSourceKind.webdav) {
      kind = StorageSourceKind.alist;
    }
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final urlCtrl = TextEditingController(
      text: existing?.baseUrl ?? 'http://192.168.1.10:5244',
    );
    final userCtrl = TextEditingController(text: existing?.username ?? '');
    final passCtrl = TextEditingController(text: existing?.password ?? '');
    final tokenCtrl = TextEditingController(text: existing?.token ?? '');
    final rootCtrl = TextEditingController(text: existing?.rootPath ?? '/');

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          return AlertDialog(
            backgroundColor: VideoPlatformTheme.bgElevated,
            title: Row(
              children: [
                Icon(
                  Icons.cloud_sync_rounded,
                  color: VideoPlatformTheme.accent,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  existing == null
                      ? '挂载远程存储 (AList / OpenList / WebDAV)'
                      : '编辑挂载：${existing.name}',
                  style: const TextStyle(fontSize: 15.5),
                ),
              ],
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text('协议类型：', style: TextStyle(fontSize: 13)),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('AList / OpenList (v3 API)'),
                          selected: kind == StorageSourceKind.alist,
                          onSelected: (_) {
                            setModalState(() {
                              kind = StorageSourceKind.alist;
                              if (urlCtrl.text ==
                                  'http://192.168.1.10:5244/dav') {
                                urlCtrl.text = 'http://192.168.1.10:5244';
                              }
                            });
                          },
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('WebDAV 标准网盘'),
                          selected: kind == StorageSourceKind.webdav,
                          onSelected: (_) {
                            setModalState(() {
                              kind = StorageSourceKind.webdav;
                              if (urlCtrl.text == 'http://192.168.1.10:5244') {
                                urlCtrl.text = 'http://192.168.1.10:5244/dav';
                              }
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: '显示名称（例如：家庭 AList / 群晖 WebDAV / CloudDrive2）',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: urlCtrl,
                      decoration: InputDecoration(
                        labelText: kind == StorageSourceKind.alist
                            ? 'AList 地址（如 http://192.168.1.10:5244）'
                            : 'WebDAV 完整地址（如 http://192.168.1.10:5244/dav）',
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: userCtrl,
                            decoration: const InputDecoration(
                              labelText: '用户名（游客留空）',
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: passCtrl,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: '密码（选填）',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: rootCtrl,
                            decoration: const InputDecoration(
                              labelText: '默认初始目录（默认 /）',
                            ),
                          ),
                        ),
                        if (kind == StorageSourceKind.alist) ...[
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: tokenCtrl,
                              decoration: const InputDecoration(
                                labelText: 'AList Token（选填）',
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              if (existing != null && !existing.isBuiltIn)
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: VideoPlatformTheme.danger,
                  ),
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    setState(() {
                      _mounts.removeWhere((m) => m.id == existing.id);
                    });
                    await _persistCustomMounts();
                    if (_activeMountId == existing.id) {
                      await _switchMount('builtin_server');
                    }
                  },
                  child: const Text('卸载此存储'),
                ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton.icon(
                onPressed: () async {
                  final rawUrl = urlCtrl.text.trim();
                  if (rawUrl.isEmpty) return;
                  final host = Uri.tryParse(
                        RemoteStorageService.cleanBaseUrl(rawUrl),
                      )?.host ??
                      '远程盘';
                  final cleanName = nameCtrl.text.trim().isEmpty
                      ? '${kind.title} ($host)'
                      : nameCtrl.text.trim();
                  final newMount = StorageMount(
                    id: existing?.id ??
                        'mount_${DateTime.now().millisecondsSinceEpoch}',
                    name: cleanName,
                    kind: kind,
                    baseUrl: rawUrl,
                    username: userCtrl.text.trim(),
                    password: passCtrl.text,
                    token: tokenCtrl.text.trim(),
                    rootPath: rootCtrl.text.trim().isEmpty
                        ? '/'
                        : RemoteStorageService.normalizePath(
                            rootCtrl.text.trim(),
                          ),
                  );
                  Navigator.of(ctx).pop();
                  setState(() {
                    final idx =
                        _mounts.indexWhere((m) => m.id == newMount.id);
                    if (idx >= 0) {
                      _mounts[idx] = newMount;
                    } else {
                      _mounts.add(newMount);
                    }
                  });
                  await _persistCustomMounts();
                  await _switchMount(newMount.id);
                },
                icon: const Icon(Icons.check_rounded, size: 16),
                label: const Text('保存并立即打开'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showTransferCenterDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          return AlertDialog(
            backgroundColor: VideoPlatformTheme.bgElevated,
            title: Row(
              children: [
                Icon(
                  Icons.swap_vert_circle_rounded,
                  color: VideoPlatformTheme.accent,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  '文件上传与下载进度中心 (${_transferTasks.length})',
                  style: const TextStyle(fontSize: 15.5),
                ),
                const Spacer(),
                if (_transferTasks.isNotEmpty)
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _transferTasks.removeWhere(
                          (t) => t.status != FileTransferStatus.running,
                        );
                      });
                      setModalState(() {});
                    },
                    child: const Text('清理已完成'),
                  ),
              ],
            ),
            content: SizedBox(
              width: 680,
              height: 420,
              child: _transferTasks.isEmpty
                  ? Center(
                      child: Text(
                        '当前暂无上传或下载任务',
                        style: TextStyle(color: VideoPlatformTheme.textMuted),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _transferTasks.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, idx) {
                        final t = _transferTasks[idx];
                        final isUpload =
                            t.direction == FileTransferDirection.upload;
                        return Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: VideoPlatformTheme.bgCard,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: VideoPlatformTheme.borderSubtle,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    isUpload
                                        ? Icons.arrow_circle_up_rounded
                                        : Icons.arrow_circle_down_rounded,
                                    color: t.status == FileTransferStatus.failed
                                        ? VideoPlatformTheme.danger
                                        : (t.status ==
                                                FileTransferStatus.completed
                                            ? const Color(0xFF22C55E)
                                            : VideoPlatformTheme.accent),
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      '[${t.direction.label}] ${t.name}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '${t.percentText} · ${t.formattedSpeed}',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w700,
                                      color: VideoPlatformTheme.accent,
                                    ),
                                  ),
                                  if (t.status ==
                                      FileTransferStatus.running) ...[
                                    const SizedBox(width: 8),
                                    TextButton(
                                      onPressed: () {
                                        t.onCancel?.call();
                                        setModalState(() {});
                                      },
                                      child: const Text('取消'),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 6),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: t.progress,
                                  minHeight: 6,
                                  color: t.status == FileTransferStatus.failed
                                      ? VideoPlatformTheme.danger
                                      : (t.status ==
                                              FileTransferStatus.completed
                                          ? const Color(0xFF22C55E)
                                          : VideoPlatformTheme.accent),
                                  backgroundColor:
                                      VideoPlatformTheme.borderSubtle,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      '${t.sourceLabel} → ${t.targetLabel} · ${t.detailMessage}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        color: VideoPlatformTheme.textMuted,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    t.formattedBytesProgress,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: VideoPlatformTheme.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showRemoteUrlDownloadDialog() async {
    final urlCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VideoPlatformTheme.bgElevated,
        title: const Text('远程链接离线下载 (支持 HTTP / M3U8 / 磁力链)', style: TextStyle(fontSize: 15.5)),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '下载链接 (https://... 或 .m3u8 或 magnet:?xt=...)',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: '保存文件名（选填，留空自动识别）',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () async {
              final rawUrl = urlCtrl.text.trim();
              if (rawUrl.isEmpty) return;
              final customName = nameCtrl.text.trim();
              Navigator.of(ctx).pop();
              final resolvedName = customName.isNotEmpty
                  ? customName
                  : (Uri.tryParse(rawUrl)?.pathSegments.lastOrNull ??
                      '离线下载_${DateTime.now().millisecondsSinceEpoch ~/ 1000}');
              if (_activeMount.kind == StorageSourceKind.localCache &&
                  rawUrl.startsWith('http') &&
                  !rawUrl.toLowerCase().contains('.m3u8')) {
                await _startDownloadFileWithProgress(
                  FileEntry(
                    name: resolvedName,
                    path: rawUrl,
                    size: 0,
                    modTime: '',
                    isDir: false,
                    isMp4: resolvedName.toLowerCase().endsWith('.mp4'),
                    ext: '',
                    mountId: 'builtin_local',
                    sourceKind: StorageSourceKind.alist,
                    rawDownloadUrl: rawUrl,
                  ),
                  customTargetDir: _listing?.path,
                );
                return;
              }
              try {
                await widget.appState.api.createDownloadTask(
                  url: rawUrl,
                  name: resolvedName,
                );
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('⬇️ 已提交服务端离线下载任务：$resolvedName')),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('提交离线下载失败：$e')),
                  );
                }
              }
            },
            icon: const Icon(Icons.download_rounded, size: 16),
            label: const Text('开始下载'),
          ),
        ],
      ),
    );
  }

  Future<void> _showMkdirDialog() async {
    final ctrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VideoPlatformTheme.bgElevated,
        title: Text(
          '在「${_activeMount.name}」新建文件夹',
          style: const TextStyle(fontSize: 15.5),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '请输入文件夹名称'),
          onSubmitted: (v) {
            Navigator.of(ctx).pop();
            _createFolderInActiveMount(v);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _createFolderInActiveMount(ctrl.text);
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  Future<void> _showRenameDialog(FileEntry entry) async {
    final ctrl = TextEditingController(text: entry.name);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VideoPlatformTheme.bgElevated,
        title: const Text('重命名', style: TextStyle(fontSize: 15.5)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '请输入新名称'),
          onSubmitted: (v) {
            Navigator.of(ctx).pop();
            _renameEntryInActiveMount(entry, v);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _renameEntryInActiveMount(entry, ctrl.text);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _showFileActionSheet(FileEntry entry) async {
    final otherUploadTargets = _mounts
        .where(
          (m) =>
              m.id != entry.mountId &&
              (m.kind == StorageSourceKind.alist ||
                  m.kind == StorageSourceKind.webdav ||
                  m.kind == StorageSourceKind.server),
        )
        .toList();

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: VideoPlatformTheme.bgElevated,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _iconForEntry(entry),
                      color: _colorForEntry(entry),
                      size: 26,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${entry.formattedSize} · ${entry.modTime} · ${entry.path}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: VideoPlatformTheme.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: const Icon(Icons.close_rounded, size: 20),
                    ),
                  ],
                ),
                const Divider(height: 18),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (entry.isDir) ...[
                      FilledButton.icon(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _loadDirectory(entry.path, folderTitleHint: entry.name);
                        },
                        icon: const Icon(Icons.folder_open_rounded, size: 16),
                        label: const Text('打开文件夹'),
                      ),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: VideoPlatformTheme.accent,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () async {
                          Navigator.of(ctx).pop();
                          final mount = _mounts
                                  .where((m) => m.id == entry.mountId)
                                  .firstOrNull ??
                              _activeMount;
                          final count = await _musicController
                              .scanAndPlayFoldersOrArchives(
                            sources: [
                              SavedMusicFolderItem(
                                mountId: mount.id,
                                mountName: mount.name,
                                sourceKind: mount.kind,
                                path: entry.path,
                                title: entry.name,
                                isArchive: false,
                              ),
                            ],
                            shuffle: true,
                            includeSubfolders: true,
                          );
                          if (!mounted) return;
                          if (count > 0) {
                            await _showCloudMusicFullscreenModal();
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('「${entry.name}」下未找到音乐文件'),
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.shuffle_rounded, size: 16),
                        label: const Text('随机播放此文件夹音乐 (含子目录/压缩包)'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () async {
                          Navigator.of(ctx).pop();
                          final mount = _mounts
                                  .where((m) => m.id == entry.mountId)
                                  .firstOrNull ??
                              _activeMount;
                          final count = await _musicController
                              .scanAndPlayFoldersOrArchives(
                            sources: [
                              SavedMusicFolderItem(
                                mountId: mount.id,
                                mountName: mount.name,
                                sourceKind: mount.kind,
                                path: entry.path,
                                title: entry.name,
                                isArchive: false,
                              ),
                            ],
                            shuffle: false,
                            includeSubfolders: true,
                          );
                          if (!mounted) return;
                          if (count > 0) {
                            await _showCloudMusicFullscreenModal();
                          }
                        },
                        icon: const Icon(Icons.album_rounded, size: 16),
                        label: const Text('顺序播放此文件夹音乐'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          Navigator.of(ctx).pop();
                          final mount = _mounts
                                  .where((m) => m.id == entry.mountId)
                                  .firstOrNull ??
                              _activeMount;
                          await _musicController.addOrToggleSavedMusicFolder(
                            SavedMusicFolderItem(
                              mountId: mount.id,
                              mountName: mount.name,
                              sourceKind: mount.kind,
                              path: entry.path,
                              title: entry.name,
                              isArchive: false,
                            ),
                          );
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('⭐ 已更新常用音乐目录：${entry.name}'),
                            ),
                          );
                        },
                        icon: const Icon(Icons.star_rounded, size: 16),
                        label: const Text('存为音乐播放器常用目录'),
                      ),
                    ],
                    if (!entry.isDir && entry.isStreamableMusicArchive) ...[
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: VideoPlatformTheme.accent,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _handleDirectEntryClick(entry);
                        },
                        icon: const Icon(Icons.folder_zip_rounded, size: 16),
                        label: const Text('浏览/播放压缩包内音乐'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () async {
                          Navigator.of(ctx).pop();
                          final count = await _musicController.playArchiveMusic(
                            archiveEntry: entry,
                            shuffle: true,
                            mounts: _mounts,
                          );
                          if (!mounted) return;
                          if (count > 0) {
                            await _showCloudMusicFullscreenModal();
                          }
                        },
                        icon: const Icon(Icons.shuffle_rounded, size: 16),
                        label: const Text('随机播放压缩包内音乐'),
                      ),
                    ],
                    if (!entry.isDir && entry.isAudio) ...[
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: VideoPlatformTheme.accent,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _handleDirectEntryClick(entry);
                        },
                        icon: const Icon(Icons.album_rounded, size: 16),
                        label: const Text('黑胶音乐厅播放'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _handleDirectEntryClick(entry, inMiniPlayer: true);
                        },
                        icon: const Icon(Icons.music_note_rounded, size: 16),
                        label: const Text('底部常驻后台播放'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _musicController.addToQueue(
                            entry,
                            playNext: true,
                            directoryEntries: _listing?.entries,
                            mounts: _mounts,
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('⏭️ 已设为下一首播放：${entry.name}'),
                            ),
                          );
                        },
                        icon: const Icon(Icons.playlist_play_rounded, size: 16),
                        label: const Text('下一首播放'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _musicController.addToQueue(
                            entry,
                            playNext: false,
                            directoryEntries: _listing?.entries,
                            mounts: _mounts,
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('➕ 已加入音乐播放队列：${entry.name}'),
                            ),
                          );
                        },
                        icon: const Icon(Icons.playlist_add_rounded, size: 16),
                        label: const Text('加入播放队列'),
                      ),
                    ],
                    if (!entry.isDir && entry.isVideo) ...[
                      FilledButton.icon(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _handleDirectEntryClick(entry);
                        },
                        icon: const Icon(Icons.play_arrow_rounded, size: 16),
                        label: const Text('立即播放'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _handleDirectEntryClick(entry, inMiniPlayer: true);
                        },
                        icon: const Icon(
                          Icons.picture_in_picture_alt_rounded,
                          size: 16,
                        ),
                        label: const Text('小窗悬浮播放'),
                      ),
                    ],
                    if (!entry.isDir &&
                        (entry.isImage || entry.isTextPreviewable))
                      FilledButton.icon(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _handleDirectEntryClick(entry);
                        },
                        icon: const Icon(Icons.visibility_outlined, size: 16),
                        label: const Text('预览内容'),
                      ),
                    if (!entry.isDir &&
                        entry.sourceKind != StorageSourceKind.localCache)
                      FilledButton.tonalIcon(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _startDownloadFileWithProgress(entry);
                        },
                        icon: const Icon(Icons.download_rounded, size: 16),
                        label: const Text('下载到本机 (显示实时进度)'),
                      ),
                    if (!entry.isDir &&
                        entry.sourceKind == StorageSourceKind.server) ...[
                      OutlinedButton.icon(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _startUploadServerFileTo115WithProgress(entry);
                        },
                        icon: const Icon(Icons.cloud_upload_outlined, size: 16),
                        label: const Text('上传到 115 网盘 (显示进度)'),
                      ),
                      if (!entry.isMp4 && entry.isVideo)
                        OutlinedButton.icon(
                          onPressed: () async {
                            Navigator.of(ctx).pop();
                            try {
                              await widget.appState.api
                                  .convertFileToMp4(entry.path);
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('已提交后台无损转封装 MP4 任务'),
                                  ),
                                );
                              }
                            } catch (e) {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('转码失败：$e')),
                                );
                              }
                            }
                          },
                          icon: const Icon(
                            Icons.video_file_outlined,
                            size: 16,
                          ),
                          label: const Text('无损转封装 MP4'),
                        ),
                    ],
                    for (final targetMount in otherUploadTargets)
                      if (!entry.isDir)
                        OutlinedButton.icon(
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            _startCrossMountUploadWithProgress(
                              entry: entry,
                              targetMount: targetMount,
                              targetDir: targetMount.rootPath,
                            );
                          },
                          icon: const Icon(Icons.upload_file_rounded, size: 16),
                          label: Text('上传至「${targetMount.name}」'),
                        ),
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _showRenameDialog(entry);
                      },
                      icon: const Icon(
                        Icons.drive_file_rename_outline,
                        size: 16,
                      ),
                      label: const Text('重命名'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _setClipboard([entry], isMove: false);
                      },
                      icon: const Icon(Icons.copy_rounded, size: 16),
                      label: const Text('复制'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _setClipboard([entry], isMove: true);
                      },
                      icon: const Icon(
                        Icons.drive_file_move_outlined,
                        size: 16,
                      ),
                      label: const Text('剪切 / 移动'),
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: VideoPlatformTheme.danger,
                      ),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _deleteEntriesInActiveMount([entry]);
                      },
                      icon: const Icon(Icons.delete_outline_rounded, size: 16),
                      label: const Text('删除'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  IconData _iconForEntry(FileEntry entry) {
    if (entry.isDir) return Icons.folder_rounded;
    if (entry.isVideo) return Icons.movie_creation_rounded;
    if (entry.isAudio) return Icons.audiotrack_rounded;
    if (entry.isImage) return Icons.image_rounded;
    if (entry.isTextPreviewable) return Icons.description_rounded;
    if (entry.isArchive) return Icons.archive_rounded;
    return Icons.insert_drive_file_rounded;
  }

  Color _colorForEntry(FileEntry entry) {
    if (entry.isDir) return const Color(0xFFFFC107);
    if (entry.isVideo) return VideoPlatformTheme.accent;
    if (entry.isAudio) return const Color(0xFF10B981);
    if (entry.isImage) return const Color(0xFFA855F7);
    if (entry.isTextPreviewable) return const Color(0xFF38BDF8);
    return VideoPlatformTheme.textSecondary;
  }

  IconData _iconForMountKind(StorageSourceKind kind) {
    return switch (kind) {
      StorageSourceKind.server => Icons.dns_rounded,
      StorageSourceKind.alist => Icons.cloud_circle_rounded,
      StorageSourceKind.webdav => Icons.language_rounded,
      StorageSourceKind.cloud115 => Icons.cloud_done_rounded,
      StorageSourceKind.localCache => Icons.folder_special_rounded,
    };
  }

  // ===========================================================================
  // UI Builders
  // ===========================================================================

  Widget _buildStorageMountsBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        border: Border(
          bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final mount in _mounts) ...[
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: StatefulBuilder(
                  builder: (mountCtx, setMountState) {
                    final isSelected = mount.id == _activeMountId;
                    return InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onFocusChange: (_) {
                        if (mountCtx.mounted) setMountState(() {});
                      },
                      onTap: () => _switchMount(mount.id),
                      onLongPress: mount.isBuiltIn
                          ? null
                          : () => _showMountStorageDialog(existing: mount),
                      child: Builder(
                        builder: (ctx) {
                          final isFocused = Focus.of(ctx).hasPrimaryFocus;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 140),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? (isFocused
                                      ? VideoPlatformTheme.accentHover
                                      : VideoPlatformTheme.accent)
                                  : (isFocused
                                      ? VideoPlatformTheme.accent
                                          .withValues(alpha: 0.34)
                                      : VideoPlatformTheme.bgCard),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: isFocused
                                    ? const Color(0xFFFFE066)
                                    : (isSelected
                                        ? VideoPlatformTheme.accent
                                        : VideoPlatformTheme.borderSubtle),
                                width: isFocused ? 2.4 : 1.0,
                              ),
                              boxShadow: isFocused
                                  ? [
                                      BoxShadow(
                                        color: VideoPlatformTheme.accent
                                            .withValues(alpha: 0.55),
                                        blurRadius: 10,
                                        spreadRadius: 1,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _iconForMountKind(mount.kind),
                                  size: 15,
                                  color: (isSelected || isFocused)
                                      ? Colors.white
                                      : VideoPlatformTheme.accent,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  mount.name,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: (isSelected || isFocused)
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: (isSelected || isFocused)
                                        ? Colors.white
                                        : VideoPlatformTheme.textPrimary,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: (isSelected || isFocused)
                                        ? Colors.black26
                                        : VideoPlatformTheme.bgElevated,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    mount.kind.badge,
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: (isSelected || isFocused)
                                          ? Colors.white
                                          : VideoPlatformTheme.textMuted,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              ),
              onPressed: () => _showMountStorageDialog(),
              icon: const Icon(Icons.add_circle_outline_rounded, size: 15),
              label: const Text('挂载 AList / WebDAV', style: TextStyle(fontSize: 12)),
            ),
            if (!_activeMount.isBuiltIn) ...[
              const SizedBox(width: 6),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '编辑当前挂载存储',
                onPressed: () =>
                    _showMountStorageDialog(existing: _activeMount),
                icon: const Icon(Icons.settings_outlined, size: 17),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLiveTransferProgressBanner() {
    final top = _primaryActiveTransfer;
    if (top == null) return const SizedBox.shrink();
    final runningCount = _runningTransfersCount;
    final isUpload = top.direction == FileTransferDirection.upload;

    return InkWell(
      onTap: _showTransferCenterDialog,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: VideoPlatformTheme.accent.withValues(alpha: 0.12),
          border: Border(
            bottom: BorderSide(
              color: VideoPlatformTheme.accent.withValues(alpha: 0.35),
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isUpload
                      ? Icons.arrow_circle_up_rounded
                      : Icons.arrow_circle_down_rounded,
                  size: 18,
                  color: top.status == FileTransferStatus.failed
                      ? VideoPlatformTheme.danger
                      : (top.status == FileTransferStatus.completed
                          ? const Color(0xFF22C55E)
                          : VideoPlatformTheme.accent),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${top.direction.label}${top.status.label}：${top.name}  (${top.detailMessage})',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (runningCount > 1)
                  Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1.5,
                    ),
                    decoration: BoxDecoration(
                      color: VideoPlatformTheme.accent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$runningCount 个并发任务',
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                Text(
                  '${top.percentText} · ${top.formattedBytesProgress} · ${top.formattedSpeed}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: VideoPlatformTheme.accent,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '队列 (${_transferTasks.length}) ›',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: VideoPlatformTheme.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: top.progress,
                minHeight: 4.5,
                color: top.status == FileTransferStatus.failed
                    ? VideoPlatformTheme.danger
                    : (top.status == FileTransferStatus.completed
                        ? const Color(0xFF22C55E)
                        : VideoPlatformTheme.accent),
                backgroundColor: VideoPlatformTheme.borderSubtle,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClickablePathBreadcrumbs() {
    final mount = _activeMount;
    final currentPath = _listing?.path ?? mount.rootPath;

    if (mount.kind == StorageSourceKind.cloud115) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: VideoPlatformTheme.bgCard,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: VideoPlatformTheme.borderSubtle),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (int i = 0; i < _cloud115Breadcrumbs.length; i++) ...[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 14,
                      color: VideoPlatformTheme.textMuted,
                    ),
                  ),
                StatefulBuilder(
                  builder: (crumbCtx, setCrumbState) {
                    return InkWell(
                      borderRadius: BorderRadius.circular(5),
                      onFocusChange: (_) {
                        if (crumbCtx.mounted) setCrumbState(() {});
                      },
                      onTap: () => _loadDirectory(
                        _cloud115Breadcrumbs[i].cid,
                        folderTitleHint: _cloud115Breadcrumbs[i].name,
                      ),
                      child: Builder(
                        builder: (ctx) {
                          final isFocused = Focus.of(ctx).hasPrimaryFocus;
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: isFocused
                                  ? VideoPlatformTheme.accent
                                      .withValues(alpha: 0.34)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(5),
                              border: isFocused
                                  ? Border.all(
                                      color: const Color(0xFFFFE066),
                                      width: 1.8,
                                    )
                                  : null,
                            ),
                            child: Text(
                              _cloud115Breadcrumbs[i].name,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: (i == _cloud115Breadcrumbs.length - 1 ||
                                        isFocused)
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                                color: isFocused
                                    ? Colors.white
                                    : (i == _cloud115Breadcrumbs.length - 1
                                        ? VideoPlatformTheme.textPrimary
                                        : VideoPlatformTheme.accent),
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      );
    }

    final parts = currentPath
        .split(RegExp(r'[/\\]'))
        .where((s) => s.trim().isNotEmpty)
        .toList();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgCard,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: VideoPlatformTheme.borderSubtle),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            StatefulBuilder(
              builder: (rootCrumbCtx, setRootCrumbState) {
                return InkWell(
                  borderRadius: BorderRadius.circular(5),
                  onFocusChange: (_) {
                    if (rootCrumbCtx.mounted) setRootCrumbState(() {});
                  },
                  onTap: () => _loadDirectory(
                    mount.kind == StorageSourceKind.server ? '' : mount.rootPath,
                  ),
                  child: Builder(
                    builder: (ctx) {
                      final isFocused = Focus.of(ctx).hasPrimaryFocus;
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: isFocused
                              ? VideoPlatformTheme.accent.withValues(alpha: 0.34)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(5),
                          border: isFocused
                              ? Border.all(
                                  color: const Color(0xFFFFE066),
                                  width: 1.8,
                                )
                              : null,
                        ),
                        child: Text(
                          '/ ${mount.name}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: (parts.isEmpty || isFocused)
                                ? FontWeight.w700
                                : FontWeight.w400,
                            color: isFocused
                                ? Colors.white
                                : (parts.isEmpty
                                    ? VideoPlatformTheme.textPrimary
                                    : VideoPlatformTheme.accent),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
            for (var i = 0; i < parts.length; i++) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 14,
                  color: VideoPlatformTheme.textMuted,
                ),
              ),
              StatefulBuilder(
                builder: (partCtx, setPartState) {
                  return InkWell(
                    borderRadius: BorderRadius.circular(5),
                    onFocusChange: (_) {
                      if (partCtx.mounted) setPartState(() {});
                    },
                    onTap: () {
                      final prefix = currentPath.startsWith('/') ? '/' : '';
                      final sep = mount.kind == StorageSourceKind.localCache
                          ? Platform.pathSeparator
                          : '/';
                      final targetPath =
                          '$prefix${parts.sublist(0, i + 1).join(sep)}';
                      _loadDirectory(targetPath);
                    },
                    child: Builder(
                      builder: (ctx) {
                        final isFocused = Focus.of(ctx).hasPrimaryFocus;
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: isFocused
                                ? VideoPlatformTheme.accent
                                    .withValues(alpha: 0.34)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(5),
                            border: isFocused
                                ? Border.all(
                                    color: const Color(0xFFFFE066),
                                    width: 1.8,
                                  )
                                : null,
                          ),
                          child: Text(
                            parts[i],
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: (i == parts.length - 1 || isFocused)
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              color: isFocused
                                  ? Colors.white
                                  : (i == parts.length - 1
                                      ? VideoPlatformTheme.textPrimary
                                      : VideoPlatformTheme.accent),
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.appState;
    state.activeChildBackHandler = _handleBackPress;
    final entries =
        _getFilteredAndSortedEntries(_listing?.entries ?? const <FileEntry>[]);
    final isBookmarked = _isCurrentDirBookmarked;

    return Stack(
      children: [
        Column(
          children: [
            // 1. Multi-Storage Source Mounts Bar
            _buildStorageMountsBar(),

            // 2. Real-Time Upload & Download Progress Banner
            if (_transferTasks.isNotEmpty) _buildLiveTransferProgressBanner(),

            // 3. Breadcrumb Path & File Upload/Download Action Toolbar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: VideoPlatformTheme.bgElevated,
                border: Border(
                  bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '返回上级目录',
                        onPressed: _canNavigateUp ? _navigateUp : null,
                        icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '根目录',
                        onPressed: () => _loadDirectory(
                          _activeMount.kind == StorageSourceKind.server
                              ? ''
                              : (_activeMount.kind == StorageSourceKind.cloud115
                                  ? '0'
                                  : _activeMount.rootPath),
                        ),
                        icon: const Icon(Icons.home_outlined, size: 18),
                      ),
                      const SizedBox(width: 4),
                      Expanded(child: _buildClickablePathBreadcrumbs()),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: isBookmarked ? '取消收藏此目录' : '收藏此目录到常用夹',
                        onPressed: _toggleCurrentDirBookmark,
                        icon: Icon(
                          isBookmarked
                              ? Icons.star_rounded
                              : Icons.star_border_rounded,
                          size: 19,
                          color: isBookmarked
                              ? VideoPlatformTheme.warning
                              : VideoPlatformTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(width: 4),
                      FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: _pickAndUploadFilesToCurrentMount,
                        icon: const Icon(Icons.upload_file_rounded, size: 15),
                        label: const Text('上传文件', style: TextStyle(fontSize: 12)),
                      ),
                      const SizedBox(width: 6),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: _showRemoteUrlDownloadDialog,
                        icon: const Icon(
                          Icons.cloud_download_outlined,
                          size: 15,
                        ),
                        label: const Text('离线下载', style: TextStyle(fontSize: 12)),
                      ),
                      const SizedBox(width: 6),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: _showMkdirDialog,
                        icon: const Icon(
                          Icons.create_new_folder_outlined,
                          size: 15,
                        ),
                        label: const Text('新建文件夹', style: TextStyle(fontSize: 12)),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '传输进度中心',
                        onPressed: _showTransferCenterDialog,
                        icon: Badge(
                          isLabelVisible: _transferTasks.isNotEmpty,
                          label: Text('${_transferTasks.length}'),
                          child: const Icon(
                            Icons.swap_vert_circle_outlined,
                            size: 19,
                          ),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '刷新目录',
                        onPressed: () =>
                            _loadDirectory(_listing?.path ?? ''),
                        icon: const Icon(Icons.refresh, size: 18),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Filter, Search, Clipboard Paste, Multi-select, Sort & Grid/List Toggle Row
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 210,
                          height: 32,
                          child: TextField(
                            controller: _searchController,
                            onChanged: (v) => setState(() => _searchFilter = v),
                            style: const TextStyle(fontSize: 12.5),
                            decoration: InputDecoration(
                              hintText: '搜索当前目录文件...',
                              prefixIcon: const Icon(Icons.search, size: 15),
                              suffixIcon: _searchFilter.isNotEmpty
                                  ? IconButton(
                                      padding: EdgeInsets.zero,
                                      icon: const Icon(Icons.clear, size: 14),
                                      onPressed: () {
                                        _searchController.clear();
                                        setState(() => _searchFilter = '');
                                      },
                                    )
                                  : null,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        for (final cat in const [
                          ('all', '全部'),
                          ('video', '视频'),
                          ('audio', '音频'),
                          ('image', '图片'),
                          ('doc', '字幕/文档'),
                        ]) ...[
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              visualDensity: VisualDensity.compact,
                              label: Text(
                                cat.$2,
                                style: const TextStyle(fontSize: 11.5),
                              ),
                              selected: _categoryFilter == cat.$1,
                              onSelected: (_) =>
                                  setState(() => _categoryFilter = cat.$1),
                            ),
                          ),
                        ],
                        if (entries.any((e) => !e.isDir && e.isAudio)) ...[
                          const SizedBox(width: 4),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: VideoPlatformTheme.accent,
                              foregroundColor: Colors.white,
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                            ),
                            onPressed: () {
                              final firstAudio = entries
                                  .where((e) => !e.isDir && e.isAudio)
                                  .firstOrNull;
                              if (firstAudio != null) {
                                _handleDirectEntryClick(firstAudio);
                              }
                            },
                            icon: const Icon(Icons.album_rounded, size: 15),
                            label: Text(
                              '播放全部音乐 (${entries.where((e) => !e.isDir && e.isAudio).length})',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          FilledButton.tonalIcon(
                            style: FilledButton.styleFrom(
                              backgroundColor: VideoPlatformTheme.accent
                                  .withValues(alpha: 0.16),
                              foregroundColor: VideoPlatformTheme.accent,
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: () async {
                              final firstAudio = entries
                                  .where((e) => !e.isDir && e.isAudio)
                                  .firstOrNull;
                              if (firstAudio != null) {
                                await _musicController.playFromDirectory(
                                  targetTrack: firstAudio,
                                  directoryEntries: entries,
                                  mounts: _mounts,
                                  shuffle: true,
                                );
                                if (!mounted) return;
                                await _showCloudMusicFullscreenModal();
                              }
                            },
                            icon: const Icon(Icons.shuffle_rounded, size: 15),
                            label: const Text(
                              '随机播放当前音乐',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(width: 6),
                        FilledButton.tonalIcon(
                          style: FilledButton.styleFrom(
                            backgroundColor:
                                VideoPlatformTheme.accent.withValues(alpha: 0.14),
                            foregroundColor: VideoPlatformTheme.accent,
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () async {
                            await showDialog<void>(
                              context: context,
                              builder: (_) => CloudMusicFolderPickerDialog(
                                controller: _musicController,
                                initialMount: _activeMount,
                                initialPath:
                                    _listing?.path ?? _activeMount.rootPath,
                              ),
                            );
                          },
                          icon: const Icon(
                            Icons.create_new_folder_rounded,
                            size: 15,
                          ),
                          label: const Text(
                            '自选文件夹/压缩包随机播放',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            foregroundColor: VideoPlatformTheme.accent,
                          ),
                          onPressed: () => widget.appState.selectTab(9),
                          icon: const Icon(Icons.album_rounded, size: 15),
                          label: const Text(
                            '独立音乐厅',
                            style: TextStyle(fontSize: 11.5),
                          ),
                        ),
                        if (_clipboard != null) ...[
                          const SizedBox(width: 6),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: _pasteClipboardToCurrentDirectory,
                            icon: const Icon(Icons.content_paste_rounded, size: 14),
                            label: Text(
                              '粘贴 ${_clipboard!.entries.length} 项到此处',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: '清空剪贴板',
                            onPressed: () => setState(() => _clipboard = null),
                            icon: const Icon(Icons.close, size: 15),
                          ),
                        ],
                        if (_multiSelectMode && _selectedPaths.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          FilledButton.tonalIcon(
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: () {
                              final sel = entries
                                  .where((e) =>
                                      _selectedPaths.contains(e.path) &&
                                      !e.isDir)
                                  .toList();
                              setState(() {
                                _multiSelectMode = false;
                                _selectedPaths.clear();
                              });
                              for (final e in sel) {
                                _startDownloadFileWithProgress(e);
                              }
                            },
                            icon: const Icon(Icons.download_rounded, size: 14),
                            label: Text(
                              '批量下载 (${_selectedPaths.length})',
                              style: const TextStyle(fontSize: 11.5),
                            ),
                          ),
                          const SizedBox(width: 4),
                          OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: () {
                              final sel = entries
                                  .where((e) => _selectedPaths.contains(e.path))
                                  .toList();
                              _setClipboard(sel, isMove: false);
                            },
                            child: const Text('复制', style: TextStyle(fontSize: 11.5)),
                          ),
                          const SizedBox(width: 4),
                          OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: () {
                              final sel = entries
                                  .where((e) => _selectedPaths.contains(e.path))
                                  .toList();
                              _setClipboard(sel, isMove: true);
                            },
                            child: const Text('移动', style: TextStyle(fontSize: 11.5)),
                          ),
                          const SizedBox(width: 4),
                          OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              foregroundColor: VideoPlatformTheme.danger,
                            ),
                            onPressed: () {
                              final sel = entries
                                  .where((e) => _selectedPaths.contains(e.path))
                                  .toList();
                              _deleteEntriesInActiveMount(sel);
                            },
                            child: Text(
                              '删除 (${_selectedPaths.length})',
                              style: const TextStyle(fontSize: 11.5),
                            ),
                          ),
                        ],
                        const SizedBox(width: 6),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () {
                            setState(() {
                              _multiSelectMode = !_multiSelectMode;
                              if (!_multiSelectMode) _selectedPaths.clear();
                            });
                          },
                          icon: Icon(
                            _multiSelectMode
                                ? Icons.check_box_rounded
                                : Icons.check_box_outline_blank_rounded,
                            size: 15,
                          ),
                          label: Text(
                            _multiSelectMode ? '退出多选' : '多选',
                            style: const TextStyle(fontSize: 11.5),
                          ),
                        ),
                        const SizedBox(width: 6),
                        StatefulBuilder(
                          builder: (sortCtx, setSortState) {
                            return Focus(
                              canRequestFocus: false,
                              onFocusChange: (_) {
                                if (sortCtx.mounted) setSortState(() {});
                              },
                              child: Builder(
                                builder: (ctx) {
                                  final isFocused = Focus.of(ctx).hasFocus;
                                  return PopupMenuButton<String>(
                                    tooltip: '排序方式',
                                    initialValue: _sortMode,
                                    onSelected: (m) =>
                                        setState(() => _sortMode = m),
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(
                                        value: 'time_desc',
                                        child: Text('按修改时间 (最新优先)'),
                                      ),
                                      PopupMenuItem(
                                        value: 'size_desc',
                                        child: Text('按文件大小 (由大到小)'),
                                      ),
                                      PopupMenuItem(
                                        value: 'name_asc',
                                        child: Text('按文件名称 (A - Z)'),
                                      ),
                                      PopupMenuItem(
                                        value: 'type_asc',
                                        child: Text('按文件类型'),
                                      ),
                                    ],
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 9,
                                        vertical: 5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isFocused
                                            ? VideoPlatformTheme.accent
                                                .withValues(alpha: 0.34)
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(5),
                                        border: Border.all(
                                          color: isFocused
                                              ? const Color(0xFFFFE066)
                                              : VideoPlatformTheme.borderStrong,
                                          width: isFocused ? 2.0 : 1.0,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.sort_rounded,
                                            size: 15,
                                            color: isFocused
                                                ? Colors.white
                                                : VideoPlatformTheme.textPrimary,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            switch (_sortMode) {
                                              'size_desc' => '大小',
                                              'name_asc' => '名称',
                                              'type_asc' => '类型',
                                              _ => '时间',
                                            },
                                            style: TextStyle(
                                              fontSize: 11.5,
                                              fontWeight: isFocused
                                                  ? FontWeight.w700
                                                  : FontWeight.w500,
                                              color: isFocused
                                                  ? Colors.white
                                                  : VideoPlatformTheme
                                                      .textPrimary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            );
                          },
                        ),
                        const SizedBox(width: 6),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: _isGridView ? '切换为列表视图' : '切换为网格视图',
                          onPressed: () async {
                            setState(() => _isGridView = !_isGridView);
                            try {
                              final prefs =
                                  await SharedPreferences.getInstance();
                              await prefs.setBool(_prefGridViewKey, _isGridView);
                            } catch (_) {}
                          },
                          icon: Icon(
                            _isGridView
                                ? Icons.view_list_rounded
                                : Icons.grid_view_rounded,
                            size: 18,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // 4. Folder Bookmarks Strip
            if (_bookmarkedRecords.isNotEmpty)
              Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: VideoPlatformTheme.bgCard,
                  border: Border(
                    bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.bookmarks_outlined,
                      size: 14,
                      color: VideoPlatformTheme.warning,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '常用目录:',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: VideoPlatformTheme.textMuted,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _bookmarkedRecords.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 6),
                        itemBuilder: (_, idx) {
                          final rec = _bookmarkedRecords[idx];
                          final parts = rec.split('::');
                          final mId =
                              parts.length >= 3 ? parts[0] : 'builtin_server';
                          final title = parts.length >= 3
                              ? parts[1]
                              : rec.split('/').last;
                          final path = parts.length >= 3
                              ? parts.sublist(2).join('::')
                              : rec;
                          final active =
                              mId == _activeMountId && path == (_listing?.path ?? '');
                          return Center(
                            child: StatefulBuilder(
                              builder: (bmCtx, setBmState) {
                                return InkWell(
                                  borderRadius: BorderRadius.circular(5),
                                  onFocusChange: (_) {
                                    if (bmCtx.mounted) setBmState(() {});
                                  },
                                  onTap: () async {
                                    if (_activeMountId != mId) {
                                      await _switchMount(mId);
                                    }
                                    await _loadDirectory(
                                      path,
                                      folderTitleHint: title,
                                    );
                                  },
                                  onLongPress: () async {
                                    setState(
                                      () => _bookmarkedRecords.removeAt(idx),
                                    );
                                    final prefs =
                                        await SharedPreferences.getInstance();
                                    await prefs.setStringList(
                                      _prefBookmarksKey,
                                      _bookmarkedRecords,
                                    );
                                  },
                                  child: Builder(
                                    builder: (ctx) {
                                      final isFocused =
                                          Focus.of(ctx).hasPrimaryFocus;
                                      return Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 2.5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: isFocused
                                              ? VideoPlatformTheme.accent
                                                  .withValues(alpha: 0.34)
                                              : (active
                                                  ? VideoPlatformTheme.accent
                                                      .withValues(alpha: 0.16)
                                                  : VideoPlatformTheme
                                                      .bgElevated),
                                          borderRadius:
                                              BorderRadius.circular(5),
                                          border: Border.all(
                                            color: isFocused
                                                ? const Color(0xFFFFE066)
                                                : (active
                                                    ? VideoPlatformTheme.accent
                                                    : VideoPlatformTheme
                                                        .borderSubtle),
                                            width: isFocused ? 2.0 : 1.0,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.folder_special_outlined,
                                              size: 13,
                                              color: isFocused
                                                  ? Colors.white
                                                  : (active
                                                      ? VideoPlatformTheme
                                                          .accent
                                                      : VideoPlatformTheme
                                                          .warning),
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              title,
                                              style: TextStyle(
                                                fontSize: 11.5,
                                                fontWeight: (active || isFocused)
                                                    ? FontWeight.w700
                                                    : FontWeight.w500,
                                                color: isFocused
                                                    ? Colors.white
                                                    : (active
                                                        ? VideoPlatformTheme
                                                            .accent
                                                        : VideoPlatformTheme
                                                            .textPrimary),
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),

            // 5. Main File & Folder Browser Body (Direct Click to Open/Play, No cluttered row buttons!)
            Expanded(
              child: _buildMainFileBrowserBody(entries),
            ),

            // 6. Persistent Cloud Hi-Fi Music Dock Bar (supports 115 / AList / WebDAV / Server / Local audio)
            CloudMusicBottomDockBar(
              controller: _musicController,
              onExpandFullscreen: _showCloudMusicFullscreenModal,
            ),
          ],
        ),

        // Desktop Drag-and-Drop Upload Overlay
        if (_isDraggingFilesOverManager)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                color: Colors.black54,
                alignment: Alignment.center,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 24,
                  ),
                  decoration: BoxDecoration(
                    color: VideoPlatformTheme.bgElevated,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: VideoPlatformTheme.accent,
                      width: 2,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.cloud_upload_rounded,
                        size: 48,
                        color: VideoPlatformTheme.accent,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '松开鼠标即可上传文件到「${_activeMount.name}」当前目录',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMainFileBrowserBody(List<FileEntry> entries) {
    final mount = _activeMount;

    if (_isLoading) {
      return Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: VideoPlatformTheme.accent,
        ),
      );
    }

    if (mount.kind == StorageSourceKind.cloud115 &&
        !Local115DirectService.instance.hasLocalCookie) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: 48,
              color: VideoPlatformTheme.accent,
            ),
            const SizedBox(height: 12),
            const Text(
              '尚未登录 115 网盘账号',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              '扫码或粘贴 Cookie 登录后即可直接浏览您的 115 网盘文件夹并原画直连播放',
              style: TextStyle(
                fontSize: 12.5,
                color: VideoPlatformTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: () async {
                final ok = await show115QuickLoginDialog(
                  context: context,
                  api: widget.appState.api,
                );
                if (ok && mounted) {
                  await _loadDirectory('0');
                }
              },
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
              label: const Text('立即扫码登录 115 网盘'),
            ),
          ],
        ),
      );
    }

    if (_loadError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '读取目录失败：$_loadError',
              style: TextStyle(color: VideoPlatformTheme.textSecondary),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton(
                  onPressed: () => _loadDirectory(_listing?.path ?? ''),
                  child: const Text('重试'),
                ),
                if (!mount.isBuiltIn) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => _showMountStorageDialog(existing: mount),
                    child: const Text('修改挂载配置'),
                  ),
                ],
              ],
            ),
          ],
        ),
      );
    }

    if (entries.isEmpty && !_canNavigateUp) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_open_rounded,
              size: 44,
              color: VideoPlatformTheme.textMuted,
            ),
            const SizedBox(height: 8),
            Text(
              '当前目录为空',
              style: TextStyle(
                color: VideoPlatformTheme.textMuted,
                fontSize: 13.5,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _pickAndUploadFilesToCurrentMount,
                  icon: const Icon(Icons.upload_file_rounded, size: 16),
                  label: const Text('上传文件到此目录'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _showMkdirDialog,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                  label: const Text('新建文件夹'),
                ),
              ],
            ),
          ],
        ),
      );
    }

    final totalCount = entries.length + (_canNavigateUp ? 1 : 0);

    if (_isGridView) {
      return GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 190,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.08,
        ),
        itemCount: totalCount,
        itemBuilder: (_, rawIdx) {
          if (_canNavigateUp && rawIdx == 0) {
            return StatefulBuilder(
              builder: (upCtx, setUpState) {
                return InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onFocusChange: (_) {
                    if (upCtx.mounted) setUpState(() {});
                  },
                  onTap: _navigateUp,
                  child: Builder(
                    builder: (ctx) {
                      final isFocused = Focus.of(ctx).hasPrimaryFocus;
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isFocused
                              ? VideoPlatformTheme.accent
                                  .withValues(alpha: 0.28)
                              : VideoPlatformTheme.bgCard,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isFocused
                                ? const Color(0xFFFFE066)
                                : VideoPlatformTheme.borderSubtle,
                            width: isFocused ? 2.4 : 1.0,
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.drive_folder_upload_rounded,
                              size: 36,
                              color: isFocused
                                  ? Colors.white
                                  : VideoPlatformTheme.warning,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '.. 返回上级目录',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: isFocused
                                    ? Colors.white
                                    : VideoPlatformTheme.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                );
              },
            );
          }

          final entry = entries[_canNavigateUp ? rawIdx - 1 : rawIdx];
          final checked = _selectedPaths.contains(entry.path);
          return StatefulBuilder(
            builder: (gridCtx, setGridState) {
              return InkWell(
                borderRadius: BorderRadius.circular(12),
                onFocusChange: (_) {
                  if (gridCtx.mounted) setGridState(() {});
                },
                onTap: () => _handleDirectEntryClick(entry),
                onLongPress: () => _showFileActionSheet(entry),
                onSecondaryTap: () => _showFileActionSheet(entry),
                child: Builder(
                  builder: (ctx) {
                    final isFocused = Focus.of(ctx).hasPrimaryFocus;
                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isFocused
                            ? VideoPlatformTheme.accent.withValues(alpha: 0.28)
                            : (checked
                                ? VideoPlatformTheme.accent
                                    .withValues(alpha: 0.16)
                                : VideoPlatformTheme.bgCard),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isFocused
                              ? const Color(0xFFFFE066)
                              : (checked
                                  ? VideoPlatformTheme.accent
                                  : VideoPlatformTheme.borderSubtle),
                          width: isFocused ? 2.4 : 1.0,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Stack(
                            alignment: Alignment.topRight,
                            children: [
                              Center(
                                child: Icon(
                                  _iconForEntry(entry),
                                  size: 38,
                                  color: _colorForEntry(entry),
                                ),
                              ),
                              if (_multiSelectMode)
                                Icon(
                                  checked
                                      ? Icons.check_circle_rounded
                                      : Icons.radio_button_unchecked_rounded,
                                  size: 18,
                                  color: checked
                                      ? VideoPlatformTheme.accent
                                      : VideoPlatformTheme.textMuted,
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            entry.name,
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: isFocused
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                              color: isFocused
                                  ? Colors.white
                                  : VideoPlatformTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            entry.isDir
                                ? '文件夹'
                                : '${entry.typeTagText} · ${entry.formattedSize}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: isFocused
                                  ? Colors.white70
                                  : VideoPlatformTheme.textMuted,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      );
    }

    // Standard List View Mode — Clicking anywhere on a row directly enters the folder or plays/previews the file!
    return ListView.separated(
      padding: const EdgeInsets.all(14),
      itemCount: totalCount,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, rawIdx) {
        if (_canNavigateUp && rawIdx == 0) {
          return StatefulBuilder(
            builder: (upTileCtx, setUpTileState) {
              return Focus(
                canRequestFocus: false,
                onFocusChange: (_) {
                  if (upTileCtx.mounted) setUpTileState(() {});
                },
                child: Builder(
                  builder: (ctx) {
                    final isFocused = Focus.of(ctx).hasFocus;
                    return Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: isFocused
                            ? Border.all(
                                color: const Color(0xFFFFE066),
                                width: 2.2,
                              )
                            : null,
                      ),
                      child: ListTile(
                        dense: true,
                        focusColor: VideoPlatformTheme.accent
                            .withValues(alpha: 0.28),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        leading: Icon(
                          Icons.drive_folder_upload_rounded,
                          color: VideoPlatformTheme.warning,
                          size: 23,
                        ),
                        title: const Text(
                          '.. (返回上级目录)',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: Text(
                          '点击直接返回上一层文件夹',
                          style: TextStyle(
                            fontSize: 11,
                            color: VideoPlatformTheme.textMuted,
                          ),
                        ),
                        trailing: Icon(
                          Icons.chevron_right_rounded,
                          size: 18,
                          color: VideoPlatformTheme.textMuted,
                        ),
                        onTap: _navigateUp,
                      ),
                    );
                  },
                ),
              );
            },
          );
        }

        final entry = entries[_canNavigateUp ? rawIdx - 1 : rawIdx];
        final checked = _selectedPaths.contains(entry.path);

        return GestureDetector(
          onSecondaryTap: () => _showFileActionSheet(entry),
          child: StatefulBuilder(
            builder: (tileCtx, setTileState) {
              return Focus(
                canRequestFocus: false,
                onFocusChange: (_) {
                  if (tileCtx.mounted) setTileState(() {});
                },
                child: Builder(
                  builder: (ctx) {
                    final isFocused = Focus.of(ctx).hasFocus;
                    return Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: isFocused
                            ? Border.all(
                                color: const Color(0xFFFFE066),
                                width: 2.2,
                              )
                            : null,
                      ),
                      child: ListTile(
                        dense: true,
                        selected: checked,
                        focusColor: VideoPlatformTheme.accent
                            .withValues(alpha: 0.28),
                        selectedTileColor: VideoPlatformTheme.accent
                            .withValues(alpha: 0.14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        leading: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_multiSelectMode) ...[
                              Icon(
                                checked
                                    ? Icons.check_circle_rounded
                                    : Icons.radio_button_unchecked_rounded,
                                size: 18,
                                color: checked
                                    ? VideoPlatformTheme.accent
                                    : VideoPlatformTheme.textMuted,
                              ),
                              const SizedBox(width: 8),
                            ],
                            Icon(
                              _iconForEntry(entry),
                              color: _colorForEntry(entry),
                              size: 23,
                            ),
                          ],
                        ),
                        title: Text(
                          entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: isFocused
                                ? FontWeight.w700
                                : FontWeight.w600,
                            color: isFocused
                                ? Colors.white
                                : VideoPlatformTheme.textPrimary,
                          ),
                        ),
                        subtitle: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 0.5,
                              ),
                              decoration: BoxDecoration(
                                color: _colorForEntry(entry)
                                    .withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                entry.typeTagText,
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w700,
                                  color: _colorForEntry(entry),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                entry.modTime.isEmpty
                                    ? (entry.isDir
                                        ? '点击进入文件夹'
                                        : entry.formattedSize)
                                    : entry.modTime,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: isFocused
                                      ? Colors.white70
                                      : VideoPlatformTheme.textMuted,
                                ),
                              ),
                            ),
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              entry.formattedSize,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: isFocused
                                    ? Colors.white
                                    : VideoPlatformTheme.textSecondary,
                              ),
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              tooltip:
                                  '文件操作菜单 (下载 / 上传 / 重命名 / 复制 / 删除)',
                              onPressed: () => _showFileActionSheet(entry),
                              icon: Icon(
                                Icons.more_horiz_rounded,
                                size: 18,
                                color: VideoPlatformTheme.textMuted,
                              ),
                            ),
                          ],
                        ),
                        onTap: () => _handleDirectEntryClick(entry),
                        onLongPress: () => _showFileActionSheet(entry),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// Cross-platform Local File Picker Fallback Dialog for File Manager Upload
class _LocalFileUploadPickerDialog extends StatefulWidget {
  const _LocalFileUploadPickerDialog();

  @override
  State<_LocalFileUploadPickerDialog> createState() =>
      _LocalFileUploadPickerDialogState();
}

class _LocalFileUploadPickerDialogState
    extends State<_LocalFileUploadPickerDialog> {
  late final TextEditingController _dirCtrl;
  List<FileSystemEntity> _entries = [];
  final Set<String> _selectedPaths = {};

  @override
  void initState() {
    super.initState();
    final initial = RemoteStorageService.defaultLocalDownloadsRoot();
    _dirCtrl = TextEditingController(text: initial);
    _listDir(initial);
  }

  @override
  void dispose() {
    _dirCtrl.dispose();
    super.dispose();
  }

  void _listDir(String path) {
    try {
      final dir = Directory(path);
      if (!dir.existsSync()) return;
      final list = dir.listSync()
        ..sort((a, b) {
          final aDir = a is Directory ? 0 : 1;
          final bDir = b is Directory ? 0 : 1;
          if (aDir != bDir) return aDir.compareTo(bDir);
          return a.path.toLowerCase().compareTo(b.path.toLowerCase());
        });
      setState(() {
        _dirCtrl.text = dir.path;
        _entries = list.where((e) {
          final name = e.path.split(Platform.pathSeparator).last;
          return !name.startsWith('.');
        }).toList();
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: VideoPlatformTheme.bgElevated,
      title: const Text('选择本机要上传的文件', style: TextStyle(fontSize: 15.5)),
      content: SizedBox(
        width: 560,
        height: 440,
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () =>
                      _listDir(Directory(_dirCtrl.text).parent.path),
                  icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                ),
                Expanded(
                  child: TextField(
                    controller: _dirCtrl,
                    onSubmitted: _listDir,
                    decoration: const InputDecoration(
                      labelText: '当前本机目录路径',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: _entries.length,
                itemBuilder: (_, idx) {
                  final e = _entries[idx];
                  final isDir = e is Directory;
                  final name = e.path.split(Platform.pathSeparator).last;
                  final checked = _selectedPaths.contains(e.path);
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      isDir
                          ? Icons.folder_rounded
                          : Icons.insert_drive_file_outlined,
                      color: isDir
                          ? VideoPlatformTheme.warning
                          : VideoPlatformTheme.accent,
                    ),
                    title: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                    trailing: isDir
                        ? null
                        : Checkbox(
                            value: checked,
                            onChanged: (_) {
                              setState(() {
                                if (checked) {
                                  _selectedPaths.remove(e.path);
                                } else {
                                  _selectedPaths.add(e.path);
                                }
                              });
                            },
                          ),
                    onTap: () {
                      if (isDir) {
                        _listDir(e.path);
                      } else {
                        setState(() {
                          if (checked) {
                            _selectedPaths.remove(e.path);
                          } else {
                            _selectedPaths.add(e.path);
                          }
                        });
                      }
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selectedPaths.toList()),
          child: Text('开始上传 (${_selectedPaths.length})'),
        ),
      ],
    );
  }
}

class _MediaFilePlayerDialog extends StatefulWidget {
  final ApiClient api;
  final String title;
  final String streamUrl;
  final Map<String, String> headers;
  final ValueChanged<int>? onEnterMiniPlayer;

  const _MediaFilePlayerDialog({
    required this.api,
    required this.title,
    required this.streamUrl,
    required this.headers,
    this.onEnterMiniPlayer,
  });

  @override
  State<_MediaFilePlayerDialog> createState() => _MediaFilePlayerDialogState();
}

class _MediaFilePlayerDialogState extends State<_MediaFilePlayerDialog> {
  late final Player _player;
  late final VideoController _controller;
  double _rate = 1.0;
  String _fitMode = 'fit'; // 'fit', 'cover'
  bool? _landscapeOverride;
  bool _didChangeOrientation = false;
  bool _using115Direct = false;

  @override
  void initState() {
    super.initState();
    _player = Player(
      configuration: PlayerConfiguration(
        bufferSize: (Platform.isAndroid || Platform.isIOS)
            ? 32 * 1024 * 1024
            : 128 * 1024 * 1024,
      ),
    );
    _controller = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        hwdec: Platform.isAndroid ? 'no' : null,
        enableHardwareAcceleration: !Platform.isAndroid,
      ),
    );
    _configureMediaPlayer();
    _player.open(
      Media(widget.streamUrl, httpHeaders: widget.headers),
      play: true,
    );
  }

  Future<void> _configureMediaPlayer() async {
    try {
      final dynamic platform = _player.platform;
      final isMobileOrTv = Platform.isAndroid || Platform.isIOS;
      final props = <String, String>{
        'hwdec': Platform.isAndroid ? 'no' : 'auto-safe',
        'hwdec-codecs': 'h264,hevc,vp8,vp9,av1',
        'vd-lavc-software-fallback': 'yes',
        'vd-lavc-threads': Platform.isAndroid ? '4' : '0',
        'cache': 'yes',
        'cache-secs': isMobileOrTv ? '45' : '120',
        'cache-pause-initial': 'no',
        'cache-pause-wait': '0.8',
        'demuxer-max-bytes': isMobileOrTv ? '50331648' : '134217728',
        'demuxer-readahead-secs': isMobileOrTv ? '30' : '60',
        'stream-buffer-size': '524288',
        'tls-verify': 'no',
      };
      for (final entry in props.entries) {
        await platform.setProperty(entry.key, entry.value);
      }
    } catch (_) {}
  }

  void _toggleOrientation() {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    final mq = MediaQuery.maybeSizeOf(context);
    final isLandscape =
        _landscapeOverride ?? (mq != null && mq.width > mq.height);
    final nextLandscape = !isLandscape;
    setState(() {
      _landscapeOverride = nextLandscape;
      _didChangeOrientation = true;
    });
    if (nextLandscape) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
    }
  }

  @override
  void dispose() {
    if (_didChangeOrientation && (Platform.isAndroid || Platform.isIOS)) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(const []);
    }
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mqSize = MediaQuery.sizeOf(context);
    final isMobileDialog = mqSize.shortestSide < 600 || mqSize.width < 760;

    return MobileEdgeSwipeBack(
      onBack: () => Navigator.of(context).pop(),
      child: Dialog(
        backgroundColor: Colors.black,
        insetPadding:
            isMobileDialog ? EdgeInsets.zero : const EdgeInsets.all(14),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: isMobileDialog ? double.infinity : 1200,
            maxHeight: isMobileDialog ? double.infinity : 820,
          ),
          child: Column(
            children: [
              Container(
                height: 46,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: VideoPlatformTheme.bgElevated,
                  border: Border(
                    bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Video115AccelerateButton(
                      api: widget.api,
                      downloadUrlBuilder: () => widget.streamUrl,
                      videoNameBuilder: () => widget.title,
                      headersBuilder: () => widget.headers,
                      isUsing115Direct: _using115Direct,
                      compact: true,
                      overlayStyle: false,
                      onResolved: (resolved) async {
                        if (!mounted) return;
                        final curSec = _player.state.position.inSeconds;
                        setState(() => _using115Direct = true);
                        await _player.open(
                          Media(
                            resolved.proxyStreamUrl,
                            httpHeaders:
                                resolved.proxyStreamUrl.contains('127.0.0.1')
                                    ? const {}
                                    : resolved.headers,
                            start: curSec > 2
                                ? Duration(seconds: curSec)
                                : null,
                          ),
                          play: true,
                        );
                        if (_rate != 1.0) {
                          await _player.setRate(_rate);
                        }
                      },
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: '快退 10 秒',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.replay_10_rounded, size: 18),
                      onPressed: () {
                        final pos = _player.state.position;
                        final target = pos - const Duration(seconds: 10);
                        _player.seek(
                          target < Duration.zero ? Duration.zero : target,
                        );
                      },
                    ),
                    IconButton(
                      tooltip: '快进 10 秒',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.forward_10_rounded, size: 18),
                      onPressed: () {
                        final pos = _player.state.position;
                        _player.seek(pos + const Duration(seconds: 10));
                      },
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        setState(() {
                          _fitMode = _fitMode == 'fit' ? 'cover' : 'fit';
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        child: Text(
                          _fitMode == 'cover' ? '铺满' : '适应',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: _fitMode == 'cover'
                                ? VideoPlatformTheme.accent
                                : VideoPlatformTheme.textSecondary,
                          ),
                        ),
                      ),
                    ),
                    if (Platform.isAndroid || Platform.isIOS)
                      IconButton(
                        tooltip: '横竖屏切换',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(
                          Icons.screen_rotation_rounded,
                          size: 17,
                        ),
                        onPressed: _toggleOrientation,
                      ),
                    PopupMenuButton<double>(
                      tooltip: '倍速播放',
                      initialValue: _rate,
                      onSelected: (r) {
                        setState(() => _rate = r);
                        _player.setRate(r);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 0.75, child: Text('0.75x')),
                        PopupMenuItem(value: 1.0, child: Text('1.0x 正常')),
                        PopupMenuItem(value: 1.25, child: Text('1.25x')),
                        PopupMenuItem(value: 1.5, child: Text('1.5x')),
                        PopupMenuItem(value: 2.0, child: Text('2.0x')),
                        PopupMenuItem(value: 3.0, child: Text('3.0x')),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          '${_rate}x',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: VideoPlatformTheme.accent,
                          ),
                        ),
                      ),
                    ),
                    if (!isMobileDialog) ...[
                      VideoDownloadSpeedBadge(
                        player: _player,
                        compact: true,
                        backgroundColor: VideoPlatformTheme.bgCard,
                      ),
                      const SizedBox(width: 4),
                    ],
                    if (widget.onEnterMiniPlayer != null)
                      IconButton(
                        tooltip: '转入右下角小窗悬浮播放',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(
                          Icons.picture_in_picture_alt_rounded,
                          size: 18,
                        ),
                        onPressed: () {
                          final posSec = _player.state.position.inSeconds;
                          Navigator.of(context).pop();
                          widget.onEnterMiniPlayer!(posSec);
                        },
                      ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, stageConstraints) {
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        Video(
                          controller: _controller,
                          width: stageConstraints.maxWidth,
                          height: stageConstraints.maxHeight,
                          fit: _fitMode == 'cover'
                              ? BoxFit.cover
                              : BoxFit.contain,
                          fill: Colors.black,
                        ),
                        Positioned(
                          top: 12,
                          right: 12,
                          child: VideoDownloadSpeedBadge(player: _player),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MediaImagePreviewDialog extends StatelessWidget {
  final String title;
  final String imageUrl;
  final Map<String, String> headers;
  final bool isLocalFile;

  const _MediaImagePreviewDialog({
    required this.title,
    required this.imageUrl,
    required this.headers,
    this.isLocalFile = false,
  });

  @override
  Widget build(BuildContext context) {
    final mqSize = MediaQuery.sizeOf(context);
    final isMobileDialog = mqSize.shortestSide < 600 || mqSize.width < 760;
    return MobileEdgeSwipeBack(
      onBack: () => Navigator.of(context).pop(),
      child: Dialog(
        insetPadding:
            isMobileDialog ? EdgeInsets.zero : const EdgeInsets.all(20),
        backgroundColor: VideoPlatformTheme.bgElevated,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: isMobileDialog ? double.infinity : 1080,
            maxHeight: isMobileDialog ? double.infinity : 780,
          ),
          child: Column(
            children: [
              Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  color: Colors.black,
                  width: double.infinity,
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 5.0,
                    child: isLocalFile
                        ? Image.file(
                            File(imageUrl),
                            fit: BoxFit.contain,
                          )
                        : Image.network(
                            imageUrl,
                            headers: headers,
                            fit: BoxFit.contain,
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
