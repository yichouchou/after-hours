extends Node

## 场景路由：大厅 / 游戏之间切换。作为 autoload 常驻。

## 启动后自动进入的大厅场景。
const LOBBY_SCENE := "res://scenes/lobby.tscn"


func goto(scene_path: String) -> void:
	# 目标场景不存在时明确跳过，而不是让 change_scene_to_file 静默失败、
	# 留下一堆 "Cannot open file" 错误。对所有调用点生效。
	if not ResourceLoader.exists(scene_path):
		print("[Router] 场景不存在，已跳过: ", scene_path)
		return
	get_tree().change_scene_to_file(scene_path)


func _ready() -> void:
	call_deferred("_boot")


func _boot() -> void:
	await get_tree().process_frame
	# headless 测试用 `--script` 启动时没有主场景，此时不要自动跳转，
	# 否则会在测试跑到一半时把场景换掉。
	if get_tree().current_scene == null:
		return
	# 大厅场景由后续任务交付；文件还没落地时不要跳转，
	# 否则 change_scene_to_file 会报 "Cannot open file"。
	if not ResourceLoader.exists(LOBBY_SCENE):
		return
	goto(LOBBY_SCENE)
