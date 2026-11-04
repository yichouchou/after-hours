extends CharacterBody2D

## 玩家角色。移动由**拥有者**权威计算，位置通过 MultiplayerSynchronizer 同步。
##
## 多人约定：玩家节点的**名字就是 peer id**（例如 "1075349658"）。
## 权威解析规则见 resolve_authority()：名字是**规范的十进制正整数**就用它，
## 否则兜底 1（房主）。
##
## 本脚本只管两件事：怎么走、怎么长。任何结果结算都不在本层。
##
## 被押送（Task 9）：收到房主的 player_caught → 输入禁用、自己走回**自己的**
## 出生点（spawn_position）→ 到了就向房主回报 escort_finished。
## ★ 位置是**拥有者权威**：房主不许直接写远端玩家的 position，
##   「送回出生点」必须由被抓玩家自己执行。
## ★ 押送**不清零**任何进度：结算用的「已完成捣蛋次数」不动，
##   手上那条没交付的捣蛋作废 —— 那是 Task 10 的数据，两件事分属不同字段。
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

## 押送到达出生点的判定容差（px）。
const ESCORT_ARRIVE_TOLERANCE := 8.0

@onready var sprite: Sprite2D = $Sprite2D

## 自己的出生点。被抓押送时自己走回这里。
##
## ★ Task 11 会按「每人固定位置」注入真值（set_spawn_position）；
## 在那之前用 _ready() 时的位置兜底。
var spawn_position: Vector2 = Vector2.ZERO

## 是否正在被押送（被抓之后、送回出生点途中）。
var escorted: bool = false

## 由游戏场景注入的 RPC 节点（scripts/net/game_rpc.gd 的实例）。
## **不**硬编码场景路径。
var rpc: Node = null

## 「我已经走回自己的出生点」——本机信号（表现层可订阅）。
signal escort_finished(peer_id: int)

var _bob: float = 0.0
var _spawn_position_set := false


## ── 捣蛋交互（Task 10）──────────────────────────────────────────────────
##
## ★ 进度**两个字段**（派单 §3.3.1 裁定，**不许**用一个字段表达两件事）：
##
##   completed_mischief        —— **已完成的捣蛋次数**（结算进度 / 清单打勾数）
##                                  **被抓不清零**、**落败不减**（零失败惩罚）
##   current_mischief_progress —— **手上那一条的进行中进度**（0.0–1.0）
##                                  被抓时**作废**（那一条要重做 —— 这不是惩罚）
##
## ★ 权威模型：进度由**客户端（操作方）**累积 → 满 1.0 时向**房主**提交 →
##   房主裁决（先到先得 + Rules）→ 广播结果 → **每个人各自更新自己的字段**。
##   房主**不写**别人的进度（位置是拥有者权威，进度同理）。
##
## ★ 被抓时「进行中进度」作废发生在**被抓的那一瞬间**（不是押送途中），
##   于是 Task 9 的「押送期间玩家脚本变量除 escorted/_bob 外零变化」断言
##   在**不改动**那条测试的前提下依然成立。

## 已完成的捣蛋次数（结算进度）。被抓 / 落败都**不清零**。
var completed_mischief: int = 0

## 手上正在做的那一条的**进行中**进度（0.0–1.0）。
var current_mischief_progress: float = 0.0

## 手上那条的行为 id（空 = 手上没东西）。
var current_behavior_id: StringName = &""

## 手上那条的目标 id（道具的 prop_id）。
var current_target_id: int = 0

## 本机玩家的捣蛋清单（Task 11 注入，来自 Session.deal()）。
var hand: Array = []

## 场上玩家容器（运行时注入，**不**硬编码场景路径）。
var players_root: Node2D = null

## 道具容器（运行时注入，**不**硬编码场景路径）。
var props_root: Node2D = null

## 交互半径（px）：够近才能开始捣蛋。
@export var interact_radius: float = 40.0

## 交互键。**按住** = 持续捣蛋（进度随时间累积）。
##
## ★ 不用 InputMap 的具名动作：project.godot 里没有这个动作，
##   引用不存在的动作会打引擎错误；而 project.godot 本轮**不许改**。
const INTERACT_KEY := KEY_E


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
	# 出生点兜底：Task 11 注入真值之前，用进场时的位置。
	if not _spawn_position_set and spawn_position == Vector2.ZERO:
		spawn_position = position


## 注入自己的出生点（Task 11 按「每人固定位置」调用）。
func set_spawn_position(pos: Vector2) -> void:
	spawn_position = pos
	_spawn_position_set = true


