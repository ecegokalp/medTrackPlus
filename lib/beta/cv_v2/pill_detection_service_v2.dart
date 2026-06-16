import 'dart:math';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';

import 'package:medTrackPlus/beta/cv_v2/cv_v2_config.dart';
import 'package:medTrackPlus/beta/cv_v2/cv_v2_metrics.dart';
import 'package:medTrackPlus/beta/cv_v2/face_detection_service_v2.dart';
import 'package:medTrackPlus/beta/cv_v2/mouth_pixel_analyzer_v2.dart';
import 'package:medTrackPlus/beta/mlkit_test/pill_detection_service.dart'
    show DetectionPhase;

enum _StageV2 {
  awaitingPill,
  awaitingDrink,
  awaitingReopen,
  verifyingSwallow,
  done,
}

/// V2 pill-on-tongue verification state machine.
///
/// Same phases/flow as the production PillOnTongueService, but with:
///  • rotation-correct, adaptive, chroma-aware pixel analysis
///    (MouthPixelAnalyzerV2) and blob-based pill localisation;
///  • EMA-smoothed confidences and mouth ratios with open/close hysteresis;
///  • pose-corrected mouth-open ratio (yaw/pitch/roll compensated);
///  • centroid-jump outlier rejection while building pill stability;
///  • chroma-filtered "empty mouth" check during swallow verification
///    (teeth no longer read as "pill still in mouth");
///  • glare tolerance: a single pill sighting during verification doesn't
///    fail the swallow (configurable);
///  • full CvV2Metrics output for the Dev CV Lab HUD.
class PillDetectionServiceV2 {
  final CvV2Config config;
  late final MouthPixelAnalyzerV2 _analyzer;
  late final ImageLabeler _imageLabeler;

  PillDetectionServiceV2(this.config) {
    _analyzer = MouthPixelAnalyzerV2(config);
    _imageLabeler =
        ImageLabeler(options: ImageLabelerOptions(confidenceThreshold: 0.3));
  }

  /// Temporal open-mouth baseline — teeth are in it, the pill never is.
  final MouthBaseline _baseline = MouthBaseline();

  static const List<String> _drinkLabelSubstrings = [
    'drink', 'bottle', 'cup', 'mug', 'glass', 'water',
    'beverage', 'liquid', 'juice', 'tableware', 'drinkware',
    'tumbler', 'jar', 'pitcher', 'flask', 'thermos', 'kettle',
  ];

  // ── State ────────────────────────────────────────────────────────────
  _StageV2 _stage = _StageV2.awaitingPill;
  DetectionPhase _lastDonePhase = DetectionPhase.swallowConfirmed;
  String _lastDoneGuidance = '';

  bool _mouthOpenState = false; // hysteresis latch
  double _ratioEma = 0.0;
  bool _ratioEmaInit = false;
  double _confEma = 0.0;

  int _stableFrames = 0;
  int _openMouthAnalyzedFrames = 0;
  Offset? _lastBlobCentroid;
  Rect? _lastSeenPillRegion;

  DateTime? _pillConfirmedAt;
  DateTime _lastLabelingRun = DateTime.fromMillisecondsSinceEpoch(0);
  String? _detectedDrinkLabel;
  bool _isLabeling = false;
  int _drinkLabelHits = 0;

  int _swallowVerifyCounter = 0;
  int _pillSeenInVerify = 0;

  bool get isTracking => _stableFrames > 0 && _stage == _StageV2.awaitingPill;

  void reset() {
    _stage = _StageV2.awaitingPill;
    _mouthOpenState = false;
    _ratioEma = 0.0;
    _ratioEmaInit = false;
    _confEma = 0.0;
    _stableFrames = 0;
    _openMouthAnalyzedFrames = 0;
    _lastBlobCentroid = null;
    _lastSeenPillRegion = null;
    _pillConfirmedAt = null;
    _detectedDrinkLabel = null;
    _drinkLabelHits = 0;
    _swallowVerifyCounter = 0;
    _pillSeenInVerify = 0;
    _baseline.reset();
  }

