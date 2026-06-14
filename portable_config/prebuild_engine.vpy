import sys, os
import vapoursynth as vs

script_dir = os.path.dirname(os.path.abspath(__file__))
if script_dir not in sys.path:
    sys.path.insert(0, script_dir)
import rife_config as config

core = vs.core
core.num_threads = 10

DISPLAY_H = 1440

# Blank clip matching the real video: 3840x1606, YUV420P10
clip = core.std.BlankClip(width=3840, height=1606, format=vs.YUV420P10, length=8, fpsnum=24000, fpsden=1001)
clip = core.std.SetFrameProps(clip, _Transfer=16, _Primaries=9, _Matrix=9, _ColorRange=1)

# Same pipeline as rife.vpy: clear props, downscale to display height, convert to RGBH
clip = core.std.SetFrameProps(clip, _Transfer=2, _Primaries=2, _Matrix=2, _ColorRange=0)
tw = round(clip.width * DISPLAY_H / clip.height / 2) * 2
clip = core.resize.Bicubic(clip, width=tw, height=DISPLAY_H, format=config.gpu_format, matrix_in=9, range_in=1, range=0)

from vsrife import rife
clip = rife(clip, model=config.rife_model, factor_num=2, factor_den=1, scale=config.scale, trt=True, trt_static_shape=True)

clip = core.resize.Bicubic(clip, format=vs.YUV420P10, matrix=9, range_in=0, range=1, chromaloc=2)
clip.set_output()
