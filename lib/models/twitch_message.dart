class TwitchMessage {
  final DateTime timestamp;
  final String username;
  final String text;
  final String? color;
  final bool isSystem;
  String? messageId;
  final String? channel;
  bool deleted;
  final bool isHistory;
  String? replyToParentId;
  final String? replyToUser;
  final String? replyToText;
  bool isHighlighted;
  String? userId;

  TwitchMessage({
    required this.username,
    required this.text,
    this.color,
    DateTime? timestamp,
    this.isSystem = false,
    this.messageId,
    this.channel,
    this.deleted = false,
    this.isHistory = false,
    this.replyToParentId,
    this.replyToUser,
    this.replyToText,
    this.isHighlighted = false,
    this.userId,
  }) : timestamp = timestamp ?? DateTime.now();
}
