import 'dart:collection';
import 'dart:math';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'package:medTrackPlus/beta/cv_v2/cv_v2_config.dart';

/// Temporal baseline of the open mouth in NORMALIZED mouth-box space.
///
/// THE definitive teeth discriminator: teeth are PERMANENT mouth features —
/// they are present from the very first open-mouth frame. The pill is a NEW
/// object that enters later. The baseline accumulates an occupancy map of
/// pill-candidate cells over the first pill-free open-mouth frames; any blob
/// that already existed in the baseline (teeth, fillings, bright gums) gets
/// near-zero novelty and is suppressed REGARDLESS of its colour, shape or
/// position. Normalized (0..1) coordinates make it robust to mouth-box
/// scale/translation changes between frames.
class MouthBaseline {
  static const int bw = 32;
  static const int bh = 24;
  static const double _alpha = 0.35; // EMA factor per update
  static const int minFrames = 5;

  final List<double> _occ = List<double>.filled(bw * bh, 0.0);
  int _frames = 0;

  int get frames => _frames;
  bool get ready => _frames >= minFrames;

  void reset() {
    for (int i = 0; i < _occ.length; i++) {
      _occ[i] = 0.0;
    }
    _frames = 0;
  }

  /// Folds the current frame's candidate grid (gw×gh) into the baseline.
  void update(List<bool> candidate, int gw, int gh) {
    if (gw < 2 || gh < 2) return;
    for (int ny = 0; ny < bh; ny++) {
      final sy = (ny * (gh - 1) / (bh - 1)).round();
      for (int nx = 0; nx < bw; nx++) {
        final sx = (nx * (gw - 1) / (bw - 1)).round();
        final cur = candidate[sy * gw + sx] ? 1.0 : 0.0;
        final i = ny * bw + nx;
        _occ[i] = _frames == 0 ? cur : _occ[i] + _alpha * (cur - _occ[i]);
      }
    }
    _frames++;
  }

  /// Occupancy at a normalized cell with a 1-cell neighbourhood MAX
  /// (tolerates small shifts of teeth between frames).
  double occupancyAtNormalized(double fx, double fy) {
    final cx = (fx * (bw - 1)).round().clamp(0, bw - 1);
    final cy = (fy * (bh - 1)).round().clamp(0, bh - 1);
    double best = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        final x = cx + dx, y = cy + dy;
        if (x < 0 || y < 0 || x >= bw || y >= bh) continue;
        final v = _occ[y * bw + x];
        if (v > best) best = v;
      }
    }
    return best;
  }
}

/// Result of the V2 mouth-region pixel analysis.
class MouthPixelAnalysisV2 {
  final int totalSamples;
  final int brightSamples;

  /// PILL-CANDIDATE cells: not reddish (tongue/lips/gums) and not dark
  /// (mouth cavity). Includes pills of ANY colour — and teeth, which are
  /// then suppressed by blob scoring.
  final int pillLikeSamples;
  final int adaptiveThreshold;
  final double meanLuma;
  final double stdLuma;
  final bool chromaAvailable;

  /// Number of candidate blobs found (after the noise filter).
  final int blobCount;

  /// BEST-SCORING pill-like blob (not the largest!), mapped back to upright
  /// image coords.
  final Rect? blobRect;
  final Offset? blobCentroid; // upright image coords
  final double blobAreaRatio; // blob cells / total cells
  final double blobAspect; // bbox width / height (grid cells)

  final double areaScore;
  final double centralityScore; // horizontal centering
  final double positionScore; // vertical tongue-zone prior
  final double compactnessScore;

  /// Colourfulness of the chosen blob: saturated non-red colour (yellow,
  /// orange, blue, green pill) → high. Teeth can never be colourful.
  final double colorScore;
  final double surroundScore; // red (tongue) ring around the blob

