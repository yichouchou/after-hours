extends SceneTree

## Task 9：守卫实体、追击与「被抓送回出生点」—— 单元测试。
##
## 覆盖派单 §3 的 **12 组断言**（下面每段注释标了 [§3-N]）。
## 另加派单 §2 的 8 处计划更正的落点断言（标了 [§2-N]）。
##
## 本测试**不需要网络**：纯逻辑 + 场景实例化 → **一个端口都不开**。
##
## 权威模型（Task 9 裁决，务必别写反）：
##   * 玩家位置是**拥有者权威** → 房主不许直接写远端玩家的 position，
##     「送回出生点」由**被抓玩家自己**走（scripts/player.gd）。
##   * 守卫 AI 是**房主权威** → 客户端只按 guard_state 广播更新表现位置。
##   * 被抓**不清零**已完成的捣蛋次数（零失败惩罚）。

## game_rpc.gd 没有 class_name（与 net/ 下其它脚本同款）→ 这里用 preload。
const GameRpcScript := preload("res://scripts/net/game_rpc.gd")

const GUARD_SCENE := "res://scenes/guard.tscn"
const PLAYER_SCENE := "res://scenes/player.tscn"
const GUARD_SRC := "res://scripts/guard.gd"
const BRAIN_SRC := "res://scripts/game/guard_brain.gd"
const PLAYER_SRC := "res://scripts/player.gd"

## 惩罚性 token（零失败惩罚）。口径与 tools/test_player.gd 保持一致。
const PENALTY_TOKENS := ["penalty", "penalized", "score", "score_delta",
	"lives", "lives_lost", "eliminated", "damage", "扣分", "扣命", "淘汰", "死亡"]

## 两字母的惩罚性 token 必须按**词边界**匹配（子串扫会误伤无关标识符）。
const PENALTY_WORD_TOKENS := ["hp"]

## char_*.png 的不透明像素包围盒（**闭区间**口径）= (14, 7, 50, 63)
## → 画布内 alpha 中心 x = 32.0、alpha 底边 = 64（= 画布高度）。
const ALPHA_CENTER_X := 32.0
const ALPHA_BOTTOM := 64.0

## 押送到达出生点的容差（与 scripts/player.gd 的常量同值）。
const ESCORT_TOLERANCE := 8.0

var _fails := 0
var _total := 0

## 允许写入位置的**自有子节点**引用。
##
## 只有**自己**的 sprite 例外（走路动画的视觉偏移 —— 那不是别人的位置）。
const OWN_SPRITE := "sprite"


## 玩家替身：**不会自己移动**的最小节点。
##
## 为什么不用真的 Player：Player 自带移动逻辑（输入 / 被押送时自己走回出生点），
## 「玩家自己走」和「守卫拖走」就分不开了 → 测不出「房主有没有写玩家的位置」。
## 这里只多暴露一个 spawn_position 字段，让「把玩家拉回出生点」那种违规写法
## 在替身身上也能**真跑出来**（而不是报个引擎错误蒙混过关）。
class StationaryStandIn extends Node2D:
	var spawn_position: Vector2 = Vector2.ZERO


