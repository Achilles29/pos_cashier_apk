# Rolling plan aktif — APK POS, Finance, dan Control

Tanggal audit: 24 September 2026. Revisi kebutuhan: **25 September 2026 — offline operasional penuh untuk kasir**. Status: **panduan implementasi lokal; bukan pernyataan APK siap produksi**.

## 1. Mulai dari sini

Pegangan utama pengembangan APK adalah dokumen ini. Dokumen Agustus/awal September menjadi riwayat, bukan daftar pekerjaan aktif. Backend acuan sekarang **`finance`**, bukan `finance2`; nama database dan domain bukan identitas produk atau lisensi.

Tiga dokumen kerja, dengan fungsi berbeda:

1. **Dokumen ini:** prioritas, peta fitur, file sasaran, dan checklist kemajuan.
2. [Kontrak Finance–APK–Control](2026-09-24_kontrak_apk_finance_control.md): API yang benar-benar ada, usulan yang belum tersedia, lisensi perangkat, dan aturan offline.
3. [Panduan eksekusi lokal dan UAT](2026-09-24_uat_apk_dan_eksekusi_lokal.md): prompt siap pakai, pengujian, bukti audit, dan kriteria rilis.

**Pekerjaan pertama: APK-01, lalu APK-02 dan APK-03.** Pembayaran dan pencatatan stok/keuangan offline adalah kebutuhan inti, bukan perluasan opsional. Bangun fondasi identitas, ledger lokal, aturan transaksi berversi dan pemulihan sebelum UI lanjutan. Pembahasan kontrak offline/lisensi dengan Finance dan Control berjalan paralel sejak APK-01; jangan menunggu semua layar selesai.

Audit ini hanya membaca source dan memperbarui dokumentasi. Tidak ada perubahan Dart/Kotlin/PHP/SQL, koneksi database, aktivasi, build release, push, atau perubahan instalasi customer. Isi `_note` tidak dijadikan sumber.

## 2. Baseline yang diperiksa

| Komponen | Baseline aktual | Batas bukti |
|---|---|---|
| APK | `/www/wwwroot/pos_cashier_apk`, commit `c2a3f32d056b91684571096622ec8bec2d74d2b9`, versi `1.1.0+2` | Source; belum dijalankan pada Android dalam audit ini |
| Finance | `/www/wwwroot/finance`, commit `4a75f07cdf0ca67a7b4fb7409db206aceb85a13d` | Source POS web/mobile, service terkait, route, feature policy, test |
| Paket Finance | Manifest `0.1.0-alpha.23`, `CUSTOMER_CLEAN` versi **11** | Nilai source; bukan bukti release telah dibangun/published |
| Control | `/www/wwwroot/control` | Working tree belum mempunyai HEAD Git; provenance memakai hash file di dokumen UAT |
| Flutter | Tidak tersedia di lingkungan audit | `analyze`, `test`, build, dan pengujian printer belum dijalankan |
| PHP | 8.1.32, pengujian tanpa database | 15 smoke POS mobile lulus; satu gate fitur global gagal, dijelaskan di bawah |

Identitas Android `com.namuaprojects.finance.pos` harus dipertahankan untuk update instalasi yang sudah memakai identitas tersebut. SQLite saat audit versi **5**. `pubspec.yaml` membutuhkan Dart `^3.7.2`; lockfile menyebut Flutter `>=3.29.0`. Ini batas minimum source, **bukan bukti kombinasi toolchain tertentu sudah lulus build**.

## 3. Tujuan produk dan batas tanggung jawab

- APK adalah kasir pendamping/pengganti POS web dengan database operasional lokal, bukan salinan database Finance yang bebas menimpa database server.
- Web dan APK boleh memakai sesi kasir yang sama sesuai akun/employee dan outlet yang diizinkan. Tidak perlu menutup web untuk berpindah perangkat. Owner terminal dan asal perangkat transaksi tetap tercatat.
- **Target sesuai arahan 25/09:** saat server tidak tersedia, kasir tetap dapat menjual, menerima pembayaran tunai, mengeluarkan struk, mencatat pergerakan stok serta kas lokal, dan menutup pekerjaan lokal sesuai izin offline. Bukan hanya menyimpan draft untuk dibayar nanti.
- **Keadaan source hasil audit berbeda:** pembayaran, void/refund, buka/tutup sesi dan verifikasi masuk saat ini masih membutuhkan server. Itu gap implementasi yang harus diselesaikan, bukan batas produk yang diinginkan pengguna.
- APK menyimpan transaksi, pembayaran, pergerakan stok, kas dan representasi jurnal POS lokal dalam transaksi database yang atomik, disertai outbox. Status bisnis `LUNAS LOKAL` berbeda dari status pengiriman `BELUM TERSINKRON`; uang yang sudah diterima tidak boleh dianggap belum dibayar hanya karena server mati.
- Finance tetap menjadi sumber aturan/master dan konsolidasi seluruh perangkat. APK menjalankan subset aturan kasir berversi yang sudah disinkronkan; hasil uang/harga/struk penjualan yang selesai tidak diganti diam-diam ketika sync. HPP/lot lokal bersifat proyeksi sampai rekonsiliasi server, dengan selisih yang dapat diaudit.
- Control tetap menjadi otoritas hak komersial. Hak `POS_MOBILE_APK`, kuota terminal, kuota server, dan lisensi instalasi APK adalah hal berbeda.
- “Setara POS web” berarti seluruh pekerjaan **kasir** yang relevan dan dibeli paketnya, termasuk kanal pesanan, printer, DP, serta laporan kasir. Bukan memindahkan payroll, produksi, purchase, atau administrasi seluruh aplikasi ke APK.

### Dua skenario wajib, bukan fitur tambahan

1. **Sejak awal menggunakan APK:** tulis transaksi secara durable ke lokal, sync terus selama server tersedia. Saat koneksi hilang, proses kasir lokal terus berjalan; saat koneksi kembali, kirim event berurutan, terima tanda penerimaan server, lalu rekonsiliasi. Jangan menyalin saldo lokal menimpa saldo pusat.
2. **Dari web berpindah ke APK sebelum pemadaman:** jalankan tombol **Siapkan / Lanjutkan Kasir di APK**. Sinkronkan snapshot lengkap, sesi, saldo pembuka, order belum selesai beserta pembayaran/versi, template cetak dan izin offline. Konfirmasikan cutover yang dicatat server; sesi tetap sama, order yang dialihkan dilindungi dari perubahan web yang bersaing. Setelah tampil **Siap offline**, APK dapat melanjutkan tanpa server.

