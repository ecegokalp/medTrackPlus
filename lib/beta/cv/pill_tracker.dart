import 'package:flutter/material.dart';

/// Position smoother for the pill-bearing mouth region.
///
/// Holds a rolling window of recent rectangles and exposes the running mean
/// as [smoothed]. Kept deliberately tiny so it can be swapped for a Kalman
/// filter later without touching call-sites.
class PillTracker {
  PillTracker({this.bufferSize = 10});

  final int bufferSize;

  final List<Rect> _buffer = [];
  Rect? _lastSeen;

  /// Records a new observation and updates [lastSeen].
  void add(Rect rect) {
    _buffer.add(rect);
    if (_buffer.length > bufferSize) {
      _buffer.removeAt(0);
    }
    _lastSeen = rect;
  }

  /// Clears the smoothing window but keeps [lastSeen] (used between phases
  /// where the pill briefly leaves frame).
  void clearBuffer() => _buffer.clear();

  /// Full reset — drops the buffer AND the last-seen rect.
  void reset() {
    _buffer.clear();
    _lastSeen = null;
  }

  Rect? get smoothed {
    if (_buffer.isEmpty) return null;
    double l = 0, t = 0, r = 0, b = 0;
    for (final rect in _buffer) {
      l += rect.left;
      t += rect.top;
      r += rect.right;
      b += rect.bottom;
    }
    final n = _buffer.length;
    return Rect.fromLTRB(l / n, t / n, r / n, b / n);
  }

  Rect? get lastSeen => _lastSeen;

  int get bufferLength => _buffer.length;
}