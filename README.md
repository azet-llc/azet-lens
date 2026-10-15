<p align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="">
</p>

<h1 align="center">Mwoyeo</h1>
<p align="center"><b>Read any screen in your language, right where the text is.</b><br>
Put a lens over a chat, a feed or a game. The original text disappears and the translation is written in its place.</p>

<p align="center">
  <code>brew install midagedev/tap/mwoyeo</code><br>
  <sub>macOS 27 · Apple silicon · everything on-device · <a href="https://github.com/midagedev/mwoyeo/releases/latest">v1.0.0</a></sub>
</p>

<p align="center"><img src="docs/media/hero.gif" width="640" alt="A lens over a Japanese chat: new messages are rewritten in Korean in place; the lens is dragged and resized, the chat scrolls under it, and ⌃⌥O flips back to the original."></p>

Mwoyeo reads the text under a lens, **erases it from the picture**, and paints the translation back in the same
place, size and colour. It is not a popup or a subtitle bar: the screen simply reads in your language, and keeps
reading as messages arrive and the page scrolls. Everything runs on your Mac; nothing is sent anywhere.

## Install

```bash
brew install midagedev/tap/mwoyeo
```

Or download the disk image from [Releases](https://github.com/midagedev/mwoyeo/releases/latest) and drag Mwoyeo to
Applications. The app is signed and notarized.

You need macOS 27 on an Apple silicon Mac.

## Getting started

1. **Open Mwoyeo.** It lives in the menu bar (the viewfinder icon); a welcome window walks you through the rest.
2. **Allow Screen Recording.** Click **Allow** and turn Mwoyeo on in System Settings › Privacy & Security › Screen &
   System Audio Recording. If the lens stays empty afterwards, quit and reopen Mwoyeo.
3. **Pick your languages.** *Translate from* can stay on **Automatic**; *Translate to* starts as your Mac's language.
4. **Get the language pack** (recommended). In Mwoyeo's Settings › Translation, click **Download** next to your
   language pair. With a pack, translation is near-instant and works offline. Without one, Apple Intelligence
   translates instead, which needs no download but takes about half a second per line.
5. **Press ⌃⌥T and drag a box** over the text you want to read, such as the message list of a Discord channel or a
   Reddit thread. Or just click, and a lens is dropped where you clicked. Hold ⌥ while you do it to pin the lens to
   the screen instead of the window (see below).

## Using a lens

- **Move it** by dragging its glowing edge or the name tag on top. Translations stay on the text underneath; only
  what is inside the lens is shown.
- **Resize it** from the bottom-right corner.
- **Close it** with the ✕ on the name tag (hover over the lens to see it).
- **Scroll and chat as usual.** The interior of a lens is click-through, so the page under it works normally. New
  messages are translated as they arrive and scrolling carries the translations along.
- **Window lens or screen lens.** A lens placed on a window is a *window lens* (🪟 on its name tag): it moves with
  that window and hides while the window is minimized or covered. A *screen lens* (📌) stays where you put it and
  translates whatever is under it, whichever app that is: handy for a subtitle line or a spot you keep switching
  apps under. Click the icon on the name tag to switch.
- **Keep lenses small.** A lens around just the part you read (the chat, not the whole browser) translates faster
  and uses less power. You can have several.

The menu bar icon lists your lenses: switch each one on or off, remove it, or add a new one. It also has
**Show Original**, **Pause** and Settings.

### Shortcuts

These work in any app (Settings › Shortcuts lists them too).

| | |
|---|---|
| ⌃⌥T | Add a lens (drag an area, or click to drop one; hold ⌥ to pin it to the screen) |
| ⌃⌥O | Show the original / the translation |
| ⌃⌥P | Pause all lenses |
| ⌃⌥R | Translate again |

## Settings

| Tab | What you can change |
|---|---|
| General | Languages · **Display**: *Adaptive* (default: plain boxes while things move, a seamless rewrite once still), *Quick* (always boxes, least battery) or *Seamless* (always rewrites) · how often the screen is checked (4, 8 or 15 fps) · open at login |
| Translation | **Engine**: *Automatic* (language pack if installed, Apple Intelligence otherwise), *High fidelity* (always Apple Intelligence) or *Glossary first* · language packs · **translation memory**: how many translations to keep for reuse (1,000, 5,000 or 20,000; in memory only, cleared when Mwoyeo quits) · a **glossary** of names, one `original = translation` per line |
| Appearance | **Lens style**: *Glow*, *Subtle* (glows only while reading) or *Minimal* (a faint line; the name tag shows on hover) · font (default, rounded, serif) · box opacity · AI erasing on photos and artwork |

## Tips and troubleshooting

- **Stuck on "Translating…"?** Usually the language pack is missing; download it in Settings › Translation. The very
  first lens after installing also takes a while, because macOS loads its text recognition models once.
- **Names come out wrong** (characters, places, usernames)? Add them to the glossary and choose *Glossary first*.
- **Nothing shows up after an update?** macOS sometimes asks for Screen Recording again. Check it in System Settings,
  then reopen Mwoyeo.
- **Want to compare with the original?** Press ⌃⌥O to see the original, and again to go back.
- **Privacy.** Mwoyeo reads only what is under a lens, never stores or sends it, and leaves its own overlays out of
  what it captures.

## Under the hood

Every stage uses Apple's on-device frameworks:

| Stage | Technology |
|---|---|
| Capture | ScreenCaptureKit — one stream per lens, Mwoyeo's own overlays excluded, frames only when pixels change |
| Text recognition | Vision `RecognizeDocumentsRequest` (paragraphs) and `RecognizeTextRequest` (lines, regions of interest) |
| Translation | Translation framework — low-latency language packs, or the high-fidelity Apple Intelligence model without a pack |
| Glossary-aware translation | Foundation Models (on-device language model), optional |
| Erasing | Core ML MI-GAN inpainting on the GPU for textured backgrounds, a fast diffusion fill for flat ones |
| Interface | SwiftUI with Liquid Glass, a menu bar extra, global shortcuts, in 12 languages |

### How it works

```
ScreenCaptureKit ──► change map (16 px tiles) ──► scroll? shift blocks, read only the new strip
      │                       │
      │                       └─► changed rows ──► Vision (ROI) ──► erase ──► translate (lens first) ──► overlay
      │
      └─► still for 0.5 s ──► whole-frame paragraph pass ──► seamless re-render, cross-faded in
```

The capture is larger than the lens ("overscan"). At rest the margin is about 30 % of the lens on each side; while
content or the lens moves it grows to about 40 %, shifted toward where things are heading. The lens moves freely
inside the captured area and the capture only re-centres when the lens nears its edge — then just the uncovered strips are read. Unchanged text keeps its
erased background across passes, results computed while content moved are shifted rather than thrown away, and the
translation queue always serves what is visible first.

Scrolling is tracked twice. Trackpad and wheel input move the translations with the page before the next frame
arrives; each captured frame then settles them to the exact offset, measured per column to a fraction of a pixel, so
a fixed sidebar or message box never drags the chat along with it. Only the strip that scrolled into view is read.

Erasing fills flat and gradient backgrounds from their surroundings; on textured ones (artwork, game scenes) an
on-device inpainting model rebuilds the background, and the translation is set in a matching weight and size.

The clip above is the real app on a made-up chat page (`demo/chat.html?lang=ja`), recorded with a real mouse and
trackpad scrolls; `docs/HERO.md` has the shot list.

The name is Korean: *mwoyeo* (뭐여) is a dialect way of saying "what's that?"

## Development

### Building

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Mwoyeo.xcodeproj -scheme Mwoyeo -configuration Release -derivedDataPath build/dd build
```

Builds are ad-hoc signed by default, which makes macOS ask for Screen Recording again after every rebuild. Put a
stable identity in `Config/Local.xcconfig` (git-ignored):

```
MWOYEO_SIGN_IDENTITY = <SHA-1 from `security find-identity -v -p codesigning`>
MWOYEO_TEAM = <team id>
```

Core logic (change detection, scroll detection, erasing masks, text fitting, overscan planning) lives in the
`MwoyeoCore` package with its own tests: `cd Core && swift test`.

#### Headless checks

The app binary doubles as a test harness that runs the real pipeline on images:

```bash
APP=build/dd/Build/Products/Release/Mwoyeo.app/Contents/MacOS/Mwoyeo
$APP --render in.png out.png --src ja --tgt ko                     # one still: read, erase, translate, composite
$APP --render page.png frames/ --pan --src ja --tgt ko \
     --lens 200,560,600,300 --to 200,860                            # simulated lens drag, one PNG per step
$APP --render page.png frames/ --pan --scroll --src ja --tgt ko \
     --lens 200,300,600,300 --to 0,400                              # simulated scroll under a still lens
```

`MWOYEO_TRACE=1` prints stage timings; in the live app `MWOYEO_DUMP=<dir>` writes what each lens captured with its
overlay on top.

#### Releasing

Pushing a `v*` tag runs `.github/workflows/release.yml`: it builds with the Developer ID identity from the repository
secrets, notarizes and staples the disk image, publishes the GitHub release and updates the Homebrew cask. Running the
workflow by hand builds and notarizes without releasing. `scripts/release.sh <version> [--publish]` does the same on
a Mac that holds the identity.

#### Demo pages

`demo/chat.html` (a Discord-like server) and `demo/forum.html` (a Reddit-like thread) are made-up pages for
recordings; their parameters (language, new-message rate, scripted scrolls) are listed at the top of each file.
`docs/HERO.md` has the shot list.

## Credits

Inpainting model: [MI-GAN](https://github.com/Picsart-AI-Research/MI-GAN) by Picsart AI Research, MIT licensed
(`tools/inpaint/models/LICENSE-MI-GAN-WEIGHTS`). The Core ML version in `tools/inpaint/models` was converted with
`tools/inpaint/convert_migan.sh`.

## License

MIT