  /// NOVELTY: 1.0 = blob did NOT exist in the open-mouth baseline (new
  /// object → pill), 0.0 = blob was always there (teeth). 0.5 = baseline
  /// not ready yet (neutral).
  final double noveltyScore;
  final int baselineFrames;
  final double teethPenalty; // combined teeth-geometry penalty (≤1)

  /// Fraction of blob cells that look tooth-like (bright + chroma-neutral).
  final double toothLikeness;

  /// Fused confidence in [0, 1].
  final double confidence;

  const MouthPixelAnalysisV2({
    this.totalSamples = 0,
    this.brightSamples = 0,
    this.pillLikeSamples = 0,
    this.adaptiveThreshold = 0,
    this.meanLuma = 0,
    this.stdLuma = 0,
    this.chromaAvailable = false,
    this.blobCount = 0,
    this.blobRect,
    this.blobCentroid,
    this.blobAreaRatio = 0,
    this.blobAspect = 0,
    this.areaScore = 0,
    this.centralityScore = 0,
    this.positionScore = 0,
    this.compactnessScore = 0,
    this.colorScore = 0,
    this.surroundScore = 0,
    this.noveltyScore = 0.5,
    this.baselineFrames = 0,
    this.teethPenalty = 1.0,
    this.toothLikeness = 0,
    this.confidence = 0,
  });

  double get brightRatio =>
      totalSamples == 0 ? 0 : brightSamples / totalSamples;
  double get pillLikeRatio =>
      totalSamples == 0 ? 0 : pillLikeSamples / totalSamples;
}

/// V2 pixel analyzer for the mouth region.
///
/// Detection model (V2.1 — colour-agnostic):
///
/// The mouth interior only contains three "native" pixel classes:
///   • REDDISH  — tongue, lips, gums (V channel clearly above neutral)
///   • DARK     — mouth cavity shadow
///   • TOOTH    — bright AND chroma-neutral-to-slightly-yellow
/// A pill is a compact foreign object: NOT reddish and NOT dark, in ANY
/// colour (white, yellow, orange, blue, green…). So candidate cells are
/// "not reddish + not dark", and teeth are separated from pills by blob
/// scoring rather than by colour alone:
///   • position prior — pill rests ON the tongue (mid/lower mouth box);
///     upper teeth hug the top rim, lower teeth the bottom rim;
///   • red-surround — a pill is bordered by tongue red; teeth border teeth;
///   • tooth-row geometry — wide thin blobs, blobs spanning most of the
///     mouth width, blobs glued to the rim;
///   • colourfulness — a saturated-colour blob CANNOT be teeth, so colour
///     both boosts the score and cancels most teeth penalties.
///
/// Plus the V2 foundations: rotation-correct buffer sampling (critical fix),
/// adaptive luma thresholds, NV21 chroma access.
class MouthPixelAnalyzerV2 {
  final CvV2Config config;
  MouthPixelAnalyzerV2(this.config);

