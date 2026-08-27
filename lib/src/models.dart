class AppSettings {
  const AppSettings({
    required this.backendUrl,
    required this.terminalDeviceKey,
    this.profileId = '',
    this.serverScope = '',
    this.mobileApiKey = '',
    this.authToken = '',
    this.username = '',
    this.authExpiresAt = '',
    this.outletId = 0,
    this.terminalId = 0,
    this.backgroundSyncEnabled = true,
    this.foregroundSyncSeconds = 30,
    this.printerName = '',
    this.printerAddress = '',
    this.printerPaperWidth = 58,
    this.printerRoutes = const {},
  });

  final String backendUrl;
  final String terminalDeviceKey;
  final String profileId;
  final String serverScope;
  final String mobileApiKey;
  final String authToken;
  final String username;
  final String authExpiresAt;
  final int outletId;
  final int terminalId;
  final bool backgroundSyncEnabled;
  final int foregroundSyncSeconds;
  final String printerName;
  final String printerAddress;
  final int printerPaperWidth;
  final Map<String, String> printerRoutes;

  String printerAddressFor(String role) {
    final route = printerRoutes[role.toUpperCase()]?.trim() ?? '';
    return route.isEmpty ? printerAddress : route;
  }

  bool get isConfigured => normalizedBackendUrl.isNotEmpty;

  String get storageScope {
    final value = serverScope.trim();
    if (value.isNotEmpty) return value;
    final profile = profileId.trim();
    return profile.isNotEmpty ? profile : normalizedBackendUrl;
  }

  String get normalizedBackendUrl {
    final value = backendUrl.trim();
    if (value.isEmpty) {
      return '';
    }
    return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
  }

  AppSettings copyWith({
    String? backendUrl,
    String? terminalDeviceKey,
    String? profileId,
    String? serverScope,
    String? mobileApiKey,
    String? authToken,
    String? username,
    String? authExpiresAt,
    int? outletId,
    int? terminalId,
    bool? backgroundSyncEnabled,
    int? foregroundSyncSeconds,
    String? printerName,
    String? printerAddress,
    int? printerPaperWidth,
    Map<String, String>? printerRoutes,
  }) {
    return AppSettings(
      backendUrl: backendUrl ?? this.backendUrl,
      terminalDeviceKey: terminalDeviceKey ?? this.terminalDeviceKey,
      profileId: profileId ?? this.profileId,
      serverScope: serverScope ?? this.serverScope,
      mobileApiKey: mobileApiKey ?? this.mobileApiKey,
      authToken: authToken ?? this.authToken,
      username: username ?? this.username,
      authExpiresAt: authExpiresAt ?? this.authExpiresAt,
      outletId: outletId ?? this.outletId,
      terminalId: terminalId ?? this.terminalId,
      backgroundSyncEnabled:
          backgroundSyncEnabled ?? this.backgroundSyncEnabled,
      foregroundSyncSeconds:
          foregroundSyncSeconds ?? this.foregroundSyncSeconds,
      printerName: printerName ?? this.printerName,
      printerAddress: printerAddress ?? this.printerAddress,
      printerPaperWidth: printerPaperWidth ?? this.printerPaperWidth,
      printerRoutes: printerRoutes ?? this.printerRoutes,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'backend_url': backendUrl,
      'terminal_device_key': terminalDeviceKey,
      'profile_id': profileId,
      'server_scope': serverScope,
      'mobile_api_key': mobileApiKey,
      'auth_token': authToken,
      'username': username,
      'auth_expires_at': authExpiresAt,
      'outlet_id': outletId,
      'terminal_id': terminalId,
      'background_sync_enabled': backgroundSyncEnabled,
      'foreground_sync_seconds': foregroundSyncSeconds,
      'printer_name': printerName,
      'printer_address': printerAddress,
      'printer_paper_width': printerPaperWidth,
      'printer_routes': printerRoutes,
    };
  }

  static AppSettings fromJson(Map<String, Object?> json) {
    return AppSettings(
      backendUrl: (json['backend_url'] as String?) ?? '',
      terminalDeviceKey: (json['terminal_device_key'] as String?) ?? '',
      profileId: (json['profile_id'] as String?) ?? '',
      serverScope: (json['server_scope'] as String?) ?? '',
      mobileApiKey: (json['mobile_api_key'] as String?) ?? '',
      authToken: (json['auth_token'] as String?) ?? '',
      username: (json['username'] as String?) ?? '',
      authExpiresAt: (json['auth_expires_at'] as String?) ?? '',
      outletId: (json['outlet_id'] as int?) ?? 0,
      terminalId: (json['terminal_id'] as int?) ?? 0,
      backgroundSyncEnabled: (json['background_sync_enabled'] as bool?) ?? true,
      foregroundSyncSeconds: (json['foreground_sync_seconds'] as int?) ?? 30,
      printerName: (json['printer_name'] as String?) ?? '',
      printerAddress: (json['printer_address'] as String?) ?? '',
      printerPaperWidth: (json['printer_paper_width'] as int?) ?? 58,
      printerRoutes: ((json['printer_routes'] as Map?) ?? const {}).map(
        (key, value) =>
            MapEntry(key.toString().toUpperCase(), value.toString()),
      ),
    );
  }
}

