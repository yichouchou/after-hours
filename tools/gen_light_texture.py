#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成点光源贴图 assets/light/lamp_light.png（256x256，白→透明径向渐变）。

用途：scripts/game_scene.gd 给每盏路灯挂的 PointLight2D 用它当 texture，
颜色由 light.color（暖黄）决定，贴图只负责亮度分布。
手绘风不需要真实焦散，所以用平方衰减的柔和径向渐变。

用法：python tools/gen_light_texture.py
"""
import math
import os

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIZE = 256
OUT = os.path.join(ROOT, "assets", "light", "lamp_light.png")


def main():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    px = img.load()
    c = (SIZE - 1) / 2.0
    for y in range(SIZE):
        for x in range(SIZE):
            r = math.hypot(x - c, y - c) / (SIZE / 2.0)
            if r >= 1.0:
                continue
            a = int(255 * (1.0 - r) ** 2.0)
            px[x, y] = (255, 255, 255, a)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    img.save(OUT)
    print("wrote", OUT, img.size)


if __name__ == "__main__":
    main()