Siapkan APK sebagai cadangan sejak awal shift agar pemadaman mendadak juga dapat ditangani sejauh snapshot yang sudah tersimpan. Jika APK belum pernah login/sinkron, transaksi web yang belum sampai perangkat tidak dapat diketahui secara ajaib. Tampilkan waktu sync dan cakupan data, bukan janji pemulihan tanpa data.

Batas nyata: QRIS/payment gateway yang membutuhkan provider, order online yang belum pernah diterima, dan saldo/voucher bersama tanpa alokasi offline tidak dapat diverifikasi tanpa koneksi. Ini tidak menghentikan penjualan tunai biasa. Detail pengamanan multi-perangkat, stock, uang dan cutover ada di bagian 4 kontrak aktif.

## 4. Status yang tidak boleh dicampur

**Ada** = jalur terlihat di source; **Sebagian** = ada jalur, tetapi ada kekurangan nyata; **Gap** = padanan mobile/kontrak belum tersedia; **UAT** = harus dibuktikan pada runtime terisolasi/perangkat.

Checklist batch hanya dicentang selesai setelah implementasi, test, dan bukti review ada. Checklist lama yang pernah lulus pada versi berbeda tidak otomatis berlaku di HEAD ini.

### Peta kesetaraan kasir

| Area POS web | Kondisi APK/API saat audit | Pekerjaan lanjutan | Batch |
|---|---|---|---|
| URL, login, multi-role, outlet/terminal | Ada; API token terikat device key dan scope; pesan login sudah memakai URL | Diagnostik aman, token aman, scope akun tetap, alasan RBAC/paket dibedakan | 01–02 |
| Hak paket dan lisensi per APK | Finance punya feature gate; APK belum punya lisensi perangkat terverifikasi | Kontrak perangkat Control + enforcement server dan offline lease | 01, 11 |
| Buka/lanjut sesi web–APK | Ada, termasuk backup mode | Uji dua perangkat/akun, shift tutup dari web, pemulihan tanpa sesi ganda | 03, 07 |
| Katalog, pencarian, foto, divisi | Ada; bootstrap hanya sebagian katalog | Pagination/snapshot lengkap, cache kosong sah, indikator stok terakhir | 04 |
| Bundle dan extra | Ada; fetch bundle sudah ada, extra bergantung jaringan | Seluruh bundle, constraint extra, variasi bundle sama, cache offline lengkap | 04 |
| Tipe layanan, meja, tamu, catatan, sales channel | Ada di cart/order | Round-trip draft dan append tanpa hilang field; harga kanal dari server | 04 |
| Member dasar | Cari/pilih, point/stamp terlihat | Pemulihan member di draft; create/edit minimal lewat API ber-RBAC bila diizinkan | 04, 05, 10 |
| Simpan/konfirmasi/append order | Ada dengan outbox | Identitas draft tetap, antrean berurutan, revisi konflik web–APK | 03–04 |
| Order aktif/terbayar dan histori | Ada, UI mengambil halaman pertama; server membatasi hari ini | Pagination, rentang tanggal server, pending lama selalu terlihat | 04, 10 |
| Pembayaran cash/noncash/campuran, rekening | Ada dua implementasi dialog | Satu payment flow, percobaan tersimpan, jumlah dari server, retry aman | 05 |
| Penjualan selesai offline | Belum; implementasi sekarang baru antrean order | Payment cash lokal, struk, stock movement, cash ledger/jurnal POS, upload idempoten dan rekonsiliasi | 03–07, 09 |
| Handover web → APK → web | Backup sesi ada; cutover + snapshot lengkap belum ada | Readiness, checkpoint/revision, writer fencing, resume/catch-up tanpa bayar/stock ganda | 03, 07 |
| Voucher dan loyalty | Pencarian voucher, ringkasan poin/stamp ada | Validasi hak paket, masa berlaku, saldo/hasil server, pembayaran voucher penuh | 05 |
| DP/deposit member | Server web mengaplikasikan DP; APK baru menampilkan sebagian ringkasan | Samakan preview sisa bayar/DP dengan web; alur penerimaan/void DP berizin | 05, 08 |
| Void/refund, partial/full, pengembalian stok | Ada preview/step-up/writer | UAT produk tanpa resep, extra/bundle, lot, refund berulang dan race web–APK | 06 |
| Rekonsiliasi dan tutup kasir | Preview/close/step-up ada; daily-recon guard juga ada di server | Petunjuk checkpoint, uang fisik vs sistem, pending lokal tidak tersembunyi | 07 |
| Self-order dan online-food | Inbox/detail/terima/tolak ada | Sinkron status final/queue, klaim bersamaan, badge, tindak lanjut pembayaran | 08 |
| Reservasi | List/detail/produk/terima/tolak + refund DP saat reject ada | Create/edit, penerimaan DP, cancel belum punya padanan mobile lengkap | 08 |
| Monitor dapur/bar/checker dan job tertunda | Finance punya monitor/runtime jobs; APK belum setara | Progress order dan retry yang diizinkan; jangan memindahkan worker ke APK | 08, 10 |
| Cetak kasir/divisi, ulang/void/refund/shift | Ada target server, Bluetooth, logo raster, QR/barcode, step-up | Queue per dokumen/target, partial print, preview sama, uji fisik | 09 |
| Lebar kertas dan jumlah karakter | Sudah lokal di binding APK | Pertahankan; jangan ditimpa konfigurasi server saat sync | 09 |
| Laporan sales/daily-sales/pembayaran/void/refund/close | Web lengkap; tidak ada route laporan khusus mobile dalam 46 route saat audit | API scoped + layar/PDF/berbagi sesuai RBAC, periode & total sama web | 10 |
| Konfigurasi kasir | URL/device/printer lokal ada; master outlet, rekening, printer/routing di web | Pisahkan setting lokal dan admin; expose operasi admin relevan lewat API aman | 09–10 |
| Notifikasi WA/Telegram dan bukti PDF | Finance punya pengiriman terpusat; belum jalur mobile setara | APK meminta server mengirim; tidak menyimpan token bot/provider | 10 |

Master produk/resep/akun/printer tetap server-authoritative. Kemampuan internal stok/resep yang dibutuhkan kasir tidak berarti semua layar manajemen inventory harus dibuka. Jangan meminta paket Enterprise hanya untuk mengatasi dependensi teknis yang salah dipetakan.

## 5. Temuan terarah dari source

