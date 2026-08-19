# Changelog

All notable changes to Mukker are documented here. The format loosely follows
[Keep a Changelog](https://keepachangelog.com/).

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
  - Snippet files exported by earlier builds still import (`sniptory.snippets.v1` stays in
    `MukkerExport.acceptedFormats`).
  - **You must re-grant Accessibility and Screen Recording once**: a bundle-identifier change
    makes macOS treat this as a new app, and permissions are the one thing no migration can carry.
  - Export/import types renamed `Sniptory*` → `Mukker*`; the Homebrew cask is now `mukker`.

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
- **First-run migration** — an existing `sniptory.sqlite` (with its image and
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
- Editor: pan tool uses the correct open-hand / closed-hand cursor icons.
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
