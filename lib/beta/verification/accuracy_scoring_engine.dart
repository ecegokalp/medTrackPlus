library;

import 'package:medTrackPlus/beta/models/cv_frame_data.dart';

enum VerificationResult { rejected, suspicious, success }

enum ScoringMode { withDevice, deviceFree }

class AccuracyScoringEngine {
  static const _deviceWeights = {
    'presence': 0.10,
    'pill': 0.22,
    'lip': 0.20,
    'mouth': 0.18,
    'pillToLip': 0.15,
    'timing': 0.15,
  };

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

  Map<String, double> calculateSubScores(List<CVFrameData> frames) {
    if (frames.isEmpty) {
      return {'pill': 0, 'lip': 0, 'mouth': 0, 'pillToLip': 0};
    }

    double maxPillConfidence = 0.0;
    for (final f in frames) {
      if (f.pillConfidence > maxPillConfidence) {
        maxPillConfidence = f.pillConfidence;
      }
    }
    final pillScore = maxPillConfidence.clamp(0.0, 1.0);

    double lipScore = 0.0;
    for (int i = frames.length - 1; i >= 0; i--) {
      if (frames[i].pillToLipDistance != null) {
        final dist = frames[i].pillToLipDistance!;
        if (dist <= _pillLipPerfectDist) {
          lipScore = 1.0;
        } else if (dist <= _pillLipMaxDist) {
          lipScore = 0.3;
        } else {
          lipScore = 0.0;
        }
        break;
      }
    }

    double mouthScore = 0.0;
    if (frames.length >= 2) {
      final sessionStart = frames.first.timestamp;
      final sessionEnd = frames.last.timestamp;
      final sessionMs = sessionEnd.difference(sessionStart).inMilliseconds;
      if (sessionMs > 0) {
        int openMs = 0;
        for (int i = 1; i < frames.length; i++) {
          if (frames[i].isMouthOpen) {
            openMs += frames[i].timestamp.difference(frames[i - 1].timestamp).inMilliseconds;
          }
        }
        mouthScore = (openMs / sessionMs).clamp(0.0, 1.0);
      }
    }

    final distFrames = frames.where((f) => f.pillToLipDistance != null).toList();
    double pillToLipScore = 0.0;
    if (distFrames.isNotEmpty) {
      double sum = 0;
      for (final f in distFrames) {
        sum += scorePillToLipDistance(f.pillToLipDistance!);
      }
      pillToLipScore = sum / distFrames.length;
    }

    return {
      'pill': pillScore,
      'lip': lipScore,
      'mouth': mouthScore,
      'pillToLip': pillToLipScore,
    };
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
