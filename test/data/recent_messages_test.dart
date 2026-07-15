import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_twitch_app/services/recent_messages.dart';

void main() {
  group('parseIrcLine', () {
    test('parses basic PRIVMSG', () {
      const raw =
          '@display-name=forsen;color=#FF0000;id=abc-123;rm-received-ts=1700000000000 :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :Hello chat';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.username, 'forsen');
      expect(msg.text, 'Hello chat');
      expect(msg.color, '#FF0000');
      expect(msg.messageId, 'abc-123');
      expect(msg.isHistory, isTrue);
      expect(msg.channel, isNull);
    });

    test('parses message without color tag', () {
      const raw =
          '@display-name=forsen;id=def-456;rm-received-ts=1700000000000 :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :no color';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.username, 'forsen');
      expect(msg.text, 'no color');
      expect(msg.color, isNotNull);
      expect(msg.color!.startsWith('#'), isTrue);
    });

    test('parses reply IRC tags', () {
      const raw =
          '@display-name=forsen;id=ghi-789;rm-received-ts=1700000000000;reply-parent-msg-id=parent-123;reply-parent-display-name=previousUser;reply-parent-msg-body=original%20message :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :@previousUser reply text';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.replyToParentId, 'parent-123');
      expect(msg.replyToUser, 'previousUser');
      expect(msg.replyToText, 'original message');
      expect(msg.text, 'reply text');
    });

    test('strips @User prefix in reply', () {
      const raw =
          '@display-name=forsen;id=xxx-111;rm-received-ts=1700000000000;reply-parent-msg-id=parent-123;reply-parent-display-name=SomeUser;reply-parent-msg-body=hey :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :@SomeUser hello there';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.replyToUser, 'SomeUser');
      expect(msg.text, 'hello there');
    });

    test('handles malformed URI in reply tag', () {
      const raw =
          '@display-name=forsen;id=yyy-222;rm-received-ts=1700000000000;reply-parent-msg-id=parent-456;reply-parent-display-name=User;reply-parent-msg-body=%ZZinvalid :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :@User hi';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.replyToText, '%ZZinvalid');
    });

    test('returns null for non-PRIVMSG', () {
      const raw = '@display-name=forsen :tmi.twitch.tv JOIN #xqc';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNull);
    });

    test('returns null for empty display-name and text', () {
      const raw =
          '@display-name=;id=zzz-333 :user!user@user.tmi.twitch.tv PRIVMSG #xqc :';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNull);
    });

    test('parses timestamp from rm-received-ts', () {
      const raw =
          '@display-name=test;id=ts-1;rm-received-ts=1700000000000 :test!test@test.tmi.twitch.tv PRIVMSG #xqc :hello';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.timestamp.millisecondsSinceEpoch, 1700000000000);
    });

    test('assigns consistent color from palette', () {
      const raw =
          '@display-name=SomeUser;id=c1;rm-received-ts=1700000000000 :user!user@user.tmi.twitch.tv PRIVMSG #xqc :msg1';
      const raw2 =
          '@display-name=SomeUser;id=c2;rm-received-ts=1700001000000 :user!user@user.tmi.twitch.tv PRIVMSG #xqc :msg2';
      final msg1 = RecentMessagesService.parseIrcLine(raw);
      final msg2 = RecentMessagesService.parseIrcLine(raw2);
      expect(msg1!.color, msg2!.color);
    });
  });
}
