import 'dart:math';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';

enum DetectionPhase {
  noFace,
  faceDetected,
  mouthOpen,
  pillOnTongue,
  mouthClosedWithPill,
  drinking,
  mouthReopened,
  swallowConfirmed,
  swallowFailed,
  timeoutExpired,
}

enum _Stage {
  awaitingPill,
  awaitingDrink,
  awaitingReopen,
  verifyingSwallow,
  done,
}

class PillOnTongueResult {
  final DetectionPhase phase;
  final Face? face;
  final double mouthOpenRatio;
  final Rect? mouthRegion;
  final double pillConfidence;
  final int whitePixelCount;
  final int totalMouthPixels;
  final String guidance;
  final DateTime timestamp;
  final Rect? smoothedPillRegion;
  final Rect? lastSeenPillRegion;
  final String? detectedDrinkLabel;

  /// Normalized distance from pill region center to lip contour center.
  /// 0.0 = pill overlaps lip, 1.0+ = far from lip. null = not calculable.
  final double? pillToLipDistance;

  /// Whether the face is frontal enough for reliable detection.
  final bool isFaceFrontal;

  PillOnTongueResult({
    required this.phase,
    this.face,
    required this.mouthOpenRatio,
    this.mouthRegion,
    required this.pillConfidence,
    this.whitePixelCount = 0,
    this.totalMouthPixels = 0,
    required this.guidance,
    required this.timestamp,
    this.smoothedPillRegion,
    this.lastSeenPillRegion,
    this.detectedDrinkLabel,
    this.pillToLipDistance,
    this.isFaceFrontal = true,
  });

  factory PillOnTongueResult.empty() => PillOnTongueResult(
        phase: DetectionPhase.noFace,
        mouthOpenRatio: 0.0,
        pillConfidence: 0.0,
        guidance: 'Yüzünüzü kameraya gösterin',
        timestamp: DateTime.now(),
      );
}

class PillOnTongueService {
  late final FaceDetector _faceDetector;
  late final ImageLabeler _imageLabeler;

  static const double _mouthOpenThreshold = 0.08;
  static const double _maxFrontalAngle = 25.0;

  static const double _pillPixelThreshold = 0.05;
  static const double _pillConfidenceThreshold = 0.4;
  static const int _brightnessThreshold = 160;

  static const int _requiredStableFrames = 5;
  static const int _positionBufferSize = 10;

  // Drink-related substrings (ML Kit default model labels, lowercased).
  // Matched as substring so "Coffee cup", "Wine glass", "Drinkware" all hit.
  static const List<String> _drinkLabelSubstrings = [
    'drink', 'bottle', 'cup', 'mug', 'glass', 'water',
    'beverage', 'liquid', 'juice', 'tableware', 'drinkware',
    'tumbler', 'jar', 'pitcher', 'flask', 'thermos', 'kettle',
  ];
  static const double _drinkConfidenceThreshold = 0.40;
  static const Duration _labelingInterval = Duration(milliseconds: 400);

  // Timeouts after pill is confirmed in mouth
  static const Duration _drinkWarningAfter = Duration(seconds: 30);
  static const Duration _drinkTimeoutAfter = Duration(seconds: 60);

  // Frames to wait when verifying swallow.
  // Each frame must show a wide-open AND visibly empty mouth — see
  // _handleVerifyingSwallow. 10 frames at ~10 fps ≈ 1.0 s of clear empty
  // mouth required before swallow can be confirmed.
  static const int _swallowVerifyFrames = 10;

  // Maximum acceptable bright-pixel ratio inside the mouth region during
  // swallow verification. Teeth alone produce ~5–8 % bright pixels under
  // normal lighting; a pill on the tongue easily pushes that to 15–30 %.
  // 0.12 = 12 % strikes a balance: it accepts visible teeth but rejects
  // a still-present pill without forcing the user to hide their teeth.
  static const double _emptyMouthMaxRatio = 0.12;

  // How many drink-label hits required before confirming drink (≈ N * interval)
  static const int _requiredDrinkHits = 3;

