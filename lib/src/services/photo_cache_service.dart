import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class PhotoCacheService {
  PhotoCacheService._();

  static final PhotoCacheService instance = PhotoCacheService._();
  final http.Client _client = http.Client();
  final Set<String> _checkedExistingUrls = {};
  final Map<String, Future<String?>> _inFlight = {};
  Directory? _directory;

  void beginSyncCycle() {
    _checkedExistingUrls.clear();
  }

  Future<String?> cacheProductPhoto({
    required String backendUrl,
    required String source,
    bool refreshExisting = false,
  }) async {
    final url = _resolveUrl(backendUrl, source);
    if (url.isEmpty) return null;
    final running = _inFlight[url];
    if (running != null) return running;
    final future = _cacheProductPhoto(url, refreshExisting: refreshExisting);
    _inFlight[url] = future;
    future.then<void>(
      (_) => _inFlight.remove(url),
      onError: (Object _, StackTrace __) {
        _inFlight.remove(url);
      },
    );
    return future;
  }

  Future<String?> _cacheProductPhoto(
    String url, {
    required bool refreshExisting,
  }) async {
    final directory = await _cacheDirectory();
    final file = File(p.join(directory.path, _fileName(url)));
    if (await file.exists()) {
      if (!refreshExisting || !_checkedExistingUrls.add(url)) return file.path;
      await _refreshExistingPhoto(url, file);
      return file.path;
    }

    try {
      final response = await _client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          response.bodyBytes.isEmpty) {
        return null;
      }
      await file.writeAsBytes(response.bodyBytes, flush: true);
      await _writeMeta(file, response.headers);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _refreshExistingPhoto(String url, File file) async {
    try {
      final meta = await _readMeta(file);
      final headers = <String, String>{};
      final etag = meta['etag']?.toString().trim() ?? '';
      final modified = meta['last-modified']?.toString().trim() ?? '';
      if (etag.isNotEmpty) headers['If-None-Match'] = etag;
      if (modified.isNotEmpty) headers['If-Modified-Since'] = modified;
      final response = await _client
          .head(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 8));
      if (response.statusCode == 304) return true;
      if (response.statusCode < 200 || response.statusCode >= 300) return true;

      final nextEtag = response.headers['etag']?.trim() ?? '';
      final nextModified = response.headers['last-modified']?.trim() ?? '';
      if (nextEtag.isEmpty && nextModified.isEmpty) return true;
      if ((nextEtag.isNotEmpty && nextEtag == etag) ||
          (nextModified.isNotEmpty && nextModified == modified)) {
        return true;
      }
      final downloaded = await _client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      if (downloaded.statusCode < 200 ||
          downloaded.statusCode >= 300 ||
          downloaded.bodyBytes.isEmpty) {
        return true;
      }
      await file.writeAsBytes(downloaded.bodyBytes, flush: true);
      await _writeMeta(file, downloaded.headers);
      return true;
    } catch (_) {
      return true;
    }
  }

  Future<Map<String, Object?>> _readMeta(File file) async {
    final metaFile = File('${file.path}.json');
    if (!await metaFile.exists()) return const {};
    try {
      final decoded = jsonDecode(await metaFile.readAsString());
      return decoded is Map
          ? Map<String, Object?>.from(decoded)
          : const <String, Object?>{};
    } catch (_) {
      return const {};
    }
  }

  Future<void> _writeMeta(File file, Map<String, String> headers) async {
    final etag = headers['etag']?.trim() ?? '';
    final modified = headers['last-modified']?.trim() ?? '';
    if (etag.isEmpty && modified.isEmpty) return;
    await File('${file.path}.json').writeAsString(
      jsonEncode({'etag': etag, 'last-modified': modified}),
      flush: true,
    );
  }

  String resolveUrl(String backendUrl, String source) {
    return _resolveUrl(backendUrl, source);
  }

  Future<Directory> _cacheDirectory() async {
    final current = _directory;
    if (current != null) return current;
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(root.path, 'product_photos'));
    await directory.create(recursive: true);
    _directory = directory;
    return directory;
  }

  String _resolveUrl(String backendUrl, String source) {
    final raw = source.trim();
    if (raw.isEmpty) return '';
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    final base = backendUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    if (base.isEmpty) return '';
    return '$base/${raw.replaceFirst(RegExp(r'^/+'), '')}';
  }

  String _fileName(String url) {
    final encoded = base64Url.encode(utf8.encode(url)).replaceAll('=', '');
    return '$encoded.img';
  }
}
