import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:medTrackPlus/main.dart';
import 'package:medTrackPlus/services/database_service.dart';

/// DEVELOPER-ONLY: ESP32 dispenser'ı RTDB üzerinden elle kontrol ve canlı
/// izleme ekranı. Sadece Developer ekranından erişilir; üretim navigasyonuna
/// kayıtlı değildir.
class DeviceControlPanelScreen extends StatefulWidget {
  const DeviceControlPanelScreen({super.key});

  @override
  State<DeviceControlPanelScreen> createState() =>
      _DeviceControlPanelScreenState();
}

class _DeviceControlPanelScreenState extends State<DeviceControlPanelScreen> {
  final DatabaseService _db = DatabaseService();

  bool _loadingDevices = true;
  List<Map<String, String>> _devices = [];
  String? _selectedMac;

  bool _liveMonitor = false;

  Map<String, dynamic> _telemetry = {};
  Map<String, dynamic>? _lastAck;
  List<Map<String, dynamic>> _logs = [];

  StreamSubscription<Map<String, dynamic>>? _telemetrySub;
  StreamSubscription<Map<String, dynamic>?>? _ackSub;
  StreamSubscription<List<Map<String, dynamic>>>? _logsSub;

  // Her bölüm için özel adım giriş değeri.
  final List<int> _customSteps = [10, 10, 10, 10];

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  @override
  void dispose() {
    _telemetrySub?.cancel();
    _ackSub?.cancel();
    _logsSub?.cancel();
    // Cihazda telemetriyi kapat.
    final mac = _selectedMac;
    if (mac != null && mac.isNotEmpty) {
      _db.devStream(mac, false);
    }
    super.dispose();
  }

