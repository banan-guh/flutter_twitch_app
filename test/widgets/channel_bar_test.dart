import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_twitch_app/main.dart';
import 'package:flutter_twitch_app/widgets/channel_underline_painter.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> joinChannel(WidgetTester tester, String name) async {
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogField, name);
    await tester.tap(find.text('Join').last);
    await tester.pumpAndSettle();
    await tester.pump();
  }

  Future<void> tapChannel(WidgetTester tester, String channel) async {
    final barText = find.text(channel).first;
    await tester.ensureVisible(barText);
    await tester.pump();
    await tester.tap(barText);
    await tester.pumpAndSettle();
    await tester.pump();
  }

  Finder underlineCustomPaint() => find.descendant(
        of: find.byType(Positioned),
        matching: find.byType(CustomPaint),
      );

  ChannelUnderlinePainter underlinePainter(WidgetTester tester) {
    final cp = tester.widget<CustomPaint>(underlineCustomPaint());
    return cp.painter! as ChannelUnderlinePainter;
  }

  group('Channel bar', () {
    testWidgets('is absent when no channels are joined',
        (WidgetTester tester) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      expect(underlineCustomPaint(), findsNothing);
    });

    testWidgets('renders channel name after joining',
        (WidgetTester tester) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      await joinChannel(tester, 'xqc');

      expect(find.text('xqc'), findsOneWidget);
    });

    testWidgets('first channel is selected by default',
        (WidgetTester tester) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      await joinChannel(tester, 'xqc');

      final text = tester.widget<Text>(find.text('xqc'));
      expect(text.style?.fontWeight, FontWeight.w600);
    });

    testWidgets('tapping a channel selects it',
        (WidgetTester tester) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      await joinChannel(tester, 'a');
      await joinChannel(tester, 'b');

      await tapChannel(tester, 'b');

      expect(tester.widget<Text>(find.text('b')).style?.fontWeight,
          FontWeight.w600);
      expect(tester.widget<Text>(find.text('a')).style?.fontWeight,
          FontWeight.normal);
    });

    testWidgets('underline painter has valid selected index and width',
        (WidgetTester tester) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      await joinChannel(tester, 'xqc');

      final painter = underlinePainter(tester);
      expect(painter.selectedIndex, 0);
      expect(painter.itemWidths[painter.selectedIndex], greaterThan(0));
    });

    testWidgets('underline moves when switching channels',
        (WidgetTester tester) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      await joinChannel(tester, 'short');
      await joinChannel(tester, 'longername');

      final painterBefore = underlinePainter(tester);
      final leftBefore = painterBefore.itemPositions[painterBefore.selectedIndex];

      await tapChannel(tester, 'short');

      final painterAfter = underlinePainter(tester);
      final leftAfter = painterAfter.itemPositions[painterAfter.selectedIndex];

      expect(leftBefore, greaterThan(leftAfter));
    });

    testWidgets('underline painter has height 2',
        (WidgetTester tester) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      await joinChannel(tester, 'xqc');

      final painter = underlinePainter(tester);
      expect(painter.underlineHeight, 2.0);
    });

    testWidgets('selected channel text uses primary color',
        (WidgetTester tester) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      await joinChannel(tester, 'xqc');

      final text = tester.widget<Text>(find.text('xqc'));
      expect(text.style?.color, isNotNull);
    });

    testWidgets('channel bar disappears when last channel is removed',
        (WidgetTester tester) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      await joinChannel(tester, 'xqc');

      await tester.tap(find.byIcon(Icons.settings));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.remove_circle_outline));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.text('xqc'), findsNothing);
      expect(underlineCustomPaint(), findsNothing);
    });

    testWidgets('multiple channels render in the bar',
        (WidgetTester tester) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      await joinChannel(tester, 'c1');
      await joinChannel(tester, 'c2');
      await joinChannel(tester, 'c3');

      expect(find.text('c1'), findsOneWidget);
      expect(find.text('c2'), findsOneWidget);
      expect(find.text('c3'), findsOneWidget);
    });

    testWidgets('unselected channel has normal font weight',
        (WidgetTester tester) async {
      await tester.pumpWidget(const TwitchChatApp());
      await tester.pump();

      await joinChannel(tester, 'a');
      await joinChannel(tester, 'b');

      expect(tester.widget<Text>(find.text('b')).style?.fontWeight,
          FontWeight.w600);
      expect(tester.widget<Text>(find.text('a')).style?.fontWeight,
          FontWeight.normal);
    });
  });
}