Semua “risiko” di bawah perlu reproduksi runtime; bukan klaim bahwa transaksi customer telah rusak. Peta ini mencegah mengulang scan besar setiap batch.

| ID / prioritas | Bukti source dan dampak | Solusi yang diarahkan |
|---|---|---|
| F01 / Kritis | `SettingsStore.profileIdForUrl`, `AppSettings.storageScope`, singleton `LocalDatabase.setScope`; scope berbasis URL, tidak mengikat pembuat event. Penggantian akun/profil saat operasi async berisiko mengirim atau mencatat ke konteks berbeda | Context immutable per operasi: instance terverifikasi, actor, device, outlet, shift. Migrasi scope lama terverifikasi; tidak memindah otomatis berdasarkan URL |
| F02 / Kritis | Dua `_clientEventId` pembayaran hidup di state dialog, bukan penyimpanan durable | Simpan payment attempt sebelum POST; setelah timeout/kill cari hasil event yang sama, bukan membuat percobaan baru |
| F03 / Tinggi | `pendingOutbox` melewati BLOCKED; `_pushOutbox` hanya menyimpan `blockedAggregates` dalam satu loop; requeue massal memakai event REJECTED lama | Dependency/sequence persisten, claim lintas isolate, pisahkan retry transport dari koreksi transaksi |
| F04 / Tinggi | `_restoreLocalDraft` tidak memulihkan identitas draft/editing order, mengosongkan member; `enqueueLocalOrder` dapat membuat UUID baru | Simpan dan restore local UUID, server ID, member/channel, bundle occurrence dan revisi. Satu draft tetap satu order |
| F05 / Tinggi | `_serverBindingFromCache` menimpa outlet/terminal payload lama; callback background memakai setting aktif | Jangan rebind intent lama diam-diam. Hold + instruksi rekonsiliasi bila binding berubah |
| F06 / Tinggi | Bootstrap memakai limit 120 produk/60 bundle, `since` belum menjadi delta nyata; extra diambil saat klik | Snapshot lengkap/pagination, tombstone, cache extra, usia stok/harga; data belum diunduh ≠ tidak tersedia |
| F07 / Tinggi | `orders_push`: simpan draft, konfirmasi, lalu catat hasil event terpisah. PROCESSING/confirm gagal memerlukan pembuktian pemulihan | Finance harus memulihkan hasil berdasarkan event/aggregate dan bukti bisnis; jangan upsert ulang buta atau menghapus jurnal event |
| F08 / Tinggi | `payment_save` hanya memakai jurnal idempoten bila event ID dan tabel tersedia | Jalur kontrak mobile baru mewajibkan idempotensi; schema belum siap harus ditolak sebelum writer. Jangan mengubah aturan payment web |
| F09 / Tinggi | Token/API key diserialisasi ke SharedPreferences; Android `usesCleartextTraffic=true`; device key editable bukan identitas kriptografis | Secure credential storage, kebijakan TLS/release, backup policy, installation key non-exportable yang diuji |
| F10 / Tinggi | Server Control hanya menerbitkan metric SERVER_INSTANCE; manifest Finance punya boolean APK dan limit terminal gabungan | Kontrak lisensi APK terpisah dengan kuota atomik, lifecycle perangkat, signed lease, dan bukti integrasi nyata |
| F11 / Sedang | Order API mengunci tanggal hari ini; daftar lokal membatasi tanggal/100 baris; UI mengambil page 1 | Pagination + rentang tanggal resmi; semua transaksi tertunda lintas hari dapat ditelusuri |
| F12 / Sedang | Print queue berbasis order/document type; sebagian printer sukses dapat menghabiskan entry; native belum dibuktikan timeout fisiknya | State per target/revisi/copy; partial retry tidak mengulang target sukses; bedakan diterima printer dengan benar-benar tercetak |
| F13 / Sedang | `consumeLegacyMigrationFlag` membersihkan tanda sebelum migrasi SQLite dipanggil | Tandai selesai setelah migrasi berhasil; crash recovery idempoten, tidak reset DB lokal |
| F14 / Sedang | `FinanceApiException` menyamaratakan 403; error mentah dapat masuk log/toString; 404 menyarankan upload controller manual | Kode error terstruktur, sanitasi, panduan update resmi, recovery center; tidak menampilkan secret/body HTML |
| F15 / Sedang | Setelah refresh, UI hanya mengganti beberapa koleksi bila nonempty; katalog yang benar-benar kosong bisa tetap menampilkan lama | Snapshot kosong tetap sah; commit cache atomik, cart aktif diberi validasi ulang tanpa dihapus |
| F16 / Kritis terhadap target offline | Belum ada ledger pembayaran/stok/kas offline lengkap dan import transaksi offline selesai; endpoint online tidak otomatis menjadi penerima replay offline | Transaksi lokal atomik + aturan snapshot berversi + kontrak import/reconcile Finance; bedakan lunas lokal dari sync |
| F17 / Tinggi | Backup session bukan bukti semua open order/payment web tersalin atau ada cutover writer | Handover checkpoint, kesiapan offline, epoch/revision fencing dan uji pemadaman terencana/mendadak |

Hal yang **sudah ada dan tidak perlu ditulis ulang tanpa reproduksi**: device header mobile, POST printer test, pencarian bundle, append existing order, step-up password untuk aksi sensitif, raster logo transparan dengan latar putih, pengaturan kertas/karakter lokal. Ketiadaan test fisik bukan bukti bahwa patch tersebut belum ada.

### Gate Finance yang perlu koordinasi terpisah

`tools/tests/feature_boundary_contract_smoke.php` gagal pada public action `procurement/division_po_sr_line_action` yang belum dipetakan. Ini temuan Finance global, bukan kegagalan lisensi APK yang sudah direproduksi. Jangan mengedit procurement dari batch APK; minta thread Finance memperbaiki mapping secara sempit dan menjalankan ulang gate sebelum paket customer baru. Jangan menurunkan gate agar hijau.

## 6. Checklist dan urutan implementasi

Semua batch implementasi di bawah **belum dikerjakan pada audit ini**. Urutan normal 01 → 12. Desain kontrak Control dibahas sejak 01; implementasi Control dilakukan di workspace/thread Control dengan izin tersendiri. Bila belum tersedia, pekerjaan APK lain boleh maju memakai fixture berlabel test, tetapi APK-11 dan rilis customer tetap terblokir.

