import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Wraps a mobile screen or dialog to support the standard left-edge -> right
/// swipe-back gesture (`从左边缘向右划动返回上一页`) with a visual edge chevron
/// indicator and conflict protection against horizontal scrollables/sliders.
class MobileEdgeSwipeBack extends StatefulWidget {
  final Widget child;
  final VoidCallback onBack;
  final bool enabled;
  final double edgeZoneWidth;

  const MobileEdgeSwipeBack({
    super.key,
    required this.child,
    required this.onBack,
    this.enabled = true,
    this.edgeZoneWidth = 36.0,
  });

  @override
  State<MobileEdgeSwipeBack> createState() => _MobileEdgeSwipeBackState();
}

class _MobileEdgeSwipeBackState extends State<MobileEdgeSwipeBack> {
  static const double _triggerDistance = 64.0;
  static const double _minFastSwipeDistance = 28.0;
  static const double _fastSwipeVelocity = 420.0;

  int? _activePointer;
  Offset _startPos = Offset.zero;
  DateTime _startTime = DateTime.fromMillisecondsSinceEpoch(0);
  double _dragDx = 0.0;
  double _dragY = 0.0;
  bool _isTracking = false;
  bool _isCommitted = false;

  void _reset() {
    if (_isTracking || _isCommitted || _dragDx > 0) {
      if (mounted) {
        setState(() {
          _activePointer = null;
          _isTracking = false;
          _isCommitted = false;
          _dragDx = 0.0;
        });
      } else {
        _activePointer = null;
        _isTracking = false;
        _isCommitted = false;
        _dragDx = 0.0;
      }
    }
  }

  bool _canActivateForEvent(PointerDownEvent event) {
    if (!widget.enabled) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    if (event.kind != PointerDeviceKind.touch &&
        event.kind != PointerDeviceKind.stylus &&
        event.kind != PointerDeviceKind.unknown) {
      return false;
    }
    final screenW = MediaQuery.maybeSizeOf(context)?.width ?? 1024.0;
    if (screenW >= 960) return false;
    return event.position.dx <= widget.edgeZoneWidth;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_activePointer != null) return;
    if (!_canActivateForEvent(event)) return;
    _activePointer = event.pointer;
    _startPos = event.position;
    _startTime = DateTime.now();
    _dragDx = 0.0;
    _dragY = event.localPosition.dy;
    _isTracking = true;
    _isCommitted = false;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_isTracking || event.pointer != _activePointer) return;
    final dx = event.position.dx - _startPos.dx;
    final dy = (event.position.dy - _startPos.dy).abs();

    if (!_isCommitted) {
      if (dx < -8.0 || (dy > 24.0 && dy > dx * 1.15)) {
        _reset();
        return;
      }
      if (dx >= 12.0 && dx > dy * 1.15) {
        _isCommitted = true;
      }
    }

    if (_isCommitted && mounted) {
      setState(() {
        _dragDx = dx.clamp(0.0, 160.0);
        _dragY = event.localPosition.dy;
      });
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (!_isTracking || event.pointer != _activePointer) return;
    final committed = _isCommitted;
    final finalDx = _dragDx;
    final elapsedMs =
        DateTime.now().difference(_startTime).inMilliseconds.clamp(1, 10000);
    final velocityPxPerSec = (finalDx / elapsedMs) * 1000.0;
    _reset();

    if (!committed) return;
    final shouldTrigger = finalDx >= _triggerDistance ||
        (finalDx >= _minFastSwipeDistance &&
            velocityPxPerSec >= _fastSwipeVelocity);
    if (shouldTrigger && mounted) {
      HapticFeedback.lightImpact();
      widget.onBack();
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _activePointer) {
      _reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    final progress = (_dragDx / _triggerDistance).clamp(0.0, 1.0);
    final readyToPop = _dragDx >= _triggerDistance;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          if (_isCommitted && _dragDx > 6)
            Positioned(
              left: (_dragDx * 0.38 - 18).clamp(-16.0, 36.0),
              top: (_dragY - 24).clamp(
                24.0,
                (MediaQuery.maybeSizeOf(context)?.height ?? 600.0) - 72.0,
              ),
              child: IgnorePointer(
                child: Opacity(
                  opacity: (progress * 1.25).clamp(0.25, 1.0),
                  child: Transform.scale(
                    scale: 0.82 + 0.22 * progress,
                    child: Container(
                      width: 42,
                      height: 48,
                      decoration: BoxDecoration(
                        color: readyToPop
                            ? VideoPlatformTheme.accent.withValues(alpha: 0.92)
                            : const Color(0xD8121620),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: readyToPop
                              ? Colors.white
                              : VideoPlatformTheme.accent.withValues(alpha: 0.7),
                          width: readyToPop ? 2.0 : 1.3,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x77000000),
                            blurRadius: 12,
                            offset: Offset(2, 3),
                          ),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.arrow_back_ios_new_rounded,
                        size: 18,
                        color: readyToPop
                            ? Colors.white
                            : VideoPlatformTheme.accent,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
