import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class FacePainter extends CustomPainter {
  final List<Face> faces;

  FacePainter(this.faces);

  @override
  void paint(Canvas canvas, Size size) {
    final boxPaint = Paint()
      ..color = Colors.green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    final normalPointPaint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.fill;

    final lipPointPaint = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.fill;

    for (final face in faces) {
      final rect = face.boundingBox;

      canvas.drawRect(
        Rect.fromLTRB(
          rect.left,
          rect.top,
          rect.right,
          rect.bottom,
        ),
        boxPaint,
      );

      face.contours.forEach((contourType, contour) {
        if (contour == null) return;

        final isLipContour =
            contourType == FaceContourType.upperLipTop ||
                contourType == FaceContourType.upperLipBottom ||
                contourType == FaceContourType.lowerLipTop ||
                contourType == FaceContourType.lowerLipBottom;

        final paintToUse = isLipContour ? lipPointPaint : normalPointPaint;

        for (final point in contour.points) {
          canvas.drawCircle(
            Offset(point.x.toDouble(), point.y.toDouble()),
            2.0,
            paintToUse,
          );
        }
      });
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}