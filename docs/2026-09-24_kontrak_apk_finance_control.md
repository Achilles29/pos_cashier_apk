# Kontrak kerja APK–Finance–Control

Audit 24 September 2026; revisi kebutuhan offline operasional 25 September 2026. Pendamping [rolling plan aktif](2026-09-24_rolling_plan_apk_finance_control.md). **Bagian berlabel USULAN/target belum merupakan API, entitlement, atau layanan yang tersedia.** Tidak ada source/database Control yang diubah untuk dokumen ini.

## 1. Sumber kebenaran

| Pemilik | Tanggung jawab | Bukan tanggung jawab |
|---|---|---|
| Control | Subscription, hak fitur bertanda tangan, aktivasi server, kuota, status komersial; kelak registry perangkat APK setelah disetujui | Password kasir/database, saldo order, stok, data pelanggan usaha |
| Finance | User/RBAC/scope, outlet/terminal/sesi, master dan seluruh transaksi, validasi license server/perangkat, proyeksi kasir, dokumen cetak | Menentukan sendiri entitlement atau menerbitkan lisensi pengganti Control |
| APK | Identitas Android, secure token, snapshot berversi, transaksi kasir/stock/cash/jurnal POS lokal, outbox dan printer offline | Menimpa saldo pusat, menerbitkan entitlement sendiri, menganggap snapshot mencakup perubahan perangkat lain yang belum diterima |

Urutan keputusan pada operasi bisnis customer: **trust & license server sah → fitur dibeli → izin perangkat APK sah (kontrak baru) → autentikasi user → RBAC/scope → binding sesi/order → aturan transaksi → commit**. Susunan implementasi dapat menyesuaikan lifecycle framework, tetapi writer dan data terbatas tidak boleh dijalankan sebelum seluruh syarat yang relevan lulus.

Pada mode offline, syarat itu diperiksa melalui grant/ruleset/scope yang sebelumnya diterbitkan sah, terikat perangkat dan masih berlaku; **bukan meminta server pada setiap transaksi**. Penyimpanan lokal merupakan pencatatan kejadian nyata. Finance kemudian mengonsolidasikan melalui import dan rekonsiliasi, bukan menganggap seluruh penjualan offline hanya draft yang boleh dibuang.

Kanal login/pairing/status pemulihan memerlukan pengecualian sempit dan data minimal; bukan bypass semua endpoint `pos-mobile`. Superadmin tidak boleh melewati lisensi. Master/development yang tidak dikelola customer tetap mengikuti kontrak development yang eksplisit, bukan customer otomatis menjadi legacy ketika file license hilang.

## 2. API yang ADA pada cutoff audit

Sumber: `finance/application/config/routes.php`, `application/controllers/Pos_mobile.php`, dan `pos_cashier_apk/lib/src/services/finance_api_client.dart`. Semua path di tabel relatif terhadap `/pos-mobile/`; `{id}` berarti route `(:num)`. GET/POST di bawah adalah pemakaian client saat ini; validasi verb server tetap harus diuji, tidak cukup melihat route CodeIgniter.

| Kelompok | Path / verb yang tersedia | Hak fitur tambahan selain POS_MOBILE_APK |
|---|---|---|
| Koneksi | GET `ping`; POST `auth/login`, `auth/logout` | — |
| Bootstrap/katalog | GET `bootstrap`, `catalog`, `members/search`, `products/extra-options` | Akses customer/member yang lebih lanjut tetap payload/RBAC policy |
| Printer | GET `printers`; POST `printers/test/{id}` | POS_PRINTER |
| Reservasi baca | GET `reservations`, `reservations/products`, `reservations/{id}` | RESERVATION |
| Reservasi aksi | POST `reservations/verify/{id}`, `reservations/reject-step-up/verify`, `reservations/reject/{id}` | RESERVATION |
| Self-order baca | GET `incoming/self-order`, `incoming/self-order/{id}` | SELF_ORDER |
| Self-order aksi | POST `incoming/self-order/verify/{id}`, `incoming/self-order/reject/{id}` | SELF_ORDER |
| Online-food baca | GET `incoming/online-food`, `incoming/online-food/{id}` | ONLINE_ORDER |
| Online-food aksi | POST `incoming/online-food/verify/{id}`, `incoming/online-food/reject/{id}` | ONLINE_ORDER |
| Order | GET `orders`, `orders/{id}`; POST `orders/confirm`, `orders/push` | — |
| Jalur draft tambahan | POST `orders/save` | Ada di server, **tidak dipanggil client sekarang** |
| Reversal | GET `orders/reversal-preview/{id}`; POST `orders/reversal-step-up/verify`, `orders/void/save`, `orders/refund/save` | Aturan embedded feature tetap berlaku |
| Cetak reversal/confirm | GET `orders/void/print-targets/{id}`, `orders/refund/print-targets/{id}`, `orders/confirm/print-targets/{id}` | POS_PRINTER |
| Cetak ulang | POST `orders/reprint-step-up/verify`, `orders/reprint-targets/{id}` | POS_PRINTER |
| Pembayaran | GET `orders/payment/prepare/{id}`; POST `orders/payment/save` | Embedded voucher/loyalty/DP tidak otomatis bebas lisensi |
| Voucher | GET `orders/payment/voucher-search` | PROMOTION_VOUCHER |
| Struk payment | GET `orders/payment/print-targets/{id}` | POS_PRINTER |
| Sesi baca | GET `cashier/session-status`, `cashier/close-preview` | — |
| Sesi aksi | POST `cashier/open`, `cashier/close-step-up/verify`, `cashier/close` | — |

