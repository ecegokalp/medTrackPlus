library;

import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../camera_test/camera_state.dart';
import '../camera_test/mock_cv_processor.dart';
import 'verification_state.dart';

class VerificationNotifier extends StateNotifier<VerificationState> {
  VerificationNotifier() : super(const VerificationIdle());

  Timer? _timeoutTimer;
  final MockCvProcessor _cvProcessor = MockCvProcessor(
    simulatedDelay: const Duration(milliseconds: 30),
  );

  // Timeout durations per state
  static const _pillWaitTimeout = Duration(seconds: 60);
  static const _pillDetectedTimeout = Duration(seconds: 30);
  static const _trackingTimeout = Duration(seconds: 20);
  static const _mouthCheckTimeout = Duration(seconds: 30);

  // Metrics tracking
  DateTime? _sessionStart;
  DateTime? _pillDetectedAt;
  DateTime? _trackingStartedAt;
  DateTime? _mouthPromptedAt;
  final List<double> _confidences = [];

  /// Start the verification flow.
  void startVerification() {
    _reset();
    _sessionStart = DateTime.now();
    state = WaitingForPill(startedAt: _sessionStart!);
    _startTimeout(_pillWaitTimeout, 'waitingForPill');
  }

  /// Feed a camera frame into the verification pipeline.
  Future<void> processFrame(CameraImage image) async {
    final cvResult = await _cvProcessor.processFrame(image);
    _handleCvResult(cvResult);
  }

  /// Process CV result and advance state machine.
  void _handleCvResult(CvResult result) {
    switch (state) {
      case WaitingForPill():
        final pillBox = _findPill(result);
        if (pillBox != null) {
          _cancelTimeout();
          _pillDetectedAt = DateTime.now();
          final detection = CvDetection(
            label: pillBox.label,
            confidence: pillBox.confidence,
            x: pillBox.x,
            y: pillBox.y,
          );
          _confidences.add(pillBox.confidence);
          state = PillDetected(
            detectedAt: _pillDetectedAt!,
            detection: detection,
          );
          _startTimeout(_pillDetectedTimeout, 'pillDetected');
        }

      case PillDetected():
        final pillBox = _findPill(result);
        if (pillBox != null && _isMovingTowardMouth(pillBox)) {
          _cancelTimeout();
          _trackingStartedAt = DateTime.now();
          _confidences.add(pillBox.confidence);
          state = TrackingToLip(
            startedAt: _trackingStartedAt!,
            lastDetection: CvDetection(
              label: pillBox.label,
              confidence: pillBox.confidence,
              x: pillBox.x,
              y: pillBox.y,
            ),
          );
          _startTimeout(_trackingTimeout, 'trackingToLip');
        }

      case TrackingToLip():
        final pillBox = _findPill(result);
        if (pillBox == null) {
          // Pill disappeared — assumed consumed
          _cancelTimeout();
          state = PillConsumed(consumedAt: DateTime.now());
          // Auto-advance to mouth check prompt
          Future.microtask(_promptMouthCheck);
        } else {
          _confidences.add(pillBox.confidence);
          state = TrackingToLip(
            startedAt: (state as TrackingToLip).startedAt,
            lastDetection: CvDetection(
              label: pillBox.label,
              confidence: pillBox.confidence,
              x: pillBox.x,
              y: pillBox.y,
            ),
          );
        }

      case MouthCheckPrompt():
        if (_isMouthEmpty(result)) {
          _cancelTimeout();
          state = MouthVerified(verifiedAt: DateTime.now());
          Future.microtask(_calculateScore);
        }

      default:
        break;
    }
  }

  void _promptMouthCheck() {
    if (state is! PillConsumed) return;
    _mouthPromptedAt = DateTime.now();
    state = MouthCheckPrompt(promptedAt: _mouthPromptedAt!);
    _startTimeout(_mouthCheckTimeout, 'mouthCheckPrompt');
  }

  void _calculateScore() {
    if (state is! MouthVerified) return;

    final now = DateTime.now();
    final totalTime = now.difference(_sessionStart!);
    final pillDetectionTime = _pillDetectedAt!.difference(_sessionStart!);
    final trackingTime = _trackingStartedAt != null
        ? now.difference(_trackingStartedAt!)
        : Duration.zero;
    final mouthVerificationTime = _mouthPromptedAt != null
        ? now.difference(_mouthPromptedAt!)
        : Duration.zero;

    final avgConfidence = _confidences.isEmpty
        ? 0.0
        : _confidences.reduce((a, b) => a + b) / _confidences.length;

    final metrics = VerificationMetrics(
      pillDetectionTime: pillDetectionTime,
      trackingTime: trackingTime,
      mouthVerificationTime: mouthVerificationTime,
      totalTime: totalTime,
      avgConfidence: avgConfidence,
    );

    state = Scoring(metrics: metrics);

    // Score: weighted combination of speed and confidence
    final speedScore = _speedScore(totalTime);
    final score = (avgConfidence * 0.6 + speedScore * 0.4).clamp(0.0, 1.0);

    state = VerificationCompleted(score: score, metrics: metrics);
  }

  double _speedScore(Duration total) {
    // Under 30s = perfect, degrades linearly up to 120s
    final seconds = total.inSeconds;
    if (seconds <= 30) return 1.0;
    if (seconds >= 120) return 0.0;
    return 1.0 - (seconds - 30) / 90.0;
  }

  /// Check if any bounding box is a pill-type object.
  BoundingBox? _findPill(CvResult result) {
    const pillLabels = {'pill', 'tablet', 'capsule'};
    for (final box in result.boundingBoxes) {
      if (pillLabels.contains(box.label) && box.confidence > 0.6) {
        return box;
      }
    }
    return null;
  }

  /// Heuristic: pill is moving toward mouth if y < 0.4 (upper part of frame).
  bool _isMovingTowardMouth(BoundingBox box) {
    return box.y < 0.4;
  }

  /// Heuristic: mouth is empty if no pill-type objects detected.
  bool _isMouthEmpty(CvResult result) {
    return _findPill(result) == null && result.detectedObjects == 0;
  }

  void _startTimeout(Duration duration, String stage) {
    _cancelTimeout();
    _timeoutTimer = Timer(duration, () {
      state = VerificationTimedOut(stage: stage, lastState: state);
    });
  }

  void _cancelTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  void cancel() {
    _cancelTimeout();
    state = const VerificationIdle();
  }

  void _reset() {
    _cancelTimeout();
    _sessionStart = null;
    _pillDetectedAt = null;
    _trackingStartedAt = null;
    _mouthPromptedAt = null;
    _confidences.clear();
  }

  @override
  void dispose() {
    _cancelTimeout();
    _cvProcessor.dispose();
    super.dispose();
  }
}

// -- Providers --

final verificationProvider =
    StateNotifierProvider<VerificationNotifier, VerificationState>((ref) {
  return VerificationNotifier();
});