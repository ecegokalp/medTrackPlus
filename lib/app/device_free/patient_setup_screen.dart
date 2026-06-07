import 'package:easy_localization/easy_localization.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:medTrackPlus/app/main_hub.dart';
import 'package:medTrackPlus/main.dart' show AppColors;
import 'package:medTrackPlus/services/app_mode_service.dart';
import 'package:medTrackPlus/services/patient_service.dart';

/// Device-free onboarding step 2: single patient or multiple patients?
///
/// - Single   → asks for the patient's name (default: account display name,
///              because in single mode the account owner IS the patient),
///              creates the patient profile, then goes to MainHub where the
///              dashboard directly shows that patient's medications.
/// - Multiple → goes to MainHub where the dashboard is a grouped patient
///              list (profiles are added there).
///
/// The single/multi preference can be changed later from Settings.
class PatientSetupScreen extends StatefulWidget {
  const PatientSetupScreen({super.key});

  @override
  State<PatientSetupScreen> createState() => _PatientSetupScreenState();
}

class _PatientSetupScreenState extends State<PatientSetupScreen> {
  final AppModeService _modeService = AppModeService();
  final PatientService _patientService = PatientService();
  bool _busy = false;

  Future<void> _goToHub() async {
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const MainHub()),
      (_) => false,
    );
  }

  Future<void> _chooseSingle() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final nameController =
        TextEditingController(text: user.displayName ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('patient_name_title'.tr()),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: InputDecoration(hintText: 'patient_name_hint'.tr()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('cancel'.tr()),
          ),
          ElevatedButton(
            onPressed: () =>
                Navigator.pop(context, nameController.text.trim()),
            child: Text('save'.tr()),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;

    setState(() => _busy = true);
    try {
      await _modeService.saveMultiPatient(false, uid: user.uid);
      await _patientService.createPatient(
        uid: user.uid,
        rawEmail: user.email ?? '',
        patientName: name,
      );
      await _goToHub();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('error_occurred'.tr(args: [e.toString()]))),
        );
      }
    }
  }

  Future<void> _chooseMulti() async {
    final user = FirebaseAuth.instance.currentUser;
    setState(() => _busy = true);
    await _modeService.saveMultiPatient(true, uid: user?.uid);
    await _goToHub();
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
                'patient_setup_title'.tr(),
                style: GoogleFonts.inter(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: AppColors.deepSea,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'patient_setup_subtitle'.tr(),
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color: AppColors.deepSea.withOpacity(0.5),
                ),
              ),
              const Spacer(),
              _ChoiceCard(
                icon: Icons.person_rounded,
                title: 'single_patient_title'.tr(),
                subtitle: 'single_patient_subtitle'.tr(),
                onTap: _busy ? null : _chooseSingle,
              ),
              const SizedBox(height: 16),
              _ChoiceCard(
                icon: Icons.groups_rounded,
                title: 'multi_patient_title'.tr(),
                subtitle: 'multi_patient_subtitle'.tr(),
                onTap: _busy ? null : _chooseMulti,
              ),
              const Spacer(),
              if (_busy) const Center(child: CircularProgressIndicator()),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChoiceCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  const _ChoiceCard({
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
                      colors: [AppColors.turquoise, AppColors.skyBlue],
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
