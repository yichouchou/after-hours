extends SceneTree

## Task 10：捣蛋交互与房主权威裁决 —— 单元测试。
##
## 覆盖派单 §4 的 **22 条断言**（下面每段注释标了 [§4-N]）。
##
## 本测试**不需要网络**：纯逻辑 + 场景实例化 → **一个端口都不开**。
##
## ★ 权威模型（务必别写反）：
##   * 进度由**客户端（操作方）**累积 → 满 1.0 时向**房主**提交
##   * 房主**权威裁决**：先到先得台账 + Rules.evaluate → 广播结果
##   * 房主**不写**别人的进度（进度是操作方自己的数据）
##   * 两个抓捕通道**分开**：护送 = 守卫通道（Task 9）；
##     裁决通道（reason == "caught"）只回答「这一条行为算不算完成」，**不触发护送**
##
## ★ 进度**两个字段**：已完成次数（不清零）/ 进行中进度（被抓作废）—— 分属不同字段。

## game_rpc.gd / player.gd 没有 class_name → 用 preload。
const GameRpcScript := preload("res://scripts/net/game_rpc.gd")
const PlayerScript := preload("res://scripts/player.gd")

const PROP_SCENE := "res://scenes/mischief_prop.tscn"
const PLAYER_SCENE := "res://scenes/player.tscn"
const GUARD_SCENE := "res://scenes/guard.tscn"

const INTERACTION_SRC := "res://scripts/game/interaction.gd"
const PROP_SRC := "res://scripts/mischief_prop.gd"
const PLAYER_SRC := "res://scripts/player.gd"
const RPC_SRC := "res://scripts/net/game_rpc.gd"

## 本任务新建 / 修改的**生产**文件（净化扫描的目标）。
## ★ 不含本测试文件自己 —— 它必须持有惩罚性 token 的清单才能做扫描
##   （与 tools/test_guard_flow.gd / tools/test_player.gd 同款做法）。
const NEW_FILES := [
	"res://scripts/game/interaction.gd",
	"res://scripts/mischief_prop.gd",
	"res://scenes/mischief_prop.tscn",
	"res://scripts/player.gd",
	"res://scripts/net/game_rpc.gd",
]

## 惩罚性 token（零失败惩罚）。口径与 tools/test_guard_flow.gd 保持一致。
const PENALTY_TOKENS := ["penalty", "penalized", "score", "score_delta",
	"lives", "lives_lost", "eliminated", "damage", "扣分", "扣命", "淘汰", "死亡"]

## 两字母的惩罚性 token 必须按**词边界**匹配（子串扫会误伤无关标识符）。
const PENALTY_WORD_TOKENS := ["hp"]

## Task 9 交付的三个 RPC 方法：**逐字未改**（连同 @rpc 修饰符）。
const RPC_BLOCK_PLAYER_CAUGHT := "@rpc(\"authority\", \"call_local\", \"reliable\")\nfunc player_caught(peer_id: int, guard_id: int) -> void:\n\tcaught_player_evt.emit(peer_id, guard_id)\n"
const RPC_BLOCK_GUARD_STATE := "@rpc(\"authority\", \"call_local\", \"reliable\")\nfunc guard_state(guard_id: int, state: int, position: Vector2, target_peer: int) -> void:\n\tguard_state_evt.emit(guard_id, state, position, target_peer)\n"
const RPC_BLOCK_ESCORT_FINISHED := "@rpc(\"any_peer\", \"call_remote\", \"reliable\")\nfunc escort_finished(peer_id: int) -> void:\n\tescort_completed_evt.emit(peer_id)\n"

## Task 10 新增的两个 RPC 方法：**@rpc 传输模式被钉住**
## （否则下一个人把 call_remote 改成 call_local，没人会发现）。
const RPC_BLOCK_SUBMIT := "@rpc(\"any_peer\", \"call_remote\", \"reliable\")\nfunc submit_mischief(behavior_id: String, target_id: int) -> void:"
const RPC_BLOCK_RESOLVE := "@rpc(\"authority\", \"call_local\", \"reliable\")\nfunc resolve_mischief(peer_id: int, behavior_id: String, success: bool, reason: String) -> void:"

## 押送到达出生点的容差（与 scripts/player.gd 的常量同值）。
const ESCORT_TOLERANCE := 8.0

## 道具贴图改成 2x 自然尺寸（每种道具高度不同），所以高度按**实际贴图**断言；
## "图片下沿落在地面 y = 0"这条不变（由 scripts/mischief_prop.gd 的自动锚定保证）。

var _fails := 0
var _total := 0


