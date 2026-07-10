library;

import 'package:medTrackPlus/beta/models/cv_frame_data.dart';

enum VerificationResult { rejected, suspicious, success }

enum ScoringMode { withDevice, deviceFree }

class AccuracyScoringEngine {
  // DEVICE mode: 80% MLKit/CV (vision) + 20% distance/presence.
  // The vision sub-weights (pill+lip+mouth+pillToLip+timing) sum to 0.80, and
  // 'presence' carries the remaining 0.20. 'presence' is fed a 0..1 value
  // derived from the ultrasonic distance (closer → 1.0, farther → 0.0).
  static const _deviceWeights = {
    'presence': 0.20,
    'pill': 0.20,
    'lip': 0.18,
    'mouth': 0.16,
    'pillToLip': 0.13,
    'timing': 0.13,
  };

  // DEVICE-FREE mode: 100% MLKit/CV vision, NO distance/presence component.
  // Vision sub-weights sum to 1.0 (exactly like the cv_v2 lab / pure vision).
  static const _deviceFreeWeights = {
    'pill': 0.25,
    'lip': 0.25,
    'mouth': 0.20,
    'pillToLip': 0.15,
    'timing': 0.15,
  };

  static const double _rejectedThreshold = 0.35;
  static const double _successThreshold = 0.65;

  static const double _pillLipPerfectDist = 0.15;
  static const double _pillLipMaxDist = 0.40;

  double calculate({
    required ScoringMode mode,
    double presence = 0.0,
    required double pill,
    required double lip,
    required double mouth,
    required double timing,
    double pillToLip = 0.0,
  }) {
    final weights = mode == ScoringMode.withDevice
        ? _deviceWeights
        : _deviceFreeWeights;

    double score = 0.0;
    score += (weights['pill'] ?? 0) * pill;
    score += (weights['lip'] ?? 0) * lip;
    score += (weights['mouth'] ?? 0) * mouth;
    score += (weights['timing'] ?? 0) * timing;
    score += (weights['pillToLip'] ?? 0) * pillToLip;
    if (mode == ScoringMode.withDevice) {
      score += (weights['presence'] ?? 0) * presence;
    }

    return score.clamp(0.0, 1.0);
  }

  Map<String, double> calculateSubScores(
    List<CVFrameData> frames, {
    bool pillValidated = false,
  }) {
    if (frames.isEmpty) {
      return {'pill': 0, 'lip': 0, 'mouth': 0, 'pillToLip': 0};
    }

    double maxPillConfidence = 0.0;
    for (final f in frames) {
      if (f.pillConfidence > maxPillConfidence) {
        maxPillConfidence = f.pillConfidence;
      }
    }
    final pillScore = pillValidated
        ? maxPillConfidence.clamp(0.85, 1.0)
        : maxPillConfidence.clamp(0.0, 0.45);

    double lipScore = 0.0;
    double pillToLipScore = 0.0;
    if (pillValidated) {
      final distFrames = frames
          .where((f) => f.pillDetected && f.pillToLipDistance != null)
          .toList();
      if (distFrames.isNotEmpty) {
        double sum = 0.0;
        double best = 0.0;
        for (final f in distFrames) {
          final s = scorePillToLipDistance(f.pillToLipDistance!);
          sum += s;
          if (s > best) best = s;
        }
        lipScore = best;
        pillToLipScore = sum / distFrames.length;
      }
    }

    double mouthScore = 0.0;
    final startIdx = frames.indexWhere((f) => f.isMouthOpen || f.pillDetected);
    if (startIdx >= 0 && frames.length - startIdx >= 2) {
      final active = frames.sublist(startIdx);
      final activeMs = active.last.timestamp
          .difference(active.first.timestamp)
          .inMilliseconds;
      if (activeMs > 0) {
        int openMs = 0;
        for (int i = 1; i < active.length; i++) {
          if (active[i].isMouthOpen) {
            openMs += active[i]
                .timestamp
                .difference(active[i - 1].timestamp)
                .inMilliseconds;
          }
        }
        mouthScore = (openMs / activeMs).clamp(0.0, 1.0);
      }
    }

    return {
      'pill': pillScore,
      'lip': lipScore,
      'mouth': mouthScore,
      'pillToLip': pillToLipScore,
    };
  }

  double anchorToDetection(
    double score, {
    required bool pillValidated,
    required bool drinkReached,
    required bool swallowConfirmed,
  }) {
    if (swallowConfirmed) return score.clamp(0.80, 1.0);
    if (!pillValidated) return score.clamp(0.0, 0.34);
    if (drinkReached) return score.clamp(0.65, 0.79);
    return score.clamp(0.40, 0.60);
  }

  VerificationResult classifyWithDetection({
    required bool pillValidated,
    required bool swallowConfirmed,
  }) {
    if (swallowConfirmed) return VerificationResult.success;
    if (!pillValidated) return VerificationResult.rejected;
    return VerificationResult.suspicious;
  }

  double scorePillToLipDistance(double normalizedDistance) {
    if (normalizedDistance <= _pillLipPerfectDist) return 1.0;
    if (normalizedDistance >= _pillLipMaxDist) return 0.0;
    return 1.0 -
        (normalizedDistance - _pillLipPerfectDist) /
            (_pillLipMaxDist - _pillLipPerfectDist);
  }

  double calculateTimingScore(DateTime? scheduledAlarm, DateTime verificationStart) {
    if (scheduledAlarm == null) return 0.5;
    final diffMin = verificationStart.difference(scheduledAlarm).inMinutes.abs();
    if (diffMin <= 5) return 1.0;
    if (diffMin <= 30) return 1.0 - (diffMin - 5) / 25.0 * 0.8;
    return 0.2;
  }

  double calculateFromFrames({
    required ScoringMode mode,
    required List<CVFrameData> frames,
    double presence = 0.0,
    required double timing,
  }) {
    final sub = calculateSubScores(frames);
    return calculate(
      mode: mode,
      presence: presence,
      pill: sub['pill'] ?? 0,
      lip: sub['lip'] ?? 0,
      mouth: sub['mouth'] ?? 0,
      timing: timing,
      pillToLip: sub['pillToLip'] ?? 0,
    );
  }

  VerificationResult classify(double score) {
    if (score < _rejectedThreshold) return VerificationResult.rejected;
    if (score <= _successThreshold) return VerificationResult.suspicious;
    return VerificationResult.success;
  }
}
