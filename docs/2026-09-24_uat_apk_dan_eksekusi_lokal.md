# Eksekusi lokal dan checklist UAT APK POS

Pendamping [rolling plan aktif](2026-09-24_rolling_plan_apk_finance_control.md) dan [kontrak integrasi](2026-09-24_kontrak_apk_finance_control.md). Tanggal baseline 24 September 2026. Revisi 25/09 menambahkan **offline operasional** dan O01–O16; seluruhnya masih target pengujian, bukan hasil implementasi.

## 1. Cara memakai panduan ini

Mulai APK-01, bukan semua batch sekaligus. Setelah lulus, lanjutkan urutan di rolling plan. Checklist UAT di dokumen ini sengaja **belum dicentang**; audit source bukan uji operasional.

Prompt awal siap ditempel ke thread pengembangan lokal:

```text
Baca docs/2026-09-24_rolling_plan_apk_finance_control.md dan dua dokumen
pendampingnya. Kerjakan APK-01 saja, mulai dari status Git dan perbedaan
terhadap baseline yang dicatat. Jangan membaca docs/_note.
Ikuti revisi 25/09: targetnya penjualan selesai offline, pembayaran tunai,
struk, stock/cash/jurnal POS lokal dan handover web-APK, bukan draft-only.

Pahami source terbaru dan pertahankan perubahan saya. Jangan reset, clean,
clear data APK, mengganti applicationId, signing identity, atau credential.
Gunakan backend/database disposable dan data dummy; jangan menghubungi
customer/produksi atau mengubah Control.

Buktikan bug dengan test sebelum patch. Endpoint usulan belum tersedia;
jangan mengarang response produksi. Jika membutuhkan Finance, buat patch
terpisah di repo Finance yang memang tersedia/diizinkan atau catat kontrak
handoff yang spesifik. Jangan mematikan lisensi/RBAC untuk membuat test lolos.

Jalankan analyze/test/build debug yang relevan. Catat perintah, hasil aktual,
file/commit, keterbatasan, dan checklist di rolling plan. Jangan menandai
UAT fisik atau integrasi Control selesai hanya berdasarkan mock.
Berhenti setelah satu subbatch teruji; laporkan subbatch selanjutnya.
```

Prompt melanjutkan, cukup ganti nomor batch:

```text
Lanjutkan APK-03 dari rolling plan aktif 2026-09-24. Baca log batch terakhir,
git diff dan file sasaran; jangan scan ulang seluruh aplikasi jika baseline
tidak berubah. Selesaikan satu subbatch kecil beserta regression test,
update checklist/log, dan jelaskan bagian Finance/Control yang masih menunggu.
Jaga aturan tidak menyentuh data/credential produksi dan tidak menghapus
antrean, log percobaan, identitas atau perubahan pengguna.
```

Jika hanya repo APK tersedia lokal, pekerjaan backend bukan “selesai”. Gunakan contract fixtures untuk client, tulis kebutuhan Finance/Control dengan contoh request/response aman, dan tandai integration blocked sampai backend nyata siap.

## 2. Persiapan lingkungan uji

Siapkan satu backend Finance disposable dengan database kosong/fixture dan URL khusus uji. Jangan gunakan database development yang berisi transaksi asli sebagai fixture. Instal lewat jalur baseline/migrasi resmi Finance, bukan impor semua folder SQL.

Data uji minimum (nama baru, bukan salinan customer):

- Dua outlet, tiga terminal (web, Android A, Android B), kasir A/B, supervisor, role read-only, dan user dengan STAFF + role tugas yang scope-nya sah.
- Satu akun tanpa employee, satu user nonaktif, satu terminal nonaktif; sertakan scope ambigu untuk uji penolakan, jangan memaksa semua user hanya satu role.
- Lebih dari 120 produk dan 60 bundle; produk biasa, produk tanpa resep/event, produk bahan baku, component, bundle sama dengan variasi extra, wajib/min-max extra, produk nonaktif dan availability UNKNOWN.
- Fixture lot/stock/defisit dan resep yang terukur; harga kanal berbeda; member, voucher sah/kedaluwarsa/terpakai, DP lebih kecil/sama/lebih besar tagihan.
- Metode cash dan noncash/rekening, printer cashier/bar/kitchen, logo transparan dan logo tanpa alpha, panjang nama melebihi satu baris.
- Sesi/order melintasi tengah malam, refund sebagian, reservasi dengan/tanpa DP, self-order/online-food belum diverifikasi, runtime job tertunda/gagal.
- Snapshot harga/BOM/aturan/mapping jurnal berversi, saldo lokal dan watermark, grant offline/custody/resource budget, skenario server benar-benar dimatikan pada instance disposable, bukan hanya mock HTTP timeout.
- Customer-policy fixtures: Starter tanpa APK; Starter dengan addon APK **setelah kontraknya disetujui**; paket lengkap; role tidak berizin; revoked/expired/bad-signature/device-kuota-habis. Gunakan test signing identity, tidak menyalin key produksi.

