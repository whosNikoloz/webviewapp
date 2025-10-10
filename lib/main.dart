import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webviewapp/credentials_persistence.dart';

import 'cookie_persistence.dart';
import 'storage_persistence.dart';

const String kRootHost = "beauty.fina24.ge";
const String kInitialUrl = "https://$kRootHost";
const String kMedicalUrl = "https://$kRootHost/Medical";

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "ჩემი ვებაპი",
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const WebAppPage(),
    );
  }
}

class WebAppPage extends StatefulWidget {
  const WebAppPage({super.key});
  @override
  State<WebAppPage> createState() => _WebAppPageState();
}

class _WebAppPageState extends State<WebAppPage> {
  final GlobalKey webKey = GlobalKey();
  InAppWebViewController? ctrl;
  PullToRefreshController? ptr;

  double progress = 0;
  double _lastProgressBucket = 0;

  bool _medicalTried = false;
  bool _justLoggedInProbe = false;

  @override
  void initState() {
    super.initState();
    CredentialsPersistence.resetHandlerTracking();
    ptr = PullToRefreshController(
      settings: PullToRefreshSettings(color: Colors.blue),
      onRefresh: () async {
        if (Platform.isAndroid) {
          await ctrl?.reload();
        } else {
          final u = await ctrl?.getUrl();
          if (u != null) await ctrl?.loadUrl(urlRequest: URLRequest(url: u));
        }
      },
    );
  }

  Future<bool> _looksLoggedIn() async {
    if (ctrl == null) return false;

    final cookies = await CookieManager.instance().getCookies(
      url: WebUri("https://beauty.fina24.ge"),
    );
    final hasAspNetAuthCookie = cookies.any(
      (c) =>
          c.name == '.AspNetCore.Identity.Application' ||
          c.name == '.AspNetCore.Cookies',
    );

    if (hasAspNetAuthCookie) return true;

    final js = r'''
    (function(){
      try {
        const hasToken =
          ['access_token','token','jwt','refresh_token','id_token']
            .some(k => !!localStorage.getItem(k) || !!sessionStorage.getItem(k));
        return !!hasToken;
      } catch(e){ return false; }
    })();
  ''';
    final res = await ctrl!.evaluateJavascript(source: js);
    return res == true;
  }

  bool _isLoginUrl(Uri u) {
    final path = u.path.toLowerCase();
    // Check for common login page paths
    if (path.contains('login') ||
        path.contains('account/login') ||
        path.contains('auth')) {
      return true;
    }

    // For beauty.fina24.ge, /Default is the login page when not logged in
    if (u.host == kRootHost && path == '/default') {
      return true;
    }

    return false;
  }

  bool _isLogoutUrl(Uri u) {
    final path = u.path.toLowerCase();
    return path.contains('logout') ||
        path.contains('signout') ||
        path.contains('account/logout');
  }

  bool _isMedicalUrl(Uri u) {
    return (u.host == kRootHost) && (u.path == '/Medical');
  }

  Future<void> _goMedicalOnce() async {
    if (_medicalTried) return;
    _medicalTried = true;
    await ctrl?.loadUrl(urlRequest: URLRequest(url: WebUri(kMedicalUrl)));
  }