## 注入 RPC 节点并接上信号（不硬编码场景路径）。
func set_rpc(node: Node) -> void:
	rpc = node
	if node == null:
		return
	if node.has_signal(&"caught_player_evt"):
		var cb := Callable(self, "_on_caught_player_evt")
		if not node.is_connected(&"caught_player_evt", cb):
			node.connect(&"caught_player_evt", cb)
	# Task 10：捣蛋结算结果（房主广播 → 各自更新**自己**的进度字段）。
	if node.has_signal(&"mischief_resolved_evt"):
		var cb2 := Callable(self, "_on_mischief_resolved_evt")
		if not node.is_connected(&"mischief_resolved_evt", cb2):
			node.connect(&"mischief_resolved_evt", cb2)


## 房主说「你被守卫抓了」→ 进入被押送状态（自己走回自己的出生点）。
func _on_caught_player_evt(peer_id: int, _guard_id: int) -> void:
	if peer_id != _local_peer_id():
		return
	escorted = true
	# ★ 被抓 → 手上那一条的**进行中进度作废**（那一条要重做）。
	#   这**不是惩罚**：「已完成次数」（completed_mischief）**不动**。
	#   ★ 发生在**被抓的这一瞬间**（不是押送途中）——
	#     于是 Task 9 的「押送期间玩家脚本变量除 escorted/_bob 外零变化」
	#     断言在**不改动**那条测试的前提下依然成立。
	_clear_current_mischief()


## 房主广播的结算结果 → 更新**自己**的进度字段。
##
## ★ 只有成功才「已完成次数 +1」；被抓 / 落败都**不减**（零失败惩罚）。
## ★ 手上那一条的**进行中进度作废**（不管是成功、被抓还是落败：
##   成功 → 那一条已经结算；失败 → 那一条要重做）。
func _on_mischief_resolved_evt(peer_id: int, behavior_id: StringName, success: bool,
		_reason: String) -> void:
	if peer_id != _local_peer_id():
		return
	if success:
		completed_mischief += 1
	if behavior_id == &"" or behavior_id == current_behavior_id:
		_clear_current_mischief()


func _physics_process(delta: float) -> void:
	if not _owns_movement():
		# 非拥有者：位置由同步器提供，只做表现（不写自己的 position / velocity）
		_bob += delta * 8.0
		sprite.position.y = -absf(sin(_bob)) * 2.0
		return

	var dir := Vector2.ZERO
	if escorted:
		# 被押送：**输入被禁用**，自己朝**自己的**出生点走。
		# 位置是拥有者权威 → 自己算自己走，位置由同步器同步给房主与其它客户端。
		dir = _escort_direction()
	else:
		dir = Vector2(
			Input.get_axis("ui_left", "ui_right"),
			Input.get_axis("ui_up", "ui_down"))
		if dir.length() > 1.0:
			dir = dir.normalized()
		# 捣蛋的本地推进（**进度由客户端 = 操作方累积**）。
		# ★ 被押送时**不**推进（输入被禁用）—— 那时手上那条的进度已经作废了。
		_update_mischief(delta)
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


## 本机是不是这个节点的「移动权威」（输入归谁算）。
##
## ★ **不能**直接用 is_multiplayer_authority()：它内部会问
##   multiplayer.get_unique_id()，而**一旦 mp 上没有 peer**，引擎就会每帧打一条
##   ERROR（"No multiplayer peer is assigned. Unable to get unique ID."），
##   而且返回值恒为 false → **输入被整个忽略（角色卡住）**
##   （2026-11-04 用户报障，headless 探针复现）。
## ★ PeerState 的口径：没有 peer ⇒ 本机即房主（peer id 1）
##   → 权威为 1 的那个化身仍然归本机管，角色照样能动。
func _owns_movement() -> bool:
	return PeerState.owns_node(self)


## 被押送时的移动方向：朝**自己的**出生点。
##
## 到了（容差内）就结束押送，并向房主回报 —— 房主收到后 brain.finish_carry()。
func _escort_direction() -> Vector2:
	var to_spawn := spawn_position - position
	if to_spawn.length() <= ESCORT_ARRIVE_TOLERANCE:
		_finish_escort()
		return Vector2.ZERO
	return to_spawn.normalized()


