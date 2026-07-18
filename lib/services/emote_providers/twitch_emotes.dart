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

  static Future<Map<String, List<GenericEmote>>> fetchUserEmotes({
    required String userId,
    String? accessToken,
  }) async {
    final result = <String, List<GenericEmote>>{};
    String? cursor;
    var page = 0;
    do {
      page++;
      final paramStr = cursor != null ? '&after=$cursor' : '';
      final uri = Uri.parse(
        'https://api.twitch.tv/helix/chat/emotes/user?user_id=$userId$paramStr',
      );
      final headers = <String, String>{'Client-ID': TwitchConfig.clientId};
      if (accessToken != null) {
        headers['Authorization'] = 'Bearer $accessToken';
      }
      final res = await http.get(uri, headers: headers);
      if (res.statusCode != 200) {
        debugPrint('Twitch user emotes error: ${res.statusCode} ${res.body}');
        return {};
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final items = data['data'] as List<dynamic>? ?? [];
      final pagination = data['pagination'] as Map<String, dynamic>?;
      cursor = pagination?['cursor'] as String?;
      for (final item in items) {
        final id = item['id'] as String?;
        final name = item['name'] as String?;
        final ownerId = item['owner_id'] as String?;
        final emoteType = item['emote_type'] as String?;
        if (id == null || name == null) continue;
        final format =
            (item['format'] as List<dynamic>?)?.firstOrNull as String?;
        final scale =
            (item['scale'] as List<dynamic>?)?.lastOrNull as String? ?? '3.0';
        final theme = (item['theme_mode'] as List<dynamic>?)
                ?.firstOrNull as String? ??
            'dark';
        final url =
            'https://static-cdn.jtvnw.net/emoticons/v2/$id/${format ?? 'static'}/$theme/$scale';
        result.putIfAbsent(ownerId ?? '', () => []).add(
          GenericEmote(
            id: id,
            code: name,
            type: EmoteType.twitch,
            url: url,
            scope: ownerId != null && ownerId.isNotEmpty
                ? EmoteScope.channel
                : EmoteScope.global,
            tier: item['tier'] as String?,
            emoteType: emoteType,
          ),
        );
      }
    } while (cursor != null && cursor.isNotEmpty);
    debugPrint(
      'Twitch user emotes total: ${result.length} owners, '
      '${result.values.fold<int>(0, (s, l) => s + l.length)} emotes, '
      '$page pages',
    );
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
    if (accessToken != null) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    final res = await http.get(uri, headers: headers);
    if (res.statusCode != 200) {
      debugPrint('Twitch channel emotes error: ${res.statusCode}');
      return [];
    }
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
    return emotes;
  }
}
