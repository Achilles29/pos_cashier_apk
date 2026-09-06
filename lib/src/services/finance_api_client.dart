import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';

class FinanceApiException implements Exception {
  const FinanceApiException({
    required this.statusCode,
    required this.path,
    required this.message,
    this.data = const {},
  });

  final int statusCode;
  final String path;
  final String message;
  final Map<String, Object?> data;

  bool get isUnauthorized => statusCode == 401;

  String get userMessage {
    if (statusCode == 401) {
      final detail = message.trim();
      if (detail.contains('Kredensial atau perangkat tidak valid')) {
        return 'Login ditolak. Pastikan username/password Finance2 benar dan device key APK sudah sama persis dengan terminal Android yang aktif di Finance2 > POS > Outlet + Terminal.';
      }
      if (detail.isNotEmpty &&
          detail != 'Token mobile atau sesi login tidak tersedia.') {
        return detail;
      }
      return 'Sesi login berakhir atau kredensial perangkat belum valid. Periksa username, password, dan device key terminal.';
    }
    if (statusCode == 403) {
      if (message.contains('Sesi kasir tidak sesuai dengan perangkat')) {
        return 'Perangkat terhubung sebagai backup kasir. Pastikan akun dan outletnya sama dengan sesi Finance2 yang sedang aktif.';
      }
      if (path.contains('/printers')) {
        return 'Akun ini belum diberi akses printer. Hubungi admin untuk mengaktifkannya.';
      }
      return 'Akun tidak memiliki akses ke fitur POS ini.';
    }
    if (statusCode == 404) {
      if (path.contains('/printers/test')) {
        return 'Server Finance belum diperbarui untuk test print. Upload Pos_mobile.php dan routes.php terbaru ke server ini.';
      }
      return 'Endpoint POS mobile belum tersedia di server.';
    }
    if (statusCode == 422) {
      return message;
    }
    if (statusCode >= 500) {
      return 'Server Finance sedang bermasalah. Coba lagi nanti.';
    }
    if (statusCode > 0) {
      return 'Server menolak permintaan. Periksa data lalu coba lagi.';
    }
    return 'Server tidak dapat dijangkau. Data lokal tetap aman.';
  }

  @override
  String toString() => 'Finance API HTTP $statusCode ($path): $message';
}

class FinanceApiClient {
  FinanceApiClient({required this.settings, http.Client? client})
    : _client = client ?? http.Client();

  final AppSettings settings;
  final http.Client _client;