  int _consecutivePillFrames = 0;
  int _swallowVerifyCounter = 0;
  bool _pillSeenInVerify = false;
  int _drinkLabelHits = 0;

  final List<Rect> _positionBuffer = [];
  Rect? _lastSeenPillRegion;

  _Stage _stage = _Stage.awaitingPill;
  DateTime? _pillConfirmedAt;
  DateTime _lastLabelingRun = DateTime.fromMillisecondsSinceEpoch(0);
  String? _detectedDrinkLabel;
  bool _isLabeling = false;

  PillOnTongueService() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.fast,
        enableContours: true,
        enableClassification: true,
        enableLandmarks: true,
      ),
    );
    _imageLabeler = ImageLabeler(
      options: ImageLabelerOptions(confidenceThreshold: 0.3),
    );
  }

  /// True while a pill is being followed toward the lip (stability buffer
  /// filling). Used by the camera loop to switch to per-frame detection
  /// during the tracking-to-lip window.
  bool get isTracking =>
      _consecutivePillFrames > 0 && _stage == _Stage.awaitingPill;

  /// Restart the workflow from the beginning.
  void reset() {
    _consecutivePillFrames = 0;
    _swallowVerifyCounter = 0;
    _pillSeenInVerify = false;
    _drinkLabelHits = 0;
    _positionBuffer.clear();
    _lastSeenPillRegion = null;
    _stage = _Stage.awaitingPill;
    _pillConfirmedAt = null;
    _detectedDrinkLabel = null;
  }

  Future<PillOnTongueResult> processFrame(
    CameraImage image,
    InputImage inputImage,
  ) async {
    final faces = await _faceDetector.processImage(inputImage);
    final face = faces.isEmpty ? null : faces.first;
    return processFrameWithFace(image, inputImage, face);
  }

  /// Same as [processFrame] but accepts a pre-detected [Face]. Lets callers
  /// run face detection ONCE per frame and share the result with other
  /// modules (FaceDetectionService) instead of re-running the detector here.
  Future<PillOnTongueResult> processFrameWithFace(
    CameraImage image,
    InputImage inputImage,
    Face? face,
  ) async {
    final now = DateTime.now();

    if (face == null) {
      _consecutivePillFrames = 0;
      return _emit(
        phase: DetectionPhase.noFace,
        guidance: 'Yüzünüzü kameraya gösterin',
        now: now,
      );
    }

    final yaw = face.headEulerAngleY;
    final pitch = face.headEulerAngleX;
    if ((yaw != null && yaw.abs() > _maxFrontalAngle) ||
        (pitch != null && pitch.abs() > _maxFrontalAngle)) {
      _consecutivePillFrames = 0;
      return _emit(
        phase: DetectionPhase.faceDetected,
        face: face,
        guidance: 'Lütfen yüzünüzü doğrudan kameraya çevirin',
        now: now,
      );
    }

    final mouthOpenRatio = _calculateMouthOpenRatio(face);
    final mouthOpen = mouthOpenRatio >= _mouthOpenThreshold;
    final mouthRect = mouthOpen ? _getMouthRegion(face) : null;

    _PillPixelAnalysis? pillAnalysis;
    bool pillDetectedThisFrame = false;
    if (mouthRect != null) {
      pillAnalysis = _analyzeMouthRegion(image, mouthRect, inputImage.metadata?.rotation);
      pillDetectedThisFrame = pillAnalysis.confidence >= _pillConfidenceThreshold;
    }

    switch (_stage) {
      case _Stage.awaitingPill:
        return _handleAwaitingPill(face, mouthOpenRatio, mouthRect,
            pillAnalysis, pillDetectedThisFrame, now);
      case _Stage.awaitingDrink:
        return _handleAwaitingDrink(
            face, mouthOpenRatio, mouthRect, inputImage, now);
      case _Stage.awaitingReopen:
        return _handleAwaitingReopen(
            face, mouthOpenRatio, mouthRect, now);
      case _Stage.verifyingSwallow:
        return _handleVerifyingSwallow(face, mouthOpenRatio, mouthRect,
            pillAnalysis, pillDetectedThisFrame, now);
      case _Stage.done:
        return _emit(
          phase: _lastDonePhase,
          face: face,
          mouthOpenRatio: mouthOpenRatio,
          guidance: _lastDoneGuidance,
          now: now,
        );
    }
  }

  DetectionPhase _lastDonePhase = DetectionPhase.swallowConfirmed;
  String _lastDoneGuidance = '';

  PillOnTongueResult _handleAwaitingPill(
    Face face,
    double mouthOpenRatio,
    Rect? mouthRect,
    _PillPixelAnalysis? analysis,
    bool pillDetected,
    DateTime now,
  ) {
    if (mouthRect == null) {
      _consecutivePillFrames = 0;
      return _emit(
        phase: DetectionPhase.faceDetected,
        face: face,
        mouthOpenRatio: mouthOpenRatio,
        guidance: 'Adım 1: Ağzınızı açın',
        now: now,
      );
    }

    if (pillDetected) {
      _consecutivePillFrames++;
      _addToPositionBuffer(mouthRect);
      _lastSeenPillRegion = mouthRect;
    } else {
      _consecutivePillFrames = max(0, _consecutivePillFrames - 1);
    }

    final smoothed = _smoothedPosition();
    final stable = _consecutivePillFrames >= _requiredStableFrames;

    if (stable) {
      _stage = _Stage.awaitingDrink;
      _pillConfirmedAt = now;
      return _emit(
        phase: DetectionPhase.pillOnTongue,
        face: face,
        mouthOpenRatio: mouthOpenRatio,
        mouthRegion: mouthRect,
        pillConfidence: analysis?.confidence ?? 0.0,
        whitePixelCount: analysis?.whitePixels ?? 0,
        totalMouthPixels: analysis?.totalPixels ?? 0,
        guidance: 'Hap algılandı! Şimdi ağzınızı kapatın ve su için',
        smoothedPillRegion: smoothed,
        lastSeenPillRegion: _lastSeenPillRegion,
        now: now,
      );
    }

    return _emit(
      phase: DetectionPhase.mouthOpen,
      face: face,
      mouthOpenRatio: mouthOpenRatio,
      mouthRegion: mouthRect,
      pillConfidence: analysis?.confidence ?? 0.0,
      whitePixelCount: analysis?.whitePixels ?? 0,
      totalMouthPixels: analysis?.totalPixels ?? 0,
      guidance: _consecutivePillFrames > 0
          ? 'Hap algılanıyor... Sabit tutun ($_consecutivePillFrames/$_requiredStableFrames)'
          : 'Adım 2: Hapı dilinizin üstüne koyun',
      smoothedPillRegion: smoothed,
      lastSeenPillRegion: _lastSeenPillRegion,
      now: now,
    );
  }

  PillOnTongueResult _handleAwaitingDrink(
    Face face,
    double mouthOpenRatio,
    Rect? mouthRect,
    InputImage inputImage,
    DateTime now,
  ) {
    final elapsed = now.difference(_pillConfirmedAt ?? now);

    if (elapsed > _drinkTimeoutAfter) {
      _stage = _Stage.done;
      _lastDonePhase = DetectionPhase.timeoutExpired;
      _lastDoneGuidance = 'Süre doldu — işlem iptal edildi';
      return _emit(
        phase: DetectionPhase.timeoutExpired,
        face: face,
        mouthOpenRatio: mouthOpenRatio,
        guidance: _lastDoneGuidance,
        lastSeenPillRegion: _lastSeenPillRegion,
        now: now,
      );
    }

    // Throttled image labeling
    if (!_isLabeling &&
        now.difference(_lastLabelingRun) >= _labelingInterval) {
      _lastLabelingRun = now;
      _isLabeling = true;
      _imageLabeler.processImage(inputImage).then((labels) {
        if (kDebugMode && labels.isNotEmpty) {
          final top = labels.take(5).map((l) =>
              '${l.label}(${(l.confidence * 100).toStringAsFixed(0)})').join(', ');
          debugPrint('[PillDetection] labels: $top');
        }
        bool frameHasDrink = false;
        for (final l in labels) {
          if (l.confidence < _drinkConfidenceThreshold) continue;
          final lower = l.label.toLowerCase();
          if (_drinkLabelSubstrings.any((s) => lower.contains(s))) {
            _detectedDrinkLabel = l.label;
            frameHasDrink = true;
            break;
          }
        }
        if (frameHasDrink) {
          _drinkLabelHits++;
          if (_drinkLabelHits >= _requiredDrinkHits &&
              _stage == _Stage.awaitingDrink) {
            _stage = _Stage.awaitingReopen;
          }
        } else {
          _drinkLabelHits = max(0, _drinkLabelHits - 1);
        }
      }).whenComplete(() => _isLabeling = false);
    }

    final String guidance;
    if (_drinkLabelHits > 0) {
      guidance = 'Bardak algılanıyor... '
          'sabit tutun ($_drinkLabelHits/$_requiredDrinkHits)';
    } else if (elapsed > _drinkWarningAfter) {
      guidance = 'Lütfen su için '
          '(kalan süre: ${(_drinkTimeoutAfter - elapsed).inSeconds}s)';
    } else if (mouthOpenRatio >= _mouthOpenThreshold) {
      guidance = 'Adım 3: Ağzınızı kapatın ve su için';
    } else {
      guidance = 'Adım 4: Bardak/şişe ile su için';
    }

    return _emit(
      phase: DetectionPhase.mouthClosedWithPill,
      face: face,
      mouthOpenRatio: mouthOpenRatio,
      mouthRegion: mouthRect,
      guidance: guidance,
      lastSeenPillRegion: _lastSeenPillRegion,
      now: now,
    );
  }

  PillOnTongueResult _handleAwaitingReopen(
    Face face,
    double mouthOpenRatio,
    Rect? mouthRect,
    DateTime now,
  ) {
    final mouthOpen = mouthOpenRatio >= _mouthOpenThreshold;
    if (mouthOpen) {
      _stage = _Stage.verifyingSwallow;
      _swallowVerifyCounter = 0;
      _pillSeenInVerify = false;
      return _emit(
        phase: DetectionPhase.mouthReopened,
        face: face,
        mouthOpenRatio: mouthOpenRatio,
        mouthRegion: mouthRect,
        guidance: 'Yutma kontrol ediliyor...',
        lastSeenPillRegion: _lastSeenPillRegion,
        now: now,
      );
    }

    return _emit(
      phase: DetectionPhase.drinking,
      face: face,
      mouthOpenRatio: mouthOpenRatio,
      guidance: 'İçme algılandı (${_detectedDrinkLabel ?? "?"}) — '
          'Adım 5: Yuttuktan sonra ağzınızı tekrar açın',
      lastSeenPillRegion: _lastSeenPillRegion,
      detectedDrinkLabel: _detectedDrinkLabel,
      now: now,
    );
  }

  PillOnTongueResult _handleVerifyingSwallow(
    Face face,
    double mouthOpenRatio,
    Rect? mouthRect,
    _PillPixelAnalysis? analysis,
    bool pillDetected,
    DateTime now,
  ) {
    if (mouthRect == null || mouthOpenRatio < _mouthOpenThreshold) {
      // Mouth closed again — keep waiting until reopened
      return _emit(
        phase: DetectionPhase.mouthReopened,
        face: face,
        mouthOpenRatio: mouthOpenRatio,
        guidance: 'Ağzınızı açık tutun (yutma kontrol ediliyor)',
        lastSeenPillRegion: _lastSeenPillRegion,
        now: now,
      );
    }

    // Gate the verify counter on TWO stronger signals:
    //   (a) mouth must be visibly EMPTY — fewer than 2% bright pixels in
    //       the mouth region. Just "no high-confidence pill detected"
    //       is too lenient: it accepted an open-and-close-empty-mouth
    //       loop because brief openings never produce bright clusters.
    //   (b) mouth must be CLEARLY open (≥ 1.3× the open threshold), not
    //       borderline. Borderline frames produced false confirms when
    //       the user briefly parted lips without truly showing the
    //       inside of the mouth.
    final whiteRatio = (analysis != null && analysis.totalPixels > 0)
        ? analysis.whitePixels / analysis.totalPixels
        : 1.0; // unknown → treat as not-empty
    final mouthClearlyEmpty = whiteRatio < _emptyMouthMaxRatio;
    final mouthClearlyOpen = mouthOpenRatio >= _mouthOpenThreshold * 1.3;

    if (!mouthClearlyOpen) {
      // Don't increment — wait for the user to actually open wide.
      return _emit(
        phase: DetectionPhase.mouthReopened,
        face: face,
        mouthOpenRatio: mouthOpenRatio,
        mouthRegion: mouthRect,
        pillConfidence: analysis?.confidence ?? 0.0,
        guidance: 'Ağzınızı daha geniş açın (yutma kontrolü)',
        lastSeenPillRegion: _lastSeenPillRegion,
        now: now,
      );
    }

    if (!mouthClearlyEmpty) {
      // Bright stuff in mouth → either pill still there or teeth/glare.
      // Mark seen, do NOT increment toward swallowConfirmed.
      _pillSeenInVerify = true;
      return _emit(
        phase: DetectionPhase.mouthReopened,
        face: face,
        mouthOpenRatio: mouthOpenRatio,
        mouthRegion: mouthRect,
        pillConfidence: analysis?.confidence ?? 0.0,
        guidance: 'Ağzınızda parlak bir şey görünüyor — '
            'dilinizi gösterip ağzınızın boş olduğunu kanıtlayın',
        lastSeenPillRegion: _lastSeenPillRegion,
        now: now,
      );
    }

    // Mouth is wide open AND visibly empty for this frame.
    _swallowVerifyCounter++;
    if (pillDetected) _pillSeenInVerify = true;

    if (_swallowVerifyCounter >= _swallowVerifyFrames) {
      if (_pillSeenInVerify) {
        // Pill still seen at any point during verification — fail and
        // require another close+reopen cycle.
        _stage = _Stage.awaitingReopen;
        _swallowVerifyCounter = 0;
        _pillSeenInVerify = false;
        return _emit(
          phase: DetectionPhase.swallowFailed,
          face: face,
          mouthOpenRatio: mouthOpenRatio,
          mouthRegion: mouthRect,
          pillConfidence: analysis?.confidence ?? 0.0,
          guidance: 'Hap hâlâ ağzınızda — yutmaya çalışın, '
              'sonra ağzınızı kapatıp tekrar açın',
          lastSeenPillRegion: _lastSeenPillRegion,
          now: now,
        );
      }
      _stage = _Stage.done;
      _lastDonePhase = DetectionPhase.swallowConfirmed;
      _lastDoneGuidance = 'Hap yutuldu! ✓';
      return _emit(
        phase: _lastDonePhase,
        face: face,
        mouthOpenRatio: mouthOpenRatio,
        mouthRegion: mouthRect,
        pillConfidence: analysis?.confidence ?? 0.0,
        guidance: _lastDoneGuidance,
        lastSeenPillRegion: _lastSeenPillRegion,
        now: now,
      );
    }

    return _emit(
      phase: DetectionPhase.mouthReopened,
      face: face,
      mouthOpenRatio: mouthOpenRatio,
      mouthRegion: mouthRect,
      pillConfidence: analysis?.confidence ?? 0.0,
      guidance: 'Yutma kontrol ediliyor... '
          '($_swallowVerifyCounter/$_swallowVerifyFrames)',
      lastSeenPillRegion: _lastSeenPillRegion,
      now: now,
    );
  }

  double? _calculatePillToLipDistance(Face? face, Rect? pillRegion) {
    if (face == null || pillRegion == null) return null;
    final faceHeight = face.boundingBox.height;
    if (faceHeight <= 0) return null;

    final upperLipBottom = face.contours[FaceContourType.upperLipBottom];
    final lowerLipTop = face.contours[FaceContourType.lowerLipTop];
    if (upperLipBottom == null || lowerLipTop == null) return null;
    if (upperLipBottom.points.isEmpty || lowerLipTop.points.isEmpty) return null;

    double ux = 0, uy = 0;
    for (final p in upperLipBottom.points) { ux += p.x; uy += p.y; }
    ux /= upperLipBottom.points.length;
    uy /= upperLipBottom.points.length;

    double lx = 0, ly = 0;
    for (final p in lowerLipTop.points) { lx += p.x; ly += p.y; }
    lx /= lowerLipTop.points.length;
    ly /= lowerLipTop.points.length;

    final lipCenterX = (ux + lx) / 2;
    final lipCenterY = (uy + ly) / 2;
    final pillCenterX = pillRegion.center.dx;
    final pillCenterY = pillRegion.center.dy;

    final dx = pillCenterX - lipCenterX;
    final dy = pillCenterY - lipCenterY;
    return sqrt(dx * dx + dy * dy) / faceHeight;
  }

  bool _isFaceFrontal(Face? face) {
    if (face == null) return false;
    final yaw = face.headEulerAngleY;
    final pitch = face.headEulerAngleX;
    return (yaw == null || yaw.abs() <= _maxFrontalAngle) &&
        (pitch == null || pitch.abs() <= _maxFrontalAngle);
  }

  PillOnTongueResult _emit({
    required DetectionPhase phase,
    Face? face,
    double mouthOpenRatio = 0.0,
    Rect? mouthRegion,
    double pillConfidence = 0.0,
    int whitePixelCount = 0,
    int totalMouthPixels = 0,
    required String guidance,
    Rect? smoothedPillRegion,
    Rect? lastSeenPillRegion,
    String? detectedDrinkLabel,
    required DateTime now,
  }) {
    return PillOnTongueResult(
      phase: phase,
      face: face,
      mouthOpenRatio: mouthOpenRatio,
      mouthRegion: mouthRegion,
      pillConfidence: pillConfidence,
      whitePixelCount: whitePixelCount,
      totalMouthPixels: totalMouthPixels,
      guidance: guidance,
      timestamp: now,
      smoothedPillRegion: smoothedPillRegion,
      lastSeenPillRegion: lastSeenPillRegion,
      detectedDrinkLabel: detectedDrinkLabel ?? _detectedDrinkLabel,
      pillToLipDistance: _calculatePillToLipDistance(face, mouthRegion ?? lastSeenPillRegion),
      isFaceFrontal: _isFaceFrontal(face),
    );
  }

  void _addToPositionBuffer(Rect position) {
    _positionBuffer.add(position);
    if (_positionBuffer.length > _positionBufferSize) {
      _positionBuffer.removeAt(0);
    }
  }

  Rect? _smoothedPosition() {
    if (_positionBuffer.isEmpty) return null;
    double l = 0, t = 0, r = 0, b = 0;
    for (final rect in _positionBuffer) {
      l += rect.left;
      t += rect.top;
      r += rect.right;
      b += rect.bottom;
    }
    final n = _positionBuffer.length;
    return Rect.fromLTRB(l / n, t / n, r / n, b / n);
  }

  double _calculateMouthOpenRatio(Face face) {
    final upperLipBottom = face.contours[FaceContourType.upperLipBottom];
    final lowerLipTop = face.contours[FaceContourType.lowerLipTop];

    if (upperLipBottom == null || lowerLipTop == null) return 0.0;
    if (upperLipBottom.points.isEmpty || lowerLipTop.points.isEmpty) return 0.0;

    final faceHeight = face.boundingBox.height;
    if (faceHeight <= 0) return 0.0;

    final upperSorted = List<Point<int>>.from(upperLipBottom.points)
      ..sort((a, b) => a.x.compareTo(b.x));
    final lowerSorted = List<Point<int>>.from(lowerLipTop.points)
      ..sort((a, b) => a.x.compareTo(b.x));

    final sampleCount = min(upperSorted.length, lowerSorted.length);
    if (sampleCount == 0) return 0.0;

    final gaps = <double>[];
    for (int i = 0; i < sampleCount; i++) {
      final uIdx = (i * (upperSorted.length - 1)) ~/ max(1, sampleCount - 1);
      final lIdx = (i * (lowerSorted.length - 1)) ~/ max(1, sampleCount - 1);
      final gap = (lowerSorted[lIdx].y - upperSorted[uIdx].y).abs().toDouble();
      gaps.add(gap);
    }

    gaps.sort();
    final medianGap = gaps[gaps.length ~/ 2];
    return medianGap / faceHeight;
  }

  Rect? _getMouthRegion(Face face) {
    final upperLipTop = face.contours[FaceContourType.upperLipTop];
    final lowerLipBottom = face.contours[FaceContourType.lowerLipBottom];

    if (upperLipTop == null || lowerLipBottom == null) return null;
    if (upperLipTop.points.isEmpty || lowerLipBottom.points.isEmpty) return null;

    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;

    for (final p in [...upperLipTop.points, ...lowerLipBottom.points]) {
      minX = min(minX, p.x.toDouble());
      minY = min(minY, p.y.toDouble());
      maxX = max(maxX, p.x.toDouble());
      maxY = max(maxY, p.y.toDouble());
    }

    final w = maxX - minX;
    final h = maxY - minY;
    final insetX = w * 0.15;
    final insetY = h * 0.1;

    return Rect.fromLTRB(
      minX + insetX,
      minY + insetY,
      maxX - insetX,
      maxY - insetY,
    );
  }

  _PillPixelAnalysis _analyzeMouthRegion(
    CameraImage image,
    Rect mouthRect,
    InputImageRotation? rotation,
  ) {
    if (image.planes.isEmpty) {
      return _PillPixelAnalysis(0, 0, 0.0);
    }

    final yPlane = image.planes.first.bytes;
    final imgW = image.width;
    final imgH = image.height;
    final bytesPerRow = image.planes.first.bytesPerRow;

    final left = mouthRect.left.toInt().clamp(0, imgW - 1);
    final top = mouthRect.top.toInt().clamp(0, imgH - 1);
    final right = mouthRect.right.toInt().clamp(0, imgW - 1);
    final bottom = mouthRect.bottom.toInt().clamp(0, imgH - 1);

    if (right <= left || bottom <= top) {
      return _PillPixelAnalysis(0, 0, 0.0);
    }

    int whitePixels = 0;
    int totalPixels = 0;

    for (int y = top; y < bottom; y += 2) {
      for (int x = left; x < right; x += 2) {
        final idx = y * bytesPerRow + x;
        if (idx >= 0 && idx < yPlane.length) {
          totalPixels++;
          final brightness = yPlane[idx];
          if (brightness >= _brightnessThreshold) {
            whitePixels++;
          }
        }
      }
    }

    if (totalPixels == 0) {
      return _PillPixelAnalysis(0, 0, 0.0);
    }

    final ratio = whitePixels / totalPixels;
    double confidence;
    if (ratio >= _pillPixelThreshold && ratio <= 0.45) {
      confidence = ((ratio - _pillPixelThreshold) / (0.30 - _pillPixelThreshold))
          .clamp(0.0, 1.0);
    } else if (ratio > 0.45) {
      confidence = 0.2;
    } else {
      confidence = 0.0;
    }

    return _PillPixelAnalysis(whitePixels, totalPixels, confidence);
  }

  Future<void> dispose() async {
    await _faceDetector.close();
    await _imageLabeler.close();
  }
}

class _PillPixelAnalysis {
  final int whitePixels;
  final int totalPixels;
  final double confidence;
  _PillPixelAnalysis(this.whitePixels, this.totalPixels, this.confidence);
}