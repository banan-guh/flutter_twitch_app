import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../color_utils.dart';
import '../models/twitch_message.dart';
import '../widgets/chat_message_tile.dart';

class MentionsPanelWidget extends StatefulWidget {
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

  const MentionsPanelWidget({
    required this.scrollController,
    required this.messages,
    required this.uiScale,
    required this.onClose,
    required this.buildBadgeSpans,
    required this.buildMessageSpans,
    super.key,
  });

  @override
  State<MentionsPanelWidget> createState() => MentionsPanelWidgetState();
}

class MentionsPanelWidgetState extends State<MentionsPanelWidget> {
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
