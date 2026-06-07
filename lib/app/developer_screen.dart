import 'package:alarm/alarm.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:medTrackPlus/app/screens_registry.dart';
import 'package:medTrackPlus/beta/beta_registry.dart';
import 'package:medTrackPlus/main.dart';
import 'package:medTrackPlus/services/database_service.dart';
import 'package:medTrackPlus/services/patient_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DeveloperScreen extends StatelessWidget {
  const DeveloperScreen({super.key});

  /// Saat kurmadan hızlı uçtan uca test: ilk uygun entity (önce hasta,
  /// yoksa cihaz) için alarm metadata'sı yazar ve 2 saniye sonrasına gerçek
  /// bir alarm kurar. Alarm, normal akışla (ringStream → tam ekran
  /// AlarmRingScreen → durdur → doğrulama) o anki saatte çalar.
  Future<void> _triggerMockAlarm(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Mock alarm: oturum açık değil')));
      return;
    }
    final email = user.email ?? '';

    // Entity seçimi: önce hasta profili, yoksa cihaz.
    String? entityId;
    final patients =
        await PatientService().getAllUserPatients(user.uid, email);
    if (patients.isNotEmpty) {
      entityId = patients.first['id'];
    } else {
      final devices =
          await DatabaseService().getAllUserDevices(user.uid, email);
      if (devices.isNotEmpty) entityId = devices.first['mac'];
    }
    if (entityId == null) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Mock alarm: hiç hasta/cihaz bulunamadı')));
      return;
    }

    // İlaç adı: entity dokümanındaki ilk ilaç (yoksa 'Mock İlaç').
    String medName = 'Mock İlaç';
    try {
      final isPatient = DatabaseService.isPatientId(entityId);
      final doc = await FirebaseFirestore.instance
          .collection(isPatient ? 'patients' : 'dispenser')
          .doc(entityId)
          .get();
      final List<dynamic> meds =
          doc.data()?[isPatient ? 'medications' : 'section_config'] ?? [];
      if (meds.isNotEmpty && (meds.first['name'] ?? '').toString().isNotEmpty) {
        medName = meds.first['name'];
      }
    } catch (_) {}

    // Metadata: AlarmRingScreen bunu okuyup doğrulamayı bölüm 0 için başlatır.
    const mockId = 999999; // entity ID aralıklarının (1000-701000) dışında
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('alarm_meta_$mockId', '$entityId|0|$medName');

    if (!context.mounted) return;
    final lang = context.locale.languageCode;
    final sound =
        lang == 'tr' ? 'assets/alarms/alarm_tr.mp3' : 'assets/alarms/alarm_en.mp3';

    await Alarm.set(
      alarmSettings: AlarmSettings(
        id: mockId,
        dateTime: DateTime.now().add(const Duration(seconds: 2)),
        assetAudioPath: sound,
        loopAudio: true,
        vibrate: true,
        volumeSettings: VolumeSettings.fade(
          volume: 1.0,
          fadeDuration: const Duration(seconds: 3),
        ),
        androidFullScreenIntent: true,
        notificationSettings: NotificationSettings(
          title: 'medicine_time_title'.tr(),
          body: medName,
          stopButton: 'stop_alarm'.tr(),
          icon: 'notification_bar_icon',
        ),
      ),
    );

    messenger.showSnackBar(SnackBar(
        content: Text('Mock alarm kuruldu → 2 sn içinde çalacak ($medName)')));
  }

  @override
  Widget build(BuildContext context) {
    final betaScreens = BetaRegistry.screens;
    final allScreens = ScreensRegistry.screens;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppColors.deepSea),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Row(
          children: [
            const Icon(Icons.code_rounded, color: AppColors.skyBlue, size: 20),
            const SizedBox(width: 8),
            Text(
              'Developer Mode',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.deepSea,
              ),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ── QUICK ACTIONS ─────────────────────────────────────────
          _SectionHeader(
            label: 'Quick Actions',
            count: 1,
            color: const Color(0xFF36C0A6),
            icon: Icons.bolt_rounded,
          ),
          const SizedBox(height: 12),
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF36C0A6).withOpacity(0.2)),
            ),
            child: ListTile(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              leading: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFF36C0A6).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.alarm_add_rounded,
                    color: Color(0xFF36C0A6), size: 22),
              ),
              title: Text('Mock Alarm (Ring Now)',
                  style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.deepSea)),
              subtitle: Text(
                  'İlk hasta/cihaz için 2 sn sonra gerçek alarm çalar — tam akış testi',
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      color: AppColors.deepSea.withOpacity(0.5))),
              trailing: const Icon(Icons.play_arrow_rounded,
                  color: Color(0xFF36C0A6)),
              onTap: () => _triggerMockAlarm(context),
            ),
          ),

          const SizedBox(height: 28),

          // ── BETA SCREENS ──────────────────────────────────────────
          _SectionHeader(
            label: 'Beta Screens',
            count: betaScreens.length,
            color: const Color(0xFFE8A020),
            icon: Icons.science_rounded,
          ),
          const SizedBox(height: 12),
          if (betaScreens.isEmpty)
            _EmptySection(
              message: 'No beta screens yet.\nAdd entries to lib/beta/beta_registry.dart',
              color: const Color(0xFFE8A020),
            )
          else
            ...betaScreens.map((s) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ScreenCard(
                name: s.name,
                description: s.description,
                icon: Icons.science_rounded,
                accentColor: const Color(0xFFE8A020),
                builder: s.builder,
              ),
            )),

          const SizedBox(height: 28),

          // ── ALL SCREENS ───────────────────────────────────────────
          _SectionHeader(
            label: 'All Screens',
            count: allScreens.length,
            color: AppColors.skyBlue,
            icon: Icons.layers_rounded,
          ),
          const SizedBox(height: 12),
          ...allScreens.map((s) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _ScreenCard(
              name: s.name,
              description: s.description,
              icon: s.icon,
              accentColor: AppColors.skyBlue,
              builder: s.builder,
            ),
          )),

          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  final IconData icon;

  const _SectionHeader({
    required this.label,
    required this.count,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 8),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: color,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '$count',
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Divider(color: color.withOpacity(0.2), thickness: 1)),
      ],
    );
  }
}

class _EmptySection extends StatelessWidget {
  final String message;
  final Color color;

  const _EmptySection({required this.message, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.15)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, color: color.withOpacity(0.6), size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: color.withOpacity(0.7),
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScreenCard extends StatelessWidget {
  final String name;
  final String description;
  final IconData icon;
  final Color accentColor;
  final WidgetBuilder builder;

  const _ScreenCard({
    required this.name,
    required this.description,
    required this.icon,
    required this.accentColor,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accentColor.withOpacity(0.12)),
        boxShadow: [
          BoxShadow(
            color: AppColors.deepSea.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: builder),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: accentColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: accentColor, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppColors.deepSea,
                        ),
                      ),
                      if (description.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          description,
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: AppColors.deepSea.withOpacity(0.5),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_ios_rounded, color: accentColor.withOpacity(0.5), size: 14),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