Hasil pencocokan statis: **46 route server, 45 pola path client, 45 cocok, 0 hilang**. Ini bukan hasil panggilan HTTP/DB atau bukti parameter/response sudah setara web.

Header client yang ada: `Authorization: Bearer ...`, alias `X-Pos-Mobile-Token`, `X-Pos-Mobile-Device-Key`, alias terminal `X-Pos-Terminal-Key`, dan `X-Pos-Mobile-Key` opsional untuk integrasi lama. Jangan memasukkan token ke query string. Jangan menjadikan API key lama sebagai pengganti token user/lisensi perangkat.

Temuan kontrak aktual:

- JSON sukses memakai `ok: true`; error `ok: false, message` dan field tambahan tertentu. Jangan mengasumsikan semua error sudah memiliki `code` yang seragam.
- Login/authorization memakai device key, active terminal unik, employee, division scope, dan RBAC. Ini **belum proof kepemilikan kunci instalasi Android**.
- `sensitive_action_contract.version = 3` menjelaskan step-up, bukan semua kapabilitas API atau versi lisensi.
- `bootstrap?since=...` belum delta lengkap: server mengembalikan subset katalog, cursor waktu, dan deleted kosong. Jangan melewati item ke-120/60 dengan asumsi data sudah habis.
- `orders` menerima page/limit tetapi tanggal server masih hari ini; client mengirim tanggal tidak membuat histori tanggal itu tersedia.
- Draft/order push dan payment punya event journal server. Kelanjutan event PROCESSING, kegagalan setelah draft tersimpan, serta payment attempt melewati restart belum terselesaikan hanya dengan keberadaan tabel tersebut.
- `orders/status` disebut rancangan lama, **tidak ada dalam route aktual**. Jangan memanggilnya sebagai fallback yang dianggap sudah didukung.

## 3. Matriks entitlement dan kebutuhan dasar

Sumber hak adalah dokumen bertanda tangan yang diverifikasi Finance, bukan string edition yang dikirim Android. `BOOLEAN` tidak boleh menerima angka batas sebagai hak fitur. Data capability untuk UI tidak boleh menjadi bukti license offline jika tidak dilindungi trust yang disepakati.

| Kegiatan APK | Hak produk | Kebutuhan dasar yang harus tetap tersedia | Yang tidak ikut terbuka |
|---|---|---|---|
| Login dan kasir bisnis | POS_MOBILE_APK + dependensi POS_WEB/BUSINESS_PROFILE/RBAC_CORE | Scope, katalog jual, UOM, harga/kanal, outlet, terminal, sesi | Seluruh pengelolaan master/global setting |
| Jual produk resep/extra/bundle | Hak kasir yang sah + aturan embedded feature | Resolver resep, HPP, stock commit internal, posting/reversal melalui service yang sama | Layar edit resep, lot audit, produksi, adjustment, payroll |
| Pilih metode/rekening | Hak kasir + RBAC transaksi | Metode aktif dan rekening yang boleh digunakan outlet | Edit saldo manual, jurnal umum dan rekonsiliasi finance lanjutan |
| Cetak | POS_PRINTER | Target/format/branding yang relevan + hardware lokal | Editor/routing admin bagi kasir tanpa izin edit |
| Member, voucher, DP | Hak kasir + CUSTOMER_LOYALTY/PROMOTION_VOUCHER/RESERVATION sesuai operasi nyata | Member search minimum dan data preview yang diizinkan | Memalsukan saldo poin, voucher atau DP lewat payload |
| Reservasi / kanal order | RESERVATION / SELF_ORDER / ONLINE_ORDER | Verifikasi dan stock job internal | Mengelola semua kanal/outlet lain tanpa scope |
| Laporan kasir | SALES_REPORTING + scope | Penjualan/payment/close yang sama sumbernya dengan web | Seluruh laporan Finance Advanced atau data outlet lain |
| Kirim WA/Telegram | Hak laporan/aksi + AUTOMATION_MESSAGING | Server memakai target/config terdaftar | Token/provider configuration di APK |
| Lisensi per perangkat | Hak APK + seat perangkat **USULAN** | Signed device grant, registry, PoP, recovery | Mengurangi/menambah max_instances server atau jumlah pengguna |

