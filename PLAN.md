# Emote Relative Scale + Timestamp Alignment Fix

## Summary

7TV emotes carry per-file `width`/`height` in `host.files[]`. Standard emotes: 1x=32, 2x=64, 3x=96, 4x=128. Small emotes are proportionally smaller at every tier. Our parser discards this data, so all emotes render at the same 28×28 size.

Additionally, the current `SizedBox(height: 28)` with no `width` causes `WidgetSpan` to report infinite intrinsic width, breaking `Text.rich` layout and misaligning timestamps in the thread panel.

Both issues are fixed together: use `28 * relativeScale` for both width and height (square), giving `WidgetSpan` a finite intrinsic width while correctly sizing small emotes.

---

## Files to change

### 1. `lib/models/generic_emote.dart` — add `relativeScale` field

Add `final double relativeScale;` with default `1.0`.

Update `toJson` → add `'relativeScale': relativeScale`.
Update `fromJson` → add `relativeScale: (json['relativeScale'] as num?)?.toDouble() ?? 1.0`.

### 2. `lib/services/emote_providers/seven_tv_emotes.dart` — extract width + compute scale

In the file selection loop (lines 58-69), also capture `file['width']` and parse the tier multiplier from `file['name']`.

**Tier standard widths:** `{1: 32, 2: 64, 3: 96, 4: 128}`.

**Parse multiplier from name:** `name` is e.g. `"4x.webp"` → extract `"4"` → `int.parse("4")`.

**Formula:** `relativeScale = fileWidth / (multiplier * 32.0)`.

Pass `relativeScale` to `GenericEmote(...)`.

### 3. `lib/widgets/emote_text.dart` — use `relativeScale` for emote sizing

Replace the hardcoded `const emoteHeight = 28.0` with `final size = 28.0 * data.base.relativeScale`.

Use `size` for both `width` and `height` on `SizedBox` and `CachedNetworkImage`.
Use `BoxFit.contain` (square container).
Overlays: `Positioned.fill` already sizes to parent — no change needed.

### 4. Tests

- `emote_manager_test.dart`: `relativeScale` JSON round-trip
- `emote_text_test.dart`: small-scale emote renders at scaled size; zero-width overlay on small base uses base's size

---

## Verification

- `flutter analyze` — clean
- `flutter test` — all pass
- Thread panel timestamps align correctly
- Small7TV emotes render smaller than 28×28
- Normal emotes still render at 28×28
- Zero-width overlays on small bases align pixel-for-pixel
