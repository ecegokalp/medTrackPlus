library;

import 'dart:math';
import 'package:camera/camera.dart';
import 'camera_state.dart';

abstract class CvProcessor {
  Future<CvResult> processFrame(CameraImage image);
  void dispose();
}

class MockCvProcessor implements CvProcessor {
  final Random _random = Random();
  final Duration _simulatedDelay;

  MockCvProcessor({
    Duration simulatedDelay = const Duration(milliseconds: 50),
  }) : _simulatedDelay = simulatedDelay;

  @override
  Future<CvResult> processFrame(CameraImage image) async {
    final stopwatch = Stopwatch()..start();

    await Future.delayed(_simulatedDelay);
    _analyzeFrame(image);

    final objectCount = _random.nextInt(5);
    final boxes = List.generate(objectCount, (i) => _generateMockBox(image));

    stopwatch.stop();

    return CvResult(
      detectedObjects: objectCount,
      confidence: 0.5 + _random.nextDouble() * 0.5,
      processingTime: stopwatch.elapsed,
      boundingBoxes: boxes,
    );
  }

  /// Reads Y plane brightness from the YUV420 frame.
  /// planes[0]=Y (full res), planes[1]=U (half), planes[2]=V (half)
  FrameInfo _analyzeFrame(CameraImage image) {
    final yPlane = image.planes[0];

    double avgBrightness = 0;
    final bytes = yPlane.bytes;
    final sampleSize = min(bytes.length, 1000);
    for (int i = 0; i < sampleSize; i++) {
      avgBrightness += bytes[i];
    }
    avgBrightness /= sampleSize;

    return FrameInfo(
      width: image.width,
      height: image.height,
      planeCount: image.planes.length,
      avgBrightness: avgBrightness / 255.0,
      bytesPerRow: yPlane.bytesPerRow,
    );
  }

  BoundingBox _generateMockBox(CameraImage image) {
    final labels = ['pill', 'tablet', 'capsule', 'bottle', 'hand'];
    final w = 0.1 + _random.nextDouble() * 0.3;
    final h = 0.1 + _random.nextDouble() * 0.3;

    return BoundingBox(
      x: _random.nextDouble() * (1 - w),
      y: _random.nextDouble() * (1 - h),
      width: w,
      height: h,
      label: labels[_random.nextInt(labels.length)],
      confidence: 0.6 + _random.nextDouble() * 0.4,
    );
  }

  @override
  void dispose() {}
}

class FrameInfo {
  final int width;
  final int height;
  final int planeCount;
  final double avgBrightness;
  final int bytesPerRow;

  const FrameInfo({
    required this.width,
    required this.height,
    required this.planeCount,
    required this.avgBrightness,
    required this.bytesPerRow,
  });

  @override
  String toString() =>
      'Frame ${width}x$height, planes: $planeCount, brightness: ${(avgBrightness * 100).toStringAsFixed(1)}%';
}