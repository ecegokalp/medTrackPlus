import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:medTrackPlus/beta/enums/app_mode.dart';
import 'package:medTrackPlus/beta/providers/mode_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the app mode (device / device-free) and the multi-patient
/// preference for device-free mode.
///
/// Storage:
///   - SharedPreferences ('app_mode', 'multi_patient') → fast access at boot
///   - users/{uid}.app_mode, users/{uid}.multi_patient → survives reinstall
///
/// The in-memory source of truth during a session is [modeProvider]
/// (lib/beta/providers/mode_provider.dart); this service loads/saves it.
class AppModeService {
  static const _kModeKey = 'app_mode';
  static const _kMultiPatientKey = 'multi_patient';
  static const _kModeChosenKey = 'app_mode_chosen';

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Loads the persisted mode into [modeProvider]. Call during bootstrap.
  /// Falls back to Firestore if SharedPreferences has no value
  /// (e.g. fresh install on a new phone).
  Future<void> loadMode({String? uid}) async {
    final prefs = await SharedPreferences.getInstance();
    String? raw = prefs.getString(_kModeKey);

    if (raw == null && uid != null) {
      try {
        final doc = await _firestore.collection('users').doc(uid).get();
        raw = doc.data()?['app_mode'] as String?;
        if (raw != null) {
          await prefs.setString(_kModeKey, raw);
          await prefs.setBool(_kModeChosenKey, true);
          final multi = doc.data()?['multi_patient'];
          if (multi is bool) await prefs.setBool(_kMultiPatientKey, multi);
        }
      } catch (_) {}
    }

    modeProvider.setMode(
        raw == 'device_free' ? AppMode.deviceFree : AppMode.device);
  }

  /// True once the user has explicitly answered the
  /// "Do you have a MedTrack+ device?" onboarding question.
  Future<bool> hasChosenMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kModeChosenKey) ?? false;
  }

  /// Persists the mode locally + to Firestore and updates [modeProvider].
  Future<void> saveMode(AppMode mode, {String? uid}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = mode == AppMode.deviceFree ? 'device_free' : 'device';
    await prefs.setString(_kModeKey, raw);
    await prefs.setBool(_kModeChosenKey, true);
    modeProvider.setMode(mode);
    if (uid != null) {
      try {
        await _firestore
            .collection('users')
            .doc(uid)
            .set({'app_mode': raw}, SetOptions(merge: true));
      } catch (_) {}
    }
  }

  /// Whether the device-free dashboard is configured for multiple patients.
  Future<bool> isMultiPatient() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kMultiPatientKey) ?? false;
  }

  Future<void> saveMultiPatient(bool multi, {String? uid}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kMultiPatientKey, multi);
    if (uid != null) {
      try {
        await _firestore
            .collection('users')
            .doc(uid)
            .set({'multi_patient': multi}, SetOptions(merge: true));
      } catch (_) {}
    }
  }
}