func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	# ==================================================================
	# [§3-1] begin_carry() → CARRY，且 target_peer 被保留
	# ==================================================================
	var b := GuardBrain.new()
	b.state = GuardBrain.State.CHASE
	b.target_peer = 4
	b.begin_carry()
	_fails += _check(b.state == GuardBrain.State.CARRY, "[§3-1] begin_carry() → state == CARRY")
	_fails += _check(b.target_peer == 4, "[§3-1] begin_carry() 保留 target_peer（仍是被抓的那位）")

	# ==================================================================
	# [§2-1] begin_carry() **无参**（计划正文三处不自洽，以无参为准）
	# ==================================================================
	_fails += _check(_method_arity(b, &"begin_carry") == 0,
		"[§2-1] begin_carry() 的参数个数是 0（不是 begin_carry(peer_id)）")

	# ==================================================================
	# [§3-2] finish_carry() → RETURN，怀疑度清零
	# ==================================================================
	b.suspicion = 1.5
	b.finish_carry()
	_fails += _check(b.state == GuardBrain.State.RETURN, "[§3-2] finish_carry() → state == RETURN")
	_fails += _check(is_equal_approx(b.suspicion, 0.0), "[§3-2] finish_carry() → suspicion == 0")

	# ==================================================================
	# [§3-3] RETURN + 不可见 + 无噪声 → 回到 PATROL
	# ==================================================================
	var b3 := GuardBrain.new()
	b3.state = GuardBrain.State.RETURN
	b3.suspicion = 0.4
	var r3: Dictionary = b3.update(0.016, _ctx(false))
	_fails += _check(int(r3["state"]) == GuardBrain.State.PATROL,
		"[§3-3] RETURN + 不可见 + 无噪声 → 回到 PATROL")

	# ==================================================================
	# [§3-4] CHASE 回落：跟丢（不可见 + 怀疑度归零）→ 不再是 CHASE
	# ==================================================================
	var b4 := GuardBrain.new()
	b4.state = GuardBrain.State.CHASE
	b4.suspicion = 0.0
	var r4: Dictionary = b4.update(0.016, _ctx(false))
	_fails += _check(int(r4["state"]) != GuardBrain.State.CHASE,
		"[§3-4] CHASE + 不可见 + 怀疑度归零 → 不再是 CHASE（跟丢有回落路径）")
	# 怀疑度从 0.5 衰减到 0 也要能回落（不是只有"本来就是 0"才回落）
	var b4b := GuardBrain.new()
	b4b.state = GuardBrain.State.CHASE
	b4b.suspicion = 0.5
	var r4b: Dictionary = b4b.update(0.5, _ctx(false))
	_fails += _check(is_equal_approx(float(r4b["suspicion"]), 0.0)
			and int(r4b["state"]) != GuardBrain.State.CHASE,
		"[§3-4] CHASE + 不可见 + 怀疑度衰减到 0 → 不再是 CHASE")

	# ==================================================================
	# [§3-5] CHASE + 可见 → 仍然是 CHASE（别把回落判据写反了）
	# ==================================================================
	var b5 := GuardBrain.new()
	b5.state = GuardBrain.State.CHASE
	b5.suspicion = 0.0
	var r5: Dictionary = b5.update(0.016, _ctx(true, Vector2(80, 0), 3))
	_fails += _check(int(r5["state"]) == GuardBrain.State.CHASE,
		"[§3-5] CHASE + 可见 → 仍然是 CHASE")
	_fails += _check(int(r5["target_peer"]) == 3, "[§3-5] 可见时锁定目标 peer")

	# ==================================================================
	# [§3-6] catch_player 的触发条件：距离 ≤ CATCH_DISTANCE **且** 可见
	# ==================================================================
	var c_near := GuardBrain.new().update(0.016, _ctx(true, Vector2(24, 0), 5))
	_fails += _check(bool(c_near["catch_player"]),
		"[§3-6] 距离正好 24 px（== CATCH_DISTANCE）→ 判定抓获（边界值钉住）")
	var c_just := GuardBrain.new().update(0.016, _ctx(true, Vector2(24.01, 0), 5))
	_fails += _check(not bool(c_just["catch_player"]),
		"[§3-6] 距离 24.01 px → 不判定抓获")
	var c_far := GuardBrain.new().update(0.016, _ctx(true, Vector2(50, 0), 5))
	_fails += _check(not bool(c_far["catch_player"]),
		"[§3-6] 距离 50 px → 不判定抓获")
	var c_blind := GuardBrain.new().update(0.016, _ctx(false, Vector2.ZERO, 5))
	_fails += _check(not bool(c_blind["catch_player"]),
		"[§3-6] 看不见玩家 → 即使重合也不判定抓获")

	# ==================================================================
	# [§3-7] light_factor 各档位
	# ==================================================================
	var g0 := Vector2.ZERO
	_fails += _check(is_equal_approx(GuardBrain.compute_light_factor(g0, []), 1.0),
		"[§3-7] 0 盏灯 → light_factor == 1.0")
	_fails += _check(is_equal_approx(GuardBrain.compute_light_factor(g0,
			[{"position": Vector2(10, 0), "on": false}]), 0.6),
		"[§3-7] 1 盏熄灭（在范围内）→ light_factor == 0.6")
	_fails += _check(is_equal_approx(GuardBrain.compute_light_factor(g0,
			[{"position": Vector2(10, 0), "on": false},
			{"position": Vector2(-10, 0), "on": false}]), 0.36),
		"[§3-7] 2 盏熄灭 → light_factor == 0.36")
	_fails += _check(is_equal_approx(GuardBrain.compute_light_factor(g0,
			[{"position": Vector2(10, 0), "on": false},
			{"position": Vector2(-10, 0), "on": false},
			{"position": Vector2(0, 10), "on": false}]), 0.216),
		"[§3-7] 3 盏熄灭 → light_factor == 0.216")
	_fails += _check(is_equal_approx(GuardBrain.compute_light_factor(g0,
			[{"position": Vector2(200, 0), "on": false}]), 1.0),
		"[§3-7] 熄灭的灯在**范围外** → 不影响")
	_fails += _check(is_equal_approx(GuardBrain.compute_light_factor(g0,
			[{"position": Vector2(10, 0), "on": true}]), 1.0),
		"[§3-7] **亮着的**灯 → 不影响")
	_fails += _check(is_equal_approx(GuardBrain.compute_light_factor(g0,
			[{"position": Vector2(160, 0), "on": false}]), 0.6),
		"[§3-7] 正好 160 px（5 格，边界含）→ 影响")
	_fails += _check(is_equal_approx(GuardBrain.compute_light_factor(g0,
			[{"position": Vector2(160.01, 0), "on": false}]), 1.0),
		"[§3-7] 160.01 px（刚出界）→ 不影响")
	_fails += _check(is_equal_approx(GuardBrain.effective_sight_range(96.0, 0.6), 57.6),
		"[§3-7] 熄灭 1 盏灯 → 实际视野 96 → 57.6")

	# ==================================================================
	# [§3-8] 跨层等值：Rules.CATCH_DISTANCE == GuardBrain.CATCH_DISTANCE
	#        （Task 5 留下的欠账，本任务补）
	# ==================================================================
	_fails += _check(Rules.CATCH_DISTANCE == GuardBrain.CATCH_DISTANCE,
		"[§3-8] Rules.CATCH_DISTANCE == GuardBrain.CATCH_DISTANCE（都是 24.0）")

	# ==================================================================
	# [§3-11] guard.tscn 可 load() 且 instantiate() 不报错
	# ==================================================================
	var guard_packed: PackedScene = load(GUARD_SCENE)
	_fails += _check(guard_packed != null, "[§3-11] guard.tscn 可加载")
	var player_packed: PackedScene = load(PLAYER_SCENE)
	_fails += _check(player_packed != null, "[§3-11] player.tscn 可加载（押送链路要用）")
	var guard = null
	if guard_packed != null:
		guard = guard_packed.instantiate()
		_fails += _check(guard != null, "[§3-11] guard.tscn 可实例化")

	# ==================================================================
	# [§2.7] 守卫贴图对齐：centered = false 必须显式写
	# ==================================================================
	if guard != null:
		var g_sprite = guard.get_node_or_null("Sprite2D")
		_fails += _check(g_sprite != null, "[§2.7] 守卫带 Sprite2D")
		if g_sprite != null:
			var rect: Rect2 = g_sprite.get_rect()
			_fails += _check(g_sprite.centered == false,
				"[§2.7] Sprite2D.centered == false（默认 true → 脚底浮空 32 px、偏左半个身位）")
			_fails += _check(rect.position.y + rect.size.y == 0.0,
				"[§2.7] 贴图绘制底落在地面 y = 0（rect %s）" % str(rect))
			_fails += _check(absf(rect.position.x + ALPHA_CENTER_X) <= 2.0,
				"[§2.7] 视觉中心基本居中（|rect.x + %.1f| ≤ 2，实测 %.3f）"
				% [ALPHA_CENTER_X, absf(rect.position.x + ALPHA_CENTER_X)])
			var bbox := _alpha_bbox(g_sprite.texture)
			_fails += _check(not bbox.is_empty(), "[§2.7] 能算出守卫贴图的不透明像素包围盒")
			if not bbox.is_empty():
				var alpha_bottom: float = rect.position.y + float(bbox[3]) + 1.0
				var alpha_center_x: float = rect.position.x + (
						float(bbox[0]) + float(bbox[2])) * 0.5
				_fails += _check(absf(alpha_bottom) <= 0.001,
					"[§2.7] alpha 脚底落在地面 y = 0（局部实测 %.3f）" % alpha_bottom)
				_fails += _check(absf((float(bbox[3]) + 1.0) - ALPHA_BOTTOM) <= 0.001,
					"[§2.7] 不透明像素一直画到画布底边（画布内 %.1f）" % ALPHA_BOTTOM)
				_fails += _check(absf(alpha_center_x) <= 2.0,
					"[§2.7] alpha 视觉中心基本居中（实测局部 %.3f）" % alpha_center_x)

	# ==================================================================
	# [§2.6] 场景层的「拔路灯」管线：熄灭的灯 → light_factor → 视野变小
	# ==================================================================
	var light_guard = null
	var light_player = null
	if guard_packed != null:
		var players_root_l := Node2D.new()
		players_root_l.name = "PlayersLight"
		root.add_child(players_root_l)
		light_player = player_packed.instantiate()
		light_player.name = "7"
		light_player.position = Vector2(80, 0)
		players_root_l.add_child(light_player)
		light_guard = guard_packed.instantiate()
		light_guard.position = Vector2.ZERO
		root.add_child(light_guard)
		light_guard.set_player_root(players_root_l)
		light_guard.set_physics_process(false)
		await process_frame
		var ctx_bright: Dictionary = light_guard._sense_context()
		_fails += _check(is_equal_approx(float(ctx_bright["light_factor"]), 1.0),
			"[§2.6] 没有灯 → 场景层算出的 light_factor == 1.0")
		_fails += _check(bool(ctx_bright["player_visible"]),
			"[§2.6] 全亮时 80 px 处的玩家**看得见**（场景层自己算可见性）")
		light_guard.set_lamps([{"position": Vector2(20, 0), "on": false}])
		var ctx_dark: Dictionary = light_guard._sense_context()
		_fails += _check(is_equal_approx(float(ctx_dark["light_factor"]), 0.6),
			"[§2.6] 注入 1 盏熄灭的路灯 → light_factor == 0.6（不是写死 1.0）")
		_fails += _check(not bool(ctx_dark["player_visible"]),
			"[§2.6] 熄灭 1 盏灯 → 视野 96 → 57.6 → 80 px 处的玩家**看不见**了")

	# ==================================================================
	# [§2.8] 显式巡逻点：非空就按顺序走这些点
	# ==================================================================
	var patrol_guard = null
	if guard_packed != null:
		patrol_guard = guard_packed.instantiate()
		patrol_guard.position = Vector2.ZERO
		# 必须是**带类型**的数组：Array[Vector2] 属性不接受普通 Array。
		var patrol_pts: Array[Vector2] = [Vector2(100, 0), Vector2(200, 0)]
		patrol_guard.patrol_points = patrol_pts
		root.add_child(patrol_guard)
		patrol_guard.set_physics_process(false)
		await process_frame
		# 显式巡逻点是**循环**的（走到最后回到第一个），
		# 所以断言的是"按顺序都走到了"，不是"停在最后一个点"。
		var first_frame := -1
		var last_frame := -1
		for i in 400:
			patrol_guard.call("_physics_process", 0.05)
			if first_frame < 0 and patrol_guard.position.distance_to(Vector2(100, 0)) <= 5.0:
				first_frame = i
			if last_frame < 0 and patrol_guard.position.distance_to(Vector2(200, 0)) <= 5.0:
				last_frame = i
		_fails += _check(first_frame >= 0,
			"[§2.8] 显式巡逻点：守卫走到了第一个点（100, 0）")
		_fails += _check(last_frame >= 0,
			"[§2.8] 显式巡逻点：守卫走到了最后一个点（200, 0）")
		_fails += _check(first_frame >= 0 and last_frame >= 0 and first_frame < last_frame,
			"[§2.8] 显式巡逻点：**按顺序**走（第 1 个点先于第 2 个点，帧号 %d → %d）"
			% [first_frame, last_frame])

	# ==================================================================
	# [§3-9] 被押送链路：房主抓到 → 玩家自己走回自己的出生点 → 回报 → 房主 finish_carry
	# ==================================================================
	var rpc := GameRpcScript.new()
	rpc.name = "GameRpc"
	root.add_child(rpc)

	var guard_states: Array = []
	rpc.guard_state_evt.connect(func(guard_id: int, state: int, position: Vector2,
			target_peer: int) -> void:
		guard_states.append({"id": guard_id, "state": state,
			"position": position, "target": target_peer}))

	var players_root := Node2D.new()
	players_root.name = "Players"
	root.add_child(players_root)

	var player = null
	if player_packed != null:
		player = player_packed.instantiate()
		player.name = "1"
		player.position = Vector2(200, 288)
		# 出生点：Task 11 注入真值；这里先注入一个固定的，验证「自己的出生点」
		player.set_spawn_position(Vector2(64, 288))
		players_root.add_child(player)
		player.set_rpc(rpc)
	await process_frame

	var escort_guard = null
	if guard_packed != null:
		escort_guard = guard_packed.instantiate()
		escort_guard.position = Vector2(190, 288)
		root.add_child(escort_guard)
		escort_guard.set_player_root(players_root)
		escort_guard.set_rpc(rpc)
		# 测试里手动驱动 _physics_process（避免自动巡逻干扰断言）
		escort_guard.set_physics_process(false)
	await process_frame

	if player != null and escort_guard != null:
		# --- 房主侧：守卫自己发现并抓到玩家（走真实的 _physics_process 路径）---
		escort_guard.call("_physics_process", 0.05)
		_fails += _check(escort_guard.brain.state == GuardBrain.State.CARRY,
			"[§3-9] 守卫抓到玩家 → brain.begin_carry() → CARRY")
		_fails += _check(escort_guard.brain.target_peer == 1,
			"[§3-9] 守卫锁定的目标 peer == 1")
		_fails += _check(player.escorted == true,
			"[§3-9] 房主广播 player_caught → 玩家进入被押送状态")

		# --- [§2.5] guard_state 广播（客户端据此更新表现位置）---
		_fails += _check(guard_states.size() >= 1,
			"[§2.5] 守卫把状态/位置广播出去（guard_state）")
		if guard_states.size() >= 1:
			var gs: Dictionary = guard_states[guard_states.size() - 1]
			var gs_pos: Vector2 = gs["position"]
			_fails += _check(int(gs["id"]) == int(escort_guard.guard_wire_id),
				"[§2.5] guard_state 载荷的 guard_id 正确")
			_fails += _check(int(gs["state"]) == GuardBrain.State.CARRY,
				"[§2.5] guard_state 载荷的状态正确")
			_fails += _check(gs_pos == escort_guard.global_position,
				"[§2.5] guard_state 载荷的位置正确")

		# --- 被押送：输入被禁用 + 自己朝自己的出生点走 ---
		var props_before := _script_props(player)
		var before_pos: Vector2 = player.position
		Input.action_press("ui_right")
		for i in 20:
			await physics_frame
		_fails += _check(player.escorted == true,
			"[§3-9] 走回出生点途中仍处于被押送状态")
		_fails += _check(player.position.x < before_pos.x - 1.0,
			"[§3-9] 被押送时**输入被禁用**（按了 ui_right 却朝出生点走，向左位移 %.2f px）"
			% (before_pos.x - player.position.x))
		_fails += _check(player.position.distance_to(Vector2(64, 288))
				< before_pos.distance_to(Vector2(64, 288)),
			"[§3-9] 被押送时自己朝**自己的出生点**移动（距离缩短）")

		# --- 走到出生点 → 押送结束 → 向房主回报 ---
		var arrived := false
		for i in 400:
			await physics_frame
			if not player.escorted:
				arrived = true
				break
		Input.action_release("ui_right")
		_fails += _check(arrived, "[§3-9] 玩家走回自己的出生点 → 押送结束")
		_fails += _check(player.position.distance_to(Vector2(64, 288)) <= ESCORT_TOLERANCE + 0.001,
			"[§3-9] 到达判定有明确容差（距出生点 %.2f px ≤ %.1f）"
			% [player.position.distance_to(Vector2(64, 288)), ESCORT_TOLERANCE])

		# --- 房主侧：收到回报 → finish_carry() → RETURN ---
		_fails += _check(escort_guard.brain.state == GuardBrain.State.RETURN,
			"[§3-9] 房主收到 escort_finished → finish_carry() → RETURN")

		# --- 进度不清零（零失败惩罚）---
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
			"[§3-9] 押送流程**没有改动任何进度类字段**（进度不清零）"
			+ ("　改动：" + ", ".join(changed) if not changed.is_empty() else ""))

		# --- 守卫走回岗位 → 回到 PATROL ---
		escort_guard.call("_physics_process", 0.05)
		_fails += _check(escort_guard.brain.state == GuardBrain.State.PATROL,
			"[§3-9] 守卫走回岗位 → 回到 PATROL")

		# --- 房主不许直接写玩家的位置（位置是拥有者权威）---
		_fails += _check(not _src_contains(GUARD_SRC, "spawn_position"),
			"[§3-9] 房主侧不碰玩家的出生点（送回出生点由玩家自己执行）")
		_fails += _check(_src_contains(PLAYER_SRC, "spawn_position"),
			"[§3-9] 玩家侧持有自己的出生点（spawn_position）")

	# ==================================================================
	# [§3-9b] 行为断言：房主**不许**写远端玩家的位置（位置是拥有者权威）
	#
	# 为什么要有这一段：以前这条 Critical 级规则只有一条**文本代理**
	# （查 guard.gd 里有没有 "spawn_position" 这个词）。房主真写
	# `pl.global_position` 时，那个词根本不出现 → 词扫描查不出来
	# （复审变异 M7a 实测：整套断言仍然全绿）。
	#
	# 这里改成**行为**证明：
	#   * 替身 = **不会自己移动**的最小 Node2D（不是 Player —— Player 自带
	#     移动逻辑，「玩家自己走」和「守卫拖走」就分不开）；
	#   * 替身挂在守卫注入的 player_root 下、节点名 = peer id（"1"），
	#     所以守卫**真的**能看见它、锁定它、走到它面前；
	#   * 让**引擎逐帧**驱动守卫的 _physics_process，跑完整段流程：
	#     看见 → CHASE 追击 → 抓人 → CARRY → 跟随；
	#   * **每一帧**都核对替身的位置 → 断言它**一帧都没被改动**。
	#
	# 机制：守卫只会**读**玩家位置（_player_position），然后自己走过去；
	#       房主一旦写替身的位置（M7a 拉过去 / M7b 瞬移），替身就动了
	#       → 断言立刻 FAIL。
	# ==================================================================
	var beh_root := Node2D.new()
	beh_root.name = "PlayersBehavior"
	root.add_child(beh_root)
	# 替身的**基准位置是常量**，不是「稍后再读一次节点的位置」——
	# 否则守卫有机会在观察窗口开始前就改写它，而断言却拿「改写后的值」
	# 当基准（反向自检 M7a 实测踩过这个坑：核心断言会假绿）。
	var beh_expected := Vector2(60, 0)
	var beh_sub := StationaryStandIn.new()
	beh_sub.name = "1"        # 玩家容器按 peer id 命名（守卫靠名字取人）
	beh_sub.position = beh_expected
	beh_sub.spawn_position = Vector2(64, 288)
	beh_root.add_child(beh_sub)

	var beh_caught: Array = []
	var beh_guard = null
	if guard_packed != null:
		beh_guard = guard_packed.instantiate()
		beh_guard.position = Vector2.ZERO
		root.add_child(beh_guard)
		beh_guard.set_player_root(beh_root)
		# 让**引擎**驱动 _physics_process（真实逐帧，不手动调）——
		# 这样走的确实是生产代码的那条路径。
		beh_guard.set_physics_process(true)
		beh_guard.caught_player.connect(func(peer_id: int) -> void:
			beh_caught.append(peer_id))

	if beh_guard != null:
		# 前提检查放在**第一次 await 之前**：守卫还没跑过一帧，
		# 这里量到的就是「场景刚搭好」的状态。
		var beh_ctx: Dictionary = beh_guard._sense_context()
		_fails += _check(bool(beh_ctx["player_visible"]),
			"[§3-9b] 前提：替身在守卫的视野内（守卫真的看得见它）")
		_fails += _check(int(beh_ctx["target_peer"]) == 1,
			"[§3-9b] 前提：守卫按 peer id 锁定了替身（target_peer == 1）")
		_fails += _check(beh_sub.global_position == beh_expected,
			"[§3-9b] 前提：替身还在基准位置 %s（守卫没在我开跑前就动过它）"
			% str(beh_expected))

		var beh_moved_at := -1
		var beh_moved_to := Vector2.ZERO
		var beh_carry_frames := 0
		var beh_saw_carry := false
		var beh_min_gap := 1.0e9
		for i in 100:
			await physics_frame
			var beh_now := beh_sub.global_position
			if beh_now != beh_expected and beh_moved_at < 0:
				beh_moved_at = i
				beh_moved_to = beh_now
			if beh_guard.brain.state == GuardBrain.State.CARRY:
				beh_carry_frames += 1
				beh_saw_carry = true
			beh_min_gap = minf(beh_min_gap,
				beh_guard.global_position.distance_to(beh_sub.global_position))

		_fails += _check(beh_caught.size() >= 1 and int(beh_caught[0]) == 1,
			"[§3-9b] 守卫发出了 caught_player(1)（真的走进了「抓人」分支）")
		_fails += _check(beh_saw_carry,
			"[§3-9b] 抓到人 → brain.begin_carry() → 进入 CARRY")
		_fails += _check(beh_carry_frames >= 10,
			"[§3-9b] CARRY/跟随阶段持续了 %d 帧（跟随路径被走到，不是只走了一帧）"
			% beh_carry_frames)
		_fails += _check(beh_min_gap <= GuardBrain.CATCH_DISTANCE,
			"[§3-9b] 守卫**自己走过去**了（离替身最近 %.2f px ≤ 抓人距离 %.1f px）"
			% [beh_min_gap, GuardBrain.CATCH_DISTANCE])
		_fails += _check(beh_moved_at < 0,
			"[§3-9b] **替身的位置一帧都没被守卫改动**（房主不写远端玩家的位置）"
			+ ("" if beh_moved_at < 0
				else "　第 %d 帧被改成 %s" % [beh_moved_at, str(beh_moved_to)]))
		_fails += _check(beh_sub.global_position == beh_expected,
			"[§3-9b] 押送全程结束后替身仍在基准位置 %s（实际 %s）"
			% [str(beh_expected), str(beh_sub.global_position)])

	# ==================================================================
	# [§3-10] scripts/guard.gd 源码净化
	# ==================================================================
	var guard_src := _read_source(GUARD_SRC)
	_fails += _check(not guard_src.is_empty(), "[§3-10] guard.gd 可读")
	_fails += _check(not guard_src.contains("Steam."), "[§3-10] guard.gd 不出现 Steam. 调用")
	for token in PENALTY_TOKENS:
		_fails += _check(not guard_src.contains(token),
			"[§3-10] guard.gd 不出现惩罚性 token「%s」" % token)
	for token in PENALTY_WORD_TOKENS:
		_fails += _check(not _has_word(guard_src, token),
			"[§3-10] guard.gd 不出现惩罚性 token「%s」（独立词）" % token)
	_fails += _check(not guard_src.contains("\"/root/"),
		"[§3-10] guard.gd 不出现硬编码绝对路径 \"/root/…\"")
	_fails += _check(not guard_src.contains("get_node(\"/"),
		"[§3-10] guard.gd 不出现 get_node(\"/…\") 这类绝对路径取节点")
	_fails += _check(not _src_contains(GUARD_SRC, "scenes/game.tscn"),
		"[§3-10] guard.gd 不引用 scenes/game.tscn（那是 Task 11 的）")

	# ==================================================================
	# [§3-12] scripts/game/guard_brain.gd 必须是纯逻辑层
	# ==================================================================
	var brain_src := _read_source(BRAIN_SRC)
	_fails += _check(not brain_src.is_empty(), "[§3-12] guard_brain.gd 可读")
	_fails += _check(not brain_src.contains("get_tree("),
		"[§3-12] guard_brain.gd 不出现 get_tree(")
	_fails += _check(not brain_src.contains("get_node("),
		"[§3-12] guard_brain.gd 不出现 get_node(")

	# ==================================================================
	# [§3-13] 结构性扫描：**位置写入**（不是查某个词）
	#
	# 规则：
	#   * scripts/guard.gd 里**任何**对**别的对象**的位置写入都不允许 ——
	#     房主不许写远端玩家的 position / global_position（位置是拥有者权威）。
	#     只有**自身**的 `global_position = …`（不带接收者）可以。
	#   * scripts/player.gd 同理：它也不该写**别的玩家**的位置；
	#     唯一例外是**自己**的 sprite（走路动画的视觉偏移）。
	#
	# 为什么不能只查某个词：房主真写 `pl.global_position` 时，源码里根本不出现
	# "spawn_position" → 词扫描查不出来（复审变异 M7a 实测：80 条断言全绿）。
	# 这里查的是**赋值形态**：谁的位置被写了。
	# ==================================================================
	var guard_writes := _position_writes(_read_source(GUARD_SRC), [OWN_SPRITE])
	var guard_foreign := _foreign_writes(guard_writes)
	_fails += _check(guard_foreign.is_empty(),
		"[§3-13] 结构性扫描：guard.gd 里没有对**别的对象**的位置写入"
		+ _writes_msg(guard_writes, guard_foreign))
	var player_writes := _position_writes(_read_source(PLAYER_SRC), [OWN_SPRITE])
	var player_foreign := _foreign_writes(player_writes)
	_fails += _check(player_foreign.is_empty(),
		"[§3-13] 结构性扫描：player.gd 里没有对**别的玩家**的位置写入"
		+ _writes_msg(player_writes, player_foreign))

	# 扫描器自检：正则不能是「空转」的（否则上面两条断言永远是绿的）。
	var probe_src := "\tpl.global_position = Vector2.ZERO\n\tpl.set_position(Vector2.ZERO)\n\tsprite.position.y = 1.0\n"
	var probe_foreign := _foreign_writes(_position_writes(probe_src))
	_fails += _check(probe_foreign.size() == 3,
		"[§3-13] 扫描器自检：能识别 3 种外来位置写入形态"
		+ "（`<对象>.global_position =` / `<对象>.set_position(` / `<对象>.position.y =`）"
		+ "　实扫到 %d 处：%s" % [probe_foreign.size(), _fmt_writes(probe_foreign)])
	var probe_allowed := _foreign_writes(_position_writes(probe_src, [OWN_SPRITE]))
	_fails += _check(probe_allowed.size() == 2,
		"[§3-13] 扫描器自检：豁免名单生效（自有子节点 %s 不算外来写入）"
		% OWN_SPRITE
		+ "　豁免后实扫到 %d 处" % probe_allowed.size())

	# ==================================================================
	# [GF-1] 守卫巡逻时**不许旋转整个节点** —— 否则人物绕着脚底翻倒
	#
	# 现象（2026-11-04 用户截图）：守卫老陈侧躺在地上，像具尸体。
	# 根因：guard.gd 用 `rotation = lerp_angle(rotation, 移动方向, ...)`
	#       直接转**节点** → 贴图连同 offset(-32,-64) 一起转 →
	#       人物绕着自己的脚底翻过去。
	#       （而且客户端那个守卫靠广播更新位置、根本不转 → 两端长得不一样。）
	# 修法：朝向改用独立字段（视野锥照旧用它），节点永远不转。
	#
	# ★ 断言盯的是**可观测的后果**（人物直立），不是实现细节：
	#   * 节点 rotation 保持 0
	#   * 贴图 global_rotation 保持 0（直立）
	#   * 巡逻照旧在动（不能为了不翻倒把 AI 停了）
	#   * 朝向仍然跟着走动方向变（视野锥不能失效）
	# ==================================================================
	var up_guard = null
	if guard_packed != null:
		up_guard = guard_packed.instantiate()
		up_guard.position = Vector2(400, 300)
		root.add_child(up_guard)
		await process_frame
		# 手动驱动（与本文件的巡逻用例同款：不让引擎自动跑，避免时序不确定）。
		# ★ 必须在 _ready() **之后**关：_ready() 里有一句 set_physics_process(...)，
		#   先关后开等于没关 → 引擎会跟手动驱动叠着跑（实测位移会差出 3 倍）。
		up_guard.set_physics_process(false)
		var up_before: Vector2 = up_guard.position
		var up_sprite = up_guard.get_node_or_null("Sprite2D")
		var up_facing_first := Vector2.ZERO
		for i in 120:
			up_guard.call("_physics_process", 1.0 / 60.0)
			if i == 30:
				up_facing_first = up_guard._sense_context()["guard_facing"]
		var up_facing_last: Vector2 = up_guard._sense_context()["guard_facing"]
		var up_moved: float = up_guard.position.distance_to(up_before)
		_fails += _check(up_moved > 1.0,
			"[GF-1] 巡逻照旧在动（位移 %.2f px）—— 不能为了不翻倒把 AI 停了" % up_moved)
		_fails += _check(absf(up_guard.rotation) < 0.01,
			"[GF-1] ★守卫节点**不旋转**（rotation = %.4f）—— 人物不会绕着脚底翻倒"
			% up_guard.rotation)
		if up_sprite != null:
			_fails += _check(absf(up_sprite.global_rotation) < 0.01,
				"[GF-1] ★贴图保持直立（global_rotation = %.4f）" % up_sprite.global_rotation)
		else:
			_fails += _check(false, "[GF-1] 守卫带 Sprite2D")
		var up_turn: float = absf(up_facing_first.angle_to(up_facing_last))
		_fails += _check(up_turn > 0.05,
			"[GF-1] 朝向仍然跟着走动方向变（转了 %.4f 弧度）—— 视野锥没失效" % up_turn)
		up_guard.queue_free()
		await process_frame

	# ==================================================================
	# 收尾：释放实例
	# ==================================================================
	if player != null:
		player.queue_free()
	if escort_guard != null:
		escort_guard.queue_free()
	if light_guard != null:
		light_guard.queue_free()
	if light_player != null:
		light_player.queue_free()
	if patrol_guard != null:
		patrol_guard.queue_free()
	if beh_guard != null:
		beh_guard.queue_free()
	if beh_sub != null:
		beh_sub.queue_free()
	if guard != null:
		guard.queue_free()
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


