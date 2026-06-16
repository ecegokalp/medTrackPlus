import 'dart:ui';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:medTrackPlus/beta/mlkit_test/pill_detection_service.dart'
    show DetectionPhase;

/// Per-frame debug metrics for the V2 pipeline — everything the Dev CV Lab
/// HUD needs to display ratios, accuracies and threshold margins live.
class CvV2Metrics {
  // Face
  final bool faceDetected;
  final int faceCount;
  final int? trackingId;

  // Head pose
  final double? yaw;
  final double? pitch;
  final double? roll;
  final double yawLimit;
  final double pitchLimit;

  // Mouth ratios
  final double mouthRatioRaw; // gap / faceHeight  (legacy-comparable)
  final double mouthRatioWidth; // gap / mouthWidth
  final double mouthRatioCorrected; // pose-corrected gap / mouthWidth
  final double mouthRatioSmoothed; // EMA of corrected ratio
  final double openEnterThreshold;
  final double openExitThreshold;
  final bool isMouthOpen;

  // Pixel analysis
  final double brightRatio; // raw bright pixels / total
  final double pillLikeRatio; // pill-CANDIDATE cells (any colour) / total
  final int adaptiveThreshold;
  final double meanLuma;
  final double stdLuma;
  final bool chromaAvailable;

  // Blob scores
  final int blobCount;
  final double blobAreaRatio;
  final double blobAspect;
  final double areaScore;
  final double centralityScore;
  final double positionScore; // vertical tongue-zone prior
  final double compactnessScore;
  final double colorScore; // saturated non-red colour (NEVER teeth)
  final double surroundScore; // red (tongue) ring around blob
  final double noveltyScore; // 1=new object (pill), 0=always there (teeth)
  final int baselineFrames; // open-mouth baseline frame count
  final double teethPenalty; // combined teeth-geometry penalty (≤1)
  final double toothLikeness; // fraction of blob cells that look tooth-like

  // Pill confidence
  final double pillConfidence; // fused, this frame
  final double pillConfidenceEma; // smoothed
  final int stableFrames;
  final int requiredStableFrames;

  // Swallow verification
  final int swallowCounter;
  final int swallowRequired;
  final int pillSeenInVerifyCount;

  // Distances
  final double? pillToLipDistance;

  // Flow
  final DetectionPhase phase;
  final String stageName;
  final String? drinkLabel;
  final int drinkHits;
  final int requiredDrinkHits;

  // Performance (filled in by the processor)
  final double latencyMs;
  final double avgLatencyMs;
  final double fps;
  final int skipFactor;

  const CvV2Metrics({
    this.faceDetected = false,
    this.faceCount = 0,
    this.trackingId,
    this.yaw,
    this.pitch,
    this.roll,
    this.yawLimit = 25.0,
    this.pitchLimit = 25.0,
    this.mouthRatioRaw = 0.0,
    this.mouthRatioWidth = 0.0,
    this.mouthRatioCorrected = 0.0,
    this.mouthRatioSmoothed = 0.0,
    this.openEnterThreshold = 0.30,
    this.openExitThreshold = 0.20,
    this.isMouthOpen = false,
    this.brightRatio = 0.0,
    this.pillLikeRatio = 0.0,
    this.adaptiveThreshold = 0,
    this.meanLuma = 0.0,
    this.stdLuma = 0.0,
    this.chromaAvailable = false,
    this.blobCount = 0,
    this.blobAreaRatio = 0.0,
    this.blobAspect = 0.0,
    this.areaScore = 0.0,
    this.centralityScore = 0.0,
    this.positionScore = 0.0,
    this.compactnessScore = 0.0,
    this.colorScore = 0.0,
    this.surroundScore = 0.0,
    this.noveltyScore = 0.5,
    this.baselineFrames = 0,
    this.teethPenalty = 1.0,
    this.toothLikeness = 0.0,
    this.pillConfidence = 0.0,
    this.pillConfidenceEma = 0.0,
    this.stableFrames = 0,
    this.requiredStableFrames = 4,
    this.swallowCounter = 0,
    this.swallowRequired = 8,
    this.pillSeenInVerifyCount = 0,
    this.pillToLipDistance,
    this.phase = DetectionPhase.noFace,
    this.stageName = '',
    this.drinkLabel,
    this.drinkHits = 0,
    this.requiredDrinkHits = 3,
    this.latencyMs = 0.0,
    this.avgLatencyMs = 0.0,
    this.fps = 0.0,
    this.skipFactor = 1,
  });

