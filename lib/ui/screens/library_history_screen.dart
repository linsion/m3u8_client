import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/models.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets/vod_poster_card.dart';
import 'vod_detail_player_screen.dart';

class LibraryHistoryScreen extends StatefulWidget {
  final AppState appState;

  const LibraryHistoryScreen({
    super.key,
    required this.appState,
  });

  @override
  State<LibraryHistoryScreen> createState() => _LibraryHistoryScreenState();
}

class _LibraryHistoryScreenState extends State<LibraryHistoryScreen> {
  int _tabIndex = 0; // 0: 观看历史, 1: 我的收藏
  String _searchQuery = '';
  String _sourceFilterKey = '';
  final TextEditingController _searchCtrl = TextEditingController();

  bool _isBatchMode = false;
  final Set<String> _selectedKeys = {};

  bool _isCheckingUpdates = false;
  final Map<String, ({String latestRemark, String latestEpisode, bool hasNew})>
      _favUpdateMap = {};

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String _itemKey(LibraryItem item) => '${item.source}|${item.vodId}';

  String _formatSeconds(double sec) {
    final total = sec.round();
    if (total <= 0) return '00:00';
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    if (h > 0) return '$h:$mm:$ss';
    return '$mm:$ss';
  }

  void _openLibraryItem(LibraryItem item) {
    final src = widget.appState.findSourceByLibraryKey(item.source);
    if (src == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未找到对应的数据源站点')),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VodDetailPlayerScreen(
          appState: widget.appState,
          source: src,
          vodId: item.vodId,
          initialTitle: item.title,
          initialPoster: item.poster,
          preferredLine: item.line.isNotEmpty ? item.line : null,
          preferredEpisodeTitle: item.episode.isNotEmpty ? item.episode : null,
          initialResumeSeconds: item.position,
        ),
      ),
    );
  }

  Future<void> _checkFavoritesUpdates() async {
    final favs = widget.appState.favorites;
    if (_isCheckingUpdates || favs.isEmpty) return;
    setState(() => _isCheckingUpdates = true);

    var updatedCount = 0;
    const batchSize = 4;
    for (var i = 0; i < favs.length; i += batchSize) {
      if (!mounted) break;
      final batch = favs.skip(i).take(batchSize);
      await Future.wait(
        batch.map((item) async {
          final src = widget.appState.findSourceByLibraryKey(item.source);
          if (src == null) return;
          try {
            final detail = await widget.appState.api.fetchVodDetail(
              src,
              item.vodId,
            );
            String latestEp = '';
            if (detail.playGroups.isNotEmpty &&
                detail.playGroups.first.episodes.isNotEmpty) {
              latestEp = detail.playGroups.first.episodes.last.title;
            }
            final latestRem = detail.vodRemarks.trim();
            final hasNew = (latestRem.isNotEmpty && latestRem != item.remark) ||
                (latestEp.isNotEmpty &&
                    item.episode.isNotEmpty &&
                    latestEp != item.episode);
            if (hasNew) updatedCount++;
            _favUpdateMap[_itemKey(item)] = (
              latestRemark: latestRem,
              latestEpisode: latestEp,
              hasNew: hasNew,
            );
          } catch (_) {}
        }),
      );
      if (mounted) setState(() {});
    }

    if (mounted) {
      setState(() => _isCheckingUpdates = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            updatedCount > 0
                ? '🔔 检测完成：发现 $updatedCount 部收藏剧集有最新剧集/状态更新'
                : '检测完成：所有收藏剧集均为最新状态',
          ),
        ),
      );
    }
  }

  Future<void> _exportLibraryBackup() async {
    final payload = {
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'favorites': widget.appState.favorites.map((e) => e.toJson()).toList(),
      'history': widget.appState.history.map((e) => e.toJson()).toList(),
    };
    final jsonStr = const JsonEncoder.withIndent('  ').convert(payload);
    await Clipboard.setData(ClipboardData(text: jsonStr));

    try {
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          Directory.systemTemp.path;
      final downloadsDir = Directory('$home/Downloads');
      final targetDir =
          await downloadsDir.exists() ? downloadsDir : Directory.systemTemp;
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final file = File('${targetDir.path}/m3u8_library_backup_$ts.json');
      await file.writeAsString(jsonStr, flush: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已导出备份文件并复制到剪贴板：${file.path}'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已将历史与收藏 JSON 备份复制到剪贴板')),
      );
    }
  }

  Future<void> _showImportLibraryDialog() async {
    final ctrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VideoPlatformTheme.bgElevated,
        title: const Text(
          '导入恢复观看历史与收藏备份 (JSON)',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '粘贴导出的 JSON 备份内容，将自动合并到当前收藏与观看历史：',
                      style: TextStyle(
                        fontSize: 12,
                        color: VideoPlatformTheme.textSecondary,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      final data =
                          await Clipboard.getData(Clipboard.kTextPlain);
                      if (data?.text != null) {
                        ctrl.text = data!.text!;
                      }
                    },
                    icon: const Icon(Icons.content_paste_rounded, size: 15),
                    label: const Text('粘贴剪贴板'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                maxLines: 8,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  hintText: '{"favorites": [...], "history": [...]}',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('立即导入'),
          ),
        ],
      ),
    );

    if (confirmed == true && ctrl.text.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(ctrl.text.trim());
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('JSON 顶层格式无效');
        }
        final favs = <LibraryItem>[];
        final hist = <LibraryItem>[];
        if (decoded['favorites'] is List) {
          for (final item in decoded['favorites'] as List) {
            if (item is Map<String, dynamic>) {
              favs.add(LibraryItem.fromJson(item));
            }
          }
        }
        if (decoded['history'] is List) {
          for (final item in decoded['history'] as List) {
            if (item is Map<String, dynamic>) {
              hist.add(LibraryItem.fromJson(item));
            }
          }
        }
        final count = await widget.appState.importLibraryBackup(
          favorites: favs,
          history: hist,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已成功导入恢复 $count 条记录')),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败：$e')),
        );
      }
    }
    ctrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.appState;
    final rawItems = _tabIndex == 0 ? state.history : state.favorites;
    final kind = _tabIndex == 0 ? 'history' : 'favorites';

    // Distinct sources in current tab
    final sourceCounts = <String, int>{};
    for (final item in rawItems) {
      if (item.source.isNotEmpty) {
        sourceCounts[item.source] = (sourceCounts[item.source] ?? 0) + 1;
      }
    }

    final kw = _searchQuery.trim().toLowerCase();
    final items = rawItems.where((item) {
      if (_sourceFilterKey.isNotEmpty && item.source != _sourceFilterKey) {
        return false;
      }
      if (kw.isEmpty) return true;
      final srcName =
          state.findSourceByLibraryKey(item.source)?.name.toLowerCase() ?? '';
      return item.title.toLowerCase().contains(kw) ||
          item.episode.toLowerCase().contains(kw) ||
          item.remark.toLowerCase().contains(kw) ||
          srcName.contains(kw);
    }).toList();

    return Column(
      children: [
        Container(
          height: 50,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12),
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
                _buildTabButton(0, '观看历史 (${state.history.length})'),
                const SizedBox(width: 10),
                _buildTabButton(1, '我的收藏 (${state.favorites.length})'),
                const SizedBox(width: 12),
                if (!state.tvMode)
                  SizedBox(
                    width: 190,
                    height: 32,
                    child: TextField(
                      controller: _searchCtrl,
                      onChanged: (v) => setState(() => _searchQuery = v),
                      style: const TextStyle(fontSize: 12.5),
                      decoration: InputDecoration(
                        hintText: '搜索片名、集数或站点...',
                        prefixIcon: const Icon(Icons.search_rounded, size: 16),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.clear_rounded, size: 14),
                                onPressed: () {
                                  _searchCtrl.clear();
                                  setState(() => _searchQuery = '');
                                },
                              )
                            : null,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                  ),
                const SizedBox(width: 12),
                if (_tabIndex == 1 && state.favorites.isNotEmpty) ...[
                  OutlinedButton.icon(
                    onPressed:
                        _isCheckingUpdates ? null : _checkFavoritesUpdates,
                    icon: Icon(
                      Icons.notifications_active_outlined,
                      size: 15,
                      color: VideoPlatformTheme.accent,
                    ),
                    label: Text(_isCheckingUpdates ? '检测更新中...' : '检测剧集更新'),
                  ),
                  const SizedBox(width: 8),
                ],
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() {
                      _isBatchMode = !_isBatchMode;
                      _selectedKeys.clear();
                    });
                  },
                  icon: Icon(
                    _isBatchMode
                        ? Icons.checklist_rtl_rounded
                        : Icons.select_all_rounded,
                    size: 15,
                  ),
                  label: Text(_isBatchMode ? '退出多选' : '批量管理'),
                ),
                if (_isBatchMode && items.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        if (_selectedKeys.length == items.length) {
                          _selectedKeys.clear();
                        } else {
                          _selectedKeys.addAll(items.map(_itemKey));
                        }
                      });
                    },
                    child: Text(
                      _selectedKeys.length == items.length ? '取消全选' : '全选',
                    ),
                  ),
                  if (_selectedKeys.isNotEmpty)
                    FilledButton.tonalIcon(
                      onPressed: () async {
                        final toDelete = items
                            .where((i) => _selectedKeys.contains(_itemKey(i)))
                            .toList();
                        setState(() => _selectedKeys.clear());
                        for (final item in toDelete) {
                          await state.deleteLibraryEntry(kind, item);
                        }
                      },
                      icon: Icon(
                        Icons.delete_outline,
                        size: 15,
                        color: VideoPlatformTheme.danger,
                      ),
                      label: Text('删除 (${_selectedKeys.length})'),
                    ),
                ],
                if (rawItems.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final msg =
                          _tabIndex == 0 ? '已清空全部观看历史' : '已清空全部收藏记录';
                      setState(() {
                        _selectedKeys.clear();
                        _sourceFilterKey = '';
                      });
                      await state.clearLibraryKind(kind);
                      if (!mounted) return;
                      messenger.showSnackBar(
                        SnackBar(content: Text(msg)),
                      );
                    },
                    icon: Icon(
                      Icons.delete_sweep_outlined,
                      size: 15,
                      color: VideoPlatformTheme.danger,
                    ),
                    label: Text(
                      _tabIndex == 0 ? '清空历史' : '清空收藏',
                      style: TextStyle(color: VideoPlatformTheme.danger),
                    ),
                  ),
                ],
                const SizedBox(width: 6),
                PopupMenuButton<String>(
                  tooltip: '备份导出 / 恢复导入 / 清空',
                  icon: const Icon(Icons.more_vert_rounded, size: 18),
                  onSelected: (action) async {
                    if (action == 'sync') {
                      state.refreshLibrary();
                    } else if (action == 'export') {
                      _exportLibraryBackup();
                    } else if (action == 'import') {
                      _showImportLibraryDialog();
                    } else if (action == 'clear') {
                      final messenger = ScaffoldMessenger.of(context);
                      final msg =
                          _tabIndex == 0 ? '已清空全部观看历史' : '已清空全部收藏记录';
                      setState(() {
                        _selectedKeys.clear();
                        _sourceFilterKey = '';
                      });
                      await state.clearLibraryKind(kind);
                      if (!mounted) return;
                      messenger.showSnackBar(
                        SnackBar(content: Text(msg)),
                      );
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'sync',
                      child: Row(
                        children: [
                          Icon(Icons.sync_rounded, size: 17),
                          SizedBox(width: 8),
                          Text('同步云端记录'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'export',
                      child: Row(
                        children: [
                          Icon(Icons.download_rounded, size: 17),
                          SizedBox(width: 8),
                          Text('导出本地 JSON 备份'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'import',
                      child: Row(
                        children: [
                          Icon(Icons.upload_file_rounded, size: 17),
                          SizedBox(width: 8),
                          Text('从 JSON 备份恢复导入'),
                        ],
                      ),
                    ),
                    if (rawItems.isNotEmpty) ...[
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: 'clear',
                        child: Row(
                          children: [
                            Icon(
                              Icons.delete_sweep_outlined,
                              size: 17,
                              color: VideoPlatformTheme.danger,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _tabIndex == 0 ? '清空全部观看历史' : '清空全部收藏',
                              style:
                                  TextStyle(color: VideoPlatformTheme.danger),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
        if (sourceCounts.length > 1)
          Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: VideoPlatformTheme.bgElevated,
              border: Border(
                bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
              ),
            ),
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _buildSourceChip('', '全部站点 (${rawItems.length})'),
                ...sourceCounts.entries.map((e) {
                  final srcName =
                      state.findSourceByLibraryKey(e.key)?.name ?? e.key;
                  return _buildSourceChip(e.key, '$srcName (${e.value})');
                }),
              ],
            ),
          ),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _tabIndex == 0
                            ? Icons.history_rounded
                            : Icons.star_border_rounded,
                        size: 42,
                        color: VideoPlatformTheme.textMuted,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _tabIndex == 0 ? '暂无匹配的观看历史记录' : '暂无匹配的收藏影视剧集',
                        style: TextStyle(
                          color: VideoPlatformTheme.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 350,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 2.45,
                  ),
                  itemCount: items.length,
                  itemBuilder: (_, idx) {
                    final item = items[idx];
                    return _buildHistoryCard(item, kind);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildSourceChip(String key, String label) {
    final selected = _sourceFilterKey == key;
    return Padding(
      padding: const EdgeInsets.only(right: 8, top: 5, bottom: 5),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onFocusChange: (_) {
          if (mounted) setState(() {});
        },
        onTap: () => setState(() => _sourceFilterKey = key),
        child: Builder(
          builder: (ctx) {
            final isFocused = Focus.of(ctx).hasPrimaryFocus;
            if (isFocused) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (ctx.mounted) {
                  Scrollable.ensureVisible(
                    ctx,
                    alignment: 0.5,
                    duration: const Duration(milliseconds: 140),
                  );
                }
              });
            }
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isFocused
                    ? VideoPlatformTheme.accent.withValues(alpha: 0.28)
                    : (selected
                        ? VideoPlatformTheme.accent.withValues(alpha: 0.18)
                        : VideoPlatformTheme.bgCard),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: (selected || isFocused)
                      ? VideoPlatformTheme.accent
                      : VideoPlatformTheme.borderSubtle,
                  width: isFocused ? 2.0 : 1.0,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  color: (selected || isFocused)
                      ? VideoPlatformTheme.accent
                      : VideoPlatformTheme.textSecondary,
                  fontWeight: (selected || isFocused)
                      ? FontWeight.w600
                      : FontWeight.w400,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildTabButton(int index, String label) {
    final selected = _tabIndex == index;
    return InkWell(
      borderRadius: BorderRadius.circular(5),
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      onTap: () => setState(() {
        _tabIndex = index;
        _sourceFilterKey = '';
        _selectedKeys.clear();
      }),
      child: Builder(
        builder: (ctx) {
          final isFocused = Focus.of(ctx).hasPrimaryFocus;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: selected
                  ? VideoPlatformTheme.accent
                  : (isFocused
                      ? VideoPlatformTheme.accent.withValues(alpha: 0.25)
                      : VideoPlatformTheme.bgCard),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                color: (selected || isFocused)
                    ? VideoPlatformTheme.accent
                    : Colors.transparent,
                width: isFocused ? 2.0 : 1.0,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: selected
                    ? Colors.white
                    : (isFocused
                        ? VideoPlatformTheme.accent
                        : VideoPlatformTheme.textSecondary),
                fontWeight: (selected || isFocused)
                    ? FontWeight.w600
                    : FontWeight.w400,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildHistoryCard(LibraryItem item, String kind) {
    final rawPoster = item.poster.trim();
    final srcObj = widget.appState.findSourceByLibraryKey(item.source);
    final key = _itemKey(item);
    final checked = _selectedKeys.contains(key);
    final updateInfo = _favUpdateMap[key];
    final progressRatio = item.duration > 0
        ? (item.position / item.duration).clamp(0.02, 1.0)
        : 0.0;

    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      onTap: () {
        if (_isBatchMode) {
          setState(() {
            if (checked) {
              _selectedKeys.remove(key);
            } else {
              _selectedKeys.add(key);
            }
          });
        } else {
          _openLibraryItem(item);
        }
      },
      child: Builder(
        builder: (ctx) {
          final isFocused = Focus.of(ctx).hasPrimaryFocus;
          if (isFocused) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (ctx.mounted) {
                Scrollable.ensureVisible(
                  ctx,
                  alignment: 0.4,
                  duration: const Duration(milliseconds: 140),
                );
              }
            });
          }
          return Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isFocused
                  ? VideoPlatformTheme.accent.withValues(alpha: 0.16)
                  : VideoPlatformTheme.bgElevated,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: (checked || isFocused)
                    ? VideoPlatformTheme.accent
                    : VideoPlatformTheme.borderSubtle,
                width: isFocused ? 2.2 : (checked ? 1.5 : 1.0),
              ),
            ),
        child: Row(
          children: [
            if (_isBatchMode) ...[
              Checkbox(
                value: checked,
                activeColor: VideoPlatformTheme.accent,
                onChanged: (_) {
                  setState(() {
                    if (checked) {
                      _selectedKeys.remove(key);
                    } else {
                      _selectedKeys.add(key);
                    }
                  });
                },
              ),
              const SizedBox(width: 4),
            ],
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Container(
                width: 70,
                height: double.infinity,
                color: VideoPlatformTheme.bgCard,
                child: rawPoster.isNotEmpty
                    ? VodCachedPosterImage(
                        rawPicUrl: rawPoster,
                        api: widget.appState.api,
                        cacheWidth: 180,
                        placeholderBuilder: (_) => Icon(
                          Icons.movie_outlined,
                          color: VideoPlatformTheme.textMuted,
                        ),
                      )
                    : Icon(
                        Icons.movie_outlined,
                        color: VideoPlatformTheme.textMuted,
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: VideoPlatformTheme.textPrimary,
                          ),
                        ),
                      ),
                      if (updateInfo != null && updateInfo.hasNew)
                        Container(
                          margin: const EdgeInsets.only(left: 4),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color:
                                VideoPlatformTheme.danger.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '有更新',
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                              color: VideoPlatformTheme.danger,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  if (item.episode.isNotEmpty)
                    Text(
                      '观看到：${item.episode} ${item.position > 0 ? "(${_formatSeconds(item.position)})" : ""}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: VideoPlatformTheme.accent,
                      ),
                    ),
                  if (updateInfo != null &&
                      (updateInfo.latestRemark.isNotEmpty ||
                          updateInfo.latestEpisode.isNotEmpty)) ...[
                    const SizedBox(height: 2),
                    Text(
                      '最新：${updateInfo.latestRemark.isNotEmpty ? updateInfo.latestRemark : updateInfo.latestEpisode}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: updateInfo.hasNew
                            ? VideoPlatformTheme.success
                            : VideoPlatformTheme.textSecondary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 3),
                  Text(
                    srcObj != null ? '来源：${srcObj.name}' : '来源：${item.source}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: VideoPlatformTheme.textMuted,
                    ),
                  ),
                  if (progressRatio > 0) ...[
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: progressRatio,
                              minHeight: 3,
                              backgroundColor: VideoPlatformTheme.borderSubtle,
                              color: VideoPlatformTheme.accent,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${(progressRatio * 100).round()}%',
                          style: TextStyle(
                            fontSize: 10,
                            color: VideoPlatformTheme.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (!_isBatchMode)
              IconButton(
                tooltip: '移除',
                icon: Icon(
                  Icons.close,
                  size: 16,
                  color: VideoPlatformTheme.textMuted,
                ),
                onPressed: () => widget.appState.deleteLibraryEntry(kind, item),
              ),
          ],
        ),
      );
        },
      ),
    );
  }
}
