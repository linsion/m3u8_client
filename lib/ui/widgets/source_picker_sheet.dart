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
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                autofocus: false,
                onChanged: (v) => setState(() => _filter = v),
                decoration: InputDecoration(
                  hintText: '搜索站点名称（如：红牛、量子、非凡、豆瓣、玩偶）...',
                  prefixIcon: Icon(
                    Icons.search,
                    size: 18,
                    color: VideoPlatformTheme.textMuted,
                  ),
                ),
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
                          return ListTile(
                            dense: true,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                            selected: isSelected,
                            selectedTileColor:
                                VideoPlatformTheme.accent.withValues(alpha: 0.12),
                            title: Text(
                              src.name,
                              style: TextStyle(
                                color: isSelected
                                    ? VideoPlatformTheme.accent
                                    : VideoPlatformTheme.textPrimary,
                                fontSize: 13,
                                fontWeight: isSelected
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                            subtitle: Text(
                              src.groupLabel,
                              style: TextStyle(
                                color: VideoPlatformTheme.textMuted,
                                fontSize: 11,
                              ),
                            ),
                            trailing: isSelected
                                ? Icon(
                                    Icons.check_circle,
                                    color: VideoPlatformTheme.accent,
                                    size: 18,
                                  )
                                : Icon(
                                    Icons.chevron_right,
                                    color: VideoPlatformTheme.textMuted,
                                    size: 16,
                                  ),
                            onTap: () {
                              Navigator.of(context).pop();
                              widget.onSelect(src);
                            },
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

  Widget _buildFilterTab(int index, String label) {
    final active = _tabIndex == index;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => setState(() => _tabIndex = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? VideoPlatformTheme.accent : VideoPlatformTheme.bgCard,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: active
                ? VideoPlatformTheme.accent
                : VideoPlatformTheme.borderSubtle,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : VideoPlatformTheme.textSecondary,
            fontSize: 12,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
