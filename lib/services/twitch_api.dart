import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../twitch_config.dart';
import 'twitch_auth.dart';

class TwitchApi {
  static const _base = 'https://api.twitch.tv/helix';

  static String? _lastError;

  static String? get lastError => _lastError;

  static http.Client _client = http.Client();

  @visibleForTesting
  static set client(http.Client c) => _client = c;

  static Future<String?> getUserId(TwitchAuth auth, String login) async {
    _lastError = null;
    final uri = Uri.parse('$_base/users?login=$login');
    final res = await _client.get(uri, headers: _headers(auth));
    if (res.statusCode != 200) {
      _setError('getUserId', res);
      return null;
    }
    final data = jsonDecode(res.body) as Map;
    final list = data['data'] as List;
    if (list.isEmpty) {
      _setError('User "$login" not found');
      return null;
    }
    return list[0]['id'] as String;
  }

  /// Returns `{'id': ..., 'login': ...}` for the authenticated user.
  static Future<Map<String, String>?> getCurrentUser(TwitchAuth auth) async {
    _lastError = null;
    final uri = Uri.parse('$_base/users');
    final res = await _client.get(uri, headers: _headers(auth));
    if (res.statusCode != 200) {
      _setError('getCurrentUser', res);
      return null;
    }
    final data = jsonDecode(res.body) as Map;
    final list = data['data'] as List;
    if (list.isEmpty) {
      _setError('No user associated with token');
      return null;
    }
    return {
      'id': list[0]['id'] as String,
      'login': list[0]['login'] as String,
    };
  }

  static Future<String?> getUserChatColor(TwitchAuth auth, String userId) async {
    _lastError = null;
    final uri = Uri.parse('$_base/chat/color?user_id=$userId');
    final res = await _client.get(uri, headers: _headers(auth));
    if (res.statusCode != 200) {
      _setError('getUserChatColor', res);
      return null;
    }
    final data = jsonDecode(res.body) as Map;
    final list = data['data'] as List;
    if (list.isEmpty) return null;
    return list[0]['color'] as String?;
  }

  static Future<bool> createSubscription({
    required TwitchAuth auth,
    required String sessionId,
    required String broadcasterUserId,
    required String userId,
  }) async {
    _lastError = null;
    final uri = Uri.parse('$_base/eventsub/subscriptions');
    final body = jsonEncode({
      'type': 'channel.chat.message',
      'version': '1',
      'condition': {
        'broadcaster_user_id': broadcasterUserId,
        'user_id': userId,
      },
      'transport': {
        'method': 'websocket',
        'session_id': sessionId,
      },
    });
    final res = await _client.post(uri, headers: _headers(auth), body: body);
    if (res.statusCode == 409) return true;
    if (res.statusCode != 202) {
      _setError('createSubscription', res);
      return false;
    }
    return true;
  }

  static Future<bool> createDeleteSubscription({
    required TwitchAuth auth,
    required String sessionId,
    required String broadcasterUserId,
    required String userId,
  }) async {
    _lastError = null;
    final uri = Uri.parse('$_base/eventsub/subscriptions');
    final body = jsonEncode({
      'type': 'channel.chat.message_delete',
      'version': '1',
      'condition': {
        'broadcaster_user_id': broadcasterUserId,
        'user_id': userId,
      },
      'transport': {
        'method': 'websocket',
        'session_id': sessionId,
      },
    });
    final res = await _client.post(uri, headers: _headers(auth), body: body);
    if (res.statusCode == 409) return true;
    if (res.statusCode != 202) {
      _setError('createDeleteSubscription', res);
      return false;
    }
    return true;
  }

  /// Returns chat settings for a broadcaster.
  /// Keys: slow_mode, follower_mode, subscriber_mode, emote_mode, etc.
  static Future<Map<String, dynamic>?> getChatSettings(TwitchAuth auth, String broadcasterId, String moderatorId) async {
    _lastError = null;
    final uri = Uri.parse('$_base/chat/settings?broadcaster_id=$broadcasterId&moderator_id=$moderatorId');
    final res = await _client.get(uri, headers: _headers(auth));
    if (res.statusCode != 200) {
      _setError('getChatSettings', res);
      return null;
    }
    final data = jsonDecode(res.body) as Map;
    final list = data['data'] as List;
    if (list.isEmpty) return null;
    return list[0] as Map<String, dynamic>;
  }

  /// Returns stream info for a broadcaster.
  /// Keys: type, viewer_count, started_at (null if offline).
  static Future<Map<String, dynamic>?> getStreamInfo(TwitchAuth auth, String broadcasterId) async {
    _lastError = null;
    final uri = Uri.parse('$_base/streams?user_id=$broadcasterId');
    final res = await _client.get(uri, headers: _headers(auth));
    if (res.statusCode != 200) {
      _setError('getStreamInfo', res);
      return null;
    }
    final data = jsonDecode(res.body) as Map;
    final list = data['data'] as List;
    if (list.isEmpty) return null;
    return list[0] as Map<String, dynamic>;
  }

  static Map<String, String> _headers(TwitchAuth auth) => {
        'Client-ID': TwitchConfig.clientId,
        'Authorization': 'Bearer ${auth.accessToken ?? ''}',
        'Content-Type': 'application/json',
      };

  /// Returns full user profile for a given login.
  /// Keys: id, login, display_name, description, profile_image_url, created_at, broadcaster_type.
  static Future<Map<String, dynamic>?> getUserProfile(TwitchAuth auth, String login) async {
    _lastError = null;
    final uri = Uri.parse('$_base/users?login=$login');
    final res = await _client.get(uri, headers: _headers(auth));
    if (res.statusCode != 200) {
      _setError('getUserProfile', res);
      return null;
    }
    final data = jsonDecode(res.body) as Map;
    final list = data['data'] as List;
    if (list.isEmpty) {
      _setError('User "$login" not found');
      return null;
    }
    return list[0] as Map<String, dynamic>;
  }

  /// Blocks a user by ID. Requires user:manage:blocks scope.
  static Future<bool> blockUser(TwitchAuth auth, String targetUserId) async {
    _lastError = null;
    final uri = Uri.parse('$_base/users/blocks?target_user_id=$targetUserId');
    final res = await _client.put(uri, headers: _headers(auth));
    if (res.statusCode == 204) return true;
    _setError('blockUser', res);
    return false;
  }

  /// Reports a user. Requires moderation:read scope.
  static Future<bool> reportUser(TwitchAuth auth, {required String userId, required String broadcasterId, String reason = ''}) async {
    _lastError = null;
    final uri = Uri.parse('$_base/moderation/reports');
    final body = jsonEncode({
      'data': {
        'user_id': userId,
        'broadcaster_id': broadcasterId,
        'reason': reason,
      },
    });
    final res = await _client.post(uri, headers: _headers(auth), body: body);
    if (res.statusCode == 204) return true;
    _setError('reportUser', res);
    return false;
  }

  static void _setError(String label, [http.Response? res]) {
    if (res != null) {
      _lastError = '$label failed (${res.statusCode}): ${res.body}';
    } else {
      _lastError = label;
    }
  }
}