  MouthPixelAnalysisV2 analyze(
    CameraImage image,
    Rect mouthRect,
    InputImageRotation rotation, {
    MouthBaseline? baseline,
    bool allowBaselineUpdate = false,
  }) {
    if (image.planes.isEmpty) return const MouthPixelAnalysisV2();

    final bufW = image.width;
    final bufH = image.height;
    final rotDeg = _rotationDegrees(rotation);
    final uprightW = (rotDeg == 90 || rotDeg == 270) ? bufH : bufW;
    final uprightH = (rotDeg == 90 || rotDeg == 270) ? bufW : bufH;

    final left = mouthRect.left.clamp(0.0, uprightW - 1.0).toInt();
    final top = mouthRect.top.clamp(0.0, uprightH - 1.0).toInt();
    final right = mouthRect.right.clamp(0.0, uprightW - 1.0).toInt();
    final bottom = mouthRect.bottom.clamp(0.0, uprightH - 1.0).toInt();
    if (right - left < 4 || bottom - top < 4) {
      return const MouthPixelAnalysisV2();
    }

    // Cap grid size for performance (~<=4096 cells).
    int step = max(2, config.sampleStep);
    while (((right - left) ~/ step + 1) * ((bottom - top) ~/ step + 1) >
        4096) {
      step += 1;
    }

    final sampler = _Nv21Sampler(image);
    if (!sampler.valid) return const MouthPixelAnalysisV2();

    final gw = (right - left) ~/ step + 1;
    final gh = (bottom - top) ~/ step + 1;

    // ── Pass 1: luma statistics ────────────────────────────────────────
    final lumas = List<int>.filled(gw * gh, 0);
    int n = 0;
    double sum = 0, sumSq = 0;
    for (int gy = 0; gy < gh; gy++) {
      final yr = top + gy * step;
      for (int gx = 0; gx < gw; gx++) {
        final xr = left + gx * step;
        final p = _mapToBuffer(xr, yr, rotDeg, bufW, bufH);
        final luma = sampler.lumaAt(p.x, p.y);
        lumas[gy * gw + gx] = luma < 0 ? 0 : luma;
        if (luma >= 0) {
          n++;
          sum += luma;
          sumSq += luma * luma;
        }
      }
    }
    if (n < 16) return const MouthPixelAnalysisV2();
    final mean = sum / n;
    final variance = max(0.0, sumSq / n - mean * mean);
    final std = sqrt(variance);

    // Tooth/bright threshold (adaptive) and dark-cavity threshold.
    final brightThreshold = (mean + config.brightnessSigmaK * std)
        .clamp(config.brightnessFloor.toDouble(),
            config.brightnessCeil.toDouble())
        .toInt();
    final darkThreshold = max(45, (mean * 0.55).round());

    // ── Pass 2: classify cells ─────────────────────────────────────────
    // candidate = not reddish && not dark  (pill of ANY colour, or teeth)
    // toothLike = candidate && bright && chroma-neutral
    // colored   = candidate && saturated non-red chroma (NEVER teeth)
    final candidate = List<bool>.filled(gw * gh, false);
    final reddish = List<bool>.filled(gw * gh, false);
    final toothLike = List<bool>.filled(gw * gh, false);
    final colored = List<bool>.filled(gw * gh, false);
    int brightCount = 0, candidateCount = 0;
    final chromaAvailable = sampler.hasChroma;

    for (int gy = 0; gy < gh; gy++) {
      final yr = top + gy * step;
      for (int gx = 0; gx < gw; gx++) {
        final i = gy * gw + gx;
        final luma = lumas[i];
        if (luma >= brightThreshold) brightCount++;

        int du = 0, dv = 0;
        bool hasUv = false;
        if (chromaAvailable) {
          final xr2 = left + gx * step;
          final p = _mapToBuffer(xr2, yr, rotDeg, bufW, bufH);
          final uv = sampler.chromaAt(p.x, p.y);
          if (uv != null) {
            hasUv = true;
            du = uv.$1 - 128;
            dv = uv.$2 - 128;
            // Tongue / lips / gums: V clearly above neutral and red
            // dominates over blue-yellow axis.
            if (dv > 12 && dv >= du) reddish[i] = true;
          }
        }

        if (luma < darkThreshold) continue; // mouth-cavity shadow
        if (reddish[i]) continue; // native mouth tissue

        candidate[i] = true;
        candidateCount++;

        if (hasUv) {
          final d = sqrt((du * du + dv * dv).toDouble());
          if (d <= config.chromaNeutralMax && luma >= brightThreshold) {
            toothLike[i] = true;
          }
          // Saturated non-red colour → impossible for teeth.
          if (d > config.chromaNeutralMax && !reddish[i]) {
            colored[i] = true;
          }
        } else {
          // No chroma → only brightness available; treat bright as
          // potentially-tooth so penalties stay active.
          if (luma >= brightThreshold) toothLike[i] = true;
        }
      }
    }

    final total = n;

    // ── Baseline occupancy for every grid cell (teeth = already there) ─
    final baselineReady = baseline != null && baseline.ready;
    List<double>? baselineOcc;
    if (baselineReady) {
      baselineOcc = List<double>.filled(gw * gh, 0.0);
      for (int gy = 0; gy < gh; gy++) {
        final fy = gy / max(1, gh - 1);
        for (int gx = 0; gx < gw; gx++) {
          baselineOcc[gy * gw + gx] =
              baseline.occupancyAtNormalized(gx / max(1, gw - 1), fy);
        }
      }
    }

    // ── Collect ALL candidate blobs (4-neighbour BFS) ──────────────────
    final blobs = <_Blob>[];
    final visited = List<bool>.filled(gw * gh, false);
    final minBlobCells = max(3, (0.008 * total).round());
    for (int i = 0; i < gw * gh; i++) {
      if (!candidate[i] || visited[i]) continue;
      final blob = _bfs(
          i, gw, gh, candidate, visited, toothLike, colored, baselineOcc);
      if (blob.area >= minBlobCells) blobs.add(blob);
    }

    // ── Score every blob; the BEST pill-like one wins (NOT the biggest:
    //    a tooth row is often the biggest candidate region). ────────────
    _BlobScore? best;
    for (final blob in blobs) {
      final s = _scoreBlob(
          blob, gw, gh, total, reddish, chromaAvailable, baselineReady);
      if (best == null || s.confidence > best.confidence) best = s;
    }

    // ── Baseline update: only from frames that look pill-free, so the
    //    pill itself never poisons the baseline. Teeth/fillings/gum glare
    //    accumulate; the pill (arriving later) won't be in the map. ─────
    if (baseline != null &&
        allowBaselineUpdate &&
        (best == null || best.confidence < 0.30)) {
      baseline.update(candidate, gw, gh);
    }

    if (best == null) {
      return MouthPixelAnalysisV2(
        totalSamples: total,
        brightSamples: brightCount,
        pillLikeSamples: candidateCount,
        adaptiveThreshold: brightThreshold,
        meanLuma: mean,
        stdLuma: std,
        chromaAvailable: chromaAvailable,
        blobCount: 0,
        baselineFrames: baseline?.frames ?? 0,
        confidence: 0,
      );
    }

    final b = best.blob;
    return MouthPixelAnalysisV2(
      totalSamples: total,
      brightSamples: brightCount,
      pillLikeSamples: candidateCount,
      adaptiveThreshold: brightThreshold,
      meanLuma: mean,
      stdLuma: std,
      chromaAvailable: chromaAvailable,
      blobCount: blobs.length,
      blobRect: Rect.fromLTRB(
        (left + b.minX * step).toDouble(),
        (top + b.minY * step).toDouble(),
        (left + (b.maxX + 1) * step).toDouble(),
        (top + (b.maxY + 1) * step).toDouble(),
      ),
      blobCentroid: Offset(
        left + b.sumX / b.area * step,
        top + b.sumY / b.area * step,
      ),
      blobAreaRatio: b.area / total,
      blobAspect: best.aspect,
      areaScore: best.areaScore,
      centralityScore: best.centralityScore,
      positionScore: best.positionScore,
      compactnessScore: best.compactnessScore,
      colorScore: best.colorScore,
      surroundScore: best.surroundScore,
      noveltyScore: best.noveltyScore,
      baselineFrames: baseline?.frames ?? 0,
      teethPenalty: best.teethPenalty,
      toothLikeness: best.toothLikeness,
      confidence: best.confidence.clamp(0.0, 1.0),
    );
  }

