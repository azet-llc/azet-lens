# Hero clips

One short loop per README language. Everything in them is the real app on a real screen; the page scrolls by
synthesized trackpad events, so a take can be repeated exactly.

| README | Chat (`demo/chat.html?lang=`) | Translated into | GIF |
|---|---|---|---|
| Korean | `ja` | Korean | `docs/media/hero.ko.gif` |
| English | `ko` | English | `docs/media/hero.en.gif` |
| Japanese | `ko` | Japanese | `docs/media/hero.ja.gif` |
| Simplified Chinese | `ko` | Simplified Chinese | `docs/media/hero.zh-CN.gif` |

## Shot list

680×720 pt around the lens (exported 600 px wide), about 17 s:

| Time | What happens | Caption |
|---|---|---|
| 0–4 s | A lens over the chat log; the visible messages are already translated. | Text under the lens, rewritten in place |
| 4.5 s, 8.5 s | Two trackpad swipes up through the history. Older messages scroll into view and are translated as they appear. | Scroll, and new lines are translated as they appear |
| 13.5 s | ⌃⌥O: the original, then the translation. | ⌃⌥O shows the original |

## Setting up

```bash
# The chat: content area 1000×1000 at (140, 96) — the --app title bar sits above it; no translate bubble
open -na "Google Chrome" --args --user-data-dir=/tmp/mwoyeo-demo --no-first-run \
  --disable-features=Translate,TranslateUI \
  --app="file://$PWD/demo/chat.html?lang=ko&every=5&history=16" \
  --window-position=140,68 --window-size=1000,1028

# Settings › Translate from must match the page, Translate to the README's language.
# A lens over the message log (global points, top-left origin). Launch the binary from a terminal that has
# Screen Recording permission, so a rebuilt ad-hoc app needs no new grant.
build/dd/Build/Products/Release/Mwoyeo.app/Contents/MacOS/Mwoyeo --add-region 480,206,620,640 &
```

`--add-region` stores the lens like any other; remove it from the menu afterwards.

## Before recording

1. **Warm up.** Wait about 18 s after launch: the first recognition loads models. Don't scroll yet; the history
   should be read for the first time on camera.
2. **Language pack** for the pair installed (System Settings › General › Language & Region › Translation Languages).
3. **Clean screen.** Nothing over the recorded rect (no dialogs or notifications); park the cursor outside it
   between moves.

## Recording and cutting

Screen recording captures Mwoyeo's overlays (only Mwoyeo's own capture leaves them out):

```bash
screencapture -v -V 20 -R 450,166,680,720 take.mov
# t = 6.5 s and 10.5 s: swipe up 330 pt over 1.1 s at the lens centre; t = 15.5 s and 17.3 s: ⌃⌥O
```

Captions are HTML pills (system font per language, 52 px on the 1360 px wide take) rendered to transparent PNGs
with headless Chrome, then laid over the bottom of the take:

```bash
ffmpeg -ss 2 -t 17.2 -i take.mov \
  -loop 1 -framerate 30 -t 17.2 -i cap0.png -loop 1 -framerate 30 -t 17.2 -i cap1.png -loop 1 -framerate 30 -t 17.2 -i cap2.png \
  -filter_complex "[0:v]fps=30,setpts=PTS-STARTPTS[v];\
[1]format=rgba,fade=in:st=0.3:d=0.3:alpha=1,fade=out:st=4.0:d=0.3:alpha=1[c0];\
[2]format=rgba,fade=in:st=4.4:d=0.3:alpha=1,fade=out:st=12.9:d=0.3:alpha=1[c1];\
[3]format=rgba,fade=in:st=13.3:d=0.3:alpha=1[c2];\
[v][c0]overlay=0:H-h-60:enable='between(t,0.3,4.3)'[a];[a][c1]overlay=0:H-h-60:enable='between(t,4.4,13.2)'[b];\
[b][c2]overlay=0:H-h-60:enable='gte(t,13.3)',format=yuv420p" -c:v libx264 -crf 16 cut.mp4
ffmpeg -i cut.mp4 -vf "fps=12,scale=600:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=sierra2_4a" \
  docs/media/hero.ko.gif
```

Keep each GIF under 10 MB.
