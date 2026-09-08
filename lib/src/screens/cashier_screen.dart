import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../services/finance_api_client.dart';
import '../services/local_database.dart';
import '../services/pos_print_dispatcher.dart';
import '../services/photo_cache_service.dart';
import '../services/settings_store.dart';
import '../services/sync_service.dart';
import '../widgets/sensitive_action_proof_dialog.dart';
import 'setup_screen.dart';
import 'order_workspace_screen.dart';
import 'printer_settings_screen.dart';
import 'incoming_orders_screen.dart';

class CashierScreen extends StatefulWidget {
  const CashierScreen({
    super.key,
    required this.settings,
    required this.settingsStore,
    required this.onOpenSetup,
  });

  final AppSettings settings;
  final SettingsStore settingsStore;
  final VoidCallback onOpenSetup;

  @override
  State<CashierScreen> createState() => _CashierScreenState();
}

class _CashierScreenState extends State<CashierScreen> {
  final LocalDatabase _db = LocalDatabase.instance;
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _customerController = TextEditingController();
  final TextEditingController _tableController = TextEditingController();
  final TextEditingController _guestController = TextEditingController(
    text: '1',
  );
  final TextEditingController _noteController = TextEditingController();
  final NumberFormat _money = NumberFormat.currency(
    locale: 'id_ID',
    symbol: 'Rp ',
    decimalDigits: 0,
  );
  static const Map<String, String> _serviceTypes = {
    'DINE_IN': 'Dine in',
    'TAKE_AWAY': 'Take away',
    'DELIVERY': 'Delivery',
    'PICKUP': 'Pickup',
  };

  late SyncService _syncService;
  late FinanceApiClient _api;
  final PosPrintDispatcher _printDispatcher = PosPrintDispatcher();
  final PhotoCacheService _photoCache = PhotoCacheService.instance;
  final Map<String, Future<String?>> _photoFutures = {};
  Timer? _syncTimer;
  Timer? _catalogSearchTimer;
  Timer? _memberSearchTimer;
  Future<void>? _cacheLoadFuture;
  SyncSnapshot _sync = SyncSnapshot.initial;
  CashierSession? _session;
  List<Map<String, Object?>> _activeServerSessions = const [];
  List<ProductItem> _products = const [];
  List<ProductItem> _remoteProducts = const [];
  List<Map<String, Object?>> _divisions = const [];
  List<Map<String, Object?>> _salesChannels = const [];
  int _salesChannelId = 0;
  MemberItem? _selectedMember;
  List<MemberItem> _memberSuggestions = const [];
  bool _memberSearchBusy = false;
  int _memberSearchRequest = 0;
  List<BundleItem> _bundles = const [];
  List<BundleItem> _remoteBundles = const [];
  String _catalogMode = 'PRODUCT';
  int _divisionId = 0;
  bool _catalogBusy = false;
  bool _authRedirecting = false;
  bool _syncInProgress = false;
  bool _modalActive = false;
  bool _initialSessionGateDone = false;
  bool _openingPromptShown = false;
  int _compactPanel = 1;
  int _localDraftCount = 0;
  final Map<int, CartLine> _cart = {};
  final GlobalKey<_ActiveOrdersPanelState> _activeOrdersKey =
      GlobalKey<_ActiveOrdersPanelState>();
  String _serviceType = 'DINE_IN';
  int _editingOrderId = 0;
  String _editingOrderNo = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _syncService = SyncService(settings: widget.settings, localDatabase: _db);
    _api = FinanceApiClient(settings: widget.settings);
    _cacheLoadFuture = _loadCachedData();
    _runSync();
    _syncTimer = Timer.periodic(
      Duration(seconds: widget.settings.foregroundSyncSeconds),
      (_) => _runSync(silent: true),
    );
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _catalogSearchTimer?.cancel();
    _memberSearchTimer?.cancel();
    _searchController.dispose();
    _customerController.dispose();
    _tableController.dispose();
    _guestController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _loadCachedData() async {
    final products = await _syncService.productsFromCache();
    final bundles = await _syncService.bundlesFromCache();
    final session = await _syncService.currentSessionFromCache();
    final activeServerSessions =
        await _syncService.activeCashierSessionsFromCache();
    final divisions = await _syncService.catalogDivisionsFromCache();
    final bootstrap = await _syncService.cashierBootstrapFromCache();
    final rawChannels = bootstrap['sales_channels'];
    final salesChannels =
        rawChannels is List
            ? rawChannels
                .whereType<Map>()
                .map((row) => Map<String, Object?>.from(row))
                .toList()
            : const <Map<String, Object?>>[];
    if (!mounted) {
      return;
    }
    setState(() {
      _products = products;
      _bundles = bundles;
      _session = session;
      _activeServerSessions = activeServerSessions;
      _divisions = divisions;
      _salesChannels = salesChannels;
      if (_salesChannelId <= 0) {
        _salesChannelId = _asInt(bootstrap['default_sales_channel_id']);
      }
    });
    _precacheBundlePhotos(bundles);
    await _refreshLocalDraftCount();
  }