  _BlobScore _scoreBlob(
    _Blob blob,
    int gw,
    int gh,
    int total,
    List<bool> reddish,
    bool chromaAvailable,
    bool baselineReady,
  ) {
    final areaRatio = blob.area / total;
    final areaScore = _scoreArea(areaRatio);

    final cx = blob.sumX / blob.area;
    final cy = blob.sumY / blob.area;

    // Horizontal centering: pill is mid-mouth.
    final dx = (cx - (gw - 1) / 2.0) / max(1.0, gw / 2.0);
    final centrality = (1.0 - dx.abs() * 1.2).clamp(0.0, 1.0);

    // Vertical tongue-zone prior: pill rests ON the tongue → roughly
    // 35–85 % down the mouth box. Upper teeth ≈ top 25 %, lower teeth ≈
    // bottom 10 % → both fall off steeply.
    final ny = cy / max(1.0, gh - 1.0); // 0 = top, 1 = bottom
    double positionScore;
    if (ny < 0.35) {
      positionScore = (ny / 0.35).clamp(0.0, 1.0);
      positionScore = positionScore * positionScore; // steep near the top
    } else if (ny <= 0.85) {
      positionScore = 1.0;
    } else {
      positionScore = ((1.0 - ny) / 0.15).clamp(0.0, 1.0);
    }

    final bw = blob.maxX - blob.minX + 1;
    final bh = blob.maxY - blob.minY + 1;
    final fill = blob.area / (bw * bh);
    final compactness = ((fill - 0.35) / 0.35).clamp(0.0, 1.0);
    final aspect = bw / max(1, bh);

    // Colourfulness: saturated non-red blob → cannot be teeth.
    final fracColored = blob.coloredCells / blob.area;
    final colorScore = (fracColored * 1.6).clamp(0.0, 1.0);
    final toothLikeness = blob.toothLikeCells / blob.area;

    // Red-surround (tongue) score: fraction of reddish cells in a ring
    // around the blob bbox. Pill-on-tongue → high; tooth row → low.
    double surroundScore;
    if (chromaAvailable) {
      final margin = max(1, (min(bw, bh) * 0.5).round());
      int ringTotal = 0, ringRed = 0;
      final x0 = max(0, blob.minX - margin);
      final x1 = min(gw - 1, blob.maxX + margin);
      final y0 = max(0, blob.minY - margin);
      final y1 = min(gh - 1, blob.maxY + margin);
      for (int y = y0; y <= y1; y++) {
        for (int x = x0; x <= x1; x++) {
          final inside = x >= blob.minX &&
              x <= blob.maxX &&
              y >= blob.minY &&
              y <= blob.maxY;
          if (inside) continue;
          ringTotal++;
          if (reddish[y * gw + x]) ringRed++;
        }
      }
      surroundScore = ringTotal == 0
          ? 0.0
          : ((ringRed / ringTotal) / 0.45).clamp(0.0, 1.0);
    } else {
      surroundScore = 0.5; // unknown → neutral
    }

    // ── NOVELTY (temporal baseline) — THE teeth killer ─────────────────
    // 1.0 = blob did not exist when the mouth first opened (new object →
    // pill). ~0.0 = blob was there from the start (teeth/fillings).
    final double noveltyScore;
    if (baselineReady && blob.baselineSamples > 0) {
      noveltyScore =
          (1.0 - blob.sumBaselineOcc / blob.baselineSamples).clamp(0.0, 1.0);
    } else {
      noveltyScore = 0.5; // baseline not ready → neutral
    }

    // ── Teeth penalties (multiplicative) ───────────────────────────────
    double penalty = 1.0;
    // Tooth-row shape: wide and thin.
    if (aspect > 2.2) {
      penalty *= (1.0 - 0.65 * ((aspect - 2.2) / 1.8)).clamp(0.35, 1.0);
    }
    // Spans most of the mouth width → almost certainly a tooth row.
    final widthFraction = bw / max(1, gw);
    if (widthFraction > 0.60) {
      penalty *= (1.0 - 2.8 * (widthFraction - 0.60)).clamp(0.30, 1.0);
    }
    // Glued to the top rim (upper teeth) / bottom rim (lower teeth).
    if (blob.minY == 0) penalty *= 0.55;
    if (blob.maxY == gh - 1) penalty *= 0.75;
    // Tooth-coloured blob with no tongue around it → slam it harder.
    if (toothLikeness > 0.7 && surroundScore < 0.15) penalty *= 0.5;

    // A clearly coloured blob cannot be teeth: recover most of the
    // geometry penalty (large yellow/orange pills can be wide too).
    penalty = penalty + (1.0 - penalty) * 0.7 * colorScore;

    // HARD baseline suppression: the blob existed before the pill could
    // have entered the mouth → it is anatomy, not medication. This fires
    // regardless of colour, brightness, shape or position.
    if (baselineReady && noveltyScore < 0.25) penalty *= 0.15;

    final core = 0.18 * areaScore +
        0.10 * centrality +
        0.16 * positionScore +
        0.10 * compactness +
        0.13 * surroundScore +
        0.13 * colorScore +
        0.20 * noveltyScore;

    return _BlobScore(
      blob: blob,
      areaScore: areaScore,
      centralityScore: centrality,
      positionScore: positionScore,
      compactnessScore: compactness,
      colorScore: colorScore,
      surroundScore: surroundScore,
      noveltyScore: noveltyScore,
      aspect: aspect,
      teethPenalty: penalty,
      toothLikeness: toothLikeness,
      confidence: core * penalty,
    );
  }