| Batch | Hasil yang harus didapat | Bergantung pada | Status |
|---|---|---|---|
| Audit 24/09 | Peta kode, dokumen, API, gap, smoke tanpa DB | Source baseline | [x] selesai audit, bukan selesai produk |
| APK-01 | Baseline lokal, harness, kontrak/error/capability terkunci | Audit | [ ] |
| APK-02 | Login/profil/identitas aman dan tidak tertukar | 01 | [ ] |
| APK-03 | Ledger lokal atomik, outbox, recovery/import offline, race web/APK | 02 | [ ] |
| APK-04 | Katalog/cart/draft/bundle/extra/append lengkap | 03 | [ ] |
| APK-05 | Payment cash offline, rekening, DP/voucher beralokasi dan rekonsiliasi | 03–04 | [ ] |
| APK-06 | Void/refund dan stok/resep tervalidasi | 03–05 | [ ] |
| APK-07 | Sesi bersama, handover web–APK, offline readiness, tutup lokal/server | 03–06 | [ ] |
| APK-08 | Self-order, online order, reservasi/DP, progres dapur | 04–07 | [ ] |
| APK-09 | Printer andal dan setting fisik lokal | 03–08 | [ ] |
| APK-10 | Laporan, operasi admin kasir, UI terpadu | 04–09 | [ ] |
| APK-11 | Lisensi tiap instalasi APK dan integrasi Control nyata | Kontrak disetujui + 02–10 | [ ] BLOKER Control |
| APK-12 | Release signed, update in-place, UAT dan pilot | Semua gate sebelumnya | [ ] |

### APK-01 — Kunci baseline dan bangun test sebelum memperbaiki

File APK: `pubspec.yaml`, `pubspec.lock`, `test/widget_test.dart`, `lib/src/services/finance_api_client.dart`, `lib/src/models.dart`, konfigurasi Android. File Finance: `Pos_mobile.php`, `routes.php`, `feature_access.php`; koordinasi saja jika repo Finance tidak tersedia lokal.

- [ ] Catat SHA APK/Finance, versi Flutter/Dart/JDK/Android SDK dan fingerprint sertifikat APK uji; pisahkan debug dari release, tanpa menulis key/password.
- [ ] Jalankan analyze/test/build debug HEAD di lokal. Bila syntax/printer settings gagal, buat patch minimal + regression; jangan membenahi kurung berdasarkan nomor baris log lama saja.
- [ ] Tambah fixture HTTP tersanitasi untuk login/bootstrap/order/payment/step-up/inbox/printer; inject transport, clock, UUID, DB dan printer agar test deterministik.
- [ ] Bekukan field/tipe/HTTP code dalam contract tests; 45 template path client sudah cocok dengan route, tetapi method/body/semantik tetap perlu diuji.
- [ ] Tambahkan parsing capability version umum dan error terstruktur sebagai kontrak baru; versi 3 yang ada hanya `sensitive_action_contract`, bukan versi seluruh API.
- [ ] Kirim rancangan lisensi perangkat ke Control. Jangan membuat endpoint khayalan menjadi URL produksi.
- [ ] Bekukan kontrak offline operasional O01–O16: state bisnis vs sync, snapshot aturan, cutover, import sale/payment/stok/kas dan kebijakan resource bersama. Buat golden test harga/extra/bundle/pajak/rounding yang sama untuk PHP dan Dart.

Selesai bila baseline lokal dapat direproduksi, test benar-benar berjalan, API lama/baru punya compatibility table, dan kegagalan yang tersisa terdaftar. UAT A01–A06; audit gate global tidak boleh disembunyikan.

### APK-02 — Profil, login, identitas dan penyimpanan rahasia

File: `lib/src/app.dart`, `models.dart`, `services/settings_store.dart`, `services/finance_api_client.dart`, `screens/setup_screen.dart`, `screens/login_screen.dart`, Android manifest. Kandidat file baru: `services/connection_context.dart`, `services/credential_store.dart`, `services/device_identity_service.dart` (belum ada).

- [ ] Pisahkan **URL server**, **device key terminal**, **token login**, dan **lisensi instalasi APK** pada UI. API key legacy masuk pengaturan lanjutan, bukan tempat memasukkan `POS-DEMO`.
- [ ] Simpan token pada storage terlindungi; migrasi preference lama hanya hapus secret lama setelah penulisan baru terverifikasi. Password pengguna/step-up tidak disimpan.
- [ ] Bentuk context immutable per pekerjaan; cache bisnis dipisah instance dan actor/outlet, printer fisik dipisah instalasi/profil. Ganti akun tidak mengirim event milik akun sebelumnya.
- [ ] Pergantian profil menunggu/cancel pekerjaan in-flight dengan fencing; hasil lama tidak boleh masuk UI/cache profil baru. Logout memutus token, bukan menghapus outbox.
- [ ] URL berubah tetapi instance terverifikasi sama: flow pindah alamat dengan konfirmasi dan migrasi atomik. URL sama tetapi instance berbeda: jangan memakai data/token lama.
- [ ] Kunci perangkat unik dibuat sekali dan tidak ikut backup export; definisikan lifecycle upgrade/uninstall/perangkat pengganti bersama Control. Jangan mengganti key setiap login.
- [ ] HTTPS untuk customer; pengecualian koneksi lokal hanya debug/test terkontrol. Jangan menonaktifkan verifikasi sertifikat untuk mengatasi error jaringan.

Selesai bila A02–A10 lulus, termasuk crash migrasi, akun kedua, dua profil dan response terlambat. Belum mengklaim lisensi perangkat aktif sebelum APK-11.

### APK-03 — Antrean tahan gangguan dan kontrak recovery server

File APK: `services/local_database.dart`, `services/sync_service.dart`, `services/background_sync_service.dart`, `services/finance_api_client.dart`, `app.dart`. Kandidat: `services/sync_coordinator.dart`. Finance: `Pos_mobile.php::orders_push/payment_save`, `Pos_model.php`, route, migrasi baru terkelola bila diperlukan.

