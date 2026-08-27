import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models.dart';

class SettingsStore {
  static const _settingsKey = 'pos_cashier_settings';
  static const _profilesKey = 'pos_connection_profiles';
  static const _activeProfileKey = 'pos_active_connection_profile';
  static const _legacyMigrationKey = 'pos_legacy_scope_pending';
  static const _uuid = Uuid();

  Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final profiles = _decodeProfiles(prefs.getString(_profilesKey));
    if (profiles.isEmpty) {
      final legacy = _decodeSettings(prefs.getString(_settingsKey));
      final migrated = _normalize(
        legacy ??
            AppSettings(backendUrl: '', terminalDeviceKey: 'APK-${_uuid.v4()}'),
      );
      if (migrated.isConfigured) {
        await _writeProfiles(prefs, [migrated], migrated.profileId);
        await prefs.setBool(_legacyMigrationKey, true);
      }
      return migrated;
    }

    final activeId = prefs.getString(_activeProfileKey) ?? '';
    final selected = profiles.where((item) => item.profileId == activeId);
    return selected.isNotEmpty ? selected.first : profiles.first;
  }

  Future<List<AppSettings>> loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    return _decodeProfiles(prefs.getString(_profilesKey));
  }

  String profileIdForUrl(String backendUrl) {
    final normalized = _normalizeUrl(backendUrl);
    return normalized.isEmpty ? '' : 'url:$normalized';
  }

  Future<AppSettings?> profile(String profileId) async {
    final profiles = await loadProfiles();
    for (final item in profiles) {
      if (item.profileId == profileId) return item;
    }
    return null;
  }

  Future<AppSettings?> profileForUrl(String backendUrl) {
    return profile(profileIdForUrl(backendUrl));
  }

  Future<void> save(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = _normalize(settings);
    final profiles = _decodeProfiles(prefs.getString(_profilesKey));
    final index = profiles.indexWhere(
      (item) => item.profileId == normalized.profileId,
    );
    if (index >= 0) {
      profiles[index] = normalized;
    } else {
      profiles.add(normalized);
    }
    await _writeProfiles(prefs, profiles, normalized.profileId);
    await prefs.setString(_settingsKey, jsonEncode(normalized.toJson()));
  }

  Future<void> activate(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final profiles = _decodeProfiles(prefs.getString(_profilesKey));
    final selected = profiles.where((item) => item.profileId == profileId);
    if (selected.isEmpty) return;
    await prefs.setString(_activeProfileKey, profileId);
    await prefs.setString(_settingsKey, jsonEncode(selected.first.toJson()));
  }

  Future<void> disconnectActive() async {
    final current = await load();
    await save(
      current.copyWith(authToken: '', authExpiresAt: '', username: ''),
    );
  }

  Future<bool> consumeLegacyMigrationFlag() async {
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getBool(_legacyMigrationKey) ?? false;
    if (pending) await prefs.setBool(_legacyMigrationKey, false);
    return pending;
  }

  Future<void> _writeProfiles(
    SharedPreferences prefs,
    List<AppSettings> profiles,
    String activeId,
  ) async {
    await prefs.setString(
      _profilesKey,
      jsonEncode(profiles.map((item) => item.toJson()).toList()),
    );
    if (activeId.isNotEmpty) {
      await prefs.setString(_activeProfileKey, activeId);
    }
  }

  List<AppSettings> _decodeProfiles(String? raw) {
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map(
            (item) => _normalize(
              AppSettings.fromJson(Map<String, Object?>.from(item)),
            ),
          )
          .where((item) => item.isConfigured)
          .toList();
    } catch (_) {
      return [];
    }
  }

  AppSettings? _decodeSettings(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      return AppSettings.fromJson(
        Map<String, Object?>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return null;
    }
  }

  AppSettings _normalize(AppSettings settings) {
    final profileId =
        settings.profileId.trim().isNotEmpty
            ? settings.profileId.trim()
            : profileIdForUrl(settings.backendUrl);
    return settings.copyWith(
      profileId: profileId,
      serverScope:
          settings.serverScope.trim().isNotEmpty
              ? settings.serverScope.trim()
              : profileId,
      terminalDeviceKey:
          settings.terminalDeviceKey.trim().isNotEmpty
              ? settings.terminalDeviceKey.trim()
              : 'APK-${_uuid.v4()}',
    );
  }

  String _normalizeUrl(String value) {
    final trimmed = value.trim().replaceFirst(RegExp(r'/+$'), '');
    if (trimmed.isEmpty) return '';
    try {
      final uri = Uri.parse(trimmed);
      if (!uri.hasScheme || uri.host.isEmpty) return trimmed.toLowerCase();
      final scheme = uri.scheme.toLowerCase();
      final host = uri.host.toLowerCase();
      final port = uri.hasPort ? ':${uri.port}' : '';
      final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
      return '$scheme://$host$port$path';
    } catch (_) {
      return trimmed.toLowerCase();
    }
  }
}
