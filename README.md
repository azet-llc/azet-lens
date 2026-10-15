<p align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="">
</p>

<h1 align="center">Mwoyea</h1>
<p align="center"><b>뭐여? 이제 바로 읽혀요.</b><br>
Live, in-place screen translation for macOS — the original text disappears and the translation is written right where it was.</p>

<!-- Hero clip: docs/HERO.md describes the shot list. Drop the recording at docs/hero.mp4 and link it here. -->

## What it does

Put a lens over any part of the screen — a game, a manga reader, a video, a web page in a language you can't read.
Mwoyea reads the text, **erases it from the picture**, and paints the translation back in the same place, size and
colour. It is not a popup or a subtitle bar: the screen simply reads in your language.

- **Seamless, not boxed.** Flat backgrounds are filled from their surroundings; textured ones (gradients, artwork,
  game scenes) are rebuilt by an on-device inpainting model, then the translation is set in a matching weight and size.
- **A lens you can drag.** Grab its edge and slide it across the screen; translations stay glued to the content
  underneath, and new text is translated as it comes into view.
- **Reads ahead.** Mwoyea captures more than the lens shows and widens that margin while things move, so dragging
  the lens or scrolling reveals text that has already been read, erased and translated.
- **Follows scrolling and windows.** A vertical scroll moves the existing translations with the page instead of
  re-reading them; a lens placed on a window follows that window around.
- **Private by construction.** Capture, recognition, inpainting and translation all run on the Mac. Nothing leaves it.

## Built on Apple's on-device AI

| Stage | Technology |
|---|---|
| Capture | ScreenCaptureKit — one stream per lens, Mwoyea's own overlays excluded, frames only when pixels change |
| Text recognition | Vision `RecognizeDocumentsRequest` (paragraphs) and `RecognizeTextRequest` (lines, regions of interest) |
| Translation | Translation framework — low-latency language packs, or the high-fidelity Apple Intelligence model without a pack |
| Glossary-aware translation | Foundation Models (on-device language model), optional |
| Erasing | Core ML MI-GAN inpainting on the GPU for textured backgrounds, a fast diffusion fill for flat ones |
| Interface | SwiftUI with Liquid Glass, a menu bar extra, global shortcuts |

## How it works

```
ScreenCaptureKit ──► change map (16 px tiles) ──► scroll? shift blocks, read only the new strip
      │                       │
      │                       └─► changed rows ──► Vision (ROI) ──► erase ──► translate (lens first) ──► overlay
      │
      └─► still for 0.5 s ──► whole-frame paragraph pass ──► seamless re-render, cross-faded in
```

The capture is larger than the lens ("overscan"). At rest the margin is about 30 % of the lens on each side; while
content or the lens moves it grows to about 60 %. The lens moves freely inside the captured area and the capture
only re-centres when the lens nears its edge — then just the uncovered strips are read. Unchanged text keeps its
erased background across passes, results computed while content moved are shifted rather than thrown away, and the
translation queue always serves what is visible first.

## Requirements

- macOS 27 on Apple silicon
- Screen Recording permission (asked on first launch)
- For the fastest translation: the language pack for your pair (System Settings › General › Language & Region ›
  Translation Languages). Without it Mwoyea uses the high-fidelity Apple Intelligence model, which needs no download
  but takes about a second per sentence.

## Shortcuts

| | |
|---|---|
| ⌃⌥T | Add a lens (drag an area, or click a window to follow it) |
| ⌃⌥O | Show the original / the translation |
| ⌃⌥P | Pause all lenses |
| ⌃⌥R | Translate again |

## Building

```bash
brew install xcodegen
tools/inpaint/convert_migan.sh        # optional: MI-GAN → Core ML (needs uv); without it textured text gets a flat fill
xcodegen generate
xcodebuild -project Mwoyea.xcodeproj -scheme Mwoyea -configuration Release -derivedDataPath build/dd build
```

Builds are ad-hoc signed by default, which makes macOS ask for Screen Recording again after every rebuild. Put a
stable identity in `Config/Local.xcconfig` (git-ignored):

```
MWOYEA_SIGN_IDENTITY = <SHA-1 from `security find-identity -v -p codesigning`>
MWOYEA_TEAM = <team id>
```

Core logic (change detection, scroll detection, erasing masks, text fitting, overscan planning) lives in the
`MwoyeaCore` package with its own tests: `cd Core && swift test`.

### Headless checks

The app binary doubles as a test harness that runs the real pipeline on images:

```bash
APP=build/dd/Build/Products/Release/Mwoyea.app/Contents/MacOS/Mwoyea
$APP --render in.png out.png --src ja --tgt ko                     # one still: read, erase, translate, composite
$APP --render page.png frames/ --pan --src ja --tgt ko \
     --lens 200,560,600,300 --to 200,860                            # simulated lens drag, one PNG per step
$APP --render page.png frames/ --pan --scroll --src ja --tgt ko \
     --lens 200,300,600,300 --to 0,400                              # simulated scroll under a still lens
```

`MWOYEA_TRACE=1` prints stage timings; in the live app `MWOYEA_DUMP=<dir>` writes what each lens captured with its
overlay on top.

## Credits

Inpainting model: [MI-GAN](https://github.com/Picsart-AI-Research/MI-GAN) (Picsart AI Research), converted to
Core ML by `tools/inpaint`. The weights are not part of this repository.
