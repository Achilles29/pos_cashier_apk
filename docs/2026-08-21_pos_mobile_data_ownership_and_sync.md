# POS Mobile - Kepemilikan Data dan Kontrak Sinkronisasi

Tanggal: 2026-08-21

Dokumen ini menjawab dua pertanyaan operasional: data mana yang menjadi milik
server, data mana yang disimpan APK, dan apa yang terjadi saat koneksi putus.

## 1. Prinsip Utama

APK sekarang menyimpan beberapa profil koneksi. Setiap profil memiliki
`profile_id`/`server_scope` sendiri. Cache, order lokal, outbox, log
sinkronisasi, dan binding printer dibaca hanya dari profil yang sedang aktif.
Mengganti URL tidak mengganti isi database profil lain.

Finance adalah sumber kebenaran. APK bukan server kedua dan tidak boleh
mengubah HPP, saldo stok final, payment, shift, member, voucher, atau master.

Sinkronisasi transaksi memakai event yang memiliki dua identitas permanen:

- `local_uuid`: identitas order yang dibuat APK;
- `client_event_id`: identitas event push yang tidak berubah saat retry.

Retry dengan identitas yang sama tidak boleh membuat order baru. Server
menyimpan hasil event di `pos_mobile_sync_event`, lalu APK memperbarui baris
lokalnya berdasarkan `server_id` dan `order_no` yang dikembalikan server.

Payment mobile juga membawa `client_event_id` yang stabil selama satu
percobaan. Jika jaringan timeout setelah payment tersimpan, retry event yang
sama membaca response payment lama dari `pos_mobile_sync_event`, bukan membuat
payment baru.

## 2. Peta Kepemilikan Data

### Server only: APK hanya membaca projection/cache

- user, permission, employee, outlet, terminal, dan shift authority;
- produk, bundle, divisi, kategori, UOM, recipe, komponen, dan extra master;
- harga POS, HPP live, availability, dan aturan stock commit;
- member, point/stamp, voucher campaign, voucher issue, dan saldo deposit;
- payment method, akun perusahaan, printer server, profile, template, route,
  dan target print;
- order final, payment, void, refund, stock ledger, batch produksi, purchase,
  adjustment, runtime job, dan laporan.

APK boleh menyimpan cache lokal untuk mempercepat tampilan, tetapi cache
memiliki timestamp dan dapat stale. Cache bukan sumber kebenaran.

### Server + APK: projection dan pekerjaan kasir lokal

- katalog, divisi, bundle, extra, payment method, availability, dan session
  status: server mengirim, APK menyimpan snapshot untuk tampilan/offline;
- order draft dan order confirmed yang dibuat APK: APK menyimpan salinan lokal
  dan outbox, server menyimpan versi resmi setelah validasi;
- status order server: server mengirim perubahan, APK memperbarui projection
  lokal dan menghapus duplikasi berdasarkan `server_id`/`local_uuid`;
- foto produk: server menyimpan `photo_path`, APK menyimpan file cache lokal;
- log sinkronisasi: lokal untuk diagnosis, bukan ledger bisnis.

Profil koneksi lama tidak dihapus saat koneksi diganti. Jika server yang sama
dipilih kembali, profil dan outbox-nya dapat digunakan lagi. Untuk menjaga
keamanan, identitas awal memakai URL backend yang dinormalisasi. Kontrak
berikutnya dapat menggantinya dengan `server_instance_id` dari Finance agar
alias URL seperti `localhost`, `10.0.2.2`, dan domain publik dapat dikenali
sebagai server yang sama bila memang menunjuk instalasi yang sama.

### APK only: tidak dikirim sebagai master server

- alamat Bluetooth, nama device Bluetooth, dan binding printer Android lokal;
- cart yang sedang diedit sebelum tombol simpan;
- cache file foto dan metadata HTTP cache;
- status UI, filter, dan preferensi perangkat.

Binding printer lokal tetap merujuk ke `server_printer_id` agar route server
tetap menjadi acuan. APK tidak membuat printer server baru dari halaman mobile.

## 3. Alur Saat Server Normal

1. APK menarik master, availability, HPP projection, dan session dari Finance.
2. Kasir memilih produk. Harga, extra, dan stok yang terlihat berasal dari
   snapshot server terakhir.
3. `Simpan Draft` membuat satu `local_orders` dan satu event outbox. Jika
   online, event segera dikirim ke `/pos-mobile/orders/push`.
