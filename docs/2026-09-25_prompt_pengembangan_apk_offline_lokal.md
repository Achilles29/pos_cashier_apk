# Prompt pengembangan APK POS offline di lokal

Tanggal: 25 September 2026.

Salin seluruh blok berikut ke thread pengembangan lokal. Sesuaikan lokasi folder jika `pos_cashier_apk` dan `finance` tidak berada berdampingan. Dokumen ini adalah prompt pelaksanaan, bukan roadmap tambahan atau bukti implementasi selesai.

Pedoman aktif:

- [Rolling plan APK–Finance–Control](2026-09-24_rolling_plan_apk_finance_control.md).
- [Kontrak APK–Finance–Control](2026-09-24_kontrak_apk_finance_control.md).
- [Panduan eksekusi lokal dan UAT](2026-09-24_uat_apk_dan_eksekusi_lokal.md).

```text
TUGAS: Lanjutkan pengembangan APK POS Finance sampai mendukung kasir offline
operasional, sinkronisasi dengan Finance, dan persiapan lisensi per instalasi
APK melalui Control.

Kerjakan implementasi dan pengujian secara bertahap. Pertahankan fitur serta
kode yang sudah benar. Jangan membangun ulang aplikasi dari nol.

LOKASI SUMBER

- pos_cashier_apk/ : source APK yang akan dikembangkan.
- finance/         : referensi source backend Finance terbaru.

Temukan lokasi aktual kedua folder di workspace lokal. Jangan menganggap
path /www/wwwroot tersedia pada komputer ini.

DOKUMEN PEDOMAN WAJIB

Baca dari folder pos_cashier_apk/docs:

1. 2026-09-24_rolling_plan_apk_finance_control.md
   Pedoman utama: prioritas, batch, file sasaran, kesenjangan fitur,
   checklist dan catatan kemajuan.

2. 2026-09-24_kontrak_apk_finance_control.md
   Pedoman API, kepemilikan data, sinkronisasi, lisensi perangkat,
   offline operasional dan perpindahan web–APK.

3. 2026-09-24_uat_apk_dan_eksekusi_lokal.md
   Pedoman pengujian, fixture, validasi dan kriteria selesai.

Ketiga dokumen tersebut sudah direvisi pada 25 September 2026.
Ikuti revisi tersebut: targetnya OFFLINE OPERASIONAL, bukan hanya antrean
draft. Skenario O01–O16 wajib menjadi acceptance test.

Dokumen lama boleh menjadi referensi historis, tetapi tidak boleh
mengalahkan ketiga pedoman aktif. Jangan membaca atau mengubah _note/_NOTE.

Bandingkan catatan audit dengan source terbaru. Bila sebuah temuan ternyata
sudah diperbaiki, buktikan dengan test dan jangan memperbaikinya ulang.

============================================================
1. KONSEP PRODUK YANG WAJIB DIPERTAHANKAN
============================================================

APK merupakan kasir yang dapat berjalan ketika server Finance mati atau
koneksi terputus. APK dan POS web dapat saling menggantikan, dengan sesi
kasir yang sama sesuai akun, outlet dan kewenangan.

SKENARIO A — KASIR SEJAK AWAL MENGGUNAKAN APK

- Ketika online, APK menyinkronkan master, aturan dan transaksi.
- Ketika server terputus, kasir tetap dapat membuat pesanan, menerima
  pembayaran tunai, menghitung kembalian, mencetak struk, dan mencatat
  pergerakan stok serta keuangan lokal.
- Transaksi tersimpan utuh di database lokal, bukan hanya cart/draft.
- Ketika server kembali, transaksi disinkronkan tanpa duplikasi.

SKENARIO B — KASIR WEB BERPINDAH KE APK

- Sebelum pemadaman, operator menjalankan “Siapkan / Lanjutkan Kasir di APK”.
- APK menerima snapshot konsisten: sesi, pesanan berjalan, pembayaran,
  saldo pembuka, master, aturan, stok dan pengaturan cetak yang diperlukan.
- Tampilkan “Siap offline” hanya setelah persiapan benar-benar lengkap.
- Sesi kasir tidak perlu ditutup untuk berpindah.
- Pesanan yang dialihkan harus terlindungi dari perubahan/pembayaran
  bersamaan melalui web atau perangkat lain.
- Setelah server pulih, sinkronkan dan lakukan handback sebelum kembali
  menggunakan web untuk pesanan yang dialihkan.

Antisipasi juga pemadaman mendadak. Jangan mengklaim APK mengetahui perubahan
web yang belum pernah diterimanya. Tampilkan waktu dan cakupan sinkronisasi
terakhir.

Pisahkan:
- Status bisnis: misalnya lunas lokal.
- Status pengiriman: belum tersinkron/sedang dikirim/sudah diterima.
- Status posting pusat: sudah diterapkan/perlu pemeriksaan.

Uang yang telah diterima tidak boleh dianggap belum dibayar hanya karena
server mati.

============================================================
2. FITUR DAN LOGIKA YANG HARUS DILENGKAPI
============================================================

Ikuti pembagian batch APK-01 sampai APK-12 dalam rolling plan.
Cakupan minimum:

A. Koneksi, akun dan identitas
- Profil server, login, multi-role, employee, outlet dan terminal.
- Isolasi data serta antrean antarserver, akun dan perangkat.
- Penyimpanan token yang aman.
- Pergantian profil tidak mengalihkan transaksi lama kepada akun/server baru.
- Pesan berbeda untuk masalah koneksi, login, RBAC, lisensi dan aturan bisnis.
- Jangan mencampur API key, device key terminal dan lisensi APK.

B. Database lokal dan sinkronisasi
- Penyimpanan durable order, payment, stock movement, cash movement,
  representasi jurnal POS, sesi, print queue dan outbox.
- Commit lokal atomik sebelum mengakui transaksi berhasil.
- Identitas transaksi/event permanen, sequence, revision dan payload hash.
- Retry idempoten, urutan event per order, claim foreground/background.
- Recovery ketika server sudah menyimpan tetapi respons tidak diterima.
- Pending lintas hari, process-kill, disk penuh dan migrasi SQLite.
- Tidak menghapus antrean untuk mengatasi error.
- Tidak menimpa saldo pusat dengan saldo absolut dari APK.

C. Katalog dan transaksi
- Produk, harga kanal, satuan, kategori/divisi, foto, bundle dan extra.
- Snapshot lengkap; jangan berhenti pada batas awal 120 produk/60 bundle.
- Aturan extra wajib/min-max dan variasi bundle.
- Draft dapat dibuka dan disimpan kembali dengan identitas yang sama.
- Append tidak menghilangkan item lama atau membuat order ganda.
- Member, meja, tamu, tipe layanan, catatan dan sales channel tetap utuh.
- Harga/BOM/pajak/pembulatan menggunakan aturan berversi yang diuji
  kesetaraannya dengan Finance.

D. Pembayaran dan keuangan lokal
- Tunai offline, kembalian, bukti pembayaran dan cash ledger lokal.
- Pembayaran online/noncash/campuran sesuai aturan Finance.
- Payment attempt tersimpan sebelum request.
- Outcome online yang belum pasti tidak otomatis menjadi pembayaran kedua.
- Penjualan offline yang sudah selesai tidak direprice diam-diam saat sync.
- DP/voucher/poin bersama tidak boleh dibelanjakan bebas hanya dari cache:
  perlukan alokasi/otorisasi offline yang aman.
- Verifikasi QRIS/provider tidak boleh dipalsukan saat provider tidak tersedia.
- Kas dan jurnal POS lokal dikonsolidasikan melalui Finance tanpa double posting.

E. Stok, resep, void dan refund
- Proyeksi stok lokal berdasarkan snapshot dan movement yang belum tercakup
  watermark server.
- Resep, component, bahan baku, extra dan bundle mengikuti aturan Finance.
- Lot/FIFO/HPP lokal tidak dianggap otomatis final untuk seluruh server.
- Void/refund penuh/sebagian dan opsi kembali stok.
- Produk tanpa resep tidak boleh tertutup jalur void/refund yang sah.
- Offline reversal hanya untuk transaksi/custody dan kewenangan yang sah.
- Jangan menyimpan password Finance atau memakai ulang proof online
  kedaluwarsa sebagai otorisasi offline.
- Koreksi melalui event kompensasi; jangan menghapus sejarah transaksi.

F. Sesi dan perpindahan web–APK
- Sesi bersama, owner terminal dan origin terminal.
- Readiness, snapshot konsisten, checkpoint, custody epoch dan fencing.
- Buka/tutup lokal yang diotorisasi, uang fisik, selisih dan laporan lokal.
- Close lokal dibedakan dari close konsolidasi server.
- Jangan memindahkan event shift lama ke shift baru secara otomatis.
- Handover/handback harus idempoten dan dapat dipulihkan saat koneksi putus.

G. Kanal pesanan
- Self-order, online-food, reservasi dan DP yang relevan untuk kasir.
- List/detail/verify/reject/create/edit/cancel sesuai fitur yang tersedia.
- Progress dapur/bar/checker dan pekerjaan stok mengikuti status Finance.
- Pesanan yang belum pernah diterima tidak dapat muncul saat server mati.
- Aksi bersama membutuhkan koneksi atau custody offline yang eksplisit.

H. Printer
- Binding perangkat, cetak kasir/divisi, payment, void/refund, reprint dan close.
- Ukuran kertas dan jumlah karakter tetap pengaturan lokal APK.
- Template, logo dan renderer lokal tersedia untuk cetak saat server mati.
- Nomor struk lokal unik dan tetap dapat dicari setelah sinkron.
- Queue per dokumen/revisi/target; kegagalan satu printer tidak mengulang
  semua target sukses.
- Preview sesuai output.
- Pertahankan perbaikan logo/raster yang sudah benar; uji dahulu sebelum
  mengubahnya.

I. Laporan dan UI
- Penjualan, pembayaran, kas, stok lokal, refund/void, daily sales dan close.
- Bedakan laporan perangkat dari konsolidasi seluruh outlet.
- Status & Pemulihan: koneksi, sesi, lisensi, usia cache, pending,
  blocked/unknown dan masalah printer.
- Tampilan responsif tablet/ponsel, mudah dipahami operator.
- Operasi admin kasir tetap tunduk RBAC.
- Pengiriman WA/Telegram melalui Finance; token bot tidak disimpan di APK.

J. Lisensi dan pembaruan
- Bedakan lisensi server, entitlement APK, limit terminal dan seat APK.
- Jangan menganggap aktivasi SERVER_INSTANCE sudah mendukung aktivasi tablet.
- Identitas/key instalasi unik; update APK tidak mengambil seat baru.
- Grant offline yang sah memungkinkan operasi tanpa cek server setiap sale.
- Jangan membuat akses tanpa batas atau mematikan pemeriksaan lisensi.
- Pertahankan applicationId, signing identity, data lokal dan identitas
  instalasi saat update.

============================================================
3. ATURAN PERUBAHAN FINANCE DAN CONTROL
============================================================

Gunakan folder finance sebagai referensi backend terbaru, terutama:

- application/controllers/Pos.php
- application/controllers/Pos_mobile.php
- application/models/Pos_model.php
- application/models/Pos_print_model.php
- application/models/Pos_report_model.php
- application/models/Pos_reservation_model.php
- application/models/Pos_order_monitor_model.php
- application/config/routes.php
- application/config/feature_access.php
- Library POS stock/runtime/bundle, feature policy dan kontrak lisensi terkait.

Boleh mengusulkan dan membuat perubahan source Finance lokal yang diperlukan,
dengan ketentuan:

- Utamakan adapter/service/endpoint mobile tambahan yang sempit.
- Pertahankan kompatibilitas endpoint dan perilaku POS web yang sudah berjalan.
- Jangan mengganti rumus atau aturan bisnis agar test APK terlihat lulus.
- Perubahan shared controller/model wajib mempunyai regresi web DAN mobile.
- Pertahankan RBAC, scope, step-up, lisensi, signature dan idempotensi.
- Perubahan SQL harus migration baru yang terdaftar beserta checksum dan
  kebijakan upgrade; jangan mengubah checksum migration lama.
- Uji database hanya pada disposable database.
- File baru harus masuk packaging/allowlist/integrity sesuai kontrak Finance.

Jangan mengubah database.php, .user.ini, customer.json, credential, konfigurasi
aktif, transaksi, saldo, stok, database development berisi data nyata,
atau instalasi customer/produksi.

Jangan deploy, push, publish release, menjalankan SQL ke server aktif,
mengaktifkan lisensi live, atau mengganti identitas instalasi.

Control yang berjalan tidak boleh diubah dari pekerjaan ini.
Jika diperlukan kontrak Control baru, buat handoff berisi kebutuhan,
request/response, signature/binding, error, quota dan test.
Jangan mengarang endpoint atau menganggap mock sebagai integrasi nyata.

Kontrak M10/M11 dalam pedoman adalah kebutuhan baru, bukan endpoint yang
sudah tersedia. Implementasikan dan uji sisi Finance secara terisolasi
sebelum client mengandalkannya.

============================================================
4. POLA KERJA
============================================================

1. Periksa status Git dan pertahankan perubahan pengguna.
2. Baca pedoman aktif, lalu bandingkan source terbaru dengan audit.
3. Catat bagian yang sudah benar, masih kurang dan perlu pembuktian.
4. Mulai APK-01 dan lanjutkan urutan batch dengan patch kecil.
5. Buat test reproduksi sebelum memperbaiki bug yang teridentifikasi.
6. Jangan refactor besar, mengganti seluruh layar, atau upgrade semua
   dependency tanpa kebutuhan yang terbukti.
7. Jalankan validasi setiap batch sebelum melanjutkan.
8. Update checklist dan log pada rolling plan yang sama; jangan membuat
   banyak dokumen progres terpisah.
9. Lanjutkan batch berikutnya yang aman. Jika kontrak Control atau keputusan
   risiko bisnis benar-benar belum tersedia, tandai blocker spesifik;
   kerjakan bagian independen tanpa membuat bypass.

============================================================
5. VALIDASI WAJIB DAN HASIL
============================================================

Jalankan sesuai lingkup:
- flutter analyze, unit/widget/integration test dan build debug.
- Build release pada fase release dengan signing privat yang sah.
- php -l untuk PHP yang berubah.
- Smoke mobile, feature boundary dan regresi POS web.
- Migration/DB integration hanya pada database disposable.
- UAT printer fisik dan lifecycle Android; jangan mengklaim lulus dari mock.

Uji terutama:
- Kasir tetap menyelesaikan cash sale ketika server benar-benar tidak tersedia.
- Handover web → APK → web tanpa menutup sesi dan tanpa duplikasi.
- Crash setelah commit lokal/server tetapi sebelum response.
- Retry, app restart, pergantian hari, dua perangkat dan network partition.
- Stock/cash/jurnal tidak double count setelah refresh snapshot.
- Nominal transaksi yang sudah selesai tidak berubah diam-diam.
- License expiry/revoke, RBAC, kuota dan offline grant.
- Update aplikasi tanpa uninstall, clear data atau kehilangan antrean.

Setiap batch laporkan:
- File yang berubah dan alasannya.
- Fitur/perilaku yang diperbaiki; bagian yang sengaja dipertahankan.
- Validasi aktual beserta hasil, bukan hanya daftar rencana.
- Kebutuhan perubahan Finance/Control dan status integrasinya.
- Risiko/blocker tersisa.
- Checklist yang diperbarui dan batch berikutnya.

Jangan menyatakan siap produksi hanya karena build berhasil.
Target selesai harus membuktikan kedua skenario offline pengguna dan
konsolidasi transaksi, stock, kas serta jurnal yang konsisten.
```
