# POS Mobile APK - Peta Fitur dan Rolling Plan

> **ARSIP sejak 2026-09-24.** Pegangan aktif pindah ke
> [Rolling plan APK–Finance–Control](2026-09-24_rolling_plan_apk_finance_control.md).
> Checklist berikut adalah riwayat versi lama, bukan bukti HEAD saat ini lulus.
> Baseline baru adalah `finance`, bukan `finance2`. Konsep license observe-only
> di bawah tidak berlaku untuk rilis customer. Lihat kontrak dan UAT pada plan aktif.

Tanggal audit awal: 2026-08-21  
Pembaruan komersialisasi dan alignment: 2026-09-03  
Scope: aplikasi kasir Android di `pos/pos_cashier_apk` yang memakai Finance2 sebagai server/dashboard testing utama.

Pada pembaruan historis 2026-09-03, `finance2` digunakan sebagai baseline backend untuk pengembangan APK.
Referensi `finance` dan `finance2` di bagian berikut dipertahankan sebagai
catatan asal pekerjaan, bukan pilihan backend untuk pekerjaan baru.
Gunakan baseline pada rolling plan aktif 2026-09-24.

## 1. Keputusan Arsitektur

Finance tetap menjadi sumber kebenaran untuk:

- user, permission, employee, outlet, terminal, dan shift;
- produk, bundle, divisi, kategori, UOM, extra, member, voucher, payment method;
- HPP live, ketersediaan stok, stock commit, transaksi, payment, void, refund, dan laporan;
- printer server, role printer, routing, template, profile, dan target cetak.

APK hanya memiliki cache dan antrean lokal untuk operasi kasir:

- cache master agar katalog tetap dapat dibuka saat koneksi terputus;
- cart dan order lokal yang belum terkirim;
- outbox dengan `client_event_id` agar retry tidak membuat transaksi ganda;
- binding printer Bluetooth Android ke printer server;
- log sinkronisasi lokal.

APK tidak menghitung HPP, tidak membuat stok final, dan tidak membuat master printer/server baru.

### Aturan HPP dan stok mobile

HPP dan stok menggunakan pola server-authoritative, bukan dua database yang
saling mengubah angka stok secara bebas:

1. Finance menghitung atau menerima perubahan inventory dari penjualan POS,
   purchase receiving, batch produksi, adjustment, void, dan refund.
2. Finance memperbarui ledger dan `pos_product_availability_cache`, termasuk
   `availability_status`, `estimated_available_qty`, dan `hpp_live_snapshot`.
3. APK menarik projection tersebut saat bootstrap/sync dan menampilkannya
   sebagai stok terakhir yang diketahui. Cache lokal diberi makna stale saat
   koneksi atau umur datanya tidak memenuhi batas operasional.
4. Saat online, order APK dikirim sebagai event idempotent. Server memvalidasi
   ulang harga, HPP live, resep/bundle, availability, session, dan permission.
   Serverlah yang melakukan stock commit dan menyimpan snapshot HPP pada order.
5. Saat offline, APK boleh menyimpan draft/order ke outbox dengan stok terakhir
   sebagai informasi bantu. APK tidak boleh mengurangi stok final, menghitung
   HPP, atau menganggap order sudah lunas/ter-commit sebelum server menerima.

Dengan demikian perubahan purchase atau produksi mengalir `server -> cache ->
APK`, sedangkan penjualan APK mengalir `APK outbox -> server validation ->
stock commit -> cache -> semua client`. Ini adalah sinkronisasi dua arah pada
event dan state, bukan edit langsung kuantitas stok dari dua tempat.

## 2. Peta POS Finance

### A. Akses dan sesi kasir

Sumber utama: `Pos.php`, `Pos_mobile.php`, `Pos_model.php`.

Tabel/domain:

- `auth_user`, permission, dan `org_employee`;
- `pos_mobile_auth_token` untuk token APK;
- `pos_outlet`, `pos_terminal`;
- `pos_shift`, `pos_shift_summary`, `pos_cashier_session`;
- daily reconciliation gate sebelum buka/tutup kasir.

Alur server:

1. Login user Finance.
2. User wajib memiliki akses POS dan terhubung ke employee.
3. APK mengirim `outlet_id`, `terminal_id`, dan modal awal.
4. Finance membuat shift dan cashier session.
5. Semua order/payment berikutnya harus berasal dari session yang sama.

### B. Master katalog dan stok

Tabel/domain:

- `mst_product`, `mst_product_division`, `mst_product_category`, `mst_uom`;
- `pos_product_bundle`, `pos_product_bundle_line`;
- `pos_product_availability_cache` dan override availability;
- recipe/component/material pada domain inventory dan production;
- `hpp_standard`, `hpp_live_cache`, dan snapshot HPP pada stock commit/order.

Method penting di `Pos_model.php`:

- `order_product_search()`;
- `order_product_catalog()`;
- `order_bundle_search()` dan `order_bundle_catalog()`;
- `cashier_catalog_filter_options()`;
- `stock_live_rows()`;
- `resolve_order_stock_commit_payload()`;
- `finalize_order_confirmation()`.

Katalog APK harus menampilkan status dan estimasi stok dari server. Nilai stok dapat berubah setelah sync atau transaksi web, sehingga cache APK wajib mempunyai timestamp/status stale.

### C. Extra dan bundle

Tabel/domain:

- `mst_product_extra_map`;
- `mst_extra_group`;
- `mst_extra_group_item`;
- `mst_extra`;
- `pos_order_line_extra`;
- bundle dan komponen bundle.

Method server:

- `order_extra_options()`;
- `load_product_extra_group_map()`;
- normalisasi line pada `save_order_draft()`;
- perhitungan ulang total dan reversal extra.

Extra hanya dikirim jika map produk, group, group item, dan extra semuanya aktif.

Temuan data lokal:

- `JAZZY ALMOND`, product ID `35`, memiliki extra aktif.
- Group aktif: `CUP ICE TA` dan `CUP ICE DINE IN`.
- Karena APK menampilkan “Tidak ada extra” saat request gagal, UI saat ini belum membedakan `tidak ada extra` dengan `API gagal`.

### D. Member, CRM, loyalty, voucher, dan deposit

Tabel/domain:

- `crm_member`;
- point ledger dan stamp ledger;
- `pos_voucher_campaign`, `pos_voucher_issue`, voucher redemption;
- `pos_payment` tipe deposit dan penggunaan deposit;
- loyalty otomatis setelah payment lunas.

Method penting:

- `order_member_search()`;
- `cashier_payment_prepare()`;
- `search_cashier_vouchers()`;
- `save_cashier_payment()`;
- `ensure_paid_order_loyalty()`;
- fungsi preview dan apply voucher/deposit/member loyalty.

### E. Order, payment, void, refund

Status order server meliputi `DRAFT`, `PENDING`, `CONFIRMED`, `PAID_PARTIAL`, `PAID`, `IN_KITCHEN`, `READY`, `SERVED`, `VOID`, dan status refund.

Tabel utama:

- `pos_order`;
- `pos_order_line`, `pos_order_line_extra`;
- `pos_payment`, `pos_payment_line`;
- void/refund line dan state log;
- runtime job, stock commit snapshot, dan print job.

Method penting:

