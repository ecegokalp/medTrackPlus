import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:medTrackPlus/services/database_service.dart';
import 'package:medTrackPlus/services/auth_service.dart';
import 'package:medTrackPlus/main.dart';

class ReportsScreen extends StatefulWidget {
  final String macAddress;
  final String? targetUserId;
  final String? titlePrefix;

  const ReportsScreen({
    super.key,
    required this.macAddress,
    this.targetUserId,
    this.titlePrefix,
  });

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> with SingleTickerProviderStateMixin {
  final DatabaseService _db = DatabaseService();
  final AuthService _authService = AuthService();

  Map<String, dynamic> _dispenseStats = {};
  Map<String, dynamic> _verificationStats = {};
  Map<int, String> _pillNames = {};
  bool _loading = true;

  late TabController _tabController;

  /// Device-free hasta profillerinde fiziksel dispense yok →
  /// yalnızca doğrulama sekmesi gösterilir.
  bool get _isPatient => widget.macAddress.startsWith('patient_');

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _isPatient ? 1 : 2, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    String uidToUse;
    if (widget.targetUserId != null) {
      uidToUse = widget.targetUserId!;
    } else {
      final user = await _authService.getOrCreateUser();
      uidToUse = user!.uid;
    }

    // Hastalarda dispense sekmesi yok → sorguyu atla.
    final dispenseData = _isPatient
        ? <String, dynamic>{}
        : await _db.getDispenseStats(widget.macAddress, uidToUse);
    final verificationData = await _db.getVerificationStats(widget.macAddress);

    Map<int, String> pillMap = {};
    try {
      // Entity-aware: cihazlar 'dispenser/section_config',
      // device-free hastalar 'patients/medications'.
      final isPatient = widget.macAddress.startsWith('patient_');
      final collection = isPatient ? 'patients' : 'dispenser';
      final medsField = isPatient ? 'medications' : 'section_config';
      var doc = await FirebaseFirestore.instance.collection(collection).doc(widget.macAddress).get();
      if (doc.exists && doc.data()!.containsKey(medsField)) {
        List<dynamic> sections = doc.data()![medsField];
        for (int i = 0; i < sections.length; i++) {
          pillMap[i] = sections[i]['name'] ?? "unknown_pill".tr();
        }
      }
    } catch (e) {
      debugPrint("İlaç isimleri çekilemedi: $e");
    }

    if (mounted) {
      setState(() {
        _dispenseStats = dispenseData;
        _verificationStats = verificationData;
        _pillNames = pillMap;
        _loading = false;
      });
    }
  }

