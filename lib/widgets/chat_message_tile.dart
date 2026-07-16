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
  final Color bodyColor;
  final String? semanticsLabel;

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
    this.bodyColor = Colors.red,
    this.semanticsLabel,
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
                width: 4,
                color: Colors.red.withValues(alpha: 0.4),
                alignment: Alignment.topCenter,
                padding: const EdgeInsets.only(top: 4),
                child: Icon(
                  Icons.alternate_email,
                  size: 10,
                  color: Colors.red.withValues(alpha: 0.6),
                ),
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

    if (onLongPress != null) {
      child = InkWell(onLongPress: onLongPress, child: child);
    }

    if (semanticsLabel != null) {
      child = Semantics(
        label: semanticsLabel!,
        excludeSemantics: true,
        child: child,
      );
    }

    return child;
  }
}
