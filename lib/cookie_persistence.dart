import 'dart:convert';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists cookies across app kills. Stores by cookie domain (not by page host).
class CookiePersistence {
  static const _storage = FlutterSecureStorage();
  static const _bucketKey = "cookies_bucket_v1"; // single bucket for all hosts

  /// Save all cookies for the given URL's origin into one shared bucket.
  static Future<void> saveForUrl(Uri url) async {
    final cookies = await CookieManager.instance().getCookies(
      url: WebUri(url.toString()),
    );

    final raw = await _storage.read(key: _bucketKey);
    final Map<String, List<Map<String, dynamic>>> bucket = raw == null
        ? {}
        : Map<String, List<Map<String, dynamic>>>.from(
            (jsonDecode(raw) as Map).map(
              (k, v) => MapEntry(
                k as String,
                (v as List).cast<Map<String, dynamic>>(),
              ),
            ),
          );

    for (final c in cookies) {
      final domainKey = (c.domain ?? url.host).replaceFirst(RegExp(r'^\.'), '');
      final list = bucket[domainKey] ?? [];

      final item = {
        "name": c.name,
        "value": c.value,
        "domain": c.domain, // keep leading dot if present
        "path": c.path ?? "/",
        "isSecure": c.isSecure,
        "isHttpOnly": c.isHttpOnly,
        "sameSite": c.sameSite
            ?.toString()
            .split('.')
            .last, // "LAX"/"STRICT"/"NONE"
        "expiresDate": c.expiresDate, // ms or null
      };

      final idx = list.indexWhere((m) => m['name'] == c.name);
      if (idx >= 0) {
        list[idx] = item;
      } else {
        list.add(item);
      }
      bucket[domainKey] = list;
    }

    await _storage.write(key: _bucketKey, value: jsonEncode(bucket));
  }

  /// Restore all cookies for all stored domains BEFORE any navigation.
  static Future<void> restoreAll({String scheme = "https"}) async {
    final raw = await _storage.read(key: _bucketKey);
    if (raw == null) return;

    final Map<String, dynamic> bucket = jsonDecode(raw);
    for (final entry in bucket.entries) {
      final domainKey = entry.key; // e.g., "fina24.ge"
      final List list = entry.value as List;

      for (final c in list.cast<Map<String, dynamic>>()) {
        final storedDomain = (c["domain"] as String?) ?? domainKey;
        final normalized = storedDomain.replaceFirst(RegExp(r'^\.'), '');

        await CookieManager.instance().setCookie(
          url: WebUri("$scheme://$normalized"),
          name: c["name"] as String,
          value: c["value"] as String,
          domain: c["domain"] as String?, // preserves leading dot
          path: (c["path"] as String?) ?? "/",
          isSecure: (c["isSecure"] as bool?) ?? false,
          isHttpOnly: (c["isHttpOnly"] as bool?) ?? false,
          sameSite: _parseSameSite((c["sameSite"] as String?)?.toUpperCase()),
          expiresDate: c["expiresDate"] as int?, // null ok (session cookie)
        );
      }
    }
  }

  static Future<void> clearAll() async {
    await _storage.delete(key: _bucketKey);
  }

  static HTTPCookieSameSitePolicy? _parseSameSite(String? s) {
    switch (s) {
      case "LAX":
        return HTTPCookieSameSitePolicy.LAX;
      case "STRICT":
        return HTTPCookieSameSitePolicy.STRICT;
      case "NONE":
        return HTTPCookieSameSitePolicy.NONE;
    }
    return null;
  }
}
