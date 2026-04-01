import 'package:flutter/material.dart';
import 'package:medTrackPlus/beta/mlkit_test/mlkit_test_screen.dart';
import 'package:medTrackPlus/beta/mlkit_test/pill_detection_test_screen.dart';
import 'package:medTrackPlus/beta/mode_selection_screen.dart';
import 'package:medTrackPlus/beta/verification_screen/verification_screen.dart';

/// Represents a single beta screen entry.
class BetaScreen {
  final String name;
  final String description;
  final WidgetBuilder builder;

  const BetaScreen({
    required this.name,
    required this.description,
    required this.builder,
  });
}

/// Registry of all beta screens under development.
/// To add a new beta screen:
///   1. Create your screen file in lib/beta/
///   2. Import it below and add a BetaScreen entry to the list.
class BetaRegistry {
  static final List<BetaScreen> screens = [
    BetaScreen(
      name: 'MLKit Face Detection',
      description: 'Face detection & contour painting test',
      builder: (_) => const MlkitTestScreen(),
    ),
    BetaScreen(
      name: 'Pill Detection Test',
      description: 'Face + mouth open + pill on tongue detection',
      builder: (_) => const PillDetectionTestScreen(),
    ),
    BetaScreen(
      name: 'Verification Screen',
      description: 'CV pipeline: pill detection + mouth verification',
      builder: (_) => const VerificationScreen(),
    ),
    BetaScreen(
      name: 'Mode Selection Screen',
      description: 'Device vs Device-Free mode picker',
      builder: (_) => const ModeSelectionScreen(),
    ),
  ];
}
