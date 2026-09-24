<!-- - foto banyak yang belum tampil?
- Foto produk memakai photo_path dari server, di-cache lokal APK, dan dipreload setelah sinkronisasi.. kalau sinrkonisasinya sering berarti sering reload donk? bisa tidak sebelum reload di cek dulu ada file berubah tidak, kalau ada baru reload yang berubah saja
- tadi saya coba simpan draft, datanya kemana? gimana saya membukanya lagi?
- saya coba di emulator, tampilan tidak responsif, dan tidak bisa di scroll
- sering tampil notif offline / belum siap dan keterangannya yang mentah jelek sekali. kenapa tampil ? dan bagaimana baiknya?
- sepertinya setiap kalau sinkron sesuai jadwal, data jadi ada crash, misal setiap saya klik produk extra nya error. sepertinya mode sinkron otomatisnya perlu diperbaiki polanya agar tidak mengganggu operasional -->


maksud saya, tadi saya coba simpan orderan draft , dan simpan transaksi orderan, datannya tidak ada. seharusnya transaksi tersimpan itu masuk order pos hari ini aktif / belum payment.
nah ini barusan saya coba simpan draft dan simpan transaksi, datanya tertimpa semua di lokal

sinkronisasi transaksi bagaimana konspenya? apakah sudah aman? misal dari pagi sampai siang saya pakai finance server, lalu listrik mati, saya melanjutkan pakai apk. ketika server kembali online apkah otomatis data yang tersimpan di apk ketika server down otomatis terupdate di server? atau justru sebaliknya?

mungkin juga perlu kamu petakan data mana saja yang server only dan server-apk agar sinkronisasinya jelas. seperti master produk itu kan server only, apk hanya mengambil data dari server

"Order lokal belum bisa dibayar sebelum diterima server." seharusnya order aktif yang belum dibayar tetap diterima server. karena order yang disimpan transaksi ini mengurangi stok, berpengaruh ke stok. dan agar admin bisa mendapat laporan realtime secara online omzet baik sudah payment ataupun belum

saya punya 1 pertanyaan.
di apk kan tersimpan cache data dan transaksi.
kan ada sinkronisasi 2 arah terkait transaksi. nah bagaimana kalau suatu saat kita ingin menyinkronkan ulang tablet mengikuti server. katakanlah seperti ini kita menarik data dari server, lalu kita melakukan demo dengan beberapa transaksi offline. ketika kita kembali menghubungkan server online, secara alami apakah apk akan menarik data server atau server menarik data apk? atau bagaimana?




buka kasir masih gagal
test print gagal Endpoint POS mobile belum tersedia


ketika pertama login, jika ada sesi kasir aktif baik dari server maupun lokal sebelumnya maka tidak perlu buka kasir, tapi jika tidak ada maka wajib buka kasir dulu


 

 