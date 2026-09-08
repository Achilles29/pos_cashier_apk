package com.namuaprojects.finance.pos

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.os.Build
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.google.zxing.BarcodeFormat
import com.google.zxing.MultiFormatWriter
import org.json.JSONArray
import java.io.IOException
import java.io.ByteArrayOutputStream
import java.util.UUID
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

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
                    call.argument<String>("segmentsJson") ?: "",
                    call.argument<Int>("paperWidthMm") ?: 80,
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
        segmentsJson: String,
        paperWidthMm: Int,
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
                val body = sanitizePlainThermalText(text)
                val output = ByteArrayOutputStream()
                repeat(safeCopies) {
                    output.write(byteArrayOf(0x1B, 0x40))
                    if (hasPrintSegments(segmentsJson)) {
                        writePrintSegments(output, segmentsJson, paperWidthMm)
                    } else {
                        output.write(body)
                    }
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

    private fun hasPrintSegments(raw: String): Boolean {
        return try {
            raw.isNotBlank() && JSONArray(raw).length() > 0
        } catch (_: Exception) {
            false
        }
    }

    private fun writePrintSegments(output: ByteArrayOutputStream, raw: String, paperWidthMm: Int) {
        val segments = try { JSONArray(raw) } catch (_: Exception) { null } ?: return
        val maxDots = if (paperWidthMm == 58) 384 else 576
        for (index in 0 until segments.length()) {
            val segment = segments.optJSONObject(index) ?: continue
            when (segment.optString("type").lowercase()) {
                "text" -> output.write(sanitizePlainThermalText(segment.optString("text")))
                "feed" -> output.write(ByteArray(segment.optInt("lines", 1).coerceIn(1, 5)) { '\n'.code.toByte() })
                "image_base64" -> {
                    val encoded = segment.optString("data")
                    val bytes = try { Base64.decode(encoded, Base64.DEFAULT) } catch (_: Exception) { null }
                    val bitmap = bytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
                    if (bitmap != null) {
                        output.write(bitmapToRaster(bitmap, maxDots))
                        output.write(byteArrayOf(0x0A))
                        bitmap.recycle()
                    }
                }
                "qrcode" -> {
                    val value = segment.optString("data").trim()
                    if (value.isNotEmpty()) {
                        val bitmap = createCodeBitmap(value, BarcodeFormat.QR_CODE, min(maxDots, 320), min(maxDots, 320))
                        if (bitmap != null) {
                            output.write(bitmapToRaster(bitmap, maxDots))
                            output.write(byteArrayOf(0x0A))
                            bitmap.recycle()
                        }
                    }
                }
                "barcode" -> {
                    val value = segment.optString("data").trim()
                    if (value.isNotEmpty()) {
                        val bitmap = createCodeBitmap(value, BarcodeFormat.CODE_128, maxDots, 72)
                        if (bitmap != null) {
                            output.write(bitmapToRaster(bitmap, maxDots))
                            output.write(byteArrayOf(0x0A))
                            bitmap.recycle()
                        }
                    }
                }
            }
        }
    }

    private fun createCodeBitmap(value: String, format: BarcodeFormat, width: Int, height: Int): Bitmap? {
        return try {
            val matrix = MultiFormatWriter().encode(value, format, width, height)
            val bitmap = Bitmap.createBitmap(matrix.width, matrix.height, Bitmap.Config.ARGB_8888)
            for (x in 0 until matrix.width) {
                for (y in 0 until matrix.height) {
                    bitmap.setPixel(x, y, if (matrix[x, y]) Color.BLACK else Color.WHITE)
                }
            }
            bitmap
        } catch (_: Exception) {
            null
        }
    }

    private fun bitmapToRaster(source: Bitmap, maxDots: Int): ByteArray {
        val scale = min(1.0, maxDots.toDouble() / max(1, source.width).toDouble())
        val bitmap = if (scale < 1.0) {
            Bitmap.createScaledBitmap(source, max(1, (source.width * scale).toInt()), max(1, (source.height * scale).toInt()), true)
        } else {
            source
        }
        val widthBytes = ceil(bitmap.width / 8.0).toInt()
        val output = ByteArrayOutputStream()
        output.write(byteArrayOf(0x1D, 0x76, 0x30, 0x00,
            (widthBytes and 0xFF).toByte(), ((widthBytes shr 8) and 0xFF).toByte(),
            (bitmap.height and 0xFF).toByte(), ((bitmap.height shr 8) and 0xFF).toByte()))
        for (y in 0 until bitmap.height) {
            for (byteIndex in 0 until widthBytes) {
                var value = 0
                for (bit in 0..7) {
                    val x = byteIndex * 8 + bit
                    if (x < bitmap.width) {
                        val pixel = bitmap.getPixel(x, y)
                        // PNG logos frequently have transparent pixels whose
                        // hidden RGB value is black. Composite those pixels on
                        // white before thresholding, otherwise the transparent
                        // canvas is printed as one solid black rectangle.
                        val sourceLuminance = (Color.red(pixel) * 299 + Color.green(pixel) * 587 + Color.blue(pixel) * 114) / 1000
                        val alpha = Color.alpha(pixel)
                        val luminance = (sourceLuminance * alpha + 255 * (255 - alpha)) / 255
                        if (luminance < 180) value = value or (1 shl (7 - bit))
                    }
                }
                output.write(value)
            }
        }
        if (bitmap !== source) bitmap.recycle()
        return output.toByteArray()
    }

    private fun sanitizePlainThermalText(text: String): ByteArray {
        var normalized = text.replace("\r\n", "\n").replace('\r', '\n')
        normalized = Regex(
            "(?is)\\[\\[(?:LOGO_URL|LOGO_BASE64|BARCODE|QRCODE)(?::.*?)?\\]\\]"
        ).replace(normalized, "")
        normalized = Regex(
            "(?i)data:image/[a-z0-9.+-]+;base64,[a-z0-9+/=\\r\\n]+"
        ).replace(normalized, "")
        normalized = Regex("\\[\\[FEED:(\\d+)\\]\\]", RegexOption.IGNORE_CASE).replace(normalized) { match ->
            "\n".repeat(match.groupValues.getOrNull(1)?.toIntOrNull()?.coerceIn(1, 5) ?: 1)
        }
        normalized = normalized.filter { character ->
            character == '\t' || character == '\n' || character in ' '..'~'
        }
        return (normalized.trimEnd() + "\n").toByteArray(Charsets.US_ASCII)
    }
}
