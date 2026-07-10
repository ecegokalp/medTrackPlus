import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;

// Roller için enum tanımı
enum DeviceRole { owner, secondary, readOnly, none }

class DatabaseService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Realtime Database (ESP32 ile haberleşme için)
  final rtdb.FirebaseDatabase _rtdb = rtdb.FirebaseDatabase.instanceFor(
    app: Firebase.app(),
    databaseURL: 'https://medtrack-plus-default-rtdb.europe-west1.firebasedatabase.app',
  );

  // --- YARDIMCI METOTLAR ---
  String _sanitize(String email) => email.trim().toLowerCase();

  // --- ENTITY ÇÖZÜMLEME (device-free desteği) ---
  // Cihazlar MAC adresiyle ('AA:BB:...'), hastalar 'patient_<uuid>' ID'siyle
  // tanımlanır. Aynı rol hiyerarşisi (owner/secondary/read_only) iki
  // koleksiyonda da geçerlidir: 'dispenser' ve 'patients'.
  static bool isPatientId(String entityId) => entityId.startsWith('patient_');
  String entityCollection(String entityId) =>
      isPatientId(entityId) ? 'patients' : 'dispenser';
  DocumentReference<Map<String, dynamic>> _entityDoc(String entityId) =>
      _firestore.collection(entityCollection(entityId)).doc(entityId);
  // Cihazlarda ilaç listesi 'section_config', hastalarda 'medications'
  // alanında tutulur (aynı eleman şekli: name/isActive/pillCount/schedule).
  String _medsField(String entityId) =>
      isPatientId(entityId) ? 'medications' : 'section_config';

  /// Hastalarda pillCount Firestore'daki medications dizisinde tutulur
  /// (RTDB yok). delta: +1 iade, -1 alındı.
  Future<void> _adjustPatientPillCount(String patientId, int medIndex, int delta) async {
    try {
      final docRef = _entityDoc(patientId);
      await _firestore.runTransaction((transaction) async {
        final snapshot = await transaction.get(docRef);
        if (!snapshot.exists) return;
        final data = snapshot.data() as Map<String, dynamic>;
        List<dynamic> meds = List.from(data['medications'] ?? []);
        if (medIndex >= 0 && medIndex < meds.length) {
          final current = (meds[medIndex]['pillCount'] ?? 0) as int;
          meds[medIndex]['pillCount'] = (current + delta).clamp(0, 9999);
          transaction.update(docRef, {'medications': meds});
        }
      });
      print('[DatabaseService] Patient pill count adjusted: $patientId med#$medIndex delta=$delta');
    } catch (e) {
      print('[DatabaseService] _adjustPatientPillCount error: $e');
    }
  }

  // ===========================================================================
  // --- BÖLÜM 1: CİHAZ LİSTELEME VE SENKRONİZASYON ---
  // ===========================================================================

  Future<List<Map<String, String>>> getAllUserDevices(String uid, String rawEmail) async {
    List<Map<String, String>> devices = [];
    String email = _sanitize(rawEmail);

    try {
      final sw = Stopwatch()..start();
      var results = await Future.wait([
        _firestore.collection('dispenser').where('owner_mail', isEqualTo: email).get(),
        _firestore.collection('dispenser').where('secondary_mails', arrayContains: email).get(),
        _firestore.collection('dispenser').where('read_only_mails', arrayContains: email).get(),
      ]);
      sw.stop();
      print('>>> getAllUserDevices: ${sw.elapsedMilliseconds}ms');

      Set<String> addedMacs = {};

      for (var snapshot in results) {
        for (var doc in snapshot.docs) {
          if (!addedMacs.contains(doc.id)) {
            addedMacs.add(doc.id);
            String name = 'unknown_device'.tr();
            if (doc.data().containsKey('device_name')) {
              name = doc.get('device_name');
            }
            devices.add({
              'mac': doc.id,
              'name': name,
            });
          }
        }
      }
    } catch (e) {
      print("Cihaz listesi çekme hatası: $e");
    }
    return devices;
  }

  Future<void> updateUserDeviceList(String uid, String rawEmail) async {
    if (uid.isEmpty || rawEmail.isEmpty) return;
    final String email = _sanitize(rawEmail);

    try {
      final sw = Stopwatch()..start();
      final results = await Future.wait([
        _firestore.collection('dispenser').where('owner_mail', isEqualTo: email).get(),
        _firestore.collection('dispenser').where('secondary_mails', arrayContains: email).get(),
        _firestore.collection('dispenser').where('read_only_mails', arrayContains: email).get(),
      ]);
      final ownerQuery = results[0];
      final secondaryQuery = results[1];
      final readOnlyQuery = results[2];
      sw.stop();
      print('>>> updateUserDeviceList: ${sw.elapsedMilliseconds}ms');

      final Set<String> ownedIds = ownerQuery.docs.map((d) => d.id).toSet();
      final Set<String> secondaryIds = secondaryQuery.docs.map((d) => d.id).toSet();
      final Set<String> readOnlyIds = readOnlyQuery.docs.map((d) => d.id).toSet();

      secondaryIds.removeAll(ownedIds);
      readOnlyIds.removeAll(ownedIds);
      readOnlyIds.removeAll(secondaryIds);

      await _firestore.collection('users').doc(uid).update({
        'owned_dispensers': ownedIds.toList(),
        'secondary_dispensers': secondaryIds.toList(),
        'read_only_dispensers': readOnlyIds.toList(),
      });
    } catch (e) {
      print('Update list error: $e');
    }
  }

  // ===========================================================================
  // --- BÖLÜM 2: SAYAÇ, LOG VE RAPORLAMA ---
  // ===========================================================================
  // --- RTDB İADE İŞLEMİ (DÜZELTİLDİ: Transaction yerine Get-Set) ---
  Future<void> incrementPillCount(String macAddress, int sectionIndex) async {
    if (macAddress.isEmpty) return;
    if (isPatientId(macAddress)) {
      // Device-free: hasta stoğu Firestore'da tutulur.
      await _adjustPatientPillCount(macAddress, sectionIndex, 1);
      return;
    }
    try {
      rtdb.DatabaseReference ref = _rtdb.ref("dispensers/$macAddress/config/section_$sectionIndex/pillCount");

      // Önce mevcut değeri oku
      final snapshot = await ref.get();
      if (snapshot.exists) {
        int current = 0;
        if (snapshot.value is int) {
          current = snapshot.value as int;
        } else {
          current = int.tryParse(snapshot.value.toString()) ?? 0;
        }

        // Sonra 1 fazlasını yaz
        await ref.set(current + 1);
        print(">>> RTDB BAŞARIYLA ARTTIRILDI: $current -> ${current + 1} (Bölme $sectionIndex)");
      } else {
        // Değer hiç yoksa 1 yap
        await ref.set(1);
        print(">>> RTDB YOKTU, 1 OLARAK AYARLANDI.");
      }
    } catch (e) {
      print('!!! SAYAC ARTIRMA HATASI: $e');
    }
  }

  // --- GÜVENLİ İADE MANTIĞI ---
  Future<void> safeRefundPill(String macAddress, int sectionIndex, String currentUserId) async {
    try {
      final now = DateTime.now();
      // Son 5 dakika kuralı
      final fiveMinutesAgo = now.subtract(const Duration(minutes: 1));

      print("Güvenli İade Kontrolü Başlıyor... (Cihaz: $macAddress, Bölme: $sectionIndex)");

      // 1. KONTROL: Sistem zaten iade yapmış mı?
      final sw = Stopwatch()..start();
      final refundCheck = await _entityDoc(macAddress).collection('logs')
          .where('type', isEqualTo: 'system_refund')
          .where('section', isEqualTo: sectionIndex)
          .where('timestamp', isGreaterThan: fiveMinutesAgo)
          .get();
      sw.stop();
      print('>>> safeRefundPill query: ${sw.elapsedMilliseconds}ms');

      if (refundCheck.docs.isNotEmpty) {
        print("!!! GÜVENLİK KİLİDİ DEVREDE !!!");
        print("Son 5 dakika içinde zaten bir iade yapılmış. İşlem mükerrer olmaması için iptal ediliyor.");
        return; // BURADA ÇIKIYORSA ARTMAZ
      }

      // 2. İŞLEM: RTDB Stok Artır
      await incrementPillCount(macAddress, sectionIndex);

      // 3. İŞLEM: "İade Yapıldı" Logu At (Kilidi Aktif Et)
      await _entityDoc(macAddress).collection('logs').add({
        'type': 'system_refund',
        'section': sectionIndex,
        'triggered_by': currentUserId,
        'timestamp': FieldValue.serverTimestamp(),
      });

      print("Güvenli iade ve loglama tamamlandı.");

    } catch (e) {
      print("Safe refund error: $e");
    }
  }

  // --- YENİ EKLENEN: Sadece Stok Sayısını Güncelle (Home Screen Kullanıyor) ---
  Future<void> updatePillCountOnly(String macAddress, int sectionIndex, int newCount) async {
    if (macAddress.isEmpty) return;
    try {
      DocumentReference docRef = _entityDoc(macAddress);
      final String medsField = _medsField(macAddress);

      await _firestore.runTransaction((transaction) async {
        DocumentSnapshot snapshot = await transaction.get(docRef);
        if (!snapshot.exists) return;

        Map<String, dynamic> data = snapshot.data() as Map<String, dynamic>;
        List<dynamic> config = List.from(data[medsField] ?? []);

        if (sectionIndex < config.length) {
          config[sectionIndex]['pillCount'] = newCount;
          transaction.update(docRef, {medsField: config});
        }
      });
      print("Firestore Sync OK: Bölme $sectionIndex -> $newCount");
    } catch (e) {
      print('Stok güncelleme hatası: $e');
    }
  }

  Future<void> logDispenseStatus({
    required String macAddress,
    required int sectionIndex,
    required bool successful,
    required String userResponse,
    required String userId,
  }) async {
    try {
      await _entityDoc(macAddress).collection('logs').add({
        'type': 'user_feedback',
        'section': sectionIndex,
        'success': successful,
        'response': userResponse,
        'userId': userId,
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Log error: $e');
    }
  }

  Future<Map<String, dynamic>> getDispenseStats(String macAddress, String targetUserId) async {
    try {
      final now = DateTime.now();
      final startOfWeek = now.subtract(const Duration(days: 7));

      final sw = Stopwatch()..start();
      final query = await _entityDoc(macAddress).collection('logs')
          .where('userId', isEqualTo: targetUserId)
          .where('timestamp', isGreaterThan: startOfWeek)
          .orderBy('timestamp', descending: true)
          .get();
      sw.stop();
      print('>>> getDispenseStats: ${sw.elapsedMilliseconds}ms');

      int total = 0; int success = 0; int failed = 0;
      Map<int, int> weeklySuccessMap = {1:0, 2:0, 3:0, 4:0, 5:0, 6:0, 7:0};
      Map<String, Map<String, int>> sectionStats = {};

      for (var doc in query.docs) {
        final data = doc.data();
        if (data['type'] == 'user_feedback') {
          total++;

          String sectionKey = (data['section'] ?? 0).toString();
          if (!sectionStats.containsKey(sectionKey)) {
            sectionStats[sectionKey] = {'success': 0, 'failed': 0};
          }

          if (data['success'] == true) {
            success++;
            sectionStats[sectionKey]!['success'] = (sectionStats[sectionKey]!['success']!) + 1;

            if (data['timestamp'] != null) {
              DateTime ts = (data['timestamp'] as Timestamp).toDate();
              weeklySuccessMap[ts.weekday] = (weeklySuccessMap[ts.weekday] ?? 0) + 1;
            }
          } else {
            failed++;
            sectionStats[sectionKey]!['failed'] = (sectionStats[sectionKey]!['failed']!) + 1;
          }
        }
      }
      return {
        'total': total,
        'success': success,
        'failed': failed,
        'weeklyData': weeklySuccessMap,
        'sectionStats': sectionStats
      };
    } catch (e) {
      print("Stats Error: $e");
      return {'total': 0, 'success': 0, 'failed': 0, 'weeklyData': {}, 'sectionStats': {}};
    }
  }

  // --- VERIFICATION İSTATİSTİKLERİ ---

  Future<Map<String, dynamic>> getVerificationStats(String macAddress, {DateTime? startDate, DateTime? endDate}) async {
    try {
      final now = DateTime.now();
      final start = startDate ?? now.subtract(const Duration(days: 7));
      final end = endDate ?? now;

      // Firestore: detaylı verification geçmişi.
      // NOT: timestamp alanı LOKAL saatle ISO string olarak yazılıyor
      // (VerificationResult.toFirestore → DateTime.now().toIso8601String()).
      // Eski kod UTC string ile lexicographic karşılaştırma yapıyordu; UTC+3
      // bölgelerde son 3 saatin doğrulamaları pencere DIŞINDA kalıyor ve
      // "az önce yaptığım doğrulama raporda yok" hatasına yol açıyordu.
      // Düzeltme: her timestamp'i DateTime olarak parse edip UTC'de
      // karşılaştır (Timestamp tipini de destekle).
      final startUtc = start.toUtc();
      final endUtc = end.toUtc();
      final allDocs = await _entityDoc(macAddress)
          .collection('verifications')
          .get();
      final query = allDocs.docs.where((doc) {
        final raw = doc.data()['timestamp'];
        DateTime? ts;
        if (raw is Timestamp) {
          ts = raw.toDate();
        } else if (raw != null) {
          ts = DateTime.tryParse(raw.toString());
        }
        if (ts == null) return false;
        final t = ts.toUtc();
        return !t.isBefore(startUtc) && !t.isAfter(endUtc);
      }).toList();

      int total = 0, successCount = 0, suspiciousCount = 0, rejectedCount = 0;
      int notDetectedCount = 0;
      double totalScore = 0;
      Map<String, Map<String, dynamic>> sectionBreakdown = {};

      for (var doc in query) {
        final data = doc.data();
        total++;

        final classification = data['classification'] ?? 'unknown';
        final score = (data['accuracyScore'] ?? 0).toDouble();
        final section = (data['sectionIndex'] ?? data['section'] ?? 0).toString();

        totalScore += score;

        if (classification == 'success') successCount++;
        else if (classification == 'suspicious') suspiciousCount++;
        else if (classification == 'rejected') rejectedCount++;

        // Consent-OFF stage watchdog: detection never advanced and the
        // verification was flagged with failureReason: 'not_detected'.
        if (data['failureReason'] == 'not_detected') notDetectedCount++;

        if (!sectionBreakdown.containsKey(section)) {
          sectionBreakdown[section] = {
            'total': 0, 'success': 0, 'suspicious': 0, 'rejected': 0, 'totalScore': 0.0,
          };
        }
        sectionBreakdown[section]!['total'] = (sectionBreakdown[section]!['total'] as int) + 1;
        sectionBreakdown[section]![classification] = ((sectionBreakdown[section]![classification] ?? 0) as int) + 1;
        sectionBreakdown[section]!['totalScore'] = (sectionBreakdown[section]!['totalScore'] as double) + score;
      }

      // Section bazlı ortalama hesapla
      for (var section in sectionBreakdown.keys) {
        final s = sectionBreakdown[section]!;
        final sTotal = s['total'] as int;
        s['avgScore'] = sTotal > 0 ? (s['totalScore'] as double) / sTotal : 0.0;
        s.remove('totalScore');
      }

      // RTDB: son verification (permission hatası olursa null döner)
      Map<String, dynamic>? lastVerification;
      try {
        lastVerification = await getLastVerification(macAddress);
      } catch (_) {}

      return {
        'total': total,
        'success': successCount,
        'suspicious': suspiciousCount,
        'rejected': rejectedCount,
        'notDetected': notDetectedCount,
        'successRate': total > 0 ? successCount / total : 0.0,
        'suspiciousRate': total > 0 ? suspiciousCount / total : 0.0,
        'rejectedRate': total > 0 ? rejectedCount / total : 0.0,
        'avgScore': total > 0 ? totalScore / total : 0.0,
        'sectionBreakdown': sectionBreakdown,
        'lastVerification': lastVerification,
        'source': 'firestore+rtdb',
      };
    } catch (e) {
      print("Verification Stats Error: $e");
      return {
        'total': 0, 'success': 0, 'suspicious': 0, 'rejected': 0,
        'notDetected': 0,
        'successRate': 0.0, 'suspiciousRate': 0.0, 'rejectedRate': 0.0,
        'avgScore': 0.0, 'sectionBreakdown': {}, 'lastVerification': null,
        'source': 'error',
      };
    }
  }

  // ===========================================================================
  // --- BÖLÜM 3: CİHAZ TERCİHLERİ VE YARDIMCI METOTLAR ---
  // ===========================================================================

  Future<void> saveDevicePreference(String uid, String macAddress, bool feedbackEnabled) async {
    try {
      await _firestore.collection('users').doc(uid).set({
        'device_preferences': {
          macAddress: {'feedback_enabled': feedbackEnabled}
        }
      }, SetOptions(merge: true));
    } catch (e) { print("Pref save error: $e"); }
  }

  Future<bool> getDeviceFeedbackPreference(String uid, String macAddress) async {
    try {
      var doc = await _firestore.collection('users').doc(uid).get();
      if (doc.exists && doc.data()!.containsKey('device_preferences')) {
        var prefs = doc.data()!['device_preferences'] as Map<String, dynamic>;
        if (prefs.containsKey(macAddress)) {
          return prefs[macAddress]['feedback_enabled'] ?? false;
        }
      }
    } catch (e) { print("Pref read error: $e"); }
    return false;
  }

  Future<String?> getUserIdByEmail(String email) async {
    try {
      var query = await _firestore.collection('users').where('email', isEqualTo: email).limit(1).get();
      if(query.docs.isNotEmpty) return query.docs.first.id;
    } catch(e) { print("User ID fetch error: $e"); }
    return null;
  }

  // ===========================================================================
  // --- BÖLÜM 4: TEMEL CİHAZ FONKSİYONLARI ---
  // ===========================================================================

  Future<void> saveSectionConfig(String macAddress, List<Map<String, dynamic>> sections) async {
    if (macAddress.isEmpty) return;
    try {
      await _entityDoc(macAddress).set({_medsField(macAddress): sections}, SetOptions(merge: true));
      if (isPatientId(macAddress)) return; // Hasta profili: RTDB senkronu yok.
      Map<String, dynamic> rtdbData = {};
      for (int i = 0; i < sections.length; i++) {
        rtdbData['section_$i'] = {
          'name': sections[i]['name'],
          'isActive': sections[i]['isActive'] ?? false,
          'pillCount': sections[i]['pillCount'] ?? 0,
          'schedule': sections[i]['schedule'] ?? [],
        };
      }
      rtdb.DatabaseReference ref = _rtdb.ref("dispensers/$macAddress/config");
      await ref.update(rtdbData);
    } catch (e) { print('Error saving config: $e'); }
  }

  Future<void> toggleBuzzer(String macAddress, bool makeItRing) async {
    if (macAddress.isEmpty || isPatientId(macAddress)) return; // Hasta: donanım yok.
    try {
      await _firestore.collection('dispenser').doc(macAddress).set({'alarm': makeItRing}, SetOptions(merge: true));
      rtdb.DatabaseReference ref = _rtdb.ref("dispensers/$macAddress/buzzer");
      await ref.set(makeItRing);
    } catch (e) { print('Error toggling buzzer: $e'); }
  }

  Future<void> updateDeviceName(String macAddress, String newName) async {
    if (macAddress.isEmpty || newName.isEmpty) return;
    final field = isPatientId(macAddress) ? 'patient_name' : 'device_name';
    try { await _entityDoc(macAddress).update({field: newName}); } catch (e) { print('Error updating name: $e'); }
  }

  // --- DISPENSE & VERIFICATION BRIDGE ---

  Future<void> triggerDispense(String macAddress, int sectionIndex) async {
    if (macAddress.isEmpty || isPatientId(macAddress)) return; // Hasta: motor yok.
    try {
      await _rtdb.ref("dispensers/$macAddress/commands/dispense").set({
        'section': sectionIndex,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      });
      print('[DatabaseService] Dispense command sent: section $sectionIndex');
    } catch (e) {
      print('[DatabaseService] triggerDispense error: $e');
    }
  }

  Future<void> decrementPillCount(String macAddress, int sectionIndex) async {
    if (macAddress.isEmpty) return;
    if (isPatientId(macAddress)) {
      await _adjustPatientPillCount(macAddress, sectionIndex, -1);
      return;
    }
    try {
      final ref = _rtdb.ref("dispensers/$macAddress/config/section_$sectionIndex/pillCount");
      final snapshot = await ref.get();
      if (snapshot.exists) {
        int current = 0;
        if (snapshot.value is int) {
          current = snapshot.value as int;
        } else {
          current = int.tryParse(snapshot.value.toString()) ?? 0;
        }
        final next = (current - 1).clamp(0, 9999);
        await ref.set(next);
        print('[DatabaseService] Pill count: $current → $next (section $sectionIndex)');
      }
    } catch (e) {
      print('[DatabaseService] decrementPillCount error: $e');
    }
  }

  Future<void> logDispenseAndVerify({
    required String macAddress,
    required int sectionIndex,
    required String userId,
    required double verificationScore,
    required String classification,
    required bool detectionConfirmed,
    required bool userConfirmed,
    required String verificationId,
    String? footageUrl,
  }) async {
    if (macAddress.isEmpty) return;
    try {
      await _entityDoc(macAddress).collection('logs').add({
        'type': 'dispense_verify',
        'section': sectionIndex,
        'userId': userId,
        'verificationScore': verificationScore,
        'classification': classification,
        'detectionConfirmed': detectionConfirmed,
        'userConfirmed': userConfirmed,
        'verificationId': verificationId,
        'footageUrl': footageUrl,
        'timestamp': FieldValue.serverTimestamp(),
      });
      print('[DatabaseService] Logged dispense_verify for section $sectionIndex');
    } catch (e) {
      print('[DatabaseService] logDispenseAndVerify error: $e');
    }
  }

  Future<void> logVerificationCancel({
    required String macAddress,
    required int sectionIndex,
    required String userId,
    required String reason,
  }) async {
    if (macAddress.isEmpty) return;
    try {
      await _entityDoc(macAddress).collection('logs').add({
        'type': 'verification_cancel',
        'section': sectionIndex,
        'userId': userId,
        'reason': reason,
        'timestamp': FieldValue.serverTimestamp(),
      });
      print('[DatabaseService] Logged verification_cancel: $reason');
    } catch (e) {
      print('[DatabaseService] logVerificationCancel error: $e');
    }
  }

  // --- PRESENCE & VERIFICATION ---

  Future<void> updatePresence(String macAddress, bool isPresent) async {
    if (macAddress.isEmpty || isPatientId(macAddress)) return; // Hasta: donanım yok.
    try {
      await _rtdb.ref("dispensers/$macAddress/presence").set(isPresent);
    } catch (e) { print('Presence update error: $e'); }
  }

  Future<bool> getPresence(String macAddress) async {
    if (macAddress.isEmpty || isPatientId(macAddress)) return false;
    try {
      final snapshot = await _rtdb.ref("dispensers/$macAddress/presence").get();
      if (snapshot.exists && snapshot.value is bool) return snapshot.value as bool;
    } catch (e) { print('Presence read error: $e'); }
    return false;
  }

  /// Reads the latest ultrasonic distance (cm) the firmware publishes under
  /// `dispensers/{mac}/dev/telemetry` (`distance_cm`). Returns null when no
  /// reading is available (no device, no telemetry, or non-numeric value).
  Future<double?> getDistanceCm(String macAddress) async {
    if (macAddress.isEmpty || isPatientId(macAddress)) return null;
    try {
      final snapshot =
          await _rtdb.ref("dispensers/$macAddress/dev/telemetry").get();
      if (snapshot.exists && snapshot.value is Map) {
        final raw = (snapshot.value as Map)['distance_cm'];
        if (raw is num) return raw.toDouble();
        final parsed = double.tryParse(raw?.toString() ?? '');
        if (parsed != null) return parsed;
      }
    } catch (e) {
      print('Distance read error: $e');
    }
    return null;
  }

  Future<void> setVerificationRequired(String macAddress, bool required) async {
    if (macAddress.isEmpty || isPatientId(macAddress)) return;
    try {
      await _rtdb.ref("dispensers/$macAddress/verification_required").set(required);
    } catch (e) { print('Verification required update error: $e'); }
  }

  Future<bool> getVerificationRequired(String macAddress) async {
    if (macAddress.isEmpty || isPatientId(macAddress)) return false;
    try {
      final snapshot = await _rtdb.ref("dispensers/$macAddress/verification_required").get();
      if (snapshot.exists && snapshot.value is bool) return snapshot.value as bool;
    } catch (e) { print('Verification required read error: $e'); }
    return false;
  }

  Future<void> saveLastVerification(String macAddress, {required double score, required String status}) async {
    if (macAddress.isEmpty) return;
    final payload = {
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'score': score,
      'status': status,
    };
    if (isPatientId(macAddress)) {
      // Device-free: RTDB yerine hasta dokümanına yaz.
      try {
        await _entityDoc(macAddress).set({'last_verification': payload}, SetOptions(merge: true));
      } catch (e) { print('Last verification save error (patient): $e'); }
      return;
    }
    try {
      await _rtdb.ref("dispensers/$macAddress/last_verification").set(payload);
    } catch (e) { print('Last verification save error: $e'); }
  }

  Future<Map<String, dynamic>?> getLastVerification(String macAddress) async {
    if (macAddress.isEmpty) return null;
    if (isPatientId(macAddress)) {
      try {
        final doc = await _entityDoc(macAddress).get();
        final raw = doc.data()?['last_verification'];
        if (raw is Map) {
          final data = Map<String, dynamic>.from(raw);
          return {
            'timestamp': data['timestamp'] ?? 0,
            'score': (data['score'] ?? 0).toDouble(),
            'status': data['status'] ?? 'unknown',
          };
        }
      } catch (e) { print('Last verification read error (patient): $e'); }
      return null;
    }
    try {
      final snapshot = await _rtdb.ref("dispensers/$macAddress/last_verification").get();
      if (snapshot.exists && snapshot.value is Map) {
        final data = Map<String, dynamic>.from(snapshot.value as Map);
        return {
          'timestamp': data['timestamp'] ?? 0,
          'score': (data['score'] ?? 0).toDouble(),
          'status': data['status'] ?? 'unknown',
        };
      }
    } catch (e) { print('Last verification read error: $e'); }
    return null;
  }

  // ===========================================================================
  // --- BÖLÜM 5: KULLANICI YÖNETİMİ ---
  // ===========================================================================

  Future<DeviceRole> getUserRole(String macAddress, String? rawEmail) async {
    if (rawEmail == null || macAddress.isEmpty) return DeviceRole.none;
    final String email = _sanitize(rawEmail);
    try {
      final doc = await _entityDoc(macAddress).get();
      if (!doc.exists) return DeviceRole.none;
      final data = doc.data()!;
      if ((data['owner_mail'] as String?)?.toLowerCase() == email) return DeviceRole.owner;
      final secondary = List<String>.from(data['secondary_mails'] ?? []).map((e) => _sanitize(e)).toList();
      if (secondary.contains(email)) return DeviceRole.secondary;
      final readOnly = List<String>.from(data['read_only_mails'] ?? []).map((e) => _sanitize(e)).toList();
      if (readOnly.contains(email)) return DeviceRole.readOnly;
      return DeviceRole.none;
    } catch (e) { return DeviceRole.none; }
  }

  Future<void> addReadOnlyUser(String macAddress, String rawEmail) async {
    final String email = _sanitize(rawEmail);
    if (macAddress.isEmpty || email.isEmpty) return;
    try { await _entityDoc(macAddress).update({'read_only_mails': FieldValue.arrayUnion([email])}); } catch (e) {}
  }

  Future<void> promoteToSecondary(String macAddress, String targetRawEmail) async {
    final String targetEmail = _sanitize(targetRawEmail);
    try {
      final deviceRef = _entityDoc(macAddress);
      await _firestore.runTransaction((transaction) async {
        final snapshot = await transaction.get(deviceRef);
        if (!snapshot.exists) return;
        final data = snapshot.data() as Map<String, dynamic>;
        List<String> readOnly = List<String>.from(data['read_only_mails'] ?? []);
        List<String> secondary = List<String>.from(data['secondary_mails'] ?? []);
        readOnly.removeWhere((e) => _sanitize(e) == targetEmail);
        if (!secondary.any((e) => _sanitize(e) == targetEmail)) secondary.add(targetEmail);
        transaction.update(deviceRef, {'read_only_mails': readOnly, 'secondary_mails': secondary});
      });
    } catch (e) { print('Terfi hatası: $e'); }
  }

  Future<void> demoteToReadOnly(String macAddress, String targetRawEmail) async {
    final String targetEmail = _sanitize(targetRawEmail);
    try {
      final deviceRef = _entityDoc(macAddress);
      await _firestore.runTransaction((transaction) async {
        final snapshot = await transaction.get(deviceRef);
        if (!snapshot.exists) return;
        final data = snapshot.data() as Map<String, dynamic>;
        List<String> readOnly = List<String>.from(data['read_only_mails'] ?? []);
        List<String> secondary = List<String>.from(data['secondary_mails'] ?? []);
        secondary.removeWhere((e) => _sanitize(e) == targetEmail);
        if (!readOnly.any((e) => _sanitize(e) == targetEmail)) readOnly.add(targetEmail);
        transaction.update(deviceRef, {'read_only_mails': readOnly, 'secondary_mails': secondary});
      });
    } catch (e) { print('Rütbe düşürme hatası: $e'); }
  }

  Future<void> removeUser(String macAddress, String rawEmail) async {
    final String email = _sanitize(rawEmail);
    try { await _entityDoc(macAddress).update({'read_only_mails': FieldValue.arrayRemove([email]), 'secondary_mails': FieldValue.arrayRemove([email])}); } catch (e) { print('Error removing user: $e'); }
  }

  // ===========================================================================
  // --- BÖLÜM 6: CİHAZ EKLEME (MANUEL) ---
  // ===========================================================================

  Future<String> addDeviceManually(String uid, String rawEmail, String macAddress) async {
    if (uid.isEmpty || macAddress.isEmpty || rawEmail.isEmpty) return 'invalid_info'.tr();
    final String userEmail = _sanitize(rawEmail);
    try {
      final deviceRef = _firestore.collection('dispenser').doc(macAddress);
      final userRef = _firestore.collection('users').doc(uid);
      return await _firestore.runTransaction((transaction) async {
        final userDoc = await transaction.get(userRef);
        List<dynamic> unvisibleList = [];
        if (userDoc.exists) unvisibleList = userDoc.data()?['unvisible_devices'] ?? [];
        if (unvisibleList.contains(macAddress)) {
          transaction.update(userRef, {'unvisible_devices': FieldValue.arrayRemove([macAddress]), 'visible_devices': FieldValue.arrayUnion([macAddress])});
          return 'device_re_visible'.tr();
        }
        final deviceDoc = await transaction.get(deviceRef);
        if (!deviceDoc.exists) {
          transaction.set(deviceRef, {'owner_mail': userEmail, 'secondary_mails': [], 'read_only_mails': [], 'device_name': 'MedTrack $macAddress'});
          transaction.update(userRef, {'owned_dispensers': FieldValue.arrayUnion([macAddress])});
          return 'success';
        }
        final deviceData = deviceDoc.data() as Map<String, dynamic>;
        final currentOwner = (deviceData['owner_mail'] as String?)?.toLowerCase();
        List<String> secondaryMails = List<String>.from(deviceData['secondary_mails'] ?? []);
        List<String> readOnlyMails = List<String>.from(deviceData['read_only_mails'] ?? []);
        secondaryMails.removeWhere((e) => _sanitize(e) == userEmail);
        readOnlyMails.removeWhere((e) => _sanitize(e) == userEmail);
        if (currentOwner == null || currentOwner.isEmpty) {
          transaction.update(deviceRef, {'owner_mail': userEmail, 'secondary_mails': secondaryMails, 'read_only_mails': readOnlyMails});
          transaction.update(userRef, {'owned_dispensers': FieldValue.arrayUnion([macAddress]), 'secondary_dispensers': FieldValue.arrayRemove([macAddress]), 'read_only_dispensers': FieldValue.arrayRemove([macAddress])});
        } else if (currentOwner != userEmail) {
          secondaryMails.add(userEmail);
          transaction.update(deviceRef, {'secondary_mails': secondaryMails, 'read_only_mails': readOnlyMails});
          transaction.update(userRef, {'secondary_dispensers': FieldValue.arrayUnion([macAddress]), 'owned_dispensers': FieldValue.arrayRemove([macAddress]), 'read_only_dispensers': FieldValue.arrayRemove([macAddress])});
        }
        return 'success';
      });
    } catch (e) { return 'error_occurred'.tr(args: [e.toString()]); }
  }

  // ===========================================================================
  // --- BÖLÜM 7: GRUPLAMA SİSTEMİ ---
  // ===========================================================================

  Future<void> createGroup(String uid, String groupName) async {
    try {
      final userDoc = _firestore.collection('users').doc(uid);
      final snapshot = await userDoc.get();
      List<dynamic> groups = snapshot.data()?['device_groups'] ?? [];
      String groupId = DateTime.now().millisecondsSinceEpoch.toString();
      groups.add({'id': groupId, 'name': groupName, 'devices': []});
      await userDoc.update({'device_groups': groups});
    } catch (e) { print('Error creating group: $e'); }
  }

  Future<void> deleteGroup(String uid, String groupId) async {
    try {
      final userDoc = _firestore.collection('users').doc(uid);
      final snapshot = await userDoc.get();
      List<dynamic> groups = List.from(snapshot.data()?['device_groups'] ?? []);
      groups.removeWhere((g) => g['id'] == groupId);
      await userDoc.update({'device_groups': groups});
    } catch (e) { print('Error deleting group: $e'); }
  }

  Future<void> renameGroup(String uid, String groupId, String newName) async {
    try {
      final userDoc = _firestore.collection('users').doc(uid);
      final snapshot = await userDoc.get();
      List<dynamic> groups = List.from(snapshot.data()?['device_groups'] ?? []);
      var group = groups.firstWhere((g) => g['id'] == groupId, orElse: () => null);
      if (group != null) {
        group['name'] = newName;
        await userDoc.update({'device_groups': groups});
      }
    } catch (e) { print('Error renaming group: $e'); }
  }

  Future<void> moveDeviceToGroup(String uid, String macAddress, String targetGroupId) async {
    try {
      final userDoc = _firestore.collection('users').doc(uid);
      final snapshot = await userDoc.get();
      List<dynamic> groups = List.from(snapshot.data()?['device_groups'] ?? []);
      for (var group in groups) {
        List<dynamic> devices = List.from(group['devices'] ?? []);
        devices.remove(macAddress);
        group['devices'] = devices;
      }
      if (targetGroupId.isNotEmpty) {
        var targetGroup = groups.firstWhere((g) => g['id'] == targetGroupId, orElse: () => null);
        if (targetGroup != null) {
          List<dynamic> devices = List.from(targetGroup['devices'] ?? []);
          if (!devices.contains(macAddress)) devices.add(macAddress);
          targetGroup['devices'] = devices;
        }
      }
      await userDoc.update({'device_groups': groups});
    } catch (e) { print('Error moving device: $e'); }
  }

  // ===========================================================================
  // --- BÖLÜM 8: AKRABA & GÖRÜNÜRLÜK ---
  // ===========================================================================

  Future<void> hideDevice(String uid, String macAddress) async {
    if (uid.isEmpty || macAddress.isEmpty) return;
    try {
      final userRef = _firestore.collection('users').doc(uid);
      await userRef.update({
        'unvisible_devices': FieldValue.arrayUnion([macAddress]),
        'visible_devices': FieldValue.arrayRemove([macAddress]),
      });
    } catch (e) { print('Gizleme hatası: $e'); }
  }

  Future<List<Map<String, dynamic>>> getRelativesInfo(String uid, String currentUserEmail) async {
    Set<String> relativeEmails = {};
    String myEmail = _sanitize(currentUserEmail);
    try {
      final sw = Stopwatch()..start();
      DocumentSnapshot userDoc = await _firestore.collection('users').doc(uid).get();
      if (!userDoc.exists) return [];
      Map<String, dynamic> userData = userDoc.data() as Map<String, dynamic>;
      List<dynamic> allDeviceIds = [];
      allDeviceIds.addAll(userData['owned_dispensers'] ?? []);
      allDeviceIds.addAll(userData['secondary_dispensers'] ?? []);
      allDeviceIds.addAll(userData['read_only_dispensers'] ?? []);
      // Device-free hasta profilleri de yakın keşfine dahil edilir.
      allDeviceIds.addAll(userData['owned_patients'] ?? []);
      allDeviceIds.addAll(userData['secondary_patients'] ?? []);
      allDeviceIds.addAll(userData['read_only_patients'] ?? []);
      if (allDeviceIds.isEmpty) return [];

      final deviceDocs = await Future.wait(
        allDeviceIds.map((deviceId) => _entityDoc(deviceId.toString()).get()),
      );
      for (var deviceDoc in deviceDocs) {
        if (deviceDoc.exists) {
          Map<String, dynamic> data = deviceDoc.data() as Map<String, dynamic>;
          if (data['owner_mail'] != null) relativeEmails.add(_sanitize(data['owner_mail'].toString()));
          if (data['secondary_mails'] != null) { for (var m in data['secondary_mails']) relativeEmails.add(_sanitize(m.toString())); }
          if (data['read_only_mails'] != null) { for (var m in data['read_only_mails']) relativeEmails.add(_sanitize(m.toString())); }
        }
      }
      relativeEmails.remove(myEmail);
      if (relativeEmails.isEmpty) return [];

      final profileResults = await Future.wait(
        relativeEmails.map((email) => _firestore.collection('users').where('email', isEqualTo: email).limit(1).get()),
      );

      List<Map<String, dynamic>> relativesProfiles = [];
      int i = 0;
      for (var email in relativeEmails) {
        String displayName = '';
        String photoURL = '';
        bool isRegistered = false;
        final query = profileResults[i];
        if (query.docs.isNotEmpty) {
          var profile = query.docs.first.data() as Map<String, dynamic>;
          displayName = profile['displayName'] ?? '';
          photoURL = profile['photoURL'] ?? '';
          isRegistered = true;
        }
        relativesProfiles.add({
          'email': email,
          'displayName': displayName,
          'photoURL': photoURL,
          'isRegistered': isRegistered,
        });
        i++;
      }
      sw.stop();
      print('>>> getRelativesInfo: ${sw.elapsedMilliseconds}ms');
      return relativesProfiles;
    } catch (e) { print("Genel getRelativesInfo hatası: $e"); return []; }
  }

  Future<void> updateRelativeNickname(String uid, String relativeEmail, String nickname) async {
    try {
      String safeKey = relativeEmail.replaceAll('.', '_dot_');
      await _firestore.collection('users').doc(uid).set({
        'relatives_nicknames': { safeKey: nickname }
      }, SetOptions(merge: true));
    } catch (e) { print("Nickname update error: $e"); }
  }

  Future<bool> hasAnyAssociatedDevice(String uid) async {
    try {
      DocumentSnapshot userDoc = await _firestore.collection('users').doc(uid).get();
      if (!userDoc.exists) return false;
      Map<String, dynamic> data = userDoc.data() as Map<String, dynamic>;
      List owned = data['owned_dispensers'] ?? [];
      List secondary = data['secondary_dispensers'] ?? [];
      List readOnly = data['read_only_dispensers'] ?? [];
      return owned.isNotEmpty || secondary.isNotEmpty || readOnly.isNotEmpty;
    } catch (e) { print("Cihaz kontrol hatası: $e"); return false; }
  }

  // ===========================================================================
  // --- BÖLÜM: GELİŞTİRİCİ DONANIM KONTROLÜ (dev-only) ---
  // ESP32 firmware ile paylaşılan protokol. Taban yol: dispensers/{MAC}/dev
  // Bu metotlar yalnızca fiziksel cihaz (MAC) için anlamlıdır; hasta/
  // device-free profillerde donanım yoktur, bu yüzden sessizce no-op olurlar.
  // ===========================================================================

  /// App → device: dispensers/$mac/dev/command alanına komut yazar.
  /// cmd haritasına benzersiz bir 'id' (ms timestamp) enjekte edilir.
  Future<void> sendDevCommand(String mac, Map<String, dynamic> cmd) async {
    if (mac.isEmpty || isPatientId(mac)) return; // Donanım yok.
    try {
      final payload = Map<String, dynamic>.from(cmd);
      payload['id'] = DateTime.now().millisecondsSinceEpoch;
      await _rtdb.ref("dispensers/$mac/dev/command").set(payload);
      print('[DatabaseService] dev command sent: $payload');
    } catch (e) {
      print('[DatabaseService] sendDevCommand error: $e');
    }
  }

  Future<void> devMotorStep(String mac, int section, int steps) =>
      sendDevCommand(mac, {'action': 'motor_step', 'section': section, 'steps': steps});

  Future<void> devMotorSlot(String mac, int section, int slots) =>
      sendDevCommand(mac, {'action': 'motor_slot', 'section': section, 'slots': slots});

  Future<void> devHome(String mac, int section) =>
      sendDevCommand(mac, {'action': 'home', 'section': section});

  Future<void> devHomeAll(String mac) =>
      sendDevCommand(mac, {'action': 'home_all'});

  Future<void> devRefillSync(String mac, int section) =>
      sendDevCommand(mac, {'action': 'refill_sync', 'section': section});

  Future<void> devRefillSyncAll(String mac) =>
      sendDevCommand(mac, {'action': 'refill_sync_all'});

  Future<void> devDispense(String mac, int section) =>
      sendDevCommand(mac, {'action': 'dispense', 'section': section});

  Future<void> devSound(String mac, {int track = 1}) =>
      sendDevCommand(mac, {'action': 'sound', 'track': track});

  Future<void> devLed(String mac, int state) =>
      sendDevCommand(mac, {'action': 'led', 'state': state});

  Future<void> devStream(String mac, bool on) =>
      sendDevCommand(mac, {'action': 'stream', 'on': on});

  /// Device → app: telemetri akışı (~1/sn, stream açıkken).
  /// Null/uyumsuz veriye karşı güvenli; her zaman bir Map döner.
  Stream<Map<String, dynamic>> devTelemetryStream(String mac) {
    if (mac.isEmpty || isPatientId(mac)) {
      return const Stream<Map<String, dynamic>>.empty();
    }
    return _rtdb.ref("dispensers/$mac/dev/telemetry").onValue.map((event) {
      final raw = event.snapshot.value;
      if (raw is Map) {
        try {
          return Map<String, dynamic>.from(raw);
        } catch (_) {
          return <String, dynamic>{};
        }
      }
      return <String, dynamic>{};
    });
  }

  /// Device → app: her komuttan sonra yazılan ack.
  Stream<Map<String, dynamic>?> devAckStream(String mac) {
    if (mac.isEmpty || isPatientId(mac)) {
      return const Stream<Map<String, dynamic>?>.empty();
    }
    return _rtdb.ref("dispensers/$mac/dev/ack").onValue.map((event) {
      final raw = event.snapshot.value;
      if (raw is Map) {
        try {
          return Map<String, dynamic>.from(raw);
        } catch (_) {
          return null;
        }
      }
      return null;
    });
  }

  /// Device → app: makine log satırları (en fazla son 120, ts'ye göre sıralı).
  /// En yeni en üstte (ts azalan) olacak şekilde döner.
  Stream<List<Map<String, dynamic>>> devLogsStream(String mac) {
    if (mac.isEmpty || isPatientId(mac)) {
      return const Stream<List<Map<String, dynamic>>>.empty();
    }
    return _rtdb
        .ref("dispensers/$mac/dev/logs")
        .orderByChild('ts')
        .limitToLast(120)
        .onValue
        .map((event) {
      final raw = event.snapshot.value;
      final List<Map<String, dynamic>> out = [];
      if (raw is Map) {
        raw.forEach((_, v) {
          if (v is Map) {
            try {
              out.add(Map<String, dynamic>.from(v));
            } catch (_) {}
          }
        });
      }
      int tsOf(Map<String, dynamic> m) {
        final t = m['ts'];
        if (t is int) return t;
        if (t is num) return t.toInt();
        return int.tryParse(t?.toString() ?? '') ?? 0;
      }
      out.sort((a, b) => tsOf(b).compareTo(tsOf(a))); // en yeni en üstte
      return out;
    });
  }

  Future<void> clearDevLogs(String mac) async {
    if (mac.isEmpty || isPatientId(mac)) return;
    try {
      await _rtdb.ref("dispensers/$mac/dev/logs").remove();
    } catch (e) {
      print('[DatabaseService] clearDevLogs error: $e');
    }
  }
}