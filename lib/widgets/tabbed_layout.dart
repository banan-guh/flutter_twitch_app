import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'channel_underline_painter.dart';

class TabbedLayout extends StatefulWidget {
  final List<String> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelectedIndexChanged;
  final IndexedWidgetBuilder pageBuilder;
  final IndexedWidgetBuilder? tabBuilder;
  final AlignmentGeometry tabAlignment;

  const TabbedLayout({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelectedIndexChanged,
    required this.pageBuilder,
    this.tabBuilder,
    this.tabAlignment = Alignment.centerLeft,
  });

  @override
  State<TabbedLayout> createState() => TabbedLayoutState();
}

class TabbedLayoutState extends State<TabbedLayout>
    with TickerProviderStateMixin {
  final _scrollController = ScrollController();
  late final PageController _pageController;
  final _itemKeys = <GlobalKey>[];
  final _underlineKey = GlobalKey();
  List<double> _itemPositions = [];
  List<double> _itemWidths = [];
  int _scrollRequestId = 0;
  bool _programmaticPageChange = false;
  double _lastDragPage = -1;

  late final AnimationController _underlineAnimController;
  late final CurvedAnimation _underlineCurve;
  double? _animStartContentX;
  double? _animEndContentX;
  bool _underway = false;

  int? _pendingTabTapIndex;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _underlineAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _underlineCurve = CurvedAnimation(
      parent: _underlineAnimController,
      curve: Curves.easeInOut,
    );
    _updateKeys();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _cachePositions();
      if (mounted) setState(() {});
    });
  }

  void _updateKeys() {
    while (_itemKeys.length < widget.tabs.length) {
      _itemKeys.add(GlobalKey());
    }
    while (_itemKeys.length > widget.tabs.length) {
      _itemKeys.removeLast();
    }
  }

  @override
  void didUpdateWidget(TabbedLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateKeys();
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      // If this change was triggered by _onTabTap, skip — its post-frame
      // callback will null _pendingTabTapIndex and handle the animation.
      if (_pendingTabTapIndex == widget.selectedIndex) return;
      _pendingTabTapIndex = null;
      _requestScrollToChannel(widget.selectedIndex);
    }
  }

  void jumpToPage(int index) {
    _updateKeys();
    _programmaticPageChange = true;
    if (_pageController.hasClients) {
      _pageController.jumpToPage(index);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _programmaticPageChange = false;
      if (!mounted) return;
      _cachePositions();
      if (mounted) setState(() {});
      _requestScrollToChannel(index);
    });
  }

  void _onTabTap(int index) {
    if (index == widget.selectedIndex) return;
    _pendingTabTapIndex = index;
    widget.onSelectedIndexChanged(index);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final savedPending = _pendingTabTapIndex;
      _pendingTabTapIndex = null;
      if (savedPending != index) return;
      _cachePositions();
      if (mounted) setState(() {});

      final prevIndex = widget.selectedIndex;
      double? startX;
      if (prevIndex >= 0 && prevIndex < _itemPositions.length) {
        startX = _itemPositions[prevIndex];
      }
      if (startX == null && _underway && _animEndContentX != null) {
        startX = _animEndContentX;
      }
      if (startX == null && _itemPositions.isNotEmpty) {
        startX = 0;
      }

      if (startX != null && index < _itemPositions.length) {
        final endX = _itemPositions[index];
        final distance = (endX - startX).abs();
        if (distance > 0.5) {
          _animStartContentX = startX;
          _animEndContentX = endX;
          _underway = true;
          final duration = (200 + distance * 0.3).clamp(150, 300).toInt();
          _underlineAnimController.duration = Duration(milliseconds: duration);
          _underlineAnimController.forward(from: 0).then((_) {
            _underway = false;
            _animStartContentX = null;
            _animEndContentX = null;
            if (mounted) setState(() {});
          });
        }
      }
    });

    _programmaticPageChange = true;
    _pageController
        .animateToPage(
          index,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
        )
        .whenComplete(() {
      _programmaticPageChange = false;
    });

    _requestScrollToChannel(index);
  }

  void _onSwipePage(int index) {
    if (_programmaticPageChange) return;
    widget.onSelectedIndexChanged(index);
    _requestScrollToChannel(index);
  }

  void _cachePositions() {
    _updateKeys();
    _itemPositions = [];
    _itemWidths = [];
    final widths = <double>[];
    double contentWidth = 0;
    for (int i = 0; i < widget.tabs.length; i++) {
      final key = _itemKeys[i];
      double w = 0;
      if (key.currentContext != null) {
        w = (key.currentContext!.findRenderObject() as RenderBox?)
                ?.size
                .width ??
            0;
      }
      widths.add(w);
      contentWidth += w;
    }
    double x = 0;
    if (widget.tabAlignment == Alignment.center) {
      final underlineCtx = _underlineKey.currentContext;
      if (underlineCtx != null) {
        final viewportWidth =
            (underlineCtx.findRenderObject() as RenderBox?)?.size.width ?? 0;
        if (contentWidth > 0 && contentWidth < viewportWidth) {
          x = (viewportWidth - contentWidth) / 2;
        }
      }
    }
    for (int i = 0; i < widget.tabs.length; i++) {
      _itemPositions.add(x);
      _itemWidths.add(widths[i]);
      x += widths[i];
    }
  }

  bool _onPageScrollNotification(ScrollNotification notification) {
    if (_programmaticPageChange) return false;
    if (notification is! ScrollUpdateNotification) return false;
    if (_itemPositions.isEmpty) return false;
    if (!_scrollController.hasClients) return false;

    final metrics = notification.metrics;
    final page = metrics.pixels / metrics.viewportDimension;
    if ((page - _lastDragPage).abs() < 0.001) return false;
    _lastDragPage = page;

    final floorIdx = page.floor().clamp(0, widget.tabs.length - 1);
    final ceilIdx = page.ceil().clamp(0, widget.tabs.length - 1);
    final fraction = (page - page.floor()).clamp(0.0, 1.0);

    final viewportWidth = _scrollController.position.viewportDimension;
    final scrollA =
        (_itemPositions[floorIdx] -
                viewportWidth / 2 +
                _itemWidths[floorIdx] / 2)
            .clamp(0.0, _scrollController.position.maxScrollExtent);
    final scrollB =
        (_itemPositions[ceilIdx] -
                viewportWidth / 2 +
                _itemWidths[ceilIdx] / 2)
            .clamp(0.0, _scrollController.position.maxScrollExtent);
    final targetScroll = scrollA + (scrollB - scrollA) * fraction;
    _scrollController.jumpTo(targetScroll);

    return false;
  }

  void _requestScrollToChannel(int index, {bool animate = true}) {
    final requestId = ++_scrollRequestId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (requestId != _scrollRequestId) return;
      if (!_scrollController.hasClients ||
          index < 0 ||
          index >= widget.tabs.length) {
        return;
      }
      if (index >= _itemPositions.length || index >= _itemWidths.length) {
        _cachePositions();
      }
      if (index >= _itemPositions.length || index >= _itemWidths.length) {
        return;
      }
      final viewportWidth = _scrollController.position.viewportDimension;
      final targetScroll =
          _itemPositions[index] -
          (viewportWidth / 2) +
          (_itemWidths[index] / 2);
      final clamped = targetScroll.clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      if (animate) {
        _scrollController.animateTo(
          clamped,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
        );
      } else {
        _scrollController.jumpTo(clamped);
      }
    });
  }

  @override
  void dispose() {
    _underlineCurve.dispose();
    _underlineAnimController.dispose();
    _scrollController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dividerColor = theme.dividerColor;
    final tabs = widget.tabs;

    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: dividerColor),
            ),
          ),
          child: SizedBox(
            height: 40,
            child: Stack(
              children: [
                Align(
                  alignment: widget.tabAlignment,
                  child: ScrollbarTheme(
                    data: const ScrollbarThemeData(
                      thickness: WidgetStatePropertyAll(0),
                    ),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      controller: _scrollController,
                      physics: const ClampingScrollPhysics(),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: List.generate(tabs.length, (i) {
                          if (i >= _itemKeys.length) {
                            _updateKeys();
                          }
                          return GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTap: () => _onTabTap(i),
                            child: Container(
                              key: i < _itemKeys.length ? _itemKeys[i] : null,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              height: 40,
                              alignment: Alignment.center,
                              child: widget.tabBuilder != null
                                  ? widget.tabBuilder!(context, i)
                                  : Text(tabs[i]),
                            ),
                          );
                        }),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      key: _underlineKey,
                      painter: ChannelUnderlinePainter(
                        scrollController: _scrollController,
                        pageController: _pageController,
                        itemPositions: _itemPositions,
                        itemWidths: _itemWidths,
                        selectedIndex: widget.selectedIndex,
                        color: theme.colorScheme.primary,
                        underlineAnimation: _underway ? _underlineCurve : null,
                        animStartContentX: _underway
                            ? _animStartContentX
                            : null,
                        animEndContentX: _underway
                            ? _animEndContentX
                            : null,
                        repaint: _underway
                            ? Listenable.merge([
                                _scrollController,
                                _pageController,
                                _underlineCurve,
                              ])
                            : Listenable.merge([
                                _scrollController,
                                _pageController,
                              ]),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: {
                PointerDeviceKind.touch,
                PointerDeviceKind.mouse,
                PointerDeviceKind.stylus,
                PointerDeviceKind.unknown,
              },
            ),
            child: NotificationListener<ScrollNotification>(
              onNotification: _onPageScrollNotification,
              child: PageView.builder(
                controller: _pageController,
                itemCount: tabs.length,
                onPageChanged: _onSwipePage,
                itemBuilder: (_, i) => widget.pageBuilder(context, i),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
