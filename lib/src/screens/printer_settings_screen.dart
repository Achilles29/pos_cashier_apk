import 'package:flutter/material.dart';

import '../models.dart';
import '../services/finance_api_client.dart';
import '../services/local_database.dart';
import '../services/printer_service.dart';
import '../services/settings_store.dart';

class PrinterSettingsScreen extends StatefulWidget {
  const PrinterSettingsScreen({
    super.key,
    required this.settings,
    this.settingsStore,
    this.onAuthExpired,
  });

  final AppSettings settings;
  final SettingsStore? settingsStore;
  final VoidCallback? onAuthExpired;

  @override
  State<PrinterSettingsScreen> createState() => _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends State<PrinterSettingsScreen> {
  final LocalDatabase _db = LocalDatabase.instance;
  final PrinterService _printer = PrinterService();
  late final FinanceApiClient _api;
  List<Map<String, Object?>> _serverPrinters = const [];
  List<Map<String, Object?>> _localPrinters = const [];
  Map<String, Object?> _serverGeneral = const {};
  String _serverConfigSource = '';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _api = FinanceApiClient(settings: widget.settings);
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final response = await _api.printers();
      final locals = await _db.localPrinters();
      final serverRows =
          (response['rows'] as List?)
              ?.whereType<Map>()
              .map((row) => Map<String, Object?>.from(row))
              .toList() ??
          const <Map<String, Object?>>[];
      await _db.saveMasterCache('printer_catalog', {'rows': serverRows});
      if (!mounted) return;
      setState(() {
        _serverPrinters = serverRows;
        _localPrinters = locals;
        _serverGeneral =
            (response['general'] as Map?)?.cast<String, Object?>() ?? const {};
        _serverConfigSource = response['config_source']?.toString() ?? '';
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      if (error is FinanceApiException && error.isUnauthorized) {
        if (widget.settingsStore != null) {
          await widget.settingsStore!.save(
            widget.settings.copyWith(authToken: '', authExpiresAt: ''),
          );
        }
        setState(() {
          _loading = false;
          _error = 'Sesi login kedaluwarsa. Silakan login kembali.';
        });
        widget.onAuthExpired?.call();
        return;
      }
      final cached = await _db.readMasterCache('printer_catalog');
      final cachedRows =
          (cached?['rows'] as List?)
              ?.whereType<Map>()
              .map((row) => Map<String, Object?>.from(row))
              .toList() ??
          const <Map<String, Object?>>[];
      setState(() {
        _loading = false;
        _serverPrinters = cachedRows;
        _error = cachedRows.isEmpty ? '$error' : null;
      });
      if (cachedRows.isNotEmpty) {
        _localPrinters = await _db.localPrinters();
        if (mounted) setState(() {});
      }
    }
  }

  Map<String, Object?>? _localFor(int serverId) {
    for (final row in _localPrinters) {
      if (_asInt(row['server_printer_id']) == serverId) return row;
    }
    return null;
  }

  Future<void> _editPrinter(Map<String, Object?> serverRow) async {
    final serverId = _asInt(serverRow['id']);
    if (serverId <= 0) return;
    final existing = _localFor(serverId);
    final result = await showDialog<Map<String, Object?>>(
      context: context,
      builder:
          (_) => _PrinterBindingDialog(
            serverRow: serverRow,
            existing: existing,
            printerService: _printer,
          ),
    );
    if (result == null) return;
    await _db.saveLocalPrinter({
      'server_printer_id': serverId,
      'server_name': serverRow['device_name']?.toString() ?? 'Printer',
      'printer_role': serverRow['printer_role']?.toString() ?? 'CUSTOM',
      'print_scope': serverRow['print_scope']?.toString() ?? 'ALL',
      'bluetooth_name': result['bluetooth_name']?.toString() ?? '',
      'bluetooth_address': result['bluetooth_address']?.toString() ?? '',
      // Paper/layout/copy/cut rules remain server-owned. This field is only
      // retained for local schema compatibility and is never edited here.
      'paper_width': _asInt(serverRow['paper_width_mm']) == 80 ? 80 : 58,
      'is_active': 1,
    });
    _showMessage('Binding printer berhasil disimpan di database lokal APK.');
    await _load();
  }

  Future<void> _addPrinter() async {
    final selected = await showDialog<Map<String, Object?>>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Pilih printer server'),
            content: SizedBox(
              width: 520,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _serverPrinters.length,
                itemBuilder: (_, index) {
                  final row = _serverPrinters[index];
                  final connected = _localFor(_asInt(row['id'])) != null;
                  return ListTile(
                    leading: Icon(connected ? Icons.check_circle : Icons.print),
                    title: Text(
                      row['device_name']?.toString() ??
                          row['device_code']?.toString() ??
                          'Printer',
                    ),
                    subtitle: Text(
                      '${row['printer_role'] ?? 'CUSTOM'} | ${connected ? 'sudah terhubung' : 'belum terhubung'}',
                    ),
                    onTap: () => Navigator.pop(dialogContext, row),
                  );
                },
              ),
            ),
          ),
    );
    if (selected != null) await _editPrinter(selected);
  }

  Future<void> _deletePrinter(Map<String, Object?> serverRow) async {
    final serverId = _asInt(serverRow['id']);
    final local = _localFor(serverId);
    if (local == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Hapus koneksi printer?'),
            content: Text(
              '${local['bluetooth_name']} tidak akan dihapus dari Bluetooth Android, hanya binding lokal POS.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Batal'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Hapus'),
              ),
            ],
          ),
    );
    if (ok != true) return;
    await _db.deleteLocalPrinter(serverId);
    await _load();
  }

  Future<void> _testPrint(Map<String, Object?> serverRow) async {
    final serverId = _asInt(serverRow['id']);
    final local = _localFor(serverId);
    final address = local?['bluetooth_address']?.toString().trim() ?? '';
    if (address.isEmpty) {
      _showMessage('Hubungkan printer Bluetooth terlebih dulu.');
      return;
    }

    try {
      final response = await _api.printerTest(serverId);
      final package =
          (response['print_payload'] as Map?)?.cast<String, Object?>() ??
          const {};
      final text = package['text']?.toString() ?? '';
      if (text.trim().isEmpty) {
        _showMessage('Preview test print dari server masih kosong.');
        return;
      }
      if (!mounted) return;
      final template =
          (response['template'] as Map?)?.cast<String, Object?>() ?? const {};
      final previewLines =
          ((response['preview'] as Map?)?['lines'] as List?)
              ?.map((line) => line.toString())
              .join('\n') ??
          text;
      final confirmed = await showDialog<bool>(
        context: context,
        builder:
            (dialogContext) => AlertDialog(
              title: const Text('Preview test print'),
              content: SizedBox(
                width: 420,
                height: 420,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${template['template_name'] ?? 'Default Finance'} | ${template['document_type'] ?? 'RECEIPT'}',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        'Divisi: ${template['division_filter'] ?? 'ALL'} | ${template['chars_per_line'] ?? '-'} karakter/baris',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const Divider(height: 24),
                      SelectableText(previewLines),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Batal'),
                ),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  icon: const Icon(Icons.print),
                  label: const Text('Cetak test'),
                ),
              ],
            ),
      );
      if (confirmed != true) return;
      await _printer.printText(
        address: address,
        text: text,
        copies: _asInt(package['copies']) <= 0 ? 1 : _asInt(package['copies']),
        cutMode: package['cut_mode']?.toString() ?? 'PARTIAL',
        openDrawer: _asInt(package['open_drawer']) == 1,
      );
      _showMessage('Test print berhasil dikirim ke printer.');
    } catch (error) {
      _showMessage('Test print gagal: ${_friendlyPrinterError(error)}');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Printer POS'),
        actions: [
          IconButton(
            tooltip: 'Muat ulang daftar server',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      floatingActionButton:
          _serverPrinters.isEmpty
              ? null
              : FloatingActionButton.extended(
                onPressed: _addPrinter,
                icon: const Icon(Icons.add),
                label: const Text('Tambah koneksi'),
              ),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_error!, textAlign: TextAlign.center),
                ),
              )
              : _serverPrinters.isEmpty
              ? const Center(
                child: Text('Belum ada printer aktif dari server finance.'),
              )
              : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
                  children: [
                    const Text(
                      'Daftar printer server',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Daftar ini mengikuti database finance. Nama dan alamat Bluetooth di bawahnya disimpan lokal di APK.',
                    ),
                    if (_serverConfigSource.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.cloud_done_outlined),
                          title: Text(
                            _serverGeneral['title']
                                        ?.toString()
                                        .trim()
                                        .isNotEmpty ==
                                    true
                                ? _serverGeneral['title'].toString()
                                : 'Pengaturan umum dari Finance',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          subtitle: Text(
                            'Layout, footer, branding, divisi, copy, potong kertas, dan aturan event dibaca dari server.\n$_serverConfigSource',
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    ..._serverPrinters.map(_printerTile),
                  ],
                ),
              ),
    );
  }

  Widget _printerTile(Map<String, Object?> serverRow) {
    final serverId = _asInt(serverRow['id']);
    final local = _localFor(serverId);
    final connected =
        local != null &&
        (local['bluetooth_address']?.toString().trim().isNotEmpty ?? false);
    final routes = (serverRow['server_routes'] as List?) ?? const [];
    final routeSummary = routes
        .whereType<Map>()
        .map(
          (route) =>
              '${route['event_code'] ?? '-'}: ${route['layout_name'] ?? '-'}',
        )
        .take(3)
        .join('\n');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: Icon(
          connected ? Icons.print : Icons.print_disabled,
          color: connected ? Colors.green : Colors.grey,
        ),
        title: Text(
          serverRow['device_name']?.toString() ??
              serverRow['device_code']?.toString() ??
              'Printer #$serverId',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          '${serverRow['printer_role'] ?? 'CUSTOM'} | ${serverRow['template_document_type'] ?? 'Aturan server'}\n${connected ? '${local['bluetooth_name']} | ${local['bluetooth_address']}' : 'Belum terhubung ke Bluetooth lokal'}${routeSummary.isEmpty ? '' : '\n$routeSummary'}',
        ),
        isThreeLine: true,
        trailing: Wrap(
          spacing: 0,
          children: [
            IconButton(
              tooltip: connected ? 'Ubah koneksi' : 'Hubungkan',
              onPressed: () => _editPrinter(serverRow),
              icon: Icon(connected ? Icons.edit : Icons.bluetooth_searching),
            ),
            if (connected)
              OutlinedButton.icon(
                onPressed: () => _testPrint(serverRow),
                icon: const Icon(Icons.print_outlined, size: 18),
                label: const Text('Test print'),
              ),
            if (connected)
              IconButton(
                tooltip: 'Hapus koneksi lokal',
                onPressed: () => _deletePrinter(serverRow),
                icon: const Icon(Icons.delete_outline),
              ),
          ],
        ),
      ),
    );
  }
}

