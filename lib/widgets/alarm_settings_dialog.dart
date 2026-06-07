import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:medTrackPlus/main.dart' show AppColors;
import 'package:medTrackPlus/services/alarm_coordinator.dart';
import 'package:medTrackPlus/services/notification_service.dart';

/// Yeniden kullanılabilir alarm/bildirim ayarları diyaloğu.
///
/// Ayarlar (tam alarm aç/kapa, ön bildirim aç/kapa, ön bildirim süresi)
/// GLOBALDİR ve tüm entity'leri (cihazlar + device-free hastalar) etkiler —
/// bu yüzden device-free tarafında "toplu alarm ayarı" olarak hem tek hasta
/// panelinden hem çoklu hasta menüsünden açılır. Kaydedince
/// [AlarmCoordinator.rescheduleAll] ile tüm alarmlar yeniden kurulur.
class AlarmSettingsDialog {
  static Future<void> show(BuildContext context) async {
    final notificationService = NotificationService();
    final settings = await notificationService.getNotificationSettings();
    bool alarmsEnabled = settings['alarms_enabled'] ?? true;
    bool notificationsEnabled = settings['notifications_enabled'] ?? true;
    int offset = settings['offset'] ?? 10;
    const List<int> offsetOptions = [0, 5, 10, 15, 30, 60];

    if (!context.mounted) return;

    await showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (stContext, setSt) => AlertDialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          title: Text('alarm_settings'.tr(),
              style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  color: AppColors.deepSea,
                  fontSize: 18)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.alarm_on_rounded,
                      color: AppColors.skyBlue),
                  title: Text('exact_alarm_title'.tr(),
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 14)),
                  subtitle: Text('exact_alarm_desc'.tr(),
                      style: const TextStyle(fontSize: 12)),
                  value: alarmsEnabled,
                  activeColor: AppColors.skyBlue,
                  onChanged: (v) => setSt(() => alarmsEnabled = v),
                ),
                const Divider(thickness: 0.5),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.notifications_active_outlined,
                      color: AppColors.skyBlue),
                  title: Text('pre_notification_title'.tr(),
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 14)),
                  subtitle: Text('pre_notification_desc'.tr(),
                      style: const TextStyle(fontSize: 12)),
                  value: notificationsEnabled,
                  activeColor: AppColors.skyBlue,
                  onChanged: (v) => setSt(() => notificationsEnabled = v),
                ),
                if (notificationsEnabled) ...[
                  const SizedBox(height: 16),
                  Text('notification_offset_label'.tr(),
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: AppColors.deepSea)),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: offsetOptions.map((val) {
                      final isSelected = offset == val;
                      return ChoiceChip(
                        label: Text(
                          val == 0
                              ? 'exact_time_label'.tr()
                              : '$val ${'minutes_unit'.tr()}',
                          style: TextStyle(
                              color: isSelected
                                  ? Colors.white
                                  : AppColors.deepSea,
                              fontWeight: FontWeight.bold,
                              fontSize: 12),
                        ),
                        selected: isSelected,
                        selectedColor: AppColors.skyBlue,
                        backgroundColor: Colors.white,
                        onSelected: (_) => setSt(() => offset = val),
                      );
                    }).toList(),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text('cancel'.tr())),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.skyBlue,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15))),
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                await notificationService.saveNotificationSettings(
                    alarmsEnabled: alarmsEnabled,
                    notificationsEnabled: notificationsEnabled,
                    offset: offset);
                if (context.mounted) {
                  await AlarmCoordinator().rescheduleAll(context);
                }
              },
              child: Text('save'.tr(),
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }
}
