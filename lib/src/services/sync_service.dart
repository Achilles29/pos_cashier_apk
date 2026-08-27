import 'dart:convert';
import 'dart:async';
import 'dart:io';

import '../models.dart';
import 'finance_api_client.dart';
import 'local_database.dart';

class SyncService {
  SyncService({required this.settings, required this.localDatabase})
    : _api = FinanceApiClient(settings: settings) {
    localDatabase.setScope(settings.storageScope);
  }

  final AppSettings settings;
  final LocalDatabase localDatabase;
  final FinanceApiClient _api;

  Future<SyncSnapshot> syncNow({bool retryBlocked = false}) async {
    final pendingBefore = await localDatabase.pendingOutboxCount();
    if (!settings.isConfigured) {
      return SyncSnapshot(
        online: false,
        outboxPending: pendingBefore,
        message: 'URL backend belum diatur',
      );
    }

    try {
      if (retryBlocked) await localDatabase.requeueBlockedOutbox();
      await _api.ping();
      await _pullMasterDelta();
      await _pullShiftState();
      await _pushOutbox();

      final pendingAfter = await localDatabase.pendingOutboxCount();
      final now = DateTime.now();
      await localDatabase.addSyncLog('OK', 'Sync selesai');
      return SyncSnapshot(
        online: true,
        outboxPending: pendingAfter,
        message:
            pendingAfter == 0
                ? 'Sinkron dengan server'
                : '$pendingAfter event menunggu server',
        serverReachable: true,
        lastRunText:
            '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
      );
    } catch (error) {
      final requiresLogin =
          error is FinanceApiException && error.isUnauthorized;
      await localDatabase.addSyncLog('ERROR', error.toString());
      return SyncSnapshot(
        online: false,
        outboxPending: await localDatabase.pendingOutboxCount(),
        message: _friendlyMessage(error),
        requiresLogin: requiresLogin,
        serverReachable: error is FinanceApiException && error.statusCode > 0,
      );
    }
  }

  String _friendlyMessage(Object error) {
    if (error is FinanceApiException) return error.userMessage;
    if (error is TimeoutException) {
      return 'Server terlalu lama merespons. Data lokal tetap aman.';
    }
    if (error is SocketException) {
      return 'Koneksi ke server terputus. Data lokal tetap aman.';
    }
    return 'Sinkronisasi belum berhasil. Data lokal tetap aman.';
  }

  Future<CashierSession?> currentSessionFromCache() async {
    final cache = await localDatabase.readMasterCache('cashier_session');
    final cachedSession = cache?['session'];
    if (cachedSession is Map) {
      final session = CashierSession.fromJson(
        Map<String, Object?>.from(cachedSession),
      );
      if (session?.isOpen == true) return session;
    }

    // Older bootstrap caches also carried the current actor's active session.
    // Keep this fallback so an app restart can resume a valid local session.
    final bootstrap = await cashierBootstrapFromCache();
    final activeSession = bootstrap['active_session'];
    return activeSession is Map
        ? CashierSession.fromJson(Map<String, Object?>.from(activeSession))
        : null;
  }

  Future<List<Map<String, Object?>>> activeCashierSessionsFromCache() async {
    final sessionCache = await localDatabase.readMasterCache('cashier_session');
    final sessionRows = sessionCache?['active_sessions'];
    if (sessionRows is List) {
      return sessionRows
          .whereType<Map>()
          .map((row) => Map<String, Object?>.from(row))
          .toList();
    }
    final bootstrap = await cashierBootstrapFromCache();
    final bootstrapRows = bootstrap['active_sessions'];
    return bootstrapRows is List
        ? bootstrapRows
            .whereType<Map>()
            .map((row) => Map<String, Object?>.from(row))
            .toList()
        : const [];
  }

  Future<Map<String, Object?>> cashierBootstrapFromCache() async {
    final cache = await localDatabase.readMasterCache('bootstrap');
    final raw = cache?['cashier_bootstrap'];
    return raw is Map ? Map<String, Object?>.from(raw) : const {};
  }

  Future<List<ProductItem>> productsFromCache() async {
    final cache = await localDatabase.readMasterCache('bootstrap');
    final rows = (cache?['products'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) => ProductItem.fromJson(Map<String, Object?>.from(row)))
        .toList();
  }

  Future<List<BundleItem>> bundlesFromCache() async {
    final cache = await localDatabase.readMasterCache('bootstrap');
    final rows = (cache?['bundles'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) => BundleItem.fromJson(Map<String, Object?>.from(row)))
        .toList();
  }

  Future<List<Map<String, Object?>>> catalogDivisionsFromCache() async {
    final cache = await localDatabase.readMasterCache('bootstrap');
    final filters = cache?['catalog_filters'];
    if (filters is! Map) return const [];
    final rows = filters['divisions'];
    return (rows is List)
        ? rows
            .whereType<Map>()
            .map((row) => Map<String, Object?>.from(row))
            .toList()
        : const [];
  }

  Future<List<PaymentMethod>> paymentMethodsFromCache() async {
    final cache = await localDatabase.readMasterCache('bootstrap');
    final rows = cache?['payment_methods'];
    if (rows is! List) return const [];
    return rows
        .whereType<Map>()
        .map((row) => PaymentMethod.fromJson(Map<String, Object?>.from(row)))
        .toList();
  }

  Future<void> _pullMasterDelta() async {
    final since = await localDatabase.getMeta('master_sync_cursor') ?? '';
    final payload = await _api.bootstrap(since: since);
    await localDatabase.saveMasterCache('bootstrap', payload);

    final nextCursor = payload['sync_cursor']?.toString() ?? '';
    if (nextCursor.isNotEmpty) {
      await localDatabase.putMeta('master_sync_cursor', nextCursor);
    }
  }

  Future<void> _pullShiftState() async {
    final payload = await _api.sessionStatus();
    await localDatabase.saveMasterCache('cashier_session', payload);
  }

  Future<void> _pushOutbox() async {
    final rows = await localDatabase.pendingOutbox();
    for (final row in rows) {
      final id = row['id'] as int;
      try {
        final payload =
            jsonDecode(row['payload'] as String) as Map<String, Object?>;
        final response = await _api.pushOrder(payload);
        await localDatabase.markOutboxSynced(id, {
          ...response,
          'local_uuid': payload['local_uuid'],
        });
      } catch (error) {
        if (error is FinanceApiException &&
            error.statusCode >= 400 &&
            error.statusCode < 500 &&
            !error.isUnauthorized) {
          await localDatabase.markOutboxBlocked(id, error.userMessage);
        } else {
          await localDatabase.markOutboxFailed(id, _friendlyMessage(error));
        }
        rethrow;
      }
    }
  }
}