4. `Simpan Transaksi` memakai event yang sama polanya, tetapi membawa
   `confirm_order=true`. Server menghitung ulang total/HPP, memeriksa session,
   recipe, dan stock sebelum mengaktifkan order dan melakukan confirmation/
   stock commit. Payment adalah proses terpisah; order aktif boleh berstatus
   `CONFIRMED` dan belum dibayar.
5. Setelah server membalas sukses, APK menyimpan `server_id`, `order_no`, dan
   status sinkron. Order kemudian muncul di tab order aktif hari ini dan dapat
   dibaca oleh admin/laporan realtime Finance sebagai omzet belum dibayar.

## 4. Alur Saat Server atau Listrik Mati

1. APK tetap dapat membuka cart dan menyimpan draft/intent transaksi ke SQLite.
   Baris tersebut langsung muncul di tab `Aktif / belum payment` sebagai order
   lokal dengan label `PENDING` atau `BLOCKED`.
2. APK tidak mengurangi stock final, tidak mengunci HPP, dan tidak menyatakan
   payment lunas. Ketersediaan yang tampil diberi makna stok terakhir yang
   diketahui dan dapat berubah.
3. Saat koneksi kembali, WorkManager/foreground sync mencoba mengirim outbox
   otomatis. Tombol `Sinkron sekarang` hanya mempercepat proses dan retry
   event yang diblokir setelah kasir memperbaiki penyebabnya.
4. Server menerima event satu per satu, memvalidasi keadaan terbaru, lalu
   menerima atau menolak. Purchase, produksi, transaksi web, void, dan refund
   yang terjadi selama APK offline tetap masuk ke ledger server dan akan
   memengaruhi validasi saat event APK tiba.
5. Jika diterima, order lokal direkonsiliasi dengan order server berdasarkan
   ID, bukan dengan menimpa seluruh database lokal. Jika ditolak, data lokal
   tetap ada dengan status `BLOCKED` dan pesan alasan untuk diperbaiki/retry.

Jadi ketika server hidup kembali, arah transaksi offline adalah:

`APK local_orders -> outbox -> server validation -> order/stock ledger Finance`

Sedangkan perubahan dari server adalah:

`Finance master/stock/order state -> sync -> cache dan tampilan APK`

Server tidak boleh menimpa event lokal yang belum terkirim. APK juga tidak
boleh menimpa angka stock server dengan angka lokal.

## 5. Status yang Harus Dipahami Kasir

| Status | Arti | Tindakan |
|---|---|---|
| `PENDING` | Tersimpan di APK, belum diterima server | Tetap aman, tunggu/retry sync |
| `SYNCED` | Server sudah menerima dan APK menyimpan `server_id` | Boleh lanjut payment jika server mengizinkan |
| `BLOCKED` | Server menolak validasi | Perbaiki shift/session/data, lalu retry manual |
| `PROCESSING` | Server masih memproses event | Jangan membuat order baru; tunggu retry |

Order lokal yang belum memiliki `server_id` belum menjadi order resmi server,
sehingga belum dapat dibayar, di-void, atau di-refund dari APK. Begitu event
`confirm_order=true` diterima server, order resmi langsung aktif dan stock
commit diproses oleh Finance walaupun payment belum dilakukan. Payment, void,
dan refund tetap harus berjalan terhadap order resmi di Finance.

## 6. Batasan dan Audit Berikutnya

- [x] Profil koneksi tersimpan dan dapat dipilih kembali dari Pengaturan POS.
- [x] Namespace lokal dipisahkan untuk cache, outbox, order, log, dan printer.
- [x] Migrasi instalasi lama memindahkan data legacy ke profil aktif satu kali.
- [x] Payment mobile memakai event idempotent agar retry timeout tidak menggandakan pembayaran.
- [ ] Tambahkan `server_instance_id` resmi dari endpoint Finance untuk
  membedakan alias URL yang menunjuk server sama.

- Payment offline belum dianggap lunas dan tetap menunggu server, tetapi
  `Simpan Transaksi` offline tetap dipush sebagai order aktif ketika koneksi
  kembali. Setelah diterima server, order tersebut masuk laporan belum bayar.
- Delta master/deleted rows perlu dilengkapi agar bootstrap tidak selalu
  mengirim seluruh katalog.
- Endpoint rekonsiliasi event perlu diuji dengan simulasi timeout tepat setelah
  server menyimpan order.
- Konflik stock karena purchase/produksi/transaksi web perlu diuji dengan data
  nyata sebelum APK dipakai operasional.
- Backup/export SQLite lokal perlu dipertimbangkan untuk perangkat kasir
  produksi.
