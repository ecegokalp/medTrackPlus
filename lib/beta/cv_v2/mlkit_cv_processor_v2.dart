import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'package:medTrackPlus/beta/cv_v2/cv_v2_config.dart';
import 'package:medTrackPlus/beta/cv_v2/cv_v2_metrics.dart';
import 'package:medTrackPlus/beta/cv_v2/face_detection_service_v2.dart';
import 'package:medTrackPlus/beta/cv_v2/pill_detection_service_v2.dart';
import 'package:medTrackPlus/beta/cv_v2/pill_tracker_v2.dart';
import 'package:medTrackPlus/beta/mlkit_test/pill_detection_service.dart'
    show DetectionPhase;
import 'package:medTrackPlus/beta/models/cv_frame_data.dart';

/// Output of one V2 processor pass: the rich V2 result plus a
/// CVFrameData-compatible view for the existing AccuracyScoringEngine.
class CvV2FrameOutput {
  final PillResultV2 result;
  final CVFrameData frameData;
  final bool fromCache;
  const CvV2FrameOutput(this.result, this.frameData, {this.fromCache = false});
}

/// V2 unified processor: ONE face-detector pass per frame shared between
/// mouth geometry and pill analysis, EMA pill tracking, phase-based +
/// latency-adaptive throttling, and full latency/fps accounting.
class MLKitCVProcessorV2 {
  MLKitCVProcessorV2({required this.rotation, CvV2Config? config})
      : config = config ?? CvV2Config() {
    _faceService = FaceDetectionServiceV2(this.config);
    _pillService = PillDetectionServiceV2(this.config);
  }

  final InputImageRotation rotation;
  final CvV2Config config;
  late final FaceDetectionServiceV2 _faceService;
  late final PillDetectionServiceV2 _pillService;
  final PillTrackerV2 _tracker = PillTrackerV2();

  CvV2FrameOutput? _last;
  DetectionPhase _lastPhase = DetectionPhase.noFace;

  // Throttling
  int _tick = 0;
  int _currentSkip = 1;

  // Latency / fps stats
  final List<double> _latencyWindow = [];
  double _sumLatency = 0;
  int _latencySamples = 0;
  double _maxLatency = 0;
  int _processedFrames = 0;
  int _cachedFrames = 0;
  DateTime? _fpsWindowStart;
  int _fpsWindowFrames = 0;
  double _fps = 0;

  double get avgLatencyMs =>
      _latencySamples == 0 ? 0 : _sumLatency / _latencySamples;
  double get maxLatencyMs => _maxLatency;
  int get processedFrames => _processedFrames;
  int get cachedFrames => _cachedFrames;
  int get currentSkipFactor => _currentSkip;
  double get fps => _fps;
  int get trackerRejectedCount => _tracker.rejectedCount;

  Future<CvV2FrameOutput?> processFrame(CameraImage image) async {
    _tick++;
    _trackFps();

    _currentSkip = _skipForPhase(_lastPhase, _pillService.isTracking);
    if (_tick % _currentSkip != 0) {
      _cachedFrames++;
      final last = _last;
      if (last == null) return null;
      return CvV2FrameOutput(last.result, last.frameData.asCached(),
          fromCache: true);
    }

    final inputImage = _buildInputImage(image);
    if (inputImage == null) return _last;

    final sw = Stopwatch()..start();
    final FaceV2Result faceResult;
    final PillResultV2 pillResult;
    try {
      faceResult = await _faceService.processImage(inputImage);
      pillResult =
          await _pillService.processFrameWithFace(image, inputImage, faceResult);
    } catch (e) {
      if (kDebugMode) debugPrint('[CVProcessorV2] error: $e');
      return _last;
    }
    sw.stop();
    final latencyMs = sw.elapsedMicroseconds / 1000.0;
    _recordLatency(latencyMs);
    _processedFrames++;

    final m = pillResult.metrics;
    final pillDetected =
        m.pillConfidenceEma >= config.pillConfidenceThreshold &&
            m.pillConfidence > 0;
    if (pillDetected && pillResult.pillBlobRegion != null) {
      _tracker.add(pillResult.pillBlobRegion!);
    }

    final metricsWithPerf = m.withPerf(
      latencyMs: latencyMs,
      avgLatencyMs: avgLatencyMs,
      fps: _fps,
      skipFactor: _currentSkip,
    );

    final enriched = PillResultV2(
      phase: pillResult.phase,
      face: pillResult.face,
      guidance: pillResult.guidance,
      timestamp: pillResult.timestamp,
      mouthRegion: pillResult.mouthRegion,
      pillBlobRegion: pillResult.pillBlobRegion,
      smoothedPillRegion: _tracker.smoothed,
      lastSeenPillRegion:
          _tracker.lastSeen ?? pillResult.lastSeenPillRegion,
      metrics: metricsWithPerf,
    );

    final frameData = CVFrameData(
      pillDetected: pillDetected,
      pillConfidence: m.pillConfidenceEma,
      pillBoundingBox: _tracker.smoothed ??
          pillResult.pillBlobRegion ??
          pillResult.mouthRegion ??
          Rect.zero,
      faceDetected: faceResult.faceDetected,
      lipContour: _extractLipContour(faceResult.face),
      // Keep rawRatio here so CVFrameData.isMouthOpen (>0.06 on this field)
      // and the scoring engine stay V1-comparable.
      mouthOpenRatio: m.mouthRatioRaw,
      faceBoundingBox: faceResult.face?.boundingBox ?? Rect.zero,
      headYaw: m.yaw,
      headPitch: m.pitch,
      headRoll: m.roll,
      isFaceFrontal: !m.yawExceeded && !m.pitchExceeded,
      pillToLipDistance: m.pillToLipDistance,
      timestamp: pillResult.timestamp,
      phase: pillResult.phase,
      guidance: pillResult.guidance,
      smoothedPillRegion: _tracker.smoothed,
      lastSeenPillRegion: enriched.lastSeenPillRegion,
      latencyMs: latencyMs,
      fromCache: false,
    );

    final out = CvV2FrameOutput(enriched, frameData);
    _last = out;
    _lastPhase = pillResult.phase;
    return out;
  }

