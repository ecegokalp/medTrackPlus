import 'dart:math' show Point;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'package:medTrackPlus/beta/core/interfaces/cv_processor.dart';
import 'package:medTrackPlus/beta/cv/frame_throttler.dart';
import 'package:medTrackPlus/beta/cv/pill_tracker.dart';
import 'package:medTrackPlus/beta/mlkit_test/face_detection_service.dart';
import 'package:medTrackPlus/beta/mlkit_test/pill_detection_service.dart';
import 'package:medTrackPlus/beta/models/cv_frame_data.dart';

/// Production CVProcessor that unifies face detection, pill detection,
/// pill tracking and frame throttling behind a single processFrame() call
/// returning a complete CVFrameData.
///
/// Pipeline per frame:
///   1. FrameThrottler decides whether this frame is processed at all.
///      Skipped frames return the previous CVFrameData with fromCache=true.
///   2. Build InputImage from the camera buffer (NV21 only).
///   3. FaceDetectionService runs ONCE — its Face is shared with the pill
///      service so we don't pay for two face-detection passes per frame.
///   4. PillOnTongueService.processFrameWithFace advances the verification
///      state machine using the pre-detected face.
///   5. PillTracker absorbs the new mouth-region observation (when the pill
///      is confidently detected) and exposes a smoothed Rect.
///   6. Everything is folded into a CVFrameData carrying phase/guidance/
///      smoothed/lastSeen rects and the end-to-end processing latency.
///
/// Latency target: < 100ms on a modern phone. Observed cost is dominated
/// by ML Kit's face detector (~20-40ms) plus the pill pixel scan (< 5ms).
class MLKitCVProcessor implements CVProcessor {
  MLKitCVProcessor({
    required this.rotation,
    FaceDetectionService? faceService,
    PillOnTongueService? pillService,
    PillTracker? tracker,
    FrameThrottler? throttler,
  })  : _faceService = faceService ?? FaceDetectionService(),
        _pillService = pillService ?? PillOnTongueService(),
        _tracker = tracker ?? PillTracker(),
        _throttler = throttler ?? FrameThrottler();

  final InputImageRotation rotation;
  final FaceDetectionService _faceService;
  final PillOnTongueService _pillService;
  final PillTracker _tracker;
  final FrameThrottler _throttler;

  static const double _pillConfidenceThreshold = 0.4;

  CVFrameData _lastResult = CVFrameData.empty();
  DetectionPhase _lastPhase = DetectionPhase.noFace;

  /// Most recent verification phase (matches the CVFrameData.phase field
  /// of the latest non-cached result).
  DetectionPhase get currentPhase => _lastPhase;

  /// True while the pill service is filling its stability buffer — the
  /// throttler uses this to switch to per-frame detection.
  bool get isTracking => _pillService.isTracking;

  @override
  Future<CVFrameData> processFrame(CameraImage image) async {
    final shouldProcess = _throttler.shouldProcess(
      _lastPhase,
      isTracking: _pillService.isTracking,
    );

    if (!shouldProcess) {
      return _lastResult.asCached();
    }

    final sw = Stopwatch()..start();

    final inputImage = _buildInputImage(image);
    if (inputImage == null) {
      sw.stop();
      return _lastResult.asCached();
    }

    final FaceDetectionResult faceResult;
    final PillOnTongueResult pillResult;
    try {
      faceResult = await _faceService.processImage(inputImage);
      pillResult = await _pillService.processFrameWithFace(
        image,
        inputImage,
        faceResult.face,
      );
    } catch (e) {
      sw.stop();
      if (kDebugMode) {
        debugPrint('[MLKitCVProcessor] processFrame error: $e');
      }
      return _lastResult.asCached();
    }

    final pillDetected = pillResult.pillConfidence >= _pillConfidenceThreshold;
    if (pillDetected && pillResult.mouthRegion != null) {
      _tracker.add(pillResult.mouthRegion!);
    }

    sw.stop();
    final latencyMs = sw.elapsedMicroseconds / 1000.0;
    if (kDebugMode && latencyMs > 100.0) {
      debugPrint(
        '[MLKitCVProcessor] SLOW frame: '
        '${latencyMs.toStringAsFixed(1)}ms phase=${pillResult.phase.name} '
        'skip=${_throttler.currentSkipFactor}',
      );
    }

    final smoothed = _tracker.smoothed;
    final lastSeen = _tracker.lastSeen ?? pillResult.lastSeenPillRegion;

    final data = CVFrameData(
      pillDetected: pillDetected,
      pillConfidence: pillResult.pillConfidence,
      pillBoundingBox: smoothed ?? pillResult.mouthRegion ?? Rect.zero,
      faceDetected: faceResult.faceDetected,
      lipContour: _extractLipContour(faceResult),
      mouthOpenRatio: faceResult.mouthOpenRatio,
      faceBoundingBox: faceResult.face?.boundingBox ?? Rect.zero,
      headYaw: faceResult.headYaw,
      headPitch: faceResult.headPitch,
      headRoll: faceResult.headRoll,
      isFaceFrontal: faceResult.isFaceFrontal,
      timestamp: pillResult.timestamp,
      phase: pillResult.phase,
      guidance: pillResult.guidance,
      smoothedPillRegion: smoothed,
      lastSeenPillRegion: lastSeen,
      latencyMs: latencyMs,
      fromCache: false,
    );

    _lastResult = data;
    _lastPhase = pillResult.phase;
    return data;
  }

  /// Drops tracker/throttler/state — restarts the verification workflow.
  void reset() {
    _tracker.reset();
    _throttler.reset();
    _pillService.reset();
    _lastResult = CVFrameData.empty();
    _lastPhase = DetectionPhase.noFace;
  }

  @override
  Future<void> dispose() async {
    await _faceService.dispose();
    await _pillService.dispose();
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

  List<Offset> _extractLipContour(FaceDetectionResult faceResult) {
    final pts = <Offset>[];
    void addAll(List<Point<int>>? src) {
      if (src == null) return;
      for (final p in src) {
        pts.add(Offset(p.x.toDouble(), p.y.toDouble()));
      }
    }

    addAll(faceResult.upperLipTop?.points);
    addAll(faceResult.upperLipBottom?.points);
    addAll(faceResult.lowerLipTop?.points);
    addAll(faceResult.lowerLipBottom?.points);
    return pts;
  }
}