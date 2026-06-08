import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:medTrackPlus/app/device_free/group_dashboard_screen.dart';
import 'package:medTrackPlus/app/device_free/patient_dashboard_screen.dart';
import 'package:medTrackPlus/main.dart' show AppColors;
import 'package:medTrackPlus/services/patient_service.dart';
import 'package:medTrackPlus/widgets/alarm_settings_dialog.dart';

/// Multi-patient dashboard for device-free mode: lists all patient
/// profiles the user can access, with grouping ("rooms") — the patient
/// counterpart of DeviceListScreen.
///
/// Groups live in users/{uid}.patient_groups (same shape as device_groups).
/// Tapping a patient opens PatientDashboardScreen full-screen.
class PatientListScreen extends StatefulWidget {
  /// Edit (drag) mode — mirrors DeviceListScreen.isDragMode.
  final bool isDragMode;

  /// Called when the screen wants to flip edit mode (e.g. a long-press
  /// drag starts while edit mode is off).
  final Function(bool) onModeChanged;

  const PatientListScreen({
    super.key,
    this.isDragMode = false,
    this.onModeChanged = _noopModeChanged,
  });

  static void _noopModeChanged(bool _) {}

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

  // ===========================================================================
  // --- SÜRÜKLE & BIRAK ---
  // ===========================================================================

  /// Hastayı hedef gruba (veya '' ile ana listeye) taşır ve bildirim gösterir.
  Future<void> _movePatient(String patientId, String targetGroupId,
      {String? groupName}) async {
    final uid = _uid;
    if (uid == null) return;
    HapticFeedback.lightImpact();
    await _patientService.movePatientToGroup(uid, patientId, targetGroupId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(targetGroupId.isEmpty
            ? 'patient_moved_main'.tr()
            : 'patient_moved_room'.tr(args: [groupName ?? ''])),
        duration: const Duration(milliseconds: 900),
      ),
    );
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

