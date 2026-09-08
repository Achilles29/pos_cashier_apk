import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../services/finance_api_client.dart';
import '../services/pos_print_dispatcher.dart';
import '../widgets/sensitive_action_proof_dialog.dart';

enum IncomingOrderChannel { reservation, selfOrder, onlineFood }

class IncomingOrdersScreen extends StatefulWidget {
  const IncomingOrdersScreen({
    super.key,
    required this.settings,
    required this.channel,
  });

  final AppSettings settings;
  final IncomingOrderChannel channel;

  @override
  State<IncomingOrdersScreen> createState() => _IncomingOrdersScreenState();
}

class _IncomingOrdersScreenState extends State<IncomingOrdersScreen>
    with TickerProviderStateMixin {
  late final FinanceApiClient _api;
  final PosPrintDispatcher _printDispatcher = PosPrintDispatcher();
  late final TabController _statusTabs;
  TabController? _reservationTabs;
  final _search = TextEditingController();
  final _money = NumberFormat.currency(
    locale: 'id_ID',
    symbol: 'Rp ',
    decimalDigits: 0,
  );
  Timer? _searchTimer;
  List<Map<String, Object?>> _rows = const [];
  List<Map<String, Object?>> _productRows = const [];
  bool _loading = true;
  String? _error;
  String _status = '';
  int _pageView = 0;

  bool get _isReservation => widget.channel == IncomingOrderChannel.reservation;

  List<String> get _statusCodes =>
      _isReservation
          ? const ['ACTIVE', 'COMPLETED', 'OVERDUE', 'ALL']
          : const [
            'NEEDS_VERIFY',
            'WAITING_PAYMENT',
            'ACTIVE_CASHIER',
            'PAID_ORDER',
            'REJECTED',
          ];

  List<String> get _statusLabels =>
      _isReservation
          ? const ['Aktif', 'Selesai', 'Sudah lewat', 'Semua']
          : const [
            'Verifikasi',
            'Menunggu bayar',
            'Order aktif',
            'Terbayar',
            'Ditolak',
          ];

  String get _title {
    switch (widget.channel) {
      case IncomingOrderChannel.reservation:
        return 'Verifikasi reservasi';
      case IncomingOrderChannel.selfOrder:
        return 'Verifikasi self-order';
      case IncomingOrderChannel.onlineFood:
        return 'Verifikasi order online';
    }
  }

  @override
  void initState() {
    super.initState();
    _api = FinanceApiClient(settings: widget.settings);
    _status = _statusCodes.first;
    _statusTabs = TabController(length: _statusCodes.length, vsync: this);
    _statusTabs.addListener(_statusChanged);
    if (_isReservation) {
      _reservationTabs = TabController(length: 2, vsync: this);
      _reservationTabs!.addListener(() {
        if (!_reservationTabs!.indexIsChanging && mounted) {
          setState(() => _pageView = _reservationTabs!.index);
          _load();
        }
      });
    }
    _load();
  }

  void _statusChanged() {
    if (_statusTabs.indexIsChanging || !mounted) return;
    final next = _statusCodes[_statusTabs.index];
    if (next == _status) return;
    setState(() => _status = next);
    _load();
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _search.dispose();
    _statusTabs.removeListener(_statusChanged);
    _statusTabs.dispose();
    _reservationTabs?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
      if (_isReservation && _pageView == 1) {
        _productRows = const [];
      } else {
        _rows = const [];
      }
    });
    try {
      if (_isReservation && _pageView == 1) {
        final result = await _api.reservationProducts(
          query: _search.text.trim(),
          statusTab: _status,
        );
        _productRows = _asRows(result['rows']);
      } else {
        final result = switch (widget.channel) {
          IncomingOrderChannel.reservation => await _api.reservations(
            query: _search.text.trim(),
            statusTab: _status,
          ),
          IncomingOrderChannel.selfOrder => await _api.selfOrderInbox(
            query: _search.text.trim(),
            statusTab: _status,
          ),
          IncomingOrderChannel.onlineFood => await _api.onlineFoodInbox(
            query: _search.text.trim(),
            statusTab: _status,
          ),
        };
        _rows = _asRows(result['rows']);
      }
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _friendlyError(error);
      });
    }
  }

  void _searchChanged(String value) {
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 350), _load);
  }

  Future<void> _openDetail(Map<String, Object?> row) async {
    final id = _asInt(row['id']);
    if (id <= 0) return;
    try {
      final response = switch (widget.channel) {
        IncomingOrderChannel.reservation => await _api.reservationDetail(id),
        IncomingOrderChannel.selfOrder => await _api.selfOrderInboxDetail(id),
        IncomingOrderChannel.onlineFood => await _api.onlineFoodInboxDetail(id),
      };
      if (!mounted) return;
      final detail =
          widget.channel == IncomingOrderChannel.reservation
              ? ((response['reservation'] as Map?)?.cast<String, Object?>() ??
                  row)
              : response;
      await showDialog<void>(
        context: context,
        builder:
            (_) => _IncomingDetailDialog(
              title: _string(
                detail['reservation_no'] ?? detail['order_no'],
                'Rincian order',
              ),
              detail: detail,
              money: _money,
              reservation: _isReservation,
              onVerify: () => _verify(id),
              onReject: () => _reject(id),
            ),
      );
    } catch (error) {
      _showMessage(_friendlyError(error));
    }
  }

  Future<void> _verify(int id) async {
    try {
      final response = switch (widget.channel) {
        IncomingOrderChannel.reservation => await _api.reservationVerify(id),
        IncomingOrderChannel.selfOrder => await _api.selfOrderInboxVerify(id),
        IncomingOrderChannel.onlineFood => await _api.onlineFoodInboxVerify(id),
      };
      final targets = (response['direct_print_targets'] as List?) ?? const [];
      if (targets.isNotEmpty) {
        final printResult = await _printDispatcher.printTargets(
          targets.whereType<Map>(),
        );
        _showMessage(
          printResult.hasProblem
              ? 'Order diterima. Cetak: ${printResult.message}'
              : 'Order diterima dan tiket dikirim ke printer.',
        );
      } else {
        _showMessage('Order diterima. Tidak ada target printer aktif.');
      }
      await _load();
    } catch (error) {
      _showMessage('Verifikasi gagal: ${_friendlyError(error)}');
    }
  }

  Future<void> _reject(int id) async {
    final controller = TextEditingController();
    final result = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (dialogContext) {
        var refundDeposit = false;
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) => Dialog(
            insetPadding: const EdgeInsets.all(22),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.block_outlined,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Tolak order',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Batal',
                          onPressed: () => Navigator.pop(dialogContext),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Berikan alasan agar keputusan ini mudah dilacak di riwayat POS.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      maxLines: 3,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        labelText: 'Alasan penolakan',
                        hintText:
                            'Contoh: item habis atau data customer tidak lengkap',
                        alignLabelWithHint: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (_isReservation) ...[
                      const SizedBox(height: 10),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: refundDeposit,
                        onChanged: (value) => setDialogState(
                          () => refundDeposit = value ?? false,
                        ),
                        title: const Text('Kembalikan DP reservasi'),
                        subtitle: const Text(
                          'Pilih hanya bila DP benar-benar harus direfund. Setelah ini Anda diminta verifikasi password.',
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text('Batal'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          onPressed: () {
                            final value = controller.text.trim();
                            if (value.isNotEmpty) {
                              Navigator.pop(dialogContext, {
                                'reason': value,
                                'refund_deposit': refundDeposit,
                              });
                            }
                          },
                          icon: const Icon(Icons.block_outlined),
                          label: const Text('Tolak order'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
    controller.dispose();
    final reason = result?['reason']?.toString().trim() ?? '';
    final refundDeposit = result?['refund_deposit'] == true;
    if (reason.isEmpty) return;
    try {
      switch (widget.channel) {
        case IncomingOrderChannel.reservation:
          var proof = '';
          if (refundDeposit) {
            final verified = await requestSensitiveActionProof(
              context,
              title: 'Verifikasi refund DP',
              description:
                  'Pengembalian DP reservasi akan diproses oleh Finance. Masukkan password Anda untuk melanjutkan.',
              confirmLabel: 'Verifikasi & refund DP',
              verify: (password) => _api.reservationRejectStepUpVerify(
                reservationId: id,
                password: password,
              ),
            );
            if (verified == null) return;
            proof = verified;
          }
          await _api.reservationReject(
            id,
            reason,
            refundDeposit: refundDeposit,
            stepUpProof: proof,
          );
        case IncomingOrderChannel.selfOrder:
          await _api.selfOrderInboxReject(id, reason);
        case IncomingOrderChannel.onlineFood:
          await _api.onlineFoodInboxReject(id, reason);
      }
      _showMessage('Order ditolak.');
      await _load();
    } catch (error) {
      _showMessage('Penolakan gagal: ${_friendlyError(error)}');
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
        title: Text(_title),
        actions: [
          IconButton(
            tooltip: 'Muat ulang',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.sync),
          ),
        ],
        bottom:
            _reservationTabs == null
                ? _statusBar()
                : PreferredSize(
                  preferredSize: const Size.fromHeight(96),
                  child: Column(
                    children: [
                      TabBar(
                        controller: _reservationTabs,
                        tabs: const [
                          Tab(text: 'Transaksi'),
                          Tab(text: 'Rincian produk'),
                        ],
                      ),
                      _statusBar(),
                    ],
                  ),
                ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              controller: _search,
              onChanged: _searchChanged,
              decoration: InputDecoration(
                hintText: 'Cari nomor order, customer, meja...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon:
                    _search.text.isEmpty
                        ? null
                        : IconButton(
                          tooltip: 'Hapus pencarian',
                          onPressed: () {
                            _search.clear();
                            _load();
                            setState(() {});
                          },
                          icon: const Icon(Icons.clear),
                        ),
              ),
            ),
          ),
          Expanded(
            child:
                _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                    ? _ErrorState(message: _error!, onRetry: _load)
                    : RefreshIndicator(
                      onRefresh: _load,
                      child:
                          _isReservation && _pageView == 1
                              ? _productList()
                              : _orderList(),
                    ),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _statusBar() {
    return PreferredSize(
      preferredSize: const Size.fromHeight(42),
      child: TabBar(
        controller: _statusTabs,
        isScrollable: true,
        tabs: [for (final label in _statusLabels) Tab(text: label)],
      ),
    );
  }

  Widget _orderList() {
    if (_rows.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: 180),
          Center(child: Text('Belum ada data pada tab ini.')),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: _rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder:
          (_, index) => _OrderCard(
            row: _rows[index],
            money: _money,
            reservation: _isReservation,
            onTap: () => _openDetail(_rows[index]),
          ),
    );
  }

  Widget _productList() {
    if (_productRows.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 180),
          Center(child: Text('Belum ada rincian produk pada tab ini.')),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: _productRows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder:
          (_, index) => _ProductCard(row: _productRows[index], money: _money),
    );
  }

  static List<Map<String, Object?>> _asRows(Object? value) {
    final rawRows = value is Map ? value['rows'] : value;
    return (rawRows as List?)
            ?.whereType<Map>()
            .map((row) => Map<String, Object?>.from(row))
            .toList() ??
        const [];
  }

  static int _asInt(Object? value) =>
      int.tryParse(value?.toString() ?? '') ?? 0;

  static String _string(Object? value, String fallback) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? fallback : text;
  }

  static String _friendlyError(Object error) {
    if (error is FinanceApiException) return error.userMessage;
    return 'Data order belum dapat dimuat. Periksa koneksi lalu coba lagi.';
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({
    required this.row,
    required this.money,
    required this.reservation,
    required this.onTap,
  });

  final Map<String, Object?> row;
  final NumberFormat money;
  final bool reservation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final number =
        row[reservation ? 'reservation_no' : 'order_no']?.toString() ?? '-';
    final customer =
        row['customer_name_display']?.toString() ??
        row['customer_name']?.toString() ??
        row['member_name']?.toString() ??
        'Walk-in';
    final status =
        row['status_label']?.toString() ??
        row['flow_label']?.toString() ??
        row['status']?.toString() ??
        '-';
    final statusColor = _statusColor(context, status);
    final total = _double(row['grand_total'] ?? row['total_amount']);
    final schedule =
        row['reservation_at']?.toString() ??
        row['ordered_at']?.toString() ??
        '';
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          number,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          customer,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        money.format(total),
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 5),
                      _StatusPill(label: status, color: statusColor),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  if (_text(row['outlet_name']).isNotEmpty)
                    _MetaText(
                      icon: Icons.storefront_outlined,
                      text: _text(row['outlet_name']),
                    ),
                  if (_text(row['table_no']).isNotEmpty)
                    _MetaText(
                      icon: Icons.table_restaurant_outlined,
                      text: 'Meja ${_text(row['table_no'])}',
                    ),
                  if (_text(row['payment_mode']).isNotEmpty)
                    _MetaText(
                      icon: Icons.payments_outlined,
                      text: _text(row['payment_mode']),
                    ),
                ],
              ),
              if (schedule.trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                _MetaText(icon: Icons.schedule_outlined, text: schedule),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static double _double(Object? value) =>
      double.tryParse(value?.toString() ?? '') ?? 0;

  static String _text(Object? value) => value?.toString().trim() ?? '';

  static Color _statusColor(BuildContext context, String status) {
    final code = status.toUpperCase();
    if (code.contains('TOLAK') || code.contains('REJECT')) return Colors.red;
    if (code.contains('PAID') || code.contains('SELESAI')) return Colors.green;
    if (code.contains('WAIT') || code.contains('MENUNGGU')) {
      return Colors.orange;
    }
    return Theme.of(context).colorScheme.primary;
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.row, required this.money});

  final Map<String, Object?> row;
  final NumberFormat money;

  @override
  Widget build(BuildContext context) {
    final name =
        row['product_name']?.toString().trim().isNotEmpty == true
            ? row['product_name'].toString()
            : row['bundle_name']?.toString() ?? 'Produk';
    final qty = double.tryParse(row['qty']?.toString() ?? '') ?? 0;
    final total = double.tryParse(row['line_total']?.toString() ?? '') ?? 0;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: const Icon(Icons.restaurant_menu),
        ),
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          '${row['operational_division_name'] ?? row['product_division_name'] ?? '-'} | Qty $qty\n${row['reservation_no'] ?? '-'}',
        ),
        trailing: Text(
          money.format(total),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _MetaText extends StatelessWidget {
  const _MetaText({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 15,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 4),
        Text(text, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _IncomingDetailDialog extends StatelessWidget {
  const _IncomingDetailDialog({
    required this.title,
    required this.detail,
    required this.money,
    required this.reservation,
    required this.onVerify,
    required this.onReject,
  });

  final String title;
  final Map<String, Object?> detail;
  final NumberFormat money;
  final bool reservation;
  final Future<void> Function() onVerify;
  final Future<void> Function() onReject;

  @override
  Widget build(BuildContext context) {
    final header =
        reservation
            ? detail
            : ((detail['header'] as Map?)?.cast<String, Object?>() ?? detail);
    final lines =
        (detail['lines'] as List?)
            ?.whereType<Map>()
            .map((line) => Map<String, Object?>.from(line))
            .toList() ??
        const <Map<String, Object?>>[];
    final customer =
        header['customer_name_display'] ??
        header['customer_name'] ??
        header['member_name'] ??
        'Walk-in';
    final status =
        (header['status_label'] ??
                header['flow_label'] ??
                header['status'] ??
                '-')
            .toString();
    final total =
        double.tryParse(
          (header['grand_total'] ?? header['total_amount'] ?? 0).toString(),
        ) ??
        0;
    return Dialog(
      insetPadding: const EdgeInsets.all(18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          customer.toString(),
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  _StatusPill(
                    label: status,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  IconButton(
                    tooltip: 'Tutup',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 16,
                      runSpacing: 8,
                      children: [
                        if (_text(header['service_type']).isNotEmpty)
                          _MetaText(
                            icon: Icons.room_service_outlined,
                            text: _text(header['service_type']),
                          ),
                        if (_text(header['outlet_name']).isNotEmpty)
                          _MetaText(
                            icon: Icons.storefront_outlined,
                            text: _text(header['outlet_name']),
                          ),
                        if (_text(header['table_no']).isNotEmpty)
                          _MetaText(
                            icon: Icons.table_restaurant_outlined,
                            text: 'Meja ${_text(header['table_no'])}',
                          ),
                        if (_text(header['payment_mode']).isNotEmpty)
                          _MetaText(
                            icon: Icons.payments_outlined,
                            text: _text(header['payment_mode']),
                          ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Text(
                          'Rincian pesanan',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const Spacer(),
                        Text(
                          money.format(total),
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (lines.isEmpty) const Text('Belum ada baris produk.'),
                    for (final line in lines) _line(line),
                    if (_text(header['notes']).isNotEmpty) ...[
                      const Divider(height: 24),
                      Text(
                        'Catatan',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(_text(header['notes'])),
                    ],
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      onReject();
                    },
                    icon: const Icon(Icons.block_outlined),
                    label: const Text('Tolak'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      onVerify();
                    },
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Verifikasi'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _line(Map<String, Object?> line) {
    final name =
        line['product_name']?.toString().trim().isNotEmpty == true
            ? line['product_name'].toString()
            : line['bundle_name']?.toString() ?? 'Produk';
    final qty = double.tryParse(line['qty']?.toString() ?? '') ?? 0;
    final total =
        double.tryParse(
          (line['line_total'] ?? line['net_amount'] ?? line['total'])
                  ?.toString() ??
              '',
        ) ??
        0;
    final extras =
        (line['extras'] as List?)
            ?.whereType<Map>()
            .map((extra) => extra['extra_name']?.toString() ?? '')
            .where((extra) => extra.trim().isNotEmpty)
            .join(', ') ??
        '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .035),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$qty x $name',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  if (extras.isNotEmpty) Text('Extra: $extras'),
                  if ((line['notes']?.toString() ?? '').trim().isNotEmpty)
                    Text('Catatan: ${line['notes']}'),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            money.format(total),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  static String _text(Object? value) => value?.toString().trim() ?? '';
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 42),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Coba lagi'),
            ),
          ],
        ),
      ),
    );
  }
}