- `order_draft_rows()` dan `find_order_draft()`;
- `save_order_draft()` dan `delete_order_draft()`;
- `order_reversal_preview()`;
- `save_order_void()` dan `save_order_refund()`;
- `cashier_payment_prepare()` dan `save_cashier_payment()`;
- `direct_print_targets_for_*()`.

### F. Printer

Finance2 memakai konfigurasi printer kanonis `pos_print_*`; tabel printer legacy
tidak boleh menjadi sumber runtime. Domain printer terdiri dari:

- `pos_print_connection` sebagai koneksi/device server;
- `pos_print_layout` sebagai layout/template output;
- `pos_print_route` sebagai aturan event, role, scope, copy, dan koneksi;
- `pos_print_general_setting` sebagai pengaturan umum outlet;
- runtime job/log dan Python printer agent bila route memakainya;
- Python printer agent untuk mode `LOCAL_AGENT`.

Method penting:

- `Pos_print_model::connection_rows()` dan `find_connection()`;
- `Pos_print_model::route_rows()`;
- `Pos_print_model::general_settings()`;
- `Pos_print_model::runtime_template()`;
- `direct_print_targets_for_order_confirm()`;
- `direct_print_targets_for_payment()`;
- target void, refund, reprint, dan shift close.

APK tidak boleh membuat device server baru dari halaman printer mobile. APK memilih device server yang sudah aktif, lalu menyimpan alamat Bluetooth Android secara lokal.

### G. Order monitor, kitchen, self-order, online food, dan laporan

Domain lain yang ada di Finance:

- `Pos_order_monitor_model.php` untuk station KITCHEN/BAR/CHECKER dan status tugas;
- self-order, meja, QRIS, dan verifikasi order;
- online food, lokasi delivery, fee, dan verifikasi order;
- laporan sales, sales detail, extra, payment, refund, void, cashier close;
- audit stock commit, sales-HPP integrity, stock live, runtime jobs.

Domain ini bukan seluruhnya layar kasir Android. Yang wajib dipantulkan ke APK adalah status order, print target, stock commit, payment, void/refund, dan error runtime yang memengaruhi kasir.

### H. Reservasi, self order, dan online order di Finance2

Ketiga kanal ini bukan database transaksi terpisah di APK. Setelah diverifikasi,
semuanya menjadi `pos_order` normal sehingga memakai payment, stok, HPP, void,
refund, monitor divisi, dan printer yang sama dengan kasir.

**Reservasi** memakai staging berikut:

- `pos_reservation` untuk customer, outlet, jadwal, layanan, total, DP, dan status;
- `pos_reservation_line` untuk produk/bundle dan snapshot harga/HPP;
- `pos_reservation_line_extra` untuk extra dan catatan line;
- `pos_reservation_payment` sebagai penghubung DP;
- `pos_reservation_state_log` untuk audit perubahan status.

Status efektif reservasi: `PENDING`, `VERIFIED_ACTIVE`, `VERIFIED_PAID`,
`REJECTED`, dan `CANCELLED`. Urutan list server menempatkan `PENDING` paling atas.
Saat kasir menerima reservasi, server menghitung ulang harga/HPP aktif, membuat
order POS, menerapkan DP melalui `pos_payment_deposit_apply`, menjalankan queue
stock commit bila diperlukan, lalu mengembalikan target cetak. Tujuan akhirnya:
`VERIFIED_ACTIVE` masuk order aktif jika masih ada tagihan, atau `VERIFIED_PAID`
masuk order terbayar jika DP sudah menutup total.

**Self order dan online food** memakai pola web Finance2:

- web memiliki list, filter status, detail, verify, reject, dan printer KOT;
- verifikasi memakai konteks kanal, finalisasi order, queue stock commit,
  monitor task, dan target printer per divisi;
- online food memiliki aturan tambahan untuk channel/lokasi/delivery;
- APK hanya perlu menampilkan item yang memang dapat diverifikasi oleh akun dan
  outletnya, lalu memanggil finalisasi server. APK tidak menulis status order
  atau stok secara langsung.

**Batas hak akses:** menu Finance2 saat ini memberi akses reservasi kepada
`SUPERADMIN`, `CEO`, `MGR`, `ADMIN`, `HOD`, dan `BARISTA` melalui seed. Permintaan
produk menetapkan full access minimal untuk Superadmin, Management, HOD, dan
Barista; implementasi APK tetap harus membaca permission endpoint server, bukan
menanam daftar role di APK. Pemetaan role `Management` ke kode role Finance2
harus dikonfirmasi dari database customer, karena seed memakai kode `CEO`/`MGR`.

## 3. API Mobile yang Sudah Dibuat

Controller: `finance2/application/controllers/Pos_mobile.php`.

| Area | Endpoint | Status |
|---|---|---|
| Health | `/pos-mobile/ping` | Selesai |
| Auth | `/pos-mobile/auth/login`, `/logout` | Selesai, perlu uji token kedaluwarsa |
| Bootstrap | `/pos-mobile/bootstrap` | Selesai dasar, delta belum lengkap |
| Catalog | `/pos-mobile/catalog` | Selesai dasar |
| Member | `/pos-mobile/members/search` | Selesai dasar |
| Extra | `/pos-mobile/products/extra-options` | Endpoint ada, error dibedakan dari kondisi kosong |
| Printer | `/pos-mobile/printers` | Endpoint ada, membutuhkan token valid |
| Printer test | `/pos-mobile/printers/test/:id` | Selesai; preview dummy/template/divisi dibuat Finance |
| Shift | session status, open, close, close preview | Endpoint ada, UI/config belum lengkap |
| Order | list, load, save, confirm, push | Dasar tersedia |
| Payment | prepare, voucher search, save, print targets | Dasar tersedia |
| Void/refund | preview, save, print targets | Dasar tersedia; APK memilih item/qty dari preview server |
| Cetak order | confirm print targets, reprint targets | Endpoint mobile dan binding Bluetooth APK tersedia |
| Reservasi | list/detail/verify/reject | Mobile read/detail/action tersedia; creator, DP, edit/cancel menyusul |
| Self order verification | list/detail/verify/reject/print targets | Mobile inbox/action tersedia; target cetak dikembalikan dari Finance |
| Online food verification | list/detail/verify/reject/print targets | Mobile inbox/action tersedia; aturan delivery tetap server-side |
| Online order verification | list/detail/verify/reject/print targets | Web Finance2 lengkap; endpoint mobile belum tersedia |
| License/entitlement | feature gate, terminal, grace period | Belum di-enforce; harus disiapkan sebagai kontrak, bukan hardcode |

### Kontrak mobile yang masih harus ditambahkan di Finance2

Controller `finance2/application/controllers/Pos_mobile.php` sudah memiliki
auth, bootstrap, katalog, member, extra, printer, shift, order, payment,
void/refund, dan print target. Namun hasil scan 2026-09-03 menunjukkan belum
ada public method maupun route `/pos-mobile/...` untuk:

- `reservations` list hari/periode, `reservation_detail`, catalog/bundle/extra,
  member search, save, deposit, verify, reject, dan cancel;
- `self_order_orders` list/detail/verify/reject serta target print hasil verify;
- `online_food_orders` list/detail/verify/reject serta target print hasil verify;
- capability/entitlement yang memberitahu APK apakah kanal tersebut dibeli dan
  diizinkan untuk user/outlet/terminal saat ini.

