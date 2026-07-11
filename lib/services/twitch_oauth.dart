import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import '../twitch_config.dart';

class TwitchOAuth {
  static const _authorizeUrl = 'https://id.twitch.tv/oauth2/authorize';
  static const _localPort = 17563;

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

    late final HttpServer server;
    try {
      server = await HttpServer.bind('127.0.0.1', _localPort);
    } catch (e) {
      lastError = 'Failed to start local server: $e';
      _flowInProgress = false;
      return null;
    }

    final redirectUri = 'http://localhost:$_localPort/';

    final state = _randomState();
    final authUrl = '$_authorizeUrl'
        '?client_id=$clientId'
        '&redirect_uri=${Uri.encodeQueryComponent(redirectUri)}'
        '&response_type=token'
        '&scope=chat:read%20chat:edit%20user:read:chat'
        '&state=$state'
        '&force_verify=true';

    onReady(authUrl);

    try {
      return await _listen(server, state).timeout(const Duration(minutes: 5));
    } on TimeoutException {
      return null;
    } catch (e) {
      lastError = 'Authorization failed: $e';
      return null;
    } finally {
      _flowInProgress = false;
      try {
        await server.close();
      } catch (_) {}
    }
  }

  static String _randomState() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static Future<String?> _listen(HttpServer server, String expectedState) async {
    await for (final request in server) {
      if (request.uri.path == '/token') {
        final token = request.uri.queryParameters['access_token'];
        final state = request.uri.queryParameters['state'];
        await _respond(request, 200, 'OK');

        if (token != null) {
          if (state != expectedState) {
            lastError = 'CSRF: state mismatch';
            return null;
          }
          return token;
        }
        lastError = 'No token in callback';
        return null;
      }

      final error = request.uri.queryParameters['error'];
      if (error != null) {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
            '<h2>Authorization denied.</h2><p>$error</p><p>You can close this tab.</p>');
        await request.response.close();
        lastError = 'Twitch returned: $error';
        return null;
      }

      request.response.headers.contentType = ContentType.html;
      request.response.write(_redirectPage);
      await request.response.close();
    }
    return null;
  }

  static Future<void> _respond(
      HttpRequest request, int status, String body) async {
    request.response.statusCode = status;
    request.response.write(body);
    await request.response.close();
  }

  static const _redirectPage = '''
<!DOCTYPE html>
<html>
<body>
<script>
var hash = window.location.hash.substring(1);
var params = new URLSearchParams(hash);
var token = params.get('access_token');
var error = params.get('error');
var state = params.get('state');
if (token && state) {
  fetch('/token?access_token=' + encodeURIComponent(token) + '&state=' + encodeURIComponent(state));
  document.body.innerHTML = '<h2>Authorized!</h2><p>You can close this tab.</p>';
} else if (error) {
  document.body.innerHTML = '<h2>Authorization denied: ' + error + '</h2><p>You can close this tab.</p>';
  fetch('/token');
} else {
  document.body.innerHTML = '<h2>Waiting for authorization...</h2>';
  fetch('/token');
}
</script>
</body>
</html>
''';
}
