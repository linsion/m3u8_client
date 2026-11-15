import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/models.dart';
import '../../state/app_state.dart';
import '../theme.dart';
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
  static const String _prefBookmarksKey = 'm3u8_media_folder_bookmarks_v1';

  String _searchFilter = '';
  String _sortMode = 'time_desc'; // 'time_desc', 'size_desc', 'name_asc'
  List<String> _bookmarkedPaths = [];
  final Map<String, double> _localDownloadProgress = {};

  @override
  void initState() {
    super.initState();
    _loadBookmarks();
    if (widget.appState.currentDirectory == null &&
        !widget.appState.isLoadingFiles) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.appState.loadFiles();
      });
    }
  }

  Future<void> _loadBookmarks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_prefBookmarksKey);
      if (list != null && mounted) {
        setState(() => _bookmarkedPaths = list);
      }
    } catch (_) {}
  }

  Future<void> _toggleBookmark(String path) async {
    final clean = path.trim();
    if (clean.isEmpty) return;
    setState(() {
      if (_bookmarkedPaths.contains(clean)) {
        _bookmarkedPaths.remove(clean);
      } else {
        _bookmarkedPaths.add(clean);
      }
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefBookmarksKey, _bookmarkedPaths);
    } catch (_) {}
  }

  bool _isImageEntry(FileEntry entry) {
    const exts = {'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'};
    return exts.contains(entry.ext.toLowerCase());
  }

  bool _isTextEntry(FileEntry entry) {
    const exts = {
      '.txt',
      '.log',
      '.srt',
      '.ass',
      '.vtt',
      '.json',
      '.md',
      '.conf',
      '.yaml',
      '.yml',
      '.m3u',
      '.m3u8',
      '.ini',
      '.sh',
    };
    return exts.contains(entry.ext.toLowerCase());
  }

  void _openEntry(FileEntry entry, {bool inMiniPlayer = false}) {
    if (entry.isDir) {
      widget.appState.loadFiles(path: entry.path);
      return;
    }
    final streamUrl = widget.appState.api.buildFileStreamUrl(entry.path);
    final headers = widget.appState.api.authHeaders;

    if (entry.isPlayableVideo) {
      if (inMiniPlayer) {
        widget.appState.startMiniPlayer(
          MiniPlayerSession(
            title: entry.name,
            subtitle: '媒体库 · ${entry.formattedSize}',
            streamUrl: streamUrl,
            headers: headers,
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
      showDialog<void>(
        context: context,
        builder: (_) => _MediaFilePlayerDialog(
          title: entry.name,
          streamUrl: streamUrl,
          headers: headers,
          onEnterMiniPlayer: (posSec) {
            widget.appState.startMiniPlayer(
              MiniPlayerSession(
                title: entry.name,
                subtitle: '媒体库 · ${entry.formattedSize}',
                streamUrl: streamUrl,
                headers: headers,
                initialPositionSeconds: posSec,
              ),
            );
          },
        ),
      );
      return;
    }

    if (_isImageEntry(entry)) {
      showDialog<void>(
        context: context,
        builder: (_) => _MediaImagePreviewDialog(
          title: entry.name,
          imageUrl: streamUrl,
          headers: headers,
        ),
      );
      return;
    }

    if (_isTextEntry(entry)) {
      _showTextFilePreview(entry);
      return;
    }

    final downloadUrl = widget.appState.api.buildFileDownloadUrl(entry.path);
    final uri = Uri.tryParse(downloadUrl);
    if (uri != null) {
      launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _showTextFilePreview(FileEntry entry) async {
    final url = widget.appState.api.buildFileDownloadUrl(entry.path);
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    final client = HttpClient()
      ..badCertificateCallback = (_, __, ___) => true;
    try {
      final req = await client.getUrl(uri);
      widget.appState.api.authHeaders.forEach(req.headers.set);
      final resp = await req.close();
      final bytes = await resp.fold<List<int>>(
        <int>[],
        (acc, chunk) {
          if (acc.length < 256 * 1024) {
            acc.addAll(chunk);
          }
          return acc;
        },
      );
      final content = utf8.decode(bytes, allowMalformed: true);
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
            width: 720,
            height: 460,
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
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _downloadEntryToLocal(FileEntry entry) async {
    if (_localDownloadProgress.containsKey(entry.path)) return;
    final url = widget.appState.api.buildFileDownloadUrl(entry.path);
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    setState(() => _localDownloadProgress[entry.path] = 0.01);
    final client = HttpClient()
      ..badCertificateCallback = (_, __, ___) => true;

    try {
      final req = await client.getUrl(uri);
      widget.appState.api.authHeaders.forEach(req.headers.set);
      final resp = await req.close();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final totalBytes = resp.contentLength;
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          Directory.systemTemp.path;
      final downloadsDir = Directory('$home${Platform.pathSeparator}Downloads');
      final targetDir =
          await downloadsDir.exists() ? downloadsDir : Directory.systemTemp;
      final safeName = entry.name.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
      final outPath = '${targetDir.path}${Platform.pathSeparator}$safeName';
      final sink = File(outPath).openWrite();
      int received = 0;

      await for (final chunk in resp) {
        sink.add(chunk);
        received += chunk.length;
        if (totalBytes > 0 && mounted) {
          setState(() {
            _localDownloadProgress[entry.path] =
                (received / totalBytes).clamp(0.01, 0.99);
          });
        }
      }
      await sink.flush();
      await sink.close();
      if (!mounted) return;
      setState(() => _localDownloadProgress.remove(entry.path));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已下载到本机：$outPath')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _localDownloadProgress.remove(entry.path));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载失败：$e')),
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _showMkdirDialog(String currentPath) async {
    final ctrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建文件夹', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '请输入文件夹名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final name = ctrl.text.trim();
              if (name.isEmpty) return;
              final messenger = ScaffoldMessenger.of(context);
              Navigator.of(ctx).pop();
              try {
                await widget.appState.api.createDirectory(currentPath, name);
                await widget.appState.loadFiles(path: currentPath);
              } catch (e) {
                if (mounted) {
                  messenger.showSnackBar(
                    SnackBar(content: Text('新建文件夹失败：$e')),
                  );
                }
              }
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  Future<void> _showRenameDialog(FileEntry entry, String currentPath) async {
    final ctrl = TextEditingController(text: entry.name);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '请输入新名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final newName = ctrl.text.trim();
              if (newName.isEmpty || newName == entry.name) return;
              final messenger = ScaffoldMessenger.of(context);
              Navigator.of(ctx).pop();
              try {
                await widget.appState.api.renameFile(entry.path, newName);
                await widget.appState.loadFiles(path: currentPath);
              } catch (e) {
                if (mounted) {
                  messenger.showSnackBar(
                    SnackBar(content: Text('重命名失败：$e')),
                  );
                }
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  List<FileEntry> _getFilteredAndSortedEntries(List<FileEntry> raw) {
    final kw = _searchFilter.trim().toLowerCase();
    final filtered = raw.where((e) {
      if (kw.isEmpty) return true;
      return e.name.toLowerCase().contains(kw);
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
        case 'time_desc':
        default:
          return b.modTime.compareTo(a.modTime);
      }
    });
    return filtered;
  }

  Widget _buildClickablePathBreadcrumbs(AppState state, String currentPath) {
    final parts = currentPath
        .split('/')
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
            InkWell(
              onTap: () => state.loadFiles(path: ''),
              child: Text(
                '/ 根目录',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight:
                      parts.isEmpty ? FontWeight.w600 : FontWeight.w400,
                  color: parts.isEmpty
                      ? VideoPlatformTheme.textPrimary
                      : VideoPlatformTheme.accent,
                ),
              ),
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
              InkWell(
                onTap: () {
                  final targetPath = parts.sublist(0, i + 1).join('/');
                  state.loadFiles(path: targetPath);
                },
                child: Text(
                  parts[i],
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: i == parts.length - 1
                        ? FontWeight.w600
                        : FontWeight.w400,
                    color: i == parts.length - 1
                        ? VideoPlatformTheme.textPrimary
                        : VideoPlatformTheme.accent,
                  ),
                ),
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
    final dir = state.currentDirectory;
    final currentPath = dir?.path ?? '';
    final isBookmarked =
        currentPath.isNotEmpty && _bookmarkedPaths.contains(currentPath);

    final entries =
        _getFilteredAndSortedEntries(dir?.entries ?? const <FileEntry>[]);

    return Column(
      children: [
        // Top toolbar (responsive: 2 rows on compact mobile, 1 row on desktop)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: VideoPlatformTheme.bgElevated,
            border: Border(
              bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isCompact = constraints.maxWidth < 680;
              final sortButton = PopupMenuButton<String>(
                tooltip: '排序方式',
                initialValue: _sortMode,
                onSelected: (m) => setState(() => _sortMode = m),
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
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: VideoPlatformTheme.borderStrong),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.sort_rounded, size: 15),
                      const SizedBox(width: 4),
                      Text(
                        _sortMode == 'size_desc'
                            ? '大小'
                            : (_sortMode == 'name_asc' ? '名称' : '时间'),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              );

              if (isCompact) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: '返回上级目录',
                          onPressed: currentPath.isEmpty
                              ? null
                              : () => state.loadFiles(path: dir?.parent ?? ''),
                          icon:
                              const Icon(Icons.arrow_upward_rounded, size: 18),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: '根目录',
                          onPressed: () => state.loadFiles(path: ''),
                          icon: const Icon(Icons.home_outlined, size: 18),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: _buildClickablePathBreadcrumbs(
                            state,
                            currentPath,
                          ),
                        ),
                        if (currentPath.isNotEmpty)
                          IconButton(
                            tooltip:
                                isBookmarked ? '取消收藏此目录' : '收藏此目录到书签栏',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => _toggleBookmark(currentPath),
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
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: '刷新目录',
                          onPressed: () => state.loadFiles(path: currentPath),
                          icon: const Icon(Icons.refresh, size: 18),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 34,
                            child: TextField(
                              onChanged: (v) =>
                                  setState(() => _searchFilter = v),
                              style: const TextStyle(fontSize: 12.5),
                              decoration: const InputDecoration(
                                hintText: '过滤当前目录...',
                                prefixIcon: Icon(Icons.search, size: 16),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        sortButton,
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: () => _showMkdirDialog(currentPath),
                          icon: const Icon(
                            Icons.create_new_folder_outlined,
                            size: 15,
                          ),
                          label: const Text('新建目录'),
                        ),
                      ],
                    ),
                  ],
                );
              }

              return Row(
                children: [
                  IconButton(
                    tooltip: '返回上级目录',
                    onPressed: currentPath.isEmpty
                        ? null
                        : () => state.loadFiles(path: dir?.parent ?? ''),
                    icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                  ),
                  IconButton(
                    tooltip: '根目录',
                    onPressed: () => state.loadFiles(path: ''),
                    icon: const Icon(Icons.home_outlined, size: 18),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _buildClickablePathBreadcrumbs(state, currentPath),
                  ),
                  if (currentPath.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: isBookmarked ? '取消收藏此目录' : '收藏此目录到书签栏',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _toggleBookmark(currentPath),
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
                  ],
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 180,
                    child: TextField(
                      onChanged: (v) => setState(() => _searchFilter = v),
                      decoration: const InputDecoration(
                        hintText: '过滤当前目录...',
                        prefixIcon: Icon(Icons.search, size: 16),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  sortButton,
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () => _showMkdirDialog(currentPath),
                    icon:
                        const Icon(Icons.create_new_folder_outlined, size: 16),
                    label: const Text('新建目录'),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: '刷新目录',
                    onPressed: () => state.loadFiles(path: currentPath),
                    icon: const Icon(Icons.refresh, size: 18),
                  ),
                ],
              );
            },
          ),
        ),

        // Folder Bookmarks Strip
        if (_bookmarkedPaths.isNotEmpty)
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 16),
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
                    itemCount: _bookmarkedPaths.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (_, idx) {
                      final bp = _bookmarkedPaths[idx];
                      final label = bp.contains('/')
                          ? bp.split('/').last
                          : bp;
                      final active = bp == currentPath;
                      return Center(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(5),
                          onTap: () => state.loadFiles(path: bp),
                          onLongPress: () => _toggleBookmark(bp),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: active
                                  ? VideoPlatformTheme.accent
                                      .withValues(alpha: 0.16)
                                  : VideoPlatformTheme.bgElevated,
                              borderRadius: BorderRadius.circular(5),
                              border: Border.all(
                                color: active
                                    ? VideoPlatformTheme.accent
                                    : VideoPlatformTheme.borderSubtle,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.folder_special_outlined,
                                  size: 13,
                                  color: active
                                      ? VideoPlatformTheme.accent
                                      : VideoPlatformTheme.warning,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: active
                                        ? VideoPlatformTheme.accent
                                        : VideoPlatformTheme.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),

        Expanded(
          child: state.isLoadingFiles
              ? Center(
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: VideoPlatformTheme.accent,
                  ),
                )
              : state.filesError != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '读取目录失败：${state.filesError}',
                            style: TextStyle(
                              color: VideoPlatformTheme.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 10),
                          FilledButton(
                            onPressed: () => state.loadFiles(path: currentPath),
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    )
                  : entries.isEmpty
                      ? Center(
                          child: Text(
                            '此目录下暂无媒体文件',
                            style: TextStyle(
                              color: VideoPlatformTheme.textMuted,
                              fontSize: 13,
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: entries.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, idx) {
                            final entry = entries[idx];
                            final dlProgress =
                                _localDownloadProgress[entry.path];

                            return ListTile(
                              dense: true,
                              leading: Icon(
                                entry.isDir
                                    ? Icons.folder_rounded
                                    : (entry.isPlayableVideo
                                        ? Icons.play_circle_fill_rounded
                                        : (_isImageEntry(entry)
                                            ? Icons.image_outlined
                                            : Icons.insert_drive_file_outlined)),
                                color: entry.isDir
                                    ? VideoPlatformTheme.warning
                                    : (entry.isPlayableVideo
                                        ? VideoPlatformTheme.accent
                                        : VideoPlatformTheme.textMuted),
                                size: 22,
                              ),
                              title: Text(
                                entry.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: VideoPlatformTheme.textPrimary,
                                ),
                              ),
                              subtitle: Text(
                                '${entry.formattedSize}  ${entry.modTime}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: VideoPlatformTheme.textMuted,
                                ),
                              ),
                              trailing: Wrap(
                                spacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  if (!entry.isDir && entry.isPlayableVideo) ...[
                                    TextButton.icon(
                                      onPressed: () => _openEntry(entry),
                                      icon: const Icon(
                                        Icons.play_arrow_rounded,
                                        size: 16,
                                      ),
                                      label: const Text('播放'),
                                    ),
                                    IconButton(
                                      tooltip: '小窗悬浮播放',
                                      visualDensity: VisualDensity.compact,
                                      onPressed: () =>
                                          _openEntry(entry, inMiniPlayer: true),
                                      icon: const Icon(
                                        Icons.picture_in_picture_alt_rounded,
                                        size: 16,
                                      ),
                                    ),
                                  ],
                                  if (!entry.isDir &&
                                      (_isImageEntry(entry) ||
                                          _isTextEntry(entry)))
                                    TextButton(
                                      onPressed: () => _openEntry(entry),
                                      child: const Text('预览'),
                                    ),
                                  if (!entry.isDir &&
                                      entry.ext.toLowerCase() == '.ts')
                                    TextButton(
                                      onPressed: () async {
                                        final messenger =
                                            ScaffoldMessenger.of(context);
                                        try {
                                          await state.api
                                              .convertFileToMp4(entry.path);
                                          messenger.showSnackBar(
                                            const SnackBar(
                                              content: Text('已提交转封装 MP4 任务'),
                                            ),
                                          );
                                        } catch (e) {
                                          messenger.showSnackBar(
                                            SnackBar(
                                              content: Text('转码失败：$e'),
                                            ),
                                          );
                                        }
                                      },
                                      child: const Text('转MP4'),
                                    ),
                                  if (!entry.isDir)
                                    TextButton(
                                      onPressed: () async {
                                        final messenger =
                                            ScaffoldMessenger.of(context);
                                        try {
                                          await state.api
                                              .uploadFileTo115(entry.path);
                                          messenger.showSnackBar(
                                            const SnackBar(
                                              content: Text('已提交上传 115 任务'),
                                            ),
                                          );
                                        } catch (e) {
                                          messenger.showSnackBar(
                                            SnackBar(
                                              content: Text('上传 115 失败：$e'),
                                            ),
                                          );
                                        }
                                      },
                                      child: const Text('上传115'),
                                    ),
                                  if (!entry.isDir)
                                    dlProgress != null
                                        ? Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                            ),
                                            child: Text(
                                              '${(dlProgress * 100).toInt()}%',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color:
                                                    VideoPlatformTheme.accent,
                                              ),
                                            ),
                                          )
                                        : IconButton(
                                            tooltip: '下载到本机 ~/Downloads',
                                            visualDensity:
                                                VisualDensity.compact,
                                            icon: const Icon(
                                              Icons.download_for_offline_outlined,
                                              size: 17,
                                            ),
                                            onPressed: () =>
                                                _downloadEntryToLocal(entry),
                                          ),
                                  IconButton(
                                    tooltip: '重命名',
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(
                                      Icons.drive_file_rename_outline,
                                      size: 17,
                                    ),
                                    onPressed: () =>
                                        _showRenameDialog(entry, currentPath),
                                  ),
                                  IconButton(
                                    tooltip: '删除',
                                    visualDensity: VisualDensity.compact,
                                    icon: Icon(
                                      Icons.delete_outline,
                                      size: 17,
                                      color: VideoPlatformTheme.textMuted,
                                    ),
                                    onPressed: () async {
                                      await state.api.deleteFile(entry.path);
                                      await state.loadFiles(path: currentPath);
                                    },
                                  ),
                                ],
                              ),
                              onTap: () => _openEntry(entry),
                            );
                          },
                        ),
        ),
      ],
    );
  }
}

