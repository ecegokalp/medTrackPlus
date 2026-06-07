import 'package:medTrackPlus/services/app_mode_service.dart';
import 'package:medTrackPlus/services/auth_service.dart';
import 'package:medTrackPlus/services/consent_service.dart';
import 'package:medTrackPlus/services/database_service.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:medTrackPlus/main.dart'; // AppColors
import 'package:medTrackPlus/app/developer_screen.dart';
import 'package:medTrackPlus/app/main_hub.dart';
import 'package:medTrackPlus/app/reports_screen.dart'; // Rapor ekranı
import 'package:medTrackPlus/beta/enums/app_mode.dart';
import 'package:medTrackPlus/beta/providers/mode_provider.dart';
import 'package:medTrackPlus/widgets/kvkk_consent_dialog.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final DatabaseService _dbService = DatabaseService();
  final AuthService _authService = AuthService();
  final AppModeService _modeService = AppModeService();

  // Sadece feedback özelliği açık olan cihazları tutacak liste
  List<Map<String, String>> _activeFeedbackDevices = [];
  bool _isLoadingDevices = true;

  // Video Doğrulama (KVKK) consent state
  bool _videoConsent = false;
  bool _videoConsentLoaded = false;

  // Uygulama modu state
  bool _multiPatient = false;

  @override
  void initState() {
    super.initState();
    _fetchAndFilterDevices();
    _loadVideoConsent();
    _loadModePrefs();
  }

  Future<void> _loadModePrefs() async {
    final multi = await _modeService.isMultiPatient();
    if (mounted) setState(() => _multiPatient = multi);
  }

  /// Mod değişimi: kalıcı kaydet, modeProvider'ı güncelle ve MainHub'ı
  /// sıfırdan aç (sekmeler ve dashboard yeniden kurulsun).
  Future<void> _changeAppMode(AppMode mode) async {
    if (modeProvider.value == mode) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    await _modeService.saveMode(mode, uid: uid);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const MainHub()),
      (_) => false,
    );
  }

  Future<void> _changeMultiPatient(bool multi) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    await _modeService.saveMultiPatient(multi, uid: uid);
    if (!mounted) return;
    setState(() => _multiPatient = multi);
    // Device-free moddaysak dashboard düzeni değişti → MainHub'ı tazele.
    if (modeProvider.isDeviceFree) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const MainHub()),
        (_) => false,
      );
    }
  }

  Future<void> _loadVideoConsent() async {
    final granted = await ConsentService.isVideoConsentEnabled();
    if (mounted) {
      setState(() {
        _videoConsent = granted;
        _videoConsentLoaded = true;
      });
    }
  }

  Future<void> _onVideoConsentToggle(bool desired) async {
    if (desired) {
      // Kullanıcı açmaya çalışıyor → KVKK dialog'u göster
      final accepted = await KvkkConsentDialog.show(context);
      if (!mounted) return;
      if (accepted) {
        await ConsentService.grantVideoConsent();
        if (!mounted) return;
        setState(() => _videoConsent = true);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('video_consent_enabled_msg'.tr()),
          duration: const Duration(seconds: 2),
        ));
      }
      // Reddedildiyse hiçbir şey yapma — toggle kapalı kalır
    } else {
      // Kullanıcı kapatıyor → onay isteme, direkt revoke
      await ConsentService.revokeVideoConsent();
      if (!mounted) return;
      setState(() => _videoConsent = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('video_consent_disabled_msg'.tr()),
        duration: const Duration(seconds: 2),
      ));
    }
  }

  // Cihazları çek ve sadece feedback açık olanları filtrele
  Future<void> _fetchAndFilterDevices() async {
    final user = await _authService.getOrCreateUser();
    if (user != null && user.email != null) {
      // 1. Tüm cihazları getir
      final allDevices = await _dbService.getAllUserDevices(user.uid, user.email!);

      List<Map<String, String>> filteredList = [];

      // 2. Her cihaz için feedback ayarını kontrol et
      for (var device in allDevices) {
        bool isEnabled = await _dbService.getDeviceFeedbackPreference(user.uid, device['mac']!);
        if (isEnabled) {
          filteredList.add(device);
        }
      }

      if (mounted) {
        setState(() {
          _activeFeedbackDevices = filteredList;
          _isLoadingDevices = false;
        });
      }
    } else {
      if (mounted) setState(() => _isLoadingDevices = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
          title: Text("settings_title".tr(),
              style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.deepSea)),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: AppColors.deepSea)
      ),
      body: _isLoadingDevices
          ? const Center(child: CircularProgressIndicator())
          : ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // 1. Dil Seçimi
          ListTile(
            leading: const Icon(Icons.language, color: AppColors.deepSea),
            title: Text("language_option".tr()),
            trailing: DropdownButton<String>(
                value: context.locale.languageCode,
                underline: Container(),
                items: const [
                  DropdownMenuItem(value: 'tr', child: Text("🇹🇷 Türkçe")),
                  DropdownMenuItem(value: 'en', child: Text("🇺🇸 English"))
                ],
                onChanged: (v) {
                  if (v != null) {
                    context.setLocale(Locale(v == 'tr' ? 'tr' : 'en', v == 'tr' ? 'TR' : 'US'));
                  }
                }
            ),
          ),

          const Divider(),

          // --- UYGULAMA MODU (device / device-free) ---
          ListTile(
            leading: const Icon(Icons.swap_horiz_rounded, color: AppColors.deepSea),
            title: Text('app_mode_title'.tr(),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              modeProvider.isDeviceFree
                  ? 'mode_device_free_title'.tr()
                  : 'mode_device_title'.tr(),
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
            trailing: DropdownButton<AppMode>(
              value: modeProvider.value,
              underline: Container(),
              items: [
                DropdownMenuItem(
                    value: AppMode.device,
                    child: Text('app_mode_device'.tr())),
                DropdownMenuItem(
                    value: AppMode.deviceFree,
                    child: Text('app_mode_device_free'.tr())),
              ],
              onChanged: (mode) {
                if (mode != null) _changeAppMode(mode);
              },
            ),
          ),

          // --- DASHBOARD DÜZENİ (yalnızca device-free) ---
          if (modeProvider.isDeviceFree)
            SwitchListTile(
              secondary: const Icon(Icons.groups_rounded, color: AppColors.deepSea),
              title: Text('multi_patient_setting_title'.tr(),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                _multiPatient
                    ? 'multi_patient_setting_on'.tr()
                    : 'multi_patient_setting_off'.tr(),
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
              value: _multiPatient,
              activeColor: AppColors.skyBlue,
              onChanged: _changeMultiPatient,
            ),

          const Divider(),

          // Developer Mode
          ListTile(
            leading: const Icon(Icons.code_rounded, color: AppColors.deepSea),
            title: Text('developer_mode_title'.tr()),
            subtitle: Text('developer_mode_subtitle'.tr()),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DeveloperScreen()),
            ),
          ),

          const Divider(),

          // Video Doğrulama Kaydı (KVKK)
          SwitchListTile(
            secondary: const Icon(Icons.videocam_rounded,
                color: AppColors.deepSea),
            title: Text(
              'video_verification_recording_title'.tr(),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              _videoConsent
                  ? 'video_consent_active_desc'.tr()
                  : 'video_consent_inactive_desc'.tr(),
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
            value: _videoConsent,
            activeColor: AppColors.skyBlue,
            onChanged: _videoConsentLoaded ? _onVideoConsentToggle : null,
          ),
          if (_videoConsent)
            Padding(
              padding: const EdgeInsets.only(left: 72, right: 16, bottom: 8),
              child: Text(
                'video_retention_note'.tr(),
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade500,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),

          const Divider(),

          // 2. Dispenser Raporları (Sadece Aktif Olanlar)
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              leading: const Icon(Icons.bar_chart_rounded, color: AppColors.deepSea),
              title: Text("dispense_reports_title".tr(), style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text("view_reports_for".tr()),
              children: [
                if(_activeFeedbackDevices.isEmpty)
                // AKTİF CİHAZ YOKSA GRİ PLACEHOLDER
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20.0),
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300)
                    ),
                    child: Column(
                      children: [
                        Icon(Icons.speaker_notes_off, color: Colors.grey.shade400, size: 30),
                        const SizedBox(height: 8),
                        Text(
                          "responsive_feedback_inactive".tr(), // "Geri bildirim kapalı"
                          style: TextStyle(color: Colors.grey.shade500, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "enable_feedback_hint".tr(), // DÜZELTİLDİ: "Cihazınızın alarm ayarlarından..."
                          style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  )
                else
                // AKTİF CİHAZLAR VARSA LİSTELE
                  ..._activeFeedbackDevices.map((device) {
                    return ListTile(
                      contentPadding: const EdgeInsets.only(left: 72, right: 16),
                      title: Text(
                          device['name'] ?? "unknown_device".tr(),
                          style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.deepSea)
                      ),
                      subtitle: Text(
                          device['mac'] ?? "",
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 12)
                      ),
                      trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                      onTap: () {
                        // Kendi raporumuzu açıyoruz (targetUserId null gider)
                        Navigator.push(context, MaterialPageRoute(builder: (context) => ReportsScreen(macAddress: device['mac']!)));
                      },
                    );
                  })
              ],
            ),
          ),
        ],
      ),
    );
  }
}