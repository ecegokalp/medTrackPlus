import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:medTrackPlus/app/reports_screen.dart';
import 'package:medTrackPlus/main.dart' show AppColors;
import 'package:medTrackPlus/services/alarm_coordinator.dart';
import 'package:medTrackPlus/services/database_service.dart';
import 'package:medTrackPlus/services/patient_service.dart';
import 'package:medTrackPlus/widgets/alarm_settings_dialog.dart';

/// Device-free patient dashboard: the medication detail screen for ONE
/// patient profile (patients/{patientId}).
///
/// Mirrors HomeScreen's responsibilities WITHOUT any hardware coupling:
/// no RTDB sync, no buzzer, no BLE — medications live in Firestore only
/// and are UNLIMITED in count (no 3-tray constraint).
///
/// Used two ways:
///   - embedded: true  → as the MainHub "Dashboard" tab (single-patient mode)
///   - embedded: false → pushed full-screen from PatientListScreen
///
/// Alarm/verification flow: medications are scheduled through the same
/// NotificationService; the alarm metadata carries [patientId] in the
/// macAddress slot, so AlarmRingScreen → VerificationScreen → entity-aware
/// services route everything to the patients collection automatically.
class PatientDashboardScreen extends StatefulWidget {
  final String patientId;
  final bool embedded;

  const PatientDashboardScreen({
    super.key,
    required this.patientId,
    this.embedded = false,
  });

  @override
  State<PatientDashboardScreen> createState() => _PatientDashboardScreenState();
}

class _PatientDashboardScreenState extends State<PatientDashboardScreen> {
  final DatabaseService _dbService = DatabaseService();
  final PatientService _patientService = PatientService();
  final AlarmCoordinator _alarmCoordinator = AlarmCoordinator();

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;

  String _patientName = '';
  String? _photoUrl;
  DeviceRole _role = DeviceRole.none;
  List<Map<String, dynamic>> _meds = [];
  bool _loading = true;
  bool _uploadingPhoto = false;

  // Alarm thrashing önleme (HomeScreen ile aynı imza yaklaşımı).
  String _lastScheduleSignature = '';
  Timer? _scheduleDebounce;

