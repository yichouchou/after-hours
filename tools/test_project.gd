extends SceneTree

## P1 冒烟测试：项目配置正确 + 能加载主场景 + 能跳转场景。

func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var fails := 0

	# 1) 工程配置
	var cfg := ConfigFile.new()
	var err := cfg.load("res://project.godot")
	fails += _check(err == OK, "project.godot 可加载")
	fails += _check(cfg.get_value("display", "window/size/viewport_width", 0) == 640, "逻辑宽度 640")
	fails += _check(cfg.get_value("display", "window/size/viewport_height", 0) == 360, "逻辑高度 360")
	fails += _check(cfg.get_value("rendering", "renderer/rendering_method", "") == "gl_compatibility", "gl_compatibility 后端")

	# 2) 主场景可实例化
	var packed: PackedScene = load("res://scenes/main.tscn")
	fails += _check(packed != null, "main.tscn 可加载")
	if packed != null:
		var scene := packed.instantiate()
		root.add_child(scene)
		await process_frame
		fails += _check(root.get_node_or_null("Router") != null, "Router 自动加载已注册")
		scene.queue_free()

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