Endpoint baru wajib memakai permission page code Finance2, employee/session
requirement, outlet scope, idempotency key untuk writer, error code stabil,
dan target printer dari `pos_print_*`. Route perlu ditambahkan di
`finance2/application/config/routes.php` karena controller method saja tidak
akan dapat dipanggil melalui URL mobile. File lain di Finance2 belum perlu
diubah pada tahap pemetaan ini.

## 4. Status APK Saat Ini

### Sudah dibuat

- [x] Flutter Android project.
- [x] Setup URL backend, device key, API key, outlet, terminal.
- [x] Login Finance menggunakan token mobile.
- [x] Local SQLite: master cache, local order, sync outbox, sync log.
- [x] Draft lokal dapat dibuka kembali dari panel kasir melalui daftar `local_orders`.
- [x] Background WorkManager periodik 15 menit saat jaringan tersedia.
- [x] Bootstrap produk, bundle, divisi, payment method, dan session cache.
- [x] Katalog produk, pencarian, filter divisi, status ketersediaan, dan estimasi stok.
- [x] Cart, customer/member picker, service type, meja, catatan order.
- [x] Modal line customization untuk extra dan catatan.
- [x] Order draft dan confirm melalui outbox.
- [x] Payment dasar dan pencarian voucher.
- [x] Payment membawa event idempotency key dan merangkum deposit/loyalty dari server.
- [x] Tab order aktif dan order terbayar.
- [x] Void dan refund dasar.
- [x] Seleksi item/qty pada void/refund menggunakan preview server.
- [x] Printer server list dan binding Bluetooth lokal.
- [x] Cetak KOT saat transaksi terkonfirmasi, cetak ulang order, struk payment,
  slip void/refund, dan laporan tutup shift melalui routing target Finance.
- [x] Modal produk dan bundle memiliki kontrol jumlah tambah/kurang sebelum masuk
  keranjang.
- [x] Foto bundle memakai `photo_path`/`photo_url` dan ikut dipreload ke cache
  lokal bersama foto produk.
- [x] Status online, sinkronisasi, draft, outbox, sync terakhir, dan kasir aktif
  dipindah ke status bar atas yang dapat digeser pada layar sempit.
- [x] Panel kiri menampilkan order aktif hari ini; payment/void/detail tetap
  memakai workspace order Finance, dan order confirmed dapat masuk mode tambah
  item dari panel tersebut.
- [x] Form keranjang dibuat responsif, daftar item memiliki scroll mandiri,
  total serta tombol Simpan Draft/Simpan Transaksi menempel di bawah.
- [x] Saat menambah item dari order aktif, APK memuat kembali header, member,
  tipe layanan, guest, meja, sales channel, catatan, dan seluruh line tersimpan.
- [x] Line lama membawa `order_line_id` dan tidak dapat diubah/hapus saat append;
  line baru dikirim sebagai tambahan sesuai kontrak Finance.
- [x] Bundle ditampilkan sebagai satu baris nama bundle di keranjang, bukan
  daftar komponen, dengan kontrol qty per paket.
- [x] Payment dari order `DRAFT/PENDING` menawarkan konfirmasi server terlebih
  dahulu lalu melanjutkan ke payment.
- [x] Test, analyzer, dan debug APK berhasil pada build terakhir.
- [ ] Modul reservasi APK, verifikasi self order, dan verifikasi online order.
- [ ] Kontrak capability/entitlement untuk menyembunyikan atau mengunci fitur
  sesuai lisensi dan RBAC Finance2.

### Masih parsial atau belum tervalidasi

- [~] Token sudah dipertahankan saat menyimpan pengaturan, tetapi instalasi yang tokennya sudah hilang/kedaluwarsa tetap harus login ulang.
- [~] Error `401` belum otomatis mengarahkan user ke halaman login; beberapa layar menampilkan error generik.
- [x] Extra API membedakan kegagalan request dari extra yang memang kosong.
- [x] Buka kasir memiliki pemilihan outlet/terminal dari bootstrap server.
- [~] Sinkronisasi pull bootstrap/session dan push order; sync berkala sekarang tidak mengganti katalog saat cart/modal aktif, dan event HTTP 4xx diblokir sampai retry manual.
- [~] Bootstrap menerima cursor, tetapi server belum mengirim delta master dan daftar deleted yang nyata.
- [x] Katalog/filter divisi sekarang memakai fallback outlet aktif/default saat APK belum memiliki shift aktif, sehingga availability stok tidak hilang pada pencarian server.
- [x] Bundle sudah menjadi alur cart dengan komponen, `bundle_id`, availability, dan detail harga dari server.
- [x] Foto produk dibaca dari `photo_path` Finance, diunduh ke cache file lokal APK, dan dipakai dari cache pada tampilan berikutnya.
- [x] Preload foto katalog berjalan bertahap setelah sync; cache file tetap dipakai saat offline.
- [~] Invalidasi berbasis versi foto belum menjadi bagian kontrak delta master; saat ini URL/path foto menjadi kunci cache.
- [~] Printer direct Bluetooth APK belum sepenuhnya menyamakan format template/routing/agent Finance.
- [x] Cash denomination tersedia pada dialog tutup shift; total pecahan dapat
  dipakai mengisi kas aktual sebelum submit ke server.
- [~] Background sync belum sama dengan foreground service terus-menerus; WorkManager hanya periodik sesuai kebijakan Android.
- [x] Error koneksi, error server, dan validasi bisnis tidak lagi ditampilkan sebagai satu status `Offline` dengan pesan mentah.
- [x] Layout tablet/desktop membuat panel cart memiliki scroll mandiri; form customer/guest/meja turun menjadi dua baris pada layar sempit.
- [x] Layout kasir terbaru menempatkan status/sinkron di atas dan order aktif hari
  ini di panel kiri; pada layar sempit seluruh area berubah menjadi scroll vertikal.

## 5. Akar Masalah Tiga Error Terbaru

Kontrak kepemilikan data, alur listrik/server mati, dan status outbox dirinci
di [2026-08-21_pos_mobile_data_ownership_and_sync.md](2026-08-21_pos_mobile_data_ownership_and_sync.md).

Checklist audit sinkronisasi transaksi:

- [x] `local_uuid` dan `client_event_id` dibuat sekali dan dipakai ulang saat retry.
- [x] Order lokal hari ini ditampilkan pada tab order aktif sebelum server menerima.
- [x] Order lokal tidak diduplikasi ketika order server sudah memiliki `server_id`.
- [x] Event server `PROCESSING` tidak dianggap sukses oleh APK.
- [x] Event server `REJECTED` tetap menjadi `BLOCKED` di perangkat.
- [x] Profil koneksi server dan namespace database lokal dipisahkan.
- [ ] Uji timeout setelah server menyimpan order, sebelum response diterima APK.
- [ ] Uji konflik stock dengan purchase/produksi/transaksi web yang terjadi saat APK offline.
- [ ] Uji printer fisik Bluetooth untuk role KASIR/BAR/KITCHEN/CHECKER dan format kertas 58/80 mm.

### Extra tidak muncul

