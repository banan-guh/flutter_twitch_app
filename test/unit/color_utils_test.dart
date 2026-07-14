import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_twitch_app/color_utils.dart';

void main() {
  group('officialColors', () {
    test('has 15 colors', () {
      expect(officialColors.length, 15);
    });

    test('all start with #', () {
      for (final c in officialColors) {
        expect(c.startsWith('#'), isTrue);
      }
    });
  });

  group('pickColor', () {
    test('returns a color from officialColors', () {
      final color = pickColor('forsen');
      expect(officialColors, contains(color));
    });

    test('is deterministic for same username', () {
      expect(pickColor('forsen'), pickColor('forsen'));
    });

    test('can return different colors for different usernames', () {
      final results = <String>{};
      for (final name in ['forsen', 'xqc', 'summit1g', 'lirik', 'shroud']) {
        results.add(pickColor(name));
      }
      expect(results.length, greaterThan(1));
    });

    test('handles empty string', () {
      expect(officialColors, contains(pickColor('')));
    });
  });

  group('parseColor', () {
    test('parses valid hex color', () {
      final c = parseColor('#FF0000');
      expect(c, isNotNull);
      expect(c!.toARGB32(), 0xFFFF0000);
    });

    test('returns null for null input', () {
      expect(parseColor(null), isNull);
    });

    test('returns null for empty string', () {
      expect(parseColor(''), isNull);
    });

    test('returns null for invalid hex', () {
      expect(parseColor('#GGGGGG'), isNull);
    });

    test('returns null for short string', () {
      expect(parseColor('#FFF'), isNull);
    });

    test('returns null for non-hex format', () {
      expect(parseColor('not a color'), isNull);
    });

    test('adjusts contrast against background', () {
      final c = parseColor('#FF0000', background: Colors.white);
      expect(c, isNotNull);
      expect(contrast(c!, Colors.white), greaterThanOrEqualTo(4.5));
    });
  });

  group('luminance', () {
    test('black has luminance 0', () {
      expect(luminance(Colors.black), closeTo(0, 0.001));
    });

    test('white has luminance ~1', () {
      expect(luminance(Colors.white), closeTo(1, 0.001));
    });
  });

  group('contrast', () {
    test('same color has contrast 1', () {
      expect(contrast(Colors.black, Colors.black), closeTo(1, 0.001));
    });

    test('black on white has contrast ~21', () {
      expect(contrast(Colors.black, Colors.white), closeTo(21, 0.5));
    });

    test('white on black has contrast ~21', () {
      expect(contrast(Colors.white, Colors.black), closeTo(21, 0.5));
    });
  });

  group('ensureContrast', () {
    test('returns same color if already >= 4.5', () {
      final c = ensureContrast(Colors.black, Colors.white);
      expect(c, equals(Colors.black));
    });

    test('adjusts dark color on dark background', () {
      final c = ensureContrast(Colors.black, const Color(0xFF111111));
      expect(contrast(c, const Color(0xFF111111)), greaterThanOrEqualTo(4.5));
    });

    test('adjusts light color on light background', () {
      final c = ensureContrast(Colors.white, const Color(0xFFEEEEEE));
      expect(contrast(c, const Color(0xFFEEEEEE)), greaterThanOrEqualTo(4.5));
    });
  });
}
