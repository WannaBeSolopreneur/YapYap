# YapYap brand

The look comes from the YapYap office show on TikTok: pixel art in the show's palette, Press Start 2P titles,
Atkinson Hyperlegible for reading, Pixelify Sans for keys and labels (all SIL OFL, licences in `fonts/`).

| | |
|---|---|
| Ink `#0f1828` · Night `#19283e` · Navy `#1b2a41` · Slate `#3e5c84` | Powder `#a7c7e7` · Pale `#dcebf7` · Cream `#f4f1ea` |
| Yellow `#ffd166` (the read-along highlight) · Teal `#06d6a0` · Red `#e63946` · Orange `#f28c28` | |

Tagline: **On-device AI productivity tools.** Page titles and search text keep "text to speech and dictation for Mac".

## The mark

A pixel speech bubble with lines of text and the yellow highlight running across it, one pixel past each edge.
It's drawn on a 16x16 grid in `make_brand.py`; edit `mark_grid()` and rerun to rebuild every icon:

    python3 web/brand/make_brand.py

That writes `site/mark.png`, `favicon.svg`, `favicon-32.png`, `icon.png`, `apple-touch-icon.png`, `og.png`,
`docs/icon.png`, `docs/social-preview.png`, `Resources/AppIcon-1024.png` and `Resources/AppIcon.icns`.

Don't use the rainbow apple from the show's end card on the site or in the app: it's too close to Apple's logo.
`site/show-intro.mp4` is the theme song cut just before that card appears.

## Art from the show

- `site/art/office-night.webp`: the office exterior, a frame of the theme song.
- `site/art/cast/<name>-<pose>.png`: 24x32 cast sprites rendered from the show's `office_cast.py` in its palette
  (bob, walt, zoe, lenny, gail, jessy). Show them at whole-number scales with `image-rendering: pixelated`.