Bukti database menunjukkan product ID 35 memiliki extra aktif. APK sekarang
membedakan request gagal dari kondisi product yang memang tidak memiliki extra;
dialog tetap menampilkan catatan error yang ringkas dan tidak mengirim extra
palsu. Pengujian product ID 35 dengan token login baru masih menjadi smoke test
perangkat yang perlu dilakukan.

### Buka kasir gagal

Pesan saat ini berhenti di `authorize_mobile()`: token atau employee session tidak tersedia. Setelah login valid, server masih memvalidasi:

- akun punya permission POS;
- user memiliki `employee_id`;
- outlet aktif;
- terminal aktif dan tidak dipakai session lain;
- daily recon gate tidak memblokir open;
- modal awal tidak negatif.

Data lokal audit memiliki outlet ID 1 dan terminal ID 1. APK sekarang menarik
pilihan outlet dan terminal dari `cashier_bootstrap`, lalu mengirim pilihan
tersebut saat membuka shift. Validasi permission, employee, terminal busy, dan
daily recon tetap harus diuji dengan akun Finance nyata.

### Tambah printer gagal

Halaman mobile hanya dapat mengikat printer server aktif. Ia tidak membuat row baru di `pos_printer`. Saat endpoint gagal autentikasi, daftar server kosong/error sehingga dialog tambah tidak memiliki pilihan.

Setelah login valid, endpoint seharusnya mengembalikan empat printer aktif.
Binding lokal dan dialog pemilihan Bluetooth sudah tersedia. Pengujian wajib
mencakup:

- daftar server tampil;
- pilih KASIR/BAR/KITCHEN/CHECKER;
- pilih bonded Bluetooth device;
- test print;
- simpan mapping lokal;
- cetak order memakai printer berdasarkan target server dan fallback role.

## 6. Rolling Plan Implementasi

### R0 - Stabilkan kontrak akses dan diagnostik

- [ ] Tambahkan HTTP status, endpoint, dan request id pada error API APK.
- [ ] Jika response `401`, revoke state lokal dan tampilkan Login.
- [ ] Tambahkan halaman/status diagnosa: URL, token expiry, user, employee, outlet, terminal, session.
- [ ] Pastikan login memakai `terminal_device_key` dan menyimpan token baru.
- [ ] Uji ulang ping, login, bootstrap, session status, printer, extra.

Exit criteria: tidak ada layar yang menampilkan “offline” sementara token sebenarnya expired tanpa tombol login ulang.

### R1 - Bootstrap master dan pilihan terminal

- [ ] Perbaiki payload bootstrap agar mengirim outlet, terminal, printer, divisi, category, bundle, extra summary, payment method, dan version cursor.
- [ ] Buat contract delta: `upsert`, `delete`, `server_version`, `generated_at`.
- [ ] APK menampilkan outlet/terminal dari server, bukan meminta ID manual.
- [ ] Simpan master dengan version dan timestamp.
- [ ] Tampilkan status stale jika cache melewati batas umur.

Exit criteria: perubahan harga, stok availability, divisi, printer aktif, dan payment method muncul otomatis pada sync berikutnya.

### R2 - Shift kasir dua arah

- [x] UI pilih outlet, terminal, modal awal, dan buka shift memakai data bootstrap server.
- [x] UI status session detail, ikon status, dan username kasir tampil di panel kasir.
- [x] Jika shift dibuka dari web untuk user yang sama, APK menarik session pada sinkron berikutnya.
- [x] UI preview tutup kasir menampilkan modal awal, penjualan tunai/non-tunai, dan kas yang diharapkan.
- [~] Tutup shift sudah menerima kas aktual dan variance; pecahan kas, account summary detail, dan print close masih berikutnya.
- [ ] UI close preview, pecahan kas, actual cash, variance, notes, dan print close.
- [ ] Tangani terminal busy, daily recon gate, dan session milik employee lain.

Exit criteria: open/close dari web dan APK menghasilkan state yang sama tanpa edit manual database.

### R3 - Catalog, extra, bundle, dan cart

- [x] Perbaiki error state extra dan validasi required/min/max.
- [ ] Tampilkan harga dasar, harga extra, subtotal line, qty, dan catatan.
- [x] Tambahkan tab katalog Paket / Bundle, komponen, harga alokasi server, dan availability.
- [x] Bundle dapat ditambahkan ke cart dengan `bundle_id` dan key cart terpisah dari produk biasa.
- [x] Tampilkan foto dari `photo_path`/`photo_url` dengan cache file lokal dan fallback yang jelas.
- [ ] Search server mendukung kode, nama, divisi, kategori, dan bundle.
- [x] Kunci tambah produk yang `OUT` sesuai availability server.

Exit criteria: product, extra, bundle, availability, dan total cart sama dengan web untuk sample yang sama.

### R4 - Order lifecycle dan stock commit

- [ ] Samakan payload line/extra dengan normalizer server.
- [~] Draft lokal dapat dibuka kembali, dilihat detailnya, dan dihapus dari
  perangkat beserta antrean lokal; edit draft server masih mengikuti tahap
  update order Finance.
- [x] `Simpan Transaksi` menjadi order aktif `CONFIRMED` walaupun belum payment;
  validasi session, HPP, dan stock tetap dilakukan Finance.
- [~] Tampilkan stock commit status dari server pada workspace dan detail order;
  warning deficit tetap mengikuti respons stock commit Finance.
- [ ] Retry order idempotent dengan `client_event_id`.
- [ ] Tampilkan order yang dibuat dari web pada tab aktif.

Exit criteria: satu order APK dan satu order web dapat dilihat dari kedua sisi dengan status dan stock commit yang benar.

### R5 - Payment, member, voucher, deposit, loyalty

- [ ] Payment method mengikuti server dan menampilkan rekening tujuan bila relevan.
- [x] Dukung multi payment, cash change, dan reference number; server tetap menentukan nominal valid dan kembalian.
- [~] Deposit, point/stamp redemption, dan detail rekening tujuan sudah dikirim oleh server tetapi belum seluruhnya memiliki kontrol UI APK.
- [x] Member point/stamp ditampilkan pada cart dan dialog payment; redemption
  point/stamp menunggu kontrak aksi Finance yang eksplisit.
- [ ] Voucher preview dan redemption memakai contract server yang sama.
- [x] Payment online membawa idempotency key dan tercatat pada shift melalui Finance.
- [ ] Payment offline masuk queue dengan status jelas; jangan dianggap lunas sebelum server menerima.
- [x] Order confirmed tanpa payment tetap masuk workspace aktif dan laporan
  omzet belum bayar setelah server menerima event.

Exit criteria: payment, voucher, deposit, point, stamp, account mutation, dan shift summary konsisten.

### R6 - Printer dan routing

- [~] Tetapkan adapter per target: direct Bluetooth untuk printer yang dipasangkan lokal atau printer agent bila route Finance2 memerlukannya; jangan mencampur payload tanpa adapter.
- [ ] Server hanya menjadi sumber printer, role, scope, route, template, dan target.
- [ ] APK menyimpan binding Bluetooth lokal per server printer.
- [ ] Test print, KASIR receipt, BAR/KITCHEN ticket, CHECKER, void, refund, payment, dan shift close.
- [ ] Tampilkan printer offline tanpa memblokir transaksi; transaksi dan target cetak harus dapat di-retry terpisah.
- [ ] Tambahkan fallback queue cetak lokal dan reprint.

