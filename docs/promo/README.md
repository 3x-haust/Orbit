# Orbit 1.0 promo

A ~32s launch film in the Screen Studio style. The camera follows the pointer, with click ripples and kinetic type. Every piece of UI is Orbit's own: window captures and offscreen renders from a DEBUG build, plus the real macOS cursors. The soundtrack is our own composition, cut on the film's bar grid.

Every cut comes in English and Korean (`-en`, `-ko`). Both the on-screen copy and the Orbit UI in the frames match the film's language.

| File | |
|---|---|
| `orbit-promo-16x9-<en\|ko>.mp4` | the film, 1920x1080 60fps |
| `orbit-promo.gif`, `orbit-promo-ko.gif` | a 9.5s loop of the demo (ring, capture, editor, launcher) for READMEs: film 4.0–13.5s, 960px, 12fps, 96 colours, under 8 MB |
| `poster.png` | the end card, from the English film |

The soundtrack is "Orbit Original A", a keynote indie-pop track at 120 BPM in C# major: disco guitars, synth stabs, a wide pad, claps and a four-on-the-floor groove. It is mastered to −14 LUFS integrated, with true peak at or below −1 dBTP. Its sections follow the film:

- the reveal at bar 0 lands on the drop;
- the notch lands after a two-beat drop-out;
- each of the four verbs gets its own stab;
- the logo lands on the final hit, and the film ends on the track's own ring-out.

The mix is `tools/promo/music/orbit-original-a/orbit-original-a.flac`; `tools/promo/music/tracks.json` places it on the grid.

Rebuild. The captured frames in `tools/promo/assets/` aren't in the repo. They are about 130 MB and come from a live Orbit. `render.py` stops and says so when they're missing. Make them with build-promo's DEBUG Orbit, run once per language:

```sh
xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Debug -derivedDataPath build-promo build
pkill -x Orbit; open build-promo/Build/Products/Debug/Orbit.app --args -AppleLanguages "(en)"   # then "(ko)"
PROMO_LANG=en python3 tools/promo/capture.py   # glyphs, cursors, pages, ring, keycaps, notch, launcher -> tools/promo/assets
PROMO_LANG=en python3 tools/promo/prepare.py   # capture, QuickAccess, editor, toasts, overlay -> assets/en/real
python3 tools/promo/render.py                  # both languages (--lang en for one, --preview for a 360p sync check, --vertical adds a 9:16)
```

What the film shows of the Mac is placeholder data or blurred:

- The notch shows the track "Into Orbit" and the event "Orbit 1.0 launch" / "Orbit 1.0 출시".
- The desktop, menu bar and wallpaper are drawn by `render.py`.
- `capture.py` puts a frosted blur over these, right after each shot:
  - the recent-captures thumbnails on the Home and Capture pages;
  - the menu bar icons on the Menu Bar page;
  - the output device and the apps on the Sound page;
  - the launcher's Recent Apps row.
- The launcher frames skip the one-digit state, because that state lists clipboard history.

## Credits

Music: "Orbit Original A", an original composition for this film, arranged and mixed from Apple's GarageBand loop library. Apple's GarageBand license allows its loops to be used royalty-free in your own original soundtracks for film and video, including broadcast and distribution. The license does not allow distributing the loops on their own, so the repo holds only the finished mix, and the arrangement sources stay out of it. No attribution is required.

UI sounds (clicks, key ticks, whooshes, notch chimes) are synthesized in `tools/promo/soundtrack.py`. Cursors are macOS's own.
