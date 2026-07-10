import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:medTrackPlus/main.dart' show AppColors;
import 'package:medTrackPlus/services/alarm_coordinator.dart';
import 'package:medTrackPlus/services/patient_service.dart';

/// GROUP CONTROL PANEL — bir hasta grubunun tüm ilaçlarını tek panelde
/// toplar ve kategori bazlı toplu düzenleme/otomasyon sağlar.
///
/// OTOMATİK görünümler (kova = aynı attribute'u paylaşan ilaçlar):
///   • Saate göre — kovanın saati değişince üyelerin o saati birden değişir.
///   • Stoğa göre — kovaya yapılan stok güncellemesi hepsine uygulanır.
///   • İsme göre  — aynı isimli ilaçlar kovalanır; toplu yeniden adlandırma.
///
/// MANUEL görünüm: kullanıcı + ile kendi gruplamasını oluşturur:
/// kriter seçer (İlaç İsmi / Saat / Stok / Diğer), özel ad verir ve üyeleri
/// seçer. Kriterli gruplarda yalnızca o attribute toplu düzenlenir;
/// "Diğer"de tüm attribute'lar (isim, saat, stok) toplu düzenlenebilir.
/// Manuel gruplar Firestore'da saklanır (users/{uid}.gcp_custom_groups)
/// — uygulama silinse de korunur.
///
/// Yetki: read-only hastaların ilaçları soluk/gri gösterilir, düzenlenemez;
/// dokununca yetki uyarısı çıkar ve toplu işlemlerde atlanır.
class GroupDashboardScreen extends StatefulWidget {
  final String groupId;
  final String groupName;
  final List<String> patientIds;

  const GroupDashboardScreen({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.patientIds,
  });

  @override
  State<GroupDashboardScreen> createState() => _GroupDashboardScreenState();
}

enum _ViewMode { byTime, byStock, byName, manual }

/// Manuel gruplama kriteri.
enum _Criterion { name, time, stock, other }

_Criterion _criterionFrom(String? raw) => _Criterion.values.firstWhere(
      (c) => c.name == raw,
      orElse: () => _Criterion.other,
    );

/// Paneldeki tek satır: bir hastanın tek bir ilacı.
class _MedEntry {
  final String patientId;
  final String patientName;
  final String photo;
  final int medIndex;
  final String medName;
  final int pillCount;
  final bool isActive;
  final List<TimeOfDay> times;
  final bool canEdit;

  _MedEntry({
    required this.patientId,
    required this.patientName,
    required this.photo,
    required this.medIndex,
    required this.medName,
    required this.pillCount,
    required this.isActive,
    required this.times,
    required this.canEdit,
  });

  String get key => '$patientId#$medIndex';
}

/// Kullanıcının oluşturduğu manuel gruplama.
class _CustomGroup {
  final String id;
  String name;
  final _Criterion criterion;
  List<String> members; // _MedEntry.key listesi

  _CustomGroup({
    required this.id,
    required this.name,
    required this.criterion,
    required this.members,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'criterion': criterion.name,
        'members': members,
      };

  factory _CustomGroup.fromMap(Map<String, dynamic> m) => _CustomGroup(
        id: m['id'] ?? '',
        name: m['name'] ?? '',
        criterion: _criterionFrom(m['criterion'] as String?),
        members: List<String>.from(m['members'] ?? []),
      );
}

class _GroupDashboardScreenState extends State<GroupDashboardScreen> {
  final PatientService _patientService = PatientService();

  List<_MedEntry> _entries = [];
  List<_CustomGroup> _customGroups = [];
  bool _loading = true;
  bool _busy = false;
  _ViewMode _mode = _ViewMode.byTime;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // ===========================================================================
  // --- VERİ YÜKLEME / KAYDETME ---
  // ===========================================================================

