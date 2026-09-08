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
    if (printed > 0) {
      parts.add('$printed printer berhasil menerima cetakan');
    }
    if (missing.isNotEmpty) {
      parts.add('printer belum terhubung: ${missing.join(', ')}');
    }
    if (failed.isNotEmpty) {
      parts.add('printer tidak merespons: ${failed.join(', ')}');
    }
    return parts.isEmpty
        ? 'Finance belum mengirim tujuan cetak aktif.'
        : parts.join('; ');
  }
}

/// Finance determines *what* is printed; the Android binding determines the
/// physical paper width and text density for its own Bluetooth printer.
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
      final localPrinter = await _database.localPrinterFor(printerId);
      final address =
          localPrinter?['bluetooth_address']?.toString().trim() ?? '';
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
        final paperWidth = _boundedPaperWidth(localPrinter?['paper_width']);
        final charsPerLine = _boundedCharsPerLine(
          localPrinter?['chars_per_line'],
          paperWidth,
        );
        await _printer.printText(
          address: address,
          text: _fitTextToLineWidth(text, charsPerLine),
          segments: _fitSegmentsToLineWidth(
            target['print_segments'],
            charsPerLine,
          ),
          paperWidthMm: paperWidth,
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

  int _boundedPaperWidth(Object? value) {
    return _asInt(value) == 58 ? 58 : 80;
  }

  int _boundedCharsPerLine(Object? value, int paperWidth) {
    final fallback = paperWidth == 58 ? 32 : 48;
    final min = paperWidth == 58 ? 24 : 32;
    final max = paperWidth == 58 ? 48 : 64;
    final chars = _asInt(value);
    return chars < min || chars > max ? fallback : chars;
  }

  List<Map<String, Object?>> _fitSegmentsToLineWidth(
    Object? rawSegments,
    int charsPerLine,
  ) {
    if (rawSegments is! List) return const [];
    return rawSegments.whereType<Map>().map((raw) {
      final segment = Map<String, Object?>.from(raw);
      if (segment['type']?.toString().toLowerCase() == 'text') {
        segment['text'] = _fitTextToLineWidth(
          segment['text']?.toString() ?? '',
          charsPerLine,
        );
      }
      return segment;
    }).toList();
  }

  String _fitTextToLineWidth(String raw, int charsPerLine) {
    return raw
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .expand((line) => _wrapThermalLine(line, charsPerLine))
        .join('\n');
  }

  List<String> _wrapThermalLine(String rawLine, int charsPerLine) {
    final line = rawLine.trimRight();
    if (line.length <= charsPerLine) return [line];
    final stripped = line.trim();
    if (stripped.isNotEmpty && stripped.split('').every((char) => char == stripped[0])) {
      return [List<String>.filled(charsPerLine, stripped[0]).join()];
    }
    final words = stripped.split(RegExp(r'\s+'));
    final rows = <String>[];
    var row = '';
    for (final word in words) {
      if (word.length > charsPerLine) {
        if (row.isNotEmpty) {
          rows.add(row);
          row = '';
        }
        for (var index = 0; index < word.length; index += charsPerLine) {
          rows.add(
            word.substring(
              index,
              (index + charsPerLine).clamp(0, word.length).toInt(),
            ),
          );
        }
        continue;
      }
      final candidate = row.isEmpty ? word : '$row $word';
      if (candidate.length > charsPerLine) {
        if (row.isNotEmpty) rows.add(row);
        row = word;
      } else {
        row = candidate;
      }
    }
    if (row.isNotEmpty) rows.add(row);
    return rows.isEmpty ? [''] : rows;
  }
}
