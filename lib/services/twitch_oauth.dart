import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import '../twitch_config.dart';
import '../widgets/login_webview.dart';

class TwitchOAuth {
  static const _authorizeUrl = 'https://id.twitch.tv/oauth2/authorize';

  static String? lastError;
  static bool _flowInProgress = false;

  /// Starts the OAuth implicit grant flow.
  ///
  /// Opens a full-screen WebView with the Twitch authorize page and intercepts
  /// the redirect to extract the access token from the URL fragment.
  /// Returns the access token, or null on failure/timeout.
  static Future<String?> startFlow(BuildContext context) async {
    if (_flowInProgress) {
      lastError = 'An authorization flow is already in progress.';
      return null;
    }
    _flowInProgress = true;

    final clientId = TwitchConfig.clientId;
    if (!TwitchConfig.isConfigured) {
      _flowInProgress = false;
      return null;
    }

    final redirectUri = TwitchConfig.redirectUri;

    final state = _randomState();
    final authUrl =
        '$_authorizeUrl'
        '?client_id=$clientId'
        '&redirect_uri=${Uri.encodeQueryComponent(redirectUri)}'
        '&response_type=token'
        '&scope=chat:read%20chat:edit%20user:read:chat%20user:write:chat%20user:manage:chat_color%20moderator:manage:banned_users%20moderator:manage:chat_messages%20moderator:manage:announcements%20moderator:manage:shoutouts'
        '&state=$state'
        '&force_verify=true';

    try {
      return await _openWebView(context, authUrl, state, redirectUri)
          .timeout(const Duration(minutes: 5));
    } on TimeoutException {
      lastError = 'Authorization timed out.';
      return null;
    } catch (e) {
      lastError = 'Authorization failed: $e';
      return null;
    } finally {
      _flowInProgress = false;
    }
  }

  static Future<String?> _openWebView(
    BuildContext context,
    String authUrl,
    String expectedState,
    String redirectUri,
  ) {
    final completer = Completer<String?>();

    Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => LoginWebView(
          authUrl: authUrl,
          expectedState: expectedState,
          redirectUri: redirectUri,
          onTokenResult: (token) {
            if (!completer.isCompleted) completer.complete(token);
          },
        ),
      ),
    );

    return completer.future;
  }

  static String _randomState() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Parses the fragment portion of a URL into key-value pairs.
  ///
  /// Used to extract OAuth params from the redirect URL fragment, e.g.:
  /// `https://example.com/callback#access_token=xxx&state=yyy`
  static Map<String, String?> parseFragment(String url) {
    final uri = Uri.parse(url);
    final fragment = uri.fragment;
    if (fragment.isEmpty) return {};
    return Uri.splitQueryString(fragment);
  }
}
