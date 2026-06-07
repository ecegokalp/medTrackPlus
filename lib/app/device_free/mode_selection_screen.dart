import 'package:easy_localization/easy_localization.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:medTrackPlus/app/device_free/patient_setup_screen.dart';
import 'package:medTrackPlus/beta/enums/app_mode.dart';
import 'package:medTrackPlus/features/ble_provisioning/sync_screen.dart';
import 'package:medTrackPlus/main.dart' show AppColors;
import 'package:medTrackPlus/services/app_mode_service.dart';

/// Onboarding step: "Do you have a MedTrack+ device?"
///
/// - Yes → device mode → BLE provisioning (SyncScreen)
/// - No  → device-free mode → PatientSetupScreen (single/multi patient)
///
/// The choice is persisted (SharedPreferences + users/{uid}) and can be
/// changed later from Settings.
class AppModeSelectionScreen extends StatefulWidget {
  const AppModeSelectionScreen({super.key});

  @override
  State<AppModeSelectionScreen> createState() => _AppModeSelectionScreenState();
}

class _AppModeSelectionScreenState extends State<AppModeSelectionScreen> {
  final AppModeService _modeService = AppModeService();
  bool _saving = false;

  Future<void> _select(AppMode mode) async {
    if (_saving) return;
    setState(() => _saving = true);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    await _modeService.saveMode(mode, uid: uid);
    if (!mounted) return;

    if (mode == AppMode.device) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const SyncScreen(isOnboarding: true)),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const PatientSetupScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'mode_selection_title'.tr(),
                style: GoogleFonts.inter(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: AppColors.deepSea,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'mode_selection_subtitle'.tr(),
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color: AppColors.deepSea.withOpacity(0.5),
                ),
              ),
              const Spacer(),
              _ModeCard(
                icon: Icons.medication_liquid_rounded,
                title: 'mode_device_title'.tr(),
                subtitle: 'mode_device_subtitle'.tr(),
                onTap: () => _select(AppMode.device),
              ),
              const SizedBox(height: 16),
              _ModeCard(
                icon: Icons.smartphone_rounded,
                title: 'mode_device_free_title'.tr(),
                subtitle: 'mode_device_free_subtitle'.tr(),
                onTap: () => _select(AppMode.deviceFree),
              ),
              const Spacer(),
              if (_saving)
                const Center(child: CircularProgressIndicator()),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ModeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.skyBlue.withOpacity(0.15)),
        boxShadow: [
          BoxShadow(
            color: AppColors.deepSea.withOpacity(0.07),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [AppColors.skyBlue, AppColors.deepSea],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, color: Colors.white, size: 28),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppColors.deepSea,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          color: AppColors.deepSea.withOpacity(0.55),
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.arrow_forward_ios_rounded,
                    color: AppColors.skyBlue, size: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