Manifest source saat audit memasukkan POS_MOBILE_APK pada **ENTERPRISE**, belum pada STARTER_POS/OPERATIONS/CONTROL. `LIMIT_POS_TERMINALS` menghitung terminal web **atau** APK; bukan registry aktivasi APK. Bila APK hendak dijual sebagai add-on Starter, Control harus menyetujui dan menerbitkan entitlement/add-on tersebut secara sah. Jangan mengubah edition di session/database untuk membuka aplikasi.

Pengujian Starter + APK dalam roadmap berarti fixture/paket **yang add-on-nya sudah disetujui**, bukan klaim bahwa Starter saat ini sudah mengandung APK. Baseline Starter murni harus tetap ditolak untuk bisnis APK, dengan penjelasan upgrade yang jelas.

## 4. Offline, konflik, dan pemulihan

### Koreksi kebutuhan 25/09: offline operasional, bukan hanya outbox draft

Bagian ini menggantikan target awal yang membatasi payment online-only. Source audit 24/09 **belum** memenuhi rancangan ini. Targetnya kasir tetap berjualan, menerima uang, mencetak bukti, mencatat persediaan/keuangan lokal, lalu menyinkronkan tanpa transaksi ganda. Implementasi wajib melibatkan Finance; perubahan layar Flutter saja tidak cukup.

| Aksi | Target offline yang harus diimplementasikan | Saat koneksi kembali |
|---|---|---|
| Katalog/harga/extra/bundle | Snapshot lengkap berversi, informasi freshness dan kalkulasi lokal teruji | Master baru berlaku untuk transaksi berikut; sale selesai tidak direprice diam-diam |
| Order baru/draft/append | Lokal dengan UUID/revision; append existing web order hanya jika custody offline sudah diberikan | Import urutan event dengan dedup/revision/receipt |
| Bayar tunai | Selesai lokal: payment, change, cash movement dan bukti penjualan tersimpan atomik | Impor hasil uang yang sudah terjadi, bukan menagih kasir/customer lagi |
| Noncash | Catat bukti manual/EDC yang memang tersedia sesuai kebijakan; status provider terpisah | Cocokkan settlement/reference provider; tidak otomatis dianggap settlement sukses |
| QRIS dinamis/gateway online | Tidak mengklaim verifikasi provider saat provider tidak dapat dijangkau; tawarkan metode yang tersedia | Callback/provider result direkonsiliasi, tidak ditagih kedua kali |
| Stok/material/component | Ledger konsumsi/return lokal dari BOM/UOM snapshot; stok proyeksi memperhitungkan seluruh event lokal | Server posting delta tepat sekali, alokasikan/validasi lot, audit selisih/HPP |
| Kas/rekap/jurnal POS lokal | Penjualan, payment, refund/DP yang diizinkan dan close dicatat lokal; proyeksi jurnal memakai mapping berversi | Finance mengonsolidasikan ke ledger/jurnal terpusat; tidak double post melalui dua jalur |
| Cetak tiket/struk/close | Wajib melalui renderer/template/logo tersimpan, nomor lokal unik dan label offline | Simpan alias nomor, tidak cetak ulang otomatis hanya karena receipt sync diterima |
| Voucher/DP/poin bersama | Pakai hanya hak/saldo yang sudah dialokasikan eksklusif; cache saldo biasa tidak cukup. Promo deterministik tanpa kuota bersama dapat mengikuti ruleset sah | Konsumsi alokasi dan validasi penggunaan tepat sekali; konflik masuk review |
| Void/refund lokal | Transaksi milik perangkat/custody yang diketahui + batas qty/cash dan offline approval yang sah | Import event kompensasi, bukan hapus histori atau ulang refund |
| Buka/tutup sesi | Actor/perangkat terdaftar dengan grant; session UUID lokal, cash count dan close lokal | Map session dan konsolidasi close; konflik shift/periode masuk review |
| Inbox/reservasi/shared order | Yang belum tersalin tidak tersedia; baca cache. Aksi bersama tetap online kecuali ada custody/grant offline khusus | Konfirmasi status lintas perangkat, tidak overwrite hasil web |
| Login user baru/aktivasi baru/ganti perangkat | Tidak boleh diterbitkan sendiri secara offline | Verifikasi server dan Control |
| Melanjutkan user yang sudah sah | USULAN actor grant + device lease terverifikasi; unlock lokal aman tanpa menyimpan password Finance | Perbarui izin; event historis tetap dapat ditelusuri walau perlu review |

Grace perangkat adalah nilai dari kebijakan Control yang ditandatangani, **bukan angka 30+30 hari server yang disalin ke APK**. Hak pemasangan tanpa tenggat bukan lease offline tanpa batas. Tidak ada cara menjamin pencabutan diketahui perangkat yang sepenuhnya offline seketika; window offline harus dijelaskan sebagai keputusan risiko produk.

### 4.1 Alur A — sejak awal kasir memakai APK

