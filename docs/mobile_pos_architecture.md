# Arsitektur Mobile POS APK

Dokumen ini menjembatani APK Flutter dengan backend CodeIgniter 3 `finance`.

## File finance yang sudah dipetakan

File utama:

- `finance/application/controllers/Pos.php`
- `finance/application/models/Pos_model.php`
- `finance/application/models/Pos_report_model.php`
- `finance/application/models/Pos_order_monitor_model.php`
- `finance/application/libraries/PosStockCommitService.php`
- `finance/application/libraries/PosOrderStockService.php`
- `finance/application/libraries/PosRuntimeJobService.php`
- `finance/application/libraries/PosAvailabilityRebuildService.php`
- `finance/application/libraries/PosBundlePricingService.php`
- `finance/application/libraries/PosPrinterPreviewService.php`

Area yang berpengaruh ke APK:

- kasir dan shift: `open_cashier_session`, `find_active_cashier_session`, `close_cashier_session`, `cashier_close_preview`
- katalog: `order_product_catalog`, `order_bundle_catalog`, `order_extra_options`
- member/CRM: `order_member_search`, tabel `crm_member`
- voucher/deposit/loyalty: `cashier_payment_prepare`, `search_cashier_vouchers`, `save_cashier_payment`
- order: `save_order_draft`, `finalize_order_confirmation`, `find_order_draft`
- stock/HPP: `resolve_order_stock_commit_payload`, `PosStockCommitService`, `PosOrderStockService`, `PosAvailabilityRebuildService`
- printer: `direct_print_targets_for_order_confirm`, `direct_print_targets_for_payment`, `direct_print_targets_for_void`, `direct_print_targets_for_refund`, `direct_print_targets_for_shift_close`
- monitor dapur/bar/checker: `Pos_order_monitor_model::sync_order_tasks`

## Prinsip sinkronisasi

Server finance tetap menjadi sumber kebenaran untuk:

- nomor order/payment/shift
- HPP final dan HPP live snapshot
- stock commit, FIFO, lot, reversal, deficit pending
- payment method, voucher, deposit, loyalty
- shift close report dan laporan kasir

APK menyimpan:

- cache master untuk UI cepat
- draft/order offline dalam outbox
- status sinkronisasi
- konfigurasi device, printer Bluetooth, dan URL backend

## Update master otomatis

Master tidak disinkron manual. Polanya:

1. Setiap tabel master server punya `updated_at`, `deleted_at` atau `is_active`, dan `sync_version`.
2. APK menyimpan `master_sync_cursor`.
3. Saat aplikasi dibuka, saat kasir aktif, dan saat background worker berjalan, APK memanggil:

```text
GET /pos-mobile/bootstrap?since={master_sync_cursor}
```

4. Server membalas katalog/master yang tersedia untuk terminal, lalu APK mengganti cache dengan data terbaru:

```json
{
  "sync_cursor": "2026-08-20T19:35:00+07:00",
  "products": [],
  "bundles": [],
  "extras": [],
  "payment_methods": [],
  "members_delta": [],
  "printers": [],
  "deleted": {
    "products": [10, 11],
    "payment_methods": []
  }
}
```

5. APK menyimpan response terbaru ke cache lokal. Pencarian katalog yang tidak ada di cache memakai `GET /pos-mobile/catalog?q=...`, sehingga katalog di atas batas bootstrap tetap bisa ditemukan.

Rekomendasi interval:

- foreground: 30 detik saat kasir aktif
- background: WorkManager periodik Android, minimal 15 menit
- setelah transaksi offline tersimpan: trigger sync langsung jika jaringan ada

## Sinkronisasi shift

Shift harus selalu server-authoritative.

APK memanggil:

```text
GET /pos-mobile/cashier/session-status?terminal_device_key=...&outlet_id=...&terminal_id=...
```

Server harus membalas sesi aktif kasir untuk employee/device tersebut. Jika shift dibuka dari web, APK menerima sesi itu pada sync berikutnya. Jika shift dibuka dari APK, server membuat `pos_shift` dan `pos_cashier_session`, lalu web melihatnya sebagai sesi aktif yang sama.

Aturan penting:

- satu terminal hanya boleh punya satu shift OPEN
- open/close shift offline sebaiknya tidak diizinkan kecuali dibuat mode darurat khusus
- order offline boleh dibuat memakai snapshot shift terakhir, tetapi server tetap harus memvalidasi saat sync

## Outbox transaksi

APK menyimpan transaksi offline ke tabel lokal:

- `local_orders`
- `sync_outbox`

Payload dikirim ke:

```text
POST /pos-mobile/orders/push
```

Payload wajib membawa:

- `local_uuid`
- `client_event_id`
- `terminal_device_key`
- `outlet_id`
- `terminal_id`
- `cashier_session_id`
- `shift_id`
- `lines`

Server harus idempotent berdasarkan `client_event_id`. Jika event yang sama terkirim dua kali, server mengembalikan hasil yang sama, bukan membuat order ganda.

## Printer Bluetooth

Web cashier saat ini mencetak lewat service lokal `127.0.0.1:{python_port}/cetak`. APK Android sebaiknya mencetak langsung ke Bluetooth ESC/POS.

Pola datanya tetap dari server:

```text
Konfigurasi printer kasir saat ini disimpan di APK (nama + alamat Bluetooth). Payload struk tetap berasal dari server melalui endpoint payment print target.
```