Perangkat: emulator untuk UI dasar, tablet Android dan ponsel nyata untuk lifecycle/Keystore/Bluetooth; minimal dua perangkat untuk concurrency dan clone/replacement. Printer fisik 58 mm dan 80 mm diperlukan. Profil Android tertua/terbaru yang didukung ditetapkan setelah build baseline, tidak ditebak dari folder generated Windows/iOS.

Gangguan yang wajib dapat dibuat: timeout setelah server commit, disconnect sebelum response, process-kill Android, rotasi/background, disk penuh, clock berubah, dua request bersamaan, printer kedua offline. Pembanding transaksi berasal dari API/read-only query **database disposable**, bukan hitungan cache APK.

## 3. Perintah baseline lokal

Jalankan dari root `pos_cashier_apk` pada komputer pengembangan. Perintah ini belum dijalankan dalam audit server karena Flutter/Dart tidak tersedia.

```text
git status --short
git rev-parse HEAD
flutter --version
dart --version
java -version
flutter doctor -v
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Simpan output yang disanitasi. `pub get` dapat mengubah lockfile/generated file; review diff, jangan melakukan upgrade dependency massal sebagai bagian bugfix. Buat test baru per batch lalu jalankan suite-nya dan suite penuh. Setelah `integration_test` ditambahkan dan terdaftar pada APK-01, jalankan `flutter test integration_test -d <ID-perangkat-uji>`; folder ini belum ada pada baseline audit.

Build release hanya pada APK-12, memakai signing key privat yang benar. Jangan menempelkan password key di command/chat. Pertahankan `com.namuaprojects.finance.pos` dan sertifikat update. Bila wrapper Gradle kurang, pulihkan di salinan kerja atau generate template sementara lalu review diff; jangan menjalankan `flutter create .` secara buta di atas Kotlin/manifest custom.

Toolchain yang terlihat pada source: Dart `^3.7.2`, lockfile Flutter `>=3.29.0`, Gradle 8.10.2, AGP 8.7.0, Kotlin plugin 1.8.22, Java/Kotlin bytecode target 11, NDK 27.0.12077973. **Target bytecode bukan versi JDK runtime build.** Catat kombinasi Flutter/JDK/SDK yang benar-benar lolos; pin sesudah terbukti. Jangan menyatakan build berhasil hanya karena versinya memenuhi minimum.

### Smoke Finance tanpa database

Hanya dari repo Finance dengan source test yang sudah direview; nama binary PHP menyesuaikan komputer lokal. Ini tidak menjalankan aplikasi aktif atau SQL.

Bash:

```bash
for test_file in tools/tests/pos_mobile*smoke.php; do
  php "$test_file" || exit 1