  String get _pageTitle {
    final base = "weekly_report".tr();
    return widget.titlePrefix != null ? "${widget.titlePrefix} - $base" : base;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(_pageTitle, style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.deepSea, fontSize: 16)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.deepSea),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.deepSea,
          unselectedLabelColor: Colors.grey,
          indicatorColor: AppColors.turquoise,
          tabs: [
            if (!_isPatient) Tab(text: "dispense_tab".tr()),
            Tab(text: "verification_tab".tr()),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                if (!_isPatient) _buildDispenseTab(),
                _buildVerificationTab(),
              ],
            ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // TAB 1: DISPENSE (mevcut)
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildDispenseTab() {
    int total = _dispenseStats['total'] ?? 0;
    int success = _dispenseStats['success'] ?? 0;
    int failed = _dispenseStats['failed'] ?? 0;

    Map<String, Map<String, int>> sectionStatsRaw = {};
    if (_dispenseStats['sectionStats'] != null) {
      _dispenseStats['sectionStats'].forEach((key, value) {
        if (value is Map<String, int>) sectionStatsRaw[key] = value;
      });
    }

    var sortedEntries = sectionStatsRaw.entries.toList()
      ..sort((a, b) => int.parse(a.key).compareTo(int.parse(b.key)));

    if (total == 0) return _buildEmptyState();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildStatCard("total_label".tr(), total.toString(), Colors.blue),
              const SizedBox(width: 10),
              _buildStatCard("success_label".tr(), success.toString(), Colors.green),
              const SizedBox(width: 10),
              _buildStatCard("issues_label".tr(), failed.toString(), Colors.redAccent),
            ],
          ),
          const SizedBox(height: 30),
          Text("weekly_activity".tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.deepSea)),
          const SizedBox(height: 20),
          _buildDispenseChart(),
          const SizedBox(height: 30),
          Text("section_details_title".tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.deepSea)),
          const SizedBox(height: 10),
          _buildDispenseSectionDetails(sortedEntries),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // TAB 2: VERIFICATION (yeni)
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildVerificationTab() {
    int total = _verificationStats['total'] ?? 0;
    int success = _verificationStats['success'] ?? 0;
    int suspicious = _verificationStats['suspicious'] ?? 0;
    int rejected = _verificationStats['rejected'] ?? 0;
    int notDetected = _verificationStats['notDetected'] ?? 0;
    double avgScore = (_verificationStats['avgScore'] ?? 0).toDouble();

    if (total == 0) return _buildEmptyState();

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Summary Cards (2x2 grid — 4 metrics would crowd a single Row)
          Row(
            children: [
              _buildVerificationCard('verified_label'.tr(), success, Colors.green, Icons.check_circle_rounded),
              const SizedBox(width: 10),
              _buildVerificationCard('suspicious_label'.tr(), suspicious, Colors.orange, Icons.warning_amber_rounded),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _buildVerificationCard('rejected_label'.tr(), rejected, Colors.redAccent, Icons.cancel_rounded),
              const SizedBox(width: 10),
              _buildVerificationCard('not_detected_label'.tr(), notDetected, Colors.blueGrey, Icons.search_off_rounded),
            ],
          ),
          const SizedBox(height: 20),

          // Accuracy Badge
          _buildAccuracyBadge(avgScore),
          const SizedBox(height: 24),

          // Verification Success Rate Bar Chart
          Text('verification_rate'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.deepSea)),
          const SizedBox(height: 16),
          _buildVerificationRateChart(success, suspicious, rejected, total),
          const SizedBox(height: 24),

          // Section Details
          Text('section_breakdown'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.deepSea)),
          const SizedBox(height: 12),
          _buildVerificationSectionDetails(),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  // --- VERIFICATION SUMMARY CARD ---

  Widget _buildVerificationCard(String label, int count, Color color, IconData icon) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(15),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10)],
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 8),
            Text(count.toString(), style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: color)),
            const SizedBox(height: 4),
            Text(label, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Colors.grey.shade600, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  // --- ACCURACY BADGE ---

  Widget _buildAccuracyBadge(double avgScore) {
    final percentage = (avgScore * 100).clamp(0.0, 100.0);
    final color = avgScore >= 0.7 ? Colors.green : avgScore >= 0.4 ? Colors.orange : Colors.redAccent;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10)],
      ),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            height: 64,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CircularProgressIndicator(
                  value: avgScore.clamp(0.0, 1.0),
                  strokeWidth: 6,
                  backgroundColor: Colors.grey.shade200,
                  valueColor: AlwaysStoppedAnimation(color),
                ),
                Center(
                  child: Text(
                    '${percentage.toStringAsFixed(0)}%',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: color),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('average_accuracy'.tr(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.deepSea)),
                const SizedBox(height: 4),
                Text(
                  avgScore >= 0.7 ? 'accuracy_good'.tr() : avgScore >= 0.4 ? 'accuracy_attention'.tr() : 'accuracy_critical'.tr(),
                  style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- VERIFICATION RATE CHART ---

  Widget _buildVerificationRateChart(int success, int suspicious, int rejected, int total) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Column(
        children: [
          _rateBar('success_title'.tr(), success, total, Colors.green),
          const SizedBox(height: 14),
          _rateBar('suspicious_label'.tr(), suspicious, total, Colors.orange),
          const SizedBox(height: 14),
          _rateBar('rejected_label'.tr(), rejected, total, Colors.redAccent),
        ],
      ),
    );
  }

  Widget _rateBar(String label, int count, int total, Color color) {
    final ratio = total > 0 ? count / total : 0.0;
    final percent = (ratio * 100).toStringAsFixed(0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
            Text('$count ($percent%)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 8,
            backgroundColor: Colors.grey.shade200,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
      ],
    );
  }

  // --- VERIFICATION SECTION DETAILS ---

  Widget _buildVerificationSectionDetails() {
    final Map<String, dynamic> breakdown = Map<String, dynamic>.from(_verificationStats['sectionBreakdown'] ?? {});
    if (breakdown.isEmpty) return const SizedBox();

    final sortedKeys = breakdown.keys.toList()..sort((a, b) => int.parse(a).compareTo(int.parse(b)));

    return Column(
      children: sortedKeys.map((key) {
        final int sectionIndex = int.parse(key);
        final data = Map<String, dynamic>.from(breakdown[key]);
        final String pillName = _pillNames[sectionIndex] ?? "unknown_pill".tr();
        final int sTotal = data['total'] ?? 0;
        final int sSuccess = data['success'] ?? 0;
        final int sSuspicious = data['suspicious'] ?? 0;
        final int sRejected = data['rejected'] ?? 0;
        final double avgScore = (data['avgScore'] ?? 0).toDouble();

        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8, offset: const Offset(0, 2))],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: AppColors.skyBlue.withOpacity(0.1), shape: BoxShape.circle),
                    child: const Icon(Icons.medication, color: AppColors.skyBlue, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("section_prefix".tr(args: [(sectionIndex + 1).toString()]),
                            style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.deepSea, fontSize: 15)),
                        Text("($pillName)", style: TextStyle(color: Colors.grey.shade600, fontSize: 13, overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                  ),
                  AccuracyBadge(score: avgScore, size: 40),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _miniStat(Icons.check_circle_rounded, Colors.green, sSuccess, sTotal),
                  _miniStat(Icons.warning_amber_rounded, Colors.orange, sSuspicious, sTotal),
                  _miniStat(Icons.cancel_rounded, Colors.redAccent, sRejected, sTotal),
                ],
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _miniStat(IconData icon, Color color, int count, int total) {
    final percent = total > 0 ? ((count / total) * 100).toStringAsFixed(0) : '0';
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text('$count', style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 14)),
        Text(' ($percent%)', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ORTAK WİDGETLAR
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.analytics_outlined, size: 80, color: Colors.grey.shade300),
          const SizedBox(height: 20),
          Text("no_data_yet".tr(), style: TextStyle(color: Colors.grey.shade500, fontSize: 16)),
        ],
      ),
    );
  }

  Widget _buildStatCard(String title, String val, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(15),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10)],
        ),
        child: Column(
          children: [
            Text(val, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: color)),
            const SizedBox(height: 5),
            Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  // --- DISPENSE CHART ---

  Widget _buildDispenseChart() {
    return Container(
      height: 280,
      padding: const EdgeInsets.fromLTRB(10, 20, 20, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [_yAxisLabel("20+"), _yAxisLabel("15"), _yAxisLabel("10"), _yAxisLabel("5"), _yAxisLabel("")],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Stack(
                  children: [
                    Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: List.generate(5, (_) => _buildGridLine())),
                    Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, crossAxisAlignment: CrossAxisAlignment.end, children: _buildBars(constraints.maxHeight)),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _yAxisLabel(String text) {
    return SizedBox(
      height: 20,
      child: Center(child: Text(text, style: const TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold))),
    );
  }

  Widget _buildGridLine() {
    return SizedBox(height: 20, child: Center(child: Container(height: 1, color: Colors.grey.shade200)));
  }

  List<Widget> _buildBars(double maxHeight) {
    Map<dynamic, dynamic> rawData = _dispenseStats['weeklyData'] ?? {};
    Map<int, int> data = {};
    rawData.forEach((key, value) {
      if (key is int && value is int) data[key] = value;
    });

    int maxScale = 20;
    List<String> days = ['day_m'.tr(), 'day_t'.tr(), 'day_w'.tr(), 'day_th'.tr(), 'day_f'.tr(), 'day_sa'.tr(), 'day_su'.tr()];

    return List.generate(7, (index) {
      int dayIndex = index + 1;
      int value = data[dayIndex] ?? 0;
      double chartAreaHeight = maxHeight - 30;
      double barHeight = (value / maxScale) * chartAreaHeight;
      if (barHeight > chartAreaHeight) barHeight = chartAreaHeight;

      return Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Tooltip(
            message: "$value",
            child: Container(
              width: 14,
              height: barHeight < 4 ? 4 : barHeight,
              decoration: BoxDecoration(
                color: value > 0 ? AppColors.skyBlue : Colors.grey.shade100,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                gradient: value > 0
                    ? const LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [AppColors.skyBlue, Color(0xFF4FC3F7)])
                    : null,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(days[index], style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 11)),
        ],
      );
    });
  }

  // --- DISPENSE SECTION DETAILS ---

  Widget _buildDispenseSectionDetails(List<MapEntry<String, Map<String, int>>> sortedEntries) {
    if (sortedEntries.isEmpty) return const SizedBox();

    return Column(
      children: sortedEntries.map((entry) {
        int sectionIndex = int.parse(entry.key);
        String sectionName = "section_prefix".tr(args: [(sectionIndex + 1).toString()]);
        String pillName = _pillNames[sectionIndex] ?? "unknown_pill".tr();
        int s = entry.value['success'] ?? 0;
        int f = entry.value['failed'] ?? 0;

        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8, offset: const Offset(0, 2))],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: AppColors.skyBlue.withOpacity(0.1), shape: BoxShape.circle),
                    child: const Icon(Icons.medication, color: AppColors.skyBlue, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(sectionName, style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.deepSea, fontSize: 15)),
                        Text("($pillName)", style: TextStyle(color: Colors.grey.shade600, fontSize: 13, overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                  ),
                ]),
              ),
              Row(children: [
                _statusBadge(Icons.check_circle_rounded, Colors.green, s),
                const SizedBox(width: 12),
                _statusBadge(Icons.cancel_rounded, Colors.redAccent, f),
              ]),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _statusBadge(IconData icon, Color color, int count) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 4),
        Text(count.toString(), style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 15)),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// ACCURACY BADGE WIDGET (Reusable)
// ═══════════════════════════════════════════════════════════════════════════

class AccuracyBadge extends StatelessWidget {
  final double score;
  final double size;

  const AccuracyBadge({super.key, required this.score, this.size = 48});

  @override
  Widget build(BuildContext context) {
    final color = score >= 0.7 ? Colors.green : score >= 0.4 ? Colors.orange : Colors.redAccent;
    final percent = (score * 100).clamp(0.0, 100.0).toStringAsFixed(0);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CircularProgressIndicator(
            value: score.clamp(0.0, 1.0),
            strokeWidth: size * 0.1,
            backgroundColor: Colors.grey.shade200,
            valueColor: AlwaysStoppedAnimation(color),
          ),
          Center(
            child: Text(
              '$percent%',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: size * 0.28, color: color),
            ),
          ),
        ],
      ),
    );
  }
}