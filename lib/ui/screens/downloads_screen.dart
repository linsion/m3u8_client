import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../models/models.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets/mobile_edge_swipe_back.dart';
import '../widgets/video_download_speed_badge.dart';

class DownloadsScreen extends StatefulWidget {
  final AppState appState;

  const DownloadsScreen({
    super.key,
    required this.appState,
  });

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  String _statusFilter = 'all'; // all, active, completed, failed
  String _taskSearchQuery = '';
  String _taskSortMode = 'default'; // default, progress_desc, name_asc
  final TextEditingController _taskSearchCtrl = TextEditingController();
  final Map<String, String> _localOfflinePathByTaskId = {};
  final Map<String, double> _localSaveProgressByTaskId = {};
  String? _sniffedClipboardUrl;
  String? _dismissedClipboardUrl;

  @override
  void initState() {
    super.initState();
    _checkClipboardForVideoLink();
  }

  @override
  void dispose() {
    _taskSearchCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkClipboardForVideoLink() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final raw = data?.text?.trim() ?? '';
      if (raw.isEmpty || raw == _dismissedClipboardUrl) return;
      final match = RegExp(
        r'(https?://[^\s"<>]+?\.(?:m3u8|mp4|mkv|flv|mov|ts)(?:\?[^\s"<>]*)?|magnet:\?xt=urn:btih:[^\s"<>]+)',
        caseSensitive: false,
      ).firstMatch(raw);
      if (match != null && mounted) {
        final url = match.group(0)!;
        if (!widget.appState.tasks.any((t) => t.url == url)) {
          setState(() => _sniffedClipboardUrl = url);
        }
      }
    } catch (_) {}
  }

  List<DownloadTask> _filterTasks(List<DownloadTask> all) {
    Iterable<DownloadTask> res;
    switch (_statusFilter) {
      case 'active':
        res = all.where((t) => t.isActive);
        break;
      case 'completed':
        res = all.where((t) => t.isCompleted);
        break;
      case 'failed':
        res = all.where((t) => t.isFailed);
        break;
      default:
        res = all;
    }
    final kw = _taskSearchQuery.trim().toLowerCase();
    if (kw.isNotEmpty) {
      res = res.where(
        (t) =>
            t.name.toLowerCase().contains(kw) ||
            t.url.toLowerCase().contains(kw),
      );
    }
    final list = res.toList();
    if (_taskSortMode == 'progress_desc') {
      list.sort((a, b) => b.progress.compareTo(a.progress));
    } else if (_taskSortMode == 'name_asc') {
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
    return list;
  }

  Future<void> _showBatchImportUrlsDialog() async {
    final textCtrl = TextEditingController();
    final prefixCtrl = TextEditingController();
    final refererCtrl = TextEditingController();
    bool isSubmitting = false;
    int submittedCount = 0;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: VideoPlatformTheme.bgElevated,
              title: const Text(
                '批量新建下载任务（多行链接导入）',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '每行一条任务，支持以下格式：\n'
                        '• 第01集\$https://example.com/ep1.m3u8\n'
                        '• 第02集,https://example.com/ep2.mp4\n'
                        '• https://example.com/video.m3u8（自动按序号命名）',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: VideoPlatformTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: textCtrl,
                        maxLines: 7,
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                        decoration: const InputDecoration(
                          hintText:
                              '第01集\$https://example.com/01/index.m3u8\n第02集\$https://example.com/02/index.m3u8',
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: prefixCtrl,
                              decoration: const InputDecoration(
                                labelText: '默认片名前缀（可选）',
                                hintText: '例如：凡人修仙传',
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: refererCtrl,
                              decoration: const InputDecoration(
                                labelText: '统一 Referer（可选）',
                                hintText: 'https://...',
                                isDense: true,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed:
                      isSubmitting ? null : () => Navigator.of(ctx).pop(),
                  child: const Text('取消'),
                ),
                FilledButton.icon(
                  onPressed: isSubmitting
                      ? null
                      : () async {
                          final rawLines = textCtrl.text
                              .split(RegExp(r'\r?\n'))
                              .map((l) => l.trim())
                              .where((l) => l.isNotEmpty)
                              .toList();
                          if (rawLines.isEmpty) return;

                          setDialogState(() {
                            isSubmitting = true;
                            submittedCount = 0;
                          });

                          final prefix = prefixCtrl.text.trim();
                          final headers = <String, String>{
                            if (refererCtrl.text.trim().isNotEmpty)
                              'Referer': refererCtrl.text.trim(),
                          };

                          for (var i = 0; i < rawLines.length; i++) {
                            final line = rawLines[i];
                            String name = '';
                            String url = line;
                            if (line.contains('\$')) {
                              final idx = line.indexOf('\$');
                              name = line.substring(0, idx).trim();
                              url = line.substring(idx + 1).trim();
                            } else if (line.contains(',') &&
                                line.indexOf(',') < line.indexOf('http')) {
                              final idx = line.indexOf(',');
                              name = line.substring(0, idx).trim();
                              url = line.substring(idx + 1).trim();
                            }
                            if (url.isEmpty) continue;
                            if (name.isEmpty) {
                              name =
                                  '第${(i + 1).toString().padLeft(2, '0')}集';
                            }
                            if (prefix.isNotEmpty && !name.startsWith(prefix)) {
                              name = '$prefix - $name';
                            }
                            try {
                              await widget.appState.api.createDownloadTask(
                                url: url,
                                name: name,
                                headers: headers,
                              );
                              submittedCount++;
                              if (ctx.mounted) setDialogState(() {});
                            } catch (_) {}
                          }

                          await widget.appState.refreshDownloadTasks();
                          if (ctx.mounted) Navigator.of(ctx).pop();
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content:
                                    Text('已批量创建 $submittedCount 个下载任务'),
                              ),
                            );
                          }
                        },
                  icon: const Icon(Icons.playlist_add_rounded, size: 16),
                  label: Text(
                    isSubmitting ? '正在创建 ($submittedCount)...' : '批量创建',
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    textCtrl.dispose();
    prefixCtrl.dispose();
    refererCtrl.dispose();
  }

  Future<void> _showCreateTaskDialog() async {
    final urlCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final refererCtrl = TextEditingController();
    final uaCtrl = TextEditingController();

    bool isSubmitting = false;
    bool isExtracting = false;
    List<ExtractedVideoCandidate> candidates = const [];
    String? dialogError;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text(
                '新建下载任务 / 网页视频提取',
                style: TextStyle(fontSize: 16),
              ),
              content: SizedBox(
                width: 540,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '视频地址或分享文本（支持 M3U8、MP4、磁力链、抖音/快手/网页链接）',
                        style: TextStyle(
                          fontSize: 12,
                          color: VideoPlatformTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: urlCtrl,
                              decoration: const InputDecoration(
                                hintText: 'https://example.com/index.m3u8 或网页地址',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: isExtracting
                                ? null
                                : () async {
                                    final input = urlCtrl.text.trim();
                                    if (input.isEmpty) return;
                                    setDialogState(() {
                                      isExtracting = true;
                                      dialogError = null;
                                    });
                                    try {
                                      final list = await widget.appState.api
                                          .extractWebVideo(input);
                                      setDialogState(() {
                                        candidates = list;
                                        if (list.isNotEmpty) {
                                          urlCtrl.text = list.first.url;
                                          if (nameCtrl.text.trim().isEmpty &&
                                              list.first.title.isNotEmpty) {
                                            nameCtrl.text = list.first.title;
                                          }
                                          final ref =
                                              list.first.headers['Referer'] ??
                                                  list.first.headers['referer'];
                                          if (ref != null && ref.isNotEmpty) {
                                            refererCtrl.text = ref;
                                          }
                                        } else {
                                          dialogError = '未在该网页中嗅探到直接视频流';
                                        }
                                      });
                                    } catch (e) {
                                      setDialogState(
                                        () => dialogError = e.toString(),
                                      );
                                    } finally {
                                      setDialogState(
                                        () => isExtracting = false,
                                      );
                                    }
                                  },
                            icon: const Icon(Icons.radar_rounded, size: 16),
                            label: Text(isExtracting ? '嗅探中...' : '网页提取'),
                          ),
                        ],
                      ),
                      if (candidates.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          '嗅探到的候选视频流 (${candidates.length})：',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: VideoPlatformTheme.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        ...candidates.take(8).map(
                              (c) => Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: VideoPlatformTheme.bgCard,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: VideoPlatformTheme.borderSubtle,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: InkWell(
                                        onTap: () {
                                          setDialogState(() {
                                            urlCtrl.text = c.url;
                                            if (c.title.isNotEmpty) {
                                              nameCtrl.text = c.title;
                                            }
                                            final ref =
                                                c.headers['Referer'] ??
                                                    c.headers['referer'];
                                            if (ref != null && ref.isNotEmpty) {
                                              refererCtrl.text = ref;
                                            }
                                          });
                                        },
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              c.title.isNotEmpty
                                                  ? c.title
                                                  : c.url,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                                color: VideoPlatformTheme
                                                    .textPrimary,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              c.url,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 11,
                                                color:
                                                    VideoPlatformTheme.textMuted,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: '直接播放此视频流',
                                      visualDensity: VisualDensity.compact,
                                      icon: Icon(
                                        Icons.play_circle_fill_rounded,
                                        size: 18,
                                        color: VideoPlatformTheme.accent,
                                      ),
                                      onPressed: () {
                                        showDialog<void>(
                                          context: context,
                                          builder: (_) =>
                                              _DirectVideoPlayerDialog(
                                            title: c.title.isNotEmpty
                                                ? c.title
                                                : '嗅探视频直连播放',
                                            streamUrl: c.url,
                                            headers: c.headers,
                                            onEnterMiniPlayer: (posSec) {
                                              widget.appState.startMiniPlayer(
                                                MiniPlayerSession(
                                                  title: c.title.isNotEmpty
                                                      ? c.title
                                                      : '网页嗅探视频',
                                                  subtitle: c.url,
                                                  streamUrl: c.url,
                                                  headers: c.headers,
                                                  initialPositionSeconds:
                                                      posSec,
                                                ),
                                              );
                                            },
                                          ),
                                        );
                                      },
                                    ),
                                    IconButton(
                                      tooltip: '转入右下角小窗播放',
                                      visualDensity: VisualDensity.compact,
                                      icon: const Icon(
                                        Icons.picture_in_picture_alt_rounded,
                                        size: 16,
                                      ),
                                      onPressed: () {
                                        Navigator.of(ctx).pop();
                                        widget.appState.startMiniPlayer(
                                          MiniPlayerSession(
                                            title: c.title.isNotEmpty
                                                ? c.title
                                                : '网页嗅探视频',
                                            subtitle: c.url,
                                            streamUrl: c.url,
                                            headers: c.headers,
                                          ),
                                        );
                                      },
                                    ),
                                    IconButton(
                                      tooltip: '复制 cURL 命令 (含防盗链 Header)',
                                      visualDensity: VisualDensity.compact,
                                      icon: const Icon(
                                        Icons.terminal_rounded,
                                        size: 16,
                                      ),
                                      onPressed: () {
                                        final headerArgs = c.headers.entries
                                            .map(
                                              (e) =>
                                                  "-H '${e.key}: ${e.value}'",
                                            )
                                            .join(' ');
                                        final curl =
                                            "curl -L $headerArgs '${c.url}'"
                                                .trim();
                                        Clipboard.setData(
                                          ClipboardData(text: curl),
                                        );
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('已复制带防盗链头的 cURL 命令'),
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ),
                      ],
                      const SizedBox(height: 12),
                      Text(
                        '保存文件名（选填，留空自动识别）',
                        style: TextStyle(
                          fontSize: 12,
                          color: VideoPlatformTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: nameCtrl,
                        decoration: const InputDecoration(
                          hintText: '例如：凡人修仙传 第01集',
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: refererCtrl,
                              decoration: const InputDecoration(
                                labelText: '自定义 Referer (选填)',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: uaCtrl,
                              decoration: const InputDecoration(
                                labelText: '自定义 User-Agent (选填)',
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (dialogError != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          dialogError!,
                          style: TextStyle(
                            color: VideoPlatformTheme.danger,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed:
                      isSubmitting ? null : () => Navigator.of(ctx).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: isSubmitting
                      ? null
                      : () async {
                          final rawUrl = urlCtrl.text.trim();
                          if (rawUrl.isEmpty) {
                            setDialogState(() => dialogError = '请输入下载链接');
                            return;
                          }
                          final taskName = nameCtrl.text.trim().isNotEmpty
                              ? nameCtrl.text.trim()
                              : '视频下载_${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
                          final headers = <String, String>{};
                          if (refererCtrl.text.trim().isNotEmpty) {
                            headers['Referer'] = refererCtrl.text.trim();
                          }
                          if (uaCtrl.text.trim().isNotEmpty) {
                            headers['User-Agent'] = uaCtrl.text.trim();
                          }

                          setDialogState(() {
                            isSubmitting = true;
                            dialogError = null;
                          });
                          try {
                            await widget.appState.api.createDownloadTask(
                              url: rawUrl,
                              name: taskName,
                              headers: headers,
                            );
                            await widget.appState.refreshDownloadTasks();
                            if (ctx.mounted) Navigator.of(ctx).pop();
                          } catch (e) {
                            setDialogState(() {
                              isSubmitting = false;
                              dialogError = e.toString();
                            });
                          }
                        },
                  child: Text(isSubmitting ? '提交中...' : '创建任务'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _resolveTaskFileName(DownloadTask task) {
    String fileName = task.outputFile.trim();
    if (fileName.contains('/')) {
      fileName = fileName.split('/').last;
    }
    if (fileName.isEmpty) {
      fileName = '${task.name}.mp4';
    }
    return fileName;
  }

  void _playTaskOutput(DownloadTask task, {bool inMiniPlayer = false}) {
    final localPath = _localOfflinePathByTaskId[task.id];
    final hasLocal = localPath != null && File(localPath).existsSync();
    final fileName = _resolveTaskFileName(task);
    final streamUrl = hasLocal
        ? Uri.file(localPath).toString()
        : widget.appState.api.buildFileStreamUrl(fileName);
    final headers = hasLocal
        ? const <String, String>{}
        : widget.appState.api.authHeaders;

    if (inMiniPlayer) {
      widget.appState.startMiniPlayer(
        MiniPlayerSession(
          title: task.name,
          subtitle: hasLocal ? '本机离线视频' : '已下载视频',
          streamUrl: streamUrl,
          headers: headers,
          isLive: false,
        ),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已开启「${task.name}」小窗悬浮播放'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    showDialog<void>(
      context: context,
      builder: (_) => _DirectVideoPlayerDialog(
        title: hasLocal ? '${task.name} (本机离线)' : task.name,
        streamUrl: streamUrl,
        headers: headers,
        onEnterMiniPlayer: (posSec) {
          widget.appState.startMiniPlayer(
            MiniPlayerSession(
              title: task.name,
              subtitle: hasLocal ? '本机离线视频' : '已下载视频',
              streamUrl: streamUrl,
              headers: headers,
              isLive: false,
              initialPositionSeconds: posSec,
            ),
          );
        },
      ),
    );
  }

  Future<void> _saveTaskToLocalOffline(DownloadTask task) async {
    if (_localSaveProgressByTaskId.containsKey(task.id)) return;
    final fileName = _resolveTaskFileName(task);
    final streamUrl = widget.appState.api.buildFileStreamUrl(fileName);
    final uri = Uri.tryParse(streamUrl);
    if (uri == null) return;

    setState(() => _localSaveProgressByTaskId[task.id] = 0.01);
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
      final safeName = fileName.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
      final outPath = '${targetDir.path}${Platform.pathSeparator}$safeName';
      final outFile = File(outPath);
      final sink = outFile.openWrite();
      int received = 0;

      await for (final chunk in resp) {
        sink.add(chunk);
        received += chunk.length;
        if (totalBytes > 0 && mounted) {
          setState(() {
            _localSaveProgressByTaskId[task.id] =
                (received / totalBytes).clamp(0.01, 0.99);
          });
        }
      }
      await sink.flush();
      await sink.close();
      if (!mounted) return;
      setState(() {
        _localSaveProgressByTaskId.remove(task.id);
        _localOfflinePathByTaskId[task.id] = outPath;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已缓存到本机离线目录：$outPath')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _localSaveProgressByTaskId.remove(task.id));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存到本机失败：$e')),
      );
    } finally {
      client.close(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.appState;
    final allTasks = state.tasks;
    final filtered = _filterTasks(allTasks);

    final activeCount = allTasks.where((t) => t.isActive).length;
    final completedCount = allTasks.where((t) => t.isCompleted).length;
    final failedCount = allTasks.where((t) => t.isFailed).length;

    return Column(
      children: [
        // Top action bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: VideoPlatformTheme.bgElevated,
            border: Border(
              bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
            ),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _buildFilterChip('all', '全部 (${allTasks.length})'),
              _buildFilterChip('active', '进行中 ($activeCount)'),
              _buildFilterChip('completed', '已完成 ($completedCount)'),
              _buildFilterChip('failed', '失败 ($failedCount)'),
              const SizedBox(width: 6),
              SizedBox(
                width: 190,
                height: 32,
                child: TextField(
                  controller: _taskSearchCtrl,
                  onChanged: (v) => setState(() => _taskSearchQuery = v),
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    hintText: '搜索任务名称或链接...',
                    prefixIcon: const Icon(Icons.search_rounded, size: 15),
                    suffixIcon: _taskSearchQuery.isNotEmpty
                        ? IconButton(
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.clear_rounded, size: 14),
                            onPressed: () {
                              _taskSearchCtrl.clear();
                              setState(() => _taskSearchQuery = '');
                            },
                          )
                        : null,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '队列排序方式',
                initialValue: _taskSortMode,
                onSelected: (v) => setState(() => _taskSortMode = v),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'default', child: Text('默认队列顺序')),
                  PopupMenuItem(
                    value: 'progress_desc',
                    child: Text('按下载进度排序'),
                  ),
                  PopupMenuItem(value: 'name_asc', child: Text('按名称 A-Z 排序')),
                ],
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: VideoPlatformTheme.bgCard,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: VideoPlatformTheme.borderSubtle),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.sort_rounded, size: 15),
                      SizedBox(width: 4),
                      Text('排序', style: TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ),
              FilledButton.icon(
                onPressed: _showCreateTaskDialog,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('新建 / 嗅探'),
              ),
              OutlinedButton.icon(
                onPressed: _showBatchImportUrlsDialog,
                icon: const Icon(Icons.playlist_add_rounded, size: 16),
                label: const Text('批量导入'),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  _dismissedClipboardUrl = null;
                  _checkClipboardForVideoLink();
                  state.refreshDownloadTasks();
                },
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('刷新'),
              ),
              if (failedCount > 0)
                OutlinedButton.icon(
                  onPressed: () async {
                    final failedTasks =
                        allTasks.where((t) => t.isFailed).toList();
                    for (final t in failedTasks) {
                      try {
                        await state.api.retryDownloadTask(t.id);
                      } catch (_) {}
                    }
                    await state.refreshDownloadTasks();
                  },
                  icon: Icon(
                    Icons.replay_rounded,
                    size: 15,
                    color: VideoPlatformTheme.warning,
                  ),
                  label: Text('重试失败 ($failedCount)'),
                ),
              if (completedCount > 0)
                TextButton(
                  onPressed: () async {
                    final ids = allTasks
                        .where((t) => t.isCompleted)
                        .map((t) => t.id)
                        .toList();
                    await state.api.batchDeleteDownloadTasks(ids);
                    await state.refreshDownloadTasks();
                  },
                  child: const Text('清理已完成记录'),
                ),
            ],
          ),
        ),
        // Smart Clipboard Sniffer Banner
        if (_sniffedClipboardUrl != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: VideoPlatformTheme.accent.withValues(alpha: 0.14),
              border: Border(
                bottom: BorderSide(
                  color: VideoPlatformTheme.accent.withValues(alpha: 0.4),
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.radar_rounded,
                  size: 18,
                  color: VideoPlatformTheme.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '智能嗅探到剪贴板视频流：$_sniffedClipboardUrl',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: VideoPlatformTheme.textPrimary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: () {
                    final url = _sniffedClipboardUrl!;
                    showDialog<void>(
                      context: context,
                      builder: (_) => _DirectVideoPlayerDialog(
                        title: '剪贴板直连播放',
                        streamUrl: url,
                        headers: const {},
                        onEnterMiniPlayer: (posSec) {
                          widget.appState.startMiniPlayer(
                            MiniPlayerSession(
                              title: '剪贴板视频流',
                              subtitle: url,
                              streamUrl: url,
                              headers: const {},
                              isLive: false,
                              initialPositionSeconds: posSec,
                            ),
                          );
                        },
                      ),
                    );
                  },
                  icon: const Icon(Icons.play_arrow_rounded, size: 16),
                  label: const Text('直接流式播放'),
                ),
                const SizedBox(width: 4),
                FilledButton.tonalIcon(
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final url = _sniffedClipboardUrl!;
                    setState(() {
                      _dismissedClipboardUrl = url;
                      _sniffedClipboardUrl = null;
                    });
                    final name =
                        '剪贴板嗅探_${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
                    try {
                      await widget.appState.api.createDownloadTask(
                        url: url,
                        name: name,
                      );
                      await widget.appState.refreshDownloadTasks();
                      if (mounted) {
                        messenger.showSnackBar(
                          SnackBar(content: Text('已加入下载队列：$name')),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        messenger.showSnackBar(
                          SnackBar(content: Text('添加下载失败：$e')),
                        );
                      }
                    }
                  },
                  icon: const Icon(Icons.download_rounded, size: 15),
                  label: const Text('一键下载'),
                ),
                IconButton(
                  tooltip: '忽略此剪贴板链接',
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () {
                    setState(() {
                      _dismissedClipboardUrl = _sniffedClipboardUrl;
                      _sniffedClipboardUrl = null;
                    });
                  },
                ),
              ],
            ),
          ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.download_done_rounded,
                        size: 40,
                        color: VideoPlatformTheme.textMuted,
                      ),
                      SizedBox(height: 10),
                      Text(
                        '当前队列暂无下载任务',
                        style: TextStyle(
                          color: VideoPlatformTheme.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final task = filtered[index];
                    return _buildTaskCard(task);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildFilterChip(String key, String label) {
    final selected = _statusFilter == key;
    return InkWell(
      borderRadius: BorderRadius.circular(5),
      onTap: () => setState(() => _statusFilter = key),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? VideoPlatformTheme.accent
              : VideoPlatformTheme.bgCard,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: selected
                ? VideoPlatformTheme.accent
                : VideoPlatformTheme.borderSubtle,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected ? Colors.white : VideoPlatformTheme.textSecondary,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _buildTaskCard(DownloadTask task) {
    Color statusColor = VideoPlatformTheme.accent;
    if (task.isCompleted) {
      statusColor = VideoPlatformTheme.success;
    } else if (task.isFailed) {
      statusColor = VideoPlatformTheme.danger;
    } else if (task.status == 'Pending') {
      statusColor = VideoPlatformTheme.warning;
    }

    final pct = task.progress.clamp(0.0, 100.0);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: VideoPlatformTheme.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: statusColor.withValues(alpha: 0.5)),
                ),
                child: Text(
                  task.statusLabel,
                  style: TextStyle(
                    fontSize: 11,
                    color: statusColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  task.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: VideoPlatformTheme.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (task.isActive)
                Text(
                  task.formattedSpeed,
                  style: TextStyle(
                    fontSize: 12,
                    color: VideoPlatformTheme.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              const SizedBox(width: 12),
              Text(
                '${pct.toStringAsFixed(1)}%',
                style: TextStyle(
                  fontSize: 12,
                  color: VideoPlatformTheme.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: pct / 100.0,
              minHeight: 6,
              backgroundColor: VideoPlatformTheme.bgCard,
              color: statusColor,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  task.error.isNotEmpty
                      ? '错误：${task.error}'
                      : (task.totalSegments > 0
                          ? '分片进度：${task.downloadedSegments} / ${task.totalSegments} · ${task.url}'
                          : task.url),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: task.error.isNotEmpty
                        ? VideoPlatformTheme.danger
                        : VideoPlatformTheme.textMuted,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (task.isCompleted) ...[
                TextButton.icon(
                  onPressed: () => _playTaskOutput(task),
                  icon: const Icon(Icons.play_circle_outline, size: 16),
                  label: Text(
                    _localOfflinePathByTaskId.containsKey(task.id)
                        ? '离线播放'
                        : '客户端播放',
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _playTaskOutput(task, inMiniPlayer: true),
                  icon: const Icon(
                    Icons.picture_in_picture_alt_rounded,
                    size: 15,
                  ),
                  label: const Text('小窗'),
                ),
                TextButton.icon(
                  onPressed: _localSaveProgressByTaskId.containsKey(task.id)
                      ? null
                      : () => _saveTaskToLocalOffline(task),
                  icon: Icon(
                    _localOfflinePathByTaskId.containsKey(task.id)
                        ? Icons.offline_pin_rounded
                        : Icons.save_alt_rounded,
                    size: 16,
                    color: _localOfflinePathByTaskId.containsKey(task.id)
                        ? VideoPlatformTheme.success
                        : null,
                  ),
                  label: Text(
                    _localSaveProgressByTaskId.containsKey(task.id)
                        ? '缓存中 ${(_localSaveProgressByTaskId[task.id]! * 100).toStringAsFixed(0)}%'
                        : (_localOfflinePathByTaskId.containsKey(task.id)
                            ? '已存本机'
                            : '保存本机离线'),
                  ),
                ),
                TextButton.icon(
                  onPressed: () async {
                    try {
                      await widget.appState.api.uploadTaskTo115(task.id);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已触发上传 115 网盘')),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('上传 115 失败：$e')),
                        );
                      }
                    }
                  },
                  icon: const Icon(Icons.cloud_upload_outlined, size: 16),
                  label: const Text('上传115'),
                ),
              ],
              if (task.isFailed)
                TextButton.icon(
                  onPressed: () async {
                    await widget.appState.api.retryDownloadTask(task.id);
                    await widget.appState.refreshDownloadTasks();
                  },
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('重试'),
                ),
              IconButton(
                tooltip: '删除任务',
                icon: Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: VideoPlatformTheme.textMuted,
                ),
                onPressed: () async {
                  await widget.appState.api.deleteDownloadTask(task.id);
                  await widget.appState.refreshDownloadTasks();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DirectVideoPlayerDialog extends StatefulWidget {
  final String title;
  final String streamUrl;
  final Map<String, String> headers;
  final ValueChanged<int>? onEnterMiniPlayer;

  const _DirectVideoPlayerDialog({
    required this.title,
    required this.streamUrl,
    required this.headers,
    this.onEnterMiniPlayer,
  });

  @override
  State<_DirectVideoPlayerDialog> createState() =>
      _DirectVideoPlayerDialogState();
}

class _DirectVideoPlayerDialogState extends State<_DirectVideoPlayerDialog> {
  late final Player _player;
  late final VideoController _controller;
  String _fitMode = 'fit'; // 'fit', 'cover'
  bool? _landscapeOverride;
  bool _didChangeOrientation = false;

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
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        setState(() {
                          _fitMode = _fitMode == 'fit' ? 'cover' : 'fit';
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Text(
                          _fitMode == 'cover' ? '比例:铺满' : '比例:适应',
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
                    if (!isMobileDialog) ...[
                      VideoDownloadSpeedBadge(
                        player: _player,
                        compact: true,
                        backgroundColor: VideoPlatformTheme.bgCard,
                      ),
                      const SizedBox(width: 6),
                    ],
                    if (widget.onEnterMiniPlayer != null)
                      TextButton.icon(
                        onPressed: () {
                          final pos = _player.state.position.inSeconds;
                          Navigator.of(context).pop();
                          widget.onEnterMiniPlayer!(pos);
                        },
                        icon: const Icon(
                          Icons.picture_in_picture_alt_rounded,
                          size: 16,
                        ),
                        label: const Text('小窗播放'),
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
