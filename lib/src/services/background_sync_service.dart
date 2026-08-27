import 'package:workmanager/workmanager.dart';

import '../models.dart';
import 'local_database.dart';
import 'settings_store.dart';
import 'sync_service.dart';

const _syncTaskName = 'pos_cashier_background_sync';

@pragma('vm:entry-point')
void posBackgroundCallback() {
  Workmanager().executeTask((task, inputData) async {
    if (task != _syncTaskName) {
      return true;
    }
    try {
      final settings = await SettingsStore().load();
      if (!settings.isConfigured || !settings.backgroundSyncEnabled) {
        return true;
      }
      final snapshot =
          await SyncService(
            settings: settings,
            localDatabase: LocalDatabase.instance,
          ).syncNow();
      return snapshot.online;
    } catch (_) {
      return false;
    }
  });
}

class BackgroundSyncService {
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    await Workmanager().initialize(posBackgroundCallback);
    _initialized = true;
  }

  static Future<void> schedule(AppSettings settings) async {
    if (!_initialized ||
        !settings.backgroundSyncEnabled ||
        !settings.isConfigured) {
      return;
    }
    await Workmanager().registerPeriodicTask(
      _syncTaskName,
      _syncTaskName,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
  }
}
