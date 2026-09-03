# Changelog

All notable changes to Mukker are documented here. The format loosely follows
[Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Changed
- **Editor toolbar is now two rows.** Window chrome (undo/redo, zoom, image size, Copy and Save)
  sits on top; the tools and their style controls sit below. The thirteen tools are grouped into
  related clusters instead of one undifferentiated run, and the color swatches and width slider
  are **contextual** — they appear only for a tool that actually draws something. Copy and Save
  now carry their labels and a resting tint, so the primary actions look like primary actions.
- Editor: the active tool is filled with the accent color instead of a 25%-opacity tint that was
  easy to miss at a glance, and every toolbar control answers the pointer with a hover highlight.
- Editor: **the pointer now matches the tool** — a crosshair to draw or crop, an open hand (closed
  while dragging) to pan, an I-beam for text. Previously every tool showed the plain arrow.
- Editor: switching tools with the keyboard names the tool in the on-screen HUD, so a keypress is
  confirmed even when you're looking at the canvas rather than the toolbar.
- Editor: arming the crop tool no longer shoves the toolbar sideways — Apply/Cancel take over the
  trailing slot of the second row, leaving Copy and Save where they were.
- Editor: **the editor window can now be much narrower.** Its 1080 pt minimum width existed only to
  keep the one-row toolbar visible; it is now 860 pt — what the widest toolbar state actually needs
  — so a small capture opens in a correspondingly small window. The window enforces that floor
  itself now, so it can no longer be dragged narrow enough to clip the toolbar.
- Editor: drawing is smoother — the base image is no longer re-wrapped and resampled on every
  frame of a drag, and freehand strokes drop points too close together to see instead of
  accumulating one per mouse event.
- Settings → Capture and the editor toolbar now render the same color-swatch component, so the
  two palettes can't drift apart again.

### Fixed
- Editor: ⌘Z while typing in a text annotation undid the entire editor state instead of the text
  edit. Undo/redo are now handled alongside the editor's other keys, which stand down while a text
  field has focus.

## [0.8.1] - 2026-09-02

### Added
- **Hourly chime.** A new section in **Settings → Calendar** plays a sound at the top of every
  hour, on whichever output device the Mac is currently using. Pick the sound from the built-in
  system sounds (with a Test button), and limit it to a range of hours — 9:00 to 22:00 out of the
  box, and a range that ends before it starts wraps past midnight. Off by default.

## [0.8.0] - 2026-09-02

### Added
- **Calendar in the menu bar.** The menu bar item now shows today's date — a calendar-page icon
  carrying the day number, which is all it shows out of the box. Clicking it drops down a month
  calendar you can page through, jump back to today from, and pick any day in; under it sits that
  day's schedule, read from the system calendars in each calendar's own colour, and days with
  something on them are marked with a dot in the grid. The rest of the menu is unchanged,
  underneath. A new **Settings → Calendar** tab picks what shows next to the day number
  (weekday, `Sep 2., Wed`, your own date pattern — with a live preview), which day the week starts
  on, whether to show week numbers, and which calendars count; a calendar you subscribe to later
  is included automatically.
- **Calendar access** is a new permission, listed alongside the others in
  **Settings → Permissions**. It is **read-only** — Mukker never creates, changes or stores an
  event — and entirely optional: without it the calendar still works, just without the events.

### Changed
- **The menu is no longer translucent.** macOS draws menus over a blurred view of whatever is
  behind them, which made the calendar grid hard to read; Mukker's menu and its submenus are now
  opaque.
- **Keep Awake shows itself differently** while the date is on. The date has taken over the icon,
  so instead of swapping glyphs the calendar page fills in solid — with the day number showing
  through it — while the Mac is being held awake. Turn the date off in Settings and the old icon
  swap comes back.

## [0.7.0] - 2026-09-02

### Added
- **Window tiling.** Four global shortcuts snap the frontmost window to half of the screen it is
  already on, filling the space between the menu bar and the Dock: **⌃⌘←** left half, **⌃⌘→**
  right half, **⌃⌘↓** top half, **⌃⌘↑** bottom half. The move is immediate — no animation and no
  focus change. A new **Settings → Windows** tab holds the on/off switch, the four rebindable
  shortcuts and an optional gap between tiled windows; switching tiling off releases the ⌃⌘arrow
  combos back to other apps rather than swallowing them. Moving windows uses the Accessibility
  permission Mukker already needs for pasting, so nothing new to grant on an existing install —
  **Settings → Permissions** now lists moving windows alongside pasting, double-⌘C merging and
  scrolling capture, and stays the one place any permission is granted.

## [0.6.0] - 2026-08-21

### Fixed
- **The popup no longer needs a second ⌘E press.** Three separate defects could each swallow a
  press: the popup was ordered behind another window (the capture editor, Settings, an alert) while
  still counting as open, so the next press "closed" something you couldn't see; `hidesOnDeactivate`
  tied the panel's visibility to app activation, which macOS 14 can refuse; and ⌘E arriving twice
  (global hotkey plus the menu item's key equivalent) could open then immediately close it. The
  hotkey now only closes the popup when it actually has focus, and re-shows it otherwise.

### Removed
- **Migration from pre-rename installs is gone**, along with every trace of the app's former
  identity. This is a **breaking change** if you are upgrading from a build older than 0.5.0:
  the old database, preferences and popup shortcut are no longer adopted on first launch, and
  snippet files exported by those builds no longer import. Export your snippets with 0.5.0 first if
  you still need them.

## [0.5.0] - 2026-08-19

### Added
- **Keep Awake** — a third feature set alongside clipboard/snippets and capture. A *Keep Awake*
  submenu in the menu bar stops the Mac idling to sleep, and the menu-bar icon changes while it's
  on so the state is visible at a glance.
  - An activation lasts **2 hours** by default and then releases itself; the menu shows the time
    remaining and offers one-off durations from 5 minutes to 5 hours, or until you turn it off.
  - **Settings → Keep Awake** sets the default duration, whether to turn on at launch, whether to
    let the display sleep while the machine keeps running, and whether an explicit manual sleep
    turns it off.
  - The underlying power assertion is short-lived and refreshed on a timer, so a crash can't leave
    your Mac pinned awake with nothing left to release it.

### Changed
- **The app's data identity is now Mukker**, matching its name. The bundle identifier is
  `com.mukker.Mukker`, storage moved to `~/Library/Application Support/Mukker/mukker.sqlite`, and
  new snippet exports are written as `mukker.snippets.v1`.
  - Your history, snippets and settings are **migrated automatically on first launch** — copied,
    not moved, so an older build still works if you roll back.
  - Snippet files exported by earlier builds still import (the previous format string stays in
    `MukkerExport.acceptedFormats`).
  - **You must re-grant Accessibility and Screen Recording once**: a bundle-identifier change
    makes macOS treat this as a new app, and permissions are the one thing no migration can carry.
  - The export/import types were renamed to match the format; the Homebrew cask is now `mukker`.

### Removed
- **Dead pixelate codepath** — `ImageEffects.pixellate`, `EditorViewModel.pixelatedBase`/
  `pixelatedLayer`/`displayPixelatedLayer` and `AnnotationCanvas.pixelatedImage`. The canvas
  stored the pre-rendered pixelated image and never drew it; blur has been rendered by
  `AnnotationLayer.drawBlur`'s graphics filter all along.
- `ImageExporter.savePanel`, `PopupResult.isSnippetSection`, `ClipboardCache.clearUnpinned` and
  `KeyCombo.displayString` — no callers.

### Fixed
- **Renaming no longer breaks the tests.** The Swift module is pinned to `AppCore`
  (`PRODUCT_MODULE_NAME`), so `@testable import` survives a rename; previously a rename left the
  test target unable to resolve the app module, which `make build` doesn't catch.
- **`scripts/rename.sh` no longer rewrites frozen identity in the docs.** It used to
  find-and-replace the old name everywhere, turning accurate statements about the Application
  Support folder, the bundle ID and the export format into false ones.
- `Branding.snippetExportFormat` is now actually the source of the export format string rather
  than an unused duplicate of it.

## [0.4.0] - 2026-08-19

### Added
- **Screen capture and annotation** — the whole capture app is now part of Mukker:
  area, fullscreen and scrolling capture, and the borderless annotation editor
  (arrow, line, rectangle, rounded rectangle, ellipse, text, highlight,
  blur/pixelate, freehand pen, numbered counter), with crop, movable base image,
  wheel zoom, and copy/save as PNG or JPEG.
- **Menu bar submenus** — one icon, with *Clipboard & Snippets* and *Capture*
  submenus so each feature set keeps its own entry points.
- **First-run migration** — an existing pre-merge database (with its image and
  rich-text sidecars) is adopted automatically, and the capture app's preferences
  are imported from its old defaults domain, so nothing is lost in the merge.

### Changed
- **Settings is one window with five tabs** — *Clipboard* and *Capture* carry each
  original app's settings, while *Hotkeys*, *Permissions* and *About* are shared.
- **One permission service** — Accessibility and Screen Recording are now handled
  by a single implementation with a single status view. One Accessibility grant
  covers pasting, double-⌘C merging and scrolling capture.
- **One hotkey manager** — the popup shortcut and the three capture shortcuts are
  registered together from a shared `ShortcutSettings`, and all four are editable
  in the Hotkeys tab. An existing popup shortcut is migrated across automatically.
- **Renaming the app is a one-command operation** — source directories are named
  `App/`/`AppTests/`, product-name strings funnel through `Branding.swift`, and
  `scripts/rename.sh` handles the rest. Data locations deliberately don't follow
  a rename.

---

Everything below is the history of the two apps before they merged.

## Clipboard & snippets (pre-merge)

## [0.3.2] - 2026-06-15

### Changed
- **Popup size is now relative to the screen** — instead of a fixed
  100%–300% scale of an 820×480 base, the popup is sized as a percentage of the
  available screen (`visibleFrame`), 30%–90% (default 60%). It preserves the
  popup's proportions and fits them into that percentage, so it scales sensibly
  across laptops and external displays. The Settings → General slider now reads
  in percent-of-screen, and the results-list/preview split is computed
  proportionally via a `GeometryReader`.
- **Popup is centered both horizontally and vertically** — removed the previous
  ~15% upward vertical offset so it now opens at the true center of the screen.

## [0.3.1] - 2026-06-10

### Fixed
- **Custom popup background now reads correctly in dark mode** — the popup's
  appearance is forced to match the chosen background's luminance, so a light
  background gets dark text (and a dark background light text) regardless of the
  system light/dark setting.

## [0.3.0] - 2026-06-10

### Added
- **Customizable popup appearance** (Settings → General → Appearance) — a new
  section lets you tailor the popup's look:
  - **Custom background color** — toggle + ColorPicker replaces the
    appearance-adaptive `PopupTheme` colors for the entire popup (search row,
    list, and preview panes) via the new `PopupPalette` helper. Ships enabled
    with a white (#FFFFFF) background.
  - **Colored bezel** — toggle + ColorPicker + width slider (0–12 pt) draws a
    `RoundedRectangle strokeBorder` around the popup edge. Ships enabled with a
    7 pt orange (#E69718) bezel.
  - Colors persist in `UserDefaults` as `#RRGGBBAA` hex (sRGB) via a new
    `Color+Hex.swift` extension. Changes take effect the next time the popup
    opens.

## [0.2.0] - 2026-06-10

### Added
- **Dark mode** — the popup follows the system appearance (light mode unchanged).
- The global shortcut now **toggles** the popup: press it again to close.
- **Clear History…** button (Settings → Clipboard → History) removes all unpinned
  items after confirmation; archives text to forever-history when enabled.
- ⌘V / ⌘A / ⌘X now work in the popup's search field; ⌘C copies the field's
  text selection when one exists.
- Hotkey recorder: Esc cancels recording, and a **Reset to Default** button
  restores ⌘E. The menu bar item shows the configured shortcut.
- Re-copying content already in history bumps it to the top instead of being
  ignored (honors the move-to-top setting).

### Changed
- The snippet editor **autosaves** pending edits when you switch snippets.
- Deleting a collection or snippet in the Snippets Manager asks for
  confirmation (collection deletes cascade to their snippets).
- Preview timestamps use your locale's time format.
- Faster popup rendering: image rows use cached thumbnails instead of decoding
  full PNGs on every keystroke.

### Fixed
- Fast-append no longer pastes stale rich text: merging clears the item's
  outdated RTF, so formatting-aware apps receive the merged text.
- On-disk image/RTF files are deleted on **every** deletion path (max-items
  trim, item delete, clear, retention), fixing a steady disk leak.
- The max-items trim follows the last-used order, so a recently reused item
  can no longer be silently removed.
- Image clips record true pixel dimensions (retina screenshots no longer
  report half their size).

## [0.1.5] - 2026-06-09

### Added
- **Configurable popup size** — a new Settings → General tab exposes a slider
  (100 %–200 %) that scales the popup window. The default is now **130 %**
  (1066 × 624), up from the previous 820 × 480. The list column scales
  proportionally; row heights and fonts stay the same so more content is
  visible. Changes take effect the next time the popup opens.

## [0.1.4] - 2026-06-09

### Added
- Settings: **About** tab — shows the app icon, name, version and build number, a
  link to the GitHub repository, and the changelog (read from the bundled
  `CHANGELOG.md`).
- **Start at Login** option.
- Option to show the clipboard preview in plain text.

## [0.1.3] - 2026-06-03

### Changed
- The popup now always resets its selection to the first row and scrolls to the
  top each time it opens.

## [0.1.2] - 2026-05-29

### Added
- Skip clipboard items marked concealed/sensitive by password managers, and skip
  copies originating from password-manager browser extensions.

### Fixed
- Refresh the snippet cache after an import so changes show immediately.

## [0.1.1] - 2026-05-29

### Added
- Initial release: a menu-bar utility combining **clipboard history** and
  **snippets**, opened with a global shortcut (⌘E by default) into a centered
  floating popup that pastes the selected item into the previously-active app.
- Rich-text support in history, with plain-text paste via ⌘⇧V.
- "Forever history" archive for deleted text items.
- Read-only import of `.alfredsnippets` bundles.
- ⌘C in the popup copies the selected item without pasting.
- Fast-append (double-tap ⌘C) merges the just-copied text onto the previous item.
- Per-kind retention and ignore-list settings.

## Capture & annotation (pre-merge)

## [0.1.8] - 2026-06-10

### Changed
- Editor: **toolbar press feedback** — every toolbar button now shows a springy scale-down
  animation and a soft gray highlight flash when pressed. Copy and Save use a stronger
  `prominent` variant with a deeper press (78 % scale) and an accent-colored highlight, so
  the click registers visually even when the window closes immediately after.

## [0.1.7] - 2026-06-10

### Added
- Settings / Editor: **"Esc copies to clipboard and closes editor"** — a new opt-in General
  setting (off by default). When on, pressing `Esc` with no pending crop and nothing selected
  copies the capture and closes the window (regardless of "Close editor after copying").
  Cancelling a crop and deselecting an annotation still take priority.

## [0.1.6] - 2026-06-10

### Fixed
- Editor: **window memory leak** — editor windows now deregister from `AppDelegate` on close so
  they are properly released; the double-capture re-entry guard (which was checking a stale
  reference) is also fixed.
- Editor: **selection style stomping** — selecting an existing annotation loads its style into
  the toolbar instead of overwriting it with the current defaults; toolbar style edits now mutate
  only the changed field (color, thickness, or text size) and leave other properties intact; undo
  records one entry per slider drag (on commit) rather than per tick.
- Editor: **stale text bounds** — text annotation rects now resize to the rendered text on every
  draw so hit-testing and export no longer clip or miss text.
- Editor: **keyboard gaps** — `⌘C` copies the capture to the clipboard from anywhere in the
  editor; `⌘W` closes the editor window; `Esc` now also ends inline text editing (in addition to
  deselecting and cancelling crop); `Return` applies a pending crop.

### Added
- Editor: **VoiceOver / accessibility** — toolbar buttons, color swatches, and sliders all carry
  descriptive accessibility labels so the editor is fully navigable with VoiceOver.

### Changed
- Editor: zoom steps are now multiplicative (smoother feel at all zoom levels).
- Capture: cursor is restored correctly while a scrolling capture is in progress.
- Settings: the monolithic `SettingsView` has been split into per-tab source files —
  `GeneralSettingsView`, `HotkeysSettingsView`, `ToolsSettingsView`, `PermissionsSettingsView`,
  and `AboutSettingsView` — for easier maintenance.

## [0.1.5] - 2026-06-09

### Fixed
- Editor: a freshly captured image now opens **centered with an equal transparent
  margin on all four sides**. The window reserves room for the configurable canvas
  padding, and the canvas scales from its center so the capture is no longer biased
  toward the top-left. Full-screen and scrolling captures still zoom to fit.

## [0.1.4] - 2026-06-09

### Added
- Settings: **About** tab — shows the app icon, name, version and build number, a
  link to the GitHub repository, and the changelog (read from the bundled
  `CHANGELOG.md`).
- Settings: **Permissions** tab — shows the live status (Granted / Not granted) of the
  Screen Recording and Accessibility permissions, with **Open System Settings** and
  **Request Access** buttons for each. Status refreshes automatically while the tab is open.

## [0.1.3] - 2026-06-02

### Added
- Settings (General): **Canvas padding** — a configurable transparent margin
  (default 24 pt) shown around the capture when the editor opens, so it presents as
  a small canvas floating in the checkerboard surround. On-screen only; the exported
  image is unchanged.

## [0.1.2] - 2026-06-02

### Added
- Settings (General): **Close editor after copying** and **Close editor after saving**
  — separate toggles, both on by default. When on, the editor window closes
  automatically once the capture is copied to the clipboard or successfully saved.
  Saving that fails leaves the window open so the error is visible.
- Editor toolbar shows a **`N pt` readout** next to the line-width / text-size slider.

### Changed
- Default **line width is now 2 pt** (was 5).
- **Highlight** is drawn with **rounded corners**.
- Tool keys swapped: **R = rounded rectangle, O = rectangle**.
- The capture **dimming overlay no longer fades** in/out (instant show/hide).
