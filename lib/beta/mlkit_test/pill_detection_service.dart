import 'dart:math';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

enum DetectionPhase {
  noFace,
  faceDetected,
  mouthOpen,
  pillDetected,
}

class PillOnTongueResult {
  final DetectionPhase phase;
  final Face? face;
  final double mouthOpenRatio;
  final Rect? mouthRegion;
  final double pillConfidence;
  final int whitePixelCount;
  final int totalMouthPixels;
  final String guidance;
  final DateTime timestamp;

  PillOnTongueResult({
    required this.phase,
    this.face,
    required this.mouthOpenRatio,
    this.mouthRegion,
    required this.pillConfidence,
    this.whitePixelCount = 0,
    this.totalMouthPixels = 0,
    required this.guidance,
    required this.timestamp,
  });

  factory PillOnTongueResult.empty() => PillOnTongueResult(
        phase: DetectionPhase.noFace,
        mouthOpenRatio: 0.0,
        pillConfidence: 0.0,
        guidance: 'Yüzünüzü kameraya gösterin',
        timestamp: DateTime.now(),
      );
}

class PillOnTongueService {
  late final FaceDetector _faceDetector;

  // Mouth open threshold (ratio of lip distance / face height)
  static const double _mouthOpenThreshold = 0.08;

  // Pill detection: minimum white-ish pixel ratio in mouth region
  static const double _pillPixelThreshold = 0.05; // 5% of mouth area
  static const double _pillConfidenceThreshold = 0.4;

  // NV21 Y channel thresholds for "white/light" pill pixels
  // Pill on tongue: bright area (Y > threshold) against dark/pink mouth
  static const int _brightnessThreshold = 160;

  // Stability
  int _consecutivePillFrames = 0;
  static const int _requiredStableFrames = 5;

