# flutter_twitch_app

A Twitch chat viewer built with Flutter. Supports multiple channels, EventSub WebSocket for live messages, IRC for sending/ban/timeout, recent message history, reply threading, and mentions/whispers view.

## Features

- Multi-channel tabbed layout with smooth-scrolling channel bar
- Live chat via Twitch EventSub WebSocket (low-latency)
- Send messages via IRC
- Reply threading with parent message preview
- Mentions and whispers view
- Recent message history via robotty.de
- Ban/timeout/message deletion system messages
- Channel points redemption, subscription, cheer, and raid event messages
- Dark mode toggle
- Twitch OAuth implicit grant login
- Persistent credentials via SharedPreferences

## Setup

1. Get a Client ID at [Twitch Developer Console](https://dev.twitch.tv/console/apps) (set redirect URI to `http://localhost:17563`)
2. Open `lib/twitch_config.dart` and replace `YOUR_CLIENT_ID_HERE` with your Client ID
3. Run the app on a connected device or emulator

## Commands

```
flutter run
flutter test
flutter analyze
dart format .
```
