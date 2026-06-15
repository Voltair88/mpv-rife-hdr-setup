# mpv — RIFE + HDR cinema setup

A personal [mpv](https://github.com/mpv-player/mpv) configuration tuned for a high-refresh HDR OLED,
built on top of **[F0903/mpv-enhanced](https://github.com/F0903/mpv-enhanced)**. It adds real-time
**RIFE** frame interpolation via TensorRT, a careful **HDR/SDR** pipeline, a TMDb **movie-info card**,
**content-aware audio** (auto audio-delay + headphone virtual surround), one-key **subtitle download**,
and a few quality-of-life tools.

> Built/tuned on: **RTX 4070**, **Samsung Odyssey G95SC** (5120×1440, 240 Hz, QD-OLED, HDR1000),
> Windows 11, with audio routed through **Voicemeeter** to **Nuraphone G2** headphones. Other rigs work
> but will need path / HDR / device tweaks — almost everything is optional and configurable.

---

## Features

### Video
- **RIFE 2× interpolation** — [vsrife](https://github.com/HolyWu/vs-rife) model **4.26**, TensorRT
  **fp16**, computed at display-native **1440p** (not the source height — saves GPU for free) with
  scene-change detection (`sc=True`) so hard cuts duplicate instead of morphing. Source ≥ a configurable
  fps threshold is passed through untouched. Toggle **`Ctrl+Shift+R`**. (`rife.vpy`, `rife_config.py`)
- **Source-aware colorimetry** — `rife.vpy` detects the source transfer and keeps HDR on its BT.2020+PQ
  path while routing **SDR** through a correct BT.709 path (older versions forced PQ on everything). It
  also upscales sub-1440p sources with **Spline36** (vs cheap Bilinear) where the GPU has headroom.
- **SDR / HDR auto color profiles** — `mpv.conf` applies debanding on SDR (8-bit gradients) and leaves
  HDR clean, switched automatically from `video-params/gamma`.
- **HDR tone-mapping** — gpu-next, `target-peak=1000`, contrast recovery, etc.
- **Scaling** — `scale=ewa_lanczossharp` + antiring (applies when RIFE is off, since RIFE already
  resizes internally).

### The movie / TV info card  (`scripts/tmdb-info.lua`, `tmdb_card.ps1`)
Pause a video and an IMDb-style **frosted-glass card** fades in: backdrop + poster + title, tagline,
★ rating, genres, runtime, plot, director & cast. Parsed from the filename, fetched live from TMDb,
rendered to a single bitmap.
- **Movies and TV episodes** — `SxxExx` filenames are detected as TV (queries show → episode); the
  rating is labelled **`series`** or **`episode`** so it's never ambiguous.
- **HDR-correct color** — on HDR video the card is encoded into BT.2020 + PQ at a reference white
  (`card_nits`, 203) so it isn't oversaturated; SDR renders at true sRGB. Auto-detected.
- **Hover-zone visibility**, smooth fade, a "Loading…" pill while it builds, background pre-build, and
  Dir/Cast wrapping so nothing clips. Toggle **`Ctrl+i`**. Needs your own free **TMDb API key**.

### Audio
- **Content-aware auto audio-delay (Voicemeeter)** (`scripts/voicemeeter-sync.lua`) — talks to the
  **Voicemeeter Remote API** to detect which physical output is active and applies the right
  `audio-delay` per output (e.g. Bluetooth headphones need ~-350 ms, wired ~0). Re-applies live when you
  re-route in Voicemeeter. Nudge manually with **`Ctrl +`/`Ctrl -`** (50 ms steps) and **`Ctrl+Shift+S`**
  saves the current value for the current output. *Optional — only useful if you route mpv through
  Voicemeeter.*
- **Headphone virtual surround** (`scripts/spatial.lua`) — renders 5.1/7.1 into spatialized stereo with
  FFmpeg's **`sofalizer`** HRTF so surround content "feels" placed on stereo headphones. Auto-applies to
  multichannel content **only on headphone output** (gated via the Voicemeeter output above); manual
  toggle **`Ctrl+Shift+V`**, off by default. Ships with a **measured corrective EQ** that flattens the
  HRTF's tonal coloration, and configurable speaker angles. *Optional — needs a SOFA HRTF file.*

### Subtitles & navigation
- **One-key OpenSubtitles download** — uosc's built-in OpenSubtitles.com downloader, surfaced on
  **`Ctrl+Shift+D`** (opens the Subtitles menu, languages English→Swedish by default). Pick a result →
  it downloads + loads.
- **Chapter-skip** (`scripts/chapterskip.lua`) — auto-skips chapters titled intro / recap / credits /
  etc. (only on files that have named chapters).
- **Tools menu** (`scripts/tools-menu.lua`) — one uosc menu (**`Ctrl+t`** or the toolbar button)
  collecting the custom toggles: RIFE, info card, sharpen, audio-delay, virtual surround, stats.

### Tooling
- **Paused-only thumbnails** ([thumbfast](https://github.com/po5/thumbfast)) — modified to generate
  **only while paused**, avoiding GPU contention with RIFE.
- **stats logger** (`scripts/statlog.lua`) — opt-in (**`Ctrl+Shift+L`**) diagnostic that logs mpv
  playback-health metrics + per-second `nvidia-smi` telemetry to `%TEMP%` (used to verify RIFE realtime
  and GPU headroom).
- **Autocrop** to fill the display with **`Shift+C`** (from mpv-enhanced).

## Keybindings

| Key | Action |
|---|---|
| `Ctrl+Shift+R` | Toggle RIFE interpolation |
| `Ctrl+i` | Toggle movie/TV info card |
| `Ctrl+t` | Tools menu |
| `Ctrl+Shift+D` | Subtitles menu (OpenSubtitles download) |
| `Ctrl+Shift+V` | Toggle headphone virtual surround |
| `Ctrl+Shift+S` | Save audio-delay for the current Voicemeeter output |
| `Ctrl+Shift+L` | Toggle stats logging |
| `Ctrl +` / `Ctrl -` | Audio-delay ±50 ms (main row & numpad) |
| `Shift+C` | Autocrop |

---

## How it fits together (the dependency chain)

RIFE is the hard part. This repo is a **`portable_config` overlay** — it does **not** bundle the engine
that runs RIFE. That chain is:

```
mpv (vo=gpu-next, vapoursynth vf)
   └─ rife.vpy  (VapourSynth script)
        └─ vsrife        (HolyWu/vs-rife — RIFE in VapourSynth)
             └─ PyTorch + torch-tensorrt  →  NVIDIA TensorRT (fp16)  →  your GPU
```

The easiest way to get all of that pre-wired is **[F0903/mpv-enhanced](https://github.com/F0903/mpv-enhanced)**,
whose installer bundles mpv + Python + VapourSynth + vsrife + the TensorRT toolchain. This repo sits on
top of it. (RIFE **model weights** and the built **TensorRT engine** are not in this repo — vsrife
fetches the weights, and the engine is built on your machine for your exact GPU/resolution.)

## Setup

1. **Install the base:** [F0903/mpv-enhanced](https://github.com/F0903/mpv-enhanced) (its PowerShell
   installer sets up mpv, Python, VapourSynth, vsrife and TensorRT).
2. **Deploy this config:** run `install.ps1` (copies `portable_config/` into your mpv-enhanced install,
   backing up any existing one) — or just copy `portable_config/` over the installed one by hand.
3. **First RIFE playback** at a new resolution builds a TensorRT engine (slow once, then cached). To
   pre-build before opening mpv: `VSPipe.exe -o 0 -e 0 portable_config/prebuild_engine.vpy .`
4. **Adjust for your machine:** HDR/display values in `mpv.conf` (`target-peak`) and `rife_config.py`,
   and any absolute paths (e.g. `script-opts/thumbfast.conf` `mpv_path`).

### Optional per-feature setup
| Feature | What you need |
|---|---|
| **TMDb info card** | A free **TMDb v3 API key** (themoviedb.org → Settings → API) in `script-opts/tmdb-info.conf` (`api_key=`). |
| **Subtitle download** | Works out of the box on uosc's bundled key (shared, rate-limited). For your own quota, make a free **opensubtitles.com** account → API consumer → put the key in `scripts/uosc/main.lua` (`open_subtitles_api_key`, ~line 170). Set languages via `uosc.conf` `languages=`. |
| **Virtual surround** | A **SOFA HRTF file** (SimpleFreeFieldHRIR), e.g. **SADIE II** KU100 (download the *HRIR* SOFA, not BRIR). Save it to a **space-free path** (FFmpeg can't handle spaces) and point `script-opts/spatial.conf` `sofa=` at it. |
| **Auto audio-delay** | Only if you route mpv through **Voicemeeter**. It auto-detects the DLL; calibrate per-output delays with `Ctrl +/-` then `Ctrl+Shift+S`. Set `enabled=no` in `script-opts/voicemeeter-sync.conf` to disable. |

All of these are **optional and independent** — the core (RIFE + HDR + info card) works without any of
them, and each script can be disabled in its `script-opts/*.conf`.

## Credits & licenses

This setup stands on a lot of other people's work — please support the upstream projects.

| Project | Used for |
|---|---|
| **[F0903/mpv-enhanced](https://github.com/F0903/mpv-enhanced)** | Base distribution / installer (this config is a customized fork) |
| **[HolyWu/vs-rife](https://github.com/HolyWu/vs-rife)** | RIFE in VapourSynth + TensorRT |
| **[hzwer/Practical-RIFE](https://github.com/hzwer/Practical-RIFE)** / **[megvii-research/ECCV2022-RIFE](https://github.com/megvii-research/ECCV2022-RIFE)** | RIFE model weights / original RIFE (not redistributed) |
| **[tomasklaen/uosc](https://github.com/tomasklaen/uosc)** | Player UI + OpenSubtitles downloader — bundled, **modified** (LGPL-2.1) |
| **[po5/thumbfast](https://github.com/po5/thumbfast)** | Seekbar thumbnails — bundled, **modified** (MPL-2.0) |
| **[mpv](https://github.com/mpv-player/mpv)** / **[VapourSynth](https://github.com/vapoursynth/vapoursynth)** / **[NVIDIA TensorRT](https://developer.nvidia.com/tensorrt)** | Player / frame-server / fp16 inference |
| **FFmpeg `sofalizer`** (in mpv) + a **SOFA HRTF** (e.g. [SADIE II](https://www.york.ac.uk/sadie-project/database.html), CC-BY) | Headphone virtual surround (HRTF not redistributed) |
| **[OpenSubtitles.com](https://www.opensubtitles.com)** | Subtitle source (via uosc) |
| **[VB-Audio Voicemeeter](https://vb-audio.com/Voicemeeter/) Remote API** | Active-output detection for auto audio-delay |

Bundled third-party scripts keep their original licenses — see
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md). My own files are MIT — see `LICENSE`.

### TMDb
This product uses the TMDB API but is not endorsed or certified by TMDB.
