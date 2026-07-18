# Split `home_screen.dart` (3847 lines → ~1000 lines)

Goal: extract self-contained widgets and logic out of `lib/screens/home_screen.dart` into their own files, in low-risk-first order, verifying after each stage. Do not change behavior — this is a pure move/extract refactor.

**Baseline:** `flutter analyze` clean, 241 tests pass, clean git.

---

## Stage 0 — Setup

1. Confirm clean git state (`git status`), create branch `refactor/split-home-screen`.
2. Run `flutter analyze && flutter test` once up front to capture a baseline.
3. Read all of `lib/screens/home_screen.dart` once fully before touching anything.

---

## Stage 1 — Extract standalone widget classes (lowest risk, do first)

These are already self-contained `State`/`StatelessWidget` classes at the bottom of the file. They take data via constructor params/callbacks, not direct access to `_HomeScreenState` private fields. Move each to its own file under `lib/widgets/`.

| Class | New file |
|---|---|
| `_UserProfileSheet` / `_UserProfileSheetState` | `lib/widgets/user_profile_sheet.dart` |
| `_EmoteSheet` | `lib/widgets/emote_sheet.dart` |
| `_MessageInput` | `lib/widgets/message_input.dart` |
| `_ThreadPanelData`, `_ThreadPanelWidget` / `_ThreadPanelWidgetState` | `lib/widgets/thread_panel.dart` |
| `_MentionsPanelWidget` / `_MentionsPanelWidgetState` | `lib/widgets/mentions_panel.dart` |
| `_EmoteMenuPanelWidget` / `_EmoteMenuPanelWidgetState` | `lib/widgets/emote_menu_panel.dart` |

**For each class, one at a time:**

1. **Before cutting: re-grep for the instantiation site** in `home_screen.dart` so you're acting on the current line number (prior commits in Stage 1 shift line numbers — never trust a static plan).
2. Cut the class (and any private helper class it alone uses, like `_ThreadPanelData`) into the new file.
3. Rename from leading-underscore private (`_ThreadPanelWidget`) to public (`ThreadPanelWidget`) — Dart privacy is file-scoped. This applies to `_Foo` → `Foo`, `_FooState` → `FooState`, `_FooData` → `FooData`.
4. Add necessary imports to the new file (check what types/packages the class actually uses — don't blanket-copy all of `home_screen.dart`'s imports).
5. In `home_screen.dart`, add `import '../widgets/<new_file.dart>';` and update the instantiation site to use the renamed public class.
6. Run `flutter analyze` — fix import errors.
7. Build/run the app and manually exercise that panel/sheet before moving to the next class.

**Do this one panel per commit.** Six small commits, each independently verifiable, each easy to revert if something breaks.

### Commit 1: `UserProfileSheet` → `lib/widgets/user_profile_sheet.dart`
- Constructor: `username` (String), `userId` (String?), `twitchAuth` (TwitchAuth), `messageController` (TextEditingController), `focusNode` (FocusNode), `onClose` (VoidCallback).
- Imports needed: `flutter/material.dart`, `twitch_auth.dart`, `twitch_api.dart`.

### Commit 2: `EmoteSheet` → `lib/widgets/emote_sheet.dart`
- StatelessWidget (no state class).
- Constructor: `emote` (GenericEmote), `messageController` (TextEditingController), `focusNode` (FocusNode), `onClose` (VoidCallback).
- Imports needed: `flutter/material.dart`, `flutter/services.dart` (Clipboard), `generic_emote.dart`, `cached_network_image`.

### Commit 3: `MessageInput` → `lib/widgets/message_input.dart`
- StatelessWidget. Constructor already receives all data via params — no new params needed.
- Constructor: `controller`, `focusNode`, `onSend`, `onSendLongPress`, `onEmoteToggle`, `replyToMsg`, `onCancelReply`, `enabled`, `hintText`.
- Imports needed: `flutter/material.dart`, `twitch_message.dart`.

