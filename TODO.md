# TODO

## High Priority

- [ ] **Emotes & Badges** — Render Twitch emotes (global + channel) as images inline; render badges (mod, sub, VIP, etc). Non-negotiable feature, defer until core is solid.
- [ ] **Command autocomplete** — When typing `/` in the input, show a dropdown of available IRC commands (`/ban`, `/timeout`, `/color`, `/me`, etc). MUST HAVE, high priority.
- [ ] **IRC command support** — Route commands through IRC: `/ban`, `/timeout`, `/color`, `/me`, and any other standard Twitch `/` commands.
- [ ] **User profiles** — Tap a username → bottom sheet (1/3 screen) with PFP top-left, display name and account creation date top-right, four buttons: Mention, Whisper, Block, Report.
- [x] **Swipe between channels** — Swipe left/right on the chat area to move to the adjacent channel, in addition to tapping the channel bar.
- [x] **Chat room state** — Display current channel chat status below the input box (e.g. "Followers-only", "Emote-only", "Sub-only", "Live with X viewers for Yh Zm").
- [ ] **Thread view input** — Typing box inside the thread view; sending a message auto-replies to the most recent message in the thread.
- [x] **Clickable links** — Detect URLs in chat messages and make them tappable to open in an external browser.
- [ ] **Message cutoff** — When a channel exceeds N messages, truncate to N. Keep threads alive until the thread itself passes the threshold. System-level change.

## Medium Priority

- [ ] **Unread indicator** — Channel tab name is white when there are unread messages, grey when all are read.
- [ ] **Localized display names** — Research how Twitch handles localized/non-ASCII display names and ensure the app handles them correctly.

## Research / Open Ends

- [ ] **Rate limit enforcement** — Enforce the 20-msg / 30-sec limit before Twitch does, with a toggle to disable. Research Twitch's exact rate limit behavior to decide on implementation.

## Low Priority / Future

- [ ] **OS notifications + background** — Push notifications when mentioned/whispered while app is backgrounded; run keepalive in background.
- [ ] **Compact mode** — Toggleable compact layout with smaller fonts and tighter spacing.
- [ ] **Infinite scrollback** — Auto-load older messages from robotty when scrolling up past the initial history (future consideration).
