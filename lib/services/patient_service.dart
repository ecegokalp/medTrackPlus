import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:uuid/uuid.dart';

/// CRUD + role management for device-free patient profiles.
///
/// Firestore: patients/{patientId} where patientId = 'patient_<uuid>'.
/// Mirrors the dispenser document shape so role logic, verifications,
/// logs, reports and relatives discovery work identically:
///
/// {
///   entity_type: 'patient',
///   patient_name: string,
///   owner_mail: string,            // creator (single mode: the patient)
///   secondary_mails: [string],
///   read_only_mails: [string],
///   medications: [                 // unlimited, same element shape as
///     {name, isActive, pillCount,  // dispenser section_config
///      schedule: [{h, m}, ...]},
///   ],
///   created_at, created_by_uid
/// }
///
/// users/{uid} mirrors: owned_patients / secondary_patients /
/// read_only_patients arrays + patient_groups (same shape as device_groups).
class PatientService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  String _sanitize(String email) => email.trim().toLowerCase();

  // ===========================================================================
  // --- OLUŞTURMA / SİLME ---
  // ===========================================================================

  /// Creates a patient profile; the creator becomes owner.
  /// Returns the new patientId.
  Future<String> createPatient({
    required String uid,
    required String rawEmail,
    required String patientName,
  }) async {
    final email = _sanitize(rawEmail);
    final patientId = 'patient_${const Uuid().v4()}';
    final batch = _firestore.batch();

    batch.set(_firestore.collection('patients').doc(patientId), {
      'entity_type': 'patient',
      'patient_name': patientName.trim(),
      'owner_mail': email,
      'secondary_mails': <String>[],
      'read_only_mails': <String>[],
      'medications': <Map<String, dynamic>>[],
      'created_at': FieldValue.serverTimestamp(),
      'created_by_uid': uid,
    });
    batch.set(
      _firestore.collection('users').doc(uid),
      {'owned_patients': FieldValue.arrayUnion([patientId])},
      SetOptions(merge: true),
    );

    await batch.commit();
    return patientId;
  }

  /// Deletes a patient profile (owner only — enforced by Firestore rules).
  /// Subcollections (logs/verifications) are left to TTL/cloud cleanup.
  Future<void> deletePatient(String uid, String patientId) async {
    final batch = _firestore.batch();
    batch.delete(_firestore.collection('patients').doc(patientId));
    batch.set(
      _firestore.collection('users').doc(uid),
      {
        'owned_patients': FieldValue.arrayRemove([patientId]),
        'secondary_patients': FieldValue.arrayRemove([patientId]),
        'read_only_patients': FieldValue.arrayRemove([patientId]),
      },
      SetOptions(merge: true),
    );
    await batch.commit();
  }

  // ===========================================================================
  // --- LİSTELEME / SENKRON ---
  // ===========================================================================

  /// All patients the user can access (any role): [{id, name}].
  Future<List<Map<String, String>>> getAllUserPatients(
      String uid, String rawEmail) async {
    final email = _sanitize(rawEmail);
    final List<Map<String, String>> patients = [];
    try {
      final results = await Future.wait([
        _firestore.collection('patients').where('owner_mail', isEqualTo: email).get(),
        _firestore.collection('patients').where('secondary_mails', arrayContains: email).get(),
        _firestore.collection('patients').where('read_only_mails', arrayContains: email).get(),
      ]);
      final Set<String> added = {};
      for (var snapshot in results) {
        for (var doc in snapshot.docs) {
          if (added.add(doc.id)) {
            patients.add({
              'id': doc.id,
              'name': (doc.data()['patient_name'] ?? 'default_patient_name'.tr()) as String,
              'photo': (doc.data()['photo_url'] ?? '') as String,
            });
          }
        }
      }
    } catch (e) {
      print('Hasta listesi çekme hatası: $e');
    }
    return patients;
  }

  /// Refreshes users/{uid} patient role arrays from the patients collection
  /// (same pattern as DatabaseService.updateUserDeviceList).
  Future<void> updateUserPatientList(String uid, String rawEmail) async {
    if (uid.isEmpty || rawEmail.isEmpty) return;
    final email = _sanitize(rawEmail);
    try {
      final results = await Future.wait([
        _firestore.collection('patients').where('owner_mail', isEqualTo: email).get(),
        _firestore.collection('patients').where('secondary_mails', arrayContains: email).get(),
        _firestore.collection('patients').where('read_only_mails', arrayContains: email).get(),
      ]);
      final Set<String> owned = results[0].docs.map((d) => d.id).toSet();
      final Set<String> secondary = results[1].docs.map((d) => d.id).toSet();
      final Set<String> readOnly = results[2].docs.map((d) => d.id).toSet();
      secondary.removeAll(owned);
      readOnly.removeAll(owned);
      readOnly.removeAll(secondary);

      await _firestore.collection('users').doc(uid).set({
        'owned_patients': owned.toList(),
        'secondary_patients': secondary.toList(),
        'read_only_patients': readOnly.toList(),
      }, SetOptions(merge: true));
    } catch (e) {
      print('updateUserPatientList error: $e');
    }
  }

  Future<bool> hasAnyPatient(String uid) async {
    try {
      final doc = await _firestore.collection('users').doc(uid).get();
      if (!doc.exists) return false;
      final data = doc.data()!;
      return (data['owned_patients'] as List?)?.isNotEmpty == true ||
          (data['secondary_patients'] as List?)?.isNotEmpty == true ||
          (data['read_only_patients'] as List?)?.isNotEmpty == true;
    } catch (e) {
      return false;
    }
  }

  /// Live updates for a single patient document.
  Stream<DocumentSnapshot<Map<String, dynamic>>> watchPatient(String patientId) =>
      _firestore.collection('patients').doc(patientId).snapshots();

  /// Tek bir ilacın belirli alanlarını transaction ile günceller.
  /// Group Control Panel'in toplu işlemleri (saat/stok eşitleme) bunu
  /// hasta+ilaç başına çağırır. Başarılıysa true döner.
  Future<bool> updateMedicationFields(
    String patientId,
    int medIndex, {
    String? name,
    int? pillCount,
    List<Map<String, int>>? schedule,
  }) async {
    if (name == null && pillCount == null && schedule == null) return false;
    try {
      final ref = _firestore.collection('patients').doc(patientId);
      await _firestore.runTransaction((tx) async {
        final snap = await tx.get(ref);
        if (!snap.exists) return;
        final List<dynamic> meds =
            List.from(snap.data()?['medications'] ?? []);
        if (medIndex < 0 || medIndex >= meds.length) return;
        final med = Map<String, dynamic>.from(meds[medIndex]);
        if (name != null && name.trim().isNotEmpty) med['name'] = name.trim();
        if (pillCount != null) med['pillCount'] = pillCount.clamp(0, 9999);
        if (schedule != null) med['schedule'] = schedule;
        meds[medIndex] = med;
        tx.update(ref, {'medications': meds});
      });
      return true;
    } catch (e) {
      print('updateMedicationFields error: $e');
      return false;
    }
  }

  // ===========================================================================
  // --- HASTA GRUPLARI (cihaz gruplarıyla aynı şema: patient_groups) ---
  // ===========================================================================

  Future<void> createPatientGroup(String uid, String groupName) async {
    try {
      final userDoc = _firestore.collection('users').doc(uid);
      final snapshot = await userDoc.get();
      final List<dynamic> groups =
          List.from(snapshot.data()?['patient_groups'] ?? []);
      groups.add({
        'id': DateTime.now().millisecondsSinceEpoch.toString(),
        'name': groupName,
        'devices': <String>[], // patientId listesi (alan adı device_groups ile uyumlu)
      });
      await userDoc.set({'patient_groups': groups}, SetOptions(merge: true));
    } catch (e) {
      print('Hasta grubu oluşturma hatası: $e');
    }
  }

  Future<void> deletePatientGroup(String uid, String groupId) async {
    try {
      final userDoc = _firestore.collection('users').doc(uid);
      final snapshot = await userDoc.get();
      final List<dynamic> groups =
          List.from(snapshot.data()?['patient_groups'] ?? []);
      groups.removeWhere((g) => g['id'] == groupId);
      await userDoc.update({'patient_groups': groups});
    } catch (e) {
      print('Hasta grubu silme hatası: $e');
    }
  }

  Future<void> movePatientToGroup(
      String uid, String patientId, String targetGroupId) async {
    try {
      final userDoc = _firestore.collection('users').doc(uid);
      final snapshot = await userDoc.get();
      final List<dynamic> groups =
          List.from(snapshot.data()?['patient_groups'] ?? []);
      for (var group in groups) {
        final List<dynamic> members = List.from(group['devices'] ?? []);
        members.remove(patientId);
        group['devices'] = members;
      }
      if (targetGroupId.isNotEmpty) {
        final target =
            groups.firstWhere((g) => g['id'] == targetGroupId, orElse: () => null);
        if (target != null) {
          final List<dynamic> members = List.from(target['devices'] ?? []);
          if (!members.contains(patientId)) members.add(patientId);
          target['devices'] = members;
        }
      }
      await userDoc.update({'patient_groups': groups});
    } catch (e) {
      print('Hasta taşıma hatası: $e');
    }
  }
}
