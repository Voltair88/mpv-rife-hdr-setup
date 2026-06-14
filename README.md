# mpv — RIFE + HDR cinema setup

A personal [mpv](https://github.com/mpv-player/mpv) configuration tuned for a high‑refresh HDR
OLED, built on top of **[F0903/mpv-enhanced](https://github.com/F0903/mpv-enhanced)**. It adds
real‑time RIFE frame interpolation via TensorRT, a careful HDR pipeline, and a custom
**paused movie‑info card** that pulls posters and metadata from TMDb.

> Built/tuned on: **RTX 4070**, **Samsung Odyssey G95SC** (5120×1440, 240 Hz, QD‑OLED, HDR1000),
> Windows 11. Other rigs work but will need path/HDR tweaks (see below).

## Features

- **RIFE 2× interpolation** — [vsrife](https://github.com/HolyWu/vs-rife) model **4.26**, TensorRT
  **fp16**, computed at display‑native **1440p** (not the source height — saves GPU for free) with
  scene‑change detection (`sc=True`) so hard cuts duplicate instead of morphing. Toggle with
  **`Ctrl+Shift+R`**. (`rife.vpy`, `rife_config.py`, `vs_script/`)
- **TMDb movie‑info card** (`scripts/tmdb-info.lua`, `tmdb_card.ps1`) — pause a movie and an
  IMDb‑style card fades in: backdrop + poster + title, tagline, ★ rating, genres, runtime, plot,
  director & cast. Parsed from the filename, fetched live from TMDb, rendered as a single bitmap.
  Shows **only while paused**; toggle with **`Ctrl+i`**.
  - **HDR‑correct color:** on HDR video the card is encoded into **BT.2020 + PQ** at a reference
    white (`card_nits`, default 203) so it isn't oversaturated; SDR video renders at true sRGB.
    Auto‑detected from the video's transfer — no manual color tuning.
  - Needs your **own free TMDb API key** (see Setup).
- **uosc UI** ([uosc](https://github.com/tomasklaen/uosc)) with a **cleaned‑up key‑bindings menu**
  (deduplicated, grouped by action).
- **Paused‑only thumbnails** ([thumbfast](https://github.com/po5/thumbfast), `scripts/thumbfast.lua`)
  — modified so seekbar thumbnails generate **only while paused**, avoiding GPU contention with RIFE
  during playback (which otherwise produced black/stale thumbnails).
- **HDR tone‑mapping** config in `mpv.conf` (gpu‑next, `target-peak=1000`, etc.).
- **Finer audio sync** — `Ctrl +` / `Ctrl -` (main row & numpad) nudge `audio-delay` in **50 ms**
  steps (mpv's default is 100 ms). (`input.conf`)
- **Autocrop** to fill the display with **`Shift+C`** (from mpv-enhanced).

## Setup

This is a `portable_config` overlay for an mpv build that already has VapourSynth + vsrife +
TensorRT wired up — the easiest base is **[F0903/mpv-enhanced](https://github.com/F0903/mpv-enhanced)**.

1. Install **[F0903/mpv-enhanced](https://github.com/F0903/mpv-enhanced)** (its PowerShell installer
   sets up mpv, VapourSynth, vsrife and the TensorRT toolchain).
2. Copy this repo's `portable_config/` over the installed one.
3. **RIFE models are not bundled here.** They're downloaded by
   [vsrife](https://github.com/HolyWu/vs-rife) on first use / via its instructions.
4. Get a free **TMDb v3 API key** (themoviedb.org → Settings → API) and put it in
   `portable_config/script-opts/tmdb-info.conf` (`api_key=`).
5. First RIFE playback at a new resolution builds a TensorRT engine — this takes a while once,
   then it's cached.

**You may need to adjust** absolute paths for your machine (e.g. `script-opts/thumbfast.conf`
`mpv_path`) and the HDR/display values in `mpv.conf` / `rife_config.py`.

## Credits & licenses

This setup stands on a lot of other people's work — please support the upstream projects:

| Project | Used for | Notes |
|---|---|---|
| **[F0903/mpv-enhanced](https://github.com/F0903/mpv-enhanced)** | Base distribution / installer | This config is a customized fork of it |
| **[HolyWu/vs-rife](https://github.com/HolyWu/vs-rife)** | RIFE in VapourSynth + TensorRT | imported by `rife.vpy` |
| **[hzwer/Practical-RIFE](https://github.com/hzwer/Practical-RIFE)** | RIFE v4.x model weights | models **not redistributed here** — fetched via vsrife |
| **[megvii-research/ECCV2022-RIFE](https://github.com/megvii-research/ECCV2022-RIFE)** | Original RIFE (paper/impl) | |
| **[tomasklaen/uosc](https://github.com/tomasklaen/uosc)** | Player UI | bundled, **modified** (key‑bindings menu) — **LGPL‑2.1** |
| **[po5/thumbfast](https://github.com/po5/thumbfast)** | Seekbar thumbnails | bundled, **modified** (paused‑only) — **MPL‑2.0** |
| **[mpv-player/mpv](https://github.com/mpv-player/mpv)** | The player | |
| **[VapourSynth](https://github.com/vapoursynth/vapoursynth)** | Frame‑server for RIFE | |
| **[NVIDIA TensorRT](https://developer.nvidia.com/tensorrt)** | fp16 inference | |

Bundled third‑party scripts keep their original licenses — see
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) for per‑component licenses and modifications.
My own files (`tmdb-info.lua`, `tmdb_card.ps1`, the RIFE configs) are MIT — see `LICENSE`.

### TMDb

This product uses the TMDB API but is not endorsed or certified by TMDB.
