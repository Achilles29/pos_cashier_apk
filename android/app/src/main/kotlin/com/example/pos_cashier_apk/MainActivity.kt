package com.example.pos_cashier_apk

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.UUID

class MainActivity : FlutterActivity() {
    private val channelName = "pos_cashier_apk/printer"
    private val sppUuid = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    private val bluetoothPermissionRequest = 4101

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "bondedDevices" -> bondedDevices(result)
                "printText" -> printText(
                    call.argument<String>("address"),
                    call.argument<String>("text"),
                    call.argument<Int>("copies") ?: 1,
                    call.argument<String>("cutMode") ?: "PARTIAL",
                    call.argument<Boolean>("openDrawer") ?: false,
                    result
                )
                else -> result.notImplemented()
            }
        }
    }

    private fun hasConnectPermission(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
    }

    private fun requireConnectPermission(result: MethodChannel.Result): Boolean {
        if (hasConnectPermission()) return true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN), bluetoothPermissionRequest)
        }
        result.error("BLUETOOTH_PERMISSION", "Izinkan akses Bluetooth lalu coba lagi.", null)
        return false
    }

    private fun bondedDevices(result: MethodChannel.Result) {
        if (!requireConnectPermission(result)) return
        val adapter = BluetoothAdapter.getDefaultAdapter()
        if (adapter == null) {
            result.error("BLUETOOTH_UNAVAILABLE", "Perangkat ini tidak memiliki Bluetooth.", null)
            return
        }
        try {
            result.success(adapter.bondedDevices.map { device: BluetoothDevice ->
                mapOf("name" to (device.name ?: "Bluetooth printer"), "address" to device.address)
            })
        } catch (error: SecurityException) {
            result.error("BLUETOOTH_PERMISSION", error.message, null)
        }
    }

    private fun printText(
        address: String?,
        text: String?,
        copies: Int,
        cutMode: String,
        openDrawer: Boolean,
        result: MethodChannel.Result
    ) {
        if (!requireConnectPermission(result)) return
        if (address.isNullOrBlank() || text.isNullOrEmpty()) {
            result.error("PRINTER_INPUT", "Alamat printer dan isi cetak wajib diisi.", null)
            return
        }
        Thread {
            var socket: android.bluetooth.BluetoothSocket? = null
            try {
                val adapter = BluetoothAdapter.getDefaultAdapter()
                val device = adapter.getRemoteDevice(address)
                socket = device.createRfcommSocketToServiceRecord(sppUuid)
                socket.connect()
                val safeCopies = copies.coerceIn(1, 10)
                val normalizedCut = cutMode.uppercase()
                val drawer = if (openDrawer) byteArrayOf(0x1B, 0x70, 0x00, 0x19, 0xFA.toByte()) else byteArrayOf()
                val cut = when (normalizedCut) {
                    "NONE" -> byteArrayOf()
                    "FULL" -> byteArrayOf(0x1D, 0x56, 0x00)
                    else -> byteArrayOf(0x1D, 0x56, 0x01)
                }
                val body = text.toByteArray(Charsets.UTF_8)
                val output = java.io.ByteArrayOutputStream()
                repeat(safeCopies) {
                    output.write(byteArrayOf(0x1B, 0x40))
                    output.write(body)
                    output.write(byteArrayOf(0x0A, 0x0A))
                    output.write(drawer)
                    output.write(cut)
                }
                val bytes = output.toByteArray()
                socket.outputStream.write(bytes)
                socket.outputStream.flush()
                runOnUiThread { result.success(true) }
            } catch (error: IOException) {
                runOnUiThread { result.error("PRINTER_IO", error.message, null) }
            } catch (error: SecurityException) {
                runOnUiThread { result.error("BLUETOOTH_PERMISSION", error.message, null) }
            } finally {
                try { socket?.close() } catch (_: IOException) { }
            }
        }.start()
    }
}
