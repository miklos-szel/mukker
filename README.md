# Sniptory

A native macOS menu-bar utility that combines **clipboard history**, **text snippets**, and
**screen capture with annotation** in one app. A quick popup on a global shortcut pastes back
into the app you were just using; a capture shortcut opens a screenshot in a full annotation
editor.

## Features

### Clipboard & snippets

- **Clipboard history** — text (incl. **rich text**/formatting), images, and file lists, with per-kind retention and a max-items cap.
- **Snippets** — organize reusable text into collections; import `.alfredsnippets` snippet bundles and export/import Sniptory's own JSON.
- **Fast popup** (⌘E) — a single searchable list of snippets + history; reads from an in-memory cache so it opens instantly. Press the shortcut again to close. History lazy-loads in pages of 50; search spans everything.
- **Fast append** — double-tap ⌘C to merge the new copy onto the previous text item.
- **Star a clip into snippets** right from the preview.
- **Forever history** *(optional, off by default)* — archives text items as `.txt` files before they're deleted.
- **Privacy** — ignores configured apps (password managers preloaded), skips concealed/sensitive copies, and respects a max clip size. **Clear History…** wipes unpinned items on demand.
- **Screen-relative popup size** (30%–90% of your display) and a **customizable popup appearance** — background color plus a colored bezel with adjustable width.

### Capture & annotation

- **Area** (⌃⇧⌘4), **fullscreen** (⌃⇧⌘3) and **scrolling** (⌃⇧⌘5) capture.
- **Annotation editor** — arrow, line, rectangle, rounded rectangle, ellipse, text, highlight, blur/pixelate, freehand pen, and numbered counters, with configurable colors, line width and per-tool keys.
- **Crop, movable base image, wheel zoom**, and a checkerboard surround that exports white.
- **Copy or save** as PNG/JPEG, with optional 1× downscaling, a configurable destination folder, and auto-close after copy/save.

Captures copied to the clipboard also land in your clipboard history, so a screenshot you took
five minutes ago is still one ⌘E away.

## Shortcuts

| Key | Action |
| --- | --- |
| ⌘E | Open / close the popup |
| ⌃⇧⌘4 / ⌃⇧⌘3 / ⌃⇧⌘5 | Capture area / screen / scrolling |
| ↑ / ↓ | Move selection in the popup |
| Return | Paste selected item (with formatting) |
| ⌘⇧V | Paste **without** formatting (plain text) |
| ⌘C | Copy selected item to the clipboard (no paste) |
| → / Return on a collection | Drill in |
| ⌘, | Open Settings |
| Esc | Close |

All four global shortcuts are configurable in **Settings → Hotkeys**.

## Permissions

One **Accessibility** grant covers everything that needs it: pasting into the active app,
double-⌘C merging, and auto-scrolling during scrolling capture. **Screen Recording** is
additionally required for capture. Both are shown live, with grant buttons, in
**Settings → Permissions**.

## Build / run

The Xcode project is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen).
A `Makefile` wraps the common flows:

```bash
make build    # regenerate project + build
make run      # build and launch
make test     # run the test suite
```

SPM dependencies (resolved on first build): GRDB.swift, HotKey, ZIPFoundation.

## Renaming the app

The product name is not baked into the tree: source directories are `App/` and `AppTests/`,
the `Makefile` reads the scheme out of `project.yml`, and every user-facing name comes from
`App/Support/Branding.swift`.

```bash
./scripts/rename.sh NewName                              # product name only
./scripts/rename.sh NewName --bundle-id com.me.NewName   # also change the bundle ID
```

Data locations deliberately do **not** follow a rename — the Application Support folder name
and the snippet export format string are frozen in `Branding.swift` so existing databases and
previously exported files keep working.

## Install

Sniptory ships ad-hoc-signed (no notarization).

- **DMG** — download from [Releases](https://github.com/miklos-szel/sniptory/releases), open it, and drag the app to `/Applications`. On first launch, right-click → **Open** to bypass Gatekeeper.
- **Homebrew** — `brew install --cask miklos-szel/sniptory/sniptory` (the cask strips the quarantine flag on install).
