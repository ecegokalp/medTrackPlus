import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_quick_video_encoder/flutter_quick_video_encoder.dart';
import 'package:path_provider/path_provider.dart';

import 'package:camera/camera.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:medTrackPlus/beta/enums/app_mode.dart';
import 'package:medTrackPlus/beta/mlkit_test/pill_detection_service.dart';
import 'package:medTrackPlus/beta/mlkit_test/pill_painter.dart';
import 'package:medTrackPlus/beta/verification_screen/frame_profiler.dart';
import 'package:medTrackPlus/beta/models/verification_result.dart' as vr;
import 'package:medTrackPlus/beta/providers/mode_provider.dart';
import 'package:medTrackPlus/beta/verification/accuracy_scoring_engine.dart';
import 'package:medTrackPlus/beta/verification/cloud_verification_service.dart';
import 'package:medTrackPlus/main.dart' show AppColors;
import 'package:medTrackPlus/services/consent_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';
import 'package:video_compress/video_compress.dart';

/// Unified medication verification screen.
class VerificationScreen extends StatefulWidget {
  final int sectionIndex;
  final AppMode? modeOverride;
  final String? macAddress;
  const VerificationScreen({
    super.key,
    this.sectionIndex = 0,
    this.modeOverride,
    this.macAddress,
  });
  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen> {
  CameraController? _controller;
  bool _isCameraInitialized = false;
  bool _isFrontCamera = true;
  InputImageRotation _rotation = InputImageRotation.rotation0deg;
  bool _torchOn = false;

  final PillOnTongueService _service = PillOnTongueService();
  PillOnTongueResult _lastResult = PillOnTongueResult.empty();
  Size _imageSize = const Size(480, 640);
  bool _isProcessing = false;
  /// Wall-clock timestamp of the last frame we processed. Used to detect when
  /// the camera plugin pauses the image stream during recording so we can
  /// hide the (now stale) PillPainter overlay.
  DateTime? _lastFrameTime;

  int _frameCount = 0;
  int _facePresentFrames = 0;
  int _mouthOpenFrames = 0;
  int _pillOnTongueFrames = 0;
  DetectionPhase _highestPhaseReached = DetectionPhase.noFace;

  // Adaptive frame skip — per-phase detection rate:
  //   waitingForPill (noFace / faceDetected)     → every 5th frame
  //   trackingToLip  (mouthOpen + tracking pill) → every frame
  //   pillDetected   (pillOnTongue/closedW.pill) → every 2nd frame
  //   mouthCheckPrompt (drinking/reopen/...)     → every 2nd frame
  int _phaseFrameTick = 0;
  final FrameProfiler _profiler = FrameProfiler();

  bool _consentEnabled = false;
  bool _recording = false;
  String? _recordedLocalPath;
  Timer? _recordingTimeoutTimer;
  DateTime? _recordingStartedAt;
  static const Duration _recordingMaxDuration = Duration(seconds: 30);

  // ── Software video encoder (replaces controller.startVideoRecording) ─────
  // We never call MediaRecorder. Instead, when "recording" is on we forward
  // every Nth frame from the imageStream into FlutterQuickVideoEncoder. This
  // way detection never pauses (no Camera2 surface conflict) AND a real MP4
  // is built from the EXACT frames detection sees.
  bool _encoderActive = false;
  bool _encoderBusy = false;
  bool _encoderConfigured = false;
  int _encodedFrameCount = 0;
  DateTime? _lastEncodedFrameAt;
  // Output 10 fps → file size manageable, plenty for review.
  static const Duration _encoderFrameInterval =
      Duration(milliseconds: 100);
  String? _encoderOutputPath;
  int _encoderWidth = 0;
  int _encoderHeight = 0;
  // Source buffer dimensions (BEFORE rotation) — needed for the rotated
  // copy step inside _encodeFrame.
  int _srcWidth = 0;
  int _srcHeight = 0;
  // 0/90/180/270 — rotation applied during encoding so the saved MP4 is
  // portrait, matching how the user holds the phone.
  int _encoderRotationDeg = 0;
  // Set true the moment DetectionPhase.swallowConfirmed fires. We do NOT
  // stop recording at that moment — the recording always runs for the full
  // _recordingMaxDuration so reviewers see the entire 30-second process.
  bool _detectionSucceeded = false;
  // True once _onTimeout has begun finalizing (stopRecording / saveAndUpload).
  // Blocks the mouth-open trigger from spawning a SECOND _startRecording
  // during the brief window before _completed gets set. Without this guard
  // the second encoder reopens the SAME .mp4 path while video_compress is
  // still reading from it, which crashes the MediaMetadataRetriever inside
  // video_compress (setDataSource fails with -22).
  bool _finalizing = false;

  bool _uploading = false;
  double _uploadProgress = 0.0;
  String _uploadStatus = '';

  // Result info shown in the centered completion modal:
  String? _completionFootageUrl;
  String? _completionStoragePath;
  String? _completionUploadError;
  double _completionScore = 0.0;
  String _completionClassification = 'unknown';

  final String _sessionId = const Uuid().v4();
  bool _videoUploaded = false;
  bool _completed = false;
  String? _statusMessage;

  final CloudVerificationService _cloudService = CloudVerificationService();
  final AccuracyScoringEngine _scoringEngine = AccuracyScoringEngine();

  AppMode get _appMode => widget.modeOverride ?? modeProvider.value;
  String get _deviceId =>
      widget.macAddress ??
      FirebaseAuth.instance.currentUser?.uid ??
      'unknown_device';

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    _consentEnabled = await ConsentService.isVideoConsentEnabled();
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (mounted) setState(() => _lastResult = PillOnTongueResult.empty());
      return;
    }
    await _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;
      final front =
          cameras.where((c) => c.lensDirection == CameraLensDirection.front);
      final ordered = [...front, ...cameras].toSet().toList();
      for (final camera in ordered) {
        try {
          final controller = CameraController(
            camera,
            ResolutionPreset.medium,
            enableAudio: false,
            imageFormatGroup: ImageFormatGroup.nv21,
          );
          await controller.initialize().timeout(const Duration(seconds: 10));
          if (!mounted) {
            await controller.dispose();
            return;
          }
          _controller = controller;
          _isFrontCamera = camera.lensDirection == CameraLensDirection.front;
          _rotation = InputImageRotationValue.fromRawValue(
                  camera.sensorOrientation) ??
              InputImageRotation.rotation0deg;
          if (mounted) setState(() => _isCameraInitialized = true);
          await _controller!.startImageStream(_onFrame);
          return;
        } catch (e) {
          debugPrint('[VerificationScreen] Camera ${camera.name} failed: $e');
        }
      }
    } catch (e) {
      debugPrint('[VerificationScreen] Camera init error: $e');
    }
  }

  /// Maps the verification flow's current phase to a skip factor: 1 means
  /// process every frame, N means every Nth frame. Decision is based on the
  /// LAST result we observed (so the very first frame after a phase
  /// transition may still use the previous skip — acceptable).
  int _skipForPhase(DetectionPhase phase, bool isTracking) {
    switch (phase) {
      // pillDetected — pill confirmed in mouth.
      case DetectionPhase.pillOnTongue:
      case DetectionPhase.mouthClosedWithPill:
        return 2;
      // mouthCheckPrompt — drink / reopen / swallow verification window.
      case DetectionPhase.drinking:
      case DetectionPhase.mouthReopened:
      case DetectionPhase.swallowConfirmed:
      case DetectionPhase.swallowFailed:
      case DetectionPhase.timeoutExpired:
        return 2;
      // trackingToLip — mouth is open AND service is building the stability
      // buffer (consecutivePillFrames > 0). Every frame matters for smoothing.
      case DetectionPhase.mouthOpen:
        return isTracking ? 1 : 5;
      // waitingForPill — no useful signal yet.
      case DetectionPhase.noFace:
      case DetectionPhase.faceDetected:
        return 5;
    }
  }

  Future<void> _onFrame(CameraImage image) async {
    if (_completed) return;
    _phaseFrameTick++;

    final skipFactor = _skipForPhase(_lastResult.phase, _service.isTracking);
    final shouldDetect = !_isProcessing && (_phaseFrameTick % skipFactor == 0);

    if (shouldDetect) {
      _isProcessing = true;
      final sw = Stopwatch()..start();
      try {
        final inputImage = _buildInputImage(image);
        if (inputImage != null) {
          final result = await _service.processFrame(image, inputImage);
          sw.stop();
          _profiler.recordProcessed(sw.elapsedMicroseconds, skipFactor);
          _frameCount++;
          _lastFrameTime = DateTime.now();
          if (result.face != null) _facePresentFrames++;
          switch (result.phase) {
            case DetectionPhase.mouthOpen:
            case DetectionPhase.pillOnTongue:
            case DetectionPhase.mouthClosedWithPill:
            case DetectionPhase.drinking:
            case DetectionPhase.mouthReopened:
              _mouthOpenFrames++;
              break;
            default:
              break;
          }
          if (result.phase == DetectionPhase.pillOnTongue ||
              result.phase == DetectionPhase.mouthClosedWithPill) {
            _pillOnTongueFrames++;
          }
          if (result.phase.index > _highestPhaseReached.index) {
            _highestPhaseReached = result.phase;
          }
          if (!_recording &&
              !_videoUploaded &&
              !_finalizing &&
              !_completed &&
              _consentEnabled &&
              result.phase == DetectionPhase.mouthOpen) {
            _startRecording(image);
          }
          if (result.phase == DetectionPhase.swallowConfirmed &&
              !_detectionSucceeded &&
              !_finalizing) {
            _detectionSucceeded = true;
            if (mounted) {
              setState(() =>
                  _statusMessage = 'Yutma onaylandı — kayıt sonlanıyor...');
            }
            _onTimeout();
          }
          if (mounted) {
            setState(() {
              _lastResult = result;
              _imageSize =
                  Size(image.width.toDouble(), image.height.toDouble());
            });
          }
        }
      } catch (e) {
        debugPrint('[VerificationScreen] Detection error: $e');
      } finally {
        _isProcessing = false;
      }
    } else {
      _profiler.recordSkipped();
    }

    // Encoder runs independently of detection skip — it's time-throttled
    // (≈10 fps via _encoderFrameInterval) and must keep feeding the MP4 even
    // on frames where detection is skipped.
    if (_encoderActive && !_encoderBusy) {
      final now = DateTime.now();
      if (_lastEncodedFrameAt == null ||
          now.difference(_lastEncodedFrameAt!) >= _encoderFrameInterval) {
        _lastEncodedFrameAt = now;
        _encoderBusy = true;
        try {
          await _encodeFrame(image);
        } finally {
          _encoderBusy = false;
        }
      }
    }
  }

  /// NV21 → RGBA conversion + append to encoder. Runs ~10 Hz.
  Future<void> _encodeFrame(CameraImage image) async {
    if (!_encoderConfigured) {
      debugPrint('[VerificationScreen] encode skipped: !_encoderConfigured');
      return;
    }
    try {
      final srcRgba = _nv21ToRgba(image);
      if (srcRgba == null) {
        debugPrint(
            '[VerificationScreen] encode skipped: _nv21ToRgba returned null '
            '(planes=${image.planes.length}, w=${image.width}, h=${image.height})');
        return;
      }
      // Rotate src landscape RGBA → portrait RGBA so the saved MP4 plays in
      // the correct orientation. rotation = _encoderRotationDeg (0/90/180/270).
      final rgba = _rotateRgba(
          srcRgba, image.width, image.height, _encoderRotationDeg);
      // Sanity-check: encoder requires EXACTLY width*height*4 RGBA bytes.
      final expected = _encoderWidth * _encoderHeight * 4;
      if (rgba.length != expected) {
        debugPrint(
            '[VerificationScreen] encode SIZE MISMATCH: rgba.length=${rgba.length} '
            'expected=$expected (encW=$_encoderWidth, encH=$_encoderHeight, '
            'rot=$_encoderRotationDeg°, '
            'imgW=${image.width}, imgH=${image.height})');
        return;
      }
      await FlutterQuickVideoEncoder.appendVideoFrame(rgba);
      _encodedFrameCount++;
      if (_encodedFrameCount == 1 || _encodedFrameCount % 30 == 0) {
        debugPrint(
            '[VerificationScreen] encoded frames so far: $_encodedFrameCount');
      }
    } catch (e, st) {
      debugPrint('[VerificationScreen] encoder append FAILED: $e\n$st');
    }
  }

  /// Quick NV21 → RGBA converter. The CameraImage may arrive in two layouts:
  ///   • 2+ planes: planes[0]=Y, planes[1]=interleaved VU (standard)
  ///   • 1 plane: single buffer = [Y (W*H bytes)] + [VU (W*H/2 bytes)]
  ///     (Samsung Exynos / some Camera2 HAL implementations do this)
  /// We handle both. RGBA size matches encoder's configured width × height.
  Uint8List? _nv21ToRgba(CameraImage image) {
    if (image.planes.isEmpty) return null;
    final w = image.width;
    final h = image.height;
    final out = Uint8List(w * h * 4);

    if (image.planes.length >= 2) {
      // Two-plane layout (standard NV21 / YUV_420_888 semi-planar)
      final yBytes = image.planes[0].bytes;
      final uvBytes = image.planes[1].bytes;
      final yRowStride = image.planes[0].bytesPerRow;
      final uvRowStride = image.planes[1].bytesPerRow;
      int dstIdx = 0;
      for (int y = 0; y < h; y++) {
        final yRowStart = y * yRowStride;
        final uvRowStart = (y >> 1) * uvRowStride;
        for (int x = 0; x < w; x++) {
          final yVal = yBytes[yRowStart + x] & 0xFF;
          final uvOffset = (x >> 1) * 2;
          final v = (uvBytes[uvRowStart + uvOffset] & 0xFF) - 128;
          final u = (uvBytes[uvRowStart + uvOffset + 1] & 0xFF) - 128;
          int r = yVal + ((359 * v) >> 8);
          int g = yVal - ((88 * u + 183 * v) >> 8);
          int b = yVal + ((454 * u) >> 8);
          if (r < 0) r = 0; else if (r > 255) r = 255;
          if (g < 0) g = 0; else if (g > 255) g = 255;
          if (b < 0) b = 0; else if (b > 255) b = 255;
          out[dstIdx++] = r;
          out[dstIdx++] = g;
          out[dstIdx++] = b;
          out[dstIdx++] = 255;
        }
      }
      return out;
    }

    // Single-plane NV21: contiguous Y then VU interleaved.
    final bytes = image.planes[0].bytes;
    final yRowStride = image.planes[0].bytesPerRow > 0
        ? image.planes[0].bytesPerRow
        : w;
    final yPlaneSize = yRowStride * h;
    final uvRowStride = yRowStride; // interleaved VU has same row stride
    if (bytes.length < yPlaneSize) return null; // incomplete buffer
    int dstIdx = 0;
    for (int y = 0; y < h; y++) {
      final yRowStart = y * yRowStride;
      final uvRowStart = yPlaneSize + (y >> 1) * uvRowStride;
      for (int x = 0; x < w; x++) {
        final yVal = bytes[yRowStart + x] & 0xFF;
        final uvOffset = (x >> 1) * 2;
        final vIdx = uvRowStart + uvOffset;
        final uIdx = vIdx + 1;
        // Defensive bounds check (some packed buffers may be slightly short)
        if (uIdx >= bytes.length) {
          out[dstIdx++] = yVal; // grayscale fallback
          out[dstIdx++] = yVal;
          out[dstIdx++] = yVal;
          out[dstIdx++] = 255;
          continue;
        }
        final v = (bytes[vIdx] & 0xFF) - 128;
        final u = (bytes[uIdx] & 0xFF) - 128;
        int r = yVal + ((359 * v) >> 8);
        int g = yVal - ((88 * u + 183 * v) >> 8);
        int b = yVal + ((454 * u) >> 8);
        if (r < 0) r = 0; else if (r > 255) r = 255;
        if (g < 0) g = 0; else if (g > 255) g = 255;
        if (b < 0) b = 0; else if (b > 255) b = 255;
        out[dstIdx++] = r;
        out[dstIdx++] = g;
        out[dstIdx++] = b;
        out[dstIdx++] = 255;
      }
    }
    return out;
  }

  /// Rotates an RGBA buffer by `rotDeg` (0/90/180/270) clockwise.
  /// For 90/270, output dimensions are swapped (srcH × srcW instead of
  /// srcW × srcH). Returns the input untouched if rotDeg == 0.
  Uint8List _rotateRgba(Uint8List src, int srcW, int srcH, int rotDeg) {
    if (rotDeg == 0) return src;
    final dst = Uint8List(src.length);
    if (rotDeg == 90) {
      // Out dims: srcH × srcW. Mapping: dst[ox, oy] = src[oy, srcH-1-ox].
      final outW = srcH;
      final outH = srcW;
      for (int oy = 0; oy < outH; oy++) {
        for (int ox = 0; ox < outW; ox++) {
          final sx = oy;
          final sy = srcH - 1 - ox;
          final si = (sy * srcW + sx) * 4;
          final di = (oy * outW + ox) * 4;
          dst[di] = src[si];
          dst[di + 1] = src[si + 1];
          dst[di + 2] = src[si + 2];
          dst[di + 3] = 255;
        }
      }
    } else if (rotDeg == 180) {
      for (int oy = 0; oy < srcH; oy++) {
        for (int ox = 0; ox < srcW; ox++) {
          final sx = srcW - 1 - ox;
          final sy = srcH - 1 - oy;
          final si = (sy * srcW + sx) * 4;
          final di = (oy * srcW + ox) * 4;
          dst[di] = src[si];
          dst[di + 1] = src[si + 1];
          dst[di + 2] = src[si + 2];
          dst[di + 3] = 255;
        }
      }
    } else {
      // 270° CW. Out dims: srcH × srcW.
      // Mapping: dst[ox, oy] = src[srcW-1-oy, ox].
      final outW = srcH;
      final outH = srcW;
      for (int oy = 0; oy < outH; oy++) {
        for (int ox = 0; ox < outW; ox++) {
          final sx = srcW - 1 - oy;
          final sy = ox;
          final si = (sy * srcW + sx) * 4;
          final di = (oy * outW + ox) * 4;
          dst[di] = src[si];
          dst[di + 1] = src[si + 1];
          dst[di + 2] = src[si + 2];
          dst[di + 3] = 255;
        }
      }
    }
    return dst;
  }

  InputImage? _buildInputImage(CameraImage image) {
    final controller = _controller;
    if (controller == null) return null;
    if (image.format.group != ImageFormatGroup.nv21) return null;
    if (image.planes.isEmpty) return null;
    return InputImage.fromBytes(
      bytes: image.planes.first.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: _rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  // Concurrent strategy: image stream and video recording run in parallel.
  // Modern Android phones deliver frames at reduced rate during recording so
  // detection keeps progressing. If a device pauses the stream, the staleness
  // detector below hides the frozen overlay and the post-recording grace
  // period in _onTimeout gives detection a chance to catch up.
  /// Starts software-side video encoding. The camera plugin's MediaRecorder
  /// is NEVER touched — we just begin forwarding the existing imageStream
  /// frames into FlutterQuickVideoEncoder. Detection runs uninterrupted.
  Future<void> _startRecording([CameraImage? firstFrame]) async {
    if (_recording || _videoUploaded || _controller == null) return;
    if (_encoderActive) return;
    try {
      // Source encoder dimensions from the actual stream buffer if we have
      // one (most reliable). Fall back to the controller's preview size only
      // if no frame has arrived yet — but in practice _startRecording is only
      // ever called from _onFrame, so a frame will always be available.
      int w;
      int h;
      if (firstFrame != null) {
        w = firstFrame.width;
        h = firstFrame.height;
      } else {
        final preview = _controller!.value.previewSize;
        if (preview == null) {
          throw StateError('Camera preview size not yet available');
        }
        w = preview.width.toInt();
        h = preview.height.toInt();
      }
      _srcWidth = w;
      _srcHeight = h;
      // Determine rotation degrees from camera sensor orientation. Most
      // front cameras have 270° (Samsung) or 90° — both require swapping
      // width/height so the encoded MP4 is portrait, matching how the user
      // holds the phone.
      switch (_rotation) {
        case InputImageRotation.rotation90deg:
          _encoderRotationDeg = 90;
          break;
        case InputImageRotation.rotation180deg:
          _encoderRotationDeg = 180;
          break;
        case InputImageRotation.rotation270deg:
          _encoderRotationDeg = 270;
          break;
        default:
          _encoderRotationDeg = 0;
      }
      final swap = _encoderRotationDeg == 90 || _encoderRotationDeg == 270;
      _encoderWidth = swap ? h : w;
      _encoderHeight = swap ? w : h;
      // Some encoders require even dimensions; clamp.
      if (_encoderWidth.isOdd) _encoderWidth -= 1;
      if (_encoderHeight.isOdd) _encoderHeight -= 1;
      debugPrint(
          '[VerificationScreen] encoder dims locked: ${_encoderWidth}x$_encoderHeight '
          '(src=${_srcWidth}x$_srcHeight, rot=$_encoderRotationDeg°, '
          'source=${firstFrame != null ? "stream-buffer" : "preview-size"})');

      final tempDir = await getTemporaryDirectory();
      _encoderOutputPath =
          '${tempDir.path}/medverify_$_sessionId.mp4';

      // 500 kbps × ~12 s typical session ≈ 750 KB.
      // 500 kbps × 30 s worst-case ≈ 1.9 MB (the 30 s timeout fallback).
      // For comparison: 1.5 Mbps was producing 3+ MB files. The face/mouth
      // is small enough in the frame that 500 kbps still looks fine for
      // the relative reviewer.
      await FlutterQuickVideoEncoder.setup(
        width: _encoderWidth,
        height: _encoderHeight,
        fps: 10,
        videoBitrate: 500000,
        audioBitrate: 0,
        audioChannels: 0,
        sampleRate: 0,
        filepath: _encoderOutputPath!,
        profileLevel: ProfileLevel.main41,
      );
      _encoderConfigured = true;
      _encodedFrameCount = 0;
      _lastEncodedFrameAt = null;
      if (!mounted) return;
      setState(() {
        _recording = true;
        _encoderActive = true;
        _recordingStartedAt = DateTime.now();
        _statusMessage =
            'Kayıt başladı — detection paralel çalışıyor, hapı yutun ve su için';
      });
      _recordingTimeoutTimer?.cancel();
      _recordingTimeoutTimer = Timer(_recordingMaxDuration, _onTimeout);
    } catch (e, st) {
      debugPrint('[VerificationScreen] startRecording FAILED: $e\n$st');
      _encoderConfigured = false;
      if (mounted) {
        setState(() {
          _recording = false;
          _encoderActive = false;
          _statusMessage = 'KAYIT BAŞLATILAMADI: $e';
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Kayıt başlatılamadı: $e'),
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 6),
        ));
      }
    }
  }

  /// Stops the software encoder and returns the finalized MP4 path.
  /// The imageStream/camera controller are not touched — detection keeps
  /// running until session end.
  Future<String?> _stopRecording() async {
    if (!_recording) return null;
    _recordingTimeoutTimer?.cancel();
    _encoderActive = false;
    if (mounted) setState(() => _recording = false);
    if (!_encoderConfigured) return null;
    try {
      // Wait briefly for any in-flight encode to finish before finalizing.
      int waited = 0;
      while (_encoderBusy && waited < 1000) {
        await Future.delayed(const Duration(milliseconds: 25));
        waited += 25;
      }
      await FlutterQuickVideoEncoder.finish();
    } catch (e) {
      debugPrint('[VerificationScreen] encoder.finish failed: $e');
    }
    _encoderConfigured = false;
    final p = _encoderOutputPath;
    _encoderOutputPath = null;
    _recordedLocalPath = p;
    debugPrint(
        '[VerificationScreen] encoder produced $_encodedFrameCount frames → $p');
    return p;
  }

  /// Kept as a noop for backwards compatibility with other call sites —
  /// we never stop the imageStream anymore so there is nothing to resume.
  Future<void> _resumeImageStreamIfNeeded() async {}

  Future<void> _discardLocalRecording() async {
    final path = _recordedLocalPath;
    _recordedLocalPath = null;
    if (path == null) return;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> _toggleTorch() async {
    final c = _controller;
    if (c == null) return;
    _torchOn = !_torchOn;
    try {
      await c.setFlashMode(_torchOn ? FlashMode.torch : FlashMode.off);
      if (mounted) setState(() {});
    } catch (_) {}
  }

  /// Kept for callers that still expect this method (e.g. dev/manual tests).
  /// In the normal flow finalization happens through [_onTimeout] when the
  /// 30-second recording window completes — that ensures reviewers see the
  /// entire process, not just up to the moment swallow was detected.
  Future<void> _finalizeSuccess() async {
    if (_completed || _finalizing) return;
    _detectionSucceeded = true;
    if (_recording) {
      // Recording still in progress — let the timer drive the finalize step.
      if (mounted) {
        setState(() => _statusMessage =
            'Yutma onaylandı — kayıt 30sn boyunca devam ediyor...');
      }
      return;
    }
    // Not recording (e.g. consent disabled, or _onTimeout already stopped it).
    _finalizing = true;
    _completed = true;
    if (mounted) setState(() => _statusMessage = 'Yutma onaylandı.');
    await _saveAndUpload(
      localPath: _recordedLocalPath,
      userConfirmed: true,
      detectionConfirmed: true,
    );
    _setFinalStatusFromClassification();
  }

  /// Recording window ended — this is the SINGLE finalization point.
  /// Routes based on whether DetectionPhase.swallowConfirmed fired during the
  /// recording (success), arrives within a short grace period (success), or
  /// never arrives (manual confirmation dialog).
  Future<void> _onTimeout() async {
    if (_completed || _finalizing) return;
    // Block the mouth-open trigger immediately — even before _stopRecording
    // sets _recording=false. Otherwise an in-flight frame can spawn a new
    // _startRecording on the same file path while we're still finalizing.
    _finalizing = true;
    if (mounted) {
      // Show the non-dismissible overlay from the moment the recording
      // window closes; it stays up through compress + upload + Firestore
      // write, until the centered completion dialog takes over.
      setState(() {
        _statusMessage = 'Kayıt tamamlandı — sonuç hazırlanıyor...';
        _uploading = true;
        _uploadProgress = 0.0;
        _uploadStatus = 'Kayıt sonlandırılıyor...';
      });
    }
    await _stopRecording();
    if (!mounted) return;

    // Path A: detection confirmed swallow at any point during the 30s window.
    if (_detectionSucceeded) {
      _completed = true;
      await _saveAndUpload(
        localPath: _recordedLocalPath,
        userConfirmed: true,
        detectionConfirmed: true,
      );
      _setFinalStatusFromClassification();
      return;
    }

    // Path B: detection did not confirm yet — wait briefly in case the last
    // few frames promote to swallowConfirmed after the encoder shut down.
    final graceUntil = DateTime.now().add(const Duration(seconds: 5));
    while (mounted && !_detectionSucceeded &&
        DateTime.now().isBefore(graceUntil)) {
      if (_lastResult.phase == DetectionPhase.swallowConfirmed) {
        _detectionSucceeded = true;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 250));
    }
    if (_detectionSucceeded) {
      _completed = true;
      await _saveAndUpload(
        localPath: _recordedLocalPath,
        userConfirmed: true,
        detectionConfirmed: true,
      );
      _setFinalStatusFromClassification();
      return;
    }

    // Path C: ask the user to confirm manually.
    if (!mounted) return;
    if (mounted) setState(() => _statusMessage = 'Otomatik doğrulanamadı.');
    final tookIt = await _showTimeoutDialog();
    if (!mounted) return;
    if (tookIt == true) {
      _completed = true;
      await _saveAndUpload(
        localPath: _recordedLocalPath,
        userConfirmed: true,
        detectionConfirmed: false,
      );
      _setFinalStatusFromClassification();
    } else {
      await _discardLocalRecording();
      _resetForRetry();
    }
  }

  /// Maps the score-derived classification to the user-facing status
  /// message so the UX never says "Doğrulama başarılı" when the score is
  /// actually too low to count as a real verification.
  void _setFinalStatusFromClassification() {
    if (!mounted) return;
    final scorePct = (_completionScore * 100).round();
    final String message;
    switch (_completionClassification) {
      case 'success':
        message = 'Doğrulama başarılı (%$scorePct).';
        break;
      case 'suspicious':
        message =
            'Doğrulama şüpheli (%$scorePct) — yakınınızın incelemesi bekleniyor.';
        break;
      case 'rejected':
      default:
        message =
            'Doğrulama yetersiz (%$scorePct). Lütfen tekrar deneyin.';
        break;
    }
    setState(() => _statusMessage = message);
  }

  Future<bool?> _showTimeoutDialog() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: const [
            Icon(Icons.timer_off_rounded, color: Colors.orange),
            SizedBox(width: 8),
            Text('Süre Doldu'),
          ],
        ),
        content: const Text(
          '30 saniye içinde yutma tespit edilemedi. '
          'İlacı aldığınızı onaylıyor musunuz?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hayır, içemedim'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.skyBlue,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Evet, içtim'),
          ),
        ],
      ),
    );
  }

  void _resetForRetry() {
    _frameCount = 0;
    _facePresentFrames = 0;
    _mouthOpenFrames = 0;
    _pillOnTongueFrames = 0;
    _highestPhaseReached = DetectionPhase.noFace;
    _detectionSucceeded = false;
    _completed = false;
    _finalizing = false;
    _service.reset();
    if (mounted) {
      setState(() {
        _statusMessage = 'Tekrar deneyin.';
        _uploading = false;
        _uploadProgress = 0.0;
        _uploadStatus = '';
      });
    }
  }

  Future<String> _compressVideo(String sourcePath) async {
    // Defensive checks: skip compression if the file is empty, missing, or
    // already small enough. Our software encoder produces a portrait MP4
    // at 480x720@10fps@1.5Mbps — that's ~3 MB for 30 s, already well under
    // any reasonable upload limit. Running video_compress on already-small
    // files is risky: when its internal validator decides "no transcode
    // needed", the plugin then tries to read metadata from a non-existent
    // output path and crashes the host app with a SecurityException
    // / setDataSource failure. We avoid that entirely by skipping when:
    //   • file missing / empty (encoder failed)
    //   • file < 8 MB (no real benefit, only crash risk)
    int size = 0;
    try {
      final f = File(sourcePath);
      final exists = await f.exists();
      size = exists ? await f.length() : 0;
      if (!exists || size < 1024) {
        debugPrint(
            '[VerificationScreen] compress SKIPPED: file empty/missing '
            '(exists=$exists, size=$size, frames=$_encodedFrameCount)');
        return sourcePath;
      }
    } catch (_) {}
    const int compressThresholdBytes = 8 * 1024 * 1024; // 8 MB
    if (size > 0 && size < compressThresholdBytes) {
      debugPrint(
          '[VerificationScreen] compress SKIPPED: file already small '
          '(size=${(size / (1024 * 1024)).toStringAsFixed(2)} MB, '
          'frames=$_encodedFrameCount). Uploading directly.');
      return sourcePath;
    }
    if (mounted) {
      setState(() {
        _uploading = true;
        _uploadProgress = 0.0;
        _uploadStatus = 'Video sıkıştırılıyor...';
      });
    }
    try {
      final sub = VideoCompress.compressProgress$.subscribe((p) {
        if (!mounted) return;
        setState(() => _uploadProgress = (p / 100.0 * 0.5).clamp(0.0, 0.5));
      });
      final info = await VideoCompress.compressVideo(
        sourcePath,
        quality: VideoQuality.LowQuality,
        deleteOrigin: false,
        includeAudio: false,
      );
      sub.unsubscribe();
      final compressedPath = info?.path;
      if (compressedPath == null || compressedPath.isEmpty) return sourcePath;
      try {
        final f = File(sourcePath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
      return compressedPath;
    } catch (e) {
      debugPrint('[VerificationScreen] Compression failed: $e');
      return sourcePath;
    }
  }

  Future<void> _saveAndUpload({
    required String? localPath,
    required bool userConfirmed,
    required bool detectionConfirmed,
  }) async {
    final score = _computeScore(detectionConfirmed: detectionConfirmed);
    final classification = _scoringEngine.classify(score);
    String footageUrl = '';
    String? storagePath;
    String? uploadError;
    if (_consentEnabled && localPath != null && !_videoUploaded) {
      // Verify file is non-empty BEFORE compress (crash guard)
      final localFile = File(localPath);
      final localExists = await localFile.exists();
      final localSize = localExists ? await localFile.length() : 0;
      if (!localExists || localSize < 1024 || _encodedFrameCount == 0) {
        debugPrint(
            '[VerificationScreen] upload SKIPPED: bad local file '
            '(exists=$localExists, size=$localSize, frames=$_encodedFrameCount)');
        uploadError =
            'Kayıt boş ($_encodedFrameCount frame). Encoder frame alamadı.';
      } else {
      final pathToUpload = await _compressVideo(localPath);
      if (mounted) setState(() => _uploadStatus = 'Sunucuya yükleniyor...');
      try {
        final upload = await _cloudService.uploadVideo(
          deviceId: _deviceId,
          localPath: pathToUpload,
          onProgress: (p) {
            if (!mounted) return;
            setState(() =>
                _uploadProgress = (0.5 + p * 0.5).clamp(0.0, 1.0));
          },
        );
        footageUrl = upload.downloadUrl;
        storagePath = upload.storagePath;
        _videoUploaded = true;
      } catch (e) {
        uploadError = e.toString();
        debugPrint('[VerificationScreen] Upload failed: $e');
        if (mounted) setState(() => _uploadStatus = 'Yükleme başarısız.');
      } finally {
        try {
          final f = File(pathToUpload);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      } // close else (non-empty local file branch)
    }
    if (mounted && _consentEnabled && localPath != null) {
      setState(() => _uploadStatus = 'Doğrulama kaydı yazılıyor...');
    }
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId != null) {
      final result = vr.VerificationResult(
        id: _sessionId,
        accuracyScore: score,
        classification: _mapClassification(classification),
        presenceDetected: _facePresentFrames > 0,
        appMode: _appMode,
        subScores: {
          'pill': _facePresentFrames == 0 ? 0.0 : _pillOnTongueFrames / _facePresentFrames,
          'lip': _frameCount == 0 ? 0.0 : _facePresentFrames / _frameCount,
          'mouth': _facePresentFrames == 0 ? 0.0 : _mouthOpenFrames / _facePresentFrames,
          'detectionConfirmed': detectionConfirmed ? 1.0 : 0.0,
          'userConfirmed': userConfirmed ? 1.0 : 0.0,
        },
        footageUrl: footageUrl,
        sectionIndex: widget.sectionIndex,
        timestamp: DateTime.now(),
      );
      try {
        await _cloudService.save(userId, result);
      } catch (_) {}
      if (widget.macAddress != null && widget.macAddress!.isNotEmpty) {
        try {
          await _cloudService.saveForDevice(
            macAddress: widget.macAddress!,
            result: result,
            extraData: {
              'storagePath': storagePath,
              'sessionId': _sessionId,
              'deviceId': _deviceId,
              'detectionConfirmed': detectionConfirmed,
              'userConfirmed': userConfirmed,
              'highestPhase': _highestPhaseReached.name,
            },
          );
        } catch (_) {}
      }
    }
    if (mounted) {
      setState(() {
        _uploading = false;
        _uploadStatus = '';
        _completionFootageUrl = footageUrl.isEmpty ? null : footageUrl;
        _completionStoragePath = storagePath;
        _completionUploadError = uploadError;
        _completionScore = score;
        _completionClassification = classification.name;
      });
      // Auto-pop the centered completion dialog as soon as save+upload
      // finishes. This replaces the bottom "Tamamla" button.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showCompletionDialog();
      });
    }
  }

  Future<void> _showCompletionDialog() async {
    if (!mounted) return;
    final cls = _completionClassification;
    Color color;
    IconData icon;
    String title;
    switch (cls) {
      case 'success':
        color = AppColors.turquoise;
        icon = Icons.verified_rounded;
        title = 'Doğrulama Başarılı';
        break;
      case 'suspicious':
        color = Colors.orange;
        icon = Icons.help_outline_rounded;
        title = 'Şüpheli Doğrulama';
        break;
      case 'rejected':
        color = Colors.redAccent;
        icon = Icons.cancel_rounded;
        title = 'Doğrulama Başarısız';
        break;
      default:
        color = AppColors.skyBlue;
        icon = Icons.info_outline_rounded;
        title = 'Doğrulama Tamamlandı';
    }

    final uploadOk = _completionFootageUrl != null &&
        _completionFootageUrl!.isNotEmpty;
    final consentSkipped = !_consentEnabled;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: AppColors.surface,
        insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 44),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppColors.deepSea,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Doğruluk: ${(_completionScore * 100).toStringAsFixed(0)}%',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              const SizedBox(height: 14),
              if (consentSkipped)
                _completionInfoRow(
                  Icons.privacy_tip_rounded,
                  'Video kaydı alınmadı (KVKK onayı kapalı).',
                  Colors.amber.shade800,
                )
              else if (uploadOk)
                _completionInfoRow(
                  Icons.cloud_done_rounded,
                  'Video sunucuya yüklendi. Yakınlarınız Yakın İncelemesi\'nden açabilir.',
                  AppColors.turquoise,
                )
              else
                _completionInfoRow(
                  Icons.cloud_off_rounded,
                  'Video YÜKLENEMEDİ: ${_completionUploadError ?? "bilinmeyen hata"}',
                  Colors.redAccent,
                ),
              if (_completionStoragePath != null) ...[
                const SizedBox(height: 6),
                Text(
                  _completionStoragePath!,
                  style: TextStyle(
                    fontSize: 9,
                    color: Colors.grey.shade500,
                    fontFamily: 'monospace',
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    // Clear the blocking flags so PopScope/overlay don't
                    // interfere with the screen-pop that follows.
                    if (mounted) {
                      setState(() {
                        _finalizing = false;
                        _uploading = false;
                      });
                    }
                    Navigator.of(ctx).pop();
                    if (mounted) Navigator.of(context).pop();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: color,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(
                    'Tamam',
                    style: GoogleFonts.inter(
                        fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _completionInfoRow(IconData icon, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: 12,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  double _computeScore({required bool detectionConfirmed}) {
    if (_frameCount == 0) return 0.0;

    // Lip tracking: how many frames had a face detected (contour tracked).
    final lipRatio = (_facePresentFrames / _frameCount).clamp(0.0, 1.0);

    // Mouth open ratio among face-present frames (not total frames).
    final mouthRatio = _facePresentFrames > 0
        ? (_mouthOpenFrames / _facePresentFrames).clamp(0.0, 1.0)
        : 0.0;

    // Pill detection: ratio among face-present frames. If the full
    // verification pipeline succeeded (swallowConfirmed), guarantee
    // at least 0.8 — the pill WAS on the tongue, was consumed, and the
    // swallow was verified; low frame-ratio shouldn't penalise the score.
    final rawPillRatio = _facePresentFrames > 0
        ? (_pillOnTongueFrames / _facePresentFrames).clamp(0.0, 1.0)
        : 0.0;
    final pillScore = detectionConfirmed
        ? rawPillRatio.clamp(0.8, 1.0)
        : rawPillRatio;

    return _scoringEngine.calculate(
      mode: _appMode == AppMode.device
          ? ScoringMode.withDevice
          : ScoringMode.deviceFree,
      pill: pillScore,
      lip: lipRatio,
      mouth: mouthRatio,
      timing: detectionConfirmed ? 1.0 : 0.4,
    );
  }

  vr.VerificationClassification _mapClassification(
      VerificationResult engineResult) {
    switch (engineResult) {
      case VerificationResult.rejected:
        return vr.VerificationClassification.rejected;
      case VerificationResult.suspicious:
        return vr.VerificationClassification.suspicious;
      case VerificationResult.success:
        return vr.VerificationClassification.success;
    }
  }

  Color _phaseAccent(DetectionPhase phase) {
    switch (phase) {
      case DetectionPhase.noFace:
      case DetectionPhase.swallowFailed:
        return Colors.redAccent;
      case DetectionPhase.faceDetected:
        return Colors.orange;
      case DetectionPhase.mouthOpen:
      case DetectionPhase.mouthReopened:
      case DetectionPhase.drinking:
        return AppColors.skyBlue;
      case DetectionPhase.pillOnTongue:
      case DetectionPhase.mouthClosedWithPill:
      case DetectionPhase.swallowConfirmed:
        return AppColors.turquoise;
      case DetectionPhase.timeoutExpired:
        return Colors.grey;
    }
  }

  IconData _phaseIcon(DetectionPhase phase) {
    switch (phase) {
      case DetectionPhase.noFace:
        return Icons.face_retouching_off_rounded;
      case DetectionPhase.faceDetected:
        return Icons.face_rounded;
      case DetectionPhase.mouthOpen:
        return Icons.sentiment_satisfied_alt_rounded;
      case DetectionPhase.pillOnTongue:
        return Icons.medication_rounded;
      case DetectionPhase.mouthClosedWithPill:
        return Icons.no_food_rounded;
      case DetectionPhase.drinking:
        return Icons.local_drink_rounded;
      case DetectionPhase.mouthReopened:
        return Icons.sentiment_neutral_rounded;
      case DetectionPhase.swallowConfirmed:
        return Icons.verified_rounded;
      case DetectionPhase.swallowFailed:
        return Icons.error_outline_rounded;
      case DetectionPhase.timeoutExpired:
        return Icons.timer_off_rounded;
    }
  }

  String _phaseLabel(DetectionPhase phase) {
    switch (phase) {
      case DetectionPhase.noFace:
        return 'Yüz Bulunamadı';
      case DetectionPhase.faceDetected:
        return 'Yüz Algılandı';
      case DetectionPhase.mouthOpen:
        return 'Ağız Açık';
      case DetectionPhase.pillOnTongue:
        return 'Hap Dilde';
      case DetectionPhase.mouthClosedWithPill:
        return 'Ağız Kapandı';
      case DetectionPhase.drinking:
        return 'Su İçiliyor';
      case DetectionPhase.mouthReopened:
        return 'Ağız Yeniden Açıldı';
      case DetectionPhase.swallowConfirmed:
        return 'Yutma Onaylandı';
      case DetectionPhase.swallowFailed:
        return 'Yutma Başarısız';
      case DetectionPhase.timeoutExpired:
        return 'Süre Doldu';
    }
  }

  bool _stepReached(DetectionPhase phase, int step) {
    int reached;
    switch (phase) {
      case DetectionPhase.noFace:
      case DetectionPhase.timeoutExpired:
        reached = 0;
        break;
      case DetectionPhase.faceDetected:
        reached = 1;
        break;
      case DetectionPhase.mouthOpen:
        reached = 2;
        break;
      case DetectionPhase.pillOnTongue:
        reached = 3;
        break;
      case DetectionPhase.mouthClosedWithPill:
        reached = 4;
        break;
      case DetectionPhase.drinking:
      case DetectionPhase.mouthReopened:
        reached = 5;
        break;
      case DetectionPhase.swallowConfirmed:
      case DetectionPhase.swallowFailed:
        reached = 6;
        break;
    }
    return reached >= step;
  }

  @override
  Widget build(BuildContext context) {
    final phase = _lastResult.phase;
    final accent = _phaseAccent(phase);
    // True while finalization is happening — the recording's already done
    // and we're processing/uploading the video. The fullscreen overlay
    // below blocks all interaction until upload completes (then the
    // completion dialog takes over).
    final blocking = _finalizing || _uploading;
    return PopScope(
      // While blocking, intercept system back so the user can't exit until
      // upload + classification finalize.
      canPop: !blocking,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: Text('İlaç Doğrulama',
              style: GoogleFonts.inter(
                  fontWeight: FontWeight.w800, color: AppColors.deepSea)),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
          // Hide the back-arrow during finalization; replace with an explicit
          // disabled icon so the user sees that exit is intentionally blocked.
          automaticallyImplyLeading: !blocking,
          leading: blocking
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: Icon(Icons.lock_clock_rounded,
                      color: AppColors.deepSea),
                )
              : null,
          iconTheme: const IconThemeData(color: AppColors.deepSea),
          actions: [
            IconButton(
              icon: Icon(
                  _torchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                  color: AppColors.deepSea),
              onPressed:
                  (_isCameraInitialized && !blocking) ? _toggleTorch : null,
            ),
            IconButton(
              icon:
                  const Icon(Icons.refresh_rounded, color: AppColors.deepSea),
              onPressed: (_completed || blocking)
                  ? null
                  : () {
                      _service.reset();
                      setState(() {
                        _lastResult = PillOnTongueResult.empty();
                        _frameCount = 0;
                        _facePresentFrames = 0;
                        _mouthOpenFrames = 0;
                        _pillOnTongueFrames = 0;
                        _highestPhaseReached = DetectionPhase.noFace;
                      });
                    },
            ),
          ],
        ),
        body: Stack(
          children: [
          SafeArea(
            child: Column(
              children: [
                Expanded(
                  flex: 7,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                    child: _CameraCard(
                      controller: _controller,
                      isInitialized: _isCameraInitialized,
                      isFrontCamera: _isFrontCamera,
                      lastResult: _lastResult,
                      imageSize: _imageSize,
                      rotation: _rotation,
                      accent: accent,
                      phaseLabel: _phaseLabel(phase),
                      phaseIcon: _phaseIcon(phase),
                      recording: _recording,
                      recordingStartedAt: _recordingStartedAt,
                      consentEnabled: _consentEnabled,
                      lastFrameTime: _lastFrameTime,
                    ),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    physics: const BouncingScrollPhysics(),
                    child: Column(
                      children: [
                        _GuidanceCard(
                          accent: accent,
                          icon: _phaseIcon(phase),
                          title: _statusMessage ?? _phaseLabel(phase),
                          subtitle: _recording
                              ? 'Detection duraklatıldı (kayıt sürüyor) — '
                                  'lütfen ilacınızı alıp yutun'
                              : _lastResult.guidance,
                        ),
                        const SizedBox(height: 8),
                        _StepTracker(
                          steps: const [
                            'Yüz',
                            'Ağız',
                            'Hap',
                            'Kapat',
                            'Su',
                            'Yut'
                          ],
                          stepReached: (i) => _stepReached(phase, i),
                          phase: phase,
                        ),
                        // Bottom button removed — completion is now shown
                        // via a centered dialog popped from _saveAndUpload.

                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
            if (blocking)
              _UploadOverlay(
                progress: _uploadProgress,
                status: _uploadStatus.isNotEmpty
                    ? _uploadStatus
                    : (_statusMessage ??
                        'Kayıt tamamlanıyor — lütfen bekleyin...'),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _recordingTimeoutTimer?.cancel();
    if (_encoderConfigured) {
      _encoderActive = false;
      FlutterQuickVideoEncoder.finish().catchError((_) {});
      _encoderConfigured = false;
    }
    if (_controller?.value.isStreamingImages ?? false) {
      _controller?.stopImageStream().catchError((_) {});
    }
    _controller?.dispose();
    _service.dispose();
    super.dispose();
  }
}

class _CameraCard extends StatelessWidget {
  final CameraController? controller;
  final bool isInitialized;
  final bool isFrontCamera;
  final PillOnTongueResult lastResult;
  final Size imageSize;
  final InputImageRotation rotation;
  final Color accent;
  final String phaseLabel;
  final IconData phaseIcon;
  final bool recording;
  final DateTime? recordingStartedAt;
  final bool consentEnabled;
  final DateTime? lastFrameTime;

  const _CameraCard({
    required this.controller,
    required this.isInitialized,
    required this.isFrontCamera,
    required this.lastResult,
    required this.imageSize,
    required this.rotation,
    required this.accent,
    required this.phaseLabel,
    required this.phaseIcon,
    required this.recording,
    required this.recordingStartedAt,
    required this.consentEnabled,
    required this.lastFrameTime,
  });

  bool get _framesAreStale {
    if (lastFrameTime == null) return true;
    return DateTime.now().difference(lastFrameTime!) >
        const Duration(milliseconds: 1500);
  }

  bool get _rotated90or270 =>
      rotation == InputImageRotation.rotation90deg ||
      rotation == InputImageRotation.rotation270deg;

  @override
  Widget build(BuildContext context) {
    if (!isInitialized || controller == null) {
      return _shell(
          child: const Center(
              child: CircularProgressIndicator(color: AppColors.skyBlue)));
    }
    final preview = controller!.value.previewSize;
    if (preview == null) {
      return _shell(
          child: const Center(child: CircularProgressIndicator()));
    }
    final w = _rotated90or270 ? preview.height : preview.width;
    final h = _rotated90or270 ? preview.width : preview.height;
    final aspect = w / h;

    return _shell(
      child: Center(
        child: AspectRatio(
          aspectRatio: aspect,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CameraPreview(controller!),
              // Painter çizilir EĞER:
              //   - face algılanmış AND
              //   - frame'ler güncel (< 1.5s eski) — yani concurrent çalışıyor
              // Bu sayede recording sırasında frame'ler gelmeye devam ediyorsa
              // dudak takibi canlı görünür; durmuşsa donmuş overlay gizlenir.
              if (lastResult.face != null && !_framesAreStale)
                CustomPaint(
                  painter: PillPainter(
                    result: lastResult,
                    imageSize: imageSize,
                    rotation: rotation,
                    isFrontCamera: isFrontCamera,
                  ),
                ),
              // Recording sırasında frame'ler donmuşsa "kayıt sürüyor" göster
              if (recording && _framesAreStale)
                const _RecordingDimOverlay(),
              if (recording && recordingStartedAt != null)
                Positioned(
                  top: 12,
                  left: 12,
                  child: _RecPill(startedAt: recordingStartedAt!),
                ),
              Positioned(
                top: 12,
                right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(phaseIcon, color: Colors.white, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        recording ? 'KAYIT' : phaseLabel,
                        style: GoogleFonts.inter(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (!consentEnabled)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade400,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline_rounded, size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'KVKK onayı yok — kayıt yapılmıyor.',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _shell({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.blueGrey.shade50, width: 1),
        boxShadow: [
          BoxShadow(
            color: AppColors.deepSea.withValues(alpha: 0.10),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: child,
      ),
    );
  }
}

/// Recording sırasında ekrana hafif karartma + büyük kayıt animasyonu.
/// Painter gizlendiği için kullanıcı "donmuş takip" yerine bunu görür.
class _RecordingDimOverlay extends StatefulWidget {
  const _RecordingDimOverlay();
  @override
  State<_RecordingDimOverlay> createState() => _RecordingDimOverlayState();
}

class _RecordingDimOverlayState extends State<_RecordingDimOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.18),
          child: Center(
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.9, end: 1.05).animate(
                CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 18, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.fiber_manual_record,
                        color: Colors.redAccent, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'KAYIT SÜRÜYOR',
                      style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GuidanceCard extends StatelessWidget {
  final Color accent;
  final IconData icon;
  final String title;
  final String subtitle;
  const _GuidanceCard({
    required this.accent,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.blueGrey.shade50),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: accent, size: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: AppColors.deepSea,
                  ),
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color: const Color(0xFF475569),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StepTracker extends StatelessWidget {
  final List<String> steps;
  final bool Function(int) stepReached;
  final DetectionPhase phase;
  const _StepTracker({
    required this.steps,
    required this.stepReached,
    required this.phase,
  });

  Color _stepColor(int i) {
    final palette = const [
      Colors.orange,
      AppColors.skyBlue,
      AppColors.turquoise,
      Colors.amber,
      Colors.lightBlue,
      AppColors.turquoise,
    ];
    if (i == 6 && phase == DetectionPhase.swallowFailed) {
      return Colors.redAccent;
    }
    return palette[i - 1];
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.blueGrey.shade50),
      ),
      child: Row(
        children: [
          for (int i = 1; i <= steps.length; i++) ...[
            _StepDot(
              label: steps[i - 1],
              active: stepReached(i),
              color: _stepColor(i),
            ),
            if (i < steps.length) _StepLine(active: stepReached(i + 1)),
          ],
        ],
      ),
    );
  }
}

class _StepDot extends StatelessWidget {
  final String label;
  final bool active;
  final Color color;
  const _StepDot({
    required this.label,
    required this.active,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? color : Colors.blueGrey.shade100,
            boxShadow: active
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.4),
                      blurRadius: 5,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: active
              ? const Icon(Icons.check_rounded,
                  color: Colors.white, size: 14)
              : null,
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: GoogleFonts.inter(
            color: active ? color : Colors.blueGrey.shade300,
            fontSize: 9,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _StepLine extends StatelessWidget {
  final bool active;
  const _StepLine({required this.active});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        height: 2,
        margin: const EdgeInsets.only(bottom: 14, left: 1, right: 1),
        color: active ? AppColors.skyBlue : Colors.blueGrey.shade100,
      ),
    );
  }
}

class _CompleteButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _CompleteButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          colors: [AppColors.skyBlue, AppColors.deepSea],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.deepSea.withValues(alpha: 0.25),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.check_rounded,
                    color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Text(
                  'Tamamla',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecPill extends StatefulWidget {
  final DateTime startedAt;
  const _RecPill({required this.startedAt});
  @override
  State<_RecPill> createState() => _RecPillState();
}

class _RecPillState extends State<_RecPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  Timer? _t;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _t = Timer.periodic(
        const Duration(milliseconds: 250), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = DateTime.now().difference(widget.startedAt).inSeconds;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadeTransition(
            opacity: _ctrl,
            child: const Icon(Icons.fiber_manual_record,
                color: Colors.redAccent, size: 12),
          ),
          const SizedBox(width: 5),
          Text(
            'REC ${elapsed}s/30s',
            style: GoogleFonts.inter(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 10,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _UploadOverlay extends StatelessWidget {
  final double progress;
  final String status;
  const _UploadOverlay({required this.progress, required this.status});

  @override
  Widget build(BuildContext context) {
    final pct = (progress.clamp(0.0, 1.0) * 100).toStringAsFixed(0);
    return Positioned.fill(
      child: ColoredBox(
        color: AppColors.deepSea.withValues(alpha: 0.65),
        child: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 32),
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 96,
                  height: 96,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 96,
                        height: 96,
                        child: CircularProgressIndicator(
                          value: progress > 0 ? progress : null,
                          strokeWidth: 6,
                          backgroundColor:
                              AppColors.skyBlue.withValues(alpha: 0.15),
                          valueColor: const AlwaysStoppedAnimation<Color>(
                              AppColors.skyBlue),
                        ),
                      ),
                      Text(
                        '$pct%',
                        style: GoogleFonts.inter(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: AppColors.deepSea,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'Video İşleniyor',
                  style: GoogleFonts.inter(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: AppColors.deepSea,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  status.isEmpty ? 'Lütfen bekleyin...' : status,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: const Color(0xFF475569),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