  Future<PillResultV2> processFrameWithFace(
    CameraImage image,
    InputImage inputImage,
    FaceV2Result faceResult,
  ) async {
    final now = DateTime.now();
    final face = faceResult.face;

    if (face == null) {
      _stableFrames = 0;
      return _emit(
        phase: DetectionPhase.noFace,
        face: null,
        guidance: 'guide_show_face'.tr(),
        faceResult: faceResult,
        now: now,
      );
    }

    final yaw = faceResult.yaw;
    final pitch = faceResult.pitch;
    final yawBad = yaw != null && yaw.abs() > config.maxYawDeg;
    final pitchBad = pitch != null && pitch.abs() > config.maxPitchDeg;
    if (yawBad || pitchBad) {
      _stableFrames = max(0, _stableFrames - 1);
      return _emit(
        phase: DetectionPhase.faceDetected,
        face: face,
        guidance: 'guide_face_camera_directly'.tr(),
        faceResult: faceResult,
        now: now,
      );
    }

    // ── Mouth ratio: EMA + hysteresis ──────────────────────────────────
    final mouth = faceResult.mouth;
    final corrected = mouth?.correctedRatio ?? 0.0;
    if (!_ratioEmaInit) {
      _ratioEma = corrected;
      _ratioEmaInit = true;
    } else {
      _ratioEma = config.ratioEmaAlpha * corrected +
          (1 - config.ratioEmaAlpha) * _ratioEma;
    }
    if (_mouthOpenState) {
      if (_ratioEma < config.mouthOpenExit) _mouthOpenState = false;
    } else {
      if (_ratioEma >= config.mouthOpenEnter) _mouthOpenState = true;
    }
    final mouthRect = (_mouthOpenState && mouth != null)
        ? mouth.innerMouthRect
        : null;

    // ── Pixel analysis (only when the mouth is open) ───────────────────
    MouthPixelAnalysisV2 analysis = const MouthPixelAnalysisV2();
    if (mouthRect != null) {
      final rotation =
          inputImage.metadata?.rotation ?? InputImageRotation.rotation0deg;
      analysis = _analyzer.analyze(
        image,
        mouthRect,
        rotation,
        baseline: _baseline,
        // Baseline yalnızca hap-bekleme aşamasında ve hap şüphesi yokken
        // güncellenir (analyzer içte confidence < 0.30 koşulunu da uygular)
        // → hap baseline'ı asla zehirleyemez.
        allowBaselineUpdate: _stage == _StageV2.awaitingPill,
      );
    }
    _confEma = config.confidenceEmaAlpha * analysis.confidence +
        (1 - config.confidenceEmaAlpha) * _confEma;
    final pillDetected = _confEma >= config.pillConfidenceThreshold &&
        analysis.confidence > 0;

    switch (_stage) {
      case _StageV2.awaitingPill:
        return _handleAwaitingPill(
            face, faceResult, mouthRect, analysis, pillDetected, now);
      case _StageV2.awaitingDrink:
        return _handleAwaitingDrink(
            face, faceResult, mouthRect, analysis, inputImage, now);
      case _StageV2.awaitingReopen:
        return _handleAwaitingReopen(face, faceResult, mouthRect, analysis, now);
      case _StageV2.verifyingSwallow:
        return _handleVerifyingSwallow(
            face, faceResult, mouthRect, analysis, pillDetected, now);
      case _StageV2.done:
        return _emit(
          phase: _lastDonePhase,
          face: face,
          guidance: _lastDoneGuidance,
          faceResult: faceResult,
          analysis: analysis,
          now: now,
        );
    }
  }

  // ── Stage handlers ───────────────────────────────────────────────────