  Future<void> _runSync({bool silent = false}) async {
    if (_syncInProgress) return;
    if (silent &&
        (_modalActive ||
            _catalogBusy ||
            _memberSearchBusy ||
            _cart.isNotEmpty)) {
      return;
    }
    if (!silent) {
      final cacheLoad = _cacheLoadFuture;
      if (cacheLoad != null) await cacheLoad;
    }
    _syncInProgress = true;
    if (!silent && mounted) setState(() => _busy = true);
    try {
      final snapshot = await _syncService.syncNow(retryBlocked: !silent);
      final session = await _syncService.currentSessionFromCache();
      final activeServerSessions =
          await _syncService.activeCashierSessionsFromCache();
      final products = await _syncService.productsFromCache();
      final bundles = await _syncService.bundlesFromCache();
      final divisions = await _syncService.catalogDivisionsFromCache();
      final bootstrap = await _syncService.cashierBootstrapFromCache();
      final rawChannels = bootstrap['sales_channels'];
      final salesChannels =
          rawChannels is List
              ? rawChannels
                  .whereType<Map>()
                  .map((row) => Map<String, Object?>.from(row))
                  .toList()
              : const <Map<String, Object?>>[];
      if (!mounted) return;
      if (snapshot.requiresLogin) {
        setState(() => _sync = snapshot);
        await _expireLogin();
        return;
      }
      final preserveCatalog =
          silent || _cart.isNotEmpty || _modalActive || _catalogBusy;
      setState(() {
        _sync = snapshot;
        _session = session;
        _activeServerSessions = activeServerSessions;
        if (!preserveCatalog) {
          _divisions = divisions;
          _salesChannels = salesChannels;
          if (products.isNotEmpty) _products = products;
          if (bundles.isNotEmpty) _bundles = bundles;
        }
        if (_salesChannelId <= 0) {
          _salesChannelId = _asInt(bootstrap['default_sales_channel_id']);
        }
      });
      _photoCache.beginSyncCycle();
      _precacheProductPhotos(products);
      _precacheBundlePhotos(bundles);
      if (!silent && !preserveCatalog) await _applyServerTerminalDefaults();
      await _refreshLocalDraftCount();
      if (snapshot.online) {
        await _dispatchPendingConfirmationPrints(silent: silent);
      }
      if (!silent) {
        await _ensureInitialCashierSession();
      }
    } finally {
      _syncInProgress = false;
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  Future<void> _ensureInitialCashierSession() async {
    if (!mounted || _initialSessionGateDone) return;
    _initialSessionGateDone = true;

    if (_session?.isOpen == true) return;

    if (_activeServerSessions.isNotEmpty) {
      final names = _activeServerSessions
          .take(3)
          .map((row) => row['cashier_name']?.toString().trim())
          .where((name) => name != null && name.isNotEmpty)
          .cast<String>()
          .join(', ');
      _showMessage(
        names.isEmpty
            ? 'Ada sesi kasir aktif di server. Ganti akun atau pilih terminal lain.'
            : 'Kasir aktif di server: $names. Ganti akun atau pilih terminal lain.',
      );
      return;
    }

    if (!_sync.online) {
      _showMessage(
        'Belum ada sesi kasir aktif. Hubungkan ke server lalu buka kasir sebelum menerima order.',
      );
      return;
    }

    await _promptOpenCashier();
  }

  Future<void> _promptOpenCashier() async {
    if (!mounted || _openingPromptShown || _session?.isOpen == true) return;
    _openingPromptShown = true;
    await _toggleShift();
  }

  void _precacheProductPhotos(List<ProductItem> products) {
    unawaited(() async {
      final candidates =
          products
              .where((product) => product.photoUrl.trim().isNotEmpty)
              .toList();
      for (var index = 0; index < candidates.length; index += 4) {
        final batch = candidates.skip(index).take(4);
        await Future.wait(
          batch.map((product) {
            final source = product.photoUrl.trim();
            final future = _photoCache.cacheProductPhoto(
              backendUrl: widget.settings.normalizedBackendUrl,
              source: source,
              refreshExisting: true,
            );
            _photoFutures[source] = future;
            return future;
          }),
        );
      }
    }());
  }

  void _precacheBundlePhotos(List<BundleItem> bundles) {
    unawaited(() async {
      final candidates =
          bundles.where((bundle) => bundle.photoUrl.trim().isNotEmpty).toList();
      for (var index = 0; index < candidates.length; index += 4) {
        final batch = candidates.skip(index).take(4);
        await Future.wait(
          batch.map((bundle) {
            final source = bundle.photoUrl.trim();
            final future = _photoCache.cacheProductPhoto(
              backendUrl: widget.settings.normalizedBackendUrl,
              source: source,
              refreshExisting: true,
            );
            _photoFutures[source] = future;
            return future;
          }),
        );
      }
    }());
  }

  Future<void> _applyServerTerminalDefaults() async {
    if (!mounted || !_sync.online || _authRedirecting) return;

    final bootstrap = await _syncService.cashierBootstrapFromCache();
    final rawOutlets = bootstrap['outlets'];
    final rawTerminals = bootstrap['terminals'];
    final outlets =
        rawOutlets is List
            ? rawOutlets.whereType<Map>().toList()
            : const <Map>[];
    final terminals =
        rawTerminals is List
            ? rawTerminals.whereType<Map>().toList()
            : const <Map>[];
    if (outlets.isEmpty || terminals.isEmpty) return;

    final activeSession = bootstrap['active_session'];
    final session =
        activeSession is Map ? activeSession : const <String, Object?>{};
    var outletId = _asInt(session['outlet_id']);
    if (outletId <= 0) outletId = widget.settings.outletId;
    if (outletId <= 0 || !outlets.any((row) => _asInt(row['id']) == outletId)) {
      outletId = _asInt(bootstrap['default_outlet_id']);
    }

    var terminalId = _asInt(session['terminal_id']);
    if (terminalId <= 0) terminalId = widget.settings.terminalId;
    final outletTerminals =
        terminals.where((row) => _asInt(row['outlet_id']) == outletId).toList();
    if (terminalId <= 0 ||
        !outletTerminals.any((row) => _asInt(row['id']) == terminalId)) {
      terminalId =
          outletTerminals.isNotEmpty
              ? _asInt(outletTerminals.first['id'])
              : _asInt(bootstrap['default_terminal_id']);
    }
    if (outletId <= 0 || terminalId <= 0) return;
    if (outletId == widget.settings.outletId &&
        terminalId == widget.settings.terminalId) {
      return;
    }

    await widget.settingsStore.save(
      widget.settings.copyWith(outletId: outletId, terminalId: terminalId),
    );
    if (mounted) widget.onOpenSetup();
  }

  Future<void> _addProduct(ProductItem product) async {
    if (_session?.isOpen != true) {
      _showMessage('Buka kasir terlebih dahulu sebelum menambah order.');
      return;
    }
    final availability = product.availabilityStatus.toUpperCase();
    if (availability == 'OUT' ||
        availability == 'UNAVAILABLE' ||
        availability == 'SOLD_OUT') {
      _showMessage('Produk sedang tidak tersedia menurut stok server.');
      return;
    }
    _modalActive = true;
    try {
      List<Map<String, Object?>> groups = const [];
      String? extraError;
      if (widget.settings.isConfigured) {
        try {
          final response = await _api.extraOptions(product.id);
          final rawGroups = response['groups'];
          if (rawGroups is List) {
            groups =
                rawGroups
                    .whereType<Map>()
                    .map((row) => Map<String, Object?>.from(row))
                    .toList();
          } else if (rawGroups is Map) {
            final flattened = <Map<String, Object?>>[];
            for (final value in rawGroups.values) {
              if (value is Map) {
                flattened.add(Map<String, Object?>.from(value));
              } else if (value is List) {
                flattened.addAll(
                  value.whereType<Map>().map(
                    (row) => Map<String, Object?>.from(row),
                  ),
                );
              }
            }
            groups = flattened;
          }
        } catch (error) {
          if (error is FinanceApiException && error.isUnauthorized) {
            await _expireLogin();
            return;
          }
          groups = const [];
          extraError = _friendlyError(error);
        }
      }
      final customization = await _pickExtras(
        product,
        groups,
        errorMessage: extraError,
      );
      if (!mounted || customization == null) {
        return;
      }
      setState(() {
        var cartKey = product.id;
        CartLine? existing = _cart[cartKey];
        if (_editingOrderId > 0 && existing?.orderLineId != 0) {
          for (final entry in _cart.entries) {
            if (entry.value.orderLineId == 0 &&
                entry.value.bundleId == 0 &&
                entry.value.product.id == product.id) {
              cartKey = entry.key;
              existing = entry.value;
              break;
            }
          }
          if (existing?.orderLineId != 0) {
            cartKey = _nextCartKey();
            existing = null;
          }
        }
        _cart[cartKey] =
            existing == null
                ? CartLine(
                  product: product,
                  qty: customization.qty,
                  notes: customization.note,
                  extras: customization.extras,
                )
                : existing.copyWith(
                  qty: existing.qty + customization.qty,
                  notes:
                      customization.note.isEmpty
                          ? existing.notes
                          : customization.note,
                  extras:
                      customization.extras.isEmpty
                          ? existing.extras
                          : customization.extras,
                );
      });
    } finally {
      _modalActive = false;
    }
  }

  Future<_ProductCustomization?> _pickExtras(
    ProductItem product,
    List<Map<String, Object?>> groups, {
    String? errorMessage,
  }) async {
    final selected = <int, CartExtra>{};
    final noteController = TextEditingController();
    var quantity = 1;
    final result = await showDialog<_ProductCustomization>(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder: (context, setDialogState) {
              return AlertDialog(
                title: Text('Atur extra: ${product.name}'),
                content: SizedBox(
                  width: 520,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          controller: noteController,
                          onTapOutside:
                              (_) =>
                                  FocusManager.instance.primaryFocus?.unfocus(),
                          maxLines: 2,
                          decoration: const InputDecoration(
                            labelText: 'Catatan line',
                            hintText:
                                'Contoh: less ice, meja pojok, tanpa sedotan',
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Jumlah produk',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Kurangi jumlah',
                              onPressed:
                                  quantity <= 1
                                      ? null
                                      : () => setDialogState(() => quantity--),
                              icon: const Icon(Icons.remove_circle_outline),
                            ),
                            SizedBox(
                              width: 32,
                              child: Text(
                                '$quantity',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Tambah jumlah',
                              onPressed: () => setDialogState(() => quantity++),
                              icon: const Icon(Icons.add_circle_outline),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        if (errorMessage != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              'Extra belum dapat diambil dari server. $errorMessage',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          )
                        else if (groups.isEmpty)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 8),
                            child: Text(
                              'Tidak ada extra aktif untuk produk ini. Catatan tetap dapat disimpan.',
                            ),
                          ),
                        ...groups.map((group) {
                          final items =
                              (group['items'] as List?)
                                  ?.whereType<Map>()
                                  .map((row) => Map<String, Object?>.from(row))
                                  .toList() ??
                              const [];
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                group['group_name']?.toString() ?? 'Extra',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                '${group['is_required'] == 1 ? 'Wajib' : 'Opsional'} | maksimal ${group['max_select'] ?? 1}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              ...items.map((item) {
                                final id = _asInt(item['extra_id']);
                                return CheckboxListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  value: selected.containsKey(id),
                                  onChanged: (_) {
                                    setDialogState(() {
                                      if (selected.containsKey(id)) {
                                        selected.remove(id);
                                      } else {
                                        selected[id] = CartExtra(
                                          extraId: id,
                                          name:
                                              item['extra_name']?.toString() ??
                                              '-',
                                          qty: 1,
                                          unitPrice: _asDouble(
                                            item['selling_price'],
                                          ),
                                        );
                                      }
                                    });
                                  },
                                  title: Text(
                                    item['extra_name']?.toString() ?? '-',
                                  ),
                                  subtitle: Text(
                                    _money.format(
                                      _asDouble(item['selling_price']),
                                    ),
                                  ),
                                );
                              }),
                              const Divider(),
                            ],
                          );
                        }),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Batal'),
                  ),
                  FilledButton(
                    onPressed: () {
                      for (final group in groups) {
                        final items =
                            (group['items'] as List?)
                                ?.whereType<Map>()
                                .toList() ??
                            const [];
                        final count =
                            items
                                .where(
                                  (item) => selected.containsKey(
                                    _asInt(item['extra_id']),
                                  ),
                                )
                                .length;
                        final min = _asInt(group['min_select']);
                        final max = _asInt(group['max_select']);
                        if ((group['is_required'] == 1 && count == 0) ||
                            count < min ||
                            (max > 0 && count > max)) {
                          _showMessage(
                            'Pilihan extra pada ${group['group_name'] ?? 'group'} belum valid.',
                          );
                          return;
                        }
                      }
                      Navigator.pop(
                        context,
                        _ProductCustomization(
                          qty: quantity,
                          extras: selected.values.toList(),
                          note: noteController.text.trim(),
                        ),
                      );
                    },
                    child: const Text('Simpan ke keranjang'),
                  ),
                ],
              );
            },
          ),
    );
    // Let the dialog route finish releasing focus/semantics before disposing
    // the controller. This avoids Flutter widget-tree errors after typing a
    // product note and tapping "Simpan ke keranjang".
    await Future<void>.delayed(Duration.zero);
    noteController.dispose();
    return result;
  }

  void _changeQty(int cartKey, int delta) {
    final savedLine = _cart[cartKey];
    if (_editingOrderId > 0 && (savedLine?.orderLineId ?? 0) > 0 && delta < 0) {
      _showMessage(
        'Item yang sudah tersimpan tidak dapat dihapus dari edit. Gunakan Void.',
      );
      return;
    }
    setState(() {
      final existing = _cart[cartKey];
      if (existing == null) {
        return;
      }
      final nextQty = existing.qty + delta;
      if (nextQty <= 0) {
        _cart.remove(cartKey);
      } else {
        _cart[cartKey] = existing.copyWith(qty: nextQty);
      }
    });
  }

  int _nextCartKey() {
    var key = 1;
    while (_cart.containsKey(key)) {
      key++;
    }
    return key;
  }

  int _nextBundleGroupId() {
    var groupId = 1;
    while (_cart.values.any((line) => line.bundleGroupId == groupId)) {
      groupId++;
    }
    return groupId;
  }

  void _changeBundleQty(List<int> keys, int delta) {
    if (_editingOrderId > 0 &&
        delta < 0 &&
        keys.any((key) => (_cart[key]?.orderLineId ?? 0) > 0)) {
      _showMessage(
        'Bundle tersimpan tidak dapat dihapus dari edit. Gunakan Void.',
      );
      return;
    }
    setState(() {
      for (final key in keys) {
        final line = _cart[key];
        if (line == null) continue;
        final nextQty = line.qty + delta;
        if (nextQty <= 0) {
          _cart.remove(key);
        } else {
          _cart[key] = line.copyWith(qty: nextQty);
        }
      }
    });
  }

  Future<int> _saveOrder({required bool confirmOrder}) async {
    if (_session?.isOpen != true) {
      _showMessage('Order belum dapat disimpan. Buka kasir terlebih dahulu.');
      return 0;
    }
    if (_cart.isEmpty) {
      _showMessage('Keranjang masih kosong.');
      return 0;
    }

    final lines = _cart.values.toList();
    final total = lines.fold<double>(0, (sum, line) => sum + line.total);
    final payload = {
      'source': 'ANDROID_APK',
      'mode': 'UPSERT_DRAFT',
      'outlet_id': widget.settings.outletId,
      'terminal_id': widget.settings.terminalId,
      'terminal_device_key': widget.settings.terminalDeviceKey,
      'cashier_session_id': _session?.sessionId,
      'shift_id': _session?.shiftId,
      'ordered_at': DateTime.now().toIso8601String(),
      'order_channel': _serviceType,
      'service_type': _serviceType,
      'customer_name': _customerController.text.trim(),
      'member_id': _selectedMember?.id,
      'member_name': _selectedMember?.name,
      'guest_count': int.tryParse(_guestController.text.trim()) ?? 1,
      'sales_channel_id': _salesChannelId > 0 ? _salesChannelId : null,
      'table_no': _tableController.text.trim(),
      'notes': _noteController.text.trim(),
      'status': 'DRAFT',
      'payment_status': 'UNPAID',
      'confirm_order': confirmOrder,
      'subtotal': total,
      'grand_total': total,
      'lines': [
        for (var i = 0; i < lines.length; i++) lines[i].toOrderJson(i + 1),
      ],
      if (_editingOrderId > 0) 'id': _editingOrderId,
    };

    final uuid = await _db.enqueueLocalOrder(
      payload,
      eventType: confirmOrder ? 'ORDER_CONFIRM' : 'ORDER_UPSERT',
    );
    if (_sync.online) {
      await _runSync();
    } else {
      // Saving offline must be immediate. The foreground/background sync will
      // deliver this idempotent event when a server connection returns.
      unawaited(_runSync(silent: true));
    }
    final pending = await _db.pendingOutboxCount();
    final local = await _db.localOrder(uuid);
    final localSyncStatus = local?['sync_status']?.toString() ?? 'PENDING';
    if (!mounted) {
      return 0;
    }
    setState(() {
      _cart.clear();
      _customerController.clear();
      _tableController.clear();
      _guestController.text = '1';
      _noteController.clear();
      _selectedMember = null;
      _memberSuggestions = const [];
      _editingOrderId = 0;
      _editingOrderNo = '';
    });
    _showMessage(
      localSyncStatus == 'BLOCKED'
          ? '${confirmOrder ? 'Order aktif' : 'Draft'} tersimpan di perangkat. Server belum menerima; buka shift atau perbaiki data lalu tekan Sinkron sekarang.'
          : pending == 0
          ? 'Order ${confirmOrder ? 'terkonfirmasi dan ' : ''}sudah sinkron: $uuid'
          : 'Order masuk outbox. $pending event menunggu sinkron.',
    );
    _activeOrdersKey.currentState?._load();
    return _asInt(local?['server_id']);
  }

  Future<void> _startOrderAppend(Map<String, Object?>? row) async {
    if (_cart.isNotEmpty) {
      _showMessage(
        'Selesaikan atau kosongkan keranjang saat ini terlebih dahulu.',
      );
      return;
    }
    final orderId = _asInt(row?['id']);
    if (row != null && orderId <= 0) {
      _showMessage(
        'Order lokal belum memiliki ID server. Sinkronkan dulu sebelum menambah item.',
      );
      return;
    }
    Map<String, Object?> header = row ?? const {};
    Map<int, CartLine> restored = const {};
    if (orderId > 0) {
      try {
        final response = await _api.orderLoad(orderId);
        header =
            (response['header'] as Map?)?.cast<String, Object?>() ?? header;
        restored = _cartLinesFromServer(response['lines'] as List?);
      } catch (error) {
        _showMessage('Order belum dapat dimuat: ${_friendlyError(error)}');
        return;
      }
    }
    final member = _memberFromOrderHeader(header);
    setState(() {
      _cart
        ..clear()
        ..addAll(restored);
      _editingOrderId = orderId;
      _editingOrderNo =
          header['order_no']?.toString() ?? row?['order_no']?.toString() ?? '';
      _customerController.text =
          header['customer_name']?.toString() ??
          header['member_name']?.toString() ??
          row?['customer_display_name']?.toString() ??
          '';
      _guestController.text =
          '${_asInt(header['guest_count']) <= 0 ? 1 : _asInt(header['guest_count'])}';
      _tableController.text = header['table_no']?.toString() ?? '';
      _noteController.text = header['notes']?.toString() ?? '';
      _serviceType = header['service_type']?.toString() ?? 'DINE_IN';
      _salesChannelId = _asInt(header['sales_channel_id']);
      _selectedMember = member;
      _memberSuggestions = const [];
    });
    _showMessage(
      orderId > 0
          ? 'Mode tambah item untuk ${_editingOrderNo.isEmpty ? 'order aktif' : _editingOrderNo}.'
          : 'Order baru siap dibuat.',
    );
  }

  MemberItem? _memberFromOrderHeader(Map<String, Object?> header) {
    final id = _asInt(header['member_id']);
    if (id <= 0) return null;
    return MemberItem(
      id: id,
      memberNo: header['member_no']?.toString() ?? '-',
      name:
          header['member_name']?.toString() ??
          header['customer_name']?.toString() ??
          '-',
      phone:
          header['member_phone']?.toString() ??
          header['mobile_phone']?.toString() ??
          '-',
      tier: header['member_tier']?.toString() ?? '-',
      pointBalance: _asDouble(
        header['member_point_balance'] ?? header['point_balance_cache'],
      ),
      stampBalance: _asDouble(
        header['member_stamp_balance'] ?? header['stamp_balance_cache'],
      ),
    );
  }

  Map<int, CartLine> _cartLinesFromServer(List? rawLines) {
    final cachedById = <int, ProductItem>{
      for (final product in _products) product.id: product,
    };
    final restored = <int, CartLine>{};
    for (var index = 0; index < (rawLines ?? const []).length; index++) {
      final raw = rawLines![index];
      if (raw is! Map) continue;
      final line = Map<String, Object?>.from(raw);
      final productId = _asInt(line['product_id']);
      final cached = cachedById[productId];
      final product = ProductItem(
        id: productId,
        code: line['product_code']?.toString() ?? cached?.code ?? '-',
        name: line['product_name']?.toString() ?? cached?.name ?? '-',
        divisionName:
            line['product_division_name']?.toString() ??
            cached?.divisionName ??
            '-',
        price: _asDouble(line['unit_price'] ?? cached?.price),
        availabilityStatus: cached?.availabilityStatus ?? 'UNKNOWN',
        estimatedAvailableQty: cached?.estimatedAvailableQty ?? 0,
        photoUrl: cached?.photoUrl ?? '',
        divisionId: cached?.divisionId ?? 0,
        categoryId: cached?.categoryId ?? 0,
      );
      final extras =
          (line['extras'] as List? ?? const [])
              .whereType<Map>()
              .map(
                (extra) => CartExtra(
                  extraId: _asInt(extra['extra_id'] ?? extra['id']),
                  name: extra['extra_name']?.toString() ?? '-',
                  qty:
                      _asDouble(extra['qty']) <= 0
                          ? 1
                          : _asDouble(extra['qty']),
                  unitPrice: _asDouble(extra['unit_price']),
                  notes: extra['notes']?.toString() ?? '',
                ),
              )
              .toList();
      final bundleId = _asInt(line['bundle_id']);
      var bundleName = line['bundle_name']?.toString() ?? '';
      if (bundleName.isEmpty && bundleId > 0) {
        for (final bundle in _bundles) {
          if (bundle.id == bundleId) {
            bundleName = bundle.name;
            break;
          }
        }
      }
      var key = bundleId > 0 ? -((bundleId * 1000) + index + 1) : productId;
      while (restored.containsKey(key)) {
        key -= 1000000;
      }
      restored[key] = CartLine(
        product: product,
        qty: _asInt(line['qty']) <= 0 ? 1 : _asInt(line['qty']),
        notes: line['notes']?.toString() ?? '',
        extras: extras,
        bundleId: bundleId,
        bundleName: bundleName,
        bundleGroupId: bundleId,
        orderLineId: _asInt(line['id'] ?? line['order_line_id']),
      );
    }
    return restored;
  }

  Future<void> _openOrderWorkspace() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OrderWorkspaceScreen(settings: widget.settings),
      ),
    );
    if (mounted) _runSync(silent: true);
  }

  void _openPrinterSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => PrinterSettingsScreen(
              settings: widget.settings,
              settingsStore: widget.settingsStore,
              onAuthExpired: _expireLogin,
            ),
      ),
    );
  }

  Future<void> _openIncomingOrders() async {
    final channel = await showModalBottomSheet<IncomingOrderChannel>(
      context: context,
      showDragHandle: true,
      builder:
          (sheetContext) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ListTile(
                  title: Text('Order masuk'),
                  subtitle: Text('Pilih kanal yang ingin diverifikasi'),
                ),
                ListTile(
                  leading: const Icon(Icons.event_available_outlined),
                  title: const Text('Reservasi'),
                  onTap:
                      () => Navigator.pop(
                        sheetContext,
                        IncomingOrderChannel.reservation,
                      ),
                ),
                ListTile(
                  leading: const Icon(Icons.qr_code_2_outlined),
                  title: const Text('Self-order'),
                  onTap:
                      () => Navigator.pop(
                        sheetContext,
                        IncomingOrderChannel.selfOrder,
                      ),
                ),
                ListTile(
                  leading: const Icon(Icons.delivery_dining_outlined),
                  title: const Text('Order online'),
                  onTap:
                      () => Navigator.pop(
                        sheetContext,
                        IncomingOrderChannel.onlineFood,
                      ),
                ),
              ],
            ),
          ),
    );
    if (channel == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => IncomingOrdersScreen(
              settings: widget.settings,
              channel: channel,
            ),
      ),
    );
    if (mounted) _runSync(silent: true);
  }

  Future<void> _dispatchPendingConfirmationPrints({
    required bool silent,
  }) async {
    final orderIds = await _db.pendingConfirmationPrintOrders();
    for (final orderId in orderIds) {
      try {
        final response = await _api.orderConfirmPrintTargets(orderId);
        final targets = (response['direct_print_targets'] as List?) ?? const [];
        if (targets.isEmpty) {
          await _db.markConfirmationPrintComplete(orderId);
          continue;
        }
        final result = await _printDispatcher.printTargets(
          targets.whereType<Map>(),
        );
        if (result.printed > 0) {
          // A retry would re-send successful targets and can duplicate a
          // kitchen ticket. Leave partial failures for a deliberate Reprint.
          await _db.markConfirmationPrintComplete(orderId);
          if (result.hasProblem && !silent) {
            _showMessage(
              'Order #$orderId sudah tersinkron. Sebagian cetak perlu diperiksa lalu gunakan Cetak Ulang bila diperlukan.',
            );
          }
          continue;
        }
        await _db.postponeConfirmationPrint(orderId, result.message);
        if (!silent) {
          _showMessage(
            'Order #$orderId sudah tersinkron; tiket menunggu printer. Hubungkan printer lalu sinkronkan kembali.',
          );
        }
      } catch (error) {
        await _db.postponeConfirmationPrint(orderId, _friendlyError(error));
        if (!silent) {
          _showMessage(
            'Order #$orderId tersinkron, tetapi tiket belum dapat disiapkan. Sistem akan mencoba lagi.',
          );
        }
      }
    }
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

  Future<void> _refreshLocalDraftCount() async {
    final rows = await _db.localDraftOrders();
    if (mounted && rows.length != _localDraftCount) {
      setState(() => _localDraftCount = rows.length);
    }
  }

  Future<void> _deleteFailedLocalOrder(Map<String, Object?> row) async {
    final localUuid = row['local_uuid']?.toString().trim() ?? '';
    if (localUuid.isEmpty || _asInt(row['id']) > 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            icon: Icon(
              Icons.delete_sweep_outlined,
              color: Colors.red.shade700,
              size: 34,
            ),
            title: const Text('Hapus order gagal?'),
            content: const Text(
              'Order lokal ini dan antrean sinkronnya akan dihapus dari perangkat. Data yang sudah tersimpan di server tidak ikut terhapus.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Batal'),
              ),
              FilledButton.tonal(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Hapus order'),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    await _db.deleteLocalOrder(localUuid);
    await _refreshLocalDraftCount();
    await _activeOrdersKey.currentState?._load();
    if (mounted) _showMessage('Order gagal dihapus dari perangkat.');
  }

  Future<void> _openLocalDrafts() async {
    final rows = await _db.localDraftOrders();
    if (!mounted) return;
    _modalActive = true;
    Map<String, Object?>? selected;
    try {
      selected = await showDialog<Map<String, Object?>>(
        context: context,
        builder:
            (dialogContext) => AlertDialog(
              title: const Text('Draft lokal'),
              content: SizedBox(
                width: 520,
                height: 420,
                child:
                    rows.isEmpty
                        ? const Center(child: Text('Belum ada draft lokal.'))
                        : ListView.separated(
                          itemCount: rows.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final row = rows[index];
                            Map<String, Object?> payload = const {};
                            try {
                              final decoded = jsonDecode(
                                row['payload']?.toString() ?? '{}',
                              );
                              if (decoded is Map) {
                                payload = Map<String, Object?>.from(decoded);
                              }
                            } catch (_) {}
                            final customer =
                                payload['customer_name']?.toString().trim() ??
                                '';
                            final localUuid =
                                row['local_uuid']?.toString() ?? '-';
                            return ListTile(
                              leading: const Icon(Icons.drafts_outlined),
                              title: Text(
                                row['order_no']?.toString().isNotEmpty == true
                                    ? row['order_no'].toString()
                                    : 'Draft ${localUuid.substring(0, localUuid.length > 12 ? 12 : localUuid.length)}',
                              ),
                              subtitle: Text(
                                '${customer.isEmpty ? 'Walk-in' : customer} | ${row['status'] ?? 'LOCAL_DRAFT'}\n${_money.format(_asDouble(payload['grand_total']))}',
                              ),
                              isThreeLine: true,
                              onTap: () => Navigator.pop(dialogContext, row),
                              trailing: IconButton(
                                tooltip: 'Hapus dari perangkat',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () async {
                                  final localUuid =
                                      row['local_uuid']?.toString() ?? '';
                                  if (localUuid.isEmpty) return;
                                  final confirmed = await showDialog<bool>(
                                    context: dialogContext,
                                    builder:
                                        (confirmContext) => AlertDialog(
                                          title: const Text(
                                            'Hapus draft lokal?',
                                          ),
                                          content: const Text(
                                            'Draft ini dihapus dari perangkat dan antrean sinkronisasi. Data yang sudah menjadi order resmi server tidak ikut dihapus.',
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed:
                                                  () => Navigator.pop(
                                                    confirmContext,
                                                    false,
                                                  ),
                                              child: const Text('Batal'),
                                            ),
                                            FilledButton(
                                              onPressed:
                                                  () => Navigator.pop(
                                                    confirmContext,
                                                    true,
                                                  ),
                                              child: const Text('Hapus'),
                                            ),
                                          ],
                                        ),
                                  );
                                  if (confirmed != true) return;
                                  await _db.deleteLocalOrder(localUuid);
                                  if (dialogContext.mounted) {
                                    Navigator.pop(dialogContext);
                                  }
                                  await _refreshLocalDraftCount();
                                  _showMessage('Draft dihapus dari perangkat.');
                                },
                              ),
                            );
                          },
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
    } finally {
      _modalActive = false;
    }
    if (selected != null) await _restoreLocalDraft(selected);
  }

  Future<void> _restoreLocalDraft(Map<String, Object?> row) async {
    if (_cart.isNotEmpty) {
      _showMessage('Kosongkan keranjang saat ini sebelum membuka draft.');
      return;
    }
    try {
      final decoded = jsonDecode(row['payload']?.toString() ?? '{}');
      if (decoded is! Map) throw const FormatException();
      final payload = Map<String, Object?>.from(decoded);
      final rawLines = payload['lines'];
      if (rawLines is! List || rawLines.isEmpty) {
        _showMessage('Draft tidak memiliki item yang dapat dipulihkan.');
        return;
      }
      final cachedById = <int, ProductItem>{
        for (final product in _products) product.id: product,
      };
      final restored = <int, CartLine>{};
      for (var index = 0; index < rawLines.length; index++) {
        final raw = rawLines[index];
        if (raw is! Map) continue;
        final line = Map<String, Object?>.from(raw);
        final productId = _asInt(line['product_id']);
        final cached = cachedById[productId];
        final product = ProductItem(
          id: productId,
          code: line['product_code']?.toString() ?? cached?.code ?? '-',
          name: line['product_name']?.toString() ?? cached?.name ?? '-',
          divisionName: cached?.divisionName ?? '-',
          price: _asDouble(line['unit_price'] ?? cached?.price),
          availabilityStatus: cached?.availabilityStatus ?? 'UNKNOWN',
          photoUrl: cached?.photoUrl ?? '',
          divisionId: cached?.divisionId ?? 0,
          categoryId: cached?.categoryId ?? 0,
          estimatedAvailableQty: cached?.estimatedAvailableQty ?? 0,
        );
        final rawExtras = line['extras'];
        final extras =
            rawExtras is List
                ? rawExtras.whereType<Map>().map((extra) {
                  final item = Map<String, Object?>.from(extra);
                  return CartExtra(
                    extraId: _asInt(item['extra_id']),
                    name: item['extra_name']?.toString() ?? '-',
                    qty:
                        _asDouble(item['qty']) < 1 ? 1 : _asDouble(item['qty']),
                    unitPrice: _asDouble(item['unit_price']),
                    notes: item['notes']?.toString() ?? '',
                  );
                }).toList()
                : const <CartExtra>[];
        final bundleId = _asInt(line['bundle_id']);
        var key = bundleId > 0 ? -((bundleId * 1000) + index + 1) : product.id;
        while (restored.containsKey(key)) {
          key -= 1000000;
        }
        restored[key] = CartLine(
          product: product,
          qty: _asInt(line['qty']) <= 0 ? 1 : _asInt(line['qty']),
          notes: line['notes']?.toString() ?? '',
          extras: extras,
          bundleId: bundleId,
          bundleName: line['bundle_name']?.toString() ?? '',
          bundleGroupId: bundleId,
          orderLineId: _asInt(line['order_line_id'] ?? line['id']),
        );
      }
      if (restored.isEmpty) {
        _showMessage('Draft tidak memiliki item yang valid.');
        return;
      }
      setState(() {
        _cart
          ..clear()
          ..addAll(restored);
        _customerController.text = payload['customer_name']?.toString() ?? '';
        _guestController.text =
            '${_asInt(payload['guest_count']) <= 0 ? 1 : _asInt(payload['guest_count'])}';
        _tableController.text = payload['table_no']?.toString() ?? '';
        _noteController.text = payload['notes']?.toString() ?? '';
        _serviceType = payload['service_type']?.toString() ?? 'DINE_IN';
        _selectedMember = null;
        _memberSuggestions = const [];
      });
      _showMessage('Draft berhasil dibuka kembali ke keranjang.');
    } catch (_) {
      _showMessage('Draft tidak dapat dibaca. Data lokal tetap tersimpan.');
    }
  }

  void _onSearchChanged(String value) {
    setState(() {});
    _catalogSearchTimer?.cancel();
    final query = value.trim();
    _catalogSearchTimer = Timer(
      const Duration(milliseconds: 350),
      () => _fetchRemoteCatalog(query),
    );
  }

  Future<void> _fetchRemoteCatalog(String query) async {
    if (!mounted) return;
    // Bundles must be loaded when the tab opens, even without a search term.
    // A fresh install has no local bundle cache to fall back to.
    if (_catalogMode != 'BUNDLE' && query.isEmpty && _divisionId == 0) {
      setState(() {
        _remoteProducts = const [];
        _remoteBundles = const [];
      });
      return;
    }
    setState(() => _catalogBusy = true);
    try {
      final response = await _api.catalog(
        query: query,
        mode: _catalogMode,
        divisionId: _divisionId,
        limit: 120,
      );
      final rawRows = response['rows'];
      final rows =
          rawRows is List
              ? rawRows
              : rawRows is Map && rawRows['rows'] is List
              ? rawRows['rows'] as List
              : const [];
      if (_catalogMode == 'BUNDLE') {
        final bundles =
            rows
                .whereType<Map>()
                .map(
                  (row) => BundleItem.fromJson(Map<String, Object?>.from(row)),
                )
                .toList();
        if (mounted) setState(() => _remoteBundles = bundles);
      } else {
        final products =
            rows
                .whereType<Map>()
                .map(
                  (row) => ProductItem.fromJson(Map<String, Object?>.from(row)),
                )
                .toList();
        if (mounted) setState(() => _remoteProducts = products);
      }
    } catch (error) {
      if (mounted && query.isNotEmpty) {
        _showMessage('Pencarian server gagal: ${_friendlyError(error)}');
      }
    } finally {
      if (mounted) setState(() => _catalogBusy = false);
    }
  }

  void _selectDivision(int divisionId) {
    setState(() {
      _divisionId = divisionId;
      _catalogMode = 'PRODUCT';
      _remoteProducts = const [];
      _remoteBundles = const [];
    });
    _catalogSearchTimer?.cancel();
    _fetchRemoteCatalog(_searchController.text.trim());
  }

  void _selectCatalogMode(String mode) {
    setState(() {
      _catalogMode = mode;
      _remoteProducts = const [];
      _remoteBundles = const [];
    });
    _catalogSearchTimer?.cancel();
    _fetchRemoteCatalog(_searchController.text.trim());
  }

  Future<void> _addBundleById(int bundleId) async {
    if (_session?.isOpen != true) {
      _showMessage('Buka kasir terlebih dahulu sebelum menambah order.');
      return;
    }
    final source = _remoteBundles.isNotEmpty ? _remoteBundles : _bundles;
    BundleItem? bundle;
    for (final item in source) {
      if (item.id == bundleId) {
        bundle = item;
        break;
      }
    }
    if (bundle == null || bundle.items.isEmpty) {
      _showMessage('Komponen bundle belum tersedia dari server.');
      return;
    }
    if (bundle.availabilityStatus.toUpperCase() == 'OUT') {
      _showMessage('Bundle sedang tidak tersedia.');
      return;
    }
    _modalActive = true;
    int? selectedQuantity;
    var quantity = 1;
    try {
      selectedQuantity = await showDialog<int>(
        context: context,
        builder:
            (dialogContext) => StatefulBuilder(
              builder: (dialogContext, setDialogState) {
                return AlertDialog(
                  title: Text(bundle!.name),
                  content: SizedBox(
                    width: 480,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Harga ${_money.format(bundle.price)}'),
                          Text(
                            'Tersedia ${bundle.estimatedAvailableQty.toStringAsFixed(0)} paket',
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'Jumlah paket',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                              IconButton(
                                onPressed:
                                    quantity <= 1
                                        ? null
                                        : () =>
                                            setDialogState(() => quantity--),
                                icon: const Icon(Icons.remove_circle_outline),
                              ),
                              Text(
                                '$quantity',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 16,
                                ),
                              ),
                              IconButton(
                                onPressed:
                                    () => setDialogState(() => quantity++),
                                icon: const Icon(Icons.add_circle_outline),
                              ),
                            ],
                          ),
                          const Divider(),
                          ...bundle.items.map(
                            (item) => ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(item.name),
                              subtitle: Text(
                                '${item.code} | Qty ${item.qty} | ${item.availabilityStatus}',
                              ),
                              trailing: Text(_money.format(item.unitPrice)),
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
                    FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, quantity),
                      child: const Text('Tambah ke keranjang'),
                    ),
                  ],
                );
              },
            ),
      );
    } finally {
      _modalActive = false;
    }
    if (!mounted || selectedQuantity == null || selectedQuantity <= 0) return;
    final quantityToAdd = selectedQuantity;
    final bundleGroupId =
        _editingOrderId > 0 ? _nextBundleGroupId() : bundle.id;
    setState(() {
      for (var index = 0; index < bundle!.items.length; index++) {
        final item = bundle.items[index];
        final product = ProductItem(
          id: item.productId,
          code: item.code,
          name: item.name,
          divisionName: item.divisionName,
          price: item.unitPrice,
          availabilityStatus: item.availabilityStatus,
          estimatedAvailableQty: item.estimatedAvailableQty,
          divisionId: item.divisionId,
        );
        var cartKey = -((bundle.id * 1000) + index + 1);
        if (_editingOrderId > 0) {
          while (_cart.containsKey(cartKey)) {
            cartKey -= 1000000;
          }
        }
        final existing = _editingOrderId > 0 ? null : _cart[cartKey];
        _cart[cartKey] =
            existing == null
                ? CartLine(
                  product: product,
                  qty: item.qty.round() * quantityToAdd,
                  bundleId: bundle.id,
                  bundleName: bundle.name,
                  bundleGroupId: bundleGroupId,
                )
                : existing.copyWith(
                  qty: existing.qty + item.qty.round() * quantityToAdd,
                );
      }
    });
  }

  void _onCustomerChanged(String value) {
    final query = value.trim();
    if (_selectedMember != null &&
        query != _selectedMember!.name.trim().toLowerCase()) {
      setState(() => _selectedMember = null);
    }
    _memberSearchTimer?.cancel();
    final request = ++_memberSearchRequest;
    if (query.length < 2) {
      setState(() {
        _memberSuggestions = const [];
        _memberSearchBusy = false;
      });
      return;
    }
    setState(() => _memberSearchBusy = true);
    _memberSearchTimer = Timer(
      const Duration(milliseconds: 350),
      () => _searchMembersInline(query, request),
    );
  }

  Future<void> _searchMembersInline(String query, int request) async {
    try {
      final response = await _api.memberSearch(query);
      final values = (response['rows'] as List?) ?? const [];
      final rows =
          values
              .whereType<Map>()
              .map((row) => MemberItem.fromJson(Map<String, Object?>.from(row)))
              .toList();
      if (!mounted || request != _memberSearchRequest) return;
      setState(() {
        _memberSuggestions = rows.take(5).toList();
        _memberSearchBusy = false;
        _selectedMember = null;
      });
    } catch (error) {
      if (!mounted || request != _memberSearchRequest) return;
      setState(() {
        _memberSuggestions = const [];
        _memberSearchBusy = false;
        _selectedMember = null;
      });
      _showMessage('Pencarian member gagal: ${_friendlyError(error)}');
    }
  }

  Future<void> _toggleShift() async {
    if (_session == null) {
      final bootstrap = await _syncService.cashierBootstrapFromCache();
      if (!mounted) return;
      final rawOutlets = bootstrap['outlets'];
      final rawTerminals = bootstrap['terminals'];
      final outlets =
          rawOutlets is List
              ? rawOutlets
                  .whereType<Map>()
                  .map((row) => Map<String, Object?>.from(row))
                  .where((row) => _asInt(row['id']) > 0)
                  .fold<List<Map<String, Object?>>>([], (items, row) {
                    if (!items.any(
                      (item) => _asInt(item['id']) == _asInt(row['id']),
                    )) {
                      items.add(row);
                    }
                    return items;
                  })
              : const <Map<String, Object?>>[];
      final terminals =
          rawTerminals is List
              ? rawTerminals
                  .whereType<Map>()
                  .map((row) => Map<String, Object?>.from(row))
                  .where((row) => _asInt(row['id']) > 0)
                  .fold<List<Map<String, Object?>>>([], (items, row) {
                    if (!items.any(
                      (item) => _asInt(item['id']) == _asInt(row['id']),
                    )) {
                      items.add(row);
                    }
                    return items;
                  })
              : const <Map<String, Object?>>[];
      final defaultOpeningCash =
          _asDouble(bootstrap['default_opening_cash']) > 0
              ? _asDouble(bootstrap['default_opening_cash'])
              : 300000;
      final openingController = TextEditingController(
        text: defaultOpeningCash.toStringAsFixed(0),
      );
      final form = await showDialog<Map<String, Object?>>(
        context: context,
        builder: (dialogContext) {
          var selectedOutlet = widget.settings.outletId;
          var selectedTerminal = widget.settings.terminalId;
          if (!outlets.any((row) => _asInt(row['id']) == selectedOutlet)) {
            selectedOutlet = _asInt(bootstrap['default_outlet_id']);
          }
          final initialTerminals =
              terminals
                  .where((row) => _asInt(row['outlet_id']) == selectedOutlet)
                  .toList();
          if (!initialTerminals.any(
            (row) => _asInt(row['id']) == selectedTerminal,
          )) {
            selectedTerminal =
                initialTerminals.isNotEmpty
                    ? _asInt(initialTerminals.first['id'])
                    : _asInt(bootstrap['default_terminal_id']);
          }
          return StatefulBuilder(
            builder:
                (dialogContext, setDialogState) => AlertDialog(
                  title: const Text('Buka kasir'),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DropdownButtonFormField<int>(
                          value:
                              outlets.any(
                                    (row) =>
                                        _asInt(row['id']) == selectedOutlet,
                                  )
                                  ? selectedOutlet
                                  : null,
                          items:
                              outlets
                                  .map(
                                    (row) => DropdownMenuItem<int>(
                                      value: _asInt(row['id']),
                                      child: Text(
                                        row['outlet_name']?.toString() ?? '-',
                                      ),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            final nextTerminals =
                                terminals
                                    .where(
                                      (row) =>
                                          _asInt(row['outlet_id']) == value,
                                    )
                                    .toList();
                            setDialogState(() {
                              selectedOutlet = value;
                              selectedTerminal =
                                  nextTerminals.isNotEmpty
                                      ? _asInt(nextTerminals.first['id'])
                                      : 0;
                            });
                          },
                          decoration: const InputDecoration(
                            labelText: 'Outlet',
                          ),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<int>(
                          value:
                              terminals.any(
                                    (row) =>
                                        _asInt(row['id']) == selectedTerminal &&
                                        _asInt(row['outlet_id']) ==
                                            selectedOutlet,
                                  )
                                  ? selectedTerminal
                                  : null,
                          items:
                              terminals
                                  .where(
                                    (row) =>
                                        _asInt(row['outlet_id']) ==
                                        selectedOutlet,
                                  )
                                  .map(
                                    (row) => DropdownMenuItem<int>(
                                      value: _asInt(row['id']),
                                      child: Text(
                                        row['terminal_name']?.toString() ??
                                            row['terminal_code']?.toString() ??
                                            '-',
                                      ),
                                    ),
                                  )
                                  .toList(),
                          onChanged:
                              (value) => setDialogState(
                                () => selectedTerminal = value ?? 0,
                              ),
                          decoration: const InputDecoration(
                            labelText: 'Terminal',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: openingController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Modal awal',
                            prefixText: 'Rp ',
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
                      onPressed:
                          selectedOutlet <= 0 || selectedTerminal <= 0
                              ? null
                              : () => Navigator.pop(dialogContext, {
                                'outlet_id': selectedOutlet,
                                'terminal_id': selectedTerminal,
                                'opening_cash': _asDouble(
                                  openingController.text,
                                ),
                              }),
                      child: const Text('Buka shift'),
                    ),
                  ],
                ),
          );
        },
      );
      openingController.dispose();
      if (form == null) return;
      final outletId = _asInt(form['outlet_id']);
      final terminalId = _asInt(form['terminal_id']);
      final openingCash = _asDouble(form['opening_cash']);
      try {
        final response = await _api.cashierOpen(
          openingCash: openingCash,
          outletId: outletId,
          terminalId: terminalId,
        );
        final rawSession = response['session'];
        final cachedSession =
            rawSession is Map
                ? (Map<String, Object?>.from(rawSession)
                  ..['backup_mode'] = response['backup_mode'] == true
                  ..['owner_terminal_id'] = _asInt(
                    response['owner_terminal_id'],
                  )
                  ..['origin_terminal_id'] = _asInt(
                    response['origin_terminal_id'],
                  ))
                : null;
        final openedSession =
            cachedSession == null
                ? null
                : CashierSession.fromJson(cachedSession);
        if (openedSession != null) {
          await _db.saveMasterCache('cashier_session', {
            'session': cachedSession,
            'active_sessions': [cachedSession],
          });
          if (mounted) setState(() => _session = openedSession);
        }
        await widget.settingsStore.save(
          widget.settings.copyWith(outletId: outletId, terminalId: terminalId),
        );
        _showMessage(
          response['attached_to_existing_session'] == true
              ? 'APK terhubung sebagai backup ke sesi kasir yang sedang aktif.'
              : 'Kasir berhasil dibuka.',
        );
        await _runSync();
      } catch (error) {
        if (error is FinanceApiException && error.isUnauthorized) {
          await _expireLogin();
          return;
        }
        if (error is FinanceApiException) {
          final active = error.data['active_session'];
          if (active is Map) {
            final activeRow = Map<String, Object?>.from(active);
            if (mounted) {
              setState(() {
                _activeServerSessions = [
                  activeRow,
                  ..._activeServerSessions.where(
                    (row) =>
                        row['id']?.toString() != activeRow['id']?.toString(),
                  ),
                ];
              });
            }
            final cashier = activeRow['cashier_name']?.toString().trim();
            _showMessage(
              cashier == null || cashier.isEmpty
                  ? 'Terminal ini sedang dipakai sesi kasir lain. Pilih terminal lain atau ganti akun.'
                  : 'Terminal ini sedang dipakai kasir $cashier. Pilih terminal lain atau ganti akun.',
            );
            return;
          }
        }
        _showMessage('Gagal membuka kasir: ${_friendlyError(error)}');
      }
      return;
    }

    if (_session?.backupMode == true) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.devices_other_outlined),
          title: const Text('Tutup shift bersama?'),
          content: const Text(
            'APK ini sedang menjadi terminal backup. Menutup kasir di sini juga akan menutup sesi yang sedang dipakai POS web. Lanjutkan hanya bila seluruh transaksi sudah selesai.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Tetap buka'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Lanjut tutup shift'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    Map<String, Object?> report = const {};
    try {
      final preview = await _api.cashierClosePreview();
      report = (preview['report'] as Map?)?.cast<String, Object?>() ?? const {};
    } catch (error) {
      if (error is FinanceApiException && error.isUnauthorized) {
        await _expireLogin();
        return;
      }
      _showMessage('Preview tutup kasir gagal: ${_friendlyError(error)}');
      return;
    }

    final summary =
        (report['summary'] as Map?)?.cast<String, Object?>() ?? const {};
    if (!mounted) return;
    final controller = TextEditingController(
      text: _asDouble(summary['expected_cash']).toStringAsFixed(0),
    );
    const denominations = [100000, 50000, 20000, 10000, 5000, 2000, 1000];
    final denominationControllers = {
      for (final denomination in denominations)
        denomination: TextEditingController(text: '0'),
    };
    final actualCash = await showDialog<double>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Tutup kasir'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Modal awal: ${_moneyText(_asDouble(summary['opening_cash']))}',
                  ),
                  Text(
                    'Penjualan tunai: ${_moneyText(_asDouble(summary['total_cash_sales']))}',
                  ),
                  Text(
                    'Penjualan non-tunai: ${_moneyText(_asDouble(summary['total_non_cash_sales']))}',
                  ),
                  Text(
                    'Kas yang diharapkan: ${_moneyText(_asDouble(summary['expected_cash']))}',
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Hitung dari pecahan (opsional)',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final denomination in denominations)
                        SizedBox(
                          width: 108,
                          child: TextField(
                            controller: denominationControllers[denomination],
                            keyboardType: TextInputType.number,
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                              labelText: 'Rp ${denomination ~/ 1000}k',
                              isDense: true,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Builder(
                    builder: (context) {
                      final counted = denominations.fold<double>(
                        0,
                        (total, denomination) =>
                            total +
                            (_asDouble(
                                  denominationControllers[denomination]?.text,
                                ) *
                                denomination),
                      );
                      return Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Total pecahan: ${_moneyText(counted)}',
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              controller.text = counted.toStringAsFixed(0);
                              setState(() {});
                            },
                            child: const Text('Pakai total'),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: controller,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Kas aktual',
                      prefixText: 'Rp ',
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
                onPressed:
                    () => Navigator.pop(
                      dialogContext,
                      _asDouble(controller.text),
                    ),
                child: const Text('Tutup shift'),
              ),
            ],
          ),
    );
    controller.dispose();
    for (final denominationController in denominationControllers.values) {
      denominationController.dispose();
    }
    if (actualCash == null) return;
    final proof = await requestSensitiveActionProof(
      context,
      title: 'Verifikasi tutup kasir',
      description:
          'Tutup kasir akan mengakhiri sesi yang juga dipakai POS web. Masukkan password Anda untuk melanjutkan.',
      confirmLabel: 'Verifikasi & tutup',
      verify: (password) => _api.cashierCloseStepUpVerify(password: password),
    );
    if (proof == null) return;
    try {
      final result = await _api.cashierClose(
        actualCash: actualCash,
        stepUpProof: proof,
      );
      final summary = (result['summary'] as Map?) ?? const {};
      final printTargets =
          (result['direct_print_targets'] as List?) ?? const [];
      final printResult = await _printDispatcher.printTargets(
        printTargets.whereType<Map>(),
      );
      _showMessage(
        'Kasir berhasil ditutup. Variance: ${_moneyText(_asDouble(summary['variance_cash']))}',
      );
      await _showPrintOutcome(printResult, title: 'Cetak tutup kasir');
      await _db.saveMasterCache('cashier_session', {
        'session': null,
        'active_sessions': const [],
      });
      if (mounted) {
        setState(() {
          _session = null;
          _activeServerSessions = const [];
        });
      }
      await _runSync();
    } catch (error) {
      if (error is FinanceApiException && error.isUnauthorized) {
        await _expireLogin();
        return;
      }
      _showMessage('Gagal menutup kasir: ${_friendlyError(error)}');
    }
  }

  // Kept for compatibility with any future direct-payment entry point.
  // ignore: unused_element
  Future<void> _openPayment(int orderId) async {
    if (!_sync.online) {
      _showMessage('Payment membutuhkan koneksi ke server finance.');
      return;
    }
    try {
      final response = await _api.paymentPrepare(orderId);
      if (!mounted) return;
      final payment = Map<String, Object?>.from(response['payment'] as Map);
      _modalActive = true;
      Map<String, Object?>? result;
      try {
        result = await showDialog<Map<String, Object?>>(
          context: context,
          builder:
              (_) => _PaymentDialog(
                payment: payment,
                onVoucherSearch: (query) async {
                  final voucherResponse = await _api.voucherSearch(
                    orderId: orderId,
                    query: query,
                  );
                  return (voucherResponse['rows'] as List?)
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
      } finally {
        _modalActive = false;
      }
      if (result == null || !mounted) return;
      final change = _asDouble(result['change_total']);
      final loyalty = (result['loyalty'] as Map?) ?? const {};
      _showMessage(
        'Payment ${result['payment_no'] ?? ''} tersimpan.'
        '${change > 0 ? ' Kembalian ${_money.format(change)}.' : ''}'
        '${_asDouble(result['deposit_applied_amount']) > 0 ? ' Deposit terpakai ${_money.format(_asDouble(result['deposit_applied_amount']))}.' : ''}'
        '${_asDouble(loyalty['point_earned']) > 0 ? ' Poin bertambah ${_asDouble(loyalty['point_earned']).toStringAsFixed(0)}.' : ''}',
      );
      final printPayload = await _api.paymentPrintTargets(_asInt(result['id']));
      final targets =
          (printPayload['direct_print_targets'] as List?) ?? const [];
      final printResult = await _printDispatcher.printTargets(
        targets.whereType<Map>(),
      );
      await _showPrintOutcome(printResult, title: 'Cetak pembayaran');
      await _runSync(silent: true);
    } catch (error) {
      if (error is FinanceApiException && error.isUnauthorized) {
        await _expireLogin();
        return;
      }
      _showMessage('Payment gagal: ${_friendlyError(error)}');
    }
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => SetupScreen(
              initialSettings: widget.settings,
              settingsStore: widget.settingsStore,
              onSaved: () {
                Navigator.of(context).pop();
                widget.onOpenSetup();
              },
            ),
      ),
    );
  }

  Future<void> _expireLogin() async {
    if (_authRedirecting) return;
    _authRedirecting = true;
    await widget.settingsStore.save(
      widget.settings.copyWith(authToken: '', authExpiresAt: ''),
    );
    if (mounted) widget.onOpenSetup();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  double get _cartTotal =>
      _cart.values.fold(0, (sum, line) => sum + line.total);

  List<ProductItem> get _visibleProducts {
    final query = _searchController.text.trim().toLowerCase();
    var selectedDivisionName = '';
    for (final division in _divisions) {
      if (_asInt(division['id']) == _divisionId) {
        selectedDivisionName =
            division['name']?.toString().trim().toLowerCase() ?? '';
        break;
      }
    }
    if (_catalogMode == 'BUNDLE') {
      final bundles = _remoteBundles.isNotEmpty ? _remoteBundles : _bundles;
      return bundles
          .where((bundle) {
            final divisionMatches =
                _divisionId == 0 || bundle.divisionId == _divisionId;
            final queryMatches =
                query.isEmpty ||
                bundle.name.toLowerCase().contains(query) ||
                bundle.code.toLowerCase().contains(query) ||
                bundle.divisionName.toLowerCase().contains(query);
            return divisionMatches && queryMatches;
          })
          .map(
            (bundle) => ProductItem(
              id: -bundle.id,
              code: bundle.code,
              name: bundle.name,
              divisionName: bundle.divisionName,
              price: bundle.price,
              availabilityStatus: bundle.availabilityStatus,
              estimatedAvailableQty: bundle.estimatedAvailableQty,
              divisionId: bundle.divisionId,
              photoUrl: bundle.photoUrl,
            ),
          )
          .toList();
    }
    final cached =
        _products.where((product) {
          return _divisionId == 0 ||
              product.divisionId == _divisionId ||
              (selectedDivisionName.isNotEmpty &&
                  product.divisionName.trim().toLowerCase() ==
                      selectedDivisionName);
        }).toList();
    if (_remoteProducts.isNotEmpty) {
      return _remoteProducts;
    }
    if (query.isEmpty) return cached;
    return cached.where((product) {
      return product.name.toLowerCase().contains(query) ||
          product.code.toLowerCase().contains(query) ||
          product.divisionName.toLowerCase().contains(query);
    }).toList();
  }

  Future<String?> _cachedPhoto(
    ProductItem product, {
    bool refreshExisting = false,
  }) {
    final source = product.photoUrl.trim();
    if (source.isEmpty) return Future<String?>.value(null);
    return _photoFutures.putIfAbsent(
      source,
      () => _photoCache.cacheProductPhoto(
        backendUrl: widget.settings.normalizedBackendUrl,
        source: source,
        refreshExisting: refreshExisting,
      ),
    );
  }

  Widget _productImage(ProductItem product) {
    final fallback = Icon(
      _catalogMode == 'BUNDLE' ? Icons.inventory_2_outlined : Icons.local_cafe,
      size: 42,
      color: const Color(0xFF943F35),
    );
    if (product.photoUrl.trim().isEmpty) return fallback;
    return FutureBuilder<String?>(
      future: _cachedPhoto(product),
      builder: (context, snapshot) {
        final path = snapshot.data;
        if (path == null || path.isEmpty) {
          final url = _photoCache.resolveUrl(
            widget.settings.normalizedBackendUrl,
            product.photoUrl,
          );
          return Image.network(
            url,
            width: double.infinity,
            height: double.infinity,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => fallback,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return Center(
                child: SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    value:
                        progress.expectedTotalBytes == null
                            ? null
                            : progress.cumulativeBytesLoaded /
                                progress.expectedTotalBytes!,
                  ),
                ),
              );
            },
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(path),
            width: double.infinity,
            height: double.infinity,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => fallback,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('POS Kasir'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: _TopStatusBar(
            compact: true,
            sync: _sync,
            session: _session,
            activeServerSessions: _activeServerSessions,
            cashierName: widget.settings.username,
            onChangeAccount: widget.onOpenSetup,
            syncBusy: _busy,
            onSync: _runSync,
            localDraftCount: _localDraftCount,
            onOpenDrafts: _openLocalDrafts,
            onOpenSettings: _openSettings,
            onOpenPrinter: _openPrinterSettings,
            onOpenWorkspace: _openOrderWorkspace,
            onOpenIncoming: _openIncomingOrders,
            onToggleShift: _busy ? null : _toggleShift,
            shiftIcon: _session == null ? Icons.lock_open : Icons.lock_outline,
            shiftTooltip: _session == null ? 'Buka kasir' : 'Tutup kasir',
          ),
        ),
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= 980;
                    final activeOrders = _ActiveOrdersPanel(
                      key: _activeOrdersKey,
                      settings: widget.settings,
                      onOpenWorkspace: _openOrderWorkspace,
                      onAppendOrder: _startOrderAppend,
                      onRetryBlocked: _runSync,
                      onDeleteFailed: _deleteFailedLocalOrder,
                    );
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child:
                          wide
                              ? Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SizedBox(width: 260, child: activeOrders),
                                  const SizedBox(width: 12),
                                  Expanded(child: _productGrid()),
                                  const SizedBox(width: 12),
                                  SizedBox(width: 330, child: _cartPanel()),
                                ],
                              )
                              : Column(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: SegmentedButton<int>(
                                      showSelectedIcon: false,
                                      segments: [
                                        const ButtonSegment<int>(
                                          value: 0,
                                          icon: Icon(Icons.receipt_long_outlined),
                                          label: Text('Order'),
                                        ),
                                        const ButtonSegment<int>(
                                          value: 1,
                                          icon: Icon(Icons.grid_view_rounded),
                                          label: Text('Katalog'),
                                        ),
                                        ButtonSegment<int>(
                                          value: 2,
                                          icon: const Icon(Icons.shopping_bag_outlined),
                                          label: Text('Keranjang ${_cart.length}'),
                                        ),
                                      ],
                                      selected: {_compactPanel},
                                      onSelectionChanged: (selected) {
                                        setState(() => _compactPanel = selected.first);
                                      },
                                    ),
                                  ),
                                  Expanded(
                                    child: switch (_compactPanel) {
                                      0 => activeOrders,
                                      2 => _cartPanel(),
                                      _ => _productGrid(),
                                    },
                                  ),
                                ],
                              ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _productGrid() {
    final visibleProducts = _visibleProducts;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.restaurant_menu),
                const SizedBox(width: 8),
                Text(
                  _catalogMode == 'BUNDLE'
                      ? 'Produk Paket / Bundle'
                      : 'Produk POS',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                Text('${visibleProducts.length} item'),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              onTapOutside:
                  (_) => FocusManager.instance.primaryFocus?.unfocus(),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                suffixIcon:
                    _searchController.text.isEmpty
                        ? null
                        : IconButton(
                          tooltip: 'Bersihkan pencarian',
                          onPressed: () {
                            _searchController.clear();
                            setState(() {});
                          },
                          icon: const Icon(Icons.close),
                        ),
                hintText: 'Cari nama, kode, atau divisi produk',
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const SizedBox(height: 8),
            SizedBox(
              height: 42,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  ChoiceChip(
                    label: const Text('Semua'),
                    selected: _catalogMode == 'PRODUCT' && _divisionId == 0,
                    onSelected: (_) => _selectDivision(0),
                  ),
                  ..._divisions.map((division) {
                    final id = _asInt(division['id']);
                    return Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: ChoiceChip(
                        label: Text(division['name']?.toString() ?? '-'),
                        selected:
                            _catalogMode == 'PRODUCT' && _divisionId == id,
                        onSelected: (_) => _selectDivision(id),
                      ),
                    );
                  }),
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: ChoiceChip(
                      label: const Text('Paket / Bundle'),
                      selected: _catalogMode == 'BUNDLE',
                      onSelected: (_) => _selectCatalogMode('BUNDLE'),
                    ),
                  ),
                ],
              ),
            ),
            if (_catalogBusy)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            const SizedBox(height: 12),
            Expanded(
              child:
                  (_catalogMode == 'PRODUCT' && _products.isEmpty)
                      ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _sync.online
                                ? 'Belum ada produk dari server untuk outlet ini.'
                                : 'Katalog belum tersedia. Periksa backend mobile lalu sinkron ulang.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                      : visibleProducts.isEmpty
                      ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Produk tidak ditemukan.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                      : GridView.builder(
                        itemCount: visibleProducts.length,
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 180,
                              mainAxisSpacing: 10,
                              crossAxisSpacing: 10,
                              childAspectRatio: .86,
                            ),
                        itemBuilder: (context, index) {
                          final product = visibleProducts[index];
                          return InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap:
                                () =>
                                    _catalogMode == 'BUNDLE'
                                        ? _addBundleById(-product.id)
                                        : _addProduct(product),
                            child: Ink(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: const Color(0xFFE5D5CB),
                                ),
                                borderRadius: BorderRadius.circular(8),
                                color: Colors.white,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(10),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Container(
                                        width: double.infinity,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF3E6DC),
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: _productImage(product),
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      product.name,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    Text(
                                      product.divisionName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style:
                                          Theme.of(context).textTheme.bodySmall,
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            product.availabilityStatus
                                                        .toUpperCase() ==
                                                    'UNKNOWN'
                                                ? 'STOK BELUM SINKRON'
                                                : product.availabilityStatus
                                                    .toUpperCase(),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color:
                                                  product.availabilityStatus
                                                              .toUpperCase() ==
                                                          'AVAILABLE'
                                                      ? Colors.green.shade700
                                                      : Colors.orange.shade800,
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          product.availabilityStatus
                                                      .toUpperCase() ==
                                                  'UNKNOWN'
                                              ? '-'
                                              : 'Stok ${product.estimatedAvailableQty.toStringAsFixed(0)}',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      _money.format(product.price),
                                      style: const TextStyle(
                                        color: Color(0xFF943F35),
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cartPanel() {
    final lines = _cart.values.toList();
    final displayGroups = <_CartPanelGroup>[];
    final bundleGroups = <int, _CartPanelGroup>{};
    for (final entry in _cart.entries) {
      final line = entry.value;
      if (line.bundleId <= 0) {
        displayGroups.add(
          _CartPanelGroup(
            keys: [entry.key],
            lines: [line],
            title: line.product.name,
            isBundle: false,
          ),
        );
        continue;
      }
      final bundleGroupKey =
          line.bundleGroupId > 0 ? line.bundleGroupId : line.bundleId;
      final group =
          bundleGroups[bundleGroupKey] ??= _CartPanelGroup(
            keys: [],
            lines: [],
            title: line.bundleName.isEmpty ? 'Paket / Bundle' : line.bundleName,
            isBundle: true,
          );
      group.keys.add(entry.key);
      group.lines.add(line);
      if (!displayGroups.contains(group)) displayGroups.add(group);
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.shopping_cart_checkout),
                const SizedBox(width: 8),
                Text(
                  'Keranjang',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (_editingOrderId > 0) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _editingOrderNo.isEmpty ? 'Tambah item' : _editingOrderNo,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Batal mode tambah item',
                    onPressed:
                        () => setState(() {
                          _editingOrderId = 0;
                          _editingOrderNo = '';
                          _cart.clear();
                        }),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final service = DropdownButtonFormField<String>(
                  value: _serviceType,
                  items:
                      _serviceTypes.entries
                          .map(
                            (entry) => DropdownMenuItem<String>(
                              value: entry.key,
                              child: Text(
                                entry.value,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                  onChanged:
                      _busy
                          ? null
                          : (value) {
                            if (value != null) {
                              setState(() => _serviceType = value);
                            }
                          },
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.room_service),
                    labelText: 'Tipe layanan',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                );
                final customer = TextField(
                  controller: _customerController,
                  onChanged: _onCustomerChanged,
                  onTapOutside:
                      (_) => FocusManager.instance.primaryFocus?.unfocus(),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.person_outline),
                    labelText: 'Customer',
                    suffixIcon:
                        _memberSearchBusy
                            ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                            : const Icon(Icons.manage_search),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                );
                return Row(
                  children: [
                    Expanded(child: service),
                    const SizedBox(width: 8),
                    Expanded(child: customer),
                  ],
                );
              },
            ),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, constraints) {
                final guest = TextField(
                  controller: _guestController,
                  keyboardType: TextInputType.number,
                  onTapOutside:
                      (_) => FocusManager.instance.primaryFocus?.unfocus(),
                  decoration: InputDecoration(
                    labelText: 'Guest',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                );
                final table = TextField(
                  controller: _tableController,
                  onTapOutside:
                      (_) => FocusManager.instance.primaryFocus?.unfocus(),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.table_restaurant),
                    labelText: 'Meja',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                );
                return Row(
                  children: [
                    Expanded(child: guest),
                    const SizedBox(width: 8),
                    Expanded(child: table),
                  ],
                );
              },
            ),
            if (_memberSuggestions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: const Color(0xFFF4FAF4),
                  border: Border.all(color: const Color(0xFFB9DDBA)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(10, 8, 10, 4),
                      child: Text(
                        'Pilih member',
                        style: TextStyle(
                          color: Colors.green,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    ..._memberSuggestions.map(
                      (member) => ListTile(
                        dense: true,
                        leading: const Icon(Icons.person),
                        title: Text(member.name),
                        subtitle: Text(
                          '${member.memberNo} | ${member.phone} | ${member.tier}',
                        ),
                        onTap: () {
                          setState(() {
                            _selectedMember = member;
                            _memberSuggestions = const [];
                            _customerController.text = member.name;
                          });
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (_selectedMember != null) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF4FAF4),
                  border: Border.all(color: const Color(0xFFB9DDBA)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.verified_user, color: Colors.green),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Member terdeteksi otomatis',
                            style: TextStyle(
                              color: Colors.green.shade800,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            '${_selectedMember!.name} - ${_selectedMember!.phone}',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          Text(
                            '${_selectedMember!.memberNo} | Tier ${_selectedMember!.tier} | Point ${_selectedMember!.pointBalance.toStringAsFixed(0)} | Stamp ${_selectedMember!.stampBalance.toStringAsFixed(0)}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Hapus member',
                      onPressed: () {
                        setState(() {
                          _selectedMember = null;
                          _customerController.clear();
                        });
                      },
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, constraints) {
                final sales = DropdownButtonFormField<int>(
                  value:
                      _salesChannels.any(
                            (row) => _asInt(row['id']) == _salesChannelId,
                          )
                          ? _salesChannelId
                          : null,
                  items:
                      _salesChannels
                          .map(
                            (row) => DropdownMenuItem<int>(
                              value: _asInt(row['id']),
                              child: Text(
                                row['channel_name']?.toString() ??
                                    row['channel_code']?.toString() ??
                                    '-',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                  onChanged:
                      _busy || _salesChannels.isEmpty
                          ? null
                          : (value) {
                            if (value != null) {
                              setState(() => _salesChannelId = value);
                            }
                          },
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.storefront_outlined),
                    labelText: 'Sales channel',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                );
                final notes = TextField(
                  controller: _noteController,
                  onTapOutside:
                      (_) => FocusManager.instance.primaryFocus?.unfocus(),
                  minLines: 1,
                  maxLines: 1,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.notes),
                    labelText: 'Catatan order',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                );
                return Row(
                  children: [
                    Expanded(child: sales),
                    const SizedBox(width: 8),
                    Expanded(child: notes),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            Expanded(
              child:
                  lines.isEmpty
                      ? const Center(child: Text('Belum ada item.'))
                      : ListView.separated(
                        padding: EdgeInsets.zero,
                        itemCount: displayGroups.length,
                        separatorBuilder: (_, __) => const Divider(height: 14),
                        itemBuilder: (context, index) {
                          final group = displayGroups[index];
                          final line = group.lines.first;
                          final total = group.lines.fold<double>(
                            0,
                            (sum, item) => sum + item.total,
                          );
                          final quantity =
                              group.isBundle
                                  ? group.lines
                                      .map((item) => item.qty)
                                      .reduce((a, b) => a < b ? a : b)
                                  : line.qty;
                          final hasSavedLine = group.lines.any(
                            (item) => item.orderLineId > 0,
                          );
                          return Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      group.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    Text(_money.format(total)),
                                    if (!group.isBundle &&
                                        line.extras.isNotEmpty)
                                      Text(
                                        '${line.extras.length} extra',
                                        style:
                                            Theme.of(
                                              context,
                                            ).textTheme.bodySmall,
                                      ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip:
                                    hasSavedLine
                                        ? 'Item tersimpan: gunakan Void'
                                        : 'Kurangi',
                                onPressed:
                                    hasSavedLine
                                        ? null
                                        : () =>
                                            group.isBundle
                                                ? _changeBundleQty(
                                                  group.keys,
                                                  -1,
                                                )
                                                : _changeQty(
                                                  group.keys.first,
                                                  -1,
                                                ),
                                icon: const Icon(Icons.remove_circle_outline),
                              ),
                              SizedBox(
                                width: 25,
                                child: Text(
                                  '$quantity',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Tambah',
                                onPressed:
                                    () =>
                                        group.isBundle
                                            ? _changeBundleQty(group.keys, 1)
                                            : _changeQty(group.keys.first, 1),
                                icon: const Icon(Icons.add_circle_outline),
                              ),
                            ],
                          );
                        },
                      ),
            ),
            const Divider(height: 24),
            Row(
              children: [
                const Text('Total'),
                const Spacer(),
                Text(
                  _money.format(_cartTotal),
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                IconButton.outlined(
                  tooltip: 'Bersihkan keranjang',
                  onPressed:
                      _busy || lines.isEmpty
                          ? null
                          : () => setState(() {
                            if (_editingOrderId > 0) {
                              _cart.removeWhere(
                                (_, line) => line.orderLineId == 0,
                              );
                            } else {
                              _cart.clear();
                            }
                          }),
                  icon: const Icon(Icons.delete_outline),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        _busy || lines.isEmpty
                            ? null
                            : () => _saveOrder(confirmOrder: false),
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Simpan draft'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed:
                        _busy || lines.isEmpty
                            ? null
                            : () => _saveOrder(confirmOrder: true),
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Simpan transaksi'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CartPanelGroup {
  _CartPanelGroup({
    required this.keys,
    required this.lines,
    required this.title,
    required this.isBundle,
  });

  final List<int> keys;
  final List<CartLine> lines;
  final String title;
  final bool isBundle;
}

class _ProductCustomization {
  const _ProductCustomization({
    required this.qty,
    required this.extras,
    required this.note,
  });

  final int qty;
  final List<CartExtra> extras;
  final String note;
}

class _ActiveServerSessionNotice extends StatelessWidget {
  const _ActiveServerSessionNotice({
    required this.sessions,
    required this.onChangeAccount,
  });

  final List<Map<String, Object?>> sessions;
  final VoidCallback onChangeAccount;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange.withValues(alpha: .35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Kasir aktif di server',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          for (final session in sessions.take(3))
            Text(
              '${session['cashier_name'] ?? 'Kasir lain'} • ${session['terminal_name'] ?? '-'}',
            ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: onChangeAccount,
            icon: const Icon(Icons.switch_account),
            label: const Text('Ganti akun kasir'),
          ),
        ],
      ),
    );
  }
}

class _TopStatusBar extends StatelessWidget {
  const _TopStatusBar({
    this.compact = false,
    required this.sync,
    required this.session,
    required this.activeServerSessions,
    required this.cashierName,
    required this.onChangeAccount,
    required this.syncBusy,
    required this.onSync,
    required this.localDraftCount,
    required this.onOpenDrafts,
    required this.onOpenSettings,
    required this.onOpenPrinter,
    required this.onOpenWorkspace,
    required this.onOpenIncoming,
    required this.onToggleShift,
    required this.shiftIcon,
    required this.shiftTooltip,
  });

  final bool compact;
  final SyncSnapshot sync;
  final CashierSession? session;
  final List<Map<String, Object?>> activeServerSessions;
  final String cashierName;
  final VoidCallback onChangeAccount;
  final bool syncBusy;
  final VoidCallback onSync;
  final int localDraftCount;
  final VoidCallback onOpenDrafts;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenPrinter;
  final VoidCallback onOpenWorkspace;
  final VoidCallback onOpenIncoming;
  final VoidCallback? onToggleShift;
  final IconData shiftIcon;
  final String shiftTooltip;

  Widget _actionButton({
    required String tooltip,
    required VoidCallback? onPressed,
    required IconData icon,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 19),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 38, height: 38),
      visualDensity: VisualDensity.standard,
      style: IconButton.styleFrom(
        foregroundColor: const Color(0xFF574944),
        backgroundColor: Colors.white,
        disabledBackgroundColor: Colors.white.withValues(alpha: .55),
        side: const BorderSide(color: Color(0xFFE5D5CB)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final statusColor =
        sync.online
            ? Colors.green.shade700
            : sync.serverReachable
            ? Colors.orange.shade800
            : Colors.red.shade700;
    final cashier =
        cashierName.trim().isEmpty ? 'Kasir belum dipilih' : cashierName;
    final content = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 0 : 8,
        vertical: compact ? 2 : 7,
      ),
      child: Row(
        children: [
          _actionButton(
            tooltip: 'Pengaturan',
            onPressed: onOpenSettings,
            icon: Icons.settings_outlined,
          ),
          const SizedBox(width: 5),
          _actionButton(
            tooltip: 'Printer POS',
            onPressed: onOpenPrinter,
            icon: Icons.print_outlined,
          ),
          const SizedBox(width: 5),
          _actionButton(
            tooltip: 'Order aktif dan terbayar',
            onPressed: onOpenWorkspace,
            icon: Icons.receipt_long_outlined,
          ),
          const SizedBox(width: 5),
          _actionButton(
            tooltip: 'Order masuk',
            onPressed: onOpenIncoming,
            icon: Icons.inbox_outlined,
          ),
          const SizedBox(width: 5),
          _actionButton(
            tooltip: shiftTooltip,
            onPressed: onToggleShift,
            icon: shiftIcon,
          ),
          const SizedBox(width: 4),
          _StatusPill(
            icon: sync.online ? Icons.cloud_done : Icons.cloud_off,
            label: sync.online ? 'Online' : 'Offline',
            value: sync.online ? 'Siap' : 'Perlu cek',
            color: statusColor,
          ),
          const SizedBox(width: 6),
          TextButton.icon(
            onPressed: syncBusy ? null : onSync,
            icon:
                syncBusy
                    ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.sync, size: 18),
            label: Text(syncBusy ? 'Sinkron...' : 'Sinkron sekarang'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF8C3F35),
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              side: const BorderSide(color: Color(0xFFE5D5CB)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          const SizedBox(width: 6),
          TextButton.icon(
            onPressed: onOpenDrafts,
            icon: const Icon(Icons.drafts_outlined, size: 18),
            label: Text('Draft lokal $localDraftCount'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF574944),
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              side: const BorderSide(color: Color(0xFFE5D5CB)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          _StatusPill(
            icon: Icons.outbox_outlined,
            label: 'Outbox',
            value: '${sync.outboxPending}',
          ),
          if (session?.backupMode == true) ...[
            const SizedBox(width: 6),
            const _StatusPill(
              icon: Icons.devices_other_outlined,
              label: 'Mode',
              value: 'Backup',
              color: Colors.orange,
            ),
          ],
          const SizedBox(width: 6),
          _StatusPill(
            icon: Icons.schedule,
            label: 'Sync terakhir',
            value: sync.lastRunText,
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap:
                session == null && activeServerSessions.isNotEmpty
                    ? onChangeAccount
                    : null,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  Icon(
                    session?.isOpen == true
                        ? Icons.account_circle
                        : Icons.account_circle_outlined,
                    size: 20,
                    color:
                        session?.isOpen == true ? Colors.green.shade700 : null,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    session?.isOpen == true
                        ? 'Kasir aktif: $cashier'
                        : activeServerSessions.isNotEmpty
                        ? 'Kasir server aktif'
                        : cashier,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  if (session == null && activeServerSessions.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.only(left: 4),
                      child: Icon(Icons.warning_amber_rounded, size: 18),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    return compact
        ? Container(
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFFFFF8F4),
            border: Border(
              top: const BorderSide(color: Color(0xFFE5D5CB)),
              bottom: const BorderSide(color: Color(0xFFE5D5CB)),
            ),
          ),
          child: content,
        )
        : Card(
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          child: content,
        );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.icon,
    required this.label,
    required this.value,
    this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE5D5CB)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 17, color: color),
          const SizedBox(width: 6),
          Text(label),
          const SizedBox(width: 5),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _ActiveOrdersPanel extends StatefulWidget {
  const _ActiveOrdersPanel({
    super.key,
    required this.settings,
    required this.onOpenWorkspace,
    required this.onAppendOrder,
    required this.onRetryBlocked,
    required this.onDeleteFailed,
  });

  final AppSettings settings;
  final VoidCallback onOpenWorkspace;
  final Future<void> Function(Map<String, Object?>? row) onAppendOrder;
  final Future<void> Function() onRetryBlocked;
  final Future<void> Function(Map<String, Object?> row) onDeleteFailed;

  @override
  State<_ActiveOrdersPanel> createState() => _ActiveOrdersPanelState();
}

class _ActiveOrdersPanelState extends State<_ActiveOrdersPanel> {
  late final FinanceApiClient _api;
  final LocalDatabase _db = LocalDatabase.instance;
  final NumberFormat _money = NumberFormat.currency(
    locale: 'id_ID',
    symbol: 'Rp ',
    decimalDigits: 0,
  );
  List<Map<String, Object?>> _rows = const [];
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
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    List<Map<String, Object?>> remote = const [];
    final paidServerIds = <int>{};
    Object? error;
    try {
      final response = await _api.orders(
        status: 'ACTIVE',
        page: 1,
        dateFrom: today,
        dateTo: today,
      );
      remote =
          (response['rows'] as List?)
              ?.whereType<Map>()
              .map((row) => Map<String, Object?>.from(row))
              .where((row) => !_isPaidRow(row))
              .toList() ??
          const [];
      final paidResponse = await _api.orders(
        status: 'PAID',
        page: 1,
        dateFrom: today,
        dateTo: today,
      );
      for (final row in (paidResponse['rows'] as List? ?? const [])) {
        if (row is Map) paidServerIds.add(_asInt(row['id']));
      }
      remote =
          remote
              .where((row) => !paidServerIds.contains(_asInt(row['id'])))
              .toList();
    } catch (caught) {
      error = caught;
    }
    final local = await _db.localWorkspaceOrders();
    final serverIds = {for (final row in remote) _asInt(row['id'])};
    for (final row in local) {
      final payload = _decodeLocalPayload(row['payload']?.toString());
      final serverId = _asInt(row['server_id']);
      if (serverId > 0 &&
          (serverIds.contains(serverId) || paidServerIds.contains(serverId))) {
        continue;
      }
      if (_isPaidRow({
        'status': row['status'],
        'payment_status': payload['payment_status'],
        'paid_at': payload['paid_at'],
        'paid_total': payload['paid_total'],
        'grand_total': payload['grand_total'] ?? payload['subtotal'],
      })) {
        continue;
      }
      final localUuid = row['local_uuid']?.toString() ?? '';
      final localLabel = localUuid.replaceFirst('ORD-', '');
      remote.add({
        'id': serverId,
        'local_uuid': localUuid,
        'order_no':
            row['order_no'] ??
            (localLabel.isEmpty
                ? 'Order lokal'
                : 'Lokal-${localLabel.substring(0, localLabel.length > 8 ? 8 : localLabel.length)}'),
        'customer_display_name': payload['customer_name'] ?? 'Walk-in',
        'status': payload['confirm_order'] == true ? 'CONFIRMED' : 'DRAFT',
        'sync_status': row['sync_status'] ?? 'PENDING',
        'last_error': row['last_error'],
        'stock_commit_status':
            payload['stock_commit_status'] ??
            (payload['confirm_order'] == true ? 'PENDING' : 'NOT_REQUIRED'),
        'grand_total': payload['grand_total'] ?? payload['subtotal'] ?? 0,
        'local_only': serverId <= 0,
      });
    }
    if (!mounted) return;
    setState(() {
      _rows = remote;
      _loading = false;
      _error = error == null ? null : 'Order aktif belum dapat dimuat.';
    });
  }

  Map<String, Object?> _decodeLocalPayload(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final value = jsonDecode(raw);
      return value is Map ? Map<String, Object?>.from(value) : const {};
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
    if ([
      'PAID',
      'REFUND_PARTIAL',
      'REFUND_FULL',
      'REFUNDED_FULL',
    ].contains(status)) {
      return true;
    }
    final paidAt = row['paid_at']?.toString().trim() ?? '';
    final paidTotal = _asDouble(row['paid_total']);
    final grandTotal = _asDouble(row['grand_total']);
    return paidAt.isNotEmpty &&
        grandTotal > 0 &&
        paidTotal + 0.009 >= grandTotal;
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.pending_actions),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Order aktif',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                  ),
                ),
                Text('${_rows.length}'),
                IconButton(
                  tooltip: 'Muat ulang order aktif',
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.refresh, size: 20),
                ),
              ],
            ),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => widget.onAppendOrder(null),
                icon: const Icon(Icons.add),
                label: const Text('Tambah order baru'),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Colors.orange.shade800),
                ),
              ),
            Expanded(
              child:
                  _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _rows.isEmpty
                      ? const Center(
                        child: Text('Belum ada order aktif hari ini.'),
                      )
                      : ListView.separated(
                        padding: const EdgeInsets.only(top: 8),
                        itemCount: _rows.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 7),
                        itemBuilder: (context, index) {
                          final row = _rows[index];
                          final orderNo =
                              row['order_no']?.toString() ?? 'Order';
                          final status = row['status']?.toString() ?? 'ACTIVE';
                          final syncStatus =
                              row['sync_status']?.toString().toUpperCase() ??
                              '';
                          final canDeleteFailed =
                              _asInt(row['id']) <= 0 &&
                              (syncStatus == 'BLOCKED' ||
                                  syncStatus == 'FAILED' ||
                                  (row['last_error']?.toString().trim() ?? '')
                                      .isNotEmpty);
                          final stockStatus =
                              row['stock_commit_status']
                                  ?.toString()
                                  .toUpperCase() ??
                              '';
                          final stockLabel = switch (stockStatus) {
                            'NOT_REQUIRED' => 'Stok: tidak diperlukan',
                            'QUEUED' => 'Stok: dalam antrean',
                            'PROCESSING' => 'Stok: sedang diproses',
                            'POSTED' => 'Stok: sudah diposting',
                            'FAILED' => 'Stok: gagal diproses',
                            'PENDING' when status.toUpperCase() == 'DRAFT' =>
                              'Stok: menunggu konfirmasi',
                            'PENDING' => 'Stok: menunggu sinkron/proses server',
                            _ => '',
                          };
                          return Container(
                            padding: const EdgeInsets.all(9),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: const Color(0xFFE5D5CB),
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        orderNo,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      _money.format(
                                        _asDouble(row['grand_total']),
                                      ),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '${row['customer_display_name'] ?? 'Walk-in'} | $status',
                                ),
                                if (stockLabel.isNotEmpty)
                                  Text(
                                    stockLabel,
                                    style: TextStyle(
                                      color:
                                          stockStatus == 'FAILED'
                                              ? Colors.red.shade700
                                              : stockStatus == 'POSTED'
                                              ? Colors.green.shade700
                                              : Colors.orange.shade800,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                if (row['sync_status'] != null)
                                  Text(
                                    'Sync: ${row['sync_status']}',
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                if (row['sync_status'] == 'BLOCKED' &&
                                    (row['last_error']?.toString() ?? '')
                                        .trim()
                                        .isNotEmpty)
                                  Text(
                                    'Perlu diperbaiki: ${row['last_error']}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.orange.shade800,
                                      fontSize: 11,
                                    ),
                                  ),
                                const SizedBox(height: 5),
                                Row(
                                  children: [
                                    Expanded(
                                      child:
                                          row['sync_status'] == 'BLOCKED' &&
                                                  _asInt(row['id']) <= 0
                                              ? OutlinedButton.icon(
                                                onPressed: () async {
                                                  await widget.onRetryBlocked();
                                                  await _load();
                                                },
                                                icon: const Icon(
                                                  Icons.sync,
                                                  size: 17,
                                                ),
                                                label: const Text(
                                                  'Coba sinkron',
                                                ),
                                                style: OutlinedButton.styleFrom(
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                ),
                                              )
                                              : OutlinedButton.icon(
                                                onPressed:
                                                    _asInt(row['id']) > 0
                                                        ? () => widget
                                                            .onAppendOrder(row)
                                                        : null,
                                                icon: const Icon(
                                                  Icons.add_circle_outline,
                                                  size: 17,
                                                ),
                                                label: const Text(
                                                  'Tambah item',
                                                ),
                                                style: OutlinedButton.styleFrom(
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                ),
                                              ),
                                    ),
                                    const SizedBox(width: 6),
                                    IconButton(
                                      tooltip:
                                          'Payment, void, refund, dan detail',
                                      onPressed: widget.onOpenWorkspace,
                                      icon: const Icon(Icons.more_horiz),
                                    ),
                                    if (canDeleteFailed)
                                      IconButton(
                                        tooltip: 'Hapus order gagal',
                                        onPressed:
                                            () => widget.onDeleteFailed(row),
                                        icon: Icon(
                                          Icons.delete_outline,
                                          color: Colors.red.shade700,
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
            ),
          ],
        ),
      ),
    );
  }
}

// Kept as a fallback layout component for narrow-screen experiments.
// ignore: unused_element
class _SidePanel extends StatelessWidget {
  const _SidePanel({
    required this.sync,
    required this.session,
    required this.activeServerSessions,
    required this.cashierName,
    required this.onChangeAccount,
    required this.syncBusy,
    required this.onSync,
    required this.localDraftCount,
    required this.onOpenDrafts,
  });

  final SyncSnapshot sync;
  final CashierSession? session;
  final List<Map<String, Object?>> activeServerSessions;
  final String cashierName;
  final VoidCallback onChangeAccount;
  final bool syncBusy;
  final VoidCallback onSync;
  final int localDraftCount;
  final VoidCallback onOpenDrafts;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  sync.online
                      ? Icons.cloud_done
                      : sync.serverReachable
                      ? Icons.cloud_queue
                      : Icons.cloud_off,
                  color:
                      sync.online
                          ? Colors.green
                          : sync.serverReachable
                          ? Colors.orange
                          : Colors.redAccent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    sync.online
                        ? 'Online'
                        : sync.serverReachable
                        ? 'Perlu perhatian'
                        : 'Offline',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(sync.message),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: syncBusy ? null : onSync,
                icon:
                    syncBusy
                        ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Icon(Icons.sync),
                label: Text(syncBusy ? 'Menyinkronkan...' : 'Sinkron sekarang'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onOpenDrafts,
                icon: const Icon(Icons.drafts_outlined),
                label: Text('Draft lokal ($localDraftCount)'),
              ),
            ),
            const SizedBox(height: 12),
            _Metric(
              label: 'Outbox',
              value: '${sync.outboxPending}',
              icon: Icons.outbox,
            ),
            if (session?.backupMode == true) ...[
              const SizedBox(height: 8),
              const _Metric(
                label: 'Mode',
                value: 'Backup',
                icon: Icons.devices_other_outlined,
              ),
            ],
            const SizedBox(height: 8),
            _Metric(
              label: 'Sync terakhir',
              value: sync.lastRunText,
              icon: Icons.schedule,
            ),
            const Divider(height: 24),
            Row(
              children: [
                Icon(
                  session?.isOpen == true
                      ? Icons.account_circle
                      : Icons.account_circle_outlined,
                  color: session?.isOpen == true ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 8),
                const Text(
                  'Kasir aktif',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              cashierName.trim().isEmpty ? 'User belum diketahui' : cashierName,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (session == null)
              if (activeServerSessions.isEmpty)
                const Text(
                  'Belum ada sesi aktif dari server. Buka kasir untuk membuat shift baru.',
                )
              else
                _ActiveServerSessionNotice(
                  sessions: activeServerSessions,
                  onChangeAccount: onChangeAccount,
                )
            else ...[
              Row(
                children: [
                  Icon(
                    session!.isOpen ? Icons.lock_open : Icons.lock_outline,
                    size: 18,
                    color: session!.isOpen ? Colors.green : Colors.orange,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      session!.isOpen ? 'Shift aktif' : session!.status,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _SessionLine(label: 'Shift', value: session!.shiftNo),
              _SessionLine(label: 'Outlet', value: session!.outletName),
              _SessionLine(label: 'Terminal', value: session!.terminalName),
              _SessionLine(label: 'Dibuka', value: session!.openedAt),
            ],
          ],
        ),
      ),
    );
  }
}

class _SessionLine extends StatelessWidget {
  const _SessionLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 66,
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

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, required this.icon});

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE5D5CB)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _PaymentEntry {
  _PaymentEntry({required this.methodId, String amount = ''})
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

class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog({
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
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  final String _clientEventId = 'PAY-${DateTime.now().microsecondsSinceEpoch}';
  final TextEditingController _voucherController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  Timer? _voucherSearchTimer;
  int _voucherSearchRequest = 0;
  List<PaymentMethod> _methods = const [];
  List<Map<String, Object?>> _vouchers = const [];
  Map<String, Object?>? _selectedVoucher;
  final List<_PaymentEntry> _entries = [];
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
        _PaymentEntry(
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
    _voucherController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _scheduleVoucherSearch() {
    _voucherSearchTimer?.cancel();
    final query = _voucherController.text.trim();
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
    final query = _voucherController.text.trim();
    if (query.isEmpty) return;
    setState(() => _busy = true);
    try {
      final rows = await widget.onVoucherSearch(query);
      if (mounted && _voucherController.text.trim() == query) {
        setState(() => _vouchers = rows);
      }
    } catch (error) {
      if (mounted && showError) _showDialogMessage('$error');
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
    if (_entries.isEmpty && due > 0) {
      _showDialogMessage('Pilih metode pembayaran.');
      return;
    }
    if (amounts.every((amount) => amount <= 0) && due > 0) {
      _showDialogMessage('Nominal pembayaran wajib diisi.');
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
        'notes': _notesController.text.trim(),
      });
      if (!mounted) return;
      Navigator.pop(context, result);
    } catch (error) {
      if (mounted) _showDialogMessage('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  PaymentMethod? _methodFor(int methodId) {
    for (final method in _methods) {
      if (method.id == methodId) return method;
    }
    return null;
  }

  double get _enteredTotal => _entries.fold(
    0,
    (sum, entry) => sum + _asDouble(entry.amountController.text),
  );

  double get _cashChangePreview {
    if (_entries.length != 1) return 0;
    final method = _methodFor(_entries.first.methodId);
    if (method?.type.toUpperCase() != 'CASH') return 0;
    return (_enteredTotal - _asDouble(widget.payment['due_total'])).clamp(
      0,
      double.infinity,
    );
  }

  int _nextMethodId() {
    for (final method in _methods) {
      if (!_entries.any((entry) => entry.methodId == method.id)) {
        return method.id;
      }
    }
    return _methods.first.id;
  }

  void _setPaymentAmount(_PaymentEntry entry, double amount) {
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
    final method = _methodFor(entry.methodId)?.name ?? 'metode terpilih';
    final options = <Map<String, Object>>[
      {'label': 'Pas', 'value': _remainingForSelectedEntry(due)},
      {'label': '10K', 'value': 10000},
      {'label': '20K', 'value': 20000},
      {'label': '50K', 'value': 50000},
      {'label': '100K', 'value': 100000},
    ];
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
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

  void _showDialogMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final due = _asDouble(widget.payment['due_total']);
    final screenHeight = MediaQuery.sizeOf(context).height;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: screenHeight * .88,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
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
                      Card(
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Tagihan dari server',
                                style: Theme.of(context).textTheme.labelLarge,
                              ),
                              const SizedBox(height: 3),
                              Text(
                                _moneyText(due),
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                              Text(
                                'Customer: ${widget.payment['customer_name'] ?? 'Walk in'}',
                              ),
                              if ((widget.payment['member_name']?.toString() ??
                                      '')
                                  .trim()
                                  .isNotEmpty)
                                Text(
                                  'Member: ${widget.payment['member_name']} | Poin ${_asDouble(widget.payment['member_point_balance']).toStringAsFixed(0)} | Stamp ${_asDouble(widget.payment['member_stamp_balance']).toStringAsFixed(0)}',
                                ),
                              if (_asDouble(
                                    widget.payment['deposit_applied_total'],
                                  ) >
                                  0)
                                Text(
                                  'Deposit terpakai: ${_moneyText(_asDouble(widget.payment['deposit_applied_total']))}',
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Rincian pembayaran',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      ..._entries.asMap().entries.map((item) {
                        final index = item.key;
                        final entry = item.value;
                        return Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: DropdownButtonFormField<int>(
                                        value:
                                            _methods.any(
                                                  (method) =>
                                                      method.id ==
                                                      entry.methodId,
                                                )
                                                ? entry.methodId
                                                : null,
                                        items:
                                            _methods
                                                .map(
                                                  (method) =>
                                                      DropdownMenuItem<int>(
                                                        value: method.id,
                                                        child: Text(
                                                          method.name,
                                                        ),
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
                                          labelText:
                                              _entries.length > 1
                                                  ? 'Metode ${index + 1}'
                                                  : 'Metode pembayaran',
                                        ),
                                      ),
                                    ),
                                    if (_entries.length > 1)
                                      IconButton(
                                        tooltip: 'Hapus metode',
                                        onPressed:
                                            _busy
                                                ? null
                                                : () => setState(() {
                                                  final removed = _entries
                                                      .removeAt(index);
                                                  removed.dispose();
                                                }),
                                        icon: const Icon(Icons.delete_outline),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                TextField(
                                  controller: entry.amountController,
                                  onTap:
                                      () => setState(
                                        () => _selectedEntryIndex = index,
                                      ),
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  onChanged: (_) => setState(() {}),
                                  onTapOutside:
                                      (_) =>
                                          FocusManager.instance.primaryFocus
                                              ?.unfocus(),
                                  decoration: const InputDecoration(
                                    labelText: 'Nominal diterima',
                                    prefixText: 'Rp ',
                                  ),
                                ),
                                const SizedBox(height: 8),
                                TextField(
                                  controller: entry.referenceController,
                                  onTapOutside:
                                      (_) =>
                                          FocusManager.instance.primaryFocus
                                              ?.unfocus(),
                                  decoration: const InputDecoration(
                                    labelText:
                                        'Referensi pembayaran (opsional)',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                      if (_entries.isNotEmpty) _quickPaymentButtons(due),
                      OutlinedButton.icon(
                        onPressed:
                            _busy || _methods.isEmpty
                                ? null
                                : () => setState(() {
                                  _entries.add(
                                    _PaymentEntry(methodId: _nextMethodId()),
                                  );
                                  _selectedEntryIndex = _entries.length - 1;
                                }),
                        icon: const Icon(Icons.add),
                        label: const Text('Tambah metode pembayaran'),
                      ),
                      const SizedBox(height: 8),
                      Text('Total input: ${_moneyText(_enteredTotal)}'),
                      if (_cashChangePreview > 0)
                        Text(
                          'Kembalian: ${_moneyText(_cashChangePreview)}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            color: Colors.green,
                          ),
                        ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _voucherController,
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
                            tooltip: 'Cek voucher',
                            onPressed: _busy ? null : _searchVoucher,
                            icon: const Icon(Icons.local_offer_outlined),
                          ),
                        ],
                      ),
                      if (_vouchers.isNotEmpty)
                        ..._vouchers.map(
                          (voucher) => ListTile(
                            dense: true,
                            title: Text(
                              voucher['label']?.toString() ??
                                  voucher['voucher_code']?.toString() ??
                                  'Voucher',
                            ),
                            subtitle: Text(
                              voucher['message']?.toString() ?? '',
                            ),
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
                                          _voucherController
                                              .value = TextEditingValue(
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
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _notesController,
                        onTapOutside:
                            (_) =>
                                FocusManager.instance.primaryFocus?.unfocus(),
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: 'Catatan payment',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
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
                        icon:
                            _busy
                                ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Icon(Icons.check),
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

String _friendlyError(Object error) {
  if (error is FinanceApiException) return error.userMessage;
  if (error is TimeoutException) return 'Server terlalu lama merespons.';
  return 'Operasi belum berhasil. Data lokal tetap aman.';
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
