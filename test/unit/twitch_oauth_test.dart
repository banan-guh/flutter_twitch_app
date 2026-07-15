import 'package:flutter_twitch_app/services/twitch_oauth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TwitchOAuth._parseCallbackUri', () {
    test('extracts access_token and state from fragment (implicit grant)', () {
      final uri = Uri.parse(
        'fluttertwitchapp://oauth-callback'
        '#access_token=testtoken123'
        '&state=abc123',
      );
      final params = TwitchOAuth.parseCallbackUri(uri);
      expect(params['access_token'], 'testtoken123');
      expect(params['state'], 'abc123');
    });

    test('extracts token and state from fragment with extra params', () {
      final uri = Uri.parse(
        'fluttertwitchapp://oauth-callback'
        '#access_token=token1'
        '&scope=chat%3Aread+chat%3Aedit'
        '&state=xyz'
        '&token_type=bearer',
      );
      final params = TwitchOAuth.parseCallbackUri(uri);
      expect(params['access_token'], 'token1');
      expect(params['state'], 'xyz');
      expect(params['token_type'], 'bearer');
    });

    test('extracts error from fragment', () {
      final uri = Uri.parse(
        'fluttertwitchapp://oauth-callback'
        '#error=access_denied&error_description=User+denied+access',
      );
      final params = TwitchOAuth.parseCallbackUri(uri);
      expect(params['error'], 'access_denied');
      expect(params['error_description'], 'User denied access');
    });

    test('falls back to query params when fragment is empty', () {
      final uri = Uri.parse(
        'fluttertwitchapp://oauth-callback'
        '?access_token=querytoken&state=xyz789',
      );
      final params = TwitchOAuth.parseCallbackUri(uri);
      expect(params['access_token'], 'querytoken');
      expect(params['state'], 'xyz789');
    });

    test('query params override fragment params when both present', () {
      final uri = Uri.parse(
        'fluttertwitchapp://oauth-callback'
        '?access_token=querytoken'
        '#access_token=fragmenttoken&state=s1',
      );
      final params = TwitchOAuth.parseCallbackUri(uri);
      expect(params['access_token'], 'querytoken');
      expect(params['state'], 's1');
    });

    test('error in query params', () {
      final uri = Uri.parse(
        'fluttertwitchapp://oauth-callback'
        '?error=access_denied&error_description=User+denied',
      );
      final params = TwitchOAuth.parseCallbackUri(uri);
      expect(params['error'], 'access_denied');
      expect(params['error_description'], 'User denied');
    });

    test('returns empty map for empty URI', () {
      final uri = Uri.parse('fluttertwitchapp://oauth-callback');
      final params = TwitchOAuth.parseCallbackUri(uri);
      expect(params, isEmpty);
    });

    test('returns empty map when no auth-related params present', () {
      final uri = Uri.parse('fluttertwitchapp://oauth-callback?foo=bar');
      final params = TwitchOAuth.parseCallbackUri(uri);
      expect(params['access_token'], isNull);
      expect(params['state'], isNull);
      expect(params['error'], isNull);
      expect(params['foo'], 'bar');
    });

    test('handles fragment with no params (empty fragment)', () {
      final uri = Uri.parse('fluttertwitchapp://oauth-callback#');
      final params = TwitchOAuth.parseCallbackUri(uri);
      expect(params, isEmpty);
    });
  });
}
