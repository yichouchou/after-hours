extends SceneTree

## 占位素材冒烟测试：18 个素材必须全部存在、尺寸正确、且能被引擎 load()。
##
## 覆盖范围（与 task-2-brief.md 的产出契约一致）：
##   地面   assets/ground/{ground_grass,ground_path}.png   256x256
##   角色   assets/chars/char_{0..5}.png                   64x64
##   道具   assets/props/prop_{id}.png                      32x32
##
## 注意：load() 在资源未导入时返回 null（本仓库的 *.import 不入库），
## 所以每处断言前先判空，避免空引用报错，并给出可操作的诊断信息。

const GROUND_SIZE := 256
const CHAR_SIZE := 64
const PROP_SIZE := 32

const PROP_IDS := [
	"carrot", "chair", "barrel", "lamp", "sign",
	"pot", "bench", "basket", "dog", "hat",
]


func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var fails := 0
	fails += _check_texture("res://assets/ground/ground_grass.png", GROUND_SIZE)
	fails += _check_texture("res://assets/ground/ground_path.png", GROUND_SIZE)
	for i in 6:
		fails += _check_texture("res://assets/chars/char_%d.png" % i, CHAR_SIZE)
	for prop_id in PROP_IDS:
		fails += _check_texture("res://assets/props/prop_%s.png" % prop_id, PROP_SIZE)
	print("")
	if fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % fails)
		quit(1)


func _check_texture(path: String, size: int) -> int:
	if not FileAccess.file_exists(path):
		return _check(false, "存在 %s" % path)
	var tex: Texture2D = load(path)
	if tex == null:
		return _check(false, "%s 可被引擎加载（资源未导入？先跑一次 --import）" % path)
	var ok := tex.get_width() == size and tex.get_height() == size
	return _check(ok, "%s 是 %dx%d" % [path, size, size])


func _check(ok: bool, what: String) -> int:
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