  Future<void> _loadDevices() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() {
        _loadingDevices = false;
        _devices = [];
      });
      return;
    }
    final email = user.email ?? '';
    final devices = await _db.getAllUserDevices(user.uid, email);
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _loadingDevices = false;
      if (devices.length == 1) {
        _selectedMac = devices.first['mac'];
      } else if (devices.isNotEmpty &&
          (_selectedMac == null ||
              !devices.any((d) => d['mac'] == _selectedMac))) {
        // Birden çok cihaz: ilkini varsayılan seç.
        _selectedMac = devices.first['mac'];
      }
    });
    // Logs her zaman dinlenebilir (telemetri akışından bağımsız).
    _subscribeLogsAndAck();
  }

  void _subscribeLogsAndAck() {
    _ackSub?.cancel();
    _logsSub?.cancel();
    final mac = _selectedMac;
    if (mac == null || mac.isEmpty) return;
    _ackSub = _db.devAckStream(mac).listen((ack) {
      if (!mounted) return;
      setState(() => _lastAck = ack);
    });
    _logsSub = _db.devLogsStream(mac).listen((logs) {
      if (!mounted) return;
      setState(() => _logs = logs);
    });
  }

  void _onDeviceChanged(String? mac) {
    if (mac == _selectedMac) return;
    // Önceki cihazda telemetriyi kapat.
    final old = _selectedMac;
    if (old != null && old.isNotEmpty && _liveMonitor) {
      _db.devStream(old, false);
    }
    _telemetrySub?.cancel();
    setState(() {
      _selectedMac = mac;
      _telemetry = {};
      _lastAck = null;
      _logs = [];
      _liveMonitor = false;
    });
    _subscribeLogsAndAck();
  }

  void _toggleLiveMonitor(bool on) {
    final mac = _selectedMac;
    if (mac == null || mac.isEmpty) return;
    setState(() => _liveMonitor = on);
    if (on) {
      _db.devStream(mac, true);
      _telemetrySub?.cancel();
      _telemetrySub = _db.devTelemetryStream(mac).listen((t) {
        if (!mounted) return;
        setState(() => _telemetry = t);
      });
    } else {
      _db.devStream(mac, false);
      _telemetrySub?.cancel();
      _telemetrySub = null;
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: GoogleFonts.inter(fontSize: 13)),
        duration: const Duration(milliseconds: 1400),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String get _mac => _selectedMac ?? '';

  // --- Sayısal yardımcılar (int/num/String'e dayanıklı) ---
  int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  bool _asBool(dynamic v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = v?.toString().toLowerCase();
    return s == 'true' || s == '1';
  }

  @override
  Widget build(BuildContext context) {
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
            const Icon(Icons.settings_remote_rounded,
                color: AppColors.skyBlue, size: 20),
            const SizedBox(width: 8),
            Text(
              'Device Control Panel',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.deepSea,
              ),
            ),
          ],
        ),
      ),
      body: _loadingDevices
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.skyBlue))
          : _devices.isEmpty
              ? _buildEmptyState()
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    _buildDevicePicker(),
                    const SizedBox(height: 24),
                    _buildLiveMonitorCard(),
                    const SizedBox(height: 24),
                    _buildTelemetryCard(),
                    const SizedBox(height: 24),
                    _buildMotorControlCard(),
                    const SizedBox(height: 24),
                    _buildSyncCard(),
                    const SizedBox(height: 24),
                    _buildSoundLedCard(),
                    const SizedBox(height: 24),
                    _buildLogsCard(),
                    const SizedBox(height: 20),
                  ],
                ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.usb_off_rounded,
                size: 56, color: AppColors.deepSea.withOpacity(0.3)),
            const SizedBox(height: 16),
            Text(
              'No physical device paired',
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.deepSea,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Bu hesaba bağlı fiziksel bir dispenser bulunamadı.\n'
              'Donanım kontrolü yalnızca gerçek cihazlar için geçerlidir.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: AppColors.deepSea.withOpacity(0.5),
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── DEVICE PICKER ─────────────────────────────────────────────────────
  Widget _buildDevicePicker() {
    if (_devices.length == 1) {
      final d = _devices.first;
      return _Card(
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: AppColors.skyBlue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.memory_rounded,
                  color: AppColors.skyBlue, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    d['name'] ?? 'Cihaz',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.deepSea,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    d['mac'] ?? '',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: AppColors.deepSea.withOpacity(0.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(Icons.memory_rounded, 'Cihaz Seç'),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _selectedMac,
            isExpanded: true,
            decoration: InputDecoration(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            items: _devices
                .map((d) => DropdownMenuItem<String>(
                      value: d['mac'],
                      child: Text(
                        '${d['name'] ?? 'Cihaz'} — ${d['mac']}',
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(fontSize: 13),
                      ),
                    ))
                .toList(),
            onChanged: _onDeviceChanged,
          ),
        ],
      ),
    );
  }

  // ── LIVE MONITOR TOGGLE + LAST ACK ────────────────────────────────────
  Widget _buildLiveMonitorCard() {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.sensors_rounded,
                  color: AppColors.skyBlue, size: 18),
              const SizedBox(width: 8),
              Text(
                'Canlı İzleme',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepSea,
                ),
              ),
              const Spacer(),
              Switch(
                value: _liveMonitor,
                activeColor: AppColors.skyBlue,
                onChanged: _toggleLiveMonitor,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _liveMonitor
                ? 'Telemetri yayını açık (~1/sn).'
                : 'Telemetri yayını kapalı.',
            style: GoogleFonts.inter(
              fontSize: 12,
              color: AppColors.deepSea.withOpacity(0.5),
            ),
          ),
          const SizedBox(height: 12),
          _buildAckChip(),
        ],
      ),
    );
  }

  Widget _buildAckChip() {
    final ack = _lastAck;
    if (ack == null) {
      return _chip(
        'Henüz ACK yok',
        const Color(0xFF94A3B8),
        Icons.hourglass_empty_rounded,
      );
    }
    final ok = _asBool(ack['ok']);
    final action = ack['action']?.toString() ?? '?';
    final msg = ack['msg']?.toString() ?? '';
    final color = ok ? const Color(0xFF36C0A6) : const Color(0xFFE53935);
    return _chip(
      'ACK: $action${msg.isNotEmpty ? ' — $msg' : ''}',
      color,
      ok ? Icons.check_circle_rounded : Icons.error_rounded,
    );
  }

  // ── TELEMETRY ─────────────────────────────────────────────────────────
  Widget _buildTelemetryCard() {
    final hasData = _telemetry.isNotEmpty;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(Icons.show_chart_rounded, 'Telemetri'),
          const SizedBox(height: 12),
          if (!hasData)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Streaming kapalı / veri yok',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: AppColors.deepSea.withOpacity(0.5),
                ),
              ),
            )
          else ...[
            ..._buildHallRows(),
            const SizedBox(height: 12),
            _buildDistanceRow(),
            const SizedBox(height: 12),
            _buildPositionsRow(),
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            _buildStatusRow(),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildHallRows() {
    final hall = _telemetry['hall'] is Map
        ? Map<String, dynamic>.from(_telemetry['hall'])
        : <String, dynamic>{};
    final home = _telemetry['home'] is Map
        ? Map<String, dynamic>.from(_telemetry['home'])
        : <String, dynamic>{};
    return List.generate(4, (i) {
      final raw = _asInt(hall['s$i']);
      final isHome = _asBool(home['s$i']);
      final pct = (raw / 4095).clamp(0.0, 1.0);
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            SizedBox(
              width: 52,
              child: Text(
                'Hall ${i + 1}',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.deepSea,
                ),
              ),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: pct,
                  minHeight: 10,
                  backgroundColor: AppColors.deepSea.withOpacity(0.08),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    isHome ? const Color(0xFF36C0A6) : AppColors.skyBlue,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 44,
              child: Text(
                '$raw',
                textAlign: TextAlign.right,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: AppColors.deepSea.withOpacity(0.7),
                ),
              ),
            ),
            const SizedBox(width: 6),
            if (isHome)
              _miniBadge('HOME', const Color(0xFF36C0A6))
            else
              const SizedBox(width: 48),
          ],
        ),
      );
    });
  }

  Widget _buildDistanceRow() {
    final dist = _asInt(_telemetry['distance_cm']);
    final present = _asBool(_telemetry['present']);
    return Row(
      children: [
        const Icon(Icons.straighten_rounded,
            size: 18, color: AppColors.skyBlue),
        const SizedBox(width: 8),
        Text(
          'Mesafe: $dist cm',
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.deepSea,
          ),
        ),
        const SizedBox(width: 10),
        if (present) _miniBadge('PRESENT', const Color(0xFF36C0A6)),
      ],
    );
  }

  Widget _buildPositionsRow() {
    final pos = _telemetry['pos'] is Map
        ? Map<String, dynamic>.from(_telemetry['pos'])
        : <String, dynamic>{};
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: List.generate(4, (i) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.deepSea.withOpacity(0.05),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            'M${i + 1}: ${_asInt(pos['s$i'])}',
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.deepSea,
            ),
          ),
        );
      }),
    );
  }

  Widget _buildStatusRow() {
    final wifi = _asBool(_telemetry['wifi']);
    final rssi = _asInt(_telemetry['rssi']);
    final heapKb = (_asInt(_telemetry['heap']) / 1024).round();
    final uptime = _asInt(_telemetry['uptime_s']);
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      children: [
        _statusItem(
          wifi ? Icons.wifi_rounded : Icons.wifi_off_rounded,
          wifi ? 'WiFi online' : 'WiFi offline',
          wifi ? const Color(0xFF36C0A6) : const Color(0xFFE53935),
        ),
        _statusItem(Icons.signal_cellular_alt_rounded, '$rssi dBm',
            AppColors.deepSea),
        _statusItem(Icons.memory_rounded, '$heapKb KB', AppColors.deepSea),
        _statusItem(
            Icons.timer_outlined, _fmtUptime(uptime), AppColors.deepSea),
      ],
    );
  }

  String _fmtUptime(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  // ── MOTOR CONTROL ─────────────────────────────────────────────────────
  Widget _buildMotorControlCard() {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(Icons.tune_rounded, 'Manuel Motor Kontrolü'),
          const SizedBox(height: 8),
          ...List.generate(4, (i) => _buildMotorRow(i)),
        ],
      ),
    );
  }

  Widget _buildMotorRow(int section) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.deepSea.withOpacity(0.03),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Çark ${section + 1}',
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.deepSea,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _smallBtn('-1 bölme', Icons.remove_rounded, () {
                _db.devMotorSlot(_mac, section, -1);
                _snack('Komut gönderildi: -1 bölme (Çark ${section + 1})');
              }),
              _smallBtn('+1 bölme', Icons.add_rounded, () {
                _db.devMotorSlot(_mac, section, 1);
                _snack('Komut gönderildi: +1 bölme (Çark ${section + 1})');
              }),
              _buildStepStepper(section),
              _smallBtn('Home', Icons.home_rounded, () {
                _db.devHome(_mac, section);
                _snack('Komut gönderildi: Home (Çark ${section + 1})');
              }, color: const Color(0xFFE8A020)),
              _smallBtn('Dağıt', Icons.vaccines_rounded, () {
                _db.devDispense(_mac, section);
                _snack('Komut gönderildi: Dağıt (Çark ${section + 1})');
              }, color: const Color(0xFF36C0A6)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStepStepper(int section) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.deepSea.withOpacity(0.15)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.remove_rounded, size: 16),
            onPressed: () {
              setState(() => _customSteps[section] =
                  (_customSteps[section] - 5).clamp(-2000, 2000));
            },
          ),
          GestureDetector(
            onTap: () {
              final v = _customSteps[section];
              _db.devMotorStep(_mac, section, v);
              _snack('Komut gönderildi: $v adım (Çark ${section + 1})');
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Column(
                children: [
                  Text(
                    '${_customSteps[section]} adım',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.skyBlue,
                    ),
                  ),
                  Text(
                    'gönder',
                    style: GoogleFonts.inter(
                      fontSize: 8,
                      color: AppColors.deepSea.withOpacity(0.45),
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.add_rounded, size: 16),
            onPressed: () {
              setState(() => _customSteps[section] =
                  (_customSteps[section] + 5).clamp(-2000, 2000));
            },
          ),
        ],
      ),
    );
  }

  // ── SYNC ──────────────────────────────────────────────────────────────
  Widget _buildSyncCard() {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(Icons.sync_rounded, 'Çark Senkronizasyonu'),
          const SizedBox(height: 6),
          Text(
            'Mıknatıs algılanınca o bölme 1. bölme olur; çarklar sırayla '
            '(paralel değil) senkronlanır.',
            style: GoogleFonts.inter(
              fontSize: 12,
              color: AppColors.deepSea.withOpacity(0.55),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _smallBtn('Home All (sıralı)', Icons.home_work_rounded, () {
                _db.devHomeAll(_mac);
                _snack('Komut gönderildi: Home All');
              }, color: const Color(0xFFE8A020)),
              _smallBtn('Refill Sync All (sıralı)', Icons.sync_alt_rounded, () {
                _db.devRefillSyncAll(_mac);
                _snack('Komut gönderildi: Refill Sync All');
              }),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Tek çark refill sync:',
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.deepSea.withOpacity(0.7),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(4, (i) {
              return _smallBtn('Çark ${i + 1}', Icons.refresh_rounded, () {
                _db.devRefillSync(_mac, i);
                _snack('Komut gönderildi: Refill Sync (Çark ${i + 1})');
              });
            }),
          ),
        ],
      ),
    );
  }

  // ── SOUND + LED ───────────────────────────────────────────────────────
  Widget _buildSoundLedCard() {
    const ledLabels = [
      'Off',
      'Green',
      'Amber',
      'Red',
      'Red-blink',
      'Blue-blink'
    ];
    const ledColors = [
      Color(0xFF94A3B8),
      Color(0xFF36C0A6),
      Color(0xFFE8A020),
      Color(0xFFE53935),
      Color(0xFFE53935),
      Color(0xFF1D8AD6),
    ];
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(Icons.campaign_rounded, 'Ses & LED Testi'),
          const SizedBox(height: 12),
          _smallBtn('Alarm sesini çal', Icons.volume_up_rounded, () {
            _db.devSound(_mac, track: 1);
            _snack('Komut gönderildi: Alarm sesi');
          }, color: const Color(0xFFE8A020)),
          const SizedBox(height: 14),
          Text(
            'LED durumları:',
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.deepSea.withOpacity(0.7),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(6, (state) {
              return _smallBtn(ledLabels[state], Icons.lightbulb_rounded, () {
                _db.devLed(_mac, state);
                _snack('Komut gönderildi: LED ${ledLabels[state]}');
              }, color: ledColors[state]);
            }),
          ),
        ],
      ),
    );
  }

  // ── LOGS ──────────────────────────────────────────────────────────────
  Widget _buildLogsCard() {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.terminal_rounded,
                  color: AppColors.skyBlue, size: 18),
              const SizedBox(width: 8),
              Text(
                'Makine Logları',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepSea,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () {
                  _db.clearDevLogs(_mac);
                  _snack('Loglar temizlendi');
                },
                icon: const Icon(Icons.delete_outline_rounded, size: 16),
                label: Text('Temizle',
                    style: GoogleFonts.inter(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            height: 220,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(10),
            ),
            child: _logs.isEmpty
                ? Center(
                    child: Text(
                      'Log yok',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: Colors.white.withOpacity(0.4),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: _logs.length,
                    itemBuilder: (context, idx) {
                      final log = _logs[idx];
                      final ts = _asInt(log['ts']);
                      final level =
                          (log['level']?.toString() ?? '').toUpperCase();
                      final msg = log['msg']?.toString() ?? '';
                      final time = _fmtLogTime(ts);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          '[$time] $level $msg',
                          style: GoogleFonts.robotoMono(
                            fontSize: 11,
                            color: _logColor(level),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _fmtLogTime(int tsSeconds) {
    if (tsSeconds <= 0) return '--:--:--';
    final dt =
        DateTime.fromMillisecondsSinceEpoch(tsSeconds * 1000).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  Color _logColor(String level) {
    switch (level) {
      case 'ERROR':
      case 'ERR':
        return const Color(0xFFFF6B6B);
      case 'WARN':
      case 'WARNING':
        return const Color(0xFFFFD166);
      case 'INFO':
        return const Color(0xFF8FD3FF);
      default:
        return Colors.white.withOpacity(0.85);
    }
  }

  // ── SHARED UI HELPERS ─────────────────────────────────────────────────
  Widget _sectionTitle(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, color: AppColors.skyBlue, size: 18),
        const SizedBox(width: 8),
        Text(
          text,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: AppColors.deepSea,
          ),
        ),
      ],
    );
  }

  Widget _smallBtn(String label, IconData icon, VoidCallback onTap,
      {Color color = AppColors.skyBlue}) {
    return Material(
      color: color.withOpacity(0.1),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: _mac.isEmpty ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          color: color,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _statusItem(IconData icon, String text, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 4),
        Text(
          text,
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _chip(String text, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// developer_screen.dart kart stilini taklit eden basit beyaz kart.
class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.skyBlue.withOpacity(0.12)),
        boxShadow: [
          BoxShadow(
            color: AppColors.deepSea.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: child,
    );
  }
}
