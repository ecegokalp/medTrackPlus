import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_quick_video_encoder/flutter_quick_video_encoder.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:path_provider/path_provider.dart';

/// Software MP4 recorder for the Dev CV Lab.
///
/// Same technique as the production VerificationScreen: frames from the
/// existing imageStream are converted NV21 → RGBA, rotated to portrait and
/// fed to FlutterQuickVideoEncoder at ~10 fps. MediaRecorder is never
/// touched, so ML Kit detection keeps running while recording.
class DevStreamRecorder {
  bool _active = false;
  bool _busy = false;
  bool _configured = false;
  int _encodedFrames = 0;
  DateTime? _lastEncodedAt;
  DateTime? _startedAt;
  String? _outputPath;
  int _encW = 0, _encH = 0;
  int _rotDeg = 0;

  static const Duration _frameInterval = Duration(milliseconds: 100);

  bool get isRecording => _active;
  int get encodedFrames => _encodedFrames;
  DateTime? get startedAt => _startedAt;
  String? get outputPath => _outputPath;

  Duration get elapsed =>
      _startedAt == null ? Duration.zero : DateTime.now().difference(_startedAt!);

  Future<void> start(CameraImage firstFrame, InputImageRotation rotation) async {
    if (_active) return;
    switch (rotation) {
      case InputImageRotation.rotation90deg:
        _rotDeg = 90;
        break;
      case InputImageRotation.rotation180deg:
        _rotDeg = 180;
        break;
      case InputImageRotation.rotation270deg:
        _rotDeg = 270;
        break;
      default:
        _rotDeg = 0;
    }
    final w = firstFrame.width;
    final h = firstFrame.height;
    final swap = _rotDeg == 90 || _rotDeg == 270;
    _encW = swap ? h : w;
    _encH = swap ? w : h;
    if (_encW.isOdd) _encW -= 1;
    if (_encH.isOdd) _encH -= 1;

    final dir = await getTemporaryDirectory();
    _outputPath =
        '${dir.path}/cv_lab_${DateTime.now().millisecondsSinceEpoch}.mp4';

    await FlutterQuickVideoEncoder.setup(
      width: _encW,
      height: _encH,
      fps: 10,
      videoBitrate: 500000,
      audioBitrate: 0,
      audioChannels: 0,
      sampleRate: 0,
      filepath: _outputPath!,
      profileLevel: ProfileLevel.main41,
    );
    _configured = true;
    _encodedFrames = 0;
    _lastEncodedAt = null;
    _startedAt = DateTime.now();
    _active = true;
  }

  /// Call from the imageStream callback on every frame; internally throttled
  /// to ~10 fps. Safe to call while not recording (no-op).
  Future<void> maybeEncode(CameraImage image) async {
    if (!_active || _busy || !_configured) return;
    final now = DateTime.now();
    if (_lastEncodedAt != null &&
        now.difference(_lastEncodedAt!) < _frameInterval) {
      return;
    }
    _lastEncodedAt = now;
    _busy = true;
    try {
      final srcRgba = _nv21ToRgba(image);
      if (srcRgba == null) return;
      final rgba = _rotateRgba(srcRgba, image.width, image.height, _rotDeg);
      if (rgba.length != _encW * _encH * 4) return;
      await FlutterQuickVideoEncoder.appendVideoFrame(rgba);
      _encodedFrames++;
    } catch (e) {
      if (kDebugMode) debugPrint('[DevStreamRecorder] append failed: $e');
    } finally {
      _busy = false;
    }
  }

  /// Finalizes the MP4 and returns its path (null if nothing was recorded).
  Future<String?> stop() async {
    if (!_active) return null;
    _active = false;
    if (!_configured) return null;
    int waited = 0;
    while (_busy && waited < 1000) {
      await Future.delayed(const Duration(milliseconds: 25));
      waited += 25;
    }
    try {
      await FlutterQuickVideoEncoder.finish();
    } catch (e) {
      if (kDebugMode) debugPrint('[DevStreamRecorder] finish failed: $e');
    }
    _configured = false;
    final p = _outputPath;
    _startedAt = null;
    return p;
  }