1. Saat pertama terhubung, pairing/login, unduh snapshot lengkap, grant offline, identitas outlet/perangkat, sesi/float, aturan dan aset cetak. Tampilkan **Siap offline sampai …**, timestamp snapshot dan cakupan fitur. Perangkat baru yang belum disiapkan tidak bisa memperoleh data/izin dari server mati.
2. Setiap operasi ditulis ke database lokal terlebih dahulu: identitas order/payment, snapshot aturan, ledger dan outbox dalam satu commit. UI/cetak mengakui hasil hanya setelah commit durable. Kalau online, segera kirim dan ambil receipt; selesaikan ambiguitas tanpa membentuk event baru.
3. Server terputus: lanjutkan penjualan lokal dari ruleset sah, kurangi proyeksi stok, tambah kas, cetak struk. Tombol bukan “simpan draft menunggu bayar”. Status per transaksi: misalnya `LUNAS LOKAL / BELUM TERSINKRON`.
4. Server kembali: masuk mode **Menyinkronkan**, bukan langsung menganggap semua sudah sama. Recovery outcome request yang sebelumnya UNKNOWN, upload event berurutan, simpan ack per event, map ID, dan tarik perubahan yang belum diterima. Kasir dapat membuat order lokal baru sesuai grant sambil catch-up; high-water mark mencegah batch sinkron mengejar antrean tanpa akhir.
5. Setelah receipt/checkpoint dan rekonsiliasi lulus, tampilkan **Tersinkron** untuk cakupan watermark itu. Event yang perlu review tetap ditampilkan beserta alasan dan data aslinya.

### 4.2 Alur B — dari web pindah sebelum pemadaman

1. Operator membuka APK dengan user/outlet yang sama, lalu **Siapkan / Lanjutkan Kasir di APK**. Tidak perlu menutup sesi kasir web atau membuat shift kedua.
2. Server membentuk handover checkpoint: session ID/owner/origin, opening dan payment/cash summary, order belum selesai beserta line/payment/revision, hasil transaksi terakhir yang berpotensi ambigu, aturan harga/resep/stock, nomor/version watermark dan template/logo cetak. Snapshot paginasi harus konsisten; perubahan web selama transfer masuk catch-up.
3. APK mempersist snapshot lengkap dan mengirim acknowledgement. Server memvalidasi revision/checkpoint terkini lalu menerbitkan custody epoch/grant untuk ruang lingkup order/sesi yang dipindah. APK memastikan grant tersimpan sebelum menyatakan **Siap offline**. Handover request/ack/status harus idempoten agar response terputus tidak memberikan dua owner.
4. Server menolak writer web/perangkat lain pada aggregate yang sudah diberikan eksklusif, termasuk sesudah koneksi putus. Tidak cukup hanya memberi pesan “mode backup” di UI. Default saat handover terencana: satu penulis untuk sesi/order tersebut; sesi lain mengikuti kebijakan stok bersama.
5. Server mati, APK melanjutkan order yang sudah dipindahkan, menerima cash baru, mencatat ledger dan mencetak. Order web yang sudah paid pada checkpoint tidak boleh diminta bayar lagi.
6. Sesudah server pulih, upload dan reconcile dulu; **Kembali ke web** memakai handback checkpoint dan pengakhiran custody secara eksplisit. Server tidak mencabut custody hanya karena sebuah ping berhasil, dan tidak menerima writer lama dengan epoch basi. Data tidak dipindahkan dengan copy/overwrite database.

Pemadaman mendadak tanpa handover: APK cadangan yang sudah tersinkron dan diberi izin dapat menjual order baru dalam namespace/grant-nya. Existing order web yang belum mempunyai custody tidak boleh dibayar ulang hanya bermodal cache lama. Sediakan informasi terakhir tersinkron dan pemulihan/otorisasi khusus, bukan janji bahwa semua perubahan web yang tidak sempat terkirim pasti tersedia.

### 4.3 Penyimpanan, state dan aturan bisnis

