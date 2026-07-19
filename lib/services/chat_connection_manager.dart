import 'dart:async';
import 'package:flutter/widgets.dart';
import '../models/generic_emote.dart';
import '../models/twitch_message.dart';
import '../color_utils.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../services/twitch_eventsub.dart';
import '../services/twitch_irc.dart';
import '../services/twitch_irc_read.dart';
import '../services/emote_manager.dart';
import '../services/twitch_badge_service.dart';
import '../services/user_store.dart';
import '../util/text_bypass.dart';

class ChatConnectionManager {
  final EventSubService eventSub;
  final IrcService irc;
  final IrcReadService ircRead;
  final TwitchBadgeService badgeService;
  final UserStore userStore;
  final TwitchAuth twitchAuth;

  final EmoteManager emoteManager;

  final Map<String, List<TwitchMessage>> channelMessages;
  final Map<String, GlobalKey> messageKeys;
  final Map<String, String> chatStatus;
  final Set<String> channelsWithUnread;
  final Set<String> channelsWithUnreadMentions;
  final Map<String, int> unreadMentionsPerChannel;
  final List<String> channels;
  final Set<String> historyLoaded;
  final Set<String> channelsEmotesResolved;
  final Map<String, String> channelUserIds;
  final Map<String, PendingLocal> pendingLocals;
  final Map<String, String> lastTypedText;
  final Map<String, String> lastSentWireText;
  final Set<String> ownMessageIds;
  final ValueNotifier<int> chatVersion;
  final String mentionsChannel;

  String? lastSentText;
  int localCounter = 0;
  EventSubStatus connectionStatus = EventSubStatus.disconnected;
  bool wasConnected = false;
  bool wasDisconnected = false;
  bool userTwitchEmotesLoaded = false;
  bool mounted = true;

  StreamSubscription<TwitchMessage>? messageSub;
  StreamSubscription<EventSubStatus>? statusSub;
  StreamSubscription<({String messageId, String targetUser, String channel})>?
  deleteSub;
  StreamSubscription<IrcBanEvent>? ircBanSub;
  StreamSubscription<IrcNoticeEvent>? ircNoticeSub;
  StreamSubscription<IrcNoticeEvent>? ircJtvSub;
  StreamSubscription<IrcMessage>? ircOwnMsgSub;
  StreamSubscription<String>? userColorSub;

  final VoidCallback onRebuild;
  final void Function(String, String) onSystemMessage;
  final Future<void> Function() loadUserTwitchEmotes;
  final int Function() getMaxMessagesPerChannel;
  final String? Function() getSelectedChannel;
  final int Function() getUnreadMentions;
  final void Function(int) setUnreadMentions;
  final String? Function() getCurrentUserLogin;
  final void Function(String?) setCurrentUserLogin;
  final String? Function() getCurrentUserId;
  final void Function(String?) setCurrentUserId;
  final String? Function() getCurrentUserColor;
  final void Function(String?) setCurrentUserColor;
  final void Function(String, String, TwitchAuth) onCommand;
  final TwitchMessage? Function() getReplyToMsg;
  final void Function(TwitchMessage?) setReplyToMsg;
  final void Function() onRequestFocus;
  final void Function(String) onShowSnackBar;

  ChatConnectionManager({
    required this.eventSub,
    required this.irc,
    required this.ircRead,
    required this.emoteManager,
    required this.badgeService,
    required this.userStore,
    required this.twitchAuth,
    required this.channelMessages,
    required this.messageKeys,
    required this.chatStatus,
    required this.channelsWithUnread,
    required this.channelsWithUnreadMentions,
    required this.unreadMentionsPerChannel,
    required this.channels,
    required this.historyLoaded,
    required this.channelsEmotesResolved,
    required this.channelUserIds,
    required this.pendingLocals,
    required this.lastTypedText,
    required this.lastSentWireText,
    required this.ownMessageIds,
    required this.chatVersion,
    required this.mentionsChannel,
    required this.onRebuild,
    required this.onSystemMessage,
    required this.loadUserTwitchEmotes,
    required this.getMaxMessagesPerChannel,
    required this.getSelectedChannel,
    required this.getUnreadMentions,
    required this.setUnreadMentions,
    required this.getCurrentUserLogin,
    required this.setCurrentUserLogin,
    required this.getCurrentUserId,
    required this.setCurrentUserId,
    required this.getCurrentUserColor,
    required this.setCurrentUserColor,
    required this.onCommand,
    required this.getReplyToMsg,
    required this.setReplyToMsg,
    required this.onRequestFocus,
    required this.onShowSnackBar,
  });

