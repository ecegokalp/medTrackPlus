import 'package:medTrackPlus/app/home_screen.dart';
import 'package:medTrackPlus/app/login_screen.dart'; // <--- YENİ EKLENDİ
import 'package:medTrackPlus/app/device_free/patient_dashboard_screen.dart';
import 'package:medTrackPlus/app/device_free/patient_list_screen.dart';
import 'package:medTrackPlus/beta/providers/mode_provider.dart';
import 'package:medTrackPlus/features/ble_provisioning/sync_screen.dart';
import 'package:medTrackPlus/app/relatives_screen.dart';
import 'package:medTrackPlus/services/alarm_coordinator.dart';
import 'package:medTrackPlus/services/app_mode_service.dart';
import 'package:medTrackPlus/services/auth_service.dart';
import 'package:medTrackPlus/services/database_service.dart';
import 'package:medTrackPlus/services/patient_service.dart';
import 'package:medTrackPlus/widgets/alarm_settings_dialog.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'device_list_screen.dart';
import 'settings_screen.dart';

class MainHub extends StatefulWidget {
  const MainHub({super.key});

  @override
  State<MainHub> createState() => _MainHubState();
}

class _MainHubState extends State<MainHub> {
  final AuthService _authService = AuthService();
  final DatabaseService _dbService = DatabaseService();
  final GlobalKey<PatientListScreenState> _patientListKey = GlobalKey();
  int _selectedIndex = 0;

  bool _isDragMode = false;

  AppUser? _currentUser;

  bool get _isDeviceFree => modeProvider.isDeviceFree;