### Commit 4: `ThreadPanelData` + `ThreadPanelWidget` → `lib/widgets/thread_panel.dart`
- `ThreadPanelData` constructor: `root` (TwitchMessage), `messages` (List<TwitchMessage>), `channel` (String) — all `required`.
- `ThreadPanelWidget` constructor: `scrollController`, `data` (ValueListenable<ThreadPanelData?>), `uiScale`, `onClose`, `onLongPress`, `buildBadgeSpans`, `buildMessageSpans` (callback function-typed params).
- Update `home_screen.dart`: change `_ThreadPanelData(` → `ThreadPanelData(`, `_ThreadPanelWidget(` → `ThreadPanelWidget(`, `ValueListenable<_ThreadPanelData?>` → `ValueListenable<ThreadPanelData?>`.
- Imports needed: `flutter/material.dart`, `twitch_message.dart`, `chat_message_tile.dart`, `color_utils.dart`.

### Commit 5: `MentionsPanelWidget` → `lib/widgets/mentions_panel.dart`
- Imports needed: `flutter/material.dart`, `twitch_message.dart`, `chat_message_tile.dart`, `color_utils.dart`.

### Commit 6: `EmoteMenuPanelWidget` → `lib/widgets/emote_menu_panel.dart`
- **NEW constructor params** to break coupling with `_HomeScreenState` statics: add `emoteMaxFraction` (double) and `sheetAnimDuration` (Duration). The widget's code references `_HomeScreenState._emoteMaxFraction` and `_HomeScreenState._sheetAnimDuration` — replace those with `widget.emoteMaxFraction` / `widget.sheetAnimDuration`.
- Update instantiation site in `home_screen.dart` to pass `emoteMaxFraction: _emoteMaxFraction`, `sheetAnimDuration: _sheetAnimDuration`.
- Imports needed: `flutter/material.dart`, `generic_emote.dart`, `emote_manager.dart`, `tabbed_layout.dart`, `cached_network_image`.

**Expected result:** `home_screen.dart` drops from ~3847 lines to roughly ~2550 lines.

---

## Stage 2 — Extract the command handler

Target: `_handleCommand` (~220 lines).

1. Create `lib/services/command_handler.dart`.
2. Design `CommandHandler` as a plain class:
   - **Constructor deps:** `IrcService`, plus callback functions for accessing `_HomeScreenState` state: `getChannelUserIds`, `getCurrentUserId`, `getCurrentUserLogin`, `addSystemMessage`. (Passing `/me` through the handler like any other command — special-casing it outside would split command logic for no reason.)
   - Expose `Future<void> handle(String text, String channel, TwitchAuth auth)` — verbatim copy of `_handleCommand` body with field accesses replaced by getter calls and `_addSystemMessage` replaced by the callback.
3. In `_HomeScreenState`, instantiate `CommandHandler` (as `late final`), wiring its callback params to existing private methods/fields.
4. Replace the body of `_handleCommand` with delegation: `_commandHandler.handle(text, channel, auth)`.
5. `flutter analyze`, then manually test every command: `/me`, `/color`, `/ban`, `/unban`, `/timeout`, `/delete`, `/clear`, `/announce`, `/shoutout`.

**Expected result:** ~250 lines off `home_screen.dart`.

---

## Stage 3 — Extract connection/message-handling into `ChatConnectionManager`

This is the highest-value, highest-risk stage — do it last, method-by-method.

### Create `lib/services/chat_connection_manager.dart`

