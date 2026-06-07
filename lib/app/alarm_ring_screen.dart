import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:alarm/alarm.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

class _AlarmRingScreenState extends State<AlarmRingScreen> {
  static const platform = MethodChannel('com.example.medTrackPlus/lock_control');
  // ignore: unused_field
  final DatabaseService _dbService = DatabaseService();

  static const Color colTurquoise = Color(0xFF36C0A6);
  static const Color colSkyBlue = Color(0xFF1D8AD6);
  static const Color colDeepSea = Color(0xFF0F5191);

  bool _processing = false;

  String _macAddress = "";
  List<int> _sectionIndices = [];
  List<String> _medicineNames = [];

  @override
  void initState() {
    super.initState();


    platform.invokeMethod('showOnLockScreen');

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
        backgroundColor: colDeepSea,
        body: _buildAlarmUI(),
      ),
    );
  }

  Widget _buildAlarmUI() {
    return Stack(
      children: [
        Container(
          width: double.infinity, height: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [colDeepSea, colSkyBlue, colTurquoise],
                stops: [0.2, 0.6, 1.0]
            ),
          ),
        ),
        Positioned(
            top: -100, right: -100,
            child: Container(
                width: 300, height: 300,
                decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withOpacity(0.05))
            )
        ),
        Positioned(
            bottom: -50, left: -50,
            child: Container(
                width: 200, height: 200,
                decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withOpacity(0.03))
            )
        ),

        SafeArea(
          child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: constraints.maxHeight),
                    child: IntrinsicHeight(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const SizedBox(height: 40),

                          StreamBuilder(
                            stream: Stream.periodic(const Duration(seconds: 1)),
                            builder: (context, snapshot) {
                              final now = DateTime.now();
                              return Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                      "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}",
                                      style: const TextStyle(
                                          fontSize: 90, fontWeight: FontWeight.w200,
                                          color: Colors.white, height: 1, fontFamily: 'Roboto',
                                          decoration: TextDecoration.none,
                                          shadows: [Shadow(blurRadius: 10, color: Colors.black26, offset: Offset(0, 4))]
                                      ),
                                      textAlign: TextAlign.center
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                      DateFormat('EEEE, d MMMM', context.locale.toString()).format(now),
                                      style: TextStyle(fontSize: 18, color: Colors.white.withOpacity(0.9), fontWeight: FontWeight.w400, letterSpacing: 1.2, decoration: TextDecoration.none),
                                      textAlign: TextAlign.center
                                  ),
                                ],
                              );
                            },
                          ),

                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                height: 180, width: 180,
                                decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.white.withOpacity(0.1),
                                    boxShadow: [BoxShadow(color: Colors.white.withOpacity(0.15), blurRadius: 50, spreadRadius: 5)]
                                ),
                                child: Padding(
                                    padding: const EdgeInsets.all(30.0),
                                    child: Image.asset('assets/pill_icon.png', fit: BoxFit.contain, errorBuilder: (c, e, s) => const Icon(Icons.medication_liquid_rounded, size: 100, color: Colors.white))
                                ),
                              ),
                              const SizedBox(height: 40),

                              Text(
                                  widget.alarmSettings.notificationSettings.title,
                                  style: const TextStyle(fontSize: 30, color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1, decoration: TextDecoration.none, shadows: [Shadow(color: Colors.black26, blurRadius: 5, offset: Offset(0, 2))]),
                                  textAlign: TextAlign.center
                              ),
                              const SizedBox(height: 15),

                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 40.0),
                                child: _medicineNames.isNotEmpty
                                    ? Column(
                                  children: _medicineNames.map((name) => Padding(
                                    padding: const EdgeInsets.only(bottom: 8.0),
                                    child: Text(
                                      "• $name",
                                      style: TextStyle(fontSize: 22, color: Colors.white.withOpacity(0.95), fontWeight: FontWeight.w600, decoration: TextDecoration.none),
                                      textAlign: TextAlign.center,
                                    ),
                                  )).toList(),
                                )
                                    : Text(
                                    widget.alarmSettings.notificationSettings.body,
                                    style: TextStyle(fontSize: 20, color: Colors.white.withOpacity(0.95), height: 1.4, fontWeight: FontWeight.w500, decoration: TextDecoration.none),
                                    textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis
                                ),
                              ),
                            ],
                          ),

                          Padding(
                            padding: const EdgeInsets.fromLTRB(30, 20, 30, 50),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // --- ERTELE (SNOOZE) BUTONU ---
                                GestureDetector(
                                  onTap: _handleSnooze,
                                  child: Container(
                                    width: double.infinity,
                                    height: 56,
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.08),
                                      borderRadius: BorderRadius.circular(40),
                                      border: Border.all(color: Colors.white.withOpacity(0.25), width: 1),
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        const Icon(Icons.snooze_rounded, color: Colors.white, size: 24),
                                        const SizedBox(width: 10),
                                        Text("snooze_button".tr(), style: TextStyle(color: Colors.white.withOpacity(0.95), fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 1, decoration: TextDecoration.none)),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 14),
                                // --- ALARMI DURDUR BUTONU ---
                                GestureDetector(
                                  onTap: _handleStop,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(50),
                                    child: BackdropFilter(
                                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                                      child: Container(
                                        width: double.infinity, height: 85,
                                        decoration: BoxDecoration(
                                            color: Colors.white.withOpacity(0.2),
                                            borderRadius: BorderRadius.circular(50),
                                            border: Border.all(color: Colors.white.withOpacity(0.4), width: 1.5),
                                            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 20, offset: const Offset(0, 10))]
                                        ),
                                        child: Row(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            children: [
                                              const Icon(Icons.alarm_off_rounded, color: Colors.white, size: 36),
                                              const SizedBox(width: 15),
                                              Text("stop_alarm_btn".tr(), style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 2, decoration: TextDecoration.none))
                                            ]
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }
          ),
        ),
      ],
    );
  }
}