- Pisahkan **business state** (draft/confirmed/paid/refunded/closed lokal), **delivery state** (pending/sending/unknown/received), dan **posting state pusat** (applied/needs-review). Received ke inbox server belum berarti seluruh stock/financial posting selesai.
- Order-line price/BOM snapshot, payment/change, stock delta, cash delta, proyeksi journal POS, actor/device/session, sequence, aturan/grant, serta outbox harus konsisten dan dapat dipulihkan. Journal POS lokal bukan modul jurnal umum offline dan tidak memberikan izin mengubah saldo/master rekening.
- Simpan jumlah uang/qty dengan presisi yang sesuai kontrak, aturan rounding/version dan fixture parity PHP–Dart. Jangan membuat kalkulator kedua yang berbeda diam-diam. Penjualan yang belum selesai boleh revalidate; sale yang telah menerima uang mempertahankan snapshot transaksi dan riwayat koreksinya.
- Import server mengonversi event bisnis ke service Finance yang sama. Client tidak mengirim saldo absolut untuk ditimpa atau SQL/jurnal arbitrer. Referensi event yang sama mengikat order, payment, kas, stok dan journal agar import ledger tidak menggandakan posting dari model bisnis.
- Stok APK = snapshot pada watermark + movement lokal yang belum tercakup snapshot itu. Setelah movement diakui server, hilangkan overlay hanya saat snapshot/watermark baru benar-benar mencakupnya; jangan kurangi dua kali atau melonjak sementara.
- Material/component/BOM menghasilkan proyeksi pemakaian lokal. Mapping lot/FIFO/HPP pusat tetap perlu validasi karena perangkat lain dapat mengonsumsi lot yang sama; simpan cost estimate vs finalized cost dan jejak koreksi, tidak memalsukan lot yang sudah habis.
- Transaksi tunai yang sudah terjadi tetapi tidak dapat diposting otomatis harus masuk review durable beserta bukti uang/struk, bukan dibuang sebagai HTTP 422 lalu hilang dari rekap. Aturan mapping/shift/periode berubah tidak membenarkan rerun payment atau backdate posting otomatis.
- Printer memanfaatkan artefak cetak tersimpan; nomor lokal unik installation ID + sequence/collision-safe ID. Alias itu tetap dapat dicari setelah server memberi nomor pusat. Payment berhasil tidak bergantung pada printer berhasil.
- Data di satu perangkat belum memiliki cadangan server sampai terkirim. Device rusak/hilang sebelum sync adalah risiko kehilangan data; sediakan health/storage warning dan rancangan backup terenkripsi yang tidak menyalin key aktivasi, tanpa menjanjikan durability yang tidak ada.

### 4.4 Beberapa kasir/perangkat saat terputus

Default awal: tetapkan perangkat backup offline yang berizin per outlet; order baru selalu punya identitas unik, sedangkan mutasi order bersama wajib mempunyai custody. Handover terencana memagari sesi/order yang dipindahkan. Operasi online web–APK biasa tetap diperbolehkan melalui revision/idempotency server; pembatas custody hanya untuk ruang lingkup yang dialihkan offline.

Stok global tidak bisa dijamin selalu terkini ketika dua perangkat tidak dapat berkomunikasi. Untuk stok ketat, alokasikan jatah stock/resource per device dan kurangi availability yang dapat dipakai writer lain di server. Jika bisnis memilih tetap menjual melebihi alokasi/berdasarkan snapshot, itu **kebijakan risiko eksplisit** dengan warning dan review setelah sync, bukan jaminan nol overselling. Jangan membuka oversell secara default untuk membuat demo lancar.

DP/poin/voucher single-use membutuhkan reservation/alokasi eksklusif dan budget yang mengikat device. Pembebasan alokasi tidak boleh hanya berdasarkan server timeout jika device masih punya grant sah untuk membelanjakannya; ikuti expiry/custody/ack yang disepakati. Dilarang membelanjakan cache saldo bersama di dua device secara bebas.

### 4.5 Otorisasi offline dan pemulihan lisensi

Offline bukan tanpa izin: device lease + actor grant + offline capability/resource budget/custody harus terverifikasi dan mencakup tindakan serta window yang cukup untuk operasi. Readiness harus memperingatkan expiry sebelum pemadaman; network failure saja tidak mengunci cash sale selama izin masih berlaku. Local unlock/approval tidak menyimpan password server atau memperpanjang proof step-up online sendiri.

Saat grant berakhir atau revoked telah diketahui, jangan menerbitkan operasi baru tanpa izin. Namun event historis tidak dihapus: jalur intake recovery mengautentikasi perangkat, memeriksa signature/sequence/checkpoint dan menampung bukti tanpa otomatis memberi hak writer baru. Bukti waktu lokal saja tidak membuktikan semua event terjadi sebelum expiry; kasus tidak pasti masuk review dengan jejak audit. Jangan mengubah masa hak license/maintenance Control.

### Kontrak transaksi usulan (APK-03; belum diimplementasikan)

Pertahankan `local_uuid` dan `client_event_id` existing; tambahkan versi kontrak secara backward-compatible setelah review server. Makna minimum:

| Field | Makna dan aturan |
|---|---|
| instance / device installation | Berasal dari binding terverifikasi, bukan dipercaya hanya karena ada di body |
| actor / outlet / session / origin terminal | Dibekukan saat intent dibuat; server menguji konteks, tidak memberi client kewenangan baru |
| local_uuid | Identitas aggregate order lokal yang sama sepanjang save/restore/append |
| client_event_id | UUID unik satu intent; dipakai ulang hanya untuk **payload identik** |
| sequence / predecessor / base revision | Menjaga urutan perubahan dan optimistic conflict dengan web/Android lain |
| payload hash | Canonicalization disepakati dan recompute server; metadata volatile/auth/step-up tidak dicampur tanpa aturan |
| status + result identity | PROCESSING/ACCEPTED/REJECTED beserta ID order/payment/reversal dan revisi sah |
| replacement event reference | Koreksi intent yang sudah ditolak final; tidak menghapus event lama atau menyamar sebagai retry |
| occurred_at / received_at / device sequence | Pisahkan waktu kejadian lokal dari penerimaan server; sequence/checkpoint lebih kuat dari percaya jam perangkat saja |
| policy / price / BOM version + grant / custody epoch | Bukti aturan dan ruang lingkup offline yang dipakai; diverifikasi server, bukan dipercaya dari label client |
| local payment / movement / receipt identifiers | Relasi transaksi uang/stok/kas/bukti yang sudah terjadi; bukan perintah menjalankan pembayaran kedua |

