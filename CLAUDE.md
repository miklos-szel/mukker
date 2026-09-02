# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Mukker is a native macOS menu-bar utility combining four feature sets — two of which used to be
separate apps:

- **Clipboard history + snippets** (with rich-text support; no auto-expansion). A global shortcut
  (⌘E default) pops a centered floating panel showing text/image clipboard history and snippet
  collections, and pastes the selected item into the previously-active app via simulated ⌘V.
- **Screen capture + annotation.** A global hotkey (or the menu-bar menu) triggers an area,
  full-screen, or scrolling capture; the capture opens in a borderless editor window with a
  toolbar for annotating (arrow, line, rectangle, rounded rectangle, ellipse, text, highlight,
  blur/pixelate, freehand pen, numbered counter), cropping, then copying to the clipboard or
  saving a PNG/JPEG. The capture side is **stateless** — captures live only until copied or
  saved; there is no capture history.
- **Keep Awake.** A menu-bar toggle that holds an IOKit power assertion so the Mac stops idling to
  sleep, for a configurable duration (**2 hours** by default) after which it releases itself. It
  needs no permissions and touches neither the database nor any other subsystem.
- **Window tiling.** Four global shortcuts (⌃⌘←/→/↓/↑ by default) that snap the frontmost window
  to a half of whichever screen it is already on, via the Accessibility API. Stateless — it reads
  a window, moves it and forgets it; there is no window history and no restore.

The sides are deliberately independent at runtime. The only things they share are
`PermissionsService`, `HotKeyManager`/`ShortcutSettings`, `Log`, `AppPaths`, `Branding`, the
`AppDelegate`, and the Settings window. Emergent integration: a capture copied to the clipboard
is picked up by `ClipboardMonitor` like any other copy, so captures land in history for free.

## Naming

The app is **Mukker** throughout — product name, bundle identifier, storage folder and export
format all agree, and nothing in the tree carries an earlier identity: the one-shot migration that
adopted data written under the pre-rename name has been removed, so there is no legacy path left to
preserve.

Identity is split into two halves that behave differently on a rename:

| Follows the product name | Frozen until deliberately migrated |
| --- | --- |
| Window titles, menus, alerts, saved screenshot names (`Branding.name`) | Bundle ID `com.mukker.Mukker` — changing it resets TCC grants and hands the app an empty defaults domain |
| `project.yml` `name:`, the `.xcodeproj`, the built `.app`, the scheme | `Branding.supportFolderName` + `databaseFileName` → `~/Library/Application Support/Mukker/mukker.sqlite` |
| Repo/README headings | `Branding.snippetExportFormat` (`mukker.snippets.v1`) and the `Mukker*` exporter/importer types |

