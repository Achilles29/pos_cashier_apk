import 'package:flutter/material.dart';

import 'models.dart';
import 'screens/cashier_screen.dart';
import 'screens/login_screen.dart';
import 'screens/setup_screen.dart';
import 'services/background_sync_service.dart';
import 'services/local_database.dart';
import 'services/settings_store.dart';

class PosCashierApp extends StatefulWidget {
  const PosCashierApp({super.key});

  @override
  State<PosCashierApp> createState() => _PosCashierAppState();
}

class _PosCashierAppState extends State<PosCashierApp> {
  final SettingsStore _settingsStore = SettingsStore();
  late Future<AppSettings> _settingsFuture;

  @override
  void initState() {
    super.initState();
    _settingsFuture = _loadSettings();
    _scheduleBackgroundSync(_settingsFuture);
  }

  void _reloadSettings() {
    setState(() {
      _settingsFuture = _loadSettings();
    });
    _scheduleBackgroundSync(_settingsFuture);
  }

  Future<AppSettings> _loadSettings() async {
    final settings = await _settingsStore.load();
    LocalDatabase.instance.setScope(settings.storageScope);
    if (await _settingsStore.consumeLegacyMigrationFlag()) {
      await LocalDatabase.instance.migrateLegacyScope(settings.storageScope);
    }
    return settings;
  }

  void _scheduleBackgroundSync(Future<AppSettings> future) {
    future.then((settings) => BackgroundSyncService.schedule(settings));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'POS Kasir',
      theme: ThemeData(
        useMaterial3: true,
        visualDensity: VisualDensity.compact,
        textTheme: const TextTheme(
          displayLarge: TextStyle(fontSize: 36, letterSpacing: 0),
          displayMedium: TextStyle(fontSize: 30, letterSpacing: 0),
          displaySmall: TextStyle(fontSize: 26, letterSpacing: 0),
          headlineLarge: TextStyle(fontSize: 24, letterSpacing: 0),
          headlineMedium: TextStyle(fontSize: 21, letterSpacing: 0),
          headlineSmall: TextStyle(fontSize: 20, letterSpacing: 0),
          titleLarge: TextStyle(fontSize: 18, letterSpacing: 0),
          titleMedium: TextStyle(fontSize: 16, letterSpacing: 0),
          titleSmall: TextStyle(fontSize: 14, letterSpacing: 0),
          bodyLarge: TextStyle(fontSize: 14, letterSpacing: 0),
          bodyMedium: TextStyle(fontSize: 13, letterSpacing: 0),
          bodySmall: TextStyle(fontSize: 11, letterSpacing: 0),
          labelLarge: TextStyle(fontSize: 12, letterSpacing: 0),
          labelMedium: TextStyle(fontSize: 11, letterSpacing: 0),
          labelSmall: TextStyle(fontSize: 10, letterSpacing: 0),
        ),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF943F35),
          brightness: Brightness.light,
        ).copyWith(
          primary: const Color(0xFF8C3F35),
          onPrimary: Colors.white,
          secondary: const Color(0xFF6E584F),
          surface: const Color(0xFFFFFCF9),
          onSurface: const Color(0xFF2F2521),
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F3EE),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFFF8F4),
          foregroundColor: Color(0xFF3E2C26),
          elevation: 0,
          scrolledUnderElevation: 1,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: TextStyle(
            color: Color(0xFF3E2C26),
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
        cardTheme: const CardTheme(
          color: Colors.white,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Color(0xFFFFFCFA),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(9)),
            ),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(10)),
          ),
        ),
      ),
      home: FutureBuilder<AppSettings>(
        future: _settingsFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }

          final settings = snapshot.data!;
          LocalDatabase.instance.setScope(settings.storageScope);
          if (!settings.isConfigured) {
            return SetupScreen(
              initialSettings: settings,
              settingsStore: _settingsStore,
              onSaved: _reloadSettings,
            );
          }

          if (settings.authToken.trim().isEmpty) {
            return LoginScreen(
              settings: settings,
              settingsStore: _settingsStore,
              onLoggedIn: _reloadSettings,
              onOpenSetup: _reloadSettings,
            );
          }

          return CashierScreen(
            settings: settings,
            settingsStore: _settingsStore,
            onOpenSetup: _reloadSettings,
          );
        },
      ),
    );
  }
}
