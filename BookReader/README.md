# BookReader

Native macOS SwiftUI app that opens a local PDF, lists chapters from the PDF outline, previews chapter text, and synthesizes narration to **MP3** with Microsoft Neural **`en-US-AndrewNeural`** via [`edge-tts`](https://github.com/rany2/edge-tts).

Personal **Run/Debug** only for now (no notarizing). Lives beside the static Readings site; it does not change Pages content.

## Requirements

- macOS 14+
- Xcode 16+ (or current Xcode that can build macOS 14 SwiftUI apps)
- Python 3 with **`edge-tts`** on your `PATH`
- Network access when synthesizing (edge-tts talks to Microsoft’s online voices)

### Install edge-tts

Any one of:

```bash
pip install edge-tts
# or
pip3 install edge-tts
# or
pipx install edge-tts
```

Confirm:

```bash
which edge-tts
edge-tts --voice en-US-AndrewNeural --text "Hello." --write-media /tmp/bookreader-smoke.mp3
```

The app looks for `edge-tts` on `PATH`, then common locations such as `~/.local/bin/edge-tts`.

## Build & run

```bash
cd BookReader
open BookReader.xcodeproj
```

In Xcode: select the **BookReader** scheme → **My Mac** → Run (⌘R).

Or from the CLI:

```bash
cd BookReader
xcodebuild -scheme BookReader -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/BookReader.app
```

Signing is set to ad-hoc (`CODE_SIGN_IDENTITY = "-"`) for personal local runs. App Sandbox is **off** so the app can spawn `edge-tts`, reach the network, and open arbitrary PDFs.

## Happy path

1. **Open PDF…** (⌘O) or drag a PDF onto the window.
2. Confirm title + page count in the sidebar; chapters come from `PDFOutline` (or a single **Full book** chapter if there is no outline).
3. Select a chapter → text preview (first ~2,500 characters) + word/character counts.
4. **Synthesize MP3** → writes  
   `~/Movies/BookReader/<BookTitle>/<ChapterTitle>.mp3`  
   (falls back to `~/Library/Application Support/BookReader/Audio/` if Movies is unavailable).
5. **Play / Pause** the generated chapter in-app.

Voice is locked to **`en-US-AndrewNeural`**. Output format is **MP3**.

## Out of scope (this slice)

Library UI, podcast `feed.xml` export, OCR for scanned PDFs, cloud/paid TTS APIs, and any changes to the GitHub Pages site.

## Layout

```
BookReader/
  BookReader.xcodeproj/
  BookReader/
    BookReaderApp.swift
    ContentView.swift
    Models/
    Services/          # PDF load, outline chapters, edge-tts, AVAudioPlayer
    Views/
  README.md
```