Exit criteria: satu order menghasilkan dokumen yang benar pada role printer yang benar, dan reprint dapat dilakukan.

### R7 - Active/Paid workspace, void, refund

- [ ] Sinkron daftar order aktif dan terbayar dengan pagination/cursor.
- [x] Load detail order server lengkap termasuk extra dan status stock commit;
  detail order lokal juga dapat dibuka dari cache saat offline.
- [ ] Void hanya untuk state yang diizinkan server.
- [x] Refund partial/full mengikuti reversal plan server.
- [ ] Tampilkan alasan, actor, timestamp, stock reversal, loyalty reversal, dan print slip.

Exit criteria: void/refund dari web atau APK terlihat sama dan tidak menggandakan reversal.

### R8 - Offline, two-way sync, dan background

- [ ] Definisikan event state machine: `PENDING`, `PROCESSING`, `ACCEPTED`, `REJECTED`, `CONFLICT`.
- [ ] Simpan response/error/server version per event.
- [ ] Pull perubahan order/session/master dari server.
- [x] Push order dan payment memakai event idempotent.
- [ ] Tambahkan retry backoff dan dead-letter view untuk event gagal.
- [x] Event order yang ditolak server dengan 4xx disimpan sebagai `BLOCKED`, tidak diulang otomatis setiap interval, dan dapat di-requeue lewat sinkron manual.
- [x] Sync foreground tidak mengubah katalog aktif saat kasir sedang mengisi cart, membuka modal extra/payment, atau melakukan pencarian.
- [ ] WorkManager hanya menjalankan sync aman; jangan memproses payment tanpa aturan retry yang jelas.
- [ ] Uji server down, reconnect, duplicate request, token expired, dan update master dari web.

Exit criteria: transaksi lokal tidak hilang, tidak dobel, dan akhirnya memiliki status server yang dapat diaudit.

### R9 - Audit dan release

- [ ] Test matrix emulator dan perangkat Bluetooth nyata.
- [ ] Uji outlet/terminal/session multi-device.
- [ ] Uji permission user kasir, barista, management, HOD, dan user tanpa permission.
- [ ] Uji HPP live tidak pernah dihitung di APK.
- [ ] Uji build release, signing key, versioning, backup, dan rollback.
- [~] Audit semua endpoint mobile terhadap permission, rate limit, token revoke, dan log; Finance2 sudah memiliki permission per aksi pada sebagian besar endpoint, tetapi coverage P0-03 dan UAT APK belum selesai.

### R10 - Reservation, self order, dan online order

Tahap ini adalah tahap berikutnya setelah kontrak endpoint mobile disetujui.

- [x] Tambahkan endpoint mobile Finance2 untuk list/detail reservasi dengan dua
  tab: transaksi dan rincian produk per divisi.
- [ ] Tambahkan input reservasi APK: customer/member, jadwal, layanan, channel,
  guest, meja, catatan, produk/bundle, extra, total, dan DP.
- [ ] DP tetap memakai `pos_payment`, rekening/mutasi Finance2, dan idempotency;
  APK hanya menampilkan hasil server.
- [x] Tambahkan verify/reject reservasi dengan alasan; cancel dan editor
  reservasi masih menyusul.
  dampaknya sebelum submit.
- [x] Saat verify, server membuat order normal, menerapkan DP,
  menjalankan stock commit queue, dan mengembalikan bucket aktif/terbayar.
- [x] Tambahkan tab verifikasi self order dan online order di APK, termasuk
  detail, accept/reject, alasan, status pembayaran, status stok, dan KOT.
- [x] Gunakan target printer server untuk reservation/self/online; Bluetooth
  hanya menjadi binding lokal device APK.
- [ ] Tambahkan refresh aman/background sync yang tidak mengganti workspace
  aktif, cart, atau modal yang sedang dipakai kasir.

Exit criteria: order dari reservasi, self order, online order, web, dan APK
terlihat konsisten; verifikasi hanya dapat dilakukan oleh permission yang sah;
stok/HPP/payment/mutasi dan printer mengikuti server.

### R11 - Commercial readiness dan license seam

Tahap ini mengikuti roadmap komersialisasi Finance2, tanpa mematikan transaksi
sebelum fondasi audit Finance2 lulus.

- [ ] Tambahkan interface lokal `LicenseContext`/feature capability di APK,
  tetapi gunakan mode observe-only selama masa testing.
- [ ] APK menyimpan identitas server sebagai profile terpisah; cache transaksi
  dan master tidak tercampur antar instalasi/customer.
- [ ] Siapkan device activation hook berbasis Android Keystore, bukan MAC
  address atau hardcode nama Namua.
- [ ] Konsumsi signed entitlement dari Finance2/Product Control Center setelah
  kontrak lisensi siap; cache offline mengikuti grace period yang disepakati.
- [ ] Backend menolak endpoint ketika feature tidak dibeli, sementara UI APK
  menampilkan pesan paket yang jelas dan tidak menghapus data historis.
- [ ] Uji minimum/maximum backend version, APK version, migration, revoke,
  replacement device, dan offline grace period.

Exit criteria: satu artefak APK dapat dipakai beberapa customer melalui profile
dan entitlement berbeda tanpa fork source code atau hardcode identitas.

## 7. Checklist Audit Per Iterasi

Setiap fitur baru harus melewati checklist berikut sebelum dinyatakan selesai:

- [ ] Contract request/response ditulis.
- [ ] Permission dan employee requirement diuji.
- [ ] Kondisi offline dan retry ditentukan.
- [ ] Idempotency key ditentukan.
- [ ] Sumber data server dan cache lokal dipisahkan.
- [ ] Timestamp/version data ditampilkan bila stale.
- [ ] Error 401, 409, 422, 500, timeout, dan malformed JSON diuji.
- [ ] Efek stock/HPP/payment/loyalty dijelaskan.
- [ ] Print target dan reprint diuji bila fitur menghasilkan dokumen.
- [ ] Web-to-APK dan APK-to-web diuji.
- [ ] Test Flutter, analyzer, PHP lint, dan smoke test endpoint lulus.

## 8. Prioritas Kerja Berikutnya

Urutan implementasi yang direkomendasikan setelah pemetaan ini:

1. **R10.1 - Kontrak API Finance2:** selesai untuk route dan endpoint read-only
   reservasi/self order/online order terlebih dahulu, termasuk capability,
   permission, outlet scope, dan response status yang stabil.
2. **R10.2 - UI APK:** selesai untuk tab verifikasi dan detail; pastikan list, filter,
   refresh, serta detail transaksi dapat dipakai tanpa mengganggu workspace
   kasir yang sedang berjalan.
3. **R10.3 - Writer aman:** verify/reject sudah tersambung; save reservasi, DP, dan
   cancel dengan idempotency; baru setelah itu aktifkan target order aktif/
   terbayar dan stock commit server.
4. **R10.4 - Printer dan audit:** target `pos_print_*` sudah dipakai; lanjutkan
   lalu uji cetak reservation/self/online, payment, KOT, void/refund, dan
   reprint per divisi.
