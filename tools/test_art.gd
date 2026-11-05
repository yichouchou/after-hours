extends SceneTree

## 素材契约测试：所有素材必须存在、尺寸正确、锚点正确、且能被引擎 load()。
##
## 覆盖范围（2x 素材契约，见 docs/superpowers/specs/2026-11-05-art-redesign-design.md）：
##   地面   assets/ground/ground_grass.png / ground_path.png   256x256（可平铺源）
##   地图   assets/ground/map_ground.png                        960x576（烘焙整图）
##   角色   assets/chars/char_{0..5}.png + char_guard.png        128x128
##   道具   assets/props/prop_{id}.png                           按 PROP_SIZE_TABLE
##   灯光   assets/light/lamp_light.png                          256x256
##
## ★ 锚点不变量（角色/道具）：不透明像素必须贴到画布最底边、水平中心居中。
##   素材由 tools/gen_art_ai.py 归一化时强制保证，这条断言把它钉住，
##   以后谁手改素材导致人物浮空 / 偏心，测试立刻报红。
##   灯光贴图不适用（径向渐变的 alpha 包围盒是内切圆，天然不贴边）。
##
## 注意：load() 在资源未导入时返回 null（本仓库的 *.import 不入库），
## 所以每处断言前先判空，避免空引用报错，并给出可操作的诊断信息。

const GROUND_SIZE := 256
const MAP_SIZE := Vector2i(960, 576)
const CHAR_SIZE := 128
const LIGHT_SIZE := 256

## 道具贴图尺寸表（2x：世界尺寸 × 2）。世界尺寸见设计规格 §4.3。
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


func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var fails := 0
	fails += _check_texture("res://assets/ground/ground_grass.png", GROUND_SIZE, GROUND_SIZE)
	fails += _check_texture("res://assets/ground/ground_path.png", GROUND_SIZE, GROUND_SIZE)
	fails += _check_texture("res://assets/ground/map_ground.png", MAP_SIZE.x, MAP_SIZE.y)
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
	print("")
	if fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % fails)
		quit(1)


func _check_texture(path: String, w: int, h: int) -> int:
	if not FileAccess.file_exists(path):
		return _check(false, "存在 %s" % path)
	var tex: Texture2D = load(path)
	if tex == null:
		return _check(false, "%s 可被引擎加载（资源未导入？先跑一次 --import）" % path)
	var ok := tex.get_width() == w and tex.get_height() == h
	return _check(ok, "%s 是 %dx%d" % [path, w, h])


## 美术不变量：不透明像素必须贴到画布最底边、水平中心居中。
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
	# bbox 是排他下界：[minx, miny, maxx+1, maxy+1]
	# → bbox[3] == h 表示最下方的不透明像素就在画布最后一行
	var bottom_ok := int(bbox[3]) == h
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


func _check(ok: bool, what: String) -> int:
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