class _MediaFilePlayerDialog extends StatefulWidget {
  final String title;
  final String streamUrl;
  final Map<String, String> headers;
  final ValueChanged<int>? onEnterMiniPlayer;

  const _MediaFilePlayerDialog({
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

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _player.open(
      Media(widget.streamUrl, httpHeaders: widget.headers),
      play: true,
    );
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960, maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 16),
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
                  IconButton(
                    tooltip: '快退 10 秒',
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
                    icon: const Icon(Icons.forward_10_rounded, size: 18),
                    onPressed: () {
                      final pos = _player.state.position;
                      _player.seek(pos + const Duration(seconds: 10));
                    },
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
                      padding: const EdgeInsets.symmetric(horizontal: 8),
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
                  VideoDownloadSpeedBadge(
                    player: _player,
                    compact: true,
                    backgroundColor: VideoPlatformTheme.bgCard,
                  ),
                  const SizedBox(width: 6),
                  if (widget.onEnterMiniPlayer != null)
                    IconButton(
                      tooltip: '转入右下角小窗悬浮播放',
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
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Flexible(
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Video(
                      controller: _controller,
                      fill: Colors.black,
                    ),
                    Positioned(
                      top: 12,
                      right: 12,
                      child: VideoDownloadSpeedBadge(player: _player),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaImagePreviewDialog extends StatelessWidget {
  final String title;
  final String imageUrl;
  final Map<String, String> headers;

  const _MediaImagePreviewDialog({
    required this.title,
    required this.imageUrl,
    required this.headers,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      backgroundColor: VideoPlatformTheme.bgElevated,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920, maxHeight: 680),
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
                  child: Image.network(
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
    );
  }
}