  void dispose() {
    mounted = false;
    messageSub?.cancel();
    statusSub?.cancel();
    deleteSub?.cancel();
    ircBanSub?.cancel();
    ircNoticeSub?.cancel();
    ircJtvSub?.cancel();
    ircOwnMsgSub?.cancel();
    userColorSub?.cancel();
  }

  void maybeAddConnected(String channel) {
    if (connectionStatus == EventSubStatus.connected &&
        historyLoaded.contains(channel)) {
      onSystemMessage(channel, 'Connected');
    }
  }

  void precacheMessageEmotes(TwitchMessage msg, String channel) {
    if (msg.isSystem || msg.isHistory) return;
    final channelEmotes = emoteManager.byCode(channel);
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
      emoteManager.enqueueSeenEmotes(found);
    }
  }

  Future<void> fetchChatStatus(String channel) async {
    final auth = twitchAuth;
    if (!auth.isConfigured) return;

    final userId = channelUserIds[channel];
    if (userId == null || getCurrentUserId() == null) return;

    final settings = await TwitchApi.getChatSettings(
      auth,
      userId,
      getCurrentUserId()!,
    );
    final stream = await TwitchApi.getStreamInfo(auth, userId);

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
    chatStatus[channel] = parts.isNotEmpty ? parts.join(' · ') : '';
    onRebuild();
  }

  void insertLocalMessage(
    String text,
    String channel,
    String? messageId,
    TwitchMessage? replyTo,
  ) {
    final login = getCurrentUserLogin();
    if (login == null) return;

    final useTempId = messageId == null;
    final effectiveId = useTempId ? 'local_${localCounter++}' : messageId;

    if (!useTempId && messageKeys.containsKey('$channel:$effectiveId')) {
      return;
    }

    final msg = TwitchMessage(
      username: login,
      text: text,
      channel: channel,
      messageId: effectiveId,
      color: getCurrentUserColor() ?? pickColor(login.toLowerCase()),
      userId: getCurrentUserId(),
      replyToParentId: replyTo?.messageId,
      replyToUser: replyTo?.username,
      replyToText: replyTo?.text,
    );
    channelMessages.putIfAbsent(channel, () => []);
    channelMessages[channel]!.insert(0, msg);
    if (useTempId) {
      pendingLocals[effectiveId] = PendingLocal(channel, text);
    }
    truncateChannelMessages(channel);
    if (!useTempId) {
      messageKeys.putIfAbsent('$channel:$messageId', () => GlobalKey());
    }
    chatVersion.value++;
    onRebuild();
  }

  void truncateChannelMessages(String channel) {
    final maxMessages = getMaxMessagesPerChannel();
    if (maxMessages <= 0) return;
    final msgs = channelMessages[channel];
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

  Future<void> subscribeChannel(String channelName) async {
    try {
      final auth = twitchAuth;
      final channelUserId = await TwitchApi.getUserId(auth, channelName);
      if (channelUserId == null) return;
      channelUserIds[channelName] = channelUserId;
      badgeService.fetchChannelBadges(auth, channelUserId, channelName);

      emoteManager.accessToken = auth.accessToken;
      debugPrint(
        'subscribeChannel $channelName userId=$channelUserId '
        'hasToken=${auth.accessToken != null} resolved=${channelsEmotesResolved.contains(channelName)}',
      );
      if (!channelsEmotesResolved.contains(channelName)) {
        await emoteManager.resolveEmotes(channelName, channelUserId);
        channelsEmotesResolved.add(channelName);
      }

      if (getCurrentUserLogin() == null) {
        final currentUser = await TwitchApi.getCurrentUser(auth);
        if (currentUser == null) return;
        setCurrentUserLogin(currentUser['login']);
        setCurrentUserId(currentUser['id']);
      }

      if (!userTwitchEmotesLoaded) {
        userTwitchEmotesLoaded = true;
        unawaited(loadUserTwitchEmotes());
      }

      eventSub.setChannelMapping(channelUserId, channelName);

      for (int attempt = 0; attempt < 3; attempt++) {
        final sessionId = eventSub.sessionId;
        if (sessionId == null) {
          if (attempt == 2) {
            onSystemMessage(channelName, 'Warning: EventSub session lost');
          }
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }

        if (attempt > 0) await Future.delayed(const Duration(seconds: 1));

        final ok = await TwitchApi.createSubscription(
          auth: auth,
          sessionId: sessionId,
          broadcasterUserId: channelUserId,
          userId: getCurrentUserId()!,
        );
        if (ok) {
          final okDel = await TwitchApi.createDeleteSubscription(
            auth: auth,
            sessionId: sessionId,
            broadcasterUserId: channelUserId,
            userId: getCurrentUserId()!,
          );
          if (!okDel) {
            onSystemMessage(
              channelName,
              'Warning: delete subscription failed (${TwitchApi.lastError ?? "unknown"})',
            );
          }
          break;
        }
        if (attempt == 2) {
          onSystemMessage(
            channelName,
            'Warning: chat subscription failed (${TwitchApi.lastError ?? "unknown"})',
          );
        }
      }
    } catch (_) {}

    onRebuild();
    fetchChatStatus(channelName);
  }

  Future<void> subscribeAll() async {
    for (final channel in channels) {
      await subscribeChannel(channel);
    }
  }

  Future<void> doSendMessage(
    String text,
    String channel, {
    TwitchMessage? replyTo,
  }) async {
    final auth = twitchAuth;
    final reply = replyTo ?? getReplyToMsg();

    if (text.startsWith('/')) {
      onCommand(text, channel, auth);
      onRequestFocus();
      return;
    }

    if (!mounted) return;
    setReplyToMsg(null);
    onRebuild();
    onRequestFocus();

    final userLogin = getCurrentUserLogin();
    if (userLogin == null) {
      onShowSnackBar('Connect an account to chat');
      return;
    }

    final String wireText;
    if (text == lastTypedText[channel]) {
      final lastWire = lastSentWireText[channel] ?? text;
      wireText = bypassTextDuplicate(lastWire);
    } else {
      wireText = text;
    }
    lastTypedText[channel] = text;
    lastSentWireText[channel] = wireText;

    if (getCurrentUserId() != null && auth.isConfigured) {
      final broadcasterId =
          channelUserIds[channel] ?? await TwitchApi.getUserId(auth, channel);
      if (broadcasterId != null) {
        try {
          final messageId = await TwitchApi.sendChatMessage(
            auth,
            broadcasterId: broadcasterId,
            senderId: getCurrentUserId()!,
            message: wireText,
            replyParentMessageId: reply?.messageId,
          );
          if (messageId != null && mounted) {
            ownMessageIds.add(messageId);
            insertLocalMessage(text, channel, messageId, reply);
          }
        } catch (_) {}
        return;
      }
    }

    insertLocalMessage(text, channel, null, reply);
    irc.sendMessage(channel, wireText, replyParentMessageId: reply?.messageId);
  }

  Future<void> connect() async {
    final auth = twitchAuth;

    messageSub ??= eventSub.onMessage.listen(onMessage);
    deleteSub ??= eventSub.onMessageDeleted.listen((event) {
      if (!mounted) return;
      final msgs = channelMessages[event.channel];
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
        onSystemMessage(
          event.channel,
          'A message from $deletedUser was deleted saying: "$deletedText".',
        );
      }
    });

    ircBanSub?.cancel();
    ircBanSub = irc.onBan.listen((event) {
      if (!mounted) return;
      final text = event.isTimeout
          ? '${event.user} was timed out${event.duration != null ? ' for ${event.duration}s' : ''}.'
          : '${event.user} was banned.';
      onSystemMessage(event.channel, text);
    });

    ircNoticeSub?.cancel();
    ircNoticeSub = irc.onNotice.listen((event) {
      if (!mounted) return;
      onSystemMessage(event.channel, event.message);
    });

    ircJtvSub?.cancel();
    ircJtvSub = irc.onJtvMessage.listen((event) {
      if (!mounted) return;
      onSystemMessage(event.channel, event.message);
    });

    ircOwnMsgSub?.cancel();
    ircOwnMsgSub = ircRead.onOwnMessage.listen(onOwnIrcMessage);

    userColorSub?.cancel();
    userColorSub = ircRead.onUserColor.listen((color) {
      setCurrentUserColor(color);
    });

    if (!auth.isConfigured) return;

    statusSub?.cancel();
    statusSub = eventSub.onStatus.listen((status) async {
      if (!mounted) return;
      connectionStatus = status;
      onRebuild();
      if (status == EventSubStatus.connected && !wasConnected) {
        wasConnected = true;
        wasDisconnected = false;
        await Future.delayed(const Duration(milliseconds: 500));
        try {
          await subscribeAll();
          if (!userTwitchEmotesLoaded) {
            userTwitchEmotesLoaded = true;
            unawaited(loadUserTwitchEmotes());
          }
        } catch (_) {}
        for (final channel in channels) {
          if (historyLoaded.contains(channel)) {
            onSystemMessage(channel, 'Connected');
          }
        }
      }
      if (status == EventSubStatus.disconnected && !wasDisconnected) {
        wasDisconnected = true;
        wasConnected = false;
        for (final channel in channels) {
          onSystemMessage(channel, 'Disconnected');
        }
      }
    });

    if (getCurrentUserLogin() == null) {
      try {
        final currentUser = await TwitchApi.getCurrentUser(auth);
        if (currentUser != null) {
          setCurrentUserLogin(currentUser['login']);
          setCurrentUserId(currentUser['id']);
        }
      } catch (_) {}
    }

    if (getCurrentUserLogin() != null && auth.accessToken != null) {
      try {
        await irc.connect(
          username: getCurrentUserLogin()!,
          accessToken: auth.accessToken!,
        );
      } catch (_) {}
      try {
        await ircRead.connect(
          username: getCurrentUserLogin()!,
          accessToken: auth.accessToken!,
        );
      } catch (_) {}
    }

    await eventSub.connect();
  }

  void onMessage(TwitchMessage msg) {
    if (!mounted) return;

    if (!msg.isSystem && msg.username.isNotEmpty && msg.channel != null) {
      userStore.addUser(msg.channel!, msg.username);
    }

    final channel = msg.channel;
    if (channel == null) return;

    if (msg.messageId != null &&
        messageKeys.containsKey('$channel:${msg.messageId}')) {
      final existing = channelMessages[channel];
      if (msg.emotePositions != null && existing != null) {
        final idx = existing.indexWhere(
          (m) => m.messageId == msg.messageId,
        );
        if (idx != -1) {
          existing[idx] = msg;
          chatVersion.value++;
          onRebuild();
        }
      }
      return;
    }

    if (msg.messageId != null &&
        getCurrentUserLogin() != null &&
        msg.username.toLowerCase() == getCurrentUserLogin()!.toLowerCase()) {
      String? pendingKey;
      for (final entry in pendingLocals.entries) {
        if (entry.value.channel == channel &&
            normalizeForReconciliation(entry.value.text) ==
                normalizeForReconciliation(msg.text)) {
          pendingKey = entry.key;
          break;
        }
      }
      if (pendingKey != null) {
        pendingLocals.remove(pendingKey);
        channelMessages[channel]?.removeWhere(
          (m) => m.messageId == pendingKey,
        );
      }
      ownMessageIds.add(msg.messageId!);
    }

    if (msg.sourceBroadcasterId != null &&
        badgeService.resolveChannelAvatar(msg.sourceBroadcasterId!) == null) {
      badgeService.fetchChannelAvatar(
        twitchAuth,
        msg.sourceBroadcasterId!,
      );
    }

    final login = getCurrentUserLogin()?.toLowerCase();

    final isReplyToMe =
        login != null &&
        !msg.isSystem &&
        !msg.isHistory &&
        msg.replyToUser != null &&
        msg.replyToUser!.toLowerCase() == login;
    final isMentioned =
        (login != null &&
            !msg.isSystem &&
            !msg.isHistory &&
            _isMention(msg, login)) ||
        isReplyToMe;

    if (isMentioned) {
      if (!msg.isHighlighted && channel != getSelectedChannel()) {
        setUnreadMentions(getUnreadMentions() + 1);
        channelsWithUnreadMentions.add(channel);
        unreadMentionsPerChannel[channel] =
            (unreadMentionsPerChannel[channel] ?? 0) + 1;
      }
      msg.isHighlighted = true;
    }

    channelMessages.putIfAbsent(channel, () => []);
    channelMessages[channel]!.insert(0, msg);
    truncateChannelMessages(channel);

    if (msg.messageId != null) {
      messageKeys.putIfAbsent('$channel:${msg.messageId}', () => GlobalKey());
    }

    if (msg.isHighlighted) {
      channelMessages.putIfAbsent(mentionsChannel, () => []);
      channelMessages[mentionsChannel]!.insert(0, msg);
    }

    chatVersion.value++;

    var needsHeaderRebuild = false;
    if (channel != getSelectedChannel() && !msg.isHistory) {
      channelsWithUnread.add(channel);
      needsHeaderRebuild = true;
    }
    if (msg.isHighlighted) {
      needsHeaderRebuild = true;
    }
    if (needsHeaderRebuild) {
      onRebuild();
    }
    precacheMessageEmotes(msg, channel);
  }

  bool _isMention(TwitchMessage msg, String login) {
    return isMention(msg.text, login);
  }

  void onOwnIrcMessage(IrcMessage ircMsg) {
    if (!mounted) return;
    final channel = ircMsg.params.isNotEmpty
        ? ircMsg.params[0].substring(1)
        : null;
    if (channel == null || ircMsg.trailing == null) return;

    final displayName =
        ircMsg.tags['display-name']?.trim() ?? getCurrentUserLogin() ?? '';
    if (displayName.isNotEmpty) {
      userStore.addUser(channel, displayName);
    }

    final colorTag = ircMsg.tags['color'];
    if (colorTag != null && colorTag.isNotEmpty) {
      setCurrentUserColor(colorTag);
    }

    final messageId = ircMsg.tags['id'];
    final text = ircMsg.trailing!;

    if (messageId != null && messageKeys.containsKey('$channel:$messageId')) {
      return;
    }

    String? pendingKey;
    TwitchMessage? pendingMsg;
    for (final entry in pendingLocals.entries) {
      if (entry.value.channel == channel &&
          normalizeForReconciliation(entry.value.text) ==
              normalizeForReconciliation(text)) {
        pendingKey = entry.key;
        break;
      }
    }
    if (pendingKey != null) {
      final existing = channelMessages[channel];
      if (existing != null) {
        final idx = existing.indexWhere((m) => m.messageId == pendingKey);
        if (idx != -1) {
          pendingMsg = existing[idx];
        }
      }
      pendingLocals.remove(pendingKey);
      channelMessages[channel]?.removeWhere((m) => m.messageId == pendingKey);
    }

    final tsMs = ircMsg.tags['tmi-sent-ts'];
    final timestamp = tsMs != null
        ? DateTime.fromMillisecondsSinceEpoch(int.parse(tsMs), isUtc: true)
        : DateTime.now().toUtc();

    final userId = ircMsg.tags['user-id'] ?? getCurrentUserId();
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

    channelMessages.putIfAbsent(channel, () => []);
    channelMessages[channel]!.insert(0, msg);
    truncateChannelMessages(channel);

    if (messageId != null) {
      messageKeys.putIfAbsent('$channel:$messageId', () => GlobalKey());
    }

    chatVersion.value++;
    onRebuild();
    precacheMessageEmotes(msg, channel);
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

class PendingLocal {
  final String channel;
  final String text;
  PendingLocal(this.channel, this.text);
}
