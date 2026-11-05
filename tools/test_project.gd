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

	# 5) 输入映射：方向键**和 WASD** 都能走（用户报障：只有方向键能走）
	#
	# ★ 引擎内置的 ui_* 动作默认**只有方向键** → 玩家按 WASD 一点反应都没有。
	#   → 给这四个动作**补上** WASD（project.godot 的 [input] 段）。
	# ★ 断言两件事，缺一不可：
	#   方向键**仍然在**（不能被 WASD 顶掉 —— 顶掉就把老玩家坑了）；
	#   WASD **也在**（这才是本次要修的）。
	# ★ 查的是 InputMap 的**生效状态**（不是解析 project.godot 文本）——
	#   内置动作的默认值不在文件里，只查文件会得出"没绑"的假结论。
	var wasd := {"ui_left": KEY_A, "ui_right": KEY_D, "ui_up": KEY_W, "ui_down": KEY_S}
	var arrows := {"ui_left": KEY_LEFT, "ui_right": KEY_RIGHT, "ui_up": KEY_UP, "ui_down": KEY_DOWN}
	var wasd_names := {"ui_left": "A", "ui_right": "D", "ui_up": "W", "ui_down": "S"}
	for action in wasd.keys():
		var events := InputMap.action_get_events(action)
		fails += _check(_has_key(events, int(arrows[action])),
			"[输入] %s 仍然绑着方向键" % action)
		fails += _check(_has_key(events, int(wasd[action])),
			"[输入] %s 也绑着 WASD 的 %s 键" % [action, str(wasd_names[action])])

	print("")
	if fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % fails)
		quit(1)


## 这个动作上有没有绑着某个键（keycode 或 physical_keycode 都认）。
func _has_key(events: Array, keycode: int) -> bool:
	for e in events:
		var ev := e as InputEventKey
		if ev == null:
			continue
		if ev.keycode == keycode or ev.physical_keycode == keycode:
			return true
	return false


func _check(ok: bool, what: String) -> int:
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