  PillOnTongueService() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.fast,
        enableContours: true,
      ),
    );
  }

  Future<PillOnTongueResult> processFrame(
    CameraImage image,
    InputImage inputImage,
  ) async {
    // Step 1: Detect face
    final faces = await _faceDetector.processImage(inputImage);

    if (faces.isEmpty) {
      _consecutivePillFrames = 0;
      return PillOnTongueResult(
        phase: DetectionPhase.noFace,
        mouthOpenRatio: 0.0,
        pillConfidence: 0.0,
        guidance: 'Yüzünüzü kameraya gösterin',
        timestamp: DateTime.now(),
      );
    }

    final face = faces.first;

    // Step 2: Check mouth open
    final mouthOpenRatio = _calculateMouthOpenRatio(face);

    if (mouthOpenRatio < _mouthOpenThreshold) {
      _consecutivePillFrames = 0;
      return PillOnTongueResult(
        phase: DetectionPhase.faceDetected,
        face: face,
        mouthOpenRatio: mouthOpenRatio,
        pillConfidence: 0.0,
        guidance: 'Ağzınızı açın ve hapı dilinizin üstüne koyun',
        timestamp: DateTime.now(),
      );
    }

    // Step 3: Mouth is open — analyze mouth region for pill
    final mouthRect = _getMouthRegion(face);
    if (mouthRect == null) {
      return PillOnTongueResult(
        phase: DetectionPhase.mouthOpen,
        face: face,
        mouthOpenRatio: mouthOpenRatio,
        pillConfidence: 0.0,
        guidance: 'Ağzınız açık — hapı dilinize koyun',
        timestamp: DateTime.now(),
      );
    }

    // Analyze NV21 pixels in mouth region
    final pillAnalysis = _analyzeMouthRegion(
      image,
      mouthRect,
      inputImage.metadata?.rotation,
    );

    if (pillAnalysis.confidence >= _pillConfidenceThreshold) {
      _consecutivePillFrames++;
    } else {
      _consecutivePillFrames = max(0, _consecutivePillFrames - 1);
    }

    final isStable = _consecutivePillFrames >= _requiredStableFrames;

    if (isStable) {
      return PillOnTongueResult(
        phase: DetectionPhase.pillDetected,
        face: face,
        mouthOpenRatio: mouthOpenRatio,
        mouthRegion: mouthRect,
        pillConfidence: pillAnalysis.confidence,
        whitePixelCount: pillAnalysis.whitePixels,
        totalMouthPixels: pillAnalysis.totalPixels,
        guidance: 'Hap algılandı! ✓',
        timestamp: DateTime.now(),
      );
    }

    return PillOnTongueResult(
      phase: DetectionPhase.mouthOpen,
      face: face,
      mouthOpenRatio: mouthOpenRatio,
      mouthRegion: mouthRect,
      pillConfidence: pillAnalysis.confidence,
      whitePixelCount: pillAnalysis.whitePixels,
      totalMouthPixels: pillAnalysis.totalPixels,
      guidance: _consecutivePillFrames > 0
          ? 'Hap algılanıyor... Sabit tutun ($_consecutivePillFrames/$_requiredStableFrames)'
          : 'Ağzınız açık — hapı dilinize koyun',
      timestamp: DateTime.now(),
    );
  }

  double _calculateMouthOpenRatio(Face face) {
    final upperLipBottom = face.contours[FaceContourType.upperLipBottom];
    final lowerLipTop = face.contours[FaceContourType.lowerLipTop];

    if (upperLipBottom == null || lowerLipTop == null) return 0.0;
    if (upperLipBottom.points.isEmpty || lowerLipTop.points.isEmpty) return 0.0;

    // Calculate vertical distance between inner lips (mouth gap)
    final upperCenter = _centerOf(upperLipBottom.points);
    final lowerCenter = _centerOf(lowerLipTop.points);
    final lipGap = (lowerCenter.dy - upperCenter.dy).abs();

    final faceHeight = face.boundingBox.height;
    if (faceHeight <= 0) return 0.0;

    return lipGap / faceHeight;
  }

  Offset _centerOf(List<Point<int>> points) {
    if (points.isEmpty) return Offset.zero;
    double sx = 0, sy = 0;
    for (final p in points) {
      sx += p.x;
      sy += p.y;
    }
    return Offset(sx / points.length, sy / points.length);
  }

  Rect? _getMouthRegion(Face face) {
    final upperLipTop = face.contours[FaceContourType.upperLipTop];
    final lowerLipBottom = face.contours[FaceContourType.lowerLipBottom];

    if (upperLipTop == null || lowerLipBottom == null) return null;
    if (upperLipTop.points.isEmpty || lowerLipBottom.points.isEmpty) return null;

    // Build bounding rect from all lip contour points
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;

    for (final p in [...upperLipTop.points, ...lowerLipBottom.points]) {
      minX = min(minX, p.x.toDouble());
      minY = min(minY, p.y.toDouble());
      maxX = max(maxX, p.x.toDouble());
      maxY = max(maxY, p.y.toDouble());
    }

    // Shrink slightly to focus on inner mouth
    final w = maxX - minX;
    final h = maxY - minY;
    final insetX = w * 0.15;
    final insetY = h * 0.1;

    return Rect.fromLTRB(
      minX + insetX,
      minY + insetY,
      maxX - insetX,
      maxY - insetY,
    );
  }

  _PillPixelAnalysis _analyzeMouthRegion(
    CameraImage image,
    Rect mouthRect,
    InputImageRotation? rotation,
  ) {
    // NV21: first plane is Y (brightness), second plane is VU (interleaved)
    if (image.planes.isEmpty) {
      return _PillPixelAnalysis(0, 0, 0.0);
    }

    final yPlane = image.planes.first.bytes;
    final imgW = image.width;
    final imgH = image.height;
    final bytesPerRow = image.planes.first.bytesPerRow;

    // Clamp mouth rect to image bounds
    final left = mouthRect.left.toInt().clamp(0, imgW - 1);
    final top = mouthRect.top.toInt().clamp(0, imgH - 1);
    final right = mouthRect.right.toInt().clamp(0, imgW - 1);
    final bottom = mouthRect.bottom.toInt().clamp(0, imgH - 1);

    if (right <= left || bottom <= top) {
      return _PillPixelAnalysis(0, 0, 0.0);
    }

    int whitePixels = 0;
    int totalPixels = 0;

    // Sample every 2nd pixel for performance
    for (int y = top; y < bottom; y += 2) {
      for (int x = left; x < right; x += 2) {
        final idx = y * bytesPerRow + x;
        if (idx >= 0 && idx < yPlane.length) {
          totalPixels++;
          final brightness = yPlane[idx];
          if (brightness >= _brightnessThreshold) {
            whitePixels++;
          }
        }
      }
    }

    if (totalPixels == 0) {
      return _PillPixelAnalysis(0, 0, 0.0);
    }

    final ratio = whitePixels / totalPixels;

    // Confidence: higher when ratio is in sweet spot (5-40%)
    // Too low = no pill, too high = probably teeth or overexposure
    double confidence;
    if (ratio >= _pillPixelThreshold && ratio <= 0.45) {
      // Normalize to 0-1 range within sweet spot
      confidence = ((ratio - _pillPixelThreshold) / (0.30 - _pillPixelThreshold))
          .clamp(0.0, 1.0);
    } else if (ratio > 0.45) {
      // Likely teeth or light — reduce confidence
      confidence = 0.2;
    } else {
      confidence = 0.0;
    }

    return _PillPixelAnalysis(whitePixels, totalPixels, confidence);
  }

  Future<void> dispose() async {
    await _faceDetector.close();
  }
}

class _PillPixelAnalysis {
  final int whitePixels;
  final int totalPixels;
  final double confidence;
  _PillPixelAnalysis(this.whitePixels, this.totalPixels, this.confidence);
}