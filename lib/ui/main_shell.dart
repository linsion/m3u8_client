import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/models.dart';
import '../services/proxy_routing_service.dart';
import '../state/app_state.dart';
import 'screens/downloads_screen.dart';
import 'screens/library_history_screen.dart';
import 'screens/live_tv_screen.dart';
import 'screens/login_screen.dart';
import 'screens/media_library_screen.dart';
import 'screens/proxy_server_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/telegram_screen.dart';
import 'screens/terminal_screen.dart';
import 'screens/vod_detail_player_screen.dart';
import 'screens/vod_home_screen.dart';
import 'theme.dart';
import 'widgets/app_brand_logo.dart';
import 'widgets/source_picker_sheet.dart';
import 'widgets/video_download_speed_badge.dart';
import 'widgets/video_proxy_node_selector.dart';

class MainShell extends StatefulWidget {
  final AppState appState;

  const MainShell({
    super.key,
    required this.appState,
  });

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _selectedIndex = 0;
  bool _isSidebarCollapsed = false;
  bool _isMobileSidebarOpen = false;
  final TextEditingController _searchController = TextEditingController();
  String? _lastSniffedClipboardUrl;
  DateTime? _lastBackHandledAt;
  bool _isExitDialogShowing = false;
  final GlobalKey _sidebarContainerKey = GlobalKey();
  final Map<int, FocusNode> _sidebarTabFocusNodes = {
    for (int i = 0; i <= 8; i++) i: FocusNode(debugLabel: 'SidebarTab_$i'),
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.appState.onNavigateToTelegramTab = () {
      if (mounted) {
        _selectTab(5);
      }
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.appState.updateTelegramReadingContext(
        isTelegramViewActive: _selectedIndex == 5,
        isAppForeground: true,
      );
    });
  }

  void _selectTab(int index) {
    final screenW = MediaQuery.maybeSizeOf(context)?.width ?? 1024;
    widget.appState.setImmersiveFullscreen(false);
    setState(() {
      _selectedIndex = index;
      _isMobileSidebarOpen = false;
      if (screenW < 860 && !widget.appState.tvMode) {
        _isSidebarCollapsed = true;
      }
    });
    widget.appState.updateTelegramReadingContext(
      isTelegramViewActive: index == 5,
    );
  }

  @override
  void dispose() {
    if (widget.appState.onNavigateToTelegramTab != null) {
      widget.appState.onNavigateToTelegramTab = null;
    }
    for (final node in _sidebarTabFocusNodes.values) {
      node.dispose();
    }
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isForeground = state == AppLifecycleState.resumed;
    widget.appState.updateTelegramReadingContext(
      isAppForeground: isForeground,
    );
    if (isForeground && widget.appState.isAuthenticated) {
      _sniffClipboardOnResume();
    }
  }

  Future<void> _sniffClipboardOnResume() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final raw = data?.text?.trim() ?? '';
      if (raw.isEmpty || raw == _lastSniffedClipboardUrl) return;
      final match = RegExp(
        r'(https?://[^\s"<>]+?\.(?:m3u8|mp4|mkv|flv|mov)(?:\?[^\s"<>]*)?|magnet:\?xt=urn:btih:[^\s"<>]+)',
        caseSensitive: false,
      ).firstMatch(raw);
      if (match == null || !mounted) return;
      final url = match.group(0)!;
      if (widget.appState.tasks.any((t) => t.url == url)) return;
      _lastSniffedClipboardUrl = raw;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(
            '📋 检测到剪贴板视频链接：${url.length > 48 ? '${url.substring(0, 48)}...' : url}',
          ),
          action: SnackBarAction(
            label: '加入下载',
            onPressed: () async {
              final name =
                  '剪贴板视频_${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
              try {
                await widget.appState.api.createDownloadTask(
                  url: url,
                  name: name,
                );
                await widget.appState.refreshDownloadTasks(silent: true);
              } catch (_) {}
            },
          ),
        ),
      );
    } catch (_) {}
  }

  void _openCommandPalette() {
    showDialog<void>(
      context: context,
      builder: (_) => _GlobalCommandPaletteDialog(
        appState: widget.appState,
        onNavigateTab: (tabIdx) {
          setState(() => _selectedIndex = tabIdx);
        },
        onOpenVodDetail: (source, vodId, title, poster) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => VodDetailPlayerScreen(
                appState: widget.appState,
                source: source,
                vodId: vodId,
                initialTitle: title,
                initialPoster: poster,
              ),
            ),
          );
        },
      ),
    );
  }

  void _submitSearch(String value) {
    final trimmed = value.trim();
    if (_selectedIndex != 0) {
      setState(() => _selectedIndex = 0);
    }
    widget.appState.performSearch(trimmed);
  }

  bool _isFocusInsideSidebar() {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) return false;
    if (_sidebarTabFocusNodes.values.contains(primary)) {
      return true;
    }
    final sidebarCtx = _sidebarContainerKey.currentContext;
    final focusedCtx = primary.context;
    if (sidebarCtx == null || focusedCtx == null) return false;
    bool inside = false;
    focusedCtx.visitAncestorElements((ancestor) {
      if (ancestor == sidebarCtx) {
        inside = true;
        return false;
      }
      return true;
    });
    return inside;
  }

  void _focusSidebarTab(int index) {
    if (_isSidebarCollapsed) {
      setState(() => _isSidebarCollapsed = false);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node = _sidebarTabFocusNodes[index] ?? _sidebarTabFocusNodes[0];
      node?.requestFocus();
    });
  }

  Future<void> _showExitConfirmDialog() async {
    if (_isExitDialogShowing || !mounted) return;
    _isExitDialogShowing = true;
    final dialogOpenedAt = DateTime.now();
    final stayFocusNode = FocusNode(debugLabel: 'ExitDialog_Stay');
    final exitFocusNode = FocusNode(debugLabel: 'ExitDialog_Exit');
    try {
      final shouldExit = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          Widget buildDialogActionBtn({
            required FocusNode focusNode,
            required FocusNode neighborNode,
            required bool autofocus,
            required String label,
            required IconData icon,
            required bool isPrimaryDanger,
            required VoidCallback onTap,
          }) {
            return StatefulBuilder(
              builder: (btnCtx, setBtnState) {
                return Focus(
                  focusNode: focusNode,
                  autofocus: autofocus,
                  onFocusChange: (_) => setBtnState(() {}),
                  onKeyEvent: (node, event) {
                    if (event is KeyUpEvent || event is KeyRepeatEvent) {
                      if (event.logicalKey == LogicalKeyboardKey.goBack ||
                          event.logicalKey == LogicalKeyboardKey.escape ||
                          event.logicalKey == LogicalKeyboardKey.browserBack) {
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    }
                    if (event is! KeyDownEvent) return KeyEventResult.ignored;
                    if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                        event.logicalKey == LogicalKeyboardKey.arrowRight) {
                      neighborNode.requestFocus();
                      return KeyEventResult.handled;
                    }
                    if (event.logicalKey == LogicalKeyboardKey.select ||
                        event.logicalKey == LogicalKeyboardKey.enter ||
                        event.logicalKey == LogicalKeyboardKey.numpadEnter ||
                        event.logicalKey == LogicalKeyboardKey.space ||
                        event.logicalKey == LogicalKeyboardKey.gameButtonA) {
                      onTap();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: Builder(
                    builder: (innerCtx) {
                      final isFocused = Focus.of(innerCtx).hasPrimaryFocus;
                      final bgColor = isPrimaryDanger
                          ? (isFocused
                              ? VideoPlatformTheme.danger
                              : VideoPlatformTheme.accent)
                          : (isFocused
                              ? VideoPlatformTheme.accent.withValues(alpha: 0.25)
                              : VideoPlatformTheme.bgCard);
                      return GestureDetector(
                        onTap: onTap,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: bgColor,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isFocused
                                  ? const Color(0xFFFFE066)
                                  : VideoPlatformTheme.borderStrong,
                              width: isFocused ? 2.4 : 1.0,
                            ),
                            boxShadow: isFocused
                                ? [
                                    BoxShadow(
                                      color: (isPrimaryDanger
                                              ? VideoPlatformTheme.danger
                                              : VideoPlatformTheme.accent)
                                          .withValues(alpha: 0.45),
                                      blurRadius: 12,
                                    ),
                                  ]
                                : null,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                icon,
                                size: 17,
                                color: Colors.white,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                label,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: isFocused
                                      ? FontWeight.w700
                                      : FontWeight.w600,
                                  color: Colors.white,
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
            );
          }

          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) return;
              // Ignore trailing ACTION_UP / key-repeat from the Back press that opened this dialog
              if (DateTime.now().difference(dialogOpenedAt).inMilliseconds <
                  650) {
                return;
              }
              Navigator.of(ctx).pop(false);
            },
            child: Focus(
              canRequestFocus: false,
              onKeyEvent: (node, event) {
                if (event.logicalKey == LogicalKeyboardKey.goBack ||
                    event.logicalKey == LogicalKeyboardKey.escape ||
                    event.logicalKey == LogicalKeyboardKey.browserBack) {
                  if (event is KeyDownEvent &&
                      DateTime.now()
                              .difference(dialogOpenedAt)
                              .inMilliseconds >=
                          650) {
                    Navigator.of(ctx).pop(false);
                  }
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: AlertDialog(
                backgroundColor: VideoPlatformTheme.bgElevated,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: VideoPlatformTheme.borderStrong),
                ),
                title: Row(
                  children: [
                    Icon(
                      Icons.exit_to_app_rounded,
                      size: 22,
                      color: VideoPlatformTheme.accent,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '确认退出流光视频？',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: VideoPlatformTheme.textPrimary,
                      ),
                    ),
                  ],
                ),
                content: Text(
                  '当前已返回主导航焦点，按“退出应用”将关闭流光视频，按“继续观看”或返回键留在应用。',
                  style: TextStyle(
                    fontSize: 13.5,
                    color: VideoPlatformTheme.textSecondary,
                    height: 1.45,
                  ),
                ),
                actions: [
                  buildDialogActionBtn(
                    focusNode: stayFocusNode,
                    neighborNode: exitFocusNode,
                    autofocus: false,
                    label: '继续观看',
                    icon: Icons.play_circle_outline_rounded,
                    isPrimaryDanger: false,
                    onTap: () => Navigator.of(ctx).pop(false),
                  ),
                  const SizedBox(width: 8),
                  buildDialogActionBtn(
                    focusNode: exitFocusNode,
                    neighborNode: stayFocusNode,
                    autofocus: true,
                    label: '退出应用',
                    icon: Icons.power_settings_new_rounded,
                    isPrimaryDanger: true,
                    onTap: () => Navigator.of(ctx).pop(true),
                  ),
                ],
              ),
            ),
          );
        },
      );
      if (shouldExit == true && mounted) {
        SystemNavigator.pop();
      }
    } finally {
      stayFocusNode.dispose();
      exitFocusNode.dispose();
      _isExitDialogShowing = false;
      _lastBackHandledAt = DateTime.now();
    }
  }

  void _handleRootPop(AppState state) {
    if (_isExitDialogShowing) return;
    final now = DateTime.now();
    if (_lastBackHandledAt != null &&
        now.difference(_lastBackHandledAt!) <
            const Duration(milliseconds: 420)) {
      return;
    }
    _lastBackHandledAt = now;

    // Step 1: Let the active child screen handle its own sub-states first
    // (e.g. exiting Live TV fullscreen, closing channel drawer, exiting Telegram chat/selection, stepping up folders/categories)
    if (state.activeChildBackHandler?.call() == true) {
      return;
    }

    // Step 2: Fallback immersive fullscreen exit
    if (state.isImmersiveFullscreen) {
      state.setImmersiveFullscreen(false);
      return;
    }

    // Step 3: Close mobile overlay drawer if open
    if (_isMobileSidebarOpen) {
      setState(() => _isMobileSidebarOpen = false);
      return;
    }

    // Step 4: Clear VOD search or Alist directory breadcrumbs if on VOD Home
    if (_selectedIndex == 0 && state.searchKeyword.isNotEmpty) {
      _searchController.clear();
      state.clearSearch();
      setState(() {});
      return;
    }
    if (_selectedIndex == 0 && state.directoryBreadcrumbs.isNotEmpty) {
      state.navigateToDirectoryBreadcrumb(
        state.directoryBreadcrumbs.length - 2,
      );
      return;
    }

    // Step 5: On TV / Desktop layout, step focus back from Content Area -> Main Navigation Bar/Sidebar -> Tab 0 Focus
    final screenW = MediaQuery.maybeSizeOf(context)?.width ?? 1024;
    final isDesktopOrTv = screenW >= 860 || state.tvMode;
    if (isDesktopOrTv) {
      if ((!state.tvMode && _isSidebarCollapsed) || !_isFocusInsideSidebar()) {
        _focusSidebarTab(_selectedIndex);
        return;
      }
      if (_selectedIndex != 0) {
        _selectTab(0);
        _focusSidebarTab(0);
        return;
      }
    } else {
      // Mobile layout: step back to Home Tab 0 before prompting to exit
      if (_selectedIndex != 0) {
        _selectTab(0);
        return;
      }
    }

    // Step 6: Already at the Main Focus (Tab 0 & Main Sidebar Focus) -> Ask confirmation to exit app
    _showExitConfirmDialog();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.appState,
      builder: (context, _) {
        final state = widget.appState;
        if (!state.isAuthenticated) {
          return LoginScreen(appState: state);
        }
        final screenWidth = MediaQuery.sizeOf(context).width;
        final effectiveTvMode = state.tvMode && screenWidth >= 680;
        final isDesktop = screenWidth >= 860 || effectiveTvMode;
        final isImmersive = state.isImmersiveFullscreen;
        final isSidebarOpen = !isImmersive &&
            (isDesktop ? !_isSidebarCollapsed : _isMobileSidebarOpen);
        final useOverlaySidebar = screenWidth < 860 && !effectiveTvMode;
        final miniSession = state.miniPlayerSession;

        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              _handleRootPop(state);
            }
          },
          child: Focus(
            canRequestFocus: false,
            onKeyEvent: (node, event) {
              if (event.logicalKey == LogicalKeyboardKey.goBack ||
                  event.logicalKey == LogicalKeyboardKey.escape ||
                  event.logicalKey == LogicalKeyboardKey.browserBack) {
                final route = ModalRoute.of(context);
                if (route != null && route.isCurrent) {
                  if (event is KeyDownEvent) {
                    _handleRootPop(state);
                  }
                  return KeyEventResult.handled;
                }
              }
              return KeyEventResult.ignored;
            },
            child: CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
                  _openCommandPalette,
              const SingleActivator(LogicalKeyboardKey.keyK, control: true):
                  _openCommandPalette,
            },
            child: Scaffold(
              backgroundColor:
                  isImmersive ? Colors.black : VideoPlatformTheme.bgPrimary,
              body: SafeArea(
                top: !isImmersive,
                bottom: !isImmersive,
                left: !isImmersive,
                right: !isImmersive,
                child: Stack(
                  children: [
                    Column(
                      children: [
                        if (!isImmersive)
                          FocusTraversalGroup(
                            child: _buildTopHeader(
                              state,
                              isDesktop,
                              screenWidth,
                            ),
                          ),
                        Expanded(
                          child: Stack(
                            children: [
                              Row(
                                children: [
                                  if (!isImmersive &&
                                      !state.tvMode &&
                                      !useOverlaySidebar &&
                                      isSidebarOpen)
                                    FocusTraversalGroup(
                                      child: _buildDesktopSidebar(
                                        state,
                                        onCollapse: () => setState(() {
                                          _isSidebarCollapsed = true;
                                          _isMobileSidebarOpen = false;
                                        }),
                                      ),
                                    ),
                                  Expanded(
                                    child: FocusTraversalGroup(
                                      child: KeyedSubtree(
                                        key: ValueKey(state.themeId),
                                        child: _buildActiveScreen(state),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (!isImmersive &&
                                  !state.tvMode &&
                                  !useOverlaySidebar &&
                                  !isSidebarOpen)
                                Positioned(
                                  left: 0,
                                  top: 12,
                                  child: _buildCollapsedSidebarExpandHandle(),
                                ),
                              if (!isImmersive &&
                                  useOverlaySidebar &&
                                  isSidebarOpen) ...[
                                Positioned.fill(
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () => setState(() {
                                      _isSidebarCollapsed = true;
                                      _isMobileSidebarOpen = false;
                                    }),
                                    child: Container(
                                      color: Colors.black54,
                                    ),
                                  ),
                                ),
                                Positioned(
                                  left: 0,
                                  top: 0,
                                  bottom: 0,
                                  child: FocusTraversalGroup(
                                    child: _buildDesktopSidebar(
                                      state,
                                      onCollapse: () => setState(() {
                                        _isSidebarCollapsed = true;
                                        _isMobileSidebarOpen = false;
                                      }),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (miniSession != null && !isImmersive)
                      _FloatingMiniPlayerOverlay(
                        key: ValueKey(miniSession.streamUrl),
                        appState: state,
                        session: miniSession,
                        onRestoreFullScreen: (currentPosSec) {
                          state.closeMiniPlayer();
                          if (miniSession.isLive) {
                            _selectTab(1);
                          } else if (miniSession.vodSource != null &&
                              miniSession.vodId != null &&
                              miniSession.vodId!.isNotEmpty) {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => VodDetailPlayerScreen(
                                  appState: state,
                                  source: miniSession.vodSource!,
                                  vodId: miniSession.vodId!,
                                  initialTitle: miniSession.vodTitle ??
                                      miniSession.title,
                                  initialPoster: miniSession.vodPoster ?? '',
                                  initialGroupIndex: miniSession.groupIndex,
                                  initialEpisodeIndex: miniSession.episodeIndex,
                                  initialResumeSeconds:
                                      currentPosSec.toDouble(),
                                ),
                              ),
                            );
                          }
                        },
                      ),
                    if (!isImmersive)
                      _buildTelegramFloatingNotifications(state, isDesktop),
                  ],
                ),
              ),
              bottomNavigationBar: (isDesktop || isImmersive)
                  ? null
                  : _buildMobileBottomBar(state),
            ),
          ),
        ),
      );
    },
    );
  }

  Widget _buildTopHeader(AppState state, bool isDesktop, double screenWidth) {
    final activeSource = state.selectedSource;
    final isSidebarOpen =
        isDesktop ? !_isSidebarCollapsed : _isMobileSidebarOpen;

    void toggleSidebar() {
      setState(() {
        if (isDesktop) {
          _isSidebarCollapsed = !_isSidebarCollapsed;
        } else {
          _isMobileSidebarOpen = !_isMobileSidebarOpen;
        }
      });
    }

    Widget buildSourceSelectorButton({double maxWidth = 140}) {
      return InkWell(
        borderRadius: BorderRadius.circular(18),
        onFocusChange: (_) {
          if (mounted) setState(() {});
        },
        onTap: state.sources.isEmpty
            ? null
            : () {
                SourcePickerDialog.show(
                  context,
                  sources: state.visibleSources,
                  selectedSource: state.selectedSource,
                  onSelect: (src) {
                    setState(() => _selectedIndex = 0);
                    state.selectVodSource(src);
                  },
                );
              },
        child: Builder(
          builder: (ctx) {
            final isFocused = Focus.of(ctx).hasPrimaryFocus;
            return Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 11),
              decoration: BoxDecoration(
                color: isFocused
                    ? VideoPlatformTheme.accent.withValues(alpha: 0.24)
                    : VideoPlatformTheme.bgCard,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: isFocused
                      ? VideoPlatformTheme.accent
                      : VideoPlatformTheme.accent.withValues(alpha: 0.35),
                  width: isFocused ? 2.0 : 1.0,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.video_library_rounded,
                    size: 15,
                    color: VideoPlatformTheme.accent,
                  ),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    child: Text(
                      activeSource?.name ??
                          (state.isConnecting ? '加载媒体库...' : '选择媒体库'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: VideoPlatformTheme.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 16,
                    color: VideoPlatformTheme.accent,
                  ),
                ],
              ),
            );
          },
        ),
      );
    }

    Widget buildInlineSearchBox() {
      if (state.tvMode) {
        return _buildTvRemoteSearchButton(state);
      }
      return SizedBox(
        height: 36,
        child: TextField(
          controller: _searchController,
          onSubmitted: _submitSearch,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: state.aggregatedSearch
                ? '全网多源搜索电影、剧集、综艺、动漫...'
                : '搜索当前站点影视资源...',
            prefixIcon: Icon(
              Icons.search,
              size: 17,
              color: VideoPlatformTheme.textMuted,
            ),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_searchController.text.isNotEmpty ||
                    state.searchKeyword.isNotEmpty)
                  IconButton(
                    tooltip: '清除搜索',
                    icon: const Icon(Icons.clear, size: 15),
                    onPressed: () {
                      _searchController.clear();
                      state.clearSearch();
                      setState(() {});
                    },
                  ),
                InkWell(
                  onTap: () => state.setAggregatedSearch(
                    !state.aggregatedSearch,
                  ),
                  child: Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: state.aggregatedSearch
                          ? VideoPlatformTheme.accent.withValues(alpha: 0.2)
                          : VideoPlatformTheme.bgCard,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: state.aggregatedSearch
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.borderStrong,
                      ),
                    ),
                    child: Text(
                      '全网搜',
                      style: TextStyle(
                        fontSize: 11,
                        color: state.aggregatedSearch
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.textSecondary,
                        fontWeight: state.aggregatedSearch
                            ? FontWeight.w600
                            : FontWeight.w400,
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

    if (state.tvMode && screenWidth >= 680) {
      return _buildTvLeanbackHeader(state, activeSource: activeSource);
    }

    if (!isDesktop) {
      // Live TV (1) and Telegram (5) have their own dedicated mobile headers;
      // hiding MainShell's header prevents double-stacked headers on phones.
      if (_selectedIndex == 1 || _selectedIndex == 5) {
        return const SizedBox.shrink();
      }
      if (_selectedIndex == 0) {
        return _buildMobileVodTopHeader(
          state,
          activeSource: activeSource,
          buildSourceSelectorButton: buildSourceSelectorButton,
        );
      }
      return _buildMobileContextualTopHeader(state);
    }

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        border: Border(
          bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: isSidebarOpen ? '收起侧边导航栏' : '展开侧边导航栏',
            onPressed: toggleSidebar,
            icon: Icon(
              isSidebarOpen ? Icons.menu_open_rounded : Icons.menu_rounded,
              size: 20,
              color: isSidebarOpen
                  ? VideoPlatformTheme.accent
                  : VideoPlatformTheme.textSecondary,
            ),
          ),
          const SizedBox(width: 4),
          // Brand Logo & Title
          InkWell(
            onTap: () {
              _selectTab(0);
              if (state.searchKeyword.isNotEmpty) {
                _searchController.clear();
                state.clearSearch();
              }
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AppBrandLogo(size: 30),
                if (screenWidth >= 900) ...[
                  const SizedBox(width: 10),
                  Text(
                    '流光视频',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: VideoPlatformTheme.textPrimary,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),

          // Source selector button
          buildSourceSelectorButton(maxWidth: isDesktop ? 150 : 110),
          const SizedBox(width: 10),

          // Integrated Search Bar
          Expanded(
            flex: 2,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: buildInlineSearchBox(),
            ),
          ),
          const SizedBox(width: 8),

          // Scrollable right-side action strip so it never overflows on medium widths
          Flexible(
            flex: 3,
            child: Align(
              alignment: Alignment.centerRight,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isDesktop && !state.tvMode) ...[
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onFocusChange: (_) {
                          if (mounted) setState(() {});
                        },
                        onTap: _openCommandPalette,
                        child: Builder(
                          builder: (ctx) {
                            final isFocused = Focus.of(ctx).hasPrimaryFocus;
                            return Container(
                              height: 34,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10),
                              decoration: BoxDecoration(
                                color: isFocused
                                    ? VideoPlatformTheme.accent
                                        .withValues(alpha: 0.24)
                                    : VideoPlatformTheme.bgCard,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: isFocused
                                      ? VideoPlatformTheme.accent
                                      : VideoPlatformTheme.borderSubtle,
                                  width: isFocused ? 2.0 : 1.0,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.terminal_rounded,
                                    size: 14,
                                    color: VideoPlatformTheme.accent,
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    '命令面板 ⌘K',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isFocused
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
                      const SizedBox(width: 8),
                    ],
                    // Quick download indicator button
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onFocusChange: (_) {
                        if (mounted) setState(() {});
                      },
                      onTap: () => _selectTab(2),
                      child: Builder(
                        builder: (ctx) {
                          final isFocused = Focus.of(ctx).hasPrimaryFocus;
                          return Container(
                            height: 34,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: BoxDecoration(
                              color: isFocused
                                  ? VideoPlatformTheme.accent
                                      .withValues(alpha: 0.24)
                                  : VideoPlatformTheme.bgCard,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: isFocused
                                    ? VideoPlatformTheme.accent
                                    : VideoPlatformTheme.borderSubtle,
                                width: isFocused ? 2.0 : 1.0,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.downloading_rounded,
                                  size: 16,
                                  color:
                                      (state.activeTasksCount > 0 || isFocused)
                                          ? VideoPlatformTheme.accent
                                          : VideoPlatformTheme.textSecondary,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  state.activeTasksCount > 0
                                      ? '下载中 (${state.activeTasksCount})'
                                      : '下载队列',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isFocused
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
                    const SizedBox(width: 8),
                    _buildProxyQuickBadge(state),
                    const SizedBox(width: 6),
                    _buildTvModeButton(state),
                    _buildThemePickerButton(state),
                    IconButton(
                      tooltip: '观看历史与收藏',
                      onPressed: () => _selectTab(4),
                      icon: const Icon(Icons.history_rounded, size: 20),
                    ),
                    IconButton(
                      tooltip: '系统设置',
                      onPressed: () => _selectTab(8),
                      icon: const Icon(Icons.settings_outlined, size: 20),
                    ),
                    IconButton(
                      tooltip: '退出登录',
                      onPressed: state.logout,
                      icon: const Icon(Icons.logout_rounded, size: 19),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTvLeanbackHeader(
    AppState state, {
    required VodSource? activeSource,
  }) {
    final proxySvc = state.proxyService;
    final proxyEnabled = proxySvc.proxyEnabled;
    final activeProxyNode = proxySvc.activeNode;
    final tgUnread =
        state.telegramNotifications.totalUnreadNotificationCount;

    return Container(
      key: _sidebarContainerKey,
      height: 68,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgPrimary,
        border: Border(
          bottom: BorderSide(
            color: VideoPlatformTheme.borderSubtle.withValues(alpha: 0.55),
          ),
        ),
      ),
      child: Row(
        children: [
          // Brand Logo & NetEase Filmly TV Identity
          const AppBrandLogo(size: 32),
          const SizedBox(width: 10),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '流光影院',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: VideoPlatformTheme.textPrimary,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: VideoPlatformTheme.accent,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'TV',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ],
              ),
              Text(
                '爆米花海报墙系统',
                style: TextStyle(
                  fontSize: 10,
                  color: VideoPlatformTheme.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(width: 22),
          // Center: NetEase Filmly Floating Capsule Navigation Bar
          Expanded(
            child: Center(
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(
                  color: VideoPlatformTheme.bgElevated,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: VideoPlatformTheme.borderSubtle,
                  ),
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildTvNavTabButton(
                        index: 0,
                        icon: Icons.video_library_rounded,
                        label: '媒体库',
                      ),
                      const SizedBox(width: 4),
                      _buildTvNavTabButton(
                        index: 1,
                        icon: Icons.live_tv_rounded,
                        label: '电视直播',
                      ),
                      const SizedBox(width: 4),
                      _buildTvNavTabButton(
                        index: 4,
                        icon: Icons.bookmarks_rounded,
                        label: '我的片单',
                      ),
                      const SizedBox(width: 4),
                      _buildTvNavTabButton(
                        index: 5,
                        icon: Icons.send_rounded,
                        label: 'Telegram',
                        badgeCount: tgUnread,
                      ),
                      const SizedBox(width: 4),
                      _buildTvNavTabButton(
                        index: 3,
                        icon: Icons.folder_copy_outlined,
                        label: '本地视频',
                      ),
                      const SizedBox(width: 4),
                      _buildTvNavTabButton(
                        index: 2,
                        icon: Icons.downloading_rounded,
                        label: '下载',
                        badgeCount: state.activeTasksCount,
                      ),
                      const SizedBox(width: 4),
                      _buildTvNavTabButton(
                        index: 6,
                        icon: Icons.bolt_rounded,
                        label: '代理加速',
                      ),
                      const SizedBox(width: 4),
                      _buildTvNavTabButton(
                        index: 8,
                        icon: Icons.settings_outlined,
                        label: '设置',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          // Right: High-Contrast TV Remote Action Pills (Media Library Switcher, Search, Proxy)
          _buildTvHeaderActionPill(
            icon: Icons.video_library_rounded,
            label: activeSource?.name ??
                (state.isConnecting ? '加载中...' : '切换媒体库'),
            highlighted: true,
            onTap: state.sources.isEmpty
                ? null
                : () {
                    SourcePickerDialog.show(
                      context,
                      sources: state.visibleSources,
                      selectedSource: state.selectedSource,
                      onSelect: (src) {
                        _selectTab(0);
                        state.selectVodSource(src);
                      },
                    );
                  },
          ),
          const SizedBox(width: 8),
          _buildTvHeaderActionPill(
            icon: Icons.search_rounded,
            label: state.searchKeyword.isNotEmpty
                ? '搜索: ${state.searchKeyword}'
                : '搜索',
            highlighted: state.searchKeyword.isNotEmpty,
            onTap: () {
              if (_selectedIndex != 0) {
                _selectTab(0);
              }
              _showTvSearchInputDialog(state);
            },
          ),
          const SizedBox(width: 8),
          _buildTvHeaderActionPill(
            icon: proxyEnabled
                ? Icons.vpn_lock_rounded
                : Icons.public_off_rounded,
            label: proxyEnabled
                ? (activeProxyNode?.displayTitle ?? '代理已开')
                : '直连',
            highlighted: proxyEnabled,
            onTap: () => _selectTab(6),
          ),
          const SizedBox(width: 6),
          _buildTvModeButton(state),
        ],
      ),
    );
  }

  Widget _buildTvNavTabButton({
    required int index,
    required IconData icon,
    required String label,
    int badgeCount = 0,
  }) {
    final selected = _selectedIndex == index;
    return InkWell(
      focusNode: _sidebarTabFocusNodes[index],
      borderRadius: BorderRadius.circular(20),
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      onTap: () => _selectTab(index),
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
          return AnimatedScale(
            scale: isFocused ? 1.06 : 1.0,
            duration: const Duration(milliseconds: 140),
            child: Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: isFocused
                    ? VideoPlatformTheme.accent
                    : (selected
                        ? VideoPlatformTheme.accent.withValues(alpha: 0.20)
                        : Colors.transparent),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isFocused
                      ? Colors.white
                      : (selected
                          ? VideoPlatformTheme.accent
                          : Colors.transparent),
                  width: isFocused ? 2.2 : 1.4,
                ),
                boxShadow: isFocused
                    ? [
                        BoxShadow(
                          color:
                              VideoPlatformTheme.accent.withValues(alpha: 0.55),
                          blurRadius: 12,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 17,
                    color: isFocused
                        ? Colors.black
                        : (selected
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.textSecondary),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: (selected || isFocused)
                          ? FontWeight.w800
                          : FontWeight.w500,
                      color: isFocused
                          ? Colors.black
                          : (selected
                              ? VideoPlatformTheme.accent
                              : VideoPlatformTheme.textPrimary),
                    ),
                  ),
                  if (badgeCount > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: isFocused
                            ? Colors.black
                            : VideoPlatformTheme.accent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        badgeCount > 99 ? '99+' : '$badgeCount',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: isFocused
                              ? VideoPlatformTheme.accent
                              : Colors.black,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTvHeaderActionPill({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool highlighted = false,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      onTap: onTap,
      child: Builder(
        builder: (ctx) {
          final isFocused = Focus.of(ctx).hasPrimaryFocus;
          return AnimatedScale(
            scale: isFocused ? 1.06 : 1.0,
            duration: const Duration(milliseconds: 140),
            child: Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 13),
              decoration: BoxDecoration(
                color: isFocused
                    ? VideoPlatformTheme.accent
                    : (highlighted
                        ? VideoPlatformTheme.accent.withValues(alpha: 0.16)
                        : VideoPlatformTheme.bgCard),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isFocused
                      ? Colors.white
                      : (highlighted
                          ? VideoPlatformTheme.accent
                          : VideoPlatformTheme.borderSubtle),
                  width: isFocused ? 2.4 : 1.2,
                ),
                boxShadow: isFocused
                    ? [
                        BoxShadow(
                          color:
                              VideoPlatformTheme.accent.withValues(alpha: 0.5),
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
                    icon,
                    size: 16,
                    color: isFocused
                        ? Colors.white
                        : (highlighted
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.textSecondary),
                  ),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: (isFocused || highlighted)
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: isFocused
                            ? Colors.white
                            : VideoPlatformTheme.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMobileVodTopHeader(
    AppState state, {
    required VodSource? activeSource,
    required Widget Function({double maxWidth}) buildSourceSelectorButton,
  }) {
    final proxyEnabled = state.proxyService.proxyEnabled;
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgPrimary,
        border: Border(
          bottom: BorderSide(
            color: VideoPlatformTheme.borderSubtle.withValues(alpha: 0.45),
          ),
        ),
      ),
      child: Row(
        children: [
          // 1. NetEase Filmly Media Library Switcher Capsule
          buildSourceSelectorButton(maxWidth: 100),
          const SizedBox(width: 8),
          // 2. Clean Rounded Search Capsule with inline 全网/单站 pill
          Expanded(
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: VideoPlatformTheme.bgCard,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: VideoPlatformTheme.borderSubtle.withValues(alpha: 0.7),
                ),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 10),
                  Icon(
                    Icons.search_rounded,
                    size: 16,
                    color: VideoPlatformTheme.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      onSubmitted: _submitSearch,
                      textInputAction: TextInputAction.search,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        contentPadding: EdgeInsets.zero,
                        hintText: state.aggregatedSearch
                            ? '全网搜电影、剧集、演员...'
                            : '搜索当前媒体库...',
                        hintStyle: TextStyle(
                          fontSize: 12.5,
                          color: VideoPlatformTheme.textMuted,
                        ),
                      ),
                    ),
                  ),
                  if (_searchController.text.isNotEmpty ||
                      state.searchKeyword.isNotEmpty)
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        _searchController.clear();
                        state.clearSearch();
                        setState(() {});
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(
                          Icons.cancel_rounded,
                          size: 15,
                          color: VideoPlatformTheme.textMuted,
                        ),
                      ),
                    ),
                  InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => state.setAggregatedSearch(
                      !state.aggregatedSearch,
                    ),
                    child: Container(
                      margin: const EdgeInsets.only(right: 4),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: state.aggregatedSearch
                            ? VideoPlatformTheme.accent.withValues(alpha: 0.18)
                            : VideoPlatformTheme.bgElevated,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: state.aggregatedSearch
                              ? VideoPlatformTheme.accent
                              : VideoPlatformTheme.borderSubtle,
                        ),
                      ),
                      child: Text(
                        state.aggregatedSearch ? '全网' : '本库',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: state.aggregatedSearch
                              ? VideoPlatformTheme.accent
                              : VideoPlatformTheme.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 3. Compact Proxy indicator button (tap -> Proxy settings, long-press -> toggle)
          InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => _selectTab(6),
            onLongPress: () =>
                state.proxyService.setProxyEnabled(!proxyEnabled),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: proxyEnabled
                    ? VideoPlatformTheme.accent.withValues(alpha: 0.16)
                    : VideoPlatformTheme.bgCard,
                shape: BoxShape.circle,
                border: Border.all(
                  color: proxyEnabled
                      ? VideoPlatformTheme.accent
                      : VideoPlatformTheme.borderSubtle,
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    proxyEnabled
                        ? Icons.bolt_rounded
                        : Icons.public_off_rounded,
                    size: 17,
                    color: proxyEnabled
                        ? VideoPlatformTheme.accent
                        : VideoPlatformTheme.textSecondary,
                  ),
                  if (proxyEnabled)
                    Positioned(
                      right: 6,
                      top: 6,
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: Color(0xFF22C55E),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileContextualTopHeader(AppState state) {
    final (IconData icon, String title) = switch (_selectedIndex) {
      2 => (Icons.downloading_rounded, '离线下载与嗅探中心'),
      3 => (Icons.folder_copy_outlined, '本地视频媒体库'),
      4 => (Icons.bookmarks_rounded, '我的片单 · 历史与收藏'),
      6 => (Icons.bolt_rounded, '代理加速与分流'),
      7 => (Icons.terminal_rounded, '系统终端命令行'),
      8 => (Icons.settings_outlined, '偏好与媒体源设置'),
      _ => (Icons.video_library_rounded, '流光视频'),
    };
    final isSubPage = _selectedIndex != 4;

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        border: Border(
          bottom: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: Row(
        children: [
          if (isSubPage)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '返回影视首页',
              onPressed: () => _selectTab(0),
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 17),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Icon(icon, size: 19, color: VideoPlatformTheme.accent),
            ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: VideoPlatformTheme.textPrimary,
              ),
            ),
          ),
          _buildProxyQuickBadge(state),
          const SizedBox(width: 4),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '更多功能与设置',
            onPressed: () => _showMobileMoreHubSheet(state),
            icon: Icon(
              Icons.apps_rounded,
              size: 20,
              color: VideoPlatformTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTvRemoteSearchButton(AppState state) {
    return Row(
      children: [
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onFocusChange: (_) {
              if (mounted) setState(() {});
            },
            onTap: () => _showTvSearchInputDialog(state),
            child: Builder(
              builder: (ctx) {
                final isFocused = Focus.of(ctx).hasPrimaryFocus;
                return Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: isFocused
                        ? VideoPlatformTheme.accent.withValues(alpha: 0.22)
                        : VideoPlatformTheme.bgCard,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isFocused
                          ? VideoPlatformTheme.accent
                          : VideoPlatformTheme.borderSubtle,
                      width: isFocused ? 2.0 : 1.0,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.search_rounded,
                        size: 17,
                        color: isFocused
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.textMuted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          state.searchKeyword.isNotEmpty
                              ? '当前搜索: ${state.searchKeyword} (按OK修改)'
                              : (state.aggregatedSearch
                                  ? '按遥控器 OK 键全网搜索影视...'
                                  : '按遥控器 OK 键搜索影视...'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: state.searchKeyword.isNotEmpty
                                ? VideoPlatformTheme.textPrimary
                                : VideoPlatformTheme.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(width: 6),
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onFocusChange: (_) {
            if (mounted) setState(() {});
          },
          onTap: () => state.setAggregatedSearch(!state.aggregatedSearch),
          child: Builder(
            builder: (ctx) {
              final isFocused = Focus.of(ctx).hasPrimaryFocus;
              return Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isFocused
                      ? VideoPlatformTheme.accent.withValues(alpha: 0.28)
                      : (state.aggregatedSearch
                          ? VideoPlatformTheme.accent.withValues(alpha: 0.16)
                          : VideoPlatformTheme.bgCard),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: (state.aggregatedSearch || isFocused)
                        ? VideoPlatformTheme.accent
                        : VideoPlatformTheme.borderSubtle,
                    width: isFocused ? 2.0 : 1.0,
                  ),
                ),
                child: Text(
                  state.aggregatedSearch ? '全网搜' : '单站搜',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: (state.aggregatedSearch || isFocused)
                        ? FontWeight.w700
                        : FontWeight.w400,
                    color: (state.aggregatedSearch || isFocused)
                        ? VideoPlatformTheme.accent
                        : VideoPlatformTheme.textSecondary,
                  ),
                ),
              );
            },
          ),
        ),
        if (state.searchKeyword.isNotEmpty) ...[
          const SizedBox(width: 6),
          IconButton(
            tooltip: '清除搜索',
            icon: const Icon(Icons.clear_rounded, size: 17),
            onPressed: () {
              _searchController.clear();
              state.clearSearch();
              setState(() {});
            },
          ),
        ],
      ],
    );
  }

  Future<void> _showTvSearchInputDialog(AppState state) async {
    final ctrl = TextEditingController(text: _searchController.text);
    final submitted = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: VideoPlatformTheme.bgElevated,
          title: Row(
            children: [
              Icon(
                Icons.search_rounded,
                size: 20,
                color: VideoPlatformTheme.accent,
              ),
              const SizedBox(width: 8),
              const Text(
                '搜索影视资源',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          content: SizedBox(
            width: 420,
            child: TextField(
              controller: ctrl,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (v) => Navigator.of(ctx).pop(v),
              decoration: const InputDecoration(
                hintText: '输入片名、主演或关键词...',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text),
              icon: const Icon(Icons.search_rounded, size: 16),
              label: const Text('开始搜索'),
            ),
          ],
        );
      },
    );
    if (submitted != null && mounted) {
      _searchController.text = submitted;
      _submitSearch(submitted);
    }
  }

  Widget _buildProxyQuickBadge(AppState state) {
    final svc = state.proxyService;
    final enabled = svc.proxyEnabled;
    final active = svc.activeNode;

    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      onTap: () => _selectTab(6),
      onLongPress: () => svc.setProxyEnabled(!enabled),
      child: Builder(
        builder: (ctx) {
          final isFocused = Focus.of(ctx).hasPrimaryFocus;
          return Tooltip(
            message: enabled
                ? '代理已开启 (${active?.displayTitle ?? "未选节点"}) · 点击进入代理与分流管理，长按快速开关'
                : '代理已关闭 · 点击配置良心云订阅与分场景路由，长按快速开启',
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: isFocused
                    ? VideoPlatformTheme.accent.withValues(alpha: 0.26)
                    : (enabled
                        ? VideoPlatformTheme.accent.withValues(alpha: 0.14)
                        : VideoPlatformTheme.bgCard),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: (enabled || isFocused)
                      ? VideoPlatformTheme.accent
                      : VideoPlatformTheme.borderSubtle,
                  width: isFocused ? 2.0 : 1.0,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    enabled ? Icons.vpn_lock_rounded : Icons.public_off_rounded,
                    size: 15,
                    color: (enabled || isFocused)
                        ? VideoPlatformTheme.accent
                        : VideoPlatformTheme.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    enabled
                        ? (active != null ? active.displayTitle : '代理已开')
                        : '代理关闭',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: (enabled || isFocused)
                          ? FontWeight.w600
                          : FontWeight.normal,
                      color: (enabled || isFocused)
                          ? VideoPlatformTheme.accent
                          : VideoPlatformTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTvModeButton(AppState state) {
    final isTv = state.tvMode;
    return IconButton(
      tooltip: isTv
          ? '已开启 TV 遥控器大屏模式（Android TV / Apple TV 焦点放大与方向键优化）'
          : '切换为 TV 遥控器大屏模式（适配 Android TV / Apple TV 遥控器）',
      onPressed: () {
        state.setTvMode(!isTv);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 2),
            content: Text(
              !isTv
                  ? '已开启 TV 大屏模式：已启用遥控器方向键焦点高亮、上下键换台与大尺寸海报网格'
                  : '已切换回标准桌面/触屏模式',
            ),
          ),
        );
      },
      icon: Icon(
        Icons.tv_rounded,
        size: 20,
        color: isTv
            ? VideoPlatformTheme.accent
            : VideoPlatformTheme.textSecondary,
      ),
    );
  }

  Widget _buildThemePickerButton(AppState state) {
    return PopupMenuButton<String>(
      tooltip: '切换界面主题',
      icon: Icon(
        Icons.palette_outlined,
        size: 20,
        color: VideoPlatformTheme.accent,
      ),
      onSelected: (themeId) {
        state.setThemeId(themeId);
      },
      itemBuilder: (_) => VideoPlatformTheme.presets.map((p) {
        final selected = p.id == state.themeId;
        return PopupMenuItem<String>(
          value: p.id,
          child: Row(
            children: [
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: p.bgPrimary,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: p.accent, width: 2),
                ),
                alignment: Alignment.center,
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: p.accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      p.name,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    Text(
                      p.subtitle,
                      style: TextStyle(
                        fontSize: 11,
                        color: VideoPlatformTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(
                  Icons.check_rounded,
                  size: 16,
                  color: VideoPlatformTheme.accent,
                ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildDesktopSidebar(AppState state, {VoidCallback? onCollapse}) {
    return Container(
      key: _sidebarContainerKey,
      width: 196,
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        border: Border(
          right: BorderSide(color: VideoPlatformTheme.borderSubtle),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 40,
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: VideoPlatformTheme.borderSubtle.withValues(alpha: 0.6),
                ),
              ),
            ),
            child: Row(
              children: [
                Text(
                  '导航菜单',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: VideoPlatformTheme.textSecondary,
                  ),
                ),
                const Spacer(),
                if (onCollapse != null)
                  InkWell(
                    borderRadius: BorderRadius.circular(5),
                    onFocusChange: (_) {
                      if (mounted) setState(() {});
                    },
                    onTap: onCollapse,
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
                                ? VideoPlatformTheme.accent
                                : VideoPlatformTheme.accent
                                    .withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(
                              color: isFocused
                                  ? Colors.white
                                  : VideoPlatformTheme.accent,
                              width: isFocused ? 2.0 : 1.0,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.chevron_left_rounded,
                                size: 16,
                                color: isFocused
                                    ? Colors.white
                                    : VideoPlatformTheme.accent,
                              ),
                              Text(
                                '收起侧栏',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: isFocused
                                      ? Colors.white
                                      : VideoPlatformTheme.accent,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSidebarSectionTitle('视频中心'),
                  _buildSidebarItem(
                    index: 0,
                    icon: Icons.home_filled,
                    label: '影视片库',
                  ),
                  _buildSidebarItem(
                    index: 1,
                    icon: Icons.live_tv_rounded,
                    label: '电视直播',
                  ),
                  _buildSidebarItem(
                    index: 4,
                    icon: Icons.bookmarks_outlined,
                    label: '历史与收藏',
                  ),
                  const SizedBox(height: 8),
                  _buildSidebarSectionTitle('下载与媒体'),
                  _buildSidebarItem(
                    index: 2,
                    icon: Icons.download_for_offline_outlined,
                    label: '下载工作台',
                    badgeCount: state.activeTasksCount,
                  ),
                  _buildSidebarItem(
                    index: 3,
                    icon: Icons.folder_copy_outlined,
                    label: '视频资料库',
                  ),
                  _buildSidebarItem(
                    index: 5,
                    icon: Icons.send_rounded,
                    label: 'Telegram 会话',
                    badgeCount: state
                        .telegramNotifications.totalUnreadNotificationCount,
                  ),
                  const SizedBox(height: 8),
                  _buildSidebarSectionTitle('网络与系统'),
                  _buildSidebarItem(
                    index: 6,
                    icon: Icons.swap_horiz_rounded,
                    label: '代理服务器',
                  ),
                  _buildSidebarItem(
                    index: 7,
                    icon: Icons.terminal_rounded,
                    label: '终端命令行',
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          if (onCollapse != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 2),
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onFocusChange: (_) {
                  if (mounted) setState(() {});
                },
                onTap: onCollapse,
                child: Builder(
                  builder: (ctx) {
                    final isFocused = Focus.of(ctx).hasPrimaryFocus;
                    return Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: isFocused
                            ? VideoPlatformTheme.accent.withValues(alpha: 0.32)
                            : VideoPlatformTheme.bgCard,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: isFocused
                              ? Colors.white
                              : VideoPlatformTheme.borderSubtle,
                          width: isFocused ? 2.2 : 1.0,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.first_page_rounded,
                            size: 18,
                            color: isFocused
                                ? Colors.white
                                : VideoPlatformTheme.accent,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '收起导航侧栏',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: isFocused
                                  ? Colors.white
                                  : VideoPlatformTheme.accent,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          _buildSidebarItem(
            index: 8,
            icon: Icons.settings_outlined,
            label: '偏好设置',
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildCollapsedSidebarExpandHandle() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: const BorderRadius.horizontal(
          right: Radius.circular(8),
        ),
        onFocusChange: (_) {
          if (mounted) setState(() {});
        },
        onTap: () {
          setState(() {
            _isSidebarCollapsed = false;
            _isMobileSidebarOpen = true;
          });
        },
        child: Builder(
          builder: (ctx) {
            final isFocused = Focus.of(ctx).hasPrimaryFocus;
            return Tooltip(
              message: '展开左侧导航菜单',
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: isFocused
                      ? VideoPlatformTheme.accent
                      : VideoPlatformTheme.bgElevated.withValues(alpha: 0.92),
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(8),
                  ),
                  border: Border.all(
                    color: isFocused
                        ? Colors.white
                        : VideoPlatformTheme.borderStrong,
                    width: isFocused ? 2.2 : 1.0,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.last_page_rounded,
                      size: 16,
                      color: isFocused
                          ? Colors.white
                          : VideoPlatformTheme.accent,
                    ),
                    if (isFocused) ...[
                      const SizedBox(width: 3),
                      const Text(
                        '展开导航',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSidebarSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 12, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: VideoPlatformTheme.textMuted,
        ),
      ),
    );
  }

  Widget _buildSidebarItem({
    required int index,
    required IconData icon,
    required String label,
    int badgeCount = 0,
  }) {
    final selected = _selectedIndex == index;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: InkWell(
        focusNode: _sidebarTabFocusNodes[index],
        borderRadius: BorderRadius.circular(6),
        focusColor: VideoPlatformTheme.accent.withValues(alpha: 0.28),
        onFocusChange: (_) {
          if (mounted) setState(() {});
        },
        onTap: () => _selectTab(index),
        child: Builder(
          builder: (ctx) {
            final isFocused = Focus.of(ctx).hasPrimaryFocus;
            return Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: isFocused
                    ? VideoPlatformTheme.accent.withValues(alpha: 0.26)
                    : (selected
                        ? VideoPlatformTheme.accent.withValues(alpha: 0.15)
                        : Colors.transparent),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isFocused
                      ? VideoPlatformTheme.accent
                      : Colors.transparent,
                  width: isFocused ? 2.0 : 1.0,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 18,
                    color: (selected || isFocused)
                        ? VideoPlatformTheme.accent
                        : VideoPlatformTheme.textSecondary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: (selected || isFocused)
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: (selected || isFocused)
                            ? VideoPlatformTheme.accent
                            : VideoPlatformTheme.textPrimary,
                      ),
                    ),
                  ),
                  if (badgeCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: VideoPlatformTheme.accent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$badgeCount',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
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

  Widget _buildMobileBottomBar(AppState state) {
    int navIdx;
    if (_selectedIndex == 0) {
      navIdx = 0; // 媒体库
    } else if (_selectedIndex == 1) {
      navIdx = 1; // 直播
    } else if (_selectedIndex == 5) {
      navIdx = 2; // Telegram
    } else if (_selectedIndex == 4) {
      navIdx = 3; // 我的片单 (历史与收藏)
    } else {
      // Tabs 2 (下载), 3 (本地视频), 6 (代理), 7 (终端), 8 (设置) highlight "我的"
      navIdx = 4;
    }

    final moreLabel = switch (_selectedIndex) {
      2 => '下载',
      3 => '本地库',
      6 => '代理',
      7 => '终端',
      8 => '设置',
      _ => '我的',
    };

    return Container(
      decoration: BoxDecoration(
        color: VideoPlatformTheme.bgElevated,
        border: Border(
          top: BorderSide(
            color: VideoPlatformTheme.borderSubtle.withValues(alpha: 0.6),
          ),
        ),
      ),
      child: BottomNavigationBar(
        currentIndex: navIdx,
        onTap: (idx) {
          switch (idx) {
            case 0:
              _selectTab(0);
              break;
            case 1:
              _selectTab(1);
              break;
            case 2:
              _selectTab(5);
              break;
            case 3:
              _selectTab(4);
              break;
            case 4:
              _showMobileMoreHubSheet(state);
              break;
          }
        },
        type: BottomNavigationBarType.fixed,
        backgroundColor: VideoPlatformTheme.bgElevated,
        selectedItemColor: VideoPlatformTheme.accent,
        unselectedItemColor: VideoPlatformTheme.textMuted,
        selectedFontSize: 11,
        unselectedFontSize: 11,
        items: [
          const BottomNavigationBarItem(
            icon: Icon(Icons.video_library_outlined, size: 21),
            activeIcon: Icon(Icons.video_library_rounded, size: 22),
            label: '媒体库',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.live_tv_outlined, size: 21),
            activeIcon: Icon(Icons.live_tv_rounded, size: 22),
            label: '电视直播',
          ),
          BottomNavigationBarItem(
            icon: Badge(
              isLabelVisible:
                  state.telegramNotifications.totalUnreadNotificationCount > 0,
              label: Text(
                state.telegramNotifications.totalUnreadNotificationCount > 99
                    ? '99+'
                    : '${state.telegramNotifications.totalUnreadNotificationCount}',
                style: const TextStyle(fontSize: 9.5),
              ),
              child: const Icon(Icons.send_rounded, size: 20),
            ),
            label: 'Telegram',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.bookmarks_outlined, size: 21),
            activeIcon: Icon(Icons.bookmarks_rounded, size: 22),
            label: '我的片单',
          ),
          BottomNavigationBarItem(
            icon: Badge(
              isLabelVisible: state.activeTasksCount > 0,
              label: Text(
                '${state.activeTasksCount}',
                style: const TextStyle(fontSize: 9.5),
              ),
              child: Icon(
                navIdx == 4
                    ? Icons.person_rounded
                    : Icons.person_outline_rounded,
                size: 22,
              ),
            ),
            label: moreLabel,
          ),
        ],
      ),
    );
  }

  void _showMobileMoreHubSheet(AppState state) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: VideoPlatformTheme.bgElevated,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        Widget buildGridTile({
          required int tabIndex,
          required IconData icon,
          required String title,
          required String subtitle,
        }) {
          final selected = _selectedIndex == tabIndex;
          return InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              Navigator.of(ctx).pop();
              _selectTab(tabIndex);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: selected
                    ? VideoPlatformTheme.accent.withValues(alpha: 0.16)
                    : VideoPlatformTheme.bgCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected
                      ? VideoPlatformTheme.accent
                      : VideoPlatformTheme.borderSubtle,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: selected
                          ? VideoPlatformTheme.accent.withValues(alpha: 0.22)
                          : VideoPlatformTheme.bgPrimary.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      icon,
                      size: 19,
                      color: selected
                          ? VideoPlatformTheme.accent
                          : VideoPlatformTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: selected
                                ? VideoPlatformTheme.accent
                                : VideoPlatformTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: VideoPlatformTheme.textMuted,
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

        final proxyEnabled = state.proxyService.proxyEnabled;
        final activeProxy = state.proxyService.activeNode;
        final visibleSources = state.visibleSources;

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: VideoPlatformTheme.borderStrong,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    const AppBrandLogo(size: 28),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '媒体库与个人中心',
                            style: TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w800,
                              color: VideoPlatformTheme.textPrimary,
                            ),
                          ),
                          Text(
                            '当前挂载：${state.selectedSource?.name ?? "未选择"} (${visibleSources.length}个源) · 代理：${proxyEnabled ? (activeProxy?.displayTitle ?? "已开启") : "直连"}',
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
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: const Icon(Icons.close_rounded, size: 20),
                    ),
                  ],
                ),
                // NetEase Filmly Quick Media Library Switcher Strip
                if (visibleSources.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(
                        Icons.storage_rounded,
                        size: 14,
                        color: VideoPlatformTheme.accent,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '快速切换媒体库片源',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: VideoPlatformTheme.textSecondary,
                        ),
                      ),
                      const Spacer(),
                      InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          SourcePickerDialog.show(
                            context,
                            sources: visibleSources,
                            selectedSource: state.selectedSource,
                            onSelect: (src) {
                              _selectTab(0);
                              state.selectVodSource(src);
                            },
                          );
                        },
                        child: Text(
                          '全部 ${visibleSources.length} 个源 ›',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: VideoPlatformTheme.accent,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 34,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: visibleSources.length.clamp(0, 15),
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (_, idx) {
                        final src = visibleSources[idx];
                        final isCurrent = state.selectedSource?.id == src.id;
                        return InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () {
                            Navigator.of(ctx).pop();
                            _selectTab(0);
                            state.selectVodSource(src);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: isCurrent
                                  ? VideoPlatformTheme.accent
                                  : VideoPlatformTheme.bgCard,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isCurrent
                                    ? VideoPlatformTheme.accent
                                    : VideoPlatformTheme.borderSubtle,
                              ),
                            ),
                            child: Text(
                              src.name,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: isCurrent
                                    ? FontWeight.w800
                                    : FontWeight.w500,
                                color: isCurrent
                                    ? Colors.black
                                    : VideoPlatformTheme.textPrimary,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 2.55,
                  children: [
                    buildGridTile(
                      tabIndex: 2,
                      icon: Icons.downloading_rounded,
                      title: '离线下载中心',
                      subtitle: state.activeTasksCount > 0
                          ? '${state.activeTasksCount} 个任务下载中'
                          : '管理 M3U8 缓存与嗅探',
                    ),
                    buildGridTile(
                      tabIndex: 3,
                      icon: Icons.folder_copy_outlined,
                      title: '本地视频资料库',
                      subtitle: '已下载与云端归档视频',
                    ),
                    buildGridTile(
                      tabIndex: 6,
                      icon: Icons.bolt_rounded,
                      title: '代理加速节点',
                      subtitle: proxyEnabled
                          ? (activeProxy?.displayTitle ?? '代理已开启')
                          : '点击管理节点与分流',
                    ),
                    buildGridTile(
                      tabIndex: 8,
                      icon: Icons.settings_outlined,
                      title: '偏好与服务端',
                      subtitle: '片源 · 播放器 · 去广告设置',
                    ),
                    buildGridTile(
                      tabIndex: 4,
                      icon: Icons.bookmarks_rounded,
                      title: '我的片单与历史',
                      subtitle:
                          '${state.history.length} 条记录 · ${state.favorites.length} 收藏',
                    ),
                    buildGridTile(
                      tabIndex: 7,
                      icon: Icons.terminal_rounded,
                      title: '系统终端',
                      subtitle: '远程 SSH / Shell 控制台',
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                // Quick theme & TV mode & logout bar
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: VideoPlatformTheme.bgCard,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: VideoPlatformTheme.borderSubtle),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.palette_outlined,
                        size: 16,
                        color: VideoPlatformTheme.accent,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: VideoPlatformTheme.presets.map((p) {
                              final isSel = p.id == state.themeId;
                              return Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(14),
                                  onTap: () {
                                    state.setThemeId(p.id);
                                    Navigator.of(ctx).pop();
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isSel
                                          ? p.accent.withValues(alpha: 0.18)
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: isSel
                                            ? p.accent
                                            : VideoPlatformTheme.borderSubtle,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          width: 8,
                                          height: 8,
                                          decoration: BoxDecoration(
                                            color: p.accent,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          p.name,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: isSel
                                                ? FontWeight.w600
                                                : FontWeight.normal,
                                            color: isSel
                                                ? p.accent
                                                : VideoPlatformTheme
                                                    .textSecondary,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          foregroundColor: const Color(0xFFEF4444),
                        ),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          state.logout();
                        },
                        icon: const Icon(Icons.logout_rounded, size: 15),
                        label: const Text(
                          '退出',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTelegramFloatingNotifications(AppState state, bool isDesktop) {
    final items = state.telegramNotifications.pendingNotifications
        .take(4)
        .toList();
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    return Positioned(
      top: 64,
      right: 14,
      width: isDesktop ? 340 : 292,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (items.length > 1)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: state.telegramNotifications.dismissAll,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xE617212B),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: const Color(0xFF3E99EE).withValues(alpha: 0.45),
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.clear_all_rounded,
                          size: 14,
                          color: Color(0xFF5EB5F7),
                        ),
                        SizedBox(width: 4),
                        Text(
                          '清除全部提醒',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF5EB5F7),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ...items.map((item) {
            return Padding(
              key: ValueKey('tg_notif_${item.key}_${item.message.id}'),
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: const Color(0xF217212B),
                elevation: 10,
                shadowColor: Colors.black87,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: const Color(0xFF3E99EE).withValues(alpha: 0.55),
                    width: 1.1,
                  ),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () =>
                      state.telegramNotifications.openNotification(item.key),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Color(0xFF42A5F5), Color(0xFF1E88E5)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.send_rounded,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      item.count > 1
                                          ? '${item.accountName} · ${item.count} 条新消息'
                                          : item.accountName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF5EB5F7),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                item.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                item.preview,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  height: 1.3,
                                  color: Color(0xFFD0DCE8),
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 26,
                            minHeight: 26,
                          ),
                          tooltip: '关闭此会话的消息提醒',
                          onPressed: () =>
                              state.telegramNotifications.dismiss(item.key),
                          icon: const Icon(
                            Icons.close_rounded,
                            size: 16,
                            color: Colors.white60,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildActiveScreen(AppState state) {
    switch (_selectedIndex) {
      case 0:
        return VodHomeScreen(appState: state);
      case 1:
        return LiveTvScreen(appState: state);
      case 2:
        return DownloadsScreen(appState: state);
      case 3:
        return MediaLibraryScreen(appState: state);
      case 4:
        return LibraryHistoryScreen(appState: state);
      case 5:
        return TelegramScreen(appState: state);
      case 6:
        return ProxyServerScreen(appState: state);
      case 7:
        return TerminalScreen(appState: state);
      case 8:
        return SettingsScreen(appState: state);
      default:
        return VodHomeScreen(appState: state);
    }
  }
}

/// Draggable Floating Mini-Player (PiP) Overlay rendered above all tabs
class _FloatingMiniPlayerOverlay extends StatefulWidget {
  final AppState appState;
  final MiniPlayerSession session;
  final ValueChanged<int> onRestoreFullScreen;

  const _FloatingMiniPlayerOverlay({
    super.key,
    required this.appState,
    required this.session,
    required this.onRestoreFullScreen,
  });

  @override
  State<_FloatingMiniPlayerOverlay> createState() =>
      _FloatingMiniPlayerOverlayState();
}

class _FloatingMiniPlayerOverlayState
    extends State<_FloatingMiniPlayerOverlay> {
  late final Player _player;
  late final VideoController _controller;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<String>? _errorSub;
  Timer? _autoPlayGuardTimer;
  Timer? _recoveryTimer;
  Timer? _watchdogTimer;

  double _right = 20;
  double _bottom = 20;
  bool _isLargeSize = false;
  bool _isMuted = false;
  double _volume = 100.0;
  double _preMuteVolume = 100.0;
  bool _hasAppliedInitialSeek = false;
  int _pendingSeekSeconds = 0;
  bool _userPaused = false;
  bool _isRecovering = false;
  int _consecutiveRecoveries = 0;
  Duration _lastKnownPosition = Duration.zero;
  Duration _lastKnownDuration = Duration.zero;
  DateTime _lastPositionAdvanceAt = DateTime.now();
  DateTime _lastProgressSave = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _pendingSeekSeconds = widget.session.initialPositionSeconds;
    if (_pendingSeekSeconds > 0) {
      _lastKnownPosition = Duration(seconds: _pendingSeekSeconds);
    }
    _player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 128 * 1024 * 1024,
      ),
    );
    _controller = VideoController(_player);
    _posSub = _player.stream.position.listen(_onPosition);
    _durSub = _player.stream.duration.listen(_onDuration);
    _playingSub = _player.stream.playing.listen(_onPlayingChanged);
    _completedSub = _player.stream.completed.listen(_onCompleted);
    _errorSub = _player.stream.error.listen(_onError);
    _watchdogTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => _checkPlaybackHealth(),
    );
    _startPlayback();
  }

  @override
  void didUpdateWidget(covariant _FloatingMiniPlayerOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.streamUrl != widget.session.streamUrl) {
      _userPaused = false;
      _isRecovering = false;
      _consecutiveRecoveries = 0;
      _hasAppliedInitialSeek = false;
      _pendingSeekSeconds = widget.session.initialPositionSeconds;
      _lastKnownPosition = _pendingSeekSeconds > 0
          ? Duration(seconds: _pendingSeekSeconds)
          : Duration.zero;
      _lastKnownDuration = Duration.zero;
      _lastPositionAdvanceAt = DateTime.now();
      _startPlayback();
    }
  }

  bool _isNonFatalDecodeError(String err) {
    final lower = err.toLowerCase();
    return lower.contains('error while decoding') ||
        lower.contains('decoding frame') ||
        lower.contains('co located pocs') ||
        lower.contains('reference picture missing') ||
        lower.contains('non-existing pps') ||
        lower.contains('non-existing sps') ||
        lower.contains('invalid data found when processing input') ||
        lower.contains('concealing') ||
        lower.contains('packet corrupt') ||
        lower.contains('missing picture in access unit') ||
        lower.contains('no frame!') ||
        lower.contains('discarding') ||
        lower.contains('overread') ||
        lower.contains(' cabac ') ||
        lower.contains('deblocking') ||
        lower.contains('pps id out of range');
  }

  Future<void> _configureMiniNativePlayer() async {
    try {
      final dynamic platform = _player.platform;
      final props = <String, String>{
        'cache': 'yes',
        'cache-on-disk': 'no',
        'cache-secs': '90',
        'cache-pause': 'yes',
        'cache-pause-initial': 'yes',
        'cache-pause-wait': '3.5',
        'demuxer-thread': 'yes',
        'demuxer-max-bytes': '134217728',
        'demuxer-max-back-bytes': '33554432',
        'demuxer-readahead-secs': '45',
        'stream-buffer-size': '4194304',
        'vd-lavc-threads': '0',
        'ad-lavc-threads': '0',
        'demuxer-lavf-probesize': '524288',
        'demuxer-lavf-analyzeduration': '0',
        'network-timeout': '15',
        'tls-verify': 'no',
        'keep-open': 'no',
        'hr-seek-framedrop': 'yes',
        'stream-lavf-o':
            'reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_on_http_error=4xx,5xx,reconnect_delay_max=5',
        'demuxer-lavf-o':
            'seg_max_retry=10,http_persistent=1,http_multiple=1,allowed_extensions=ALL,protocol_whitelist=file,http,https,httpproxy,tcp,tls,crypto,data,rtp,udp,subfile',
        if (widget.session.isLive) ...{
          'loop-file': 'inf',
          'loop-playlist': 'inf',
          'force-seekable': 'yes',
        },
      };
      for (final entry in props.entries) {
        await platform.setProperty(entry.key, entry.value);
      }
    } catch (_) {}
  }

  static String _unwrapRelayUrlIfNeeded(String url) {
    if (!url.contains('/__m3u8_proxy__/')) return url;
    try {
      final uri = Uri.tryParse(url);
      final encoded =
          uri?.queryParameters['u'] ?? uri?.queryParameters['url'] ?? '';
      if (encoded.isNotEmpty) {
        final decoded = utf8.decode(
          base64Url.decode(base64Url.normalize(encoded)),
          allowMalformed: true,
        );
        if (decoded.startsWith('http://') || decoded.startsWith('https://')) {
          return decoded;
        }
      }
    } catch (_) {}
    return url;
  }

  Future<void> _startPlayback({int? overrideResumeSeconds}) async {
    if (overrideResumeSeconds != null && overrideResumeSeconds > 2) {
      _pendingSeekSeconds = overrideResumeSeconds;
      _hasAppliedInitialSeek = false;
    }
    var streamUrl = _unwrapRelayUrlIfNeeded(widget.session.streamUrl);
    if (!widget.session.isLive && !streamUrl.contains('/api/telegram/')) {
      final relayed = await widget.appState.proxyService.resolveProxiedStreamUrl(
        RequestScenario.vodStream,
        streamUrl,
        headers: widget.session.headers,
        cleanM3u8Ads: widget.appState.vodFilterM3u8Ads,
      );
      if (relayed.isNotEmpty) {
        streamUrl = relayed;
      }
    }
    final usingLocalStreamRelay = streamUrl.contains('/__m3u8_proxy__/') ||
        streamUrl.contains('://127.0.0.1:') ||
        streamUrl.contains('://localhost:');

    await _configureMiniNativePlayer();

    try {
      final dynamic platform = _player.platform;
      final headers = widget.session.headers;
      final ua = headers['User-Agent'] ??
          headers['user-agent'] ??
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
      await platform.setProperty('user-agent', ua);
      final ref =
          headers['Referer'] ?? headers['referer'] ?? headers['Referrer'] ?? '';
      await platform.setProperty('referrer', ref);

      if (usingLocalStreamRelay) {
        await platform.setProperty('http-proxy', '');
      } else {
        final scenario = widget.session.isLive
            ? RequestScenario.liveStream
            : (streamUrl.contains('/api/telegram/')
                ? RequestScenario.telegram
                : RequestScenario.vodStream);
        final proxyUrl = await widget.appState.proxyService
            .resolvePlayerHttpProxyUrl(
          scenario,
          streamUri: Uri.tryParse(streamUrl),
        );
        await platform.setProperty('http-proxy', proxyUrl);
      }
    } catch (_) {}

    if (!mounted) return;
    _lastPositionAdvanceAt = DateTime.now();
    await _player.setVolume(_isMuted ? 0.0 : _volume);
    await _player.open(
      Media(
        streamUrl,
        httpHeaders: usingLocalStreamRelay ? const {} : widget.session.headers,
      ),
      play: !_userPaused,
    );
  }

  void _onDuration(Duration dur) {
    if (dur > Duration.zero) {
      _lastKnownDuration = dur;
      _tryApplyPendingSeek();
    }
  }

  void _tryApplyPendingSeek() {
    if (_hasAppliedInitialSeek || _pendingSeekSeconds <= 2) return;
    final totalSec = _lastKnownDuration.inSeconds > 0
        ? _lastKnownDuration.inSeconds
        : _player.state.duration.inSeconds;
    if (totalSec <= 0) return;
    _hasAppliedInitialSeek = true;
    final targetSec = _pendingSeekSeconds;
    _pendingSeekSeconds = 0;
    if (targetSec < totalSec - 4) {
      _player.seek(Duration(seconds: targetSec));
    }
  }

  void _onPlayingChanged(bool playing) {
    _autoPlayGuardTimer?.cancel();
    if (playing) {
      _lastPositionAdvanceAt = DateTime.now();
      return;
    }
    if (_userPaused || _isRecovering || _player.state.completed) {
      return;
    }
    // Guard against unexpected libmpv self-pauses (e.g. momentary audio/buffer hiccup)
    _autoPlayGuardTimer = Timer(const Duration(milliseconds: 450), () {
      if (!mounted ||
          _userPaused ||
          _isRecovering ||
          _player.state.playing ||
          _player.state.completed) {
        return;
      }
      _player.play();
    });
  }

  void _onCompleted(bool completed) {
    if (!completed || !mounted || _userPaused) return;
    if (widget.session.isLive) {
      _scheduleAutoRecovery(keepPosition: false);
      return;
    }
    final durSec = _lastKnownDuration.inSeconds > 0
        ? _lastKnownDuration.inSeconds
        : _player.state.duration.inSeconds;
    final posSec = _lastKnownPosition.inSeconds;
    // Detect premature EOF caused by transient network/proxy disconnect mid-video
    final isPrematureEof =
        durSec <= 0 || (durSec > 10 && posSec < durSec - 6);
    if (isPrematureEof) {
      _scheduleAutoRecovery(keepPosition: true);
      return;
    }
    _handleEpisodeFinishedInMiniPlayer();
  }

  void _onError(String err) {
    if (err.isEmpty || !mounted || _userPaused) return;
    if (_isNonFatalDecodeError(err)) return;
    _scheduleAutoRecovery(keepPosition: !widget.session.isLive);
  }

  void _checkPlaybackHealth() {
    if (!mounted || _userPaused || _isRecovering) return;
    if (_player.state.completed) {
      _onCompleted(true);
      return;
    }
    if (!_player.state.playing && !_player.state.buffering) {
      _player.play();
    }
    final idleSec = DateTime.now().difference(_lastPositionAdvanceAt).inSeconds;
    if (idleSec >= 14) {
      _scheduleAutoRecovery(keepPosition: !widget.session.isLive);
    }
  }

  void _scheduleAutoRecovery({required bool keepPosition}) {
    if (!mounted || _userPaused || _isRecovering) return;
    _isRecovering = true;
    _recoveryTimer?.cancel();
    final resumeSec = keepPosition ? _lastKnownPosition.inSeconds : 0;
    final delayMs = (_consecutiveRecoveries * 400).clamp(250, 2000);
    _consecutiveRecoveries++;
    _recoveryTimer = Timer(Duration(milliseconds: delayMs), () async {
      if (!mounted || _userPaused) {
        _isRecovering = false;
        return;
      }
      try {
        await _startPlayback(
          overrideResumeSeconds: resumeSec > 2 ? resumeSec : null,
        );
      } finally {
        if (mounted) {
          _isRecovering = false;
        }
      }
    });
  }

  Future<void> _handleEpisodeFinishedInMiniPlayer() async {
    final s = widget.session;
    if (s.vodSource != null && s.vodId != null && s.vodId!.isNotEmpty) {
      try {
        final detail =
            await widget.appState.api.fetchVodDetail(s.vodSource!, s.vodId!);
        if (!mounted) return;
        if (s.groupIndex >= 0 && s.groupIndex < detail.playGroups.length) {
          final grp = detail.playGroups[s.groupIndex];
          final nextEpIdx = s.episodeIndex + 1;
          if (nextEpIdx >= 0 && nextEpIdx < grp.episodes.length) {
            final nextEp = grp.episodes[nextEpIdx];
            final resolved = await widget.appState.api.resolveVodPlayback(
              s.vodSource!,
              playGroup: grp.name,
              episodeUrl: nextEp.rawUrl,
            );
            if (!mounted) return;
            var playUrl = resolved.directUrl.isNotEmpty
                ? resolved.directUrl
                : widget.appState.api.resolveUrl(resolved.serverProxyUrl);
            var headers = resolved.directUrl.isNotEmpty
                ? <String, String>{...resolved.headers}
                : <String, String>{
                    ...widget.appState.api.authHeaders,
                    ...resolved.headers,
                  };
            if (resolved.directUrl.isNotEmpty) {
              final relayed =
                  await widget.appState.proxyService.resolveProxiedStreamUrl(
                RequestScenario.vodStream,
                playUrl,
                headers: headers,
                cleanM3u8Ads: widget.appState.vodFilterM3u8Ads,
              );
              if (!mounted) return;
              if (relayed.isNotEmpty) {
                playUrl = relayed;
              }
            }
            widget.appState.startMiniPlayer(
              MiniPlayerSession(
                title: s.title,
                subtitle: '${nextEp.title} · ${s.vodSource!.name}',
                streamUrl: playUrl,
                headers: headers,
                isLive: false,
                vodSource: s.vodSource,
                vodId: s.vodId,
                vodTitle: s.vodTitle,
                vodPoster: s.vodPoster,
                episodeName: nextEp.title,
                groupIndex: s.groupIndex,
                episodeIndex: nextEpIdx,
                initialPositionSeconds: widget.appState.vodSkipIntroSeconds,
              ),
            );
            return;
          }
        }
      } catch (_) {}
    }
    // Single-video or last episode finished: loop back to start so mini-player doesn't freeze
    _lastKnownPosition = Duration.zero;
    _scheduleAutoRecovery(keepPosition: false);
  }

  void _onPosition(Duration pos) {
    if (pos > Duration.zero) {
      if ((pos - _lastKnownPosition).inMilliseconds.abs() >= 200) {
        _lastPositionAdvanceAt = DateTime.now();
        _consecutiveRecoveries = 0;
      }
      _lastKnownPosition = pos;
    }
    final totalSec = _lastKnownDuration.inSeconds > 0
        ? _lastKnownDuration.inSeconds
        : _player.state.duration.inSeconds;
    if (!_hasAppliedInitialSeek && _pendingSeekSeconds > 2 && totalSec > 0) {
      _tryApplyPendingSeek();
      return;
    }

    // Periodically save VOD progress while watching in mini-player
    final s = widget.session;
    if (!s.isLive &&
        s.vodSource != null &&
        s.vodId != null &&
        pos.inSeconds > 2) {
      final now = DateTime.now();
      if (now.difference(_lastProgressSave).inSeconds >= 5) {
        _lastProgressSave = now;
        widget.appState.saveVodProgress(
          sourceKey: s.vodSource!.id,
          vodId: s.vodId!,
          groupIndex: s.groupIndex,
          episodeIndex: s.episodeIndex,
          episodeName: s.episodeName ?? '',
          positionSeconds: pos.inSeconds,
          durationSeconds: totalSec,
        );
      }
    }
  }

  @override
  void dispose() {
    _autoPlayGuardTimer?.cancel();
    _recoveryTimer?.cancel();
    _watchdogTimer?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();
    _errorSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final width = _isLargeSize
        ? (screenSize.width - 20).clamp(320.0, 440.0)
        : 340.0;
    final height = _isLargeSize ? 248.0 : 200.0;

    return Positioned(
      right: _right.clamp(8.0, (screenSize.width - width - 8).clamp(8.0, 4000.0)),
      bottom:
          _bottom.clamp(8.0, (screenSize.height - height - 8).clamp(8.0, 4000.0)),
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            _right -= details.delta.dx;
            _bottom -= details.delta.dy;
          });
        },
        child: Material(
          elevation: 16,
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: VideoPlatformTheme.accent.withValues(alpha: 0.7),
                width: 1.5,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x88000000),
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Video(
                  controller: _controller,
                  fill: Colors.black,
                  controls: NoVideoControls,
                ),
                // Top header bar (drag handle + title + restore/close buttons)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(10, 5, 4, 8),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xDD000000), Color(0x00000000)],
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          widget.session.isLive
                              ? Icons.live_tv_rounded
                              : Icons.picture_in_picture_alt_rounded,
                          size: 14,
                          color: VideoPlatformTheme.accent,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                widget.session.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (widget.session.subtitle.isNotEmpty)
                                Text(
                                  widget.session.subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 10,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                        VideoProxyNodeSelector(
                          proxyService: widget.appState.proxyService,
                          scenario: widget.session.isLive
                              ? RequestScenario.liveStream
                              : (widget.session.streamUrl
                                      .contains('/api/telegram/')
                                  ? RequestScenario.telegram
                                  : RequestScenario.vodStream),
                          compact: true,
                          overlayStyle: true,
                          onProxyChanged: (_) {
                            _scheduleAutoRecovery(
                              keepPosition: !widget.session.isLive,
                            );
                          },
                        ),
                        const SizedBox(width: 3),
                        VideoDownloadSpeedBadge(
                          player: _player,
                          compact: true,
                        ),
                        const SizedBox(width: 2),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 26,
                            minHeight: 26,
                          ),
                          tooltip: _isLargeSize ? '缩小悬浮窗' : '放大悬浮窗',
                          onPressed: () =>
                              setState(() => _isLargeSize = !_isLargeSize),
                          icon: Icon(
                            _isLargeSize
                                ? Icons.photo_size_select_small_rounded
                                : Icons.photo_size_select_large_rounded,
                            size: 15,
                            color: Colors.white,
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 26,
                            minHeight: 26,
                          ),
                          tooltip: '恢复大屏播放',
                          onPressed: () => widget.onRestoreFullScreen(
                            _player.state.position.inSeconds > 0
                                ? _player.state.position.inSeconds
                                : _lastKnownPosition.inSeconds,
                          ),
                          icon: const Icon(
                            Icons.open_in_full_rounded,
                            size: 15,
                            color: Colors.white,
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 26,
                            minHeight: 26,
                          ),
                          tooltip: '关闭小窗',
                          onPressed: widget.appState.closeMiniPlayer,
                          icon: const Icon(
                            Icons.close_rounded,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Bottom control strip
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Color(0xDD000000), Color(0x00000000)],
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!widget.session.isLive)
                          StreamBuilder<Duration>(
                            stream: _player.stream.position,
                            initialData: _player.state.position,
                            builder: (_, posSnap) {
                              return StreamBuilder<Duration>(
                                stream: _player.stream.duration,
                                initialData: _player.state.duration,
                                builder: (_, durSnap) {
                                  final pos = posSnap.data ?? Duration.zero;
                                  final dur = durSnap.data ?? Duration.zero;
                                  final maxMs = dur.inMilliseconds > 0
                                      ? dur.inMilliseconds.toDouble()
                                      : 1.0;
                                  final curMs = pos.inMilliseconds
                                      .toDouble()
                                      .clamp(0.0, maxMs);
                                  return SizedBox(
                                    height: 16,
                                    child: SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        trackHeight: 2.8,
                                        thumbShape:
                                            const RoundSliderThumbShape(
                                          enabledThumbRadius: 5.5,
                                        ),
                                        overlayShape:
                                            const RoundSliderOverlayShape(
                                          overlayRadius: 10.0,
                                        ),
                                        activeTrackColor:
                                            VideoPlatformTheme.accent,
                                        inactiveTrackColor: Colors.white24,
                                        thumbColor: Colors.white,
                                      ),
                                      child: Slider(
                                        value: curMs,
                                        min: 0.0,
                                        max: maxMs,
                                        onChanged: (val) {
                                          if (dur.inMilliseconds > 0) {
                                            _player.seek(
                                              Duration(
                                                milliseconds: val.round(),
                                              ),
                                            );
                                          }
                                        },
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        Row(
                          children: [
                            StreamBuilder<bool>(
                              stream: _player.stream.playing,
                              initialData: _player.state.playing,
                          builder: (_, snap) {
                            final playing = snap.data ?? true;
                            return IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 28,
                                minHeight: 28,
                              ),
                              onPressed: () {
                                final currentlyPlaying = _player.state.playing;
                                _userPaused = currentlyPlaying;
                                if (!_userPaused) {
                                  _lastPositionAdvanceAt = DateTime.now();
                                  if (_player.state.completed) {
                                    _scheduleAutoRecovery(keepPosition: false);
                                    return;
                                  }
                                }
                                _player.playOrPause();
                              },
                              icon: Icon(
                                playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                size: 20,
                                color: Colors.white,
                              ),
                            );
                          },
                        ),
                        if (!widget.session.isLive)
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 28,
                              minHeight: 28,
                            ),
                            tooltip: '快进 +15s',
                            onPressed: () {
                              _player.seek(
                                _player.state.position +
                                    const Duration(seconds: 15),
                              );
                            },
                            icon: const Icon(
                              Icons.forward_10_rounded,
                              size: 18,
                              color: Colors.white,
                            ),
                          ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 28,
                            minHeight: 28,
                          ),
                          tooltip: _isMuted || _volume <= 0 ? '取消静音' : '静音',
                          onPressed: () {
                            if (_isMuted || _volume <= 0) {
                              final restored =
                                  _preMuteVolume > 5 ? _preMuteVolume : 100.0;
                              setState(() {
                                _isMuted = false;
                                _volume = restored;
                              });
                              _player.setVolume(restored);
                            } else {
                              _preMuteVolume = _volume;
                              setState(() {
                                _isMuted = true;
                                _volume = 0.0;
                              });
                              _player.setVolume(0.0);
                            }
                          },
                          icon: Icon(
                            _isMuted || _volume <= 0
                                ? Icons.volume_off_rounded
                                : (_volume < 50
                                    ? Icons.volume_down_rounded
                                    : Icons.volume_up_rounded),
                            size: 17,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(
                          width: _isLargeSize ? 90 : 64,
                          height: 24,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 2.5,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 5,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 9,
                              ),
                              activeTrackColor: VideoPlatformTheme.accent,
                              inactiveTrackColor: Colors.white24,
                              thumbColor: Colors.white,
                            ),
                            child: Slider(
                              value: (_isMuted ? 0.0 : _volume)
                                  .clamp(0.0, 100.0),
                              min: 0,
                              max: 100,
                              onChanged: (val) {
                                final clamped = val.clamp(0.0, 100.0);
                                if (clamped > 0) _preMuteVolume = clamped;
                                setState(() {
                                  _volume = clamped;
                                  _isMuted = clamped <= 0;
                                });
                                _player.setVolume(clamped);
                              },
                            ),
                          ),
                        ),
                        const Spacer(),
                        InkWell(
                          onTap: () => widget.onRestoreFullScreen(
                            _player.state.position.inSeconds > 0
                                ? _player.state.position.inSeconds
                                : _lastKnownPosition.inSeconds,
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: VideoPlatformTheme.accent,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              '恢复大屏',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
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
    );
  }
}

/// Global `Cmd/Ctrl + K` Command Palette & Omni-Search Dialog
class _GlobalCommandPaletteDialog extends StatefulWidget {
  final AppState appState;
  final ValueChanged<int> onNavigateTab;
  final void Function(
    VodSource source,
    String vodId,
    String title,
    String poster,
  ) onOpenVodDetail;

  const _GlobalCommandPaletteDialog({
    required this.appState,
    required this.onNavigateTab,
    required this.onOpenVodDetail,
  });

  @override
  State<_GlobalCommandPaletteDialog> createState() =>
      _GlobalCommandPaletteDialogState();
}

class _GlobalCommandPaletteDialogState
    extends State<_GlobalCommandPaletteDialog> {
  final TextEditingController _queryCtrl = TextEditingController();
  int _selectedIndex = 0;

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  List<({IconData icon, String title, String subtitle, VoidCallback onRun})>
      _buildEntries() {
    final kw = _queryCtrl.text.trim().toLowerCase();
    final state = widget.appState;
    final entries =
        <({IconData icon, String title, String subtitle, VoidCallback onRun})>[];

    void addIfMatch({
      required IconData icon,
      required String title,
      required String subtitle,
      required VoidCallback onRun,
    }) {
      if (kw.isEmpty ||
          title.toLowerCase().contains(kw) ||
          subtitle.toLowerCase().contains(kw)) {
        entries.add((
          icon: icon,
          title: title,
          subtitle: subtitle,
          onRun: onRun,
        ));
      }
    }

    // 1. Navigation commands
    const navItems = [
      (0, Icons.home_filled, '跳转：影视片库', '浏览点播电影、剧集、综艺、动漫'),
      (1, Icons.live_tv_rounded, '跳转：电视直播', '观看央视、卫视及全球 IPTV 直播'),
      (2, Icons.download_for_offline_outlined, '跳转：下载工作台', '管理 M3U8 下载任务与网页视频嗅探'),
      (3, Icons.folder_copy_outlined, '跳转：视频资料库', '浏览服务端已下载的媒体文件'),
      (4, Icons.bookmarks_outlined, '跳转：观看历史与收藏', '查看收藏夹与历史播放进度'),
      (5, Icons.send_rounded, '跳转：Telegram 会话', '收发 Telegram 消息、截图、相册与视频'),
      (6, Icons.swap_horiz_rounded, '跳转：代理服务器', '管理 HTTP / SOCKS5 / SS / Trojan 代理'),
      (7, Icons.terminal_rounded, '跳转：终端命令行', '打开交互式系统终端与快捷运维指令'),
      (8, Icons.settings_outlined, '跳转：偏好与服务端设置', '配置 115 网盘、TVBox 源与去广告参数'),
    ];
    for (final nav in navItems) {
      addIfMatch(
        icon: nav.$2,
        title: nav.$3,
        subtitle: nav.$4,
        onRun: () {
          Navigator.of(context).pop();
          widget.onNavigateTab(nav.$1);
        },
      );
    }

    // 2. Theme switching commands
    for (final preset in VideoPlatformTheme.presets) {
      addIfMatch(
        icon: Icons.palette_outlined,
        title: '切换主题：${preset.name}',
        subtitle: preset.subtitle,
        onRun: () {
          Navigator.of(context).pop();
          state.setThemeId(preset.id);
        },
      );
    }

    // 3. Watch History & Favorites quick resume
    for (final h in state.history.take(15)) {
      final src = state.resolveLibrarySource(h);
      if (src != null) {
        addIfMatch(
          icon: Icons.history_rounded,
          title: '续播：《${h.title}》 ${h.episode}',
          subtitle: '历史记录 · ${src.name}',
          onRun: () {
            Navigator.of(context).pop();
            widget.onOpenVodDetail(src, h.vodId, h.title, h.poster);
          },
        );
      }
    }

    // 4. Current VOD catalog items
    final curSrc = state.selectedSource;
    if (curSrc != null) {
      for (final item in state.vodItems.take(30)) {
        addIfMatch(
          icon: Icons.movie_creation_outlined,
          title: '点播：《${item.vodName}》',
          subtitle: '${curSrc.name} · ${item.vodRemarks}',
          onRun: () {
            Navigator.of(context).pop();
            widget.onOpenVodDetail(
              curSrc,
              item.vodId,
              item.vodName,
              item.vodPic,
            );
          },
        );
      }
    }

    // 5. Live TV channels
    for (final ch in state.liveChannels.take(40)) {
      if (ch.urls.isEmpty) continue;
      addIfMatch(
        icon: Icons.live_tv_rounded,
        title: '直播频道：${ch.name}',
        subtitle: '${ch.group} · 小窗立即播放',
        onRun: () {
          Navigator.of(context).pop();
          state.startMiniPlayer(
            MiniPlayerSession(
              title: ch.name,
              subtitle: ch.group,
              streamUrl: ch.urls.first,
              headers: ch.headers,
              isLive: true,
              liveChannel: ch,
            ),
          );
        },
      );
    }

    // 6.VOD Source switching
    for (final s in state.sources.take(25)) {
      addIfMatch(
        icon: Icons.layers_outlined,
        title: '切换点播站点：${s.name}',
        subtitle: s.groupLabel,
        onRun: () {
          Navigator.of(context).pop();
          widget.onNavigateTab(0);
          state.selectVodSource(s);
        },
      );
    }

    return entries.take(35).toList();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _buildEntries();
    final safeIdx = entries.isEmpty
        ? 0
        : _selectedIndex.clamp(0, entries.length - 1);

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowDown): () {
          if (entries.isEmpty) return;
          setState(() => _selectedIndex = (safeIdx + 1) % entries.length);
        },
        const SingleActivator(LogicalKeyboardKey.arrowUp): () {
          if (entries.isEmpty) return;
          setState(
            () => _selectedIndex =
                (safeIdx - 1 + entries.length) % entries.length,
          );
        },
        const SingleActivator(LogicalKeyboardKey.enter): () {
          if (entries.isNotEmpty) {
            entries[safeIdx].onRun();
          }
        },
      },
      child: Dialog(
        backgroundColor: VideoPlatformTheme.bgElevated,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 60),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: VideoPlatformTheme.borderStrong),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620, maxHeight: 460),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.search_rounded,
                      size: 20,
                      color: VideoPlatformTheme.accent,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _queryCtrl,
                        autofocus: true,
                        onChanged: (_) => setState(() => _selectedIndex = 0),
                        style: const TextStyle(fontSize: 14),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          hintText:
                              '输入关键词检索功能模块、影片续播、直播频道、切换片源或主题 (↑↓ 选择，Enter 执行)...',
                        ),
                      ),
                    ),
                    if (_queryCtrl.text.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.clear, size: 16),
                        onPressed: () {
                          _queryCtrl.clear();
                          setState(() => _selectedIndex = 0);
                        },
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: entries.isEmpty
                    ? Center(
                        child: Text(
                          '无匹配命令，按 Enter 可直接在全网搜索「${_queryCtrl.text.trim()}」',
                          style: TextStyle(
                            color: VideoPlatformTheme.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (_, idx) {
                          final item = entries[idx];
                          final selected = idx == safeIdx;
                          return ListTile(
                            dense: true,
                            selected: selected,
                            selectedTileColor: VideoPlatformTheme.accent
                                .withValues(alpha: 0.16),
                            leading: Icon(
                              item.icon,
                              size: 19,
                              color: selected
                                  ? VideoPlatformTheme.accent
                                  : VideoPlatformTheme.textSecondary,
                            ),
                            title: Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: selected
                                    ? VideoPlatformTheme.accent
                                    : VideoPlatformTheme.textPrimary,
                              ),
                            ),
                            subtitle: Text(
                              item.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: VideoPlatformTheme.textMuted,
                              ),
                            ),
                            trailing: Icon(
                              Icons.keyboard_return_rounded,
                              size: 15,
                              color: selected
                                  ? VideoPlatformTheme.accent
                                  : Colors.transparent,
                            ),
                            onTap: item.onRun,
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
