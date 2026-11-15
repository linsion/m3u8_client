import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/proxy_routing_service.dart';
import '../theme.dart';

/// Dropdown selector for switching proxy nodes (or toggling Direct / Auto-Fastest)
/// directly from any video playback interface (VOD Player, Live TV, Floating Mini-Player,
/// Telegram Video Gallery).
class VideoProxyNodeSelector extends StatefulWidget {
  final ProxyRoutingService proxyService;
  final RequestScenario scenario;
  final ValueChanged<String>? onProxyChanged;
  final bool compact;
  final bool overlayStyle;
  final FocusNode? focusNode;
  final FocusNode? upFocusNode;
  final FocusNode? downFocusNode;
  final FocusNode? leftFocusNode;
  final FocusNode? rightFocusNode;
  final VoidCallback? onInteraction;

  const VideoProxyNodeSelector({
    super.key,
    required this.proxyService,
    this.scenario = RequestScenario.vodStream,
    this.onProxyChanged,
    this.compact = false,
    this.overlayStyle = true,
    this.focusNode,
    this.upFocusNode,
    this.downFocusNode,
    this.leftFocusNode,
    this.rightFocusNode,
    this.onInteraction,
  });

  @override
  State<VideoProxyNodeSelector> createState() => _VideoProxyNodeSelectorState();
}

class _VideoProxyNodeSelectorState extends State<VideoProxyNodeSelector> {
  static const String _kModeDirect = '__mode_direct__';
  static const String _kModeAuto = '__mode_auto__';
  static const String _kActionRetest = '__action_retest__';

  final GlobalKey<PopupMenuButtonState<String>> _menuKey =
      GlobalKey<PopupMenuButtonState<String>>();
  bool _isFocused = false;

  ProxyRoutingService get proxyService => widget.proxyService;
  RequestScenario get scenario => widget.scenario;
  ValueChanged<String>? get onProxyChanged => widget.onProxyChanged;
  bool get compact => widget.compact;
  bool get overlayStyle => widget.overlayStyle;

  bool _isDirectActive() {
    if (!proxyService.proxyEnabled) return true;
    final rule = proxyService.scenarioRules[scenario];
    return rule?.mode == ScenarioRouteMode.direct;
  }

  String _buildCurrentLabel() {
    if (_isDirectActive()) {
      return compact ? '直连' : '代理: 直连';
    }
    final active = proxyService.resolveNodeForScenario(scenario);
    if (active == null) {
      return compact ? '无节点' : '代理: 未选节点';
    }
    final isAuto =
        proxyService.selectionMode == ProxySelectionMode.autoFastest &&
        (proxyService.scenarioRules[scenario]?.specificNodeId == null ||
            proxyService.scenarioRules[scenario]!.specificNodeId!.isEmpty);
    final shortName = _shortenNodeName(
      active.displayTitle,
      maxChars: compact ? 8 : 14,
    );
    final lat = (active.latencyMs != null && active.latencyMs! > 0)
        ? ' ${active.latencyMs}ms'
        : '';
    if (compact) {
      return isAuto ? '⚡$shortName' : shortName;
    }
    return isAuto ? '⚡ $shortName$lat' : '$shortName$lat';
  }

  static String _shortenNodeName(String raw, {int maxChars = 14}) {
    final trimmed = raw.trim();
    if (trimmed.runes.length <= maxChars) return trimmed;
    return '${String.fromCharCodes(trimmed.runes.take(maxChars))}…';
  }

  Color _latencyColor(int? ms) {
    if (ms == null || ms == 0) return Colors.white54;
    if (ms < 0) return const Color(0xFFFF6B6B);
    if (ms < 220) return const Color(0xFF34D399);
    if (ms < 450) return const Color(0xFFFBBF24);
    return const Color(0xFFFB923C);
  }

