import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../twitch_config.dart';
import '../../models/generic_emote.dart';

class TwitchEmoteProvider {
  static Future<List<GenericEmote>> fetchGlobal({String? accessToken}) async {
    final uri = Uri.parse('https://api.twitch.tv/helix/chat/emotes/global');
    final headers = <String, String>{'Client-ID': TwitchConfig.clientId};
    if (accessToken != null) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    final res = await http.get(uri, headers: headers);
    debugPrint(
      'Twitch global emotes: ${res.statusCode} — ${res.body.length} bytes',
    );
    if (res.statusCode != 200) return [];
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return _parseEmotes(data['data'] as List<dynamic>? ?? []);
  }

  static Future<List<GenericEmote>> fetchChannel(
    String broadcasterId, {
    String? accessToken,
  }) async {
    final uri = Uri.parse(
      'https://api.twitch.tv/helix/chat/emotes?broadcaster_id=$broadcasterId',
    );
    final headers = <String, String>{'Client-ID': TwitchConfig.clientId};
    if (accessToken != null) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    final res = await http.get(uri, headers: headers);
    debugPrint(
      'Twitch channel emotes ($broadcasterId): ${res.statusCode} — ${res.body.length} bytes',
    );
    debugPrint('Twitch channel body: ${res.body}');
    if (res.statusCode != 200) return [];
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return _parseEmotes(data['data'] as List<dynamic>? ?? [], channel: true);
  }

  static List<GenericEmote> _parseEmotes(
    List<dynamic> items, {
    bool channel = false,
  }) {
    final emotes = <GenericEmote>[];
    for (final item in items) {
      final id = item['id'] as String?;
      final name = item['name'] as String?;
      if (id == null || name == null) continue;
      final format =
          (item['images'] as Map<String, dynamic>?)?['url_4x'] as String? ??
          (item['images'] as Map<String, dynamic>?)?['url_2x'] as String? ??
          (item['images'] as Map<String, dynamic>?)?['url_1x'] as String?;
      if (format == null) continue;
      emotes.add(
        GenericEmote(
          id: id,
          code: name,
          type: EmoteType.twitch,
          url: format,
          scope: channel ? EmoteScope.channel : EmoteScope.global,
        ),
      );
    }
    debugPrint('Twitch parsed ${emotes.length} emotes');
    return emotes;
  }
}
