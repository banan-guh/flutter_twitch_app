import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/generic_emote.dart';
import '../models/twitch_message.dart';
import '../services/emote_manager.dart';

class EmoteSpanData {
  final GenericEmote base;
  final List<GenericEmote> overlays;

  const EmoteSpanData({required this.base, this.overlays = const []});
}

class EmoteText {
  static List<InlineSpan> build({
    required String text,
    required List<EmotePosition>? twitchPositions,
    required ChannelEmotes? channelEmotes,
  }) {
    if (channelEmotes == null) {
      return parseTextWithLinks(text);
    }

    final spans = <InlineSpan>[];
    final byCode = channelEmotes.byCode;

    // Build sorted segments from Twitch positions and whitespace tokens
    final segments = _buildSegments(text, twitchPositions, byCode);
    if (segments.isEmpty) {
      return parseTextWithLinks(text);
    }

    // Walk segments left-to-right tracking current base for zero-width stacking
    EmoteSpanData? currentBase;
    int? currentBaseEnd;
    String? pendingSpace;

    void flushBase() {
      if (currentBase == null) return;
      spans.add(_buildEmoteSpan(currentBase!));
      if (pendingSpace != null) {
        spans.addAll(parseTextWithLinks(pendingSpace!));
        pendingSpace = null;
      }
      currentBase = null;
      currentBaseEnd = null;
    }

    for (final seg in segments) {
      if (seg is TextSegment) {
        if (seg.text.trim().isEmpty) {
          pendingSpace = (pendingSpace ?? '') + seg.text;
        } else {
          flushBase();
          if (pendingSpace != null) {
            spans.addAll(parseTextWithLinks(pendingSpace!));
            pendingSpace = null;
          }
          spans.addAll(parseTextWithLinks(seg.text));
        }
      } else if (seg is EmoteSegment) {
        if (seg.emote.isZeroWidth) {
          if (currentBase != null && currentBaseEnd == seg.startIndex) {
            pendingSpace = null;
            currentBase = EmoteSpanData(
              base: currentBase!.base,
              overlays: [...currentBase!.overlays, seg.emote],
            );
            currentBaseEnd = seg.endIndex;
          } else if (currentBase != null &&
              pendingSpace != null &&
              currentBaseEnd == seg.startIndex - pendingSpace!.length) {
            pendingSpace = null;
            currentBase = EmoteSpanData(
              base: currentBase!.base,
              overlays: [...currentBase!.overlays, seg.emote],
            );
            currentBaseEnd = seg.endIndex;
          } else {
            flushBase();
            if (pendingSpace != null) {
              spans.addAll(parseTextWithLinks(pendingSpace!));
              pendingSpace = null;
            }
            currentBase = EmoteSpanData(base: seg.emote);
            currentBaseEnd = seg.endIndex;
          }
        } else {
          flushBase();
          pendingSpace = null;
          currentBase = EmoteSpanData(base: seg.emote);
          currentBaseEnd = seg.endIndex;
        }
      }
    }

    flushBase();

    if (pendingSpace != null) {
      spans.addAll(parseTextWithLinks(pendingSpace!));
    }

    return spans;
  }