        // Arka plan, "gruptan çıkar" hedefi: hasta kartı bir grubun
        // dışına (listenin boş alanına) bırakılırsa tüm gruplardan çıkar.
        return DragTarget<String>(
          onWillAccept: (data) => widget.isDragMode && data != null,
          onAccept: (patientId) => _movePatient(patientId, ''),
          builder: (context, candidateData, rejectedData) {
            return AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              color: candidateData.isNotEmpty
                  ? AppColors.skyBlue.withOpacity(0.05)
                  : Colors.transparent,
              child: RefreshIndicator(
                onRefresh: refresh,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
                  children: [
                    _buildDragInfoBanner(),
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
                    for (final p in ungrouped) _buildPatientCard(p),
                    // Geniş bırakma alanı (gruptan çıkarmayı kolaylaştırır).
                    const SizedBox(height: 150),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Düzenleme modu açıkken görünen bilgi şeridi (cihaz listesiyle aynı).
  Widget _buildDragInfoBanner() {
    return AnimatedCrossFade(
      duration: const Duration(milliseconds: 300),
      crossFadeState: widget.isDragMode
          ? CrossFadeState.showFirst
          : CrossFadeState.showSecond,
      firstChild: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: const Color(0xFFF0F9FF),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFBAE6FD)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.touch_app_rounded,
                  color: AppColors.deepSea, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'drag_info'.tr(),
                style: const TextStyle(
                    color: AppColors.deepSea,
                    fontSize: 13,
                    fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
      secondChild: const SizedBox(width: double.infinity),
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
    final String groupId = group['id'] as String? ?? '';
    final String groupName = group['name'] as String? ?? '';
    final List<String> memberIds = List<String>.from(group['devices'] ?? []);
    final members =
        _patients.where((p) => memberIds.contains(p['id'])).toList();

    Widget buildCard({required bool hovering}) {
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: hovering
                ? AppColors.skyBlue
                : AppColors.skyBlue.withOpacity(0.12),
            width: hovering ? 2 : 1,
          ),
          boxShadow: hovering
              ? [
                  BoxShadow(
                    color: AppColors.skyBlue.withOpacity(0.25),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: InkWell(
          // Grup kabına uzun basış: toplu alarm ayarları.
          onLongPress: () => AlarmSettingsDialog.show(context),
          borderRadius: BorderRadius.circular(16),
          child: ExpansionTile(
            shape: const Border(),
            initiallyExpanded: widget.isDragMode,
            leading:
                const Icon(Icons.groups_rounded, color: AppColors.skyBlue),
            title: Text(groupName,
                style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
            subtitle: Text('${members.length} ${'patients_suffix'.tr()}',
                style: const TextStyle(fontSize: 12)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.alarm_rounded,
                      size: 20, color: AppColors.skyBlue),
                  tooltip: 'alarm_settings'.tr(),
                  onPressed: () => AlarmSettingsDialog.show(context),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded,
                      size: 20, color: Colors.red),
                  onPressed: () async {
                    if (_uid != null) {
                      await _patientService.deletePatientGroup(_uid!, groupId);
                    }
                  },
                ),
                const Icon(Icons.expand_more_rounded),
              ],
            ),
            children: [
              // GROUP CONTROL PANEL: grubun tüm ilaçlarını tek panelde
              // toplayıp saat/stok bazlı toplu düzenleme sağlar.
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Material(
                  color: AppColors.skyBlue.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => GroupDashboardScreen(
                            groupId: groupId,
                            groupName: groupName,
                            patientIds: memberIds,
                          ),
                        ),
                      );
                      refresh();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      child: Row(
                        children: [
                          const Icon(Icons.dashboard_customize_rounded,
                              size: 18, color: AppColors.skyBlue),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text('group_control_panel'.tr(),
                                style: GoogleFonts.inter(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.skyBlue)),
                          ),
                          const Icon(Icons.arrow_forward_ios_rounded,
                              size: 12, color: AppColors.skyBlue),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
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
                  child: _buildPatientCard(p, inGroup: true),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    }

    if (widget.isDragMode) {
      // Grup kartı bırakma hedefi: üzerine gelince parlar/hafif büyür.
      return DragTarget<String>(
        onWillAccept: (data) => data != null,
        onAccept: (patientId) =>
            _movePatient(patientId, groupId, groupName: groupName),
        builder: (context, candidateData, rejectedData) {
          final isHovering = candidateData.isNotEmpty;
          return TweenAnimationBuilder<double>(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutBack,
            tween: Tween<double>(begin: 1.0, end: isHovering ? 1.02 : 1.0),
            builder: (context, scale, child) {
              return Transform.scale(
                scale: scale,
                child: buildCard(hovering: isHovering),
              );
            },
          );
        },
      );
    }

    return buildCard(hovering: false);
  }

  Widget _buildPatientAvatar(Map<String, String> patient) {
    return CircleAvatar(
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
    );
  }

  Widget _buildPatientCard(Map<String, String> patient,
      {bool inGroup = false}) {
    final patientId = patient['id'] ?? '';

    final Widget card = Container(
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
        leading: _buildPatientAvatar(patient),
        title: Text(patient['name'] ?? '',
            style: GoogleFonts.inter(
                fontWeight: FontWeight.w700, color: AppColors.deepSea)),
        trailing: widget.isDragMode
            ? const Icon(Icons.drag_indicator_rounded, color: Colors.grey)
            : const Icon(Icons.chevron_right_rounded,
                color: AppColors.skyBlue),
        // Düzenleme modunda dokunma gezinmez (cihaz listesiyle tutarlı).
        onTap: widget.isDragMode
            ? null
            : () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        PatientDashboardScreen(patientId: patientId),
                  ),
                );
                refresh();
              },
      ),
    );

    // Uzun basış sürüklemeyi başlatır; düzenleme modu kapalıysa aynı
    // hareketle otomatik açılır (eski "gruba taşı" menüsünün yerini aldı).
    return LongPressDraggable<String>(
      data: patientId,
      delay: const Duration(milliseconds: 300),
      onDragStarted: () {
        HapticFeedback.selectionClick();
        if (!widget.isDragMode) {
          widget.onModeChanged(true);
        }
      },
      childWhenDragging: Opacity(opacity: 0.3, child: card),
      feedback: Material(
        color: Colors.transparent,
        child: Transform.scale(
          scale: 1.04,
          child: SizedBox(
            width: MediaQuery.of(context).size.width * 0.85,
            child: Card(
              elevation: 10,
              color: Colors.white.withOpacity(0.95),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(Icons.drag_indicator,
                        color: AppColors.skyBlue),
                    const SizedBox(width: 12),
                    _buildPatientAvatar(patient),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        patient['name'] ?? '',
                        style: GoogleFonts.inter(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: AppColors.deepSea),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      child: card,
    );
  }
}
