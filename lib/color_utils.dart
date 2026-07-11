import 'dart:math';
import 'package:flutter/material.dart';

const officialColors = [
  '#FF0000',
  '#0000FF',
  '#008000',
  '#B22222',
  '#FF7F50',
  '#9ACD32',
  '#FF4500',
  '#2E8B57',
  '#DAA520',
  '#D2691E',
  '#5F9EA0',
  '#1E90FF',
  '#FF69B4',
  '#8A2BE2',
  '#00FF7F',
];

String pickColor(String username) {
  final hash = username.codeUnits.fold(0, (h, c) => h * 31 + c);
  return officialColors[hash.abs() % officialColors.length];
}

Color? parseColor(String? color, {Color? background}) {
  if (color == null || color.length != 7 || !color.startsWith('#')) return null;
  final value = int.tryParse(color.replaceFirst('#', '0xff'));
  if (value == null) return null;
  final c = Color(value);
  if (background == null) return c;
  return ensureContrast(c, background);
}

double luminance(Color c) {
  double r = c.r;
  double g = c.g;
  double b = c.b;
  r = r <= 0.03928 ? r / 12.92 : (pow((r + 0.055) / 1.055, 2.4) as double);
  g = g <= 0.03928 ? g / 12.92 : (pow((g + 0.055) / 1.055, 2.4) as double);
  b = b <= 0.03928 ? b / 12.92 : (pow((b + 0.055) / 1.055, 2.4) as double);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

double contrast(Color a, Color b) {
  final l1 = luminance(a);
  final l2 = luminance(b);
  return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05);
}

Color ensureContrast(Color color, Color background) {
  if (contrast(color, background) >= 4.5) return color;
  final hsl = HSLColor.fromColor(color);
  final hue = hsl.hue;
  final saturation = hsl.saturation;
  for (double l = hsl.lightness; l >= 0; l -= 0.01) {
    final test = HSLColor.fromAHSL(
      1, hue, max(saturation, l > 0.5 ? saturation : saturation * 0.5), l,
    ).toColor();
    if (contrast(test, background) >= 4.5) return test;
  }
  for (double l = hsl.lightness; l <= 1; l += 0.01) {
    final test = HSLColor.fromAHSL(1, hue, saturation, l).toColor();
    if (contrast(test, background) >= 4.5) return test;
  }
  return color;
}