done
php tools/tests/feature_boundary_contract_smoke.php
```

PowerShell:

```powershell
Get-ChildItem tools/tests/pos_mobile*smoke.php | ForEach-Object {
  php $_.FullName
  if ($LASTEXITCODE -ne 0) { throw "Smoke gagal: $($_.Name)" }
}
php tools/tests/feature_boundary_contract_smoke.php
if ($LASTEXITCODE -ne 0) { throw 'Feature boundary belum lulus' }
```

Jika Finance ikut diubah: lint PHP berubah, cek katalog/checksum migrasi bila ada SQL, regression shared service web/mobile, lalu DB integration disposable. Jangan menjalankan test HTTP/DB terhadap URL atau konfigurasi default produksi.

## 4. Checklist UAT dengan hasil yang harus terlihat

Format bukti setiap item: build APK/commit Finance, fixture, langkah, expected, actual, PASS/FAIL/BLOCKED, referensi test/screenshot tersanitasi. `[ ]` tidak berarti kodenya tidak ada; berarti hasil ini belum dibuktikan pada cutoff baru.

### A — Koneksi, akun dan identitas (APK-01/02)

- [ ] A01 Fresh install membuka setup berbahasa Indonesia; URL, device binding dan login dijelaskan berbeda dari license; tidak ada default akun/domain customer.
- [ ] A02 Login kasir yang sah dengan terminal Android aktif berhasil; password/key salah tidak membocorkan validitas username, dan error menampilkan server yang dikonfigurasi, bukan Finance2.
- [ ] A03 STAFF + BARISTA dengan scope sah berhasil; tanpa employee, nonaktif, scope ambigu dan tanpa RBAC ditolak dengan pesan aman. Multi-role tidak dipaksa dipecah.
- [ ] A04 401 di payment/inbox/printer/sync kembali ke login profil yang benar; cart/outbox tetap tersimpan dan tidak otomatis dibayar ulang.
- [ ] A05 403 RBAC, FEATURE_UPGRADE_REQUIRED, 409 recon, 422 data salah, 429 dan server mati tampil berbeda; HTML error/secret tidak bocor ke UI/log.
- [ ] A06 Client versi lama/baru diuji terhadap capability matrix; fitur yang belum didukung tidak memakai endpoint fiktif atau fallback bypass.
- [ ] A07 Ganti akun A→B pada URL sama dengan outbox A: B tidak melihat data privat atau mengirim event sebagai A; pemulihan A tetap tersedia.
- [ ] A08 Ganti profil saat request/background masih berjalan: response dan hasil DB tetap pada instance/actor asal; URL sama ke instance lain tidak mengambil cache/token lama.
- [ ] A09 Ganti domain untuk instance yang sama melalui verifikasi dan konfirmasi tidak menghabiskan seat atau mencampur scope; spoof instance ditolak.
- [ ] A10 Migrasi credential/profile terputus lalu restart: dapat dilanjutkan, token aman, tidak reset SQLite; logout tidak menghapus pending dan backup tidak mengekspos key.

### S — Antrean, sinkronisasi dan recovery (APK-03)

- [ ] S01 Simpan 10 order saat server mati, restart APK, hidupkan server: 10 aggregate yang sama tersimpan, bukan 0/20; nomor resmi hanya dari server.
- [ ] S02 Timeout sesudah server menyimpan order/payment tetapi sebelum response: pemeriksaan hasil memakai event ID sama, tidak memanggil writer kedua.
- [ ] S03 Edit draft lokal tiga kali: satu local UUID, urutan revisi benar, member/channel/notes tetap; tidak ada tiga order terpisah.
- [ ] S04 Event pertama BLOCKED dan app restart: event kedua aggregate sama tetap menunggu; aggregate lain tetap berjalan.
- [ ] S05 Foreground + background + tombol sinkron bersamaan: satu claim efektif per event; lease worker mati dipulihkan tanpa intent baru.
- [ ] S06 Event ID sama/payload sama replay hasil; ID sama/payload berubah ditolak. Akun/outlet lain tidak dapat membaca hasil event itu.
- [ ] S07 Koreksi REJECTED final menghasilkan event pengganti dengan jejak asal; tombol retry jaringan tidak diam-diam mengubah payload atau requeue semua penolakan.
- [ ] S08 Web mengubah order saat APK mengedit revisi lama: konflik terlihat, tidak overwrite; field/outlet/session intent lama tidak diganti default baru otomatis.
- [ ] S09 Server terputus setelah draft tersimpan sebelum confirm/journal final: pemeriksaan menemukan draft yang sama dan melanjutkan secara sah tanpa duplikasi.
- [ ] S10 PROCESSING terlalu lama memerlukan recovery berbukti; tidak disembunyikan dengan menghapus event/journal atau memperbolehkan payment baru.
- [ ] S11 Antrean kemarin tetap terlihat setelah tengah malam, lebih dari 100 pending dapat ditelusuri, tidak ada silent limit yang menghilangkan pekerjaan.
- [ ] S12 Migrasi SQLite versi lama/disk penuh/process-kill tidak menghapus data; cache refresh gagal tidak merusak snapshot aktif; retry backoff berhenti saat auth/license bermasalah.

### C — Katalog, cart dan order (APK-04)

- [ ] C01 Semua fixture >120 produk/>60 bundle dapat dimuat online dan offline setelah sinkron lengkap; indikator “siap offline” tidak muncul untuk snapshot parsial.
- [ ] C02 Pencarian/filter divisi, kategori, kode/nama, bundle, sold-out/UNKNOWN dan harga kanal sesuai server; UNKNOWN bukan stok nol.
- [ ] C03 Extra wajib/min-max/qty, catatan dan harga extra tersimpan; offline tanpa cache extra menampilkan pembatas yang jelas, tidak melewati pilihan wajib.
- [ ] C04 Dua bundle sama dengan extra/catatan berbeda tetap dua occurrence; qty dan harga komponen tidak terlipat ketika restore/append/refund.
- [ ] C05 Simpan draft → keluar → buka → tambah item → simpan/confirm: order tetap sama dan seluruh field/member/channel/UOM/notes tetap benar.
- [ ] C06 Append setelah confirmed/paid mengikuti aturan web; line lama tidak dikurangi/ditulis ulang sembarangan, stok dan tiket hanya untuk perubahan yang sah.
- [ ] C07 Produk/harga berubah ketika cart terbuka: tidak membuang cart, tampil revalidasi server dan persetujuan bila perlu.
- [ ] C08 Produk dihapus/nonaktif atau seluruh katalog menjadi kosong: snapshot baru menggantikan cache, tidak mempertahankan item lama seolah aktif.
- [ ] C09 Histori tanggal/pagination/order terbaru sesuai web; order belum selesai kemarin masih bisa ditemukan sesuai izin dan aturan server.
- [ ] C10 Foto panjang URL/berukuran besar/rusak/server gagal tidak menyebabkan crash, pemborosan storage tak terbatas, atau membocorkan credential query.

### P — Payment, rekening, voucher dan DP (APK-05)

- [ ] P01 Bayar cash tepat/lebih/kurang: due/change/remaining server benar; nominal format lokal tidak mengubah angka final.
- [ ] P02 Noncash dan campuran dua metode memakai rekening/reference benar; akun/metode tidak aktif/di luar scope ditolak sebelum posting.
- [ ] P03 Partial payment hanya jika aturan server mengizinkan; buka ulang order membawa remaining yang benar, bukan membayar grand total lagi.
- [ ] P04 Voucher sah/expired/used/kuota habis/minimum gagal diuji; pembayaran voucher penuh dan promo tidak dibeli ditangani sesuai policy.
- [ ] P05 DP lebih kecil/sama/lebih besar tagihan: preview pemakaian dan sisa bayar cocok web; DP penuh tidak meminta cash tambahan.
- [ ] P06 Poin/stamp/voucher hasil transaksi tepat sekali; retry payment tidak menghasilkan hadiah/debit DP dua kali.
- [ ] P07 Klik bayar dua kali, timeout, tutup dialog, kill/restart APK: satu attempt/result; layar “periksa pembayaran” tidak menyediakan jalan mudah untuk bayar kedua.
- [ ] P08 Dua kasir web/APK membayar order sama bersamaan: batas/tagihan terlindungi; response replay hanya untuk actor/binding yang sah.
- [ ] P09 Harga/order/promo berubah setelah prepare: transaksi belum selesai direview sesuai mode; sale offline yang sudah menerima uang mempertahankan snapshot/nominal dan bukti, selisih tidak ditagihkan ulang diam-diam saat import.
- [ ] P10 Server offline dengan offline-ready/grant sah: cash payment menjadi lunas lokal, ledger/outbox dan struk tersimpan; status sinkron terpisah. Schema/kontrak offline belum siap menolak readiness, bukan fallback writer non-idempoten. Outcome online UNKNOWN tidak diubah menjadi cash sale kedua.

### R — Void/refund dan persediaan (APK-06)

- [ ] R01 Produk tanpa resep/event yang sah di-void/refund tanpa alasan palsu “stock commit belum ada”; kas dan status tetap sesuai aturan web.
- [ ] R02 Produk material/component dengan resep: confirm, full void, refund dengan kembali stok mengubah lot/ledger dan kas tepat sekali.
- [ ] R03 Partial refund beberapa kali, qty melebihi sisa, tanpa kembali stok dan refund lintas metode diuji; tidak ada qty/saldo negatif akibat double reversal.
- [ ] R04 Extra dan bundle mengembalikan qty/HPP sesuai server; komponen bersama dan defisit ditangani server, tidak dihitung sendiri oleh APK.
- [ ] R05 Password step-up salah, proof expired, proof untuk order/action/user lain, replay proof: semuanya ditolak tanpa write.
- [ ] R06 Refund web dan APK bersamaan serta timeout setelah commit: hasil pasti dicari dulu, tidak menggandakan kas/stok/reward reversal.
- [ ] R07 Printer gagal setelah reversal berhasil: retry cetak tidak memanggil refund/void lagi; alasan dan actor ada di audit server.
- [ ] R08 Role tanpa izin atau modul terkunci tidak bisa void/refund lewat POST langsung; UI tidak mengirim request dengan superadmin palsu.

### H — Sesi, recon dan tutup kasir (APK-07)

- [ ] H01 Buka dari web, lanjut APK akun/outlet sama: satu sesi, mode backup, owner terminal tidak tertimpa; arah sebaliknya juga lulus.
- [ ] H02 Akun/outlet/terminal tidak cocok ditolak sesuai aturan; mengganti device key bukan cara mengambil sesi orang lain.
- [ ] H03 Daily recon OPEN/CLOSE belum lengkap: status/checkpoint/tindakan terlihat; APK tidak menghilangkan guard.
- [ ] H04 Shift ditutup web saat APK offline: intent lama tetap terikat shift asal dan ditangani eksplisit setelah reconnect, bukan otomatis masuk shift baru.
- [ ] H05 Outbox/payment UNKNOWN/order belum final sebelum close terlihat; tidak ada pesan “sinkron selesai” palsu.
- [ ] H06 Preview sistem vs uang aktual, metode/rekening, DP, selisih dan close sama web; step-up valid; cetak ringkasan tidak menduplikasi close.
- [ ] H07 Dua permintaan close/timeout/restart menghasilkan satu penutupan sah; session cache segera memperbarui perangkat lain saat koneksi tersedia.

### I — Kanal masuk, reservasi dan dapur (APK-08)

- [ ] I01 Self-order/online-food/reservasi masuk muncul pada outlet benar dengan detail/extra/pembayaran/DP dan badge yang dapat di-refresh.
- [ ] I02 Terima/tolak disertai alasan, perubahan status dan print targets yang benar; order stock queued tidak ditampilkan seolah posted.
- [ ] I03 Web dan APK verify/reject bersamaan: satu hasil akhir, tidak ada order/stock job ganda.
- [ ] I04 Create/edit reservasi dari APK berisi meja/tanggal/member/produk/bundle/extra sesuai web, validasi server tetap berlaku.
- [ ] I05 Terima DP reservasi/member lalu cancel/reject dengan opsi refund sah: uang dan journal tepat, proof password hanya ketika diperlukan aturan.
- [ ] I06 Tolak/cancel tanpa refund tidak membuat cash-out; DP yang sudah refund tidak bisa di-refund kedua kali.
- [ ] I07 Status dapur/bar/checker terbarui; ack/ready/checker dibatasi role; APK tidak menjalankan worker global atau membaca task outlet lain.
- [ ] I08 Offline dan fitur kanal tidak dibeli: UI menjelaskan batas, cached data ditandai, POST langsung tetap ditolak tanpa write.

### T — Printer fisik (APK-09)

- [ ] T01 Binding exact printer ID→Bluetooth benar; printer cashier/bar/kitchen tidak tertukar oleh fallback role generik.
- [ ] T02 Kertas 58/80 dan jumlah karakter lokal bertahan setelah sync/restart/update APK; tidak ditimpa database server.
- [ ] T03 Logo PNG transparan/JPEG tampil, bukan blok hitam; QR/barcode terbaca scanner; nama panjang/angka tidak terpotong.
- [ ] T04 Preview memakai layout yang sama dengan output; kolom total/qty, copies, cut dan drawer sesuai profil/izin.
- [ ] T05 Tiga target, satu gagal: dua sukses tidak dicetak ulang ketika retry target gagal.
- [ ] T06 Bluetooth mati/izin ditolak/MAC invalid/paper-out/timeout: UI responsif, job tetap terlacak, tidak mengulang transaksi finansial.
- [ ] T07 Confirm lalu append menghasilkan tiket sesuai revisi/perubahan; background/foreground tidak mengirim tiket identik bersamaan.
- [ ] T08 Struk payment, void/refund dan shift-close menggunakan ID hasil yang benar; reprint meminta proof/audit sesuai aturan.
- [ ] T09 Kill app sesudah bytes dikirim sebelum ack: status “hasil cetak belum pasti” dan pilihan recovery jelas; jangan menjanjikan exactly-once kertas tercetak.
- [ ] T10 Target transport non-Bluetooth dipisahkan; struk lokal offline memakai template/logo tersimpan, nomor lokal unik dan status lunas sebenarnya dengan label belum tersinkron; nomor pusat tidak dipalsukan.

### L — Laporan dan operasi admin kasir (APK-10)

- [ ] L01 Sales/detail/daily/payment/refund/void/close: periode, outlet, total dan basis tanggal cocok laporan web, bukan total baris page pertama.
- [ ] L02 Urutan sales mengikuti order time; pergantian hari/timezone tidak menyembunyikan pembayaran/order lintas hari.
- [ ] L03 PDF/download sesuai izin dan dapat dibuka di Android; akses direct URL/token lintas outlet ditolak; URL tidak membawa token jangka panjang.
- [ ] L04 Kirim daily sales/bukti terkonfigurasi melalui WA/Telegram hanya via Finance dan hak yang sah, bukan mengisi bot token di APK.
- [ ] L05 Member create/edit minimum dan pilihan metode/rekening diuji sesuai RBAC; kasir tanpa admin tidak dapat mengedit master/saldo.
- [ ] L06 Admin outlet/terminal/printer/routing/kanal melakukan aksi yang disetujui dari UI; pilihan ID tidak menjadi bypass bearer binding/kuota.
- [ ] L07 Coverage setiap menu/aksi kasir web pada cutoff terpetakan: sudah native + teruji, gap yang memblokir, atau bukan pekerjaan kasir dengan alasan eksplisit. Tidak menyembunyikan gap di balik WebView.

### U — Pengalaman pengguna (APK-10)

- [ ] U01 Tablet landscape/portrait dan ponsel: katalog, cart, keyboard dan tombol bayar tidak tertutup/overflow; rotasi mempertahankan transaksi.
- [ ] U02 Loading, hasil kosong, gagal, disabled, locked/upgrade dan offline mempunyai state berbeda dengan tindakan yang jelas.
- [ ] U03 Status & Pemulihan menampilkan user/outlet/sesi, lisensi, umur cache, pending/blocked/unknown dan printer; bukan hanya lampu “online”.
- [ ] U04 Font besar, uang Rupiah, tanggal, icon/warna dan target sentuh nyaman; konfirmasi transaksi tidak bergantung pada warna saja.
- [ ] U05 Operator dapat pulih dari salah URL/login/printer/retry tanpa terminal, menghapus data aplikasi, atau membuka halaman admin Control.
- [ ] U06 Logout/ganti profil/exit saat ada pending memberi peringatan dan jalan aman; error sanitasi tetap menyediakan correlation ID untuk dukungan.

### K — Paket dan lisensi perangkat (APK-11)

- [ ] K01 Starter tanpa APK ditolak; Starter + addon sah bisa POS minimum lengkap tanpa akses layar Inventory Advanced; full paket tetap tunduk RBAC.
- [ ] K02 Pairing baru dengan grant Control terverifikasi membuat satu seat Android, tidak mengambil slot server dan tidak meminta key privat agent.
- [ ] K03 Dua aktivasi berebut satu seat terakhir: tepat satu diterima; perangkat sah yang sudah aktif tetap berjalan.
- [ ] K04 Edit preference/database lokal/edition/header/entitlement tidak membuka fitur; false/missing/numeric-limit bukan boolean true.
- [ ] K05 Signature/trust key/instance/device/public-key/revision/nonce salah atau replay ditolak baik client maupun server.
- [ ] K06 Copy backup/token/device key ke Android kedua tidak membuktikan kepemilikan installation key; challenge gagal tanpa seat sah.
- [ ] K07 Offline dengan lease+actor grant sah sesuai window boleh operasi yang ditentukan; expired/revoked/clock rollback/reboot tidak memberi unlimited access.
- [ ] K08 Login user baru offline dan first activation offline ditolak; lease perangkat tidak otomatis memberi RBAC semua user.
- [ ] K09 Upgrade/downgrade fitur setelah sync langsung mengubah keputusan/menu; data dan outbox tetap utuh, tidak install ulang/aktivasi baru.
- [ ] K10 Update APK mempertahankan seat dan key; uninstall/key hilang/replacement memakai recovery resmi serta jejak audit, bukan duplikasi seat tersembunyi.
- [ ] K11 Domain berganti/Control tidak terjangkau/izin pairing kedaluwarsa ditangani sesuai policy; tidak menambahkan deadline pemasangan dari tanggal beli/build.
- [ ] K12 Bukti integrasi Control nyata terisolasi disimpan: request/status/grant/renew/revoke/kuota; hasil mock dicatat terpisah dan bukan klaim aktivasi sungguhan.

### Z — Release dan pilot (APK-12)

- [ ] Z01 Analyze, unit/widget/integration, build debug dan release lulus pada source cutoff yang sama; failure/timeout dilaporkan.
- [ ] Z02 Update in-place dari build lama dengan data lokal/pending/print binding tidak kehilangan data; signing cert/applicationId/installation key tetap; tidak perlu clear data.
- [ ] Z03 Release scan bebas secret, data fixture/customer, production URL default, debug bypass dan permission tak perlu; manifest/network/backup policy direview.
- [ ] Z04 Pilot satu shift web+dua Android dengan gangguan jaringan/pergantian hari selesai; order/payment/stock/DP/promo/refund/reports cocok server.
- [ ] Z05 Artefak signed, hash, versionCode, backend minimum, device policy, changelog dan compatibility matrix diserahkan; Control review/publish dilakukan terpisah.
- [ ] Z06 Customer guide dan recovery tersedia; rollback/forward-fix mempertahankan data dan schema. Lisensi perangkat/fitur yang belum teruji menjadi blocker distribusi, bukan catatan kecil.

### O — Offline operasional dan pemadaman (revisi kebutuhan 25/09; wajib untuk rilis)

Jalankan dua skenario pengguna dengan proses Finance/DB **disposable** benar-benar tidak tersedia. Mematikan internet saja tidak cukup jika aplikasi masih diam-diam mengakses server LAN. Tidak mematikan layanan server bersama/produksi.

- [ ] O01 Mulai kasir di APK yang sudah disiapkan, putuskan koneksi Finance, jual produk+bundle/extra, terima cash dan kembalian, cetak struk: lunas lokal, stok berkurang dan kas bertambah; tidak membutuhkan prepare/payment/print-target server.
- [ ] O02 Kill/restart APK setelah local commit sebelum print/upload: order/payment/stock/cash/jurnal POS dan outbox tetap konsisten; tidak meminta pembayaran kedua; printer dapat dipulihkan secara terpisah.
- [ ] O03 Inject kegagalan disk/transaction pada tiap langkah simpan lokal: seluruh transaksi rollback atau seluruhnya commit; tidak ada lunas tanpa ledger/outbox. Kasir menerima peringatan sebelum mengambil uang ketika penyimpanan tidak dapat dipastikan.
- [ ] O04 Jual 20 transaksi offline, sambungkan server, putuskan lagi sesudah beberapa receipt, lalu ulang sync: tepat 20 sale/payment terposting; stock/cash/journal tidak digandakan dan alias struk dapat dicari.
- [ ] O05 Harga/resep/mapping/stock pusat berubah saat offline: nominal cash/struk penjualan yang selesai tetap sama, HPP/lot dan mapping yang tidak dapat diposting masuk rekonsiliasi; tidak menghapus kejadian uang atau menagih ulang.
- [ ] O06 Pull snapshot baru sesudah sebagian movement diterima: proyeksi stok/kas memakai watermark dengan benar; tidak ada pengurangan stock/tambahan cash ganda dari overlay lokal+saldo pusat.
- [ ] O07 Buat sesi web dan beberapa order belum bayar/sebagian/sudah lunas, handover ber-checkpoint ke APK, matikan server: semua order dalam snapshot dan remaining sah dapat dilanjutkan; owner/session sama, tidak ada pembayaran ulang terhadap yang sudah lunas.
- [ ] O08 Response handover/ack hilang atau web mengedit order selama snapshot: recovery hanya menghasilkan satu custody epoch sah; readiness belum hijau sebelum konsisten; writer web/Android kedua pada order yang dialihkan ditolak server, bukan hanya disembunyikan UI.
- [ ] O09 Saldo DP/voucher/poin tersedia di cache dua perangkat: tanpa alokasi tidak boleh sama-sama dibelanjakan offline; jatah teralokasi dipakai tepat sekali. Cash sale biasa tetap dapat diselesaikan. QRIS/provider yang belum diverifikasi tidak dilabeli settlement sukses.
- [ ] O10 Void/refund transaksi lokal/custody dengan grant approval yang sah: event reversal, cash dan stock kembali benar. Tanpa grant/batas cash/qty tidak cukup ditolak aman; password Finance atau proof online kedaluwarsa tidak dipakai sebagai bypass offline.
- [ ] O11 Buka/tutup sesi lokal sesuai grant, catat uang fisik dan laporan close saat server mati: close lokal tersimpan, bukan menunggu server tanpa akhir; import memetakan session UUID dan mereview konflik sesi/periode tanpa memindahkan transaksi diam-diam.
- [ ] O12 Dua perangkat/network partition: new order ID unik; order bersama tidak dibayar dua kali; stok ketat dibatasi alokasi. Jika ada kebijakan oversell eksplisit, warning/selisih tetap terlihat dan tidak disamarkan sebagai sinkron tanpa masalah.
- [ ] O13 Printer offline memakai logo/ruleset lokal, struk membawa nomor unik dan nominal cash/change; server sync tidak mencetak ulang otomatis atau menghapus nomor yang sudah dibawa pembeli.
- [ ] O14 Server/Control putus dengan grant offline sah: kasir berjalan tanpa cek online tiap sale. Expiry/revoke/clock rollback tidak memperpanjang izin sendiri; event historis tetap tersimpan dan dapat masuk intake review berotorisasi.
- [ ] O15 Pemadaman mendadak tanpa handover: APK siap-cadangan bisa membuat transaksi baru sesuai grant, menampilkan usia/cakupan snapshot, dan tidak mengarang order web yang belum pernah tersalin atau mengambil custody cache lama secara sepihak.
- [ ] O16 Setelah catch-up, handback ke web memakai checkpoint final/epoch baru; order/payment/stock/cash/journal/close dapat ditelusuri per event, tetap satu kali terposting. Event needs-review terlihat, kasir tidak diminta copy database, clear data, atau clean-install.

## 5. Test otomatis yang perlu dibuat (bukan file yang sudah ada)

Penamaan berikut usulan untuk batch terkait, supaya pengembang lokal punya target konkret. Jangan mengklaim path ini ada sebelum dibuat.

| Batch | Target test baru | Hal utama yang dibuktikan |
|---|---|---|
| 01–02 | `test/api_contract_test.dart`, `test/connection_context_test.dart`, `test/credential_migration_test.dart` | Payload/verb/status, actor/instance terpisah, migrasi tidak hilang saat crash |
| 03 | `test/outbox_ordering_test.dart`, `test/sync_claim_test.dart`, `integration_test/sync_recovery_test.dart` | Head-of-line, concurrency lintas isolate, kill/timeout, ambiguous result |
| 03–07 | `test/offline_ledger_atomicity_test.dart`, `test/offline_ruleset_parity_test.dart`, `integration_test/server_outage_test.dart`, `integration_test/web_apk_handover_test.dart` | Local sale/payment/stock/cash atomik, ruleset PHP–Dart setara, pemadaman nyata disposable, fencing dan import/handback |
| 04 | `test/catalog_snapshot_test.dart`, `test/draft_roundtrip_test.dart`, `test/bundle_extra_test.dart` | Pagination/tombstone/empty, UUID/member/channel, bundle occurrence |
| 05 | `test/payment_attempt_test.dart`, `test/payment_preview_test.dart` | Durable attempt, money/DP/voucher server, retry dan drawer/cetak tidak menggandakan payment |
| 06–08 | `test/step_up_test.dart`, `test/session_backup_test.dart`, `test/incoming_order_test.dart` | Proof binding, sesi bersama, reject/verify concurrency; ledger divalidasi test Finance disposable |
| 09 | `test/print_queue_test.dart`, `test/receipt_layout_test.dart`, native Android tests | Target/revision/copy, raster/width, invalid address/permission; tetap perlu printer nyata |
| 10 | `test/reports_contract_test.dart`, `test/cashier_layout_test.dart` | Periode/scoping, total bukan page subtotal, responsive/locked/recovery UI |
| 11 | `test/device_license_test.dart`, `integration_test/device_pairing_test.dart` | Signature/PoP/expiry/replay/quota; suite Control terpisah untuk signed issuance nyata |
| 12 | `integration_test/upgrade_in_place_test.dart`, `integration_test/cashier_shift_test.dart` | Update SQLite/auth/key tanpa reset dan shift penuh |

## 6. Bukti audit yang benar-benar dijalankan 24/09

Lingkungan: PHP CLI 8.1.32. Tidak ada koneksi database/Control live atau pemanggilan HTTP customer. Source-only/in-memory fakes **tidak membuktikan** transaksi SQL, perangkat Android, atau jalur pembayaran nyata.

| Pemeriksaan | Hasil aktual |
|---|---|
| Git status awal APK dan Finance | Bersih; perubahan dokumentasi audit dibuat setelah baseline ini |
| Path client vs routes | 45 pola client / 46 route server; semua 45 cocok; server-only `pos-mobile/orders/save` |
| 15 `tools/tests/pos_mobile*smoke.php` | Seluruhnya exit 0 (daftar di bawah) |
| `feature_boundary_contract_smoke.php` | **FAIL exit 255:** `unmapped public action procurement/division_po_sr_line_action` |
| Flutter/Dart executable | Tidak tersedia; tidak menjalankan analyze/test/build |
| `test/widget_test.dart` existing | Hanya satu smoke tampilan Pengaturan POS; bukan test transaksi/sync/license |
| UAT Android/print/DB/Control actual | **Belum dijalankan** |
| Pemeriksaan dokumentasi | Link lokal 3 dokumen aktif valid; 106 item UAT unik masih unchecked; 15 hash source cocok; perubahan hanya Markdown di `docs`, bukan `_note` |

Revisi **25/09** menambahkan 16 item O01–O16 sehingga checklist aktif berjumlah **122**; pemeriksaan 24/09 di tabel di atas tetap catatan historis. Revisi kebutuhan ini hanya mengubah dokumentasi: tidak ada implementasi ledger/payment offline, simulasi pemadaman, atau test runtime baru yang diklaim lulus.

Smoke yang lulus (prefix semua `tools/tests/`, suffix `.php`):

```text
pos_mobile_authorization_smoke
pos_mobile_cashier_session_binding_smoke
pos_mobile_device_binding_recovery_smoke
pos_mobile_draft_upsert_binding_smoke
pos_mobile_financial_writer_binding_smoke
pos_mobile_incoming_scope_smoke
pos_mobile_login_throttle_smoke
pos_mobile_order_action_reader_binding_smoke
pos_mobile_order_reader_binding_smoke
pos_mobile_print_document_binding_smoke
pos_mobile_printer_binding_smoke
pos_mobile_reader_outlet_binding_smoke
pos_mobile_reservation_refund_step_up_smoke
pos_mobile_reversal_step_up_smoke
pos_mobile_role_scope_negative_smoke
```

Kegagalan gate global tidak diperbaiki dalam tugas dokumentasi ini. Thread Finance perlu memetakan aksi procurement secara sah dan rerun gate; jangan menjadikan kelulusan 15 smoke mobile sebagai pengganti quality gate seluruh paket.

### Provenance source

Commit APK: `c2a3f32d056b91684571096622ec8bec2d74d2b9`. Commit Finance: `4a75f07cdf0ca67a7b4fb7409db206aceb85a13d`. Control belum mempunyai HEAD Git; hash berikut mengacu working tree yang dibaca. Tidak ada commit/push yang dibuat untuk audit ini.

| File | SHA256 saat audit |
|---|---|
| APK `lib/src/services/finance_api_client.dart` | `9a15579f5c5e5267fe4b15d1ac66bae4ecf3d2d460ef08bd153eff52f1e86994` |
| APK `lib/src/services/local_database.dart` | `ff001a133f8cf10bded075356d644d15b63871260b78e1f2e3f1b159e06c388f` |
| APK `lib/src/services/sync_service.dart` | `fafe99d777aa321a6a607f4ce13b18dec43eefa46879d3a4cd5b69f01f501490` |
| APK `lib/src/screens/cashier_screen.dart` | `edebba6d405b1b61df5d340192aef45a88fc981c21fc17ebf0ebfb72225fa874` |
| APK `lib/src/screens/order_workspace_screen.dart` | `d6a2ad402b70b979143e8c66021faacec6b100dc748264a736ddc3f3882d58b2` |
| APK `pubspec.lock` | `097df2030eed9e3466fffcf3a9371f4b5c8cd50d9b0ef89ba6ce70c5b01860cd` |
| Finance `application/controllers/Pos_mobile.php` | `e282f2a385e3c830cc983b874e2040f33f18c587c6de529843af4cc76c63bb90` |
| Finance `application/models/Pos_model.php` | `1d04c0ae3a9afb3ec8807b801b01580812ba76bdc3f13c593613847bb9157758` |
| Finance `application/config/routes.php` | `45dc8ed70420c87392c4e742e3e88e150089f04c88ad7c4176e9d2b06ae28a9b` |
| Finance `application/config/feature_access.php` | `5c41b7097b398a8dc3d027e408b559541acadf9e38e34828411383c16afac528` |
| Finance `app-manifest.json` | `9ec16685e302bf9e3b0fc55f2c0cf830ce9fe977e5acfecc6ae75c8ff275d415` |
| Finance `tools/release/customer_clean_profile.json` | `269e8ee19d6627b3dd8b519aca93e0edfdff66f097d4542104fc57e1d0486cd0` |
| Control `application/models/License_activation_model.php` | `3a8aedfe57178f616b3baa8a9eab74ea3a327b072008b038f62ae4bb1cbca0d7` |
| Control `tools/lib/license_issuance_worker.php` | `e7d5a88b73531198c726e71550b50f76641a0f3167446ce3a3b52cd248125d13` |
| Control `application/config/routes.php` | `5691f9edcf107c7b867594e82aa1df8ed513c8d8510cb0ce59391b41d6556bc1` |

Jika hash/HEAD berubah, audit ulang bagian yang terkena diff sebelum menerapkan batch, bukan menyatakan semua temuan ini pasti masih berlaku. Panduan ini tidak menaikkan versi atau menjanjikan release yang belum diuji.
