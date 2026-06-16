import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'package:medTrackPlus/beta/cv_v2/cv_v2_metrics.dart';
import 'package:medTrackPlus/beta/mlkit_test/pill_detection_service.dart'
    show DetectionPhase;

/// Overlay painter for the Dev CV Lab: face box, lip contours, inner-mouth
/// rect, tight pill blob rect, smoothed tracker rect and per-region labels.
class CvV2OverlayPainter extends CustomPainter {
  final PillResultV2 result;
  final Size imageSize; // raw buffer size (pre-rotation)
  final InputImageRotation rotation;
  final bool isFrontCamera;

  CvV2OverlayPainter({
    required this.result,
    required this.imageSize,
    required this.rotation,
    required this.isFrontCamera,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final face = result.face;
    if (face == null) return;
    final color = _phaseColor(result.phase);

    // Face box
    canvas.drawRect(
      _transformRect(face.boundingBox, size),
      Paint()
        ..color = color.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Lip contours
    final lipPaint = Paint()..color = color;
    for (final type in [
      FaceContourType.upperLipTop,
      FaceContourType.upperLipBottom,
      FaceContourType.lowerLipTop,
      FaceContourType.lowerLipBottom,
    ]) {
      final contour = face.contours[type];
      if (contour == null) continue;
      for (final p in contour.points) {
        canvas.drawCircle(
          _transformPoint(Offset(p.x.toDouble(), p.y.toDouble()), size),
          2.0,
          lipPaint,
        );
      }
    }

    // Inner mouth rect
    if (result.mouthRegion != null) {
      final r = _transformRect(result.mouthRegion!, size);
      canvas.drawRect(
        r,
        Paint()
          ..color = Colors.blueAccent.withValues(alpha: 0.8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    // Tight pill blob rect (the V2 star of the show)
    if (result.pillBlobRegion != null) {
      final r = _transformRect(result.pillBlobRegion!, size);
      canvas.drawRect(
        r,
        Paint()
          ..color = Colors.greenAccent.withValues(alpha: 0.25)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRect(
        r,
        Paint()
          ..color = Colors.greenAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      _label(canvas, r.topLeft,
          'PILL ${(result.metrics.pillConfidence * 100).toStringAsFixed(0)}%',
          Colors.green);
    }

    // Smoothed tracker rect
    if (result.smoothedPillRegion != null) {
      final r = _transformRect(result.smoothedPillRegion!, size);
      canvas.drawRect(
        r,
        Paint()
          ..color = Colors.orangeAccent.withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }

    // Last seen (during drink / verify phases)
    final phase = result.phase;
    final showLastSeen = result.lastSeenPillRegion != null &&
        (phase == DetectionPhase.mouthClosedWithPill ||
            phase == DetectionPhase.drinking ||
            phase == DetectionPhase.swallowConfirmed ||
            phase == DetectionPhase.swallowFailed ||
            phase == DetectionPhase.timeoutExpired);
    if (showLastSeen) {
      final r = _transformRect(result.lastSeenPillRegion!, size);
      canvas.drawRect(
        r,
        Paint()
          ..color = color.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      _label(canvas, r.topLeft, _lastSeenLabel(phase), color);
    }
  }

  String _lastSeenLabel(DetectionPhase phase) {
    switch (phase) {
      case DetectionPhase.mouthClosedWithPill:
        return 'WAITING FOR DRINK';
      case DetectionPhase.drinking:
        return 'DRINKING (${result.metrics.drinkLabel ?? "?"})';
      case DetectionPhase.swallowConfirmed:
        return 'SWALLOWED ✓';
      case DetectionPhase.swallowFailed:
        return 'NOT SWALLOWED ✗';
      case DetectionPhase.timeoutExpired:
        return 'TIMEOUT';
      default:
        return '';
    }
  }

  void _label(Canvas canvas, Offset topLeft, String text, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: ' $text ',
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          backgroundColor: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(topLeft.dx, topLeft.dy - 16));
  }

  Offset _transformPoint(Offset point, Size canvasSize) {
    final rotated = _isRotated90or270()
        ? Size(imageSize.height, imageSize.width)
        : imageSize;
    double x = point.dx * canvasSize.width / rotated.width;
    final double y = point.dy * canvasSize.height / rotated.height;
    if (isFrontCamera) x = canvasSize.width - x;
    return Offset(x, y);
  }

  Rect _transformRect(Rect rect, Size canvasSize) {
    final a = _transformPoint(rect.topLeft, canvasSize);
    final b = _transformPoint(rect.bottomRight, canvasSize);
    return Rect.fromLTRB(
      a.dx < b.dx ? a.dx : b.dx,
      a.dy < b.dy ? a.dy : b.dy,
      a.dx > b.dx ? a.dx : b.dx,
      a.dy > b.dy ? a.dy : b.dy,
    );
  }

  bool _isRotated90or270() =>
      rotation == InputImageRotation.rotation90deg ||
      rotation == InputImageRotation.rotation270deg;

  /// Public phase→color mapping (HUD and guidance bar reuse it).
  static Color phaseColor(DetectionPhase phase) => _phaseColor(phase);

  static Color _phaseColor(DetectionPhase phase) {
    switch (phase) {
      case DetectionPhase.noFace:
        return Colors.red;
      case DetectionPhase.faceDetected:
        return Colors.orange;
      case DetectionPhase.mouthOpen:
        return Colors.blue;
      case DetectionPhase.pillOnTongue:
        return Colors.green;
      case DetectionPhase.mouthClosedWithPill:
        return Colors.amber;
      case DetectionPhase.drinking:
        return Colors.lightBlue;
      case DetectionPhase.mouthReopened:
        return Colors.cyan;
      case DetectionPhase.swallowConfirmed:
        return Colors.greenAccent;
      case DetectionPhase.swallowFailed:
        return Colors.redAccent;
      case DetectionPhase.timeoutExpired:
        return Colors.grey;
    }
  }

  @override
  bool shouldRepaint(covariant CvV2OverlayPainter oldDelegate) =>
      oldDelegate.result != result;
}
