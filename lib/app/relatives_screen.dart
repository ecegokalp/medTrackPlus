import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:medTrackPlus/app/relative_review_screen.dart';
import 'package:medTrackPlus/app/reports_screen.dart';
import 'package:medTrackPlus/services/auth_service.dart';
import 'package:medTrackPlus/services/database_service.dart';
import 'package:medTrackPlus/services/patient_service.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

class RelativesScreen extends StatefulWidget {
  const RelativesScreen({super.key});

  @override
  State<RelativesScreen> createState() => _RelativesScreenState();
}

class _RelativesScreenState extends State<RelativesScreen> {
  final AuthService _authService = AuthService();
  final DatabaseService _dbService = DatabaseService();
  final PatientService _patientService = PatientService();

  String? _currentUid;
  String? _currentEmail;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initUser();
  }

  Future<void> _initUser() async {
    final user = await _authService.getOrCreateUser();
    if (user != null) {
      setState(() {
        _currentUid = user.uid;
        _currentEmail = user.email;
        _isLoading = false;
      });
    }
  }

  // Takma İsim Düzenleme
  void _showEditNicknameDialog(String email, String currentNickname) {
    final controller = TextEditingController(text: currentNickname);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("edit_nickname".tr()),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("nickname_hint".tr(), style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                hintText: "father_mom_etc".tr(),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text("cancel".tr()),
          ),
          ElevatedButton(
            onPressed: () {
              if (_currentUid != null) {
                _dbService.updateRelativeNickname(_currentUid!, email, controller.text.trim());
              }
              Navigator.pop(context);
            },
            child: Text("save".tr()),
          ),
        ],
      ),
    );
  }

  // Ortak cihazları VE device-free hasta profillerini bulma
  Future<List<Map<String, String>>> _getCommonDevices(String otherEmail) async {
    List<Map<String, String>> commonDevices = [];
    if(_currentUid == null || _currentEmail == null) return [];

    // Benim listemdeki cihazlar + hasta profilleri (tek listede)
    final myDevices = await _dbService.getAllUserDevices(_currentUid!, _currentEmail!);
    final myPatients =
        await _patientService.getAllUserPatients(_currentUid!, _currentEmail!);
    final List<Map<String, String>> allEntities = [
      ...myDevices,
      // Hastaları cihaz formatına eşle ({mac, name}) — alt akışlar
      // (RelativeReviewScreen, ReportsScreen) entity-aware olduğundan
      // 'patient_' ID'leri doğrudan kullanılabilir.
      ...myPatients.map((p) => {'mac': p['id']!, 'name': p['name'] ?? ''}),
    ];

    for (var device in allEntities) {
      String entityId = device['mac']!;
      final collection =
          entityId.startsWith('patient_') ? 'patients' : 'dispenser';
      var doc = await FirebaseFirestore.instance
          .collection(collection)
          .doc(entityId)
          .get();
      if (doc.exists) {
        var data = doc.data()!;
        List<String> allUsers = [];
        if (data['owner_mail'] != null) allUsers.add(data['owner_mail']);
        if (data['secondary_mails'] != null) allUsers.addAll(List<String>.from(data['secondary_mails']));
        if (data['read_only_mails'] != null) allUsers.addAll(List<String>.from(data['read_only_mails']));

        // Diğer kişi listede mi?
        if (allUsers.map((e) => e.toLowerCase()).contains(otherEmail.toLowerCase())) {
          commonDevices.add(device);
        }
      }
    }
    return commonDevices;
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_currentUid == null) return Center(child: Text("login_error_generic".tr()));

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance.collection('users').doc(_currentUid).snapshots(),
        builder: (context, userSnapshot) {
          if (!userSnapshot.hasData) return const Center(child: CircularProgressIndicator());

          Map<String, dynamic> nicknamesMap = {};
          try {
            nicknamesMap = userSnapshot.data!.get('relatives_nicknames') as Map<String, dynamic>;
          } catch (e) { }

          return FutureBuilder<List<Map<String, dynamic>>>(
            future: _dbService.getRelativesInfo(_currentUid!, _currentEmail!),
            builder: (context, relativesSnapshot) {
              if (relativesSnapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              final relatives = relativesSnapshot.data ?? [];

              if (relatives.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(color: Colors.blue.shade50, shape: BoxShape.circle),
                        child: Icon(Icons.people_outline_rounded, size: 60, color: Colors.blue.shade200),
                      ),
                      const SizedBox(height: 16),
                      Text("no_relatives_found".tr(), style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.blueGrey.shade700)),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 40),
                        child: Text("no_relatives_desc".tr(), textAlign: TextAlign.center, style: TextStyle(color: Colors.blueGrey.shade400)),
                      ),
                    ],
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: relatives.length,
                itemBuilder: (context, index) {
                  final person = relatives[index];
                  final String email = person['email'];
                  final String rawName = person['displayName'];
                  final String photoUrl = person['photoURL'];

                  String safeKey = email.replaceAll('.', '_dot_');
                  String? nickname = nicknamesMap[safeKey];
                  String displayName = (nickname != null && nickname.isNotEmpty)
                      ? nickname
                      : (rawName.isNotEmpty ? rawName : email.split('@')[0]);

                  return Card(
                    elevation: 0,
                    margin: const EdgeInsets.only(bottom: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: Colors.grey.shade200)),
                    child: Theme(
                      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        leading: CircleAvatar(
                          radius: 26,
                          backgroundColor: const Color(0xFF1D8AD6),
                          backgroundImage: (photoUrl.isNotEmpty) ? NetworkImage(photoUrl) : null,
                          child: (photoUrl.isEmpty)
                              ? Text(displayName.isNotEmpty ? displayName[0].toUpperCase() : "?", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 20))
                              : null,
                        ),
                        title: Text(displayName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: Color(0xFF0F5191))),
                        subtitle: Text(email, style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade300), overflow: TextOverflow.ellipsis),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              onPressed: () => _showEditNicknameDialog(email, nickname ?? ""),
                              icon: const Icon(Icons.edit_note_rounded, color: Color(0xFF36C0A6)),
                              tooltip: "edit_nickname".tr(),
                            ),
                            const Icon(Icons.expand_more, color: Colors.grey),
                          ],
                        ),
                        children: [
                          FutureBuilder<List<Map<String, String>>>(
                            future: _getCommonDevices(email),
                            builder: (context, deviceSnap) {
                              if (deviceSnap.connectionState == ConnectionState.waiting) return const Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator());

                              final devices = deviceSnap.data ?? [];

                              if (devices.isEmpty) return Padding(padding: const EdgeInsets.all(16.0), child: Text("no_common_devices".tr(), style: TextStyle(color: Colors.grey.shade600)));

                              return Column(
                                children: devices.map((device) {
                                  return Padding(
                                    padding: const EdgeInsets.only(left: 60, right: 16, bottom: 6),
                                    child: Column(
                                      children: [
                                        // Birincil eylem: video doğrulama incelemesi
                                        ListTile(
                                          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                                          tileColor: Colors.white,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(12),
                                            side: BorderSide(color: Colors.blueGrey.shade50),
                                          ),
                                          leading: const Icon(Icons.videocam_rounded, color: Color(0xFF1D8AD6)),
                                          title: Text(
                                            device['name']!,
                                            style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0F5191)),
                                          ),
                                          subtitle: Text(
                                            '${'review_video_verification'.tr()} • ${device['mac']!}',
                                            style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade600),
                                          ),
                                          trailing: const Icon(Icons.chevron_right_rounded, color: Color(0xFF36C0A6)),
                                          onTap: () {
                                            Navigator.push(context, MaterialPageRoute(
                                              builder: (_) => RelativeReviewScreen(
                                                macAddress: device['mac']!,
                                              ),
                                            ));
                                          },
                                        ),
                                        const SizedBox(height: 6),
                                        // İkincil eylem: istatistik raporu
                                        Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 12),
                                          child: TextButton.icon(
                                            onPressed: () async {
                                              String? targetUid = await _dbService.getUserIdByEmail(email);
                                              if (targetUid == null) {
                                                if (!context.mounted) return;
                                                ScaffoldMessenger.of(context).showSnackBar(
                                                    SnackBar(content: Text('user_data_unreachable'.tr())));
                                                return;
                                              }
                                              if (!context.mounted) return;
                                              Navigator.push(context, MaterialPageRoute(
                                                builder: (_) => ReportsScreen(
                                                  macAddress: device['mac']!,
                                                  targetUserId: targetUid,
                                                  titlePrefix: displayName,
                                                ),
                                              ));
                                            },
                                            icon: const Icon(Icons.bar_chart_rounded, size: 18),
                                            label: Text('open_stats_report'.tr()),
                                            style: TextButton.styleFrom(
                                              foregroundColor: const Color(0xFF36C0A6),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }).toList(),
                              );
                            },
                          )
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}