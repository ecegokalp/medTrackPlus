import 'dart:ui';

/// V2 pill-position tracker: exponential smoothing with outlier rejection.
///
/// Compared to the V1 rolling-mean tracker:
///  • EMA reacts faster to genuine movement while still suppressing jitter
///    (a 10-frame mean lags ~0.5 s behind the pill at 20 fps);
///  • observations that jump implausibly far in one frame (reflection
///    flicker, contour glitch) are rejected instead of dragging the mean.
class PillTrackerV2 {
  PillTrackerV2({this.alpha = 0.45, this.maxJumpFraction = 1.2});

  /// EMA factor (higher = snappier).
  final double alpha;

  /// Reject observations whose center jumps more than this fraction of the
  /// current smoothed rect's diagonal in a single frame.
  final double maxJumpFraction;

  Rect? _smoothed;
  Rect? _lastSeen;
  int _rejectedCount = 0;

  int get rejectedCount => _rejectedCount;

  void add(Rect rect) {
    _lastSeen = rect;
    final s = _smoothed;
    if (s == null) {
      _smoothed = rect;
      return;
    }
    final diag = s.size.longestSide;
    final jump = (rect.center - s.center).distance;
    if (diag > 0 && jump > maxJumpFraction * diag) {
      _rejectedCount++;
      return; // outlier — keep the smoothed estimate
    }
    _smoothed = Rect.fromLTRB(
      alpha * rect.left + (1 - alpha) * s.left,
      alpha * rect.top + (1 - alpha) * s.top,
      alpha * rect.right + (1 - alpha) * s.right,
      alpha * rect.bottom + (1 - alpha) * s.bottom,
    );
  }

  /// Clears smoothing but keeps lastSeen (pill briefly out of frame).
  void clearBuffer() => _smoothed = null;

  void reset() {
    _smoothed = null;
    _lastSeen = null;
    _rejectedCount = 0;
  }

  Rect? get smoothed => _smoothed;
  Rect? get lastSeen => _lastSeen;
}
