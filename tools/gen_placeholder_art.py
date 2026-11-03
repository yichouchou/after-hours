# -*- coding: utf-8 -*-
"""占位素材生成器（P1 用；P3 会被 AI 手绘素材替换）。

生成规则：
  地面   256x256 可平铺纹理
  角色   64x64 单张立绘（脚底对齐原点，程序化动画用）
  道具   32x32 单物件
"""
import math
import os
import random

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
random.seed(20261103)

PALETTE = [
    ((214, 122, 96), (168, 88, 70), (96, 56, 44)),    # 0 红
    ((118, 168, 214), (86, 128, 170), (56, 84, 118)),  # 1 蓝
    ((140, 190, 120), (106, 150, 92), (68, 102, 62)),   # 2 绿
    ((226, 196, 118), (186, 156, 88), (124, 100, 58)), # 3 黄
    ((178, 142, 200), (138, 108, 160), (94, 72, 112)), # 4 紫
    ((240, 178, 140), (196, 142, 110), (136, 96, 72)),  # 5 肤/棕
]
NIGHT = (38, 44, 62)
NIGHT_L = (52, 60, 82)
GRASS = (74, 106, 74)
GRASS_L = (88, 122, 86)
DIRT = (120, 96, 70)
DIRT_L = (142, 116, 86)


def ensure(path):
    os.makedirs(path, exist_ok=True)
    return path


def ground_tiles(name, base, light):
    im = Image.new("RGB", (256, 256), base)
    d = ImageDraw.Draw(im)
    for _ in range(900):
        x, y = random.randrange(256), random.randrange(256)
        d.point((x, y), fill=light)
    for _ in range(40):
        x, y = random.randrange(256), random.randrange(256)
        d.ellipse((x, y, x + 2, y + 1), fill=light)
    im.save(os.path.join(ensure(os.path.join(ROOT, "assets", "ground")), name + ".png"))


def character(idx):
    main, dark, line = PALETTE[idx % len(PALETTE)]
    im = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    # 影子
    d.ellipse((20, 54, 44, 60), fill=(0, 0, 0, 60))
    # 身体
    d.rounded_rectangle((22, 26, 42, 54), radius=6, fill=main, outline=dark, width=2)
    # 头
    d.ellipse((22, 8, 42, 30), fill=(246, 212, 178), outline=dark, width=2)
    # 头发/帽子
    d.pieslice((21, 4, 43, 26), 180, 360, fill=dark)
    # 眼睛
    d.rectangle((28, 17, 30, 20), fill=(30, 26, 24))
    d.rectangle((35, 17, 37, 20), fill=(30, 26, 24))
    # 手臂
    d.line((22, 32, 16, 46), fill=main, width=5)
    d.line((42, 32, 48, 46), fill=main, width=5)
    im.save(os.path.join(ensure(os.path.join(ROOT, "assets", "chars")),
                         "char_%d.png" % idx))


def prop(name, color):
    im = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.ellipse((6, 8, 26, 28), fill=color, outline=(40, 34, 30), width=2)
    d.ellipse((10, 11, 18, 17), fill=(255, 255, 255, 60))
    im.save(os.path.join(ensure(os.path.join(ROOT, "assets", "props")), name + ".png"))


ground_tiles("ground_grass", NIGHT, NIGHT_L)
ground_tiles("ground_path", DIRT, DIRT_L)
for i in range(6):
    character(i)
for name, col in [
    ("prop_carrot", (226, 118, 58)),
    ("prop_chair", (150, 110, 66)),
    ("prop_barrel", (158, 112, 64)),
    ("prop_lamp", (250, 226, 140)),
    ("prop_sign", (186, 158, 110)),
    ("prop_pot", (176, 104, 70)),
    ("prop_bench", (140, 104, 62)),
    ("prop_basket", (198, 168, 110)),
    ("prop_dog", (168, 132, 92)),
    ("prop_hat", (72, 62, 96)),
]:
    prop(name, col)
print("placeholder art written to", ROOT)