  PillResultV2 _handleAwaitingPill(
    Face face,
    FaceV2Result faceResult,
    Rect? mouthRect,
    MouthPixelAnalysisV2 analysis,
    bool pillDetected,
    DateTime now,
  ) {
    if (mouthRect == null) {
      _stableFrames = max(0, _stableFrames - 1);
      return _emit(
        phase: DetectionPhase.faceDetected,
        face: face,
        guidance: 'guide_step1_open_mouth'.tr(),
        faceResult: faceResult,
        now: now,
      );
    }

    _openMouthAnalyzedFrames++;

    // ── Baseline collection gate ─────────────────────────────────────
    // While the open-mouth baseline (teeth map) is still forming, do NOT
    // let any blob accumulate stable frames — without novelty data teeth
    // could win the very first frames. Capped at 15 analyzed frames so a
    // pill already in the mouth can't deadlock the flow (baseline simply
    // stays unready and detection proceeds with neutral novelty).
    final baselineReady =
        analysis.baselineFrames >= MouthBaseline.minFrames;
    if (!baselineReady && _openMouthAnalyzedFrames < 15) {
      return _emit(
        phase: DetectionPhase.mouthOpen,
        face: face,
        guidance: 'guide_keep_mouth_open'.tr(),
        faceResult: faceResult,
        analysis: analysis,
        mouthRegion: mouthRect,
        now: now,
      );
    }

    if (pillDetected) {
      // Outlier guard: reject impossible blob jumps (reflection flicker).
      final c = analysis.blobCentroid;
      final mouthWidth = mouthRect.width;
      bool accept = true;
      if (c != null && _lastBlobCentroid != null && mouthWidth > 0) {
        final jump = (c - _lastBlobCentroid!).distance;
        if (jump > config.maxCentroidJumpFraction * mouthWidth) {
          accept = false;
        }
      }
      if (accept) {
        _stableFrames++;
        _lastSeenPillRegion = analysis.blobRect ?? mouthRect;
      }
      if (c != null) _lastBlobCentroid = c;
    } else {
      _stableFrames = max(0, _stableFrames - 1);
    }

    if (_stableFrames >= config.requiredStableFrames) {
      _stage = _StageV2.awaitingDrink;
      _pillConfirmedAt = now;
      return _emit(
        phase: DetectionPhase.pillOnTongue,
        face: face,
        guidance: 'guide_pill_detected_close_drink'.tr(),
        faceResult: faceResult,
        analysis: analysis,
        mouthRegion: mouthRect,
        now: now,
      );
    }

    return _emit(
      phase: DetectionPhase.mouthOpen,
      face: face,
      guidance: _stableFrames > 0
          ? 'guide_pill_detecting_hold'.tr(args: [
              _stableFrames.toString(),
              config.requiredStableFrames.toString(),
            ])
          : 'guide_step2_pill_on_tongue'.tr(),
      faceResult: faceResult,
      analysis: analysis,
      mouthRegion: mouthRect,
      now: now,
    );
  }

  PillResultV2 _handleAwaitingDrink(
    Face face,
    FaceV2Result faceResult,
    Rect? mouthRect,
    MouthPixelAnalysisV2 analysis,
    InputImage inputImage,
    DateTime now,
  ) {
    final elapsed = now.difference(_pillConfirmedAt ?? now);

    if (elapsed > config.drinkTimeoutAfter) {
      _stage = _StageV2.done;
      _lastDonePhase = DetectionPhase.timeoutExpired;
      _lastDoneGuidance = 'guide_timeout_cancelled'.tr();
      return _emit(
        phase: DetectionPhase.timeoutExpired,
        face: face,
        guidance: _lastDoneGuidance,
        faceResult: faceResult,
        now: now,
      );
    }

    if (!_isLabeling &&
        now.difference(_lastLabelingRun) >= config.labelingInterval) {
      _lastLabelingRun = now;
      _isLabeling = true;
      _imageLabeler.processImage(inputImage).then((labels) {
        if (kDebugMode && labels.isNotEmpty) {
          final top = labels
              .take(5)
              .map((l) =>
                  '${l.label}(${(l.confidence * 100).toStringAsFixed(0)})')
              .join(', ');
          debugPrint('[PillV2] labels: $top');
        }
        bool frameHasDrink = false;
        for (final l in labels) {
          if (l.confidence < config.drinkConfidenceThreshold) continue;
          final lower = l.label.toLowerCase();
          if (_drinkLabelSubstrings.any((s) => lower.contains(s))) {
            _detectedDrinkLabel = l.label;
            frameHasDrink = true;
            break;
          }
        }
        if (frameHasDrink) {
          _drinkLabelHits++;
          if (_drinkLabelHits >= config.requiredDrinkHits &&
              _stage == _StageV2.awaitingDrink) {
            _stage = _StageV2.awaitingReopen;
          }
        } else {
          _drinkLabelHits = max(0, _drinkLabelHits - 1);
        }
      }).whenComplete(() => _isLabeling = false);
    }

    final String guidance;
    if (_drinkLabelHits > 0) {
      guidance = 'guide_glass_detecting_hold'.tr(args: [
        _drinkLabelHits.toString(),
        config.requiredDrinkHits.toString(),
      ]);
    } else if (elapsed > config.drinkWarningAfter) {
      guidance = 'guide_please_drink_remaining'.tr(args: [
        (config.drinkTimeoutAfter - elapsed).inSeconds.toString()
      ]);
    } else if (_mouthOpenState) {
      guidance = 'guide_step3_close_drink'.tr();
    } else {
      guidance = 'guide_step4_drink_with_glass'.tr();
    }

    return _emit(
      phase: DetectionPhase.mouthClosedWithPill,
      face: face,
      guidance: guidance,
      faceResult: faceResult,
      analysis: analysis,
      mouthRegion: mouthRect,
      now: now,
    );
  }

