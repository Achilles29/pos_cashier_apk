import 'local_database.dart';
import 'printer_service.dart';

class PrintDispatchResult {
  const PrintDispatchResult({
    required this.printed,
    required this.missing,
    required this.failed,
  });

  final int printed;
  final List<String> missing;
  final List<String> failed;

  bool get hasProblem => missing.isNotEmpty || failed.isNotEmpty;

  String get message {
    final parts = <String>[];
    if (printed > 0) parts.add('$printed tujuan terkirim');
    if (missing.isNotEmpty) {
      parts.add('binding belum terhubung: ${missing.join(', ')}');
    }
    if (failed.isNotEmpty) parts.add('gagal: ${failed.join(', ')}');
    return parts.isEmpty
        ? 'Tidak ada tujuan cetak aktif dari Finance.'
        : parts.join('; ');
  }
}

/// Dispatches the exact text/layout decision returned by Finance to the
/// Bluetooth binding stored in the current server scope.
class PosPrintDispatcher {
  PosPrintDispatcher({LocalDatabase? database, PrinterService? printer})
    : _database = database ?? LocalDatabase.instance,
      _printer = printer ?? PrinterService();

  final LocalDatabase _database;
  final PrinterService _printer;

  Future<PrintDispatchResult> printTargets(Iterable<Map> rawTargets) async {
    var printed = 0;
    final missing = <String>[];
    final failed = <String>[];

    for (final raw in rawTargets) {
      final target = Map<String, Object?>.from(raw);
      final printerId = _asInt(target['printer_id']);
      final role = (target['printer_role']?.toString() ?? 'CUSTOM').trim();
      final name = (target['printer_name']?.toString() ?? role).trim();
      final label = name.isEmpty ? 'printer #$printerId' : name;
      final address = await _database.exactPrinterAddressFor(printerId);
      if (address.isEmpty) {
        missing.add(label);
        continue;
      }

      final text = target['text']?.toString() ?? '';
      if (text.trim().isEmpty) {
        failed.add('$label (isi kosong)');
        continue;
      }
      try {
        await _printer.printText(
          address: address,
          text: text,
          copies: _boundedInt(target['copies'], 1, 10),
          cutMode: target['cut_mode']?.toString() ?? 'PARTIAL',
          openDrawer: _asInt(target['open_drawer']) == 1,
        );
        printed++;
      } catch (error) {
        failed.add(
          '$label (${error.toString().replaceFirst('Exception: ', '')})',
        );
      }
    }

    return PrintDispatchResult(
      printed: printed,
      missing: missing,
      failed: failed,
    );
  }

  int _asInt(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  int _boundedInt(Object? value, int fallback, int max) {
    final parsed = _asInt(value);
    return parsed <= 0 ? fallback : parsed.clamp(fallback, max);
  }
}
