import 'package:flutter/material.dart';

import '../theme.dart';

/// Custom vector brand mark matching the native desktop/mobile cinema app icon.
/// Dynamically adapts its primary prism & timeline fill to [VideoPlatformTheme.accent].
class AppBrandLogo extends StatelessWidget {
  final double size;

  const AppBrandLogo({
    super.key,
    this.size = 28,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _AppBrandLogoPainter(
          accent: VideoPlatformTheme.accent,
          accentHover: VideoPlatformTheme.accentHover,
          liveDot: VideoPlatformTheme.badgeHot,
        ),
      ),
    );
  }
}

class _AppBrandLogoPainter extends CustomPainter {
  final Color accent;
  final Color accentHover;
  final Color liveDot;

  const _AppBrandLogoPainter({
    required this.accent,
    required this.accentHover,
    required this.liveDot,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // 1. Outer squircle container (#131722 -> #1E2434)
    final outerRRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, w, h),
      Radius.circular(w * 0.22),
    );
    final bgPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFF1E2433),
          Color(0xFF10131C),
        ],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    canvas.drawRRect(outerRRect, bgPaint);

    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = (w * 0.035).clamp(0.8, 2.0)
      ..color = const Color(0xFF333D52);
    canvas.drawRRect(outerRRect, borderPaint);

    // 2. Left & right subtle film perforation ticks
    final tickPaint = Paint()..color = const Color(0xFF2B3448);
    for (final yRatio in const [0.26, 0.46, 0.66]) {
      final tickH = h * 0.11;
      final tickW = w * 0.055;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(w * 0.11, h * yRatio, tickW, tickH),
          Radius.circular(w * 0.02),
        ),
        tickPaint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(w * 0.835, h * yRatio, tickW, tickH),
          Radius.circular(w * 0.02),
        ),
        tickPaint,
      );
    }

    // 3. Back layered play card
    final backPath = Path()
      ..moveTo(w * 0.33, h * 0.27)
      ..lineTo(w * 0.66, h * 0.46)
      ..lineTo(w * 0.33, h * 0.65)
      ..close();
    canvas.drawPath(
      backPath,
      Paint()
        ..color = accent.withValues(alpha: 0.32)
        ..style = PaintingStyle.fill,
    );

    // 4. Main play prism
    final playPath = Path()
      ..moveTo(w * 0.38, h * 0.25)
      ..lineTo(w * 0.73, h * 0.46)
      ..lineTo(w * 0.38, h * 0.67)
      ..close();
    final playPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [accentHover, accent],
      ).createShader(Rect.fromLTWH(w * 0.38, h * 0.25, w * 0.35, h * 0.42));
    canvas.drawPath(playPath, playPaint);

    // 5. Bottom timeline scrubber bar
    final barY = h * 0.80;
    final barH = (h * 0.055).clamp(1.5, 4.0);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.20, barY, w * 0.60, barH),
        Radius.circular(barH),
      ),
      Paint()..color = const Color(0xFF2D3548),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.20, barY, w * 0.38, barH),
        Radius.circular(barH),
      ),
      Paint()..color = accent,
    );
    canvas.drawCircle(
      Offset(w * 0.58, barY + barH / 2),
      barH * 0.95,
      Paint()..color = Colors.white,
    );

    // 6. Top-right live status dot
    canvas.drawCircle(
      Offset(w * 0.80, h * 0.19),
      (w * 0.045).clamp(1.4, 3.5),
      Paint()..color = liveDot,
    );
  }

  @override
  bool shouldRepaint(covariant _AppBrandLogoPainter oldDelegate) {
    return oldDelegate.accent != accent ||
        oldDelegate.accentHover != accentHover ||
        oldDelegate.liveDot != liveDot;
  }
}
