import 'dart:convert';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists localStorage + sessionStorage per host, and restores them at
/// document start so the app JS sees tokens immediately.
class StoragePersistence {
  static const _storage = FlutterSecureStorage();
  static const _keyPrefixLocal = "ls_";
  static const _keyPrefixSession = "ss_";

  static String _hostKey(String host) => host;

  /// Save storages of the current page.
  static Future<void> save(
    WebUri url,
    InAppWebViewController controller,
  ) async {
    final host = Uri.parse(url.toString()).host;
    if (host.isEmpty) return;

    final String? lsJson = await controller.evaluateJavascript(
      source:
          'JSON.stringify(Object.fromEntries(Object.entries(localStorage)))',
    );
    final String? ssJson = await controller.evaluateJavascript(
      source:
          'JSON.stringify(Object.fromEntries(Object.entries(sessionStorage)))',
    );

    if (lsJson != null) {
      await _storage.write(
        key: _keyPrefixLocal + _hostKey(host),
        value: lsJson,
      );
    }
    if (ssJson != null) {
      await _storage.write(
        key: _keyPrefixSession + _hostKey(host),
        value: ssJson,
      );
    }
  }

  /// Inject a UserScript to restore storages at document start for this origin.
  /// Call BEFORE navigating to that origin.
  static Future<void> restoreAtDocumentStart(
    InAppWebViewController controller,
    Uri seedUrl,
  ) async {
    final host = seedUrl.host;
    if (host.isEmpty) return;

    final lsRaw = await _storage.read(key: _keyPrefixLocal + _hostKey(host));
    final ssRaw = await _storage.read(key: _keyPrefixSession + _hostKey(host));

    final ls = lsRaw ?? '{}';
    final ss = ssRaw ?? '{}';

    final script =
        '''
      (function() {
        try {
          var _ls = ${jsonEncode(jsonDecode(ls))};
          var _ss = ${jsonEncode(jsonDecode(ss))};
          for (var k in _ls) { if (_ls.hasOwnProperty(k)) localStorage.setItem(k, String(_ls[k])); }
          for (var k in _ss) { if (_ss.hasOwnProperty(k)) sessionStorage.setItem(k, String(_ss[k])); }
        } catch (e) {}
      })();
    ''';

    await controller.addUserScript(
      userScript: UserScript(
        source: script,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
    );
  }

  static Future<void> clearForHost(String host) async {
    await _storage.delete(key: _keyPrefixLocal + _hostKey(host));
    await _storage.delete(key: _keyPrefixSession + _hostKey(host));
  }
}