- [ ] Migrasi SQLite dari v5 secara additive; uji v1–v5 sesuai upgrade path. Tambah actor/context, aggregate revision/sequence, payload hash, attempt/lease/retry metadata, hasil server. Nomor schema diputuskan dari HEAD lokal, bukan hardcode dari dokumen ini.
- [ ] Klaim event atomik lintas foreground/background; timeout lease boleh dipulihkan, tetapi event ID dan payload tidak berubah. Cegah event berikut melewati predecessor BLOCKED/UNKNOWN.
- [ ] Bedakan PENDING, SENDING, UNKNOWN/PROCESSING, ACCEPTED, REJECTED/NEEDS_ACTION. Ini rancangan state baru; jangan menyamakan `HTTP timeout` dengan ditolak.
- [ ] Hilangkan rebind payload otomatis dan requeue seluruh penolakan bisnis. Perbaikan intent yang benar-benar ditolak memakai event baru yang merujuk event lama; hasil ambigu harus dicari dulu.
- [ ] Finance menyediakan lookup hasil event terikat actor/instance/device/outlet serta recovery PROCESSING. Pastikan draft tersimpan tetapi confirm gagal tidak menjadi order ganda ketika dilanjutkan.
- [ ] Uji dua POST identik bersamaan, payload berbeda dengan ID sama, crash sesudah commit sebelum response/journal-final, dan konflik revisi order web–APK. Resolusi memeriksa bukti transaksi, bukan menghapus log.
- [ ] Sinkronisasi memisahkan refresh master, session, push dan rekonsiliasi hasil; refresh katalog gagal tidak membenarkan mengirim dengan binding tak tervalidasi, tetapi tidak boleh menghalangi pembacaan hasil payment yang sudah terjadi.
- [ ] Antrean lintas hari tetap terlihat. Workmanager membantu, bukan janji sinkron real-time saat aplikasi dibatasi Android. UI foreground menyediakan sinkron manual dan retry backoff yang terukur.
- [ ] Tambahkan tabel/record immutable order-line snapshot, payment lokal, stock movement, cash movement, posting journal POS lokal, session/checkpoint dan sync receipt. Sale + payment + ledger + outbox harus commit atomik sebelum UI menyebut lunas atau printer berjalan; koreksi melalui reversal, bukan overwrite histori.
- [ ] Finance menyediakan import event offline selesai, bukan memaksa semua event melewati validasi order online dengan harga/shift terkini. Validasi policy snapshot, batas offline dan bukti urutan; intake durable/idempoten terpisah dari status posting/review. Tidak menagih ulang payment yang sudah diterima lokal.
- [ ] Setelah server pulih, jangan overwrite saldo atau refresh snapshot terlebih dahulu hingga transaksi lokal tampak hilang. Rekonsiliasi watermark/receipt, mapping UUID↔ID pusat dan saldo proyeksi; event ditahan review tetap tersimpan. Uji O01–O06/O12–O16.

Selesai bila S01–S12 lulus termasuk process-kill. Perubahan server yang belum tersedia adalah blocker integrasi, bukan alasan menambahkan fallback penulisan non-idempoten.

### APK-04 — Katalog lengkap, cart, draft, dan append

File APK: `models.dart`, `cashier_screen.dart`, `order_workspace_screen.dart`, `photo_cache_service.dart`, `local_database.dart`. Finance: `Pos_mobile.php::bootstrap/catalog/extra_options/orders`, `Pos_model.php::order_product_catalog/order_bundle_catalog/order_extra_options/save_order_draft`, `PosBundlePricingService.php` sebagai referensi aturan, bukan salinan ke Dart.

- [ ] Snapshot katalog terpaginasi lengkap dengan versi dan tombstone; cursor maju hanya setelah seluruh snapshot selesai dan tersimpan atomik. Tidak menyebut delta bila hanya full refresh.
- [ ] Cache extra wajib/opsional, batas min/max/qty, bundle berikut pilihannya. Bila cache belum lengkap, tampilkan “Belum siap offline”; jangan mengizinkan konfigurasi invalid diam-diam.
- [ ] Restore identitas draft, server ID/revision, member, channel, notes/tamu/meja, UOM/qty dan bundle occurrence. Save draft berkali-kali tidak membuat order baru.
- [ ] Append mempertahankan line lama, identitas variasi, dan total server; dua bundle sama dengan extra berbeda tidak digabung tanpa aturan.
- [ ] Tangani produk dinonaktifkan, harga/availability berubah dan katalog menjadi kosong. Cart tidak dibuang; perbedaan ditampilkan sebelum konfirmasi ulang.
- [ ] Histori/order API mendukung pagination dan tanggal terikat timezone usaha; cache lokal pending tidak dibatasi hari ini. Availability UNKNOWN dibedakan dari nol stok.
- [ ] Batasi cache foto (ukuran/MIME/nama file pendek/kuota) dan dukung invalidasi; cache bukan tempat menyimpan credential URL.
- [ ] Paket data **siap offline** mencakup resep/BOM/extra/bundle dan UOM secukupnya untuk ledger persediaan, kebijakan harga/promo/pajak/rounding, metode/rekening, aturan kas dan template/logo cetak. Ambil hanya scope yang diizinkan; golden tests membuktikan perhitungan lokal setara aturan versi snapshot.

Selesai bila C01–C10 serta S03–S08 lulus. Paket Starter + addon APK harus bisa memesan produk yang memerlukan service stok/resep internal tanpa membuka layar Inventory Advanced.

### APK-05 — Pembayaran satu alur, DP dan promo tidak salah tagih

File: kedua dialog payment di `cashier_screen.dart` dan `order_workspace_screen.dart`, `finance_api_client.dart`, `local_database.dart`. Kandidat: `services/payment_attempt_repository.dart`, `widgets/payment_dialog.dart`. Finance: `payment_prepare/payment_save`, `Pos_model.php::cashier_payment_prepare/save_cashier_payment`, feature payload guard.

- [ ] Satukan dua dialog pada komponen dan service yang diuji; ID attempt durable sebelum kirim, response final disimpan sebelum navigasi/cetak.
- [ ] Online menggunakan keputusan server; offline menggunakan aturan snapshot berversi dan aritmetika uang presisi yang sama. Simpan versi aturan/harga, total, due, pajak/service, DP/promo, nominal diterima dan kembalian; UI formatting tidak boleh menentukan angka transaksi.
- [ ] Samakan DP otomatis dengan web: tampilkan DP tersedia/terpakai/sisa; **DP menutup tagihan** dan voucher penuh tidak memaksa pembayaran cash tambahan. Tidak mengarang tombol redeem point jika web tidak punya aturan itu.
- [ ] Cash, noncash, rekening terikat metode, referensi, split tender, pembayaran sebagian jika memang diizinkan server, dan kembalian diuji. “Split tender” bukan split/merge order baru.
- [ ] Setelah timeout, buka ulang dialog/restart melakukan periksa hasil; jangan memulai payment kedua sampai status lama jelas.
- [ ] Transaksi yang belum selesai direvalidasi sesuai mode. Penjualan offline yang telah menerima uang mempertahankan nilai transaksi/struk saat itu; perubahan harga pusat saat sync tidak menagih ulang atau mengubah histori diam-diam. Perbedaan masuk rekonsiliasi.
- [ ] Periksa akun/member berbeda, voucher used/expired, downgrade entitlement, dan dua kasir membayar bersamaan. Tidak ada debit DP/voucher atau posting kas ganda.
- [ ] Selesaikan pembayaran tunai offline berikut change/cash ledger/struk; restart tetap menunjukkan lunas lokal dan belum sinkron. Timeout pembayaran online yang hasilnya UNKNOWN tidak boleh otomatis diubah menjadi pembayaran tunai baru.
- [ ] Noncash dibedakan bukti eksternal vs verifikasi provider. DP/voucher/saldo bersama hanya dapat dibelanjakan offline dari alokasi eksklusif yang telah dicadangkan, bukan angka cache biasa. Cash sale tetap berfungsi bila resource itu belum dialokasikan.

