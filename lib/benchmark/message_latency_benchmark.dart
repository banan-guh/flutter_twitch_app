import 'dart:async';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/twitch_message.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../services/twitch_irc.dart';

class PerMessageResult {
  final int index;
  final String text;
  final String? messageId;
  final Duration postRtt;
  Duration? eventSubDelivery;
  Duration? ircDelivery;

  PerMessageResult({
    required this.index,
    required this.text,
    required this.messageId,
    required this.postRtt,
    this.eventSubDelivery,
    this.ircDelivery,
  });
}

class LatencyBenchmark {
  final TwitchAuth auth;
  final String channelLogin;
  final String broadcasterId;
  final String senderId;
  final String senderLogin;
  final int numMessages;
  final int delayBetweenMs;
  final Stream<TwitchMessage>? eventSubMessages;
  final int ircTimeoutMs;

  LatencyBenchmark({
    required this.auth,
    required this.channelLogin,
    required this.broadcasterId,
    required this.senderId,
    required this.senderLogin,
    this.numMessages = 10,
    this.delayBetweenMs = 3000,
    this.eventSubMessages,
    this.ircTimeoutMs = 10000,
  });

  StreamSubscription<TwitchMessage>? _esSub;
  WebSocketChannel? _ircChannel;
  StreamSubscription<dynamic>? _ircSub;

  final _results = <PerMessageResult>[];
  final _pendingEs = <String, _PendingMeasurement>{};
  final _pendingIrc = <String, _PendingMeasurement>{};

  Future<List<PerMessageResult>> run() async {
    final benchmarkId = DateTime.now().millisecondsSinceEpoch;

    // Open a temporary, read-only IRC WebSocket for comparison timing.
    _ircChannel = WebSocketChannel.connect(
      Uri.parse('wss://irc-ws.chat.twitch.tv:443'),
    );
    await _ircChannel!.ready;
    _ircChannel!.sink.add('PASS oauth:${auth.accessToken}');
    _ircChannel!.sink.add('NICK $senderLogin');
    _ircChannel!.sink.add('CAP REQ :twitch.tv/tags');
    _ircChannel!.sink.add('JOIN #$channelLogin');

    _ircSub = _ircChannel!.stream.listen((raw) {
      for (final line in (raw as String).split('\r\n')) {
        if (line.isEmpty) continue;
        if (line.startsWith('PING')) {
          _ircChannel!.sink.add(line.replaceFirst('PING', 'PONG'));
          continue;
        }
        if (line.contains('PRIVMSG #$channelLogin :')) {
          final parsed = parseIrcMessage(line);
          if (parsed == null || parsed.trailing == null) continue;
          final text = parsed.trailing!;
          final pending = _pendingIrc[text];
          if (pending != null) {
            pending.tIrc = DateTime.now();
          }
        }
      }
    });

    // Observe existing EventSub stream for delivery timing.
    if (eventSubMessages != null) {
      _esSub = eventSubMessages!.listen((msg) {
        if (msg.channel != channelLogin) return;
        if (msg.messageId == null) return;
        final pending = _pendingEs[msg.messageId];
        if (pending != null) {
          pending.tEventSub = DateTime.now();
        }
      });
    }

    // Allow IRC JOIN and EventSub session to settle.
    await Future.delayed(const Duration(seconds: 2));

    for (int i = 0; i < numMessages; i++) {
      final text = '[bm_${benchmarkId}_$i]';

      final tSend = DateTime.now();
      final messageId = await TwitchApi.sendChatMessage(
        auth,
        broadcasterId: broadcasterId,
        senderId: senderId,
        message: text,
      );
      final tPost = DateTime.now();

      final meas = _PendingMeasurement(tSend: tSend, tPostResponse: tPost);

      if (messageId != null) {
        _pendingEs[messageId] = meas;
      }
      _pendingIrc[text] = meas;

      _results.add(
        PerMessageResult(
          index: i,
          text: text,
          messageId: messageId,
          postRtt: tPost.difference(tSend),
        ),
      );

      if (i < numMessages - 1) {
        await Future.delayed(Duration(milliseconds: delayBetweenMs));
      }
    }

    // Wait for remaining EventSub / IRC deliveries.
    final deadline = DateTime.now().add(Duration(milliseconds: ircTimeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    // Backfill delivery timings.
    for (final r in _results) {
      final esMeas = _pendingEs[r.messageId];
      if (esMeas != null && esMeas.tEventSub != null) {
        r.eventSubDelivery = esMeas.tEventSub!.difference(esMeas.tPostResponse);
      }
      final ircMeas = _pendingIrc[r.text];
      if (ircMeas != null && ircMeas.tIrc != null) {
        r.ircDelivery = ircMeas.tIrc!.difference(ircMeas.tPostResponse);
      }
    }

    await _cleanup();
    return _results;
  }

  Future<void> _cleanup() async {
    await _esSub?.cancel();
    await _ircSub?.cancel();
    _ircChannel?.sink.close();
    _ircChannel = null;
  }
}

class _PendingMeasurement {
  final DateTime tSend;
  final DateTime tPostResponse;
  DateTime? tEventSub;
  DateTime? tIrc;

  _PendingMeasurement({required this.tSend, required this.tPostResponse});
}
