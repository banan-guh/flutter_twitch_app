import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/generic_emote.dart';
import '../models/twitch_message.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../services/twitch_eventsub.dart';
import '../services/twitch_irc.dart';
import '../services/twitch_irc_read.dart';
import '../services/recent_messages.dart';
import '../services/emote_manager.dart';
import '../services/twitch_badge_service.dart';
import '../services/emote_providers/twitch_emotes.dart';
import '../widgets/settings.dart';
import '../widgets/emote_text.dart';
import '../widgets/chat_message_tile.dart';
import '../widgets/tabbed_layout.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../color_utils.dart';
import '../services/user_store.dart';
import '../services/suggestion.dart';
import '../widgets/autocomplete_dropdown.dart';
import '../widgets/user_profile_sheet.dart';
import '../widgets/emote_sheet.dart';
import '../widgets/message_input.dart';
import '../util/text_bypass.dart';
import '../services/foreground_task.dart';

enum OverlayPanel { closed, thread, mentions, emotes }

class HomeScreen extends StatefulWidget {
  final TwitchAuth twitchAuth;
  final ValueChanged<ThemeMode> onThemeChanged;
  final EventSubService? eventSubService;
  final IrcService? ircService;
  final IrcReadService? ircReadService;
  final RecentMessagesService? recentMessagesService;
  final String? initialCurrentUserLogin;