  Map<String, String> get _headers {
    final headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'X-Pos-Terminal-Key': settings.terminalDeviceKey,
      // Finance2 token authorization uses the explicit mobile device header.
      // Keep the terminal alias for older deployments during the transition.
      'X-Pos-Mobile-Device-Key': settings.terminalDeviceKey,
    };
    if (settings.mobileApiKey.trim().isNotEmpty) {
      headers['X-Pos-Mobile-Key'] = settings.mobileApiKey.trim();
    }
    if (settings.authToken.trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer ${settings.authToken.trim()}';
      headers['X-Pos-Mobile-Token'] = settings.authToken.trim();
    }
    return headers;
  }

  Future<Map<String, Object?>> ping() {
    return getJson('/pos-mobile/ping');
  }

  Future<Map<String, Object?>> login({
    required String identifier,
    required String password,
  }) {
    return postJson('/pos-mobile/auth/login', {
      'identifier': identifier,
      'password': password,
      'terminal_device_key': settings.terminalDeviceKey,
      'device_label': 'Android POS',
    });
  }

  Future<Map<String, Object?>> logout() {
    return postJson('/pos-mobile/auth/logout', const {});
  }

  Future<Map<String, Object?>> bootstrap({String since = ''}) {
    final query = <String, String>{'since': since};
    if (settings.authToken.trim().isEmpty && settings.outletId > 0) {
      query['outlet_id'] = '${settings.outletId}';
    }
    return getJson('/pos-mobile/bootstrap', query: query);
  }

  Future<Map<String, Object?>> catalog({
    String query = '',
    String mode = 'PRODUCT',
    int divisionId = 0,
    int categoryId = 0,
    int limit = 60,
  }) {
    final requestQuery = <String, String>{
      'q': query,
      'mode': mode,
      'division_id': '$divisionId',
      'category_id': '$categoryId',
      'limit': '$limit',
    };
    if (settings.authToken.trim().isEmpty && settings.outletId > 0) {
      requestQuery['outlet_id'] = '${settings.outletId}';
    }
    return getJson('/pos-mobile/catalog', query: requestQuery);
  }

  Future<Map<String, Object?>> memberSearch(String query) {
    return getJson('/pos-mobile/members/search', query: {'q': query});
  }

  Future<Map<String, Object?>> extraOptions(int productId) {
    return getJson(
      '/pos-mobile/products/extra-options',
      query: {'product_id': '$productId'},
    );
  }

  Future<Map<String, Object?>> printers({String query = ''}) {
    final requestQuery = <String, String>{
      'q': query,
      'status': 'ACTIVE',
      'limit': '100',
    };
    if (settings.authToken.trim().isEmpty && settings.outletId > 0) {
      requestQuery['outlet_id'] = '${settings.outletId}';
    }
    return getJson('/pos-mobile/printers', query: requestQuery);
  }

  Future<Map<String, Object?>> printerTest(int printerId) {
    // Finance builds the preview and print payload server-side and protects
    // this action with POST so a browser refresh cannot create an attempt.
    return postJson('/pos-mobile/printers/test/$printerId', const {});
  }

  Future<Map<String, Object?>> reservations({
    String query = '',
    String statusTab = 'ACTIVE',
    int page = 1,
  }) {
    return getJson(
      '/pos-mobile/reservations',
      query: {
        'q': query,
        'status_tab': statusTab,
        'page': '$page',
        'limit': '25',
      },
    );
  }

  Future<Map<String, Object?>> reservationProducts({
    String query = '',
    String statusTab = 'ACTIVE',
    int page = 1,
  }) {
    return getJson(
      '/pos-mobile/reservations/products',
      query: {
        'q': query,
        'status_tab': statusTab,
        'page': '$page',
        'limit': '50',
      },
    );
  }

  Future<Map<String, Object?>> reservationDetail(int reservationId) {
    return getJson('/pos-mobile/reservations/$reservationId');
  }

  Future<Map<String, Object?>> reservationVerify(int reservationId) {
    return postJson('/pos-mobile/reservations/verify/$reservationId', const {});
  }

  Future<Map<String, Object?>> reservationReject(
    int reservationId,
    String reason,
  ) {
    return postJson('/pos-mobile/reservations/reject/$reservationId', {
      'reason': reason,
    });
  }

  Future<Map<String, Object?>> selfOrderInbox({
    String query = '',
    String statusTab = 'ALL',
    int page = 1,
  }) {
    return getJson(
      '/pos-mobile/incoming/self-order',
      query: {
        'q': query,
        'status_tab': statusTab,
        'page': '$page',
        'limit': '25',
      },
    );
  }

  Future<Map<String, Object?>> selfOrderInboxDetail(int orderId) {
    return getJson('/pos-mobile/incoming/self-order/$orderId');
  }

  Future<Map<String, Object?>> selfOrderInboxVerify(int orderId) {
    return postJson(
      '/pos-mobile/incoming/self-order/verify/$orderId',
      const {},
    );
  }

  Future<Map<String, Object?>> selfOrderInboxReject(
    int orderId,
    String reason,
  ) {
    return postJson('/pos-mobile/incoming/self-order/reject/$orderId', {
      'reason': reason,
    });
  }

  Future<Map<String, Object?>> onlineFoodInbox({
    String query = '',
    String statusTab = 'ALL',
    int page = 1,
  }) {
    return getJson(
      '/pos-mobile/incoming/online-food',
      query: {
        'q': query,
        'status_tab': statusTab,
        'page': '$page',
        'limit': '25',
      },
    );
  }

  Future<Map<String, Object?>> onlineFoodInboxDetail(int orderId) {
    return getJson('/pos-mobile/incoming/online-food/$orderId');
  }

  Future<Map<String, Object?>> onlineFoodInboxVerify(int orderId) {
    return postJson(
      '/pos-mobile/incoming/online-food/verify/$orderId',
      const {},
    );
  }

  Future<Map<String, Object?>> onlineFoodInboxReject(
    int orderId,
    String reason,
  ) {
    return postJson('/pos-mobile/incoming/online-food/reject/$orderId', {
      'reason': reason,
    });
  }

  Future<Map<String, Object?>> orders({
    String query = '',
    String status = 'ACTIVE',
    int page = 1,
    String dateFrom = '',
    String dateTo = '',
  }) {
    return getJson(
      '/pos-mobile/orders',
      query: {
        'q': query,
        'status': status,
        'page': '$page',
        'date_from': dateFrom,
        'date_to': dateTo,
      },
    );
  }

  Future<Map<String, Object?>> orderLoad(int orderId) {
    return getJson('/pos-mobile/orders/$orderId');
  }

  Future<Map<String, Object?>> reversalPreview(int orderId) {
    return getJson('/pos-mobile/orders/reversal-preview/$orderId');
  }

  Future<Map<String, Object?>> voidSave(Map<String, Object?> payload) {
    return postJson('/pos-mobile/orders/void/save', payload);
  }

  Future<Map<String, Object?>> refundSave(Map<String, Object?> payload) {
    return postJson('/pos-mobile/orders/refund/save', payload);
  }

  Future<Map<String, Object?>> voidPrintTargets(int voidId) {
    return getJson('/pos-mobile/orders/void/print-targets/$voidId');
  }

  Future<Map<String, Object?>> refundPrintTargets(int refundId) {
    return getJson('/pos-mobile/orders/refund/print-targets/$refundId');
  }

  Future<Map<String, Object?>> orderReprintTargets(
    int orderId, {
    String lineScope = 'ALL',
    int printerId = 0,
  }) {
    return postJson('/pos-mobile/orders/reprint-targets/$orderId', {
      'line_scope': lineScope,
      'printer_id': printerId,
    });
  }

  Future<Map<String, Object?>> orderConfirmPrintTargets(int orderId) {
    return getJson('/pos-mobile/orders/confirm/print-targets/$orderId');
  }

  Future<Map<String, Object?>> paymentPrepare(int orderId) {
    return getJson('/pos-mobile/orders/payment/prepare/$orderId');
  }

  Future<Map<String, Object?>> orderConfirm(Map<String, Object?> payload) {
    return postJson('/pos-mobile/orders/confirm', payload);
  }

  Future<Map<String, Object?>> voucherSearch({
    required int orderId,
    String query = '',
  }) async {
    try {
      return await getJson(
        '/pos-mobile/orders/payment/voucher-search',
        query: {'order_id': '$orderId', 'q': query},
      );
    } on FinanceApiException catch (error) {
      // Finance may return HTTP 422 with preview rows when a typed voucher
      // is invalid. Keep those rows visible so the cashier gets feedback.
      if (error.statusCode == 422 && error.data['rows'] is List) {
        return {
          'ok': false,
          'rows': error.data['rows'],
          'message': error.message,
        };
      }
      rethrow;
    }
  }

  Future<Map<String, Object?>> paymentSave(Map<String, Object?> payload) {
    return postJson('/pos-mobile/orders/payment/save', payload);
  }

  Future<Map<String, Object?>> paymentPrintTargets(int paymentId) {
    return getJson('/pos-mobile/orders/payment/print-targets/$paymentId');
  }

  Future<Map<String, Object?>> sessionStatus() {
    final query = <String, String>{
      'terminal_device_key': settings.terminalDeviceKey,
    };
    if (settings.authToken.trim().isEmpty) {
      query['outlet_id'] = '${settings.outletId}';
      query['terminal_id'] = '${settings.terminalId}';
    }
    return getJson('/pos-mobile/cashier/session-status', query: query);
  }

  Future<Map<String, Object?>> cashierOpen({
    required double openingCash,
    int? outletId,
    int? terminalId,
  }) {
    return postJson('/pos-mobile/cashier/open', {
      'outlet_id': outletId ?? settings.outletId,
      'terminal_id': terminalId ?? settings.terminalId,
      'opening_cash': openingCash,
    });
  }

  Future<Map<String, Object?>> cashierClosePreview() {
    return getJson('/pos-mobile/cashier/close-preview');
  }

  Future<Map<String, Object?>> cashierClose({required double actualCash}) {
    return postJson('/pos-mobile/cashier/close', {
      'actual_cash': actualCash,
      'notes': 'Ditutup dari Android POS',
    });
  }

  Future<Map<String, Object?>> pushOrder(Map<String, Object?> payload) {
    return postJson('/pos-mobile/orders/push', payload);
  }

  Future<Map<String, Object?>> getJson(
    String path, {
    Map<String, String> query = const {},
  }) async {
    final uri = _uri(path, query);
    final response = await _client
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 8));
    return _decode(response, uri);
  }

  Future<Map<String, Object?>> postJson(
    String path,
    Map<String, Object?> payload,
  ) async {
    final uri = _uri(path);
    final response = await _client
        .post(uri, headers: _headers, body: jsonEncode(payload))
        .timeout(const Duration(seconds: 12));
    return _decode(response, uri);
  }

  Uri _uri(String path, [Map<String, String> query = const {}]) {
    final base = settings.normalizedBackendUrl;
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$base$normalizedPath');
    final cleanQuery = Map<String, String>.from(query)
      ..removeWhere((key, value) => value.trim().isEmpty);
    return uri.replace(queryParameters: cleanQuery.isEmpty ? null : cleanQuery);
  }

  Map<String, Object?> _decode(http.Response response, Uri uri) {
    final text = response.body.trim();
    if (text.isNotEmpty && !text.startsWith('{') && !text.startsWith('[')) {
      final snippet =
          text.length > 80 ? '${text.substring(0, 80).trim()}...' : text;
      throw FinanceApiException(
        statusCode: response.statusCode,
        path: uri.path,
        message:
            'Server belum membalas JSON. Kemungkinan endpoint belum terpasang, URL backend salah, atau request diarahkan ke login web. Awal response: $snippet',
      );
    }

    final parsed = text.isEmpty ? <String, Object?>{} : jsonDecode(text);
    if (parsed is! Map<String, Object?>) {
      throw FinanceApiException(
        statusCode: response.statusCode,
        path: uri.path,
        message: 'Response bukan object JSON yang valid.',
      );
    }
    final decoded = parsed;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message =
          decoded['message']?.toString() ??
          'HTTP ${response.statusCode} dari server finance untuk ${uri.path}.';
      throw FinanceApiException(
        statusCode: response.statusCode,
        path: uri.path,
        message: message,
        data: decoded,
      );
    }
    return decoded;
  }
}
