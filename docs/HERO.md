# Hero clip

One 15-second loop for the README and social posts. Everything in it is the real app on a real screen — no editing
beyond trimming.

## Shot list

| t | What happens | What it shows |
|---|---|---|
| 0–2 s | A Japanese visual novel fills the screen (`demo/vn.html`). ⌃⌥T, drag a lens over the dialogue box and the choices. | Picking is instant and native |
| 2–5 s | The Japanese dissolves; Korean appears in the same place, size and colour, on the untouched painted background. | Seamless erase + rewrite, not a box |
| 5–9 s | Grab the lens edge and glide it up across the title. The title is already Korean as it enters the lens. | The lens, and reading ahead |
| 9–12 s | Cut to a Japanese article in Chrome (`demo/article.html`), lens on the body text, scroll with the trackpad. | Translations ride the scroll |
| 12–14 s | ⌃⌥O twice: original, translation. | Before / after in one beat |
| 14–15 s | End card: icon, “뭐여? 이제 바로 읽혀요.”, “100% on-device”. | |

## Before recording

1. **Language pack.** Install Japanese → Korean (System Settings › General › Language & Region › Translation
   Languages). With it, new lines translate fast enough to keep up with a drag; without it each sentence takes
   about a second.
2. **Warm up once.** Run the whole sequence one time before the take. The first text recognition after launch takes
   tens of seconds, and translations are cached for the rest of the session, so the take itself is instant.
3. **Clean screen.** Hide the Dock and desktop icons, use a plain wallpaper, set Chrome to full screen.

## Setting up the scenes

```bash
# Visual novel, 1440×900 window at the top-left of the main display
open -na "Google Chrome" --args --app="file://$PWD/demo/vn.html" --window-position=0,0 --window-size=1440,900

# Article
open -na "Google Chrome" --args --app="file://$PWD/demo/article.html" --window-position=0,0 --window-size=1440,900

# Start with a lens already placed (global points, top-left origin) instead of picking one on camera
open -a build/dd/Build/Products/Release/Mwoyea.app --args --add-region 86,560,1268,260
```

## Recording

Screen Recording captures Mwoyea's overlays (only Mwoyea's own capture leaves them out), so any recorder works:
⌘⇧5, QuickTime, or

```bash
screencapture -v -C hero.mov       # stop with ⌃C
ffmpeg -i hero.mov -vf "fps=30,scale=1440:-2" -c:v libx264 -crf 20 -pix_fmt yuv420p docs/hero.mp4
```

Keep the pointer movements slow and deliberate — the lens should glide, not jump.
