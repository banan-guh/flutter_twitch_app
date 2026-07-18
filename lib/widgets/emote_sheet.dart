import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/generic_emote.dart';

class EmoteSheet extends StatelessWidget {
  final GenericEmote emote;
  final TextEditingController messageController;
  final FocusNode focusNode;
  final VoidCallback onClose;

  const EmoteSheet({
    super.key,
    required this.emote,
    required this.messageController,
    required this.focusNode,
    required this.onClose,
  });

  String _typeLabel(GenericEmote emote) {
    final scope = switch (emote.scope) {
      EmoteScope.global => 'Global',
      EmoteScope.channel => 'Channel',
    };
    final provider = switch (emote.type) {
      EmoteType.twitch => 'Twitch',
      EmoteType.bttv => 'BTTV',
      EmoteType.ffz => 'FFZ',
      EmoteType.sevenTv => '7TV',
    };
    return '$scope $provider emote';
  }

  String? _ownerLabel(GenericEmote emote) {
    final owner = emote.ownerChannel;
    if (owner == null) return null;
    return 'Created by $owner';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[400],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: emote.url,
                  width: 64,
                  height: 64,
                  fit: BoxFit.contain,
                  fadeInDuration: Duration.zero,
                  placeholder: (_, _) => Container(
                    width: 64,
                    height: 64,
                    color: theme.colorScheme.surfaceContainerHighest,
                  ),
                  errorWidget: (_, _, _) => Container(
                    width: 64,
                    height: 64,
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: Icon(
                      Icons.image,
                      size: 32,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      emote.code,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _typeLabel(emote),
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (_ownerLabel(emote) != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        _ownerLabel(emote)!,
                        style: TextStyle(
                          fontSize: 13,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Divider(height: 1, color: theme.dividerColor),
          const SizedBox(height: 4),
          ListTile(
            dense: true,
            leading: const Icon(Icons.send),
            title: const Text('Use emote'),
            onTap: () {
              onClose();
              final text = messageController.text;
              final suffix = text.isEmpty ? emote.code : ' $emote.code';
              messageController.text = '$text$suffix';
              messageController.selection = TextSelection.fromPosition(
                TextPosition(offset: messageController.text.length),
              );
              focusNode.requestFocus();
            },
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.copy),
            title: const Text('Copy'),
            onTap: () {
              Clipboard.setData(ClipboardData(text: emote.code));
              onClose();
            },
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.open_in_new),
            title: const Text('Open emote link'),
            onTap: () {
              onClose();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Emote link not yet available')),
              );
            },
          ),
        ],
      ),
    );
  }
}
