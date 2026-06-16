import 'package:flutter/material.dart';
import 'package:medTrackPlus/beta/camera_test/camera_test_screen.dart';
import 'package:medTrackPlus/beta/camera_test/unified_test_screen.dart';
import 'package:medTrackPlus/beta/cv/cv_test_screen.dart';
import 'package:medTrackPlus/beta/cv_v2/cv_v2_lab_screen.dart';
import 'package:medTrackPlus/beta/mlkit_test/mlkit_test_screen.dart';
import 'package:medTrackPlus/beta/mlkit_test/pill_detection_test_screen.dart';
import 'package:medTrackPlus/beta/mode_selection_screen.dart';
import 'package:medTrackPlus/beta/verification_screen/verification_screen.dart';
import 'package:medTrackPlus/app/relative_review_screen.dart';
import 'package:medTrackPlus/app/reports_screen.dart';

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
    // -- Efe: Foundation --
    BetaScreen(
      name: 'Mode Selection',
      description: 'Device vs Device-Free mode picker',
      builder: (_) => const ModeSelectionScreen(),
    ),
    BetaScreen(
      name: 'Verification Screen',
      description: 'CV pipeline: pill detection + mouth verification',
      builder: (_) => const VerificationScreen(),
    ),

    // -- Ipek: ML Kit --
    BetaScreen(
      name: 'MLKit Face Detection',
      description: 'Face detection & contour painting test',
      builder: (_) => const MlkitTestScreen(),
    ),
    BetaScreen(
      name: 'Pill Detection Test',
      description: 'ML Kit pill-on-tongue detection pipeline test',
      builder: (_) => const PillDetectionTestScreen(),
    ),

    // -- Ecenaz: Camera & State Machine --
    BetaScreen(
      name: 'Camera Test',
      description: 'CV Processor, video recording & upload',
      builder: (_) => const CameraTestScreen(),
    ),

    // -- Merged: Ipek + Ecenaz --
    BetaScreen(
      name: 'Unified Detection Test',
      description: 'ML Kit detection + video recording + upload (birlesik)',
      builder: (_) => const UnifiedTestScreen(),
    ),

    // -- V2 EXPERIMENTAL: improved accuracy pipeline (does NOT touch prod) --
    BetaScreen(
      name: 'CV v2 Accuracy Lab',
      description:
          'V2 pipeline testi: rotasyon fix + adaptif eşik + chroma + blob. '
          'Canlı ratio/accuracy HUD, açı sınır uyarıları, yutma doğrulama, '
          'video kayıt + upload, eşik slider\'ları',
      builder: (_) => const CvV2LabScreen(),
    ),

    // -- CV pipeline benchmark --
    BetaScreen(
      name: 'CV Pipeline Test',
      description:
          'MLKitCVProcessor: Face+Pill+Tracker+Throttler — latency HUD',
      builder: (_) => const CvTestScreen(),
    ),

    // -- Doga: Review --
    BetaScreen(
      name: 'Relative Review Screen',
      description: 'Verification review with video, scores & approve/deny',
      builder: (_) => const RelativeReviewScreen(
        macAddress: 'ABCDEF123456',
        verificationId: 'XayfII1aJPBK9jvpis9q',
      ),
    ),

    // -- Doga: Reports --
    BetaScreen(
      name: 'Reports Screen',
      description: 'Dispense + Verification stats with charts',
      builder: (_) => const ReportsScreen(
        macAddress: 'ABCDEF123456',
        targetUserId: 'testuser123',
      ),
    ),
  ];
}
