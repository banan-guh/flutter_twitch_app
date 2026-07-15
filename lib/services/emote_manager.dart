import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/generic_emote.dart';
import 'emote_providers/twitch_emotes.dart';
import 'emote_providers/bttv_emotes.dart';
import 'emote_providers/ffz_emotes.dart';
import 'emote_providers/seven_tv_emotes.dart';

class ChannelEmotes {
  final Map<String, GenericEmote> byCode;
  final List<GenericEmote> suggestions;

  ChannelEmotes({required this.byCode, required this.suggestions});
}

class EmoteManager extends ChangeNotifier {
  static const _globalTtl = Duration(hours: 24);
  static const _channelTtl = Duration(hours: 1);
  static const _providerPriority = {
    EmoteType.sevenTv: 0,
    EmoteType.bttv: 1,
    EmoteType.ffz: 2,
    EmoteType.twitch: 3,
  };

  ChannelEmotes? _globalCache;
  final _channelCaches = <String, ChannelEmotes>{};
  final _channelFetchTimes = <String, DateTime>{};
  final _lastErrors = <String, String>{};
  String? _accessToken;

  set accessToken(String? value) => _accessToken = value;

  String? get fetchError {
    if (_lastErrors.isEmpty) return null;
    return _lastErrors.entries.map((e) => '${e.key}: ${e.value}').join('; ');
  }

  ChannelEmotes? byCode(String channel) {
    final channelEmotes = _channelCaches[channel];
    if (channelEmotes == null) return _globalCache;
    if (_globalCache == null) return channelEmotes;
    final merged = {..._globalCache!.byCode, ...channelEmotes.byCode};
    final suggestions = merged.values.toList()
      ..sort((a, b) => a.code.compareTo(b.code));
    return ChannelEmotes(byCode: merged, suggestions: suggestions);
  }

  Future<void> preloadGlobalEmotes() async {
    if (_globalCache != null) return;
    final cached = await _loadFromPrefs('emotes2_global', _globalTtl);
    if (cached != null) {
      _globalCache = cached;
      notifyListeners();
    }
    final emotes = await _fetchAllGlobal();
    _globalCache = _buildChannelMap(emotes);
    await _saveToPrefs('emotes2_global', _globalCache!, _globalTtl);
    notifyListeners();
  }

  Future<void> resolveEmotes(String channel, String? broadcasterId) async {
    _lastErrors.clear();
    final cached = await _loadFromPrefs(
      'emotes2_$channel',
      _channelTtl,
      fetchTime: _channelFetchTimes[channel],
    );
    if (cached != null) {
      _channelCaches[channel] = cached;
      _channelFetchTimes[channel] = DateTime.now();
      notifyListeners();
    }
    final emotes = await _fetchAllChannel(broadcasterId);
    final map = _buildChannelMap(emotes);
    _channelCaches[channel] = map;
    _channelFetchTimes[channel] = DateTime.now();
    await _saveToPrefs('emotes2_$channel', map, _channelTtl);
    notifyListeners();
  }

  void evictChannel(String channel) {
    _channelCaches.remove(channel);
    _channelFetchTimes.remove(channel);
  }

  void evictGlobal() {
    _globalCache = null;
  }

  // TODO: persist recently-used emote IDs so boost survives app restarts
  // Same SharedPreferences pattern as the emote cache — small, easy addition later

  ChannelEmotes _buildChannelMap(List<GenericEmote> emotes) {
    // Scope precedence (channel > global) applied before provider precedence.
    // Provider precedence (tiebreaker within same scope): 7TV > BTTV > FFZ > Twitch
    final best = <String, GenericEmote>{};
    final seenScope = <String, int>{};
    for (final emote in emotes) {
      final existing = best[emote.code];
      if (existing == null) {
        best[emote.code] = emote;
        seenScope[emote.code] = emote.scope.index;
        continue;
      }
      final existingScopePrio = seenScope[emote.code] ?? 0;
      final newScopePrio = emote.scope.index;
      // Scope wins: channel (1) over global (0)
      if (newScopePrio > existingScopePrio) {
        best[emote.code] = emote;
        seenScope[emote.code] = newScopePrio;
      } else if (newScopePrio == existingScopePrio) {
        // Same scope – provider precedence
        final existingProvPrio = _providerPriority[existing.type] ?? 99;
        final newProvPrio = _providerPriority[emote.type] ?? 99;
        if (newProvPrio < existingProvPrio) {
          best[emote.code] = emote;
        }
      }
    }
    final suggestions = best.values.toList()
      ..sort((a, b) => a.code.compareTo(b.code));
    return ChannelEmotes(byCode: best, suggestions: suggestions);
  }

  Future<List<GenericEmote>> _fetchAllGlobal() async {
    _lastErrors.clear();
    final all = <GenericEmote>[];
    await _fetchProvider(
      'Twitch',
      () => TwitchEmoteProvider.fetchGlobal(accessToken: _accessToken),
      all,
    );
    await _fetchProvider('BTTV', () => BttvEmoteProvider.fetchGlobal(), all);
    await _fetchProvider('FFZ', () => FfzEmoteProvider.fetchGlobal(), all);
    await _fetchProvider('7TV', () => SevenTvEmoteProvider.fetchGlobal(), all);
    return all;
  }

  Future<List<GenericEmote>> _fetchAllChannel(String? broadcasterId) async {
    if (broadcasterId == null) return [];
    final all = <GenericEmote>[];
    await _fetchProvider(
      'Twitch',
      () => TwitchEmoteProvider.fetchChannel(
        broadcasterId,
        accessToken: _accessToken,
      ),
      all,
    );
    await _fetchProvider(
      'BTTV',
      () => BttvEmoteProvider.fetchChannel(broadcasterId),
      all,
    );
    await _fetchProvider(
      'FFZ',
      () => FfzEmoteProvider.fetchChannel(broadcasterId),
      all,
    );
    await _fetchProvider(
      '7TV',
      () => SevenTvEmoteProvider.fetchChannel(broadcasterId),
      all,
    );
    return all;
  }

  Future<void> _fetchProvider(
    String name,
    Future<List<GenericEmote>> Function() fetch,
    List<GenericEmote> out,
  ) async {
    try {
      out.addAll(await fetch());
    } catch (e) {
      final msg = e.toString();
      debugPrint('EmoteManager: $name failed: $msg');
      _lastErrors[name] = msg;
    }
  }

  Future<ChannelEmotes?> _loadFromPrefs(
    String key,
    Duration ttl, {
    DateTime? fetchTime,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) return null;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final ts = DateTime.parse(data['ts'] as String);
      final cachedTime = fetchTime ?? ts;
      if (DateTime.now().difference(cachedTime) > ttl) return null;
      final list = (data['emotes'] as List<dynamic>)
          .map((e) => GenericEmote.fromJson(e as Map<String, dynamic>))
          .toList();
      return _buildChannelMap(list);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveToPrefs(
    String key,
    ChannelEmotes channelEmotes,
    Duration ttl,
  ) async {
    final nonTwitch = channelEmotes.suggestions
        .where((e) => e.type != EmoteType.twitch)
        .toList();
    if (nonTwitch.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = {
        'ts': DateTime.now().toIso8601String(),
        'emotes': nonTwitch.map((e) => e.toJson()).toList(),
      };
      await prefs.setString(key, jsonEncode(data));
    } catch (_) {}
  }
}