  @override
  void initState() {
    super.initState();
    // Mod değişimini dinle (Ayarlar'dan değiştirilebilir).
    modeProvider.addListener(_onModeChanged);
    _authService.getOrCreateUser().then((user) {
      if (user != null) {
        setState(() {
          _currentUser = user;
        });
        // Uygulama açılışında TÜM entity'lerin (cihaz + hasta) alarmlarını
        // kur — herhangi bir detay ekranı açılmasa bile alarmlar tetiklensin.
        if (mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) AlarmCoordinator().rescheduleAll(context);
          });
        }
      }
    });
  }

  @override
  void dispose() {
    modeProvider.removeListener(_onModeChanged);
    super.dispose();
  }

  void _onModeChanged() {
    if (mounted) setState(() => _selectedIndex = 0);
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
      _isDragMode = false;
    });
  }

  void _toggleDragMode(bool value) {
    setState(() {
      _isDragMode = value;
    });
    if (value) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("drag_info".tr()),
            duration: const Duration(seconds: 2),
          )
      );
    }
  }

  // --- GÜNCELLENEN ÇIKIŞ FONKSİYONU ---
  Future<void> _signOut() async {
    // 1. Profil menüsü (Dialog) açıksa kapat
    if (mounted && Navigator.canPop(context)) {
      Navigator.of(context).pop();
    }

    // 2. Firebase ve Google oturumunu kapat
    await _authService.signOut();

    // 3. Login Ekranına Yönlendir ve Geçmişi Temizle
    // (Böylece kullanıcı "Geri" tuşuna basıp tekrar uygulamaya giremez)
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const LoginScreen()),
            (route) => false, // Tüm geçmiş rotaları sil
      );
    }
  }

  // --- PROFİL MENÜSÜ ---
  void _showProfileMenu() {
    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Profil Fotoğrafı
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFFE0F2FE), width: 2),
                  ),
                  child: CircleAvatar(
                    radius: 42,
                    backgroundColor: const Color(0xFF1D8AD6),
                    backgroundImage: _currentUser?.photoURL != null
                        ? NetworkImage(_currentUser!.photoURL!)
                        : null,
                    child: _currentUser?.photoURL == null
                        ? Text(
                      _currentUser?.displayName != null
                          ? _currentUser!.displayName![0].toUpperCase()
                          : "U",
                      style: const TextStyle(fontSize: 32, color: Colors.white, fontWeight: FontWeight.bold),
                    )
                        : null,
                  ),
                ),
                const SizedBox(height: 16),

                // İsim ve Bilgi
                Text(
                  _currentUser?.displayName ?? "user_fallback".tr(),
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF0F5191)),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  _currentUser?.email ?? "",
                  style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade400),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),

                // Ayarlar Butonu
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 4)],
                      ),
                      child: const Icon(Icons.settings_rounded, color: Color(0xFF0F5191), size: 22),
                    ),
                    title: Text(
                        "settings_title".tr(),
                        style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF0F5191))
                    ),
                    trailing: Icon(Icons.chevron_right_rounded, color: Colors.blueGrey.shade300),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => const SettingsScreen()),
                      );
                    },
                  ),
                ),

                // Çıkış Butonu
                InkWell(
                  onTap: _signOut, // Güncellenen fonksiyon çağrılıyor
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFFECACA)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.logout_rounded, color: Colors.red.shade700, size: 20),
                        const SizedBox(width: 10),
                        Text(
                            "logout".tr(),
                            style: TextStyle(
                                color: Colors.red.shade700,
                                fontWeight: FontWeight.w700,
                                fontSize: 15
                            )
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showCreateFolderDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("create_room".tr()),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(hintText: "room_name_hint".tr()),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text("cancel".tr())
          ),
          ElevatedButton(
            onPressed: () {
              if (controller.text.isNotEmpty && _currentUser != null) {
                _dbService.createGroup(_currentUser!.uid, controller.text.trim());
              }
              Navigator.pop(context);
            },
            child: Text("create".tr()),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    Widget currentScreen;
    if (_isDeviceFree) {
      // --- DEVICE-FREE MOD: 2 sekme (Dashboard, Yakınlar) ---
      if (_selectedIndex == 0) {
        currentScreen = _DeviceFreeDashboard(patientListKey: _patientListKey);
      } else {
        currentScreen = const RelativesScreen();
      }
    } else if (_selectedIndex == 0) {
      currentScreen = DeviceListScreen(
        isDragMode: _isDragMode,
        onModeChanged: _toggleDragMode,
      );
    } else if (_selectedIndex == 1) {
      // MainHub içinden çağrıldığı için isOnboarding: false
      currentScreen = const SyncScreen(isOnboarding: false);
    } else {
      currentScreen = const RelativesScreen();
    }

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        backgroundColor: theme.scaffoldBackgroundColor,
        foregroundColor: colorScheme.onSurface,
        centerTitle: true,
        leadingWidth: 74,
        leading: Container(
          margin: const EdgeInsets.only(left: 20.0),
          child: Center(
            child: InkWell(
              onTap: _showProfileMenu,
              borderRadius: BorderRadius.circular(50),
              child: Container(
                width: 46,
                height: 46,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.transparent,
                  border: Border.all(
                      color: const Color(0xFF1D8AD6).withOpacity(0.4),
                      width: 2.5
                  ),
                ),
                child: CircleAvatar(
                  backgroundColor: colorScheme.primary,
                  backgroundImage: _currentUser?.photoURL != null
                      ? NetworkImage(_currentUser!.photoURL!)
                      : null,
                  child: _currentUser?.photoURL == null
                      ? Text(
                    _currentUser?.displayName != null
                        ? _currentUser!.displayName![0].toUpperCase()
                        : "U",
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 18),
                  )
                      : null,
                ),
              ),
            ),
          ),
        ),
        title: Text(
          _isDeviceFree
              ? (_selectedIndex == 0 ? 'dashboard'.tr() : 'relatives'.tr())
              : (_selectedIndex == 0
                  ? (_isDragMode ? 'edit_mode'.tr() : 'my_devices'.tr())
                  : (_selectedIndex == 1 ? 'sync'.tr() : 'relatives'.tr())),
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
        actions: [
          if (!_isDeviceFree && _selectedIndex == 0)
            IconButton(
              icon: Icon(
                _isDragMode ? Icons.check_circle_rounded : Icons.menu_rounded,
                size: 30,
                color: _isDragMode ? colorScheme.primary : colorScheme.onSurface,
              ),
              tooltip: _isDragMode ? 'edit_mode'.tr() : 'edit_mode'.tr(),
              onPressed: () => _toggleDragMode(!_isDragMode),
            ),
          const SizedBox(width: 12),
        ],
      ),
      body: currentScreen,
      floatingActionButton: (!_isDeviceFree && _selectedIndex == 0 && _isDragMode)
          ? FloatingActionButton.extended(
        onPressed: _showCreateFolderDialog,
        icon: const Icon(Icons.groups_rounded),
        label: Text("create_new_group".tr()),
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
      )
          : null,
      bottomNavigationBar: BottomNavigationBar(
        items: _isDeviceFree
            ? <BottomNavigationBarItem>[
                BottomNavigationBarItem(
                    icon: const Icon(Icons.dashboard_rounded),
                    label: 'dashboard'.tr()),
                BottomNavigationBarItem(
                    icon: const Icon(Icons.people_alt_rounded),
                    label: 'relatives'.tr()),
              ]
            : <BottomNavigationBarItem>[
                BottomNavigationBarItem(
                    icon: const Icon(Icons.devices_other_rounded),
                    label: 'my_devices'.tr()),
                BottomNavigationBarItem(
                    icon: const Icon(Icons.sync_rounded),
                    label: 'sync'.tr()),
                BottomNavigationBarItem(
                    icon: const Icon(Icons.people_alt_rounded),
                    label: 'relatives'.tr()),
              ],
        currentIndex: _selectedIndex.clamp(0, _isDeviceFree ? 1 : 2),
        selectedItemColor: colorScheme.primary,
        onTap: _onItemTapped,
      ),
    );
  }
}

