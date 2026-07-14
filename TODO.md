# TODO

## High Priority

- [x] **Switch to Send Chat Message API** — Replaced IRC-based message sending with `POST /helix/chat/messages`. Added `user:write:chat` scope. Commands like `/color`, `/ban`, `/timeout` now work again via dedicated API endpoints.
- [ ] **Emotes & Badges** — Render Twitch emotes (global + channel) as images inline; render badges (mod, sub, VIP, etc). Non-negotiable feature, defer until core is solid.
- [ ] **Command autocomplete** — When typing `/` in the input, show a dropdown of available IRC commands (`/ban`, `/timeout`, `/color`, `/me`, etc). MUST HAVE, high priority.
- [x] **IRC command support** — Commands routed through dedicated API endpoints: `/ban`, `/timeout`, `/unban`, `/color`, `/delete`, `/clear`, `/announce`, `/shoutout`. `/me` sent via IRC (only supported IRC command).
- [x] **User profiles** — Tap a username → bottom sheet (1/3 screen) with PFP top-left, display name and account creation date top-right, four buttons: Mention, Whisper, Block, Report.
- [x] **Swipe between channels** — Swipe left/right on the chat area to move to the adjacent channel, in addition to tapping the channel bar.
- [x] **Chat room state** — Display current channel chat status below the input box (e.g. "Followers-only", "Emote-only", "Sub-only", "Live with X viewers for Yh Zm").
- [x] **Thread view input** — Typing box inside the thread view; sending a message auto-replies to the most recent message in the thread.
- [x] **Clickable links** — Detect URLs in chat messages and make them tappable to open in an external browser.
- [x] **Message cutoff** — When a channel exceeds N messages, truncate to N. Keep threads alive until the thread itself passes the threshold. System-level change.

## Medium Priority

- [ ] **Documentation** — Add comprehensive comments throughout the codebase explaining architecture, data flow, key design decisions, and non-obvious logic (e.g. EventSub vs IRC split, underline animation system, thread panel architecture).
- [x] **/me handling** — `/me` messages detected from `\x01ACTION ... \x01` wrapping in both EventSub and IRC. Rendered as `username message` (no colon, message colored like username) in all 3 views.
- [ ] **Unread indicator** — Channel tab name is white when there are unread messages, grey when all are read.
- [ ] **Localized display names** — Research how Twitch handles localized/non-ASCII display names and ensure the app handles them correctly.

## Research / Open Ends

- [ ] **Rate limit enforcement** — Enforce the 20-msg / 30-sec limit before Twitch does, with a toggle to disable. Research Twitch's exact rate limit behavior to decide on implementation.

## Low Priority / Future

- [ ] **Vertical scrolling (desktop)** — Mouse wheel doesn't change channels on desktop. `PointerScrollEvent` is consumed by the inner `ListView.builder` before reaching any outer `Listener`. Not a priority since this is a mobile app.
- [ ] **OS notifications + background** — Push notifications when mentioned/whispered while app is backgrounded; run keepalive in background.
- [ ] **Different mode** — Toggleable type box visibility and fullscreen.