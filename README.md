<p align="center">
  <img src="scripts/icon-preview.png" width="128" alt="Klick icon">
</p>

<h1 align="center">Klick</h1>

<p align="center">A GTA‑style radial wheel for your files on macOS.<br>
Select a file in Finder, hold <kbd>⇧ Shift</kbd>, point, release.</p>

---

Klick is a native macOS menu-bar app (Swift, SwiftUI + AppKit, Liquid Glass) that turns
Shift into a weapon wheel for whatever you have selected in Finder: convert, compress,
crop, add a background, redact, annotate, read metadata and more — without opening an app.

## How it works

1. Click a file (or several, or a folder) in Finder.
2. Hold **Shift** for a moment — the wheel appears under the cursor.
3. Move toward an action. Release Shift (or click) to run it; release over the center to cancel.

Each trigger key opens its own wheel:

| Key | Wheel |
| --- | --- |
| <kbd>⇧ Shift</kbd> | **Convert** — every format the selection can become |
| <kbd>⌘ Command</kbd> | **Tools** — compress, crop, trim, redact, … |
| <kbd>⌃ Control</kbd> | **File** — AirDrop, Float, Copy, Move, Copy Path, Terminal, ZIP |

**Drag mode:** start dragging files from anywhere, tap a trigger key, and drop the files on an
action. It works even without Finder access.

While the wheel is open:

| Input | Action |
| --- | --- |
| Point + release trigger / click | Run the highlighted action |
| <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>⌃</kbd> | Switch wheel |
| <kbd>Tab</kbd>, scroll, right‑click, <kbd>←</kbd> <kbd>→</kbd> | Next / previous wheel |
| <kbd>1</kbd>…<kbd>8</kbd> | Pick an action directly |
| <kbd>Esc</kbd> | Close |

Typing with Shift (e.g. <kbd>⇧A</kbd>), Shift‑clicking or moving the mouse a lot while holding
Shift cancels the gesture, so normal Shift usage is unaffected. The trigger key, hold delay,
sounds and haptics are configurable in **Settings → Shortcut**. Command and Control need a
slightly longer hold, so quick shortcuts like <kbd>⌘C</kbd> never open a wheel.

## Actions

| Selection | Convert (⇧) | Tools (⌘) |
| --- | --- | --- |
| Image (JPG, PNG, WEBP, HEIC, TIFF, AVIF, BMP, SVG) | JPG/PNG · WEBP · HEIC · TIFF · AVIF · BMP · PDF · DOCX (OCR) | Compress · Metadata · Edit · Annotate · Add BG · Crop · Redact — several: Compress · Metadata · Crop · Create PDF · Collage |
| PDF | DOCX · PPTX · XLSX · JPG · PNG · EPUB · TXT · MD | Compress · Metadata · Split · Organize · Rotate — several: Merge PDF |
| Video (MP4, MOV, M4V) | MP4 · MOV · GIF · M4A · MP3 | Compress · Metadata · Mute · Trim · Crop · Speed · Snapshot · Split · Redact — several: Join |
| Audio (MP3, M4A, WAV, FLAC, OGG, OPUS, AIFF) | MP3 · M4A · WAV · FLAC · OGG · OPUS · AIFF | Compress · Metadata · Normalize · Visualize · Trim · Channels · Bleep |
| Document (DOCX, Pages, MD, RTF, RTFD, TXT, HTML, ODT, text clipping) | PDF · DOCX · TXT · MD · HTML · EPUB · PNG · JPG · RTF · ODT | — |
| Presentation (PPTX, PPT, Keynote) | PDF · JPG · PNG | — |
| E-book (EPUB) | PDF · DOCX · TXT · MD · HTML | — |
| Spreadsheet (XLSX, XLS, ODS, CSV, TSV) | XLSX · ODS · CSV · TSV · PDF | — |
| Subtitles (SRT, VTT) | SRT · VTT · TXT | — |
| Archive (ZIP, TAR, GZIP, RAR, 7Z) | ZIP · TAR · GZIP | Extract |

The **File** wheel (⌃) works with anything — files, folders, mixed selections: AirDrop · Float
(a floating shelf you can pin to a screen edge and drag files out of) · Copy · Move · Copy Path ·
Terminal · ZIP · Duplicate (DMG for a folder).

Everything runs locally with macOS frameworks; nothing is uploaded.
Every action is non‑destructive: results are written next to the original
(`Page 001.pdf` → `Page 001.jpg`, `Page 001 Cropped.jpg`, …).

## Feedback

Hovering a segment plays a very short, low (≈200 Hz) synthesized tick that mimics a
Taptic Engine pulse, and fires a real haptic on Force Touch trackpads. Both can be turned off.

## Permissions

* **Finder automation** — Klick asks Finder for the current selection via Apple Events.
  macOS shows a one-time prompt; you can review it in *System Settings → Privacy & Security → Automation*.
* No Accessibility or Input Monitoring permission is needed: the trigger is detected from
  the system's modifier state.

## Building

Requirements: macOS 26+, Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open Klick.xcodeproj        # or:
xcodebuild -project Klick.xcodeproj -scheme Klick -configuration Release build
```

The project is generated from `project.yml`. WebP encoding uses a vendored copy of
[libwebp](https://chromium.googlesource.com/webm/libwebp) (`Vendor/libwebp`, BSD‑3‑Clause),
because ImageIO can read WebP but not write it. MP3 encoding uses
[LAME](https://lame.sourceforge.io) (`Vendor/lame`, LGPL‑2.0), built as a dynamically linked framework.

### Project layout

```
Klick/
  App/         entry point, menu bar item, app info
  Core/        trigger detection, Finder bridge, settings, file model, output naming
  Wheel/       radial menu (geometry, SwiftUI view, panel controller)
  Actions/     action catalog per file kind + runner
  Converters/  ImageIO / PDFKit / AVFoundation / AppKit conversions
  Editors/     editor cards: image (Crop, Add BG, Edit, Annotate, Redact, Collage…), video, audio, PDF
  Shelf/       Float shelf
  Toast/       progress toasts
  Feedback/    synthesized haptic sounds + trackpad haptics
  Settings/    About · Shortcut · Credits · License
  Debug/       developer hooks (see below)
scripts/       icon generator and dev tools
```

### Developer hooks (Debug builds)

```sh
Klick --list-actions file.pdf                 # pages/actions for a selection
Klick --run-action convert.jpg file.pdf       # run an action headlessly
```

`scripts/klickctl.swift` drives a running instance (open the wheel, hover, commit, open editors…)
through distributed notifications — handy for automated screenshots.

## Contributing

Pull requests are welcome! Add yourself to `AppInfo.contributors` so you show up in
**Settings → Credits**.

## License

[MIT](LICENSE) © 2026 Giovanni D'Andrea. Inspired by the weapon wheel of GTA V.