/// Device-free "Dashboard" sekmesi.
///
/// Tek hasta modunda hastanın ilaç detayını (PatientDashboardScreen,
/// embedded) doğrudan gösterir; çoklu hasta modunda gruplandırılabilir
/// hasta listesini (PatientListScreen) gösterir. Tercih Ayarlar'dan
/// değiştirilebilir.
class _DeviceFreeDashboard extends StatefulWidget {
  final GlobalKey<PatientListScreenState> patientListKey;
  const _DeviceFreeDashboard({required this.patientListKey});

  @override
  State<_DeviceFreeDashboard> createState() => _DeviceFreeDashboardState();
}

class _DeviceFreeDashboardState extends State<_DeviceFreeDashboard> {
  final AppModeService _modeService = AppModeService();
  final PatientService _patientService = PatientService();

  bool _loading = true;
  bool _multiPatient = false;
  String? _singlePatientId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final multi = await _modeService.isMultiPatient();
    String? patientId;
    if (!multi) {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await _patientService.updateUserPatientList(user.uid, user.email ?? '');
        final patients =
            await _patientService.getAllUserPatients(user.uid, user.email ?? '');
        if (patients.isNotEmpty) patientId = patients.first['id'];
      }
    }
    if (!mounted) return;
    setState(() {
      _multiPatient = multi;
      _singlePatientId = patientId;
      _loading = false;
    });
    // Not: Alarm planlaması MainHub açılışında AlarmCoordinator ile
    // merkezi olarak yapılır; burada tekrar gerekmiyor.
  }

  Future<void> _createOwnProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final controller = TextEditingController(text: user.displayName ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('patient_name_title'.tr()),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: 'patient_name_hint'.tr()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('cancel'.tr())),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: Text('create'.tr())),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    setState(() => _loading = true);
    await _patientService.createPatient(
        uid: user.uid, rawEmail: user.email ?? '', patientName: name);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_multiPatient) {
      // Çoklu hasta: gruplandırılabilir liste + ekleme menüsü.
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: PatientListScreen(key: widget.patientListKey),
        floatingActionButton: FloatingActionButton(
          backgroundColor: Theme.of(context).colorScheme.primary,
          foregroundColor: Colors.white,
          child: const Icon(Icons.add),
          onPressed: () {
            showModalBottomSheet(
              context: context,
              shape: const RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.vertical(top: Radius.circular(20))),
              builder: (context) => SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 8),
                    ListTile(
                      leading: const Icon(Icons.person_add_rounded),
                      title: Text('create_new_patient_profile'.tr()),
                      onTap: () {
                        Navigator.pop(context);
                        widget.patientListKey.currentState
                            ?.showAddPatientDialog();
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.groups_rounded),
                      title: Text('create_new_group'.tr()),
                      onTap: () {
                        Navigator.pop(context);
                        widget.patientListKey.currentState
                            ?.showCreateGroupDialog();
                      },
                    ),
                    // Toplu alarm ayarları: tüm hastalar için geçerli
                    // (alarm aç/kapa, ön bildirim, süre).
                    ListTile(
                      leading: const Icon(Icons.alarm_rounded),
                      title: Text('alarm_settings'.tr()),
                      onTap: () {
                        Navigator.pop(context);
                        AlarmSettingsDialog.show(this.context);
                      },
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            );
          },
        ),
      );
    }

    // Tek hasta: doğrudan ilaç detay ekranı.
    if (_singlePatientId == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.person_add_alt_1_rounded,
                  size: 64, color: Colors.blueGrey),
              const SizedBox(height: 16),
              Text('no_patient_profile'.tr(), textAlign: TextAlign.center),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _createOwnProfile,
                child: Text('create_patient_profile'.tr()),
              ),
            ],
          ),
        ),
      );
    }

    return PatientDashboardScreen(
        patientId: _singlePatientId!, embedded: true);
  }
}