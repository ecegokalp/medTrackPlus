import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:medTrackPlus/app/device_free/patient_dashboard_screen.dart';
import 'package:medTrackPlus/main.dart' show AppColors;
import 'package:medTrackPlus/services/patient_service.dart';

/// Multi-patient dashboard for device-free mode: lists all patient
/// profiles the user can access, with grouping ("rooms") — the patient
/// counterpart of DeviceListScreen.
///
/// Groups live in users/{uid}.patient_groups (same shape as device_groups).
/// Tapping a patient opens PatientDashboardScreen full-screen.
class PatientListScreen extends StatefulWidget {
  const PatientListScreen({super.key});

  @override
  State<PatientListScreen> createState() => PatientListScreenState();
}

class PatientListScreenState extends State<PatientListScreen> {
  final PatientService _patientService = PatientService();

  List<Map<String, String>> _patients = [];
  bool _loading = true;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;
  String? get _email => FirebaseAuth.instance.currentUser?.email;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    final uid = _uid;
    final email = _email;
    if (uid == null || email == null) return;
    await _patientService.updateUserPatientList(uid, email);
    final patients = await _patientService.getAllUserPatients(uid, email);
    if (!mounted) return;
    setState(() {
      _patients = patients;
      _loading = false;
    });
  }

  // ===========================================================================
  // --- HASTA / GRUP OLUŞTURMA ---
  // ===========================================================================

  Future<void> showAddPatientDialog() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('create_new_patient_profile'.tr()),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: 'patient_name_hint'.tr()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('cancel'.tr()),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text('create'.tr()),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || _uid == null) return;
    await _patientService.createPatient(
        uid: _uid!, rawEmail: _email ?? '', patientName: name);
    await refresh();
  }

  Future<void> showCreateGroupDialog() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('create_new_group'.tr()),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: 'room_name_hint'.tr()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('cancel'.tr()),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text('create'.tr()),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || _uid == null) return;
    await _patientService.createPatientGroup(_uid!, name);
  }

  Future<void> _showMoveToGroupSheet(
      String patientId, List<dynamic> groups) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Text('move_to_group'.tr(),
                style: GoogleFonts.inter(
                    fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.home_rounded),
              title: Text('main_list'.tr()),
              onTap: () => Navigator.pop(context, ''),
            ),
            for (final g in groups)
              ListTile(
                leading: const Icon(Icons.groups_rounded,
                    color: AppColors.skyBlue),
                title: Text(g['name'] ?? ''),
                onTap: () => Navigator.pop(context, g['id'] as String),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (selected == null || _uid == null) return;
    await _patientService.movePatientToGroup(_uid!, patientId, selected);
  }

  // ===========================================================================
  // --- UI ---
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.skyBlue));
    }
    final uid = _uid;
    if (uid == null) return const SizedBox.shrink();

    // patient_groups canlı dinlenir; hasta listesi refresh() ile yüklenir.
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream:
          FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
      builder: (context, snapshot) {
        final userData = snapshot.data?.data() ?? {};
        final List<dynamic> groups =
            List.from(userData['patient_groups'] ?? []);

        // Gruplara atanmış hasta ID'leri
        final Set<String> grouped = {};
        for (final g in groups) {
          grouped.addAll(List<String>.from(g['devices'] ?? []));
        }
        final ungrouped =
            _patients.where((p) => !grouped.contains(p['id'])).toList();

        if (_patients.isEmpty && groups.isEmpty) {
          return _buildEmptyState();
        }

        return RefreshIndicator(
          onRefresh: refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
            children: [
              for (final g in groups) _buildGroupCard(g),
              if (ungrouped.isNotEmpty && groups.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text('other_patients'.tr(),
                      style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.blueGrey)),
                ),
              for (final p in ungrouped) _buildPatientCard(p, groups),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.groups_rounded,
                size: 64, color: AppColors.skyBlue.withOpacity(0.3)),
            const SizedBox(height: 16),
            Text('no_patients_yet'.tr(),
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                    fontSize: 15,
                    color: AppColors.deepSea.withOpacity(0.5))),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: showAddPatientDialog,
              icon: const Icon(Icons.person_add_rounded),
              label: Text('add_patient'.tr()),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.skyBlue,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupCard(Map<String, dynamic> group) {
    final List<String> memberIds = List<String>.from(group['devices'] ?? []);
    final members =
        _patients.where((p) => memberIds.contains(p['id'])).toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.skyBlue.withOpacity(0.12)),
      ),
      child: ExpansionTile(
        shape: const Border(),
        leading: const Icon(Icons.groups_rounded, color: AppColors.skyBlue),
        title: Text(group['name'] ?? '',
            style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
        subtitle: Text('${members.length} ${'patients_suffix'.tr()}',
            style: const TextStyle(fontSize: 12)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded,
                  size: 20, color: Colors.red),
              onPressed: () async {
                if (_uid != null) {
                  await _patientService.deletePatientGroup(
                      _uid!, group['id'] as String);
                }
              },
            ),
            const Icon(Icons.expand_more_rounded),
          ],
        ),
        children: [
          if (members.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('empty_room'.tr(),
                  style: TextStyle(
                      fontSize: 12, color: Colors.blueGrey.shade300)),
            ),
          for (final p in members)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _buildPatientCard(p, null, inGroup: true),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildPatientCard(Map<String, String> patient, List<dynamic>? groups,
      {bool inGroup = false}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: inGroup ? AppColors.background : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.skyBlue.withOpacity(0.12)),
        boxShadow: inGroup
            ? null
            : [
                BoxShadow(
                  color: AppColors.deepSea.withOpacity(0.04),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
      ),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        leading: CircleAvatar(
          backgroundColor: AppColors.turquoise.withOpacity(0.15),
          backgroundImage: (patient['photo'] ?? '').isNotEmpty
              ? NetworkImage(patient['photo']!)
              : null,
          child: (patient['photo'] ?? '').isNotEmpty
              ? null
              : Text(
                  (patient['name'] ?? 'H').isNotEmpty
                      ? patient['name']![0].toUpperCase()
                      : 'H',
                  style: const TextStyle(
                      color: AppColors.turquoise, fontWeight: FontWeight.bold),
                ),
        ),
        title: Text(patient['name'] ?? '',
            style: GoogleFonts.inter(
                fontWeight: FontWeight.w700, color: AppColors.deepSea)),
        trailing: const Icon(Icons.chevron_right_rounded,
            color: AppColors.skyBlue),
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  PatientDashboardScreen(patientId: patient['id']!),
            ),
          );
          refresh();
        },
        onLongPress: () async {
          // Uzun basış: gruba taşı / listeden kaldırma menüsü
          final userDoc = await FirebaseFirestore.instance
              .collection('users')
              .doc(_uid)
              .get();
          final currentGroups =
              List<dynamic>.from(userDoc.data()?['patient_groups'] ?? []);
          if (!mounted) return;
          await _showMoveToGroupSheet(patient['id']!, currentGroups);
        },
      ),
    );
  }
}
