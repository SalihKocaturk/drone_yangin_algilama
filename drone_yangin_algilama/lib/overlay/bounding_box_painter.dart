import 'package:flutter/material.dart';

import '../services/detection_models.dart';

/// Tespit edilen alev bolgelerinin etrafini kirmizi dikdortgen/cember ile cizer.
/// Koordinatlar normalize (0..1) geldigi icin painter'in size'ina gore olceklenir,
/// boylece overlay hangi cihaz/cozunurlukte calisirsa calissin doğru hizalanir.
class BoundingBoxPainter extends CustomPainter {
  final List<FlameDetection> detections;
  final bool drawAsCircle;

  BoundingBoxPainter({required this.detections, this.drawAsCircle = false});

  @override
  void paint(Canvas canvas, Size size) {
    if (detections.isEmpty) return;

    final boxPaint = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0;

    final glowPaint = Paint()
      ..color = Colors.redAccent.withValues(alpha: 0.18)
      ..style = PaintingStyle.fill;

    final labelStyle = TextStyle(
      color: Colors.white,
      fontSize: 13,
      fontWeight: FontWeight.bold,
      backgroundColor: Colors.redAccent.withValues(alpha: 0.9),
    );

    for (final d in detections) {
      final rect = Rect.fromLTRB(
        d.left * size.width,
        d.top * size.height,
        d.right * size.width,
        d.bottom * size.height,
      );

      if (drawAsCircle) {
        final center = rect.center;
        final radius = (rect.width > rect.height ? rect.width : rect.height) / 2;
        canvas.drawCircle(center, radius, glowPaint);
        canvas.drawCircle(center, radius, boxPaint);
      } else {
        canvas.drawRect(rect, glowPaint);
        canvas.drawRect(rect, boxPaint);
      }

      final tp = TextPainter(
        text: TextSpan(
          text: ' 🔥 ${d.label} %${(d.confidence * 100).toStringAsFixed(0)} ',
          style: labelStyle,
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(rect.left, (rect.top - tp.height).clamp(0, size.height)));
    }
  }

  @override
  bool shouldRepaint(covariant BoundingBoxPainter oldDelegate) {
    return oldDelegate.detections != detections || oldDelegate.drawAsCircle != drawAsCircle;
  }
}