Selesai bila P01–P10 dan O01–O06/O09/O12/O16 lulus; kas/stok/jurnal POS lokal dan konsolidasi di DB disposable cocok, tanpa pembayaran ganda.

### APK-06 — Void/refund, resep, stok dan jejak audit

File: `order_workspace_screen.dart`, `widgets/sensitive_action_proof_dialog.dart`, API client; Finance `order_reversal_preview`, step-up, `order_void_save/order_refund_save`, shared POS stock/void services.

- [ ] Online memakai preview reversal server; offline memakai transaksi/snapshot yang dimiliki perangkat dan aturan versi yang sama. Full/partial, line/extra/bundle, alasan, uang dan stok kembali dicatat sebagai event kompensasi berreferensi, bukan menghapus penjualan.
- [ ] Kasus produk/event tanpa resep harus mengikuti keputusan server `NOT_REQUIRED` bila berlaku; jangan mensyaratkan stock commit yang memang tidak diperlukan.
- [ ] Resep/material/component, extra, bundle, defisit dan pengembalian lot diuji pada fixture. Tidak memperbaiki saldo/mismatch data nyata sebagai bagian batch APK.
- [ ] Step-up sekali pakai terikat actor/action/order; gagal/mundur/kedaluwarsa tidak boleh menjadi bypass. Saat hasil aksi ambigu, lookup sebelum meminta dan mengirim aksi baru.
- [ ] Partial berulang dibatasi jumlah tersisa, race refund web/APK tidak menggandakan kas/stok; kegagalan printer tidak mengulang refund.
- [ ] Reversal offline hanya untuk order lokal atau order yang sudah dialihkan eksklusif dan masih tercakup izin/saldo kas. Desain offline step-up melalui autentikasi lokal kuat + grant supervisor terikat device/action/limit; jangan menyimpan password Finance atau memakai ulang proof online kedaluwarsa. Tanpa izin aman, aksi sensitif ditunda tetapi penjualan biasa tetap jalan. Uji O10.

Selesai bila R01–R08 lulus, termasuk audit stok dan kas server serta RBAC multi-role. Jangan mengubah rumus Finance untuk membuat test Android lulus.

### APK-07 — Sesi kasir bersama dan tutup kasir yang jelas

File: `cashier_screen.dart`, session/cache service, API client; Finance `session_status/cashier_open/cashier_close_preview/cashier_close`, shared session/recon model.

- [ ] Web membuka sesi, APK attach sesi yang sama; APK membuka, web melanjutkan; beda akun/outlet tetap tunduk aturan. Simpan origin terminal terpisah dari owner.
- [ ] Tampilkan pemilik, outlet, mode backup dan status recon. Gunakan error `daily_recon_status` yang sudah ada; tambahkan read-only status API bila diperlukan, bukan mematikan guard.
- [ ] Shift ditutup di web saat APK offline: jangan mengubah shift lama ke shift baru pada payload. Tampilkan pemulihan sesuai keputusan server/supervisor; pending tetap tersimpan.
- [ ] Sebelum close, periksa payment UNKNOWN, outbox tertunda dan order belum final; laporan “semua tersinkron” tidak boleh menipu. Server memeriksa kewajiban online, APK menunjukkan kewajiban lokal.
- [ ] Uang aktual per metode/rekening, selisih, summary, step-up dan cetak close sama web; UI tidak membuat mutasi kas otomatis yang tidak diminta aturan server.
- [ ] Implementasikan handover web→APK dengan snapshot konsisten, watermark, daftar order + payment/revision, custody epoch, owner/origin dan ack **Siap offline**. Server memagari penulisan bersaing pada order yang dialihkan, bukan sekadar mengganti tab UI. Pelanggan tidak perlu menutup sesi web dulu.
- [ ] Dukung buka/tutup sesi lokal bagi actor/perangkat yang telah diotorisasi offline; local session UUID dipetakan saat import. Close lokal menghitung uang fisik dan membuat laporan lokal, sementara close konsolidasi menunggu sinkron/review; jangan memindahkan transaksi ke sesi baru secara diam-diam.
- [ ] Uji pemadaman mendadak, APK belum siap, dua device terputus berbeda, serta kembali ke web hanya setelah receipt/checkpoint terverifikasi. Uji O07–O08/O11–O12/O15.

Selesai bila H01–H07 lulus. Jangan memberi seluruh kasir akses halaman inventory hanya agar checkpoint bisa dilewati.

### APK-08 — Pesanan masuk, reservasi, DP dan progress produksi

File: `incoming_orders_screen.dart`, API client, model; Finance `Pos_mobile.php`, `Pos_reservation_model.php`, `Pos_model.php` (self-order/online-food), `Pos_order_monitor_model.php`, shared POS services.

- [ ] Terima/tolak self-order/online-food dengan alasan, scope outlet, status final dan hasil stock queue. Refresh/badge tidak mengirim notifikasi atau konfirmasi dua kali.
- [ ] Race web/APK verify/reject dilindungi server; UI menampilkan “sudah diproses” beserta hasil sah, bukan tombol retry yang membuat transaksi baru.
- [ ] Tambah wrapper API dan UI reservasi create/edit, katalog/extra/member, menerima DP, cancel sesuai metode web. Reject + refund DP yang sudah ada dipertahankan dan diuji.
- [ ] Penerimaan/void DP memakai model, RBAC, metode rekening, step-up dan idempotensi yang sama; tidak menjadi cash-in buatan APK.
- [ ] Progress dapur/bar/checker memakai status server. Operasi ack/ready/checker hanya untuk role dan entitlement yang sah; worker stok tidak dijalankan Android.
- [ ] Menu kanal di luar lisensi tetap memberi info upgrade sesuai RBAC; endpoint tetap menolak. Mode offline hanya melihat cache berlabel, bukan terima/tolak lokal seolah server sudah setuju.

