import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class SevenTvEmoteUpdateEvent {
  final String emoteSetId;
  final List<SevenTvAddedEmote> added;
  final List<SevenTvRemovedEmote> removed;
  final List<SevenTvRenamedEmote> renamed;
  final String? actor;

  const SevenTvEmoteUpdateEvent({
    required this.emoteSetId,
    this.added = const [],
    this.removed = const [],
    this.renamed = const [],
    this.actor,
  });
}

class SevenTvAddedEmote {
  final String id;
  final String name;
  final Map<String, dynamic> raw;

  const SevenTvAddedEmote({
    required this.id,
    required this.name,
    required this.raw,
  });
}

class SevenTvRemovedEmote {
  final String id;
  final String name;

  const SevenTvRemovedEmote({required this.id, required this.name});
}

class SevenTvRenamedEmote {
  final String id;
  final String oldName;
  final String newName;

  const SevenTvRenamedEmote({
    required this.id,
    required this.oldName,
    required this.newName,
  });
}

class SevenTvUserUpdate {
  final String userId;
  final String newEmoteSetId;
  final String oldEmoteSetId;
  final int connectionIndex;
  final String? actor;

  const SevenTvUserUpdate({
    required this.userId,
    required this.newEmoteSetId,
    required this.oldEmoteSetId,
    required this.connectionIndex,
    this.actor,
  });
}

enum SevenTvEventStatus { connected, disconnected }

class SevenTvEventClient {
  static const _wsUrl = 'wss://events.7tv.io/v3';

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _streamSub;
  Timer? _heartbeatTimer;
  int? _heartbeatInterval;

  final _emoteSetUpdateCtrl =
      StreamController<SevenTvEmoteUpdateEvent>.broadcast(sync: true);
  final _userUpdateCtrl =
      StreamController<SevenTvUserUpdate>.broadcast(sync: true);
  final _statusCtrl =
      StreamController<SevenTvEventStatus>.broadcast(sync: true);

  Stream<SevenTvEmoteUpdateEvent> get onEmoteSetUpdate =>
      _emoteSetUpdateCtrl.stream;
  Stream<SevenTvUserUpdate> get onUserUpdate => _userUpdateCtrl.stream;
  Stream<SevenTvEventStatus> get onStatus => _statusCtrl.stream;

  bool get isConnected => _channel != null;

  Future<void> connect() async {
    _disconnect();
    try {
      _channel = WebSocketChannel.connect(Uri.parse(_wsUrl));
      await _channel!.ready;

      _streamSub = _channel!.stream.listen(
        (raw) => _handleMessage(raw as String),
        onError: (e) {
          debugPrint('7TV event stream error: $e');
          _statusCtrl.add(SevenTvEventStatus.disconnected);
        },
        onDone: () {
          debugPrint('7TV event stream closed');
          _statusCtrl.add(SevenTvEventStatus.disconnected);
        },
      );
    } catch (e) {
      debugPrint('7TV event connect error: $e');
      _disconnect();
    }
  }

  void subscribeEmoteSet(String emoteSetId) {
    _send(jsonEncode({
      'op': 35,
      'd': {
        'type': 'emote_set.update',
        'condition': {'object_id': emoteSetId},
      },
    }));
  }

  void unsubscribeEmoteSet(String emoteSetId) {
    _send(jsonEncode({
      'op': 36,
      'd': {
        'type': 'emote_set.update',
        'condition': {'object_id': emoteSetId},
      },
    }));
  }

  void subscribeUser(String userId) {
    _send(jsonEncode({
      'op': 35,
      'd': {
        'type': 'user.update',
        'condition': {'object_id': userId},
      },
    }));
  }

  void unsubscribeUser(String userId) {
    _send(jsonEncode({
      'op': 36,
      'd': {
        'type': 'user.update',
        'condition': {'object_id': userId},
      },
    }));
  }

