import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../services/finance_api_client.dart';
import '../services/local_database.dart';
import '../services/pos_print_dispatcher.dart';
import '../widgets/sensitive_action_proof_dialog.dart';

class OrderWorkspaceScreen extends StatefulWidget {
  const OrderWorkspaceScreen({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<OrderWorkspaceScreen> createState() => _OrderWorkspaceScreenState();
}

class _OrderWorkspaceScreenState extends State<OrderWorkspaceScreen>
    with SingleTickerProviderStateMixin {
  late final FinanceApiClient _api;
  final PosPrintDispatcher _printDispatcher = PosPrintDispatcher();
  final LocalDatabase _db = LocalDatabase.instance;
  final NumberFormat _money = NumberFormat.currency(
    locale: 'id_ID',
    symbol: 'Rp ',
    decimalDigits: 0,
  );
  late final TabController _tabs;
  List<Map<String, Object?>> _active = const [];
  List<Map<String, Object?>> _paid = const [];
  List<PaymentMethod> _refundMethods = const [];
  bool _loading = true;
  String? _error;
  String? _warning;

  @override
  void initState() {
    super.initState();
    _api = FinanceApiClient(settings: widget.settings);
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging) return;
      _loadOrders();
    });
    _loadOrders();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadOrders() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _warning = null;
      });
    }
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    Map<String, Object?>? activeResponse;
    Map<String, Object?>? paidResponse;
    Object? remoteError;
    try {
      activeResponse = await _api.orders(
        status: 'ACTIVE',
        page: 1,
        dateFrom: today,
        dateTo: today,
      );
      paidResponse = await _api.orders(
        status: 'PAID',
        page: 1,
        dateFrom: today,
        dateTo: today,
      );
    } catch (error) {
      remoteError = error;
    }

    final localRows = await _localWorkspaceRows();
    final methods = await _loadRefundMethods();
    final activeServerRows =
        _rows(activeResponse).where((row) => !_isPaidRow(row)).toList();
    final paidServerRows = _rows(paidResponse).where(_isPaidRow).toList();
    final paidServerIds = {
      for (final row in paidServerRows)
        if (_asInt(row['id']) > 0) _asInt(row['id']),
    };
    final active = _mergeRows(
      activeServerRows,
      localRows,
      paid: false,
      excludeServerIds: paidServerIds,
    );
    final paid = _mergeRows(paidServerRows, localRows, paid: true);
    if (!mounted) return;
    setState(() {
      _active = active;
      _paid = paid;
      _refundMethods = methods;
      _loading = false;
      if (remoteError != null && active.isEmpty && paid.isEmpty) {
        _error = _workspaceError(remoteError);
      } else if (remoteError != null) {
        _warning = 'Server belum tersambung. Order lokal tetap ditampilkan.';
      }
    });
  }

  Future<List<PaymentMethod>> _loadRefundMethods() async {
    try {
      final bootstrap = await _api.bootstrap();
      final rows = (bootstrap['payment_methods'] as List?) ?? const [];
      return rows
          .whereType<Map>()
          .map((row) => PaymentMethod.fromJson(Map<String, Object?>.from(row)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  List<Map<String, Object?>> _rows(Map<String, Object?>? response) {
    if (response == null) return const [];
    return (response['rows'] as List?)
            ?.whereType<Map>()
            .map((row) => Map<String, Object?>.from(row))
            .toList() ??
        const [];
  }

  Future<List<Map<String, Object?>>> _localWorkspaceRows() async {
    final rows = await _db.localWorkspaceOrders();
    final result = <Map<String, Object?>>[];
    for (final row in rows) {
      final payload = _decodePayload(row['payload']?.toString());
      final localUuid = row['local_uuid']?.toString() ?? '';
      if (localUuid.isEmpty) continue;
      final confirmOrder = payload['confirm_order'] == true;
      final syncStatus = row['sync_status']?.toString() ?? 'PENDING';
      final status = row['status']?.toString() ?? 'LOCAL_DRAFT';
      final serverId = _asInt(row['server_id']);
      final customer =
          payload['member_name']?.toString().trim().isNotEmpty == true
              ? payload['member_name']!.toString()
              : payload['customer_name']?.toString() ?? 'Walk in';
      result.add({
        'id': serverId,
        'local_uuid': localUuid,
        'local_payload': payload,
        'local_only': serverId <= 0,
        'sync_status': syncStatus,
        'order_no':
            row['order_no']?.toString() ??
            'LOKAL-${localUuid.replaceFirst('ORD-', '').substring(0, 8)}',
        'status':
            status == 'LOCAL_DRAFT'
                ? (confirmOrder ? 'CONFIRMED' : 'DRAFT')
                : status,
        'customer_display_name': customer,
        'customer_name': payload['customer_name'],
        'outlet_name': 'Perangkat ini',
        'service_type': payload['service_type'] ?? 'DINE_IN',
        'grand_total': payload['grand_total'] ?? payload['subtotal'] ?? 0,
        'stock_commit_status':
            payload['stock_commit_status'] ??
            (serverId > 0 ? 'SERVER' : 'PENDING'),
        'ordered_at': payload['ordered_at'] ?? row['created_at'],
      });
    }
    return result;
  }

  Map<String, Object?> _decodePayload(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? Map<String, Object?>.from(decoded)
          : const <String, Object?>{};
    } catch (_) {
      return const {};
    }
  }

  bool _isPaidRow(Map<String, Object?> row) {
    final status = row['status']?.toString().toUpperCase().trim() ?? '';
    final paymentStatus =
        row['payment_status']?.toString().toUpperCase().trim() ?? '';
    if ([
      'PAID',
      'SETTLED',
      'FULLY_PAID',
      'REFUND_PARTIAL',
      'REFUND_FULL',
      'REFUNDED_FULL',
    ].contains(paymentStatus)) {
      return true;
    }
    return [
      'PAID',
      'READY',
      'SERVED',
      'REFUND_PARTIAL',
      'REFUND_FULL',
      'REFUNDED_FULL',
    ].contains(status);
  }

  List<Map<String, Object?>> _mergeRows(
    List<Map<String, Object?>> serverRows,
    List<Map<String, Object?>> localRows, {
    required bool paid,
    Set<int> excludeServerIds = const {},
  }) {
    final serverIds = {
      for (final row in serverRows)
        if (_asInt(row['id']) > 0) _asInt(row['id']),
    };
    final merged = [...serverRows];
    for (final row in localRows) {
      final status = row['status']?.toString().toUpperCase() ?? '';
      final isPaid = [
        'PAID',
        'PAID_PARTIAL',
        'READY',
        'SERVED',
        'REFUND_PARTIAL',
        'REFUND_FULL',
        'REFUNDED_FULL',
      ].contains(status);
      if (isPaid != paid) continue;
      final serverId = _asInt(row['id']);
      if (serverId > 0 && excludeServerIds.contains(serverId)) continue;
      if (serverId > 0 && serverIds.contains(serverId)) continue;
      merged.add(row);
    }
    merged.sort((a, b) {
      final aDate = DateTime.tryParse(a['ordered_at']?.toString() ?? '');
      final bDate = DateTime.tryParse(b['ordered_at']?.toString() ?? '');
      return (bDate ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(
        aDate ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
    });
    return merged;
  }

  Future<void> _openAction(
    Map<String, Object?> row, {
    required bool paid,
  }) async {
    final id = _asInt(row['id']);
    if (id <= 0) {
      _showMessage(
        row['sync_status'] == 'BLOCKED'
            ? 'Order lokal ditahan karena validasi server. Buka kasir atau perbaiki data, lalu sinkronkan lagi.'
            : 'Order masih tersimpan di perangkat dan menunggu server online.',
      );
      return;
    }
    if (paid) {
      await _refund(id, row);
    } else {
      final status = row['status']?.toString().toUpperCase() ?? '';
      if (status == 'DRAFT' || status == 'PENDING') {
        _showMessage(
          'Draft belum memakai stok. Buka dari keranjang untuk mengubahnya.',
        );
        return;
      }
      await _void(id, row);
    }
  }

  Future<void> _reprint(Map<String, Object?> row) async {
    final orderId = _asInt(row['id']);
    if (orderId <= 0) {
      _showMessage(
        'Order lokal belum memiliki nomor server untuk dicetak ulang.',
      );
      return;
    }
    final options = await _reprintOptions();
    if (options == null) return;
    final proof = await _orderStepUpProof(
      orderId: orderId,
      action: 'ORDER_REPRINT',
      title: 'Verifikasi cetak ulang',
      description:
          'Konfirmasi identitas Anda sebelum mengirim ulang tiket order ke printer.',
      confirmLabel: 'Verifikasi & cetak',
    );
    if (proof == null) return;
    try {
      final response = await _api.orderReprintTargets(
        orderId,
        lineScope: options['line_scope']?.toString() ?? 'LATEST',
        printerId: _asInt(options['printer_id']),
        stepUpProof: proof,
      );
      final targets = (response['direct_print_targets'] as List?) ?? const [];
      final result = await _printDispatcher.printTargets(
        targets.whereType<Map>(),
      );
      await _showPrintOutcome(result, title: 'Cetak ulang order');
    } catch (error) {
      await _showPrintFailure(
        title: 'Cetak ulang belum berhasil',
        message: _workspaceError(error),
      );
    }
  }

  Future<Map<String, Object?>?> _reprintOptions() async {
    List<Map<String, Object?>> printers = const [];
    List<Map<String, Object?>> localPrinters = const [];
    try {
      final bootstrap = await _api.bootstrap();
      final cashierBootstrap = bootstrap['cashier_bootstrap'];
      final rawOptions =
          cashierBootstrap is Map
              ? cashierBootstrap['order_reprint_printers']
              : null;
      printers =
          rawOptions is List
              ? rawOptions
                  .whereType<Map>()
                  .map((row) => Map<String, Object?>.from(row))
                  .toList()
              : const [];
      // Keep compatibility with a Finance2 deployment before the printer
      // options were added to cashier bootstrap.
      if (printers.isEmpty) {
        final response = await _api.printers();
        printers =
            (response['rows'] as List?)
                ?.whereType<Map>()
                .map((row) => Map<String, Object?>.from(row))
                .toList() ??
            const [];
      }
      localPrinters = await _db.localPrinters();
    } catch (error) {
      if (mounted) {
        await _showPrintFailure(
          title: 'Daftar printer belum tersedia',
          message: _workspaceError(error),
        );
      }
      return null;
    }
    if (!mounted) return null;
    var selectedPrinterId = 0;
    for (final printer in printers) {
      if (printer['print_mode']?.toString().toUpperCase() == 'PRE_BILL') {
        selectedPrinterId = _asInt(printer['id']);
        break;
      }
    }
    var lineScope = 'LATEST';
    return showDialog<Map<String, Object?>>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (dialogContext, setDialogState) => AlertDialog(
                  icon: const Icon(Icons.print_outlined),
                  title: const Text('Atur cetak ulang'),
                  content: SizedBox(
                    width: 540,
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Pilih sumber item dan printer tujuan. Layout tetap mengikuti pengaturan Finance.',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Item yang dicetak',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                          RadioListTile<String>(
                            contentPadding: EdgeInsets.zero,
                            value: 'LATEST',
                            groupValue: lineScope,
                            title: const Text('Order baru saja'),
                            subtitle: const Text(
                              'Hanya item pada snapshot penambahan/konfirmasi terakhir.',
                            ),
                            onChanged:
                                (value) => setDialogState(
                                  () => lineScope = value ?? 'LATEST',
                                ),
                          ),
                          RadioListTile<String>(
                            contentPadding: EdgeInsets.zero,
                            value: 'ALL',
                            groupValue: lineScope,
                            title: const Text('Semua item'),
                            subtitle: const Text(
                              'Cetak ulang seluruh item order.',
                            ),
                            onChanged:
                                (value) => setDialogState(
                                  () => lineScope = value ?? 'ALL',
                                ),
                          ),
                          const Divider(height: 18),
                          const Text(
                            'Printer tujuan',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                          RadioListTile<int>(
                            contentPadding: EdgeInsets.zero,
                            value: 0,
                            groupValue: selectedPrinterId,
                            title: const Text(
                              'Semua printer sesuai aturan Finance',
                            ),
                            onChanged:
                                (value) => setDialogState(
                                  () => selectedPrinterId = value ?? 0,
                                ),
                          ),
                          if (printers.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                'Belum ada printer aktif dari Finance.',
                              ),
                            ),
                          for (final printer in printers)
                            RadioListTile<int>(
                              contentPadding: EdgeInsets.zero,
                              value: _asInt(printer['id']),
                              groupValue: selectedPrinterId,
                              title: Text(
                                printer['label']?.toString() ??
                                    printer['device_name']?.toString() ??
                                    printer['printer_name']?.toString() ??
                                    printer['device_code']?.toString() ??
                                    'Printer',
                              ),
                              subtitle: Text(
                                '${printer['print_mode']?.toString() == 'PRE_BILL' ? 'BILL' : printer['printer_role'] ?? 'CUSTOM'} | ${localPrinters.any((local) => _asInt(local['server_printer_id']) == _asInt(printer['id'])) ? 'Bluetooth terhubung' : 'Bluetooth belum dihubungkan'}',
                              ),
                              onChanged:
                                  (value) => setDialogState(
                                    () => selectedPrinterId = value ?? 0,
                                  ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Batal'),
                    ),
                    FilledButton.icon(
                      onPressed:
                          () => Navigator.pop(dialogContext, {
                            'printer_id': selectedPrinterId,
                            'line_scope': lineScope,
                          }),
                      icon: const Icon(Icons.print),
                      label: const Text('Cetak'),
                    ),
                  ],
                ),
          ),
    );
  }

  Future<void> _showPrintOutcome(
    PrintDispatchResult result, {
    required String title,
  }) async {
    if (!mounted) return;
    final problem = result.hasProblem || result.printed == 0;
    await showDialog<void>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            icon: Icon(
              problem
                  ? Icons.warning_amber_rounded
                  : Icons.check_circle_outline,
              color: problem ? Colors.orange.shade800 : Colors.green.shade700,
              size: 34,
            ),
            title: Text(problem ? '$title perlu perhatian' : '$title berhasil'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(result.message),
                if (result.missing.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  const Text(
                    'Tindakan: buka Pengaturan > Printer lalu hubungkan printer Bluetooth yang sesuai.',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Mengerti'),
              ),
            ],
          ),
    );
  }

  Future<void> _showPrintFailure({
    required String title,
    required String message,
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            icon: Icon(
              Icons.print_disabled_outlined,
              color: Colors.orange.shade800,
              size: 34,
            ),
            title: Text(title),
            content: Text('$message\n\nData transaksi tetap tersimpan.'),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Mengerti'),
              ),
            ],
          ),
    );
  }

  Future<void> _openDetail(Map<String, Object?> row) async {
    final orderId = _asInt(row['id']);
    if (orderId <= 0) {
      final payload =
          row['local_payload'] is Map
              ? Map<String, Object?>.from(row['local_payload'] as Map)
              : const <String, Object?>{};
      await _showLocalDetail(row, payload);
      return;
    }
    try {
      final response = await _api.orderLoad(orderId);
      final header =
          (response['header'] as Map?)?.cast<String, Object?>() ?? const {};
      final lines = (response['lines'] as List?) ?? const [];
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder:
            (dialogContext) => AlertDialog(
              title: Text(
                header['order_no']?.toString() ??
                    row['order_no']?.toString() ??
                    'Detail order',
              ),
              content: SizedBox(
                width: 560,
                height: 500,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _DetailBadge(
                        label: 'Status',
                        value:
                            header['status']?.toString() ??
                            row['status']?.toString() ??
                            '-',
                      ),
                      _DetailBadge(
                        label: 'Stock commit',
                        value: header['stock_commit_status']?.toString() ?? '-',
                      ),
                      _DetailBadge(
                        label: 'Customer',
                        value:
                            header['customer_display_name']?.toString() ??
                            header['customer_name']?.toString() ??
                            'Walk-in',
                      ),
                      _DetailBadge(
                        label: 'Layanan',
                        value: header['service_type']?.toString() ?? '-',
                      ),
                      const Divider(height: 24),
                      if (lines.isEmpty)
                        const Text('Belum ada baris item.')
                      else
                        ...lines.whereType<Map>().map((value) {
                          final extras = (value['extras'] as List?) ?? const [];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        value['product_name']?.toString() ??
                                            value['name']?.toString() ??
                                            'Produk',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      'x${_asDouble(value['qty']).toStringAsFixed(0)}',
                                    ),
                                    const SizedBox(width: 12),
                                    Text(
                                      _money.format(
                                        _asDouble(
                                          value['net_amount'] ??
                                              value['subtotal'],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                if (extras.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 3),
                                    child: Text(
                                      'Extra: ${extras.whereType<Map>().map((extra) => extra['extra_name']?.toString() ?? '-').join(', ')}',
                                      style:
                                          Theme.of(context).textTheme.bodySmall,
                                    ),
                                  ),
                              ],
                            ),
                          );
                        }),
                      const Divider(height: 24),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          'Grand total ${_money.format(_asDouble(header['grand_total'] ?? row['grand_total']))}',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Tutup'),
                ),
              ],
            ),
      );
    } catch (error) {
      _showMessage(
        'Detail order belum dapat dibuka: ${_workspaceError(error)}',
      );
    }
  }

  Future<void> _showLocalDetail(
    Map<String, Object?> row,
    Map<String, Object?> payload,
  ) async {
    final lines = (payload['lines'] as List?) ?? const [];
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text(row['order_no']?.toString() ?? 'Order lokal'),
            content: SizedBox(
              width: 560,
              height: 500,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DetailBadge(
                      label: 'Status',
                      value: row['status']?.toString() ?? 'LOCAL_DRAFT',
                    ),
                    _DetailBadge(
                      label: 'Sinkron',
                      value: row['sync_status']?.toString() ?? 'PENDING',
                    ),
                    _DetailBadge(
                      label: 'Stok',
                      value:
                          row['stock_commit_status']?.toString() ?? 'PENDING',
                    ),
                    _DetailBadge(
                      label: 'Customer',
                      value:
                          payload['member_name']
                                      ?.toString()
                                      .trim()
                                      .isNotEmpty ==
                                  true
                              ? payload['member_name']!.toString()
                              : payload['customer_name']?.toString() ??
                                  'Walk-in',
                    ),
                    _DetailBadge(
                      label: 'Layanan',
                      value: payload['service_type']?.toString() ?? '-',
                    ),
                    const Divider(height: 24),
                    if (lines.isEmpty)
                      const Text('Belum ada baris item.')
                    else
                      ...lines.whereType<Map>().map((value) {
                        final extras = (value['extras'] as List?) ?? const [];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      value['product_name']?.toString() ??
                                          'Produk',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    'x${_asDouble(value['qty']).toStringAsFixed(0)}',
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    _money.format(
                                      _asDouble(
                                        value['line_total'] ??
                                            value['subtotal'] ??
                                            value['unit_price'],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (extras.isNotEmpty)
                                Text(
                                  'Extra: ${extras.whereType<Map>().map((extra) => extra['extra_name']?.toString() ?? '-').join(', ')}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              if ((value['notes']?.toString() ?? '')
                                  .trim()
                                  .isNotEmpty)
                                Text(
                                  'Catatan: ${value['notes']}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                            ],
                          ),
                        );
                      }),
                    const Divider(height: 24),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        'Grand total ${_money.format(_asDouble(payload['grand_total'] ?? payload['subtotal']))}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Tutup'),
              ),
            ],
          ),
    );
  }

  Future<void> _void(int orderId, Map<String, Object?> row) async {
    final reason = await _reasonDialog(
      'Void order ${row['order_no'] ?? orderId}',
    );
    if (reason == null || reason.trim().isEmpty) return;
    try {
      final payload = await _fullReversalPayload(orderId, reason);
      if (payload.isEmpty) return;
      final proof = await _orderStepUpProof(
        orderId: orderId,
        action: 'VOID',
        title: 'Verifikasi void order',
        description:
            'Void dapat membatalkan order dan mengubah stok. Masukkan password Anda untuk melanjutkan.',
        confirmLabel: 'Verifikasi & void',
      );
      if (proof == null) return;
      payload['step_up_proof'] = proof;
      final result = await _api.voidSave(payload);
      await _printReversal(result, isRefund: false);
      _showMessage('Void ${result['void_no'] ?? ''} berhasil disimpan.');
      await _loadOrders();
    } catch (error) {
      _showMessage('Void gagal: ${_workspaceError(error)}');
    }
  }

  Future<Map<String, Object?>?> _preparePaymentOrder(int orderId) async {
    final order = await _api.orderLoad(orderId);
    final header =
        (order['header'] as Map?)?.cast<String, Object?>() ?? const {};
    final status = header['status']?.toString().toUpperCase() ?? 'DRAFT';
    if (!['DRAFT', 'PENDING'].contains(status)) {
      return _api.paymentPrepare(orderId);
    }

    final lines = (order['lines'] as List?) ?? const [];
    if (lines.isEmpty) {
      _showMessage('Order belum memiliki item yang dapat dibayar.');
      return null;
    }
    if (!mounted) return null;
    final shouldConfirm = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Konfirmasi order sebelum payment'),
            content: Text(
              'Order ${header['order_no'] ?? orderId} masih berstatus $status. Konfirmasi order sekarang agar stok dan HPP divalidasi server, lalu lanjut payment?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Batal'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Konfirmasi & payment'),
              ),
            ],
          ),
    );
    if (shouldConfirm != true) return null;

    final payload = <String, Object?>{
      'id': orderId,
      'source': 'ANDROID_APK_PAYMENT_GATE',
      'mode': 'UPSERT_DRAFT',
      'outlet_id': _asInt(header['outlet_id']),
      'terminal_id': _asInt(header['terminal_id']),
      'service_type': header['service_type'] ?? 'DINE_IN',
      'customer_name': header['customer_name'] ?? '',
      'member_id': header['member_id'],
      'guest_count':
          _asInt(header['guest_count']) <= 0
              ? 1
              : _asInt(header['guest_count']),
      'sales_channel_id': header['sales_channel_id'],
      'table_no': header['table_no'] ?? '',
      'notes': header['notes'] ?? '',
      'confirm_order': true,
      'lines': [
        for (final raw in lines.whereType<Map>())
          {
            'order_line_id': _asInt(raw['id'] ?? raw['order_line_id']),
            'product_id': _asInt(raw['product_id']),
            'product_code': raw['product_code']?.toString() ?? '',
            'product_name': raw['product_name']?.toString() ?? '',
            'bundle_id':
                _asInt(raw['bundle_id']) > 0 ? _asInt(raw['bundle_id']) : null,
            'qty': _asDouble(raw['qty']),
            'unit_price': _asDouble(raw['unit_price']),
            'gross_amount': _asDouble(raw['gross_amount'] ?? raw['line_total']),
            'net_amount': _asDouble(raw['net_amount'] ?? raw['line_total']),
            'notes': raw['notes']?.toString() ?? '',
            'extras': [
              for (final extra
                  in (raw['extras'] as List? ?? const []).whereType<Map>())
                {
                  'extra_id': _asInt(extra['extra_id'] ?? extra['id']),
                  'extra_name': extra['extra_name']?.toString() ?? '',
                  'qty': _asDouble(extra['qty']),
                  'unit_price': _asDouble(extra['unit_price']),
                  'notes': extra['notes']?.toString() ?? '',
                },
            ],
          },
      ],
    };
    await _api.orderConfirm(payload);
    _showMessage('Order dikonfirmasi server. Menyiapkan payment...');
    return _api.paymentPrepare(orderId);
  }

  Future<void> _pay(int orderId) async {
    try {
      final response = await _preparePaymentOrder(orderId);
      if (response == null) return;
      final payment =
          (response['payment'] as Map?)?.cast<String, Object?>() ?? const {};
      if (!mounted) return;
      final result = await showDialog<Map<String, Object?>>(
        context: context,
        builder:
            (_) => _WorkspacePaymentDialog(
              payment: payment,
              onVoucherSearch: (query) async {
                final response = await _api.voucherSearch(
                  orderId: orderId,
                  query: query,
                );
                return (response['rows'] as List?)
                        ?.whereType<Map>()
                        .map((row) => Map<String, Object?>.from(row))
                        .toList() ??
                    const [];
              },
              onSubmit:
                  (payload) =>
                      _api.paymentSave({'order_id': orderId, ...payload}),
            ),
      );
      if (result == null || !mounted) return;
      final printPayload = await _api.paymentPrintTargets(_asInt(result['id']));
      final targets =
          (printPayload['direct_print_targets'] as List?) ?? const [];
      if (targets.isNotEmpty) {
        final printResult = await _printDispatcher.printTargets(
          targets.whereType<Map>(),
        );
        await _showPrintOutcome(printResult, title: 'Cetak pembayaran');
      }
      final change = _asDouble(result['change_total']);
      _showMessage(
        'Payment ${result['payment_no'] ?? ''} berhasil disimpan.'
        '${change > 0 ? ' Kembalian ${_money.format(change)}.' : ''}',
      );
      await _loadOrders();
    } catch (error) {
      _showMessage('Payment gagal: ${_workspaceError(error)}');
    }
  }

  Future<void> _refund(int orderId, Map<String, Object?> row) async {
    if (_refundMethods.isEmpty) {
      _showMessage('Metode pembayaran refund belum tersedia dari server.');
      return;
    }
    final reason = await _reasonDialog(
      'Alasan refund ${row['order_no'] ?? orderId}',
    );
    if (reason == null || reason.trim().isEmpty) return;
    try {
      final payload = await _fullReversalPayload(orderId, reason.trim());
      if (payload.isEmpty) return;
      final form = await _refundDialog(row, _refundMethods);
      if (form == null) return;
      payload['payment_method_id'] = _asInt(form['payment_method_id']);
      payload['reference_no'] = form['reference_no'];
      final proof = await _orderStepUpProof(
        orderId: orderId,
        action: 'REFUND',
        title: 'Verifikasi refund',
        description:
            'Refund mengembalikan nilai pembayaran. Masukkan password Anda untuk melanjutkan.',
        confirmLabel: 'Verifikasi & refund',
      );
      if (proof == null) return;
      payload['step_up_proof'] = proof;
      final result = await _api.refundSave(payload);
      await _printReversal(result, isRefund: true);
      _showMessage('Refund ${result['refund_no'] ?? ''} berhasil disimpan.');
      await _loadOrders();
    } catch (error) {
      _showMessage('Refund gagal: ${_workspaceError(error)}');
    }
  }

  Future<String?> _orderStepUpProof({
    required int orderId,
    required String action,
    required String title,
    required String description,
    required String confirmLabel,
  }) {
    return requestSensitiveActionProof(
      context,
      title: title,
      description: description,
      confirmLabel: confirmLabel,
      verify: (password) {
        if (action == 'ORDER_REPRINT') {
          return _api.orderReprintStepUpVerify(
            orderId: orderId,
            password: password,
          );
        }
        return _api.orderReversalStepUpVerify(
          orderId: orderId,
          action: action,
          password: password,
        );
      },
    );
  }

  Future<Map<String, Object?>> _fullReversalPayload(
    int orderId,
    String reason,
  ) async {
    final preview = await _api.reversalPreview(orderId);
    final order =
        (preview['order'] as Map?)?.cast<String, Object?>() ?? const {};
    final lines = (order['lines'] as List?) ?? const [];
    if (!mounted) return {};

    final selected = <int, bool>{};
    final quantities = <int, TextEditingController>{};
    final selectedExtras = <int, bool>{};
    final extraQuantities = <int, TextEditingController>{};
    for (final value in lines.whereType<Map>()) {
      final id = _asInt(value['id']);
      if (id <= 0) continue;
      selected[id] = true;
      quantities[id] = TextEditingController(
        text: _asDouble(value['qty']).toString(),
      );
      for (final extra
          in (value['extras'] as List? ?? const []).whereType<Map>()) {
        final extraId = _asInt(extra['id']);
        if (extraId <= 0) continue;
        selectedExtras[extraId] = false;
        extraQuantities[extraId] = TextEditingController(
          text: _asDouble(extra['qty']).toString(),
        );
      }
    }

    final selection = await showDialog<Map<String, Object?>>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder: (dialogContext, setDialogState) {
              final height = MediaQuery.sizeOf(dialogContext).height;
              void submitSelection() {
                final requested = <Map<String, Object?>>[];
                for (final value in lines.whereType<Map>()) {
                  final id = _asInt(value['id']);
                  if (id <= 0) continue;
                  final productSelected = selected[id] == true;
                  final qty = _asDouble(quantities[id]?.text);
                  final extras = <Map<String, Object?>>[];
                  for (final extra
                      in (value['extras'] as List? ?? const [])
                          .whereType<Map>()) {
                    final extraId = _asInt(extra['id']);
                    if (extraId <= 0 ||
                        productSelected ||
                        selectedExtras[extraId] != true) {
                      continue;
                    }
                    final extraQty = _asDouble(extraQuantities[extraId]?.text);
                    if (extraQty > 0) {
                      extras.add({
                        'order_line_extra_id': extraId,
                        'qty': extraQty,
                        'processed_state':
                            value['process_status']?.toString() ??
                            'NOT_PROCESSED',
                        'return_to_stock': true,
                        'notes': reason,
                      });
                    }
                  }
                  if ((productSelected && qty > 0) || extras.isNotEmpty) {
                    requested.add({
                      'order_line_id': id,
                      'qty': productSelected ? qty : 0,
                      'processed_state':
                          value['process_status']?.toString() ??
                          'NOT_PROCESSED',
                      'return_to_stock': true,
                      'notes': reason,
                      if (extras.isNotEmpty) 'extras': extras,
                    });
                  }
                }
                if (requested.isEmpty) {
                  _showMessage(
                    'Pilih minimal satu produk atau extra dengan qty valid.',
                  );
                  return;
                }
                Navigator.pop(dialogContext, {'lines': requested});
              }

              return Dialog(
                insetPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 20,
                ),
                child: SafeArea(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: 580,
                      maxHeight: height * .88,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
                          child: Row(
                            children: [
                              const Icon(Icons.tune),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Text(
                                  'Pilih item yang diproses',
                                  style: TextStyle(
                                    fontSize: 19,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              IconButton(
                                onPressed: () => Navigator.pop(dialogContext),
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Pilih produk penuh, atau buka produk untuk memilih extra satu per satu. Finance tetap menghitung nilai dan stok dari data server.',
                            ),
                          ),
                        ),
                        Flexible(
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                            children: [
                              for (final value in lines.whereType<Map>())
                                _reversalProductCard(
                                  value,
                                  selected,
                                  quantities,
                                  selectedExtras,
                                  extraQuantities,
                                  setDialogState,
                                ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
                          child: Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () => Navigator.pop(dialogContext),
                                  child: const Text('Batal'),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: FilledButton(
                                  onPressed: submitSelection,
                                  child: const Text('Lanjutkan'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
    );
    for (final controller in quantities.values) {
      controller.dispose();
    }
    if (selection == null) return {};
    return {
      'order_id': orderId,
      'reason': reason,
      'return_to_stock': true,
      'adjustment_mode': 'NONE',
      'lines': selection['lines'],
    };
  }

  Widget _reversalProductCard(
    Map value,
    Map<int, bool> selected,
    Map<int, TextEditingController> quantities,
    Map<int, bool> selectedExtras,
    Map<int, TextEditingController> extraQuantities,
    void Function(void Function()) setDialogState,
  ) {
    final id = _asInt(value['id']);
    final controller = quantities[id];
    if (id <= 0 || controller == null) return const SizedBox.shrink();
    final extras = (value['extras'] as List? ?? const []).whereType<Map>();
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 12, 10),
        child: Column(
          children: [
            Row(
              children: [
                Checkbox(
                  value: selected[id] ?? false,
                  onChanged:
                      (checked) =>
                          setDialogState(() => selected[id] = checked ?? false),
                ),
                Expanded(
                  child: Text(
                    '${value['product_name'] ?? value['name'] ?? 'Produk'}\nMaksimal ${_asDouble(value['qty']).toStringAsFixed(2)}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                SizedBox(
                  width: 92,
                  child: TextField(
                    controller: controller,
                    enabled: selected[id] ?? false,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: 'Qty'),
                  ),
                ),
              ],
            ),
            for (final extra in extras)
              _reversalExtraRow(
                extra,
                selected[id] == true,
                selectedExtras,
                extraQuantities,
                setDialogState,
              ),
          ],
        ),
      ),
    );
  }

  Widget _reversalExtraRow(
    Map extra,
    bool productSelected,
    Map<int, bool> selectedExtras,
    Map<int, TextEditingController> extraQuantities,
    void Function(void Function()) setDialogState,
  ) {
    final id = _asInt(extra['id']);
    final controller = extraQuantities[id];
    if (id <= 0 || controller == null) return const SizedBox.shrink();
    return Row(
      children: [
        Checkbox(
          value: productSelected ? true : (selectedExtras[id] ?? false),
          onChanged:
              productSelected
                  ? null
                  : (checked) => setDialogState(
                    () => selectedExtras[id] = checked ?? false,
                  ),
        ),
        Expanded(
          child: Text(
            '${extra['extra_name'] ?? extra['name'] ?? 'Extra'}\nQty ${_asDouble(extra['qty']).toStringAsFixed(2)}',
          ),
        ),
        SizedBox(
          width: 92,
          child: TextField(
            controller: controller,
            enabled: !productSelected && (selectedExtras[id] ?? false),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Qty'),
          ),
        ),
      ],
    );
  }

  Future<void> _printReversal(
    Map<String, Object?> result, {
    required bool isRefund,
  }) async {
    final id = _asInt(result['id']);
    if (id <= 0) return;
    final response =
        isRefund
            ? await _api.refundPrintTargets(id)
            : await _api.voidPrintTargets(id);
    final targets = (response['direct_print_targets'] as List?) ?? const [];
    if (targets.isEmpty) return;
    final printResult = await _printDispatcher.printTargets(
      targets.whereType<Map>(),
    );
    await _showPrintOutcome(
      printResult,
      title: isRefund ? 'Cetak refund' : 'Cetak void',
    );
  }

  Future<String?> _reasonDialog(String title) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text(title),
            content: TextField(
              controller: controller,
              autofocus: true,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Alasan wajib diisi',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Batal'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, controller.text),
                child: const Text('Lanjutkan'),
              ),
            ],
          ),
    );
    controller.dispose();
    return result;
  }

  Future<Map<String, Object?>?> _refundDialog(
    Map<String, Object?> row,
    List<PaymentMethod> methods,
  ) async {
    final reference = TextEditingController();
    var methodId = methods.first.id;
    final result = await showDialog<Map<String, Object?>>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (dialogContext, setDialogState) => AlertDialog(
                  title: Text('Refund ${row['order_no'] ?? row['id']}'),
                  content: SizedBox(
                    width: 480,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DropdownButtonFormField<int>(
                          value: methodId,
                          items:
                              methods
                                  .map(
                                    (method) => DropdownMenuItem(
                                      value: method.id,
                                      child: Text(method.name),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (value) {
                            if (value != null) {
                              setDialogState(() => methodId = value);
                            }
                          },
                          decoration: const InputDecoration(
                            labelText: 'Metode pengembalian',
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: reference,
                          decoration: const InputDecoration(
                            labelText: 'Referensi refund (opsional)',
                          ),
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Batal'),
                    ),
                    FilledButton(
                      onPressed: () {
                        Navigator.pop(dialogContext, {
                          'payment_method_id': methodId,
                          'reference_no': reference.text.trim(),
                        });
                      },
                      child: const Text('Simpan refund'),
                    ),
                  ],
                ),
          ),
    );
    reference.dispose();
    return result;
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
        title: const Text('Order POS - Hari Ini'),
        actions: [
          IconButton(
            tooltip: 'Muat ulang order',
            onPressed: _loading ? null : _loadOrders,
            icon: const Icon(Icons.sync),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(
              icon: Icon(Icons.pending_actions),
              text: 'Aktif / belum payment',
            ),
            Tab(icon: Icon(Icons.payments_outlined), text: 'Terbayar / refund'),
          ],
        ),
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child:
            _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
                : TabBarView(
                  controller: _tabs,
                  children: [
                    _workspaceTab(_active, paid: false),
                    _workspaceTab(_paid, paid: true),
                  ],
                ),
      ),
    );
  }

  Widget _workspaceTab(List<Map<String, Object?>> rows, {required bool paid}) {
    return Column(
      children: [
        if (_warning != null)
          MaterialBanner(
            content: Text(_warning!),
            leading: const Icon(Icons.cloud_off),
            actions: [
              TextButton(
                onPressed: _loadOrders,
                child: const Text('Coba lagi'),
              ),
            ],
          ),
        Expanded(child: _orderList(rows, paid: paid)),
      ],
    );
  }

  Widget _orderList(List<Map<String, Object?>> rows, {required bool paid}) {
    if (rows.isEmpty) {
      return Center(
        child: Text(
          paid
              ? 'Belum ada order terbayar.'
              : 'Belum ada order aktif yang menunggu payment.',
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 620;
        return RefreshIndicator(
          onRefresh: _loadOrders,
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final row = rows[index];
              final status = row['status']?.toString() ?? '-';
              final actions = <Widget>[
                if (_asInt(row['id']) > 0)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => _reprint(row),
                    label: const Text('Cetak ulang'),
                    icon: const Icon(Icons.print_outlined),
                  ),
                if (!paid &&
                    _asInt(row['id']) > 0 &&
                    row['sync_status'] != 'BLOCKED' &&
                    row['sync_status'] != 'PENDING' &&
                    [
                      'DRAFT',
                      'PENDING',
                      'CONFIRMED',
                      'PAID_PARTIAL',
                      'IN_KITCHEN',
                      'READY',
                      'SERVED',
                    ].contains(status.toUpperCase()))
                  IconButton(
                    tooltip:
                        ['DRAFT', 'PENDING'].contains(status.toUpperCase())
                            ? 'Konfirmasi dan payment'
                            : 'Payment',
                    onPressed: () => _pay(_asInt(row['id'])),
                    icon: const Icon(Icons.payments_outlined),
                  ),
                IconButton(
                  tooltip: paid ? 'Refund' : 'Void',
                  onPressed: () => _openAction(row, paid: paid),
                  icon: Icon(paid ? Icons.keyboard_return : Icons.block),
                ),
              ];
              final summary = Text(
                '${row['customer_display_name'] ?? row['customer_name'] ?? 'Walk in'}\n${row['outlet_name'] ?? '-'} | $status'
                '${row['sync_status'] != null ? ' | ${row['sync_status']}' : ''}\n'
                'Stok: ${row['stock_commit_status'] ?? 'SERVER'}',
              );
              final total = Text(
                _money.format(_asDouble(row['grand_total'])),
                style: const TextStyle(fontWeight: FontWeight.w800),
              );
              return Card(
                child: InkWell(
                  onTap: () => _openDetail(row),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child:
                        compact
                            ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        row['order_no']?.toString() ??
                                            'POS #${row['id']}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    total,
                                  ],
                                ),
                                const SizedBox(height: 4),
                                summary,
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: Wrap(children: actions),
                                ),
                              ],
                            )
                            : Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        row['order_no']?.toString() ??
                                            'POS #${row['id']}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      summary,
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    total,
                                    const SizedBox(height: 4),
                                    Wrap(children: actions),
                                  ],
                                ),
                              ],
                            ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _DetailBadge extends StatelessWidget {
  const _DetailBadge({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkspacePaymentDialog extends StatefulWidget {
  const _WorkspacePaymentDialog({
    required this.payment,
    required this.onVoucherSearch,
    required this.onSubmit,
  });

  final Map<String, Object?> payment;
  final Future<List<Map<String, Object?>>> Function(String query)
  onVoucherSearch;
  final Future<Map<String, Object?>> Function(Map<String, Object?> payload)
  onSubmit;

  @override
  State<_WorkspacePaymentDialog> createState() =>
      _WorkspacePaymentDialogState();
}

class _WorkspacePaymentEntry {
  _WorkspacePaymentEntry({required this.methodId, String amount = ''})
    : amountController = TextEditingController(text: amount),
      referenceController = TextEditingController();

  int methodId;
  final TextEditingController amountController;
  final TextEditingController referenceController;

  void dispose() {
    amountController.dispose();
    referenceController.dispose();
  }
}

class _WorkspacePaymentDialogState extends State<_WorkspacePaymentDialog> {
  final String _clientEventId = 'PAY-${DateTime.now().microsecondsSinceEpoch}';
  final _voucher = TextEditingController();
  final _notes = TextEditingController();
  Timer? _voucherSearchTimer;
  int _voucherSearchRequest = 0;
  List<PaymentMethod> _methods = const [];
  List<Map<String, Object?>> _vouchers = const [];
  Map<String, Object?>? _selectedVoucher;
  final List<_WorkspacePaymentEntry> _entries = [];
  int _selectedEntryIndex = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final rows = (widget.payment['payment_methods'] as List?) ?? const [];
    _methods = rows
        .whereType<Map>()
        .map((row) => PaymentMethod.fromJson(Map<String, Object?>.from(row)))
        .where((method) => method.id > 0)
        .fold<List<PaymentMethod>>([], (items, method) {
          if (!items.any((item) => item.id == method.id)) {
            items.add(method);
          }
          return items;
        });
    if (_methods.isNotEmpty) {
      _entries.add(
        _WorkspacePaymentEntry(
          methodId: _methods.first.id,
          amount: _asDouble(widget.payment['due_total']).toStringAsFixed(0),
        ),
      );
    }
  }

  @override
  void dispose() {
    _voucherSearchTimer?.cancel();
    for (final entry in _entries) {
      entry.dispose();
    }
    _voucher.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _scheduleVoucherSearch() {
    _voucherSearchTimer?.cancel();
    final query = _voucher.text.trim();
    final request = ++_voucherSearchRequest;
    if (query.isEmpty) {
      if (mounted) {
        setState(() {
          _vouchers = const [];
          _selectedVoucher = null;
        });
      }
      return;
    }
    _voucherSearchTimer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted || request != _voucherSearchRequest) return;
      _searchVoucher(showError: false);
    });
  }

  Future<void> _searchVoucher({bool showError = true}) async {
    final query = _voucher.text.trim();
    if (query.isEmpty) return;
    setState(() => _busy = true);
    try {
      final rows = await widget.onVoucherSearch(query);
      if (mounted && _voucher.text.trim() == query) {
        setState(() => _vouchers = rows);
      }
    } catch (error) {
      if (showError) _message('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    final due = _asDouble(widget.payment['due_total']);
    final methodIds = _entries.map((entry) => entry.methodId).toList();
    final amounts =
        _entries
            .map((entry) => _asDouble(entry.amountController.text))
            .toList();
    final references =
        _entries.map((entry) => entry.referenceController.text.trim()).toList();
    if (due > 0 && _entries.isEmpty) {
      _message('Pilih metode pembayaran.');
      return;
    }
    if (due > 0 && amounts.every((amount) => amount <= 0)) {
      _message('Nominal pembayaran wajib diisi.');
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await widget.onSubmit({
        'client_event_id': _clientEventId,
        'payment_method_ids': methodIds,
        'paid_amounts': amounts,
        'reference_nos': references,
        'voucher_selection':
            _selectedVoucher?['selection_value']?.toString() ?? '',
        'voucher_code': _selectedVoucher?['voucher_code']?.toString() ?? '',
        'notes': _notes.text.trim(),
      });
      if (mounted) Navigator.pop(context, result);
    } catch (error) {
      _message('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  double get _enteredTotal => _entries.fold(
    0,
    (sum, entry) => sum + _asDouble(entry.amountController.text),
  );

  int _nextMethodId() {
    for (final method in _methods) {
      if (!_entries.any((entry) => entry.methodId == method.id)) {
        return method.id;
      }
    }
    return _methods.first.id;
  }

  void _setPaymentAmount(_WorkspacePaymentEntry entry, double amount) {
    final text = amount.round().toString();
    entry.amountController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() {});
  }

  double _remainingForSelectedEntry(double due) {
    final selected =
        _selectedEntryIndex >= 0 && _selectedEntryIndex < _entries.length
            ? _selectedEntryIndex
            : 0;
    var enteredBefore = 0.0;
    for (var index = 0; index < selected; index++) {
      enteredBefore += _asDouble(_entries[index].amountController.text);
    }
    return max(0, due - enteredBefore);
  }

  Widget _quickPaymentButtons(double due) {
    final index =
        _selectedEntryIndex >= 0 && _selectedEntryIndex < _entries.length
            ? _selectedEntryIndex
            : 0;
    final entry = _entries[index];
    var method = 'metode terpilih';
    for (final item in _methods) {
      if (item.id == entry.methodId) {
        method = item.name;
        break;
      }
    }
    final options = <Map<String, Object>>[
      {'label': 'Pas', 'value': _remainingForSelectedEntry(due)},
      {'label': '10K', 'value': 10000},
      {'label': '20K', 'value': 20000},
      {'label': '50K', 'value': 50000},
      {'label': '100K', 'value': 100000},
    ];
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4, bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8F4),
        border: Border.all(color: const Color(0xFFE5D5CB)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Nominal cepat untuk $method',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 7),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final option in options)
                OutlinedButton(
                  onPressed:
                      _busy
                          ? null
                          : () => _setPaymentAmount(
                            entry,
                            (option['value'] as num).toDouble(),
                          ),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  child: Text(option['label'] as String),
                ),
            ],
          ),
        ],
      ),
    );
  }

  void _message(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _paymentEntryFields(_WorkspacePaymentEntry entry, int index) {
    final method = DropdownButtonFormField<int>(
      value: entry.methodId == 0 ? null : entry.methodId,
      items:
          _methods
              .map(
                (item) => DropdownMenuItem<int>(
                  value: item.id,
                  child: Text(item.name, overflow: TextOverflow.ellipsis),
                ),
              )
              .toList(),
      onChanged:
          _busy
              ? null
              : (value) => setState(() {
                _selectedEntryIndex = index;
                entry.methodId = value ?? 0;
              }),
      decoration: InputDecoration(
        labelText: _entries.length > 1 ? 'Metode ${index + 1}' : 'Metode',
        isDense: true,
      ),
    );
    final amount = TextField(
      controller: entry.amountController,
      onTap: () => setState(() => _selectedEntryIndex = index),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: (_) => setState(() {}),
      onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
      decoration: const InputDecoration(
        labelText: 'Nominal',
        prefixText: 'Rp ',
        isDense: true,
      ),
    );
    final reference = TextField(
      controller: entry.referenceController,
      onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
      decoration: const InputDecoration(
        labelText: 'Referensi (opsional)',
        isDense: true,
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontal = constraints.maxWidth >= 520;
        final remove =
            _entries.length > 1
                ? IconButton(
                  tooltip: 'Hapus metode',
                  onPressed:
                      _busy
                          ? null
                          : () => setState(() {
                            final removed = _entries.removeAt(index);
                            removed.dispose();
                          }),
                  icon: const Icon(Icons.remove_circle_outline),
                )
                : const SizedBox.shrink();
        if (horizontal) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 4, child: method),
              const SizedBox(width: 8),
              Expanded(flex: 3, child: amount),
              const SizedBox(width: 8),
              Expanded(flex: 3, child: reference),
              remove,
            ],
          );
        }
        return Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [Expanded(child: method), remove],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: amount),
                const SizedBox(width: 8),
                Expanded(child: reference),
              ],
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final due = _asDouble(widget.payment['due_total']);
    final screenHeight = MediaQuery.sizeOf(context).height;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 760,
            maxHeight: screenHeight * .90,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
                child: Row(
                  children: [
                    const Icon(Icons.payments_outlined),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Payment ${widget.payment['order_no'] ?? ''}',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Tutup',
                      onPressed: _busy ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Tagihan dari server: ${_moneyText(due)}',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      if ((widget.payment['member_name']?.toString() ?? '')
                          .trim()
                          .isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Member: ${widget.payment['member_name']} | Poin ${_asDouble(widget.payment['member_point_balance']).toStringAsFixed(0)} | Stamp ${_asDouble(widget.payment['member_stamp_balance']).toStringAsFixed(0)}',
                          ),
                        ),
                      if (_asDouble(widget.payment['deposit_applied_total']) >
                          0)
                        Text(
                          'Deposit terpakai: ${_moneyText(_asDouble(widget.payment['deposit_applied_total']))}',
                        ),
                      const SizedBox(height: 10),
                      ..._entries.asMap().entries.map(
                        (item) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _paymentEntryFields(item.value, item.key),
                        ),
                      ),
                      if (_entries.isNotEmpty) _quickPaymentButtons(due),
                      OutlinedButton.icon(
                        onPressed:
                            _busy || _methods.isEmpty
                                ? null
                                : () => setState(() {
                                  _entries.add(
                                    _WorkspacePaymentEntry(
                                      methodId: _nextMethodId(),
                                    ),
                                  );
                                  _selectedEntryIndex = _entries.length - 1;
                                }),
                        icon: const Icon(Icons.add),
                        label: const Text('Tambah metode pembayaran'),
                      ),
                      const SizedBox(height: 6),
                      Text('Total input: ${_moneyText(_enteredTotal)}'),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _voucher,
                              onChanged: (_) {
                                setState(() {
                                  _selectedVoucher = null;
                                  _vouchers = const [];
                                });
                                _scheduleVoucherSearch();
                              },
                              onSubmitted: (_) => _searchVoucher(),
                              onTapOutside:
                                  (_) =>
                                      FocusManager.instance.primaryFocus
                                          ?.unfocus(),
                              decoration: const InputDecoration(
                                labelText: 'Kode voucher',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.outlined(
                            onPressed: _busy ? null : _searchVoucher,
                            icon: const Icon(Icons.local_offer_outlined),
                            tooltip: 'Cek voucher',
                          ),
                        ],
                      ),
                      ..._vouchers.map(
                        (voucher) => ListTile(
                          dense: true,
                          title: Text(
                            voucher['label']?.toString() ??
                                voucher['voucher_code']?.toString() ??
                                'Voucher',
                          ),
                          subtitle: Text(voucher['message']?.toString() ?? ''),
                          trailing:
                              voucher['ok'] == true
                                  ? const Icon(
                                    Icons.check_circle,
                                    color: Colors.green,
                                  )
                                  : const Icon(Icons.info_outline),
                          onTap:
                              voucher['ok'] == true
                                  ? () {
                                    final code =
                                        voucher['voucher_code']
                                            ?.toString()
                                            .trim() ??
                                        '';
                                    setState(() {
                                      _selectedVoucher = voucher;
                                      if (code.isNotEmpty) {
                                        _voucher.value = TextEditingValue(
                                          text: code,
                                          selection: TextSelection.collapsed(
                                            offset: code.length,
                                          ),
                                        );
                                      }
                                    });
                                  }
                                  : null,
                        ),
                      ),
                      if (_selectedVoucher != null)
                        Text(
                          'Voucher dipilih: ${_selectedVoucher?['voucher_code'] ?? _selectedVoucher?['label']}',
                        ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _notes,
                        onTapOutside:
                            (_) =>
                                FocusManager.instance.primaryFocus?.unfocus(),
                        maxLines: 2,
                        minLines: 1,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        decoration: const InputDecoration(
                          labelText: 'Catatan payment',
                          isDense: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy ? null : () => Navigator.pop(context),
                        child: const Text('Batal'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _submit,
                        icon: const Icon(Icons.check),
                        label: const Text('Simpan payment'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

double _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString().replaceAll(',', '.') ?? '') ?? 0;
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

String _moneyText(double value) {
  return NumberFormat.currency(
    locale: 'id_ID',
    symbol: 'Rp ',
    decimalDigits: 0,
  ).format(value);
}

String _workspaceError(Object error) {
  if (error is FinanceApiException) return error.userMessage;
  if (error is TimeoutException) return 'Server terlalu lama merespons.';
  return 'Operasi belum berhasil. Data lokal tetap aman.';
}