  bool get yawExceeded => yaw != null && yaw!.abs() > yawLimit;
  bool get pitchExceeded => pitch != null && pitch!.abs() > pitchLimit;
  bool get yawWarning =>
      yaw != null && !yawExceeded && yaw!.abs() > yawLimit * 0.8;
  bool get pitchWarning =>
      pitch != null && !pitchExceeded && pitch!.abs() > pitchLimit * 0.8;

  CvV2Metrics withPerf({
    required double latencyMs,
    required double avgLatencyMs,
    required double fps,
    required int skipFactor,
  }) {
    return CvV2Metrics(
      faceDetected: faceDetected,
      faceCount: faceCount,
      trackingId: trackingId,
      yaw: yaw,
      pitch: pitch,
      roll: roll,
      yawLimit: yawLimit,
      pitchLimit: pitchLimit,
      mouthRatioRaw: mouthRatioRaw,
      mouthRatioWidth: mouthRatioWidth,
      mouthRatioCorrected: mouthRatioCorrected,
      mouthRatioSmoothed: mouthRatioSmoothed,
      openEnterThreshold: openEnterThreshold,
      openExitThreshold: openExitThreshold,
      isMouthOpen: isMouthOpen,
      brightRatio: brightRatio,
      pillLikeRatio: pillLikeRatio,
      adaptiveThreshold: adaptiveThreshold,
      meanLuma: meanLuma,
      stdLuma: stdLuma,
      chromaAvailable: chromaAvailable,
      blobCount: blobCount,
      blobAreaRatio: blobAreaRatio,
      blobAspect: blobAspect,
      areaScore: areaScore,
      centralityScore: centralityScore,
      positionScore: positionScore,
      compactnessScore: compactnessScore,
      colorScore: colorScore,
      surroundScore: surroundScore,
      noveltyScore: noveltyScore,
      baselineFrames: baselineFrames,
      teethPenalty: teethPenalty,
      toothLikeness: toothLikeness,
      pillConfidence: pillConfidence,
      pillConfidenceEma: pillConfidenceEma,
      stableFrames: stableFrames,
      requiredStableFrames: requiredStableFrames,
      swallowCounter: swallowCounter,
      swallowRequired: swallowRequired,
      pillSeenInVerifyCount: pillSeenInVerifyCount,
      pillToLipDistance: pillToLipDistance,
      phase: phase,
      stageName: stageName,
      drinkLabel: drinkLabel,
      drinkHits: drinkHits,
      requiredDrinkHits: requiredDrinkHits,
      latencyMs: latencyMs,
      avgLatencyMs: avgLatencyMs,
      fps: fps,
      skipFactor: skipFactor,
    );
  }
}

/// Full per-frame output of the V2 pipeline.
class PillResultV2 {
  final DetectionPhase phase;
  final Face? face;
  final String guidance;
  final DateTime timestamp;

  /// Inner-mouth rect (image/upright coordinates). Null when mouth closed.
  final Rect? mouthRegion;

  /// Tight pill blob rect (image coords) — much tighter than mouthRegion.
  final Rect? pillBlobRegion;

  /// Smoothed pill rect from the tracker.
  final Rect? smoothedPillRegion;

  /// Last place the pill was seen.
  final Rect? lastSeenPillRegion;

  final CvV2Metrics metrics;

  const PillResultV2({
    required this.phase,
    required this.face,
    required this.guidance,
    required this.timestamp,
    this.mouthRegion,
    this.pillBlobRegion,
    this.smoothedPillRegion,
    this.lastSeenPillRegion,
    required this.metrics,
  });
}
