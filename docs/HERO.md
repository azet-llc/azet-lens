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
# The chat, 1200×800 at the top-left of the main display; scripted scrolls at 9 s (up) and 11 s (down)
open -na "Google Chrome" --args --user-data-dir=/tmp/mwoyeo-demo \
  --app="file://$PWD/demo/chat.html?every=3&history=16&scroll=9:-500,11:500" \
  --window-position=0,40 --window-size=1200,800

# A lens over the message column (global points, top-left origin), gliding up 260 pt after 5 s
open -n build/dd/Build/Products/Release/Mwoyeo.app --args \
  --add-region 340,330,820,380 --glide 0,-260,2.5,5
```

`--add-region` stores the lens like any other; remove it from the menu afterwards.

## Before recording

1. **Warm up once.** The first text recognition after launch takes tens of seconds, and translations are cached for
   the rest of the session. Run the sequence once, reload the page, then record.
2. **Language pack.** For Japanese scenes install Japanese → Korean (System Settings › General › Language & Region ›
   Translation Languages); English → Korean is fast without one.
3. **Clean screen.** Nothing but the demo window in the recorded rect.

## Recording

Screen recording captures Mwoyeo's overlays (only Mwoyeo's own capture leaves them out):

```bash
screencapture -v -V 14 -R 0,40,1200,800 hero.mov
ffmpeg -i hero.mov -vf "fps=15,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" docs/hero.gif
```

Keep the GIF under 10 MB; the full-quality video goes on the release page.
