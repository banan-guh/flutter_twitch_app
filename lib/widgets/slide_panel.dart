import 'package:flutter/material.dart';

class SlidePanel extends StatelessWidget {
  final Animation<double> animation;
  final double stackHeight;
  final Widget child;
  final double top;

  const SlidePanel({
    super.key,
    required this.animation,
    required this.stackHeight,
    required this.child,
    this.top = 0,
  });

  @override
  Widget build(BuildContext context) {
    final panelHeight = stackHeight - top;
    return Positioned(
      left: 0,
      right: 0,
      top: top,
      height: panelHeight,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, (1 - animation.value) * panelHeight),
          child: child,
        ),
        child: child,
      ),
    );
  }
}
