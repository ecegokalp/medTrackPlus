import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:medTrackPlus/services/database_service.dart';
import 'package:medTrackPlus/services/notification_service.dart';
import 'package:medTrackPlus/services/patient_service.dart';

/// Birleşik alarm planlayıcısı — kullanıcının erişebildiği TÜM entity'lerin
/// (fiziksel cihazlar + device-free hasta profilleri) ilaç programlarını tek
/// seferde planlar.
///
/// Mevcut [NotificationService] altyapısını (Alarm paketi + tam ekran intent
/// + AwesomeNotifications ön bildirimleri + stok uyarıları) aynen yeniden
/// kullanır. Temizlik yalnızca İLK entity planlanırken yapılır
/// (`clearExisting: true`); sonraki entity'ler entity'ye özgü alarm ID
/// aralıklarıyla üstüne eklenir. Böylece:
///   - bir cihazın/hastanın planlaması diğerlerininkini silmez,
///   - ekranı hiç açılmamış cihaz/hasta için de alarmlar telefona kurulur.
///
/// Çağrı noktaları: MainHub açılışı + HomeScreen/PatientDashboard'da
/// program değişiklikleri (debounce'lu).
class AlarmCoordinator {
  final DatabaseService _dbService = DatabaseService();
  final PatientService _patientService = PatientService();
  final NotificationService _notificationService = NotificationService();

  bool _running = false;

  /// Tüm cihaz + hasta alarmlarını yeniden kurar. İdempotent;
  /// üst üste çağrılara karşı basit bir kilitle korunur.
  Future<void> rescheduleAll(BuildContext context) async {
    if (_running) return;
    _running = true;
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final email = user.email ?? '';

      // Cihazlar ve hastalar paralel listelenir.
      final results = await Future.wait([
        _dbService.getAllUserDevices(user.uid, email),
        _patientService.getAllUserPatients(user.uid, email),
      ]);
      final devices = results[0]; // [{mac, name}]
      final patients = results[1]; // [{id, name, photo}]

      final List<String> entityIds = [
        ...devices.map((d) => d['mac']!),
        ...patients.map((p) => p['id']!),
      ];
      if (entityIds.isEmpty) return;

      // Tüm entity dokümanlarını paralel çek (koleksiyon ID önekine göre).
      final docs = await Future.wait(entityIds.map((id) {
        final collection =
            DatabaseService.isPatientId(id) ? 'patients' : 'dispenser';
        return FirebaseFirestore.instance.collection(collection).doc(id).get();
      }));

      bool first = true;
      int scheduled = 0;
      for (final doc in docs) {
        if (!doc.exists) continue;
        final entityId = doc.id;
        final medsField = DatabaseService.isPatientId(entityId)
            ? 'medications'
            : 'section_config';
        final List<dynamic> rawMeds = doc.data()?[medsField] ?? [];
        if (rawMeds.isEmpty && !first) continue; // boş entity, temizlik sonrası atla

        final sections = rawMeds.map<Map<String, dynamic>>((m) {
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

        if (!context.mounted) return;
        await _notificationService.scheduleMedicationNotifications(
          context,
          sections,
          entityId,
          clearExisting: first, // tüm temizlik yalnızca ilk entity'de
        );
        first = false;
        scheduled++;
      }
      debugPrint(
          '[AlarmCoordinator] $scheduled entity için alarmlar planlandı '
          '(${devices.length} cihaz, ${patients.length} hasta).');
    } catch (e) {
      debugPrint('[AlarmCoordinator] rescheduleAll hatası: $e');
    } finally {
      _running = false;
    }
  }
}
