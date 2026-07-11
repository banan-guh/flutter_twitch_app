import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/twitch_message.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../services/twitch_eventsub.dart';
import '../services/twitch_irc.dart';
import '../services/recent_messages.dart';
import '../widgets/settings.dart';
import '../widgets/channel_underline_painter.dart';
import '../color_utils.dart';

class HomeScreen extends StatefulWidget {
  final TwitchAuth twitchAuth;
  final ValueChanged<ThemeMode> onThemeChanged;
  final EventSubService? eventSubService;
  final IrcService? ircService;
  final RecentMessagesService? recentMessagesService;

  const HomeScreen({
    super.key,
    required this.twitchAuth,
    required this.onThemeChanged,
    this.eventSubService,
    this.ircService,
    this.recentMessagesService,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  static const _mentionsChannel = '@mentions';

  late final _eventSub = widget.eventSubService ?? EventSubService();
  late final _irc = widget.ircService ?? IrcService();
  late final _recentMessages = widget.recentMessagesService ?? RecentMessagesService();
  final _messageController = TextEditingController();
  final _focusNode = FocusNode();

  final _channels = <String>[];
  final _channelNotifier = ValueNotifier<List<String>>([]);
  final _channelScrollController = ScrollController();
  final _pageController = PageController();
  String? _selectedChannel;
  final _channelMessages = <String, List<TwitchMessage>>{};
  final _scrollControllers = <String, ScrollController>{};
  final _historyLoaded = <String>{};
  final _messageKeys = <String, GlobalKey>{};
  final _chatStatus = <String, String>{};
  final _channelUserIds = <String, String>{};
  final _channelItemKeys = <String, GlobalKey>{};
  final _underlineKey = GlobalKey();
  List<double> _itemPositions = [];
  List<double> _itemWidths = [];
  int _scrollRequestId = 0;
  bool _programmaticPageChange = false;
  int _unreadMentions = 0;
  TwitchMessage? _replyToMsg;

  late final AnimationController _underlineAnimController;
  late final CurvedAnimation _underlineCurve;
  double? _animStartContentX;
  double? _animEndContentX;
  bool _underway = false;

  StreamSubscription<TwitchMessage>? _messageSub;
  StreamSubscription<EventSubStatus>? _statusSub;
  StreamSubscription<({String messageId, String targetUser, String channel})>? _deleteSub;
  StreamSubscription<IrcBanEvent>? _ircBanSub;
  StreamSubscription<IrcNoticeEvent>? _ircNoticeSub;

  String? _currentUserLogin;
  String? _currentUserId;
  String? _currentUserColor;
  bool _wasConnected = false;
  bool _wasDisconnected = false;
  EventSubStatus _connectionStatus = EventSubStatus.disconnected;

  @override
  void initState() {
    super.initState();
    _underlineAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _underlineCurve = CurvedAnimation(
      parent: _underlineAnimController,
      curve: Curves.easeInOut,
    );
    _connect();
  }

  void _cachePositions() {
    _itemPositions = [];
    _itemWidths = [];
    double x = 0;
    for (final channel in _channels) {
      _itemPositions.add(x);
      final key = _channelItemKeys[channel];
      double w = 0;
      if (key?.currentContext != null) {
        w = (key!.currentContext!.findRenderObject() as RenderBox?)?.size.width ?? 0;
      }
      _itemWidths.add(w);
      x += w;
    }
  }

  double _lastDragPage = -1;
  bool _onPageScrollNotification(ScrollNotification notification) {
    if (_programmaticPageChange) return false;
    if (notification is! ScrollUpdateNotification) return false;
    if (_itemPositions.isEmpty) return false;
    if (!_channelScrollController.hasClients) return false;

    final metrics = notification.metrics;
    final page = metrics.pixels / metrics.viewportDimension;
    if ((page - _lastDragPage).abs() < 0.001) return false;
    _lastDragPage = page;

    final floorIdx = page.floor().clamp(0, _channels.length - 1);
    final ceilIdx = page.ceil().clamp(0, _channels.length - 1);
    final fraction = (page - page.floor()).clamp(0.0, 1.0);

    final viewportWidth = _channelScrollController.position.viewportDimension;
    final scrollA = (_itemPositions[floorIdx] - viewportWidth / 2 + _itemWidths[floorIdx] / 2)
        .clamp(0.0, _channelScrollController.position.maxScrollExtent);
    final scrollB = (_itemPositions[ceilIdx] - viewportWidth / 2 + _itemWidths[ceilIdx] / 2)
        .clamp(0.0, _channelScrollController.position.maxScrollExtent);
    final targetScroll = scrollA + (scrollB - scrollA) * fraction;
    _channelScrollController.jumpTo(targetScroll);

    return false;
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    _statusSub?.cancel();
    _deleteSub?.cancel();
    _ircBanSub?.cancel();
    _eventSub.dispose();
    _irc.dispose();
    _messageController.dispose();
    _focusNode.dispose();
    _ircBanSub?.cancel();
    _ircNoticeSub?.cancel();
    _underlineCurve.dispose();
    _underlineAnimController.dispose();
    _channelScrollController.dispose();
    _pageController.dispose();
    for (final c in _scrollControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _connect() async {
    final auth = widget.twitchAuth;
    if (!auth.isConfigured) return;

    _messageSub?.cancel();
    _messageSub = _eventSub.onMessage.listen(_onMessage);
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

    _deleteSub?.cancel();
    _deleteSub = _eventSub.onMessageDeleted.listen((event) {
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
        _addSystemMessage(event.channel,
            'A message from $deletedUser was deleted saying: "$deletedText".');
      }
    });

    if (_currentUserLogin == null) {
      try {
        final currentUser = await TwitchApi.getCurrentUser(auth);
        if (currentUser != null) {
          _currentUserLogin = currentUser['login'];
          _currentUserId = currentUser['id'];
          if (_currentUserId != null) {
            final color = await TwitchApi.getUserChatColor(auth, _currentUserId!);
            if (color != null) _currentUserColor = color;
          }
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
    }

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

    await _eventSub.connect();
  }

  void _onMessage(TwitchMessage msg) {
    if (!mounted) return;
    final channel = msg.channel;
    if (channel == null) return;

    final login = _currentUserLogin?.toLowerCase();
    final isOwn = login != null && !msg.isSystem && msg.username.toLowerCase() == login;

    if (isOwn) {
      bool updated = false;
      final msgs = _channelMessages[channel];
      if (msgs != null) {
        for (final existing in msgs) {
          if (existing.username == msg.username &&
              existing.text == msg.text &&
              existing.messageId == null) {
            existing.messageId = msg.messageId;
            if (msg.messageId != null) {
              _messageKeys.putIfAbsent('$channel:${msg.messageId}', () => GlobalKey());
            }
            updated = true;
            break;
          }
        }
        if (!updated) {
          setState(() {
            msgs.insert(0, msg);
          });
          return;
        }
        if (msg.messageId != null) {
          for (final existing in msgs) {
            if (existing.replyToUser == msg.username &&
                existing.replyToParentId == null) {
              existing.replyToParentId = msg.messageId;
              updated = true;
            }
          }
        }
      }
      if (updated && mounted) setState(() {});
      return;
    }

    final isReplyToMe = login != null && !msg.isSystem && !msg.isHistory &&
        msg.replyToUser != null && msg.replyToUser!.toLowerCase() == login;
    final isMention = (login != null && !msg.isSystem && !msg.isHistory && _isMention(msg, login)) || isReplyToMe;

    if (isMention) {
      if (!msg.isHighlighted) _unreadMentions++;
      msg.isHighlighted = true;
    }

    if (login != null && msg.username.toLowerCase() == login && msg.color != null) {
      _currentUserColor = msg.color;
    }

    setState(() {
      _channelMessages.putIfAbsent(channel, () => []);
      _channelMessages[channel]!.insert(0, msg);
      if (msg.messageId != null) {
        _messageKeys.putIfAbsent('$channel:${msg.messageId}', () => GlobalKey());
      }
      if (msg.isHighlighted) {
        _channelMessages.putIfAbsent(_mentionsChannel, () => []);
        _channelMessages[_mentionsChannel]!.insert(0, msg);
      }
    });
  }

  bool _isMention(TwitchMessage msg, String login) {
    return isMention(msg.text, login);
  }

  void _addSystemMessage(String channel, String text) {
    setState(() {
      _channelMessages.putIfAbsent(channel, () => []);
      _channelMessages[channel]!.insert(
        0,
        TwitchMessage(username: '', text: text, isSystem: true, channel: channel),
      );
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
                final ts = '${msg.timestamp.hour.toString().padLeft(2, '0')}:${msg.timestamp.minute.toString().padLeft(2, '0')}';
                Clipboard.setData(ClipboardData(text: '$ts ${msg.username}: ${msg.text}'));
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
    if (_connectionStatus == EventSubStatus.connected && _historyLoaded.contains(channel)) {
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
      _selectedChannel = name;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _cachePositions();
      if (mounted) setState(() {});
      final idx = _channels.indexOf(name);
      if (_pageController.hasClients) {
        _pageController.jumpToPage(idx);
      }
      _requestScrollToChannel(idx);
    });

    _focusNode.requestFocus();

    final loadingMsg = TwitchMessage(
      username: '', text: 'Loading chat history...', isSystem: true, channel: name,
    );
    _channelMessages[name]!.insert(0, loadingMsg);

    _recentMessages.fetchRecent(name).then((history) {
      if (!mounted) return;
      _historyLoaded.add(name);
      setState(() {
        if (history.isEmpty) {
          _addSystemMessage(name, 'No chat history available');
        } else {
          final existing = _channelMessages[name]!;
          final existingIds = existing.map((m) => m.messageId).toSet();
          for (final msg in history) {
            if (msg.messageId == null || !existingIds.contains(msg.messageId)) {
              existing.insert(0, msg);
            }
            if (msg.messageId != null) {
              _messageKeys.putIfAbsent('$name:${msg.messageId}', () => GlobalKey());
            }
          }
        }
      });
      _maybeAddConnected(name);
    }).catchError((e) {
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

    _irc.join(name);

    if (_eventSub.isConnected && _eventSub.sessionId != null) {
      await _subscribeChannel(name);
    }

    if (mounted) setState(() {});
  }

  Future<void> _fetchChatStatus(String channel) async {
    final auth = widget.twitchAuth;
    if (!auth.isConfigured) return;

    final userId = _channelUserIds[channel];
    if (userId == null || _currentUserId == null) return;

    final settings = await TwitchApi.getChatSettings(auth, userId, _currentUserId!);
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
        parts.add('Live — $viewers viewers for ${h}h ${m}m');
      } else {
        parts.add('Live — $viewers viewers');
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

      if (_currentUserLogin == null) {
        final currentUser = await TwitchApi.getCurrentUser(auth);
        if (currentUser == null) return;
        _currentUserLogin = currentUser['login'];
        _currentUserId = currentUser['id'];
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
            _addSystemMessage(channelName,
                'Warning: delete subscription failed (${TwitchApi.lastError ?? "unknown"})');
          }
          break;
        }
        if (attempt == 2) {
          _addSystemMessage(channelName,
            'Warning: chat subscription failed (${TwitchApi.lastError ?? "unknown"})');
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
    _irc.part(channel);
    setState(() {
      _channels.remove(channel);
      _channelNotifier.value = List.of(_channels);
      _channelMessages.remove(channel);
      _scrollControllers.remove(channel)?.dispose();
      if (_selectedChannel == channel) {
        _selectedChannel = _channels.isNotEmpty ? _channels.last : null;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _cachePositions();
      if (mounted) setState(() {});
      if (_selectedChannel != null && _pageController.hasClients) {
        _pageController.jumpToPage(_channels.indexOf(_selectedChannel!));
      }
      _requestScrollToChannel(
        _selectedChannel != null ? _channels.indexOf(_selectedChannel!) : 0,
      );
    });
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    final channel = _selectedChannel;
    if (text.isEmpty || channel == null || channel == _mentionsChannel) return;

    _messageController.clear();
    _doSendMessage(text, channel);
  }

  void _doSendMessage(String text, String channel) async {
    final auth = widget.twitchAuth;
    if (_currentUserId != null && auth.isConfigured) {
      final color = await TwitchApi.getUserChatColor(auth, _currentUserId!);
      if (color != null) _currentUserColor = color;
    }

    final reply = _replyToMsg;
    if (_currentUserLogin != null && auth.isConfigured) {
      _irc.sendMessage(channel, text, replyParentMessageId: reply?.messageId);
    }

    if (!mounted) return;
    setState(() {
      _replyToMsg = null;
      _channelMessages.putIfAbsent(channel, () => []);
      if (reply?.messageId != null) {
        _messageKeys.putIfAbsent('$channel:${reply!.messageId}', () => GlobalKey());
      }
      _channelMessages[channel]!.insert(
        0,
        TwitchMessage(
          username: _currentUserLogin ?? 'You',
          text: text,
          color: _currentUserColor ?? (_currentUserLogin != null ? pickColor(_currentUserLogin!) : null),
          channel: channel,
          replyToParentId: reply?.messageId,
          replyToUser: reply?.username,
          replyToText: reply?.text,
        ),
      );
    });
    _focusNode.requestFocus();
  }

  ScrollController _scrollCtrl(String channel) {
    return _scrollControllers.putIfAbsent(
      channel,
      () => ScrollController(),
    );
  }

  TwitchMessage? _findThreadRoot(TwitchMessage msg) {
    final channel = msg.channel;
    if (channel == null) return null;
    final msgs = _channelMessages[channel];
    if (msgs == null) return null;

    final hasReplies = msg.messageId != null && msgs.any((m) => m.replyToParentId == msg.messageId);
    if (!hasReplies && msg.replyToParentId == null) return null;

    final visited = <String>{};
    TwitchMessage current = msg;
    while (current.replyToParentId != null && !visited.contains(current.replyToParentId)) {
      visited.add(current.replyToParentId!);
      final parent = msgs.where((m) => m.messageId == current.replyToParentId).firstOrNull;
      if (parent == null) break;
      current = parent;
    }
    return current;
  }

  void _showThreadView(TwitchMessage rootMsg) {
    final channel = rootMsg.channel;
    if (channel == null) return;
    final allMsgs = _channelMessages[channel] ?? [];

    final threadIds = <String>{};
    final threadMsgs = <TwitchMessage>[];
    if (rootMsg.messageId != null) threadIds.add(rootMsg.messageId!);

    bool added;
    do {
      added = false;
      for (final m in allMsgs) {
        if (m.messageId != null && threadIds.contains(m.messageId) && !threadMsgs.contains(m)) {
          threadMsgs.add(m);
          added = true;
        }
        if (m.replyToParentId != null && threadIds.contains(m.replyToParentId) && !threadMsgs.contains(m)) {
          if (m.messageId != null) threadIds.add(m.messageId!);
          threadMsgs.add(m);
          added = true;
        }
      }
    } while (added);

    threadMsgs.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: double.infinity),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      builder: (ctx) => _ThreadView(
        messages: threadMsgs,
        currentUserLogin: _currentUserLogin,
        currentUserColor: _currentUserColor,
        rootMsg: rootMsg,
        onUsernameTap: (username) {
          Navigator.pop(ctx);
          _showUserProfile(username, null);
        },
      ),
    );
  }

  void _showMentionsView() {
    final msgs = _channelMessages[_mentionsChannel] ?? [];
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: double.infinity),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      builder: (ctx) => _MentionsView(
        messages: msgs,
        currentUserLogin: _currentUserLogin,
        currentUserColor: _currentUserColor,
        onUsernameTap: (username) {
          Navigator.pop(ctx);
          _showUserProfile(username, null);
        },
      ),
    );
  }

  void _showUserProfile(String username, String? userId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _UserProfileSheet(
        username: username,
        userId: userId,
        twitchAuth: widget.twitchAuth,
        messageController: _messageController,
        focusNode: _focusNode,
        onClose: () => Navigator.pop(ctx),
      ),
    );
  }

  void _selectChannel(int index, {bool animatePageView = true}) {
    final channel = _channels[index];
    if (_selectedChannel == channel) return;

    double? startContentX;
    if (_underway && _animStartContentX != null && _animEndContentX != null) {
      startContentX = _animStartContentX! +
          (_animEndContentX! - _animStartContentX!) *
              _underlineCurve.value;
    } else if (_selectedChannel != null && _itemPositions.isNotEmpty) {
      final prevIdx = _channels.indexOf(_selectedChannel!);
      if (prevIdx >= 0 && prevIdx < _itemPositions.length) {
        startContentX = _itemPositions[prevIdx];
      }
    }

    setState(() {
      _selectedChannel = channel;
    });

    if (startContentX != null && index < _itemPositions.length) {
      final endContentX = _itemPositions[index];
      final distance = (endContentX - startContentX).abs();
      if (distance > 0.5) {
        _animStartContentX = startContentX;
        _animEndContentX = endContentX;
        _underway = true;
        final duration = (200 + distance * 0.3).clamp(150, 300).toInt();
        _underlineAnimController.duration = Duration(milliseconds: duration);
        _underlineAnimController.forward(from: 0).then((_) {
          _underway = false;
          _animStartContentX = null;
          _animEndContentX = null;
          if (mounted) setState(() {});
        });
      }
    }

    if (animatePageView) {
      _programmaticPageChange = true;
      _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      ).whenComplete(() {
        _programmaticPageChange = false;
      });
    }
    _requestScrollToChannel(index);
  }

  void _requestScrollToChannel(int index, {bool animate = true}) {
    final requestId = ++_scrollRequestId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (requestId != _scrollRequestId) return;
      if (!_channelScrollController.hasClients || index < 0 || index >= _channels.length) return;
      final viewportWidth = _channelScrollController.position.viewportDimension;
      final targetScroll = _itemPositions[index] - (viewportWidth / 2) + (_itemWidths[index] / 2);
      final clamped = targetScroll.clamp(0.0, _channelScrollController.position.maxScrollExtent);
      if (animate) {
        _channelScrollController.animateTo(
          clamped,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
        );
      } else {
        _channelScrollController.jumpTo(clamped);
      }
    });
  }

  List<TwitchMessage> _messages(String channel) {
    return _channelMessages[channel] ?? [];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dividerColor = theme.dividerColor;

    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Join channel',
            onPressed: _addChannelDialog,
          ),
          IconButton(
            icon: _unreadMentions > 0
                ? Badge(
                    label: Text('$_unreadMentions'),
                    child: const Icon(Icons.notifications_outlined),
                  )
                : const Icon(Icons.notifications_outlined),
            tooltip: 'Mentions',
            onPressed: () {
              _unreadMentions = 0;
              if (mounted) setState(() {});
              _showMentionsView();
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
          ),
        ],
      ),
      body: Column(
        children: [
          if (_channels.isNotEmpty)
            Container(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: dividerColor)),
              ),
              child: SizedBox(
                height: 40,
                child: Stack(
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: ScrollbarTheme(
                        data: const ScrollbarThemeData(thickness: WidgetStatePropertyAll(0)),
                        child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        controller: _channelScrollController,
                        physics: const ClampingScrollPhysics(),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: _channels.map((channel) {
                            final selected = channel == _selectedChannel;
                            return GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onTap: () => _selectChannel(
                                _channels.indexOf(channel),
                              ),
                              child: Container(
                                key: _channelItemKeys.putIfAbsent(channel, () => GlobalKey()),
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                height: 40,
                                alignment: Alignment.center,
                                child: Text(
                                  channel,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                                    color: selected ? theme.colorScheme.primary : null,
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        key: _underlineKey,
                        painter: ChannelUnderlinePainter(
                          scrollController: _channelScrollController,
                          pageController: _pageController,
                          itemPositions: _itemPositions,
                          itemWidths: _itemWidths,
                          selectedIndex: _selectedChannel == null
                              ? -1
                              : _channels.indexOf(_selectedChannel!),
                          color: theme.colorScheme.primary,
                          underlineAnimation: _underway ? _underlineCurve : null,
                          animStartContentX: _underway ? _animStartContentX : null,
                          animEndContentX: _underway ? _animEndContentX : null,
                          repaint: _underway
                              ? Listenable.merge([
                                  _channelScrollController,
                                  _pageController,
                                  _underlineCurve,
                                ])
                              : Listenable.merge([
                                  _channelScrollController,
                                  _pageController,
                                ]),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: _channels.isNotEmpty
                ? Column(
                    children: [
                      Expanded(
                        child: ScrollConfiguration(
                          behavior: ScrollConfiguration.of(context).copyWith(
                            dragDevices: {
                              PointerDeviceKind.touch,
                              PointerDeviceKind.mouse,
                              PointerDeviceKind.stylus,
                              PointerDeviceKind.unknown,
                            },
                          ),
                          child: NotificationListener<ScrollNotification>(
                            onNotification: _onPageScrollNotification,
                            child: PageView.builder(
                              controller: _pageController,
                              itemCount: _channels.length,
                              onPageChanged: (i) {
                                if (_programmaticPageChange) return;
                                setState(() {
                                  _selectedChannel = _channels[i];
                                });
                                _requestScrollToChannel(i);
                              },
                              itemBuilder: (_, i) => _buildChat(_channels[i]),
                            ),
                          ),
                        ),
                      ),
                      _MessageInput(
                        controller: _messageController,
                        focusNode: _focusNode,
                        onSend: _sendMessage,
                        replyToMsg: _replyToMsg,
                        onCancelReply: () => setState(() => _replyToMsg = null),
                      ),
                      if (_chatStatus[_selectedChannel] != null && _chatStatus[_selectedChannel]!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 12, right: 12, bottom: 4),
                          child: Text(
                            _chatStatus[_selectedChannel]!,
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                            textAlign: TextAlign.center,
                          ),
                        ),
                    ],
                  )
                : _buildEmpty(),
          ),
        ],
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

  Widget _buildChat(String channel) {
    final msgs = _messages(channel);
    final surface = Theme.of(context).colorScheme.surface;

    if (msgs.isEmpty) {
      return const Center(child: Text('No messages yet'));
    }

    return ScrollbarTheme(
      data: const ScrollbarThemeData(thickness: WidgetStatePropertyAll(0)),
      child: ListView.builder(
        key: ValueKey(channel),
        controller: _scrollCtrl(channel),
        reverse: true,
        itemCount: msgs.length,
      itemBuilder: (_, i) {
        final msg = msgs[i];

        final key = msg.messageId != null
            ? _messageKeys.putIfAbsent('$channel:${msg.messageId}', () => GlobalKey())
            : null;

        Widget body;
        final ts = '${msg.timestamp.hour.toString().padLeft(2, '0')}:${msg.timestamp.minute.toString().padLeft(2, '0')}';

        if (msg.isSystem) {
          body = Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 45,
                  child: Text(ts, textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 14, color: Colors.grey, decoration: TextDecoration.none),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: parseTextWithLinks(msg.text),
                      style: const TextStyle(fontSize: 14, color: Colors.grey, decoration: TextDecoration.none),
                    ),
                  ),
                ),
              ],
            ),
          );
        } else {
          body = Opacity(
            opacity: msg.deleted || msg.isHistory ? 0.35 : 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 45,
                    child: Text(ts, textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 14, color: Colors.grey, decoration: TextDecoration.none),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${msg.username}: ',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: parseColor(msg.color, background: surface),
                              decoration: TextDecoration.none,
                            ),
                            recognizer: TapGestureRecognizer()
                              ..onTap = () => _showUserProfile(msg.username, msg.userId),
                          ),
                          ...parseTextWithLinks(msg.text),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        if (msg.isHighlighted) {
          body = Container(
            color: Colors.red.withValues(alpha: 0.06),
            child: Stack(
              children: [
                body,
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    width: 3,
                    color: Colors.red.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          );
        }

        if (msg.replyToUser != null) {
          body = InkWell(
            onLongPress: msg.isSystem ? null : () => _showMessageMenu(msg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildReplyIndicator(msg),
                body,
              ],
            ),
          );
        } else if (!msg.isSystem) {
          body = InkWell(
            onLongPress: () => _showMessageMenu(msg),
            child: body,
          );
        }

        if (key != null) {
          body = Container(key: key, child: body);
        }
        return body;
      },
    ),
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
            Icon(Icons.subdirectory_arrow_right, size: 14, color: Colors.grey[500]),
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

List<InlineSpan> parseTextWithLinks(String text) {
  final urlRegExp = RegExp(
    r'(?:https?://|www\.)[^\s<]+'
    r'|[a-zA-Z0-9-]+\.[a-zA-Z]{2,}(?:/\S*)?',
  );
  final spans = <InlineSpan>[];
  int lastEnd = 0;
  for (final match in urlRegExp.allMatches(text)) {
    if (match.start > lastEnd) {
      spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
    }
    var url = match.group(0)!;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    spans.add(TextSpan(
      text: match.group(0),
      style: const TextStyle(color: Colors.blue),
      recognizer: TapGestureRecognizer()..onTap = () => launchUrl(Uri.parse(url)),
    ));
    lastEnd = match.end;
  }
  if (lastEnd < text.length) {
    spans.add(TextSpan(text: text.substring(lastEnd)));
  }
  return spans;
}

class _ThreadView extends StatefulWidget {
  final List<TwitchMessage> messages;
  final String? currentUserLogin;
  final String? currentUserColor;
  final TwitchMessage rootMsg;
  final ValueChanged<String>? onUsernameTap;

  const _ThreadView({
    required this.messages,
    this.currentUserLogin,
    this.currentUserColor,
    required this.rootMsg,
    this.onUsernameTap,
  });

  @override
  State<_ThreadView> createState() => _ThreadViewState();
}

class _ThreadViewState extends State<_ThreadView> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.colorScheme.surface;

    return DraggableScrollableSheet(
      initialChildSize: 1.0,
      minChildSize: 1.0,
      maxChildSize: 1.0,
      expand: false,
      builder: (context, scrollController) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Center(
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[400],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
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
          Divider(height: 1, color: theme.dividerColor),
          Expanded(
            child: widget.messages.isEmpty
                ? const Center(child: Text('No messages found'))
                : ListView.builder(
                    controller: scrollController,
                    itemCount: widget.messages.length,
                    itemBuilder: (_, i) {
                      final msg = widget.messages[i];
                      final ts = '${msg.timestamp.hour.toString().padLeft(2, '0')}:${msg.timestamp.minute.toString().padLeft(2, '0')}';

                      if (msg.isSystem) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 45,
                                child: Text(ts, textAlign: TextAlign.right,
                                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(msg.text,
                                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                                ),
                              ),
                            ],
                          ),
                        );
                      }

                      return Opacity(
                        opacity: msg.deleted ? 0.35 : 1,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 45,
                                child: Text(ts, textAlign: TextAlign.right,
                                  style: const TextStyle(fontSize: 14, color: Colors.grey),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text: '${msg.username}: ',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: parseColor(msg.color, background: surface),
                                        ),
                                        recognizer: widget.onUsernameTap != null
                                            ? (TapGestureRecognizer()..onTap = () => widget.onUsernameTap!(msg.username))
                                            : null,
                                      ),
                                      TextSpan(
                                        text: msg.text,
                                        style: const TextStyle(fontSize: 14),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _MentionsView extends StatefulWidget {
  final List<TwitchMessage> messages;
  final String? currentUserLogin;
  final String? currentUserColor;
  final ValueChanged<String>? onUsernameTap;

  const _MentionsView({
    required this.messages,
    this.currentUserLogin,
    this.currentUserColor,
    this.onUsernameTap,
  });

  @override
  State<_MentionsView> createState() => _MentionsViewState();
}

class _MentionsViewState extends State<_MentionsView> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.colorScheme.surface;

    return DraggableScrollableSheet(
      initialChildSize: 1.0,
      minChildSize: 1.0,
      maxChildSize: 1.0,
      expand: false,
      builder: (context, scrollController) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Center(
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[400],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
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
          Divider(height: 1, color: theme.dividerColor),
          Expanded(
            child: widget.messages.isEmpty
                ? const Center(child: Text('No mentions or whispers'))
                : ListView.builder(
                    controller: scrollController,
                    itemCount: widget.messages.length,
                    itemBuilder: (_, i) {
                      final msg = widget.messages[i];
                      final ts = '${msg.timestamp.hour.toString().padLeft(2, '0')}:${msg.timestamp.minute.toString().padLeft(2, '0')}';

                      if (msg.isSystem) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 45,
                                child: Text(ts, textAlign: TextAlign.right,
                                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(msg.text,
                                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                                ),
                              ),
                            ],
                          ),
                        );
                      }

                      return Opacity(
                        opacity: msg.deleted ? 0.35 : 1,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 45,
                                child: Text(ts, textAlign: TextAlign.right,
                                  style: const TextStyle(fontSize: 14, color: Colors.grey),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text: '${msg.username}: ',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: parseColor(msg.color, background: surface),
                                        ),
                                        recognizer: widget.onUsernameTap != null
                                            ? (TapGestureRecognizer()..onTap = () => widget.onUsernameTap!(msg.username))
                                            : null,
                                      ),
                                      TextSpan(
                                        text: msg.text,
                                        style: const TextStyle(fontSize: 14),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _UserProfileSheet extends StatefulWidget {
  final String username;
  final String? userId;
  final TwitchAuth twitchAuth;
  final TextEditingController messageController;
  final FocusNode focusNode;
  final VoidCallback onClose;

  const _UserProfileSheet({
    required this.username,
    this.userId,
    required this.twitchAuth,
    required this.messageController,
    required this.focusNode,
    required this.onClose,
  });

  @override
  State<_UserProfileSheet> createState() => _UserProfileSheetState();
}

class _UserProfileSheetState extends State<_UserProfileSheet> {
  Map<String, dynamic>? _profile;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchProfile();
  }

  Future<void> _fetchProfile() async {
    try {
      final profile = await TwitchApi.getUserProfile(widget.twitchAuth, widget.username);
      if (!mounted) return;
      if (profile != null) {
        setState(() {
          _profile = profile;
          _loading = false;
        });
      } else {
        setState(() {
          _error = TwitchApi.lastError ?? 'User not found';
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  String _formatDate(String iso) {
    try {
      final dt = DateTime.parse(iso);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[400],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_loading) ...[
            const Center(child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            )),
          ] else if (_error != null) ...[
            Center(child: Text(_error!, style: const TextStyle(color: Colors.grey))),
          ] else if (_profile != null) ...[
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    _profile!['profile_image_url'] as String? ?? '',
                    width: 64,
                    height: 64,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 64,
                      height: 64,
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: Icon(Icons.person, size: 32, color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _profile!['display_name'] as String? ?? widget.username,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Created: ${_formatDate(_profile!['created_at'] as String? ?? '')}',
                        style: TextStyle(
                          fontSize: 13,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Divider(height: 1, color: theme.dividerColor),
            const SizedBox(height: 4),
            ListTile(
              dense: true,
              leading: const Icon(Icons.alternate_email),
              title: const Text('Mention user'),
              onTap: () {
                widget.onClose();
                final text = widget.messageController.text;
                final prefix = text.isEmpty ? '@${widget.username} ' : '@${widget.username} ';
                widget.messageController.text = '$prefix$text';
                widget.messageController.selection = TextSelection.fromPosition(
                  TextPosition(offset: widget.messageController.text.length),
                );
                widget.focusNode.requestFocus();
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('Whisper user'),
              onTap: () {
                widget.onClose();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Whisper not yet supported')),
                );
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.block),
              title: const Text('Block'),
              onTap: () async {
                final userId = widget.userId ?? _profile?['id'] as String?;
                if (userId == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Cannot block: user ID unknown')),
                  );
                  return;
                }
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Block user'),
                    content: Text('Block ${widget.username}? They will not be able to whisper you or host your channel.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Block')),
                    ],
                  ),
                );
                if (confirmed != true || !context.mounted) return;
                final ok = await TwitchApi.blockUser(widget.twitchAuth, userId);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(ok ? '${widget.username} blocked' : 'Block failed: ${TwitchApi.lastError ?? "unknown"}')),
                );
                widget.onClose();
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.flag_outlined),
              title: const Text('Report'),
              onTap: () async {
                final userId = widget.userId ?? _profile?['id'] as String?;
                if (userId == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Cannot report: user ID unknown')),
                  );
                  return;
                }
                final reasonController = TextEditingController();
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Report user'),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Report ${widget.username} for:'),
                        const SizedBox(height: 12),
                        TextField(
                          controller: reasonController,
                          decoration: const InputDecoration(
                            hintText: 'Reason (optional)',
                            border: OutlineInputBorder(),
                          ),
                          maxLines: 2,
                        ),
                      ],
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Report')),
                    ],
                  ),
                );
                if (confirmed != true || !context.mounted) return;
                final broadcasterId = _profile?['id'] as String? ?? userId;
                final ok = await TwitchApi.reportUser(
                  widget.twitchAuth,
                  userId: userId,
                  broadcasterId: broadcasterId,
                  reason: reasonController.text,
                );
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(ok ? 'Report submitted' : 'Report failed: ${TwitchApi.lastError ?? "unknown"}')),
                );
                widget.onClose();
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _MessageInput extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final TwitchMessage? replyToMsg;
  final VoidCallback? onCancelReply;

  const _MessageInput({
    required this.controller,
    required this.focusNode,
    required this.onSend,
    this.replyToMsg,
    this.onCancelReply,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (replyToMsg != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
              ),
              child: Row(
                children: [
                  Icon(Icons.reply, size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: 'Replying to ${replyToMsg!.username}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          TextSpan(
                            text: ': ${replyToMsg!.text.length > 60 ? '${replyToMsg!.text.substring(0, 60)}…' : replyToMsg!.text}',
                            style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, size: 16),
                    onPressed: onCancelReply,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('message_input'),
                  controller: controller,
                  focusNode: focusNode,
                  decoration: InputDecoration(
                    hintText: replyToMsg != null ? 'Reply...' : 'Type a message...',
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => onSend(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.send),
                onPressed: onSend,
              ),
            ],
          ),
        ],
      ),
    );
  }
}


