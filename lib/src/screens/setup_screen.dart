import 'package:flutter/material.dart';

import '../models.dart';
import '../services/finance_api_client.dart';
import '../services/settings_store.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({
    super.key,
    required this.initialSettings,
    required this.settingsStore,
    required this.onSaved,
  });

  final AppSettings initialSettings;
  final SettingsStore settingsStore;
  final VoidCallback onSaved;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final TextEditingController _backendUrl;
  late final TextEditingController _terminalKey;
  late final TextEditingController _mobileApiKey;
  late final TextEditingController _outletId;
  late final TextEditingController _terminalId;
  bool _backgroundSync = true;
  bool _saving = false;
  bool _loggingOut = false;
  List<AppSettings> _profiles = const [];

  @override
  void initState() {
    super.initState();
    final settings = widget.initialSettings;
    _backendUrl = TextEditingController(text: settings.backendUrl);
    _terminalKey = TextEditingController(text: settings.terminalDeviceKey);
    _mobileApiKey = TextEditingController(text: settings.mobileApiKey);
    _outletId = TextEditingController(
      text: settings.outletId == 0 ? '' : '${settings.outletId}',
    );
    _terminalId = TextEditingController(
      text: settings.terminalId == 0 ? '' : '${settings.terminalId}',
    );
    _backgroundSync = settings.backgroundSyncEnabled;
    _loadProfiles();
  }

  Future<void> _loadProfiles() async {
    final profiles = await widget.settingsStore.loadProfiles();
    if (mounted) setState(() => _profiles = profiles);
  }

  @override
  void dispose() {
    _backendUrl.dispose();
    _terminalKey.dispose();
    _mobileApiKey.dispose();
    _outletId.dispose();
    _terminalId.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final backendUrl = _backendUrl.text.trim();
    if (backendUrl.isEmpty ||
        (!backendUrl.startsWith('http://') &&
            !backendUrl.startsWith('https://'))) {
      _showMessage('URL backend wajib diawali http:// atau https://');
      return;
    }

    setState(() => _saving = true);
    final profileId = widget.settingsStore.profileIdForUrl(backendUrl);
    final existing = await widget.settingsStore.profile(profileId);
    final sameProfile = profileId == widget.initialSettings.profileId;
    final source = existing ?? (sameProfile ? widget.initialSettings : null);
    final terminalDeviceKey = _terminalKey.text.trim();
    final bindingChanged =
        sameProfile &&
        (backendUrl.replaceFirst(RegExp(r'/+$'), '') !=
                widget.initialSettings.normalizedBackendUrl ||
            terminalDeviceKey !=
                widget.initialSettings.terminalDeviceKey.trim());
    await widget.settingsStore.save(
      AppSettings(
        backendUrl: backendUrl,
        terminalDeviceKey: terminalDeviceKey,
        profileId: profileId,
        serverScope: source?.serverScope ?? profileId,
        mobileApiKey: _mobileApiKey.text.trim(),
        authToken: bindingChanged ? '' : (source?.authToken ?? ''),
        username: bindingChanged ? '' : (source?.username ?? ''),
        authExpiresAt: bindingChanged ? '' : (source?.authExpiresAt ?? ''),
        outletId: int.tryParse(_outletId.text.trim()) ?? 0,
        terminalId: int.tryParse(_terminalId.text.trim()) ?? 0,
        backgroundSyncEnabled: _backgroundSync,
        printerName: source?.printerName ?? '',
        printerAddress: source?.printerAddress ?? '',
        printerPaperWidth: source?.printerPaperWidth ?? 58,
        printerRoutes: source?.printerRoutes ?? const {},
      ),
    );
    setState(() => _saving = false);
    widget.onSaved();
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Keluar dari akun?'),
            content: const Text(
              'Token login akan dihapus dari APK. Data lokal dan antrean transaksi tetap disimpan.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Batal'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Keluar'),
              ),
            ],
          ),
    );
    if (confirmed != true || _loggingOut) return;

    setState(() => _loggingOut = true);
    try {
      if (widget.initialSettings.authToken.trim().isNotEmpty) {
        try {
          await FinanceApiClient(settings: widget.initialSettings).logout();
        } catch (_) {
          // Local logout must still work when the server is unreachable.
        }
      }
      await widget.settingsStore.save(
        widget.initialSettings.copyWith(
          authToken: '',
          authExpiresAt: '',
          username: '',
        ),
      );
      widget.onSaved();
    } finally {
      if (mounted) setState(() => _loggingOut = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pengaturan POS')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Koneksi',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _connectionFields(),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Divider(height: 1),
                      ),
                      Text(
                        'Perangkat',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _deviceFields(),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _saving || _loggingOut ? null : _save,
                          icon:
                              _saving
                                  ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                  : const Icon(Icons.save),
                          label: const Text('Simpan pengaturan'),
                        ),
                      ),
                      if (widget.initialSettings.authToken.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _saving || _loggingOut ? null : _logout,
                            icon:
                                _loggingOut
                                    ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                    : const Icon(Icons.logout),
                            label: const Text('Keluar dari akun'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _connectionFields() {
    return Column(
      children: [
        if (_profiles.isNotEmpty) ...[
          DropdownButtonFormField<String>(
            value:
                _profiles.any(
                      (profile) =>
                          profile.profileId == widget.initialSettings.profileId,
                    )
                    ? widget.initialSettings.profileId
                    : null,
            decoration: const InputDecoration(
              labelText: 'Koneksi tersimpan',
              prefixIcon: Icon(Icons.dns_outlined),
            ),
            items:
                _profiles
                    .map(
                      (profile) => DropdownMenuItem<String>(
                        value: profile.profileId,
                        child: Text(
                          '${profile.normalizedBackendUrl}${profile.authToken.isEmpty ? ' (belum login)' : ''}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
            onChanged: _saving ? null : _switchProfile,
          ),
          const SizedBox(height: 8),
        ],
        TextField(
          controller: _backendUrl,
          decoration: const InputDecoration(
            labelText: 'URL backend finance',
            hintText: 'http://192.168.1.10/finance',
            prefixIcon: Icon(Icons.link),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _mobileApiKey,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Mobile API key',
            prefixIcon: Icon(Icons.key),
          ),
        ),
      ],
    );
  }

  Widget _deviceFields() {
    return Column(
      children: [
        TextField(
          controller: _terminalKey,
          decoration: const InputDecoration(
            labelText: 'Kode perangkat',
            prefixIcon: Icon(Icons.devices),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _outletId,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Outlet ID',
                  prefixIcon: Icon(Icons.storefront),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _terminalId,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Terminal ID',
                  prefixIcon: Icon(Icons.point_of_sale),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _backgroundSync,
          onChanged: (value) => setState(() => _backgroundSync = value),
          title: const Text('Sinkronisasi otomatis'),
        ),
      ],
    );
  }

  Future<void> _switchProfile(String? profileId) async {
    if (profileId == null || profileId == widget.initialSettings.profileId) {
      return;
    }
    await widget.settingsStore.activate(profileId);
    widget.onSaved();
  }
}
