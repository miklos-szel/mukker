# CLAUDE.md

Guidance for working in this repository.

## What this is

The Windows port of the macOS app Mukker (the Swift app in `../App`, same repo). Four feature
sets only: clipboard history + snippets, capture + annotation, translate and dictation, plus the
hourly chime.
The calendar (Windows has its own), window tiling, the bandwidth monitor and keep-awake are
deliberately not ported.
**The Mac app is the behavioural spec**: its constants, prompts, CLI argument lists and the SQLite
schema are copied exactly, so check there first when in doubt.

## Layout

- `src/Mukker.Core/`
  - Targets `net8.0`, platform-neutral, and is unit-tested on the Mac.
  - Holds all logic that doesn't need Win32 or WPF:
    - settings model + JSON store
    - SQLite storage (`Database` migrations v1–v4 identical to the Mac's, plus the repositories)
    - capture policy, `HtmlSanitizer` (a regex-for-regex port), CF_HTML
    - fast-append planning, retention + forever archive
    - snippets JSON
    - translate prompt/arguments/CLI locator/runner/error mapping
    - chime schedule, export naming, scrolling-capture stitcher
    - dictation (`Dictation/`): the model catalog (copied verbatim from the Mac), language plan,
      press machine, `DictationTriggerTracker` (the key-chord state machine), text/level/SHA-256
      helpers and the download/delete plan; `Settings/DictationSettings.cs`
- `src/Mukker.App/`
  - Targets `net8.0-windows`, WPF + WinForms (WinForms only for `NotifyIcon` and the colour and
    folder dialogs).
  - `AppHost` owns every service; start there.
  - Folders: `Interop/` (P/Invoke, message window, hotkeys), `Tray/`, `Chime/`, `Clipboard/`,
    `Popup/`, `Snippets/`, `Translate/`, `Capture/`, `Editor/`, `Settings/`, `Dictation/`
    (`Engine/` is the transcribe.cpp P/Invoke layer and the only caller of the native library).
- `tests/Mukker.Core.Tests/` — xUnit, runs anywhere: `dotnet test tests/Mukker.Core.Tests`
  (use the `test-runner` subagent).

Keep the split: anything testable without Windows belongs in Core.

## Build / run

```bash
dotnet build                 # builds on macOS thanks to EnableWindowsTargeting
scripts/fetch-native.sh      # pinned transcribe.cpp x64 DLLs → native/win-x64 (publish.sh runs it)
scripts/publish.sh           # dist/win-arm64 + dist/win-x64 single-file Mukker.exe
scripts/vm.sh deploy         # push the arm64 build into the UTM VM "Windows" (RID=win-x64 for Dictation)
scripts/vm.sh run [popup|settings:<tab>|snippets|menu|menu-right|editor|translate-en|translate-hu|translate-de|dictation|dictation-notice|dictate-file:<wav>]
scripts/vm.sh shot out.png   # screenshot the VM desktop
scripts/vm.sh log
```

- **`MUKKER_OPEN`** opens a surface at launch, so it can be screenshotted without a human
  clicking.
- **`MUKKER_HOME`** redirects data and settings, for demo or test runs.
- **`MUKKER_CHIME_EVERY_MINUTE=1`** moves the chime to every minute.
- **`MUKKER_OPEN=dictate-file:C:\path\clip.wav`** transcribes a WAV with the selected model and
  writes the text to `dictate-file.txt` beside it — the engine without a microphone. It is the
  only place a transcript is ever written. `dictation` starts/stops a recording,
  `dictation-notice` shows the pill with a sample notice.
- **VM setup:**
  - Windows 11 arm64 VM named `Windows` in UTM (start it with `utmctl start Windows`).
  - UTM Guest Tools installed in it; this provides the qemu guest agent `utmctl` needs.
  - Local user `m` (override with `VM_USER`).
  - Dictation needs the x64 build: `RIDS=win-x64 scripts/publish.sh && RID=win-x64 scripts/vm.sh deploy`
    (it runs emulated, ~10 s for a short clip with Whisper Small). The VM has no microphone, only
    a silent line-in, so test transcription with `dictate-file:`; inject Ctrl+Win with
    `keybd_event` from `vm.sh ps` to test the trigger.
  - `utmctl exec` runs as SYSTEM in session 0, so GUI work goes through an interactive scheduled
    task (`scripts/vm.sh`).

## Load-bearing details

- **Hotkeys:**
  - `HotKeyManager` registers via `RegisterHotKey` on a message-only window and re-registers
    everything on any settings save.
  - A disabled feature's combos are not registered at all.
  - The shortcut recorder suspends all hotkeys while listening.
  - Defaults avoid Ctrl+Alt (AltGr).
- **Clipboard monitor:**
  - `AddClipboardFormatListener`, never polling.
  - It reads in one `OpenClipboard` session on the UI thread, then hashes, encodes and stores on
    a serial background queue so copy order is kept.
  - Our own writes are skipped by clipboard **sequence number** (`SuppressCurrent()` right after a
    write).
  - Snippet pastes and translations are deliberately *not* suppressed: they land in history like
    on the Mac.
- **Row first, then sidecar** (PNG/RTF/HTML files). The launch-time orphan sweep relies on every
  file having its row. Every deletion path in `ClipboardRepository` removes the row's files.
- **The image dedupe key** is the SHA-256 of the canonical PNG that WPF re-encodes. Don't change
  the encoder, or existing history stops deduping.
- **Paste:**
  1. Capture the foreground window *before* showing the popup.
  2. Write to the clipboard.
  3. `ForceForeground(target)`.
  4. After 80 ms, `SendInput` Ctrl+V, releasing held Shift/Alt/Win first.

  Our synthetic input is tagged with `Native.MukkerInputTag` so the fast-append hook ignores it.
- **Translate:**
  - The source is the UIA selection, else history. Never a simulated Ctrl+C: it would put the
    selection on the clipboard and trigger fast append.
  - **Chromium/Electron** (`Chrome_WidgetWin_*` windows) build their UIA tree only once a client
    asks. A first read that finds a focused element without a `TextPattern` in such a window returns
    `Waking`; the panel then shows "Reading the selection…" **without activating** (focus must stay
    in the app, since `FocusedElement` is what is read) and polls every 150 ms for up to 3 s, then
    falls back to history.
  - The source field is editable (`TranslationController.Draft`). With untranslated edits
    (`IsDraftEdited`) Esc only beeps and both hotkeys translate the draft; Ctrl+W/Close discard.
    Esc, Ctrl+W and Ctrl+Enter are taken in the window's `PreviewKeyDown`, before the TextBox.
  - The panel is resizable (`WindowChrome`, no caption; the header is the drag handle). Size (DIPs)
    and top-left (**physical pixels**, placed with `SetWindowPos`) are saved on `WM_EXITSIZEMOVE`
    only, not per mouse move — every settings save re-registers hotkeys. The border mirrors the
    popup bezel with its own `TranslationSettings` keys.
  - CLIs are launched with an argument list, never a shell string.
  - An npm `.cmd` shim is unwrapped to `node <script>`, so the multi-line `--system-prompt` never
    goes through cmd.exe.
  - The child runs in an empty temp directory with `CLAUDECODE`/`CLAUDE_CODE_*` scrubbed, and its
    process tree is killed on timeout (60 s) or cancel.
  - Never log the text.
- **Capture:**
  - The process is per-monitor-v2 DPI aware (`app.manifest`).
  - Everything capture-related works in physical pixels.
  - Overlay windows are placed with `SetWindowPos` in pixels, then show the frozen bitmap
    stretched.
  - Editor units are capture pixels.
  - Blur re-renders the composite *beneath* it (image + earlier annotations), downscaled, and
    draws it nearest-neighbour.
  - Crop flattens the inside of the rect into the new base image.
  - `ImageOutput.Save` never overwrites (`FileMode.CreateNew`; names are `scr_yyyy-MM-dd_HH-mm-ss` like the Mac app, + "_2", "_3"… on a collision).
- **Tray icon:**
  - The app icon (`Assets/mukker.ico`), drawn per size by `../scripts/make-icons.py` together
    with the Mac `AppIcon` — edit the design there, never the .ico. Reloaded at `SmallIconSize` on
    DPI/theme change so Windows uses a real frame, not a scaled one.
  - Left click shows the actions menu through NotifyIcon's own `ShowContextMenu` (reflection) — a
    plain `ContextMenuStrip.Show()` doesn't take foreground and then never closes on an outside
    click. Left click = actions (translate, popup, captures); right click = Snippets Manager, Clear
    History, Settings, Quit.
- **Dictation:**
  - The Mac's `### Dictation` section is the spec; catalog, defaults, the 0.3 s hold threshold and
    minimum, the 5-min cap and the language plan are copied exactly.
  - **The trigger is a `WH_KEYBOARD_LL` hook** (`DictationKeyHook`), not `RegisterHotKey`: a
    modifier-only chord (Ctrl+Win, the default, standing in for the Mac's fn) and key-up both need
    it. The hook only feeds `DictationTriggerTracker` (Core, tested) and posts to the dispatcher —
    it must return fast. Our own `MukkerInputTag` input is ignored; nothing is swallowed for the
    chord (Ctrl+Win+→ still switches desktops, and cancels the recording); a custom/language combo's
    main key is swallowed. Releasing Win after a chord injects a tagged VK 0xFF down/up first, or
    Windows opens the Start menu on the lone Win key-up.
  - A language combo pressed on top of the chord (e.g. Ctrl+Win+E) arrives as
    `[Interrupt(Base), Press(Language)]`: cancel, `Reset()` the press machine, then press.
  - **Engine:** transcribe.cpp 0.4.2, x64 only (no Windows arm64 build exists), so the arm64 exe
    shows a banner instead of the feature. The DLLs are bundled into the single-file exe as native
    binaries and extracted together; `transcribe_init_backends(<extraction dir>)` must be told
    where the `ggml-cpu-*`/`ggml-vulkan` modules are — it never searches the exe directory. Struct
    sizes are checked against `transcribe_abi_struct_size()` at load. One worker thread does all
    native work. AUTO backend, falling back to CPU on a backend error.
  - **Models are memory-mapped**, so a loaded model file can't be deleted on Windows: the store
    unloads the engine first and retries the delete.
  - Downloads land as `.partial`, are SHA-256-checked off the UI thread and only then renamed;
    stale `.partial`s are removed at launch.
  - Audio: NAudio `WasapiCapture`, downmixed/resampled to 16 kHz mono float in memory, never on
    disk. Windows' microphone privacy switch is read from the `CapabilityAccessManager` registry
    keys and surfaced in the Dictation tab (there is no Permissions tab).
  - The paste goes through `Paster.PasteText` and is **not** suppressed: the text stays on the
    clipboard and in history. Never log the transcript.
  - Sounds are `Assets/Sounds/*.wav`, generated by `../scripts/make-sounds.py` with the Mac's.
- **Frozen identifiers:** `AppPaths.SupportFolderName`/`DatabaseFileName` and
  `MukkerSnippetsJson.CurrentFormat` — renaming them orphans data or breaks import compatibility
  with the Mac app.

## Conventions

- Don't reference the inspiration apps by name anywhere in code or UI.
- Never add a Claude co-author trailer to commits.
