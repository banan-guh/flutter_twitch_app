import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import '../twitch_config.dart';

class TwitchOAuth {
  static const _authorizeUrl = 'https://id.twitch.tv/oauth2/authorize';

  static String? lastError;
  static bool _flowInProgress = false;

  /// Starts the OAuth implicit grant flow.
  ///
  /// [onReady] is called with the Twitch authorization URL.
  /// Returns the access token, or null on failure/timeout.
  static Future<String?> startFlow({
    required void Function(String authUrl) onReady,
  }) async {
    if (_flowInProgress) {
      lastError = 'An authorization flow is already in progress.';
      return null;
    }
    _flowInProgress = true;

    final clientId = TwitchConfig.clientId;
    if (!TwitchConfig.isConfigured) {
      onReady('');
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

    onReady(authUrl);

    try {
      return await _listenForRedirect(state)
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

  static String _randomState() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static Future<String?> _listenForRedirect(String expectedState) async {
    final appLinks = AppLinks();
    final completer = Completer<String?>();
    StreamSubscription<Uri>? sub;

    sub = appLinks.uriLinkStream.listen((Uri uri) {
      if (uri.scheme != 'fluttertwitchapp' || uri.host != 'oauth-callback') {
        return;
      }

      final params = parseCallbackUri(uri);
      final token = params['access_token'];
      final state = params['state'];
      final error = params['error'];

      if (error != null) {
        lastError = 'Twitch returned: $error';
        if (!completer.isCompleted) completer.complete(null);
        return;
      }

      if (token != null) {
        if (state != expectedState) {
          lastError = 'CSRF: state mismatch';
          if (!completer.isCompleted) completer.complete(null);
          return;
        }
        if (!completer.isCompleted) completer.complete(token);
      }
    });

    try {
      return await completer.future;
    } finally {
      sub.cancel();
    }
  }

  @visibleForTesting
  static Map<String, String?> parseCallbackUri(Uri uri) {
    final params = <String, String?>{};

    if (uri.fragment.isNotEmpty) {
      final fragmentParams = Uri.splitQueryString(uri.fragment);
      params.addAll(fragmentParams);
    }

    if (uri.query.isNotEmpty) {
      params.addAll(uri.queryParameters);
    }

    return params;
  }
}