  bool get _canEdit =>
      _role == DeviceRole.owner || _role == DeviceRole.secondary;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scheduleDebounce?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    final email = FirebaseAuth.instance.currentUser?.email;
    _role = await _dbService.getUserRole(widget.patientId, email);
    _sub = _patientService.watchPatient(widget.patientId).listen((doc) {
      if (!doc.exists || !mounted) return;
      final data = doc.data()!;
      final List<dynamic> rawMeds = data['medications'] ?? [];
      final meds = rawMeds.map<Map<String, dynamic>>((m) {
        final List<TimeOfDay> times = ((m['schedule'] ?? []) as List)
            .map<TimeOfDay>((t) => TimeOfDay(
                hour: (t['h'] ?? 8) as int, minute: (t['m'] ?? 0) as int))
            .toList();
        return {
          'name': m['name'] ?? '',
          'isActive': m['isActive'] ?? true,
          'pillCount': m['pillCount'] ?? 0,
          'times': times,
        };
      }).toList();
      setState(() {
        _patientName = data['patient_name'] ?? '';
        _photoUrl = data['photo_url'] as String?;
        _meds = meds;
        _loading = false;
      });
      _scheduleIfNeeded(meds);
    });
  }

  /// İmza değiştiyse 2 sn debounce ile alarm kurulumunu tetikler.
  void _scheduleIfNeeded(List<Map<String, dynamic>> meds) {
    final signature = meds
        .map((m) =>
            '${m['name']}|${m['isActive']}|${(m['times'] as List<TimeOfDay>).map((t) => '${t.hour}:${t.minute}').join(',')}')
        .join(';');
    if (signature == _lastScheduleSignature) return;
    _lastScheduleSignature = signature;

    _scheduleDebounce?.cancel();
    _scheduleDebounce = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      // Tek hastayı değil TÜM entity'leri (cihaz + hasta) yeniden planla.
      _alarmCoordinator.rescheduleAll(context);
    });
  }

  Future<void> _saveMeds(List<Map<String, dynamic>> meds) async {
    final payload = meds
        .map((m) => {
              'name': m['name'],
              'isActive': m['isActive'] ?? true,
              'pillCount': m['pillCount'] ?? 0,
              'schedule': (m['times'] as List<TimeOfDay>)
                  .map((t) => {'h': t.hour, 'm': t.minute})
                  .toList(),
            })
        .toList();
    // Entity-aware: patients/{id}.medications alanına yazar (RTDB yok).
    await _dbService.saveSectionConfig(widget.patientId, payload);
  }

  // ===========================================================================
  // --- İLAÇ EKLE / DÜZENLE / SİL ---
  // ===========================================================================

  Future<void> _showMedicationDialog({int? index}) async {
    final isNew = index == null;
    final existing = isNew ? null : _meds[index];
    final nameController =
        TextEditingController(text: existing?['name'] ?? '');
    final countController = TextEditingController(
        text: (existing?['pillCount'] ?? 0).toString());
    List<TimeOfDay> times = isNew
        ? [const TimeOfDay(hour: 8, minute: 0)]
        : List<TimeOfDay>.from(existing!['times']);
    bool isActive = existing?['isActive'] ?? true;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(isNew ? 'add_medication'.tr() : 'edit_medicine_title'.tr()),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(
                    labelText: 'medicine_name_label'.tr(),
                    hintText: 'medicine_name_hint'.tr(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: countController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'total_pills_label'.tr(),
                  ),
                ),
                const SizedBox(height: 16),
                Text('reminder_times_header'.tr(),
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (int i = 0; i < times.length; i++)
                      InputChip(
                        label: Text(times[i].format(context)),
                        onDeleted: times.length > 1
                            ? () => setLocal(() => times.removeAt(i))
                            : null,
                        onPressed: () async {
                          final picked = await showTimePicker(
                              context: context, initialTime: times[i]);
                          if (picked != null) {
                            setLocal(() => times[i] = picked);
                          }
                        },
                      ),
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 18),
                      label: Text('add_time'.tr()),
                      onPressed: () async {
                        final picked = await showTimePicker(
                            context: context,
                            initialTime: const TimeOfDay(hour: 8, minute: 0));
                        if (picked != null) {
                          setLocal(() => times.add(picked));
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('active'.tr()),
                  value: isActive,
                  activeColor: AppColors.turquoise,
                  onChanged: (v) => setLocal(() => isActive = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('cancel'.tr()),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('save'.tr()),
            ),
          ],
        ),
      ),
    );

    if (saved != true || !mounted) return;
    final name = nameController.text.trim();
    if (name.isEmpty) return;

    // Saatleri sırala
    times.sort((a, b) => (a.hour * 60 + a.minute) - (b.hour * 60 + b.minute));

    final med = {
      'name': name,
      'isActive': isActive,
      'pillCount': int.tryParse(countController.text) ?? 0,
      'times': times,
    };

    final updated = List<Map<String, dynamic>>.from(_meds);
    if (isNew) {
      updated.add(med);
    } else {
      updated[index] = med;
    }
    await _saveMeds(updated);
  }

  Future<void> _deleteMedication(int index) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('delete_medication'.tr()),
        content: Text('delete_medication_confirm'
            .tr(args: [_meds[index]['name'] ?? ''])),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('cancel'.tr()),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: Text('delete'.tr()),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final updated = List<Map<String, dynamic>>.from(_meds)..removeAt(index);
    await _saveMeds(updated);
  }

  // ===========================================================================
  // --- HASTA BİLGİSİ DÜZENLEME (ad + fotoğraf) ---
  // ===========================================================================

  /// Galeriden fotoğraf seç → Storage'a yükle → patients doc'a photo_url yaz.
  Future<void> _pickAndUploadPhoto(StateSetter setLocal) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 75,
      );
      if (picked == null) return;

      setLocal(() => _uploadingPhoto = true);
      if (mounted) setState(() => _uploadingPhoto = true);

      final ref = FirebaseStorage.instance
          .ref()
          .child('patients/${widget.patientId}/avatar.jpg');
      await ref.putFile(
        File(picked.path),
        SettableMetadata(contentType: 'image/jpeg'),
      );
      final url = await ref.getDownloadURL();

      await FirebaseFirestore.instance
          .collection('patients')
          .doc(widget.patientId)
          .update({'photo_url': url});
      // Snapshot listener _photoUrl'i günceller.
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('error_occurred'.tr(args: [e.toString()]))),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
      try {
        setLocal(() => _uploadingPhoto = false);
      } catch (_) {}
    }
  }

  /// Mavi başlık kartına tıklayınca açılır: ad düzenleme + fotoğraf değiştirme.
  Future<void> _showEditPatientDialog() async {
    if (!_canEdit) return;
    final nameController = TextEditingController(text: _patientName);

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text('edit_patient_title'.tr()),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Fotoğraf önizleme + değiştirme
              GestureDetector(
                onTap: _uploadingPhoto ? null : () => _pickAndUploadPhoto(setLocal),
                child: Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    CircleAvatar(
                      radius: 44,
                      backgroundColor: AppColors.skyBlue.withOpacity(0.15),
                      backgroundImage:
                          _photoUrl != null ? NetworkImage(_photoUrl!) : null,
                      child: _uploadingPhoto
                          ? const CircularProgressIndicator()
                          : (_photoUrl == null
                              ? const Icon(Icons.person_rounded,
                                  size: 44, color: AppColors.skyBlue)
                              : null),
                    ),
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: const BoxDecoration(
                        color: AppColors.skyBlue,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.camera_alt_rounded,
                          size: 16, color: Colors.white),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text('tap_to_change_photo'.tr(),
                  style: TextStyle(
                      fontSize: 11, color: Colors.blueGrey.shade300)),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: 'patient_name_title'.tr(),
                  hintText: 'patient_name_hint'.tr(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('cancel'.tr()),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('save'.tr()),
            ),
          ],
        ),
      ),
    );

    if (saved != true || !mounted) return;
    final newName = nameController.text.trim();
    if (newName.isNotEmpty && newName != _patientName) {
      // Entity-aware: patient_name alanını günceller.
      await _dbService.updateDeviceName(widget.patientId, newName);
    }
  }

  // ===========================================================================
  // --- ERİŞİM YÖNETİMİ (yalnızca owner) ---
  // ===========================================================================

  void _showAccessManagement() {
    final emailController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('access_management_title'.tr()),
        content: SizedBox(
          width: double.maxFinite,
          child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: _patientService.watchPatient(widget.patientId),
            builder: (context, snapshot) {
              final data = snapshot.data?.data() ?? {};
              final secondary =
                  List<String>.from(data['secondary_mails'] ?? []);
              final readOnly =
                  List<String>.from(data['read_only_mails'] ?? []);
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: emailController,
                          keyboardType: TextInputType.emailAddress,
                          decoration: InputDecoration(
                              hintText: 'email_hint'.tr(),
                              isDense: true),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.person_add_rounded,
                            color: AppColors.skyBlue),
                        onPressed: () async {
                          final email = emailController.text.trim();
                          if (email.isEmpty) return;
                          await _dbService.addReadOnlyUser(
                              widget.patientId, email);
                          emailController.clear();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (secondary.isEmpty && readOnly.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text('no_users_yet'.tr(),
                          style: TextStyle(color: Colors.blueGrey.shade300)),
                    ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final email in secondary)
                          _accessTile(email, isSecondary: true),
                        for (final email in readOnly)
                          _accessTile(email, isSecondary: false),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('close'.tr()),
          ),
        ],
      ),
    );
  }

  Widget _accessTile(String email, {required bool isSecondary}) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        isSecondary ? Icons.edit_rounded : Icons.visibility_rounded,
        size: 20,
        color: isSecondary ? AppColors.skyBlue : Colors.blueGrey,
      ),
      title: Text(email, style: const TextStyle(fontSize: 13)),
      subtitle: Text(isSecondary ? 'admin'.tr() : 'viewer'.tr(),
          style: const TextStyle(fontSize: 11)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              isSecondary
                  ? Icons.arrow_downward_rounded
                  : Icons.arrow_upward_rounded,
              size: 18,
            ),
            tooltip:
                isSecondary ? 'demote_viewer'.tr() : 'promote_admin'.tr(),
            onPressed: () => isSecondary
                ? _dbService.demoteToReadOnly(widget.patientId, email)
                : _dbService.promoteToSecondary(widget.patientId, email),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded,
                size: 18, color: Colors.red),
            onPressed: () => _dbService.removeUser(widget.patientId, email),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // --- UI ---
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    final content = _loading
        ? const Center(
            child: CircularProgressIndicator(color: AppColors.skyBlue))
        : _buildBody();

    if (widget.embedded) return content;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(_patientName.isEmpty ? 'dashboard'.tr() : _patientName,
            style: GoogleFonts.inter(
                fontWeight: FontWeight.w800, color: AppColors.deepSea)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: content,
      floatingActionButton: _canEdit
          ? FloatingActionButton.extended(
              onPressed: () => _showMedicationDialog(),
              backgroundColor: AppColors.skyBlue,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: Text('add_medication'.tr()),
            )
          : null,
    );
  }

  Widget _buildBody() {
    return RefreshIndicator(
      onRefresh: () async {},
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
        children: [
          _buildHeaderCard(),
          const SizedBox(height: 16),
          if (_role == DeviceRole.readOnly)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.lock_rounded,
                      size: 18, color: Colors.orange.shade700),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('read_only_banner'.tr(),
                        style: TextStyle(
                            fontSize: 12, color: Colors.orange.shade800)),
                  ),
                ],
              ),
            ),
          Text('scheduled_meds_title'.tr(),
              style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepSea)),
          const SizedBox(height: 12),
          if (_meds.isEmpty)
            _buildEmptyState()
          else
            for (int i = 0; i < _meds.length; i++) _buildMedCard(i),
          if (widget.embedded && _canEdit) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => _showMedicationDialog(),
              icon: const Icon(Icons.add),
              label: Text('add_medication'.tr()),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.skyBlue,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHeaderCard() {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        // Karta tıklayınca hasta bilgileri düzenlenir (owner/secondary).
        onTap: _canEdit ? _showEditPatientDialog : null,
        child: Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.skyBlue, AppColors.deepSea],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: Colors.white24,
                backgroundImage:
                    _photoUrl != null ? NetworkImage(_photoUrl!) : null,
                child: _photoUrl == null
                    ? const Icon(Icons.person_rounded, color: Colors.white)
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _patientName,
                      style: GoogleFonts.inter(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: Colors.white),
                    ),
                    Text(
                      '${_meds.length} ${'medications_suffix'.tr()}',
                      style: GoogleFonts.inter(
                          fontSize: 12, color: Colors.white70),
                    ),
                  ],
                ),
              ),
              _roleBadge(),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _headerAction(
                  icon: Icons.bar_chart_rounded,
                  label: 'reports'.tr(),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          ReportsScreen(macAddress: widget.patientId),
                    ),
                  ),
                ),
              ),
              if (_canEdit) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: _headerAction(
                    icon: Icons.alarm_rounded,
                    label: 'alarm_settings'.tr(),
                    onTap: () => AlarmSettingsDialog.show(context),
                  ),
                ),
              ],
              if (_role == DeviceRole.owner) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: _headerAction(
                    icon: Icons.group_add_rounded,
                    label: 'access_management'.tr(),
                    onTap: _showAccessManagement,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
        ),
      ),
    );
  }

  Widget _roleBadge() {
    final String label;
    final Color color;
    switch (_role) {
      case DeviceRole.owner:
        label = 'owner'.tr();
        color = AppColors.turquoise;
        break;
      case DeviceRole.secondary:
        label = 'admin'.tr();
        color = AppColors.skyBlue;
        break;
      default:
        label = 'viewer'.tr();
        color = Colors.blueGrey;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }

  Widget _headerAction(
      {required IconData icon,
      required String label,
      required VoidCallback onTap}) {
    return Material(
      color: Colors.white.withOpacity(0.15),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: Colors.white),
              const SizedBox(width: 6),
              Flexible(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.white)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.skyBlue.withOpacity(0.15)),
      ),
      child: Column(
        children: [
          Image.asset('assets/single_pill.png',
              width: 48,
              height: 48,
              color: AppColors.skyBlue.withOpacity(0.4),
              colorBlendMode: BlendMode.srcIn),
          const SizedBox(height: 12),
          Text('no_medications'.tr(),
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                  fontSize: 14, color: AppColors.deepSea.withOpacity(0.5))),
        ],
      ),
    );
  }

  Widget _buildMedCard(int index) {
    final med = _meds[index];
    final times = med['times'] as List<TimeOfDay>;
    final bool isActive = med['isActive'] == true;
    final int pillCount = med['pillCount'] ?? 0;
    final bool lowStock = isActive && pillCount <= 1;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: lowStock
                ? Colors.red.shade200
                : AppColors.skyBlue.withOpacity(0.12)),
        boxShadow: [
          BoxShadow(
            color: AppColors.deepSea.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ExpansionTile(
        shape: const Border(),
        leading: Container(
          width: 44,
          height: 44,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: (isActive ? AppColors.turquoise : Colors.blueGrey)
                .withOpacity(0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Image.asset(
            'assets/single_pill.png',
            fit: BoxFit.contain,
            color: isActive ? null : Colors.blueGrey,
            colorBlendMode: isActive ? null : BlendMode.srcIn,
          ),
        ),
        title: Text(
          med['name'] ?? '',
          style: GoogleFonts.inter(
              fontWeight: FontWeight.w700,
              color: isActive ? AppColors.deepSea : Colors.blueGrey),
        ),
        subtitle: Text(
          '${times.length} ${'times_a_day'.tr()} • $pillCount ${'pills'.tr()}'
          '${lowStock ? ' ⚠' : ''}',
          style: TextStyle(
              fontSize: 12,
              color: lowStock ? Colors.red.shade400 : Colors.blueGrey),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final t in times)
                      Chip(
                        avatar: const Icon(Icons.access_time_rounded,
                            size: 16, color: AppColors.skyBlue),
                        label: Text(t.format(context),
                            style: const TextStyle(fontSize: 12)),
                        backgroundColor: AppColors.skyBlue.withOpacity(0.08),
                        side: BorderSide.none,
                      ),
                  ],
                ),
                if (_canEdit) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: Text(isActive ? 'active'.tr() : 'passive'.tr(),
                              style: const TextStyle(fontSize: 13)),
                          value: isActive,
                          activeColor: AppColors.turquoise,
                          onChanged: (v) async {
                            final updated =
                                List<Map<String, dynamic>>.from(_meds);
                            updated[index] = {...updated[index], 'isActive': v};
                            await _saveMeds(updated);
                          },
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_rounded,
                            color: AppColors.skyBlue, size: 20),
                        onPressed: () => _showMedicationDialog(index: index),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline_rounded,
                            color: Colors.red, size: 20),
                        onPressed: () => _deleteMedication(index),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
