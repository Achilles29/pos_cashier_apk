import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/services/background_sync_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BackgroundSyncService.initialize();
  runApp(const PosCashierApp());
}
