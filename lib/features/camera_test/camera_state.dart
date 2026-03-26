library;

import 'package:camera/camera.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// -- Camera States --

sealed class CameraState {
  const CameraState();
}

class CameraIdle extends CameraState {
  const CameraIdle();
}

class CameraInitializing extends CameraState {
  const CameraInitializing();
}

class CameraPreviewing extends CameraState {
  final CameraController controller;
  const CameraPreviewing(this.controller);
}

class CameraStreaming extends CameraState {
  final CameraController controller;
  final int frameCount;
  final CvResult? lastResult;
  const CameraStreaming(this.controller, {this.frameCount = 0, this.lastResult});
}

class CameraRecording extends CameraState {
  final CameraController controller;
  final DateTime startedAt;
  const CameraRecording(this.controller, this.startedAt);
}

class CameraCompressing extends CameraState {
  final String originalPath;
  final double progress;
  const CameraCompressing(this.originalPath, {this.progress = 0.0});
}

class CameraUploading extends CameraState {
  final String filePath;
  final double progress;
  const CameraUploading(this.filePath, {this.progress = 0.0});
}

class CameraDone extends CameraState {
  final String? downloadUrl;
  final String message;
  const CameraDone({this.downloadUrl, this.message = 'Done'});
}

class CameraError extends CameraState {
  final String message;
  final CameraState previousState;
  const CameraError(this.message, this.previousState);
}

// -- CV Result --

class CvResult {
  final int detectedObjects;
  final double confidence;
  final Duration processingTime;
  final List<BoundingBox> boundingBoxes;

  const CvResult({
    required this.detectedObjects,
    required this.confidence,
    required this.processingTime,
    this.boundingBoxes = const [],
  });
}

class BoundingBox {
  final double x, y, width, height;
  final String label;
  final double confidence;

  const BoundingBox({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.label,
    required this.confidence,
  });
}

// -- Camera Notifier (State Machine) --

class CameraNotifier extends StateNotifier<CameraState> {
  CameraNotifier() : super(const CameraIdle());

  CameraController? _controller;
  List<CameraDescription>? _cameras;

  Future<List<CameraDescription>> get cameras async {
    _cameras ??= await availableCameras();
    return _cameras!;
  }

  Future<void> initialize({int cameraIndex = 0}) async {
    state = const CameraInitializing();
    try {
      final cams = await cameras;
      if (cams.isEmpty) {
        state = const CameraError('No camera found', CameraIdle());
        return;
      }

      _controller = CameraController(
        cams[cameraIndex],
        ResolutionPreset.medium,
        enableAudio: true,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _controller!.initialize();
      state = CameraPreviewing(_controller!);
    } catch (e) {
      state = CameraError('Failed to initialize camera: $e', const CameraIdle());
    }
  }

  /// Starts image stream and processes every [skipFrames+1]th frame via [onFrame].
  Future<void> startStreaming({
    required Future<CvResult> Function(CameraImage image) onFrame,
    int skipFrames = 2,
  }) async {
    if (_controller == null || state is! CameraPreviewing) return;

    int frameIndex = 0;
    int processedCount = 0;

    state = CameraStreaming(_controller!, frameCount: 0);

    _controller!.startImageStream((CameraImage image) async {
      frameIndex++;
      if (frameIndex % (skipFrames + 1) != 0) return;

      try {
        final result = await onFrame(image);
        processedCount++;

        if (state is CameraStreaming) {
          state = CameraStreaming(
            _controller!,
            frameCount: processedCount,
            lastResult: result,
          );
        }
      } catch (_) {}
    });
  }

  Future<void> stopStreaming() async {
    if (_controller == null) return;
    try {
      await _controller!.stopImageStream();
    } catch (_) {}
    state = CameraPreviewing(_controller!);
  }

  Future<void> startRecording() async {
    if (_controller == null) return;

    if (state is CameraStreaming) {
      await stopStreaming();
    }

    try {
      await _controller!.startVideoRecording();
      state = CameraRecording(_controller!, DateTime.now());
    } catch (e) {
      state = CameraError('Failed to start recording: $e', CameraPreviewing(_controller!));
    }
  }

  Future<String?> stopRecording() async {
    if (_controller == null || state is! CameraRecording) return null;

    try {
      final XFile file = await _controller!.stopVideoRecording();
      state = CameraPreviewing(_controller!);
      return file.path;
    } catch (e) {
      state = CameraError('Failed to stop recording: $e', CameraPreviewing(_controller!));
      return null;
    }
  }

  void setCompressing(String path, {double progress = 0.0}) {
    state = CameraCompressing(path, progress: progress);
  }

  void setUploading(String path, {double progress = 0.0}) {
    state = CameraUploading(path, progress: progress);
  }

  void setDone({String? downloadUrl, String message = 'Done'}) {
    state = CameraDone(downloadUrl: downloadUrl, message: message);
  }

  void setError(String message) {
    state = CameraError(message, state);
  }

  void backToPreview() {
    if (_controller != null) {
      state = CameraPreviewing(_controller!);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }
}

// -- Providers --

final cameraProvider = StateNotifierProvider<CameraNotifier, CameraState>((ref) {
  return CameraNotifier();
});

final frameCountProvider = Provider<int>((ref) {
  final state = ref.watch(cameraProvider);
  if (state is CameraStreaming) return state.frameCount;
  return 0;
});

final lastCvResultProvider = Provider<CvResult?>((ref) {
  final state = ref.watch(cameraProvider);
  if (state is CameraStreaming) return state.lastResult;
  return null;
});