5. **R11 - Komersialisasi:** pasang abstraction license/entitlement dalam mode
   observe-only, lalu lanjutkan activation device dan signed cache setelah
   audit Finance2 menyatakan fondasinya siap.

Pekerjaan backend pada langkah 1 akan dibatasi pada
`finance2/application/controllers/Pos_mobile.php` dan route baru di
`finance2/application/config/routes.php`. Jika implementasi ternyata
memerlukan model/service/schema tambahan, file tersebut harus disampaikan dan
disetujui terlebih dahulu; tidak boleh mengubah `Pos.php` atau `Pos_model.php`
yang bukan bagian dari perubahan ini.

### Progress Log

### 2026-09-03 - Alignment Finance2, kanal masuk, dan kesiapan komersial

- [x] Membaca roadmap komersialisasi Finance2 dan audit total aplikasi Finance2
  sebagai sumber keputusan paket, RBAC, schema, release, dan lisensi.
- [x] Memetakan alur web Finance2 untuk kasir, reservasi, self order, online
  food, payment/DP, stock commit, HPP live, monitor divisi, dan printer.
- [x] Menegaskan reservasi sebagai staging document; setelah verifikasi menjadi
  `pos_order` normal dan masuk bucket aktif atau terbayar sesuai sisa tagihan.
- [x] Menegaskan DP tetap memakai `pos_payment` dan mutasi rekening Finance2;
  APK tidak membuat mutasi keuangan lokal.
- [x] Menegaskan printer runtime memakai `pos_print_connection`,
  `pos_print_layout`, `pos_print_route`, dan `pos_print_general_setting`;
  tabel legacy tidak menjadi sumber konfigurasi.
- [x] Menemukan gap endpoint mobile: Finance2 `Pos_mobile.php` belum memiliki
  kontrak reservasi, verifikasi self order, dan verifikasi online order.
- [x] Menemukan gap route: `finance2/application/config/routes.php` juga perlu
  route `/pos-mobile/...` untuk endpoint baru.
- [x] Menambahkan R10 untuk seluruh kanal order masuk dan R11 untuk abstraction
  lisensi/entitlement tanpa enforcement prematur saat testing.
- [x] Implementasi endpoint dan UI R10 tahap inbox sudah dimulai; perubahan
  Finance2 dibatasi pada `Pos_mobile.php` dan route baru.
- [x] Perbaikan kontrak client mengirim `X-Pos-Mobile-Device-Key` dan memakai
  `POST` untuk printer test sesuai middleware Finance2.

### 2026-08-27 - Penyempurnaan kasir tablet dan recovery order

- [x] Field tipe layanan/customer dan sales channel/catatan order dipaksa
  sejajar pada panel cart agar area katalog lebih luas.
- [x] Tab katalog langsung menampilkan Semua dan divisi; Paket / Bundle
  dipindah menjadi tab terakhir.
- [x] Cart merangkum bundle sebagai satu baris nama bundle dan mempertahankan
  kontrol jumlah per paket.
- [x] Order lokal `BLOCKED` menampilkan alasan sinkronisasi dan tombol `Coba
  sinkron`; tambah item tetap dikunci sampai order memiliki `server_id`.
- [x] Order aktif `DRAFT/PENDING` dapat dikonfirmasi melalui alur payment
  sebelum dialog pembayaran dibuka.
- [x] Status bar dipindah ke area toolbar penuh agar tidak terpotong oleh
  title/action pada tablet maupun emulator sempit.
- [x] `flutter analyze`, `flutter test`, dan `flutter build apk --debug`
  lulus.

### 2026-08-25 - Kasir workspace dan katalog responsif

- [x] Modal produk dan bundle mendukung quantity tambah/kurang sebelum item
  masuk keranjang.
- [x] Bundle meneruskan `photo_url`/`photo_path` ke kartu produk dan ikut
  dipreload ke cache foto lokal.
- [x] Status/sinkronisasi dipindah ke bar atas; panel kiri sekarang berisi
  order aktif hari ini dengan aksi tambah item dan akses workspace payment,
  void, refund, serta cetak ulang.
- [x] Mode tambah item memakai ID order existing sehingga penyimpanan dapat
  diteruskan ke order server yang sama.
- [x] Cart memakai scroll mandiri, footer total dan tombol simpan tetap
  terlihat, serta form berubah menjadi dua kolom pada ruang yang cukup.
- [x] Status bar ditempatkan di toolbar atas bersama aksi pengaturan, printer,
  workspace, dan shift.
- [x] Append order memuat detail server dan mempertahankan line lama melalui
  `order_line_id`; bundle diringkas menjadi satu baris pada cart.
- [x] Tombol payment pada order `DRAFT/PENDING` mengonfirmasi order melalui
  endpoint mobile yang tersedia sebelum menyiapkan pembayaran.
- [x] `flutter analyze`, `flutter test`, dan `flutter build apk --debug`
  lulus.

### 2026-08-23 - Lifecycle, printer, profile, dan idempotency

- [x] Profil koneksi server memiliki namespace lokal terpisah untuk cache,
  order, outbox, log, dan binding printer.
- [x] Endpoint cetak KOT saat order confirmed, cetak ulang order, payment,
  void, refund, dan tutup shift tersedia untuk APK.
- [x] Binding Bluetooth lokal menjadi sumber alamat printer terakhir; alur
  cetak tidak lagi bergantung pada alamat printer global di setup awal.
- [x] Void/refund APK mengambil reversal preview Finance dan memungkinkan
  pemilihan item serta qty parsial.
- [x] Payment menyimpan `client_event_id` pada event server yang sama dengan
  order, sehingga retry setelah timeout tidak menggandakan payment.
- [x] Payment menampilkan informasi member, deposit terpakai, poin, dan stamp
  dari response server.
- [x] Produk dengan availability `OUT`, `UNAVAILABLE`, atau `SOLD_OUT` tidak
  dapat ditambahkan ke keranjang.
- [x] `flutter analyze`, `flutter test`, PHP lint, dan `flutter build apk
  --debug` lulus.
- [ ] Uji smoke test dengan login token baru pada server lokal, printer
  Bluetooth nyata, order confirmed, payment, void, refund, dan reconnect.

### 2026-08-23 - Penyelesaian alur non-printer

- [x] Draft lokal tidak lagi tertimpa: setiap order memiliki UUID dan event
  sendiri; draft dapat dihapus dari perangkat tanpa menghapus order resmi
  server.
- [x] Workspace order aktif/terbayar menampilkan detail order server maupun
  detail cache lokal, termasuk item, extra, catatan, customer, total, dan
  status sinkronisasi.
- [x] Respons `stock_commit_status` dari server disimpan ke payload lokal agar
  status tidak hilang setelah APK restart.
- [x] Daftar order dibuat responsif; tombol payment, void, refund, dan reprint
  tidak keluar layar pada emulator sempit.
- [x] Tutup shift menerima input langsung atau perhitungan pecahan uang.
- [x] `flutter analyze`, `flutter test`, PHP lint, dan `flutter build apk
  --debug` lulus.
- [x] Endpoint mobile printer memakai konfigurasi baru Finance bila fondasi
  `pos_print_*` aktif: koneksi, layout, aturan event, dan tampilan umum tidak
  lagi membaca device printer lama.