  void reset() {
    _tracker.reset();
    _pillService.reset();
    _last = null;
    _lastPhase = DetectionPhase.noFace;
    _tick = 0;
    _currentSkip = 1;
    _latencyWindow.clear();
    _sumLatency = 0;
    _latencySamples = 0;
    _maxLatency = 0;
    _processedFrames = 0;
    _cachedFrames = 0;
    _fpsWindowStart = null;
    _fpsWindowFrames = 0;
    _fps = 0;
  }

  Future<void> dispose() async {
    await _faceService.dispose();
    await _pillService.dispose();
  }

  // ── Internals ────────────────────────────────────────────────────────

  void _recordLatency(double ms) {
    _sumLatency += ms;
    _latencySamples++;
    if (ms > _maxLatency) _maxLatency = ms;
    _latencyWindow.add(ms);
    if (_latencyWindow.length > 20) _latencyWindow.removeAt(0);
  }

  double get _rollingAvgLatency {
    if (_latencyWindow.isEmpty) return 0;
    double s = 0;
    for (final v in _latencyWindow) {
      s += v;
    }
    return s / _latencyWindow.length;
  }

  void _trackFps() {
    final now = DateTime.now();
    _fpsWindowStart ??= now;
    _fpsWindowFrames++;
    final elapsed = now.difference(_fpsWindowStart!).inMilliseconds;
    if (elapsed >= 1000) {
      _fps = _fpsWindowFrames * 1000.0 / elapsed;
      _fpsWindowStart = now;
      _fpsWindowFrames = 0;
    }
  }

  int _skipForPhase(DetectionPhase phase, bool isTracking) {
    int base;
    switch (phase) {
      case DetectionPhase.pillOnTongue:
      case DetectionPhase.mouthClosedWithPill:
      case DetectionPhase.drinking:
      case DetectionPhase.mouthReopened:
      case DetectionPhase.swallowConfirmed:
      case DetectionPhase.swallowFailed:
      case DetectionPhase.timeoutExpired:
        base = 2;
        break;
      case DetectionPhase.mouthOpen:
        base = isTracking ? 1 : 5;
        break;
      case DetectionPhase.noFace:
      case DetectionPhase.faceDetected:
        base = 5;
        break;
    }
    // Latency-adaptive: over budget → skip one extra frame (never during
    // the critical tracking-to-lip window).
    if (base > 1 && _rollingAvgLatency > config.latencyBudgetMs) {
      base += 1;
    }
    return base;
  }

  InputImage? _buildInputImage(CameraImage image) {
    if (image.format.group != ImageFormatGroup.nv21) return null;
    if (image.planes.isEmpty) return null;
    return InputImage.fromBytes(
      bytes: image.planes.first.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  List<Offset> _extractLipContour(Face? face) {
    if (face == null) return const [];
    final pts = <Offset>[];
    for (final type in [
      FaceContourType.upperLipTop,
      FaceContourType.upperLipBottom,
      FaceContourType.lowerLipTop,
      FaceContourType.lowerLipBottom,
    ]) {
      final contour = face.contours[type];
      if (contour == null) continue;
      for (final p in contour.points) {
        pts.add(Offset(p.x.toDouble(), p.y.toDouble()));
      }
    }
    return pts;
  }
}
