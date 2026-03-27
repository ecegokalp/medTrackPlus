import 'dart:math';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:flutter/material.dart';

class FaceDetectionResult {
  final bool faceDetected;
  final double mouthOpenRatio;
  final bool isMouthOpen;
  final Face? face;
  final FaceContour? upperLipTop;
  final FaceContour? upperLipBottom;
  final FaceContour? lowerLipTop;
  final FaceContour? lowerLipBottom;

  FaceDetectionResult({
    required this.faceDetected,
    required this.mouthOpenRatio,
    required this.isMouthOpen,
    required this.face,
    required this.upperLipTop,
    required this.upperLipBottom,
    required this.lowerLipTop,
    required this.lowerLipBottom,
  });
}

class FaceDetectionService {
  late final FaceDetector _faceDetector;

  FaceDetectionService() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.fast,
        enableContours: true,
      ),
    );
  }

  Future<FaceDetectionResult> processImage(InputImage inputImage) async {
    final faces = await _faceDetector.processImage(inputImage);

    if (faces.isEmpty) {
      return FaceDetectionResult(
        faceDetected: false,
        mouthOpenRatio: 0.0,
        isMouthOpen: false,
        face: null,
        upperLipTop: null,
        upperLipBottom: null,
        lowerLipTop: null,
        lowerLipBottom: null,
      );
    }

    final face = faces.first;

    final upperLipTop = face.contours[FaceContourType.upperLipTop];
    final upperLipBottom = face.contours[FaceContourType.upperLipBottom];
    final lowerLipTop = face.contours[FaceContourType.lowerLipTop];
    final lowerLipBottom = face.contours[FaceContourType.lowerLipBottom];

    if (upperLipTop == null ||
        upperLipBottom == null ||
        lowerLipTop == null ||
        lowerLipBottom == null) {
      return FaceDetectionResult(
        faceDetected: true,
        mouthOpenRatio: 0.0,
        isMouthOpen: false,
        face: face,
        upperLipTop: upperLipTop,
        upperLipBottom: upperLipBottom,
        lowerLipTop: lowerLipTop,
        lowerLipBottom: lowerLipBottom,
      );
    }

    final upperLipCenter = _calculateCenter([
      ...upperLipTop.points,
      ...upperLipBottom.points,
    ]);

    final lowerLipCenter = _calculateCenter([
      ...lowerLipTop.points,
      ...lowerLipBottom.points,
    ]);

    final lipCenterDistance =
    (lowerLipCenter.dy - upperLipCenter.dy).abs();

    final faceHeight = face.boundingBox.height;

    double mouthOpenRatio = 0.0;
    if (faceHeight > 0) {
      mouthOpenRatio = lipCenterDistance / faceHeight;
    }

    final isMouthOpen = mouthOpenRatio > 0.06;

    return FaceDetectionResult(
      faceDetected: true,
      mouthOpenRatio: mouthOpenRatio,
      isMouthOpen: isMouthOpen,
      face: face,
      upperLipTop: upperLipTop,
      upperLipBottom: upperLipBottom,
      lowerLipTop: lowerLipTop,
      lowerLipBottom: lowerLipBottom,
    );
  }

  Offset _calculateCenter(List<Point<int>> points) {
    if (points.isEmpty) return const Offset(0, 0);

    double sumX = 0;
    double sumY = 0;

    for (final point in points) {
      sumX += point.x.toDouble();
      sumY += point.y.toDouble();
    }

    return Offset(
      sumX / points.length,
      sumY / points.length,
    );
  }

  Future<void> dispose() async {
    await _faceDetector.close();
  }
}