import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../state/app_state.dart';
import '../theme.dart';

class SourcePickerDialog extends StatefulWidget {
  final List<VodSource> sources;
  final VodSource? selectedSource;
  final ValueChanged<VodSource> onSelect;
  final AppState? appState;

  const SourcePickerDialog({
    super.key,
    required this.sources,
    required this.selectedSource,
    required this.onSelect,
    this.appState,
  });

  static Future<void> show(
    BuildContext context, {
    required List<VodSource> sources,
    required VodSource? selectedSource,
    required ValueChanged<VodSource> onSelect,
    AppState? appState,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => SourcePickerDialog(
        sources: sources,
        selectedSource: selectedSource,
        onSelect: onSelect,
        appState: appState,
      ),
    );
  }

  @override
  State<SourcePickerDialog> createState() => _SourcePickerDialogState();
}

class _SourcePickerDialogState extends State<SourcePickerDialog> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  String _filter = '';
  int _tabIndex = 0; // 0: 全部, 1: 标准资源站, 2: TVBox 站点, 3: 已置顶
  bool _sortByLatency = false;
  bool _didInitialAutoFocus = false;

  // Local fallback speed test state when appState is not provided
  final Map<String, int> _localLatencyMs = {};
  final Set<String> _localTestingIds = {};
  final Set<String> _localPinnedIds = {};
  bool _localBatchTesting = false;

  @override
  void initState() {
    super.initState();
    _scrollToSelectedSourceOnce();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  List<VodSource> get _effectiveAllSources {
    final state = widget.appState;
    if (state != null && state.visibleSources.isNotEmpty) {
      return state.visibleSources;
    }
    return widget.sources;
  }

  Map<String, int> get _latencyMap =>
      widget.appState?.sourceLatencyMs ?? _localLatencyMs;

  Set<String> get _testingIds =>
      widget.appState?.testingSourceIds ?? _localTestingIds;

  Set<String> get _pinnedIds =>
      widget.appState?.pinnedSourceIds ?? _localPinnedIds;

  bool get _isBatchTesting =>
      widget.appState?.isTestingSources ?? _localBatchTesting;

  bool _isPinned(String id) => _pinnedIds.contains(id);

  int? _latencyOf(String id) => _latencyMap[id];

  bool _isTestingSource(String id) => _testingIds.contains(id);

  Future<void> _triggerBatchTest() async {
    final state = widget.appState;
    final list = _computeFilteredSources();
    final targets = list.isNotEmpty ? list : _effectiveAllSources;
    if (state != null) {
      await state.batchTestVodSources(targetSources: targets);
      return;
    }
    if (_localBatchTesting || targets.isEmpty) return;
    setState(() => _localBatchTesting = true);
    for (final src in targets.take(24)) {
      await _triggerSingleTest(src);
    }
    if (mounted) {
      setState(() => _localBatchTesting = false);
    }
  }

  Future<void> _triggerSingleTest(VodSource src) async {
    final state = widget.appState;
    if (state != null) {
      await state.testSingleVodSource(src);
      return;
    }
    if (_localTestingIds.contains(src.id)) return;
    setState(() => _localTestingIds.add(src.id));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    setState(() {
      _localTestingIds.remove(src.id);
      _localLatencyMs[src.id] = 160;
    });
  }

  Future<void> _togglePin(VodSource src) async {
    final state = widget.appState;
    if (state != null) {
      await state.togglePinSource(src.id);
      return;
    }
    setState(() {
      if (_localPinnedIds.contains(src.id)) {
        _localPinnedIds.remove(src.id);
      } else {
        _localPinnedIds.add(src.id);
      }
    });
  }

  void _applySortByLatency() {
    setState(() => _sortByLatency = !_sortByLatency);
    widget.appState?.sortSourcesByLatency();
  }

  VodSource? _findFastestOnlineSource([List<VodSource>? candidates]) {
    final list = candidates ?? _effectiveAllSources;
    VodSource? best;
    int bestMs = 999999;
    for (final s in list) {
      final ms = _latencyOf(s.id);
      if (ms != null && ms > 0 && ms < bestMs) {
        bestMs = ms;
        best = s;
      }
    }
    return best;
  }

  List<VodSource> _computeFilteredSources() {
    final kw = _filter.trim().toLowerCase();
    final all = _effectiveAllSources;
    final list = all.where((s) {
      if (_tabIndex == 1 && s.isTvBox) return false;
      if (_tabIndex == 2 && !s.isTvBox) return false;
      if (_tabIndex == 3 && !_isPinned(s.id)) return false;
      if (kw.isEmpty) return true;
      return s.name.toLowerCase().contains(kw) ||
          s.tvboxSourceName.toLowerCase().contains(kw) ||
          s.groupLabel.toLowerCase().contains(kw) ||
          s.api.toLowerCase().contains(kw);
    }).toList();

    list.sort((a, b) {
      final ap = _isPinned(a.id) ? 0 : 1;
      final bp = _isPinned(b.id) ? 0 : 1;
      if (ap != bp) return ap.compareTo(bp);
      if (_sortByLatency && _latencyMap.isNotEmpty) {
        final la = _latencyOf(a.id);
        final lb = _latencyOf(b.id);
        final effA = (la == null) ? 500000 : (la <= 0 ? 999999 : la);
        final effB = (lb == null) ? 500000 : (lb <= 0 ? 999999 : lb);
        if (effA != effB) return effA.compareTo(effB);
      }
      return 0;
    });
    return list;
  }

  void _scrollToSelectedSourceOnce() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _didInitialAutoFocus = true;
      if (!_scrollController.hasClients) return;
      final selectedId = widget.selectedSource?.id;
      if (selectedId == null || selectedId.isEmpty) return;
      final filtered = _computeFilteredSources();
      final idx = filtered.indexWhere((s) => s.id == selectedId);
      if (idx <= 0) return;
      const estimatedItemExtent = 74.0;
      final pos = _scrollController.position;
      final targetOffset =
          (idx * estimatedItemExtent - pos.viewportDimension * 0.35)
              .clamp(0.0, pos.maxScrollExtent);
      _scrollController.jumpTo(targetOffset);
    });
  }

  static String _extractCleanApiLabel(VodSource src) {
    final raw = src.api.trim();
    if (raw.isEmpty) return src.groupLabel;
    if (raw.startsWith('csp_')) return '内置爬虫 · $raw';
    final uri = Uri.tryParse(raw);
    if (uri != null && uri.host.isNotEmpty) {
      return uri.host;
    }
    return raw.length > 36 ? '${raw.substring(0, 36)}...' : raw;
  }

  static String _protocolTypeTag(VodSource src) {
    if (!src.isTvBox) {
      return src.api.toLowerCase().contains('xml') ? 'CMS XML' : 'CMS JSON';
    }
    return switch (src.tvboxType) {
      0 => 'TVBox XML',
      1 => 'TVBox JSON',
      3 => 'Spider JAR',
      4 => 'Remote Spider',
      _ => 'TVBox',
    };
  }

  static ({
    String label,
    String grade,
    Color color,
    IconData icon,
    int bars,
  }) _describeLatency(int? ms, {required bool isTesting}) {
    if (isTesting) {
      return (
        label: '测速中...',
        grade: '检测中',
        color: VideoPlatformTheme.accent,
        icon: Icons.sync_rounded,
        bars: 2,
      );
    }
    if (ms == null) {
      return (
        label: '点击测速',
        grade: '待测速',
        color: VideoPlatformTheme.textMuted,
        icon: Icons.speed_rounded,
        bars: 0,
      );
    }
    if (ms <= 0) {
      return (
        label: '连接超时',
        grade: '不可达',
        color: VideoPlatformTheme.danger,
        icon: Icons.error_outline_rounded,
        bars: 0,
      );
    }
    if (ms < 500) {
      return (
        label: '${ms}ms',
        grade: '极速',
        color: const Color(0xFF22C55E),
        icon: Icons.bolt_rounded,
        bars: 4,
      );
    }
    if (ms < 1200) {
      return (
        label: '${ms}ms',
        grade: '良好',
        color: const Color(0xFF38BDF8),
        icon: Icons.network_check_rounded,
        bars: 3,
      );
    }
    if (ms < 2500) {
      return (
        label: '${ms}ms',
        grade: '一般',
        color: VideoPlatformTheme.warning,
        icon: Icons.signal_cellular_alt_2_bar_rounded,
        bars: 2,
      );
    }
    return (
      label: '${ms}ms',
      grade: '较慢',
      color: const Color(0xFFF97316),
      icon: Icons.signal_cellular_alt_1_bar_rounded,
      bars: 1,
    );
  }

  @override
  Widget build(BuildContext context) {
    final listenable = widget.appState;
    if (listenable != null) {
      return ListenableBuilder(
        listenable: listenable,
        builder: (ctx, _) => _buildDialogContent(ctx),
      );
    }
    return _buildDialogContent(context);
  }

  Widget _buildDialogContent(BuildContext context) {
    final allSources = _effectiveAllSources;
    final filtered = _computeFilteredSources();
    final customCount = allSources.where((s) => !s.isTvBox).length;
    final tvboxCount = allSources.where((s) => s.isTvBox).length;
    final pinnedCount = allSources.where((s) => _isPinned(s.id)).length;

    int testedCount = 0;
    int fastCount = 0;
    int onlineCount = 0;
    int timeoutCount = 0;
    for (final s in allSources) {
      final ms = _latencyOf(s.id);
      if (ms != null) {
        testedCount++;
        if (ms > 0) {
          onlineCount++;
          if (ms < 600) fastCount++;
        } else {
          timeoutCount++;
        }
      }
    }
    final fastestSource = _findFastestOnlineSource(filtered);
    final screenW = MediaQuery.sizeOf(context).width;
    final isCompact = screenW < 640;

    final actionButtons = <Widget>[
      _buildHeaderActionButton(
        key: const ValueKey('source_picker_batch_test_btn'),
        onPressed: _isBatchTesting ? null : _triggerBatchTest,
        icon: _isBatchTesting
            ? SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: VideoPlatformTheme.accent,
                ),
              )
            : Icon(
                Icons.speed_rounded,
                size: 15,
                color: VideoPlatformTheme.accent,
              ),
        label: _isBatchTesting
            ? '测速中 ($testedCount/${allSources.take(40).length})'
            : '一键测速',
        highlighted: true,
      ),
      _buildHeaderActionButton(
        key: const ValueKey('source_picker_sort_speed_btn'),
        onPressed: _applySortByLatency,
        icon: Icon(
          Icons.sort_rounded,
          size: 15,
          color: _sortByLatency
              ? VideoPlatformTheme.accent
              : VideoPlatformTheme.textSecondary,
        ),
        label: _sortByLatency ? '已按速度排序' : '按速度排序',
        highlighted: _sortByLatency,
      ),
      if (fastestSource != null)
        _buildHeaderActionButton(
          key: const ValueKey('source_picker_pick_fastest_btn'),
          onPressed: () {
            Navigator.of(context).pop();
            widget.onSelect(fastestSource);
          },
          icon: const Icon(
            Icons.bolt_rounded,
            size: 15,
            color: Colors.white,
          ),
          label: '秒选最快 (${_latencyOf(fastestSource.id)}ms)',
          solidBgColor: const Color(0xFF16A34A),
          solidFgColor: Colors.white,
        ),
    ];

    final filterTabChips = <Widget>[
      _buildFilterTab(
        0,
        '全部 (${allSources.length})',
        Icons.apps_rounded,
      ),
      _buildFilterTab(
        1,
        '标准资源站 ($customCount)',
        Icons.dns_rounded,
      ),
      _buildFilterTab(
        2,
        'TVBox 站点 ($tvboxCount)',
        Icons.extension_rounded,
      ),
      if (pinnedCount > 0 || _tabIndex == 3)
        _buildFilterTab(
          3,
          '常用置顶 ($pinnedCount)',
          Icons.push_pin_rounded,
        ),
    ];

    return Dialog(
      backgroundColor: VideoPlatformTheme.bgElevated,
      surfaceTintColor: Colors.transparent,
      insetPadding: EdgeInsets.symmetric(
        horizontal: isCompact ? 10 : 22,
        vertical: isCompact ? 14 : 24,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: VideoPlatformTheme.borderStrong),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 680),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. Top Header Bar with Title, Stats & Batch Speed Test Controls
            Container(
              padding: EdgeInsets.fromLTRB(
                isCompact ? 12 : 18,
                isCompact ? 11 : 14,
                isCompact ? 8 : 14,
                isCompact ? 10 : 12,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    VideoPlatformTheme.accent.withValues(alpha: 0.12),
                    VideoPlatformTheme.bgElevated,
                  ],
                ),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(14),
                ),
                border: Border(
                  bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: isCompact ? 32 : 34,
                        height: isCompact ? 32 : 34,
                        decoration: BoxDecoration(
                          color:
                              VideoPlatformTheme.accent.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(
                            color: VideoPlatformTheme.accent
                                .withValues(alpha: 0.45),
                          ),
                        ),
                        child: Icon(
                          Icons.hub_rounded,
                          size: isCompact ? 16 : 18,
                          color: VideoPlatformTheme.accent,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    '切换片源站点',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: isCompact ? 15 : 16,
                                      fontWeight: FontWeight.w800,
                                      color: VideoPlatformTheme.textPrimary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: VideoPlatformTheme.bgCard,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: VideoPlatformTheme.borderSubtle,
                                    ),
                                  ),
                                  child: Text(
                                    '共 ${allSources.length} 个站点',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: VideoPlatformTheme.textSecondary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              testedCount > 0
                                  ? '已测速 $testedCount 个 · 可用 $onlineCount 个 (极速 $fastCount 个) · 超时 $timeoutCount 个'
                                  : '支持并发检测各站点连接延迟、按速度排序与一键优选最快片源',
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
                      if (!isCompact) ...[
                        const SizedBox(width: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: actionButtons,
                        ),
                      ],
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: '关闭',
                        icon: const Icon(Icons.close_rounded, size: 19),
                        onPressed: () => Navigator.of(context).pop(),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                  if (isCompact) ...[
                    const SizedBox(height: 8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (int i = 0; i < actionButtons.length; i++) ...[
                            if (i > 0) const SizedBox(width: 6),
                            actionButtons[i],
                          ],
                        ],
                      ),
                    ),
                  ],
                  if (_isBatchTesting) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        minHeight: 3,
                        backgroundColor: VideoPlatformTheme.bgCard,
                        color: VideoPlatformTheme.accent,
                      ),
                    ),
                  ],
                  SizedBox(height: isCompact ? 8 : 12),
                  // 2. Category Tabs + Search Box Row
                  if (isCompact) ...[
                    _buildSearchField(context, isCompact: true),
                    const SizedBox(height: 8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (int i = 0; i < filterTabChips.length; i++) ...[
                            if (i > 0) const SizedBox(width: 6),
                            filterTabChips[i],
                          ],
                        ],
                      ),
                    ),
                  ] else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      alignment: WrapAlignment.spaceBetween,
                      children: [
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: filterTabChips,
                        ),
                        _buildSearchField(context, isCompact: false),
                      ],
                    ),
                ],
              ),
            ),

            // 3. Source Card List
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.search_off_rounded,
                            size: 38,
                            color: VideoPlatformTheme.textMuted,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '没有匹配的站点',
                            style: TextStyle(
                              color: VideoPlatformTheme.textSecondary,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (_filter.isNotEmpty || _tabIndex != 0) ...[
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: () {
                                _searchController.clear();
                                setState(() {
                                  _filter = '';
                                  _tabIndex = 0;
                                });
                              },
                              icon: const Icon(Icons.refresh_rounded, size: 15),
                              label: const Text('重置筛选条件'),
                            ),
                          ],
                        ],
                      ),
                    )
                  : ListView.separated(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(14),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final src = filtered[index];
                        final isSelected =
                            widget.selectedSource?.id == src.id;
                        return _buildSourceItemTile(
                          context,
                          src: src,
                          index: index,
                          isSelected: isSelected,
                          autofocus: !_didInitialAutoFocus &&
                              (isSelected ||
                                  (widget.selectedSource == null &&
                                      index == 0)),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderActionButton({
    required Key key,
    required VoidCallback? onPressed,
    required Widget icon,
    required String label,
    bool highlighted = false,
    Color? solidBgColor,
    Color? solidFgColor,
  }) {
    final disabled = onPressed == null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(18),
        onFocusChange: (_) {
          if (mounted) setState(() {});
        },
        onTap: onPressed,
        child: Builder(
          builder: (ctx) {
            final isFocused = Focus.of(ctx).hasPrimaryFocus;
            final bgColor = solidBgColor != null
                ? (isFocused
                    ? solidBgColor.withValues(alpha: 0.92)
                    : solidBgColor)
                : (isFocused
                    ? VideoPlatformTheme.accent.withValues(alpha: 0.28)
                    : (highlighted
                        ? VideoPlatformTheme.accent.withValues(alpha: 0.16)
                        : VideoPlatformTheme.bgCard));
            final borderColor = isFocused
                ? Colors.white
                : (solidBgColor ??
                    (highlighted
                        ? VideoPlatformTheme.accent
                        : VideoPlatformTheme.borderSubtle));
            final textColor = solidFgColor ??
                (isFocused
                    ? Colors.white
                    : (highlighted
                        ? VideoPlatformTheme.accent
                        : (disabled
                            ? VideoPlatformTheme.textMuted
                            : VideoPlatformTheme.textSecondary)));
            return AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6.5),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: borderColor,
                  width: isFocused ? 2.0 : 1.0,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  icon,
                  const SizedBox(width: 5),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: (highlighted || isFocused || solidBgColor != null)
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: textColor,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSearchField(BuildContext context, {required bool isCompact}) {
    final isTv = widget.appState?.tvMode ?? false;
    if (isTv) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onFocusChange: (_) {
              if (mounted) setState(() {});
            },
            onTap: () => _openSourceFilterInputDialog(context),
            child: Builder(
              builder: (ctx) {
                final isFocused = Focus.of(ctx).hasPrimaryFocus;
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: isFocused
                        ? VideoPlatformTheme.accent.withValues(alpha: 0.24)
                        : VideoPlatformTheme.bgInput,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isFocused
                          ? VideoPlatformTheme.accent
                          : VideoPlatformTheme.borderSubtle,
                      width: isFocused ? 2.0 : 1.0,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.search_rounded,
                        size: 15,
                        color: isFocused
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.textMuted,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        _filter.isEmpty ? '搜索站点...' : '筛选: $_filter',
                        style: TextStyle(
                          fontSize: 12,
                          color: _filter.isNotEmpty
                              ? VideoPlatformTheme.accent
                              : VideoPlatformTheme.textSecondary,
                          fontWeight: _filter.isNotEmpty
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          if (_filter.isNotEmpty) ...[
            const SizedBox(width: 4),
            IconButton(
              tooltip: '清除站点筛选',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.clear_rounded, size: 16),
              onPressed: () {
                _searchController.clear();
                setState(() => _filter = '');
              },
            ),
          ],
        ],
      );
    }

    return SizedBox(
      width: isCompact ? double.infinity : 220,
      height: 34,
      child: TextField(
        controller: _searchController,
        onChanged: (v) => setState(() => _filter = v.trim()),
        style: const TextStyle(fontSize: 12.5),
        decoration: InputDecoration(
          hintText: '搜索站点名称或分组...',
          prefixIcon: const Icon(Icons.search_rounded, size: 15),
          suffixIcon: _filter.isNotEmpty
              ? IconButton(
                  padding: EdgeInsets.zero,
                  tooltip: '清除站点筛选',
                  icon: const Icon(Icons.clear_rounded, size: 14),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _filter = '');
                  },
                )
              : null,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10),
        ),
      ),
    );
  }

  Future<void> _openSourceFilterInputDialog(BuildContext context) async {
    final ctrl = TextEditingController(text: _filter);
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VideoPlatformTheme.bgElevated,
        title: const Text(
          '搜索片源站点',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
            decoration: const InputDecoration(
              hintText: '输入站点名（如：量子、非凡、红牛、玩偶）...',
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ),
        ),
        actions: [
          if (_filter.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(''),
              child: const Text('清空筛选'),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (res != null && mounted) {
      _searchController.text = res.trim();
      setState(() => _filter = res.trim());
    }
  }

  Widget _buildSignalBars(int activeBars, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(4, (i) {
        final barHeight = 5.0 + i * 2.6;
        final active = i < activeBars;
        return Container(
          width: 2.8,
          height: barHeight,
          margin: const EdgeInsets.only(right: 1.5),
          decoration: BoxDecoration(
            color: active
                ? color
                : VideoPlatformTheme.textMuted.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(1.5),
          ),
        );
      }),
    );
  }

  Widget _buildSourceItemTile(
    BuildContext context, {
    required VodSource src,
    required int index,
    required bool isSelected,
    required bool autofocus,
  }) {
    final isPinned = _isPinned(src.id);
    final ms = _latencyOf(src.id);
    final isTesting = _isTestingSource(src.id);
    final latencyInfo = _describeLatency(ms, isTesting: isTesting);
    final protoTag = _protocolTypeTag(src);
    final hostLabel = _extractCleanApiLabel(src);
    final isTv = widget.appState?.tvMode ?? false;
    final isCompact = MediaQuery.sizeOf(context).width < 640;

    return StatefulBuilder(
      builder: (tileCtx, setTileState) {
        return Material(
          color: Colors.transparent,
          child: InkWell(
            autofocus: autofocus,
            borderRadius: BorderRadius.circular(10),
            onFocusChange: (_) {
              if (tileCtx.mounted) {
                setTileState(() {});
              }
            },
            onTap: () {
              Navigator.of(context).pop();
              widget.onSelect(src);
            },
            child: Builder(
              builder: (ctx) {
                final isFocused = Focus.of(ctx).hasPrimaryFocus;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  padding: EdgeInsets.symmetric(
                    horizontal: isCompact ? 10 : 13,
                    vertical: isCompact ? 9 : 11,
                  ),
                  decoration: BoxDecoration(
                    color: isFocused
                        ? VideoPlatformTheme.accent.withValues(alpha: 0.22)
                        : (isSelected
                            ? VideoPlatformTheme.accent.withValues(alpha: 0.12)
                            : VideoPlatformTheme.bgCard),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isFocused
                          ? (isTv ? Colors.white : VideoPlatformTheme.accent)
                          : (isSelected
                              ? VideoPlatformTheme.accent.withValues(alpha: 0.65)
                              : VideoPlatformTheme.borderSubtle),
                      width: isFocused ? (isTv ? 2.2 : 1.6) : (isSelected ? 1.6 : 1.0),
                    ),
                  ),
                  child: Row(
                    children: [
                      // Leading Source Avatar / Type Badge
                      Container(
                        width: isCompact ? 34 : 38,
                        height: isCompact ? 34 : 38,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: isSelected
                                ? [
                                    VideoPlatformTheme.accent,
                                    VideoPlatformTheme.accent
                                        .withValues(alpha: 0.72),
                                  ]
                                : (src.isTvBox
                                    ? [
                                        const Color(0xFF6366F1)
                                            .withValues(alpha: 0.22),
                                        const Color(0xFF4F46E5)
                                            .withValues(alpha: 0.12),
                                      ]
                                    : [
                                        VideoPlatformTheme.accent
                                            .withValues(alpha: 0.20),
                                        VideoPlatformTheme.accent
                                            .withValues(alpha: 0.08),
                                      ]),
                          ),
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(
                            color: isSelected
                                ? VideoPlatformTheme.accent
                                : (src.isTvBox
                                    ? const Color(0xFF6366F1)
                                        .withValues(alpha: 0.4)
                                    : VideoPlatformTheme.accent
                                        .withValues(alpha: 0.35)),
                          ),
                        ),
                        alignment: Alignment.center,
                        child: isSelected
                            ? Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: isCompact ? 19 : 21,
                              )
                            : Text(
                                src.name.trim().isNotEmpty
                                    ? src.name.trim().characters.first
                                    : '${index + 1}',
                                style: TextStyle(
                                  fontSize: isCompact ? 13 : 14,
                                  fontWeight: FontWeight.w800,
                                  color: src.isTvBox
                                      ? const Color(0xFF818CF8)
                                      : VideoPlatformTheme.accent,
                                ),
                              ),
                      ),
                      SizedBox(width: isCompact ? 10 : 12),

                      // Center: Source Name + Tags + Host Info
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                if (isPinned) ...[
                                  Icon(
                                    Icons.push_pin_rounded,
                                    size: 13.5,
                                    color: VideoPlatformTheme.warning,
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                Flexible(
                                  child: Text(
                                    src.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: (isSelected || isFocused)
                                          ? VideoPlatformTheme.accent
                                          : VideoPlatformTheme.textPrimary,
                                      fontSize: isCompact ? 13.5 : 14,
                                      fontWeight: (isSelected || isFocused)
                                          ? FontWeight.w700
                                          : FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (isSelected) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 1.5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: VideoPlatformTheme.accent
                                          .withValues(alpha: 0.18),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(
                                        color: VideoPlatformTheme.accent
                                            .withValues(alpha: 0.6),
                                      ),
                                    ),
                                    child: Text(
                                      '当前使用',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        color: VideoPlatformTheme.accent,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 5),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                _buildMiniMetaBadge(
                                  label: src.groupLabel,
                                  color: src.isTvBox
                                      ? const Color(0xFF818CF8)
                                      : VideoPlatformTheme.accent,
                                ),
                                _buildMiniMetaBadge(
                                  label: protoTag,
                                  color: VideoPlatformTheme.textSecondary,
                                ),
                                if (src.searchable && !isCompact)
                                  _buildMiniMetaBadge(
                                    label: '支持聚合搜',
                                    color: const Color(0xFF10B981),
                                  ),
                                Text(
                                  hostLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: VideoPlatformTheme.textMuted,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),

                      // Right: Interactive Latency / Speed Test Pill + Pin Button
                      ExcludeFocus(
                        excluding: isTv,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Tooltip(
                              message: '点击单独测试「${src.name}」连接响应速度',
                              child: InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: isTesting
                                    ? null
                                    : () => _triggerSingleTest(src),
                                child: Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: isCompact ? 7 : 9,
                                    vertical: isCompact ? 5 : 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: latencyInfo.color
                                        .withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: latencyInfo.color
                                          .withValues(alpha: 0.42),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (isTesting)
                                        SizedBox(
                                          width: 12,
                                          height: 12,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 1.8,
                                            color: latencyInfo.color,
                                          ),
                                        )
                                      else
                                        _buildSignalBars(
                                          latencyInfo.bars,
                                          latencyInfo.color,
                                        ),
                                      const SizedBox(width: 5),
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            latencyInfo.label,
                                            style: TextStyle(
                                              fontSize: isCompact ? 11 : 11.5,
                                              fontWeight: FontWeight.w700,
                                              color: latencyInfo.color,
                                            ),
                                          ),
                                          Text(
                                            latencyInfo.grade,
                                            style: TextStyle(
                                              fontSize: 9.5,
                                              color: latencyInfo.color
                                                  .withValues(alpha: 0.85),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 2),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 30,
                                minHeight: 30,
                              ),
                              tooltip: isPinned ? '取消置顶此站点' : '置顶此常用站点',
                              onPressed: () => _togglePin(src),
                              icon: Icon(
                                isPinned
                                    ? Icons.push_pin_rounded
                                    : Icons.push_pin_outlined,
                                size: 15.5,
                                color: isPinned
                                    ? VideoPlatformTheme.warning
                                    : VideoPlatformTheme.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildMiniMetaBadge({
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _buildFilterTab(int index, String label, IconData icon) {
    final active = _tabIndex == index;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      onTap: () => setState(() => _tabIndex = index),
      child: Builder(
        builder: (ctx) {
          final isFocused = Focus.of(ctx).hasPrimaryFocus;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(
              color: active
                  ? VideoPlatformTheme.accent
                  : (isFocused
                      ? VideoPlatformTheme.accent.withValues(alpha: 0.25)
                      : VideoPlatformTheme.bgCard),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: (active || isFocused)
                    ? VideoPlatformTheme.accent
                    : VideoPlatformTheme.borderSubtle,
                width: isFocused ? 2.0 : 1.0,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 13.5,
                  color: active
                      ? Colors.white
                      : (isFocused
                          ? VideoPlatformTheme.accent
                          : VideoPlatformTheme.textSecondary),
                ),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    color: active
                        ? Colors.white
                        : (isFocused
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.textSecondary),
                    fontSize: 12,
                    fontWeight: (active || isFocused)
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
}
