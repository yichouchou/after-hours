extends Node

## 场景路由：大厅 / 游戏之间切换。作为 autoload 常驻。

## 启动后自动进入的大厅场景。
const LOBBY_SCENE := "res://scenes/lobby.tscn"

## 最近一次因文件不存在而被跳过的场景路径（空串 = 没有跳过过）。
## 只有跳转到缺失场景时才会写入；正常跳转不改动它，保留上一次跳过的记录。
var last_skipped_scene: String = ""


func goto(scene_path: String) -> void:
	# 目标场景不存在时明确跳过，而不是让 change_scene_to_file 静默失败、
	# 留下一堆 "Cannot open file" 错误。对所有调用点生效。
	if not ResourceLoader.exists(scene_path):
		last_skipped_scene = scene_path
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
	# 不在这里再挡一次存在性检查：那会让 goto() 的诊断在启动路径上永远打不出来，
	# 场景缺失时游戏会静默停在主场景里，什么提示都没有。
	goto(LOBBY_SCENE)
