extends CharacterBody2D

## 玩家角色。移动由**拥有者**权威计算，位置通过 MultiplayerSynchronizer 同步。
##
## 多人约定：玩家节点的**名字就是 peer id**（例如 "1075349658"）。
## 权威解析规则见 resolve_authority()：名字是**规范的十进制正整数**就用它，
## 否则兜底 1（房主）。
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

## 权威 id 的位数上限（peer id 最多 10 位）。
const MAX_AUTHORITY_DIGITS := 10

## 权威 id 的数值上限（2^31 - 1）。
const MAX_AUTHORITY := 2147483647

@onready var sprite: Sprite2D = $Sprite2D

var _bob: float = 0.0


## 节点名 → multiplayer authority 的**纯函数**解析（静态、不碰场景树，可直接单测）。
##
## 规则：名字是**规范的十进制正整数**（形态 ^[1-9][0-9]{0,9}$、数值 ∈ [1, 2^31-1]）→ 用它；
## 其余一律兜底 1（房主）。
##
## 为什么不能只看 is_valid_int()（它是**纯字面**判断）：
##   * "007" → 7（前导零被吞 → 与 "7" 撞车）、"-5" → -5、"0" → 0
##     → set_multiplayer_authority() 收到非法 id，引擎**静默接受**，
##       但 is_multiplayer_authority() 恒为 false → **该玩家永远不响应输入**。
##   * "99999999999999999999" → is_valid_int() 返回 true，但 int() 会**溢出**
##     并打一条引擎 ERROR（Cannot represent … as a 64-bit signed integer）。
## → 所以**先查形态与长度、再转换**：转换前已保证最多 10 位，不可能溢出。
static func resolve_authority(node_name: String) -> int:
	if node_name.is_empty() or node_name.length() > MAX_AUTHORITY_DIGITS:
		return 1
	for i in node_name.length():
		var c := node_name.unicode_at(i)
		if c < 48 or c > 57:  # '0'(48) .. '9'(57)
			return 1
	if node_name[0] == "0":  # 前导零（"0" 本身也在这里被挡下）
		return 1
	var v := node_name.to_int()  # 最多 10 位 → 绝不会溢出
	if v < 1 or v > MAX_AUTHORITY:
		return 1
	return v


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