  Future<bool> _maybeLaunchExternal(Uri url) async {
    // external schemes → open outside
    const externalSchemes = {
      "tel",
      "mailto",
      "whatsapp",
      "tg",
      "viber",
      "sms",
      "intent",
    };
    if (externalSchemes.contains(url.scheme)) {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final settings = InAppWebViewSettings(
      // Perf & rendering
      javaScriptEnabled: true,
      allowsInlineMediaPlayback: true,
      mediaPlaybackRequiresUserGesture: false,
      transparentBackground: false,
      useHybridComposition: true,

      // Storage / auth
      cacheEnabled: true,
      domStorageEnabled: true,
      databaseEnabled: true,
      sharedCookiesEnabled: true,
      thirdPartyCookiesEnabled: true,
      clearSessionCache: false,
      incognito: false,

      // UX
      supportMultipleWindows: true,
      useWideViewPort: true,
      builtInZoomControls: false,
      supportZoom: false,
      disableContextMenu: true,
      allowsBackForwardNavigationGestures: true,
    );

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            InAppWebView(
              key: webKey,
              initialSettings: settings,
              pullToRefreshController: ptr,

              // === FIRST-TIME LOAD: restore everything, then try /Medical ===
              onWebViewCreated: (c) async {
                ctrl = c;

                // Restore COOKIES for all saved domains BEFORE any load:
                await CookiePersistence.restoreAll(scheme: "https");

                // Prime local/session storage AT_DOCUMENT_START for initial origin:
                await StoragePersistence.restoreAtDocumentStart(
                  ctrl!,
                  Uri.parse(kInitialUrl),
                );

                // Try to go straight to /Medical (server will redirect to login if needed)
                await ctrl!.loadUrl(
                  urlRequest: URLRequest(url: WebUri(kMedicalUrl)),
                );
              },

              // === Ensure storage is primed BEFORE every navigation target ===
              shouldOverrideUrlLoading: (c, nav) async {
                final u = nav.request.url;
                if (u == null) return NavigationActionPolicy.ALLOW;

                // External schemes -> open outside
                if (await _maybeLaunchExternal(Uri.parse(u.toString()))) {
                  return NavigationActionPolicy.CANCEL;
                }

                // Prime storage for the NEXT origin at document start
                await StoragePersistence.restoreAtDocumentStart(
                  c,
                  Uri.parse(u.toString()),
                );
                return NavigationActionPolicy.ALLOW;
              },

              // === Handle window.open/popups inside the same WebView ===
              onCreateWindow: (c, req) async {
                final u = req.request.url;
                if (u != null) {
                  // Prime storage for the popup target, then open in same WebView
                  await StoragePersistence.restoreAtDocumentStart(
                    c,
                    Uri.parse(u.toString()),
                  );
                  await c.loadUrl(urlRequest: URLRequest(url: u));
                }
                return true;
              },

              // === Save cookies & storage after each top-level navigation ===
              onLoadStop: (c, url) async {
                ptr?.endRefreshing();
                if (url == null) return;

                final u = Uri.parse(url.toString());

                // Persist current state
                await CookiePersistence.saveForUrl(u);
                await StoragePersistence.save(WebUri(u.toString()), c);

                // Handle logout - DON'T clear credentials, they should persist
                // Only the session cookies/storage are cleared by the server
                if (_isLogoutUrl(u)) {
                  // Reset the medical tried flag so user can navigate after re-login
                  _medicalTried = false;
                  _justLoggedInProbe = false;
                  // Note: We keep credentials saved for easier re-login
                  return;
                }

                // Login detection logic
                if (_isLoginUrl(u)) {
                  // Wait a bit for the page to fully render
                  await Future.delayed(Duration(milliseconds: 500));

                  // Inject autofill + capture on login pages
                  await CredentialsPersistence.injectAutofillAndCaptureJS(c, u);

                  // we are on login page; allow user to login and then one-shot try /Medical
                  _medicalTried = false;
                  _justLoggedInProbe = true;
                  return;
                }

                // Already at /Medical -> done
                if (_isMedicalUrl(u)) {
                  return;
                }

                // Not on login and not /Medical:
                // If looks logged-in or we just finished login, go to /Medical once
                final logged = await _looksLoggedIn();

                if ((logged || _justLoggedInProbe) && !_medicalTried) {
                  _justLoggedInProbe = false;
                  await _goMedicalOnce();
                }
              },
              onReceivedError: (c, req, err) => ptr?.endRefreshing(),

              onProgressChanged: (c, p) {
                if (p == 100) ptr?.endRefreshing();
                final bucket = (p / 10).floorToDouble();
                if (bucket != _lastProgressBucket || p == 100) {
                  _lastProgressBucket = bucket;
                  setState(() => progress = p / 100.0);
                }
              },
            ),

            if (progress < 1.0)
              Align(
                alignment: Alignment.topCenter,
                child: LinearProgressIndicator(value: progress),
              ),
          ],
        ),
      ),
    );
  }
}
