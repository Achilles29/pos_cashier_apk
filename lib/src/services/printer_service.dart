import 'package:flutter/services.dart';
import 'dart:convert';

class BluetoothPrinter {
  const BluetoothPrinter({required this.name, required this.address});

  final String name;
  final String address;

  factory BluetoothPrinter.fromMap(Map<Object?, Object?> value) {
    return BluetoothPrinter(
      name: value['name']?.toString() ?? 'Bluetooth printer',
      address: value['address']?.toString() ?? '',
    );
  }
}

class PrinterService {
  static const _channel = MethodChannel('pos_cashier_apk/printer');

  Future<List<BluetoothPrinter>> bondedDevices() async {
    final rows = await _channel.invokeListMethod<Object?>('bondedDevices');
    return (rows ?? const [])
        .whereType<Map>()
        .map((row) => BluetoothPrinter.fromMap(Map<Object?, Object?>.from(row)))
        .where((printer) => printer.address.isNotEmpty)
        .toList();
  }

  Future<void> printText({
    required String address,
    required String text,
    List<Map<String, Object?>> segments = const [],
    int paperWidthMm = 80,
    int copies = 1,
    String cutMode = 'PARTIAL',
    bool openDrawer = false,
  }) {
    return _channel.invokeMethod<void>('printText', {
      'address': address,
      'text': text,
      'segmentsJson': jsonEncode(segments),
      'paperWidthMm': paperWidthMm,
      'copies': copies,
      'cutMode': cutMode,
      'openDrawer': openDrawer,
    });
  }
}