Server mengirim daftar printer, role, divisi, template, dan routing. APK menyimpan MAC Bluetooth per printer role/divisi. Saat transaksi sukses, server membalas `direct_print_targets`, lalu APK mengirim teks ESC/POS ke printer Bluetooth yang sesuai.

## Endpoint minimal CI3 yang perlu dibuat

```text
GET  /pos-mobile/ping
POST /pos-mobile/auth/login
GET  /pos-mobile/bootstrap
GET  /pos-mobile/cashier/session-status
POST /pos-mobile/cashier/open
POST /pos-mobile/cashier/close
POST /pos-mobile/orders/push
GET  /pos-mobile/orders/status
GET  /pos-mobile/catalog
GET  /pos-mobile/members/search
GET  /pos-mobile/products/extra-options
GET  /pos-mobile/orders
GET  /pos-mobile/orders/{id}
POST /pos-mobile/orders/save
POST /pos-mobile/orders/confirm
GET  /pos-mobile/orders/payment/prepare/{id}
GET  /pos-mobile/orders/payment/voucher-search
POST /pos-mobile/orders/payment/save
GET  /pos-mobile/orders/payment/print-targets/{id}
```

Endpoint di atas sebaiknya hanya membungkus logic `Pos_model` yang sudah ada, bukan menduplikasi hitungan HPP/stock di mobile.

## Status implementasi awal

Sudah dibuat:

- `finance/application/controllers/Pos_mobile.php`
- route:
  - `GET /pos-mobile/ping`
  - `POST /pos-mobile/auth/login`
  - `POST /pos-mobile/auth/logout`
  - `GET /pos-mobile/bootstrap`
- `GET /pos-mobile/cashier/session-status`
- `POST /pos-mobile/cashier/open`
- `GET /pos-mobile/cashier/close-preview`
- `POST /pos-mobile/cashier/close`
- `GET /pos-mobile/catalog`
- `GET /pos-mobile/members/search`
- `GET /pos-mobile/products/extra-options`
- `GET /pos-mobile/orders`
- `GET /pos-mobile/orders/{id}`
- `POST /pos-mobile/orders/save`
- `POST /pos-mobile/orders/confirm`
- `POST /pos-mobile/orders/push`
- `GET /pos-mobile/orders/payment/prepare/{id}`
- `GET /pos-mobile/orders/payment/voucher-search`
- `POST /pos-mobile/orders/payment/save`
- `GET /pos-mobile/orders/payment/print-targets/{id}`
- SQL idempotency: `finance/sql/2026-08-20a_pos_mobile_sync_foundation.sql`
- SQL token mobile: `pos_mobile_auth_token` di file SQL yang sama
- field APK `Mobile API key`, dikirim sebagai header `X-Pos-Mobile-Key`
- login APK mengirim token sebagai `Authorization: Bearer {token}`
- APK menjalankan WorkManager periodik minimal 15 menit saat jaringan tersedia.
- APK dapat membuka/menutup shift melalui endpoint mobile; server tetap menerapkan gate daily recon dan aturan shift.
- APK mengirim order draft/confirm melalui outbox yang sama, sehingga transaksi offline tidak membuat order ganda saat tersambung kembali.

Catatan security:

- Jika environment `POS_MOBILE_API_KEY` di server diisi, semua endpoint selain ping wajib membawa header `X-Pos-Mobile-Key`.
- Jika `POS_MOBILE_API_KEY` kosong, endpoint mobile tetap bisa dipakai dengan token dari `POST /pos-mobile/auth/login`.
- Push order membutuhkan `employee_id`; sekarang bisa berasal dari token mobile.

## Checklist deploy ke server online

Jika APK diisi `https://core.namuacoffee.com` tetapi muncul `HTTP 404` untuk `/pos-mobile/ping`, berarti backend mobile belum terpasang di server online.

Naikkan file berikut ke server online:

- `application/controllers/Pos_mobile.php`
- perubahan route di `application/config/routes.php`
- jalankan `sql/2026-08-20a_pos_mobile_sync_foundation.sql`

Tes setelah deploy:

```text
https://core.namuacoffee.com/pos-mobile/ping
```

Harus membalas JSON:

```json
{"ok":true,"server_time":"...","service":"finance-pos-mobile"}
```

## Kontrak APK terkini

APK dan Finance memakai kontrak capability POS Mobile versi 3. Aksi bernilai
tinggi berikut selalu meminta password sekali lagi, lalu mengirim proof yang
singkat, terikat pada user/perangkat/aksi/target, dan hanya dapat dipakai satu
kali:

- Void dan Refund order;
- Cetak ulang order;
- Tutup kasir;
- Penolakan reservasi yang sekaligus mengembalikan DP.

Password tidak pernah ditulis ke database lokal, outbox, atau payload aksi
akhir. APK meminta proof dari endpoint verify Finance tepat sebelum submit.

### Offline dan tiket printer

Order draft/confirm dapat disimpan segera saat server tidak dapat dijangkau.
Saat server kembali online, `client_event_id` membuat push tetap idempoten.
Payment, refund, void, dan tutup kasir tetap online-only karena memengaruhi
uang dan tidak boleh direplikasi dari perangkat.

Jika order confirm diterima server ketika APK sedang offline, APK membuat
tugas cetak lokal. Saat aplikasi aktif lagi, ia mengambil print target dari
Finance dan mengirim ke binding Bluetooth yang tepat. Tugas tanpa printer
yang siap ditunda dengan backoff; bila hanya sebagian target berhasil, APK
tidak mencetak otomatis ulang agar tiket dapur tidak ganda—kasir memakai
menu Cetak Ulang setelah memeriksa printer.
