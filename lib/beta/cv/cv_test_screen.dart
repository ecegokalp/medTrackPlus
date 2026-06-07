import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:medTrackPlus/beta/cv/mlkit_cv_processor.dart';
import 'package:medTrackPlus/beta/mlkit_test/pill_detection_service.dart';
import 'package:medTrackPlus/beta/models/cv_frame_data.dart';

/// Isolated test screen for the unified MLKitCVProcessor pipeline.
///
/// Exists ONLY to verify on a real device that:
///   1. FaceDetection + PillDetection + PillTracker + FrameThrottler glue
///      into a single processFrame() returning a complete CVFrameData.
///   2. End-to-end frame latency stays under the 100ms target on the
///      device the user holds.
///
/// Independent of the production verification flow — touching this screen
/// will never affect VerificationScreen.
class CvTestScreen extends StatefulWidget {
  const CvTestScreen({super.key});

  @override
  State<CvTestScreen> createState() => _CvTestScreenState();
}

class _CvTestScreenState extends State<CvTestScreen> {
  CameraController? _controller;
  MLKitCVProcessor? _processor;
  bool _streaming = false;
  bool _isProcessing = false;

  CVFrameData _last = CVFrameData.empty();

  int _totalFrames = 0;
  int _processedFrames = 0;
  int _cachedFrames = 0;
  int _over100msFrames = 0;
  double _maxLatencyMs = 0.0;
  double _sumLatencyMs = 0.0;
  int _latencySamples = 0;

  Timer? _hudTimer;
  String _rssMb = '?';

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _hudTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        try {
          _rssMb = (ProcessInfo.currentRss / 1024 / 1024).toStringAsFixed(1);
        } catch (_) {
          _rssMb = '?';
        }
      });
    });
  }

  Future<void> _bootstrap() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) return;
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;
    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    final controller = CameraController(
      front,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );
    await controller.initialize();
    if (!mounted) {
      await controller.dispose();
      return;
    }
    final rotation =
        InputImageRotationValue.fromRawValue(front.sensorOrientation) ??
            InputImageRotation.rotation0deg;
    _processor = MLKitCVProcessor(rotation: rotation);
    setState(() => _controller = controller);
    await controller.startImageStream(_onFrame);
    _streaming = true;
  }

  Future<void> _onFrame(CameraImage image) async {
    _totalFrames++;
    if (_isProcessing || _processor == null) return;
    _isProcessing = true;
    try {
      final data = await _processor!.processFrame(image);
      if (data.fromCache) {
        _cachedFrames++;
      } else {
        _processedFrames++;
        _sumLatencyMs += data.latencyMs;
        _latencySamples++;
        if (data.latencyMs > _maxLatencyMs) _maxLatencyMs = data.latencyMs;
        if (data.latencyMs > 100.0) _over100msFrames++;
      }
      if (mounted) setState(() => _last = data);
    } finally {
      _isProcessing = false;
    }
  }

  void _resetStats() {
    setState(() {
      _totalFrames = 0;
      _processedFrames = 0;
      _cachedFrames = 0;
      _over100msFrames = 0;
      _maxLatencyMs = 0.0;
      _sumLatencyMs = 0.0;
      _latencySamples = 0;
      _processor?.reset();
      _last = CVFrameData.empty();
    });
  }

  @override
  void dispose() {
    _hudTimer?.cancel();
    if (_streaming && _controller != null) {
      _controller!.stopImageStream().catchError((_) {});
    }
    _controller?.dispose();
    _processor?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;
    final avgLatency =
        _latencySamples == 0 ? 0.0 : _sumLatencyMs / _latencySamples;
    final skipRatio = _totalFrames == 0
        ? 0.0
        : (_cachedFrames / _totalFrames * 100);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('CV Pipeline Test'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.restart_alt),
            tooltip: 'Reset stats',
            onPressed: _resetStats,
          ),
        ],
      ),
      body: !ready
          ? const Center(
              child: CircularProgressIndicator(color: Colors.white),
            )
          : Stack(
              children: [
                Positioned.fill(child: CameraPreview(controller)),
                Positioned(
                  left: 12,
                  right: 12,
                  top: 12,
                  child: _Hud(
                    data: _last,
                    avgLatencyMs: avgLatency,
                    maxLatencyMs: _maxLatencyMs,
                    totalFrames: _totalFrames,
                    processedFrames: _processedFrames,
                    cachedFrames: _cachedFrames,
                    over100msFrames: _over100msFrames,
                    skipRatioPct: skipRatio,
                    rssMb: _rssMb,
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: _GuidanceBar(text: _last.guidance),
                ),
              ],
            ),
    );
  }
}

class _Hud extends StatelessWidget {
  const _Hud({
    required this.data,
    required this.avgLatencyMs,
    required this.maxLatencyMs,
    required this.totalFrames,
    required this.processedFrames,
    required this.cachedFrames,
    required this.over100msFrames,
    required this.skipRatioPct,
    required this.rssMb,
  });

  final CVFrameData data;
  final double avgLatencyMs;
  final double maxLatencyMs;
  final int totalFrames;
  final int processedFrames;
  final int cachedFrames;
  final int over100msFrames;
  final double skipRatioPct;
  final String rssMb;

  @override
  Widget build(BuildContext context) {
    final latencyColor = data.latencyMs > 100.0
        ? Colors.redAccent
        : (data.latencyMs > 50.0 ? Colors.amberAccent : Colors.greenAccent);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontFamily: 'monospace',
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'phase: ${_phaseName(data.phase)}',
                  style: const TextStyle(
                    color: Colors.lightBlueAccent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (data.fromCache)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    color: Colors.purpleAccent.withValues(alpha: 0.4),
                    child: const Text('CACHED'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'latency: ${data.latencyMs.toStringAsFixed(1)}ms  '
              'avg: ${avgLatencyMs.toStringAsFixed(1)}ms  '
              'max: ${maxLatencyMs.toStringAsFixed(1)}ms',
              style: TextStyle(color: latencyColor),
            ),
            Text(
              'frames: total=$totalFrames  proc=$processedFrames  '
              'cached=$cachedFrames  skip=${skipRatioPct.toStringAsFixed(0)}%',
            ),
            Text('over-100ms frames: $over100msFrames'),
            Text('rss: ${rssMb}MB'),
            const Divider(height: 12, color: Colors.white24),
            Text(
              'face: ${data.faceDetected ? "yes" : "no"}  '
              'mouth: ${data.mouthOpenRatio.toStringAsFixed(2)} '
              '${data.isMouthOpen ? "(open)" : ""}',
            ),
            Text(
              'pill: ${data.pillDetected ? "YES" : "no"}  '
              'conf=${data.pillConfidence.toStringAsFixed(2)}',
            ),
            Text(
              'tracker: smoothed=${_rectShort(data.smoothedPillRegion)}  '
              'lastSeen=${_rectShort(data.lastSeenPillRegion)}',
            ),
          ],
        ),
      ),
    );
  }

  String _rectShort(Rect? r) {
    if (r == null) return '—';
    return '${r.left.toInt()},${r.top.toInt()} '
        '${r.width.toInt()}x${r.height.toInt()}';
  }

  String _phaseName(DetectionPhase p) => p.name;
}

class _GuidanceBar extends StatelessWidget {
  const _GuidanceBar({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}