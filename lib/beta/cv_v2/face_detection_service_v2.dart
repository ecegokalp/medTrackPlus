import 'dart:math';
import 'dart:ui';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'package:medTrackPlus/beta/cv_v2/cv_v2_config.dart';

/// Mouth geometry extracted from inner-lip contours, with pose correction.
class MouthGeometryV2 {
  /// Median perpendicular inner-lip gap in pixels (roll-compensated).
  final double gapPx;

  /// Mouth-corner-to-corner width in pixels.
  final double widthPx;

  /// gap / faceBoxHeight — comparable with the V1 ratio (and CVFrameData).
  final double rawRatio;

  /// gap / mouthWidth — stable under face-box jitter.
  final double widthRatio;

  /// Pose-corrected widthRatio: gap shrinks with pitch (cos), width shrinks
  /// with yaw (cos) — correcting both keeps the ratio comparable across
  /// moderate head movement.
  final double correctedRatio;

  /// Tight inner-mouth rect (upright image coords) built from the INNER lip
  /// contours — excludes the lips themselves, unlike the V1 outer-lip box.
  final Rect innerMouthRect;

  final int contourPointCount;

  const MouthGeometryV2({
    required this.gapPx,
    required this.widthPx,
    required this.rawRatio,
    required this.widthRatio,
    required this.correctedRatio,
    required this.innerMouthRect,
    required this.contourPointCount,
  });
}

class FaceV2Result {
  final Face? face;
  final int faceCount;
  final double? yaw;
  final double? pitch;
  final double? roll;
  final MouthGeometryV2? mouth;

  const FaceV2Result({
    this.face,
    this.faceCount = 0,
    this.yaw,
    this.pitch,
    this.roll,
    this.mouth,
  });

  bool get faceDetected => face != null;
}

/// V2 face detection.
///
/// Improvements over V1:
///  • `enableTracking` keeps a stable face identity across frames → less
///    contour jitter from detector re-acquisition.
///  • LARGEST face is selected instead of `faces.first` (first is arbitrary;
///    the patient is the closest/biggest face — a poster or a relative in
///    the background no longer hijacks detection).
///  • `minFaceSize 0.15` skips tiny background faces → faster + cleaner.
///  • Roll-compensated, pose-corrected mouth ratio measured perpendicular
///    to the mouth axis (V1 used raw vertical pixel gaps, which inflate
///    when the head tilts).
class FaceDetectionServiceV2 {
  final CvV2Config config;
  late final FaceDetector _detector;

  FaceDetectionServiceV2(this.config) {
    _detector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.fast,
        enableContours: true,
        enableClassification: true,
        enableLandmarks: true,
        enableTracking: true,
        minFaceSize: 0.15,
      ),
    );
  }

  Future<FaceV2Result> processImage(InputImage inputImage) async {
    final faces = await _detector.processImage(inputImage);
    if (faces.isEmpty) return const FaceV2Result();

    // Largest face = the patient.
    Face best = faces.first;
    double bestArea = _area(best);
    for (final f in faces.skip(1)) {
      final a = _area(f);
      if (a > bestArea) {
        best = f;
        bestArea = a;
      }
    }

    return FaceV2Result(
      face: best,
      faceCount: faces.length,
      yaw: best.headEulerAngleY,
      pitch: best.headEulerAngleX,
      roll: best.headEulerAngleZ,
      mouth: _mouthGeometry(best),
    );
  }

  double _area(Face f) => f.boundingBox.width * f.boundingBox.height;

  MouthGeometryV2? _mouthGeometry(Face face) {
    final upper = face.contours[FaceContourType.upperLipBottom]?.points;
    final lower = face.contours[FaceContourType.lowerLipTop]?.points;
    if (upper == null || lower == null || upper.isEmpty || lower.isEmpty) {
      return null;
    }
    final faceHeight = face.boundingBox.height;
    if (faceHeight <= 0) return null;

    final all = [...upper, ...lower];
    // Mouth axis: leftmost → rightmost point of the inner contours.
    Point<int> leftPt = all.first, rightPt = all.first;
    for (final p in all) {
      if (p.x < leftPt.x) leftPt = p;
      if (p.x > rightPt.x) rightPt = p;
    }
    final axX = (rightPt.x - leftPt.x).toDouble();
    final axY = (rightPt.y - leftPt.y).toDouble();
    final widthPx = sqrt(axX * axX + axY * axY);
    if (widthPx < 4) return null;
    // Unit normal to the mouth axis (roll compensation).
    final nx = -axY / widthPx;
    final ny = axX / widthPx;

    final upperSorted = List<Point<int>>.from(upper)
      ..sort((a, b) => a.x.compareTo(b.x));
    final lowerSorted = List<Point<int>>.from(lower)
      ..sort((a, b) => a.x.compareTo(b.x));
    final sampleCount = min(upperSorted.length, lowerSorted.length);
    if (sampleCount == 0) return null;

    final gaps = <double>[];
    for (int i = 0; i < sampleCount; i++) {
      final uIdx =
          (i * (upperSorted.length - 1)) ~/ max(1, sampleCount - 1);
      final lIdx =
          (i * (lowerSorted.length - 1)) ~/ max(1, sampleCount - 1);
      final dx = (lowerSorted[lIdx].x - upperSorted[uIdx].x).toDouble();
      final dy = (lowerSorted[lIdx].y - upperSorted[uIdx].y).toDouble();
      // Project the upper→lower vector onto the mouth normal: this is the
      // true opening regardless of head roll.
      gaps.add((dx * nx + dy * ny).abs());
    }
    gaps.sort();
    final medianGap = gaps[gaps.length ~/ 2];

    final rawRatio = medianGap / faceHeight;
    final widthRatio = medianGap / widthPx;

    // Pose correction (clamped so extreme angles can't explode the ratio).
    final yawRad = (face.headEulerAngleY ?? 0) * pi / 180.0;
    final pitchRad = (face.headEulerAngleX ?? 0) * pi / 180.0;
    final cosYaw = max(0.5, cos(yawRad));
    final cosPitch = max(0.5, cos(pitchRad));
    final correctedRatio = (medianGap / cosPitch) / (widthPx / cosYaw);

    // Inner-mouth rect with a small inset.
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final p in all) {
      minX = min(minX, p.x.toDouble());
      minY = min(minY, p.y.toDouble());
      maxX = max(maxX, p.x.toDouble());
      maxY = max(maxY, p.y.toDouble());
    }
    final w = maxX - minX, h = maxY - minY;
    final rect = Rect.fromLTRB(
      minX + w * 0.08,
      minY + h * 0.06,
      maxX - w * 0.08,
      maxY - h * 0.06,
    );

    return MouthGeometryV2(
      gapPx: medianGap,
      widthPx: widthPx,
      rawRatio: rawRatio,
      widthRatio: widthRatio,
      correctedRatio: correctedRatio,
      innerMouthRect: rect,
      contourPointCount: all.length,
    );
  }

  Future<void> dispose() => _detector.close();
}