Selesai bila I01–I08 lulus. Modul reservasi belum disebut lengkap hanya karena inbox-nya ada.

### APK-09 — Cetak benar dan bisa dipulihkan

File: `printer_settings_screen.dart`, `printer_service.dart`, `pos_print_dispatcher.dart`, `local_database.dart`, `android/app/src/main/kotlin/com/example/pos_cashier_apk/MainActivity.kt`; Finance `Pos_print_model.php`, print-target wrappers.

- [ ] Ukuran kertas/jumlah karakter/binding Bluetooth tetap lokal per printer. Server menentukan dokumen, routing/divisi, logo, template dan izin.
- [ ] Queue durable per document revision + target + copy, bukan hanya order. Pisahkan confirm awal, append tambahan, payment, void/refund, reprint, shift-close.
- [ ] Printer kedua gagal: retry target itu saja. Socket timeout/connection lost menghasilkan status jujur “belum dapat dipastikan”, bukan otomatis mengulang semua tiket.
- [ ] Gunakan satu pipeline layout untuk preview dan bytes cetak; uji font, lebar, kolom angka, logo transparan/putih, QR, barcode, multiline dan nama panjang.
- [ ] Routing Bluetooth vs agent/LAN diperiksa eksplisit. Tambah adapter transport hanya yang benar-benar didukung server/perangkat; jangan mengirim target agent ke Bluetooth secara diam-diam.
- [ ] Tangani izin Bluetooth ditolak, Bluetooth mati, printer tidak paired, MAC salah, printer paper-out, rotasi, app background; serialize job per printer.
- [ ] Cetak offline **wajib** untuk penjualan selesai: renderer lokal memakai template/logo/routing tersimpan, nomor unik instalasi+sequence, nominal dan status lunas sebenarnya, serta label “Transaksi offline — belum tersinkron”. Nomor bukti lokal disimpan sebagai alias permanen ketika ID pusat terbit; bukan dipalsukan sebagai nomor pusat. Tidak memerlukan fetch print-target saat server mati. Uji O01/O13.

Selesai bila T01–T10 lulus pada printer fisik 58/80 mm. Perbaikan komposit logo sudah ada; ukur hasil perangkat sebelum mengutak-atik threshold/raster kembali.

### APK-10 — Laporan, kelengkapan operasi kasir, dan UI terpadu

File: `cashier_screen.dart`, `order_workspace_screen.dart`, `incoming_orders_screen.dart`, `setup_screen.dart`, `app.dart`; layar laporan/settings baru dibuat bertahap. Finance: `Pos.php::report_*`, `Pos_report_model.php`, `Pos_print_model.php`, wrapper mobile/routes/feature mapping.

- [ ] Laporan penjualan, rincian order/payment, daily sales, metode/rekening, refund/void dan tutup kasir: API read-only scoped, pagination, tanggal dan total server, PDF/download sesuai izin.
- [ ] Tambahkan laporan lokal penjualan/pembayaran/kas/pergerakan stok/jurnal POS dan shift offline. Bedakan lingkup perangkat vs seluruh outlet, lunas vs status upload/posting, dan rebase snapshot berdasarkan watermark agar angka tidak berkurang dua kali sesudah sync.
- [ ] Urutan sales mengikuti jam order terbaru sebagaimana aturan web yang berlaku; filter tanggal dan basis agregat harus identik dengan laporan web, bukan dijumlah dari halaman pertama.
- [ ] Pengiriman daily sales/PDF WA/Telegram meminta Finance memakai pengaturan yang sudah ada. Tidak membawa credential messaging ke APK, dan tidak otomatis mengirim ulang saat refresh.
- [ ] Operasi kasir master minimum (member, pilihan rekening/metode, outlet/terminal) tersedia. Pengelolaan data itu hanya bagi admin berizin melalui wrapper resmi; jangan membolehkan payload mengganti outlet bearer.
- [ ] Admin printer dapat melihat/mengatur routing/template server melalui API yang direview; kasir biasa hanya setting hardware lokal. Pengaturan self-order/table/online location dapat diletakkan di bagian admin, bukan mengganggu cart.
- [ ] Buat coverage list semua aksi yang tampil di POS web pada cutoff. Aksi yang memang belum ada di web, misalnya split/merge order, bukan kewajiban diam-diam batch ini; usulkan terpisah.
- [ ] UI operasional: navigasi **Kasir / Pesanan / Order masuk / Ringkasan / Lainnya**. Tablet dua panel katalog-cart, ponsel cart ringkas dengan bottom sheet; state transaksi tidak hilang saat rotasi.
- [ ] Satu panel **Status & Pemulihan**: koneksi, user/outlet/sesi, lisensi, umur master, jumlah pending/blocked/unknown, printer bermasalah, tombol periksa hasil. “Offline”, “perlu login”, “upgrade paket” dan “stok ditolak server” bukan pesan yang sama.
- [ ] Mode kosong/loading/error, keyboard angka, uang Rupiah, teks besar, warna dan ikon konsisten. Jangan menutupi masalah stok/sync dengan snackbar singkat yang hilang.

Selesai bila L01–L07 dan U01–U06 lulus. Tidak menggunakan WebView halaman desktop sebagai bukti otomatis bahwa fitur sudah setara mobile; jika ada deep link sementara, tandai gap dan jangan mengirim token lewat URL.

### APK-11 — Lisensi per instalasi APK yang benar-benar terintegrasi

Detail wajib: [kontrak](2026-09-24_kontrak_apk_finance_control.md). File APK baru untuk license state/verifier/device identity; Finance controller/service khusus pairing/recovery, Feature_policy/gate, manifest dan distribusi; Control dikerjakan oleh thread Control.

