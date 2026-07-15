import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/twitch_oauth.dart';

class LoginWebView extends StatefulWidget {
  final String authUrl;
  final String expectedState;
  final String redirectUri;
  final ValueChanged<String?> onTokenResult;

  const LoginWebView({
    super.key,
    required this.authUrl,
    required this.expectedState,
    required this.redirectUri,
    required this.onTokenResult,
  });

  @override
  State<LoginWebView> createState() => _LoginWebViewState();
}

class _LoginWebViewState extends State<LoginWebView> {
  bool _isLoading = true;
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          if (mounted) setState(() => _isLoading = true);
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _isLoading = false);
        },
        onNavigationRequest: (request) {
          if (_isRedirect(request.url)) {
            _extractToken(request.url);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(Uri.parse(widget.authUrl));
  }

  bool _isRedirect(String url) {
    return url.startsWith(widget.redirectUri);
  }

  void _extractToken(String url) {
    final params = TwitchOAuth.parseFragment(url);
    final error = params['error'];
    final token = params['access_token'];
    final state = params['state'];

    if (error != null) {
      TwitchOAuth.lastError = 'Twitch returned: $error';
      widget.onTokenResult(null);
      Navigator.pop(context);
      return;
    }

    if (token != null) {
      if (state != widget.expectedState) {
        TwitchOAuth.lastError = 'CSRF: state mismatch';
        widget.onTokenResult(null);
        Navigator.pop(context);
        return;
      }
      widget.onTokenResult(token);
      Navigator.pop(context);
      return;
    }

    // URL matched redirectUri but had neither token nor error — ignore
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Twitch Login'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            widget.onTokenResult(null);
            Navigator.pop(context);
          },
        ),
      ),
      body: Column(
        children: [
          if (_isLoading)
            const LinearProgressIndicator(),
          Expanded(
            child: WebViewWidget(controller: _controller),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
}
