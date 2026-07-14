# flutter_twitch_app

Twitch chat viewer (WIP). Single Flutter package, no monorepo.

See [TODO.md](TODO.md) for the feature roadmap.

## Commands

```
flutter run                # launch on connected device/emulator
flutter test               # run all tests (176 total)
flutter analyze            # static analysis (uses package:flutter_lints)
dart format .              # format all Dart files
```

## Structure

### lib/

- `lib/main.dart` — app entrypoint (TwitchChatApp with theme mode, injectable services)
- `lib/color_utils.dart` — Twitch username color picking, luminance/contrast helpers
- `lib/twitch_config.dart` — compile‑time Client ID constant
- `lib/models/twitch_message.dart` — chat message data class (reply threading, metadata)
- `lib/screens/home_screen.dart` — multi‑channel layout, EventSub + IRC integration, reply threads, mentions/whispers view, message input, system messages
- `lib/screens/settings_screen.dart` — full-screen settings (dark mode toggle, Twitch credentials, channel management, injectable OAuth starter)
- `lib/widgets/settings.dart` — shared settings button (navigates to settings screen)
- `lib/services/twitch_auth.dart` — credential holder (client ID + access token), persistence via SharedPreferences
- `lib/services/twitch_oauth.dart` — OAuth implicit grant flow (browser-based login)
- `lib/services/twitch_api.dart` — Twitch Helix API calls (user lookup, EventSub subscription) with injectable `http.Client`
- `lib/services/twitch_eventsub.dart` — EventSub WebSocket transport, message parsing, keepalive; exposes `handleRawMessage()` and `emitConnected()` for tests
- `lib/services/twitch_irc.dart` — lightweight IRC WebSocket for send/delete/ban/timeout; exports `parseIrcMessage`
- `lib/services/recent_messages.dart` — recent‑messages.robotty.de client; exports `RecentMessagesService.parseIrcLine`

### test/

#### test/unit/
- `color_utils_test.dart` — 21 tests: color picking, luminance, contrast, ensureContrast
- `emote_manager_test.dart` — emote manager state, GenericEmote creation, relativeScale/aspectRatio JSON round-trip
- `emote_text_test.dart` — text parsing with emotes, segment building, whole-token matching, zero-width overlays
- `twitch_auth_test.dart` — 6 tests: credential persistence and accessors
- `twitch_config_test.dart` — 2 tests: client ID constant
- `twitch_message_test.dart` — 3 tests: model creation and reply threading

#### test/data/
- `twitch_eventsub_test.dart` — 20 tests: EventSub routing for all message types (channel.chat.message, channel.channel_points_custom_reward_redemption.add, channel.ban, channel.message_delete, channel.subscribe, channel.subscription.gift, channel.subscription.message, channel.cheer, channel.raid, channel.chat.user_message_hold)
- `twitch_api_test.dart` — 15 tests: Helix API calls (getUser, createEventSubSubscription, deleteEventSubSubscription, getEventSubSubscriptions, sendChatMessage) with MockClient
- `twitch_irc_test.dart` — 9 tests: IRC message parsing (PRIVMSG, CLEARCHAT with/without duration, NOTICE, JOIN, PART, PING, WHO)
- `recent_messages_test.dart` — 9 tests: Robotty IRC line parsing (TwitchMessage creation, ban/timeout, highlights)

#### test/widgets/
- `widget_test.dart` — 40 tests: main screen renders, channel bar, reply threads (10), system messages (7), settings screen (7), connected/disconnected dedup, join channel dialog, message cutoff (3)
- `channel_bar_test.dart` — channel bar rendering, selection, underline painting, font weight, disappearance
- `home_screen_test.dart` — 8 tests: channel subscription, tab switching, message display, thread navigation

## Test naming convention

- Widget tests in `test/widgets/widget_test.dart`
- Unit tests for each service/model file named `test/unit/<file_name>_test.dart`
- Integration/high-level tests in `test/widgets/home_screen_test.dart`

## Setup

1. Open `lib/twitch_config.dart` and replace `YOUR_CLIENT_ID_HERE` with your Twitch app's Client ID (get one at https://dev.twitch.tv/console/apps, set redirect URI to `http://localhost:17563`).

## Notes

- Dart SDK `^3.12.2`, Flutter stable channel
- No custom lint rules; uses `package:flutter_lints/flutter.yaml`
- No codegen, migrations, or build artifacts to manage
- Standard Flutter `.gitignore` in use
- `parseIrcMessage` (top-level in `twitch_irc.dart`) and `RecentMessagesService.parseIrcLine` (public static) are exposed for unit testing
- `TwitchApi` uses `http.Client _client` with `@visibleForTesting set client()` for MockClient injection
- `EventSubService` exposes `@visibleForTesting void handleRawMessage(Map<String, dynamic>)` and `@visibleForTesting void emitConnected()` for test injection
- `SettingsScreen` accepts optional `OAuthStarter? oAuthStarter` param for mocking OAuth
- `HomeScreen` / `TwitchChatApp` accept optional `EventSubService`, `IrcService`, `RecentMessagesService` for injection
- `StreamController.broadcast()` uses `sync: true` for synchronous event delivery in tests

## Consistency

When adding or modifying UI, keep patterns consistent across the codebase:
- **Long-press menus**: Use `InkWell` (not `GestureDetector`) for `onLongPress` handlers on messages. `InkWell` provides `HitTestBehavior.opaque` by default, which works correctly inside `ListView.builder`. `GestureDetector` defaults to `deferToChild` and can silently fail in scrollable contexts.
- **Message rendering**: The main chat (`_buildChat`) and thread panel (`_buildThreadPanel`) are separate code paths. When adding message features (long-press menus, tap handlers, layout), apply the same pattern to both.
- **Test coverage**: When fixing a gesture or interaction bug, add a test that reproduces the exact gesture (e.g., `tester.longPress`) in the affected context (e.g., inside the thread panel, not just the main chat).

## Bug fixes

When fixing a notable bug, write a test that reproduces it before applying the fix. Add the test to the relevant `test/` file or create a new one following the naming convention.
