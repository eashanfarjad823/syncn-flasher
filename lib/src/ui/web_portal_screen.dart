import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'theme.dart';
import 'widgets.dart';

/// Shows the board's own configuration portal in an embedded browser.
///
/// The portal sits behind HTTP Basic auth. Credentials are prompted for and
/// passed straight through to that one request — the app never stores them,
/// because the shipped defaults are already recoverable from the firmware and
/// baking them into the client would make that worse.
class WebPortalScreen extends StatefulWidget {
  const WebPortalScreen({super.key, required this.ip});

  final String ip;

  @override
  State<WebPortalScreen> createState() => _WebPortalScreenState();
}

class _WebPortalScreenState extends State<WebPortalScreen> {
  late final WebViewController _controller;
  int _progress = 0;
  String? _error;

  String get _url => 'http://${widget.ip}/';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) => setState(() => _progress = p),
          onPageFinished: (_) => setState(() => _progress = 100),
          onWebResourceError: (e) {
            // Sub-resource failures are noise; only report the main document.
            if (e.isForMainFrame ?? true) {
              setState(() => _error = e.description);
            }
          },
          onHttpAuthRequest: _promptForCredentials,
        ),
      )
      ..loadRequest(Uri.parse(_url));
  }

  Future<void> _promptForCredentials(HttpAuthRequest request) async {
    final userCtl = TextEditingController();
    final passCtl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign in to the device'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              request.realm?.isNotEmpty == true
                  ? '${request.host} — ${request.realm}'
                  : request.host,
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: userCtl,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Username'),
            ),
            TextField(
              controller: passCtl,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign in'),
          ),
        ],
      ),
    );

    if (ok == true) {
      request.onProceed(
        WebViewCredential(user: userCtl.text, password: passCtl.text),
      );
    } else {
      request.onCancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = SyncnPalette.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Device portal'),
        bottom: _progress < 100
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                  value: _progress / 100,
                  minHeight: 2,
                ),
              )
            : null,
        actions: [
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () {
              setState(() {
                _error = null;
                _progress = 0;
              });
              _controller.reload();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Row(
                children: [
                  Icon(Icons.lan_rounded, size: 14, color: p.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _url,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: p.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                child: AdviceBanner(
                  tone: AdviceTone.danger,
                  message: 'Could not load the device page.',
                  advice: 'Make sure this phone is on the same Wi-Fi network as '
                      'the board, then reload. ($_error)',
                ),
              ),
            Expanded(child: WebViewWidget(controller: _controller)),
          ],
        ),
      ),
    );
  }
}