  static List<_Segment> _buildSegments(
    String text,
    List<EmotePosition>? twitchPositions,
    Map<String, GenericEmote> byCode,
  ) {
    final segments = <_Segment>[];

    // Create a map from position ranges to Twitch emote data
    final twitchRanges = <int, EmotePosition>{};
    if (twitchPositions != null) {
      // Sort by start position to handle overlap
      final sorted = List<EmotePosition>.from(twitchPositions)
        ..sort((a, b) => a.startIndex.compareTo(b.startIndex));
      for (final pos in sorted) {
        for (int i = pos.startIndex; i < pos.endIndex; i++) {
          twitchRanges[i] = pos;
        }
      }
    }

    // Walk through text, extracting Twitch-position segments and whitespace tokens
    int i = 0;
    while (i < text.length) {
      // Check if we're in a Twitch position range
      if (twitchRanges.containsKey(i)) {
        final pos = twitchRanges[i]!;
        final emoteCode = pos.emoteCode;
        final length = pos.endIndex - pos.startIndex;
        final emote = byCode[emoteCode];
        if (emote != null) {
          segments.add(
            EmoteSegment(emote: emote, startIndex: i, endIndex: i + length),
          );
        } else {
          segments.add(
            TextSegment(text: text.substring(pos.startIndex, pos.endIndex)),
          );
        }
        i = pos.endIndex;
        continue;
      }

      // Handle whitespace
      if (text[i] == ' ' || text[i] == '\t' || text[i] == '\n') {
        final start = i;
        while (i < text.length &&
            (text[i] == ' ' || text[i] == '\t' || text[i] == '\n')) {
          i++;
        }
        segments.add(TextSegment(text: text.substring(start, i)));
        continue;
      }

      // Extract a word token
      final start = i;
      while (i < text.length &&
          text[i] != ' ' &&
          text[i] != '\t' &&
          text[i] != '\n' &&
          !twitchRanges.containsKey(i)) {
        i++;
      }
      final token = text.substring(start, i);

      // Check if token matches an emote
      final emote = byCode[token];
      if (emote != null) {
        segments.add(
          EmoteSegment(emote: emote, startIndex: start, endIndex: i),
        );
      } else {
        segments.add(TextSegment(text: token));
      }
    }

    return segments;
  }

  static WidgetSpan _buildEmoteSpan(EmoteSpanData data) {
    final size = min(28.0, 28.0 * data.base.relativeScale);

    final width = size * data.base.aspectRatio;

    if (data.overlays.isEmpty) {
      return WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: SizedBox(
          width: width,
          height: size,
          child: CachedNetworkImage(
            imageUrl: data.base.url,
            width: width,
            height: size,
            fit: BoxFit.contain,
            fadeInDuration: Duration.zero,
            placeholder: (_, _) => SizedBox(width: width, height: size),
            errorWidget: (_, url, error) {
              debugPrint('Emote image load failed: $url — $error');
              return SizedBox(width: width, height: size);
            },
          ),
        ),
      );
    }

    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: SizedBox(
        width: width,
        height: size,
        child: Stack(
          children: [
            CachedNetworkImage(
              imageUrl: data.base.url,
              width: width,
              height: size,
              fit: BoxFit.contain,
              fadeInDuration: Duration.zero,
              placeholder: (_, _) => const SizedBox(),
              errorWidget: (_, url, error) {
                debugPrint('Emote base image load failed: $url — $error');
                return const SizedBox();
              },
            ),
            ...data.overlays.map(
              (overlay) => Positioned.fill(
                child: CachedNetworkImage(
                  imageUrl: overlay.url,
                  width: width,
                  height: size,
                  fit: BoxFit.contain,
                  fadeInDuration: Duration.zero,
                  placeholder: (_, _) => const SizedBox(),
                  errorWidget: (_, url, error) {
                    debugPrint(
                      'Emote overlay image load failed: $url — $error',
                    );
                    return const SizedBox();
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

abstract class _Segment {
  int get startIndex;
  int get endIndex;
}

class TextSegment implements _Segment {
  final String text;

  @override
  int get startIndex => 0;

  @override
  int get endIndex => 0;

  const TextSegment({required this.text});
}

class EmoteSegment implements _Segment {
  final GenericEmote emote;
  @override
  final int startIndex;
  @override
  final int endIndex;

  const EmoteSegment({
    required this.emote,
    required this.startIndex,
    required this.endIndex,
  });
}

final _urlRegExp = RegExp(
  r'(?:https?://|www\.)[^\s<]+'
  r'|[a-zA-Z0-9-]+\.[a-zA-Z]{2,}(?:/\S*)?',
);

List<InlineSpan> parseTextWithLinks(String text) {
  final spans = <InlineSpan>[];
  int lastEnd = 0;
  for (final match in _urlRegExp.allMatches(text)) {
    if (match.start > lastEnd) {
      spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
    }
    var url = match.group(0)!;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    spans.add(
      TextSpan(
        text: match.group(0),
        style: const TextStyle(color: Colors.blue),
        recognizer: TapGestureRecognizer()
          ..onTap = () => launchUrl(Uri.parse(url)),
      ),
    );
    lastEnd = match.end;
  }
  if (lastEnd < text.length) {
    spans.add(TextSpan(text: text.substring(lastEnd)));
  }
  return spans;
}
