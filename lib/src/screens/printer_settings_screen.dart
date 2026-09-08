import 'package:flutter/material.dart';

import '../models.dart';
import '../services/finance_api_client.dart';
import '../services/local_database.dart';
import '../services/pos_print_dispatcher.dart';
import '../services/printer_service.dart';
import '../services/settings_store.dart';

class PrinterSettingsScreen extends StatefulWidget {
  const PrinterSettingsScreen({
    super.key,
    required this.settings,
    this.settingsStore,
    this.onAuthExpired,
    this.embedded = false,
  });

  final AppSettings settings;
  final SettingsStore? settingsStore;
  final VoidCallback? onAuthExpired;
  final bool embedded;

  @override
  State<PrinterSettingsScreen> createState() => _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends State<PrinterSettingsScreen> {
  final LocalDatabase _db = LocalDatabase.instance;
  final PrinterService _printer = PrinterService();
  final PosPrintDispatcher _printDispatcher = PosPrintDispatcher();
  late final FinanceApiClient _api;
  List<Map<String, Object?>> _serverPrinters = const [];
  List<Map<String, Object?>> _localPrinters = const [];
  Map<String, Object?> _serverGeneral = const {};
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
        _error = cachedRows.isEmpty ? _friendlyLoadError(error) : null;
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
    try {
      await _db.saveLocalPrinter({
        'server_printer_id': serverId,
        'server_name': serverRow['device_name']?.toString() ?? 'Printer',
        'printer_role': serverRow['printer_role']?.toString() ?? 'CUSTOM',
        'print_scope': serverRow['print_scope']?.toString() ?? 'ALL',
        'bluetooth_name': result['bluetooth_name']?.toString() ?? '',
        'bluetooth_address': result['bluetooth_address']?.toString() ?? '',
        // The physical Bluetooth printer belongs to this APK/device. Do not
        // import its paper and character settings from the Finance server.
        'paper_width': _asInt(result['paper_width']) == 80 ? 80 : 58,
        'chars_per_line': _asInt(result['chars_per_line']),
        'is_active': 1,
      });
      _showMessage(
        'Printer berhasil dihubungkan. Ukuran kertas dan karakter/baris tersimpan di APK ini.',
      );
      await _load();
    } catch (error) {
      _showMessage(
        'Koneksi printer gagal disimpan: ${_friendlyPrinterError(error)}',
      );
    }
  }

  Future<void> _addPrinter() async {
    final selected = await showDialog<Map<String, Object?>>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Hubungkan printer'),
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
      final localPaperWidth = _asInt(local?['paper_width']) == 80 ? 80 : 58;
      final localChars = _asInt(local?['chars_per_line']) > 0
          ? _asInt(local?['chars_per_line'])
          : (localPaperWidth == 58 ? 32 : 48);
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
                        'Template: ${template['division_filter'] ?? 'ALL'} | Cetak APK: $localPaperWidth mm, $localChars karakter/baris',
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
      final result = await _printDispatcher.printTargets([
        {
          ...package,
          'printer_id': serverId,
          'printer_name': serverRow['device_name']?.toString() ?? 'Printer',
          'printer_role': serverRow['printer_role']?.toString() ?? 'CUSTOM',
        },
      ]);
      if (result.printed <= 0) {
        throw StateError(result.message);
      }
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
    final content = _content();
    if (widget.embedded) return content;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Printer POS'),
        actions: [
          IconButton(
            tooltip: 'Muat ulang daftar printer',
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
                label: const Text('Hubungkan printer'),
              ),
      body: content,
    );
  }

  Widget _content() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    if (_serverPrinters.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 120),
            Center(child: Text('Belum ada printer yang dapat digunakan.')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Printer',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                tooltip: 'Muat ulang daftar printer',
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          if (_serverGeneral['title']?.toString().trim().isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _serverGeneral['title'].toString(),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ..._serverPrinters.map(_printerTile),
        ],
      ),
    );
  }

  String _friendlyLoadError(Object error) {
    if (error is FinanceApiException) return error.userMessage;
    return 'Daftar printer belum dapat dimuat. Periksa koneksi lalu coba lagi.';
  }

  Widget _printerTile(Map<String, Object?> serverRow) {
    final serverId = _asInt(serverRow['id']);
    final local = _localFor(serverId);
    final connected =
        local != null &&
        (local['bluetooth_address']?.toString().trim().isNotEmpty ?? false);
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
          '${serverRow['printer_role'] ?? 'CUSTOM'} | ${serverRow['template_document_type'] ?? 'Jenis cetak'}\n${connected ? '${local['bluetooth_name']} | ${local['bluetooth_address']}' : 'Belum terhubung ke Bluetooth'}',
        ),
        isThreeLine: false,
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
  late final TextEditingController _charsPerLine;
  int _paperWidth = 58;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(
      text: widget.existing?['bluetooth_name']?.toString() ?? '',
    );
    _address = TextEditingController(
      text: widget.existing?['bluetooth_address']?.toString() ?? '',
    );
    _paperWidth = _asInt(widget.existing?['paper_width']) == 80 ? 80 : 58;
    final savedChars = _asInt(widget.existing?['chars_per_line']);
    _charsPerLine = TextEditingController(
      text: '${savedChars > 0 ? savedChars : (_paperWidth == 58 ? 32 : 48)}',
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _charsPerLine.dispose();
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
                ),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<int>(
                value: _paperWidth,
                decoration: const InputDecoration(
                  labelText: 'Ukuran kertas di APK',
                  prefixIcon: Icon(Icons.receipt_long_outlined),
                ),
                items: const [
                  DropdownMenuItem(value: 58, child: Text('58 mm')),
                  DropdownMenuItem(value: 80, child: Text('80 mm')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _paperWidth = value;
                    _charsPerLine.text = value == 58 ? '32' : '48';
                  });
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _charsPerLine,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Jumlah karakter per baris',
                  hintText: _paperWidth == 58 ? 'Contoh: 32' : 'Contoh: 48',
                  helperText: 'Disimpan di APK ini; tidak mengikuti database Finance.',
                  prefixIcon: const Icon(Icons.format_size),
                ),
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
            final chars = int.tryParse(_charsPerLine.text.trim()) ?? 0;
            final min = _paperWidth == 58 ? 24 : 32;
            final max = _paperWidth == 58 ? 48 : 64;
            if (chars < min || chars > max) {
              _message('Jumlah karakter untuk ${_paperWidth} mm harus antara $min–$max.');
              return;
            }
            Navigator.pop(context, {
              'bluetooth_name': _name.text.trim(),
              'bluetooth_address': _address.text.trim(),
              'paper_width': _paperWidth,
              'chars_per_line': chars,
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
