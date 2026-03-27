import 'face_painter.dart';
import 'face_detection_service.dart';
import 'dart:typed_data';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class MlkitTestScreen extends StatefulWidget {
  const MlkitTestScreen({super.key});

  @override
  State<MlkitTestScreen> createState() => _MlkitTestScreenState();
}

class _MlkitTestScreenState extends State<MlkitTestScreen> {
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isStreaming = false;
  String _debugText = 'Stream başlamadı';

  bool _isProcessing = false;
  late FaceDetectionService _faceDetectionService;
  List<Face> _faces = [];
  double _mouthOpenRatio = 0.0;
  bool _isMouthOpen = false;

  @override
  void initState() {
    super.initState();

    _faceDetectionService = FaceDetectionService();

    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();

      if (cameras.isEmpty) {
        setState(() {
          _debugText = 'Hiç kamera bulunamadı';
        });
        return;
      }

      for (final cam in cameras) {
        debugPrint('Camera: ${cam.name}, lens: ${cam.lensDirection}');
      }

      final selectedCamera = cameras.first;

      _cameraController = CameraController(
        selectedCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );

      await _cameraController!.initialize();

      setState(() {
        _debugText = 'Kamera initialize oldu';
      });

      if (!_cameraController!.value.isInitialized) {
        setState(() {
          _debugText = 'Kamera initialize edilemedi';
        });
        return;
      }

      await _cameraController!.startImageStream((image) async {
        if (!_isStreaming) {
          _isStreaming = true;
        }

        if (_isProcessing) return;
        _isProcessing = true;

        try {
          final inputImage = _inputImageFromCameraImage(image);
          if (inputImage == null) {
            setState(() {
              _debugText =
              'InputImage oluşturulamadı | Format group: ${image.format.group}';
            });
            return;
          }

          final result = await _faceDetectionService.processImage(inputImage);

          setState(() {
            _faces = result.face != null ? [result.face!] : [];
            _mouthOpenRatio = result.mouthOpenRatio;
            _isMouthOpen = result.isMouthOpen;

            _debugText =
            'Faces: ${result.faceDetected ? 1 : 0} | '
                'Ratio: ${result.mouthOpenRatio.toStringAsFixed(3)} | '
                'Mouth: ${result.isMouthOpen ? "OPEN" : "CLOSED"}';
          });
        } catch (e) {
          setState(() {
            _debugText = 'Face detection error: $e';
          });
        } finally {
          _isProcessing = false;
        }
      });

      if (!mounted) return;

      setState(() {
        _isCameraInitialized = true;
      });
    } catch (e) {
      setState(() {
        _debugText = 'Kamera hatası: $e';
      });
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _faceDetectionService.dispose();
    super.dispose();
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    final camera = _cameraController;
    if (camera == null) return null;

    final rotation =
    InputImageRotationValue.fromRawValue(camera.description.sensorOrientation);
    if (rotation == null) return null;

    // Android için sadece NV21 destekle
    if (image.format.group != ImageFormatGroup.nv21) {
      return null;
    }

    if (image.planes.isEmpty) return null;

    final bytes = image.planes.first.bytes;

    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: InputImageFormat.nv21,
      bytesPerRow: image.planes.first.bytesPerRow,
    );

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: metadata,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ML Kit Test Camera'),
      ),
      body: _isCameraInitialized && _cameraController != null
          ? Stack(
        children: [
          Positioned.fill(
            child: CameraPreview(_cameraController!),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: FacePainter(_faces),
            ),
          ),
          Positioned(
            top: 100,
            left: 16,
            child: Container(
              padding: const EdgeInsets.all(12),
              color: Colors.black54,
              child: Text(
                'Ratio: ${_mouthOpenRatio.toStringAsFixed(3)}\n'
                    'Mouth: ${_isMouthOpen ? "OPEN" : "CLOSED"}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Container(
              padding: const EdgeInsets.all(12),
              color: Colors.black54,
              child: Text(
                _debugText,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                ),
              ),
            ),
          ),
        ],
      )
          : const Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}