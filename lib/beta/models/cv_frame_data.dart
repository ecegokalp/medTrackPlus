import 'package:flutter/material.dart';
import 'package:medTrackPlus/beta/mlkit_test/pill_detection_service.dart';

class CVFrameData {
  final bool pillDetected;
  final double pillConfidence;

  /// Bounding box of the detected pill in image coordinates.
  final Rect pillBoundingBox;

  final bool faceDetected;

  /// Lip landmark points (combined upper + lower contour) in image coordinates.
  final List<Offset> lipContour;

  /// Ratio of mouth opening to face height. 0.0 = closed, ~0.1+ = open.
  final double mouthOpenRatio;

  /// Bounding box of the detected face in image coordinates.
  final Rect faceBoundingBox;

  /// Head pose euler angles in degrees (null when unavailable).
  final double? headYaw;
  final double? headPitch;
  final double? headRoll;

  /// Whether the face is frontal enough for reliable detection.
  final bool isFaceFrontal;

  /// Normalized pill-to-lip distance (0.0 = at lip, higher = farther).
  final double? pillToLipDistance;

  final DateTime timestamp;

  const CVFrameData({
    required this.pillDetected,
    required this.pillConfidence,
    required this.pillBoundingBox,
    required this.faceDetected,
    required this.lipContour,
    required this.mouthOpenRatio,
    required this.faceBoundingBox,
    this.headYaw,
    this.headPitch,
    this.headRoll,
    this.isFaceFrontal = true,
    this.pillToLipDistance,
    required this.timestamp,
  });

  /// Empty frame — no detections.
  factory CVFrameData.empty() => CVFrameData(
        pillDetected: false,
        pillConfidence: 0.0,
        pillBoundingBox: Rect.zero,
        faceDetected: false,
        lipContour: const [],
        mouthOpenRatio: 0.0,
        faceBoundingBox: Rect.zero,
        timestamp: DateTime.now(),
      );

  bool get isMouthOpen => mouthOpenRatio > 0.06;

  factory CVFrameData.fromPillResult(PillOnTongueResult result) {
    final face = result.face;
    return CVFrameData(
      pillDetected: result.pillConfidence >= 0.4,
      pillConfidence: result.pillConfidence,
      pillBoundingBox: result.mouthRegion ?? Rect.zero,
      faceDetected: face != null,
      lipContour: const [],
      mouthOpenRatio: result.mouthOpenRatio,
      faceBoundingBox: face?.boundingBox ?? Rect.zero,
      headYaw: face?.headEulerAngleY,
      headPitch: face?.headEulerAngleX,
      headRoll: face?.headEulerAngleZ,
      isFaceFrontal: result.isFaceFrontal,
      pillToLipDistance: result.pillToLipDistance,
      timestamp: result.timestamp,
    );
  }
}
