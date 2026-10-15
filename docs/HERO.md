# Hero clip

One short loop for the README and social posts. Everything in it is the real app on a real screen; the lens moves
and the page scrolls by script, so a take can be repeated exactly.

## Shot list

1:1 (1000×1000 pt content, exported at 1080×1080), Japanese chat → Korean, about 23 s after cutting:

| Clip | What happens | What it shows |
|---|---|---|
| 1 | A Discord-style chat in Japanese (`demo/chat.html?lang=ja&every=4`); a new message arrives under the lens and turns Korean in place. | Reading a live chat in another language |
| 2 | The cursor takes the lens by its name pill and drags it up over older messages, then back. | A lens you can drag; reading ahead |
| 3 | The resize corner: smaller, then back. | |
| 4 | Trackpad scroll up through the history, then down. | Translations ride the scroll |
| 5 | ⌃⌥O: the original, then the translation. | Before / after in one beat |
| End | `docs/media/endcard.html` rendered at 1080×1080, cross-faded in. | |

## Setting up

```bash
# The chat: content area 1000×1000 at (140, 96) — the --app title bar sits above it; no translate bubble
open -na "Google Chrome" --args --user-data-dir=/tmp/mwoyeo-demo --no-first-run \
  --app="file://$PWD/demo/chat.html?lang=ja&every=4&history=14" \
  --window-position=140,68 --window-size=1000,1028

# The source language must match the page (Settings › Translate from: Japanese).
# A lens over the newest messages (global points, top-left origin). Launch the binary from a terminal that has
# Screen Recording permission, so a rebuilt ad-hoc app needs no new grant.
build/dd/Build/Products/Release/Mwoyeo.app/Contents/MacOS/Mwoyeo --add-region 470,596,620,420 &
```

`--add-region` stores the lens like any other; remove it from the menu afterwards. Drag, resize and scroll with the
real mouse and trackpad: the lens's name pill moves it, its bottom-right corner resizes it.

## Before recording

1. **Warm up.** Wait about 20 s after launch: the first recognition loads models and translations are cached.
2. **Scroll once over the chat.** The first gesture over a window teaches the lens which area scrolls; until then a
   scroll is followed frame by frame instead of predicted.
3. **Language pack.** Japanese → Korean installed (System Settings › General › Language & Region › Translation
   Languages) for sub-second translation.
4. **Clean screen.** Nothing but the demo window in the recorded rect; park the cursor outside it between moves.

## Recording and cutting

Screen recording captures Mwoyeo's overlays (only Mwoyeo's own capture leaves them out):

```bash
screencapture -v -V 30 -R 140,96,1000,1000 take.mov
# keep the five clips, drop the waits between them
ffmpeg -i take.mov -filter_complex "[0:v]trim=1:5.6,setpts=PTS-STARTPTS[a];[0:v]trim=6.2:11.8,setpts=PTS-STARTPTS[b];\
[0:v]trim=12.6:16.4,setpts=PTS-STARTPTS[c];[0:v]trim=18.2:24.6,setpts=PTS-STARTPTS[d];[0:v]trim=25.7:28.2,setpts=PTS-STARTPTS[e];\
[a][b][c][d][e]concat=n=5,scale=1080:1080:flags=lanczos,fps=30,format=yuv420p" -c:v libx264 -crf 16 cut.mp4
ffmpeg -i cut.mp4 -vf "fps=12,scale=640:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse" \
  docs/media/hero.gif
```

Keep the GIF under 10 MB; the 1080×1080 video with the end card goes on the release page.
