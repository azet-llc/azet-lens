# Hero clip

One short loop for the README and social posts. Everything in it is the real app on a real screen; the lens moves
and the page scrolls by script, so a take can be repeated exactly.

## Shot list

| t | What happens | What it shows |
|---|---|---|
| 0–4 s | A Discord-style chat in English (`demo/chat.html`) with a lens over the messages. New messages arrive and are rewritten in Korean in place. | The everyday use: reading a chat in another language |
| 4–8 s | The lens glides up over older messages. They are already Korean as they enter it. | The lens, and reading ahead |
| 8–12 s | The chat scrolls back down. Translations ride the scroll instead of flickering. | Scrolling |
| 12–14 s | ⌃⌥O: original, then translation. | Before / after in one beat |

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