  double _scoreArea(double r) {
    final c = config;
    if (r < c.minPillAreaRatio) return 0.0;
    if (r < c.idealMinAreaRatio) {
      return (r - c.minPillAreaRatio) /
          (c.idealMinAreaRatio - c.minPillAreaRatio);
    }
    if (r <= c.idealMaxAreaRatio) return 1.0;
    if (r <= c.maxPillAreaRatio) {
      return 1.0 -
          0.85 *
              (r - c.idealMaxAreaRatio) /
              (c.maxPillAreaRatio - c.idealMaxAreaRatio);
    }
    return 0.1;
  }

  _Blob _bfs(
    int start,
    int gw,
    int gh,
    List<bool> mask,
    List<bool> visited,
    List<bool> toothLike,
    List<bool> colored,
    List<double>? baselineOcc,
  ) {
    final blob = _Blob();
    final queue = Queue<int>()..add(start);
    visited[start] = true;
    while (queue.isNotEmpty) {
      final i = queue.removeFirst();
      final x = i % gw, y = i ~/ gw;
      blob.absorb(x, y, toothLike[i], colored[i],
          baselineOcc == null ? null : baselineOcc[i]);
      void tryAdd(int nx, int ny) {
        if (nx < 0 || ny < 0 || nx >= gw || ny >= gh) return;
        final ni = ny * gw + nx;
        if (mask[ni] && !visited[ni]) {
          visited[ni] = true;
          queue.add(ni);
        }
      }

      tryAdd(x - 1, y);
      tryAdd(x + 1, y);
      tryAdd(x, y - 1);
      tryAdd(x, y + 1);
    }
    return blob;
  }