## 组装一份给纯逻辑用的世界快照。
func _ctx(visible: bool, player_pos: Vector2 = Vector2.ZERO, target_peer: int = 0) -> Dictionary:
	return {
		"guard_pos": Vector2.ZERO, "guard_facing": Vector2.RIGHT,
		"player_pos": player_pos, "player_visible": visible,
		"noise_pos": Vector2.ZERO, "noise_active": false,
		"sight_range": 100.0, "sight_angle_deg": 80.0,
		"hearing_range": 0.0, "target_peer": target_peer,
		"light_factor": 1.0,
	}


## 读源码（纯文本）。
func _read_source(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


## 源码里有没有出现某个片段。
func _src_contains(path: String, needle: String) -> bool:
	return _read_source(path).contains(needle)


## 源码里有没有出现「作为一个独立词」的 token（**词边界**匹配）。
func _has_word(src: String, token: String) -> bool:
	var re := RegEx.new()
	if re.compile("\\b%s\\b" % token) != OK:
		return src.contains(token)
	return re.search(src) != null


## 结构化扫描：找出源码里的**位置写入**。
##
## 查的是**赋值形态**（不是查某个词）：
##   * `<接收者>.position = / += / -= …`、`<接收者>.global_position = …`
##   * `<接收者>.position.<分量> = …`（例如 `sprite.position.y = 1.0`）
##   * `<接收者>.set_position(…)` / `<接收者>.set_global_position(…)`
##
## **自身**的写入（不带接收者，如 `global_position = position`）不是外来写入。
## allowed_receivers：豁免的**自有子节点**引用（自己的 sprite）。
##
## 返回 [{line, text, receiver, kind}]，kind ∈ {self, allowed, foreign}。
func _position_writes(src: String, allowed_receivers: Array = []) -> Array:
	var out: Array = []
	var re_prop := RegEx.new()
	re_prop.compile("([A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*)\\s*\\.\\s*(position|global_position)\\s*(?:=|\\+=|-=|\\*=|/=)")
	var re_comp := RegEx.new()
	re_comp.compile("([A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*)\\s*\\.\\s*(position|global_position)\\s*\\.\\s*[xyzw]\\s*(?:=|\\+=|-=|\\*=|/=)")
	var re_setter := RegEx.new()
	re_setter.compile("([A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*)\\s*\\.\\s*set_(?:global_)?position\\s*\\(")
	var re_self := RegEx.new()
	re_self.compile("^\\s*(position|global_position)\\s*(?:=|\\+=|-=|\\*=|/=)")
	var lines := src.split("\n")
	for i in lines.size():
		var raw: String = lines[i]
		var text := raw.strip_edges()
		if text.is_empty() or text.begins_with("#"):
			continue        # 空行 / 整行注释：不是代码
		var recv := ""
		var kind := ""
		var m := re_prop.search(raw)
		if m == null:
			m = re_comp.search(raw)
		if m == null:
			m = re_setter.search(raw)
		if m != null:
			recv = m.get_string(1)
			kind = "allowed" if allowed_receivers.has(recv) else "foreign"
		elif re_self.search(raw) != null:
			kind = "self"
		if kind == "":
			continue
		out.append({"line": i + 1, "text": text, "receiver": recv, "kind": kind})
	return out


## 只挑出「外来」的写入（写的是**别的对象**的位置）。
func _foreign_writes(writes: Array) -> Array:
	var out: Array = []
	for w in writes:
		if str(w.get("kind", "")) == "foreign":
			out.append(w)
	return out


## 把扫描结果排成一行可读的文本（行号 + 原文 + 接收者）。
func _fmt_writes(writes: Array) -> String:
	if writes.is_empty():
		return "（无）"
	var parts: Array = []
	for w in writes:
		var recv := str(w.get("receiver", ""))
		parts.append("L%d %s%s" % [int(w.get("line", 0)), str(w.get("text", "")),
			("" if recv == "" else "　→ 接收者 " + recv)])
	return "；".join(parts)


## 扫描结果的说明（违规时列出违规行；合规时列出全部匹配行）。
func _writes_msg(writes: Array, foreign: Array) -> String:
	if not foreign.is_empty():
		return "　违规：" + _fmt_writes(foreign)
	return "　（扫到 %d 处位置写入，全部合规：%s）" % [writes.size(), _fmt_writes(writes)]


## 方法的**必填**参数个数（-1 = 没这个方法）。
func _method_arity(obj: Object, method: StringName) -> int:
	for m in obj.get_method_list():
		if StringName(str(m.get("name", ""))) != method:
			continue
		var args: Array = m.get("args", [])
		var defaults: Array = m.get("default_args", [])
		return args.size() - defaults.size()
	return -1


## 对象的**脚本变量**快照（只取 PROPERTY_USAGE_SCRIPT_VARIABLE）。
##
## 用途：证明「押送流程没有改动任何进度类字段」——
## Task 10 之后进度字段也会被这个快照覆盖到。
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


## 贴图不透明像素的包围盒 [minx, miny, maxx, maxy]（整张透明 → 空数组）。
func _alpha_bbox(tex: Texture2D) -> Array:
	if tex == null:
		return []
	var img := tex.get_image()
	if img == null:
		return []
	if img.is_compressed():
		img.decompress()
	var minx := 9999
	var miny := 9999
	var maxx := -1
	var maxy := -1
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.0:
				minx = mini(minx, x)
				miny = mini(miny, y)
				maxx = maxi(maxx, x)
				maxy = maxi(maxy, y)
	if maxx < 0:
		return []
	return [minx, miny, maxx, maxy]


func _check(ok: bool, what: String) -> int:
	_total += 1
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
