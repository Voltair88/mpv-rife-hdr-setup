# Third‑party notices

This repository bundles and (in some cases) **modifies** code from other open‑source projects.
Each component is the property of its authors and remains under its original license. Please
support and refer to the upstream projects.

## Bundled (redistributed) code

### uosc — `portable_config/scripts/uosc/`
- Upstream: https://github.com/tomasklaen/uosc — © tomasklaen and contributors
- License: **LGPL‑2.1** (full text: https://github.com/tomasklaen/uosc/blob/main/LICENSE.LGPL)
- **Modified** in this repo: the key‑bindings menu (`lib/menus.lua`, `lib/utils.lua`, `main.lua`)
  was changed to deduplicate and group bindings by action. All other files are unmodified.

### thumbfast — `portable_config/scripts/thumbfast.lua`
- Upstream: https://github.com/po5/thumbfast — © po5 and contributors
- License: **MPL‑2.0** (https://www.mozilla.org/MPL/2.0/)
- **Modified** in this repo: thumbnails are restricted to the **paused** state (to avoid GPU
  contention with RIFE during playback). The original file header is retained.

### autocrop — `portable_config/scripts/autocrop.lua`
- Distributed as part of [F0903/mpv-enhanced](https://github.com/F0903/mpv-enhanced); refer to that
  project for its origin and license. Unmodified here.

## Not redistributed (linked only)

- **RIFE models** (v4.x weights) — [hzwer/Practical-RIFE](https://github.com/hzwer/Practical-RIFE),
  original [megvii-research/ECCV2022-RIFE](https://github.com/megvii-research/ECCV2022-RIFE).
  Downloaded by vsrife; **not** included in this repo.
- **vsrife** — [HolyWu/vs-rife](https://github.com/HolyWu/vs-rife) (installed separately).
- **mpv**, **VapourSynth**, **NVIDIA TensorRT** — installed via
  [F0903/mpv-enhanced](https://github.com/F0903/mpv-enhanced).

## Fonts — `portable_config/fonts/`
- `uosc_icons.otf`, `uosc_textures.ttf` ship with uosc (LGPL‑2.1, as above).

## TMDb
This product uses the TMDB API but is not endorsed or certified by TMDB.