  const HomeScreen({
    super.key,
    required this.twitchAuth,
    required this.onThemeChanged,
    this.eventSubService,
    this.ircService,
    this.ircReadService,
    this.recentMessagesService,
    this.initialCurrentUserLogin,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver {
  static const _mentionsChannel = '@mentions';

  late final _eventSub = widget.eventSubService ?? EventSubService();
  late final _irc = widget.ircService ?? IrcService();
  late final _ircRead = widget.ircReadService ?? IrcReadService();
  late final _recentMessages =
      widget.recentMessagesService ?? RecentMessagesService();
  final _messageController = TextEditingController();
  final _focusNode = FocusNode();

  final _emoteManager = EmoteManager();
  final _badgeService = TwitchBadgeService();
  final _userStore = UserStore();
  final _channels = <String>[];
  final _channelNotifier = ValueNotifier<List<String>>([]);
  final _chatVersion = ValueNotifier(0);
  String? _selectedChannel;
  final _channelMessages = <String, List<TwitchMessage>>{};
  final _scrollControllers = <String, ScrollController>{};
  final _isAtBottom = <String, bool>{};
  final _frozenSnapshot = <String, List<TwitchMessage>>{};
  final _historyLoaded = <String>{};
  final _messageKeys = <String, GlobalKey>{};
  final _chatStatus = <String, String>{};
  final _channelUserIds = <String, String>{};
  final _channelsEmotesResolved = <String>{};
  int _unreadMentions = 0;
  final _channelsWithUnread = <String>{};
  final _channelsWithUnreadMentions = <String>{};
  final _unreadMentionsPerChannel = <String, int>{};

  TwitchMessage? _replyToMsg;
  TwitchMessage? _openThreadRoot;
  OverlayPanel _activePanel = OverlayPanel.closed;
  int _maxMessagesPerChannel = 200;

  List<Suggestion> _suggestions = [];

  late final DraggableScrollableController _threadSheetCtrl;
  late final DraggableScrollableController _mentionsSheetCtrl;
  late final DraggableScrollableController _emoteSheetCtrl;
  static const _sheetAnimDuration = Duration(milliseconds: 250);
  static const _sheetCloseDuration = Duration(milliseconds: 180);
  static const _emoteMaxFraction = 0.6;
  static const _fullHeightFraction = 1.0;
  double? _emoteSheetBoxHeight;
  final _threadPanelData = ValueNotifier<_ThreadPanelData?>(null);
  final _mentionsPanelData = ValueNotifier<List<TwitchMessage>?>(null);

  StreamSubscription<TwitchMessage>? _messageSub;
  StreamSubscription<EventSubStatus>? _statusSub;
  StreamSubscription<({String messageId, String targetUser, String channel})>?
  _deleteSub;
  StreamSubscription<IrcBanEvent>? _ircBanSub;
  StreamSubscription<IrcNoticeEvent>? _ircNoticeSub;
  StreamSubscription<IrcNoticeEvent>? _ircJtvSub;
  StreamSubscription<IrcMessage>? _ircOwnMsgSub;
  StreamSubscription<String>? _userColorSub;

  final _ownMessageIds = <String>{};
  int _localCounter = 0;
  final _pendingLocals = <String, _PendingLocal>{};

  String? _currentUserLogin;
  String? _currentUserColor;
  String? _currentUserId;
  String? _lastSentText;
  final Map<String, String> _lastTypedText = {};
  final Map<String, String> _lastSentWireText = {};
  bool _wasConnected = false;
  bool _wasDisconnected = false;
  bool _userTwitchEmotesLoaded = false;
  EventSubStatus _connectionStatus = EventSubStatus.disconnected;

  void _onSheetSizeChanged(OverlayPanel panel, DraggableScrollableController ctrl) {
    // When the user drags a sheet down to size 0, close the panel.
    if (_activePanel == panel && ctrl.isAttached && ctrl.size <= 0.001) {
      setState(() {
        _activePanel = OverlayPanel.closed;
        if (panel == OverlayPanel.thread) {
          _openThreadRoot = null;
          _threadPanelData.value = null;
        } else if (panel == OverlayPanel.mentions) {
          _mentionsPanelData.value = null;
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _currentUserLogin = widget.initialCurrentUserLogin;
    _threadSheetCtrl = DraggableScrollableController();
    _threadSheetCtrl.addListener(
      () => _onSheetSizeChanged(OverlayPanel.thread, _threadSheetCtrl),
    );
    _mentionsSheetCtrl = DraggableScrollableController();
    _mentionsSheetCtrl.addListener(
      () => _onSheetSizeChanged(OverlayPanel.mentions, _mentionsSheetCtrl),
    );
    _emoteSheetCtrl = DraggableScrollableController();
    _emoteSheetCtrl.addListener(
      () => _onSheetSizeChanged(OverlayPanel.emotes, _emoteSheetCtrl),
    );
    _chatVersion.addListener(_onPanelDataChanged);
    _loadMaxMessages();
    _loadChannels();
    _connect();
    _emoteManager.accessToken = widget.twitchAuth.accessToken;
    _emoteManager.preloadGlobalEmotes();
    _emoteManager.addListener(_onEmotesChanged);
    _badgeService.fetchGlobalBadges(widget.twitchAuth);
    widget.twitchAuth.addListener(_onAuthChanged);
    _focusNode.addListener(_onInputFocusChanged);
    _messageController.addListener(_onInputChanged);
    WidgetsBinding.instance.addObserver(this);
    _initForegroundService();
  }

  Future<void> _initForegroundService() async {
    initForegroundService();
    await requestForegroundPermissions();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isAndroid) return;
    if (state == AppLifecycleState.paused) {
      startForegroundService(List.of(_channels));
    } else if (state == AppLifecycleState.resumed) {
      stopForegroundService();
    }
  }

  Future<void> _saveChannels() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('channels', List.of(_channels));
  }

  Future<void> _loadChannels() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('channels');
    if (saved == null || saved.isEmpty) return;
    for (final name in saved) {
      if (_channels.contains(name)) continue;
      _channels.add(name);
      _channelMessages.putIfAbsent(name, () => []);
      _isAtBottom[name] = true;
    }
    _channelNotifier.value = List.of(_channels);
    _selectedChannel = _channels.first;
    if (mounted) setState(() {});
    for (final name in saved) {
      _subscribeChannel(name);
      _recentMessages
          .fetchRecent(name)
          .then((history) {
            if (!mounted) return;
            _historyLoaded.add(name);
            setState(() {
              if (history.isEmpty) {
                _addSystemMessage(name, 'No chat history available');
              } else {
                final existing = _channelMessages[name]!;
                final existingIds = existing.map((m) => m.messageId).toSet();
                for (final msg in history) {
                  if (msg.messageId == null ||
                      !existingIds.contains(msg.messageId)) {
                    existing.insert(0, msg);
                  }
                  if (msg.messageId != null) {
                    _messageKeys.putIfAbsent(
                      '$name:${msg.messageId}',
                      () => GlobalKey(),
                    );
                  }
                }
                _truncateChannelMessages(name);
              }
            });
            _maybeAddConnected(name);
          })
          .catchError((e) {
            if (!mounted) return;
            _historyLoaded.add(name);
            _addSystemMessage(name, 'Failed to load chat history ($e)');
            _maybeAddConnected(name);
          });
    }
  }

  void _onInputFocusChanged() {
    if (_activePanel == OverlayPanel.emotes) {
      _closePanel();
    }
  }

  void _onInputChanged() {
    final text = _messageController.text;
    final cursor = _messageController.selection.baseOffset;
    final word = getCurrentWord(text, cursor);
    if (word.text.length < 2) {
      if (_suggestions.isNotEmpty) {
        setState(() {
          _suggestions = [];
        });
      }
      return;
    }
    final channel = _selectedChannel;
    if (channel == null) return;
    final channelEmotes = _emoteManager.byCode(channel);
    final emotes = channelEmotes?.suggestions ?? [];
    final users = _userStore.usersForChannel(channel);
    final filtered = filterSuggestions(
      word: word.text,
      emotes: emotes,
      users: users,
    );
    setState(() {
      _suggestions = filtered;
    });
  }

  void _onSuggestionSelected(Suggestion suggestion) {
    final replacement = switch (suggestion) {
      UserSuggestion() => suggestion.displayName,
      EmoteSuggestion() => suggestion.emote.code,
    };
    replaceCurrentWord(_messageController, replacement);
    if (suggestion is EmoteSuggestion) {
      _emoteManager.markEmoteUsed(suggestion.emote);
    }
    setState(() {
      _suggestions = [];
    });
    _focusNode.requestFocus();
  }

  void _onEmotesChanged() {
    for (final msgs in _channelMessages.values) {
      for (final msg in msgs) {
        msg.cachedSpans = null;
      }
    }
    if (mounted) setState(() {});
  }

  void _onPanelDataChanged() {
    if (_activePanel == OverlayPanel.thread && _openThreadRoot != null) {
      final channel = _openThreadRoot!.channel!;
      _threadPanelData.value = _ThreadPanelData(
        root: _openThreadRoot!,
        messages: _computeThreadMessages(),
        channel: channel,
      );
    } else if (_activePanel == OverlayPanel.mentions) {
      _mentionsPanelData.value = _channelMessages[_mentionsChannel] ?? [];
    }
  }

  void _onAuthChanged() {
    _emoteManager.accessToken = widget.twitchAuth.accessToken;
    _refreshEmotesAfterAuth();
  }

  Future<void> _refreshEmotesAfterAuth() async {
    try {
      for (final channel in _channels) {
        final userId = await TwitchApi.getUserId(widget.twitchAuth, channel);
        if (userId != null) {
          _channelUserIds[channel] = userId;
        }
      }
      _emoteManager.evictGlobal();
      _emoteManager.preloadGlobalEmotes();
      _badgeService.dispose();
      _badgeService.fetchGlobalBadges(widget.twitchAuth);
      for (final channel in _channels) {
        _emoteManager.evictChannel(channel);
        final userId = _channelUserIds[channel];
        if (userId != null) {
          _badgeService.fetchChannelBadges(widget.twitchAuth, userId, channel);
        }
      }
      await Future.wait(
        _channels.map(
          (c) => _emoteManager.resolveEmotes(c, _channelUserIds[c]),
        ),
      );
      _userTwitchEmotesLoaded = false;
      unawaited(_loadUserTwitchEmotes());
    } catch (e) {
      debugPrint('_refreshEmotesAfterAuth failed: $e');
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadUserTwitchEmotes() async {
    final auth = widget.twitchAuth;
    final userId = _currentUserId;
    if (!auth.isConfigured || userId == null) return;
    final byOwner = await TwitchEmoteProvider.fetchUserEmotes(
      userId: userId,
      accessToken: auth.accessToken,
    );
    if (byOwner.isEmpty) return;
    final userIdToChannel = <String, String>{};
    for (final entry in _channelUserIds.entries) {
      userIdToChannel[entry.value] = entry.key;
    }
    final unknownIds = <String>[];
    for (final ownerId in byOwner.keys) {
      if (ownerId.isEmpty) continue;
      if (!userIdToChannel.containsKey(ownerId)) {
        unknownIds.add(ownerId);
      }
    }
    if (unknownIds.isNotEmpty) {
      final resolved = await TwitchApi.getUserLoginsByIds(auth, unknownIds);
      userIdToChannel.addAll(resolved);
    }
    final perChannel = <String, List<GenericEmote>>{};
    for (final entry in byOwner.entries) {
      if (entry.key.isEmpty) continue;
      final channel = userIdToChannel[entry.key];
      if (channel == null) continue;
      perChannel[channel] = entry.value
          .map((e) => GenericEmote(
                id: e.id,
                code: e.code,
                type: e.type,
                url: e.url,
                scope: e.scope,
                tier: e.tier,
                emoteType: e.emoteType,
                ownerChannel: channel,
              ))
          .toList();
    }
    if (perChannel.isNotEmpty) {
      await _emoteManager.storeUserTwitchEmotes(perChannel);
    }
  }

  void _loadMaxMessages() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _maxMessagesPerChannel = prefs.getInt('max_messages_per_channel') ?? 200;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageSub?.cancel();
    _statusSub?.cancel();
    _deleteSub?.cancel();
    _ircBanSub?.cancel();
    _eventSub.dispose();
    _irc.dispose();
    _ircRead.dispose();
    _emoteManager.removeListener(_onEmotesChanged);
    widget.twitchAuth.removeListener(_onAuthChanged);
    _messageController.dispose();
    _focusNode.removeListener(_onInputFocusChanged);
    _focusNode.dispose();
    _ircOwnMsgSub?.cancel();
    _userColorSub?.cancel();
    _ircBanSub?.cancel();
    _ircNoticeSub?.cancel();
    _ircJtvSub?.cancel();
    _chatVersion.removeListener(_onPanelDataChanged);
    _threadSheetCtrl.dispose();
    _mentionsSheetCtrl.dispose();
    _emoteSheetCtrl.dispose();
    _threadPanelData.dispose();
    _mentionsPanelData.dispose();
    for (final c in _scrollControllers.values) {
      c.dispose();
    }
    _chatVersion.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final auth = widget.twitchAuth;

    // Always listen for EventSub messages/incoming data, regardless of auth
    // state. In tests these come from injected fake services; in production
    // they flow from the EventSub WebSocket once connected.
    _messageSub ??= _eventSub.onMessage.listen(_onMessage);
    _deleteSub ??= _eventSub.onMessageDeleted.listen((event) {
      if (!mounted) return;
      final msgs = _channelMessages[event.channel];
      if (msgs == null) return;
      String? deletedUser;
      String? deletedText;
      for (final msg in msgs) {
        if (msg.messageId == event.messageId && !msg.isSystem) {
          msg.deleted = true;
          deletedUser = msg.username;
          deletedText = msg.text;
          break;
        }
      }
      if (deletedUser != null && deletedText != null) {
        _addSystemMessage(
          event.channel,
          'A message from $deletedUser was deleted saying: "$deletedText".',
        );
      }
    });

    _ircBanSub?.cancel();
    _ircBanSub = _irc.onBan.listen((event) {
      if (!mounted) return;
      final text = event.isTimeout
          ? '${event.user} was timed out${event.duration != null ? ' for ${event.duration}s' : ''}.'
          : '${event.user} was banned.';
      _addSystemMessage(event.channel, text);
    });

    _ircNoticeSub?.cancel();
    _ircNoticeSub = _irc.onNotice.listen((event) {
      if (!mounted) return;
      _addSystemMessage(event.channel, event.message);
    });

    _ircJtvSub?.cancel();
    _ircJtvSub = _irc.onJtvMessage.listen((event) {
      if (!mounted) return;
      _addSystemMessage(event.channel, event.message);
    });

    _ircOwnMsgSub?.cancel();
    _ircOwnMsgSub = _ircRead.onOwnMessage.listen(_onOwnIrcMessage);

    _userColorSub?.cancel();
    _userColorSub = _ircRead.onUserColor.listen((color) {
      _currentUserColor = color;
    });

    if (!auth.isConfigured) return;

    _statusSub?.cancel();
    _statusSub = _eventSub.onStatus.listen((status) async {
      if (!mounted) return;
      setState(() {
        _connectionStatus = status;
      });
      if (status == EventSubStatus.connected && !_wasConnected) {
        _wasConnected = true;
        _wasDisconnected = false;
        await Future.delayed(const Duration(milliseconds: 500));
        try {
          await _subscribeAll();
          if (!_userTwitchEmotesLoaded) {
            _userTwitchEmotesLoaded = true;
            unawaited(_loadUserTwitchEmotes());
          }
        } catch (_) {}
        for (final channel in _channels) {
          if (_historyLoaded.contains(channel)) {
            _addSystemMessage(channel, 'Connected');
          }
        }
      }
      if (status == EventSubStatus.disconnected && !_wasDisconnected) {
        _wasDisconnected = true;
        _wasConnected = false;
        for (final channel in _channels) {
          _addSystemMessage(channel, 'Disconnected');
        }
      }
    });

    if (_currentUserLogin == null) {
      try {
        final currentUser = await TwitchApi.getCurrentUser(auth);
        if (currentUser != null) {
          _currentUserLogin = currentUser['login'];
          _currentUserId = currentUser['id'];
        }
      } catch (_) {}
    }

    if (_currentUserLogin != null && auth.accessToken != null) {
      try {
        await _irc.connect(
          username: _currentUserLogin!,
          accessToken: auth.accessToken!,
        );
      } catch (_) {}
      try {
        await _ircRead.connect(
          username: _currentUserLogin!,
          accessToken: auth.accessToken!,
        );
      } catch (_) {}
    }

    await _eventSub.connect();
  }

  void _onMessage(TwitchMessage msg) {
    if (!mounted) return;

    if (!msg.isSystem && msg.username.isNotEmpty && msg.channel != null) {
      _userStore.addUser(msg.channel!, msg.username);
    }

    final channel = msg.channel;
    if (channel == null) return;

    if (msg.messageId != null &&
        _messageKeys.containsKey('$channel:${msg.messageId}')) {
      // EventSub may deliver our own message with emote fragments that the
      // local optimistic insert didn't have. Replace to get proper rendering.
      final existing = _channelMessages[channel];
      if (msg.emotePositions != null && existing != null) {
        final idx = existing.indexWhere(
          (m) => m.messageId == msg.messageId,
        );
        if (idx != -1) {
          existing[idx] = msg;
          _chatVersion.value++;
          if (mounted) setState(() {});
        }
      }
      return;
    }

    if (msg.messageId != null &&
        _currentUserLogin != null &&
        msg.username.toLowerCase() == _currentUserLogin!.toLowerCase()) {
      String? pendingKey;
      for (final entry in _pendingLocals.entries) {
        if (entry.value.channel == channel &&
            normalizeForReconciliation(entry.value.text) ==
                normalizeForReconciliation(msg.text)) {
          pendingKey = entry.key;
          break;
        }
      }
      if (pendingKey != null) {
        _pendingLocals.remove(pendingKey);
        _channelMessages[channel]?.removeWhere(
          (m) => m.messageId == pendingKey,
        );
      }
      _ownMessageIds.add(msg.messageId!);
    }

    if (msg.sourceBroadcasterId != null &&
        _badgeService.resolveChannelAvatar(msg.sourceBroadcasterId!) == null) {
      _badgeService.fetchChannelAvatar(
        widget.twitchAuth,
        msg.sourceBroadcasterId!,
      );
    }

    final login = _currentUserLogin?.toLowerCase();

    final isReplyToMe =
        login != null &&
        !msg.isSystem &&
        !msg.isHistory &&
        msg.replyToUser != null &&
        msg.replyToUser!.toLowerCase() == login;
    final isMention =
        (login != null &&
            !msg.isSystem &&
            !msg.isHistory &&
            _isMention(msg, login)) ||
        isReplyToMe;

    if (isMention) {
      if (!msg.isHighlighted && channel != _selectedChannel) {
        _unreadMentions++;
        _channelsWithUnreadMentions.add(channel);
        _unreadMentionsPerChannel[channel] =
            (_unreadMentionsPerChannel[channel] ?? 0) + 1;
      }
      msg.isHighlighted = true;
    }

    _channelMessages.putIfAbsent(channel, () => []);
    _channelMessages[channel]!.insert(0, msg);
    _truncateChannelMessages(channel);

    if (msg.messageId != null) {
      _messageKeys.putIfAbsent('$channel:${msg.messageId}', () => GlobalKey());
    }

    if (msg.isHighlighted) {
      _channelMessages.putIfAbsent(_mentionsChannel, () => []);
      _channelMessages[_mentionsChannel]!.insert(0, msg);
    }

    _chatVersion.value++;

    var needsHeaderRebuild = false;
    if (channel != _selectedChannel && !msg.isHistory) {
      _channelsWithUnread.add(channel);
      needsHeaderRebuild = true;
    }
    if (msg.isHighlighted) {
      needsHeaderRebuild = true;
    }
    if (needsHeaderRebuild && mounted) {
      setState(() {});
    }
    _precacheMessageEmotes(msg, channel);
  }

  void _onOwnIrcMessage(IrcMessage ircMsg) {
    if (!mounted) return;
    final channel = ircMsg.params.isNotEmpty
        ? ircMsg.params[0].substring(1)
        : null;
    if (channel == null || ircMsg.trailing == null) return;

    final displayName =
        ircMsg.tags['display-name']?.trim() ?? _currentUserLogin ?? '';
    if (displayName.isNotEmpty) {
      _userStore.addUser(channel, displayName);
    }

    final colorTag = ircMsg.tags['color'];
    if (colorTag != null && colorTag.isNotEmpty) {
      _currentUserColor = colorTag;
    }

    final messageId = ircMsg.tags['id'];
    final text = ircMsg.trailing!;

    if (messageId != null && _messageKeys.containsKey('$channel:$messageId')) {
      return;
    }

    String? pendingKey;
    TwitchMessage? pendingMsg;
    for (final entry in _pendingLocals.entries) {
      if (entry.value.channel == channel &&
          normalizeForReconciliation(entry.value.text) ==
              normalizeForReconciliation(text)) {
        pendingKey = entry.key;
        break;
      }
    }
    if (pendingKey != null) {
      final existing = _channelMessages[channel];
      if (existing != null) {
        final idx = existing.indexWhere((m) => m.messageId == pendingKey);
        if (idx != -1) {
          pendingMsg = existing[idx];
        }
      }
      _pendingLocals.remove(pendingKey);
      _channelMessages[channel]?.removeWhere((m) => m.messageId == pendingKey);
    }

    final tsMs = ircMsg.tags['tmi-sent-ts'];
    final timestamp = tsMs != null
        ? DateTime.fromMillisecondsSinceEpoch(int.parse(tsMs), isUtc: true)
        : DateTime.now().toUtc();

    final userId = ircMsg.tags['user-id'] ?? _currentUserId;
    final color =
        ircMsg.tags['color'] != null && ircMsg.tags['color']!.isNotEmpty
        ? ircMsg.tags['color']!
        : pickColor(displayName.toLowerCase());

    List<EmotePosition>? emotePositions;
    final emotesTag = ircMsg.tags['emotes'];
    if (emotesTag != null && emotesTag.isNotEmpty) {
      emotePositions = [];
      for (final emoteEntry in emotesTag.split('/')) {
        final colonIdx = emoteEntry.indexOf(':');
        if (colonIdx == -1) continue;
        final emoteId = emoteEntry.substring(0, colonIdx);
        final positionsStr = emoteEntry.substring(colonIdx + 1);
        for (final posStr in positionsStr.split(',')) {
          final dashIdx = posStr.indexOf('-');
          if (dashIdx == -1) continue;
          final start = int.tryParse(posStr.substring(0, dashIdx));
          final end = int.tryParse(posStr.substring(dashIdx + 1));
          if (start == null || end == null) continue;
          if (start < 0 || end >= text.length) continue;
          final emoteCode = text.substring(start, end + 1);
          emotePositions.add(
            EmotePosition(
              emoteId: emoteId,
              startIndex: start,
              endIndex: end + 1,
              emoteCode: emoteCode,
            ),
          );
        }
      }
      if (emotePositions.isEmpty) emotePositions = null;
    }

    final msg = TwitchMessage(
      username: displayName,
      text: text,
      channel: channel,
      messageId: messageId,
      timestamp: timestamp,
      userId: userId,
      color: color,
      replyToParentId: pendingMsg?.replyToParentId,
      replyToUser: pendingMsg?.replyToUser,
      replyToText: pendingMsg?.replyToText,
      emotePositions: emotePositions,
    );

    _channelMessages.putIfAbsent(channel, () => []);
    _channelMessages[channel]!.insert(0, msg);
    _truncateChannelMessages(channel);

    if (messageId != null) {
      _messageKeys.putIfAbsent('$channel:$messageId', () => GlobalKey());
    }

    _chatVersion.value++;
    if (mounted) setState(() {});
    _precacheMessageEmotes(msg, channel);
  }

  void _insertLocalMessage(
    String text,
    String channel,
    String? messageId,
    TwitchMessage? replyTo,
  ) {
    final login = _currentUserLogin;
    if (login == null) return;

    final useTempId = messageId == null;
    final effectiveId = useTempId ? 'local_${_localCounter++}' : messageId;

    if (!useTempId && _messageKeys.containsKey('$channel:$effectiveId')) {
      return;
    }

    final msg = TwitchMessage(
      username: login,
      text: text,
      channel: channel,
      messageId: effectiveId,
      color: _currentUserColor ?? pickColor(login.toLowerCase()),
      userId: _currentUserId,
      replyToParentId: replyTo?.messageId,
      replyToUser: replyTo?.username,
      replyToText: replyTo?.text,
    );
    _channelMessages.putIfAbsent(channel, () => []);
    _channelMessages[channel]!.insert(0, msg);
    if (useTempId) {
      _pendingLocals[effectiveId] = _PendingLocal(channel, text);
    }
    _truncateChannelMessages(channel);
    if (!useTempId) {
      _messageKeys.putIfAbsent('$channel:$messageId', () => GlobalKey());
    }
    _chatVersion.value++;
    if (mounted) setState(() {});
  }

  void _precacheMessageEmotes(TwitchMessage msg, String channel) {
    if (msg.isSystem || msg.isHistory) return;
    final channelEmotes = _emoteManager.byCode(channel);
    if (channelEmotes == null) return;
    final found = <GenericEmote>[];
    final seen = <String>{};
    for (final word in msg.text.split(RegExp(r'\s+'))) {
      if (seen.contains(word)) continue;
      final emote = channelEmotes.byCode[word];
      if (emote != null) {
        found.add(emote);
        seen.add(word);
      }
    }
    if (found.isNotEmpty) {
      _emoteManager.enqueueSeenEmotes(found);
    }
  }

  bool _isMention(TwitchMessage msg, String login) {
    return isMention(msg.text, login);
  }

  void _addSystemMessage(String channel, String text) {
    setState(() {
      _channelMessages.putIfAbsent(channel, () => []);
      _channelMessages[channel]!.insert(
        0,
        TwitchMessage(
          username: '',
          text: text,
          isSystem: true,
          channel: channel,
        ),
      );
      _truncateChannelMessages(channel);
      if (channel != _selectedChannel) {
        _channelsWithUnread.add(channel);
      }
    });
  }

  void _showMessageMenu(TwitchMessage msg) {
    final threadRoot = _findThreadRoot(msg);
    final hasThread = threadRoot != null;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Reply to message'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _replyToMsg = msg;
                });
                _focusNode.requestFocus();
              },
            ),
            if (hasThread)
              ListTile(
                leading: const Icon(Icons.forum),
                title: const Text('View thread'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showThreadView(threadRoot);
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy message'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: msg.text));
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.more_horiz),
              title: const Text('More...'),
              onTap: () {
                Navigator.pop(ctx);
                _showMoreMenu(msg);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showThreadMessageMenu(TwitchMessage msg) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy message'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: msg.text));
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.more_horiz),
              title: const Text('More...'),
              onTap: () {
                Navigator.pop(ctx);
                _showMoreMenu(msg);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showMoreMenu(TwitchMessage msg) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_all),
              title: const Text('Copy full message'),
              onTap: () {
                final ts =
                    '${msg.timestamp.toLocal().hour.toString().padLeft(2, '0')}:${msg.timestamp.toLocal().minute.toString().padLeft(2, '0')}';
                Clipboard.setData(
                  ClipboardData(text: '$ts ${msg.username}: ${msg.text}'),
                );
                Navigator.pop(ctx);
              },
            ),
            if (msg.messageId != null)
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Copy message ID'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: msg.messageId!));
                  Navigator.pop(ctx);
                },
              ),
            ],
          ),
      ),
    );
  }

  void _maybeAddConnected(String channel) {
    if (_connectionStatus == EventSubStatus.connected &&
        _historyLoaded.contains(channel)) {
      _addSystemMessage(channel, 'Connected');
    }
  }

  Future<void> _addChannel(String channelName) async {
    final name = channelName.trim().toLowerCase();
    if (name.isEmpty || _channels.contains(name)) return;

    setState(() {
      _channels.add(name);
      _channelNotifier.value = List.of(_channels);
      _channelMessages.putIfAbsent(name, () => []);
      _isAtBottom[name] = true;
      _selectedChannel = name;
    });
    _saveChannels();
    _focusNode.requestFocus();

    final loadingMsg = TwitchMessage(
      username: '',
      text: 'Loading chat history...',
      isSystem: true,
      channel: name,
    );
    _channelMessages[name]!.insert(0, loadingMsg);

    _recentMessages
        .fetchRecent(name)
        .then((history) {
          if (!mounted) return;
          _historyLoaded.add(name);
          setState(() {
            if (history.isEmpty) {
              _addSystemMessage(name, 'No chat history available');
            } else {
              final existing = _channelMessages[name]!;
              final existingIds = existing.map((m) => m.messageId).toSet();
              for (final msg in history) {
                if (msg.messageId == null ||
                    !existingIds.contains(msg.messageId)) {
                  existing.insert(0, msg);
                }
                if (msg.messageId != null) {
                  _messageKeys.putIfAbsent(
                    '$name:${msg.messageId}',
                    () => GlobalKey(),
                  );
                }
              }
              _truncateChannelMessages(name);
            }
          });
          _maybeAddConnected(name);
        })
        .catchError((e) {
          if (!mounted) return;
          _historyLoaded.add(name);
          _addSystemMessage(name, 'Failed to load chat history ($e)');
          _maybeAddConnected(name);
        });

    final auth = widget.twitchAuth;
    if (!auth.isConfigured) {
      if (mounted) setState(() {});
      return;
    }

    _ircRead.join(name);

    await _subscribeChannel(name);

    if (mounted) setState(() {});
  }

  Future<void> _fetchChatStatus(String channel) async {
    final auth = widget.twitchAuth;
    if (!auth.isConfigured) return;

    final userId = _channelUserIds[channel];
    if (userId == null || _currentUserId == null) return;

    final settings = await TwitchApi.getChatSettings(
      auth,
      userId,
      _currentUserId!,
    );
    final stream = await TwitchApi.getStreamInfo(auth, userId);

    if (!mounted) return;
    final parts = <String>[];
    if (settings != null) {
      if (settings['follower_mode'] == true) parts.add('Followers-only');
      if (settings['subscriber_mode'] == true) parts.add('Subscribers-only');
      if (settings['emote_mode'] == true) parts.add('Emote-only');
      if (settings['slow_mode'] == true) {
        final wait = settings['slow_mode_wait_time'] ?? '?';
        parts.add('Slow ($wait${wait == '?' ? '' : 's'})');
      }
    }
    if (stream != null && stream['type'] == 'live') {
      final viewers = stream['viewer_count'] ?? 0;
      final started = stream['started_at'] as String?;
      if (started != null) {
        final dur = DateTime.now().difference(DateTime.parse(started));
        final h = dur.inHours;
        final m = dur.inMinutes.remainder(60);
        parts.add('Live with $viewers viewers for ${h}h ${m}m');
      } else {
        parts.add('Live with $viewers viewers');
      }
    }
    setState(() {
      _chatStatus[channel] = parts.isNotEmpty ? parts.join(' · ') : '';
    });
  }

  Future<void> _subscribeChannel(String channelName) async {
    try {
      final auth = widget.twitchAuth;
      final channelUserId = await TwitchApi.getUserId(auth, channelName);
      if (channelUserId == null) return;
      _channelUserIds[channelName] = channelUserId;
      _badgeService.fetchChannelBadges(auth, channelUserId, channelName);

      _emoteManager.accessToken = auth.accessToken;
      debugPrint(
        '_subscribeChannel $channelName userId=$channelUserId '
        'hasToken=${auth.accessToken != null} resolved=${_channelsEmotesResolved.contains(channelName)}',
      );
      if (!_channelsEmotesResolved.contains(channelName)) {
        await _emoteManager.resolveEmotes(channelName, channelUserId);
        _channelsEmotesResolved.add(channelName);
      }

      if (_currentUserLogin == null) {
        final currentUser = await TwitchApi.getCurrentUser(auth);
        if (currentUser == null) return;
        _currentUserLogin = currentUser['login'];
        _currentUserId = currentUser['id'];
      }

      if (!_userTwitchEmotesLoaded) {
        _userTwitchEmotesLoaded = true;
        unawaited(_loadUserTwitchEmotes());
      }

      _eventSub.setChannelMapping(channelUserId, channelName);

      for (int attempt = 0; attempt < 3; attempt++) {
        final sessionId = _eventSub.sessionId;
        if (sessionId == null) {
          if (attempt == 2) {
            _addSystemMessage(channelName, 'Warning: EventSub session lost');
          }
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }

        if (attempt > 0) await Future.delayed(const Duration(seconds: 1));

        final ok = await TwitchApi.createSubscription(
          auth: auth,
          sessionId: sessionId,
          broadcasterUserId: channelUserId,
          userId: _currentUserId!,
        );
        if (ok) {
          final okDel = await TwitchApi.createDeleteSubscription(
            auth: auth,
            sessionId: sessionId,
            broadcasterUserId: channelUserId,
            userId: _currentUserId!,
          );
          if (!okDel) {
            _addSystemMessage(
              channelName,
              'Warning: delete subscription failed (${TwitchApi.lastError ?? "unknown"})',
            );
          }
          break;
        }
        if (attempt == 2) {
          _addSystemMessage(
            channelName,
            'Warning: chat subscription failed (${TwitchApi.lastError ?? "unknown"})',
          );
        }
      }
    } catch (_) {}

    if (mounted) {
      setState(() {});
      _fetchChatStatus(channelName);
    }
  }

  Future<void> _subscribeAll() async {
    for (final channel in _channels) {
      await _subscribeChannel(channel);
    }
  }

  void _addChannelDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Join channel'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'channel name',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
          onSubmitted: (_) {
            Navigator.pop(ctx);
            _addChannel(controller.text);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _addChannel(controller.text);
            },
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }

  void _removeChannel(String channel) {
    _ircRead.part(channel);
    _emoteManager.evictChannel(channel);
    _channelsEmotesResolved.remove(channel);
    setState(() {
      _channels.remove(channel);
      _channelNotifier.value = List.of(_channels);
    _channelMessages.remove(channel);
    _userStore.removeChannel(channel);
      _scrollControllers.remove(channel)?.dispose();
      _channelsWithUnread.remove(channel);
      _channelsWithUnreadMentions.remove(channel);
      _unreadMentionsPerChannel.remove(channel);
      if (_selectedChannel == channel) {
        _selectedChannel = _channels.isNotEmpty ? _channels.last : null;
      }
    });
    _saveChannels();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  void _sendMessage() {
    if (_suggestions.isNotEmpty) {
      setState(() {
        _suggestions = [];
      });
    }

    final text = _messageController.text.trim();
    final channel = _selectedChannel;
    if (text.isEmpty ||
        channel == null ||
        _activePanel == OverlayPanel.mentions) {
      return;
    }

    if (!widget.twitchAuth.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connect an account to chat')),
      );
      return;
    }

    _lastSentText = text;
    _messageController.clear();

    final threadRoot = _openThreadRoot;
    if (threadRoot != null) {
      final threadMsgs = _computeThreadMessages();
      final lastMsg = threadMsgs.isNotEmpty ? threadMsgs.last : null;
      _doSendMessage(text, channel, replyTo: lastMsg);
    } else {
      _doSendMessage(text, channel);
    }
  }

  void _doSendMessage(
    String text,
    String channel, {
    TwitchMessage? replyTo,
  }) async {
    final auth = widget.twitchAuth;
    final reply = replyTo ?? _replyToMsg;

    // Handle slash commands via dedicated API endpoints.
    if (text.startsWith('/')) {
      _handleCommand(text, channel, auth);
      _focusNode.requestFocus();
      return;
    }

    if (!mounted) return;
    setState(() {
      _replyToMsg = null;
    });
    _focusNode.requestFocus();

    final userLogin = _currentUserLogin;
    if (userLogin == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Connect an account to chat')),
        );
      }
      return;
    }

    final String wireText;
    if (text == _lastTypedText[channel]) {
      final lastWire = _lastSentWireText[channel] ?? text;
      wireText = bypassTextDuplicate(lastWire);
    } else {
      wireText = text;
    }
    _lastTypedText[channel] = text;
    _lastSentWireText[channel] = wireText;

    // Try Helix API if available.
    if (_currentUserId != null && auth.isConfigured) {
      final broadcasterId =
          _channelUserIds[channel] ?? await TwitchApi.getUserId(auth, channel);
      if (broadcasterId != null) {
        try {
          final messageId = await TwitchApi.sendChatMessage(
            auth,
            broadcasterId: broadcasterId,
            senderId: _currentUserId!,
            message: wireText,
            replyParentMessageId: reply?.messageId,
          );
          if (messageId != null && mounted) {
            _ownMessageIds.add(messageId);
            _insertLocalMessage(text, channel, messageId, reply);
          }
        } catch (_) {}
        return;
      }
    }

    // IRC fallback — insert optimistically with temp ID.
    _insertLocalMessage(text, channel, null, reply);
    _irc.sendMessage(channel, wireText, replyParentMessageId: reply?.messageId);
  }

  void _onSendLongPress() {
    if (_lastSentText != null && _lastSentText!.isNotEmpty) {
      _messageController.text = _lastSentText!;
      _messageController.selection = TextSelection.fromPosition(
        TextPosition(offset: _messageController.text.length),
      );
      _focusNode.requestFocus();
    }
  }

  /// Handles slash commands by routing to the appropriate Twitch API endpoint.
  void _handleCommand(String text, String channel, TwitchAuth auth) async {
    final parts = text.split(RegExp(r'\s+'));
    final cmd = parts[0].toLowerCase();
    final args = parts.length > 1 ? parts.sublist(1) : [];

    // /me is the only IRC command still supported by Twitch (Feb 2023).
    // Send via IRC; the response comes back through EventSub/IRC.
    if (cmd == '/me') {
      if (_currentUserLogin != null && auth.isConfigured) {
        _irc.sendMessage(channel, text);
      }
      return;
    }

    final broadcasterId = _channelUserIds[channel];
    if (_currentUserId == null || broadcasterId == null || !auth.isConfigured) {
      _addSystemMessage(channel, 'Not authenticated or channel not joined.');
      return;
    }

    switch (cmd) {
      case '/color':
        if (args.isEmpty) {
          _addSystemMessage(
            channel,
            "Usage: /color <color> - Color must be one of Twitch's supported colors (blue, blue_violet, cadet_blue, chocolate, coral, dodger_blue, firebrick, golden_rod, green, hot_pink, orange_red, red, sea_green, spring_green, yellow_green) or a hex code (#000000) if you have Turbo or Prime.",
          );
          return;
        }
        final color = args.join(' ');
        final ok = await TwitchApi.updateUserChatColor(
          auth,
          userId: _currentUserId!,
          color: color,
        );
        if (ok) {
          _addSystemMessage(channel, 'Your color has been changed to $color');
        } else {
          _addSystemMessage(
            channel,
            'Failed to change color to $color - ${TwitchApi.lastError ?? "unknown error"}',
          );
        }

      case '/ban':
        if (args.isEmpty) {
          _addSystemMessage(channel, 'Usage: /ban <username> [reason]');
          return;
        }
        final targetLogin = args[0];
        final reason = args.length > 1 ? args.sublist(1).join(' ') : null;
        final targetId = await TwitchApi.getUserId(auth, targetLogin);
        if (targetId == null) {
          _addSystemMessage(channel, 'User "$targetLogin" not found.');
          return;
        }
        final ok = await TwitchApi.banUser(
          auth,
          broadcasterId: broadcasterId,
          moderatorId: _currentUserId!,
          userId: targetId,
          reason: reason,
        );
        if (ok) {
          _addSystemMessage(channel, '$targetLogin has been banned.');
        } else {
          _addSystemMessage(
            channel,
            'Failed to ban $targetLogin: ${TwitchApi.lastError ?? "unknown error"}',
          );
        }

      case '/unban':
        if (args.isEmpty) {
          _addSystemMessage(channel, 'Usage: /unban <username>');
          return;
        }
        final targetId = await TwitchApi.getUserId(auth, args[0]);
        if (targetId == null) {
          _addSystemMessage(channel, 'User "${args[0]}" not found.');
          return;
        }
        final ok = await TwitchApi.unbanUser(
          auth,
          broadcasterId: broadcasterId,
          moderatorId: _currentUserId!,
          userId: targetId,
        );
        if (ok) {
          _addSystemMessage(channel, '${args[0]} has been unbanned.');
        } else {
          _addSystemMessage(
            channel,
            'Failed to unban ${args[0]}: ${TwitchApi.lastError ?? "unknown error"}',
          );
        }

      case '/timeout':
        if (args.isEmpty) {
          _addSystemMessage(
            channel,
            'Usage: /timeout <username> [seconds] [reason]',
          );
          return;
        }
        final targetLogin = args[0];
        int duration = 600; // default 10 min
        String? reason;
        if (args.length > 1) {
          final parsed = int.tryParse(args[1]);
          if (parsed != null) {
            duration = parsed;
            if (args.length > 2) reason = args.sublist(2).join(' ');
          } else {
            reason = args.sublist(1).join(' ');
          }
        }
        final targetId = await TwitchApi.getUserId(auth, targetLogin);
        if (targetId == null) {
          _addSystemMessage(channel, 'User "$targetLogin" not found.');
          return;
        }
        final ok = await TwitchApi.banUser(
          auth,
          broadcasterId: broadcasterId,
          moderatorId: _currentUserId!,
          userId: targetId,
          duration: duration,
          reason: reason,
        );
        if (ok) {
          _addSystemMessage(
            channel,
            '$targetLogin timed out for ${duration}s.',
          );
        } else {
          _addSystemMessage(
            channel,
            'Failed to timeout $targetLogin: ${TwitchApi.lastError ?? "unknown error"}',
          );
        }

      case '/delete':
        if (args.isEmpty) {
          _addSystemMessage(channel, 'Usage: /delete <message_id>');
          return;
        }
        final ok = await TwitchApi.deleteChatMessage(
          auth,
          broadcasterId: broadcasterId,
          moderatorId: _currentUserId!,
          messageId: args[0],
        );
        if (ok) {
          _addSystemMessage(channel, 'Message deleted.');
        } else {
          _addSystemMessage(
            channel,
            'Failed to delete message: ${TwitchApi.lastError ?? "unknown error"}',
          );
        }

      case '/clear':
        final ok = await TwitchApi.deleteChatMessage(
          auth,
          broadcasterId: broadcasterId,
          moderatorId: _currentUserId!,
        );
        if (ok) {
          _addSystemMessage(channel, 'Chat cleared.');
        } else {
          _addSystemMessage(
            channel,
            'Failed to clear chat: ${TwitchApi.lastError ?? "unknown error"}',
          );
        }

      case '/announce':
        if (args.isEmpty) {
          _addSystemMessage(channel, 'Usage: /announce <message>');
          return;
        }
        final ok = await TwitchApi.sendChatAnnouncement(
          auth,
          broadcasterId: broadcasterId,
          moderatorId: _currentUserId!,
          message: args.join(' '),
        );
        if (!ok) {
          _addSystemMessage(
            channel,
            'Failed to announce: ${TwitchApi.lastError ?? "unknown error"}',
          );
        }

      case '/shoutout':
        if (args.isEmpty) {
          _addSystemMessage(channel, 'Usage: /shoutout <username>');
          return;
        }
        final targetId = await TwitchApi.getUserId(auth, args[0]);
        if (targetId == null) {
          _addSystemMessage(channel, 'User "${args[0]}" not found.');
          return;
        }
        final ok = await TwitchApi.sendShoutout(
          auth,
          broadcasterId: broadcasterId,
          moderatorId: _currentUserId!,
          targetUserId: targetId,
        );
        if (!ok) {
          _addSystemMessage(
            channel,
            'Failed to send shoutout: ${TwitchApi.lastError ?? "unknown error"}',
          );
        }

      default:
        _addSystemMessage(channel, 'Unknown command: $cmd');
    }
  }

  ScrollController _scrollCtrl(String channel) {
    return _scrollControllers.putIfAbsent(channel, () => ScrollController());
  }

  TwitchMessage? _findThreadRoot(TwitchMessage msg) {
    final channel = msg.channel;
    if (channel == null) return null;
    final msgs = _channelMessages[channel];
    if (msgs == null) return null;

    final hasReplies =
        msg.messageId != null &&
        msgs.any((m) => m.replyToParentId == msg.messageId);
    if (!hasReplies && msg.replyToParentId == null) return null;

    final visited = <String>{};
    TwitchMessage current = msg;
    while (current.replyToParentId != null &&
        !visited.contains(current.replyToParentId)) {
      visited.add(current.replyToParentId!);
      final parent = msgs
          .where((m) => m.messageId == current.replyToParentId)
          .firstOrNull;
      if (parent == null) break;
      current = parent;
    }
    return current;
  }

  Future<void> _showThreadView(TwitchMessage rootMsg) async {
    final channel = rootMsg.channel;
    if (channel == null) return;
    if (_activePanel != OverlayPanel.closed) await _closePanel();
    if (_selectedChannel != channel) {
      final idx = _channels.indexOf(channel);
      if (idx >= 0) _onChannelChanged(idx);
    }
    setState(() {
      _activePanel = OverlayPanel.thread;
      _openThreadRoot = rootMsg;
    });
    _threadPanelData.value = _ThreadPanelData(
      root: rootMsg,
      messages: _computeThreadMessages(),
      channel: channel,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _threadSheetCtrl.isAttached) {
        _threadSheetCtrl.animateTo(
          _fullHeightFraction,
          duration: _sheetAnimDuration,
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _showMentionsView() async {
    if (_activePanel != OverlayPanel.closed) await _closePanel();
    setState(() {
      _activePanel = OverlayPanel.mentions;
      _openThreadRoot = null;
    });
    _mentionsPanelData.value = _channelMessages[_mentionsChannel] ?? [];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _mentionsSheetCtrl.isAttached) {
        _mentionsSheetCtrl.animateTo(
          _fullHeightFraction,
          duration: _sheetAnimDuration,
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _showEmoteMenu() async {
    if (_activePanel != OverlayPanel.closed) await _closePanel();
    setState(() => _activePanel = OverlayPanel.emotes);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _emoteSheetCtrl.isAttached) {
        _emoteSheetCtrl.animateTo(
          _emoteMaxFraction,
          duration: _sheetAnimDuration,
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _onEmoteSelected(GenericEmote emote) {
    final text = _messageController.text;
    final pos = _messageController.selection.baseOffset;
    final insertPos = pos.clamp(0, text.length);
    _messageController.text =
        '${text.substring(0, insertPos)}${emote.code} ${text.substring(insertPos)}';
    _messageController.selection = TextSelection.collapsed(
      offset: insertPos + emote.code.length + 1,
    );
    _emoteManager.markEmoteUsed(emote);
  }

  Future<void> _closePanel() async {
    final panelToClose = _activePanel;
    if (panelToClose == OverlayPanel.closed) return;
    final ctrl = switch (panelToClose) {
      OverlayPanel.thread => _threadSheetCtrl,
      OverlayPanel.mentions => _mentionsSheetCtrl,
      OverlayPanel.emotes => _emoteSheetCtrl,
      OverlayPanel.closed => null,
    };
    if (ctrl == null || !ctrl.isAttached) return;
    await ctrl.animateTo(
      0.0,
      duration: _sheetCloseDuration,
      curve: Curves.easeOut,
    );
    if (mounted) {
      setState(() {
        _activePanel = OverlayPanel.closed;
        _openThreadRoot = null;
        _threadPanelData.value = null;
        _mentionsPanelData.value = null;
      });
    }
  }

  /// Wraps [child] so it renders at its full expanded height and translates
  /// vertically as the sheet opens/closes — true slide-up/down motion.
  ///
  /// At size = 0 the content is shifted down by its full height (invisible
  /// below the viewport). As the sheet grows to [maxSize] the content rises
  /// into view, bottom-anchored.
  ///
  /// [totalAvailH] is the pixel height of the Positioned area that the sheet
  /// occupies. Captured once per layout from a LayoutBuilder wrapping the sheet.
  ///
  /// Uses [OverflowBox] so the child always lays out at full height regardless
  /// of sheet box size, preventing Column overflow during animation. [ClipRect]
  /// clips to the sheet box boundary. [AnimatedBuilder] and [FractionalTranslation]
  /// drive the per-frame offset.
  Widget _buildSlideUpContent({
    required DraggableScrollableController controller,
    required double totalAvailH,
    required double maxSize,
    required Widget child,
  }) {
    final contentH = maxSize * totalAvailH;
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.bottomCenter,
        minHeight: contentH,
        maxHeight: contentH,
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, child) {
            final size = controller.isAttached ? controller.size : 0.0;
            final closedFraction =
                maxSize <= 0
                    ? 0.0
                    : (1 - (size / maxSize)).clamp(0.0, 1.0);
            return FractionalTranslation(
              translation: Offset(0, closedFraction),
              child: child!,
            );
          },
          child: child,
        ),
      ),
    );
  }

  List<TwitchMessage> _computeThreadMessages() {
    final root = _openThreadRoot;
    if (root == null) return const [];
    final channel = root.channel;
    if (channel == null) return const [];
    final allMsgs = _channelMessages[channel] ?? [];

    final threadIds = <String>{};
    final threadMsgs = <TwitchMessage>[];
    if (root.messageId != null) threadIds.add(root.messageId!);

    bool added;
    do {
      added = false;
      for (final m in allMsgs) {
        if (m.messageId != null &&
            threadIds.contains(m.messageId) &&
            !threadMsgs.contains(m)) {
          threadMsgs.add(m);
          added = true;
        }
        if (m.replyToParentId != null &&
            threadIds.contains(m.replyToParentId) &&
            !threadMsgs.contains(m)) {
          if (m.messageId != null) threadIds.add(m.messageId!);
          threadMsgs.add(m);
          added = true;
        }
      }
    } while (added);

    threadMsgs.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return threadMsgs;
  }

  void _showUserProfile(String username, String? userId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => UserProfileSheet(
        username: username,
        userId: userId,
        twitchAuth: widget.twitchAuth,
        messageController: _messageController,
        focusNode: _focusNode,
        onClose: () => Navigator.pop(ctx),
      ),
    );
  }

  void _showEmoteSheet(GenericEmote emote) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => EmoteSheet(
        emote: emote,
        messageController: _messageController,
        focusNode: _focusNode,
        onClose: () => Navigator.pop(ctx),
      ),
    );
  }

  void _onChannelChanged(int index) {
    final channel = _channels[index];
    if (_selectedChannel == channel) return;
    setState(() {
      _selectedChannel = channel;
      _channelsWithUnread.remove(channel);
      _channelsWithUnreadMentions.remove(channel);
      final cleared = _unreadMentionsPerChannel.remove(channel) ?? 0;
      if (cleared > 0) {
        _unreadMentions -= cleared;
        if (_unreadMentions < 0) _unreadMentions = 0;
      }
      if (_activePanel == OverlayPanel.emotes) {
        _activePanel = OverlayPanel.closed;
      }
      _openThreadRoot = null;
      if (_suggestions.isNotEmpty) {
        _suggestions = [];
      }
    });
    _closePanel();
  }

  List<TwitchMessage> _messages(String channel) {
    return _channelMessages[channel] ?? [];
  }

  void _truncateChannelMessages(String channel) {
    final maxMessages = _maxMessagesPerChannel;
    if (maxMessages <= 0) return;
    final msgs = _channelMessages[channel];
    if (msgs == null || msgs.length <= maxMessages) return;

    final threadParentIds = <String>{};
    for (final m in msgs) {
      if (m.replyToParentId != null) {
        threadParentIds.add(m.replyToParentId!);
      }
    }

    final toRemove = <int>[];
    int extra = msgs.length - maxMessages;
    for (int i = msgs.length - 1; i >= 0 && extra > 0; i--) {
      final m = msgs[i];
      final inThread =
          (m.messageId != null && threadParentIds.contains(m.messageId!)) ||
          m.replyToParentId != null;
      if (!inThread) {
        toRemove.add(i);
        extra--;
      }
    }

    for (final i in toRemove) {
      msgs.removeAt(i);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return PopScope(
      canPop: _activePanel == OverlayPanel.closed,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closePanel();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final statusBarH = MediaQuery.of(context).padding.top;
                  if (bottomInset == 0) {
                    _emoteSheetBoxHeight = constraints.maxHeight;
                  }
                  final sheetBoxHeight =
                      (_emoteSheetBoxHeight ?? constraints.maxHeight) -
                      statusBarH;
                  return Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      Column(
                        children: [
                          SafeArea(
                            bottom: false,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              child: Row(
                                children: [
                                  const Spacer(),
                                  IconButton(
                                    icon: const Icon(Icons.add),
                                    tooltip: 'Join channel',
                                    onPressed: _addChannelDialog,
                                  ),
                                  IconButton(
                                    icon: Icon(
                                      Icons.notifications_active,
                                      color: _unreadMentions > 0
                                          ? theme.colorScheme.error
                                          : null,
                                    ),
                                    tooltip: 'Mentions',
                                    onPressed: () {
                                      _unreadMentions = 0;
                                      _channelsWithUnreadMentions.clear();
                                      _unreadMentionsPerChannel.clear();
                                      if (mounted) setState(() {});
                                      if (_activePanel ==
                                          OverlayPanel.mentions) {
                                        _closePanel();
                                      } else {
                                        _showMentionsView();
                                      }
                                    },
                                  ),
                                  SettingsButton(
                                    twitchAuth: widget.twitchAuth,
                                    onThemeChanged: widget.onThemeChanged,
                                    channelNotifier: _channelNotifier,
                                    onLeaveChannel: _removeChannel,
                                    onAddChannel: _addChannel,
                                    onSettingsClosed: () {
                                      if (mounted) setState(() {});
                                      _connect();
                                    },
                                    eventSubMessageStream: _eventSub.onMessage,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Expanded(
                            child: _channels.isNotEmpty
                                ? ListenableBuilder(
                                    listenable: _chatVersion,
                                    builder: (context, _) => TabbedLayout(
                                      tabs: _channels,
                                      selectedIndex: _channels.indexOf(
                                        _selectedChannel ?? '',
                                      ),
                                      onSelectedIndexChanged: _onChannelChanged,
                                      pageBuilder: (_, i) =>
                                          _buildChat(_channels[i]),
                                      tabBuilder: (_, i) {
                                        final channel = _channels[i];
                                        final selected =
                                            channel == _selectedChannel;
                                        final hasUnreadMention =
                                            _channelsWithUnreadMentions
                                                .contains(channel);
                                        return Stack(
                                          clipBehavior: Clip.none,
                                          children: [
                                            Text(
                                              channel,
                                              style: TextStyle(
                                                fontSize: 14,
                                                fontWeight:
                                                    selected ||
                                                    _channelsWithUnread
                                                        .contains(channel)
                                                    ? FontWeight.w600
                                                    : FontWeight.normal,
                                                color: selected
                                                    ? theme.colorScheme.primary
                                                    : _channelsWithUnread
                                                        .contains(channel)
                                                    ? Colors.white
                                                    : null,
                                              ),
                                            ),
                                            if (hasUnreadMention && !selected)
                                              Positioned(
                                                top: -2,
                                                right: -4,
                                                child: Container(
                                                  key: const Key(
                                                    'unread_mention_dot',
                                                  ),
                                                  width: 6,
                                                  height: 6,
                                                  decoration: BoxDecoration(
                                                    color:
                                                        theme
                                                            .colorScheme
                                                            .error,
                                                    shape: BoxShape.circle,
                                                  ),
                                                ),
                                              ),
                                          ],
                                        );
                                      },
                                    ),
                                  )
                                : _buildEmpty(),
                          ),
                        ],
                      ),
                      // Thread sheet — always mounted, full height below status bar.
                      Positioned(
                        top: statusBarH,
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final totalAvailH = constraints.maxHeight;
                            return IgnorePointer(
                              ignoring: _activePanel != OverlayPanel.thread,
                              child: DraggableScrollableSheet(
                                controller: _threadSheetCtrl,
                                initialChildSize: 0,
                                minChildSize: 0,
                                maxChildSize: _fullHeightFraction,
                                snap: true,
                                builder: (context, scrollController) {
                                  final sheetTheme = Theme.of(context);
                                  return _buildSlideUpContent(
                                    controller: _threadSheetCtrl,
                                    totalAvailH: totalAvailH,
                                    maxSize: _fullHeightFraction,
                                    child: RepaintBoundary(
                                      child: Material(
                                        color: sheetTheme.scaffoldBackgroundColor,
                                        child: _ThreadPanelWidget(
                                          key: const ValueKey('thread_panel'),
                                          data: _threadPanelData,
                                          uiScale: 1.0,
                                          onClose: _closePanel,
                                          onLongPress: _showThreadMessageMenu,
                                          buildBadgeSpans: _buildBadgeSpans,
                                          buildMessageSpans: _buildMessageSpans,
                                          scrollController: scrollController,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            );
                          },
                        ),
                      ),
                      // Mentions sheet — always mounted, full height below
                      // status bar.
                      Positioned(
                        top: statusBarH,
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final totalAvailH = constraints.maxHeight;
                            return IgnorePointer(
                              ignoring: _activePanel != OverlayPanel.mentions,
                              child: DraggableScrollableSheet(
                                controller: _mentionsSheetCtrl,
                                initialChildSize: 0,
                                minChildSize: 0,
                                maxChildSize: _fullHeightFraction,
                                snap: true,
                                builder: (context, scrollController) {
                                  final sheetTheme = Theme.of(context);
                                  return _buildSlideUpContent(
                                    controller: _mentionsSheetCtrl,
                                    totalAvailH: totalAvailH,
                                    maxSize: _fullHeightFraction,
                                    child: RepaintBoundary(
                                      child: Material(
                                        color: sheetTheme.scaffoldBackgroundColor,
                                        child: _MentionsPanelWidget(
                                          key: const ValueKey('mentions_panel'),
                                          messages: _mentionsPanelData,
                                          uiScale: 1.0,
                                          onClose: _closePanel,
                                          buildBadgeSpans: _buildBadgeSpans,
                                          buildMessageSpans: _buildMessageSpans,
                                          scrollController: scrollController,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            );
                          },
                        ),
                      ),
                      // Emote sheet — always mounted, always 60%.
                      // Box height is fixed (captured without keyboard);
                      // bottom: 0 stays anchored to the Stack's bottom edge
                      // which already moves up when the keyboard shrinks
                      // the Expanded area (same as the input below it).
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        height: sheetBoxHeight,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final totalAvailH = constraints.maxHeight;
                            return IgnorePointer(
                              ignoring: _activePanel != OverlayPanel.emotes,
                              child: DraggableScrollableSheet(
                                controller: _emoteSheetCtrl,
                                initialChildSize: 0,
                                minChildSize: 0,
                                maxChildSize: _emoteMaxFraction,
                                snap: true,
                                builder: (context, scrollController) {
                                  final sheetTheme = Theme.of(context);
                                  return _buildSlideUpContent(
                                    controller: _emoteSheetCtrl,
                                    totalAvailH: totalAvailH,
                                    maxSize: _emoteMaxFraction,
                                    child: RepaintBoundary(
                                      child: Material(
                                        color: sheetTheme.scaffoldBackgroundColor,
                                        child: _EmoteMenuPanelWidget(
                                          key: const ValueKey('emote_panel'),
                                          isActive: _activePanel == OverlayPanel.emotes,
                                          uiScale: 1.0,
                                          selectedChannel: _selectedChannel,
                                          onEmoteSelected: _onEmoteSelected,
                                          onClose: _closePanel,
                                          emoteManager: _emoteManager,
                                          scrollController: scrollController,
                                          sheetCtrl: _emoteSheetCtrl,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            );
                          },
                        ),
                      ),

                      // Autocomplete dropdown — floats above chat, anchored just
                      // above the message input, 60% width like DankChat's popup.
                      Positioned(
                        bottom: 0,
                        left: 0,
                        child: SizedBox(
                          width: (MediaQuery.of(context).size.width * 0.6)
                              .clamp(0.0, 340.0),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: min(
                                MediaQuery.of(context).size.height * 0.25,
                                192.0,
                              ),
                            ),
                            child: AutocompleteDropdown(
                              suggestions: _suggestions,
                              onSelect: _onSuggestionSelected,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: EdgeInsets.only(bottom: bottomInset),
              child: ColoredBox(
                color: theme.scaffoldBackgroundColor,
                child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                MessageInput(
                      controller: _messageController,
                      focusNode: _focusNode,
                      onSend: _sendMessage,
                      onSendLongPress: _onSendLongPress,
                      onEmoteToggle: () {
                        if (_activePanel == OverlayPanel.emotes) {
                          _closePanel();
                        } else {
                          _showEmoteMenu();
                        }
                      },
                      replyToMsg: _replyToMsg,
                      onCancelReply: () => setState(() => _replyToMsg = null),
                      enabled:
                          _activePanel != OverlayPanel.mentions &&
                          widget.twitchAuth.isConfigured,
                      hintText: !widget.twitchAuth.isConfigured
                          ? 'Connect an account to chat'
                          : _activePanel == OverlayPanel.thread
                          ? 'Reply to thread...'
                          : _activePanel == OverlayPanel.mentions
                          ? 'Type a message...'
                          : null,
                    ),
                    if (_chatStatus[_selectedChannel] != null &&
                        _chatStatus[_selectedChannel]!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(
                          left: 12,
                          right: 12,
                          bottom: 4,
                        ),
                        child: Text(
                          _chatStatus[_selectedChannel]!,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    if (!widget.twitchAuth.isConfigured) {
      return const Center(
        child: Text('Configure Twitch credentials in Settings first'),
      );
    }
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey),
          SizedBox(height: 16),
          Text('Press + to join a channel'),
        ],
      ),
    );
  }

  List<InlineSpan> _buildMessageSpans(
    TwitchMessage msg,
    String channel,
    Color surface, {
    bool colored = false,
    double textScale = 1.0,
  }) {
    msg.cachedSpans ??= _computeMessageSpans(msg, channel, scale: textScale);
    if (colored) {
      return [
        ...msg.cachedSpans!.map((span) {
          if (span is TextSpan) {
            return TextSpan(
              text: span.text,
              style: TextStyle(
                fontSize: 14 * textScale,
                color: parseColor(msg.color, background: surface),
                decoration: TextDecoration.none,
              ),
              recognizer: span.recognizer,
            );
          }
          return span;
        }),
      ];
    }
    return msg.cachedSpans!;
  }

  List<InlineSpan> _computeMessageSpans(
    TwitchMessage msg,
    String channel, {
    double scale = 1.0,
  }) {
    final channelEmotes = _emoteManager.byCode(channel);
    return EmoteText.build(
      text: msg.text,
      twitchPositions: msg.emotePositions,
      channelEmotes: channelEmotes,
      onEmoteTap: _showEmoteSheet,
      scale: scale,
    );
  }

  List<WidgetSpan> _buildBadgeSpans(
    String channel,
    TwitchMessage msg, {
    double badgeScale = 1.0,
  }) {
    final badgeSize = 18.0 * badgeScale;
    final spans = <WidgetSpan>[];

    // Shared chat source badge (circular avatar, prepended)
    if (msg.sourceBroadcasterId != null) {
      final avatarUrl = _badgeService.resolveChannelAvatar(
        msg.sourceBroadcasterId!,
      );
      if (avatarUrl != null) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Semantics(
              label: msg.sourceBroadcasterName ?? 'shared chat',
              child: Padding(
                padding: const EdgeInsets.only(right: 2),
                child: ClipOval(
                  child: CachedNetworkImage(
                    imageUrl: avatarUrl,
                    width: badgeSize,
                    height: badgeSize,
                    fit: BoxFit.cover,
                    fadeInDuration: Duration.zero,
                    placeholder: (_, _) =>
                        SizedBox(width: badgeSize, height: badgeSize),
                    errorWidget: (_, url, error) {
                      debugPrint(
                        'Shared chat badge image failed: $url — $error',
                      );
                      return SizedBox(width: badgeSize, height: badgeSize);
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }

    // Standard badges
    final badges = msg.badges;
    if (badges != null) {
      for (final badge in badges) {
        final url = _badgeService.resolveBadgeUrl(
          channel,
          badge.setId,
          badge.versionId,
        );
        if (url == null) continue;
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Semantics(
              label: badge.setId,
              child: Padding(
                padding: const EdgeInsets.only(right: 2),
                child: CachedNetworkImage(
                  imageUrl: url,
                  width: badgeSize,
                  height: badgeSize,
                  fit: BoxFit.contain,
                  fadeInDuration: Duration.zero,
                  placeholder: (_, _) =>
                      SizedBox(width: badgeSize, height: badgeSize),
                  errorWidget: (_, url, error) {
                    debugPrint('Badge image load failed: $url — $error');
                    return SizedBox(width: badgeSize, height: badgeSize);
                  },
                ),
              ),
            ),
          ),
        );
      }
    }
    return spans;
  }

  Widget _buildChat(String channel) {
    final msgs = _frozenSnapshot[channel] ?? _messages(channel);
    final surface = Theme.of(context).colorScheme.surface;
    final systemScale = MediaQuery.textScalerOf(context).scale(1.0);
    final s = 1.0 * systemScale;
    final atBottom = _isAtBottom[channel] ?? true;

    if (msgs.isEmpty) {
      return const Center(child: Text('No messages yet'));
    }

    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollUpdateNotification) {
              final scrolledUp = notification.metrics.pixels > 50.0;
              if (scrolledUp && (_isAtBottom[channel] ?? true)) {
                setState(() {
                  _isAtBottom[channel] = false;
                  _frozenSnapshot[channel] =
                      List.of(_channelMessages[channel] ?? []);
                });
              } else if (!scrolledUp && !(_isAtBottom[channel] ?? true)) {
                setState(() {
                  _isAtBottom[channel] = true;
                  _frozenSnapshot.remove(channel);
                });
              }
            }
            return false;
          },
          child: ScrollbarTheme(
            data: const ScrollbarThemeData(thickness: WidgetStatePropertyAll(0)),
            child: ListView.builder(
              key: ValueKey(channel),
              controller: _scrollCtrl(channel),
              reverse: true,
              itemCount: msgs.length,
              itemBuilder: (_, i) {
                final msg = msgs[i];

                final key = msg.messageId != null
                    ? _messageKeys.putIfAbsent(
                        '$channel:${msg.messageId}',
                        () => GlobalKey(),
                      )
                    : null;

                Widget body;
                final ts =
                    '${msg.timestamp.toLocal().hour.toString().padLeft(2, '0')}:${msg.timestamp.toLocal().minute.toString().padLeft(2, '0')}';

                if (msg.isSystem) {
                  body = ChatMessageTile(
                    timestamp: ts,
                    isHistory: msg.isHistory,
                    children: parseTextWithLinks(msg.text),
                    bodyColor: msg.bodyColor,
                    useTextDecorationNone: true,
                    bodyFontSize: 14 * s,
                    timestampFontSize: 14 * s,
                    semanticsLabel: msg.text,
                  );
                } else {
                  body = ChatMessageTile(
                    timestamp: ts,
                    deleted: msg.deleted,
                    isHistory: msg.isHistory,
                    bodyColor: msg.bodyColor,
                    bodyFontSize: 14 * s,
                    timestampFontSize: 14 * s,
                    children: [
                      ..._buildBadgeSpans(channel, msg, badgeScale: s),
                      TextSpan(
                        text: msg.isAction ? '${msg.username} ' : '${msg.username}: ',
                        style: TextStyle(
                          fontSize: 14 * s,
                          fontWeight: FontWeight.w600,
                          color: parseColor(msg.color, background: surface),
                          decoration: TextDecoration.none,
                        ),
                        recognizer: TapGestureRecognizer()
                          ..onTap = () => _showUserProfile(msg.username, msg.userId),
                      ),
                      if (msg.isAction)
                        ..._buildMessageSpans(
                          msg,
                          channel,
                          surface,
                          colored: true,
                          textScale: s,
                        )
                      else
                        ..._buildMessageSpans(msg, channel, surface, textScale: s),
                    ],
                    useTextDecorationNone: true,
                    isHighlighted: msg.isHighlighted,
                    replyIndicator: msg.replyToUser != null
                        ? _buildReplyIndicator(msg)
                        : null,
                    onLongPress: () => _showMessageMenu(msg),
                    semanticsLabel: msg.isHighlighted
                        ? 'Mention: $ts ${msg.username}: ${msg.text}'
                        : '$ts ${msg.username}: ${msg.text}',
                  );
                }

                if (key != null) {
                  body = Container(key: key, child: body);
                }
                return body;
              },
            ),
          ),
        ),
        if (!atBottom)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton(
              heroTag: 'scroll_down_$channel',
              onPressed: () {
                _isAtBottom[channel] = true;
                _frozenSnapshot.remove(channel);
                if (mounted) setState(() {});
                _scrollCtrl(channel).jumpTo(0);
              },
              child: const Icon(Icons.keyboard_arrow_down),
            ),
          ),
      ],
    );
  }

  Widget _buildReplyIndicator(TwitchMessage msg) {
    final replyPreview = msg.replyToText ?? '';
    final preview = replyPreview.length > 60
        ? '${replyPreview.substring(0, 60)}…'
        : replyPreview;
    return Padding(
      padding: const EdgeInsets.only(left: 12, top: 2),
      child: GestureDetector(
        onTap: () {
          final root = _findThreadRoot(msg);
          if (root != null) _showThreadView(root);
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.subdirectory_arrow_right,
              size: 14,
              color: Colors.grey[500],
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                'replying to ${msg.replyToUser ?? 'unknown'}: $preview',
                style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool isMention(String text, String login) {
  final words = text.split(RegExp(r'[\s,;:.!?()\[\]{}<>"/\\|@#$%^&*+=~`]+'));
  for (final w in words) {
    final lower = w.toLowerCase();
    if (lower == '@$login' || lower == login) return true;
  }
  return false;
}

class _ThreadPanelData {
  final TwitchMessage root;
  final List<TwitchMessage> messages;
  final String channel;
  _ThreadPanelData({
    required this.root,
    required this.messages,
    required this.channel,
  });
}

class _ThreadPanelWidget extends StatefulWidget {
  final ScrollController scrollController;
  final ValueListenable<_ThreadPanelData?> data;
  final double uiScale;
  final VoidCallback onClose;
  final void Function(TwitchMessage) onLongPress;
  final List<WidgetSpan> Function(String, TwitchMessage, {double badgeScale})
  buildBadgeSpans;
  final List<InlineSpan> Function(
    TwitchMessage,
    String,
    Color, {
    bool colored,
    double textScale,
  })
  buildMessageSpans;

  const _ThreadPanelWidget({
    required this.scrollController,
    required this.data,
    required this.uiScale,
    required this.onClose,
    required this.onLongPress,
    required this.buildBadgeSpans,
    required this.buildMessageSpans,
    super.key,
  });

  @override
  State<_ThreadPanelWidget> createState() => _ThreadPanelWidgetState();
}

class _ThreadPanelWidgetState extends State<_ThreadPanelWidget> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_ThreadPanelData?>(
      valueListenable: widget.data,
      builder: (context, data, _) {
        final theme = Theme.of(context);
        final surface = theme.colorScheme.surface;
        final systemScale = MediaQuery.textScalerOf(context).scale(1.0);
        final s = widget.uiScale * systemScale;

        if (data == null) return const SizedBox.shrink();

        final threadMsgs = data.messages;

        return Material(
          color: theme.scaffoldBackgroundColor,
          clipBehavior: Clip.hardEdge,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Material(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: 'Close reply thread',
                        onPressed: widget.onClose,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'Reply Thread',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Divider(height: 1, color: theme.dividerColor),
              Expanded(
                child: threadMsgs.isEmpty
                    ? ListView(
                        controller: widget.scrollController,
                        padding: const EdgeInsets.only(bottom: 8),
                        children: const [
                          Center(child: Text('No messages found')),
                        ],
                      )
                    : ListView.builder(
                        controller: widget.scrollController,
                        physics: const ClampingScrollPhysics(),
                        reverse: true,
                        padding: const EdgeInsets.only(bottom: 8),
                        itemCount: threadMsgs.length,
                        itemBuilder: (_, i) {
                          final msg = threadMsgs[threadMsgs.length - 1 - i];
                          final ts =
                              '${msg.timestamp.toLocal().hour.toString().padLeft(2, '0')}:${msg.timestamp.toLocal().minute.toString().padLeft(2, '0')}';

                          if (msg.isSystem) {
                            return ChatMessageTile(
                              timestamp: ts,
                              isHistory: msg.isHistory,
                              children: [TextSpan(text: msg.text)],
                              timestampFontSize: 13 * s,
                              bodyFontSize: 13 * s,
                              bodyColor: msg.bodyColor,
                              semanticsLabel: msg.text,
                            );
                          }

                          return ChatMessageTile(
                            timestamp: ts,
                            deleted: msg.deleted,
                            isHistory: msg.isHistory,
                            bodyColor: msg.bodyColor,
                            bodyFontSize: 14 * s,
                            timestampFontSize: 14 * s,
                            children: [
                              if (msg.isAction) ...[
                                ...widget.buildBadgeSpans(
                                  data.channel,
                                  msg,
                                  badgeScale: s,
                                ),
                                TextSpan(
                                  text: '${msg.username} ',
                                  style: TextStyle(
                                    fontSize: 14 * s,
                                    fontWeight: FontWeight.w600,
                                    color: parseColor(
                                      msg.color,
                                      background: surface,
                                    ),
                                  ),
                                ),
                                ...widget.buildMessageSpans(
                                  msg,
                                  data.channel,
                                  surface,
                                  colored: true,
                                  textScale: s,
                                ),
                              ] else ...[
                                ...widget.buildBadgeSpans(
                                  data.channel,
                                  msg,
                                  badgeScale: s,
                                ),
                                TextSpan(
                                  text: '${msg.username}: ',
                                  style: TextStyle(
                                    fontSize: 14 * s,
                                    fontWeight: FontWeight.w600,
                                    color: parseColor(
                                      msg.color,
                                      background: surface,
                                    ),
                                  ),
                                ),
                                ...widget.buildMessageSpans(
                                  msg,
                                  data.channel,
                                  surface,
                                  textScale: s,
                                ),
                              ],
                            ],
                            onLongPress: () => widget.onLongPress(msg),
                            semanticsLabel: msg.isHighlighted
                                ? 'Mention: $ts ${msg.username}: ${msg.text}'
                                : '$ts ${msg.username}: ${msg.text}',
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MentionsPanelWidget extends StatefulWidget {
  final ScrollController scrollController;
  final ValueListenable<List<TwitchMessage>?> messages;
  final double uiScale;
  final VoidCallback onClose;
  final List<WidgetSpan> Function(String, TwitchMessage, {double badgeScale})
  buildBadgeSpans;
  final List<InlineSpan> Function(
    TwitchMessage,
    String,
    Color, {
    bool colored,
    double textScale,
  })
  buildMessageSpans;

  const _MentionsPanelWidget({
    required this.scrollController,
    required this.messages,
    required this.uiScale,
    required this.onClose,
    required this.buildBadgeSpans,
    required this.buildMessageSpans,
    super.key,
  });

  @override
  State<_MentionsPanelWidget> createState() => _MentionsPanelWidgetState();
}

class _MentionsPanelWidgetState extends State<_MentionsPanelWidget> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<TwitchMessage>?>(
      valueListenable: widget.messages,
      builder: (context, msgs, _) {
        final theme = Theme.of(context);
        final surface = theme.colorScheme.surface;
        final systemScale = MediaQuery.textScalerOf(context).scale(1.0);
        final s = widget.uiScale * systemScale;

        final messageList = msgs ?? [];

        if (msgs == null) return const SizedBox.shrink();

        return Material(
          color: theme.scaffoldBackgroundColor,
          clipBehavior: Clip.hardEdge,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Material(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back),
                        tooltip: 'Back',
                        onPressed: widget.onClose,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'Mentions / Whispers',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Divider(height: 1, color: theme.dividerColor),
              Expanded(
                child: messageList.isEmpty
                    ? CustomScrollView(
                        controller: widget.scrollController,
                        slivers: const [
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(
                                child: Text('No mentions or whispers')),
                          ),
                        ],
                      )
                    : ListView.builder(
                        controller: widget.scrollController,
                        physics: const ClampingScrollPhysics(),
                        reverse: true,
                        padding: const EdgeInsets.only(bottom: 8),
                        itemCount: messageList.length,
                        itemBuilder: (_, i) {
                          final msg = messageList[messageList.length - 1 - i];
                          final ts =
                              '${msg.timestamp.toLocal().hour.toString().padLeft(2, '0')}:${msg.timestamp.toLocal().minute.toString().padLeft(2, '0')}';

                          if (msg.isSystem) {
                            return ChatMessageTile(
                              timestamp: ts,
                              isHistory: msg.isHistory,
                              children: [TextSpan(text: msg.text)],
                              timestampFontSize: 13 * s,
                              bodyFontSize: 13 * s,
                              bodyColor: msg.bodyColor,
                              semanticsLabel: msg.text,
                            );
                          }

                          final channel = msg.channel ?? '';

                          return ChatMessageTile(
                            timestamp: ts,
                            deleted: msg.deleted,
                            isHistory: msg.isHistory,
                            bodyColor: msg.bodyColor,
                            bodyFontSize: 14 * s,
                            timestampFontSize: 14 * s,
                            children: [
                              if (msg.isAction) ...[
                                ...widget.buildBadgeSpans(
                                  channel,
                                  msg,
                                  badgeScale: s,
                                ),
                                TextSpan(
                                  text: '${msg.username} ',
                                  style: TextStyle(
                                    fontSize: 14 * s,
                                    fontWeight: FontWeight.w600,
                                    color: parseColor(
                                      msg.color,
                                      background: surface,
                                    ),
                                  ),
                                ),
                                ...widget.buildMessageSpans(
                                  msg,
                                  channel,
                                  surface,
                                  colored: true,
                                  textScale: s,
                                ),
                              ] else ...[
                                ...widget.buildBadgeSpans(
                                  channel,
                                  msg,
                                  badgeScale: s,
                                ),
                                TextSpan(
                                  text: '${msg.username}: ',
                                  style: TextStyle(
                                    fontSize: 14 * s,
                                    fontWeight: FontWeight.w600,
                                    color: parseColor(
                                      msg.color,
                                      background: surface,
                                    ),
                                  ),
                                ),
                                ...widget.buildMessageSpans(
                                  msg,
                                  channel,
                                  surface,
                                  textScale: s,
                                ),
                              ],
                            ],
                            semanticsLabel: msg.isHighlighted
                                ? 'Mention: $ts ${msg.username}: ${msg.text}'
                                : '$ts ${msg.username}: ${msg.text}',
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EmoteMenuPanelWidget extends StatefulWidget {
  final ScrollController scrollController;
  final bool isActive;
  final double uiScale;
  final String? selectedChannel;
  final void Function(GenericEmote) onEmoteSelected;
  final VoidCallback onClose;
  final EmoteManager emoteManager;
  final DraggableScrollableController sheetCtrl;

  const _EmoteMenuPanelWidget({
    required this.scrollController,
    required this.isActive,
    required this.sheetCtrl,
    required this.uiScale,
    required this.selectedChannel,
    required this.onEmoteSelected,
    required this.onClose,
    required this.emoteManager,
    super.key,
  });

  @override
  State<_EmoteMenuPanelWidget> createState() => _EmoteMenuPanelWidgetState();
}

class _EmoteMenuPanelWidgetState extends State<_EmoteMenuPanelWidget> {
  int _emoteTabIndex = 0;
  List<GenericEmote> _cachedRecentEmotes = [];
  bool _recentEmotesLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadRecentEmotes();
    widget.emoteManager.addListener(_loadRecentEmotes);
  }

  @override
  void dispose() {
    widget.emoteManager.removeListener(_loadRecentEmotes);
    super.dispose();
  }

  Future<void> _loadRecentEmotes() async {
    final recent = await widget.emoteManager.recentEmotes();
    if (mounted) {
      setState(() {
        _cachedRecentEmotes = recent;
        _recentEmotesLoaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isActive) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        children: [
          GestureDetector(
            key: const Key('emote_panel_handle'),
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (details) {
              final newPixels = widget.sheetCtrl.pixels - details.primaryDelta!;
              final newSize = widget.sheetCtrl.pixelsToSize(newPixels).clamp(0.0, 1.0);
              if (widget.sheetCtrl.isAttached) {
                widget.sheetCtrl.jumpTo(newSize);
              }
            },
            onVerticalDragEnd: (details) {
              if (!widget.sheetCtrl.isAttached) return;
              final velocity = details.primaryVelocity ?? 0;
              if (widget.sheetCtrl.size < 0.3 || velocity > 400) {
                widget.onClose();
              } else {
                widget.sheetCtrl.animateTo(
                  _HomeScreenState._emoteMaxFraction,
                  duration: _HomeScreenState._sheetAnimDuration,
                  curve: Curves.easeOut,
                );
              }
            },
            child: Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 16),
              child: Center(
                child: SizedBox(
                  width: 32,
                  height: 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.grey,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: TabbedLayout(
              tabAlignment: Alignment.center,
              tabs: const ['Recent', 'Subs', 'Channel', 'Global'],
              selectedIndex: _emoteTabIndex,
              onSelectedIndexChanged: (i) => setState(() => _emoteTabIndex = i),
              pageBuilder: (_, i) => _buildEmoteTabPage(
                i,
                i == _emoteTabIndex ? widget.scrollController : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmoteTabPage(int tabIndex, ScrollController? scrollController) {
    switch (tabIndex) {
      case 0:
        return _buildEmoteRecentGrid(scrollController);
      case 1:
        return _buildEmoteSubsGrid(scrollController);
      case 2:
        return _buildEmoteChannelGrid(scrollController);
      case 3:
        return _buildEmoteGlobalGrid(scrollController);
      default:
        return const SizedBox();
    }
  }

  Widget _buildEmoteRecentGrid(ScrollController? scrollController) {
    if (!_recentEmotesLoaded) {
      return _buildEmoteEmptyState(
        scrollController,
        const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_cachedRecentEmotes.isEmpty) {
      return _buildEmoteEmptyState(
        scrollController,
        const Center(child: Text('No recently used emotes')),
      );
    }
    return _buildEmoteGrid(_cachedRecentEmotes, scrollController);
  }

  Widget _buildEmoteSubsGrid(ScrollController? scrollController) {
    final byChannel = widget.emoteManager.subscriberEmotesByChannel();
    if (byChannel.isEmpty) {
      return _buildEmoteEmptyState(
        scrollController,
        const Center(child: Text('No subscriber emotes available')),
      );
    }
    return CustomScrollView(
      controller: scrollController,
      slivers: [
        for (final entry in byChannel.entries) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(left: 8, top: 8, right: 8),
              child: Text(
                entry.key,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
          ),
          SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 5,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1,
            ),
            delegate: SliverChildBuilderDelegate(
              (_, i) => _buildEmoteGridItem(entry.value[i]),
              childCount: entry.value.length,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildEmoteChannelGrid(ScrollController? scrollController) {
    final channel = widget.selectedChannel ?? '';
    final emotes = widget.emoteManager.channelNonTwitchEmotes(channel);
    if (emotes.isEmpty) {
      return _buildEmoteEmptyState(
        scrollController,
        const Center(child: Text('No channel emotes')),
      );
    }
    return _buildEmoteGrid(emotes, scrollController);
  }

  Widget _buildEmoteGlobalGrid(ScrollController? scrollController) {
    final emotes = widget.emoteManager.globalEmotes();
    if (emotes.isEmpty) {
      return _buildEmoteEmptyState(
        scrollController,
        const Center(child: Text('No global emotes')),
      );
    }
    return _buildEmoteGrid(emotes, scrollController);
  }

  /// Keeps [scrollController] attached (so [DraggableScrollableController]
  /// stays usable) while ensuring [child] fills the viewport via
  /// [SliverFillRemaining] — otherwise a bare [Center] inside [ListView]
  /// shrink-wraps to its child and sits at the top.
  Widget _buildEmoteEmptyState(
    ScrollController? scrollController,
    Widget child,
  ) {
    if (scrollController == null) return child;
    return CustomScrollView(
      controller: scrollController,
      slivers: [
        SliverFillRemaining(child: child),
      ],
    );
  }

  Widget _buildEmoteGrid(
    List<GenericEmote> emotes,
    ScrollController? scrollController,
  ) {
    return GridView.builder(
      controller: scrollController,
      padding: const EdgeInsets.all(4),
      physics: const AlwaysScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 5,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: emotes.length,
      itemBuilder: (_, i) => _buildEmoteGridItem(emotes[i]),
    );
  }

  Widget _buildEmoteGridItem(GenericEmote emote) {
    return Material(
      type: MaterialType.transparency,
      clipBehavior: Clip.hardEdge,
      child: InkWell(
        onTap: () => widget.onEmoteSelected(emote),
        child: CachedNetworkImage(
          imageUrl: emote.url,
          fit: BoxFit.contain,
          placeholder: (_, _) => const SizedBox(),
          errorWidget: (_, _, _) => const Icon(Icons.broken_image, size: 20),
        ),
      ),
    );
  }
}

class _PendingLocal {
  final String channel;
  final String text;
  _PendingLocal(this.channel, this.text);
}
