import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets/source_picker_sheet.dart';
import '../widgets/vod_poster_card.dart';
import 'vod_detail_player_screen.dart';

class VodHomeScreen extends StatefulWidget {
  final AppState appState;

  const VodHomeScreen({
    super.key,
    required this.appState,
  });

  @override
  State<VodHomeScreen> createState() => _VodHomeScreenState();
}

class _VodHomeScreenState extends State<VodHomeScreen> {
  static final Map<String, double> _savedScrollOffsets = {};

  final ScrollController _scrollController = ScrollController();
  final ScrollController _categoryScrollController = ScrollController();
  final TextEditingController _categoryFilterCtrl = TextEditingController();
  bool _categoriesExpanded = false;
  String _categoryFilterQuery = '';
  String _selectedCategoryGroupTab = '全部';
  String? _lastSourceId;
  String? _lastTypeId;
  String _lastSearchKeyword = '';
  int _lastItemCount = 0;

  String _viewCacheKey({
    String? sourceId,
    String? typeId,
    String? searchKeyword,
  }) {
    final s = sourceId ?? widget.appState.selectedSource?.id ?? '';
    final t = typeId ?? widget.appState.selectedTypeId;
    final q = searchKeyword ?? widget.appState.searchKeyword;
    return '$s|$t|$q';
  }

