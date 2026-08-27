import 'package:flutter/material.dart';

import '../models.dart';
import '../services/finance_api_client.dart';
import '../services/settings_store.dart';
import 'printer_settings_screen.dart';

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
    await widget.settingsStore.save(
      AppSettings(
        backendUrl: backendUrl,
        terminalDeviceKey: _terminalKey.text.trim(),
        profileId: profileId,
        serverScope: source?.serverScope ?? profileId,
        mobileApiKey: _mobileApiKey.text.trim(),
        authToken: source?.authToken ?? '',
        username: source?.username ?? '',
        authExpiresAt: source?.authExpiresAt ?? '',
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
    final height =
        (MediaQuery.sizeOf(context).height - 80).clamp(520.0, 760.0).toDouble();
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Pengaturan POS'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.link), text: 'Koneksi'),
              Tab(icon: Icon(Icons.print), text: 'Printer'),
              Tab(icon: Icon(Icons.settings), text: 'Perangkat'),
            ],
          ),
        ),
        body: SafeArea(
          child: Center(
            child: SizedBox(
              width: 620,
              height: height,
              child: Card(
                margin: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 18, 20, 12),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Server finance adalah sumber master, shift, transaksi, HPP, dan stock commit.',
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: TabBarView(
                        children: [
                          _connectionTab(),
                          _printerTab(),
                          _deviceTab(),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
                      child: Column(
                        children: [
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
                                onPressed:
                                    _saving || _loggingOut ? null : _logout,
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
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _connectionTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
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
          const Text(
            'Setiap koneksi memiliki cache, transaksi lokal, outbox, dan printer binding sendiri.',
          ),
          const SizedBox(height: 14),
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
        const SizedBox(height: 14),
        const Text(
          'Gunakan alamat yang dapat dijangkau perangkat Android. Untuk emulator Android, localhost komputer adalah http://10.0.2.2/finance.',
        ),
      ],
    );
  }

  Widget _printerTab() {
    final ready = widget.initialSettings.authToken.isNotEmpty;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Icon(Icons.print, size: 48),
        const SizedBox(height: 12),
        Text(
          'Printer POS',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        const Text(
          'Daftar printer mengikuti pengaturan printer di server finance. Hubungan Bluetooth, nama perangkat, dan lebar kertas disimpan lokal di APK.',
        ),
        const SizedBox(height: 18),
        OutlinedButton.icon(
          onPressed:
              ready
                  ? () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder:
                            (_) => PrinterSettingsScreen(
                              settings: _draftSettings(),
                            ),
                      ),
                    );
                  }
                  : null,
          icon: const Icon(Icons.manage_accounts),
          label: const Text('Kelola printer server & Bluetooth'),
        ),
        if (!ready) ...[
          const SizedBox(height: 12),
          const Text(
            'Simpan pengaturan, login kembali, lalu buka tab ini untuk mengelola printer.',
          ),
        ],
      ],
    );
  }

  Widget _deviceTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        TextField(
          controller: _terminalKey,
          decoration: const InputDecoration(
            labelText: 'Device key terminal',
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
          title: const Text('Sinkronisasi background'),
          subtitle: const Text(
            'WorkManager mencoba sinkron otomatis minimal setiap 15 menit saat jaringan tersedia.',
          ),
        ),
      ],
    );
  }

  AppSettings _draftSettings() {
    return AppSettings(
      backendUrl: _backendUrl.text.trim(),
      terminalDeviceKey: _terminalKey.text.trim(),
      profileId: widget.initialSettings.profileId,
      serverScope: widget.initialSettings.serverScope,
      mobileApiKey: _mobileApiKey.text.trim(),
      authToken: widget.initialSettings.authToken,
      username: widget.initialSettings.username,
      authExpiresAt: widget.initialSettings.authExpiresAt,
      outletId: int.tryParse(_outletId.text.trim()) ?? 0,
      terminalId: int.tryParse(_terminalId.text.trim()) ?? 0,
      backgroundSyncEnabled: _backgroundSync,
      printerName: widget.initialSettings.printerName,
      printerAddress: widget.initialSettings.printerAddress,
      printerPaperWidth: widget.initialSettings.printerPaperWidth,
      printerRoutes: widget.initialSettings.printerRoutes,
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