class SyncSnapshot {
  const SyncSnapshot({
    required this.online,
    required this.outboxPending,
    required this.message,
    this.lastRunText = '-',
    this.requiresLogin = false,
    this.serverReachable = false,
  });

  final bool online;
  final int outboxPending;
  final String message;
  final String lastRunText;
  final bool requiresLogin;
  final bool serverReachable;

  static const initial = SyncSnapshot(
    online: false,
    outboxPending: 0,
    message: 'Belum sinkron',
  );
}

class CashierSession {
  const CashierSession({
    required this.sessionId,
    required this.shiftId,
    required this.shiftNo,
    required this.outletName,
    required this.terminalName,
    required this.openedAt,
    required this.status,
  });

  final int sessionId;
  final int shiftId;
  final String shiftNo;
  final String outletName;
  final String terminalName;
  final String openedAt;
  final String status;

  bool get isOpen => status.toUpperCase() == 'OPEN';

  static CashierSession? fromJson(Map<String, Object?>? json) {
    if (json == null || json.isEmpty) {
      return null;
    }
    return CashierSession(
      sessionId: _intValue(json['id']),
      shiftId: _intValue(json['shift_id']),
      shiftNo: _stringValue(json['shift_no'], '-'),
      outletName: _stringValue(json['outlet_name'], '-'),
      terminalName: _stringValue(json['terminal_name'], '-'),
      openedAt: _stringValue(json['opened_at'], '-'),
      status: _stringValue(json['session_status'], 'OPEN'),
    );
  }
}

class ProductItem {
  const ProductItem({
    required this.id,
    required this.code,
    required this.name,
    required this.divisionName,
    required this.price,
    required this.availabilityStatus,
    this.photoUrl = '',
    this.divisionId = 0,
    this.categoryId = 0,
    this.estimatedAvailableQty = 0,
  });

  final int id;
  final String code;
  final String name;
  final String divisionName;
  final double price;
  final String availabilityStatus;
  final String photoUrl;
  final int divisionId;
  final int categoryId;
  final double estimatedAvailableQty;

  static ProductItem fromJson(Map<String, Object?> json) {
    return ProductItem(
      id: _intValue(json['id']),
      code: _stringValue(json['product_code'], '-'),
      name: _stringValue(json['product_name'], '-'),
      divisionName: _stringValue(json['product_division_name'], '-'),
      price: _doubleValue(json['selling_price']),
      availabilityStatus: _stringValue(
        json['availability_status'] ?? json['cache_availability_status'],
        'UNKNOWN',
      ),
      photoUrl: _stringValue(json['photo_url'] ?? json['photo_path'], ''),
      divisionId: _intValue(json['product_division_id'] ?? json['division_id']),
      categoryId: _intValue(json['product_category_id'] ?? json['category_id']),
      estimatedAvailableQty: _doubleValue(
        json['estimated_available_qty'] ??
            json['cache_estimated_available_qty'] ??
            json['available_qty'],
      ),
    );
  }
}

class BundleItem {
  const BundleItem({
    required this.id,
    required this.code,
    required this.name,
    required this.divisionName,
    required this.price,
    required this.availabilityStatus,
    required this.estimatedAvailableQty,
    required this.items,
    this.photoUrl = '',
  });

  final int id;
  final String code;
  final String name;
  final String divisionName;
  final double price;
  final String availabilityStatus;
  final double estimatedAvailableQty;
  final List<BundleComponent> items;
  final String photoUrl;

  int get divisionId => items.isEmpty ? 0 : items.first.divisionId;

  static BundleItem fromJson(Map<String, Object?> json) {
    final rawItems = json['items'];
    return BundleItem(
      id: _intValue(json['id']),
      code: _stringValue(json['bundle_code'], '-'),
      name: _stringValue(json['bundle_name'], '-'),
      divisionName: _stringValue(json['product_division_name'], '-'),
      price: _doubleValue(json['selling_price']),
      availabilityStatus: _stringValue(json['availability_status'], 'CHECK'),
      estimatedAvailableQty: _doubleValue(json['estimated_available_qty']),
      photoUrl: _stringValue(
        json['photo_url'] ?? json['photo_path'] ?? json['image_url'],
        '',
      ),
      items:
          rawItems is List
              ? rawItems
                  .whereType<Map>()
                  .map(
                    (row) => BundleComponent.fromJson(
                      Map<String, Object?>.from(row),
                    ),
                  )
                  .toList()
              : const [],
    );
  }
}