  Future<void> deleteOutput() async {
    final p = _outputPath;
    _outputPath = null;
    if (p == null) return;
    try {
      final f = File(p);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  // ── Pixel plumbing (same approach as production) ─────────────────────

  Uint8List? _nv21ToRgba(CameraImage image) {
    if (image.planes.isEmpty) return null;
    final w = image.width;
    final h = image.height;
    final out = Uint8List(w * h * 4);

    if (image.planes.length >= 2) {
      final yBytes = image.planes[0].bytes;
      final uvBytes = image.planes[1].bytes;
      final yRowStride = image.planes[0].bytesPerRow;
      final uvRowStride = image.planes[1].bytesPerRow;
      int dst = 0;
      for (int y = 0; y < h; y++) {
        final yRow = y * yRowStride;
        final uvRow = (y >> 1) * uvRowStride;
        for (int x = 0; x < w; x++) {
          final yVal = yBytes[yRow + x] & 0xFF;
          final uvOff = (x >> 1) * 2;
          final v = (uvBytes[uvRow + uvOff] & 0xFF) - 128;
          final u = (uvBytes[uvRow + uvOff + 1] & 0xFF) - 128;
          dst = _writeRgba(out, dst, yVal, u, v);
        }
      }
      return out;
    }

    final bytes = image.planes[0].bytes;
    final yRowStride =
        image.planes[0].bytesPerRow > 0 ? image.planes[0].bytesPerRow : w;
    final yPlaneSize = yRowStride * h;
    if (bytes.length < yPlaneSize) return null;
    int dst = 0;
    for (int y = 0; y < h; y++) {
      final yRow = y * yRowStride;
      final uvRow = yPlaneSize + (y >> 1) * yRowStride;
      for (int x = 0; x < w; x++) {
        final yVal = bytes[yRow + x] & 0xFF;
        final uvOff = (x >> 1) * 2;
        final vIdx = uvRow + uvOff;
        if (vIdx + 1 >= bytes.length) {
          out[dst++] = yVal;
          out[dst++] = yVal;
          out[dst++] = yVal;
          out[dst++] = 255;
          continue;
        }
        final v = (bytes[vIdx] & 0xFF) - 128;
        final u = (bytes[vIdx + 1] & 0xFF) - 128;
        dst = _writeRgba(out, dst, yVal, u, v);
      }
    }
    return out;
  }

  int _writeRgba(Uint8List out, int dst, int yVal, int u, int v) {
    int r = yVal + ((359 * v) >> 8);
    int g = yVal - ((88 * u + 183 * v) >> 8);
    int b = yVal + ((454 * u) >> 8);
    if (r < 0) {
      r = 0;
    } else if (r > 255) {
      r = 255;
    }
    if (g < 0) {
      g = 0;
    } else if (g > 255) {
      g = 255;
    }
    if (b < 0) {
      b = 0;
    } else if (b > 255) {
      b = 255;
    }
    out[dst++] = r;
    out[dst++] = g;
    out[dst++] = b;
    out[dst++] = 255;
    return dst;
  }

  Uint8List _rotateRgba(Uint8List src, int srcW, int srcH, int rotDeg) {
    if (rotDeg == 0) return src;
    final dst = Uint8List(src.length);
    if (rotDeg == 90) {
      final outW = srcH, outH = srcW;
      for (int oy = 0; oy < outH; oy++) {
        for (int ox = 0; ox < outW; ox++) {
          final si = ((srcH - 1 - ox) * srcW + oy) * 4;
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
          final si = ((srcH - 1 - oy) * srcW + (srcW - 1 - ox)) * 4;
          final di = (oy * srcW + ox) * 4;
          dst[di] = src[si];
          dst[di + 1] = src[si + 1];
          dst[di + 2] = src[si + 2];
          dst[di + 3] = 255;
        }
      }
    } else {
      final outW = srcH, outH = srcW;
      for (int oy = 0; oy < outH; oy++) {
        for (int ox = 0; ox < outW; ox++) {
          final si = (ox * srcW + (srcW - 1 - oy)) * 4;
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
}
