library;

enum VerificationResult { rejected, suspicious, success }

enum ScoringMode { withDevice, deviceFree }

class AccuracyScoringEngine {
  static const _deviceWeights = {
    'presence': 0.15,
    'pill': 0.25,
    'lip': 0.25,
    'mouth': 0.20,
    'timing': 0.15,
  };

  static const _deviceFreeWeights = {
    'pill': 0.30,
    'lip': 0.30,
    'mouth': 0.25,
    'timing': 0.15,
  };

  double calculate({
    required ScoringMode mode,
    double presence = 0.0,
    required double pill,
    required double lip,
    required double mouth,
    required double timing,
  }) {
    final weights = mode == ScoringMode.withDevice
        ? _deviceWeights
        : _deviceFreeWeights;

    double score = 0.0;
    score += (weights['pill'] ?? 0) * pill;
    score += (weights['lip'] ?? 0) * lip;
    score += (weights['mouth'] ?? 0) * mouth;
    score += (weights['timing'] ?? 0) * timing;
    if (mode == ScoringMode.withDevice) {
      score += (weights['presence'] ?? 0) * presence;
    }

    return score.clamp(0.0, 1.0);
  }

  VerificationResult classify(double score) {
    if (score < 0.30) return VerificationResult.rejected;
    if (score <= 0.70) return VerificationResult.suspicious;
    return VerificationResult.success;
  }
}