Kunci unik server harus punya scope yang tepat dan dilindungi constraint/transaksi. Lookup hanya boleh mengembalikan event milik konteks sah, termasuk pada replay. Jangan menaruh token, password, proof step-up atau data kartu di persisted payload/log. Refresh proof tidak boleh berubah menjadi transaksi bisnis kedua.

Urutan pemulihan:

1. Persist intent sebelum HTTP. Worker mengklaim event atomik dengan lease lokal.
2. Server autentikasi, otorisasi, cek idempotensi/payload dan revisi, kemudian jalankan service bisnis.
3. Simpan kaitan hasil bisnis dan journal dengan jaminan transaksi/recovery yang terbukti. Crash antara draft/confirm/payment/result diperiksa per tahap.
4. Bila response hilang: APK menyimpan UNKNOWN, periksa hasil event yang sama. Jangan hapus draft lokal, membuat UUID baru, atau otomatis mengirim payment kedua.
5. PROCESSING lama hanya dipulihkan berdasarkan bukti server. Penolakan final dapat dikoreksi lewat alur eksplisit dan event pengganti; kejadian ambigu bukan penolakan final.
6. Event berikut pada order itu menunggu predecessor selesai. Order lain tetap dapat sinkron. Untuk sale/payment yang sudah selesai offline, “ditolak posting” tidak menghapus kejadian bisnis: intake dan review mempertahankan bukti, koreksi memakai event kompensasi.

### Tambahan API Finance yang diperlukan — seluruhnya USULAN

Nama path final belum disepakati; jangan hardcode path baru sampai route dan contract test backend ada.

| ID kontrak | Kebutuhan | Pemilik / batch |
|---|---|---|
| M01 capabilities | API version/range, server identity terverifikasi, feature decisions dan reason, revision; respons minimal aman sebelum login, detail setelah berizin | Finance + APK-01/02 |
| M02 sync recovery | Query hasil event/aggregate, recover server PROCESSING, konflik revisi, receipt payload hash, expired predecessor | Finance + APK-03 |
| M03 master snapshot | Produk/bundle/extra/method/kanal/printer scoped, pagination, completeness, revision/tombstone; upload-free read contract | Finance + APK-04 |
| M04 history/report | Order lintas tanggal, sales/detail/daily/payment/refund/void/close/PDF, scope dan export permissions | Finance + APK-04/10 |
| M05 reservation/deposit | Create/edit/cancel/DP dan member minimal, reuse shared business services, idempotensi dan step-up | Finance + APK-05/08 |
| M06 session/monitor | Checkpoint recon read-only, status job/order dan ack/ready/checker berizin; tidak expose worker global | Finance + APK-07/08 |
| M07 print receipt | Dokumen/revisi/target/copy identifier, ack attempt, partial failure; print-unknown berbeda dari financial-unknown | Finance + APK-09 |
| M08 admin/notify | Operasi master kasir/admin printer/kanal minimum, request kirim laporan terkonfigurasi | Finance + APK-10 |
| M09 device license | Pair/claim/renew/status/revoke/recovery serta trust binding ke Control baru | Finance + Control + APK-11 |
| M10 offline package/custody | Ruleset dan snapshot lengkap konsisten, readiness, grant actor/resource budget, handover checkpoint/claim/status/handback dengan fencing dan idempotensi | Finance + Control policy + APK-01/03/07 |
| M11 offline business import | Durable intake sale/payment/movement/session/close, batch cursor, hasil import per event, mapping ID dan stock/cash/journal reconciliation; recovery ambigu/expired historical events | Finance + APK-03/05/06/07 |

### Pesan dan status UI

`FEATURE_UPGRADE_REQUIRED` sudah merupakan kontrak feature gate Finance. Kode lain pada tabel adalah target normalisasi yang harus dicek/ditambahkan, bukan klaim semua sudah ada.

