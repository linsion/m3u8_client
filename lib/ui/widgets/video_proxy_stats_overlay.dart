import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/proxy_routing_service.dart';
import '../theme.dart';

/// Toggle button placed in video player control bars to show or hide
/// the real-time proxy IP & inbound/outbound traffic statistics detail window.
class VideoProxyStatsButton extends StatefulWidget {
  final ProxyRoutingService proxyService;
  final RequestScenario scenario;
  final bool isShowingStats;
  final VoidCallback onToggle;
  final bool compact;
  final bool overlayStyle;
  final FocusNode? focusNode;
  final FocusNode? upFocusNode;
  final FocusNode? downFocusNode;
  final FocusNode? leftFocusNode;
  final FocusNode? rightFocusNode;
  final VoidCallback? onInteraction;

  const VideoProxyStatsButton({
    super.key,
    required this.proxyService,
    this.scenario = RequestScenario.vodStream,
    required this.isShowingStats,
    required this.onToggle,
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
  State<VideoProxyStatsButton> createState() => _VideoProxyStatsButtonState();
}

class _VideoProxyStatsButtonState extends State<VideoProxyStatsButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.isShowingStats;
    final compact = widget.compact;
    final overlayStyle = widget.overlayStyle;
    final accentColor = active
        ? const Color(0xFF38BDF8)
        : (overlayStyle ? Colors.white70 : VideoPlatformTheme.textSecondary);

    return Focus(
      focusNode: widget.focusNode,
      canRequestFocus: true,
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
          widget.onToggle();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: ExcludeFocus(
        excluding: true,
        child: Tooltip(
          message: active ? '隐藏代理实时 IP 与流量监控窗口' : '显示代理实时 IP 与流量监控窗口',
          child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            widget.onInteraction?.call();
            widget.onToggle();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 7 : 10,
              vertical: compact ? 3.5 : 5,
            ),
            decoration: BoxDecoration(
              color: _isFocused
                  ? VideoPlatformTheme.accent.withValues(alpha: 0.34)
                  : (active
                      ? const Color(0xFF0284C7).withValues(alpha: 0.28)
                      : (overlayStyle
                          ? Colors.white.withValues(alpha: 0.10)
                          : VideoPlatformTheme.bgCard)),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _isFocused
                    ? Colors.white
                    : (active
                        ? const Color(0xFF38BDF8).withValues(alpha: 0.75)
                        : (overlayStyle
                            ? Colors.white24
                            : VideoPlatformTheme.borderSubtle)),
                width: _isFocused ? 1.8 : 1.0,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.radar_rounded,
                  size: compact ? 12 : 14,
                  color: _isFocused ? Colors.white : accentColor,
                ),
                const SizedBox(width: 4),
                Text(
                  compact ? '监控' : '代理监控',
                  style: TextStyle(
                    fontSize: compact ? 10.5 : 11.5,
                    fontWeight:
                        (_isFocused || active) ? FontWeight.w700 : FontWeight.w600,
                    color: _isFocused
                        ? Colors.white
                        : (active
                            ? const Color(0xFF7DD3FC)
                            : (overlayStyle
                                ? Colors.white
                                : VideoPlatformTheme.textPrimary)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }
}

/// Draggable floating detail panel displaying real-time proxy Entry/Exit IP,
/// Location/ISP, RTT latency, and live Inbound/Outbound traffic statistics.
class VideoProxyStatsDetailPanel extends StatefulWidget {
  final ProxyRoutingService proxyService;
  final RequestScenario scenario;
  final VoidCallback onClose;

  const VideoProxyStatsDetailPanel({
    super.key,
    required this.proxyService,
    required this.scenario,
    required this.onClose,
  });

  @override
  State<VideoProxyStatsDetailPanel> createState() =>
      _VideoProxyStatsDetailPanelState();
}

class _VideoProxyStatsDetailPanelState
    extends State<VideoProxyStatsDetailPanel> {
  Timer? _tickTimer;
  Offset _dragOffset = const Offset(16, 56);
  bool _isProbingIp = false;
  String _lastProbedKey = '';

  String _routeLabel = '检测中...';
  bool _isUsingProxy = false;
  String _nodeName = '-';
  String _protocolBadge = '-';
  String _entryHostPort = '-';
  String _entryResolvedIp = '解析中...';
  String _exitPublicIp = '探测中...';
  String _exitLocation = '';
  String _exitIsp = '';
  int _rttMs = 0;

  @override
  void initState() {
    super.initState();
    widget.proxyService.addListener(_onProxyConfigChanged);
    _refreshIpTelemetry(force: false);
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    widget.proxyService.removeListener(_onProxyConfigChanged);
    _tickTimer?.cancel();
    super.dispose();
  }

  void _onProxyConfigChanged() {
    if (!mounted) return;
    final eff = widget.proxyService.resolveEffectiveRoute(widget.scenario);
    final node = widget.proxyService.resolveNodeForScenario(widget.scenario);
    final curKey = '${eff.name}|${node?.id ?? ""}';
    if (curKey != _lastProbedKey) {
      _refreshIpTelemetry(force: true);
    } else {
      setState(() {});
    }
  }

  Future<void> _refreshIpTelemetry({bool force = true}) async {
    if (!mounted) return;
    final eff = widget.proxyService.resolveEffectiveRoute(widget.scenario);
    final node = widget.proxyService.resolveNodeForScenario(widget.scenario);
    _lastProbedKey = '${eff.name}|${node?.id ?? ""}';

    setState(() {
      _isProbingIp = true;
    });
    try {
      final info = await widget.proxyService.probeScenarioRealTimeIpInfo(
        widget.scenario,
        forceRefresh: force,
      );
      if (!mounted) return;
      setState(() {
        _routeLabel = info.routeLabel;
        _isUsingProxy = info.isUsingProxy;
        _nodeName = info.nodeName;
        _protocolBadge = info.protocolBadge;
        _entryHostPort = info.entryHostPort;
        _entryResolvedIp = info.entryResolvedIp;
        _exitPublicIp = info.exitPublicIp;
        _exitLocation = info.exitLocation;
        _exitIsp = info.exitIsp;
        _rttMs = info.rttMs;
        _isProbingIp = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _isProbingIp = false);
      }
    }
  }

  static String _formatSpeed(double bytesPerSec) {
    if (bytesPerSec <= 0) return '0 B/s';
    const kb = 1024.0;
    const mb = kb * 1024.0;
    if (bytesPerSec >= mb) {
      return '${(bytesPerSec / mb).toStringAsFixed(2)} MB/s';
    }
    if (bytesPerSec >= kb) {
      return '${(bytesPerSec / kb).toStringAsFixed(1)} KB/s';
    }
    return '${bytesPerSec.toStringAsFixed(0)} B/s';
  }

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const kb = 1024.0;
    const mb = kb * 1024.0;
    const gb = mb * 1024.0;
    if (bytes >= gb) {
      return '${(bytes / gb).toStringAsFixed(2)} GB';
    }
    if (bytes >= mb) {
      return '${(bytes / mb).toStringAsFixed(2)} MB';
    }
    if (bytes >= kb) {
      return '${(bytes / kb).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    final svc = widget.proxyService;
    final inSpeed = svc.currentInboundBytesPerSecond;
    final outSpeed = svc.currentOutboundBytesPerSecond;
    final totalIn = svc.totalInboundBytes;
    final totalOut = svc.totalOutboundBytes;
    final activeConns = svc.activeTunnelConnections;
    final totalReqs = svc.totalTunnelRequests;
    final prefetched = svc.localBridgePrefetchedSegmentCount;

    final statusColor = _isUsingProxy
        ? const Color(0xFF34D399)
        : const Color(0xFFFBBF24);

    return Positioned(
      left: _dragOffset.dx.clamp(8.0, 520.0),
      top: _dragOffset.dy.clamp(8.0, 420.0),
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            _dragOffset += details.delta;
          });
        },
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 340,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: const Color(0xEB0D131F),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: statusColor.withValues(alpha: 0.45),
                width: 1.2,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black87,
                  blurRadius: 18,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: statusColor.withValues(alpha: 0.6),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        '代理实时 IP 与流量监控',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => _refreshIpTelemetry(force: true),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_isProbingIp)
                              const SizedBox(
                                width: 11,
                                height: 11,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.6,
                                  color: Color(0xFF38BDF8),
                                ),
                              )
                            else
                              const Icon(
                                Icons.refresh_rounded,
                                size: 13,
                                color: Color(0xFF38BDF8),
                              ),
                            const SizedBox(width: 3),
                            const Text(
                              '刷新IP',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF38BDF8),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: widget.onClose,
                      child: const Padding(
                        padding: EdgeInsets.all(3),
                        child: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Divider(height: 1, color: Colors.white12),
                const SizedBox(height: 8),

                // Route & Node Info
                _buildInfoRow(
                  label: '当前模式',
                  value: _routeLabel,
                  valueColor: statusColor,
                  trailingBadge: _protocolBadge,
                ),
                const SizedBox(height: 5),
                _buildInfoRow(
                  label: '生效节点',
                  value: _nodeName,
                  valueColor: Colors.white,
                  trailingBadge: _rttMs > 0 ? '${_rttMs}ms' : null,
                ),
                const SizedBox(height: 5),
                _buildInfoRow(
                  label: '入口节点IP',
                  value: _entryResolvedIp.isNotEmpty
                      ? _entryResolvedIp
                      : _entryHostPort,
                  valueColor: Colors.white70,
                  monospace: true,
                ),
                const SizedBox(height: 5),
                _buildInfoRow(
                  label: '实时出口IP',
                  value: _exitPublicIp,
                  valueColor: const Color(0xFF38BDF8),
                  monospace: true,
                ),
                if (_exitLocation.isNotEmpty || _exitIsp.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  _buildInfoRow(
                    label: 'IP 归属地',
                    value: [
                      if (_exitLocation.isNotEmpty) _exitLocation,
                      if (_exitIsp.isNotEmpty) _exitIsp,
                    ].join(' · '),
                    valueColor: Colors.white70,
                  ),
                ],

                const SizedBox(height: 9),
                // Traffic grid
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _buildMetricCell(
                              title: '↓ 实时入站速率',
                              value: _formatSpeed(inSpeed),
                              color: const Color(0xFF34D399),
                            ),
                          ),
                          Container(
                            width: 1,
                            height: 28,
                            color: Colors.white12,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _buildMetricCell(
                              title: '↑ 实时出站速率',
                              value: _formatSpeed(outSpeed),
                              color: const Color(0xFF60A5FA),
                            ),
                          ),
                        ],
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 6),
                        child: Divider(height: 1, color: Colors.white10),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: _buildMetricCell(
                              title: '⬇️ 累计入站流量',
                              value: _formatBytes(totalIn),
                              color: Colors.white,
                            ),
                          ),
                          Container(
                            width: 1,
                            height: 28,
                            color: Colors.white12,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _buildMetricCell(
                              title: '⬆️ 累计出站流量',
                              value: _formatBytes(totalOut),
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '活跃隧道: $activeConns · 预取分片: $prefetched · 累计请求: $totalReqs',
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: Colors.white54,
                        ),
                      ),
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: svc.resetTrafficCounters,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        child: Text(
                          '清零统计',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: Colors.white60,
                            decoration: TextDecoration.underline,
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
      ),
    );
  }

  Widget _buildInfoRow({
    required String label,
    required String value,
    required Color valueColor,
    String? trailingBadge,
    bool monospace = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 68,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 11.5,
              color: Colors.white54,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            maxLines: 1,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: valueColor,
              fontFamily: monospace ? 'monospace' : null,
            ),
          ),
        ),
        if (trailingBadge != null && trailingBadge.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(left: 6),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              trailingBadge,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: Colors.white70,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMetricCell({
    required String title,
    required String value,
    required Color color,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 10.5,
            color: Colors.white54,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: color,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }
}
