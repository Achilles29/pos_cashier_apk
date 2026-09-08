import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

class LocalDatabase {
  LocalDatabase._();

  static final LocalDatabase instance = LocalDatabase._();
  static const _uuid = Uuid();

  Database? _db;
  String _scopeKey = 'default';

  void setScope(String scope) {
    final value = scope.trim();
    _scopeKey = value.isEmpty ? 'default' : value;
  }

  Future<void> migrateLegacyScope(String scope) async {
    final target = scope.trim();
    if (target.isEmpty || target == 'default') return;
    final db = await database;
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      await txn.rawUpdate(
        "UPDATE local_orders SET scope_key = ? WHERE scope_key = 'default'",
        [target],
      );
      await txn.rawUpdate(
        "UPDATE sync_outbox SET scope_key = ? WHERE scope_key = 'default'",
        [target],
      );
      await txn.rawUpdate(
        "UPDATE sync_log SET scope_key = ? WHERE scope_key = 'default'",
        [target],
      );
      await txn.rawUpdate(
        "UPDATE local_printer SET scope_key = ? WHERE scope_key = 'default'",
        [target],
      );
      await txn.rawUpdate(
        "UPDATE local_print_outbox SET scope_key = ? WHERE scope_key = 'default'",
        [target],
      );

      final cacheRows = await txn.query(
        'master_cache',
        where: "cache_key NOT LIKE '%::%'",
      );
      for (final row in cacheRows) {
        await txn.update(
          'master_cache',
          {'cache_key': '$target::${row['cache_key']}', 'updated_at': now},
          where: 'cache_key = ?',
          whereArgs: [row['cache_key']],
        );
      }
      final metaRows = await txn.query(
        'app_meta',
        where: "key NOT LIKE '%::%'",
      );
      for (final row in metaRows) {
        await txn.update(
          'app_meta',
          {'key': '$target::${row['key']}', 'updated_at': now},
          where: 'key = ?',
          whereArgs: [row['key']],
        );
      }
    });
    setScope(target);
  }

  String _scopedKey(String key) => '$_scopeKey::$key';

  Future<Database> get database async {
    final current = _db;
    if (current != null) {
      return current;
    }

    final path = p.join(await getDatabasesPath(), 'pos_cashier_local.db');
    final opened = await openDatabase(
      path,
      version: 5,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE app_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE master_cache (
            cache_key TEXT PRIMARY KEY,
            payload TEXT NOT NULL,
            version_token TEXT,
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE local_orders (
            local_uuid TEXT PRIMARY KEY,
            scope_key TEXT NOT NULL DEFAULT 'default',
            server_id INTEGER,
            order_no TEXT,
            status TEXT NOT NULL,
            sync_status TEXT NOT NULL,
            payload TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE sync_outbox (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            scope_key TEXT NOT NULL DEFAULT 'default',
            event_uuid TEXT NOT NULL UNIQUE,
            event_type TEXT NOT NULL,
            aggregate_uuid TEXT NOT NULL,
            payload TEXT NOT NULL,
            status TEXT NOT NULL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE sync_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            scope_key TEXT NOT NULL DEFAULT 'default',
            status TEXT NOT NULL,
            message TEXT NOT NULL,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE local_printer (
            scope_key TEXT NOT NULL,
            server_printer_id INTEGER NOT NULL,
            server_name TEXT NOT NULL,
            printer_role TEXT NOT NULL,
            print_scope TEXT NOT NULL,
            bluetooth_name TEXT NOT NULL,
            bluetooth_address TEXT NOT NULL,
            paper_width INTEGER NOT NULL DEFAULT 58,
            chars_per_line INTEGER NOT NULL DEFAULT 32,
            is_active INTEGER NOT NULL DEFAULT 1,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (scope_key, server_printer_id)
          )
        ''');
        await db.execute('''
          CREATE TABLE local_print_outbox (
            scope_key TEXT NOT NULL,
            server_order_id INTEGER NOT NULL,
            document_type TEXT NOT NULL DEFAULT 'ORDER_CONFIRM',
            attempt_count INTEGER NOT NULL DEFAULT 0,
            retry_after TEXT,
            last_error TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (scope_key, server_order_id, document_type)
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS local_printer (
              server_printer_id INTEGER PRIMARY KEY,
              server_name TEXT NOT NULL,
              printer_role TEXT NOT NULL,
              print_scope TEXT NOT NULL,
              bluetooth_name TEXT NOT NULL,
              bluetooth_address TEXT NOT NULL,
              paper_width INTEGER NOT NULL DEFAULT 58,
              is_active INTEGER NOT NULL DEFAULT 1,
              updated_at TEXT NOT NULL
            )
          ''');
        }
        if (oldVersion < 3) {
          await db.execute(
            "ALTER TABLE local_orders ADD COLUMN scope_key TEXT NOT NULL DEFAULT 'default'",
          );
          await db.execute(
            "ALTER TABLE sync_outbox ADD COLUMN scope_key TEXT NOT NULL DEFAULT 'default'",
          );
          await db.execute(
            "ALTER TABLE sync_log ADD COLUMN scope_key TEXT NOT NULL DEFAULT 'default'",
          );
          await db.execute('''
            CREATE TABLE local_printer_scoped (
              scope_key TEXT NOT NULL,
              server_printer_id INTEGER NOT NULL,
              server_name TEXT NOT NULL,
              printer_role TEXT NOT NULL,
              print_scope TEXT NOT NULL,
              bluetooth_name TEXT NOT NULL,
              bluetooth_address TEXT NOT NULL,
              paper_width INTEGER NOT NULL DEFAULT 58,
              is_active INTEGER NOT NULL DEFAULT 1,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (scope_key, server_printer_id)
            )
          ''');
          await db.execute('''
            INSERT INTO local_printer_scoped
              (scope_key, server_printer_id, server_name, printer_role,
               print_scope, bluetooth_name, bluetooth_address, paper_width,
               is_active, updated_at)
            SELECT 'default', server_printer_id, server_name, printer_role,
              print_scope, bluetooth_name, bluetooth_address, paper_width,
              is_active, updated_at
            FROM local_printer
          ''');
          await db.execute('DROP TABLE local_printer');
          await db.execute(
            'ALTER TABLE local_printer_scoped RENAME TO local_printer',
          );
        }
        if (oldVersion < 4) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS local_print_outbox (
              scope_key TEXT NOT NULL,
              server_order_id INTEGER NOT NULL,
              document_type TEXT NOT NULL DEFAULT 'ORDER_CONFIRM',
              attempt_count INTEGER NOT NULL DEFAULT 0,
              retry_after TEXT,
              last_error TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (scope_key, server_order_id, document_type)
            )
          ''');
        }
        if (oldVersion < 5) {
          await db.execute(
            'ALTER TABLE local_printer ADD COLUMN chars_per_line INTEGER NOT NULL DEFAULT 32',
          );
        }
      },
    );
    _db = opened;
    return opened;
  }

  Future<void> putMeta(String key, String value) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    await db.insert('app_meta', {
      'key': _scopedKey(key),
      'value': value,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getMeta(String key) async {
    final db = await database;
    final rows = await db.query(
      'app_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_scopedKey(key)],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return rows.first['value'] as String?;
  }

  Future<void> saveMasterCache(
    String cacheKey,
    Map<String, Object?> payload, {
    String versionToken = '',
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    await db.insert('master_cache', {
      'cache_key': _scopedKey(cacheKey),
      'payload': jsonEncode(payload),
      'version_token': versionToken,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, Object?>?> readMasterCache(String cacheKey) async {
    final db = await database;
    final rows = await db.query(
      'master_cache',
      columns: ['payload'],
      where: 'cache_key = ?',
      whereArgs: [_scopedKey(cacheKey)],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return jsonDecode(rows.first['payload'] as String) as Map<String, Object?>;
  }

  Future<String> enqueueLocalOrder(
    Map<String, Object?> payload, {
    String eventType = 'ORDER_UPSERT',
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final requestedServerId = _databaseInt(payload['id']);
    var localUuid = 'ORD-${_uuid.v4()}';
    if (requestedServerId > 0) {
      final existing = await db.query(
        'local_orders',
        columns: ['local_uuid'],
        where: 'scope_key = ? AND server_id = ?',
        whereArgs: [_scopeKey, requestedServerId],
        orderBy: 'updated_at DESC',
        limit: 1,
      );
      if (existing.isNotEmpty) {
        localUuid = existing.first['local_uuid']?.toString() ?? localUuid;
      }
    }
    final eventUuid = 'EVT-${_uuid.v4()}';
    final finalPayload = {
      ...payload,
      'local_uuid': localUuid,
      'client_event_id': eventUuid,
      'client_created_at': now,
    };

    await db.transaction((txn) async {
      final existingRows = await txn.query(
        'local_orders',
        columns: ['local_uuid'],
        where: 'scope_key = ? AND local_uuid = ?',
        whereArgs: [_scopeKey, localUuid],
        limit: 1,
      );
      if (existingRows.isNotEmpty) {
        await txn.update(
          'local_orders',
          {
            'status': 'LOCAL_DRAFT',
            'sync_status': 'PENDING',
            'payload': jsonEncode(finalPayload),
            'updated_at': now,
          },
          where: 'scope_key = ? AND local_uuid = ?',
          whereArgs: [_scopeKey, localUuid],
        );
      } else {
        await txn.insert('local_orders', {
          'local_uuid': localUuid,
          'scope_key': _scopeKey,
          'server_id': requestedServerId > 0 ? requestedServerId : null,
          'order_no': payload['order_no'],
          'status':
              requestedServerId > 0
                  ? (payload['confirm_order'] == true ? 'CONFIRMED' : 'DRAFT')
                  : 'LOCAL_DRAFT',
          'sync_status': 'PENDING',
          'payload': jsonEncode(finalPayload),
          'created_at': now,
          'updated_at': now,
        });
      }
      await txn.insert('sync_outbox', {
        'scope_key': _scopeKey,
        'event_uuid': eventUuid,
        'event_type': eventType,
        'aggregate_uuid': localUuid,
        'payload': jsonEncode(finalPayload),
        'status': 'PENDING',
        'attempt_count': 0,
        'created_at': now,
        'updated_at': now,
      });
    });

    return localUuid;
  }

  int _databaseInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<Map<String, Object?>?> localOrder(String localUuid) async {
    final db = await database;
    final rows = await db.query(
      'local_orders',
      where: 'scope_key = ? AND local_uuid = ?',
      whereArgs: [_scopeKey, localUuid],
      limit: 1,
    );
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.first);
  }

  Future<void> deleteLocalOrder(String localUuid) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'sync_outbox',
        where: 'scope_key = ? AND aggregate_uuid = ?',
        whereArgs: [_scopeKey, localUuid],
      );
      await txn.delete(
        'local_orders',
        where: 'scope_key = ? AND local_uuid = ?',
        whereArgs: [_scopeKey, localUuid],
      );
    });
  }

  Future<List<Map<String, Object?>>> localDraftOrders() async {
    final db = await database;
    final rows = await db.query(
      'local_orders',
      where:
          "scope_key = ? AND status IN ('LOCAL_DRAFT', 'DRAFT', 'PENDING', 'CONFIRMED')",
      whereArgs: [_scopeKey],
      orderBy: 'updated_at DESC',
      limit: 50,
    );
    return rows.map((row) => Map<String, Object?>.from(row)).toList();
  }

  Future<List<Map<String, Object?>>> localWorkspaceOrders() async {
    final db = await database;
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final rows = await db.rawQuery(
      '''
      SELECT lo.*,
        (
          SELECT so.last_error
          FROM sync_outbox so
          WHERE so.scope_key = lo.scope_key
            AND so.aggregate_uuid = lo.local_uuid
            AND so.last_error IS NOT NULL
            AND TRIM(so.last_error) <> ''
          ORDER BY so.id DESC
          LIMIT 1
        ) AS last_error
      FROM local_orders lo
      WHERE lo.scope_key = ?
        AND lo.created_at LIKE ?
        AND lo.status NOT IN ('PAID', 'VOID', 'REFUNDED_FULL')
      ORDER BY lo.updated_at DESC
      LIMIT 100
      ''',
      [_scopeKey, '$today%'],
    );
    return rows.map((row) => Map<String, Object?>.from(row)).toList();
  }

  Future<int> pendingOutboxCount() async {
    final db = await database;
    final result = Sqflite.firstIntValue(
      await db.rawQuery(
        "SELECT COUNT(*) FROM sync_outbox WHERE scope_key = ? AND status IN ('PENDING', 'FAILED', 'BLOCKED')",
        [_scopeKey],
      ),
    );
    return result ?? 0;
  }

  Future<int> blockedOutboxCount() async {
    final db = await database;
    final result = Sqflite.firstIntValue(
      await db.rawQuery(
        "SELECT COUNT(*) FROM sync_outbox WHERE scope_key = ? AND status = 'BLOCKED'",
        [_scopeKey],
      ),
    );
    return result ?? 0;
  }

  Future<List<Map<String, Object?>>> pendingOutbox({int limit = 20}) async {
    final db = await database;
    return db.query(
      'sync_outbox',
      where: "scope_key = ? AND status IN ('PENDING', 'FAILED')",
      whereArgs: [_scopeKey],
      orderBy: 'id ASC',
      limit: limit,
    );
  }

  Future<void> markOutboxSynced(int id, Map<String, Object?> response) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final aggregateUuid = response['local_uuid']?.toString() ?? '';
    await db.transaction((txn) async {
      await txn.update(
        'sync_outbox',
        {'status': 'SYNCED', 'last_error': null, 'updated_at': now},
        where: 'scope_key = ? AND id = ?',
        whereArgs: [_scopeKey, id],
      );
      if (aggregateUuid.isNotEmpty) {
        final serverStatus = response['status']?.toString() ?? '';
        final serverOrderId = _databaseInt(response['server_id']);
        final localStatus =
            serverStatus == 'SERVER_CONFIRMED' ? 'CONFIRMED' : 'DRAFT';
        final existingRows = await txn.query(
          'local_orders',
          columns: ['payload'],
          where: 'scope_key = ? AND local_uuid = ?',
          whereArgs: [_scopeKey, aggregateUuid],
          limit: 1,
        );
        Map<String, Object?> localPayload = {};
        if (existingRows.isNotEmpty) {
          try {
            final decoded = jsonDecode(
              existingRows.first['payload']?.toString() ?? '{}',
            );
            if (decoded is Map) {
              localPayload = Map<String, Object?>.from(decoded);
            }
          } catch (_) {}
        }
        localPayload.addAll({
          'server_id': response['server_id'],
          'order_no': response['order_no'],
          'server_status': serverStatus,
          'stock_commit_status': response['stock_commit_status'],
          'server_synced_at': now,
        });
        await txn.update(
          'local_orders',
          {
            'server_id': response['server_id'],
            'order_no': response['order_no'],
            'status': localStatus,
            'sync_status': 'SYNCED',
            'payload': jsonEncode(localPayload),
            'updated_at': now,
          },
          where: 'scope_key = ? AND local_uuid = ?',
          whereArgs: [_scopeKey, aggregateUuid],
        );
        if (serverStatus == 'SERVER_CONFIRMED' && serverOrderId > 0) {
          await txn.insert('local_print_outbox', {
            'scope_key': _scopeKey,
            'server_order_id': serverOrderId,
            'document_type': 'ORDER_CONFIRM',
            'attempt_count': 0,
            'retry_after': null,
            'last_error': null,
            'created_at': now,
            'updated_at': now,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
    });
  }

  Future<void> markOutboxFailed(int id, String message) async {
    final db = await database;
    await db.rawUpdate(
      '''
      UPDATE sync_outbox
      SET status = 'FAILED',
          attempt_count = attempt_count + 1,
          last_error = ?,
          updated_at = ?
      WHERE id = ?
        AND scope_key = ?
      ''',
      [message, DateTime.now().toIso8601String(), id, _scopeKey],
    );
  }

  Future<void> markOutboxBlocked(int id, String message) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      await txn.update(
        'sync_outbox',
        {'status': 'BLOCKED', 'last_error': message, 'updated_at': now},
        where: 'scope_key = ? AND id = ?',
        whereArgs: [_scopeKey, id],
      );
      final row = await txn.query(
        'sync_outbox',
        columns: ['aggregate_uuid'],
        where: 'scope_key = ? AND id = ?',
        whereArgs: [_scopeKey, id],
        limit: 1,
      );
      final aggregateUuid =
          row.isEmpty ? '' : row.first['aggregate_uuid']?.toString() ?? '';
      if (aggregateUuid.isNotEmpty) {
        await txn.update(
          'local_orders',
          {'sync_status': 'BLOCKED', 'updated_at': now},
          where: 'scope_key = ? AND local_uuid = ?',
          whereArgs: [_scopeKey, aggregateUuid],
        );
      }
    });
  }

  Future<void> requeueBlockedOutbox() async {
    final db = await database;
    await db.update(
      'sync_outbox',
      {'status': 'PENDING', 'last_error': null},
      where: "scope_key = ? AND status = 'BLOCKED'",
      whereArgs: [_scopeKey],
    );
  }

  Future<void> addSyncLog(String status, String message) async {
    final db = await database;
    await db.insert('sync_log', {
      'scope_key': _scopeKey,
      'status': status,
      'message': message,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, Object?>>> localPrinters() async {
    final db = await database;
    return db.query(
      'local_printer',
      where: 'scope_key = ?',
      whereArgs: [_scopeKey],
      orderBy: 'printer_role ASC, server_name ASC',
    );
  }

  Future<Map<String, Object?>?> localPrinterFor(int serverPrinterId) async {
    if (serverPrinterId <= 0) return null;
    final db = await database;
    final rows = await db.query(
      'local_printer',
      where: 'scope_key = ? AND server_printer_id = ? AND is_active = 1',
      whereArgs: [_scopeKey, serverPrinterId],
      limit: 1,
    );
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.first);
  }

  Future<void> saveLocalPrinter(Map<String, Object?> row) async {
    final db = await database;
    await db.insert('local_printer', {
      'scope_key': _scopeKey,
      ...row,
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteLocalPrinter(int serverPrinterId) async {
    final db = await database;
    await db.delete(
      'local_printer',
      where: 'scope_key = ? AND server_printer_id = ?',
      whereArgs: [_scopeKey, serverPrinterId],
    );
  }

  Future<List<int>> pendingConfirmationPrintOrders({int limit = 10}) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final rows = await db.query(
      'local_print_outbox',
      columns: ['server_order_id'],
      where:
          "scope_key = ? AND document_type = 'ORDER_CONFIRM' AND (retry_after IS NULL OR retry_after <= ?)",
      whereArgs: [_scopeKey, now],
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return rows
        .map((row) => _databaseInt(row['server_order_id']))
        .where((orderId) => orderId > 0)
        .toList();
  }

  Future<void> markConfirmationPrintComplete(int serverOrderId) async {
    if (serverOrderId <= 0) return;
    final db = await database;
    await db.delete(
      'local_print_outbox',
      where:
          "scope_key = ? AND server_order_id = ? AND document_type = 'ORDER_CONFIRM'",
      whereArgs: [_scopeKey, serverOrderId],
    );
  }

  Future<void> postponeConfirmationPrint(
    int serverOrderId,
    String message,
  ) async {
    if (serverOrderId <= 0) return;
    final db = await database;
    final existing = await db.query(
      'local_print_outbox',
      columns: ['attempt_count'],
      where:
          "scope_key = ? AND server_order_id = ? AND document_type = 'ORDER_CONFIRM'",
      whereArgs: [_scopeKey, serverOrderId],
      limit: 1,
    );
    if (existing.isEmpty) return;
    final previous = _databaseInt(existing.first['attempt_count']);
    final exponent = previous.clamp(0, 4).toInt();
    final delayMinutes = (1 << exponent).clamp(1, 15).toInt();
    final now = DateTime.now();
    await db.update(
      'local_print_outbox',
      {
        'attempt_count': previous + 1,
        'last_error': message,
        'retry_after': now.add(Duration(minutes: delayMinutes)).toIso8601String(),
        'updated_at': now.toIso8601String(),
      },
      where:
          "scope_key = ? AND server_order_id = ? AND document_type = 'ORDER_CONFIRM'",
      whereArgs: [_scopeKey, serverOrderId],
    );
  }

  Future<String> printerAddressFor(
    int serverPrinterId,
    String role,
    String fallback,
  ) async {
    final db = await database;
    final rows = await db.query(
      'local_printer',
      columns: ['bluetooth_address'],
      where: 'scope_key = ? AND server_printer_id = ? AND is_active = 1',
      whereArgs: [_scopeKey, serverPrinterId],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final address =
          (rows.first['bluetooth_address'] as String?)?.trim() ?? '';
      if (address.isNotEmpty) return address;
    }
    final routeRows = await db.query(
      'local_printer',
      columns: ['bluetooth_address'],
      where: 'scope_key = ? AND printer_role = ? AND is_active = 1',
      whereArgs: [_scopeKey, role.toUpperCase()],
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    if (routeRows.isNotEmpty) {
      final address =
          (routeRows.first['bluetooth_address'] as String?)?.trim() ?? '';
      if (address.isNotEmpty) return address;
    }
    return fallback;
  }

  /// A server print target must resolve to its exact local binding. Falling
  /// back by role can send a kitchen or bar ticket to the wrong device when a
  /// division has more than one printer.
  Future<String> exactPrinterAddressFor(int serverPrinterId) async {
    if (serverPrinterId <= 0) return '';
    final db = await database;
    final rows = await db.query(
      'local_printer',
      columns: ['bluetooth_address'],
      where: 'scope_key = ? AND server_printer_id = ? AND is_active = 1',
      whereArgs: [_scopeKey, serverPrinterId],
      limit: 1,
    );
    if (rows.isEmpty) return '';
    return (rows.first['bluetooth_address'] as String?)?.trim() ?? '';
  }
}
