# Screenshot X — changes to Screendrop

A CleanShot X–style screenshot experience for Screendrop: a floating preview
that behaves like a real object, pinned captures you can resize and close with
the keyboard, and a scrolling capture that actually stitches the page.

Everything below is in this pull request. Fork-only settings (bundle
identifier, signing team, the personal Cloudflare worker URL and its token)
are deliberately **not** part of it.

## Preview and pins

- **Floating preview cards.** Recent captures appear as 200 × 132 rounded
  cards in a bottom-corner column, with light-grey hover controls instead of
  the previous dark chrome. Close sits in the top-left corner; copy and delete
  are stacked vertically in the middle (CleanShot-style) with a little air
  between them; cloud, pin and save stay in the bottom capsule.
- **Pins.** A capture can be pinned at the exact rectangle and size it was
  taken from, so it sits on top of the content it shows rather than jumping to
  the middle of the screen. One pin per file.
- **⌘W closes a focused pin**, never a preview card and never the page behind.
  With several pins the key walks the stack in reverse creation order
  (3 → 2 → 1) and only the last one hands focus back to the previous app.
  A confirmation ("Close this pinned screenshot?" / "Confirm closing pins",
  on by default) guards the action; the file is never deleted.
- **Resize grip.** An AppKit-backed corner grip (30 pt hit area, corner-resize
  cursor) instead of a SwiftUI drag gesture: it follows both axes, keeps the
  aspect ratio, clamps to the visible screen, rebuilds the shadow only at the
  end, and reveals the full toolbar once the pin passes 160 × 90.
- **Tiny pins** (below 160 × 90) show a compact close badge and a corner resize
  grip, so they can be grown instead of being a dead end.
- **Leave animations.** Pins slide slightly right and fade over 0.16 s; preview
  cards slide right and fade over 0.18 s. Both honour Reduce Motion.
- **The app's own windows never appear in captures.** Region captures used to
  blank out wherever a ScreenDrop window overlapped the area — even when that
  window sat behind the browser — because the whole process was excluded from
  the capture filter. Only windows explicitly marked hidden are excluded now,
  and pins/previews are hidden for the duration of a capture.

## Scrolling capture

- **It works.** A finished session is stitched, saved to the Screenshots
  folder, and shown as a preview. Manual scrolling with Return to finish,
  Esc to cancel, and an Auto Scroll mode.
- **Fixed transparent (black) frames.** The temporary PNG for each frame was
  opened lazily and then deleted, so every frame decoded as fully transparent
  once it was actually drawn. Frames are decoded before the file is removed.
- **The selection border is captured, not excluded.** Excluding a window whose
  frame spans the whole region produced a hole of exactly that size. The border
  is drawn just outside the selected rectangle and is simply photographed.
- **HUD and live preview stay outside the region**, so they cannot punch holes
  in the frames either.
- **Live preview card** in a free screen corner showing the latest viewport,
  frame count, stitched height, and a status line ("Capturing…", "Scroll the
  page to keep adding frames", blank-area warning).
- **Matching rewritten.** Row-brightness profiles nominate candidate offsets,
  then real 2D correlation scores each one, so a page of text no longer locks
  onto a repeated line band and stitches only a fraction of the page. Uneven
  scroll steps, fast flicks and long pages are handled; polling is 140 ms so
  consecutive frames overlap well.
- Blank first frames are retried, with a clear message if the area is protected
  or genuinely empty.

## Image quality

- **Resolution metadata.** Captures written through ScreenCaptureKit had no
  DPI tag, so macOS treated a 2× Retina capture as 72 dpi and displayed it at
  double size — the "magnifying glass" look. Every writer now tags files with
  **72 × display scale** (144 dpi on Retina), and re-encodes (JPEG/HEIC,
  annotations, crops, compression) preserve it.
- **Sharper pins**: images load at 2800 px with high-quality interpolation, and
  the thin outline that was drawn around pinned screenshots is gone.

## Capture workflow

- **Lighter selection overlay** (14 % scrim instead of 28 %) and a 140 ms
  handoff, so the screen is barely dimmed and returns to normal immediately.
- **Scrolling Capture shortcut** in Settings → Shortcuts (default ⌥6) and the
  menu bar, alongside the existing capture shortcuts.
- **Menu bar labels follow the settings**: reassigning a shortcut rebuilds the
  menu instead of leaving the old key on screen.
- **15-second auto-close** option for the preview.
- **On-device content naming** (Settings → Screenshots → "Name screenshots from
  their content"): Vision reads the capture and Apple Intelligence writes a
  short title, giving files such as `Invoices dashboard 2026-10-27 21.43.07.png`.
  Nothing leaves the Mac; the Library copy and the exported file are renamed
  together, and open editors are left alone.
- **Cloud upload** with a retention policy: at most 20 files or 100 MB, oldest
  deleted first, and single uploads above the cap rejected. The worker source
  lives in `cloud/academy-upload/worker.js`; its token is a Cloudflare secret
  and is never stored in the repository.
- **Removed the upstream worker-version nag.** It compared the deployed worker
  with a manifest in the upstream worker repository, which can never be right
  for a self-hosted worker.

## Diagnostics

Debug-only self-tests (`PreviewSelfTest`) cover the hover appearance of cards
and pins, a full scrolling session against a synthetic page (including a pin
laid over the region), the ⌘W pin stack, the resize maths, and the
content-naming pipeline. They compile out of Release builds.