## 押送结束：解除押送状态 → 向房主回报「已走回出生点」。
func _finish_escort() -> void:
	if not escorted:
		return
	escorted = false
	# 停下：别带着惯性从出生点漂开（到达判定有明确容差，停得住才算数）。
	velocity = Vector2.ZERO
	var peer_id := _local_peer_id()
	escort_finished.emit(peer_id)
	if rpc != null and rpc.has_method(&"send_escort_finished"):
		rpc.send_escort_finished(peer_id)


## 本机 peer id。玩家节点的**名字就是 peer id**（Task 8 的约定），
## 解析规则与权威解析共用同一套（非法名字兜底 1）。
func _local_peer_id() -> int:
	return resolve_authority(name)


## ── 捣蛋交互（Task 10）──────────────────────────────────────────────────

## 注入本机玩家的捣蛋清单（Task 11 调用，来自 Session.deal()）。
func set_hand(list: Array) -> void:
	hand = list


## 注入场上玩家容器（运行时注入，**不**硬编码场景路径）。
func set_players_root(node: Node2D) -> void:
	players_root = node


## 注入道具容器（运行时注入，**不**硬编码场景路径）。
func set_props_root(node: Node2D) -> void:
	props_root = node


## 捣蛋的本地推进。
##
## ★ 只有**拥有者**跑（进度是操作方自己的数据；房主不写别人的进度）。
## ★ 手上有东西 → 累积进度；进度满 1.0 → 向房主提交。
## ★ 手上没东西 → 试试能不能开始一条。
func _update_mischief(delta: float) -> void:
	if current_behavior_id == &"":
		_try_start_mischief()
		return
	if current_mischief_progress >= 1.0:
		return
	var m := _find_behavior(current_behavior_id)
	if m == null:
		_clear_current_mischief()
		return
	var need := Interaction.effective_duration(m, _has_partner())
	current_mischief_progress += delta / maxf(need, 0.0001)
	if current_mischief_progress >= 1.0:
		current_mischief_progress = 1.0
		_submit_current_mischief()


## 按住交互键、且旁边有对得上 tag 的道具 → 开始一条捣蛋。
func _try_start_mischief() -> void:
	if not Input.is_key_pressed(INTERACT_KEY):
		return
	if props_root == null or hand.is_empty():
		return
	var hit := Interaction.find_nearest_by_data(global_position, _prop_entries(),
		interact_radius)
	if hit.is_empty():
		return
	var m := _find_behavior(StringName(str(hit.get("tag", ""))))
	if m == null:
		return
	current_behavior_id = m.id
	current_target_id = int(hit.get("id", 0))
	current_mischief_progress = 0.0


## 道具的数据快照：[{ "id": int, "tag": StringName, "position": Vector2 }]。
##
## ★ 纯数据（不持有节点引用）→ 交互层不需要碰场景树。
func _prop_entries() -> Array:
	var out: Array = []
	if props_root == null:
		return out
	for child in props_root.get_children():
		var n2d := child as Node2D
		if n2d == null:
			continue
		out.append({
			"id": int(n2d.get_meta("prop_id", 0)),
			"tag": StringName(str(n2d.get_meta("prop_tag", ""))),
			"position": n2d.global_position,
		})
	return out


## 场上有没有搭档（另一个玩家在**同一个目标**旁边）。
##
## ★ **不缓存**：每次现算 —— 缓存下来的值会在押送过程中变化，
##   踩坏 Task 9 的「押送期间玩家脚本变量除 escorted/_bob 外零变化」断言。
func _has_partner() -> bool:
	if players_root == null:
		return false
	var players: Array = []
	for child in players_root.get_children():
		var n2d := child as Node2D
		if n2d == null:
			continue
		players.append({
			"peer_id": resolve_authority(str(child.name)),
			"position": n2d.global_position,
		})
	return Interaction.has_partner_near(players, _local_peer_id(), global_position)


## 进度满了 → 向房主提交（**房主权威裁决**）。
func _submit_current_mischief() -> void:
	if rpc == null or not rpc.has_method(&"send_submit_mischief"):
		# 没有房主通道 → 这一条只能重做（**不是惩罚**，只是没提交出去）。
		_clear_current_mischief()
		return
	rpc.send_submit_mischief(String(current_behavior_id), current_target_id)


## 手上那一条作废（**只清进行中进度，绝不碰「已完成次数」**）。
func _clear_current_mischief() -> void:
	current_mischief_progress = 0.0
	current_behavior_id = &""
	current_target_id = 0


## 在手牌里找一个行为（按 id）。
func _find_behavior(behavior_id: StringName) -> Mischief:
	for b in hand:
		var m := b as Mischief
		if m != null and m.id == behavior_id:
			return m
	return null
