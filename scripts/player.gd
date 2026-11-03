extends CharacterBody2D

## 玩家角色。移动由**拥有者**权威计算，位置通过 MultiplayerSynchronizer 同步。
##
## 多人约定：玩家节点的**名字就是 peer id**（例如 "1075349658"）。
## 权威解析规则见 resolve_authority()：名字是合法整数就用它，否则兜底 1（房主）。
##
## 本脚本只管两件事：怎么走、怎么长。任何结果结算都不在本层。
##
## 贴图：assets/chars/char_0..5.png 共 CHAR_TEXTURE_COUNT 张，
## 用 posmod 取模 —— % 对负数返回负数，会拼出非法路径。

## 移动速度（px / 秒）。
@export var speed: float = 150.0

## 玩家序号（决定用哪张贴图）。**稳定序号由 Task 11 分配**，本任务只负责取值。
@export var player_index: int = 0

## 贴图张数。
const CHAR_TEXTURE_COUNT := 6

@onready var sprite: Sprite2D = $Sprite2D

var _bob: float = 0.0


## 节点名 → multiplayer authority 的**纯函数**解析（静态、不碰场景树，可直接单测）。
##
## 规则：名字是合法整数 → 用它；否则兜底 1（房主）。
## 纯数字节点名在 Godot 4 里合法（路径 /root/1075349658，get_node_or_null 能命中）。
static func resolve_authority(node_name: String) -> int:
	if node_name.is_valid_int():
		return int(node_name)
	return 1


func _ready() -> void:
	# 节点名 = peer id，作为多人权威的依据
	set_multiplayer_authority(resolve_authority(name))
	# 贴图索引用 posmod（% 对负数返回负数 → 路径非法）
	sprite.texture = load("res://assets/chars/char_%d.png"
		% posmod(player_index, CHAR_TEXTURE_COUNT))


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		# 非拥有者：位置由同步器提供，只做表现（不写自己的 position / velocity）
		_bob += delta * 8.0
		sprite.position.y = -absf(sin(_bob)) * 2.0
		return

	var dir := Vector2(
		Input.get_axis("ui_left", "ui_right"),
		Input.get_axis("ui_up", "ui_down"))
	if dir.length() > 1.0:
		dir = dir.normalized()
	velocity = velocity.lerp(dir * speed, 1.0 - exp(-12.0 * delta))
	move_and_slide()

	# 程序化行走动画：上下 bob + 轻微 squash（替代多帧序列帧）
	if dir != Vector2.ZERO:
		_bob += delta * 9.0
		sprite.position.y = -absf(sin(_bob)) * 3.0
		sprite.scale = Vector2(1.0 + sin(_bob * 2.0) * 0.04, 1.0 - sin(_bob * 2.0) * 0.04)
	else:
		_bob = 0.0
		sprite.position.y = 0.0
		sprite.scale = Vector2.ONE
