import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/twitch_message.dart';
import '../color_utils.dart';

class RecentMessagesService {
  static const _baseUrl = 'https://recent-messages.robotty.de/api/v2/recent-messages';

  Future<List<TwitchMessage>> fetchRecent(String channel) async {
    try {
      final uri = Uri.parse('$_baseUrl/${Uri.encodeComponent(channel.toLowerCase())}?limit=100');
      final res = await http.get(uri).timeout(const Duration(seconds: 10));

      if (res.statusCode != 200) return [];

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final rawMessages = body['messages'] as List<dynamic>?;
      if (rawMessages == null || rawMessages.isEmpty) return [];

      final messages = <TwitchMessage>[];
      for (final raw in rawMessages) {
        final parsed = parseIrcLine(raw as String, channel: channel);
        if (parsed != null) messages.add(parsed);
      }

      messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return messages;
    } catch (e, s) {
      debugPrint('recent-messages error: $e\n$s');
      return [];
    }
  }

  static TwitchMessage? parseIrcLine(String raw, {String? channel}) {
    String? tagsPart;

    int idx = 0;
    if (raw.startsWith('@')) {
      final space = raw.indexOf(' ');
      if (space == -1) return null;
      tagsPart = raw.substring(1, space);
      idx = space + 1;
    }

    if (idx >= raw.length || raw[idx] != ':') return null;
    final sourceEnd = raw.indexOf(' ', idx);
    if (sourceEnd == -1) return null;
    idx = sourceEnd + 1;

    final cmdEnd = raw.indexOf(' ', idx);
    if (cmdEnd == -1) return null;
    final command = raw.substring(idx, cmdEnd);
    if (command != 'PRIVMSG') return null;
    idx = cmdEnd + 1;

    final targetEnd = raw.indexOf(' ', idx);
    if (targetEnd == -1) return null;
    idx = targetEnd + 1;

    if (idx >= raw.length || raw[idx] != ':') return null;
    final text = raw.substring(idx + 1);

    final tags = _parseTags(tagsPart ?? '');
    final username = tags['display-name'] ?? '';
    final color = tags['color'];
    final tsMs = tags['rm-received-ts'];
    final messageId = tags['id'];

    String? replyParentId;
    String? replyUser;
    String? replyText;
    String displayText = text;
    if (tags.containsKey('reply-parent-msg-id')) {
      replyParentId = tags['reply-parent-msg-id'];
      replyUser = tags['reply-parent-display-name'];
      replyText = tags['reply-parent-msg-body'] != null
          ? (_unescapeIrcTag(_tryDecodeUri(tags['reply-parent-msg-body']!)))
          : null;
      if (replyUser != null) {
        final prefix = '@$replyUser ';
        if (displayText.startsWith(RegExp('^${RegExp.escape(prefix)}', caseSensitive: false))) {
          displayText = displayText.substring(prefix.length);
        }
      }
    }

    if (username.isEmpty && displayText.isEmpty) return null;

    final ts = tsMs != null
        ? DateTime.fromMillisecondsSinceEpoch(int.tryParse(tsMs) ?? 0)
        : DateTime.now();

    final effectiveColor = (color != null && color.isNotEmpty)
        ? color
        : pickColor(username);

    return TwitchMessage(
      username: username,
      text: displayText,
      color: effectiveColor,
      timestamp: ts,
      messageId: messageId,
      channel: channel,
      isHistory: true,
      replyToParentId: replyParentId,
      replyToUser: replyUser,
      replyToText: replyText,
    );
  }

  static String _tryDecodeUri(String raw) {
    try {
      return Uri.decodeComponent(raw);
    } catch (_) {
      return raw;
    }
  }

  static String _unescapeIrcTag(String raw) {
    return raw
        .replaceAll('\\s', ' ')
        .replaceAll('\\\\', '\\')
        .replaceAll('\\:', ';')
        .replaceAll('\\r', '\r')
        .replaceAll('\\n', '\n');
  }

  static Map<String, String> _parseTags(String tagsStr) {
    if (tagsStr.isEmpty) return {};
    final tags = <String, String>{};
    for (final pair in tagsStr.split(';')) {
      final eq = pair.indexOf('=');
      if (eq == -1) continue;
      tags[pair.substring(0, eq)] = pair.substring(eq + 1);
    }
    return tags;
  }
}
