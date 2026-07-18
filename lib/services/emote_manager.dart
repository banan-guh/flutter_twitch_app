import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
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
  final _channelTwitchEmotes = <String, List<GenericEmote>>{};
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

  List<String> get joinedChannels => _channelCaches.keys.toList()..sort();

  List<GenericEmote> globalEmotes() => _globalCache?.suggestions ?? [];

  List<GenericEmote> channelNonTwitchEmotes(String channel) {
    final cached = _channelCaches[channel];
    if (cached == null) return [];
    return cached.suggestions.where((e) => e.type != EmoteType.twitch).toList()
      ..sort((a, b) => a.code.compareTo(b.code));
  }

  List<GenericEmote> channelEmotes(String channel) {
    final cached = _channelCaches[channel];
    if (cached == null) return [];
    return cached.suggestions.toList()
      ..sort((a, b) => a.code.compareTo(b.code));
  }

  Map<String, List<GenericEmote>> subscriberEmotesByChannel() {
    final result = <String, List<GenericEmote>>{};
    final keys = _channelTwitchEmotes.keys.toList()..sort();
    for (final channel in keys) {
      final raw = _channelTwitchEmotes[channel];
      if (raw == null) continue;
      final subs = raw.where((e) => e.tier != null).toList()
        ..sort((a, b) => a.code.compareTo(b.code));
      if (subs.isNotEmpty) result[channel] = subs;
    }
    return result;
  }

  static const _recentKey = 'recent_emotes';
  static const _maxRecent = 100;
  List<String> _recentIds = [];
  bool _recentLoaded = false;

  Future<void> _ensureRecentLoaded() async {
    if (_recentLoaded) return;
    _recentLoaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_recentKey);
    if (raw == null) return;
    try {
      _recentIds = (jsonDecode(raw) as List<dynamic>).cast<String>();
    } catch (_) {}
  }

  Future<void> _saveRecent() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_recentKey, jsonEncode(_recentIds));
  }

  /// Resolve an emote by ID across all caches.
  GenericEmote? _emoteById(String id) {
    if (_globalCache != null) {
      for (final e in _globalCache!.suggestions) {
        if (e.id == id) return e;
      }
    }
    for (final cached in _channelCaches.values) {
      for (final e in cached.suggestions) {
        if (e.id == id) return e;
      }
    }
    for (final raw in _channelTwitchEmotes.values) {
      for (final e in raw) {
        if (e.id == id) return e;
      }
    }
    return null;
  }

  Future<void> markEmoteUsed(GenericEmote emote) async {
    await _ensureRecentLoaded();
    _recentIds.remove(emote.id);
    _recentIds.insert(0, emote.id);
    if (_recentIds.length > _maxRecent) {
      _recentIds = _recentIds.sublist(0, _maxRecent);
    }
    await _saveRecent();
    notifyListeners();
  }

  Future<List<GenericEmote>> recentEmotes() async {
    await _ensureRecentLoaded();
    final result = <GenericEmote>[];
    for (final id in _recentIds) {
      final emote = _emoteById(id);
      if (emote != null) result.add(emote);
    }
    return result;
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

  Future<void> storeUserTwitchEmotes(
    Map<String, List<GenericEmote>> perChannel,
  ) async {
    for (final entry in perChannel.entries) {
      final channel = entry.key;
      final emotes = entry.value;
      if (emotes.isEmpty) continue;
      final existing = _channelTwitchEmotes[channel] ?? [];
      final merged = <GenericEmote>[
        for (final e in existing)
          if (e.tier == null) e,
        ...emotes,
      ];
      _channelTwitchEmotes[channel] = merged;
      final existingCache = _channelCaches[channel];
      final allEmotes = <GenericEmote>[
        ...merged,
        if (existingCache != null)
          for (final e in existingCache.suggestions)
            if (e.type != EmoteType.twitch) e,
      ];
      _channelCaches[channel] = _buildChannelMap(allEmotes);
      debugPrint(
        'EmoteManager: stored ${emotes.length} user Twitch emotes '
        'for $channel (subs: ${merged.where((e) => e.tier != null).length})',
      );
    }
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
    final emotes = await _fetchAllChannel(broadcasterId, channelName: channel);
    _channelTwitchEmotes[channel] = emotes
        .where((e) => e.type == EmoteType.twitch)
        .toList();
    debugPrint(
      'EmoteManager: $_channelTwitchEmotes[channel].length Twitch emotes '
      'for $channel (subs: ${_channelTwitchEmotes[channel]!.where((e) => e.tier != null).length})',
    );
    final map = _buildChannelMap(emotes);
    _channelCaches[channel] = map;
    _channelFetchTimes[channel] = DateTime.now();
    await _saveToPrefs('emotes2_$channel', map, _channelTtl);
    notifyListeners();
  }

  void evictChannel(String channel) {
    _channelCaches.remove(channel);
    _channelFetchTimes.remove(channel);
    _channelTwitchEmotes.remove(channel);
  }

  void evictGlobal() {
    _globalCache = null;
  }

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

  Future<List<GenericEmote>> _fetchAllChannel(
    String? broadcasterId, {
    String? channelName,
  }) async {
    debugPrint(
      'EmoteManager: _fetchAllChannel broadcasterId=$broadcasterId channel=$channelName',
    );
    if (broadcasterId == null) return [];
    final all = <GenericEmote>[];
    await _fetchProvider(
      'Twitch',
      () => TwitchEmoteProvider.fetchChannel(
        broadcasterId,
        accessToken: _accessToken,
        channelName: channelName,
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

  // ── Pre-cache queue for seen emotes ──────────────────────────────────

  final Set<String> _seenEmoteIds = {};
  final _precacheQueue = <GenericEmote>[];
  bool _isProcessingPrecache = false;
  static const _maxConcurrentPrecache = 5;

  void enqueueSeenEmotes(List<GenericEmote> emotes) {
    final fresh = <GenericEmote>[];
    for (final e in emotes) {
      if (_seenEmoteIds.add(e.id)) {
        fresh.add(e);
      }
    }
    if (fresh.isEmpty) return;
    _precacheQueue.addAll(fresh);
    if (!_isProcessingPrecache) {
      _processPrecacheQueue();
    }
  }

  void _processPrecacheQueue() {
    _isProcessingPrecache = true;
    _stepPrecache();
  }

  void _stepPrecache() {
    if (_precacheQueue.isEmpty) {
      _isProcessingPrecache = false;
      return;
    }
    final batch = _precacheQueue.take(_maxConcurrentPrecache).toList();
    _precacheQueue.removeRange(0, batch.length);
    Future.wait(
      batch.map(_precacheEmote),
      eagerError: false,
    ).then((_) => _stepPrecache());
  }

  Future<void> _precacheEmote(GenericEmote emote) async {
    try {
      await DefaultCacheManager().getSingleFile(emote.url);
    } catch (_) {}
  }
}
