import 'package:flutter/material.dart';
import 'package:medTrackPlus/app/device_list_screen.dart';
import 'package:medTrackPlus/app/login_screen.dart';
import 'package:medTrackPlus/app/main_hub.dart';
import 'package:medTrackPlus/app/permissions_screen.dart';
import 'package:medTrackPlus/app/relatives_screen.dart';
import 'package:medTrackPlus/app/settings_screen.dart';
import 'package:medTrackPlus/app/welcome_screen.dart';
import 'package:medTrackPlus/features/ble_provisioning/sync_screen.dart';

/// Registry of all existing (production) screens.
/// Used by DeveloperScreen to allow direct navigation during testing.
/// Screens that require live objects (AlarmRingScreen, WifiCredentialsScreen) are excluded.
class ScreensRegistry {
  static final List<ScreenEntry> screens = [
    ScreenEntry(
      name: 'Welcome Screen',
      description: 'First launch / onboarding screen',
      icon: Icons.waving_hand_rounded,
      builder: (_) => const WelcomeScreen(),
    ),
    ScreenEntry(
      name: 'Permissions Screen',
      description: 'Runtime permission requests',
      icon: Icons.verified_user_rounded,
      builder: (_) => const PermissionsScreen(),
    ),
    ScreenEntry(
      name: 'Login Screen',
      description: 'Google Sign-In',
      icon: Icons.login_rounded,
      builder: (_) => const LoginScreen(),
    ),
    ScreenEntry(
      name: 'Main Hub',
      description: 'Tab navigation hub (authenticated)',
      icon: Icons.home_rounded,
      builder: (_) => const MainHub(),
    ),
    ScreenEntry(
      name: 'Device List Screen',
      description: 'User\'s connected devices',
      icon: Icons.devices_rounded,
      builder: (_) => DeviceListScreen(
        isDragMode: false,
        onModeChanged: (_) {},
      ),
    ),
    ScreenEntry(
      name: 'Relatives Screen',
      description: 'Manage relatives / caregivers',
      icon: Icons.people_rounded,
      builder: (_) => const RelativesScreen(),
    ),
    ScreenEntry(
      name: 'Settings Screen',
      description: 'User preferences',
      icon: Icons.settings_rounded,
      builder: (_) => const SettingsScreen(),
    ),
    ScreenEntry(
      name: 'Sync Screen',
      description: 'BLE device provisioning (non-onboarding)',
      icon: Icons.bluetooth_rounded,
      builder: (_) => const SyncScreen(isOnboarding: false),
    ),
  ];
}

class ScreenEntry {
  final String name;
  final String description;
  final IconData icon;
  final WidgetBuilder builder;

  const ScreenEntry({
    required this.name,
    required this.description,
    required this.icon,
    required this.builder,
  });
}
