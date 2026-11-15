import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../theme.dart';

class SourcePickerDialog extends StatefulWidget {
  final List<VodSource> sources;
  final VodSource? selectedSource;
  final ValueChanged<VodSource> onSelect;

  const SourcePickerDialog({
    super.key,
    required this.sources,
    required this.selectedSource,
    required this.onSelect,
  });

  static Future<void> show(
    BuildContext context, {
    required List<VodSource> sources,
    required VodSource? selectedSource,
    required ValueChanged<VodSource> onSelect,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => SourcePickerDialog(
        sources: sources,
        selectedSource: selectedSource,
        onSelect: onSelect,
      ),
    );
  }

  @override
  State<SourcePickerDialog> createState() => _SourcePickerDialogState();
}

class _SourcePickerDialogState extends State<SourcePickerDialog> {
  String _filter = '';
  int _tabIndex = 0; // 0: 全部, 1: 采集资源站, 2: TVBox 站点

  @override
  Widget build(BuildContext context) {
    final kw = _filter.trim().toLowerCase();
    final filtered = widget.sources.where((s) {
      if (_tabIndex == 1 && s.isTvBox) return false;
      if (_tabIndex == 2 && !s.isTvBox) return false;
      if (kw.isEmpty) return true;
      return s.name.toLowerCase().contains(kw) ||
          s.tvboxSourceName.toLowerCase().contains(kw);
    }).toList();

    final customCount = widget.sources.where((s) => !s.isTvBox).length;
    final tvboxCount = widget.sources.where((s) => s.isTvBox).length;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '切换片源站点',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: VideoPlatformTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '共 ${widget.sources.length} 个可用站点',
                    style: TextStyle(
                      fontSize: 12,
                      color: VideoPlatformTheme.textMuted,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.of(context).pop(),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _buildFilterTab(0, '全部 (${widget.sources.length})'),
                  const SizedBox(width: 8),
                  _buildFilterTab(1, '标准资源站 ($customCount)'),
                  const SizedBox(width: 8),
                  _buildFilterTab(2, 'TVBox 站点 ($tvboxCount)'),
                  const Spacer(),
                  _buildSearchButtonOrBar(context),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Text(
                          '没有匹配的站点',
                          style: TextStyle(
                            color: VideoPlatformTheme.textMuted,
                            fontSize: 13,
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final src = filtered[index];
                          final isSelected =
                              widget.selectedSource?.id == src.id;
                          return _buildSourceItemTile(
                            context,
                            src: src,
                            isSelected: isSelected,
                            autofocus: isSelected ||
                                (widget.selectedSource == null && index == 0),
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

  Widget _buildSearchButtonOrBar(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onFocusChange: (_) {
            if (mounted) setState(() {});
          },
          onTap: () => _openSourceFilterInputDialog(context),
          child: Builder(
            builder: (ctx) {
              final isFocused = Focus.of(ctx).hasPrimaryFocus;
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: isFocused
                      ? VideoPlatformTheme.accent.withValues(alpha: 0.24)
                      : VideoPlatformTheme.bgInput,
                  borderRadius: BorderRadius.circular(6),
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
            onPressed: () => setState(() => _filter = ''),
          ),
        ],
      ],
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
      setState(() => _filter = res.trim());
    }
  }

  Widget _buildSourceItemTile(
    BuildContext context, {
    required VodSource src,
    required bool isSelected,
    required bool autofocus,
  }) {
    return InkWell(
      autofocus: autofocus,
      borderRadius: BorderRadius.circular(6),
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      onTap: () {
        Navigator.of(context).pop();
        widget.onSelect(src);
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isFocused
                  ? VideoPlatformTheme.accent.withValues(alpha: 0.25)
                  : (isSelected
                      ? VideoPlatformTheme.accent.withValues(alpha: 0.12)
                      : Colors.transparent),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isFocused
                    ? VideoPlatformTheme.accent
                    : (isSelected
                        ? VideoPlatformTheme.accent.withValues(alpha: 0.5)
                        : Colors.transparent),
                width: isFocused ? 2.0 : 1.0,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        src.name,
                        style: TextStyle(
                          color: (isSelected || isFocused)
                              ? VideoPlatformTheme.accent
                              : VideoPlatformTheme.textPrimary,
                          fontSize: 13.5,
                          fontWeight: (isSelected || isFocused)
                              ? FontWeight.w700
                              : FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        src.groupLabel,
                        style: TextStyle(
                          color: VideoPlatformTheme.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isSelected)
                  Icon(
                    Icons.check_circle,
                    color: VideoPlatformTheme.accent,
                    size: 18,
                  )
                else
                  Icon(
                    Icons.chevron_right,
                    color: isFocused
                        ? VideoPlatformTheme.accent
                        : VideoPlatformTheme.textMuted,
                    size: 18,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildFilterTab(int index, String label) {
    final active = _tabIndex == index;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      onTap: () => setState(() => _tabIndex = index),
      child: Builder(
        builder: (ctx) {
          final isFocused = Focus.of(ctx).hasPrimaryFocus;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: active
                  ? VideoPlatformTheme.accent
                  : (isFocused
                      ? VideoPlatformTheme.accent.withValues(alpha: 0.25)
                      : VideoPlatformTheme.bgCard),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: (active || isFocused)
                    ? VideoPlatformTheme.accent
                    : VideoPlatformTheme.borderSubtle,
                width: isFocused ? 2.0 : 1.0,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: active
                    ? Colors.white
                    : (isFocused
                        ? VideoPlatformTheme.accent
                        : VideoPlatformTheme.textSecondary),
                fontSize: 12,
                fontWeight: (active || isFocused)
                    ? FontWeight.w600
                    : FontWeight.w400,
              ),
            ),
          );
        },
      ),
    );
  }
}
