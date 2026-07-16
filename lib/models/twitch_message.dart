import 'package:flutter/material.dart';
import 'twitch_badge.dart';

class EmotePosition {
  final String emoteId;
  final int startIndex;
  final int endIndex;
  final String emoteCode;

  const EmotePosition({
    required this.emoteId,
    required this.startIndex,
    required this.endIndex,
    required this.emoteCode,
  });
}

class TwitchMessage {
  final DateTime timestamp;
  final String username;
  final String text;
  final String? color;
  final bool isSystem;
  final bool isAction;
  String? messageId;
  final String? channel;
  bool deleted;
  final bool isHistory;
  String? replyToParentId;
  final String? replyToUser;
  final String? replyToText;
  bool isHighlighted;
  String? userId;
  final List<EmotePosition>? emotePositions;
  final List<MessageBadge>? badges;
  final String? sourceBroadcasterId;
  final String? sourceBroadcasterName;
  List<InlineSpan>? cachedSpans;
  Color? get bodyColor => isSystem ? Colors.grey : null;
  TwitchMessage({
    required this.username,
    required this.text,
    this.color,
    DateTime? timestamp,
    this.isSystem = false,
    this.isAction = false,
    this.messageId,
    this.channel,
    this.deleted = false,
    this.isHistory = false,
    this.replyToParentId,
    this.replyToUser,
    this.replyToText,
    this.isHighlighted = false,
    this.userId,
    this.emotePositions,
    this.badges,
    this.sourceBroadcasterId,
    this.sourceBroadcasterName,
  }) : timestamp = timestamp ?? DateTime.now();
}