- [x] Test print server-authoritative mengambil route aktif dan layout yang
  benar-benar dipakai koneksi tersebut, termasuk branding umum, divisi,
  document type, lebar kertas, jumlah copy, potong kertas, dan drawer.
- [x] Semua target order/KOT, payment, cetak ulang, void, refund, dan tutup
  kasir dinormalisasi oleh endpoint mobile; marker logo/QR/barcode yang hanya
  dipahami print agent dibuang untuk Bluetooth SPP.
- [x] APK memakai satu dispatcher cetak dan binding lokal berdasarkan ID
  koneksi server secara exact; fallback berdasarkan role di jalur operasional
  dihapus agar printer antar-divisi tidak tertukar.
- [x] Native Android mendukung jumlah copy, `cut_mode`, dan `open_drawer`
  dari Finance.
- [~] Pengelolaan printer lanjutan menunggu deploy file Finance terbaru ke
  server publik dan smoke test dengan printer Bluetooth fisik.
- [x] Runtime Finance dan endpoint mobile printer tidak lagi memakai fallback
  `pos_printer_*`; sumber konfigurasi aktif hanya `pos_print_*`.
- [x] Migration `finance/sql/2026-08-25e_drop_legacy_pos_printer_tables.sql`
  sudah diuji dan diterapkan pada `db_finance` lokal setelah backup; migration
  menghapus tabel anak lebih dulu sesuai foreign key. Deploy ke server publik
  tetap harus dilakukan setelah kode Finance terbaru terpasang.
- [x] Dialog payment APK memakai panel responsif dengan isi yang dapat di-scroll
  dan footer tombol tetap terlihat; metode pembayaran server dideduplikasi.
- [x] Tombol `Cetak ulang` dibuat terlihat pada order aktif dan terbayar, bukan
  hanya ikon kecil.
- [x] Void/refund APK dapat memilih produk penuh atau extra tertentu, lalu
  mengirim `lines[].extras[]` ke kontrak reversal Finance.
- [x] Reversal Finance membedakan pilihan extra-only dari pembatalan produk penuh.
- [x] Finance mengirim daftar seluruh sesi kasir aktif beserta nama kasir,
  outlet, dan terminal; konflik pembukaan shift menyebut kasir yang sedang
  memakai terminal.
- [x] APK menampilkan peringatan kasir aktif dari server dan tombol `Ganti akun
  kasir` menuju Pengaturan.
- [x] Refund APK sekarang meminta alasan dan memilih produk/extra sebelum
  memilih metode pengembalian, mengikuti urutan operasional POS web.
- [~] `core.namuacoffee.com` masih mengembalikan HTTP 404 untuk
  `/pos-mobile/printers/test/:id`; route sudah aktif di lokal (tanpa token
  mengembalikan 401). Server publik harus menerima `Pos_mobile.php` dan
  `routes.php` terbaru sebelum test print dapat dipakai di tablet.

### 2026-08-27 - Gate sesi kasir saat login/restart APK

- [x] Setelah login, APK membaca sesi aktif dari cache lokal per profile/server
  sebelum meminta pembukaan shift baru.
- [x] Jika sesi aktif milik user masih ada di server, APK langsung melanjutkan
  ke workspace tanpa dialog `Buka kasir`.
- [x] Jika tidak ada sesi aktif, APK meminta buka kasir otomatis setelah sync
  awal berhasil; transaksi baru ditolak sampai shift tersedia.
- [x] Jika terminal sedang dipakai kasir lain, APK menampilkan nama kasir dari
  respons konflik dan tidak menganggap pembukaan shift berhasil.
- [x] Respons pembukaan shift disimpan ke cache lokal segera setelah berhasil,
  sehingga restart atau putus koneksi sesaat tidak menghilangkan sesi aktif.
- [x] Setelah tutup kasir berhasil, cache sesi lokal dikosongkan agar shift yang
  sudah ditutup tidak dipakai kembali saat APK dibuka offline.
- [x] Urutan bootstrap cache dan sync awal dibuat serial agar state server tidak
  tertimpa oleh pembacaan cache lama.
- [ ] Uji perangkat: login user yang sudah punya shift, login tanpa shift,
  restart saat offline, dan konflik terminal oleh kasir lain.

### 2026-08-27 - Penyempurnaan cart dan payment APK

- [x] Preview member diringkas menjadi format `NAMA - NOMOR HP`, dengan nomor
  member, tier, poin, dan stamp tetap tersedia pada baris informasi berikutnya.
- [x] `Simpan Transaksi` hanya menyimpan order sebagai confirmed/aktif dan tidak
  otomatis membuka modal payment; payment dilakukan dari workspace order aktif.
- [x] Item order yang sudah memiliki `order_line_id` tidak dapat dikurangi atau
  dihapus dari cart saat edit; pembatalannya tetap melalui Void per produk/extra.
- [x] Tombol bersihkan cart saat edit hanya membersihkan item baru, tidak item
  yang sudah tersimpan di server.
- [x] Modal payment workspace dipadatkan dan dibuat responsif: field metode,
  nominal, serta referensi sejajar pada layar lebar dan bertumpuk aman pada
  layar sempit; footer tetap terlihat.
- [x] Ukuran font dan kepadatan komponen umum APK diturunkan tanpa memakai
  `TextTheme.apply` yang dapat memicu assertion Flutter.
- [ ] Uji perangkat: simpan transaksi tanpa payment, buka kembali dari Order
  Aktif, lakukan payment, dan edit order tanpa menghapus item server.

### 2026-08-21 - R0 tahap pertama

- [x] Error HTTP mobile sekarang menyimpan status code dan path endpoint.
- [x] HTTP 401 dikenali sebagai token kedaluwarsa.
- [x] APK menghapus token lokal dan kembali ke alur login saat sync/session/printer menerima 401.
- [x] `auth_expires_at` disimpan dari response login.
- [x] Dialog extra membedakan API error dari extra yang memang kosong.
- [x] Bootstrap sukses dapat mengisi default outlet/terminal dari Finance secara otomatis.
- [x] Tombol `Sinkron sekarang` tampil sebagai tombol teks di panel status kasir.
- [x] Logout lokal dan revoke token server tersedia dari halaman Pengaturan POS.
- [x] Tab order aktif dan terbayar dibatasi ke order tanggal hari ini.
- [x] Form keranjang APK sekarang membawa tipe layanan, customer/member, guest, meja, sales channel, catatan order, extra, dan catatan line.
- [x] Panel sesi menampilkan ikon status shift dan username kasir yang login.
- [x] Customer member terpilih sekarang menampilkan preview nama, nomor member, tier, point, stamp, dan tombol hapus di keranjang.
- [x] Pencarian Customer sekarang berjalan otomatis setelah minimal dua karakter; hasil kandidat dipisahkan dari mode Walk-in/non-member.
- [x] Pencarian Customer menampilkan maksimal lima kandidat member; pemilihan member dilakukan dengan klik, atau dapat dipaksa menjadi non-member.
- [x] Tab Paket / Bundle menampilkan 9 bundle aktif dari server dan detail komponennya.
- [x] Jalur dialog pencarian member lama dihapus untuk mencegah assertion lifecycle Flutter saat response async kembali setelah widget ditutup.
- [x] Audit awal menemukan 9 bundle aktif di server untuk tahap R3.
- [x] `flutter analyze` bersih, `flutter test` lulus, dan debug APK berhasil dibuat.
- [~] Smoke test endpoint ber-token: endpoint diuji dengan token emulator dan mengembalikan 401 karena token sudah invalid; perlu login ulang untuk uji 200.
- [ ] Halaman diagnostik lengkap untuk user, employee, outlet, terminal, token expiry, dan session.