class _PrinterBindingDialog extends StatefulWidget {
  const _PrinterBindingDialog({
    required this.serverRow,
    required this.existing,
    required this.printerService,
  });

  final Map<String, Object?> serverRow;
  final Map<String, Object?>? existing;
  final PrinterService printerService;

  @override
  State<_PrinterBindingDialog> createState() => _PrinterBindingDialogState();
}

class _PrinterBindingDialogState extends State<_PrinterBindingDialog> {
  late final TextEditingController _name;
  late final TextEditingController _address;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(
      text: widget.existing?['bluetooth_name']?.toString() ?? '',
    );
    _address = TextEditingController(
      text: widget.existing?['bluetooth_address']?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _choose() async {
    try {
      final devices = await widget.printerService.bondedDevices();
      if (!mounted) return;
      if (devices.isEmpty) {
        _message(
          'Pasangkan printer melalui pengaturan Bluetooth Android terlebih dulu.',
        );
        return;
      }
      final selected = await showDialog<BluetoothPrinter>(
        context: context,
        builder:
            (dialogContext) => AlertDialog(
              title: const Text('Pilih printer Bluetooth'),
              content: SizedBox(
                width: 440,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: devices.length,
                  itemBuilder:
                      (_, index) => ListTile(
                        leading: const Icon(Icons.bluetooth),
                        title: Text(devices[index].name),
                        subtitle: Text(devices[index].address),
                        onTap:
                            () => Navigator.pop(dialogContext, devices[index]),
                      ),
                ),
              ),
            ),
      );
      if (selected == null || !mounted) return;
      setState(() {
        _name.text = selected.name;
        _address.text = selected.address;
      });
    } catch (error) {
      _message('Bluetooth belum siap: $error');
    }
  }

