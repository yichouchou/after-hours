#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AI 素材流水线：清单 -> 生成 -> 抠透明 -> 归一化 -> 写 assets/。

用法：
    python tools/gen_art_ai.py --kind char      # 只跑角色
    python tools/gen_art_ai.py --kind prop
    python tools/gen_art_ai.py --kind tile
    python tools/gen_art_ai.py --dry-run        # 只打印将要做什么

依赖：mcode-tools CLI（MiniMax matrix 图像生成 + 抠图）、Pillow。

★ 归一化保证的美术不变量（tools/test_art.gd 会断言）：
  - 不透明像素贴到画布最底边
  - 水平中心居中
  两条都由 normalize_sprite() 强制实现，不依赖 AI 输出的构图。
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCALE = 2                 # 素材按 2x 出图
SHADOW_BAND_RATIO = 0.08  # 画面区底部留给接地影子的比例


def run(args):
    """跑一条命令，返回 (returncode, 输出)。

    Windows 上 mcode-tools 是 .cmd 包装器（里面设置认证 broker 的环境变量，
    不能绕开直接跑 cli.mjs），必须经 cmd.exe 调用。
    """
    exe = shutil.which(args[0]) or args[0]
    argv = [exe] + list(args[1:])
    if exe.lower().endswith((".cmd", ".bat")):
        argv = ["cmd", "/c", exe] + list(args[1:])
    proc = subprocess.run(argv, capture_output=True, text=True,
                          encoding="utf-8", errors="replace", shell=False)
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def cli_json(args):
    code, out = run(args)
    if code != 0:
        raise RuntimeError("命令失败 %s：%s" % (args, out.strip()))
    return json.loads(out)


def write_args_file(payload):
    """args 文件必须 UTF-8 无 BOM（带 BOM 会被 CLI 拒绝）。"""
    fd, path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(payload, f, ensure_ascii=False)
    return path


def upload_temp_url(local_path):
    data = cli_json(["mcode-tools", "upload_temp_url", local_path])
    return data["temp_url"]


def download(url, dest):
    """下载到本地（用 urllib，避免每次起一个 PowerShell）。"""
    with urllib.request.urlopen(url, timeout=120) as resp, open(dest, "wb") as f:
        f.write(resp.read())
    return dest


def generate(prompt, style_ref_url, out_file):
    req = {"prompt": prompt, "aspect_ratio": "1:1", "resolution": "1K",
           "output_file": out_file}
    if style_ref_url:
        req["input_urls"] = [style_ref_url]
    path = write_args_file({"requests": [req]})
    try:
        data = cli_json(["mcode-tools", "connector", "call",
                         "connector__matrix__generate_image", "--args-file", path])
    finally:
        os.remove(path)
    items = data.get("success_items") or []
    if not items:
        raise RuntimeError("生成失败：%s" % json.dumps(data, ensure_ascii=False))
    return items[0]["node_id"]


def strip_background(image_url):
    path = write_args_file({"image_url": image_url})
    try:
        data = cli_json(["mcode-tools", "connector", "call",
                         "connector__matrix__remove_image_background",
                         "--args-file", path])
    finally:
        os.remove(path)
    return data["node_id"]


def asset_url(node_id):
    return cli_json(["mcode-tools", "get_asset_url", node_id])["download_url"]