  Future<void> _handleSelection(String value) async {
    if (value == _kActionRetest) {
      unawaited(proxyService.testAllNodesLatency(silent: false));
      return;
    }

    if (value == _kModeDirect) {
      await proxyService.updateScenarioRule(
        scenario,
        mode: ScenarioRouteMode.direct,
        clearSpecificNode: true,
      );
      onProxyChanged?.call('已切换为直连播放（不走客户端代理）');
      return;
    }

    if (value == _kModeAuto) {
      if (!proxyService.proxyEnabled) {
        await proxyService.setProxyEnabled(true);
      }
      await proxyService.updateScenarioRule(
        scenario,
        mode: ScenarioRouteMode.proxyNode,
        clearSpecificNode: true,
      );
      await proxyService.setSelectionMode(ProxySelectionMode.autoFastest);
      final node = proxyService.activeNode;
      onProxyChanged?.call(
        node != null
            ? '已切换为自动择优代理：${node.displayTitle}'
            : '已切换为自动择优代理',
      );
      return;
    }

    // Specific proxy node selected
    if (!proxyService.proxyEnabled) {
      await proxyService.setProxyEnabled(true);
    }
    await proxyService.updateScenarioRule(
      scenario,
      mode: ScenarioRouteMode.proxyNode,
      clearSpecificNode: true,
    );
    await proxyService.selectNode(value, switchToManual: true);
    final selected = proxyService.activeNode;
    onProxyChanged?.call(
      selected != null
          ? '已切换代理节点：${selected.displayTitle}'
          : '已切换代理节点',
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: proxyService,
      builder: (context, _) {
        final isDirect = _isDirectActive();
        final activeNode = proxyService.resolveNodeForScenario(scenario);
        final isAuto = !isDirect &&
            proxyService.selectionMode == ProxySelectionMode.autoFastest &&
            (proxyService.scenarioRules[scenario]?.specificNodeId == null ||
                proxyService.scenarioRules[scenario]!.specificNodeId!.isEmpty);
        final selectableNodes =
            proxyService.nodes.where((n) => !n.isInfoNode).toList();

        // Sort reachable/tested nodes to top while keeping stable relative order
        final sortedNodes = List<ProxyNode>.from(selectableNodes)
          ..sort((a, b) {
            final aOk = a.isReachable ? 0 : (a.latencyMs == null ? 1 : 2);
            final bOk = b.isReachable ? 0 : (b.latencyMs == null ? 1 : 2);
            if (aOk != bOk) return aOk.compareTo(bOk);
            if (a.isReachable && b.isReachable) {
              return a.effectiveScore.compareTo(b.effectiveScore);
            }
            return 0;
          });

        final badgeColor = isDirect
            ? Colors.white60
            : const Color(0xFF34D399);

        return Focus(
          focusNode: widget.focusNode,
          canRequestFocus: widget.focusNode != null,
          onFocusChange: (focused) {
            if (focused) {
              widget.onInteraction?.call();
            }
            if (mounted && _isFocused != focused) {
              setState(() => _isFocused = focused);
            }
          },
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent || event is KeyRepeatEvent) {
              widget.onInteraction?.call();
              if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
                  widget.upFocusNode != null) {
                widget.upFocusNode!.requestFocus();
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
                  widget.downFocusNode != null) {
                widget.downFocusNode!.requestFocus();
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
                  widget.leftFocusNode != null) {
                widget.leftFocusNode!.requestFocus();
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
                  widget.rightFocusNode != null) {
                widget.rightFocusNode!.requestFocus();
                return KeyEventResult.handled;
              }
            }
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.select ||
                    event.logicalKey == LogicalKeyboardKey.enter ||
                    event.logicalKey == LogicalKeyboardKey.numpadEnter ||
                    event.logicalKey == LogicalKeyboardKey.space ||
                    event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
              _menuKey.currentState?.showButtonMenu();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: ExcludeFocus(
            excluding: widget.focusNode != null,
            child: PopupMenuButton<String>(
            key: _menuKey,
            tooltip: '切换视频播放代理节点',
            offset: Offset(0, compact ? 26 : 34),
            color: VideoPlatformTheme.bgElevated,
            constraints: const BoxConstraints(
              minWidth: 270,
              maxWidth: 360,
              maxHeight: 440,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: VideoPlatformTheme.borderStrong),
            ),
            onSelected: _handleSelection,
            itemBuilder: (ctx) {
              final items = <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                value: _kModeDirect,
                height: 38,
                child: Row(
                  children: [
                    Icon(
                      isDirect
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 16,
                      color: isDirect
                          ? VideoPlatformTheme.accent
                          : VideoPlatformTheme.textMuted,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        '🚫 直连播放 (不走代理)',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: _kModeAuto,
                height: 38,
                child: Row(
                  children: [
                    Icon(
                      isAuto
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 16,
                      color: isAuto
                          ? VideoPlatformTheme.accent
                          : VideoPlatformTheme.textMuted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        proxyService.fastestNode != null
                            ? '⚡ 自动择优 (${_shortenNodeName(proxyService.fastestNode!.displayTitle, maxChars: 12)})'
                            : '⚡ 自动择优 (卡顿自动换)',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: _kActionRetest,
                height: 34,
                child: Row(
                  children: [
                    Icon(
                      proxyService.isTestingNodes
                          ? Icons.sync_rounded
                          : Icons.speed_rounded,
                      size: 15,
                      color: VideoPlatformTheme.accent,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      proxyService.isTestingNodes
                          ? '正在并发测速中...'
                          : '🔄 立即测速全部节点 (${sortedNodes.length})',
                      style: TextStyle(
                        fontSize: 12,
                        color: VideoPlatformTheme.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const PopupMenuDivider(height: 8),
            ];

            if (sortedNodes.isEmpty) {
              items.add(
                PopupMenuItem<String>(
                  enabled: false,
                  height: 36,
                  child: Text(
                    '暂无可用代理节点，请先在「代理服务」中更新订阅',
                    style: TextStyle(
                      fontSize: 12,
                      color: VideoPlatformTheme.textMuted,
                    ),
                  ),
                ),
              );
            } else {
              for (final node in sortedNodes) {
                final isSelectedNode =
                    !isDirect && activeNode?.id == node.id;
                final latMs = node.latencyMs;
                final latText = latMs == null
                    ? '未测速'
                    : (latMs < 0 ? '超时' : '${latMs}ms');
                final speedText = node.speedLabel;

                items.add(
                  PopupMenuItem<String>(
                    value: node.id,
                    height: 38,
                    child: Row(
                      children: [
                        Icon(
                          isSelectedNode
                              ? Icons.check_circle_rounded
                              : Icons.circle_outlined,
                          size: 15,
                          color: isSelectedNode
                              ? const Color(0xFF34D399)
                              : VideoPlatformTheme.textMuted,
                        ),
                        const SizedBox(width: 7),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: VideoPlatformTheme.accent.withValues(
                              alpha: 0.15,
                            ),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            node.protocolBadge,
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                              color: VideoPlatformTheme.accent,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            node.displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: isSelectedNode
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              color: isSelectedNode
                                  ? const Color(0xFF34D399)
                                  : VideoPlatformTheme.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          speedText.isNotEmpty
                              ? '$latText · $speedText'
                              : latText,
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w600,
                            color: _latencyColor(latMs),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }
            }
            return items;
          },
            child: Builder(
              builder: (ctx) {
                final isFocused = _isFocused || Focus.of(ctx).hasPrimaryFocus;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 110),
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? 7 : 10,
                    vertical: compact ? 3 : 5,
                  ),
                  decoration: BoxDecoration(
                    color: isFocused
                        ? VideoPlatformTheme.accent
                        : (overlayStyle
                            ? const Color(0xBB090E14)
                            : VideoPlatformTheme.bgCard),
                    borderRadius: BorderRadius.circular(compact ? 10 : 18),
                    border: Border.all(
                      color: isFocused
                          ? Colors.white
                          : (isDirect
                              ? (overlayStyle
                                  ? Colors.white.withValues(alpha: 0.25)
                                  : VideoPlatformTheme.borderSubtle)
                              : const Color(0xFF34D399)
                                  .withValues(alpha: 0.65)),
                      width: isFocused ? 2.2 : 1.0,
                    ),
                    boxShadow: isFocused
                        ? [
                            BoxShadow(
                              color: VideoPlatformTheme.accent
                                  .withValues(alpha: 0.65),
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
                        isDirect
                            ? Icons.public_off_rounded
                            : Icons.vpn_lock_rounded,
                        size: compact ? 11.5 : 13.5,
                        color: isFocused ? Colors.white : badgeColor,
                      ),
                      SizedBox(width: compact ? 3 : 5),
                      Text(
                        _buildCurrentLabel(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isFocused
                              ? Colors.white
                              : (overlayStyle
                                  ? Colors.white
                                  : VideoPlatformTheme.textPrimary),
                          fontSize: compact ? 10.5 : 11.5,
                          fontWeight:
                              isFocused ? FontWeight.w700 : FontWeight.w600,
                        ),
                      ),
                      SizedBox(width: compact ? 1 : 2),
                      Icon(
                        Icons.arrow_drop_down_rounded,
                        size: compact ? 14 : 16,
                        color: isFocused
                            ? Colors.white
                            : (overlayStyle
                                ? Colors.white70
                                : VideoPlatformTheme.textSecondary),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        );
      },
    );
  }
}
