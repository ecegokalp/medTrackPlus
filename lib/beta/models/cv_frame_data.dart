import 'package:flutter/material.dart';
import 'package:medTrackPlus/beta/mlkit_test/pill_detection_service.dart';

/// Raw output of the CV pipeline for a single camera frame.
/// Produced by CVProcessor and consumed by AccuracyScoringEngine.
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

  final DateTime timestamp;

  /// Current verification-flow phase (workflow state, not just per-frame).
  final DetectionPhase phase;

  /// Human-readable guidance string for the user (Turkish).
  final String guidance;

  /// Smoothed pill region (rolling mean over recent frames). Null until
  /// the tracker has observations.
  final Rect? smoothedPillRegion;

  /// Last observed pill region — persists across frames where the pill
  /// momentarily disappears.
  final Rect? lastSeenPillRegion;

  /// End-to-end CV processing time in milliseconds for this frame.
  /// Zero for cached frames (skipped by the throttler).
  final double latencyMs;

  /// True when the processor returned a cached result because the throttler
  /// decided to skip this frame.
  final bool fromCache;

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
    required this.timestamp,
    this.phase = DetectionPhase.noFace,
    this.guidance = '',
    this.smoothedPillRegion,
    this.lastSeenPillRegion,
    this.latencyMs = 0.0,
    this.fromCache = false,
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

  /// Returns a copy of this frame marked as cached, with a refreshed
  /// timestamp and zero latency. Used when the throttler skips a frame so
  /// consumers still receive a complete CVFrameData.
  CVFrameData asCached() => CVFrameData(
        pillDetected: pillDetected,
        pillConfidence: pillConfidence,
        pillBoundingBox: pillBoundingBox,
        faceDetected: faceDetected,
        lipContour: lipContour,
        mouthOpenRatio: mouthOpenRatio,
        faceBoundingBox: faceBoundingBox,
        headYaw: headYaw,
        headPitch: headPitch,
        headRoll: headRoll,
        isFaceFrontal: isFaceFrontal,
        timestamp: DateTime.now(),
        phase: phase,
        guidance: guidance,
        smoothedPillRegion: smoothedPillRegion,
        lastSeenPillRegion: lastSeenPillRegion,
        latencyMs: 0.0,
        fromCache: true,
      );
}