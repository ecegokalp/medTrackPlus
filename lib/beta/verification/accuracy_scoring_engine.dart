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
      return {'pill': 0, 'lip': 0, 'mouth': 0, 'pillToLip': 0, 'timing': 0};
    }

    final total = frames.length.toDouble();
    final faceFrames = frames.where((f) => f.faceDetected).length;
    final mouthOpenFrames = frames.where((f) => f.isMouthOpen).length;
    final pillFrames = frames.where((f) => f.pillDetected).length;

    final lipRatio = (faceFrames / total).clamp(0.0, 1.0);
    final mouthRatio = faceFrames > 0
        ? (mouthOpenFrames / faceFrames).clamp(0.0, 1.0)
        : 0.0;
    final pillRatio = faceFrames > 0
        ? (pillFrames / faceFrames).clamp(0.0, 1.0)
        : 0.0;

    final distFrames = frames
        .where((f) => f.pillToLipDistance != null)
        .toList();
    double pillToLipScore = 0.0;
    if (distFrames.isNotEmpty) {
      double sumScore = 0;
      for (final f in distFrames) {
        sumScore += scorePillToLipDistance(f.pillToLipDistance!);
      }
      pillToLipScore = sumScore / distFrames.length;
    }

    return {
      'pill': pillRatio,
      'lip': lipRatio,
      'mouth': mouthRatio,
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