  PillResultV2 _handleAwaitingReopen(
    Face face,
    FaceV2Result faceResult,
    Rect? mouthRect,
    MouthPixelAnalysisV2 analysis,
    DateTime now,
  ) {
    if (_mouthOpenState) {
      _stage = _StageV2.verifyingSwallow;
      _swallowVerifyCounter = 0;
      _pillSeenInVerify = 0;
      return _emit(
        phase: DetectionPhase.mouthReopened,
        face: face,
        guidance: 'guide_checking_swallow'.tr(),
        faceResult: faceResult,
        analysis: analysis,
        mouthRegion: mouthRect,
        now: now,
      );
    }
    return _emit(
      phase: DetectionPhase.drinking,
      face: face,
      guidance: 'guide_drinking_detected_reopen'
          .tr(args: [_detectedDrinkLabel ?? '?']),
      faceResult: faceResult,
      now: now,
    );
  }

  PillResultV2 _handleVerifyingSwallow(
    Face face,
    FaceV2Result faceResult,
    Rect? mouthRect,
    MouthPixelAnalysisV2 analysis,
    bool pillDetected,
    DateTime now,
  ) {
    if (mouthRect == null || !_mouthOpenState) {
      return _emit(
        phase: DetectionPhase.mouthReopened,
        face: face,
        guidance: 'guide_keep_mouth_open'.tr(),
        faceResult: faceResult,
        now: now,
      );
    }

    final clearlyOpen =
        _ratioEma >= config.mouthOpenEnter * config.swallowOpenFactor;
    // Teeth-aware emptiness: blob CONFIDENCE applies position / red-surround
    // / tooth-geometry penalties, so visible teeth score low and no longer
    // read as "pill still in mouth". (The candidate-cell ratio can NOT be
    // used here — it includes teeth by design in the colour-agnostic model.)
    final clearlyEmpty =
        analysis.confidence < config.emptyMouthMaxConfidence;

    if (!clearlyOpen) {
      return _emit(
        phase: DetectionPhase.mouthReopened,
        face: face,
        guidance: 'guide_open_mouth_wider'.tr(),
        faceResult: faceResult,
        analysis: analysis,
        mouthRegion: mouthRect,
        now: now,
      );
    }

    if (!clearlyEmpty) {
      _pillSeenInVerify++;
      return _emit(
        phase: DetectionPhase.mouthReopened,
        face: face,
        guidance: 'guide_bright_object_show_tongue'.tr(),
        faceResult: faceResult,
        analysis: analysis,
        mouthRegion: mouthRect,
        now: now,
      );
    }

    _swallowVerifyCounter++;
    if (pillDetected) _pillSeenInVerify++;

    if (_swallowVerifyCounter >= config.swallowVerifyFrames) {
      if (_pillSeenInVerify > config.maxPillSeenInVerify) {
        _stage = _StageV2.awaitingReopen;
        _swallowVerifyCounter = 0;
        _pillSeenInVerify = 0;
        return _emit(
          phase: DetectionPhase.swallowFailed,
          face: face,
          guidance: 'guide_pill_still_in_mouth'.tr(),
          faceResult: faceResult,
          analysis: analysis,
          mouthRegion: mouthRect,
          now: now,
        );
      }
      _stage = _StageV2.done;
      _lastDonePhase = DetectionPhase.swallowConfirmed;
      _lastDoneGuidance = 'guide_pill_swallowed'.tr();
      return _emit(
        phase: _lastDonePhase,
        face: face,
        guidance: _lastDoneGuidance,
        faceResult: faceResult,
        analysis: analysis,
        mouthRegion: mouthRect,
        now: now,
      );
    }

    return _emit(
      phase: DetectionPhase.mouthReopened,
      face: face,
      guidance: 'guide_checking_swallow_progress'.tr(args: [
        _swallowVerifyCounter.toString(),
        config.swallowVerifyFrames.toString(),
      ]),
      faceResult: faceResult,
      analysis: analysis,
      mouthRegion: mouthRect,
      now: now,
    );
  }

