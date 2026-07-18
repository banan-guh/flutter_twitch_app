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
  final Color? bodyColor;
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
    this.bodyColor,
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
      color: bodyColor ?? Theme.of(context).colorScheme.onSurface,
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
                    alignment: PlaceholderAlignment.middle,
                    child: SizedBox(
                      width: timestampFontSize * 3.5,
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
      final isDark = Theme.of(context).brightness == Brightness.dark;
      child = ColoredBox(
        color: isDark
            ? const Color(0xFF773031)
            : const Color(0xFFEF9A9A),
        child: child,
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