class BundleComponent {
  const BundleComponent({
    required this.productId,
    required this.code,
    required this.name,
    required this.divisionName,
    required this.divisionId,
    required this.qty,
    required this.unitPrice,
    required this.availabilityStatus,
    required this.estimatedAvailableQty,
  });

  final int productId;
  final String code;
  final String name;
  final String divisionName;
  final int divisionId;
  final double qty;
  final double unitPrice;
  final String availabilityStatus;
  final double estimatedAvailableQty;

  static BundleComponent fromJson(Map<String, Object?> json) {
    return BundleComponent(
      productId: _intValue(json['product_id']),
      code: _stringValue(json['product_code'], '-'),
      name: _stringValue(json['product_name'], '-'),
      divisionName: _stringValue(json['product_division_name'], '-'),
      divisionId: _intValue(json['product_division_id']),
      qty: _doubleValue(json['qty']),
      unitPrice: _doubleValue(json['unit_price']),
      availabilityStatus: _stringValue(json['availability_status'], 'CHECK'),
      estimatedAvailableQty: _doubleValue(json['estimated_available_qty']),
    );
  }
}

class CartLine {
  const CartLine({
    required this.product,
    required this.qty,
    this.notes = '',
    this.extras = const [],
    this.bundleId = 0,
    this.bundleName = '',
    this.bundleGroupId = 0,
    this.orderLineId = 0,
  });

  final ProductItem product;
  final int qty;
  final String notes;
  final List<CartExtra> extras;
  final int bundleId;
  final String bundleName;
  final int bundleGroupId;
  final int orderLineId;

  double get extraTotal => extras.fold(0, (sum, extra) => sum + extra.total);
  double get total => product.price * qty + extraTotal;

  CartLine copyWith({int? qty, String? notes, List<CartExtra>? extras}) {
    return CartLine(
      product: product,
      qty: qty ?? this.qty,
      notes: notes ?? this.notes,
      extras: extras ?? this.extras,
      bundleId: bundleId,
      bundleName: bundleName,
      bundleGroupId: bundleGroupId,
      orderLineId: orderLineId,
    );
  }

  Map<String, Object?> toOrderJson(int lineNo) {
    return {
      'line_no': lineNo,
      'product_id': product.id,
      'product_code': product.code,
      'product_name': product.name,
      if (orderLineId > 0) 'order_line_id': orderLineId,
      if (bundleId > 0) 'bundle_id': bundleId,
      'qty': qty,
      'unit_price': product.price,
      'gross_amount': total,
      'net_amount': total,
      'notes': notes,
      'extras': extras.map((extra) => extra.toJson()).toList(),
    };
  }
}

class CartExtra {
  const CartExtra({
    required this.extraId,
    required this.name,
    required this.qty,
    required this.unitPrice,
    this.notes = '',
  });

  final int extraId;
  final String name;
  final double qty;
  final double unitPrice;
  final String notes;

  double get total => qty * unitPrice;

  Map<String, Object?> toJson() => {
    'extra_id': extraId,
    'extra_name': name,
    'qty': qty,
    'unit_price': unitPrice,
    'notes': notes,
  };
}

class MemberItem {
  const MemberItem({
    required this.id,
    required this.memberNo,
    required this.name,
    required this.phone,
    required this.tier,
    required this.pointBalance,
    required this.stampBalance,
  });

  final int id;
  final String memberNo;
  final String name;
  final String phone;
  final String tier;
  final double pointBalance;
  final double stampBalance;

  static MemberItem fromJson(Map<String, Object?> json) => MemberItem(
    id: _intValue(json['id']),
    memberNo: _stringValue(json['member_no'], '-'),
    name: _stringValue(json['member_name'], '-'),
    phone: _stringValue(json['mobile_phone'], '-'),
    tier: _stringValue(json['member_tier'], '-'),
    pointBalance: _doubleValue(json['point_balance_cache']),
    stampBalance: _doubleValue(json['stamp_balance_cache']),
  );
}

class PaymentMethod {
  const PaymentMethod({required this.id, required this.name, this.type = ''});

  final int id;
  final String name;
  final String type;

  static PaymentMethod fromJson(Map<String, Object?> json) => PaymentMethod(
    id: _intValue(json['id']),
    name: _stringValue(json['method_name'], '-'),
    type: _stringValue(json['method_type'], 'OTHER'),
  );
}

int _intValue(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _doubleValue(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

String _stringValue(Object? value, String fallback) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}