  void _handleMessage(String raw) {
    try {
      final msg = jsonDecode(raw) as Map<String, dynamic>;
      final op = msg['op'] as int?;
      final d = msg['d'] as Map<String, dynamic>?;

      switch (op) {
        case 1:
          final interval = d?['heartbeat_interval'] as int? ?? 30000;
          _heartbeatInterval = interval;
          _statusCtrl.add(SevenTvEventStatus.connected);
          _startHeartbeat();
        case 0:
          _handleDispatch(d ?? {});
        case 4:
          debugPrint('7TV server requested reconnect');
          connect();
      }
    } catch (e) {
      debugPrint('7TV event parse error: $e');
    }
  }

  void _handleDispatch(Map<String, dynamic> d) {
    final type = d['type'] as String?;
    final body = d['body'] as Map<String, dynamic>? ?? {};
    final actor = body['actor']?['display_name'] as String?;

    switch (type) {
      case 'emote_set.update':
        final pushed = (body['pushed'] as List<dynamic>?)
                ?.whereType<Map<String, dynamic>>()
                .map((e) {
              final value = e['value'] as Map<String, dynamic>? ?? e;
              return SevenTvAddedEmote(
                id: value['id'] as String? ?? '',
                name: value['name'] as String? ?? '',
                raw: value,
              );
            }).where((e) => e.id.isNotEmpty).toList() ??
            [];

        final pulled = (body['pulled'] as List<dynamic>?)
                ?.whereType<Map<String, dynamic>>()
                .map((e) {
              final oldValue = e['old_value'] as Map<String, dynamic>? ?? e;
              return SevenTvRemovedEmote(
                id: oldValue['id'] as String? ?? '',
                name: oldValue['name'] as String? ?? '',
              );
            }).where((e) => e.id.isNotEmpty).toList() ??
            [];

        final updated = (body['updated'] as List<dynamic>?)
                ?.whereType<Map<String, dynamic>>()
                .map((e) {
              final value = e['value'] as Map<String, dynamic>? ?? {};
              final oldValue = e['old_value'] as Map<String, dynamic>? ?? {};
              return SevenTvRenamedEmote(
                id: value['id'] as String? ?? '',
                newName: value['name'] as String? ?? '',
                oldName: oldValue['name'] as String? ?? '',
              );
            }).where((e) => e.id.isNotEmpty).toList() ??
            [];

        _emoteSetUpdateCtrl.add(
          SevenTvEmoteUpdateEvent(
            emoteSetId: d['id'] as String? ?? '',
            added: pushed,
            removed: pulled,
            renamed: updated,
            actor: actor,
          ),
        );

      case 'user.update':
        final changeMap =
            body['change_map'] as Map<String, dynamic>? ?? {};
        final connectionIndex =
            (body['connection_index'] as int?) ?? (changeMap['index'] as int?) ?? -1;
        final fields = changeMap['fields'] as List<dynamic>? ?? [];
        for (final field in fields) {
          final f = field as Map<String, dynamic>;
          if (f['key'] == 'emote_set_id') {
            final newId = f['value'] as String? ?? '';
            final oldId = f['old_value'] as String? ?? '';
            if (newId.isNotEmpty) {
              _userUpdateCtrl.add(
                SevenTvUserUpdate(
                  userId: d['id'] as String? ?? '',
                  newEmoteSetId: newId,
                  oldEmoteSetId: oldId,
                  connectionIndex: connectionIndex,
                  actor: actor,
                ),
              );
            }
          }
        }
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    if (_heartbeatInterval == null) return;
    _heartbeatTimer = Timer.periodic(
      Duration(milliseconds: _heartbeatInterval!),
      (_) => _send(jsonEncode({'op': 3})),
    );
  }

  void _send(String message) {
    _channel?.sink.add(message);
  }

  void _disconnect() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatInterval = null;
    _streamSub?.cancel();
    _streamSub = null;
    _channel?.sink.close();
    _channel = null;
  }

  void dispose() {
    _disconnect();
    _emoteSetUpdateCtrl.close();
    _userUpdateCtrl.close();
    _statusCtrl.close();
  }
}
