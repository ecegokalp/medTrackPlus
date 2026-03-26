library;

/// Pill-consumption verification state machine.
/// Flow: idle → waitingForPill → pillDetected → trackingToLip
///     → pillConsumed → mouthCheckPrompt → mouthVerified → scoring → completed
sealed class VerificationState {
  const VerificationState();
}

class VerificationIdle extends VerificationState {
  const VerificationIdle();
}

/// Waiting for CV to detect a pill in frame. Timeout: 60s.
class WaitingForPill extends VerificationState {
  final DateTime startedAt;
  const WaitingForPill({required this.startedAt});
}

/// Pill detected in frame. Timeout: 30s to start moving toward lip.
class PillDetected extends VerificationState {
  final DateTime detectedAt;
  final CvDetection detection;
  const PillDetected({required this.detectedAt, required this.detection});
}

/// Tracking pill movement toward lip/mouth. Timeout: 20s.
class TrackingToLip extends VerificationState {
  final DateTime startedAt;
  final CvDetection lastDetection;
  const TrackingToLip({required this.startedAt, required this.lastDetection});
}

/// Pill no longer visible — assumed consumed. Transitions to mouth check.
class PillConsumed extends VerificationState {
  final DateTime consumedAt;
  const PillConsumed({required this.consumedAt});
}

/// Prompting user to open mouth for verification. Timeout: 30s.
class MouthCheckPrompt extends VerificationState {
  final DateTime promptedAt;
  const MouthCheckPrompt({required this.promptedAt});
}

/// Mouth verified empty — pill confirmed consumed.
class MouthVerified extends VerificationState {
  final DateTime verifiedAt;
  const MouthVerified({required this.verifiedAt});
}

/// Calculating verification score.
class Scoring extends VerificationState {
  final VerificationMetrics metrics;
  const Scoring({required this.metrics});
}

/// Verification completed successfully.
class VerificationCompleted extends VerificationState {
  final double score;
  final VerificationMetrics metrics;
  const VerificationCompleted({required this.score, required this.metrics});
}

/// Verification timed out at a specific stage.
class VerificationTimedOut extends VerificationState {
  final String stage;
  final VerificationState lastState;
  const VerificationTimedOut({required this.stage, required this.lastState});
}

/// Verification failed with error.
class VerificationError extends VerificationState {
  final String message;
  final VerificationState previousState;
  const VerificationError(this.message, this.previousState);
}

// -- Supporting models --

class CvDetection {
  final String label;
  final double confidence;
  final double x;
  final double y;
  const CvDetection({
    required this.label,
    required this.confidence,
    required this.x,
    required this.y,
  });
}

class VerificationMetrics {
  final Duration pillDetectionTime;
  final Duration trackingTime;
  final Duration mouthVerificationTime;
  final Duration totalTime;
  final double avgConfidence;

  const VerificationMetrics({
    required this.pillDetectionTime,
    required this.trackingTime,
    required this.mouthVerificationTime,
    required this.totalTime,
    required this.avgConfidence,
  });
}