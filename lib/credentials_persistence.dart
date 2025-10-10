// credentials_persistence.dart
import 'dart:convert';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Securely stores and restores last-used credentials per host,
/// and injects JS to autofill + capture updates.
class CredentialsPersistence {
  static const _storage = FlutterSecureStorage();
  static const _kUserPrefix = "cred_user_";
  static const _kPassPrefix = "cred_pass_";

  // Track if handler is already registered to avoid duplicates
  static bool _handlerRegistered = false;

  /// Save credentials for a specific host.
  static Future<void> saveForHost({
    required String host,
    required String username,
    required String password,
  }) async {
    if (host.isEmpty || username.isEmpty || password.isEmpty) return;
    await _storage.write(key: _kUserPrefix + host, value: username);
    await _storage.write(key: _kPassPrefix + host, value: password);
    print("✅ Saved credentials for $host: $username");
  }

  /// Read saved credentials for a host.
  static Future<Map<String, String?>> readForHost(String host) async {
    if (host.isEmpty) return {"username": null, "password": null};
    final u = await _storage.read(key: _kUserPrefix + host);
    final p = await _storage.read(key: _kPassPrefix + host);
    print(
      "📖 Read credentials for $host: username=$u, hasPassword=${p != null}",
    );
    return {"username": u, "password": p};
  }

  /// Clear saved credentials for a host (e.g., on explicit logout).
  static Future<void> clearForHost(String host) async {
    await _storage.delete(key: _kUserPrefix + host);
    await _storage.delete(key: _kPassPrefix + host);
    print("🗑️ Cleared credentials for $host");
  }

  /// Injects autofill script that waits for form fields to appear
  static Future<void> injectAutofillAndCaptureJS(
    InAppWebViewController controller,
    Uri loginUri, {
    String? presetUsername,
    String? presetPassword,
  }) async {
    final host = loginUri.host;
    final saved = await readForHost(host);
    final userToFill = presetUsername ?? saved["username"];
    final passToFill = presetPassword ?? saved["password"];

    print(
      "🔧 Injecting autofill for $host - username: $userToFill, hasPassword: ${passToFill != null && passToFill.isNotEmpty}",
    );

    // Register handler only once
    if (!_handlerRegistered) {
      _handlerRegistered = true;

      controller.addJavaScriptHandler(
        handlerName: 'credSave',
        callback: (args) async {
          try {
            final m = (args.isNotEmpty && args.first is Map)
                ? (args.first as Map)
                : {};
            final u = (m['username'] ?? '') as String;
            final p = (m['password'] ?? '') as String;
            print(
              "📥 Received credentials from JS: username=$u, hasPassword=${p.isNotEmpty}",
            );
            if (u.isNotEmpty && p.isNotEmpty) {
              await saveForHost(host: host, username: u, password: p);
            }
          } catch (e) {
            print("❌ Error saving credentials: $e");
          }
          return {"ok": true};
        },
      );
      print("✅ Handler registered");
    }

    // Heuristic CSS selectors
    const selectors = {
      "user": [
        'input[type="email"]',
        'input[type="text"][name*="email" i]',
        'input[type="text"][name*="user" i]',
        'input[type="text"][name*="login" i]',
        'input[name*="email" i]',
        'input[name*="user" i]',
        'input[name*="login" i]',
        'input[id*="email" i]',
        'input[id*="user" i]',
        'input[id*="login" i]',
      ],
      "pass": [
        'input[type="password"]',
        'input[name*="pass" i]',
        'input[id*="pass" i]',
      ],
    };

    final script =
        '''
(function() {
  console.log('🚀 Autofill script started');
  
  var presetUser = ${jsonEncode(userToFill ?? "")};
  var presetPass = ${jsonEncode(passToFill ?? "")};
  
  console.log('📝 Credentials to fill:', presetUser ? 'YES' : 'NO', presetPass ? 'YES' : 'NO');

  function pick(selArr) {
    for (var i = 0; i < selArr.length; i++) {
      var el = document.querySelector(selArr[i]);
      if (el) {
        console.log('✓ Found field with selector:', selArr[i]);
        return el;
      }
    }
    return null;
  }

  function fillFields() {
    var userSel = ${jsonEncode(selectors["user"])};
    var passSel = ${jsonEncode(selectors["pass"])};
    
    var userEl = pick(userSel);
    var passEl = pick(passSel);
    
    console.log('Fields found - user:', !!userEl, 'pass:', !!passEl);

    if (!userEl || !passEl) {
      console.log('⏳ Fields not ready, will retry...');
      return false;
    }

    // Fill username
    if (userEl && presetUser) {
      userEl.value = presetUser;
      userEl.dispatchEvent(new Event('input', { bubbles: true }));
      userEl.dispatchEvent(new Event('change', { bubbles: true }));
      userEl.dispatchEvent(new Event('blur', { bubbles: true }));
      console.log('✅ Filled username:', presetUser);
    }

    // Fill password
    if (passEl && presetPass) {
      passEl.value = presetPass;
      passEl.dispatchEvent(new Event('input', { bubbles: true }));
      passEl.dispatchEvent(new Event('change', { bubbles: true }));
      passEl.dispatchEvent(new Event('blur', { bubbles: true }));
      console.log('✅ Filled password');
    }

    // Set autocomplete attributes
    if (userEl) userEl.setAttribute('autocomplete', 'username');
    if (passEl) passEl.setAttribute('autocomplete', 'current-password');

    // Setup capture handlers
    function report() {
      var u = (userEl && userEl.value) ? String(userEl.value) : '';
      var p = (passEl && passEl.value) ? String(passEl.value) : '';
      console.log('📤 Reporting credentials:', u ? 'YES' : 'NO', p ? 'YES' : 'NO');
      if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('credSave', { username: u, password: p });
      }
    }

    // Hook forms
    var forms = document.querySelectorAll('form');
    forms.forEach(function(f) {
      f.addEventListener('submit', function(e) {
        console.log('📋 Form submitted');
        report();
      }, { capture: true });
    });

    // Hook buttons
    var btns = document.querySelectorAll('button, input[type="submit"]');
    btns.forEach(function(b) {
      var txt = (b.innerText || b.value || '').toLowerCase();
      if (txt.includes('login') || txt.includes('sign') || txt.includes('შესვლა') || txt.includes('submit')) {
        b.addEventListener('click', function() {
          console.log('🖱️ Login button clicked');
          setTimeout(report, 100);
        });
      }
    });

    // Watch for changes
    if (userEl) userEl.addEventListener('input', report);
    if (passEl) passEl.addEventListener('input', report);

    console.log('✅ Autofill complete');
    return true;
  }

  // Try immediately
  if (fillFields()) {
    return;
  }

  // If fields not found, wait for DOM
  var attempts = 0;
  var maxAttempts = 20;
  var interval = setInterval(function() {
    attempts++;
    console.log('🔄 Retry attempt', attempts);
    
    if (fillFields() || attempts >= maxAttempts) {
      clearInterval(interval);
      if (attempts >= maxAttempts) {
        console.log('❌ Failed to find fields after', attempts, 'attempts');
      }
    }
  }, 300);

  // Also try on DOMContentLoaded
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function() {
      console.log('📄 DOMContentLoaded fired');
      setTimeout(fillFields, 500);
    });
  }

})();
''';

    try {
      await controller.evaluateJavascript(source: script);
      print("✅ Script injected successfully");
    } catch (e) {
      print("❌ Failed to inject script: $e");
    }
  }

  /// Reset handler tracking (call when creating new WebView)
  static void resetHandlerTracking() {
    _handlerRegistered = false;
    print("🔄 Handler tracking reset");
  }
}