- [ ] Control menyetujui metric, cakupan seat, add-on per edition, lease/grace, penggantian perangkat dan trust key. Tidak menyamakan `LIMIT_POS_TERMINALS` dengan lisensi APK.
- [ ] Pairing user-friendly URL + kode/QR singkat berizin, challenge/PoP, instalasi unik dan kuota atomik. Update APK tidak mengambil seat baru; uninstall/kehilangan key perlu recovery sah.
- [ ] Finance memverifikasi lisensi perangkat bersama lisensi server, entitlement, RBAC dan scope; admin customer tidak bypass. Tidak memakai API key generik sebagai hak perangkat.
- [ ] Android memverifikasi signed lease offline serta actor grant yang disetujui; perangkat/account belum pernah diotorisasi tidak membuka bisnis offline.
- [ ] Grant offline mencakup policy/ruleset/custody/resource budget dan window operasional yang jelas; hilangnya koneksi Finance/Control saja tidak membekukan perangkat yang masih berizin. Event lama diunggah lewat intake recovery berotorisasi dan diaudit meski perlu review setelah expiry, bukan dibuang atau dijadikan izin penjualan baru tanpa batas.
- [ ] Renewal, revoke, downgrade, ganti perangkat, perubahan domain, clock rollback dan backup-clone diuji. Antrean/bukti lama tidak dihapus saat lisensi ditolak.
- [ ] Status API, fitur dasar, hasil transaksi lama dan kanal pemulihan didefinisikan secara sempit agar lisensi bermasalah tidak menjadi bypass writer, atau menghilangkan bukti transaksi.
- [ ] Test integrasi Control nyata terisolasi dicatat terpisah dari mock. Perubahan manifest/allowlist/migrasi/profil Finance melalui build baru; tidak mengedit paket signed yang sudah diterbitkan.

Selesai bila K01–K12 lulus dengan Control terisolasi yang benar-benar menerbitkan dan memverifikasi dokumen; “signature fixture valid” saja belum cukup untuk komersialisasi.

### APK-12 — Hardening, update dan pilot

- [ ] Semua regresi di UAT lulus atau blokir rilis; tidak memindahkan kegagalan keamanan/uang ke daftar “nanti”. Flutter analyze/test/debug/release tersedia bukti dari cutoff yang sama.
- [ ] Uji upgrade in-place dari `1.1.0+2` dengan outbox/pembayaran/printer/profil lama. Tidak uninstall/clear data, tidak mengganti applicationId/cert/key instalasi, tidak mengonsumsi seat baru.
- [ ] Putuskan minimum Android/SDK berdasarkan plugin dan perangkat yang benar-benar diuji; catat RAM, printer dan batas background. Pin toolchain build yang berhasil, bukan upgrade semua dependency sekaligus.
- [ ] Audit release tidak membawa URL customer default, akun demo, token, private key, fixture data, signing secrets atau debug bypass. Android backup tidak boleh menyalin credential/identity ke device kedua.
- [ ] APK signed + SHA256 + versionCode meningkat + backend min/max contract + policy perangkat diserahkan ke Control. Jangan mengasumsikan endpoint distribusi APK sudah ada; gunakan kontrak rilis yang disepakati.
- [ ] Pilot satu outlet disposable/khusus uji: web + dua APK, shift penuh, jaringan putus/nyala, app mati, pergantian hari, queue stock/print dan laporan akhir.
- [ ] Seluruh O01–O16 wajib lulus untuk kedua skenario pengguna: kasir sejak awal APK dan cutover dari web sebelum server padam. Tidak boleh memberi label siap offline bila payment/stock/cash/struk hanya bekerja online.
- [ ] Runbook customer singkat: hubungkan server → daftarkan perangkat → login → sinkron awal → buka/lanjut kasir → transaksi → pemulihan → tutup kasir → pembaruan.

Selesai bila Z01–Z06 lulus. Jika downgrade aplikasi tidak kompatibel schema lokal, gunakan forward-fix yang teruji; jangan menjanjikan rollback dengan menghapus SQLite.

## 7. Aturan pengerjaan supaya tidak melebar

- Satu batch dipecah menjadi patch kecil berurutan: test reproduksi → implementasi → test otomatis → UAT → checklist/log. Jangan mengganti seluruh `cashier_screen.dart` sekaligus.
- File sasaran di atas titik awal, bukan izin mengubah perhitungan bisnis. Perubahan service Finance harus mempunyai regresi web dan mobile.
- Hanya baca ulang diff terhadap baseline dan method yang relevan; lakukan audit luas lagi jika kontrak/source benar-benar bergeser.
- SQL Finance baru harus migration terdaftar dan checksum; uji disposable. SQLite migration milik APK tidak dijalankan ke database Finance. Jangan menjalankan ulang folder SQL manual.
- Endpoint usulan jangan dipanggil produksi sebelum server menyatakan capability tersedia. Stub test tidak boleh ikut membolehkan transaksi pada release.
- Pekerjaan Control, data produksi, credential, lisensi, deploy dan publish memerlukan otorisasi tersendiri. Jangan menutupi gap dengan memberikan paket Enterprise pada semua customer.
- Paket yang memiliki POS + hak APK harus memiliki kebutuhan dasar POS; layar modul tambahan tetap ber-RBAC dan berlisensi. Fitur tidak dibeli diberi label upgrade, bukan error login palsu.

## 8. Catatan kemajuan bergulir

Perbarui tabel batch dan bagian ini setiap selesai patch. Jangan membuat dokumen progres baru setiap hari kecuali ada kontrak terpisah yang memang dibutuhkan.

| Tanggal / batch | Hasil | Validasi / keterbatasan | Lanjutan |
|---|---|---|---|
| 2026-09-24 / audit | Source APK + 4 dokumen non-note ditinjau; POS Finance dan Control dipetakan; 3 panduan aktif disiapkan | 45/45 path client cocok dengan 46 route server; 15 smoke mobile lulus; gate fitur global gagal; Flutter/Android/DB/Control live tidak diuji | APK-01 lokal; paralel review kontrak perangkat oleh Control |
| 2026-09-25 / koreksi kebutuhan offline | Target diperluas/diperjelas menjadi penjualan selesai offline, stock/cash/jurnal POS lokal, handover web–APK dan import tanpa duplikasi; batas online-only rencana sebelumnya dicabut untuk transaksi kasir yang dapat diotorisasi offline | Revisi dokumen saja; O01–O16 baru belum diuji, kode tidak berubah | Kontrak M10/M11 dan foundation ledger/cutover masuk APK-01/03; lanjut payment offline APK-05 |

Template entri berikutnya: `tanggal, batch/subbatch, commit APK/Finance, file berubah, perilaku sebelum/sesudah, migrasi (tidak ada/belum diuji/lulus disposable), test aktual, bukti UAT, risiko sisa, batch berikut`. Tandai selesai hanya berdasarkan bukti, bukan panjangnya diff.