def normalize_sprite(img, target_w, target_h):
    """裁 alpha 包围盒 -> 等比缩放 -> 脚底线居中贴进画面区 -> 补接地影子。

    保证：最后一行的 alpha 非零（alpha 包围盒贴到画布底边）、水平中心居中。
    """
    img = img.convert("RGBA")
    bbox = img.getbbox()
    if bbox is None:
        raise RuntimeError("抠图后没有任何不透明像素")
    art = img.crop(bbox)
    band = max(1, int(round(target_h * SHADOW_BAND_RATIO)))
    art_h = target_h - band
    scale = min(float(target_w) / art.width, float(art_h) / art.height)
    new_w = max(1, int(round(art.width * scale)))
    new_h = max(1, int(round(art.height * scale)))
    art = art.resize((new_w, new_h), Image.LANCZOS)
    canvas = Image.new("RGBA", (target_w, target_h), (0, 0, 0, 0))
    off_x = (target_w - new_w) // 2
    feet_y = target_h - band       # 脚底线 = 影子带的上沿
    off_y = feet_y - new_h         # 主体底边贴着脚底线
    canvas.alpha_composite(art, (off_x, off_y))
    # 接地影子：椭圆以脚底线为中心，上半截藏在主体后面，下半截露在脚下；
    # 底部故意画到画布下沿之外，保证最后一行 alpha 非零（锚点不变量）。
    sh_w = max(4, int(new_w * 0.7))
    sh_h = band + 4
    shadow = Image.new("RGBA", (target_w, target_h), (0, 0, 0, 0))
    d = ImageDraw.Draw(shadow)
    cx = target_w // 2
    d.ellipse((cx - sh_w // 2, feet_y - sh_h, cx + sh_w // 2, feet_y + sh_h),
              fill=(0, 0, 0, 90))
    shadow = shadow.filter(ImageFilter.GaussianBlur(1.2))
    return Image.alpha_composite(shadow, canvas)


def make_tile(img, size):
    """可平铺纹理：直接缩放到 size，不抠透明、不加影子。"""
    return img.convert("RGB").resize((size, size), Image.LANCZOS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kind", required=True, choices=["char", "prop", "tile"])
    ap.add_argument("--manifest",
                    default=os.path.join(ROOT, "tools", "art_manifest.json"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    with open(args.manifest, "r", encoding="utf-8") as f:
        manifest = json.load(f)
    prefix = manifest["style_prefix"]
    items = [it for it in manifest["items"] if it["kind"] == args.kind]
    if not items:
        print("清单里没有 kind=%s 的条目" % args.kind)
        return 0

    sources = {}
    src_path = os.path.join(ROOT, "assets", "art_sources.json")
    if os.path.exists(src_path):
        with open(src_path, "r", encoding="utf-8") as f:
            sources = json.load(f)

    anchor_url = None
    tmpdir = tempfile.mkdtemp(prefix="artgen_")
    try:
        for it in items:
            out_abs = os.path.join(ROOT, it["out"])
            print("[gen] %s <- %s" % (it["out"], it["prompt"][:60]), flush=True)
            if args.dry_run:
                continue
            os.makedirs(os.path.dirname(out_abs), exist_ok=True)
            ref = it.get("style_ref")
            if ref and anchor_url is None:
                ref_abs = os.path.join(ROOT, ref)
                if os.path.exists(ref_abs):
                    anchor_url = upload_temp_url(ref_abs)

            node_id = generate(prefix + ", " + it["prompt"], anchor_url,
                               os.path.splitext(os.path.basename(it["out"]))[0] + ".jpg")

            if it["kind"] == "tile":
                # 可平铺纹理：抠图反而会吃掉纹理细节，直接缩放
                raw = download(asset_url(node_id), os.path.join(tmpdir, "raw.jpg"))
                img = Image.open(raw)
                size = it["world_size"][0]
                make_tile(img, size).save(out_abs)
                print("[ok] %s (%dx%d)" % (it["out"], size, size), flush=True)
                sources[it["out"]] = {
                    "node_id": node_id,
                    "prompt": prefix + ", " + it["prompt"],
                    "style_ref": ref,
                    "tool": "mcode-tools connector__matrix__generate_image",
                }
                continue

            bg_node = strip_background(asset_url(node_id))
            cut = download(asset_url(bg_node), os.path.join(tmpdir, "cut.png"))
            img = Image.open(cut)
            w, h = it["world_size"]
            tw, th = w * SCALE, h * SCALE
            normalize_sprite(img, tw, th).save(out_abs)
            sources[it["out"]] = {
                "node_id": node_id,
                "bg_node_id": bg_node,
                "prompt": prefix + ", " + it["prompt"],
                "style_ref": ref,
                "tool": "mcode-tools connector__matrix__generate_image + remove_image_background",
            }
            print("[ok] %s (%dx%d)" % (it["out"], tw, th), flush=True)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    if not args.dry_run:
        os.makedirs(os.path.dirname(src_path), exist_ok=True)
        with open(src_path, "w", encoding="utf-8", newline="\n") as f:
            json.dump(sources, f, ensure_ascii=False, indent=2, sort_keys=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
