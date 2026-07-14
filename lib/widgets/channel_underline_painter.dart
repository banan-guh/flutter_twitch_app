import 'package:flutter/material.dart';

class ChannelUnderlinePainter extends CustomPainter {
  final ScrollController scrollController;
  final PageController? pageController;
  final List<double> itemPositions;
  final List<double> itemWidths;
  final int selectedIndex;
  final Color color;
  final double underlineHeight;
  final Animation<double>? underlineAnimation;
  final double? animStartContentX;
  final double? animEndContentX;

  ChannelUnderlinePainter({
    required this.scrollController,
    this.pageController,
    required this.itemPositions,
    required this.itemWidths,
    required this.selectedIndex,
    required this.color,
    this.underlineHeight = 2,
    this.underlineAnimation,
    this.animStartContentX,
    this.animEndContentX,
    required super.repaint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (itemPositions.isEmpty || itemWidths.isEmpty) return;

    final scrollOffset = scrollController.hasClients
        ? scrollController.offset
        : 0.0;

    double contentX;
    double w;

    if (underlineAnimation != null &&
        animStartContentX != null &&
        animEndContentX != null) {
      contentX =
          animStartContentX! +
          (animEndContentX! - animStartContentX!) * underlineAnimation!.value;
      if (selectedIndex >= 0 && selectedIndex < itemWidths.length) {
        w = itemWidths[selectedIndex];
      } else {
        return;
      }
    } else if (pageController != null &&
        pageController!.hasClients &&
        pageController!.position.hasContentDimensions &&
        itemPositions.length > 1) {
      final pos = pageController!.position;
      final page = pos.pixels / pos.viewportDimension;
      final floorIdx = page.floor().clamp(0, itemPositions.length - 1);
      final ceilIdx = page.ceil().clamp(0, itemPositions.length - 1);
      final fraction = (page - floorIdx).clamp(0.0, 1.0);
      contentX =
          itemPositions[floorIdx] +
          (itemPositions[ceilIdx] - itemPositions[floorIdx]) * fraction;
      w =
          itemWidths[floorIdx] +
          (itemWidths[ceilIdx] - itemWidths[floorIdx]) * fraction;
    } else {
      if (selectedIndex < 0 || selectedIndex >= itemPositions.length) return;
      if (selectedIndex >= itemWidths.length) return;
      contentX = itemPositions[selectedIndex];
      w = itemWidths[selectedIndex];
    }

    if (w <= 0) return;

    final x = contentX - scrollOffset;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x, size.height - underlineHeight, w, underlineHeight),
        const Radius.circular(1),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant ChannelUnderlinePainter old) {
    return old.selectedIndex != selectedIndex ||
        old.color != color ||
        old.underlineAnimation != underlineAnimation ||
        old.animStartContentX != animStartContentX ||
        old.animEndContentX != animEndContentX ||
        old.pageController != pageController ||
        !_doubleListEquals(old.itemPositions, itemPositions) ||
        !_doubleListEquals(old.itemWidths, itemWidths);
  }

  static bool _doubleListEquals(List<double> a, List<double> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
