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

  static Future<Map<String, List<GenericEmote>>> fetchEmoteSets(
    List<String> setIds, {
    String? accessToken,
  }) async {
    final result = <String, List<GenericEmote>>{};
    for (var i = 0; i < setIds.length; i += 25) {
      final batch = setIds.sublist(i, (i + 25).clamp(0, setIds.length));
      final params = batch.map((id) => 'emote_set_id=$id').join('&');
      final uri = Uri.parse(
        'https://api.twitch.tv/helix/chat/emotes/set?$params',
      );
      final headers = <String, String>{'Client-ID': TwitchConfig.clientId};
      if (accessToken != null) {
        headers['Authorization'] = 'Bearer $accessToken';
      }
      final res = await http.get(uri, headers: headers);
      debugPrint(
        'Twitch emote sets (${batch.length} sets): ${res.statusCode} — ${res.body.length} bytes',
      );
      if (res.statusCode != 200) {
        debugPrint('Twitch emote sets error body: ${res.body}');
        continue;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final items = data['data'] as List<dynamic>? ?? [];
      for (final item in items) {
        final id = item['id'] as String?;
        final name = item['name'] as String?;
        final ownerId = item['owner_id'] as String?;
        if (id == null || name == null || ownerId == null) continue;
        final format =
            (item['images'] as Map<String, dynamic>?)?['url_4x'] as String? ??
            (item['images'] as Map<String, dynamic>?)?['url_2x'] as String? ??
            (item['images'] as Map<String, dynamic>?)?['url_1x'] as String?;
        if (format == null) continue;
        final tier = item['tier'] as String?;
        result.putIfAbsent(ownerId, () => []).add(
          GenericEmote(
            id: id,
            code: name,
            type: EmoteType.twitch,
            url: format,
            scope: EmoteScope.channel,
            tier: tier,
          ),
        );
      }
    }
    debugPrint('Twitch emote sets: ${result.length} owners');
    return result;
  }

  static Future<List<GenericEmote>> fetchChannel(
    String broadcasterId, {
    String? accessToken,
    String? channelName,
  }) async {
    final uri = Uri.parse(
      'https://api.twitch.tv/helix/chat/emotes?broadcaster_id=$broadcasterId',
    );
    final headers = <String, String>{'Client-ID': TwitchConfig.clientId};
    final hasToken = accessToken != null;
    if (hasToken) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    final res = await http.get(uri, headers: headers);
    debugPrint(
      'Twitch channel emotes ($broadcasterId) hasToken=$hasToken: ${res.statusCode} — ${res.body.length} bytes',
    );
    debugPrint('Twitch channel body: ${res.body}');
    if (res.statusCode != 200) return [];
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return _parseEmotes(
      data['data'] as List<dynamic>? ?? [],
      channel: true,
      channelName: channelName,
    );
  }

  static List<GenericEmote> _parseEmotes(
    List<dynamic> items, {
    bool channel = false,
    String? channelName,
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
      final tier = item['tier'] as String?;
      emotes.add(
        GenericEmote(
          id: id,
          code: name,
          type: EmoteType.twitch,
          url: format,
          scope: channel ? EmoteScope.channel : EmoteScope.global,
          tier: tier,
          ownerChannel: channel ? channelName : null,
        ),
      );
    }
    debugPrint('Twitch parsed ${emotes.length} emotes');
    if (channel) {
      for (final e in emotes) {
        debugPrint('  Twitch emote: ${e.code} id=${e.id} tier=${e.tier}');
      }
    }
    return emotes;
  }
}
