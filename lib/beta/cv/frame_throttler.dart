import 'package:medTrackPlus/beta/mlkit_test/pill_detection_service.dart';

/// Decides whether the current camera frame should be processed, based on
/// the verification-flow phase the system was in on the previous frame.
///
/// Per-phase skip factors (= "process every Nth frame"):
///   waitingForPill   (noFace / faceDetected / mouthOpen w/o tracking) → 5
///   trackingToLip    (mouthOpen + isTracking)                         → 1
///   pillDetected     (pillOnTongue / mouthClosedWithPill)             → 2
///   mouthCheckPrompt (drinking / mouthReopened / swallow*)            → 2
class FrameThrottler {
  int _tick = 0;
  int _lastSkipFactor = 1;

  int get currentSkipFactor => _lastSkipFactor;

  bool shouldProcess(DetectionPhase phase, {bool isTracking = false}) {
    _tick++;
    _lastSkipFactor = _skipForPhase(phase, isTracking);
    return _tick % _lastSkipFactor == 0;
  }

  void reset() {
    _tick = 0;
    _lastSkipFactor = 1;
  }

  int _skipForPhase(DetectionPhase phase, bool isTracking) {
    switch (phase) {
      case DetectionPhase.pillOnTongue:
      case DetectionPhase.mouthClosedWithPill:
        return 2;
      case DetectionPhase.drinking:
      case DetectionPhase.mouthReopened:
      case DetectionPhase.swallowConfirmed:
      case DetectionPhase.swallowFailed:
      case DetectionPhase.timeoutExpired:
        return 2;
      case DetectionPhase.mouthOpen:
        return isTracking ? 1 : 5;
      case DetectionPhase.noFace:
      case DetectionPhase.faceDetected:
        return 5;
    }
  }
}