  void _restoreScrollForCurrentView() {
    final key = _viewCacheKey();
    final savedOffset = _savedScrollOffsets[key] ?? 0.0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final maxExt = _scrollController.position.maxScrollExtent;
      final target = savedOffset.clamp(0.0, maxExt);
      if ((_scrollController.offset - target).abs() > 1.0) {
        _scrollController.jumpTo(target);
      }
      _checkViewportAndAutoLoadMore();
    });
  }

  @override
  void initState() {
    super.initState();
    _lastSourceId = widget.appState.selectedSource?.id;
    _lastTypeId = widget.appState.selectedTypeId;
    _lastSearchKeyword = widget.appState.searchKeyword;
    _lastItemCount = widget.appState.vodItems.length;
    _scrollController.addListener(_onScroll);
    widget.appState.addListener(_onAppStateChanged);
    _restoreScrollForCurrentView();
  }

  @override
  void didUpdateWidget(covariant VodHomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appState != widget.appState) {
      oldWidget.appState.removeListener(_onAppStateChanged);
      widget.appState.addListener(_onAppStateChanged);
    }
  }

  @override
  void dispose() {
    widget.appState.removeListener(_onAppStateChanged);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _categoryScrollController.dispose();
    _categoryFilterCtrl.dispose();
    super.dispose();
  }

  void _onAppStateChanged() {
    if (!mounted) return;
    final state = widget.appState;
    final curSourceId = state.selectedSource?.id;
    final curTypeId = state.selectedTypeId;
    final curSearch = state.searchKeyword;

    if (curSourceId != _lastSourceId) {
      _lastSourceId = curSourceId;
      _lastTypeId = curTypeId;
      _lastSearchKeyword = curSearch;
      _lastItemCount = state.vodItems.length;
      _categoriesExpanded = false;
      _categoryFilterQuery = '';
      _selectedCategoryGroupTab = '全部';
      _categoryFilterCtrl.clear();
      if (_categoryScrollController.hasClients) {
        _categoryScrollController.jumpTo(0);
      }
      _restoreScrollForCurrentView();
    } else if (curTypeId != _lastTypeId || curSearch != _lastSearchKeyword) {
      _lastTypeId = curTypeId;
      _lastSearchKeyword = curSearch;
      _lastItemCount = state.vodItems.length;
      _restoreScrollForCurrentView();
    }

    if (!state.isLoadingVod &&
        !state.isLoadingMoreVod &&
        state.vodItems.length != _lastItemCount) {
      _lastItemCount = state.vodItems.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _checkViewportAndAutoLoadMore();
      });
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    _savedScrollOffsets[_viewCacheKey()] = pos.pixels;
    if (pos.pixels >= pos.maxScrollExtent - 420) {
      widget.appState.loadMoreVod();
    }
  }

  /// Automatically loads the next page when the currently loaded items do not
  /// fill the viewport (e.g. Page 1 has 20 items on a wide screen so
  /// `maxScrollExtent <= 420`) or when scroll position is already near the bottom.
  void _checkViewportAndAutoLoadMore() {
    if (!mounted || !_scrollController.hasClients) return;
    final state = widget.appState;
    if (!state.hasMoreVod || state.isLoadingVod || state.isLoadingMoreVod) {
      return;
    }
    final pos = _scrollController.position;
    if (pos.maxScrollExtent <= 420 ||
        pos.pixels >= pos.maxScrollExtent - 420) {
      state.loadMoreVod();
    }
  }

  void _openVodItem(VodItem item) {
    if (item.isAlistDirectory) {
      widget.appState.enterAlistDirectory(item);
      return;
    }
    if (item.isSearchJumpItem) {
      widget.appState.setAggregatedSearch(true);
      widget.appState.performSearch(item.vodName);
      return;
    }
    final src = item.source ?? widget.appState.selectedSource;
    if (src == null) return;

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VodDetailPlayerScreen(
          appState: widget.appState,
          source: src,
          vodId: item.vodId,
          initialTitle: item.vodName,
          initialPoster: item.vodPic,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.appState;

    return PopScope(
      canPop: !_categoriesExpanded,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _categoriesExpanded) {
          setState(() => _categoriesExpanded = false);
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top category filter bar or search status banner
          if (state.searchKeyword.isNotEmpty)
            _buildSearchStatusBar(state)
          else
            _buildCategoryFilterBar(state),

          // Alist directory breadcrumbs if inside a folder
          if (state.directoryBreadcrumbs.isNotEmpty &&
              state.searchKeyword.isEmpty)
            _buildDirectoryBreadcrumbs(state),

          // Main content area + Floating All-Categories Overlay Drawer
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: _buildBodyContent(state),
                ),
                if (_categoriesExpanded && state.searchKeyword.isEmpty) ...[
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _categoriesExpanded = false),
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.48),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _buildExpandedCategoryDrawer(state),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _scrollCategoriesBy(double delta) {
    if (!_categoryScrollController.hasClients) return;
    final pos = _categoryScrollController.position;
    final target = (pos.pixels + delta).clamp(0.0, pos.maxScrollExtent);
    _categoryScrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _selectCategoryAndSync(AppState state, String typeId, int indexInList) {
    setState(() {
      _categoriesExpanded = false;
    });
    state.selectCategory(typeId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_categoryScrollController.hasClients) return;
      final pos = _categoryScrollController.position;
      final estimatedOffset = (indexInList * 84.0) - (pos.viewportDimension / 2) + 42.0;
      _categoryScrollController.animateTo(
        estimatedOffset.clamp(0.0, pos.maxScrollExtent),
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Widget _buildCategoryFilterBar(AppState state) {
    final categories = state.categories;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isCompactMobile = screenWidth < 580;

    return Container(
      height: 48,
      padding: EdgeInsets.symmetric(horizontal: isCompactMobile ? 10 : 16),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        border: Border(
          bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: Row(
        children: [
          // Single-line horizontal scrollable category ribbon
          Expanded(
            child: SizedBox(
              height: 34,
              child: Listener(
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent &&
                      _categoryScrollController.hasClients) {
                    final delta = event.scrollDelta.dx != 0
                        ? event.scrollDelta.dx
                        : event.scrollDelta.dy;
                    final pos = _categoryScrollController.position;
                    _categoryScrollController.jumpTo(
                      (pos.pixels + delta).clamp(0.0, pos.maxScrollExtent),
                    );
                  }
                },
                child: ListView(
                  controller: _categoryScrollController,
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  children: [
                    _buildCategoryChip(
                      label: '全部推荐',
                      selected: state.selectedTypeId.isEmpty,
                      onTap: () => _selectCategoryAndSync(state, '', 0),
                    ),
                    ...categories.asMap().entries.map(
                      (entry) => Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: _buildCategoryChip(
                          label: entry.value.typeName,
                          selected: state.selectedTypeId == entry.value.typeId,
                          onTap: () => _selectCategoryAndSync(
                            state,
                            entry.value.typeId,
                            entry.key + 1,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (!isCompactMobile && categories.length > 5) ...[
            const SizedBox(width: 6),
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => _scrollCategoriesBy(-260),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.chevron_left_rounded,
                  size: 19,
                  color: VideoPlatformTheme.textSecondary,
                ),
              ),
            ),
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => _scrollCategoriesBy(260),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 19,
                  color: VideoPlatformTheme.textSecondary,
                ),
              ),
            ),
          ],
          const SizedBox(width: 6),
          // "全部分类" pill button that toggles the floating category dropdown window
          InkWell(
            borderRadius: BorderRadius.circular(7),
            onFocusChange: (_) {
              if (mounted) setState(() {});
            },
            onTap: () {
              final nextExpanded = !_categoriesExpanded;
              setState(() => _categoriesExpanded = nextExpanded);
              if (nextExpanded &&
                  state.categories.isEmpty &&
                  !state.isLoadingVod) {
                state.loadVodCatalog(
                  resetCategories: true,
                  forceRefresh: true,
                );
              }
            },
            child: Builder(
              builder: (ctx) {
                final isFocused = Focus.of(ctx).hasPrimaryFocus;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: _categoriesExpanded
                        ? VideoPlatformTheme.accent
                        : (isFocused
                            ? VideoPlatformTheme.accent.withValues(alpha: 0.26)
                            : VideoPlatformTheme.bgCard),
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color: (_categoriesExpanded || isFocused)
                          ? VideoPlatformTheme.accent
                          : VideoPlatformTheme.borderSubtle,
                      width: isFocused ? 2.0 : 1.0,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _categoriesExpanded
                            ? Icons.close_fullscreen_rounded
                            : Icons.grid_view_rounded,
                        size: 14,
                        color: _categoriesExpanded
                            ? Colors.white
                            : VideoPlatformTheme.accent,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _categoriesExpanded
                            ? '收起'
                            : (isCompactMobile
                                ? '分类 (${categories.length + 1})'
                                : '全部分类 (${categories.length + 1})'),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _categoriesExpanded
                              ? Colors.white
                              : (isFocused
                                  ? VideoPlatformTheme.accent
                                  : VideoPlatformTheme.textPrimary),
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        _categoriesExpanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: 16,
                        color: _categoriesExpanded
                            ? Colors.white
                            : (isFocused
                                ? VideoPlatformTheme.accent
                                : VideoPlatformTheme.textSecondary),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          if (!isCompactMobile && state.totalCount > 0) ...[
            const SizedBox(width: 10),
            Text(
              '共 ${state.totalCount} 部',
              style: TextStyle(
                fontSize: 12,
                color: VideoPlatformTheme.textMuted,
              ),
            ),
          ],
          if (!isCompactMobile) ...[
            const SizedBox(width: 8),
            Tooltip(
              message: state.aggregatedSearch
                  ? '当前：全网多站点聚合搜索（点击切换为单站搜索）'
                  : '当前：仅搜索当前站点（点击开启全网聚合搜索）',
              child: InkWell(
                borderRadius: BorderRadius.circular(5),
                onFocusChange: (_) {
                  if (mounted) setState(() {});
                },
                onTap: () => state.setAggregatedSearch(!state.aggregatedSearch),
                child: Builder(
                  builder: (ctx) {
                    final isFocused = Focus.of(ctx).hasPrimaryFocus;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isFocused
                            ? VideoPlatformTheme.accent.withValues(alpha: 0.28)
                            : (state.aggregatedSearch
                                ? VideoPlatformTheme.accent
                                    .withValues(alpha: 0.16)
                                : VideoPlatformTheme.bgCard),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(
                          color: (state.aggregatedSearch || isFocused)
                              ? VideoPlatformTheme.accent
                              : VideoPlatformTheme.borderSubtle,
                          width: isFocused ? 2.0 : 1.0,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            state.aggregatedSearch
                                ? Icons.travel_explore_rounded
                                : Icons.location_on_outlined,
                            size: 14,
                            color: (state.aggregatedSearch || isFocused)
                                ? VideoPlatformTheme.accent
                                : VideoPlatformTheme.textSecondary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            state.aggregatedSearch ? '全网搜' : '单站搜',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: (state.aggregatedSearch || isFocused)
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: (state.aggregatedSearch || isFocused)
                                  ? VideoPlatformTheme.accent
                                  : VideoPlatformTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Categorizes CMS categories into intuitive sections for the expanded matrix drawer.
  String _classifyCategoryGroup(String name) {
    final n = name.trim();
    if (RegExp(
      r'(电影|动作|喜剧|爱情|科幻|恐怖|剧情|战争|灾难|悬疑|犯罪|奇幻|惊悚|院线|蓝光|4K|粤语片|邵氏|经典片|动画片|微电影)',
      caseSensitive: false,
    ).hasMatch(n)) {
      return '电影频道';
    }
    if (RegExp(
      r'(剧|连续|国产|香港|台湾|韩国|日本|欧美|海外|泰国|新马|英美|短剧|爽剧|TVB)',
      caseSensitive: false,
    ).hasMatch(n)) {
      return '剧集剧场';
    }
    if (RegExp(
      r'(动漫|动画|番剧|国漫|日漫|美漫|综艺|晚会|真人秀|脱口秀|纪录|纪实|探索|解说|体育|赛事|足球|篮球|音乐|MV|演唱会)',
      caseSensitive: false,
    ).hasMatch(n)) {
      return '动漫 · 综艺 · 纪实';
    }
    return '更多频道专区';
  }

  IconData _groupSectionIcon(String groupTitle) {
    switch (groupTitle) {
      case '电影频道':
        return Icons.movie_filter_rounded;
      case '剧集剧场':
        return Icons.live_tv_rounded;
      case '动漫 · 综艺 · 纪实':
        return Icons.auto_awesome_rounded;
      default:
        return Icons.explore_outlined;
    }
  }

  Widget _buildExpandedCategoryDrawer(AppState state) {
    final categories = state.categories;
    final kw = _categoryFilterQuery.trim().toLowerCase();

    final sectionOrder = <String>[
      '电影频道',
      '剧集剧场',
      '动漫 · 综艺 · 纪实',
      '更多频道专区',
    ];
    final allGrouped = <String, List<({VodCategory cat, int index})>>{};
    for (int i = 0; i < categories.length; i++) {
      final g = _classifyCategoryGroup(categories[i].typeName);
      allGrouped.putIfAbsent(g, () => []).add(
        (cat: categories[i], index: i + 1),
      );
    }

    final availableGroupTabs = <String>[
      '全部',
      for (final s in sectionOrder)
        if (allGrouped[s]?.isNotEmpty ?? false) s,
    ];
    final effectiveGroupTab = availableGroupTabs.contains(_selectedCategoryGroupTab)
        ? _selectedCategoryGroupTab
        : '全部';

    final indexedCategories = <({VodCategory cat, int index})>[
      for (int i = 0; i < categories.length; i++)
        if ((kw.isEmpty || categories[i].typeName.toLowerCase().contains(kw)) &&
            (effectiveGroupTab == '全部' ||
                _classifyCategoryGroup(categories[i].typeName) ==
                    effectiveGroupTab))
          (cat: categories[i], index: i + 1),
    ];

    String activeLabel = '全部推荐';
    if (state.selectedTypeId.isNotEmpty) {
      for (final c in categories) {
        if (c.typeId == state.selectedTypeId) {
          activeLabel = c.typeName;
          break;
        }
      }
    }

    final screenSize = MediaQuery.sizeOf(context);
    final isCompactDrawer = screenSize.width < 620;
    final maxDrawerHeight = (screenSize.height * 0.62).clamp(240.0, 390.0);

    Widget buildCategoryFilterField() {
      return SizedBox(
        width: isCompactDrawer ? double.infinity : 190,
        height: 30,
        child: TextField(
          controller: _categoryFilterCtrl,
          onChanged: (v) => setState(() => _categoryFilterQuery = v),
          style: TextStyle(
            fontSize: 12,
            color: VideoPlatformTheme.textPrimary,
          ),
          decoration: InputDecoration(
            hintText: '筛选分类名称...',
            hintStyle: TextStyle(
              fontSize: 11.5,
              color: VideoPlatformTheme.textMuted,
            ),
            prefixIcon: Icon(
              Icons.filter_alt_outlined,
              size: 15,
              color: VideoPlatformTheme.textMuted,
            ),
            suffixIcon: _categoryFilterQuery.isNotEmpty
                ? IconButton(
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.close, size: 14),
                    onPressed: () {
                      _categoryFilterCtrl.clear();
                      setState(() => _categoryFilterQuery = '');
                    },
                  )
                : null,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 4,
            ),
          ),
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: Container(
        width: double.infinity,
        constraints: BoxConstraints(maxHeight: maxDrawerHeight),
        decoration: BoxDecoration(
          color: VideoPlatformTheme.bgElevated,
          borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(14),
          ),
          border: Border(
            bottom: BorderSide(color: VideoPlatformTheme.borderStrong),
            left: BorderSide(color: VideoPlatformTheme.borderSubtle),
            right: BorderSide(color: VideoPlatformTheme.borderSubtle),
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x88000000),
              blurRadius: 24,
              offset: Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drawer Header Bar (responsive so '收起' button never overflows off screen)
            Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 12, 8),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color:
                              VideoPlatformTheme.accent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.grid_view_rounded,
                          size: 16,
                          color: VideoPlatformTheme.accent,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '全部分类导航',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: VideoPlatformTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Container(
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
                            '当前：$activeLabel',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: VideoPlatformTheme.accent,
                            ),
                          ),
                        ),
                      ),
                      const Spacer(),
                      if (!isCompactDrawer &&
                          categories.length > 6 &&
                          !state.tvMode) ...[
                        buildCategoryFilterField(),
                        const SizedBox(width: 8),
                      ],
                      FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                        ),
                        onPressed: () =>
                            setState(() => _categoriesExpanded = false),
                        icon: const Icon(
                          Icons.keyboard_arrow_up_rounded,
                          size: 17,
                        ),
                        label: const Text(
                          '收起',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  if (isCompactDrawer &&
                      categories.length > 6 &&
                      !state.tvMode) ...[
                    const SizedBox(height: 8),
                    buildCategoryFilterField(),
                  ],
                ],
              ),
            ),

            // Category Group Tab Bar (分类分组标签页按钮栏)
            if (availableGroupTabs.length > 1)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: VideoPlatformTheme.bgPrimary.withValues(alpha: 0.45),
                  border: Border(
                    bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
                  ),
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: availableGroupTabs.map((tabName) {
                    final isTabSelected = effectiveGroupTab == tabName;
                    final count = tabName == '全部'
                        ? categories.length + 1
                        : (allGrouped[tabName]?.length ?? 0);
                    return _buildDrawerGroupTabButton(
                      label: '$tabName ($count)',
                      icon: tabName == '全部'
                          ? Icons.apps_rounded
                          : _groupSectionIcon(tabName),
                      selected: isTabSelected,
                      onTap: () => setState(
                        () => _selectedCategoryGroupTab = tabName,
                      ),
                    );
                  }).toList(),
                ),
              ),

            // Scrollable Multi-Column Category Tag Buttons Body
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (indexedCategories.isEmpty && kw.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Center(
                          child: Text(
                            '未找到匹配「$_categoryFilterQuery」的分类标签',
                            style: TextStyle(
                              fontSize: 13,
                              color: VideoPlatformTheme.textMuted,
                            ),
                          ),
                        ),
                      )
                    else
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          if (kw.isEmpty && effectiveGroupTab == '全部')
                            _buildMatrixCategoryTile(
                              label: '全部推荐',
                              selected: state.selectedTypeId.isEmpty,
                              icon: Icons.local_fire_department_rounded,
                              onTap: () =>
                                  _selectCategoryAndSync(state, '', 0),
                            ),
                          ...indexedCategories.map((entry) {
                            final selected =
                                state.selectedTypeId == entry.cat.typeId;
                            return _buildMatrixCategoryTile(
                              label: entry.cat.typeName,
                              selected: selected,
                              onTap: () => _selectCategoryAndSync(
                                state,
                                entry.cat.typeId,
                                entry.index,
                              ),
                            );
                          }),
                          if (categories.isEmpty && kw.isEmpty)
                            _buildMatrixCategoryTile(
                              label: state.isLoadingVod
                                  ? '正在加载分类标签...'
                                  : '刷新分类标签',
                              selected: false,
                              icon: Icons.refresh_rounded,
                              onTap: () {
                                if (!state.isLoadingVod) {
                                  state.loadVodCatalog(
                                    resetCategories: true,
                                    forceRefresh: true,
                                  );
                                }
                              },
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
              InkWell(
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(14),
                ),
                onTap: () => setState(() => _categoriesExpanded = false),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color:
                        VideoPlatformTheme.bgPrimary.withValues(alpha: 0.55),
                    border: Border(
                      top: BorderSide(color: VideoPlatformTheme.borderSubtle),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.keyboard_arrow_up_rounded,
                        size: 18,
                        color: VideoPlatformTheme.accent,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '点击此处收起分类导航',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: VideoPlatformTheme.accent,
                        ),
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

  Widget _buildDrawerGroupTabButton({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(7),
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      onTap: onTap,
      child: Builder(
        builder: (ctx) {
          final isFocused = Focus.of(ctx).hasPrimaryFocus;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
            decoration: BoxDecoration(
              color: isFocused
                  ? VideoPlatformTheme.accent.withValues(alpha: 0.28)
                  : (selected
                      ? VideoPlatformTheme.accent.withValues(alpha: 0.18)
                      : VideoPlatformTheme.bgCard),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: (selected || isFocused)
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
                  color: (selected || isFocused)
                      ? VideoPlatformTheme.accent
                      : VideoPlatformTheme.textSecondary,
                ),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: (selected || isFocused)
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: (selected || isFocused)
                        ? VideoPlatformTheme.accent
                        : VideoPlatformTheme.textSecondary,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildMatrixCategoryTile({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    IconData? icon,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      onTap: onTap,
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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? VideoPlatformTheme.accent
                  : (isFocused
                      ? VideoPlatformTheme.accent.withValues(alpha: 0.24)
                      : VideoPlatformTheme.bgCard),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: (selected || isFocused)
                    ? VideoPlatformTheme.accent
                    : VideoPlatformTheme.borderSubtle,
                width: isFocused ? 2.2 : (selected ? 1.3 : 1.0),
              ),
              boxShadow: (selected || isFocused)
                  ? [
                      BoxShadow(
                        color:
                            VideoPlatformTheme.accent.withValues(alpha: 0.35),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(
                    icon,
                    size: 14,
                    color: selected ? Colors.white : VideoPlatformTheme.accent,
                  ),
                  const SizedBox(width: 5),
                ] else if (selected) ...[
                  const Icon(
                    Icons.check_circle_rounded,
                    size: 13.5,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 5),
                ] else ...[
                  Icon(
                    Icons.label_outline_rounded,
                    size: 13,
                    color: isFocused
                        ? VideoPlatformTheme.accent
                        : VideoPlatformTheme.textMuted,
                  ),
                  const SizedBox(width: 5),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: (selected || isFocused)
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: selected
                        ? Colors.white
                        : (isFocused
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.textPrimary),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildCategoryChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Align(
      alignment: Alignment.center,
      widthFactor: 1.0,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onFocusChange: (_) {
          if (mounted) setState(() {});
        },
        onTap: onTap,
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
            return AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: selected
                    ? VideoPlatformTheme.accent
                    : (isFocused
                        ? VideoPlatformTheme.accent.withValues(alpha: 0.25)
                        : Colors.transparent),
                borderRadius: BorderRadius.circular(6),
                border: isFocused
                    ? Border.all(
                        color: VideoPlatformTheme.accent,
                        width: 2.0,
                      )
                    : null,
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
      ),
    );
  }

  Widget _buildSearchStatusBar(AppState state) {
    // Count results per source for aggregated search filter chips
    final sourceCounts = <String, ({String name, int count})>{};
    if (state.aggregatedSearch) {
      for (final item in state.vodItems) {
        final src = item.source;
        if (src != null) {
          final prev = sourceCounts[src.id];
          sourceCounts[src.id] = (
            name: src.name,
            count: (prev?.count ?? 0) + 1,
          );
        }
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        border: Border(
          bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.search,
                    size: 16,
                    color: VideoPlatformTheme.accent,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      state.aggregatedSearch
                          ? '全网搜索 "${state.searchKeyword}" (${state.searchCompletedSources}/${state.searchTotalSources}站 · ${state.vodItems.length}条)'
                          : '当前源搜索 "${state.searchKeyword}" · ${state.vodItems.length}条',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: VideoPlatformTheme.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              FilterChip(
                selected: state.aggregatedSearch,
                onSelected: (v) => state.setAggregatedSearch(v),
                label: Text(
                  state.aggregatedSearch ? '🌐 全网聚合' : '📍 切换全网',
                  style: const TextStyle(fontSize: 11.5),
                ),
                visualDensity: VisualDensity.compact,
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: state.clearSearch,
                icon: const Icon(Icons.close, size: 15),
                label: const Text('返回片库', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          if (state.aggregatedSearch && sourceCounts.length > 1) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 28,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _buildSourceFilterPill(
                    label: '全部站点 (${state.vodItems.length})',
                    selected: state.searchSourceFilterId == null,
                    onTap: () => state.setSearchSourceFilterId(null),
                  ),
                  ...sourceCounts.entries.map(
                    (e) => Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: _buildSourceFilterPill(
                        label: '${e.value.name} (${e.value.count})',
                        selected: state.searchSourceFilterId == e.key,
                        onTap: () => state.setSearchSourceFilterId(e.key),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSourceFilterPill({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      onTap: onTap,
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
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: selected
                  ? VideoPlatformTheme.accent
                  : (isFocused
                      ? VideoPlatformTheme.accent.withValues(alpha: 0.25)
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

  Widget _buildDirectoryBreadcrumbs(AppState state) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgCard,
        border: Border(
          bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            InkWell(
              onTap: () => state.navigateToDirectoryBreadcrumb(-1),
              child: Text(
                '根目录',
                style: TextStyle(
                  fontSize: 12,
                  color: VideoPlatformTheme.accent,
                ),
              ),
            ),
            for (var i = 0; i < state.directoryBreadcrumbs.length; i++) ...[
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(
                  Icons.chevron_right,
                  size: 14,
                  color: VideoPlatformTheme.textMuted,
                ),
              ),
              InkWell(
                onTap: () => state.navigateToDirectoryBreadcrumb(i),
                child: Text(
                  state.directoryBreadcrumbs[i].title,
                  style: TextStyle(
                    fontSize: 12,
                    color: i == state.directoryBreadcrumbs.length - 1
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

  Widget _buildBodyContent(AppState state) {
    if (state.isConnecting) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: VideoPlatformTheme.accent,
              ),
            ),
            SizedBox(height: 12),
            Text(
              '正在连接影视服务端...',
              style: TextStyle(
                color: VideoPlatformTheme.textSecondary,
                fontSize: 13,
              ),
            ),
          ],
        ),
      );
    }

    if (state.connectionError != null && state.sources.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 42,
                color: VideoPlatformTheme.textMuted,
              ),
              const SizedBox(height: 12),
              Text(
                '无法连接服务器：${state.connectionError}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: VideoPlatformTheme.textPrimary,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: state.connectAndBootstrap,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重新连接'),
              ),
            ],
          ),
        ),
      );
    }

    if (state.isLoadingVod && state.vodItems.isEmpty) {
      return Center(
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: VideoPlatformTheme.accent,
        ),
      );
    }

    if (state.vodError != null && state.vodItems.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 38,
                color: VideoPlatformTheme.warning,
              ),
              const SizedBox(height: 10),
              Text(
                '当前片源加载失败：${state.vodError}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: VideoPlatformTheme.textSecondary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                children: [
                  FilledButton.icon(
                    onPressed: () => state.loadVodCatalog(
                      resetCategories: true,
                      forceRefresh: true,
                    ),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('重试加载'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {
                      SourcePickerDialog.show(
                        context,
                        sources: state.visibleSources,
                        selectedSource: state.selectedSource,
                        onSelect: state.selectVodSource,
                      );
                    },
                    icon: const Icon(Icons.swap_horiz, size: 16),
                    label: const Text('切换其他片源'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    if (state.vodItems.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.video_library_outlined,
              size: 40,
              color: VideoPlatformTheme.textMuted,
            ),
            const SizedBox(height: 10),
            Text(
              '当前分类或搜索下暂无影视内容',
              style: TextStyle(
                color: VideoPlatformTheme.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () {
                SourcePickerDialog.show(
                  context,
                  sources: state.sources,
                  selectedSource: state.selectedSource,
                  onSelect: state.selectVodSource,
                );
              },
              child: const Text('切换片源站点'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      color: VideoPlatformTheme.accent,
      onRefresh: () => state.searchKeyword.isNotEmpty
          ? state.performSearch(state.searchKeyword)
          : state.loadVodCatalog(
              resetCategories: false,
              forceRefresh: true,
            ),
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (notification) {
          if (notification.metrics.axis == Axis.vertical) {
            _checkViewportAndAutoLoadMore();
          }
          return false;
        },
        child: Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent && event.scrollDelta.dy > 0) {
              _checkViewportAndAutoLoadMore();
            }
          },
          child: CustomScrollView(
            controller: _scrollController,
            cacheExtent: 1500,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: state.tvMode ? 220 : 185,
                    mainAxisSpacing: state.tvMode ? 20 : 16,
                    crossAxisSpacing: state.tvMode ? 18 : 14,
                    childAspectRatio: 0.57,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final items = state.filteredVodItems;
                      final item = items[index];
                      return VodPosterCard(
                        key: ValueKey(
                          '${item.source?.id ?? state.selectedSource?.id ?? ""}_${item.vodId}_${item.vodPic}',
                        ),
                        item: item,
                        api: state.api,
                        autofocus: state.tvMode && index == 0,
                        showSourceBadge: state.searchKeyword.isNotEmpty &&
                            state.aggregatedSearch,
                        onFocused: () {
                          if (index >= items.length - 8 &&
                              state.hasMoreVod &&
                              !state.isLoadingVod &&
                              !state.isLoadingMoreVod) {
                            state.loadMoreVod();
                          }
                        },
                        onTap: () => _openVodItem(item),
                      );
                    },
                    childCount: state.filteredVodItems.length,
                  ),
                ),
              ),
              if (state.isLoadingMoreVod)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: VideoPlatformTheme.accent,
                        ),
                      ),
                    ),
                  ),
                )
              else if (state.hasMoreVod)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: Center(
                      child: TextButton.icon(
                        onPressed: state.loadMoreVod,
                        icon: const Icon(Icons.expand_more_rounded, size: 18),
                        label: Text(
                          '加载更多影视 (${state.currentPage}/${state.totalPages} 页)',
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
}