A plain class (not `ChangeNotifier` — matches the codebase's existing patterns of `ValueNotifier` + callbacks):

**Owned state** (moved from `_HomeScreenState`):
- `_channelUserIds`, `_pendingLocals`, `_lastTypedText`, `_lastSentWireText`, `_ownMessageIds`, `_localCounter`, related boolean flags
- `_PendingLocal` data class (moved inside the new file, stays private with underscore prefix — it's an implementation detail, not a shared type)

**Outputs** (exposed to `_HomeScreenState`):
- `ValueNotifier<int> chatVersion` — replaces `_chatVersion.value++` calls
- Callbacks for side effects: `onSystemMessage(String channel, String text)`, `onRebuild()` (for `setState`/`mounted` calls)

**Inputs** (constructor):
- Services: `EventSubService`, `IrcService`, `IrcReadService`, `RecentMessagesService`, `EmoteManager`, `TwitchBadgeService`, `UserStore`, `TwitchAuth`
- Callback functions for all UI-facing side effects

### Move methods in dependency order, one at a time:

1. **Leaf methods first:**
   - `_fetchChatStatus` → `fetchChatStatus(channel)`
   - `_maybeAddConnected` → `maybeAddConnected(channel)`
   - `_precacheMessageEmotes` → `precacheMessageEmotes(msg, channel)`
   - `_addSystemMessage` → `addSystemMessage(channel, text)` (calls `onSystemMessage` callback)
   - `_insertLocalMessage` → `insertLocalMessage(text, channel, messageId, replyTo)`
   - `_truncateChannelMessages` → `truncateChannelMessages(channel)`

2. **Mid-level methods:**
   - `_subscribeChannel` → `subscribeChannel(channelName)`
   - `_subscribeAll` → `subscribeAll(channels)`

3. **Message-handling core:**
   - `_onMessage` → `onMessage(msg)`
   - `_onOwnIrcMessage` → `onOwnIrcMessage(ircMsg)`

4. **Top-level orchestrators:**
   - `_doSendMessage` → `doSendMessage(text, channel, ...)`
   - `_connect` → `connect(channels)`

**After each individual method move:** update call sites in `home_screen.dart`, run `flutter analyze`, fix references to now-external state.

### Critical: retest duplicate-detection edge cases

This stage touches the pending-message/anti-duplicate logic. Before committing, verify:
- Rapid duplicate sends
- IRC-fallback reconciliation
- Anti-duplicate bypass chaining (`normalizeForReconciliation` / `bypassTextDuplicate` from `lib/util/text_bypass.dart`)

`_HomeScreenState` after Stage 3 should hold a single manager instance and mostly delegate: `initState` creates/wires, `dispose` disposes, thin wrapper methods just forward.

**Expected result:** ~800-1000 lines off `home_screen.dart`.

---

## Stage 4 — Cleanup pass

1. Re-read remaining `home_screen.dart` (should be ~800-1200 lines): `build()`, `_buildChat`, `_buildEmpty`, `_buildSlideUpContent`, `_buildReplyIndicator`, `_buildMessageSpans`, `_buildBadgeSpans`, lifecycle/focus callbacks, and thin delegation wrappers.
2. Tighten API surfaces — no fields left exposed as public just to avoid writing a proper method.
3. Run `flutter analyze` and full manual QA: connect, join/leave channel, send message, duplicate send, mention/emote autocomplete, thread view, mentions panel, emote menu, user profile sheet, settings sync.
4. Final commit, open PR for review.

---

## Key design decisions (resolved)

- **`_EmoteMenuPanelWidget` coupling to `_HomeScreenState` statics:** Resolved by adding `emoteMaxFraction` and `sheetAnimDuration` constructor params (Stage 1, Commit 6). Lower risk than promoting constants to a shared file preemptively.
- **Class renaming:** Every extracted `_Foo`/`_FooState`/`_FooData` is renamed to public `Foo`/`FooState`/`FooData`. Dart privacy is file-scoped; underscore names aren't importable.
- **`_PendingLocal`:** Moves with `chat_connection_manager.dart` (Stage 3), not its own file. It's a private implementation detail of the pending/duplicate logic.
- **State management:** `ChatConnectionManager` is a plain class, not `ChangeNotifier`. Exposes `ValueNotifier`/callbacks. Consistent with the codebase's existing `setState` + `ValueNotifier` + `ListenableBuilder` patterns.
- **`/me` command:** Handled inside `CommandHandler` like any other command. `IrcService` is passed as a constructor dep.
- **Commit granularity:** One panel/sheet unit per commit (Widget + State + private data class as a unit). Six commits for Stage 1.
- **Line numbers:** Never trust a static plan. Re-grep for instantiation sites and method boundaries immediately before each commit — prior commits shift line numbers.

---

## Risk notes

- `_EmoteMenuPanelWidget` is the only Stage 1 widget that couples to `_HomeScreenState` internals (static consts). Resolved with new params.
- `_buildMessageSpans` and `_buildBadgeSpans` stay in `home_screen.dart` — they're passed as callbacks to extracted widgets and touch `_emoteManager` / `_badgeService`. Extracting them would be circular or require passing those services through to widgets.
- Duplicate-detection logic in Stage 3 is hard-won and subtle. Method-by-method move with analyze/test checkpoints is mandatory. Never move `_onMessage` before `_insertLocalMessage`'s dependencies are stable.
- `normalizeForReconciliation` / `bypassTextDuplicate` are already in `lib/util/text_bypass.dart`. No extraction needed; the connection manager imports them directly.
