/// Tunable configuration for the V2 (experimental) CV pipeline.
///
/// All values are MUTABLE so the Dev CV Lab screen can adjust them live via
/// sliders and observe the effect frame-by-frame. The production pipeline
/// (PillOnTongueService) is NOT affected by anything in this file.
class CvV2Config {
  // ── Head pose limits ───────────────────────────────────────────────
  /// Max |yaw| (left/right turn) in degrees before detection is paused.
  double maxYawDeg = 25.0;

  /// Max |pitch| (up/down tilt) in degrees before detection is paused.
  double maxPitchDeg = 25.0;

  /// Fraction of the limit at which the HUD shows an amber warning
  /// (e.g. 0.8 → warn at 20° when the limit is 25°).
  double angleWarnFraction = 0.8;

  // ── Mouth-open detection (hysteresis on pose-corrected ratio) ──────
  /// Pose-corrected (gap / mouthWidth) ratio to ENTER the open state.
  double mouthOpenEnter = 0.30;

  /// Ratio to EXIT the open state (must be < enter → hysteresis, kills
  /// flicker right at the threshold).
  double mouthOpenExit = 0.20;

  /// EMA smoothing factor for the mouth ratio (higher = snappier).
  double ratioEmaAlpha = 0.55;

  // ── Adaptive pill pixel analysis ───────────────────────────────────
  /// k in `threshold = mean + k * std` computed inside the mouth region.
  double brightnessSigmaK = 1.0;

  /// Absolute clamps for the adaptive brightness threshold.
  int brightnessFloor = 135;
  int brightnessCeil = 205;

  /// Max chroma distance from neutral (sqrt((U-128)²+(V-128)²)) for a
  /// bright pixel to count as "pill-like" (white pills are chroma-neutral;
  /// tongue/lips are strongly red, teeth slightly yellow). Tightened to 24
  /// so slightly-yellow teeth fall outside the pill-like band more often.
  double chromaNeutralMax = 24.0;

  /// Grid sampling step in pixels (2 = every other pixel).
  int sampleStep = 2;

  // ── Blob (connected component) scoring ─────────────────────────────
  double minPillAreaRatio = 0.015; // below → noise
  double idealMinAreaRatio = 0.05; // full confidence band start
  double idealMaxAreaRatio = 0.28; // full confidence band end
  double maxPillAreaRatio = 0.50; // above → glare / overexposure

  // ── Pill confirmation ──────────────────────────────────────────────
  /// Final fused confidence needed to count a frame as "pill present".
  double pillConfidenceThreshold = 0.45;

  /// EMA factor for confidence smoothing.
  double confidenceEmaAlpha = 0.5;

  /// Consecutive pill frames required to confirm pill-on-tongue.
  int requiredStableFrames = 4;

  /// Reject tracker updates whose centroid jumps more than this fraction
  /// of the mouth width between consecutive detections (outlier guard).
  double maxCentroidJumpFraction = 0.6;

  // ── Swallow verification ───────────────────────────────────────────
  /// Frames of clearly-open + clearly-empty mouth required.
  int swallowVerifyFrames = 8;

  /// Mouth must be at least `mouthOpenEnter * swallowOpenFactor` during
  /// swallow verification (wide open, not borderline).
  double swallowOpenFactor = 1.15;

  /// Max blob CONFIDENCE for the mouth to count as "empty" during swallow
  /// verification. This is the primary emptiness signal: it is teeth-aware
  /// (position/surround/geometry penalties), so visible teeth no longer
  /// read as "pill still in mouth".
  double emptyMouthMaxConfidence = 0.40;

  /// Pill sightings during verification tolerated before failing
  /// (1 = a single glare frame won't fail the whole swallow).
  int maxPillSeenInVerify = 1;

  // ── Drink detection (image labeling) ───────────────────────────────
  double drinkConfidenceThreshold = 0.40;
  int requiredDrinkHits = 3;
  Duration labelingInterval = const Duration(milliseconds: 400);
  Duration drinkWarningAfter = const Duration(seconds: 30);
  Duration drinkTimeoutAfter = const Duration(seconds: 60);

  // ── Throttling / performance ───────────────────────────────────────
  /// Latency budget; when the rolling average exceeds this, the adaptive
  /// throttler increases skip factors by one step.
  double latencyBudgetMs = 90.0;

  /// Restore defaults (used by the lab screen's reset button).
  void resetToDefaults() {
    final d = CvV2Config();
    maxYawDeg = d.maxYawDeg;
    maxPitchDeg = d.maxPitchDeg;
    angleWarnFraction = d.angleWarnFraction;
    mouthOpenEnter = d.mouthOpenEnter;
    mouthOpenExit = d.mouthOpenExit;
    ratioEmaAlpha = d.ratioEmaAlpha;
    brightnessSigmaK = d.brightnessSigmaK;
    brightnessFloor = d.brightnessFloor;
    brightnessCeil = d.brightnessCeil;
    chromaNeutralMax = d.chromaNeutralMax;
    sampleStep = d.sampleStep;
    minPillAreaRatio = d.minPillAreaRatio;
    idealMinAreaRatio = d.idealMinAreaRatio;
    idealMaxAreaRatio = d.idealMaxAreaRatio;
    maxPillAreaRatio = d.maxPillAreaRatio;
    pillConfidenceThreshold = d.pillConfidenceThreshold;
    confidenceEmaAlpha = d.confidenceEmaAlpha;
    requiredStableFrames = d.requiredStableFrames;
    maxCentroidJumpFraction = d.maxCentroidJumpFraction;
    swallowVerifyFrames = d.swallowVerifyFrames;
    swallowOpenFactor = d.swallowOpenFactor;
    emptyMouthMaxConfidence = d.emptyMouthMaxConfidence;
    maxPillSeenInVerify = d.maxPillSeenInVerify;
    drinkConfidenceThreshold = d.drinkConfidenceThreshold;
    requiredDrinkHits = d.requiredDrinkHits;
    latencyBudgetMs = d.latencyBudgetMs;
  }
}
