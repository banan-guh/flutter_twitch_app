/// Twitch application credentials.
///
/// 1. Go to https://dev.twitch.tv/console/apps
/// 2. Create a new application (Client Type: Public)
/// 3. Set "OAuth Redirect URL" to: fluttertwitchapp://oauth-callback
/// 4. Copy the Client ID below
///
/// If your app requires a client secret (Confidential), also set [clientSecret].
class TwitchConfig {
  static const String clientId = 'hn6tq8xvgzx91n4mx72573o1c2x9nk';

  /// Leave empty for Public apps. Set only if Twitch requires it.
  static const String clientSecret = '';

  /// Custom URL scheme redirect URI for the OAuth flow.
  static const String redirectUri = 'fluttertwitchapp://oauth-callback';

  static bool get isConfigured =>
      clientId.isNotEmpty && clientId != 'YOUR_CLIENT_ID_HERE';
}