func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	# ==================================================================
	# [§4-1] 范围内能找到道具，且是**最近**的那个
	# ==================================================================
	var carrot := Node2D.new()
	carrot.set_meta("prop_tag", &"carrot")
	carrot.set_meta("prop_id", 7)
	carrot.position = Vector2(100, 0)
	var lamp := Node2D.new()
	lamp.set_meta("prop_tag", &"lamp")
	lamp.set_meta("prop_id", 8)
	lamp.position = Vector2(140, 0)
	var props: Array = [carrot, lamp]

	var found := Interaction.find_prop_in_range(Vector2(105, 0), props, 40.0)
	_fails += _check(found != null, "[§4-1] 范围内能找到道具")
	_fails += _check(found != null and int(found.get_meta("prop_id", -1)) == 7,
		"[§4-1] 找到的是**最近**的那个（prop_id 7）")

	# ==================================================================
	# [§4-2] 范围外找不到 → 返回空
	# ==================================================================
	var none := Interaction.find_prop_in_range(Vector2(500, 500), props, 40.0)
	_fails += _check(none == null, "[§4-2] 范围外找不到道具")
	var edge := Interaction.find_prop_in_range(Vector2(100, 0), props, 40.0)
	_fails += _check(edge != null and int(edge.get_meta("prop_id", -1)) == 7,
		"[§4-2] 正好在半径边缘（40 px）→ 算命中（判据 d <= radius）")

	# ==================================================================
	# [§4-3] 纯数据入口与 Node 入口**一致**
	# ==================================================================
	var entries: Array = [
		{"id": 7, "tag": &"carrot", "position": Vector2(100, 0)},
		{"id": 8, "tag": &"lamp", "position": Vector2(140, 0)},
	]
	var hit := Interaction.find_nearest_by_data(Vector2(105, 0), entries, 40.0)
	_fails += _check(not hit.is_empty() and int(hit.get("id", -1)) == 7,
		"[§4-3] 纯数据入口命中的是同一条（id 7）")
	_fails += _check(found != null and not hit.is_empty()
			and int(hit.get("id", -1)) == int(found.get_meta("prop_id", -1)),
		"[§4-3] 两个入口对同一组数据给出**一致**的结果")
	var hit_none := Interaction.find_nearest_by_data(Vector2(500, 500), entries, 40.0)
	_fails += _check(hit_none.is_empty(), "[§4-3] 纯数据入口：范围外 → 空字典")

	# ==================================================================
	# [§4-4] 并列规则：距离相等 → 取遍历顺序**靠后**的那个（写死 + 注释）
	# ==================================================================
	var tie_a := Node2D.new()
	tie_a.set_meta("prop_id", 1)
	tie_a.position = Vector2(50, 0)
	var tie_b := Node2D.new()
	tie_b.set_meta("prop_id", 2)
	tie_b.position = Vector2(150, 0)
	var tie := Interaction.find_prop_in_range(Vector2(100, 0), [tie_a, tie_b], 60.0)
	_fails += _check(tie != null and int(tie.get_meta("prop_id", -1)) == 2,
		"[§4-4] 并列（距离都是 50 px）→ 取遍历顺序**靠后**的那个（2）")
	var tie_data := Interaction.find_nearest_by_data(Vector2(100, 0),
		[{"id": 1, "tag": &"x", "position": Vector2(50, 0)},
		 {"id": 2, "tag": &"x", "position": Vector2(150, 0)}], 60.0)
	_fails += _check(not tie_data.is_empty() and int(tie_data.get("id", -1)) == 2,
		"[§4-4] 纯数据入口的并列规则与 Node 入口**一致**（也是 2）")

	# ==================================================================
	# [§4-5] 对**脱离场景树**的节点也能工作
	# ==================================================================
	_fails += _check(not carrot.is_inside_tree() and not lamp.is_inside_tree(),
		"[§4-5] 前提：这些道具**没有**加入场景树")
	_fails += _check(found != null and int(found.get_meta("prop_id", -1)) == 7,
		"[§4-5] 对脱离场景树的节点也能工作（找到 prop_id 7）")

	# ==================================================================
	# [§4-6] Rules.evaluate() 的接线：被守卫盯上 → caught
	# ==================================================================
	var r_caught := Rules.evaluate(
		{"peer_id": 2, "behavior_id": &"steal_carrot", "target_id": 7, "progress": 1.0},
		{"nearest_guard_distance": 12.0, "guard_alerted": true, "has_partner": true,
			"needs_partner": false, "guard_catch_distance": 24.0})
	_fails += _check(not bool(r_caught["success"]) and bool(r_caught["caught"])
			and str(r_caught["reason"]) == "caught",
		"[§4-6] 被守卫盯上（警觉 + 距离 ≤ 抓捕半径）→ caught")
	var r_ok := Rules.evaluate(
		{"peer_id": 2, "behavior_id": &"steal_carrot", "target_id": 7, "progress": 1.0},
		{"nearest_guard_distance": 12.0, "guard_alerted": false, "has_partner": true,
			"needs_partner": false, "guard_catch_distance": 24.0})
	_fails += _check(bool(r_ok["success"]) and str(r_ok["reason"]) == "ok",
		"[§4-6] 守卫没盯上 → ok（别把判定写反）")

	# ==================================================================
	# [§4-7] 效率倍率：缺搭档 → 所需时间 × 2
	# ==================================================================
	var m_pair := _make_behavior(&"mess_chairs", 3.0, true)
	var m_solo := _make_behavior(&"steal_carrot", 1.5, false)
	_fails += _check(is_equal_approx(Interaction.effective_duration(m_pair, false), 6.0),
		"[§4-7] needs_partner=true 且 has_partner=false → 时长 = duration × 2（3 → 6）")
	_fails += _check(is_equal_approx(Interaction.effective_duration(m_pair, true), 3.0),
		"[§4-7] needs_partner=true 且 has_partner=true → 时长 = duration 原值（3）")
	_fails += _check(is_equal_approx(Interaction.effective_duration(m_solo, false), 1.5),
		"[§4-7] needs_partner=false → 恒为 duration（1.5）")
	_fails += _check(is_equal_approx(Interaction.effective_duration(m_solo, true), 1.5),
		"[§4-7] needs_partner=false 且 has_partner=true → 仍是 duration（1.5）")
	# ★ 倍率取自**那张牌自己的字段**（不许硬编码 true/false）
	var real_pair := Mischief.find_by_id(Mischief.load_all(), &"mess_chairs")
	_fails += _check(real_pair != null and real_pair.needs_partner
			and is_equal_approx(Interaction.effective_duration(real_pair, false),
				real_pair.duration * 2.0),
		"[§4-7] 倍率取自 data/mischief.json 里那张牌自己的 needs_partner / duration")

	# ==================================================================
	# [§4-12] 跨层等值：Rules.CATCH_DISTANCE == GuardBrain.CATCH_DISTANCE
	# ==================================================================
	_fails += _check(Rules.CATCH_DISTANCE == GuardBrain.CATCH_DISTANCE,
		"[§4-12] Rules.CATCH_DISTANCE == GuardBrain.CATCH_DISTANCE（都是 24.0）")

	# ==================================================================
	# [§4-8] 「先到先得」台账（**房主侧**纯逻辑）
	# ==================================================================
	var ledger := Interaction.ClaimLedger.new()
	_fails += _check(ledger.claim(7, 2), "[§4-8] 第一次提交 → 占住 target 7")
	_fails += _check(not ledger.claim(7, 3),
		"[§4-8] 同一个 target_id 第二次提交 → **落败**")
	_fails += _check(ledger.owner_of(7) == 2, "[§4-8] 台账里归**先到**的那个 peer（2）")
	_fails += _check(ledger.is_claimed(7) and not ledger.is_claimed(8),
		"[§4-8] 台账只记被占住的目标")

	# ==================================================================
	# 房主侧环境：rpc 节点 + 玩家容器 + 守卫容器
	# ==================================================================
	var rpc := GameRpcScript.new()
	rpc.name = "GameRpc"
	root.add_child(rpc)

	var players_root := Node2D.new()
	players_root.name = "Players"
	root.add_child(players_root)
	# 房主侧看到的「远端玩家」替身（节点名 = peer id）。
	var peer2 := Node2D.new()
	peer2.name = "2"
	peer2.position = Vector2(100, 0)
	players_root.add_child(peer2)
	# 第三个玩家：先放远（没有搭档），后面挪近（当搭档用）。
	var peer3 := Node2D.new()
	peer3.name = "3"
	peer3.position = Vector2(400, 0)
	players_root.add_child(peer3)

	var guards_root := Node2D.new()
	guards_root.name = "Guards"
	root.add_child(guards_root)
	var guard_packed: PackedScene = load(GUARD_SCENE)
	_fails += _check(guard_packed != null, "[§4-16] guard.tscn 可加载（拔路灯要用守卫）")
	var guard = null
	if guard_packed != null:
		guard = guard_packed.instantiate()
		guard.position = Vector2(112, 0)
		guards_root.add_child(guard)
		await process_frame
		guard.set_physics_process(false)  # 别让守卫的 AI 跑起来干扰断言
		guard.brain.state = GuardBrain.State.CHASE
	rpc.players_root = players_root
	rpc.guards_root = guards_root

	var resolved: Array = []
	rpc.mischief_resolved_evt.connect(func(peer_id: int, behavior_id: StringName,
			success: bool, reason: String) -> void:
		resolved.append({"peer_id": peer_id, "behavior_id": behavior_id,
			"success": success, "reason": reason}))
	var caught_events: Array = []
	rpc.caught_player_evt.connect(func(peer_id: int, guard_id: int) -> void:
		caught_events.append(peer_id))

	# ==================================================================
	# [§4-9] [§4-10] 广播载荷：含**非空** behavior_id，且是**纯数据**
	# ==================================================================
	var caught_before := caught_events.size()
	var verdict := rpc.adjudicate(2, &"steal_carrot", 7, 1.0)
	_fails += _check(resolved.size() == 1, "[§4-9] 房主裁决后广播了一次结果")
	var payload: Dictionary = rpc.last_mischief_payload
	_fails += _check(payload.size() == 4,
		"[§4-10] 载荷恰好 **4 个字段**（peer_id / behavior_id / success / reason）")
	_fails += _check(payload.has("peer_id") and payload.has("behavior_id")
			and payload.has("success") and payload.has("reason"),
		"[§4-10] 载荷的字段名固定为那 4 个")
	_fails += _check(typeof(payload.get("behavior_id")) == TYPE_STRING,
		"[§4-10] 载荷里的 behavior_id 是 **String**（不是 StringName）")
	_fails += _check(str(payload.get("behavior_id", "")) == "steal_carrot"
			and not str(payload.get("behavior_id", "")).is_empty(),
		"[§4-9] 载荷里的 behavior_id **非空**且是真实的行为 id")
	_fails += _check(_payload_is_pure_data(payload),
		"[§4-10] 载荷里没有 Object / Resource（纯数据）")
	if resolved.size() >= 1:
		var ev: Dictionary = resolved[resolved.size() - 1]
		_fails += _check(typeof(ev["behavior_id"]) == TYPE_STRING_NAME
				and StringName(str(ev["behavior_id"])) == &"steal_carrot",
			"[§4-9] 内部信号层的 behavior_id 是 StringName 且非空")
	_fails += _check(str(verdict.get("reason", "")) == "caught"
			and not bool(verdict.get("success", true)),
		"[§4-6] 房主侧接线：完成瞬间被守卫盯上 → reason == caught")
	_fails += _check(caught_events.size() == caught_before,
		"[§4-11] 裁决通道（reason == caught）**不触发护送**（护送是守卫通道的职责）")

	# ==================================================================
	# [§4-8] 房主侧的落败：同一个 target_id 第二次提交 → 落败，零失败惩罚
	# ==================================================================
	var verdict2 := rpc.adjudicate(3, &"steal_carrot", 7, 1.0)
	_fails += _check(not bool(verdict2["success"]) and str(verdict2["reason"]) == "target_taken",
		"[§4-8] 房主侧：同一个 target_id 第二次提交 → **落败**（不扣分、不淘汰）")
	_fails += _check(verdict2.size() == 2 and verdict2.has("success") and verdict2.has("reason"),
		"[§4-8] 裁决返回值只有 {success, reason} 两个键")
	_fails += _check(_no_penalty_keys(verdict2),
		"[§4-8] 裁决返回值里**没有任何惩罚性字段**（零失败惩罚）")

	# ==================================================================
	# [§4-11] reason == "in_progress" 是**非终态**
	# ==================================================================
	var resolved_before := resolved.size()
	var payload_before: Dictionary = rpc.last_mischief_payload.duplicate()
	var caught_before2 := caught_events.size()
	var verdict3 := rpc.adjudicate(2, &"mess_chairs", 11, 0.4)
	_fails += _check(str(verdict3["reason"]) == "in_progress",
		"[§4-11] progress < 1.0 → reason == in_progress")
	_fails += _check(resolved.size() == resolved_before,
		"[§4-11] in_progress **不广播**")
	_fails += _check(rpc.last_mischief_payload == payload_before,
		"[§4-11] in_progress **不写**广播载荷")
	_fails += _check(caught_events.size() == caught_before2,
		"[§4-11] in_progress **不触发护送**")
	_fails += _check(not rpc._ledger.is_claimed(11),
		"[§4-11] in_progress **不占**先到先得的台账（不清进度）")
	_fails += _check(_no_penalty_keys(verdict3),
		"[§4-11] in_progress 的返回值里也没有惩罚性字段")

	# ==================================================================
	# [§4-2.2] has_partner / needs_partner **不许硬编码** true/false
	#
	# needs_partner 取自 Mischief.needs_partner（那张牌自己的字段）；
	# has_partner 取自**实际搭档状态**（场上是否有另一个玩家在同一目标旁边）。
	# ==================================================================
	rpc.adjudicate(2, &"mess_chairs", 31, 1.0)
	_fails += _check(bool(rpc.last_mischief_context.get("needs_partner", false)),
		"[§4-2.2] needs_partner 取自**那张牌自己的字段**（mess_chairs.needs_partner == true）")
	_fails += _check(not bool(rpc.last_mischief_context.get("has_partner", true)),
		"[§4-2.2] has_partner 取自**实际搭档状态**（旁边没人 → false，不是写死的 true）")
	# 把第三个玩家挪到 peer2 旁边 → 真的有搭档了
	peer3.position = Vector2(130, 0)
	rpc.adjudicate(2, &"mess_chairs", 32, 1.0)
	_fails += _check(bool(rpc.last_mischief_context.get("has_partner", false)),
		"[§4-2.2] 旁边有另一个玩家 → has_partner == true（不是写死的 false）")
	rpc.adjudicate(2, &"steal_carrot", 33, 1.0)
	_fails += _check(not bool(rpc.last_mischief_context.get("needs_partner", true)),
		"[§4-2.2] needs_partner=false 的牌 → 上下文里也是 false")
	peer3.position = Vector2(400, 0)

	# ==================================================================
	# [§4-14] mischief_prop.tscn 可 load() 且 instantiate() 不报错
	# ==================================================================
	var prop_packed: PackedScene = load(PROP_SCENE)
	_fails += _check(prop_packed != null, "[§4-14] mischief_prop.tscn 可加载")
	var prop = null
	if prop_packed != null:
		prop = prop_packed.instantiate()
		_fails += _check(prop != null, "[§4-14] mischief_prop.tscn 可实例化")
		prop.prop_tag = &"lamp"
		prop.prop_id = 42
		root.add_child(prop)
		await process_frame
		_fails += _check(StringName(str(prop.get_meta("prop_tag", ""))) == &"lamp",
			"[§4-14] prop_tag 导出生效（_ready() 写进 meta）")
		_fails += _check(int(prop.get_meta("prop_id", -1)) == 42,
			"[§4-14] prop_id 导出生效")
		var sprite := prop.get_node_or_null("Sprite2D") as Sprite2D
		_fails += _check(sprite != null, "[§4-14] 道具带 Sprite2D")
		if sprite != null:
			_fails += _check(sprite.centered == false,
				"[§4-14] Sprite2D.centered == false（默认 true → 道具整体上浮 19 px、悬在半空）")
			var rect: Rect2 = sprite.get_rect()
			# 高度按**实际贴图**断言（道具改成 2x 自然尺寸，每种高度不同）；
			# "图片下沿落在地面 y = 0"这条不变（自动锚定保证的）。
			var tex: Texture2D = sprite.texture
			var expect_h := float(tex.get_height()) if tex != null else 0.0
			_fails += _check(is_equal_approx(rect.size.y, expect_h) and expect_h > 0.0,
				"[§4-14] 道具贴图高度 = 实际贴图高度（实测 %.0f，期望 %.0f）" % [rect.size.y, expect_h])
			_fails += _check(is_equal_approx(rect.position.y + rect.size.y, 0.0),
				"[§4-14] **图片**下沿落在地面 y = 0（rect %s）" % str(rect))

	# ==================================================================
	# [§4-16] [§4-20] 拔路灯：**真的**让守卫的视野变小
	# ==================================================================
	var lamp_guard = null
	var lamp_prop = null
	if guard_packed != null:
		lamp_guard = guard_packed.instantiate()
		lamp_guard.position = Vector2.ZERO
		root.add_child(lamp_guard)
		lamp_guard.set_physics_process(false)
		await process_frame
		# 一盏灯（真的用 mischief_prop.tscn 的道具）
		var lamp_root := Node2D.new()
		lamp_root.name = "Lamps"
		root.add_child(lamp_root)
		if prop_packed != null:
			lamp_prop = prop_packed.instantiate()
			lamp_prop.prop_tag = &"lamp"
			lamp_prop.prop_id = 42
			lamp_prop.position = Vector2(20, 0)
			lamp_root.add_child(lamp_prop)
		await process_frame
		# ★ 只走 lamp_root 这一条注入通道（两种都上 → 被算两次 → 0.36）
		_fails += _check(Interaction.attach_lamps(lamp_guard, lamp_root),
			"[§4-20] 路灯接进守卫（只走 lamp_root 一条通道）")
		_fails += _check(not lamp_prop.has_meta("lamp_on"),
			"[§4-16] 前提：没被动过的灯**没有** meta \"lamp_on\"（走属性那条读取路径）")
		_fails += _check(lamp_prop.lamp_on == true,
			"[§4-16] 前提：属性的初始值是亮着")
		var ctx_bright: Dictionary = lamp_guard._sense_context()
		_fails += _check(is_equal_approx(float(ctx_bright["light_factor"]), 1.0),
			"[§4-16] 灯亮着 → light_factor == 1.0")
		# 熄灯：写 meta "lamp_on"（Task 9 已定的读取契约：meta 优先）
		lamp_prop.turn_lamp_off()
		_fails += _check(lamp_prop.has_meta("lamp_on")
				and bool(lamp_prop.get_meta("lamp_on", true)) == false,
			"[§4-16] 熄灯是写 meta \"lamp_on\"（Task 9 的读取契约：meta 优先）")
		var ctx_dark: Dictionary = lamp_guard._sense_context()
		_fails += _check(is_equal_approx(float(ctx_dark["light_factor"]), 0.6),
			"[§4-16] 熄掉一盏 → light_factor 1.0 → 0.6（每盏灭 −40%）")
		var range_bright := GuardBrain.effective_sight_range(96.0,
			float(ctx_bright["light_factor"]))
		var range_dark := GuardBrain.effective_sight_range(96.0,
			float(ctx_dark["light_factor"]))
		_fails += _check(range_dark < range_bright,
			"[§4-16] 守卫的**实际视野**确实变小（%.1f → %.1f px）"
			% [range_bright, range_dark])
		# 恢复点亮 → 又变回原值（证明是「熄灯」起作用，不是别的原因）
		lamp_prop.turn_lamp_on()
		var ctx_again: Dictionary = lamp_guard._sense_context()
		_fails += _check(is_equal_approx(float(ctx_again["light_factor"]), 1.0),
			"[§4-16] 重新点亮 → light_factor 回到 1.0（证明是熄灯起作用，不是别的原因）")
		# [§4-16] 熄灯必须同时作用到**画面**：灯光节点消失、贴图压暗。
		# （灯光节点由场景层挂上，这里手动补一个，测的是同步逻辑本身。）
		var lamp_light := PointLight2D.new()
		lamp_light.name = "PointLight2D"
		lamp_prop.add_child(lamp_light)
		await process_frame
		_fails += _check(lamp_light.visible,
			"[§4-16] 灯亮着 → 灯光节点可见")
		lamp_prop.turn_lamp_off()
		await process_frame
		_fails += _check(not lamp_light.visible,
			"[§4-16] 熄灯后对应的 PointLight2D 不可见（画面与玩法一致）")
		lamp_prop.turn_lamp_on()
		await process_frame
		_fails += _check(lamp_light.visible,
			"[§4-16] 重新点亮 → 灯光节点恢复可见")
		# [§4-20] 同一盏灯不能被算两次
		_fails += _check(lamp_guard._lamp_states().size() == 1,
			"[§4-20] 守卫只收到**一盏**灯（同一盏灯不会被算两次）")
		_fails += _check(lamp_guard._injected_lamps.is_empty(),
			"[§4-20] 没有同时用 set_lamps() 数组注入同一盏灯")
		_fails += _check(is_equal_approx(float(ctx_dark["light_factor"]), 0.6),
			"[§4-20] 1 盏熄灭的灯 → light_factor == 0.6（0.36 = 被算了两次）")

	# ==================================================================
	# [§4-15] [§4-19] 进度**两个字段**
	# ==================================================================
	var player_packed: PackedScene = load(PLAYER_SCENE)
	_fails += _check(player_packed != null, "[§4-17] player.tscn 可加载")
	var player = null
	if player_packed != null:
		player = player_packed.instantiate()
		player.name = "1"
		player.position = Vector2(300, 300)
		players_root.add_child(player)
		player.set_spawn_position(Vector2(300, 300))
		player.set_rpc(rpc)
		player.set_players_root(players_root)
		player.set_hand([_make_behavior(&"steal_carrot", 1.5, false)])
		await process_frame

		# --- 进度是**活的**：不捣蛋时它自己会涨（客户端 = 操作方累积进度）---
		player.current_behavior_id = &"steal_carrot"
		player.current_target_id = 7
		player.current_mischief_progress = 0.0
		player.completed_mischief = 3
		var progress_before: float = player.current_mischief_progress
		for i in 20:
			await physics_frame
		_fails += _check(player.current_mischief_progress > progress_before,
			"[§4-15] 「进行中进度」是**活**的（20 帧后 0.00 → %.3f）"
			% player.current_mischief_progress)
		_fails += _check(player.current_mischief_progress < 1.0,
			"[§4-15] 前提：还没满 1.0（没提交出去）")

		# --- 被抓 → 进行中进度作废；已完成次数**不变** ---
		rpc.player_caught.rpc(1, 1)
		_fails += _check(player.escorted == true, "[§4-15] 被抓 → 进入被押送状态")
		_fails += _check(player.completed_mischief == 3,
			"[§4-15] 被抓后「已完成次数」**不变**（还是 3 —— 零失败惩罚）")
		_fails += _check(is_equal_approx(player.current_mischief_progress, 0.0),
			"[§4-15] 被抓后「进行中进度」**作废**（回到 0）")
		_fails += _check(player.current_behavior_id == &"",
			"[§4-15] 被抓后手上那条被清掉（那一条要重做）")
		# --- 两者是**不同的字段** ---
		_fails += _check(_script_props(player).has("completed_mischief")
				and _script_props(player).has("current_mischief_progress"),
			"[§4-15] 「已完成次数」与「进行中进度」是**两个不同的字段**")

		# ==================================================================
		# [§4-19] **不破坏** Task 9 的测试排除名单语义
		#
		# Task 9 的 test_guard_flow.gd 有一条断言：「押送期间玩家脚本变量除
		# escorted / _bob 外零变化」。本轮**不许改**既有 tools/test_*.gd
		# （派单 §1 的禁止清单 + 验收标准 §5.4），所以这里**复刻**那条断言。
		#
		# 做法：让「进行中进度」在**被抓的那一瞬间**就作废（而不是押送途中），
		# 于是押送期间它**本来就不变** → 原排除名单（escorted / _bob）依然
		# **完全正确**，「已完成次数」也仍然**留在受检集合里**。
		# ==================================================================
		var props_before := _script_props(player)
		for i in 30:
			await physics_frame
		var props_after := _script_props(player)
		var changed: Array = []
		for k in props_before.keys():
			var key := str(k)
			# escorted 是押送状态本身、_bob 是行走动画 —— 两者本来就会变。
			if key == "escorted" or key == "_bob":
				continue
			if not _same_value(props_before[k], props_after.get(k)):
				changed.append("%s: %s → %s" % [key, str(props_before[k]),
					str(props_after.get(k))])
		_fails += _check(changed.is_empty(),
			"[§4-19] 押送期间玩家脚本变量除 escorted/_bob 外**零变化**（复刻 Task 9 的断言）"
			+ ("　改动：" + ", ".join(changed) if not changed.is_empty() else ""))
		_fails += _check(_script_props(player).has("completed_mischief")
				and _script_props(player).has("current_mischief_progress"),
			"[§4-19] 「已完成次数」与「进行中进度」**都在受检集合里**（都没被排除）")

		# --- 两个字段彼此独立 ---
		player.completed_mischief = 9
		_fails += _check(is_equal_approx(player.current_mischief_progress, 0.0),
			"[§4-15] 改「已完成次数」**不影响**「进行中进度」（两个字段彼此独立）")

		# --- 成功结算 → 「已完成次数」+1 ---
		rpc.resolve_mischief.rpc(1, "steal_carrot", true, "ok")
		_fails += _check(player.completed_mischief == 10,
			"[§4-15] 结算成功 → 「已完成次数」+1（9 → 10）")

	# ==================================================================
	# [§4-17] **不破坏** Task 9 的契约
	# ==================================================================
	var rpc_src := _read_source(RPC_SRC)
	_fails += _check(rpc_src.contains(RPC_BLOCK_PLAYER_CAUGHT),
		"[§4-17] game_rpc.gd 的 player_caught **逐字未改**（含 @rpc 修饰符）")
	_fails += _check(rpc_src.contains(RPC_BLOCK_GUARD_STATE),
		"[§4-17] game_rpc.gd 的 guard_state **逐字未改**（含 @rpc 修饰符）")
	_fails += _check(rpc_src.contains(RPC_BLOCK_ESCORT_FINISHED),
		"[§4-17] game_rpc.gd 的 escort_finished **逐字未改**（含 @rpc 修饰符）")
	_fails += _check(_method_block(rpc_src, "player_caught").size() == 3,
		"[§4-17] player_caught 的方法块行数未变（3 行：@rpc + 签名 + 1 行方法体）")
	_fails += _check(_method_block(rpc_src, "guard_state").size() == 3,
		"[§4-17] guard_state 的方法块行数未变（3 行）")
	_fails += _check(_method_block(rpc_src, "escort_finished").size() == 3,
		"[§4-17] escort_finished 的方法块行数未变（3 行）")
	_fails += _check(rpc_src.contains("const HOST_PEER_ID := 1"),
		"[§4-17] HOST_PEER_ID 常量未改")
	_fails += _check(rpc_src.contains(
			"signal caught_player_evt(peer_id: int, guard_id: int)"),
		"[§4-17] 信号名 caught_player_evt 未改")
	_fails += _check(rpc_src.contains(
			"signal guard_state_evt(guard_id: int, state: int, position: Vector2, target_peer: int)"),
		"[§4-17] 信号名 guard_state_evt 未改")
	_fails += _check(rpc_src.contains("signal escort_completed_evt(peer_id: int)"),
		"[§4-17] 信号名 escort_completed_evt 未改")
	# ★ 新方法的 @rpc 传输模式要有断言钉住（否则下一个人改错了没人知道）
	_fails += _check(rpc_src.contains(RPC_BLOCK_SUBMIT),
		"[§4-17] submit_mischief 的 @rpc 传输模式被钉住（any_peer / call_remote / reliable）")
	_fails += _check(rpc_src.contains(RPC_BLOCK_RESOLVE),
		"[§4-17] resolve_mischief 的 @rpc 传输模式被钉住（authority / call_local / reliable）")
	# player.gd 的 Task 9 契约
	_fails += _check(player != null and _script_props(player).has("spawn_position"),
		"[§4-17] player.gd 的 spawn_position 仍在")
	_fails += _check(player != null and _script_props(player).has("escorted"),
		"[§4-17] player.gd 的 escorted 仍在")
	_fails += _check(player != null and player.has_method(&"set_spawn_position"),
		"[§4-17] player.gd 的 set_spawn_position() 仍在")
	_fails += _check(player != null and player.has_method(&"set_rpc"),
		"[§4-17] player.gd 的 set_rpc() 仍在")
	_fails += _check(player != null
			and is_equal_approx(player.ESCORT_ARRIVE_TOLERANCE, ESCORT_TOLERANCE),
		"[§4-17] player.gd 的 ESCORT_ARRIVE_TOLERANCE 未改（8.0）")
	_fails += _check(player != null and rpc.is_connected(&"caught_player_evt",
			Callable(player, "_on_caught_player_evt")),
		"[§4-17] set_rpc() 仍然接上 caught_player_evt（Task 9 的押送链路没被拆掉）")
	_fails += _check(player != null and rpc.is_connected(&"mischief_resolved_evt",
			Callable(player, "_on_mischief_resolved_evt")),
		"[§4-17] set_rpc() 接上了 mischief_resolved_evt（Task 10 的结算链路）")

	# ==================================================================
	# [§4-21] guard_wire_id 的分配规则
	# ==================================================================
	var guard_ids: Array = []
	for g in _read_json_array("res://data/guards.json"):
		guard_ids.append(StringName(str(g.get("id", ""))))
	var wire := Interaction.assign_guard_wire_ids(guard_ids)
	var wire_values: Array = []
	for k in wire.keys():
		wire_values.append(int(wire[k]))
	var unique: Dictionary = {}
	for v in wire_values:
		unique[v] = true
	_fails += _check(wire_values.size() == unique.size(),
		"[§4-21] 守卫的网络编号**唯一**（%s）" % str(wire_values))
	_fails += _check(Interaction.assign_guard_wire_ids(guard_ids) == wire,
		"[§4-21] 编号与 data/guards.json 的顺序**确定性绑定**（再算一次结果相同）")
	_fails += _check(guard_ids.size() == 1 and int(wire[guard_ids[0]]) == 1,
		"[§4-21] P1 只有 1 个守卫 → 编号 1（不是「依赖默认值」）")
	if guard != null:
		_fails += _check(int(guard.guard_wire_id)
				== int(wire[StringName(str(guard.guard_id))]),
			"[§4-21] 场景里的 guard_wire_id 与分配表一致")

	# ==================================================================
	# [§4-22] peer id 解析器**只有两套**，不许再添第三套
	# ==================================================================
	_fails += _check(rpc_src.contains("resolve_authority"),
		"[§4-22] game_rpc.gd 的 peer id 解析走 Player.resolve_authority()")
	_fails += _check(not rpc_src.contains("is_valid_int"),
		"[§4-22] game_rpc.gd 不自己写第三个解析器（不用宽松的 is_valid_int）")
	_fails += _check(PlayerScript.resolve_authority("007") == 1
			and PlayerScript.resolve_authority("7") == 7,
		"[§4-22] 严格解析器：\"007\" → 1（前导零兜底房主）、\"7\" → 7")
	# 行为证明："007" 在宽松口径下是 7；严格口径兜底成 1。
	var id_root := Node2D.new()
	id_root.name = "PlayersIds"
	root.add_child(id_root)
	var loose := Node2D.new()
	loose.name = "007"
	id_root.add_child(loose)
	var saved_players_root = rpc.players_root
	rpc.players_root = id_root
	rpc.adjudicate(7, &"steal_carrot", 21, 1.0)
	_fails += _check(is_equal_approx(
			float(rpc.last_mischief_context.get("nearest_guard_distance", -1.0)),
			Rules.NO_GUARD_NEAR_DISTANCE),
		"[§4-22] 宽松口径会把 \"007\" 当成 7；严格口径下 peer 7 **找不到**（证明用的是 Player.resolve_authority）")
	rpc.adjudicate(1, &"steal_carrot", 22, 1.0)
	_fails += _check(not is_equal_approx(
			float(rpc.last_mischief_context.get("nearest_guard_distance", -1.0)),
			Rules.NO_GUARD_NEAR_DISTANCE),
		"[§4-22] 同一个节点在严格口径下解析成 peer **1** → 能被找到")
	rpc.players_root = saved_players_root

	# ==================================================================
	# [§4-23] ★ submit_mischief() 是**生产入口**：完成瞬间才问询 Rules
	#
	# 派单 §2.5：「Rules.evaluate() 只在**完成瞬间**被问询（progress >= 1.0）」。
	# 生产调用点在 scripts/net/game_rpc.gd 的 submit_mischief() 里（progress 实参写死 1.0）。
	# → 这里**真的调一次那个入口**（不是调 adjudicate 旁路），
	#   断言它走的是**完成瞬间**（占台账 + 广播恰好一次），
	#   而不是 progress < 1.0 的 in_progress 早退（不占台账、不广播）。
	# ==================================================================
	var tid23 := 41
	var resolved_before23 := resolved.size()
	rpc.submit_mischief("steal_carrot", tid23)
	_fails += _check(rpc._ledger.is_claimed(tid23),
		"[§4-23] submit_mischief 走的是**完成瞬间**（progress = 1.0）→ 台账被占住")
	_fails += _check(rpc._ledger.owner_of(tid23) == rpc.multiplayer.get_unique_id(),
		"[§4-23] 台账里这个目标的归属是**本机**（房主）peer id")
	_fails += _check(resolved.size() == resolved_before23 + 1,
		"[§4-23] submit_mischief 触发**恰好一次** mischief_resolved_evt")
	if resolved.size() > resolved_before23:
		var ev23: Dictionary = resolved[resolved.size() - 1]
		var bid23 := StringName(str(ev23.get("behavior_id", "")))
		_fails += _check(not String(bid23).is_empty() and bid23 == &"steal_carrot",
			"[§4-23] 广播载荷里的 behavior_id **非空**且是真实的行为 id")
		_fails += _check(bool(ev23.get("success", false)),
			"[§4-23] 完成瞬间被裁决成**成功**（success == true）")
		_fails += _check(int(ev23.get("peer_id", -1)) == rpc._ledger.owner_of(tid23),
			"[§4-23] 台账与广播的 peer_id **一致**")

	# ==================================================================
	# [§4-24] ★ 房主自己的捣蛋走**本地投递分支**
	#
	# scripts/net/game_rpc.gd 的 send_submit_mischief() 里：
	#   if mp.get_unique_id() == HOST_PEER_ID: submit_mischief(...)  ← 房主本地
	#   else: submit_mischief.rpc_id(HOST_PEER_ID, ...)              ← 远端
	# submit_mischief 是 "call_remote" → **发送方本地不会执行**它
	# → 房主自己捣蛋时若不走本地分支，就**永远不会被裁决**（Task 9 踩过的同一个坑）。
	# 判据：离线环境里远端分支什么都不会发生 → 「目标被占住 + 广播了一次」
	#       就等于「走的是本地分支」。
	# ==================================================================
	var tid24 := 42
	var resolved_before24 := resolved.size()
	_fails += _check(rpc.multiplayer.get_unique_id() == 1,
		"[§4-24] 前提：本机就是房主（peer id == 1），才会走本地投递分支")
	rpc.send_submit_mischief("mess_chairs", tid24)
	_fails += _check(rpc._ledger.is_claimed(tid24),
		"[§4-24] 房主自己捣蛋 → 走**本地投递分支**（目标被占住；远端分支在离线环境里不会有任何事）")
	_fails += _check(rpc._ledger.owner_of(tid24) == rpc.multiplayer.get_unique_id(),
		"[§4-24] 本地投递的台账归属是**本机**（房主）")
	_fails += _check(resolved.size() == resolved_before24 + 1,
		"[§4-24] 房主本地投递 → 广播**恰好一次**")
	if resolved.size() > resolved_before24:
		var ev24: Dictionary = resolved[resolved.size() - 1]
		_fails += _check(StringName(str(ev24.get("behavior_id", ""))) == &"mess_chairs",
			"[§4-24] 广播载荷里的 behavior_id == \"mess_chairs\"")

	# ==================================================================
	# [§4-25] ★ progress 实参的**结构性**保险（对 §4-23 的补强，不是替代）
	#
	# 扫描 scripts/net/game_rpc.gd 的 submit_mischief 方法体：
	#   必须出现 adjudicate(..., 1.0) —— 第 4 个实参是**字面量 1.0**。
	# 扫描写成「切方法体 + 正则」→ 容忍空白与换行，不硬编码整行文本。
	# ==================================================================
	var submit_block := _method_block(rpc_src, "submit_mischief")
	var submit_text := ""
	for l in submit_block:
		submit_text += str(l) + "\n"
	var re_progress := RegEx.new()
	var re_ok := re_progress.compile(
		"adjudicate\\(\\s*[^,]+\\s*,\\s*[^,]+\\s*,\\s*[^,]+\\s*,\\s*1\\.0\\s*\\)")
	_fails += _check(submit_block.size() > 0,
		"[§4-25] 能取到 submit_mischief 的方法块")
	_fails += _check(re_ok == OK and re_progress.search(submit_text) != null,
		"[§4-25] submit_mischief 的 adjudicate() **第 4 个实参是字面量 1.0**")
	# ★ 只扫「**代码部分**」：先把注释剥掉（修复轮 2 Important 2）——
	#   否则生产代码**一个字没改**、只在方法体里加一句提到 0.5 的说明性注释 → 测试**假红**。
	var submit_code := _strip_comments(submit_text)
	_fails += _check(not submit_code.contains("0.5"),
		"[§4-25] submit_mischief 方法体的**代码部分**里不出现 0.5（注释不算）")
	# ★ §4-28：把「剥注释」这件事本身钉死（helper 改坏 → 又假红）。
	_fails += _check(not _strip_comments("var a = 1  # 进度阈值曾经写成 0.5").contains("0.5"),
		"[§4-28] 剥注释：**行尾注释**里的 0.5 不算进代码部分")
	_fails += _check(not _strip_comments("# 0.5\nvar b = 2").contains("0.5"),
		"[§4-28] 剥注释：**整行注释**里的 0.5 不算进代码部分")
	_fails += _check(_strip_comments("var s = \"# 0.5\"").contains("0.5"),
		"[§4-28] 剥注释：**字符串字面量**里的 # 不是注释起点（其中的 0.5 仍算代码）")
	# ★ §4-29：钉住「剥注释」的**另一半** —— §4-28 那三条只钉了「**必须**把注释剥掉」，
	#   压根没钉「**不许**把真代码一起剥掉」→ 于是一个「遇到 # 就把整行清空」的坏 helper
	#   照样让 §4-28 三条全绿（复审变异 M26：§4-25 的检测力被**静默关闭**，零条断言报警）。
	#   这里**反过来**钉：# **之前**的代码必须原样留在结果里。
	#   （与 §4-28 **不互为蕴含**：§4-28 管「必须剥」，§4-29 管「不许剥过头」；
	#     只剥过头 → M26；该剥不剥 → M27/M28 —— 两条合起来把 helper 行为**双向**钉死。）
	var s29_tail := _strip_comments("var x := compute()  # side note")
	_fails += _check(s29_tail.strip_edges() == "var x := compute()",
		"[§4-29] 剥注释：**行尾注释之前的真代码必须原样保留**（不许把真代码一起剥掉）")
	var s29_str := _strip_comments("var s = \"# 0.5\"  # side note")
	_fails += _check(s29_str.strip_edges() == "var s = \"# 0.5\"",
		"[§4-29] 剥注释：带**字符串字面量**的行，行尾注释也不许把前面的真代码一起剥掉")

	# ==================================================================
	# [§4-26] ★★ 房主**不许写**远端玩家的进度（行为断言，不是文本代理）
	#
	# 派单 §3.3：房主不写别人的进度（进度是**操作方自己**的数据）。
	# 反例（复审变异 M20）：房主在 adjudicate 里直接给远端玩家写 completed_mischief。
	# → 这里用**真的 Player 实例**（player.tscn，completed_mischief 是真实字段）
	#   当那个远端玩家，断言裁决走完之后它的 completed_mischief **仍然是 0**。
	#   （裸 Node2D 存不住 set("completed_mischief", …) → 断言会假绿，所以不能用裸节点。）
	# ==================================================================
	var remote_root := Node2D.new()
	remote_root.name = "RemotePlayers"
	root.add_child(remote_root)
	var remote_player = null
	if player_packed != null:
		remote_player = player_packed.instantiate()
		# ★ 节点名 = peer id（生产口径：scripts/player.gd 的 resolve_authority()）。
		#   必须叫 "7"：下面裁决的 peer 就是 7 → 严格解析器必须能把它解析成 **7**。
		#   （曾叫 "007" → 严格解析器兜底成 1 → 房主按**生产口径**根本找不到这个节点
		#    → 一次都不写 → §4-26 的断言**恒真** → 整族漏网。修复轮 2 Important 1。）
		remote_player.name = "7"
		remote_player.position = Vector2(600, 600)
		remote_root.add_child(remote_player)
		remote_player.set_physics_process(false)
		await process_frame
	_fails += _check(remote_player != null,
		"[§4-26] 前提：造得出一个**真的 Player 实例**当远端玩家")
	# ★ §4-27：把「假远端玩家的身份」钉死 —— 这是 §4-26 **成立的前提**。
	#   断言：它的节点名能被**严格解析器**（生产口径）解析成**被裁决的那个 peer id**。
	#   不钉这一条 → 下次有人把节点名改回 "007" → 房主找不到节点 → §4-26 又静默恒真。
	var remote_peer_strict := -1
	if remote_player != null:
		remote_peer_strict = int(PlayerScript.resolve_authority(str(remote_player.name)))
	_fails += _check(remote_peer_strict == 7 and remote_peer_strict != 1,
		"[§4-27] 前提：假远端玩家的节点名能被**严格解析器**解析成被裁决的 peer id 7（实际 %d；≠ 1 = 不被兜底成房主）"
		% remote_peer_strict)
	var saved_players_root26 = rpc.players_root
	rpc.players_root = remote_root
	var verdict26 := rpc.adjudicate(7, &"steal_carrot", 43, 1.0)
	rpc.players_root = saved_players_root26
	_fails += _check(str(verdict26.get("reason", "")) == "ok"
			and bool(verdict26.get("success", false)),
		"[§4-26] 前提：裁决确实走完了（reason == ok）→ 下面看房主有没有写远端玩家的进度")
	var remote_completed: Variant = null
	var remote_has_field := false
	if remote_player != null:
		remote_has_field = _script_props(remote_player).has("completed_mischief")
		remote_completed = remote_player.get("completed_mischief")
	_fails += _check(remote_has_field,
		"[§4-26] 前提：远端玩家节点带**真实的** completed_mischief 字段")
	_fails += _check(typeof(remote_completed) == TYPE_INT and int(remote_completed) == 0,
		"[§4-26] 房主**没有写**远端玩家的进度（completed_mischief 仍然是 0，实际 %s）"
		% str(remote_completed))
	_fails += _check(typeof(remote_completed) == TYPE_INT and int(remote_completed) != 999,
		"[§4-26] 远端玩家的进度没被房主改成 999（派单 §3.3：房主不许写远端玩家的进度）")
	if remote_player != null:
		remote_player.queue_free()
	remote_root.queue_free()

	# ==================================================================
	# [§4-13] 纯净化
	# ==================================================================
	var interaction_src := _read_source(INTERACTION_SRC)
	_fails += _check(not interaction_src.is_empty(), "[§4-13] interaction.gd 可读")
	_fails += _check(not interaction_src.contains("get_tree("),
		"[§4-13] interaction.gd 不出现 get_tree(")
	_fails += _check(not interaction_src.contains("get_node("),
		"[§4-13] interaction.gd 不出现 get_node(")
	for path in NEW_FILES:
		var src := _read_source(path)
		_fails += _check(not src.is_empty(), "[§4-13] %s 可读" % path)
		_fails += _check(not src.contains("Steam."),
			"[§4-13] %s 不出现 Steam. 调用" % path)
		for token in PENALTY_TOKENS:
			_fails += _check(not src.contains(token),
				"[§4-13] %s 不出现惩罚性 token「%s」" % [path, token])
		for token in PENALTY_WORD_TOKENS:
			_fails += _check(not _has_word(src, token),
				"[§4-13] %s 不出现惩罚性 token「%s」（独立词）" % [path, token])

	# ==================================================================
	# [§4-28] ★★ 按住 E 能**真的开一条捣蛋**（tag 与 id 两套口径不许错配）
	#
	# 背景（2026-11-05 用户报障：「只能乱逛不能捣乱」）：
	#   玩家站在道具上、手里有对得上的牌、E 也按住了，
	#   但 current_behavior_id 一直是空的 → 进度永远不动 → 捣蛋开不了头。
	#   根因：道具那边给的是 **tag**（"carrot"），
	#         而查手牌用的是**行为的 id**（"steal_carrot"）
	#         → 两套口径永远对不上 → 查不到 → return。
	#
	# ★ 这条**端到端**钉住：站位 + 按键 + 牌 + 道具全都到位时，
	#   捣蛋必须真的开起来（不许只测某个零件）。
	# ★ 玩家必须是**本地权威**（移动与捣蛋都只由拥有者算）。
	# ==================================================================
	# ★ 用**脚本内省**查静态方法（Interaction 是 class_name，不是实例，
	#   不能直接 has_method）。
	var interaction_script := load(INTERACTION_SRC) as GDScript
	var has_tag_api := false
	if interaction_script != null:
		for meth in interaction_script.get_script_method_list():
			if str(meth.get("name", "")) == "find_behavior_for_tag":
				has_tag_api = true
	_fails += _check(has_tag_api,
		"[§4-28] Interaction 提供 find_behavior_for_tag()（按道具 tag 找手牌）")
	if has_tag_api:
		# ★ 纯函数层的行为断言（tag → id 的翻译本身）
		var hand_two: Array = [
			_make_behavior_tagged(&"steal_carrot", &"carrot", 1.5, false),
			_make_behavior_tagged(&"noise_pot", &"pot", 0.5, false),
		]
		var found_carrot := Interaction.find_behavior_for_tag(hand_two, &"carrot")
		_fails += _check(found_carrot != null and found_carrot.id == &"steal_carrot",
			"[§4-28] 按道具的 tag 查到**对得上的那张牌**（carrot → steal_carrot）")
		_fails += _check(Interaction.find_behavior_for_tag(hand_two, &"lamp") == null,
			"[§4-28] 没有对得上的牌 → 返回 null（不乱开）")
		# 一手牌里两张卡打同一个道具（prank_pot 与 noise_pot 的 target_tag 都是 pot）
		var hand_pots: Array = [
			_make_behavior_tagged(&"prank_pot", &"pot", 2.0, false),
			_make_behavior_tagged(&"noise_pot", &"pot", 0.5, false),
		]
		var found_pot := Interaction.find_behavior_for_tag(hand_pots, &"pot")
		_fails += _check(found_pot != null and found_pot.id == &"prank_pot",
			"[§4-28] 两张卡打同一个道具 → 取**手牌顺序里的第一张**（确定、可预期）")
	if player_packed != null and prop_packed != null:
		var e2e_props := Node2D.new()
		e2e_props.name = "PropsE2E"
		root.add_child(e2e_props)
		var e2e_prop = prop_packed.instantiate()
		e2e_prop.prop_tag = &"carrot"
		e2e_prop.prop_id = 77
		e2e_prop.position = Vector2(500, 400)
		e2e_props.add_child(e2e_prop)
		var e2e_player = player_packed.instantiate()
		e2e_player.name = "9"
		e2e_player.position = Vector2(500, 400)
		root.add_child(e2e_player)
		await process_frame
		# 权威设成本机（peer id 1）：捣蛋只由**拥有者**推进。
		e2e_player.set_multiplayer_authority(1)
		e2e_player.call(&"set_props_root", e2e_props)
		e2e_player.call(&"set_hand", [_make_behavior(&"steal_carrot", 1.5, false)])
		await process_frame

		# 按住 E
		var key_ev := InputEventKey.new()
		key_ev.keycode = KEY_E
		key_ev.physical_keycode = KEY_E
		key_ev.pressed = true
		Input.parse_input_event(key_ev)
		await process_frame
		_fails += _check(Input.is_key_pressed(KEY_E),
			"[§4-28] 前提：E 键按住了")
		for i in 12:
			await physics_frame
		_fails += _check(StringName(str(e2e_player.get("current_behavior_id"))) == &"steal_carrot",
			"[§4-28] 站在对得上的道具上按住 E → 捣蛋**开得起来**"
			+ "（current_behavior_id = '%s'，期望 'steal_carrot'）"
			% str(e2e_player.get("current_behavior_id")))
		_fails += _check(int(e2e_player.get("current_target_id")) == 77,
			"[§4-28] 捣蛋锁定的是**眼前那个道具**（current_target_id = %d，期望 77）"
			% int(e2e_player.get("current_target_id")))
		_fails += _check(float(e2e_player.get("current_mischief_progress")) > 0.0,
			"[§4-28] 进度真的在涨（%.3f）"
			% float(e2e_player.get("current_mischief_progress")))
		# 松开 E（别把按键状态留给后面的断言）
		key_ev.pressed = false
		Input.parse_input_event(key_ev)
		await process_frame
		e2e_player.queue_free()
		e2e_prop.queue_free()
		e2e_props.queue_free()
		await process_frame

	# ==================================================================
	# 收尾：释放实例
	# ==================================================================
	if player != null:
		player.queue_free()
	if guard != null:
		guard.queue_free()
	if lamp_guard != null:
		lamp_guard.queue_free()
	if prop != null:
		prop.queue_free()
	if lamp_prop != null:
		lamp_prop.queue_free()
	# 脱离场景树的替身节点也要显式释放（Node 不是引用计数对象）。
	for n in [carrot, lamp, tie_a, tie_b]:
		var node := n as Node
		if node != null and is_instance_valid(node):
			node.free()
	rpc.queue_free()
	await process_frame

	print("")
	print("断言总数: %d" % _total)
	if _fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % _fails)
		quit(1)


