import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:permission_handler/permission_handler.dart';
import 'pill_detection_service.dart';
import 'pill_painter.dart';

class PillDetectionTestScreen extends StatefulWidget {
  const PillDetectionTestScreen({super.key});

  @override
  State<PillDetectionTestScreen> createState() =>
      _PillDetectionTestScreenState();
}

class _PillDetectionTestScreenState extends State<PillDetectionTestScreen> {
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isProcessing = false;
  late PillOnTongueService _service;
  PillOnTongueResult _lastResult = PillOnTongueResult.empty();
  Size _imageSize = const Size(480, 640);

  @override
  void initState() {
    super.initState();
    _service = PillOnTongueService();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        setState(() => _lastResult = PillOnTongueResult(
              phase: DetectionPhase.noFace,
              mouthOpenRatio: 0.0,
              pillConfidence: 0.0,
              guidance: 'Kamera izni verilmedi',
              timestamp: DateTime.now(),
            ));
        return;
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) return;

      // Front camera for face/mouth detection
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );

      await _cameraController!.initialize();
      if (!mounted) return;

      setState(() {
        _isCameraInitialized = true;
      });

      await _cameraController!.startImageStream(_onFrame);
    } catch (e) {
      debugPrint('Camera error: $e');
    }
  }

  Future<void> _onFrame(CameraImage image) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final inputImage = _buildInputImage(image);
      if (inputImage == null) {
        _isProcessing = false;
        return;
      }

      final result = await _service.processFrame(image, inputImage);

      if (!mounted) return;

      setState(() {
        _lastResult = result;
        _imageSize = Size(image.width.toDouble(), image.height.toDouble());
      });
    } catch (e) {
      debugPrint('Detection error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  InputImage? _buildInputImage(CameraImage image) {
    final camera = _cameraController;
    if (camera == null) return null;

    final rotation = InputImageRotationValue.fromRawValue(
        camera.description.sensorOrientation);
    if (rotation == null) return null;

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

  @override
  void dispose() {
    _cameraController?.dispose();
    _service.dispose();
    super.dispose();
  }

  Color _phaseColor(DetectionPhase phase) {
    switch (phase) {
      case DetectionPhase.noFace:
        return Colors.red;
      case DetectionPhase.faceDetected:
        return Colors.orange;
      case DetectionPhase.mouthOpen:
        return Colors.blue;
      case DetectionPhase.pillDetected:
        return Colors.green;
    }
  }

  IconData _phaseIcon(DetectionPhase phase) {
    switch (phase) {
      case DetectionPhase.noFace:
        return Icons.face_retouching_off;
      case DetectionPhase.faceDetected:
        return Icons.face;
      case DetectionPhase.mouthOpen:
        return Icons.mood;
      case DetectionPhase.pillDetected:
        return Icons.check_circle;
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
      case DetectionPhase.pillDetected:
        return 'Hap Algılandı!';
    }
  }

  @override
  Widget build(BuildContext context) {
    final phase = _lastResult.phase;
    final color = _phaseColor(phase);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pill Detection Test'),
        backgroundColor: color,
        foregroundColor: Colors.white,
      ),
      body: _isCameraInitialized && _cameraController != null
          ? Column(
              children: [
                // Camera preview with overlay
                Expanded(
                  flex: 3,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: AspectRatio(
                          aspectRatio: _cameraController!.value.aspectRatio,
                          child: _cameraController!.buildPreview(),
                        ),
                      ),
                      // Face & mouth overlay
                      if (_lastResult.face != null)
                        Positioned.fill(
                          child: CustomPaint(
                            painter: PillPainter(
                              result: _lastResult,
                              imageSize: _imageSize,
                            ),
                          ),
                        ),
                      // Phase indicator top-right
                      Positioned(
                        top: 16,
                        right: 16,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(_phaseIcon(phase),
                                  color: Colors.white, size: 18),
                              const SizedBox(width: 6),
                              Text(
                                _phaseLabel(phase),
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Guidance & info panel
                Container(
                  color: Colors.grey[900],
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      // Guidance text
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: color, width: 1.5),
                        ),
                        child: Row(
                          children: [
                            Icon(_phaseIcon(phase), color: color, size: 28),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _lastResult.guidance,
                                style: TextStyle(
                                  color: color,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Steps indicator
                      Row(
                        children: [
                          _stepDot('Yüz', phase.index >= 1, Colors.orange),
                          _stepLine(phase.index >= 1),
                          _stepDot('Ağız', phase.index >= 2, Colors.blue),
                          _stepLine(phase.index >= 2),
                          _stepDot('Hap', phase.index >= 3, Colors.green),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // Debug info
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        color: Colors.black,
                        child: Text(
                          'Mouth: ${(_lastResult.mouthOpenRatio * 100).toStringAsFixed(1)}% | '
                          'Pill conf: ${(_lastResult.pillConfidence * 100).toStringAsFixed(0)}% | '
                          'White px: ${_lastResult.whitePixelCount}/${_lastResult.totalMouthPixels}',
                          style: const TextStyle(
                              color: Colors.greenAccent,
                              fontSize: 11,
                              fontFamily: 'monospace'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            )
          : Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(_lastResult.guidance),
                ],
              ),
            ),
    );
  }

  Widget _stepDot(String label, bool active, Color color) {
    return Column(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? color : Colors.grey[700],
          ),
          child: active
              ? const Icon(Icons.check, color: Colors.white, size: 16)
              : null,
        ),
        const SizedBox(height: 4),
        Text(label,
            style: TextStyle(
                color: active ? color : Colors.grey,
                fontSize: 11,
                fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _stepLine(bool active) {
    return Expanded(
      child: Container(
        height: 2,
        margin: const EdgeInsets.only(bottom: 18),
        color: active ? Colors.white38 : Colors.grey[800],
      ),
    );
  }
}