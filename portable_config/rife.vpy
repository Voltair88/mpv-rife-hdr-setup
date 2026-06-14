import sys
import os
from fractions import Fraction
import vapoursynth as vs

script_dir = os.path.dirname(os.path.abspath(__file__))
if script_dir not in sys.path:
    sys.path.insert(0, script_dir)

import rife_config as config

core = vs.core
core.num_threads = 6  # zimg YUV<->RGBH conversion threads. Was 10, which saturated the
# 12-thread CPU (starved the whole system). The GPU/TensorRT is the realtime bottleneck, so
# fewer conversion threads still feeds it fast enough while leaving ~6 cores for the OS.
# Tune: raise if fps drops/stutters, lower if the system still feels starved.


def print_log(*values: object):
    if not config.log:
        return
    print(*values, file=config.log)
    config.log.flush()


DISPLAY_H = 1440  # Samsung G95SC native height — process RIFE here, not at source 1606p


def apply_rife(clip, factor_num, factor_den):
    """YUV(PQ/HDR) -> RGBH -> vsrife TensorRT -> YUV420P10, at display-native height."""
    # Clear colorspace props so zimg does NOT linearize PQ during YUV->RGB
    clip = core.std.SetFrameProps(clip, _Transfer=2, _Primaries=2, _Matrix=2, _ColorRange=0)

    # Downscale to display height + convert YUV420P10 -> RGBH (fp16) in one zimg pass.
    # The panel shows 1440p, so computing RIFE above that is wasted GPU (no visible gain).
    tw = round(clip.width * DISPLAY_H / clip.height / 2) * 2
    # Bilinear (was Bicubic): cheaper zimg resampling on the CPU. This downscale is only
    # 1606->1440 (~0.9x), so the quality difference is negligible but the CPU saving is real,
    # helping sustain realtime (avoid A-V desync) at a lower thread count.
    clip = core.resize.Bilinear(clip, width=tw, height=DISPLAY_H, format=config.gpu_format, matrix_in=9, range_in=1, range=0)

    from vsrife import rife
    clip = rife(
        clip,
        model=config.rife_model,   # "4.26" / "4.25" — both have prebuilt 3456x1536 engines
        factor_num=factor_num,
        factor_den=factor_den,
        scale=config.scale,        # optical-flow at half-res (output at display res)
        sc=config.sc,              # scene-change detection: duplicate across hard cuts, don't morph
        sc_threshold=config.sc_threshold,
        trt=True,                  # TensorRT fp16 inference
        trt_static_shape=True,
    )

    # RGBH -> YUV420P10, restore HDR (PQ / bt.2020 / limited) props
    # Bilinear (was Bicubic): runs at 2x output rate (47.952fps) so it's the bigger CPU cost;
    # only chroma 444->420 here (no luma resize), so bilinear is visually ~identical at 1440p.
    clip = core.resize.Bilinear(clip, format=vs.YUV420P10, matrix=9, range_in=0, range=1, chromaloc=2)
    clip = core.std.SetFrameProps(clip, _Transfer=16, _Primaries=9, _Matrix=9, _ColorRange=1)
    return clip


if container_fps < config.disable_fps_threshold:  # type: ignore[name-defined]
    container_fps_frac = Fraction(container_fps).limit_denominator(100)  # type: ignore[name-defined]
    target_fps_frac = config.target_mode.get_fps_fraction(container_fps_frac).limit_denominator(100)
    [factor_num, factor_den] = target_fps_frac.as_integer_ratio()

    print_log(f"vsrife TRT: {float(container_fps_frac):.3f}fps x{factor_num}/{factor_den} -> {float(container_fps_frac * target_fps_frac):.3f}fps")

    clip = video_in  # type: ignore[name-defined]
    print_log(f"Resolution: {clip.width}x{clip.height} -> 1440p | model={config.rife_model} scale={config.scale} sc={config.sc}")

    clip = apply_rife(clip, factor_num, factor_den)

    print_log("vsrife TRT applied successfully.")
    clip.set_output()

else:
    print_log(f"FPS {container_fps} above threshold {config.disable_fps_threshold}, skipping.")  # type: ignore[name-defined]
    clip = video_in  # type: ignore[name-defined]
    clip.set_output()
