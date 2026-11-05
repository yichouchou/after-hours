extends SceneTree

## P1 冒烟测试：工程配置正确 + 能加载主场景 + Router.goto() 跳转行为正确。

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
	fails += _check(cfg.get_value("display", "window/stretch/mode", "") == "canvas_items", "拉伸模式 canvas_items")
	fails += _check(cfg.get_value("rendering", "renderer/rendering_method", "") == "gl_compatibility", "gl_compatibility 后端")
	# 这两项与引擎默认值相同，Godot 编辑器保存 project.godot 时**不再写进文件**，
	# 所以要读**生效值**（ProjectSettings）而不是解析文件文本；否则编辑器改写一次
	# project.godot 就会把这两条断言变成假失败。
	fails += _check(ProjectSettings.get_setting("display/window/stretch/aspect", "") == "keep", "拉伸宽高比 keep")
	fails += _check(ProjectSettings.get_setting("rendering/textures/canvas_textures/default_texture_filter", 0) == 1, "纹理过滤为 Linear(1)")

	# 2) 主场景可实例化 + Router 自动加载已注册
	var packed: PackedScene = load("res://scenes/main.tscn")
	fails += _check(packed != null, "main.tscn 可加载")
	var router = root.get_node_or_null("Router")
	fails += _check(router != null, "Router 自动加载已注册")
	if packed != null:
		var scene := packed.instantiate()
		root.add_child(scene)
		await process_frame
		# 手动挂载的实例必须先摘掉，否则会和新跳进来的 Main 抢名字、污染 current_scene。
		scene.queue_free()
		await process_frame
		await process_frame

	# 3) Router.goto()：跳到真实场景要真的切过去，且不改动 last_skipped_scene
	if router != null:
		var skipped_before: String = router.last_skipped_scene
		router.goto("res://scenes/main.tscn")
		await process_frame
		await process_frame
		fails += _check(current_scene != null, "goto 后 current_scene 非空")
		fails += _check(current_scene != null and current_scene.scene_file_path == "res://scenes/main.tscn",
			"goto 后 current_scene 来自 main.tscn")
		fails += _check(router.last_skipped_scene == skipped_before, "正常跳转不改动 last_skipped_scene")

	# 4) Router.goto()：目标场景不存在时必须安全跳过，并留下可观测记录
	if router != null:
		var before := current_scene
		router.goto("res://scenes/不存在的场景.tscn")
		await process_frame
		await process_frame
		fails += _check(current_scene == before, "goto 不存在的场景不改变 current_scene")
		fails += _check(router.last_skipped_scene == "res://scenes/不存在的场景.tscn",
			"goto 缺失场景时记录 last_skipped_scene")

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
