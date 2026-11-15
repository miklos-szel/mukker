# Mukker for Windows

A notification-area utility for Windows 10/11 combining four of the macOS Mukker app's feature
sets:

- a **calendar**
- **clipboard history + snippets**
- **screen capture with annotation**
- **translation** of the selected text or of what you just copied

Builds for Windows on ARM (arm64) and x64.

## Features

### Calendar

- **Today's date is the tray icon** — a calendar page with the day number knocked out of it,
  redrawn at midnight and on resume, and adapting to a light or dark taskbar.
- **Click it for the month calendar**:
  - page back and forth with ◀ ▶ (or PgUp/PgDn), and ● or Home jumps back to today
  - arrow keys move the selected day
  - today is filled with the accent colour; the selected day is ringed
  - optional week numbers and a choice of first weekday
  - display only: no personal calendars are read
- **Tooltip text** presets (weekday, month and day…) or a custom .NET date pattern.
- **Hourly chime** (off by default):
  - any sound from `C:\Windows\Media`
  - only between the hours you choose
  - a range that ends before it starts runs past midnight

### Clipboard & snippets

- **History of text** (including rich text: RTF, and HTML sanitised of anything that could load
  remote content), **images** and **file lists**, with a retention period per kind and a maximum
  item count. Pinned items are never removed.
- **Fast popup** (**Ctrl+Shift+Space**):
  - **Search:** one searchable list with snippet collections above the clipboard history.
  - **Paste:** Enter pastes into the app you were using.
  - **Plain text:** Ctrl+Shift+V pastes without formatting.
  - **Copy only:** Ctrl+C copies without pasting.
  - **Pin:** Ctrl+P pins an item.
  - **Collections:** → or Enter opens a collection, and ← or Backspace goes back.
  - **Close:** Esc or the shortcut again.
- **Snippets** in collections, edited in the Snippets Manager. You can also save a clip as a
  snippet with the star in the preview, or right-click a clip → Add to Collection. Import and
  export use Mukker's JSON format (`mukker.snippets.v1`), which is shared with the macOS app.
- **Fast append** (optional) — press Ctrl+C twice quickly to append the new copy to the previous
  text item.
- **Privacy:**
  - Ignores copies from listed apps (password managers preloaded).
  - Ignores copies that apps mark as excluded from clipboard history.
  - Ignores copies from password-manager browser extensions.
- **Forever history** (optional) archives text items as `.txt` files before they are deleted.
- Popup size as a share of the screen, plus a custom background and bezel colour.

### Capture & annotation

- **Area** (Ctrl+Shift+4):
  - selects on a frozen screenshot, across monitors and DPI scales
  - shows a live size badge
  - offers an optional magnifier with a colour readout
- **Fullscreen** (Ctrl+Shift+3) captures the monitor under the mouse.
- **Scrolling capture** (Ctrl+Shift+5) — select an area; Mukker scrolls it and stitches the frames.
  Press Esc to stop early.
- **Editor tools:**
  - **Shapes:** arrow, line, rectangle, rounded rectangle, ellipse.
  - **Freehand:** pen.
  - **Text:** inline.
  - **Counter:** numbered circles.
  - **Highlight.**
  - **Blur:** pixelates whatever is beneath it, annotations included.
  - **Crop.**
  - **Tool keys:** V, M, A, L, O, R, E, P, T, N, H, B, C. A held Shift constrains lines to 45° and
    shapes to squares and circles.
- **Editing:**
  - The select tool moves and reshapes annotations and also moves the image itself.
  - Double-click a text annotation to edit it.
  - Undo and redo keep 50 steps.
  - Mouse-wheel zoom, Ctrl+0 to fit, Ctrl+1 for actual pixels.
- **Output:** **copy** (Enter / Ctrl+C) or **save** (Ctrl+S) as PNG or JPEG. Saving goes silently
  to the folder of your choice and never overwrites a file. Optionally downscales to 100% scale.
- Copied captures land in the clipboard history.

### Translate

- **Ctrl+Shift+E** → English, **Ctrl+Shift+H** → Hungarian.
- **The source:** the text selected in the focused app, read through UI Automation and never
  copied. With nothing selected (or in an app that doesn't expose its selection), it uses the
  newest clipboard history item.
- **The translation service:** the **Codex CLI** (ChatGPT, the default) or the **Claude Code CLI**,
  signed in with your own subscription. Mukker stores no API key.
- **The result** shows in a floating panel and is copied to the clipboard. Its buttons:
  - **Copy**
  - **Translate to the other language**
  - **Close**

  Esc closes the panel, and so does the same shortcut again.
- **Setup:** install the CLI first and sign in once:
  - Codex: `npm install -g @openai/codex`, then `codex login`
  - Claude Code: `irm https://claude.ai/install.ps1 | iex` in PowerShell, then `claude` → `/login`

All shortcuts can be changed in **Settings → Hotkeys** and **Settings → Translate**. The defaults
avoid Ctrl+Alt, which is AltGr on many European keyboard layouts.

## Data

| What | Where |
| --- | --- |
| History database | `%LOCALAPPDATA%\Mukker\mukker.sqlite` (same schema as the macOS app) |
| Images / rich text | `%LOCALAPPDATA%\Mukker\images`, `…\richtext` |
| Settings | `%APPDATA%\Mukker\settings.json` |
| Log (never contains clipboard text) | `%LOCALAPPDATA%\Mukker\mukker.log` |

## Building

Requires the .NET 8 SDK. The app builds on macOS or Linux too (`EnableWindowsTargeting`).

```bash
dotnet build                      # everything
dotnet test tests/Mukker.Core.Tests
scripts/publish.sh                # dist/win-arm64/Mukker.exe and dist/win-x64/Mukker.exe
```

The result is a single self-contained `Mukker.exe` with no installer. Start it and it lives in the
notification area. Turn on **Settings → About → Start Mukker when you sign in** to launch it
automatically.