## 造一个行为（纯数据；不依赖 data/mischief.json）。
func _make_behavior(id: StringName, duration: float, needs_partner: bool) -> Mischief:
	var m := Mischief.new()
	m.id = id
	m.title = String(id)
	m.category = &"test"
	m.target_tag = &"carrot"
	m.needs_partner = needs_partner
	m.duration = duration
	m.points = 10
	return m


## 造一个行为（**可指定 target_tag**）。
##
## ★ 与 _make_behavior() 的区别只有 target_tag ——
##   tag（道具那边）与 id（行为这边）是**两套口径**，测它们之间的翻译时
##   必须能分别指定（§4-28）。
func _make_behavior_tagged(id: StringName, target_tag: StringName, duration: float,
		needs_partner: bool) -> Mischief:
	var m := _make_behavior(id, duration, needs_partner)
	m.target_tag = target_tag
	return m


## 读源码（纯文本）。**换行符归一化**成 "\n"（LF）——
##
## ★ 为什么必须归一化：本文件里的 RPC_BLOCK_* 常量写死了 "\n"，
##   而 Windows 上 `git config core.autocrlf=true` 的**干净检出**会把工作区写成 CRLF
##   → "\n" 比不过 "\r\n" → §4-17 的「逐字比对」全红
##   → **同一个 commit 在干净检出上跑不过自己的测试**（断言结论依赖环境）。
##   → 读出来先把 CRLF / 裸 CR 统一成 LF，两种工作区的结论一致。
func _read_source(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text().replace("\r\n", "\n").replace("\r", "\n")


## 源码里有没有出现「作为一个独立词」的 token（**词边界**匹配）。
func _has_word(src: String, token: String) -> bool:
	var re := RegEx.new()
	if re.compile("\\b%s\\b" % token) != OK:
		return src.contains(token)
	return re.search(src) != null


## 读一个 JSON 数组文件（解析失败 / 不是数组 → 返回空数组）。
func _read_json_array(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_ARRAY:
		return []
	var out: Array = []
	for e in parsed:
		if typeof(e) == TYPE_DICTIONARY:
			out.append(e)
	return out


## 取出一个方法的方法块（含紧邻的 @rpc 修饰符行）。
##
## 规则：从 `func <name>(` 那行开始，往上并一行（如果是 @rpc(...)），
## 然后往下收集所有**缩进**的行；末尾的空行不算。
func _method_block(src: String, name: String) -> Array:
	var lines := src.split("\n")
	var func_at := -1
	for i in lines.size():
		if lines[i].begins_with("func %s(" % name):
			func_at = i
			break
	if func_at < 0:
		return []
	var start := func_at
	if start > 0 and lines[start - 1].strip_edges().begins_with("@rpc("):
		start -= 1
	var out: Array = []
	if start != func_at:
		out.append(lines[start])   # @rpc 修饰符行
	out.append(lines[func_at])      # func 签名行
	for i in range(func_at + 1, lines.size()):
		var raw: String = lines[i]
		if not raw.strip_edges().is_empty() and not raw.begins_with("\t"):
			break
		out.append(raw)
	while out.size() > 0 and str(out[out.size() - 1]).strip_edges().is_empty():
		out.pop_back()
	return out


## 把源码里的**注释**剥掉，只留**代码部分**。
##
## ★ 为什么需要（Task 10 修复轮 2 Important 2）：
##   「方法体里不出现某个字面量」这类**裸子串扫描**会把注释一起扫进去
##   → 生产代码**一个字没改**、只在方法体里加一句提到该字面量的说明性注释
##   → 测试**假红**（行为完全没变却被判红）。
##
## 规则：
##   * `#` 到行尾是注释（**整行注释**与**行尾注释**都剥掉）；
##   * **字符串字面量里的 `#` 不是注释起点**（否则会误删真正的代码）；
##   * 支持 "..." / '...' / """...""" 三种引号与反斜杠转义。
func _strip_comments(src: String) -> String:
	var out := ""
	var i := 0
	var n := src.length()
	while i < n:
		var ch := src[i]
		if ch == "\n":
			out += ch
			i += 1
			continue
		if ch == "#":
			while i < n and src[i] != "\n":
				i += 1
			continue
		if ch == "\"" or ch == "'":
			var quote := ch
			var triple := false
			if i + 2 < n and src[i + 1] == quote and src[i + 2] == quote:
				triple = true
			var q := quote
			if triple:
				q = quote + quote + quote
			out += q
			i += q.length()
			while i < n:
				var c2 := src[i]
				if c2 == "\\" and i + 1 < n:
					out += c2 + src[i + 1]
					i += 2
					continue
				out += c2
				i += 1
				if c2 != quote:
					continue
				if not triple:
					break
				if i + 1 < n and src[i] == quote and src[i + 1] == quote:
					out += src[i] + src[i + 1]
					i += 2
					break
			continue
		out += ch
		i += 1
	return out


## 对象的**脚本变量**快照（只取 PROPERTY_USAGE_SCRIPT_VARIABLE）。
func _script_props(obj: Object) -> Dictionary:
	var out: Dictionary = {}
	for p in obj.get_property_list():
		var usage := int(p.get("usage", 0))
		if (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		var key := str(p.get("name", ""))
		out[key] = obj.get(key)
	return out


## 两个值是否"算相等"（浮点用近似比较）。
func _same_value(a: Variant, b: Variant) -> bool:
	if typeof(a) == TYPE_FLOAT or typeof(b) == TYPE_FLOAT:
		return is_equal_approx(float(a), float(b))
	return a == b


## 载荷里有没有 Object / Resource（纯数据检查）。
func _payload_is_pure_data(payload: Dictionary) -> bool:
	for k in payload.keys():
		if typeof(k) != TYPE_STRING and typeof(k) != TYPE_STRING_NAME:
			return false
		var v: Variant = payload[k]
		if typeof(v) == TYPE_OBJECT or typeof(v) == TYPE_DICTIONARY \
				or typeof(v) == TYPE_ARRAY:
			return false
	return true


## 裁决返回值里有没有惩罚性字段（零失败惩罚）。
func _no_penalty_keys(verdict: Dictionary) -> bool:
	for k in verdict.keys():
		var key := str(k)
		for token in PENALTY_TOKENS:
			if key.contains(token):
				return false
		for token in PENALTY_WORD_TOKENS:
			if _has_word(key, token):
				return false
		var v: Variant = verdict[k]
		if typeof(v) == TYPE_STRING:
			for token in PENALTY_TOKENS:
				if str(v).contains(token):
					return false
	return true


func _check(ok: bool, what: String) -> int:
	_total += 1
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