| Kondisi | Perilaku yang harus dicapai |
|---|---|
| 401 token berakhir | Login ulang ke profil yang sama; jangan hapus transaksi tertunda atau membocorkan apakah username valid |
| 403 RBAC | “Akun belum diberi izin”; jangan menyuruh membeli paket jika paket sudah mencakup fitur |
| 403 FEATURE_UPGRADE_REQUIRED | “Fitur memerlukan upgrade”; link informasi customer/penjual, bukan halaman admin Control |
| 409 konflik/shift/recon | Tampilkan tindakan spesifik dan detail aman; tidak dicap offline, tidak auto-rebind |
| License/device invalid/expired/revoked | Pesan lisensi/perangkat dan tombol periksa status; jangan mengirim writer atau menghapus bukti lama |
| 422 aturan bisnis | Tampilkan field/alasan yang aman; tidak retry otomatis sebagai kegagalan jaringan |
| 429 | Tunda sesuai retry policy; jangan tandai ditolak bisnis permanen |
| Timeout/5xx/non-JSON | Sanitasi; tandai hasil write belum pasti; baca status terlebih dahulu |
| Versi API tidak didukung | Panduan update resmi; jangan menyuruh upload dua file PHP secara manual |

## 5. Lisensi per APK: keadaan aktual dan keputusan yang dibutuhkan

### Yang sudah tersedia di Control

`License_activation_model` membatasi metric `SERVER_INSTANCE`; worker `license_issuance_worker.php` menerbitkan dokumen server yang terikat instance/installation/public key/fingerprint, edition/entitlement, policy dan masa lease. Kuota diambil dari max_instances subscription.

Route yang terlihat: `/api/v1/license-activations`, `/api/v1/license-activations/status`, `/api/v1/license-activations/recover`, `/api/v1/heartbeats`, `/api/v1/deployment-receipts`, `/api/v1/application-updates` dan claim install plan. Keberadaan route ini **bukan dukungan lisensi Android**. Jangan memakai aktivasi server untuk mendaftarkan setiap tablet dan menghabiskan slot server.

### Desain default untuk direview Control — belum disetujui/diimplementasikan

1. **Satu seat per instalasi Android aktif dalam subscription customer**, dibuktikan oleh pasangan ID instalasi dan kunci perangkat. Banyak akun kasir di device yang sama tidak mengambil seat tambahan. Binding ke server Finance yang diizinkan tetap dicatat; domain dapat berubah.
2. Kuota server tetap `max_instances`. Kuota terminal Finance tetap aturan terminal. Tambahkan kapasitas perangkat APK terpisah; calon nama `APK_DEVICE` / `LIMIT_APK_DEVICES` hanya nama usulan, bukan feature code aktif.
3. Add-on APK tidak otomatis mengaktifkan Self-order/Reservation/Inventory Advanced. Peta fitur tetap mengikuti dokumen server yang sah. Penjualan addon untuk edition selain Enterprise perlu konfigurasi Control yang direview.
4. Control menerbitkan signed device grant/lease terikat product, customer/subscription, device installation ID, public-key hash, server yang diizinkan, serial/revision, issued/not-before/expiry/grace dan policy. Jangan mengubah masa hak server/maintenance hanya demi APK.
5. Kunci penandatangan Control **tidak masuk APK/Finance**. APK menyimpan trust public keys yang distribusinya diverifikasi. Kunci privat unik Android dibuat di perangkat, tidak dibundel dan tidak diekspor melalui backup/log.
6. Algoritma signature envelope Control dan algoritma proof-of-possession Android boleh berbeda. Pilih implementasi Android Keystore yang benar-benar didukung minimum OS dan uji perangkat; jangan mengasumsikan field Ed25519 server activation otomatis cocok dengan key hardware Android.
7. Nonce/challenge berumur pendek dan sekali pakai; canonical request terikat method/path/body/instance/device/revision. Replay ditolak. Shared API key dan device label saja tidak cukup untuk aktivasi.
8. Update aplikasi mempertahankan installation identity/key/seat. Clear data/uninstall/kehilangan key adalah recovery/replacement resmi dengan bukti lama; jangan “ambil key lama” dari backup tanpa pemeriksaan anti-clone.
9. Kuota habis menolak perangkat tambahan secara atomik, tanpa mematikan perangkat sah. Revoke/retire/replacement diaudit. Normal logout tidak mengembalikan seat otomatis.
10. Multi-profile ke server berbeda milik customer yang sama tidak boleh otomatis menggabungkan database/antrean. Apakah satu seat dapat dipakai pada beberapa server berizin sekaligus harus disetujui Control; default usulan satu seat subscription dengan daftar binding server eksplisit, bukan semua server bebas.
11. Lease offline dan grant actor menentukan operasi apa yang masih boleh dilakukan. Penolakan/revoke yang sudah diketahui tidak dihapus dengan mengubah jam, preference atau mode airplane. Tidak menjanjikan software di perangkat customer mustahil dimodifikasi.
12. Hasil transaksi lama dan recovery tetap dapat diverifikasi melalui jalur sempit; rekonsiliasi intent offline sesudah lease/shift berakhir membutuhkan aturan eksplisit. Jangan secara otomatis mem-backdate otorisasi atau mengirim semua writer saat license terkunci.

### Alur customer yang dituju

`Pasang APK → isi/pindai alamat Finance → masuk/otorisasi pairing → pilih terminal yang diizinkan → Control memeriksa seat → Finance/APK memverifikasi izin → sinkron awal → mulai kasir`.

