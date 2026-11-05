# 美术重做实施计划：手绘绘本风（地图 / 人物 / 道具 / 灯光）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把《镇长不在的时候》的地图、人物、道具换成 AI 生成的手绘绘本风素材，并补上 2D 灯光与相机钳制，消除"丑"和地图边缘黑虚空。

**Architecture:** 素材由离线流水线产出（`tools/gen_art_ai.py` 调 mcode-tools 生成 → 抠透明 → PIL 归一化 → 写 `assets/`），地面由离线烘焙产出（`tools/bake_map_ground.py` 合成草地 + 土路 + 边缘压暗 → 单张 `map_ground.png`）。运行时只做最小改动：道具按贴图尺寸自动锚定、角色按朝向左右翻转、每盏灯挂 `PointLight2D`、`CanvasModulate` 做夜色、相机 limit 钳进地图。美术不变量（贴图 alpha 底边贴地、水平居中）由归一化脚本强制保证，并写成测试断言。

**Tech Stack:** Godot 4.7.2.stable（gl_compatibility）、GDScript、Python 3.10 + Pillow 11.3.0、mcode-tools CLI（MiniMax matrix 图像生成 / 抠图）、godot-ai MCP 桥（跑游戏、截图取证）

## Global Constraints

- 引擎固定 `4.7.2.stable`，后端固定 `gl_compatibility`，逻辑分辨率 `640×360`，窗口 `1280×720`，`window/stretch/mode="canvas_items"`
- 素材一律按 **2x 出图**（贴图尺寸 = 世界尺寸 × 2），`Sprite2D.scale = (0.5, 0.5)`；世界里的占位与碰撞不变
- 角色贴图 128×128（世界 64×64）；道具贴图尺寸见规格 §4.3；地面 `map_ground.png` 960×576（1x）；灯光贴图 256×256
- **美术不变量**：每张角色/道具贴图的 alpha 包围盒必须贴到画布最底边、水平中心居中
- `scripts/game/**` 是纯逻辑层：禁止 `get_tree()` / `get_node()` / 场景节点引用
- 守卫朝向走 `facing_angle` 字段，**节点 `rotation` 恒为 0**
- 零失败惩罚：返回值/变量/函数/**注释**里都不得出现 `penalty`/`penalized`/`score`/`score_delta`/`lives`/`lives_lost`/`eliminated`/`damage`/`扣分`/`扣命`/`淘汰`/`死亡`；`hp` 按独立词匹配
- 新文件 UTF-8 **无 BOM** + LF；`.ps1` 必须带 UTF-8 BOM
- 测试入口只有一个：`powershell -ExecutionPolicy Bypass -NoProfile -File tools\run_tests.ps1`；判定通过 = 退出码 0 **且**输出含 `TEST PASSED`
- 端口：测试走 `tools/port_alloc.gd` 动态分配，禁硬编码 270xx；生产默认 28000
- 每个任务结束必须 git commit；**不要 `git add -A`**；不 push
- Godot 不在 PATH：`D:\Godot\Godot_v4.7.2-stable_win64_console.exe`（控制台）、`D:\Godot\Godot_v4.7.2-stable_win64.exe`（GUI）
- 所有 Godot 编辑器侧操作（跑游戏、截图、看日志）走 godot-ai MCP 桥；headless 测试走 `tools/run_tests.ps1`

---

## File Structure

| 文件 | 职责 |
|---|---|
| `tools/art_manifest.json` | 素材清单：每个素材的输出路径、类别、世界尺寸、提示词、风格锚点 |
| `tools/gen_art_ai.py` | 素材流水线：调 mcode-tools 生成 → 抠透明 → PIL 归一化 → 写 `assets/`，并记录 `assets/art_sources.json` |
| `tools/bake_map_ground.py` | 地面烘焙：草地 + 土路 + 边缘压暗 → `assets/ground/map_ground.png` |
| `assets/chars/char_0..5.png` | 6 个村民（128×128） |
| `assets/chars/char_guard.png` | 巡夜守卫（128×128） |
| `assets/props/prop_<tag>.png` | 10 种道具（尺寸见规格 §4.3） |
| `assets/ground/map_ground.png` | 烘焙出的整张地图地面（960×576） |
| `assets/ground/ground_grass.png` / `ground_path.png` | 可平铺源纹理（256×256），烘焙输入 |
| `assets/light/lamp_light.png` | 径向渐变点光源（256×256，程序化生成） |
| `assets/art_sources.json` | 每张素材的 prompt / node_id / 工具名，用于复现与换风格 |

运行时改动（每文件一个明确职责）：

| 文件 | 改动职责 |
|---|---|
| `scripts/mischief_prop.gd` | `apply_texture()` 自动锚定；`_process` 同步灯光可见性与灯的明暗 |
| `scripts/game_scene.gd` | 地面换烘焙图；`_build_props` 走 `apply_texture` 并给灯挂 `PointLight2D`；相机加 limit |
| `scripts/game/interaction.gd` | 新增 `is_lamp_on()` 作为灯亮灭的唯一读取路径 |
| `scripts/guard.gd` | `_lamp_is_on` 委托；按 `facing_angle` 翻转贴图 |
| `scripts/player.gd` | 浮动动画乘基础缩放；按水平速度翻转贴图 |
| `scenes/game.tscn` | 新增 `CanvasModulate` 夜色 |
| `scenes/player.tscn` / `guard.tscn` / `mischief_prop.tscn` | Sprite2D 缩放 0.5；守卫贴图换 `char_guard.png` |

---

### Task 1: 角色素材（7 张）

**Files:**
- Modify: `tools/test_art.gd`（新增角色契约 + 锚点断言）
- Create: `tools/art_manifest.json`
- Create: `tools/gen_art_ai.py`
- Create: `assets/chars/char_0..5.png`、`assets/chars/char_guard.png`
- Create: `assets/art_sources.json`（由脚本生成）

**Interfaces:**
- Consumes: 无（首个任务）
- Produces:
  - `tools/gen_art_ai.py` 的命令行接口：`python tools/gen_art_ai.py --kind char|prop|tile [--manifest tools/art_manifest.json] [--dry-run]`
  - 归一化函数 `normalize_sprite(img: Image, target_w: int, target_h: int) -> Image`，语义：**裁 alpha 包围盒 → 等比缩放到能放进 (target_w, target_h - shadow_band) → 底部居中贴进画面区 → 画面区底部画柔和接地影子 → 保证最后一列/行有非零 alpha**
  - `tools/test_art.gd` 的新契约常量：`CHAR_SIZE := 128`、`CHAR_GUARD := "char_guard.png"`、`PROP_SIZE_TABLE := {...}`、`CHAR_IDS := [...]`

- [ ] **Step 1: 先改测试契约（RED）**

改 `tools/test_art.gd`：

```gdscript
const GROUND_SIZE := 256          # 源纹理仍是 256x256
const MAP_SIZE := Vector2i(960, 576)   # 新增：烘焙出的整图
const CHAR_SIZE := 128            # 2x 素材
const PROP_SIZE_TABLE := {
	"carrot": Vector2i(32, 32),
	"hat": Vector2i(40, 28),
	"basket": Vector2i(52, 40),
	"chair": Vector2i(52, 56),
	"barrel": Vector2i(52, 60),
	"lamp": Vector2i(44, 112),
	"bench": Vector2i(112, 48),
	"pot": Vector2i(48, 48),
	"sign": Vector2i(44, 80),
	"dog": Vector2i(60, 44),
}
const LIGHT_SIZE := 256
```

把 `_boot()` 里的素材断言整体换成（**注意：地面那两行也要补上第三个参数**，因为 `_check_texture` 改成三参了；另外删掉旧的 `PROP_IDS` 常量，改用 `PROP_SIZE_TABLE`）：

```gdscript
	fails += _check_texture("res://assets/ground/ground_grass.png", GROUND_SIZE, GROUND_SIZE)
	fails += _check_texture("res://assets/ground/ground_path.png", GROUND_SIZE, GROUND_SIZE)
	for i in 6:
		fails += _check_texture("res://assets/chars/char_%d.png" % i, CHAR_SIZE, CHAR_SIZE)
		fails += _check_anchor("res://assets/chars/char_%d.png" % i)
	fails += _check_texture("res://assets/chars/char_guard.png", CHAR_SIZE, CHAR_SIZE)
	fails += _check_anchor("res://assets/chars/char_guard.png")
	for tag in PROP_SIZE_TABLE:
		var sz: Vector2i = PROP_SIZE_TABLE[tag]
		fails += _check_texture("res://assets/props/prop_%s.png" % tag, sz.x, sz.y)
		fails += _check_anchor("res://assets/props/prop_%s.png" % tag)
	fails += _check_texture("res://assets/light/lamp_light.png", LIGHT_SIZE, LIGHT_SIZE)
```

并把 `_check_texture` 改成支持非方形尺寸：

```gdscript
func _check_texture(path: String, w: int, h: int) -> int:
	if not FileAccess.file_exists(path):
		return _check(false, "存在 %s" % path)
	var tex: Texture2D = load(path)
	if tex == null:
		return _check(false, "%s 可被引擎加载（资源未导入？先跑一次 --import）" % path)
	var ok := tex.get_width() == w and tex.get_height() == h
	return _check(ok, "%s 是 %dx%d" % [path, w, h])
```

再追加**锚点断言**（把美术不变量变成测试）。锚点只适用于角色与道具，**不适用于灯光贴图**（径向渐变的 alpha 包围盒是内切圆，天然不贴边）：

```gdscript
## 美术不变量：不透明像素必须贴到画布最底边、水平中心居中。
## （灯光贴图不适用 —— 径向渐变的 alpha 包围盒是内切圆，天然不贴边。）
func _check_anchor(path: String) -> int:
	if not FileAccess.file_exists(path):
		return _check(false, "锚点：存在 %s" % path)
	var tex: Texture2D = load(path)
	if tex == null:
		return _check(false, "锚点：%s 可加载" % path)
	var img := tex.get_image()
	if img == null:
		return _check(false, "锚点：%s 能取到图像" % path)
	var bbox := _alpha_bbox(img)
	if bbox.is_empty():
		return _check(false, "锚点：%s 有不透明像素" % path)
	var w := img.get_width()
	var h := img.get_height()
	var bottom_ok := int(bbox[3]) == h - 1
	var center_ok := absf((float(bbox[0]) + float(bbox[2])) * 0.5 - float(w) * 0.5) <= 2.0
	return _check(bottom_ok and center_ok,
		"锚点：%s 底边贴地+中心居中（bbox %s，画布 %dx%d）" % [path, str(bbox), w, h])


## 不透明像素的包围盒 [minx, miny, maxx, maxy]（整张透明 → 空数组）。
func _alpha_bbox(img: Image) -> Array:
	if img == null:
		return []
	var minx := img.get_width()
	var miny := img.get_height()
	var maxx := -1
	var maxy := -1
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.0:
				minx = mini(minx, x)
				miny = mini(miny, y)
				maxx = maxi(maxx, x)
				maxy = maxi(maxy, y)
	if maxx < 0:
		return []
	return [minx, miny, maxx + 1, maxy + 1]
```

- [ ] **Step 2: 跑测试确认 RED**

```powershell
& 'D:\Godot\Godot_v4.7.2-stable_win64_console.exe' --headless --path D:\GodotProjects\after-hours --import
& 'D:\Godot\Godot_v4.7.2-stable_win64_console.exe' --headless --path D:\GodotProjects\after-hours --quit-after 600 --script 'res://tools/test_art.gd'
```

预期：FAIL（`char_0.png` 是 64×64 不是 128×128；`char_guard.png` 不存在）。

- [ ] **Step 3: 写素材清单 `tools/art_manifest.json`**

```json
{
  "style_prefix": "hand-drawn children's picture book style game sprite, warm gouache texture, clean dark outline, flat muted colors, soft lighting, single object centered, plain white background, no shadow, no text, no extra objects",
  "items": [
    {"out": "assets/chars/char_0.png", "kind": "char", "world_size": [64, 64], "prompt": "a chibi villager in a red hooded jacket, full body standing, facing right", "style_ref": null, "anchor": "feet"},
    {"out": "assets/chars/char_1.png", "kind": "char", "world_size": [64, 64], "prompt": "a chibi villager in a blue coat, full body standing, facing right", "style_ref": "assets/chars/char_0.png", "anchor": "feet"},
    {"out": "assets/chars/char_2.png", "kind": "char", "world_size": [64, 64], "prompt": "a chibi villager in a green sweater, full body standing, facing right", "style_ref": "assets/chars/char_0.png", "anchor": "feet"},
    {"out": "assets/chars/char_3.png", "kind": "char", "world_size": [64, 64], "prompt": "a chibi villager in a yellow raincoat, full body standing, facing right", "style_ref": "assets/chars/char_0.png", "anchor": "feet"},
    {"out": "assets/chars/char_4.png", "kind": "char", "world_size": [64, 64], "prompt": "a chibi villager in a purple dress, full body standing, facing right", "style_ref": "assets/chars/char_0.png", "anchor": "feet"},
    {"out": "assets/chars/char_5.png", "kind": "char", "world_size": [64, 64], "prompt": "a chibi villager in a brown apron, full body standing, facing right", "style_ref": "assets/chars/char_0.png", "anchor": "feet"},
    {"out": "assets/chars/char_guard.png", "kind": "char", "world_size": [64, 64], "prompt": "a chibi night watchman guard in a dark blue uniform with a peaked cap, holding a lantern, full body standing, facing right", "style_ref": "assets/chars/char_0.png", "anchor": "feet"}
  ]
}
```

- [ ] **Step 4: 写流水线脚本 `tools/gen_art_ai.py`**

```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AI 素材流水线：清单 -> 生成 -> 抠透明 -> 归一化 -> 写 assets/。

用法：
    python tools/gen_art_ai.py --kind char      # 只跑角色
    python tools/gen_art_ai.py --kind prop
    python tools/gen_art_ai.py --kind tile
    python tools/gen_art_ai.py --dry-run        # 只打印将要做什么

依赖：mcode-tools CLI（MiniMax matrix 图像生成 + 抠图）、Pillow。
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCALE = 2                 # 素材按 2x 出图
SHADOW_BAND_RATIO = 0.08  # 画面区底部留给接地影子


def run(args, stdin_text=None):
    """跑一条命令，返回 (returncode, stdout)。"""
    proc = subprocess.run(args, input=stdin_text, capture_output=True, text=True,
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
    code, out = run(["powershell", "-NoProfile", "-Command",
                     "Invoke-WebRequest -Uri '%s' -OutFile '%s' -UseBasicParsing" % (url, dest)])
    if code != 0:
        raise RuntimeError("下载失败 %s：%s" % (url, out.strip()))
    return dest


def generate(prompt, style_ref_url, out_file):
    req = {"prompt": prompt, "aspect_ratio": "1:1", "resolution": "1K", "output_file": out_file}
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
                         "connector__matrix__remove_image_background", "--args-file", path])
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
    out = Image.alpha_composite(shadow, canvas)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kind", required=True, choices=["char", "prop", "tile"])
    ap.add_argument("--manifest", default=os.path.join(ROOT, "tools", "art_manifest.json"))
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
    for it in items:
        out_abs = os.path.join(ROOT, it["out"])
        print("[gen] %s <- %s" % (it["out"], it["prompt"][:60]))
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
        raw = download(asset_url(node_id), out_abs + ".raw.jpg")
        bg_node = strip_background(asset_url(node_id))
        cut = download(asset_url(bg_node), out_abs + ".cut.png")
        img = Image.open(cut)
        w, h = it["world_size"]
        tw, th = w * SCALE, h * SCALE
        out = normalize_sprite(img, tw, th)
        out.save(out_abs)
        sources[it["out"]] = {
            "node_id": node_id,
            "bg_node_id": bg_node,
            "prompt": prefix + ", " + it["prompt"],
            "style_ref": ref,
            "tool": "mcode-tools connector__matrix__generate_image + remove_image_background",
        }
        print("[ok] %s (%dx%d)" % (it["out"], tw, th))

    if not args.dry_run:
        os.makedirs(os.path.dirname(src_path), exist_ok=True)
        with open(src_path, "w", encoding="utf-8", newline="\n") as f:
            json.dump(sources, f, ensure_ascii=False, indent=2, sort_keys=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

注意：脚本里 `normalize_sprite` 需要 `from PIL import Image, ImageDraw, ImageFilter`（把 import 行改成这三个）。

- [ ] **Step 5: 跑流水线生成角色**

```powershell
cd D:\GodotProjects\after-hours
python tools\gen_art_ai.py --kind char
```

预期：7 张 `char_*.png` 落到 `assets/chars/`，`assets/art_sources.json` 生成。若某张明显跑偏（主体太小/被裁掉/不是全身），单独重跑该条目：把该条目的 `prompt` 微调后再次执行 `--kind char`（会重跑全部 7 张，可接受）。

- [ ] **Step 6: 肉眼检查 7 张角色**

```powershell
python -c "from PIL import Image; import os; p=r'D:\GodotProjects\after-hours\assets\chars'; names=sorted(os.listdir(p)); names=[n for n in names if n.endswith('.png')]; sheet=Image.new('RGBA',(128*len(names),128),(30,32,42)); [sheet.alpha_composite(Image.open(os.path.join(p,n)),(i*128,0)) for i,n in enumerate(names)]; sheet.convert('RGB').save(r'D:\GodotProjects\after-hours\..\sheet_chars.png')"
```

把 sheet 读图确认：每个角色都是**全身 Q 版、单主体、白底已抠净**，且 6 个村民之间能靠衣服颜色区分、守卫明显是制服+帽子。

- [ ] **Step 7: 跑测试确认 GREEN**

```powershell
& 'D:\Godot\Godot_v4.7.2-stable_win64_console.exe' --headless --path D:\GodotProjects\after-hours --import
& 'D:\Godot\Godot_v4.7.2-stable_win64_console.exe' --headless --path D:\GodotProjects\after-hours --quit-after 600 --script 'res://tools/test_art.gd'
```

预期：`test_art.gd` 仍会因**道具与灯光贴图尚未产出**而 FAIL，但角色相关断言必须 PASS。

- [ ] **Step 8: 提交**

```powershell
git add -- tools/test_art.gd tools/art_manifest.json tools/gen_art_ai.py assets/chars assets/art_sources.json
git commit -m "feat: 角色换成 AI 手绘绘本风素材（2x 契约 + 锚点不变量）"
```

---

### Task 2: 道具素材（10 张）

**Files:**
- Modify: `tools/art_manifest.json`（追加 10 条 `prop`）
- Create: `assets/props/prop_<tag>.png`（由流水线产出）
- Create: `assets/light/lamp_light.png`（程序化生成，不走 AI）

**Interfaces:**
- Consumes: Task 1 的 `tools/gen_art_ai.py` 与风格锚点 `assets/chars/char_0.png`
- Produces: 10 张道具贴图 + `assets/light/lamp_light.png`

- [ ] **Step 1: 清单追加道具条目**

在 `items` 里追加（世界尺寸 = 规格 §4.3 的世界尺寸，贴图 = ×2 由脚本算）：

```json
{"out": "assets/props/prop_carrot.png", "kind": "prop", "world_size": [16, 16], "prompt": "a single orange carrot with green leaves lying on the ground, small", "style_ref": "assets/chars/char_0.png", "anchor": "feet"},
{"out": "assets/props/prop_hat.png", "kind": "prop", "world_size": [20, 14], "prompt": "a single brown fedora hat, small", "style_ref": "assets/chars/char_0.png", "anchor": "feet"},
{"out": "assets/props/prop_basket.png", "kind": "prop", "world_size": [26, 20], "prompt": "a single woven wicker basket, small", "style_ref": "assets/chars/char_0.png", "anchor": "feet"},
{"out": "assets/props/prop_chair.png", "kind": "prop", "world_size": [26, 28], "prompt": "a single wooden chair seen from a three-quarter view, small", "style_ref": "assets/chars/char_0.png", "anchor": "feet"},
{"out": "assets/props/prop_barrel.png", "kind": "prop", "world_size": [26, 30], "prompt": "a single wooden barrel, three-quarter view, small", "style_ref": "assets/chars/char_0.png", "anchor": "feet"},
{"out": "assets/props/prop_lamp.png", "kind": "prop", "world_size": [22, 56], "prompt": "a single tall vintage street lamp post with a glowing lantern on top, full lamp, small", "style_ref": "assets/chars/char_0.png", "anchor": "feet"},
{"out": "assets/props/prop_bench.png", "kind": "prop", "world_size": [56, 24], "prompt": "a single long wooden park bench seen from the side, small", "style_ref": "assets/chars/char_0.png", "anchor": "feet"},
{"out": "assets/props/prop_pot.png", "kind": "prop", "world_size": [24, 24], "prompt": "a single terracotta flower pot with a small plant, small", "style_ref": "assets/chars/char_0.png", "anchor": "feet"},
{"out": "assets/props/prop_sign.png", "kind": "prop", "world_size": [22, 40], "prompt": "a single wooden notice board sign on a post, small", "style_ref": "assets/chars/char_0.png", "anchor": "feet"},
{"out": "assets/props/prop_dog.png", "kind": "prop", "world_size": [30, 22], "prompt": "a single small brown dog sitting, small", "style_ref": "assets/chars/char_0.png", "anchor": "feet"}
```

- [ ] **Step 2: 生成道具**

```powershell
python tools\gen_art_ai.py --kind prop
```

- [ ] **Step 3: 程序化生成灯光贴图**

```powershell
python -c "from PIL import Image; import math,os; S=256; im=Image.new('RGBA',(S,S),(0,0,0,0)); px=im.load(); c=(S-1)/2.0; [px.__setitem__((x,y), (255,236,190, int(255*max(0.0,1.0-math.hypot(x-c,y-c)/(S/2.0))**2.0))) for y in range(S) for x in range(S)]; os.makedirs(r'D:\GodotProjects\after-hours\assets\light',exist_ok=True); im.save(r'D:\GodotProjects\after-hours\assets\light\lamp_light.png')"
```

- [ ] **Step 4: 肉眼检查 10 张道具**

生成 contact sheet（把 10 张按名字排开）并读图确认：每种道具**外形可辨认**（胡萝卜是胡萝卜、木桶是木桶、路灯是灯柱），不是同一个椭圆换色。

- [ ] **Step 5: 跑测试确认 GREEN**

```powershell
& 'D:\Godot\Godot_v4.7.2-stable_win64_console.exe' --headless --path D:\GodotProjects\after-hours --import
& 'D:\Godot\Godot_v4.7.2-stable_win64_console.exe' --headless --path D:\GodotProjects\after-hours --quit-after 600 --script 'res://tools/test_art.gd'
```

预期：`TEST PASSED`（角色 + 道具 + 灯光贴图契约全过；地面断言仍是旧的 256×256，下个任务才改）。

- [ ] **Step 6: 提交**

```powershell
git add -- tools/art_manifest.json assets/props assets/light assets/art_sources.json
git commit -m "feat: 10 种道具换成手绘绘本风素材（自然尺寸）+ 点光源贴图"
```

---

### Task 3: 地面土路 + 相机钳制

**Files:**
- Modify: `data/map.json`（新增 `paths` 段）
- Create: `tools/bake_map_ground.py`
- Create: `assets/ground/map_ground.png`（960×576）
- Modify: `scripts/game_scene.gd`（`GROUND_TEXTURE` + 相机 limit）
- Modify: `tools/test_art.gd`（地面契约改 960×576 + 保留两个 256×256 源纹理断言）
- Modify: `tools/test_game_scene.gd`（新增相机 limit 断言）

**Interfaces:**
- Consumes: Task 2 的 `assets/ground/ground_grass.png` / `ground_path.png`（256×256 源纹理，本任务先补生成）
- Produces: `assets/ground/map_ground.png`；`data/map.json` 的 `paths` 段（格式 `[[格x, 格y, 宽, 高], ...]`）

- [ ] **Step 1: 先改测试契约（RED）**

`tools/test_art.gd`：把地面断言改成

```gdscript
	fails += _check_texture("res://assets/ground/ground_grass.png", GROUND_SIZE, GROUND_SIZE)
	fails += _check_texture("res://assets/ground/ground_path.png", GROUND_SIZE, GROUND_SIZE)
	fails += _check_texture("res://assets/ground/map_ground.png", MAP_SIZE.x, MAP_SIZE.y)
```

`tools/test_game_scene.gd`：在地面断言附近加相机钳制断言：

```gdscript
	# 相机必须钳在地图内（否则玩家贴边时看到黑虚空）
	# 源码级断言（仓库既有惯例，见 [§4-17]）+ 运行时断言（场景里真有相机时）
	_fails += _check(game_src.contains("limit_left") and game_src.contains("limit_right")
			and game_src.contains("limit_bottom"),
		"[§4-3] game_scene.gd 给相机设了 limit_left/right/bottom")
	var cam: Camera2D = null
	if players_root != null:
		for c in players_root.get_children():
			var cc := c.get_node_or_null("Camera2D") as Camera2D
			if cc != null:
				cam = cc
				break
	if cam != null:
		_fails += _check(cam.limit_left == 0 and cam.limit_top == 0
				and cam.limit_right == 960 and cam.limit_bottom == 576,
			"[§4-3] 相机 limit 钳在地图 960x576 内（实际 %d/%d/%d/%d）"
			% [cam.limit_left, cam.limit_top, cam.limit_right, cam.limit_bottom])
```

- [ ] **Step 2: 跑测试确认 RED**

预期：`map_ground.png` 不存在 → FAIL；相机 limit 断言 FAIL。

- [ ] **Step 3: 给清单加两张 tile 并生成**

```json
{"out": "assets/ground/ground_grass.png", "kind": "tile", "world_size": [256, 256], "prompt": "a seamless tileable top-down night meadow, deep blue-green grass, hand-drawn children book texture, viewed straight from above", "style_ref": null, "anchor": "none"},
{"out": "assets/ground/ground_path.png", "kind": "tile", "world_size": [256, 256], "prompt": "a seamless tileable top-down dirt path, warm brown packed earth, hand-drawn children book texture, viewed straight from above", "style_ref": "assets/ground/ground_grass.png", "anchor": "none"}
```

`kind = "tile"` 时脚本**不做锚点归一化**，只抠透明 + 缩放到 256×256（tile 不需要透明，抠图反而可能吃掉纹理细节 —— 因此脚本对 tile 走"不抠图、直接缩放"分支）。

```powershell
python tools\gen_art_ai.py --kind tile
```

- [ ] **Step 4: `data/map.json` 加 paths 段**

```json
{
  "size": [30, 18],
  "paths": [
    [1, 9, 14, 2],
    [13, 1, 2, 9],
    [23, 3, 2, 6],
    [21, 11, 2, 3]
  ],
  "props": { ...原样不动... }
}
```

- [ ] **Step 5: 写 `tools/bake_map_ground.py` 并烘焙**

```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把草地 + 土路 + 边缘压暗烘焙成一张整图地面（960x576）。

输入：assets/ground/ground_grass.png、ground_path.png（各 256x256 可平铺）
      data/map.json 的 paths 段（[[格x, 格y, 宽, 高], ...]，单位=格）
输出：assets/ground/map_ground.png
"""
import json
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TILE = 32
MAP_W, MAP_H = 30 * TILE, 18 * TILE
EDGE = 24          # 边缘压暗宽度（px）
EDGE_DARK = 0.35   # 边缘最暗处亮度系数


def main():
    grass = Image.open(os.path.join(ROOT, "assets", "ground", "ground_grass.png")).convert("RGB")
    path_tex = Image.open(os.path.join(ROOT, "assets", "ground", "ground_path.png")).convert("RGB")
    with open(os.path.join(ROOT, "data", "map.json"), "r", encoding="utf-8") as f:
        data = json.load(f)

    ground = Image.new("RGB", (MAP_W, MAP_H))
    for oy in range(0, MAP_H, 256):
        for ox in range(0, MAP_W, 256):
            tile = grass.crop((0, 0, min(256, MAP_W - ox), min(256, MAP_H - oy)))
            ground.paste(tile, (ox, oy))

    # 土路：先铺矩形路面，再用噪声只在**边缘带**啃出不规则轮廓
    mask = Image.new("L", (MAP_W, MAP_H), 0)
    md = ImageDraw.Draw(mask)
    for seg in data.get("paths", []):
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
            out_data[i] = 255 if ndata[i] > 90 else 0   # 边缘带：用噪声啃出毛边
    mask = Image.frombytes("L", (MAP_W, MAP_H), bytes(out_data))

    road_rgb = Image.new("RGB", (MAP_W, MAP_H))
    for oy in range(0, MAP_H, 256):
        for ox in range(0, MAP_W, 256):
            tile = path_tex.crop((0, 0, min(256, MAP_W - ox), min(256, MAP_H - oy)))
            road_rgb.paste(tile, (ox, oy))
    ground.paste(road_rgb, (0, 0), mask)

    # 边缘压暗：越靠边越暗，EDGE 像素内从 EDGE_DARK 过渡到全亮
    vign = Image.new("L", (MAP_W, MAP_H))
    vp = vign.load()
    for y in range(MAP_H):
        for x in range(MAP_W):
            d = min(x, y, MAP_W - 1 - x, MAP_H - 1 - y)
            t = min(1.0, d / float(EDGE))
            vp[x, y] = int(255 * (EDGE_DARK + (1.0 - EDGE_DARK) * t))
    vign = vign.filter(ImageFilter.GaussianBlur(3))
    dark = Image.new("RGB", (MAP_W, MAP_H), (10, 12, 22))
    ground = Image.composite(ground, dark, vign)

    out = os.path.join(ROOT, "assets", "ground", "map_ground.png")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    ground.save(out)
    print("baked", out, ground.size)


if __name__ == "__main__":
    main()
```

- [ ] **Step 6: 改 `scripts/game_scene.gd`**

1) 常量：`const GROUND_TEXTURE := "res://assets/ground/ground_grass.png"` → `"res://assets/ground/map_ground.png"`
2) `_attach_camera(player)` 里创建 Camera2D 后加：

```gdscript
	cam.limit_left = 0
	cam.limit_top = 0
	cam.limit_right = 960    # 30 格 × 32 px
	cam.limit_bottom = 576   # 18 格 × 32 px
```

（地图尺寸常量见 `game_scene.gd` 的 `GUARD_HOME` 附近；若别处已有地图尺寸变量则改用它，注释写明来源是 30×18 格 × 32px。）

- [ ] **Step 7: 跑测试确认 GREEN**

```powershell
& 'D:\Godot\Godot_v4.7.2-stable_win64_console.exe' --headless --path D:\GodotProjects\after-hours --import
powershell -ExecutionPolicy Bypass -NoProfile -File tools\run_tests.ps1
```

预期：16 个测试全绿。

- [ ] **Step 8: 提交**

```powershell
git add -- data/map.json tools/bake_map_ground.py tools/test_art.gd tools/test_game_scene.gd scripts/game_scene.gd assets/ground
git commit -m "feat: 地面烘焙成手绘土路整图，相机钳进地图消除黑虚空"
```

---

### Task 4: 运行时改造（锚定 / 翻转 / 灯光 / 夜色）

**Files:**
- Modify: `scripts/game/interaction.gd`（`is_lamp_on`）
- Modify: `scripts/guard.gd`（委托 + 翻转）
- Modify: `scripts/player.gd`（缩放 + 翻转）
- Modify: `scripts/mischief_prop.gd`（`apply_texture` + 灯光同步）
- Modify: `scripts/game_scene.gd`（`apply_texture` + 挂 `PointLight2D`）
- Modify: `scenes/game.tscn`（`CanvasModulate`）
- Modify: `scenes/player.tscn`、`scenes/guard.tscn`、`scenes/mischief_prop.tscn`
- Modify: `tools/test_player.gd`、`tools/test_guard_flow.gd`、`tools/test_interaction.gd`

**Interfaces:**
- Consumes: Task 3 的 `map_ground.png`、Task 1/2 的 2x 素材
- Produces:
  - `Interaction.is_lamp_on(node: Node) -> bool`
  - `MischiefProp.apply_texture(tex: Texture2D) -> void`

- [ ] **Step 1: 先改测试契约（RED）**

`tools/test_player.gd`：`const ALPHA_CENTER_X := 32.0` → `64.0`，`const ALPHA_BOTTOM := 64.0` → `128.0`（2x 贴图；不变量语义不变）。

`tools/test_guard_flow.gd`：同样把 `ALPHA_CENTER_X` 改 64、`ALPHA_BOTTOM` 改 128。

`tools/test_interaction.gd`：[§4-14] 的

```gdscript
			_fails += _check(is_equal_approx(rect.size.y, PROP_TEXTURE_SIZE),
				"[§4-14] 道具贴图 32x32（实测 %.0f）" % rect.size.y)
```

改为动态尺寸 + 灯灭时灯光隐藏：

```gdscript
			var tex := sprite.texture
			var expect_h := float(tex.get_height()) if tex != null else 0.0
			_fails += _check(is_equal_approx(rect.size.y, expect_h) and expect_h > 0.0,
				"[§4-14] 道具贴图高度 = 实际贴图高度（实测 %.0f，期望 %.0f）" % [rect.size.y, expect_h])
			_fails += _check(is_equal_approx(rect.position.y + rect.size.y, 0.0),
				"[§4-14] **图片**下沿落在地面 y = 0（rect %s）" % str(rect))
```

并新增一条：灯灭后灯光节点不可见（在 [§4-16] 段末尾追加）

```gdscript
	# 熄灯后灯光必须真的消失（画面与玩法一致）
	var light := lamp_prop.get_node_or_null("PointLight2D") as PointLight2D
	if light != null:
		_fails += _check(not light.visible,
			"[§4-16] 熄灯后对应的 PointLight2D 不可见")
```

- [ ] **Step 2: 跑测试确认 RED**

预期：`test_player.gd` / `test_guard_flow.gd` 因 alpha 常量与 64×64 贴图不匹配而 FAIL；`test_interaction.gd` 的道具高度断言 FAIL。

- [ ] **Step 3: `scripts/game/interaction.gd` 新增唯一读取路径**

```gdscript
## 这盏灯亮着吗？亮着 → true。
##
## ★ 读取契约（Task 9 定，优先级从高到低）：
##   meta "lamp_on" → 属性 lamp_on → 都没有就当亮着。
##   本函数是**唯一**的读取路径：守卫的视野计算与灯光显示都调它。
static func is_lamp_on(node: Node) -> bool:
	if node == null:
		return true
	if node.has_meta("lamp_on"):
		return bool(node.get_meta("lamp_on", true))
	for p in node.get_property_list():
		if str(p.get("name", "")) == "lamp_on":
			return bool(node.get("lamp_on"))
	return true
```

- [ ] **Step 4: `scripts/guard.gd` 委托 + 翻转**

把 `_lamp_is_on` 的函数体换成：

```gdscript
## 这盏灯亮着吗？亮着 → true。读取路径收口到 Interaction.is_lamp_on()。
func _lamp_is_on(n: Node) -> bool:
	return Interaction.is_lamp_on(n)
```

并在 `_physics_process`（或已有的每帧逻辑）里加翻转：

```gdscript
	# 朝向决定贴图左右翻转。**只改 flip_h，绝不改节点 rotation**。
	var want_flip := facing.x < -0.35
	if want_flip != sprite.flip_h:
		_flip_hold += delta
		if _flip_hold >= 0.15:
			sprite.flip_h = want_flip
			_flip_hold = 0.0
	else:
		_flip_hold = 0.0
```

并在成员变量区加 `var _flip_hold := 0.0`。

- [ ] **Step 5: `scripts/player.gd` 缩放 + 翻转**

加常量 `const SPRITE_SCALE := 0.5`，把浮动动画里的

```gdscript
	sprite.scale = Vector2(1.0 + sin(_bob * 2.0) * 0.04, 1.0 - sin(_bob * 2.0) * 0.04)
```

改成

```gdscript
	sprite.scale = Vector2.ONE * SPRITE_SCALE * Vector2(1.0 + sin(_bob * 2.0) * 0.04, 1.0 - sin(_bob * 2.0) * 0.04)
```

并把复位处 `sprite.scale = Vector2.ONE` 改成 `sprite.scale = Vector2.ONE * SPRITE_SCALE`。

翻转（按水平速度）：

```gdscript
	# 水平速度决定贴图左右翻转（|vx| > 8 才翻，翻转后 0.15s 滞回防抖）
	var want_flip := velocity.x < -8.0
	if want_flip != sprite.flip_h:
		_flip_hold += delta
		if _flip_hold >= 0.15:
			sprite.flip_h = want_flip
			_flip_hold = 0.0
	else:
		_flip_hold = 0.0
```

加成员 `var _flip_hold := 0.0`。

- [ ] **Step 6: `scripts/mischief_prop.gd` 自动锚定 + 灯光同步**

```gdscript
## ★ 素材按 2x 出图（贴图尺寸 = 世界尺寸 × 2），Sprite2D 用 scale 0.5 回到世界尺寸。
##   自动锚定：offset = (-w/2, -h) → 水平居中、底边贴地（对任意尺寸都成立）。
func apply_texture(tex: Texture2D) -> void:
	if tex == null:
		return
	var sprite := get_node_or_null("Sprite2D") as Sprite2D
	if sprite == null:
		return
	sprite.texture = tex
	sprite.offset = Vector2(-tex.get_width() * 0.5, -tex.get_height())
```

```gdscript
## 灯的亮灭同步到画面：灯灭 → 灯光不可见 + 贴图压暗。
func _process(_delta: float) -> void:
	var light := get_node_or_null("PointLight2D") as PointLight2D
	if light == null:
		return
	var on := Interaction.is_lamp_on(self)
	light.visible = on
	var sprite := get_node_or_null("Sprite2D") as Sprite2D
	if sprite != null:
		sprite.modulate = Color.WHITE if on else Color(0.55, 0.55, 0.65)
```

- [ ] **Step 7: `scripts/game_scene.gd` 应用素材 + 挂灯光**

`_build_props` 里把贴图赋值那段改成：

```gdscript
		var tex := load(PROP_TEXTURE_FORMAT % String(tag))
		if tex != null:
			p.call(&"apply_texture", tex)
		if StringName(str(tag)) == &"lamp":
			var light := PointLight2D.new()
			light.name = "PointLight2D"
			light.texture = load(LIGHT_TEXTURE)
			light.color = Color(1.0, 0.92, 0.72)
			light.texture_scale = 0.95
			light.position = Vector2(0, -48)   # 灯泡高度（灯贴图 44x112 → 灯泡在顶部）
			p.add_child(light)
```

并加常量 `const LIGHT_TEXTURE := "res://assets/light/lamp_light.png"`。

- [ ] **Step 8: 场景文件**

`scenes/player.tscn`、`scenes/guard.tscn`、`scenes/mischief_prop.tscn` 的 `Sprite2D` 节点加 `scale = Vector2(0.5, 0.5)`；`scenes/guard.tscn` 的贴图改成 `res://assets/chars/char_guard.png`。

`scenes/game.tscn` 加夜色节点：

```
[node name="Night" type="CanvasModulate" parent="."]
color = Color(0.7, 0.72, 0.88, 1)
```

- [ ] **Step 9: 跑全量测试确认 GREEN**

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File tools\run_tests.ps1
```

预期：16 个测试全绿。

- [ ] **Step 10: 提交**

```powershell
git add -- scripts scenes tools/test_player.gd tools/test_guard_flow.gd tools/test_interaction.gd
git commit -m "feat: 素材自动锚定、角色左右翻转、路灯真发光 + 夜色"
```

---

### Task 5: 实机验收与对比取证

**Files:**
- Modify: `docs/gameplay-guide.md`（若外观描述需要同步）
- Create: `docs/superpowers/plans/2026-11-05-art-redesign/shot_after.png`（对比截图）

**Interfaces:**
- Consumes: Task 1-4 的全部产出
- Produces: 改造后实机截图，供用户验收

- [ ] **Step 1: 用 godot-ai 桥跑游戏并抓同机位截图**

```text
mcp__godot-ai__project_run(mode="main")
mcp__godot-ai__editor_manage(op="game_eval", params={code:"<切到 game.tscn → 等帧 → 存 PNG>"})
```

对照基准是改造前的 `probe_out/art_before_01.png`（玩家出生点机位）。

- [ ] **Step 2: 逐条核对验收标准**

- 地图边缘无黑虚空 ✔（相机钳制）
- 10 种道具外形可辨认 ✔（肉眼看截图）
- 玩家移动时左右翻转、守卫转身不翻倒 ✔（`rotation` 恒 0）
- 熄灯后光池消失、场景变暗；HUD 清单文字仍清晰 ✔

- [ ] **Step 3: 若 `gl_compatibility` 下 2D 灯光不生效**

回退：删掉 `scenes/game.tscn` 的 `CanvasModulate` 与 `PointLight2D`，改为在 `tools/bake_map_ground.py` 里把灯位画成亮斑（半径 120px 的暖色渐变叠在地面图上），并在 `docs/gameplay-guide.md` 里注明"熄灯只影响守卫视野，不改变画面亮度"。

- [ ] **Step 4: 提交**

```powershell
git add -- docs
git commit -m "docs: 美术改造后的实机验收截图与说明同步"
```

---

## 验收总表

| 规格条目 | 落在哪个任务 |
|---|---|
| §3 AI 生成 + 风格锚点 + 抠图归一化 | Task 1、Task 2 |
| §4.2 角色 128×128 + char_guard | Task 1 |
| §4.3 道具自然尺寸 2x | Task 2 |
| §4.4 map_ground 960×576 + lamp_light 256×256 | Task 2、Task 3 |
| §4.5 接地影子 | Task 1（`normalize_sprite` 内置） |
| §5 土路 + paths 段 | Task 3 |
| §6 2D 灯光 + 夜色 + 读取路径收口 | Task 4 |
| §7 代码改动 12 项 | Task 3、Task 4 |
| §8 测试契约 4 个文件 | Task 1、Task 2、Task 3、Task 4 |
| §9 验收标准 7 条 | Task 5 |
| §10 风险与对策 | Task 5（灯光回退）+ 各任务的兜底步骤 |
| §11 实施批次 4 批 | Task 1-4 恰好对应四批 |