The frozen half may only change together with a migration step that adopts the old value, and no
such step exists in the tree any more — so each constant now costs something specific on its own:
`supportFolderName`/`databaseFileName` orphan the database and its sidecars (the app starts from an
empty history), the bundle ID resets TCC grants and hands the app an empty defaults domain (history
survives, settings and permissions don't), and `snippetExportFormat` makes previously exported
snippet files unreadable unless the old string is added to `MukkerExport.acceptedFormats`.
`scripts/rename.sh` derives its protect-list from these constants and skips doc lines mentioning
them, so a plain rename can never silently rewrite them.

## Build / test / run

The Xcode project (`Mukker.xcodeproj` — named after `project.yml`'s `name:`) is
**generated from `project.yml`** by
[xcodegen](https://github.com/yonaskolb/XcodeGen). Treat `project.yml` as the source of truth —
edit it and re-run `xcodegen generate` (or `make generate`). Do not hand-edit the `.xcodeproj`;
it is not checked in.

```bash
make build        # regenerate project + build Debug
make test         # run all tests
make test-one ONLY=SnippetBundleImporterTests/testParsesProvidedFixture   # single test
make run          # quit any running instance, build, launch
make rebuild      # quit + clean + regenerate + build + launch
make quit         # quit cleanly (no Dock icon, so AppleScript/pkill)
make dmg          # Release .dmg into dist/ (ad-hoc signed)
```

SPM dependencies (resolved on first build): `GRDB.swift` (SQLite), `HotKey` (Carbon global-hotkey
wrapper), `ZIPFoundation` (.alfredsnippets unzip).

## Renaming the app

The product name is **not** baked into the tree, and this is load-bearing — don't undo it:

- Source directories are `App/` and `AppTests/`, never named after the product.
- `Makefile` and `scripts/build-dmg.sh` read the scheme/app name out of `project.yml`
  (`awk '/^name:/{print $2; exit}'`).
- Every user-facing name comes from **`App/Support/Branding.swift`** (`Branding.name`, read from
  `CFBundleName` at runtime). Never hardcode the app name in a string literal — interpolate
  `Branding.name`.
- The Swift module is pinned to **`AppCore`** via `PRODUCT_MODULE_NAME` in `project.yml`, so
  `@testable import AppCore` survives a rename. Don't let the module name track the product name —
  `make build` compiles only the app target, so a broken test import hides until `make test`; use
  `make build-tests` for a fast compile-only check of the test target.
- `scripts/rename.sh NewName [--bundle-id …] [--repo …]` (or `make rename NAME=NewName`) does the
  rest: `project.yml` (name, target key, `CFBundleName`/`DisplayName`, the test target's dependency
  and `TEST_HOST`), `Info.plist`, optionally `Branding.repoURL`, the docs, then a clean
  `xcodegen generate`. It has already been used once.

Two constants in `Branding` are **frozen** and must not follow a rename:
`supportFolderName` (the Application Support folder holding the database + sidecars — renaming
orphans user data) and `snippetExportFormat` (the wire format string in exported snippet files).
The rename script skips doc lines mentioning either, plus the bundle ID — a blanket
find-and-replace across the docs turns accurate statements into false ones, which is exactly what
happened the first time.
`MukkerExporter`/`MukkerImporter`/`MukkerExport` are named after the file format, not the product,
so they only move when the format does — and when it moves, the old string must stay in
`MukkerExport.acceptedFormats` or previously exported files stop importing.

A bundle-ID change also resets TCC, so a rename that touches it costs the user their Accessibility
and Screen Recording grants — there is no way to migrate those.

## Architecture

**Layering (strict, top → bottom):** `App` → `Features` → `Core` + `Storage` → `Support`.
Higher layers may import lower; never the reverse.

**Singleton coordinators.** Long-lived services use `@MainActor static let shared`:
`AppDatabase`, `SnippetCache`, `ClipboardCache`, `ClipboardSettings`, `CaptureSettings`,
`ShortcutSettings`, `HotKeyManager`, `ClipboardMonitor`, `ClipboardRetentionService`,
`FastAppendService`, `ActiveAppTracker`, `PermissionsService`, `LoginItemService`, `Paster`,
`PopupWindowController`, `CaptureCoordinator`, `ScrollingCaptureService`,
`EditorWindowController`, `AppIconCache`, `ClipThumbnailCache`, `KeepAwakeSettings`,
`KeepAwakeService`, `WindowTilingSettings`, `WindowTiler`.
`AppDelegate.applicationDidFinishLaunching` wires them together — start there to follow runtime
flow.

### Shared plumbing

- **`PermissionsService`** is the single owner of both TCC permissions. Screen Recording
  (`hasScreenRecordingPermission` / `requestScreenRecordingPermission` / `ensureScreenRecording`)
  and Accessibility (`hasAccessibilityPermission` / `requestAccessibilityPermission` /
  `ensureAccessibility(reason:)`), each with an "open System Settings" helper and a denied-alert.
  Callers use the `ensure*` methods; the settings pane uses the raw checks plus a 1 s poll. One
  Accessibility grant serves four subsystems: `Paster` (⌘V), `FastAppendService` (global ⌘C
  monitor), `ScrollingCaptureService` (synthetic scroll) and `WindowTiler` (moving windows).
  Don't add a second permissions type.
- **`ShortcutSettings`** holds all eight global combos (`popupCombo`, `areaCombo`,
  `fullscreenCombo`, `scrollCombo`, plus `tileLeftCombo`/`tileRightCombo`/`tileTopCombo`/
  `tileBottomCombo`) as `HotKey.KeyCombo`s persisted to `UserDefaults`, and publishes
  `comboChanges` — whose `dropFirst(n)` **must equal the number of merged publishers**, because
  `@Published` replays on subscribe. **`HotKeyManager`** subscribes to it and re-registers every
  hotkey on change (the `HotKey` objects must be retained or the shortcuts die). Each shortcut is
  a `HotKeyManager.Action` carrying an `isEnabled` closure, so a switched-off feature's combos are
  *not registered* rather than registered-and-ignored — that is what frees ⌃⌘arrows for other
  apps; `start(…, reloadOn:)` takes an extra re-register trigger for a flag living outside
  `ShortcutSettings`. The menu-bar glyphs derive from the same object via
  `KeyCombo.swiftUIKeyEquivalent`, so menu, settings and live hotkey can never drift — note that
  helper takes the first character of the key's description and so yields a garbage glyph for
  arrow keys; special-case it before putting any arrow-bound action in the menu bar.
- **Menu bar:** one `MenuBarExtra` (`App/App/AppMain.swift`) with a *Clipboard & Snippets*, a
  *Capture* and a *Keep Awake* submenu; only Settings and Quit sit at the top level. Its icon is
  the one piece of shared state — it swaps to `MenuBarIconAwake` while Keep Awake is on, which is
  why `AppMain` observes `KeepAwakeService`.
- **Settings:** one `TabView` (`Features/Settings/SettingsWindow.swift`) — `ClipboardPane`,
  `CapturePane`, `KeepAwakePane`, `WindowTilingPane`, `HotkeysPane`, `PermissionsPane`,
  `AboutPane`. The first four are per-feature-set; the last three are shared. Add a
  feature-specific setting to its own pane, not to the shared ones. (`WindowTilingPane` keeps its
  four shortcut recorders next to its on/off switch rather than in `HotkeysPane`, since the switch
  is what decides whether they exist.)

### Clipboard & snippets

**The popup flow (the load-bearing one):**
1. `HotKeyManager` fires → `PopupWindowController.toggle()` — the hotkey **toggles**, so a second
   press closes the popup. The menu's "Show Clipboard & Snippets" routes through
   `AppDelegate.showPopup()` (always shows).
2. `PopupWindowController.show()` first calls `ActiveAppTracker.shared.captureFrontmost()` —
   **this must happen before `NSApp.activate(...)`** or we lose the target app. It sets
   `viewModel.onRequestClose` once at panel creation, and calls `viewModel.reset()` on every show
   so each open starts at the top level with an empty query. The panel is sized **as a percentage
   of the primary screen's `visibleFrame`** (`ClipboardSettings.popupSizePercent`, 0.3–0.9,
   default 0.6) via `popupSize(for:)`, fitting the reference aspect ratio (`baseSize` 820×480)
   into that percentage; the size is re-applied on every show. `PopupRootView` derives the
   results-list width from `PopupWindowController.listWidthFraction` so the split stays
   proportional at any size.
3. `PopupPanel` (a borderless `NSPanel` with `.nonactivatingPanel` + `.floating`) hosts a SwiftUI
   tree via `NSHostingView`. `PopupViewModel` is the only environment object.
4. The popup is a **single unified list** (no sidebar tabs): `Collections`/`Snippets` section
   first, then `Clipboard History`, each with a header; rows are dense. Search filters snippets by
   **name + keyword only** (`SnippetCache.filterByName`, never content); clip items by
   preview/content/source app. Live filtering depends on `PopupSearchField.controlTextDidChange`
   (an `NSTextField`'s target/action alone does NOT fire per keystroke — don't remove it). Enter on
   a `.collection` drills in; Enter on a `.snippet`/`.clip` pastes and closes; **Esc always closes**
   (drill-out is via the `‹ All` breadcrumb or left-arrow at caret start). Keyboard intent lives on
   the view model (`submit`/`activate`/`cancel`/`drillOutIfEmpty`/`drillInIfCollection`) — views
   call those, no logic in `body`. **Region backgrounds** route through `PopupPalette`, which reads
   `ClipboardSettings` popup appearance keys; a user-configurable colored bezel is a
   `RoundedRectangle strokeBorder` in `PopupRootView`. Colors persist as `#RRGGBBAA` hex via
   `Color+Hex.swift`. Default: white background, 7 pt orange bezel, both on. Changes take effect
   the next open.
5. `Paster.paste(_:)` (`@MainActor`) writes to `NSPasteboard.general`, optionally bumps
   `lastUsedAt` (`moveToTopOnUse`), then `ActiveAppTracker.shared.reactivate()` + a CGEvent ⌘V to
   `cghidEventTap` after ~80 ms. Without AX trust we silently degrade to copy-only.

**Caches (the snappy path).** `SnippetCache.shared` keeps all collections + snippets in memory;
`ClipboardCache.shared` keeps the most recent ~500 items. The popup reads exclusively from caches
(zero DB hits per ⌘E after launch). Writes go through the repositories **and** update the cache:
viewmodel write methods call `SnippetCache.shared.loadAll()` after committing;
`ClipboardMonitor` calls `ClipboardCache.shared.insertNew(_:)` after each insert (a re-copy bumps
`lastUsedAt` instead — see `persist`). `ClipThumbnailCache` serves image rows/preview so list
rendering never decodes a full PNG. For text items the cache strips `textContent` above **3 KB**
(`textInlineThreshold`); the preview pane and `Paster` lazily fetch the full text via
`ClipboardCache.fullText(for:)`.

**Clipboard settings & services.** `ClipboardSettings.shared` is the single source of truth for
clipboard prefs. It is a `@MainActor ObservableObject` backed by computed properties over
`UserDefaults` that fire `objectWillChange` on write — **do not** switch these to `@AppStorage`;
`@AppStorage` inside an observable object does not publish changes. (`CaptureSettings` uses
`@Published` + `didSet` instead; both patterns are fine, don't unify them for its own sake.)
- `ClipboardMonitor` reads settings each tick: skips ignored apps, gates each kind on its `keep*`
  toggle, captures file lists (`.fileURL` → `ClipKind.file`).
- `ClipboardRetentionService` sweeps hourly (and on settings change) via
  `ClipboardRepository.purgeOlderThan(kind:cutoff:)`. **Sidecar files** (image PNGs, RTFs) are
  removed by the repository itself on every deletion path — keep it that way; deleting rows
  without their files leaks disk.
- `FastAppendService` installs a global ⌘C monitor; a double-tap within 0.5 s appends the copied
  text onto the previous text item, optionally writing the merged result back to the pasteboard
  (calling `ClipboardMonitor.suppressNextChange()` so we don't re-capture our own write).

**Storage.** GRDB `DatabaseQueue` at `~/Library/Application Support/Mukker/mukker.sqlite`
(both parts come from `Branding` — see *Naming* above).
Schema is owned by `AppDatabase.migrator`; add schema via a new `registerMigration("vN")` block,
never edit an existing one (currently `v1`, `v2_lastUsed`, `v3_richText`). Models (`ClipItem`,
`Snippet`, `SnippetCollection`) conform to `FetchableRecord, MutablePersistableRecord` with
explicit `Columns` enums — use those for type-safe queries, not raw SQL. The Swift type is
`SnippetCollection` (not `Collection`) to avoid a stdlib clash. Repositories are the only callers
of `dbQueue`. Clip history is ordered by `pinned DESC, COALESCE(lastUsedAt, createdAt) DESC`.
Image items are PNG files under `AppPaths.imagesDirectory`, named by SHA-256 of the PNG bytes (the
same hash used in `content_hash` for dedupe); `ClipboardMonitor` re-encodes pasteboard TIFF/PNG to
a canonical PNG before hashing so identical images dedupe regardless of source format.

**Import/export.** `.alfredsnippets` is a **read-only** import format (`SnippetBundleImporter`).
The fixture `AppTests/Fixtures/test.alfredsnippets` (also at the repo root) is the canonical test
asset and round-trip target. Native export uses our own JSON versioned via the `format` string
(`Branding.snippetExportFormat`). `SnippetRepository.importCollection` is **idempotent by
(collection name, snippet uid)** — re-importing the same file must not create duplicates.

### Capture & annotation

**Capture flow:** hotkey/menu → `CaptureCoordinator` → `PermissionsService.ensureScreenRecording()`
→ `ScreenCaptureService` grabs the display as a frozen `CGImage` → `SelectionOverlayWindow` lets
the user drag a region → crop the frozen image → routed by `CaptureSettings.afterCapture`
(show/copy/save) in `AppDelegate.handleCapture`.

**Editor model:** annotations are value types in an ordered array on `EditorViewModel`; the canvas
(`FlatCanvas`) is a `ZStack` of a white matte + the base image + an `AnnotationLayer` (a single
SwiftUI `Canvas` that draws every annotation) + the interactive `ToolGestureHandler` overlay.
Export flattens `FlatCanvas` to a `CGImage` via SwiftUI `ImageRenderer`. `copyToClipboard()`/
`save()` fire `EditorViewModel.requestClose` when the matching `closeAfterCopy`/`closeAfterSave`
toggle is on.

- **Base image is a movable layer** (`imageOrigin`, in canvas points): the pointer tool drags it,
  crop/blur/flatten honor it. The `.hand` tool pans the *view* only (`EditorView.viewPan`, never
  exported). Mouse-wheel zoom is a window-scoped `WheelZoomCatcher`.
- **Two bounds:** `contentBounds` (includes the live `draft`) drives drawing; `layoutBounds`
  (committed only) drives matte/gesture/scroll geometry so starting a draw outside the image
  doesn't shift the canvas mid-gesture. Both extend a draw-outside canvas back to the capture's
  **original aspect ratio** (`canvasBounds` → `expand(toRatio:)`).
- **Editor vs export look:** on screen the non-exported surround is a transparency `Checkerboard`;
  `FlatCanvas`'s white matte makes the same region export white.
- **Blur** obscures the composite beneath it via a `GraphicsContext` blur filter in
  `AnnotationLayer.drawBlur(_:below:)` — it does not erase what's under it. There is no
  pre-rendered pixelated layer: the old `ImageEffects.pixellate` → `pixelatedBase` →
  `AnnotationCanvas.pixelatedImage` chain was dead (the canvas stored the image and never drew
  it) and has been removed.
- **Inline text** uses an AppKit-backed `InlineTextField` (in `ToolGestureHandler`) that makes
  itself first responder on appear — SwiftUI `@FocusState` is unreliable in our custom window.

**Extensibility seams:** `AnnotationKind` and `Tool` are the single extension points — a new tool
is a `Tool`/`AnnotationKind` case + a draw arm in `AnnotationLayer.draw` + (if its geometry
differs) an arm in `EditorViewModel.updateDraft`. Non-drawing tools (`select`, `crop`, `hand`)
have a nil `annotationKind`. Tool keys resolve through `EditorShortcuts` against
`CaptureSettings.toolShortcuts`.

On the popup side, `PopupResult` is the single row type the list renders — adding a kind (e.g.
`.screenshot`, to browse captures in the popup) is one case + a switch arm in `PopupRow`,
`PreviewPane` and `PopupViewModel.confirmSelection`. `ClipKind`'s string column accepts new values
without migration, but exhaustive switches in `Paster`, `PreviewPane`, `PopupRow` and
`ClipboardSettings.retention(for:)`/`isKindEnabled(_:)` must each gain an arm.

### Keep awake

`KeepAwakeService` (`Core/`) is the only thing in the app that talks to IOKit power management;
`KeepAwakeSettings` holds the preferences and the `KeepAwakeDuration` enum (raw value = minutes,
`0` = indefinite). Two details are load-bearing and easy to "simplify" wrongly:

- The assertion is created with a **30 s timeout and re-created every 10 s**, not once for the
  whole duration. A long-lived assertion survives a crash or `kill -9` and pins the Mac awake with
  nothing left to release it; a self-expiring one drains within the timeout. The refresh interval
  must stay *below* the timeout so consecutive assertions overlap. The refresh timer runs on
  `.common` so it keeps firing while a menu is open.
- The countdown is an **absolute `Date` deadline**, not a decrementing counter — run-loop timers
  don't advance while the Mac is asleep, so `NSWorkspace.didWakeNotification` settles up against
  the wall clock. `willSleep` (honouring `deactivateOnManualSleep`) and the session-resign/become
  pair (fast user switching drops the assertion) are handled alongside it.

`isActive` is the service's only stored `@Published` property; `remaining` is derived from the
deadline on read. `AppMain` observes the service for both the icon and the menu's status line, so a
value that changed every second would rebuild the whole `MenuBarExtra` body (and can close an open
menu). Instead the object republishes **once a minute** while counting down, and
`format(remaining:)` hides seconds above a minute — the two granularities are matched on purpose,
so the menu is never visibly stale. Anything wanting a per-second countdown polls `remaining`
itself, as `KeepAwakePane` does. `KeepAwakeDuration` carries a
`#if DEBUG` **1-minute** case so the expiry path can be exercised without a five-minute wait.

Assertion type follows `allowDisplaySleep`: `kIOPMAssertPreventUserIdleDisplaySleep` normally,
`kIOPMAssertPreventUserIdleSystemSleep` when the user lets the screen go dark. The service
subscribes to that setting so flipping it re-asserts immediately instead of at the next refresh.
Verify a change with `pmset -g assertions` — and check again 30 s later, or you have only proven
the *first* assertion was created.

### Window tiling

`WindowTiler` (`Core/`) is the only thing in the app that talks to `AXUIElement`;
`WindowTilingSettings` holds the on/off switch and the `gap`. Four details are load-bearing:

- **AX and Cocoa disagree about which way is up.** AX window geometry is top-left-origin with Y
  growing *down*, anchored at the top-left of the primary display; `NSScreen.frame`/`visibleFrame`
  is bottom-left-origin with Y growing up. Everything crossing that boundary goes through
  `axRect(fromCocoa:primaryHeight:)` / `cocoaRect(fromAX:primaryHeight:)`, and `primaryHeight` must
  come from `NSScreen.screens.first` — the physical menu-bar display. `NSScreen.main` follows
  keyboard focus and silently gives the wrong answer the moment a second display is attached.
- **Position and size are written twice**, in the order position → size → position → size. Many
  apps clamp a requested size against the window's *current* screen and position, so a single pass
  lands short whenever the move crosses displays or grows the window.
- **`AXUIElementSetMessagingTimeout(app, 0.5)`.** AX calls into a hung app block for six seconds by
  default, which would freeze the main thread — and the menu bar — on every press. Nothing on the
  tile path sleeps, animates or waits for an app to activate: the move is meant to be instant.
- **The default Top/Bottom shortcuts are deliberately inverted** — top is ⌃⌘↓ and bottom is ⌃⌘↑,
  matching what the user asked for. Both the constants and the tests say so; don't "fix" them.

`tile(_:)` finds its target through the **system-wide** AX element
(`AXUIElementCreateSystemWide()` → `kAXFocusedApplicationAttribute` → `kAXFocusedWindow`), not
`NSWorkspace.shared.frontmostApplication` — the workspace answer is not trustworthy from an
`LSUIElement` accessory process and was observed reporting `com.apple.loginwindow` while a normal
app plainly had focus. The workspace is kept only as a fallback. Everything else that can go wrong — no focused window, a natively
full-screen window, a fixed-size panel that refuses the new size — is a `Log.window` line, not an
alert. The pure geometry is `nonisolated static` so `AppTests/WindowTilerTests.swift` can cover it
without a real window or a permission grant; the AX half is verified by hand.

## Conventions

- **Concurrency:** `SWIFT_STRICT_CONCURRENCY: minimal`. UI/coordinator classes are `@MainActor`;
  background polling lives in `ClipboardMonitor` (RunLoop timer on `.common`).
- **No Dock icon.** `Info.plist` sets `LSUIElement=true`; activation policy is `.accessory`.
  Tests, screenshots and `osascript` are the only ways to interact when running headless.
- **Windows are app-owned `NSWindow`/`NSPanel`s** hosting SwiftUI via `NSHostingView`. Snippets
  Manager and Settings are created in `AppDelegate` (`openSnippetsManager()` / `openSettings()`),
  not SwiftUI `WindowGroup`/`Settings` scenes — there is intentionally no `Settings { }` scene.
- **AppKit ↔ SwiftUI bridges** live next to the views that need them (`PopupSearchField`,
  `KeyEventCatcher`, `ShortcutRecorderField`, `InlineTextField`). Follow these patterns rather than
  fighting SwiftUI.
- **Logging:** use `Log.<category>` from `Support/Logger.swift` (categories: `app`, `hotkey`,
  `keepAwake`, `window`, `clipboard`, `snippets`, `db`, `paste`, `capture`, `editor`, `export`). View with
  `log show --predicate 'subsystem == "com.mukker.Mukker"' --info --last 1m` (the subsystem is the
  bundle ID).
- **Code signing:** ad-hoc only (`CODE_SIGN_IDENTITY: "-"`); hardened runtime auto-disabled. Don't
  add entitlements requiring a real Developer ID without coordinating with the user.
- **Always work on a feature branch.** Never commit directly to `main`. Create **one** branch off
  `main` and keep using it for a working session — don't spin up a branch per request.
- **Commit regularly.** After every confirmed-working feature, make a focused commit.
- **Releases are automated — never build/upload the DMG yourself.**
  `.github/workflows/release.yml` triggers on a pushed `v*` tag, runs `make dmg`, and publishes the
  GitHub release with the DMG + SHA-256. To cut a release: bump `CFBundleShortVersionString`/
  `CFBundleVersion` in `project.yml`, update `CHANGELOG.md`, commit, then
  `git tag vX.Y.Z && git push origin vX.Y.Z`. **This repo doubles as its own Homebrew tap**:
  `Casks/mukker.rb` is the live cask (it strips the quarantine flag on install because the build is
  ad-hoc signed), and the release workflow rewrites its `version`/`sha256` and pushes that back to
  `main` — so never hand-edit those two lines. Because the repo is not named `homebrew-*`, users
  tap it with the two-argument form:
  `brew tap miklos-szel/mukker https://github.com/miklos-szel/mukker`.
- Do **not** reference the inspiration apps by name anywhere in the code or UI.
