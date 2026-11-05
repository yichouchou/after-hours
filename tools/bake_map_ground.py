#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把草地 + 土路 + 边缘压暗烘焙成一张整图地面（960x576）。

输入：assets/ground/ground_grass.png、ground_path.png（各 256x256 可平铺源）
      data/map.json 的 paths 段（[[格x, 格y, 宽, 高], ...]，单位=格）
输出：assets/ground/map_ground.png

为什么烘焙成整图而不是运行时拼贴图：
运行时逐格拼贴图会在每条路边缘露出 32px 的方块接缝；烘焙成一张图则完全无缝，
而且能把"边缘压暗"和路面毛边一起做进同一张贴图。

用法：python tools/bake_map_ground.py
"""
import json
import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TILE = 32
MAP_W, MAP_H = 30 * TILE, 18 * TILE
EDGE = 24          # 边缘压暗宽度（px）
EDGE_DARK = 0.35   # 边缘最暗处亮度系数


def tile_uniformity(src):
    """贴图的亮度离散度（标准差 / 255）。0 = 完全均匀，越大越花。"""
    hist = src.convert("L").histogram()
    total = sum(hist)
    mean = sum(i * h for i, h in enumerate(hist)) / float(total)
    var = sum(h * (i - mean) ** 2 for i, h in enumerate(hist)) / float(total)
    return math.sqrt(var) / 255.0


def median_color(src):
    """各通道取中位数（比均值抗"局部大亮区"干扰）。"""
    r = sorted(p[0] for p in src.convert("RGB").getdata())
    g = sorted(p[1] for p in src.convert("RGB").getdata())
    b = sorted(p[2] for p in src.convert("RGB").getdata())
    n = len(r)
    return (r[n // 2], g[n // 2], b[n // 2])


def _lighten(c, k):
    return tuple(min(255, int(v + (255 - v) * k)) for v in c)


def procedural_grass(size, base):
    """程序化夜草地：多层草叶笔触。

    每个笔触在 9 个环绕位置各画一次（-size/0/+size），所以跨边的笔触会在对边
    续上 → 平铺时没有接缝。
    """
    random.seed(20261105)
    im = Image.new("RGB", (size, size), base)
    d = ImageDraw.Draw(im)
    layers = [
        (1100, _lighten(base, 0.10), 7),
        (700, _lighten(base, 0.05), 5),
        (300, _lighten(base, 0.20), 9),
        (220, _lighten(base, -0.35), 6),
    ]
    for count, color, length in layers:
        for _ in range(count):
            x = random.randrange(size)
            y = random.randrange(size)
            ang = random.uniform(-0.7, 0.7) - math.pi / 2
            dx = math.cos(ang) * length
            dy = math.sin(ang) * length
            for ox in (-size, 0, size):
                for oy in (-size, 0, size):
                    d.line((x + ox, y + oy, x + ox + dx, y + oy + dy), fill=color, width=1)
    return im


def strip_outliers(src, tol=48):
    """把离中位色太远的像素替换成中位色。

    AI 常把"白背景 / 高光块"一起画进贴图，平铺后路面会出现白洞。
    这里把离中位色过远的像素抹平，保留同色系的纹理细节。
    """
    med = median_color(src)
    out = src.copy()
    px = out.load()
    w, h = src.size
    limit = tol * 3
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y]
            if abs(r - med[0]) + abs(g - med[1]) + abs(b - med[2]) > limit:
                px[x, y] = med
    return out


def make_seamless(src):
    """把一张图变成近似无缝的可平铺纹理（offset + 羽化混合）。

    AI 生成的"seamless tile"通常并不真的无缝，直接平铺会出现网格状接缝。
    这里把图四分后错位拼接，再用羽化蒙版在十字接缝处把两张图混合回去，
    接缝就被抹平了。
    """
    w, h = src.size
    qw, qh = w // 2, h // 2
    out = Image.new("RGB", (w, h))
    out.paste(src.crop((qw, 0, w, qh)), (0, 0))
    out.paste(src.crop((0, 0, qw, qh)), (qw, 0))
    out.paste(src.crop((0, qh, w, h)), (0, qh))
    out.paste(src.crop((qw, qh, w, h)), (qw, qh))
    mask = Image.new("L", (w, h), 0)
    md = ImageDraw.Draw(mask)
    md.rectangle((qw - 18, 0, qw + 18, h), fill=255)
    md.rectangle((0, qh - 18, w, qh + 18), fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(14))
    return Image.composite(out, src, mask)


def tile_fill(src, w, h):
    """把 256x256 的可平铺源铺成 w×h（边缘裁切）。"""
    out = Image.new("RGB", (w, h))
    sw, sh = src.size
    for oy in range(0, h, sh):
        for ox in range(0, w, sw):
            out.paste(src.crop((0, 0, min(sw, w - ox), min(sh, h - oy))), (ox, oy))
    return out


def road_mask(paths):
    """路面蒙版：矩形路面 + 模糊 + 只在**边缘带**用噪声啃出不规则毛边。"""
    mask = Image.new("L", (MAP_W, MAP_H), 0)
    md = ImageDraw.Draw(mask)
    for seg in paths:
        gx, gy, gw, gh = seg
        md.rounded_rectangle((gx * TILE, gy * TILE, (gx + gw) * TILE, (gy + gh) * TILE),
                             radius=8, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(2.0))
    noise = Image.effect_noise((MAP_W, MAP_H), 28).convert("L")
    mdata = list(mask.getdata())
    ndata = list(noise.getdata())
    out_data = bytearray(len(mdata))
    for i, m in enumerate(mdata):
        if m <= 38:
            out_data[i] = 0          # 路面之外
        elif m >= 217:
            out_data[i] = 255        # 路面之内，保持完整
        else:
            out_data[i] = 255 if ndata[i] > 130 else 0   # 边缘带：噪声啃出毛边
    return Image.frombytes("L", (MAP_W, MAP_H), bytes(out_data))


def vignette():
    """越靠边越暗的蒙版（255 = 保留原图，0 = 全暗）。"""
    vign = Image.new("L", (MAP_W, MAP_H))
    vp = vign.load()
    for y in range(MAP_H):
        for x in range(MAP_W):
            d = min(x, y, MAP_W - 1 - x, MAP_H - 1 - y)
            t = min(1.0, d / float(EDGE))
            vp[x, y] = int(255 * (EDGE_DARK + (1.0 - EDGE_DARK) * t))
    return vign.filter(ImageFilter.GaussianBlur(3))


def main():
    grass_src = Image.open(
        os.path.join(ROOT, "assets", "ground", "ground_grass.png")).convert("RGB")
    path_src = Image.open(
        os.path.join(ROOT, "assets", "ground", "ground_path.png")).convert("RGB")

    # AI 未必给得出"均匀可平铺"的草地（可能带大块亮区）。这里量一下离散度，
    # 不合格就退回程序化草地（用 AI 图的中位色当底色，保留它的色调）。
    u = tile_uniformity(grass_src)
    if u > 0.12:
        base = median_color(grass_src)
        grass = procedural_grass(256, base)
        print("草地贴图离散度 %.3f 过高 → 改用程序化草地（底色 %s）" % (u, str(base)))
    else:
        grass = make_seamless(grass_src)
        print("草地贴图离散度 %.3f 可用 → 去接缝后平铺" % u)

    path_tex = make_seamless(strip_outliers(path_src))
    with open(os.path.join(ROOT, "data", "map.json"), "r", encoding="utf-8") as f:
        data = json.load(f)

    ground = tile_fill(grass, MAP_W, MAP_H)
    road = tile_fill(path_tex, MAP_W, MAP_H)
    ground.paste(road, (0, 0), road_mask(data.get("paths", [])))

    dark = Image.new("RGB", (MAP_W, MAP_H), (10, 12, 22))
    ground = Image.composite(ground, dark, vignette())

    out = os.path.join(ROOT, "assets", "ground", "map_ground.png")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    ground.save(out)
    print("baked", out, ground.size)


if __name__ == "__main__":
    main()
