# Rilis APK POS Kasir

Dokumen ini untuk membuat APK atau AAB yang dapat dipasang sebagai build
operasional. Build release sengaja berhenti bila keystore belum ada; jangan
pernah membagikan keystore atau password lewat Git, chat, atau screenshot.

## Sekali saja: buat identitas tanda tangan

1. Pada komputer pengembang, buat keystore Android dan simpan pada folder
   privat di luar project.
2. Salin `android/key.properties.example` menjadi `android/key.properties`.
3. Isi `storeFile`, `storePassword`, `keyAlias`, dan `keyPassword` dengan
   nilai keystore Anda.
4. Pastikan `android/key.properties` dan file `.jks` tidak masuk Git. Project
   sudah mengabaikannya secara default.

Keystore yang sama wajib dipakai untuk semua update aplikasi setelah build
pertama didistribusikan. Kehilangan keystore berarti APK yang sudah terpasang
tidak bisa diperbarui sebagai aplikasi yang sama.

Identitas Android rilis saat ini adalah `com.namuaprojects.finance.pos`.
Identitas ini sudah menggantikan placeholder `com.example...` dan tidak boleh
diganti setelah APK pertama didistribusikan sebagai aplikasi produksi.

## Build dan pemeriksaan

```text
flutter pub get
flutter analyze
flutter test
flutter build apk --release
# atau untuk Play Store:
flutter build appbundle --release
```

Jika source baru dipindah ke komputer lain dan folder `android/gradlew` atau
`android/gradle/wrapper/gradle-wrapper.jar` belum ada, pulihkan file generated
tersebut lebih dahulu memakai Flutter SDK:

```text
flutter create --platforms=android .
```

Sesudah itu pastikan kembali perubahan pada `android/app/build.gradle.kts`,
`AndroidManifest.xml`, dan `MainActivity.kt` dari project ini tetap ada sebelum
menjalankan build. Folder wrapper harus dibawa pada source pengembangan;
keystore tetap tidak boleh dibawa.

Sebelum membagikan build, uji pada tablet nyata dengan backend staging:

1. Login memakai device key terminal yang terdaftar di Finance.
2. Buka shift dari web, lalu pastikan APK masuk mode Backup tanpa membuat
   shift kedua.
3. Buat order saat online, cek stok/order di POS web dan tiket Bluetooth.
4. Matikan koneksi, buat draft dan order confirm, hidupkan koneksi, lalu cek
   satu order saja masuk server dan tiket terkirim sekali.
5. Uji payment cash/rekening, voucher, member/deposit, Void, Refund, Cetak
   Ulang, Tutup Kasir, serta refund DP reservasi. Aksi sensitif harus meminta
   password dan gagal bila password salah.
6. Uji self-order dan online order dari inbox APK serta POS web.

Tidak ada data transaksi produksi yang boleh dipakai sebagai fixture uji.