  // ── Emit ─────────────────────────────────────────────────────────────

  PillResultV2 _emit({
    required DetectionPhase phase,
    required Face? face,
    required String guidance,
    required FaceV2Result faceResult,
    MouthPixelAnalysisV2 analysis = const MouthPixelAnalysisV2(),
    Rect? mouthRegion,
    required DateTime now,
  }) {
    final mouth = faceResult.mouth;
    final pillRect = analysis.blobRect ?? _lastSeenPillRegion;

    final metrics = CvV2Metrics(
      faceDetected: face != null,
      faceCount: faceResult.faceCount,
      trackingId: face?.trackingId,
      yaw: faceResult.yaw,
      pitch: faceResult.pitch,
      roll: faceResult.roll,
      yawLimit: config.maxYawDeg,
      pitchLimit: config.maxPitchDeg,
      mouthRatioRaw: mouth?.rawRatio ?? 0.0,
      mouthRatioWidth: mouth?.widthRatio ?? 0.0,
      mouthRatioCorrected: mouth?.correctedRatio ?? 0.0,
      mouthRatioSmoothed: _ratioEma,
      openEnterThreshold: config.mouthOpenEnter,
      openExitThreshold: config.mouthOpenExit,
      isMouthOpen: _mouthOpenState,
      brightRatio: analysis.brightRatio,
      pillLikeRatio: analysis.pillLikeRatio,
      adaptiveThreshold: analysis.adaptiveThreshold,
      meanLuma: analysis.meanLuma,
      stdLuma: analysis.stdLuma,
      chromaAvailable: analysis.chromaAvailable,
      blobCount: analysis.blobCount,
      blobAreaRatio: analysis.blobAreaRatio,
      blobAspect: analysis.blobAspect,
      areaScore: analysis.areaScore,
      centralityScore: analysis.centralityScore,
      positionScore: analysis.positionScore,
      compactnessScore: analysis.compactnessScore,
      colorScore: analysis.colorScore,
      surroundScore: analysis.surroundScore,
      noveltyScore: analysis.noveltyScore,
      baselineFrames: analysis.baselineFrames,
      teethPenalty: analysis.teethPenalty,
      toothLikeness: analysis.toothLikeness,
      pillConfidence: analysis.confidence,
      pillConfidenceEma: _confEma,
      stableFrames: _stableFrames,
      requiredStableFrames: config.requiredStableFrames,
      swallowCounter: _swallowVerifyCounter,
      swallowRequired: config.swallowVerifyFrames,
      pillSeenInVerifyCount: _pillSeenInVerify,
      pillToLipDistance: _pillToLipDistance(face, pillRect),
      phase: phase,
      stageName: _stage.name,
      drinkLabel: _detectedDrinkLabel,
      drinkHits: _drinkLabelHits,
      requiredDrinkHits: config.requiredDrinkHits,
    );

    return PillResultV2(
      phase: phase,
      face: face,
      guidance: guidance,
      timestamp: now,
      mouthRegion: mouthRegion,
      pillBlobRegion: analysis.blobRect,
      lastSeenPillRegion: _lastSeenPillRegion,
      metrics: metrics,
    );
  }

  double? _pillToLipDistance(Face? face, Rect? pillRegion) {
    if (face == null || pillRegion == null) return null;
    final faceHeight = face.boundingBox.height;
    if (faceHeight <= 0) return null;

    final upper = face.contours[FaceContourType.upperLipBottom]?.points;
    final lower = face.contours[FaceContourType.lowerLipTop]?.points;
    if (upper == null || lower == null || upper.isEmpty || lower.isEmpty) {
      return null;
    }

    double ux = 0, uy = 0;
    for (final p in upper) {
      ux += p.x;
      uy += p.y;
    }
    ux /= upper.length;
    uy /= upper.length;
    double lx = 0, ly = 0;
    for (final p in lower) {
      lx += p.x;
      ly += p.y;
    }
    lx /= lower.length;
    ly /= lower.length;

    final dx = pillRegion.center.dx - (ux + lx) / 2;
    final dy = pillRegion.center.dy - (uy + ly) / 2;
    return sqrt(dx * dx + dy * dy) / faceHeight;
  }

  Future<void> dispose() async {
    await _imageLabeler.close();
  }
}