  static int _rotationDegrees(InputImageRotation r) {
    switch (r) {
      case InputImageRotation.rotation90deg:
        return 90;
      case InputImageRotation.rotation180deg:
        return 180;
      case InputImageRotation.rotation270deg:
        return 270;
      default:
        return 0;
    }
  }

  /// Maps a point in UPRIGHT (rotated) coordinates back to raw buffer
  /// coordinates. `rotDeg` is the clockwise rotation that makes the buffer
  /// upright (ML Kit's InputImageRotation convention).
  static ({int x, int y}) _mapToBuffer(
      int xr, int yr, int rotDeg, int bufW, int bufH) {
    switch (rotDeg) {
      case 90:
        return (x: yr, y: bufH - 1 - xr);
      case 180:
        return (x: bufW - 1 - xr, y: bufH - 1 - yr);
      case 270:
        return (x: bufW - 1 - yr, y: xr);
      default:
        return (x: xr, y: yr);
    }
  }
}

class _Blob {
  int area = 0;
  int toothLikeCells = 0;
  int coloredCells = 0;
  double sumBaselineOcc = 0;
  int baselineSamples = 0;
  int minX = 1 << 30, minY = 1 << 30, maxX = -1, maxY = -1;
  double sumX = 0, sumY = 0;

  void absorb(
      int x, int y, bool isToothLike, bool isColored, double? baselineOcc) {
    area++;
    if (isToothLike) toothLikeCells++;
    if (isColored) coloredCells++;
    if (baselineOcc != null) {
      sumBaselineOcc += baselineOcc;
      baselineSamples++;
    }
    sumX += x;
    sumY += y;
    if (x < minX) minX = x;
    if (y < minY) minY = y;
    if (x > maxX) maxX = x;
    if (y > maxY) maxY = y;
  }
}

