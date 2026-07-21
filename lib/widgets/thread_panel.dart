import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../color_utils.dart';
import '../models/twitch_message.dart';
import '../widgets/chat_message_tile.dart';

class ThreadPanelData {
  final TwitchMessage root;
  final List<TwitchMessage> messages;
  final String channel;
  ThreadPanelData({
    required this.root,
    required this.messages,
    required this.channel,
  });
}

class ThreadPanelWidget extends StatefulWidget {
  final ScrollController scrollController;
  final ValueListenable<ThreadPanelData?> data;
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

  const ThreadPanelWidget({
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
  State<ThreadPanelWidget> createState() => ThreadPanelWidgetState();
}

class ThreadPanelWidgetState extends State<ThreadPanelWidget> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThreadPanelData?>(
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
                                  text: '${msg.formattedUsername} ',
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
                                  text: '${msg.formattedUsername}: ',
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
                                ? 'Mention: $ts ${msg.formattedUsername}: ${msg.text}'
                                : '$ts ${msg.formattedUsername}: ${msg.text}',
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
