import 'package:flutter/material.dart';

class ChatMessageTile extends StatelessWidget {
  final String timestamp;
  final bool deleted;
  final bool isHistory;
  final List<InlineSpan> children;
  final double timestampFontSize;
  final double bodyFontSize;
  final bool useTextDecorationNone;
  final bool isHighlighted;
  final Widget? replyIndicator;
  final VoidCallback? onLongPress;
  final bool pending;
  final bool failed;
  final bool unconfirmed;
  final VoidCallback? onRetry;
  final Color bodyColor;

  const ChatMessageTile({
    super.key,
    required this.timestamp,
    this.deleted = false,
    this.isHistory = false,
    required this.children,
    this.timestampFontSize = 14,
    this.bodyFontSize = 14,
    this.useTextDecorationNone = false,
    this.isHighlighted = false,
    this.replyIndicator,
    this.onLongPress,
    this.pending = false,
    this.failed = false,
    this.unconfirmed = false,
    this.onRetry,
    this.bodyColor = Colors.red,
  });

  @override
  Widget build(BuildContext context) {
    final tsStyle = TextStyle(
      fontSize: timestampFontSize,
      color: Colors.grey,
      decoration: useTextDecorationNone ? TextDecoration.none : null,
    );
    final bodyStyle = TextStyle(
      fontSize: bodyFontSize,
      color: bodyColor,
      decoration: useTextDecorationNone ? TextDecoration.none : null,
    );

    Widget child = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  WidgetSpan(
                    child: SizedBox(
                      width: 49,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Text(
                          timestamp,
                          textAlign: TextAlign.right,
                          style: tsStyle,
                        ),
                      ),
                    ),
                  ),
                  ...children,
                ],
                style: bodyStyle,
              ),
            ),
          ),
        ],
      ),
    );

    if (deleted && !isHistory) {
      child = Opacity(opacity: 0.35, child: child);
    }

    if (isHighlighted) {
      child = Container(
        color: Colors.red.withValues(alpha: 0.06),
        child: Stack(
          children: [
            child,
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

    if (replyIndicator != null) {
      child = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [replyIndicator!, child],
      );
    }

    if (pending) {
      child = Opacity(opacity: 0.4, child: child);
    } else if (failed) {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: Colors.red.shade300, width: 3),
              ),
            ),
            child: child,
          ),
          Padding(
            padding: const EdgeInsets.only(left: 12, bottom: 4, right: 12),
            child: Row(
              children: [
                Icon(Icons.error_outline, size: 14, color: Colors.red.shade300),
                const SizedBox(width: 4),
                Text(
                  'Failed to send',
                  style: TextStyle(fontSize: 11, color: Colors.red.shade300),
                ),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.refresh, size: 14),
                  label: const Text('Retry', style: TextStyle(fontSize: 11)),
                  onPressed: onRetry,
                ),
              ],
            ),
          ),
        ],
      );
    } else if (unconfirmed) {
      child = Row(
        children: [
          Expanded(child: Opacity(opacity: 0.6, child: child)),
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: Icon(Icons.check, size: 14, color: Colors.grey),
          ),
        ],
      );
    }

    if (onLongPress != null) {
      child = InkWell(onLongPress: onLongPress, child: child);
    }

    return child;
  }
}
