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
