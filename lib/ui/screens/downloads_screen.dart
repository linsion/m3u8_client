import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../models/models.dart';
import '../../services/tv_platform_service.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets/cloud_music_player.dart';
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
  String _taskSortMode = 'default'; // default, progress_desc, speed_desc, name_asc
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
            t.url.toLowerCase().contains(kw) ||
            t.outputFile.toLowerCase().contains(kw),
      );
    }
    final list = res.toList();
    if (_taskSortMode == 'progress_desc') {
      list.sort((a, b) => b.progress.compareTo(a.progress));
    } else if (_taskSortMode == 'speed_desc') {
      list.sort((a, b) => b.speed.compareTo(a.speed));
    } else if (_taskSortMode == 'name_asc') {
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
    return list;
  }

  static String _formatBytesPerSec(double bytesPerSec) {
    if (bytesPerSec <= 0) return '0 B/s';
    if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(2)} MB/s';
  }

  static String _detectTaskTypeBadge(DownloadTask task) {
    final t = task.urlType.trim().toLowerCase();
    final u = task.url.toLowerCase();
    if (u.startsWith('magnet:') || t == 'magnet') return 'MAGNET';
    if (u.contains('.mp4') || t == 'mp4') return 'MP4';
    if (u.contains('.mkv') || t == 'mkv') return 'MKV';
    if (u.contains('.flv') || t == 'flv') return 'FLV';
    return 'HLS / M3U8';
  }

  static String _extractUrlHost(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.startsWith('magnet:')) return 'BitTorrent 磁力网络';
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.host.isNotEmpty) {
      return uri.host;
    }
    return '直连流媒体';
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
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: VideoPlatformTheme.borderStrong),
              ),
              title: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: VideoPlatformTheme.accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.playlist_add_rounded,
                      size: 18,
                      color: VideoPlatformTheme.accent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    '批量新建下载任务（多行链接导入）',
                    style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              content: SizedBox(
                width: 580,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: VideoPlatformTheme.bgCard,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: VideoPlatformTheme.borderSubtle,
                          ),
                        ),
                        child: Text(
                          '每行一条任务，自动识别剧集名与链接：\n'
                          '• 第01集\$https://example.com/ep1.m3u8\n'
                          '• 第02集,https://example.com/ep2.mp4\n'
                          '• https://example.com/video.m3u8（自动按序号命名）',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: VideoPlatformTheme.textSecondary,
                          ),
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
                      const SizedBox(height: 12),
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
              backgroundColor: VideoPlatformTheme.bgElevated,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: VideoPlatformTheme.borderStrong),
              ),
              title: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: VideoPlatformTheme.accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.radar_rounded,
                      size: 18,
                      color: VideoPlatformTheme.accent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    '新建下载任务 / 网页视频提取',
                    style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              content: SizedBox(
                width: 560,
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
                                  borderRadius: BorderRadius.circular(8),
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
                                          useSafeArea: false,
                                          barrierColor: Colors.black,
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
                FilledButton.icon(
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
                  icon: const Icon(Icons.download_rounded, size: 16),
                  label: Text(isSubmitting ? '提交中...' : '创建任务'),
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
      useSafeArea: false,
      barrierColor: Colors.black,
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

    final activeTasks = allTasks.where((t) => t.isActive).toList();
    final activeCount = activeTasks.length;
    final completedCount = allTasks.where((t) => t.isCompleted).length;
    final failedCount = allTasks.where((t) => t.isFailed).length;
    final totalActiveSpeed =
        activeTasks.fold<double>(0.0, (sum, t) => sum + t.speed);
    final isCompact = MediaQuery.sizeOf(context).width < 720;

    return Column(
      children: [
        // 1. Dashboard Summary Header + Action Bar
        Container(
          padding: EdgeInsets.fromLTRB(
            isCompact ? 12 : 18,
            12,
            isCompact ? 12 : 18,
            12,
          ),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                activeCount > 0
                    ? VideoPlatformTheme.accent.withValues(alpha: 0.12)
                    : VideoPlatformTheme.bgElevated,
                VideoPlatformTheme.bgElevated,
              ],
            ),
            border: Border(
              bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Top Summary Row: Metrics Cards & Primary Action Buttons
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _buildSummaryStatPill(
                        icon: Icons.downloading_rounded,
                        label: '进行中',
                        value: '$activeCount',
                        color: activeCount > 0
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.textSecondary,
                        highlighted: activeCount > 0,
                      ),
                      _buildSummaryStatPill(
                        icon: Icons.speed_rounded,
                        label: '总速率',
                        value: _formatBytesPerSec(totalActiveSpeed),
                        color: totalActiveSpeed > 0
                            ? const Color(0xFF22C55E)
                            : VideoPlatformTheme.textSecondary,
                        highlighted: totalActiveSpeed > 0,
                      ),
                      _buildSummaryStatPill(
                        icon: Icons.task_alt_rounded,
                        label: '已完成',
                        value: '$completedCount',
                        color: completedCount > 0
                            ? const Color(0xFF10B981)
                            : VideoPlatformTheme.textSecondary,
                      ),
                      if (failedCount > 0)
                        _buildSummaryStatPill(
                          icon: Icons.error_outline_rounded,
                          label: '异常',
                          value: '$failedCount',
                          color: VideoPlatformTheme.danger,
                          highlighted: true,
                        ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: _showCreateTaskDialog,
                        icon: const Icon(Icons.add_rounded, size: 16),
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
                        icon: const Icon(Icons.refresh_rounded, size: 16),
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
                          label: Text('全部重试 ($failedCount)'),
                        ),
                      if (completedCount > 0)
                        TextButton.icon(
                          onPressed: () async {
                            final ids = allTasks
                                .where((t) => t.isCompleted)
                                .map((t) => t.id)
                                .toList();
                            await state.api.batchDeleteDownloadTasks(ids);
                            await state.refreshDownloadTasks();
                          },
                          icon: const Icon(
                            Icons.cleaning_services_outlined,
                            size: 15,
                          ),
                          label: const Text('清理已完成记录'),
                        ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Second Row: Status Filter Chips + Search Field + Sort Selector
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _buildFilterChip(
                        'all',
                        '全部 (${allTasks.length})',
                        Icons.list_alt_rounded,
                      ),
                      _buildFilterChip(
                        'active',
                        '进行中 ($activeCount)',
                        Icons.downloading_rounded,
                      ),
                      _buildFilterChip(
                        'completed',
                        '已完成 ($completedCount)',
                        Icons.check_circle_outline_rounded,
                      ),
                      _buildFilterChip(
                        'failed',
                        '失败 ($failedCount)',
                        Icons.error_outline_rounded,
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: isCompact ? 180 : 220,
                        height: 33,
                        child: TextField(
                          controller: _taskSearchCtrl,
                          onChanged: (v) =>
                              setState(() => _taskSearchQuery = v),
                          style: const TextStyle(fontSize: 12),
                          decoration: InputDecoration(
                            hintText: '搜索任务名称或链接...',
                            prefixIcon:
                                const Icon(Icons.search_rounded, size: 15),
                            suffixIcon: _taskSearchQuery.isNotEmpty
                                ? IconButton(
                                    padding: EdgeInsets.zero,
                                    icon: const Icon(
                                      Icons.clear_rounded,
                                      size: 14,
                                    ),
                                    onPressed: () {
                                      _taskSearchCtrl.clear();
                                      setState(() => _taskSearchQuery = '');
                                    },
                                  )
                                : null,
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 8),
                          ),
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '队列排序方式',
                        initialValue: _taskSortMode,
                        onSelected: (v) => setState(() => _taskSortMode = v),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'default',
                            child: Text('默认队列顺序'),
                          ),
                          PopupMenuItem(
                            value: 'progress_desc',
                            child: Text('按下载进度排序'),
                          ),
                          PopupMenuItem(
                            value: 'speed_desc',
                            child: Text('按实时速度排序'),
                          ),
                          PopupMenuItem(
                            value: 'name_asc',
                            child: Text('按名称 A-Z 排序'),
                          ),
                        ],
                        child: Container(
                          height: 33,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: VideoPlatformTheme.bgCard,
                            borderRadius: BorderRadius.circular(7),
                            border: Border.all(
                              color: _taskSortMode != 'default'
                                  ? VideoPlatformTheme.accent
                                  : VideoPlatformTheme.borderSubtle,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.sort_rounded,
                                size: 15,
                                color: _taskSortMode != 'default'
                                    ? VideoPlatformTheme.accent
                                    : VideoPlatformTheme.textSecondary,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                switch (_taskSortMode) {
                                  'progress_desc' => '进度排序',
                                  'speed_desc' => '速度排序',
                                  'name_asc' => '名称排序',
                                  _ => '排序',
                                },
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _taskSortMode != 'default'
                                      ? VideoPlatformTheme.accent
                                      : VideoPlatformTheme.textSecondary,
                                  fontWeight: _taskSortMode != 'default'
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),

        // 2. Smart Clipboard Sniffer Banner
        if (_sniffedClipboardUrl != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  VideoPlatformTheme.accent.withValues(alpha: 0.16),
                  VideoPlatformTheme.accent.withValues(alpha: 0.06),
                ],
              ),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: VideoPlatformTheme.accent.withValues(alpha: 0.45),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: VideoPlatformTheme.accent.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.radar_rounded,
                    size: 18,
                    color: VideoPlatformTheme.accent,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '智能嗅探到剪贴板视频流',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: VideoPlatformTheme.accent,
                        ),
                      ),
                      Text(
                        _sniffedClipboardUrl!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: VideoPlatformTheme.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
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
                  label: const Text('直接播放'),
                ),
                const SizedBox(width: 6),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
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
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_rounded, size: 17),
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

        // 3. Task Cards List or Empty State
        Expanded(
          child: filtered.isEmpty
              ? _buildEmptyState(allTasks.isEmpty)
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

  Widget _buildSummaryStatPill({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    bool highlighted = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: highlighted
            ? color.withValues(alpha: 0.13)
            : VideoPlatformTheme.bgCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: highlighted
              ? color.withValues(alpha: 0.45)
              : VideoPlatformTheme.borderSubtle,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(
            '$label ',
            style: TextStyle(
              fontSize: 11.5,
              color: VideoPlatformTheme.textSecondary,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: highlighted ? color : VideoPlatformTheme.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(bool queueIsTotallyEmpty) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: VideoPlatformTheme.bgElevated,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: VideoPlatformTheme.borderSubtle),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: VideoPlatformTheme.accent.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                queueIsTotallyEmpty
                    ? Icons.cloud_download_outlined
                    : Icons.filter_alt_off_rounded,
                size: 28,
                color: VideoPlatformTheme.accent,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              queueIsTotallyEmpty ? '当前队列暂无下载任务' : '没有符合当前筛选条件的下载任务',
              style: TextStyle(
                color: VideoPlatformTheme.textPrimary,
                fontSize: 14.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              queueIsTotallyEmpty
                  ? '支持多线程高速下载 M3U8 / MP4 / 磁力链接，以及网页视频流智能嗅探与自动转封装 MP4'
                  : '可以切换上方状态标签或清空搜索关键词查看全部任务',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: VideoPlatformTheme.textMuted,
                fontSize: 12,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (queueIsTotallyEmpty) ...[
                  FilledButton.icon(
                    onPressed: _showCreateTaskDialog,
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: const Text('新建 / 网页嗅探'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _showBatchImportUrlsDialog,
                    icon: const Icon(Icons.playlist_add_rounded, size: 16),
                    label: const Text('批量导入链接'),
                  ),
                ] else
                  OutlinedButton.icon(
                    onPressed: () {
                      _taskSearchCtrl.clear();
                      setState(() {
                        _statusFilter = 'all';
                        _taskSearchQuery = '';
                      });
                    },
                    icon: const Icon(Icons.refresh_rounded, size: 15),
                    label: const Text('查看全部任务'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip(String key, String label, IconData icon) {
    final selected = _statusFilter == key;
    return InkWell(
      borderRadius: BorderRadius.circular(7),
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      onTap: () => setState(() => _statusFilter = key),
      child: Builder(
        builder: (ctx) {
          final isFocused = Focus.of(ctx).hasPrimaryFocus;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(
              color: selected
                  ? VideoPlatformTheme.accent
                  : (isFocused
                      ? VideoPlatformTheme.accent.withValues(alpha: 0.25)
                      : VideoPlatformTheme.bgCard),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: isFocused
                    ? Colors.white
                    : (selected
                        ? VideoPlatformTheme.accent
                        : VideoPlatformTheme.borderSubtle),
                width: isFocused ? 2.0 : 1.0,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 13.5,
                  color: (selected || isFocused)
                      ? Colors.white
                      : VideoPlatformTheme.textSecondary,
                ),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: (selected || isFocused)
                        ? Colors.white
                        : VideoPlatformTheme.textSecondary,
                    fontWeight: (selected || isFocused)
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildTaskCard(DownloadTask task) {
    Color statusColor = VideoPlatformTheme.accent;
    IconData statusIcon = Icons.downloading_rounded;
    if (task.isCompleted) {
      statusColor = VideoPlatformTheme.success;
      statusIcon = Icons.check_circle_rounded;
    } else if (task.isFailed) {
      statusColor = VideoPlatformTheme.danger;
      statusIcon = Icons.error_outline_rounded;
    } else if (task.status == 'Pending') {
      statusColor = VideoPlatformTheme.warning;
      statusIcon = Icons.schedule_rounded;
    } else if (task.status == 'Converting') {
      statusColor = const Color(0xFFA855F7);
      statusIcon = Icons.movie_filter_rounded;
    } else if (task.status == 'Uploading') {
      statusColor = const Color(0xFF38BDF8);
      statusIcon = Icons.cloud_upload_rounded;
    }

    final pct = task.isCompleted ? 100.0 : task.progress.clamp(0.0, 100.0);
    final typeBadge = _detectTaskTypeBadge(task);
    final hostLabel = _extractUrlHost(task.url);
    final hasLocalOffline = _localOfflinePathByTaskId.containsKey(task.id);
    final localSavePct = _localSaveProgressByTaskId[task.id];

    return Container(
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: task.isActive
              ? VideoPlatformTheme.accent.withValues(alpha: 0.45)
              : (task.isFailed
                  ? VideoPlatformTheme.danger.withValues(alpha: 0.4)
                  : VideoPlatformTheme.borderSubtle),
          width: task.isActive ? 1.3 : 1.0,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top Row: Leading Icon + Status Badge + Type Badge + Title + Speed Pill + Percentage
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: statusColor.withValues(alpha: 0.38),
                  ),
                ),
                child: Icon(statusIcon, size: 18, color: statusColor),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 1.5,
                          ),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: statusColor.withValues(alpha: 0.5),
                            ),
                          ),
                          child: Text(
                            task.statusLabel,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: statusColor,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1.5,
                          ),
                          decoration: BoxDecoration(
                            color: VideoPlatformTheme.bgCard,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: VideoPlatformTheme.borderSubtle,
                            ),
                          ),
                          child: Text(
                            typeBadge,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: VideoPlatformTheme.textSecondary,
                            ),
                          ),
                        ),
                        if (hasLocalOffline) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: VideoPlatformTheme.success
                                  .withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '已存本机',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: VideoPlatformTheme.success,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            task.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: VideoPlatformTheme.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(
                          Icons.link_rounded,
                          size: 13,
                          color: VideoPlatformTheme.textMuted,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          hostLabel,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: VideoPlatformTheme.textSecondary,
                          ),
                        ),
                        if (task.totalSegments > 0) ...[
                          const SizedBox(width: 8),
                          Text(
                            '· 分片 ${task.downloadedSegments} / ${task.totalSegments}',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: VideoPlatformTheme.accent,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                        if (task.outputFile.trim().isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              '· ${_resolveTaskFileName(task)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: VideoPlatformTheme.textMuted,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Real-time Speed Pill & Percentage Badge
              if (task.isActive)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: VideoPlatformTheme.accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: VideoPlatformTheme.accent.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.speed_rounded,
                        size: 13,
                        color: VideoPlatformTheme.accent,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        task.formattedSpeed,
                        style: TextStyle(
                          fontSize: 12,
                          color: VideoPlatformTheme.accent,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(width: 10),
              Text(
                '${pct.toStringAsFixed(1)}%',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: task.isCompleted
                      ? VideoPlatformTheme.success
                      : VideoPlatformTheme.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Progress Bar
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct / 100.0,
              minHeight: 6,
              backgroundColor: VideoPlatformTheme.bgCard,
              color: statusColor,
            ),
          ),

          // Error Banner if task failed
          if (task.error.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: VideoPlatformTheme.danger.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: VideoPlatformTheme.danger.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 15,
                    color: VideoPlatformTheme.danger,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '错误原因：${task.error}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: VideoPlatformTheme.danger,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 9),

          // Bottom Row: Source URL + Copy URL + Task Action Buttons
          Row(
            children: [
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: task.url));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('已复制任务源链接到剪贴板'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Icon(
                          Icons.copy_rounded,
                          size: 12,
                          color: VideoPlatformTheme.textMuted,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            task.url,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: VideoPlatformTheme.textMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (task.isCompleted) ...[
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                      ),
                      onPressed: () => _playTaskOutput(task),
                      icon: const Icon(
                        Icons.play_circle_outline_rounded,
                        size: 15,
                      ),
                      label: Text(
                        hasLocalOffline ? '离线播放' : '客户端播放',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                      ),
                      onPressed: () =>
                          _playTaskOutput(task, inMiniPlayer: true),
                      icon: const Icon(
                        Icons.picture_in_picture_alt_rounded,
                        size: 14,
                      ),
                      label: const Text('小窗', style: TextStyle(fontSize: 12)),
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                      ),
                      onPressed: localSavePct != null
                          ? null
                          : () => _saveTaskToLocalOffline(task),
                      icon: Icon(
                        hasLocalOffline
                            ? Icons.offline_pin_rounded
                            : Icons.save_alt_rounded,
                        size: 15,
                        color:
                            hasLocalOffline ? VideoPlatformTheme.success : null,
                      ),
                      label: Text(
                        localSavePct != null
                            ? '缓存中 ${(localSavePct * 100).toStringAsFixed(0)}%'
                            : (hasLocalOffline ? '已存本机' : '保存本机离线'),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                      ),
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
                      icon: const Icon(Icons.cloud_upload_outlined, size: 15),
                      label: const Text('上传115', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                  if (task.isFailed)
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                      ),
                      onPressed: () async {
                        await widget.appState.api.retryDownloadTask(task.id);
                        await widget.appState.refreshDownloadTasks();
                      },
                      icon: const Icon(Icons.refresh_rounded, size: 15),
                      label: const Text('重试', style: TextStyle(fontSize: 12)),
                    ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '删除任务',
                    icon: Icon(
                      Icons.delete_outline_rounded,
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
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;
  Timer? _osdHideTimer;
  double _rate = 1.0;
  String _fitMode = 'fit'; // 'fit' (适应), 'cover' (铺满), 'fill' (拉伸)
  bool? _landscapeOverride;
  bool _didChangeOrientation = false;
  bool _controlsVisible = true;
  bool _isScreenLocked = false;
  bool _isPlaying = true;
  bool _isBuffering = false;
  bool _isLongPressFastForward = false;
  bool _isHorizontalSeeking = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _seekStartPos = Duration.zero;
  Duration _seekPreviewPos = Duration.zero;
  double? _scrubOverrideMs;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    unawaited(CloudMusicController.stopAllBackgroundAudioForVideo());
    _player = Player(
      configuration: PlayerConfiguration(
        bufferSize: (Platform.isAndroid || Platform.isIOS)
            ? 96 * 1024 * 1024
            : 128 * 1024 * 1024,
      ),
    );
    _controller = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        hwdec: Platform.isAndroid ? 'mediacodec-copy' : null,
        enableHardwareAcceleration: true,
      ),
    );
    _posSub = _player.stream.position.listen((pos) {
      if (!mounted) return;
      if ((pos - _position).inMilliseconds.abs() >= 200 || pos == Duration.zero) {
        setState(() => _position = pos);
      }
    });
    _durSub = _player.stream.duration.listen((dur) {
      if (!mounted) return;
      if (dur != _duration) {
        setState(() => _duration = dur);
      }
    });
    _playingSub = _player.stream.playing.listen((playing) {
      if (!mounted) return;
      setState(() => _isPlaying = playing);
      if (playing) {
        _scheduleOsdAutoHide();
      } else {
        _osdHideTimer?.cancel();
        if (!_controlsVisible) {
          setState(() => _controlsVisible = true);
        }
      }
    });
    _bufferingSub = _player.stream.buffering.listen((buf) {
      if (!mounted) return;
      if (buf != _isBuffering) {
        setState(() => _isBuffering = buf);
      }
    });
    unawaited(_configureDownloadPlayerAndOpen());
    _scheduleOsdAutoHide();
  }

  void _scheduleOsdAutoHide() {
    _osdHideTimer?.cancel();
    _osdHideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted ||
          !_isPlaying ||
          _isHorizontalSeeking ||
          _scrubOverrideMs != null) {
        return;
      }
      setState(() => _controlsVisible = false);
    });
  }

  void _wakeControls() {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _scheduleOsdAutoHide();
  }

  static String _formatClock(Duration d) {
    final totalSec = d.inSeconds.clamp(0, 359999);
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _configureDownloadPlayerAndOpen() async {
    try {
      final dynamic platform = _player.platform;
      final isMobileOrTv = Platform.isAndroid || Platform.isIOS;
      final props = <String, String>{
        'hwdec': Platform.isAndroid ? 'mediacodec-copy' : 'auto',
        'hwdec-codecs': 'h264,hevc,vp8,vp9,av1',
        'vd-lavc-check-hw-profile': 'yes',
        'vd-lavc-software-fallback': 'yes',
        'vd-lavc-dr': 'yes',
        'vd-lavc-fast': 'yes',
        'vd-lavc-skiploopfilter': 'nonref',
        'vd-lavc-threads': '0',
        'ad-lavc-threads': '0',
        'ad-lavc-downmix': 'yes',
        'audio-channels': 'stereo',
        'hr-seek-framedrop': 'yes',
        'framedrop': 'vo',
        'demuxer-thread': 'yes',
        'cache': 'yes',
        'cache-on-disk': 'no',
        'cache-secs': isMobileOrTv ? '90' : '150',
        'demuxer-max-bytes': isMobileOrTv ? '100663296' : '167772160',
        'demuxer-readahead-secs': isMobileOrTv ? '60' : '90',
        'stream-buffer-size': '2097152',
        'tls-verify': 'no',
      };
      for (final entry in props.entries) {
        await platform.setProperty(entry.key, entry.value);
      }
      final ua = widget.headers['User-Agent'] ??
          widget.headers['user-agent'] ??
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 115Browser/27.0.5.7';
      await platform.setProperty('user-agent', ua);
      final referer = widget.headers['Referer'] ??
          widget.headers['referer'] ??
          widget.headers['Referrer'] ??
          '';
      if (referer.isNotEmpty) {
        await platform.setProperty('referrer', referer);
      }
    } catch (_) {}
    if (!mounted) return;
    await _player.open(
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
      _controlsVisible = true;
    });
    _scheduleOsdAutoHide();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (nextLandscape) {
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

  void _cycleFitMode() {
    setState(() {
      _fitMode = switch (_fitMode) {
        'fit' => 'cover',
        'cover' => 'fill',
        _ => 'fit',
      };
    });
    _wakeControls();
  }

  BoxFit _resolveBoxFit() {
    return switch (_fitMode) {
      'cover' => BoxFit.cover,
      'fill' => BoxFit.fill,
      _ => BoxFit.contain,
    };
  }

  String _fitModeLabel() {
    return switch (_fitMode) {
      'cover' => '画面:铺满',
      'fill' => '画面:拉伸',
      _ => '画面:适应',
    };
  }

  void _seekRelativeSeconds(int deltaSeconds) {
    final pos = _player.state.position;
    final dur =
        _duration.inMilliseconds > 0 ? _duration : _player.state.duration;
    final target = pos + Duration(seconds: deltaSeconds);
    final clamped = target < Duration.zero
        ? Duration.zero
        : (dur > Duration.zero && target > dur ? dur : target);
    setState(() => _position = clamped);
    _player.seek(clamped);
    _wakeControls();
  }

  Future<void> _openInEmbeddedExoPlayer() async {
    if (!Platform.isAndroid || !mounted) return;
    final curMs = _player.state.position.inMilliseconds;
    await _player.pause();
    final res = await TvPlatformService.openNativeExoPlayer(
      streamUrl: widget.streamUrl,
      title: widget.title,
      headers: widget.headers,
      startPositionMs: curMs,
    );
    if (!mounted) return;
    if (res.positionMs > 1000) {
      await _player.seek(Duration(milliseconds: res.positionMs));
    }
    final errStr = res.error ?? '';
    if (errStr.startsWith('FALLBACK_MPV_SOFT_AUDIO')) {
      if (errStr.startsWith('FALLBACK_MPV_SOFT_AUDIO:')) {
        final idx = int.tryParse(
          errStr.substring('FALLBACK_MPV_SOFT_AUDIO:'.length),
        );
        final realTracks = _player.state.tracks.audio
            .where((t) => t.id != 'auto' && t.id != 'no')
            .toList();
        if (idx != null && idx >= 0 && idx < realTracks.length) {
          await _player.setAudioTrack(realTracks[idx]);
        }
      }
      await _player.play();
    }
  }

  String _formatAudioTrackTitle(AudioTrack t, int index) {
    final parts = <String>[];
    final lang = (t.language ?? '').trim().toLowerCase();
    final rawTitle = (t.title ?? '').trim();
    if (rawTitle.contains('国语') ||
        rawTitle.contains('国配') ||
        lang.startsWith('cmn')) {
      parts.add('国语');
    } else if (rawTitle.contains('粤语') || lang.startsWith('yue')) {
      parts.add('粤语');
    } else if (lang.startsWith('zh') ||
        lang.startsWith('chi') ||
        lang.startsWith('zho')) {
      parts.add('中文');
    } else if (lang.startsWith('en')) {
      parts.add('英语');
    } else if (lang.startsWith('ja') || lang.startsWith('jpn')) {
      parts.add('日语');
    } else if (lang.startsWith('ko') || lang.startsWith('kor')) {
      parts.add('韩语');
    } else if (lang.isNotEmpty && lang != 'und') {
      parts.add(lang.toUpperCase());
    } else {
      parts.add('音轨${index + 1}');
    }
    if (rawTitle.isNotEmpty && !parts.any((p) => rawTitle == p)) {
      parts.add(rawTitle);
    }
    final codec = (t.codec ?? '').trim();
    if (codec.isNotEmpty) {
      parts.add(codec.toUpperCase());
    }
    if ((t.channelscount ?? 0) > 0) {
      final ch = t.channelscount!;
      parts.add(
        ch == 8 ? '7.1' : (ch == 6 ? '5.1' : (ch == 2 ? '2.0' : '${ch}ch')),
      );
    }
    return parts.join(' · ');
  }

  Future<void> _showAudioTrackSelectorDialog() async {
    final allTracks = _player.state.tracks.audio;
    final realTracks =
        allTracks.where((t) => t.id != 'auto' && t.id != 'no').toList();
    final tracks = realTracks.isNotEmpty ? realTracks : allTracks;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final current = _player.state.track.audio;
            return AlertDialog(
              backgroundColor: VideoPlatformTheme.bgElevated,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: BorderSide(
                  color: VideoPlatformTheme.accent.withValues(alpha: 0.45),
                ),
              ),
              title: Row(
                children: [
                  Icon(
                    Icons.surround_sound_rounded,
                    color: VideoPlatformTheme.accent,
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '选择音轨 / 声道 (共 ${tracks.length} 条 · 全格式软解混音)',
                      style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 540,
                child: tracks.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Text('当前视频仅包含默认音轨，或正在解析音轨列表...'),
                      )
                    : ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 400),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: tracks.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (_, idx) {
                            final t = tracks[idx];
                            final isSelected = current.id == t.id;
                            final label = _formatAudioTrackTitle(t, idx);
                            return InkWell(
                              autofocus: isSelected || idx == 0,
                              borderRadius: BorderRadius.circular(12),
                              onTap: () async {
                                await _player.setAudioTrack(t);
                                if (mounted) setState(() {});
                                if (ctx.mounted) {
                                  Navigator.of(ctx).pop();
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? VideoPlatformTheme.accent
                                          .withValues(alpha: 0.22)
                                      : VideoPlatformTheme.bgCard,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isSelected
                                        ? VideoPlatformTheme.accent
                                        : VideoPlatformTheme.borderSubtle,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      isSelected
                                          ? Icons.check_circle_rounded
                                          : Icons.audiotrack_rounded,
                                      size: 19,
                                      color: isSelected
                                          ? VideoPlatformTheme.accent
                                          : VideoPlatformTheme.textSecondary,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        '#${idx + 1}  $label',
                                        style: TextStyle(
                                          fontSize: 13.5,
                                          fontWeight: isSelected
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                    if (isSelected)
                                      const Text(
                                        '当前音轨',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.white,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
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
        );
      },
    );
    _wakeControls();
  }

  Widget _buildAudioTrackButton() {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _showAudioTrackSelectorDialog,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF1E3A8A).withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF60A5FA)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.surround_sound_rounded,
              size: 14,
              color: Color(0xFF93C5FD),
            ),
            SizedBox(width: 4),
            Text(
              '音轨 ▾',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExoHardwareButton() {
    if (!Platform.isAndroid) return const SizedBox.shrink();
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _openInEmbeddedExoPlayer,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF0284C7).withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF38BDF8)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bolt_rounded, size: 14, color: Color(0xFF38BDF8)),
            SizedBox(width: 3),
            Text(
              'Exo硬解',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: Color(0xFF38BDF8),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFitModePill() {
    final isFull = _fitMode != 'fit';
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _cycleFitMode,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isFull
              ? VideoPlatformTheme.accent.withValues(alpha: 0.22)
              : VideoPlatformTheme.bgCard.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isFull
                ? VideoPlatformTheme.accent
                : VideoPlatformTheme.borderSubtle,
          ),
        ),
        child: Text(
          _fitModeLabel(),
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: isFull
                ? VideoPlatformTheme.accent
                : VideoPlatformTheme.textPrimary,
          ),
        ),
      ),
    );
  }

  Widget _buildSpeedPopupPill() {
    return PopupMenuButton<double>(
      tooltip: '倍速播放',
      initialValue: _rate,
      onSelected: (r) {
        setState(() => _rate = r);
        _player.setRate(r);
        _wakeControls();
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 0.75, child: Text('0.75x')),
        PopupMenuItem(value: 1.0, child: Text('1.0x 正常')),
        PopupMenuItem(value: 1.25, child: Text('1.25x')),
        PopupMenuItem(value: 1.5, child: Text('1.5x')),
        PopupMenuItem(value: 2.0, child: Text('2.0x')),
        PopupMenuItem(value: 3.0, child: Text('3.0x')),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: _rate != 1.0
              ? VideoPlatformTheme.accent.withValues(alpha: 0.18)
              : VideoPlatformTheme.bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _rate != 1.0
                ? VideoPlatformTheme.accent
                : VideoPlatformTheme.borderSubtle,
          ),
        ),
        child: Text(
          '倍速 ${_rate}x',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: VideoPlatformTheme.accent,
          ),
        ),
      ),
    );
  }

  Widget _buildInteractiveVideoStage({required bool isMobileDialog}) {
    return LayoutBuilder(
      builder: (context, stageConstraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            setState(() => _controlsVisible = !_controlsVisible);
            if (_controlsVisible) {
              _scheduleOsdAutoHide();
            }
          },
          onDoubleTap: () {
            if (_isScreenLocked) {
              _wakeControls();
              return;
            }
            _player.playOrPause();
            _wakeControls();
          },
          onLongPressStart: (_) {
            if (_isScreenLocked) return;
            setState(() => _isLongPressFastForward = true);
            _player.setRate(3.0);
          },
          onLongPressEnd: (_) {
            if (!_isLongPressFastForward) return;
            setState(() => _isLongPressFastForward = false);
            _player.setRate(_rate);
          },
          onLongPressCancel: () {
            if (!_isLongPressFastForward) return;
            setState(() => _isLongPressFastForward = false);
            _player.setRate(_rate);
          },
          onHorizontalDragStart: (details) {
            if (_isScreenLocked) return;
            if (details.globalPosition.dx <= 36.0) return;
            setState(() {
              _isHorizontalSeeking = true;
              _seekStartPos = _player.state.position;
              _seekPreviewPos = _seekStartPos;
            });
          },
          onHorizontalDragUpdate: (details) {
            if (!_isHorizontalSeeking || _isScreenLocked) return;
            final stageW = stageConstraints.maxWidth.clamp(220.0, 1920.0);
            final maxSec = _duration.inSeconds > 0 ? _duration.inSeconds : 300;
            final spanSec = maxSec.clamp(60, 240);
            final deltaMs =
                ((details.delta.dx / stageW) * spanSec * 1000).round();
            final nextMs = (_seekPreviewPos.inMilliseconds + deltaMs)
                .clamp(0, maxSec * 1000);
            setState(() {
              _seekPreviewPos = Duration(milliseconds: nextMs);
            });
          },
          onHorizontalDragEnd: (_) {
            if (!_isHorizontalSeeking) return;
            final target = _seekPreviewPos;
            setState(() {
              _isHorizontalSeeking = false;
              _position = target;
            });
            _player.seek(target);
            _wakeControls();
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              Video(
                controller: _controller,
                width: stageConstraints.maxWidth,
                height: stageConstraints.maxHeight,
                fit: _resolveBoxFit(),
                fill: Colors.black,
                pauseUponEnteringBackgroundMode: false,
                resumeUponEnteringForegroundMode: true,
                controls: NoVideoControls,
              ),
              if (!isMobileDialog)
                Positioned(
                  top: 12,
                  right: 12,
                  child: VideoDownloadSpeedBadge(
                    player: _player,
                    compact: true,
                  ),
                ),
              if (_isLongPressFastForward)
                Positioned(
                  top: isMobileDialog ? 64 : 14,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xDD0D1824),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: VideoPlatformTheme.accent,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.bolt_rounded,
                              size: 16,
                              color: VideoPlatformTheme.accent,
                            ),
                            const SizedBox(width: 4),
                            const Text(
                              '3.0x 倍速快进中 (松手恢复)',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (_isHorizontalSeeking)
                Center(
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xE0090E14),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: VideoPlatformTheme.accent,
                          width: 1.4,
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${_seekPreviewPos >= _seekStartPos ? "⏩ 快进" : "⏪ 快退"}  ${_formatClock(_seekPreviewPos)} / ${_formatClock(_duration)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${(_seekPreviewPos.inSeconds - _seekStartPos.inSeconds) >= 0 ? "+" : ""}${_seekPreviewPos.inSeconds - _seekStartPos.inSeconds} 秒',
                            style: TextStyle(
                              color: VideoPlatformTheme.accent,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else if (_isBuffering)
                Center(
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: CircularProgressIndicator(
                        strokeWidth: 2.6,
                        color: VideoPlatformTheme.accent,
                      ),
                    ),
                  ),
                )
              else if (!_isPlaying && !_isScreenLocked)
                Center(
                  child: GestureDetector(
                    onTap: () {
                      _player.play();
                      _wakeControls();
                    },
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: const Color(0xAA090E14),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: VideoPlatformTheme.accent,
                          width: 2.0,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 40,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _osdHideTimer?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      if (_didChangeOrientation) {
        SystemChrome.setPreferredOrientations(const []);
      }
    }
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mqSize = MediaQuery.sizeOf(context);
    final viewPadding = MediaQuery.viewPaddingOf(context);
    final isMobileDialog = mqSize.shortestSide < 600 || mqSize.width < 760;
    final isLandscape =
        _landscapeOverride ?? (mqSize.width > mqSize.height);
    final effectiveDurMs = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds.toDouble()
        : (_player.state.duration.inMilliseconds > 0
            ? _player.state.duration.inMilliseconds.toDouble()
            : 1.0);
    final effectivePosMs = (_scrubOverrideMs ??
            _position.inMilliseconds.toDouble())
        .clamp(0.0, effectiveDurMs);

    if (isMobileDialog) {
      final showHud = _controlsVisible && !_isScreenLocked;
      final topInset = viewPadding.top > 4 ? viewPadding.top : 8.0;
      final bottomInset = viewPadding.bottom > 4 ? viewPadding.bottom : 8.0;
      final leftInset = viewPadding.left > 8 ? viewPadding.left : 10.0;
      final rightInset = viewPadding.right > 8 ? viewPadding.right : 10.0;

      return MobileEdgeSwipeBack(
        onBack: () => Navigator.of(context).pop(),
        child: Scaffold(
          backgroundColor: Colors.black,
          resizeToAvoidBottomInset: false,
          body: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            removeBottom: true,
            removeLeft: true,
            removeRight: true,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Layer 1: 100% Fullscreen Video Stage
                Positioned.fill(
                  child: _buildInteractiveVideoStage(isMobileDialog: true),
                ),

                // Layer 2: Floating Top Gradient HUD
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    ignoring: !showHud,
                    child: AnimatedOpacity(
                      opacity: showHud ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: Container(
                        padding: EdgeInsets.fromLTRB(
                          leftInset,
                          topInset,
                          rightInset,
                          14,
                        ),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Color(0xEB050A12),
                              Color(0xA6050A12),
                              Colors.transparent,
                            ],
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              height: 38,
                              child: Row(
                                children: [
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(
                                      Icons.arrow_back_ios_new_rounded,
                                      size: 18,
                                      color: Colors.white,
                                    ),
                                    onPressed: () =>
                                        Navigator.of(context).pop(),
                                  ),
                                  Expanded(
                                    child: Text(
                                      widget.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  VideoDownloadSpeedBadge(
                                    player: _player,
                                    compact: true,
                                  ),
                                  if (Platform.isAndroid || Platform.isIOS)
                                    IconButton(
                                      tooltip: '横竖屏切换',
                                      visualDensity: VisualDensity.compact,
                                      icon: const Icon(
                                        Icons.screen_rotation_rounded,
                                        size: 18,
                                        color: Colors.white,
                                      ),
                                      onPressed: _toggleOrientation,
                                    ),
                                  if (widget.onEnterMiniPlayer != null)
                                    IconButton(
                                      tooltip: '小窗播放',
                                      visualDensity: VisualDensity.compact,
                                      onPressed: () {
                                        final pos =
                                            _player.state.position.inSeconds;
                                        Navigator.of(context).pop();
                                        widget.onEnterMiniPlayer!(pos);
                                      },
                                      icon: const Icon(
                                        Icons.picture_in_picture_alt_rounded,
                                        size: 18,
                                        color: Colors.white,
                                      ),
                                    ),
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(
                                      Icons.close,
                                      size: 20,
                                      color: Colors.white,
                                    ),
                                    onPressed: () =>
                                        Navigator.of(context).pop(),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 2),
                            SizedBox(
                              height: 32,
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 4),
                                child: Row(
                                  children: [
                                    if (Platform.isAndroid) ...[
                                      _buildExoHardwareButton(),
                                      const SizedBox(width: 6),
                                    ],
                                    _buildAudioTrackButton(),
                                    const SizedBox(width: 6),
                                    _buildFitModePill(),
                                    const SizedBox(width: 6),
                                    _buildSpeedPopupPill(),
                                    const SizedBox(width: 6),
                                    PlayerVolumeControl(
                                      player: _player,
                                      compact: true,
                                      sliderWidth: 54,
                                      showPercentage: false,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // Layer 3: Mid-Left Screen Lock Button
                Positioned(
                  left: leftInset + 4,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: IgnorePointer(
                      ignoring: !_controlsVisible,
                      child: AnimatedOpacity(
                        opacity: _controlsVisible ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 200),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(22),
                          onTap: () {
                            setState(() {
                              _isScreenLocked = !_isScreenLocked;
                              _controlsVisible = true;
                            });
                            _scheduleOsdAutoHide();
                          },
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: _isScreenLocked
                                  ? VideoPlatformTheme.accent
                                      .withValues(alpha: 0.88)
                                  : const Color(0xAA060B14),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _isScreenLocked
                                    ? Colors.white
                                    : VideoPlatformTheme.borderStrong,
                              ),
                            ),
                            child: Icon(
                              _isScreenLocked
                                  ? Icons.lock_rounded
                                  : Icons.lock_open_rounded,
                              size: 19,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // Layer 4: Floating Bottom Gradient Transport & Seek Bar
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    ignoring: !showHud,
                    child: AnimatedOpacity(
                      opacity: showHud ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: Container(
                        padding: EdgeInsets.fromLTRB(
                          leftInset,
                          14,
                          rightInset,
                          bottomInset,
                        ),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Color(0xEB050A12),
                              Color(0xA6050A12),
                              Colors.transparent,
                            ],
                          ),
                        ),
                        child: Row(
                          children: [
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              tooltip: _isPlaying ? '暂停' : '播放',
                              onPressed: () {
                                _player.playOrPause();
                                _wakeControls();
                              },
                              icon: Icon(
                                _isPlaying
                                    ? Icons.pause_circle_filled_rounded
                                    : Icons.play_circle_fill_rounded,
                                size: 30,
                                color: VideoPlatformTheme.accent,
                              ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              tooltip: '快退 10 秒',
                              onPressed: () => _seekRelativeSeconds(-10),
                              icon: const Icon(
                                Icons.replay_10_rounded,
                                size: 20,
                                color: Colors.white,
                              ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              tooltip: '快进 10 秒',
                              onPressed: () => _seekRelativeSeconds(10),
                              icon: const Icon(
                                Icons.forward_10_rounded,
                                size: 20,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 2),
                            Text(
                              _formatClock(
                                Duration(milliseconds: effectivePosMs.round()),
                              ),
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                            Expanded(
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 3.5,
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 6.5,
                                  ),
                                  overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 12,
                                  ),
                                  activeTrackColor: VideoPlatformTheme.accent,
                                  inactiveTrackColor: Colors.white24,
                                  thumbColor: Colors.white,
                                ),
                                child: Slider(
                                  value: effectivePosMs,
                                  min: 0.0,
                                  max: effectiveDurMs,
                                  onChanged: (v) {
                                    setState(() => _scrubOverrideMs = v);
                                    _osdHideTimer?.cancel();
                                  },
                                  onChangeEnd: (v) {
                                    final target =
                                        Duration(milliseconds: v.round());
                                    setState(() {
                                      _scrubOverrideMs = null;
                                      _position = target;
                                    });
                                    _player.seek(target);
                                    _scheduleOsdAutoHide();
                                  },
                                ),
                              ),
                            ),
                            Text(
                              _formatClock(_duration),
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: Colors.white70,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                            const SizedBox(width: 2),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              tooltip: '切换画面比例 (${_fitModeLabel()})',
                              onPressed: _cycleFitMode,
                              icon: Icon(
                                _fitMode == 'fit'
                                    ? Icons.aspect_ratio_rounded
                                    : Icons.fit_screen_rounded,
                                size: 20,
                                color: _fitMode == 'fit'
                                    ? Colors.white70
                                    : VideoPlatformTheme.accent,
                              ),
                            ),
                            if (Platform.isAndroid || Platform.isIOS)
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                tooltip: isLandscape ? '切换竖屏全屏' : '进入横屏全屏',
                                onPressed: _toggleOrientation,
                                icon: Icon(
                                  isLandscape
                                      ? Icons.fullscreen_exit_rounded
                                      : Icons.fullscreen_rounded,
                                  size: 24,
                                  color: Colors.white,
                                ),
                              ),
                          ],
                        ),
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

    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(14),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 1200,
          maxHeight: 820,
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
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (Platform.isAndroid) ...[
                    _buildExoHardwareButton(),
                    const SizedBox(width: 6),
                  ],
                  _buildAudioTrackButton(),
                  const SizedBox(width: 6),
                  _buildFitModePill(),
                  const SizedBox(width: 6),
                  _buildSpeedPopupPill(),
                  const SizedBox(width: 6),
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
              child: _buildInteractiveVideoStage(isMobileDialog: false),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
              decoration: BoxDecoration(
                color: VideoPlatformTheme.bgElevated,
                border: Border(
                  top: BorderSide(color: VideoPlatformTheme.borderSubtle),
                ),
              ),
              child: Row(
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: _isPlaying ? '暂停' : '播放',
                    onPressed: () {
                      _player.playOrPause();
                      _wakeControls();
                    },
                    icon: Icon(
                      _isPlaying
                          ? Icons.pause_circle_filled_rounded
                          : Icons.play_circle_fill_rounded,
                      size: 30,
                      color: VideoPlatformTheme.accent,
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '快退 10 秒',
                    onPressed: () => _seekRelativeSeconds(-10),
                    icon: const Icon(Icons.replay_10_rounded, size: 19),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '快进 10 秒',
                    onPressed: () => _seekRelativeSeconds(10),
                    icon: const Icon(Icons.forward_10_rounded, size: 19),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _formatClock(
                      Duration(milliseconds: effectivePosMs.round()),
                    ),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: VideoPlatformTheme.textPrimary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3.5,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6.5,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 12,
                        ),
                        activeTrackColor: VideoPlatformTheme.accent,
                        inactiveTrackColor: VideoPlatformTheme.borderStrong,
                        thumbColor: Colors.white,
                      ),
                      child: Slider(
                        value: effectivePosMs,
                        min: 0.0,
                        max: effectiveDurMs,
                        onChanged: (v) {
                          setState(() => _scrubOverrideMs = v);
                          _osdHideTimer?.cancel();
                        },
                        onChangeEnd: (v) {
                          final target = Duration(milliseconds: v.round());
                          setState(() {
                            _scrubOverrideMs = null;
                            _position = target;
                          });
                          _player.seek(target);
                          _scheduleOsdAutoHide();
                        },
                      ),
                    ),
                  ),
                  Text(
                    _formatClock(_duration),
                    style: TextStyle(
                      fontSize: 12,
                      color: VideoPlatformTheme.textSecondary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
