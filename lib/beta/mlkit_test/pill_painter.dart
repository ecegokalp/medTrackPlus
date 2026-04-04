import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'pill_detection_service.dart';

class PillPainter extends CustomPainter {
  final PillOnTongueResult result;
  final Size imageSize;

  PillPainter({
    required this.result,
    required this.imageSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final face = result.face;
    if (face == null) return;

    // We don't scale since face contour coordinates are in image space
    // and the preview fills the widget — but we need to handle potential
    // coordinate mapping. For front camera, x may be mirrored.

    // Draw face bounding box (subtle)
    final faceRect = face.boundingBox;
    final facePaint = Paint()
      ..color = _phaseColor(result.phase).withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawRect(faceRect, facePaint);

    // Draw lip contours
    _drawLipContours(canvas, face);

    // Draw mouth region highlight if mouth is open
    if (result.mouthRegion != null && result.phase.index >= 2) {
      final mouthPaint = Paint()
        ..color = result.phase == DetectionPhase.pillDetected
            ? Colors.green.withValues(alpha: 0.3)
            : Colors.blue.withValues(alpha: 0.2)
        ..style = PaintingStyle.fill;
      canvas.drawRect(result.mouthRegion!, mouthPaint);

      final mouthBorderPaint = Paint()
        ..color = result.phase == DetectionPhase.pillDetected
            ? Colors.green
            : Colors.blue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawRect(result.mouthRegion!, mouthBorderPaint);

      // Label
      final label = result.phase == DetectionPhase.pillDetected
          ? 'PILL DETECTED'
          : 'Scanning...';
      final labelColor = result.phase == DetectionPhase.pillDetected
          ? Colors.green
          : Colors.blue;

      final textPainter = TextPainter(
        text: TextSpan(
          text: ' $label ',
          style: TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            backgroundColor: labelColor,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      textPainter.paint(
        canvas,
        Offset(result.mouthRegion!.left, result.mouthRegion!.top - 18),
      );
    }
  }

  void _drawLipContours(Canvas canvas, Face face) {
    final lipColor = result.phase == DetectionPhase.pillDetected
        ? Colors.greenAccent
        : result.phase == DetectionPhase.mouthOpen
            ? Colors.lightBlueAccent
            : Colors.orangeAccent;

    final lipPaint = Paint()
      ..color = lipColor
      ..style = PaintingStyle.fill;

    final contourTypes = [
      FaceContourType.upperLipTop,
      FaceContourType.upperLipBottom,
      FaceContourType.lowerLipTop,
      FaceContourType.lowerLipBottom,
    ];

    for (final type in contourTypes) {
      final contour = face.contours[type];
      if (contour == null) continue;
      for (final point in contour.points) {
        canvas.drawCircle(
          Offset(point.x.toDouble(), point.y.toDouble()),
          2.5,
          lipPaint,
        );
      }
    }
  }

  Color _phaseColor(DetectionPhase phase) {
    switch (phase) {
      case DetectionPhase.noFace:
        return Colors.red;
      case DetectionPhase.faceDetected:
        return Colors.orange;
      case DetectionPhase.mouthOpen:
        return Colors.blue;
      case DetectionPhase.pillDetected:
        return Colors.green;
    }
  }

  @override
  bool shouldRepaint(covariant PillPainter oldDelegate) {
    return oldDelegate.result != result;
  }
}