### 2026-08-21 - Perbaikan availability stok pada katalog

- [x] Audit database menemukan `pos_product_availability_cache` berisi 278 row.
- [x] Sampel outlet 1 tervalidasi: BTS COFFEE `6,2`, JAZZY ALMOND `10`, dan KOPI SUSU NAMUA `25,95`.
- [x] API `/pos-mobile/catalog` sekarang memakai active session atau default outlet dari `cashier_bootstrap_options()` jika `outlet_id` belum dikirim/masih nol.
- [x] APK mengirim `outlet_id` pada bootstrap jika sudah tersimpan di pengaturan.
- [x] Parser produk menerima field availability server dan fallback alias yang relevan; foto juga menerima `photo_path` dari Finance.
- [x] Kartu produk tidak lagi menampilkan `Stok 0` ketika availability memang belum ada; statusnya menjadi `STOK BELUM SINKRON`.
- [x] Foto katalog memakai `photo_path` server dan cache file lokal APK; fallback icon dipakai bila foto kosong/gagal.
- [x] Dialog payment utama menerima beberapa metode pembayaran, referensi per metode, dan menampilkan kembalian dari respons server.
- [x] Kontrak HPP/stok didokumentasikan sebagai server-authoritative: APK tidak menghitung HPP atau commit stok lokal.
- [x] Cache foto memakai `ETag`/`Last-Modified` bila tersedia; foto yang tidak berubah tidak diunduh ulang.
- [x] Preload foto dibatasi empat request paralel dan request URL yang sama dideduplikasi.
- [x] Error HTTP 422 tidak lagi tampil sebagai `Offline`; pesan ringkas diarahkan ke status tindakan server.
- [x] Draft yang tersimpan lokal dapat dipilih dari tombol `Draft lokal` lalu dipulihkan ke cart.
- [x] `flutter analyze` bersih dan `flutter test` lulus setelah perbaikan sync/layout/cache.
- [x] PHP lint, `flutter analyze`, `flutter test`, dan `flutter build apk --debug` lulus.
- [ ] Uji perangkat: login ulang dengan token baru, sinkron, pilih `FOOD`, dan cocokkan angka stok dengan web/server.

### 2026-09-03 - Tahap inbox order masuk dan printer test

- [x] APK menambahkan menu `Order masuk` dari toolbar kasir untuk memilih
  Reservasi, Self-order, atau Order online.
- [x] APK memiliki layar inbox responsif dengan pencarian, refresh, tab status,
  detail order, rincian item, dan rincian extra dari server.
- [x] Reservasi memiliki tab `Transaksi` dan `Rincian produk`; default status
  mengikuti tab aktif Finance (`ACTIVE`).
- [x] Finance2 menambahkan endpoint mobile read/detail di `Pos_mobile.php`
  untuk ketiga kanal dan route baru di `application/config/routes.php`.
- [x] Endpoint inbox memakai model Finance2 yang sama dengan web sehingga
  status order, payment, outlet, customer, dan snapshot operasional tidak
  dihitung ulang di APK.
- [x] `printerTest` APK diperbaiki dari `GET` menjadi `POST`, sesuai kontrak
  Finance2 dan pencatatan print attempt.
- [x] Tombol tambah printer diperjelas menjadi `Hubungkan printer`; yang dibuat
  APK hanya binding Bluetooth lokal ke printer server yang sudah ada.
- [x] Simpan binding printer lokal diberi error handling agar kegagalan database
  atau Bluetooth tidak menampilkan exception mentah.
- [x] Inbox memiliki aksi terima/tolak; verifikasi memakai resolver stock,
  snapshot/queue, finalisasi Finance, monitor task, dan target cetak per route.
- [x] Penolakan meminta alasan dan memakai model Finance2 untuk menjaga audit
  status serta payment channel tetap konsisten.
- [ ] Uji hasil verifikasi pada data nyata dengan token baru dan pastikan worker
  runtime menyelesaikan queue stock sebelum audit laporan.
- [ ] Uji Apache lokal, login token baru, inbox berisi data, koneksi Bluetooth,
  preview test print, dan cetak fisik di Samsung.

### Urutan kerja yang disepakati

1. R0: bereskan token dan diagnostik agar error tidak disamarkan.
2. R1-R2: outlet/terminal/bootstrap dan shift kasir.
3. R3: extra, bundle, search, foto, dan cart sampai sama dengan web. Langkah berikutnya: uji foto pada perangkat dan audit payload extra/bundle.
4. R4/R8: uji draft lokal, event `BLOCKED`, retry manual setelah shift dibuka, dan reconnect tanpa mengganggu cart aktif.
5. R5: payment, voucher, member, dan deposit; lanjutkan point/stamp serta split payment pada workspace order.
5. R6: printer end-to-end; deploy API printer test dan endpoint katalog baru
   ke server publik, lalu uji binding Bluetooth dan cetak dummy per role/divisi
   di tablet Samsung.
6. R7: active/paid, void, refund; audit hasil reversal produk dan extra pada
   stok serta dokumen cetak.
7. R8: offline two-way sync dan background reliability.
8. R9: audit, release, dan pilot outlet.

Dokumen ini dipertahankan sebagai baseline historis. Perbarui status dan checklist pekerjaan baru hanya pada rolling plan aktif 2026-09-24, bukan checklist arsip ini.

## 9. Referensi Kode

- [Finance2 POS controller](../../finance2/application/controllers/Pos.php)
- [Finance2 mobile controller](../../finance2/application/controllers/Pos_mobile.php)
- [Finance2 POS model](../../finance2/application/models/Pos_model.php)
- [Finance2 reservation model](../../finance2/application/models/Pos_reservation_model.php)
- [Finance2 POS report model](../../finance2/application/models/Pos_report_model.php)
- [Finance2 order monitor model](../../finance2/application/models/Pos_order_monitor_model.php)
- [APK cashier screen](../pos_cashier_apk/lib/src/screens/cashier_screen.dart)
- [APK order workspace](../pos_cashier_apk/lib/src/screens/order_workspace_screen.dart)
- [APK printer screen](../pos_cashier_apk/lib/src/screens/printer_settings_screen.dart)
- [APK sync service](../pos_cashier_apk/lib/src/services/sync_service.dart)
- [APK local database](../pos_cashier_apk/lib/src/services/local_database.dart)
- [Mobile foundation SQL](../../finance2/sql/2026-08-20a_pos_mobile_sync_foundation.sql)
- [POS reservation foundation SQL](../../finance2/sql/2026-08-28a_pos_reservation_module_foundation.sql)
- [POS reservation audit SQL](../../finance2/sql/2026-08-28b_pos_reservation_creator_audit_and_cashier_independence.sql)
- [POS foundation SQL](../../finance2/sql/_old/2026-05-28a_pos_foundation_phase1.sql)
