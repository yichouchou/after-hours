extends SceneTree

func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var fails := 0
	for i in 6:
		var p := "res://assets/chars/char_%d.png" % i
		fails += _check(FileAccess.file_exists(p), "存在 %s" % p)
		if FileAccess.file_exists(p):
			var tex: Texture2D = load(p)
			fails += _check(tex != null and tex.get_width() == 64 and tex.get_height() == 64,
				"char_%d.png 是 64x64" % i)
	for n in ["ground_grass", "ground_path"]:
		var p2 := "res://assets/ground/%s.png" % n
		fails += _check(FileAccess.file_exists(p2), "存在 %s" % p2)
	print("")
	if fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % fails)
		quit(1)


func _check(ok: bool, what: String) -> int:
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
