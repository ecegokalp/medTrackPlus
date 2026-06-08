import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:alarm/alarm.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:medTrackPlus/main.dart';
import 'package:medTrackPlus/beta/enums/app_mode.dart';
import 'package:medTrackPlus/beta/providers/mode_provider.dart';
import 'package:medTrackPlus/services/database_service.dart';
import 'package:medTrackPlus/beta/verification_screen/verification_screen.dart';

class AlarmRingScreen extends StatefulWidget {
  final AlarmSettings alarmSettings;
  const AlarmRingScreen({super.key, required this.alarmSettings});

  @override
  State<AlarmRingScreen> createState() => _AlarmRingScreenState();
}

class _AlarmRingScreenState extends State<AlarmRingScreen>
    with SingleTickerProviderStateMixin {
  static const platform = MethodChannel('com.example.medTrackPlus/lock_control');
  // ignore: unused_field
  final DatabaseService _dbService = DatabaseService();

  static const Color colTurquoise = Color(0xFF36C0A6);
  static const Color colSkyBlue = Color(0xFF1D8AD6);
  static const Color colDeepSea = Color(0xFF0F5191);
  static const Color colNightNavy = Color(0xFF0A1F33);

  bool _processing = false;

  String _macAddress = "";
  List<int> _sectionIndices = [];
  List<String> _medicineNames = [];

  late final AnimationController _pulseController;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();


    platform.invokeMethod('showOnLockScreen');

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
    _pulse = Tween<double>(begin: 1.0, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _loadMetadata();
  }

  Future<void> _loadMetadata() async {
    final prefs = await SharedPreferences.getInstance();
    String? metaData = prefs.getString('alarm_meta_${widget.alarmSettings.id}');

    debugPrint("Alarm Çalıyor - Meta Veri: $metaData");

    if (metaData != null && metaData.isNotEmpty) {
      List<String> parts = metaData.split('|');
      if (parts.length >= 3) {
        setState(() {
          _macAddress = parts[0];
          if (parts[1].isNotEmpty) {
            _sectionIndices = parts[1].split(',').map((e) => int.parse(e)).toList();
          }
          if (parts[2].isNotEmpty) {
            _medicineNames = parts[2].split(',');
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  /// ALARMI DURDUR: alarmı kapat, overlay'i kaldır ve doğrulama akışını
  /// GLOBAL navigator üzerinden başlat.
  ///
  /// ÖNEMLİ: Bu ekran MaterialApp.builder'da Navigator'ın ÜSTÜNDE bir
  /// overlay olarak çizilir. Bu yüzden (1) `Navigator.of(context)` burada
  /// kullanılamaz — `navigatorKey` şart; (2) doğrulama ekranının görünmesi
  /// için push'tan ÖNCE overlay (globalAlarmState) temizlenmelidir.
  /// Overlay temizlenince bu widget dispose olur; akışın geri kalanı bu
  /// yüzden widget'a bağlı olmayan statik metoda devredilir.
  Future<void> _handleStop() async {
    if (_processing) return;
    setState(() => _processing = true);
    await Alarm.stop(widget.alarmSettings.id);

    final String mac = _macAddress;
    final List<int> sections = List<int>.from(_sectionIndices);
    final DateTime scheduledTime = widget.alarmSettings.dateTime;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('alarm_meta_${widget.alarmSettings.id}');

    // Overlay'i kaldır → altta kalan Navigator görünür olur, bu widget
    // dispose edilir. Bundan sonra context/setState KULLANMA.
    globalAlarmState.value = null;

    await _runPostAlarmFlow(mac, sections, scheduledTime);
  }

  /// ERTELE: alarmı sustur ve aynı alarmı (metadata'sı korunarak)
  /// 5 dakika sonrasına yeniden kur.
  Future<void> _handleSnooze() async {
    if (_processing) return;
    setState(() => _processing = true);

    await Alarm.stop(widget.alarmSettings.id);
    final snoozedTime = DateTime.now().add(const Duration(minutes: 5));
    try {
      await Alarm.set(
        alarmSettings: widget.alarmSettings.copyWith(dateTime: snoozedTime),
      );
      debugPrint('[AlarmRingScreen] Alarm 5 dk ertelendi → $snoozedTime');
    } catch (e) {
      debugPrint('[AlarmRingScreen] Snooze error: $e');
    }
    // Metadata (alarm_meta_{id}) bilinçli olarak SİLİNMEZ — alarm tekrar
    // çaldığında doğrulama akışı aynı bilgilerle çalışır.

    globalAlarmState.value = null;
    _exitApp();
  }

  /// Widget dispose edildikten sonra da güvenle çalışır: yalnızca global
  /// navigatorKey ve servisler kullanılır.
  static Future<void> _runPostAlarmFlow(
      String mac, List<int> sections, DateTime scheduledTime) async {
    if (mac.isNotEmpty && sections.isNotEmpty) {
      // Karar entity ID'sine göre: 'patient_' önekli ID'ler device-free hasta
      // profilidir (motor yok → doğrudan doğrulama).
      final isPatientAlarm = DatabaseService.isPatientId(mac);
      final isDeviceMode = modeProvider.value == AppMode.device;
      final dbService = DatabaseService();

      for (final section in sections) {
        // Cihaz yolunda önce motoru tetikle (2 deneme).
        if (!isPatientAlarm && isDeviceMode) {
          for (int attempt = 1; attempt <= 2; attempt++) {
            try {
              await dbService.triggerDispense(mac, section);
              await Future.delayed(const Duration(seconds: 3));
              break;
            } catch (e) {
              debugPrint('[AlarmRingScreen] Dispense attempt $attempt failed: $e');
              if (attempt < 2) await Future.delayed(const Duration(seconds: 2));
            }
          }
        }

        try {
          await navigatorKey.currentState?.push(
            MaterialPageRoute(
              builder: (_) => VerificationScreen(
                sectionIndex: section,
                macAddress: mac,
                scheduledAlarmTime: scheduledTime,
              ),
            ),
          );
        } catch (e) {
          debugPrint('[AlarmRingScreen] Verification screen error: $e');
        }
      }
    }

    _exitApp();
  }

  static void _exitApp() {
    try {
      platform.invokeMethod('hideFromLockScreen');
    } catch (e) {
      debugPrint("Lock screen error: $e");
    }

    globalAlarmState.value = null;

    if (Platform.isAndroid) {
      SystemNavigator.pop();
    } else {
      navigatorKey.currentState?.maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: colNightNavy,
        body: _buildAlarmUI(),
      ),
    );
  }

  Widget _buildAlarmUI() {
    return Stack(
      children: [
        // --- ARKA PLAN: sakin, koyu degrade ---
        Container(
          width: double.infinity,
          height: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [colNightNavy, Color(0xFF0C3055), colDeepSea],
              stops: [0.0, 0.55, 1.0],
            ),
          ),
        ),
        // Çok hafif bir ışık halesi — saatin arkasında derinlik hissi.
        Positioned(
          top: 60,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: Container(
              height: 360,
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    colSkyBlue.withOpacity(0.14),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ),

        SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const SizedBox(height: 28),

                          // --- ÜST: küçük "alarm" rozeti ---
                          _buildAlarmChip(),

                          const Spacer(flex: 2),

                          // --- SAAT + TARİH ---
                          _buildClock(),

                          const Spacer(flex: 2),

                          // --- ORTA: buzlu cam ilaç kartı ---
                          _buildMedicineCard(),

                          const Spacer(flex: 3),

                          // --- ALT: aksiyonlar ---
                          _buildActions(),

                          const SizedBox(height: 36),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Üstteki küçük "alarm" rozeti — bildirim başlığını kullanır.
  Widget _buildAlarmChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: Colors.white.withOpacity(0.12), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.alarm_rounded,
              size: 16, color: Colors.white.withOpacity(0.85)),
          const SizedBox(width: 8),
          Text(
            widget.alarmSettings.notificationSettings.title,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.4,
              color: Colors.white.withOpacity(0.85),
              decoration: TextDecoration.none,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  /// Devasa, ince saat + tarih. Saniyede bir güncellenir.
  Widget _buildClock() {
    return StreamBuilder(
      stream: Stream.periodic(const Duration(seconds: 1)),
      builder: (context, snapshot) {
        final now = DateTime.now();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}",
              style: GoogleFonts.inter(
                fontSize: 96,
                fontWeight: FontWeight.w200,
                height: 1.0,
                letterSpacing: -3,
                color: Colors.white,
                decoration: TextDecoration.none,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              DateFormat('EEEE, d MMMM', context.locale.toString()).format(now),
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w400,
                letterSpacing: 0.4,
                color: Colors.white.withOpacity(0.65),
                decoration: TextDecoration.none,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        );
      },
    );
  }

  /// Buzlu cam ilaç kartı: nabız gibi atan hap ikonu + ilaç adları.
  Widget _buildMedicineCard() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.07),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withOpacity(0.12), width: 1),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Nabız animasyonlu hap ikonu
              ScaleTransition(
                scale: _pulse,
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colTurquoise.withOpacity(0.18),
                    border: Border.all(
                        color: colTurquoise.withOpacity(0.35), width: 1),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Image.asset(
                      'assets/single_pill.png',
                      fit: BoxFit.contain,
                      errorBuilder: (c, e, s) => const Icon(
                        Icons.medication_rounded,
                        size: 28,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              // İlaç adları (veya bildirim gövdesi)
              Expanded(
                child: _medicineNames.isNotEmpty
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: _medicineNames
                            .map(
                              (name) => Padding(
                                padding: const EdgeInsets.symmetric(vertical: 3),
                                child: Text(
                                  name,
                                  style: GoogleFonts.inter(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600,
                                    height: 1.25,
                                    color: Colors.white.withOpacity(0.95),
                                    decoration: TextDecoration.none,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                      )
                    : Text(
                        widget.alarmSettings.notificationSettings.body,
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          height: 1.4,
                          color: Colors.white.withOpacity(0.9),
                          decoration: TextDecoration.none,
                        ),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Alt aksiyonlar: dolgulu beyaz "Durdur" (birincil) + hayalet "Ertele".
  Widget _buildActions() {
    return AnimatedOpacity(
      opacity: _processing ? 0.45 : 1.0,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(
        ignoring: _processing,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // --- ERTELE (SNOOZE) — ikincil / hayalet buton ---
            SizedBox(
              width: double.infinity,
              height: 56,
              child: Material(
                color: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                  side: BorderSide(
                      color: Colors.white.withOpacity(0.25), width: 1),
                ),
                child: InkWell(
                  onTap: _handleSnooze,
                  borderRadius: BorderRadius.circular(28),
                  splashColor: Colors.white.withOpacity(0.08),
                  highlightColor: Colors.white.withOpacity(0.04),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.snooze_rounded,
                            size: 20, color: Colors.white.withOpacity(0.9)),
                        const SizedBox(width: 8),
                        Text(
                          "snooze_button".tr(),
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.3,
                            color: Colors.white.withOpacity(0.9),
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            // --- ALARMI DURDUR — birincil dolgulu buton ---
            SizedBox(
              width: double.infinity,
              height: 64,
              child: Material(
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(32),
                ),
                elevation: 0,
                child: InkWell(
                  onTap: _handleStop,
                  borderRadius: BorderRadius.circular(32),
                  splashColor: colDeepSea.withOpacity(0.10),
                  highlightColor: colDeepSea.withOpacity(0.05),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.alarm_off_rounded,
                            size: 24, color: colNightNavy),
                        const SizedBox(width: 10),
                        Text(
                          "stop_alarm_btn".tr(),
                          style: GoogleFonts.inter(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3,
                            color: colNightNavy,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}