class _BlobScore {
  final _Blob blob;
  final double areaScore;
  final double centralityScore;
  final double positionScore;
  final double compactnessScore;
  final double colorScore;
  final double surroundScore;
  final double noveltyScore;
  final double aspect;
  final double teethPenalty;
  final double toothLikeness;
  final double confidence;

  const _BlobScore({
    required this.blob,
    required this.areaScore,
    required this.centralityScore,
    required this.positionScore,
    required this.compactnessScore,
    required this.colorScore,
    required this.surroundScore,
    required this.noveltyScore,
    required this.aspect,
    required this.teethPenalty,
    required this.toothLikeness,
    required this.confidence,
  });
}

/// Reads luma + chroma out of an NV21 CameraImage in either the 2-plane
/// (Y + interleaved VU) or single-plane (contiguous NV21) layout.
class _Nv21Sampler {
  final CameraImage image;
  late final bool valid;
  late final bool hasChroma;

  late final List<int> _yBytes;
  late final int _yRowStride;
  List<int>? _uvBytes;
  int _uvRowStride = 0;
  int _uvOffset = 0; // offset into _uvBytes where VU data starts

  _Nv21Sampler(this.image) {
    if (image.planes.isEmpty) {
      valid = false;
      hasChroma = false;
      return;
    }
    final w = image.width;
    final h = image.height;
    _yBytes = image.planes[0].bytes;
    _yRowStride =
        image.planes[0].bytesPerRow > 0 ? image.planes[0].bytesPerRow : w;
    if (_yBytes.length < _yRowStride * (h - 1) + w) {
      valid = false;
      hasChroma = false;
      return;
    }
    valid = true;

    if (image.planes.length >= 2) {
      _uvBytes = image.planes[1].bytes;
      _uvRowStride =
          image.planes[1].bytesPerRow > 0 ? image.planes[1].bytesPerRow : w;
      _uvOffset = 0;
      hasChroma = true;
    } else {
      // Single contiguous NV21 buffer: Y plane then interleaved VU.
      final yPlaneSize = _yRowStride * h;
      if (_yBytes.length >= yPlaneSize + (_yRowStride * h ~/ 2)) {
        _uvBytes = _yBytes;
        _uvRowStride = _yRowStride;
        _uvOffset = yPlaneSize;
        hasChroma = true;
      } else {
        hasChroma = false;
      }
    }
  }

  /// Returns luma at buffer coords, or -1 when out of bounds.
  int lumaAt(int x, int y) {
    if (x < 0 || y < 0 || x >= image.width || y >= image.height) return -1;
    final idx = y * _yRowStride + x;
    if (idx >= _yBytes.length) return -1;
    return _yBytes[idx] & 0xFF;
  }

  /// Returns (U, V) at buffer coords, or null when unavailable.
  (int, int)? chromaAt(int x, int y) {
    final uv = _uvBytes;
    if (uv == null) return null;
    if (x < 0 || y < 0 || x >= image.width || y >= image.height) return null;
    // NV21: interleaved VU, one pair per 2x2 block.
    final vIdx = _uvOffset + (y >> 1) * _uvRowStride + ((x >> 1) << 1);
    final uIdx = vIdx + 1;
    if (uIdx >= uv.length) return null;
    final v = uv[vIdx] & 0xFF;
    final u = uv[uIdx] & 0xFF;
    return (u, v);
  }
}