  Future<void> _load() async {
    final email =
        (FirebaseAuth.instance.currentUser?.email ?? '').trim().toLowerCase();
    final List<_MedEntry> entries = [];
    List<_CustomGroup> customGroups = [];
    try {
      final futures = <Future<DocumentSnapshot<Map<String, dynamic>>>>[
        ...widget.patientIds.map((id) =>
            FirebaseFirestore.instance.collection('patients').doc(id).get()),
        if (_uid != null)
          FirebaseFirestore.instance.collection('users').doc(_uid).get(),
      ];
      final docs = await Future.wait(futures);

      for (final doc in docs.take(widget.patientIds.length)) {
        if (!doc.exists) continue;
        final data = doc.data()!;
        final owner = (data['owner_mail'] ?? '').toString().toLowerCase();
        final secondary = List<String>.from(data['secondary_mails'] ?? [])
            .map((e) => e.toLowerCase())
            .toList();
        final canEdit = owner == email || secondary.contains(email);
        final List<dynamic> meds = data['medications'] ?? [];
        for (int i = 0; i < meds.length; i++) {
          final m = meds[i];
          entries.add(_MedEntry(
            patientId: doc.id,
            patientName: data['patient_name'] ?? '',
            photo: (data['photo_url'] ?? '') as String,
            medIndex: i,
            medName: m['name'] ?? '',
            pillCount: (m['pillCount'] ?? 0) as int,
            isActive: m['isActive'] ?? true,
            times: ((m['schedule'] ?? []) as List)
                .map<TimeOfDay>((t) => TimeOfDay(
                    hour: (t['h'] ?? 8) as int, minute: (t['m'] ?? 0) as int))
                .toList(),
            canEdit: canEdit,
          ));
        }
      }

      // Manuel gruplamalar (Firestore'da kalıcı; gruba özgü anahtar).
      if (_uid != null && docs.length > widget.patientIds.length) {
        final userData = docs.last.data() ?? {};
        final raw = (userData['gcp_custom_groups'] ?? {}) as Map?;
        final list = (raw?[widget.groupId] ?? []) as List? ?? [];
        customGroups = list
            .map((g) => _CustomGroup.fromMap(Map<String, dynamic>.from(g)))
            .toList();
        // Artık var olmayan üyeleri ayıkla.
        final validKeys = entries.map((e) => e.key).toSet();
        for (final g in customGroups) {
          g.members = g.members.where(validKeys.contains).toList();
        }
      }
    } catch (e) {
      debugPrint('[GroupDashboard] load error: $e');
    }
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _customGroups = customGroups;
      _loading = false;
    });
  }

  Future<void> _saveCustomGroups() async {
    if (_uid == null) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(_uid).set({
        'gcp_custom_groups': {
          widget.groupId: _customGroups.map((g) => g.toMap()).toList(),
        }
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[GroupDashboard] saveCustomGroups error: $e');
    }
  }

  // ===========================================================================
  // --- OTOMATİK KOVALAR ---
  // ===========================================================================

  Map<TimeOfDay, List<_MedEntry>> get _timeBuckets {
    final Map<String, MapEntry<TimeOfDay, List<_MedEntry>>> buckets = {};
    for (final e in _entries.where((e) => e.isActive)) {
      for (final t in e.times) {
        final k =
            '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
        buckets.putIfAbsent(k, () => MapEntry(t, []));
        buckets[k]!.value.add(e);
      }
    }
    final sortedKeys = buckets.keys.toList()..sort();
    return {for (final k in sortedKeys) buckets[k]!.key: buckets[k]!.value};
  }

  Map<int, List<_MedEntry>> get _stockBuckets {
    final Map<int, List<_MedEntry>> buckets = {};
    for (final e in _entries) {
      buckets.putIfAbsent(e.pillCount, () => []).add(e);
    }
    final sorted = buckets.keys.toList()..sort();
    return {for (final k in sorted) k: buckets[k]!};
  }

  /// İsim kovaları: küçük harfe indirgenmiş ada göre eşleme.
  Map<String, List<_MedEntry>> get _nameBuckets {
    final Map<String, List<_MedEntry>> buckets = {};
    for (final e in _entries) {
      final k = e.medName.trim().toLowerCase();
      if (k.isEmpty) continue;
      buckets.putIfAbsent(k, () => []).add(e);
    }
    final sorted = buckets.keys.toList()..sort();
    return {for (final k in sorted) k: buckets[k]!};
  }

  List<_MedEntry> _membersOf(_CustomGroup g) =>
      _entries.where((e) => g.members.contains(e.key)).toList();

  // ===========================================================================
  // --- TOPLU İŞLEMLER ---
  // ===========================================================================

  List<Map<String, int>> _toSchedule(List<TimeOfDay> times) {
    final seen = <String>{};
    final list = <Map<String, int>>[];
    final sorted = List<TimeOfDay>.from(times)
      ..sort((a, b) => (a.hour * 60 + a.minute) - (b.hour * 60 + b.minute));
    for (final t in sorted) {
      if (seen.add('${t.hour}:${t.minute}')) {
        list.add({'h': t.hour, 'm': t.minute});
      }
    }
    return list;
  }

  Future<void> _finishBulk(int updated, int skipped) async {
    if (!mounted) return;
    final msg = StringBuffer('gcp_updated'.tr(args: [updated.toString()]));
    if (skipped > 0) {
      msg.write(' • ${'gcp_skipped_readonly'.tr(args: [skipped.toString()])}');
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg.toString())));
    if (updated > 0) {
      await AlarmCoordinator().rescheduleAll(context);
    }
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  /// Hedef listeyi düzenlenebilir/atlanan olarak ayırır ve işlemi uygular.
  Future<void> _applyToTargets(
    List<_MedEntry> targets,
    Future<bool> Function(_MedEntry e) op,
  ) async {
    setState(() => _busy = true);
    int updated = 0, skipped = 0;
    for (final e in targets) {
      if (!e.canEdit) {
        skipped++;
        continue;
      }
      if (await op(e)) updated++;
    }
    await _finishBulk(updated, skipped);
  }

  /// SAAT: [oldTime] saatini topluca yeni saate taşır (diğer saatler korunur).
  Future<void> _bulkChangeTime(TimeOfDay oldTime, List<_MedEntry> targets) async {
    final newTime =
        await showTimePicker(context: context, initialTime: oldTime);
    if (newTime == null ||
        (newTime.hour == oldTime.hour && newTime.minute == oldTime.minute)) {
      return;
    }
    await _applyToTargets(targets, (e) {
      final newTimes = e.times
          .map((t) => (t.hour == oldTime.hour && t.minute == oldTime.minute)
              ? newTime
              : t)
          .toList();
      return _patientService.updateMedicationFields(e.patientId, e.medIndex,
          schedule: _toSchedule(newTimes));
    });
  }

  /// SAAT EKLE/DÜZENLE POP-UP'I (manuel gruplar): üyelerin saatlerinin
  /// birleşimini çipler halinde gösterir — bir saate dokununca time picker
  /// açılır ve o saat TÜM üyelerde topluca değişir; + çipiyle tüm üyelere
  /// yeni ortak saat eklenir.
  Future<void> _showTimeEditor(List<_MedEntry> targets) async {
    final distinct = <String, TimeOfDay>{};
    for (final e in targets) {
      for (final t in e.times) {
        distinct['${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}'] = t;
      }
    }
    final keys = distinct.keys.toList()..sort();

    // Dokunulan eylem diyalogdan dönüş değeriyle taşınır:
    // ('edit', TimeOfDay) → o saati değiştir; ('add', null) → yeni saat ekle.
    final result = await showDialog<(String, TimeOfDay?)>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('gcp_edit_times'.tr()),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('reminder_times_header'.tr(),
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600,
                    color: Colors.blueGrey)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (keys.isEmpty)
                  Text('no_times_added'.tr(),
                      style: TextStyle(
                          fontSize: 12, color: Colors.blueGrey.shade300)),
                for (final k in keys)
                  InputChip(
                    avatar: const Icon(Icons.access_time_rounded,
                        size: 16, color: AppColors.skyBlue),
                    label: Text(distinct[k]!.format(context),
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    backgroundColor: AppColors.skyBlue.withOpacity(0.08),
                    side: BorderSide.none,
                    onPressed: () =>
                        Navigator.pop(context, ('edit', distinct[k])),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: Text('add_time'.tr(),
                      style: const TextStyle(fontSize: 13)),
                  onPressed: () => Navigator.pop(context, ('add', null)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('gcp_edit_times_hint'.tr(),
                style: TextStyle(
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    color: Colors.blueGrey.shade300)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('close'.tr())),
        ],
      ),
    );
    if (result == null || !mounted) return;

    if (result.$1 == 'edit' && result.$2 != null) {
      await _bulkChangeTime(result.$2!, targets);
    } else if (result.$1 == 'add') {
      await _bulkAddTime(targets);
    }
  }

  /// SAAT: tüm hedeflere ortak hatırlatma saati ekler.
  Future<void> _bulkAddTime(List<_MedEntry> targets) async {
    final newTime = await showTimePicker(
        context: context, initialTime: const TimeOfDay(hour: 8, minute: 0));
    if (newTime == null) return;
    await _applyToTargets(
        targets,
        (e) => _patientService.updateMedicationFields(e.patientId, e.medIndex,
            schedule: _toSchedule([...e.times, newTime])));
  }

  /// STOK: tüm hedeflerin stok adedini aynı değere ayarlar.
  Future<void> _bulkSetStock(List<_MedEntry> targets, {int? initial}) async {
    final controller = TextEditingController(text: (initial ?? 0).toString());
    final value = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('gcp_set_stock'.tr()),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: 'gcp_stock_value_label'.tr(),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('cancel'.tr())),
          ElevatedButton(
            onPressed: () =>
                Navigator.pop(context, int.tryParse(controller.text)),
            child: Text('save'.tr()),
          ),
        ],
      ),
    );
    if (value == null) return;
    await _applyToTargets(
        targets,
        (e) => _patientService.updateMedicationFields(e.patientId, e.medIndex,
            pillCount: value));
  }

  /// İSİM: tüm hedefleri aynı yeni adla yeniden adlandırır.
  Future<void> _bulkRename(List<_MedEntry> targets, {String? initial}) async {
    final controller = TextEditingController(text: initial ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('gcp_rename'.tr()),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'gcp_new_name_label'.tr(),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('cancel'.tr())),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text('save'.tr()),
          ),
        ],
      ),
    );
    if (value == null || value.isEmpty) return;
    await _applyToTargets(
        targets,
        (e) => _patientService.updateMedicationFields(e.patientId, e.medIndex,
            name: value));
  }

  // ===========================================================================
  // --- MANUEL GRUPLAMA: OLUŞTUR / DÜZENLE / SİL ---
  // ===========================================================================

  Future<void> _createCustomGroup() async {
    // 1) Kriter seçimi
    final criterion = await showModalBottomSheet<_Criterion>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Text('gcp_criterion_title'.tr(),
                style: GoogleFonts.inter(
                    fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 8),
            _criterionOption(_Criterion.name, Icons.medication_rounded,
                'gcp_criterion_name'.tr()),
            _criterionOption(_Criterion.time, Icons.schedule_rounded,
                'gcp_criterion_time'.tr()),
            _criterionOption(_Criterion.stock, Icons.inventory_2_rounded,
                'gcp_criterion_stock'.tr()),
            _criterionOption(_Criterion.other, Icons.tune_rounded,
                'gcp_criterion_other'.tr()),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (criterion == null || !mounted) return;

    // 2) Özel grup adı
    final nameController = TextEditingController();
    final groupName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('gcp_group_name_label'.tr()),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: InputDecoration(hintText: 'gcp_group_name_hint'.tr()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('cancel'.tr())),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, nameController.text.trim()),
            child: Text('create'.tr()),
          ),
        ],
      ),
    );
    if (groupName == null || groupName.isEmpty || !mounted) return;

    // 3) Üye seçimi
    final members = await _pickMembers(initial: const {});
    if (members == null || members.isEmpty) return;

    setState(() {
      _customGroups.add(_CustomGroup(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: groupName,
        criterion: criterion,
        members: members.toList(),
      ));
    });
    await _saveCustomGroups();
  }

  Widget _criterionOption(_Criterion c, IconData icon, String label) {
    return ListTile(
      leading: Icon(icon, color: AppColors.skyBlue),
      title: Text(label),
      onTap: () => Navigator.pop(context, c),
    );
  }

  /// Üye çoklu seçim diyaloğu. Read-only girdiler soluk + kilitli gösterilir
  /// ve seçilemez (dokununca yetki uyarısı).
  Future<Set<String>?> _pickMembers({required Set<String> initial}) {
    final selected = Set<String>.from(initial);
    return showDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text('gcp_select_members'.tr()),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final e in _entries)
                  Opacity(
                    opacity: e.canEdit ? 1.0 : 0.45,
                    child: CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: selected.contains(e.key),
                      activeColor: AppColors.skyBlue,
                      title: Text(e.medName,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: e.canEdit
                                  ? AppColors.deepSea
                                  : Colors.grey)),
                      subtitle: Text(e.patientName,
                          style: const TextStyle(fontSize: 11)),
                      secondary: e.canEdit
                          ? null
                          : const Icon(Icons.lock_rounded,
                              size: 16, color: Colors.grey),
                      onChanged: e.canEdit
                          ? (v) => setLocal(() {
                                if (v == true) {
                                  selected.add(e.key);
                                } else {
                                  selected.remove(e.key);
                                }
                              })
                          : (_) => _showNoPermission(),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('cancel'.tr())),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, selected),
              child: Text('save'.tr()),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editGroupMembers(_CustomGroup g) async {
    final members = await _pickMembers(initial: g.members.toSet());
    if (members == null) return;
    setState(() => g.members = members.toList());
    await _saveCustomGroups();
  }

  Future<void> _deleteCustomGroup(_CustomGroup g) async {
    setState(() => _customGroups.remove(g));
    await _saveCustomGroups();
  }

  // ===========================================================================
  // --- YETKİ UYARISI ---
  // ===========================================================================

  void _showNoPermission() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.lock_rounded, color: Colors.orange, size: 36),
        title: Text('no_permission'.tr()),
        content: Text('read_only_warning'.tr(),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13)),
        actions: [
          Center(
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: Text('ok_btn'.tr()),
            ),
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
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.deepSea),
        centerTitle: true,
        title: Column(
          children: [
            Text(widget.groupName,
                style: GoogleFonts.inter(
                    fontWeight: FontWeight.w800,
                    fontSize: 17,
                    color: AppColors.deepSea)),
            Text('group_control_panel'.tr(),
                style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.skyBlue,
                    letterSpacing: 0.5)),
          ],
        ),
      ),
      // Manuel modda: yeni gruplama oluştur.
      floatingActionButton: _mode == _ViewMode.manual && !_loading
          ? FloatingActionButton(
              backgroundColor: AppColors.skyBlue,
              foregroundColor: Colors.white,
              onPressed: _busy ? null : _createCustomGroup,
              child: const Icon(Icons.add),
            )
          : null,
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.skyBlue))
          : Stack(
              children: [
                RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
                    children: [
                      _buildSummaryCard(),
                      const SizedBox(height: 16),
                      _buildModeSelector(),
                      const SizedBox(height: 16),
                      if (_entries.isEmpty)
                        _buildEmpty()
                      else ...[
                        if (_mode == _ViewMode.byTime) ..._buildTimeView(),
                        if (_mode == _ViewMode.byStock) ..._buildStockView(),
                        if (_mode == _ViewMode.byName) ..._buildNameView(),
                        if (_mode == _ViewMode.manual) ..._buildManualView(),
                      ],
                    ],
                  ),
                ),
                if (_busy)
                  Positioned.fill(
                    child: Container(
                      color: Colors.black26,
                      child: const Center(
                          child:
                              CircularProgressIndicator(color: Colors.white)),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildSummaryCard() {
    final patientCount = _entries.map((e) => e.patientId).toSet().length;
    final lowStock =
        _entries.where((e) => e.isActive && e.pillCount <= 1).length;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.deepSea, AppColors.skyBlue],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          _summaryItem(patientCount.toString(), 'gcp_patients'.tr(),
              icon: Icons.groups_rounded),
          _vDivider(),
          _summaryItem(_entries.length.toString(), 'gcp_medications'.tr(),
              imageAsset: 'assets/single_pill.png'),
          _vDivider(),
          _summaryItem(lowStock.toString(), 'gcp_low_stock'.tr(),
              icon: Icons.warning_amber_rounded,
              color: lowStock > 0 ? const Color(0xFFFFD2D2) : Colors.white),
        ],
      ),
    );
  }

  /// Üç özet öğesi arasındaki ayraçlar birebir aynı (boyut + kenar boşluğu).
  Widget _vDivider() => Container(
      width: 1,
      height: 36,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      color: Colors.white.withOpacity(0.25));

  Widget _summaryItem(String value, String label,
      {IconData? icon, String? imageAsset, Color color = Colors.white}) {
    return Expanded(
      child: Column(
        children: [
          if (imageAsset != null)
            Image.asset(imageAsset,
                width: 20,
                height: 20,
                color: color.withOpacity(0.9),
                colorBlendMode: BlendMode.srcIn)
          else
            Icon(icon, color: color.withOpacity(0.9), size: 20),
          const SizedBox(height: 4),
          Text(value,
              style: GoogleFonts.inter(
                  fontSize: 18, fontWeight: FontWeight.w800, color: color)),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                  fontSize: 11, color: color.withOpacity(0.8))),
        ],
      ),
    );
  }

  Widget _buildModeSelector() {
    // Dar ekranda 4 segment taşabiliyordu; FittedBox ile sığdır (taşma yok).
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: SegmentedButton<_ViewMode>(
      segments: [
        ButtonSegment(
            value: _ViewMode.byTime,
            label: Text('gcp_by_time'.tr(),
                style: const TextStyle(fontSize: 11))),
        ButtonSegment(
            value: _ViewMode.byStock,
            label: Text('gcp_by_stock'.tr(),
                style: const TextStyle(fontSize: 11))),
        ButtonSegment(
            value: _ViewMode.byName,
            label: Text('gcp_by_name'.tr(),
                style: const TextStyle(fontSize: 11))),
        ButtonSegment(
            value: _ViewMode.manual,
            label: Text('gcp_manual'.tr(),
                style: const TextStyle(fontSize: 11))),
      ],
      selected: {_mode},
      onSelectionChanged: (s) => setState(() => _mode = s.first),
      style: SegmentedButton.styleFrom(
        backgroundColor: Colors.white,
        selectedBackgroundColor: AppColors.skyBlue,
        selectedForegroundColor: Colors.white,
        foregroundColor: AppColors.deepSea,
        side: BorderSide(color: AppColors.skyBlue.withOpacity(0.25)),
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      showSelectedIcon: false,
      ),
    );
  }

  Widget _buildEmpty() {
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
          Text('gcp_no_meds'.tr(),
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                  fontSize: 14, color: AppColors.deepSea.withOpacity(0.5))),
        ],
      ),
    );
  }

  // --- SAATE GÖRE ---

  List<Widget> _buildTimeView() {
    final buckets = _timeBuckets;
    if (buckets.isEmpty) return [_buildEmpty()];
    return [
      for (final entry in buckets.entries)
        _buildBucketCard(
          header: Row(
            children: [
              _headerChip(
                  text: entry.key.format(context), color: AppColors.skyBlue),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                    '${entry.value.length} ${'medications_suffix'.tr()}',
                    style: GoogleFonts.inter(
                        fontSize: 12, color: Colors.blueGrey)),
              ),
              _bucketAction(Icons.edit_rounded, 'gcp_change_time'.tr(),
                  () => _bulkChangeTime(entry.key, entry.value)),
            ],
          ),
          entries: entry.value,
        ),
    ];
  }

  // --- STOĞA GÖRE ---

  List<Widget> _buildStockView() {
    final buckets = _stockBuckets;
    if (buckets.isEmpty) return [_buildEmpty()];
    return [
      for (final entry in buckets.entries)
        _buildBucketCard(
          header: Row(
            children: [
              _headerChip(
                  text: '${entry.key} ${'pills'.tr()}',
                  color: _stockColor(entry.key),
                  icon: Icons.inventory_2_rounded),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                    '${entry.value.length} ${'medications_suffix'.tr()}',
                    style: GoogleFonts.inter(
                        fontSize: 12, color: Colors.blueGrey)),
              ),
              _bucketAction(Icons.edit_rounded, 'gcp_set_stock_btn'.tr(),
                  () => _bulkSetStock(entry.value, initial: entry.key)),
            ],
          ),
          entries: entry.value,
          showTimes: true,
        ),
    ];
  }

  // --- İSME GÖRE ---

  List<Widget> _buildNameView() {
    final buckets = _nameBuckets;
    if (buckets.isEmpty) return [_buildEmpty()];
    return [
      for (final entry in buckets.entries)
        _buildBucketCard(
          header: Row(
            children: [
              _headerChip(
                  text: entry.value.first.medName,
                  color: AppColors.turquoise,
                  imageAsset: 'assets/single_pill.png'),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                    '${entry.value.length} ${'medications_suffix'.tr()}',
                    style: GoogleFonts.inter(
                        fontSize: 12, color: Colors.blueGrey)),
              ),
              _bucketAction(
                  Icons.edit_rounded,
                  'gcp_rename'.tr(),
                  () => _bulkRename(entry.value,
                      initial: entry.value.first.medName)),
            ],
          ),
          entries: entry.value,
          showTimes: true,
        ),
    ];
  }

  // --- MANUEL: ÖZEL GRUPLAMALAR ---

  List<Widget> _buildManualView() {
    if (_customGroups.isEmpty) {
      return [
        Container(
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.skyBlue.withOpacity(0.15)),
          ),
          child: Column(
            children: [
              const Icon(Icons.dashboard_customize_rounded,
                  size: 44, color: AppColors.skyBlue),
              const SizedBox(height: 12),
              Text('gcp_no_custom_groups'.tr(),
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                      fontSize: 13,
                      color: AppColors.deepSea.withOpacity(0.6))),
            ],
          ),
        ),
      ];
    }
    return [for (final g in _customGroups) _buildCustomGroupCard(g)];
  }

  String _criterionLabel(_Criterion c) {
    switch (c) {
      case _Criterion.name:
        return 'gcp_criterion_name'.tr();
      case _Criterion.time:
        return 'gcp_criterion_time'.tr();
      case _Criterion.stock:
        return 'gcp_criterion_stock'.tr();
      case _Criterion.other:
        return 'gcp_criterion_other'.tr();
    }
  }

  Widget _buildCustomGroupCard(_CustomGroup g) {
    final members = _membersOf(g);
    // Kritere göre izin verilen toplu aksiyonlar:
    final bool canName =
        g.criterion == _Criterion.name || g.criterion == _Criterion.other;
    final bool canTime =
        g.criterion == _Criterion.time || g.criterion == _Criterion.other;
    final bool canStock =
        g.criterion == _Criterion.stock || g.criterion == _Criterion.other;

    return _buildBucketCard(
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: _headerChip(
                    text: g.name,
                    color: AppColors.deepSea,
                    icon: Icons.folder_special_rounded),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.turquoise.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_criterionLabel(g.criterion),
                    style: GoogleFonts.inter(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: AppColors.turquoise)),
              ),
              const Spacer(),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert_rounded,
                    size: 20, color: Colors.blueGrey),
                onSelected: (v) {
                  if (v == 'members') _editGroupMembers(g);
                  if (v == 'delete') _deleteCustomGroup(g);
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                      value: 'members',
                      child: Text('gcp_edit_members'.tr(),
                          style: const TextStyle(fontSize: 13))),
                  PopupMenuItem(
                      value: 'delete',
                      child: Text('delete'.tr(),
                          style: const TextStyle(
                              fontSize: 13, color: Colors.red))),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Kritere bağlı toplu aksiyonlar
          Wrap(
            spacing: 4,
            children: [
              if (canName)
                _bucketAction(Icons.drive_file_rename_outline_rounded,
                    'gcp_rename'.tr(), () => _bulkRename(members)),
              if (canTime)
                _bucketAction(Icons.more_time_rounded, 'gcp_edit_times'.tr(),
                    () => _showTimeEditor(members)),
              if (canStock)
                _bucketAction(Icons.inventory_2_rounded,
                    'gcp_set_stock_btn'.tr(), () => _bulkSetStock(members)),
            ],
          ),
        ],
      ),
      entries: members,
      showTimes: true,
    );
  }

  // --- ORTAK PARÇALAR ---

  Widget _headerChip(
      {required String text,
      required Color color,
      IconData? icon,
      String? imageAsset}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (imageAsset != null) ...[
            Image.asset(imageAsset,
                width: 15,
                height: 15,
                color: color,
                colorBlendMode: BlendMode.srcIn),
            const SizedBox(width: 6),
          ] else if (icon != null) ...[
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(text,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                    fontSize: 15, fontWeight: FontWeight.w800, color: color)),
          ),
        ],
      ),
    );
  }

  Widget _bucketAction(IconData icon, String label, VoidCallback onTap) {
    return TextButton.icon(
      onPressed: _busy ? null : onTap,
      icon: Icon(icon, size: 15),
      label: Text(label, style: const TextStyle(fontSize: 11)),
      style: TextButton.styleFrom(
        foregroundColor: AppColors.skyBlue,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  Color _stockColor(int count) {
    if (count <= 1) return Colors.red;
    if (count <= 5) return Colors.orange;
    return AppColors.turquoise;
  }

  Widget _buildBucketCard(
      {required Widget header,
      required List<_MedEntry> entries,
      bool showTimes = false}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.skyBlue.withOpacity(0.12)),
        boxShadow: [
          BoxShadow(
              color: AppColors.deepSea.withOpacity(0.04),
              blurRadius: 10,
              offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          const Divider(height: 16, thickness: 0.5),
          for (final e in entries) _buildEntryTile(e, showTimes: showTimes),
        ],
      ),
    );
  }

  /// İlaç satırı. Read-only girdiler soluk/gri gösterilir; dokununca
  /// yetki uyarısı açılır ve hiçbir düzenleme yapılamaz.
  Widget _buildEntryTile(_MedEntry e, {bool showTimes = false}) {
    final bool locked = !e.canEdit;
    final Color nameColor = locked
        ? Colors.grey
        : (e.isActive ? AppColors.deepSea : Colors.blueGrey);

    final tile = Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: locked ? Colors.grey.shade100 : AppColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: locked
                ? Colors.grey.shade300
                : AppColors.skyBlue.withOpacity(0.08)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: locked
                ? Colors.grey.shade300
                : AppColors.turquoise.withOpacity(0.15),
            backgroundImage:
                e.photo.isNotEmpty ? NetworkImage(e.photo) : null,
            child: e.photo.isNotEmpty
                ? null
                : Text(
                    e.patientName.isNotEmpty
                        ? e.patientName[0].toUpperCase()
                        : '?',
                    style: TextStyle(
                        fontSize: 13,
                        color: locked ? Colors.grey : AppColors.turquoise,
                        fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.medName,
                    style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: nameColor)),
                Text(
                  e.patientName +
                      (showTimes && e.times.isNotEmpty
                          ? ' • ${e.times.map((t) => t.format(context)).join(', ')}'
                          : ''),
                  style: GoogleFonts.inter(
                      fontSize: 11,
                      color: locked ? Colors.grey : Colors.blueGrey),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: locked
                  ? Colors.grey.shade300
                  : _stockColor(e.pillCount).withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('${e.pillCount}',
                style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color:
                        locked ? Colors.grey : _stockColor(e.pillCount))),
          ),
          if (locked)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.lock_rounded, size: 14, color: Colors.grey),
            ),
        ],
      ),
    );

    if (locked) {
      // Soluk göster + dokununca yetki uyarısı.
      return GestureDetector(
        onTap: _showNoPermission,
        child: Opacity(opacity: 0.55, child: tile),
      );
    }
    return tile;
  }
}
