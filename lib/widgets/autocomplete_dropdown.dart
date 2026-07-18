import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/suggestion.dart';

class AutocompleteDropdown extends StatelessWidget {
  final List<Suggestion> suggestions;
  final void Function(Suggestion) onSelect;

  const AutocompleteDropdown({
    super.key,
    required this.suggestions,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    if (suggestions.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final maxItems = suggestions.length.clamp(0, 4);

    return Container(
      constraints: BoxConstraints(maxHeight: maxItems * 48.0),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.3)),
        ),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < maxItems; i++)
              _buildRow(theme, suggestions[i]),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(ThemeData theme, Suggestion suggestion) {
    return InkWell(
      onTap: () => onSelect(suggestion),
      child: SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              switch (suggestion) {
                UserSuggestion() => Icon(
                    Icons.person,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                EmoteSuggestion() => SizedBox(
                    width: 20,
                    height: 20,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: CachedNetworkImage(
                        imageUrl: suggestion.emote.url,
                        fit: BoxFit.contain,
                        fadeInDuration: Duration.zero,
                        placeholder: (_, _) => const SizedBox(),
                        errorWidget: (_, _, _) =>
                            const Icon(Icons.image, size: 16),
                      ),
                    ),
                  ),
              },
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  suggestion.displayText,
                  style: const TextStyle(fontSize: 14),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
