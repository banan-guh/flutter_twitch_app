import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

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
  TabController? _tabController;
  int _tabLength = 0;

  @override
  void initState() {
    super.initState();
    _initTabController();
  }

  void _initTabController() {
    final len = widget.tabs.length;
    _tabLength = len;
    if (len == 0) return;
    final idx = widget.selectedIndex.clamp(0, len - 1);
    _tabController = TabController(length: len, vsync: this, initialIndex: idx);
    _tabController!.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (_tabController!.indexIsChanging) return;
    if (_tabController!.index != widget.selectedIndex) {
      widget.onSelectedIndexChanged(_tabController!.index);
    }
  }

  @override
  void didUpdateWidget(TabbedLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    final len = widget.tabs.length;
    if (len != _tabLength) {
      _tabController?.removeListener(_onTabChanged);
      _tabController?.dispose();
      _tabController = null;
      _tabLength = len;
      if (len > 0) {
        final idx = widget.selectedIndex.clamp(0, len - 1);
        _tabController = TabController(length: len, vsync: this);
        _tabController!.addListener(_onTabChanged);
        _tabController!.index = idx;
      }
    } else if (len > 0) {
      final idx = widget.selectedIndex.clamp(0, len - 1);
      if (_tabController!.index != idx) {
        _tabController!.index = idx;
      }
    }
  }

  @override
  void dispose() {
    _tabController?.removeListener(_onTabChanged);
    _tabController?.dispose();
    super.dispose();
  }

  TabAlignment _resolveTabAlignment() {
    if (widget.tabAlignment == Alignment.center) {
      return TabAlignment.center;
    }
    return TabAlignment.start;
  }

  @override
  Widget build(BuildContext context) {
    final tabs = widget.tabs;
    if (tabs.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);

    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: theme.dividerColor),
            ),
          ),
          child: SizedBox(
            height: 40,
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              tabAlignment: _resolveTabAlignment(),
              labelPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 0,
              ),
              indicator: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: theme.colorScheme.primary,
                    width: 2,
                  ),
                ),
              ),
              indicatorSize: TabBarIndicatorSize.label,
              tabs: List.generate(tabs.length, (i) {
                return Tab(
                  child: widget.tabBuilder?.call(context, i) ?? Text(tabs[i]),
                );
              }),
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
            child: TabBarView(
              controller: _tabController,
              children: List.generate(
                tabs.length,
                (i) => widget.pageBuilder(context, i),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