UI membedakan: alamat server, kode pairing sementara, device key terminal legacy, password pengguna, status paket, dan seat perangkat. Seller/customer admin menentukan paket di Control; kasir tidak memilih edition atau mengisi kunci server.

Tidak perlu menyimpan password Control/admin database di APK. Jika Finance menjadi perantara Control, gunakan agent server yang sudah beridentitas untuk kontrak baru yang disetujui; jangan meneruskan private key agent ke ponsel. Token pairing bukan izin tanpa batas dan tidak masuk URL/log yang dapat dibagikan.

### Handoff pekerjaan per repository

| Pemilik | Deliverable sebelum integrasi dinyatakan lulus |
|---|---|
| Control | Metric/seat/add-on disetujui; schema registry perangkat; API request/claim/status/renew/revoke/replacement terdefinisi; quota concurrency; signed grants + public trust rotation; UI admin customer; dokumentasi error/version/rate-limit; sandbox bukan produksi |
| Finance | Adapter Control baru, registry perangkat, mobile guard, capabilities/pairing, snapshot offline berversi, custody/checkpoint/resource allocation, import/reconcile ledger bisnis, migrasi terdaftar dan integrity/test; lisensi server tetap utuh |
| APK | Keystore identity, secure auth/grant verifier, database transaksi/stock/cash/jurnal POS lokal atomik, ruleset/renderer cetak offline, readiness/handover dan sync/recovery; update tanpa mengganti identity |
| Bersama | Contract fixtures, server/device quota terpisah, replay/clone/revocation/clock tests, rollback key rotation, upgrade/downgrade fitur, integration UAT dengan Control nyata terisolasi |

Control harus memberikan method/path/schema/signature/error yang telah diimplementasikan sebelum adapter memakai jaringan sungguhan. Mock hanya dipakai untuk mengembangkan client dan regression; laporan mock tidak boleh ditulis “sudah terhubung Control”.

## 6. Versi, migrasi dan rollout

- Audit ini tidak menaikkan versi APK/Finance/profil dan tidak membuat SQL baru. `1.1.0+2`, alpha.23 dan profil 11 hanyalah baseline source.
- Setiap batch implementasi mencatat compatibility matrix APK build ↔ mobile API contract ↔ device-license policy ↔ Finance customer profile. Pertahankan client lama hanya pada jalur yang masih aman; missing capability tidak membuka writer baru.
- Schema SQLite ditingkatkan tanpa menghapus profil/outbox. Schema Finance melalui katalog migration dan disposable DB; schema Control dikerjakan thread Control. Jangan memodifikasi checksum migrasi lama.
- File guard/adapter/route baru masuk manifest/allowlist/inventory/integrity Finance. Customer tidak diminta menyalin controller saja atau clean-install ulang untuk menambah dukungan APK.
- Urutan rollout: contract review → backend Finance/Control backward-compatible diuji → build APK signed diuji → pilot → distribusi yang disetujui. APK tidak membebaskan akses hanya karena backend belum siap.
- Update APK mempertahankan applicationId, signing cert dan identity lokal. VersionCode harus lebih besar dari build terdistribusi, bukan sekadar lebih besar dari angka di source audit.
- Domain Finance tidak mengunci lisensi. Perubahan domain dipulihkan menggunakan instance terverifikasi dan konfirmasi pengguna; jangan menyamakan domain baru dengan customer baru.
- Tidak menambahkan deadline pemasangan dari tanggal pembelian/build/registrasi. Izin sementara yang berakhir diperbarui lewat proses sah, bukan diabaikan; provisioning server existing tidak diulang untuk memasang APK.

## 7. Checklist persetujuan kontrak

- [ ] Control menyetujui definisi seat dan kebijakan beberapa server/profil.
- [ ] Control menyetujui addon APK per edition dan relasinya dengan limit terminal.
- [ ] Control menetapkan lease/grace/revocation/replacement dan data yang boleh dikirim.
- [ ] Algoritma, key storage, trust rotation, challenge/PoP dan anti-replay direview dan diuji perangkat nyata.
- [ ] Finance menerbitkan M01–M11 yang memang dibutuhkan dengan feature/RBAC/payload guard dan test; M10/M11 adalah prasyarat offline operasional, bukan endpoint yang sudah tersedia.
- [ ] Recovery payment/order/process interruption memiliki bukti, bukan sekadar response mock.
- [ ] Semua endpoint data/aksi baru mempunyai pemetaan fitur terpusat dan scope.
- [ ] Integration Control sebenarnya tersedia di lingkungan terisolasi; seluruh K01–K12 dijalankan.
- [ ] O01–O16 membuktikan kasir tunai tetap berjalan saat server mati, handover web→APK→web, stok/kas/jurnal tercatat dan terkonsolidasi tanpa duplikasi.

Sampai daftar ini lulus, klaim yang benar adalah **fondasi POS mobile sudah ada, lisensi per APK masih membutuhkan kontrak dan implementasi lintas repository**.
