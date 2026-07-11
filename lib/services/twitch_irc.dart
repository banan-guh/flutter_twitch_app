import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class IrcBanEvent {
  final String channel;
  final String user;
  final String? userId;
  final bool isTimeout;
  final int? duration;

  IrcBanEvent({
    required this.channel,
    required this.user,
    this.userId,
    required this.isTimeout,
    this.duration,
  });
}

class IrcNoticeEvent {
  final String channel;
  final String message;

  IrcNoticeEvent({required this.channel, required this.message});
}

class IrcService {
  static const _wsUrl = 'wss://irc-ws.chat.twitch.tv:443';

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _streamSub;
  Timer? _pingTimer;
  final _channels = <String>{};
  String? _username;
  String? _token;
  bool _reconnecting = false;
  bool _disposed = false;

  final _banController = StreamController<IrcBanEvent>.broadcast();
  final _noticeController = StreamController<IrcNoticeEvent>.broadcast();

  Stream<IrcBanEvent> get onBan => _banController.stream;
  Stream<IrcNoticeEvent> get onNotice => _noticeController.stream;

  bool get isConnected => _channel != null;

  Future<void> connect({
    required String username,
    required String accessToken,
  }) async {
    _username = username.toLowerCase();
    _token = accessToken;
    await _connect();
  }

  Future<void> _connect() async {
    _disconnect();

    try {
      _channel = WebSocketChannel.connect(Uri.parse(_wsUrl));
      await _channel!.ready;

      _streamSub = _channel!.stream.listen(
        (raw) => _handleLine(raw as String),
        onError: (e) {
          debugPrint('IRC stream error: $e');
          _scheduleReconnect();
        },
        onDone: () {
          debugPrint('IRC stream closed');
          _scheduleReconnect();
        },
      );

      _send('PASS oauth:$_token');
      _send('NICK $_username');
      _send('CAP REQ :twitch.tv/tags');

      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        _send('PING :keepalive');
      });

      for (final channel in _channels) {
        _send('JOIN #$channel');
      }
    } catch (e) {
      debugPrint('IRC connect error: $e');
      _scheduleReconnect();
    }
  }

  void _disconnect() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _streamSub?.cancel();
    _streamSub = null;
    _channel?.sink.close();
    _channel = null;
  }

  void _scheduleReconnect() {
    if (_reconnecting || _disposed) return;
    _reconnecting = true;
    Future.delayed(const Duration(seconds: 3), () {
      _reconnecting = false;
      if (!_disposed && _username != null && _token != null) {
        _connect();
      }
    });
  }

  void _send(String message) {
    _channel?.sink.add(message);
  }

  void _handleLine(String raw) {
    for (final line in raw.split('\r\n')) {
      if (line.isEmpty) continue;

      if (line.startsWith('PING')) {
        _send(line.replaceFirst('PING', 'PONG'));
        continue;
      }

      if (line.contains('CLEARCHAT ')) {
        _handleClearChat(line);
        continue;
      }

      if (line.contains('NOTICE ')) {
        _handleNotice(line);
        continue;
      }
    }
  }

  void _handleClearChat(String line) {
    final msg = parseIrcMessage(line);
    if (msg == null || msg.command != 'CLEARCHAT') return;

    final channel = msg.params.isNotEmpty ? msg.params[0].substring(1) : null;
    if (channel == null) return;

    final targetUser = msg.trailing;
    if (targetUser == null || targetUser.isEmpty) return;

    final banDuration = msg.tags['ban-duration'];
    final targetUserId = msg.tags['target-user-id'];
    final isTimeout = banDuration != null;
    final duration = isTimeout ? int.tryParse(banDuration) : null;

    _banController.add(IrcBanEvent(
      channel: channel,
      user: targetUser,
      userId: targetUserId,
      isTimeout: isTimeout,
      duration: duration,
    ));
  }

  void _handleNotice(String line) {
    final msg = parseIrcMessage(line);
    if (msg == null || msg.command != 'NOTICE') return;

    final channel = msg.params.isNotEmpty ? msg.params[0].substring(1) : null;
    if (channel == null || msg.trailing == null) return;

    _noticeController.add(IrcNoticeEvent(
      channel: channel,
      message: msg.trailing!,
    ));
  }

  void join(String channel) {
    _channels.add(channel);
    if (_channel != null) {
      _send('JOIN #$channel');
    }
  }

  void part(String channel) {
    _channels.remove(channel);
    if (_channel != null) {
      _send('PART #$channel');
    }
  }

  void sendMessage(String channel, String text, {String? replyParentMessageId}) {
    if (_channel == null || _username == null) return;
    final tag = replyParentMessageId != null
        ? '@reply-parent-msg-id=$replyParentMessageId '
        : '';
    _send('${tag}PRIVMSG #$channel :$text');
  }

  void dispose() {
    _disposed = true;
    _reconnecting = false;
    _pingTimer?.cancel();
    _streamSub?.cancel();
    _channel?.sink.close();
    _banController.close();
    _noticeController.close();
  }
}

IrcMessage? parseIrcMessage(String line) {
  try {
    String? tags;
    String? prefix;
    String command;
    List<String> params = [];
    String? trailing;

    int pos = 0;

    if (line.startsWith('@')) {
      final end = line.indexOf(' ');
      if (end == -1) return null;
      tags = line.substring(1, end);
      pos = end + 1;
    }

    if (pos < line.length && line[pos] == ':') {
      final end = line.indexOf(' ', pos);
      if (end == -1) return null;
      prefix = line.substring(pos + 1, end);
      pos = end + 1;
    }

    final rest = line.substring(pos);
    final parts = rest.split(' ');
    command = parts[0];

    int i = 1;
    while (i < parts.length) {
      if (parts[i].startsWith(':')) {
        trailing = parts.sublist(i).join(' ').substring(1);
        break;
      }
      params.add(parts[i]);
      i++;
    }

    final tagMap = <String, String>{};
    if (tags != null) {
      for (final tag in tags.split(';')) {
        final eq = tag.indexOf('=');
        if (eq != -1) {
          tagMap[tag.substring(0, eq)] = Uri.decodeComponent(tag.substring(eq + 1));
        }
      }
    }

    return IrcMessage(
      tags: tagMap,
      prefix: prefix,
      command: command,
      params: params,
      trailing: trailing,
    );
  } catch (_) {
    return null;
  }
}

class IrcMessage {
  final Map<String, String> tags;
  final String? prefix;
  final String command;
  final List<String> params;
  final String? trailing;

  IrcMessage({
    required this.tags,
    this.prefix,
    required this.command,
    required this.params,
    this.trailing,
  });
}