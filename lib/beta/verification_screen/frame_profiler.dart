import 'dart:io';
import 'package:flutter/foundation.dart';

/// Lightweight CPU/memory profiler for the verification camera loop.
///
/// Emits a debug-mode log every [_logInterval] containing average
/// detection-frame processing time, processed-vs-skipped counts, and process
/// RSS (resident memory) so the adaptive-frame-skip tuning can be evaluated
/// on-device without attaching Android Studio / Instruments.
class FrameProfiler {
  int _processed = 0;
  int _skipped = 0;
  int _processedUs = 0;

  int _windowProcessed = 0;
  int _windowSkipped = 0;
  int _windowUs = 0;
  DateTime _windowStart = DateTime.now();

  static const Duration _logInterval = Duration(seconds: 5);

  void recordProcessed(int micros, int skipFactor) {
    _processed++;
    _windowProcessed++;
    _processedUs += micros;
    _windowUs += micros;
    _maybeLog(skipFactor);
  }

  void recordSkipped() {
    _skipped++;
    _windowSkipped++;
    _maybeLog(null);
  }

  void _maybeLog(int? skipFactor) {
    final now = DateTime.now();
    final elapsed = now.difference(_windowStart);
    if (elapsed < _logInterval) return;

    if (kDebugMode) {
      final secs = elapsed.inMilliseconds / 1000.0;
      final avgMs = _windowProcessed == 0
          ? 0.0
          : (_windowUs / _windowProcessed) / 1000.0;
      final fpsProc = secs > 0 ? _windowProcessed / secs : 0.0;
      final fpsTotal =
          secs > 0 ? (_windowProcessed + _windowSkipped) / secs : 0.0;
      final rss = _rssMb();
      debugPrint(
        '[FrameProfiler] win=${secs.toStringAsFixed(1)}s '
        'proc=$_windowProcessed skip=$_windowSkipped '
        'avg=${avgMs.toStringAsFixed(1)}ms '
        'fpsProc=${fpsProc.toStringAsFixed(1)} '
        'fpsTotal=${fpsTotal.toStringAsFixed(1)} '
        'curSkip=${skipFactor ?? "-"} '
        'rss=${rss}MB '
        'totalProc=$_processed totalSkip=$_skipped',
      );
    }

    _windowProcessed = 0;
    _windowSkipped = 0;
    _windowUs = 0;
    _windowStart = now;
  }

  String _rssMb() {
    try {
      return (ProcessInfo.currentRss / 1024 / 1024).toStringAsFixed(1);
    } catch (_) {
      return '?';
    }
  }

  String summary() {
    final avgMs =
        _processed == 0 ? 0.0 : (_processedUs / _processed) / 1000.0;
    return 'processed=$_processed skipped=$_skipped '
        'avg=${avgMs.toStringAsFixed(1)}ms';
  }
}