  void _message(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Hubungkan ${widget.serverRow['device_name'] ?? 'printer'}'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.serverRow['printer_role'] ?? 'CUSTOM'} | ${widget.serverRow['print_scope'] ?? 'ALL'}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Nama Bluetooth lokal',
                  prefixIcon: Icon(Icons.print),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _address,
                      decoration: const InputDecoration(
                        labelText: 'Alamat Bluetooth',
                        hintText: '00:11:22:33:44:55',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.outlined(
                    tooltip: 'Pilih perangkat terpasang',
                    onPressed: _choose,
                    icon: const Icon(Icons.bluetooth_searching),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton.icon(
          onPressed: () {
            if (_address.text.trim().isEmpty) {
              _message('Alamat Bluetooth wajib diisi.');
              return;
            }
            Navigator.pop(context, {
              'bluetooth_name': _name.text.trim(),
              'bluetooth_address': _address.text.trim(),
            });
          },
          icon: const Icon(Icons.save),
          label: const Text('Simpan'),
        ),
      ],
    );
  }
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

String _friendlyPrinterError(Object error) {
  if (error is FinanceApiException) return error.userMessage;
  if (error.toString().contains('BLUETOOTH_PERMISSION')) {
    return 'Izin Bluetooth belum diberikan pada tablet.';
  }
  if (error.toString().contains('PRINTER_IO')) {
    return 'Printer tidak merespons. Pastikan sudah dipair dan menyala.';
  }
  return 'Periksa koneksi printer dan coba lagi.';
}
