extends Node

## 对局期的 RPC 承载节点（房主 ↔ 客户端）。
##
## 本文件由 **Task 9** 创建（计划有洞：Task 11 引用了它却没人建），
## 承载「被抓 → 押送 → 送回自己的出生点」这条链路需要的三个 RPC：
##
##   房主 → 所有人：player_caught(peer_id, guard_id)
##   房主 → 所有人：guard_state(guard_id, state, position, target_peer)
##   客户端 → 房主：escort_finished(peer_id)        ← 控制器补充的回执
##
## 名字与签名照设计文档 §5.3 的 RPC 协议走，不要自造。
##
## ★ Task 10 会在**同一个文件**里追加 submit_mischief / resolve_mischief
##   —— **不要动**本任务交付的三个方法。
##
## 载荷全是**纯数据**（int / float / Vector2）：
## 没有 StringName、没有 Resource、没有对象引用
## （Task 7 的教训：Resource 作 RPC 载荷在客户端读不出字段）。

## 房主的 peer id 恒为 1（ENet server-relay）。
const HOST_PEER_ID := 1

## 「这个玩家被守卫抓了」（房主 → 所有人）。
## 名字带 _evt 后缀是为了不和同名 RPC 方法 player_caught 抢标识符。
signal caught_player_evt(peer_id: int, guard_id: int)

## 「守卫的状态与位置」（房主 → 所有人）。客户端据此更新**表现**位置，不跑 AI。
signal guard_state_evt(guard_id: int, state: int, position: Vector2, target_peer: int)

## 「被抓玩家已走回自己的出生点」（客户端 → 房主）。
signal escort_completed_evt(peer_id: int)


## 房主 → 所有人：这个玩家被守卫抓了（进入押送）。
@rpc("authority", "call_local", "reliable")
func player_caught(peer_id: int, guard_id: int) -> void:
	caught_player_evt.emit(peer_id, guard_id)


## 房主 → 所有人：守卫的状态与位置。
## 客户端据此更新本地守卫节点的**表现**位置（客户端不跑 AI）。
@rpc("authority", "call_local", "reliable")
func guard_state(guard_id: int, state: int, position: Vector2, target_peer: int) -> void:
	guard_state_evt.emit(guard_id, state, position, target_peer)


## 客户端 → 房主：被抓玩家已走回自己的出生点。
@rpc("any_peer", "call_remote", "reliable")
func escort_finished(peer_id: int) -> void:
	escort_completed_evt.emit(peer_id)


## 房主侧：广播「玩家被抓」。
##
## 直接用 .rpc()：注解是 "call_local" → **本地也会执行**（房主自己被抓也要生效），
## 同时发给所有远端客户端。实测（4.7.2）：离线（无 peer）时 .rpc() 只本地执行、
## 不报任何引擎 ERROR。
func broadcast_player_caught(peer_id: int, guard_id: int) -> void:
	player_caught.rpc(peer_id, guard_id)


## 房主侧：广播守卫的状态与位置。
func broadcast_guard_state(guard_id: int, state: int, position: Vector2,
		target_peer: int) -> void:
	guard_state.rpc(guard_id, state, position, target_peer)


## 被抓玩家侧：向房主回报「我已经走回自己的出生点」。
##
## 注意 escort_finished 是 "call_remote"：**发送方本地不会执行**它。
## → 房主自己被抓时必须本地投递（否则房主自己永远等不到回执，押送卡死）。
func send_escort_finished(peer_id: int) -> void:
	var mp := multiplayer
	if mp == null:
		return
	if mp.get_unique_id() == HOST_PEER_ID:
		# 房主自己被抓 → 本地投递（call_remote 不会在本地执行）。
		escort_finished(peer_id)
		return
	if not mp.get_peers().has(HOST_PEER_ID):
		# 房主不在（房主掉线即本局结束，不重试）。
		return
	escort_finished.rpc_id(HOST_PEER_ID, peer_id)


## ── Task 10：捣蛋裁决 ─────────────────────────────────────────────────────
##
## ★ 载荷是**纯数据**：behavior_id 在**线上是 String**（StringName 线上要转 String，
##   Task 7 的教训），内部信号层再转回 StringName。没有 Object / Resource。
## ★ 载荷固定 **4 个字段**：{peer_id, behavior_id, success, reason}。
##   caught **不单独进载荷** —— 用 reason 表达（reason == "caught" ⇔ caught）。
## ★ 先到先得的台账在**房主侧**（Rules 是无状态的单次裁决，不裁决归属）。
## ★ 两个抓捕通道**分开**：护送是**守卫通道**（Task 9 的 caught_player）的职责；
##   本文件的裁决通道只回答「这一条行为算不算完成」，**不触发护送**。

## player.gd 没有 class_name → 用 preload 取它的静态方法。
## ★ peer id 的解析**一律**走 Player.resolve_authority()（不许自己写第三个解析器）。
const PlayerScript := preload("res://scripts/player.gd")

## 「这个捣蛋行为结算了」（房主 → 所有人）。
signal mischief_resolved_evt(peer_id: int, behavior_id: StringName, success: bool, reason: String)

## 由 game_scene.gd 注入（避免依赖场景路径）。
var players_root: Node2D = null
var guards_root: Node2D = null

## 由 game_scene.gd 注入的**道具容器**（**两端**都注入：客户端也有 props_root）。
##
## ★ 用途：房主按 target_id 找到「被拔掉的那盏灯」并熄灭它；
##   客户端按 target_id 找到**自己**那盏灯并同步亮灭。
## ★ 灯的状态**只**走 meta "lamp_on"（唯一入口是 Interaction.set_lamp_on）——
##   不许引入第二套灯状态，也不许碰 guard.set_lamps()
##   （双通道 → 同一盏灯被算两遍 → light_factor 变成 0.36 而不是 0.6）。
var props_root: Node2D = null

## 房主侧的捣蛋行为表（Task 11 可注入；没注入时回退读 data/mischief.json）。
var behaviors: Array = []

## 最近一次广播的载荷（纯数据字典；供表现层与测试查看）。
var last_mischief_payload: Dictionary = {}

## 最近一次裁决用的世界快照（5 个键；供表现层与测试查看）。
var last_mischief_context: Dictionary = {}

## 房主侧的「先到先得」台账（target_id → peer_id）。
var _ledger := Interaction.ClaimLedger.new()

var _behavior_cache: Array[Mischief] = []
var _behavior_cache_loaded := false


## 客户端 → 房主：提交一条捣蛋行为的**完成申请**。
##
## ★ "call_remote"：**发送方本地不会执行**它
##   → 房主自己捣蛋时走 send_submit_mischief() 的本地投递分支
##     （否则房主自己的捣蛋永远不会被裁决；与 Task 9 的 send_escort_finished 同一个坑）。
@rpc("any_peer", "call_remote", "reliable")
func submit_mischief(behavior_id: String, target_id: int) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 0:
		# 房主本地投递：没有远端发送者。
		sender = multiplayer.get_unique_id()
	adjudicate(sender, StringName(behavior_id), target_id, 1.0)


## 房主裁决一条捣蛋提交。返回 { "success": bool, "reason": String } —— **只有 2 个键**。
##
## ★ 零失败惩罚：返回值里**没有**任何惩罚性字段（只回答「算不算完成」）。
## ★ Rules.evaluate() 只在**完成瞬间**被问询（生产路径上 progress 恒为 1.0）；
##   reason == "in_progress" 是**非终态**：不广播、不清进度、不触发护送、不占台账。
## ★ 先到先得：台账在**房主侧**；落败方**不产生任何惩罚性后果**，只是这一条行为算没完成。
func adjudicate(peer_id: int, behavior_id: StringName, target_id: int,
		progress: float) -> Dictionary:
	var ctx := _gather_context(peer_id, behavior_id)
	last_mischief_context = ctx
	var outcome := Rules.evaluate(
		{"peer_id": peer_id, "behavior_id": behavior_id,
			"target_id": target_id, "progress": progress}, ctx)
	var success := bool(outcome["success"])
	var reason := String(outcome["reason"])
	if reason == "in_progress":
		# 非终态：什么都不做（不广播、不占台账、不清进度、不触发护送）。
		return {"success": false, "reason": reason}
	# 先到先得：同一个 target_id 只能被一个 peer 占住。
	if not _ledger.claim(target_id, peer_id):
		success = false
		reason = "target_taken"
	# ★ 广播（"call_local" → 房主本地也执行；远端客户端也收到）。
	resolve_mischief.rpc(peer_id, String(behavior_id), success, reason)
	# ★ 改世界（房主权威）：只有「成功」且该行为有世界效果时才改。
	#   落败方（target_taken）**不产生任何后果** —— 零失败惩罚。
	if success:
		_apply_world_effect(behavior_id, target_id)
	return {"success": success, "reason": reason}


## 房主 → 所有人：某个捣蛋行为结算了。
##
## ★ 载荷固定 **4 个字段**：{peer_id, behavior_id, success, reason}。
## ★ caught **不单独进载荷** —— 用 reason 表达（reason == "caught" ⇔ caught）。
## ★ behavior_id 在**线上是 String**（StringName 线上要转 String，Task 7 的教训）；
##   内部信号层再转回 StringName。
## ★ 本方法**不触发护送**：护送是**守卫通道**的职责（两个抓捕通道必须分开）。
@rpc("authority", "call_local", "reliable")
func resolve_mischief(peer_id: int, behavior_id: String, success: bool, reason: String) -> void:
	last_mischief_payload = make_mischief_payload(peer_id, StringName(behavior_id),
		success, reason)
	mischief_resolved_evt.emit(peer_id, StringName(behavior_id), success, reason)


## 广播载荷的**规范形状**：{peer_id, behavior_id, success, reason} —— 恰好 4 个字段。
##
## ★ 纯数据：没有 Object / Resource；behavior_id 是 **String**（不是 StringName）。
static func make_mischief_payload(peer_id: int, behavior_id: StringName, success: bool,
		reason: String) -> Dictionary:
	return {
		"peer_id": int(peer_id),
		"behavior_id": String(behavior_id),
		"success": bool(success),
		"reason": String(reason),
	}


## 客户端 → 房主：提交一条捣蛋行为的完成申请。
##
## ★ submit_mischief 是 "call_remote"：**发送方本地不会执行**它。
## → 房主自己捣蛋时必须**本地投递**（否则房主自己的捣蛋永远不会被裁决）。
func send_submit_mischief(behavior_id: String, target_id: int) -> void:
	var mp := multiplayer
	if mp == null:
		return
	if mp.get_unique_id() == HOST_PEER_ID:
		submit_mischief(behavior_id, target_id)
		return
	if not mp.get_peers().has(HOST_PEER_ID):
		# 房主不在（房主掉线即本局结束，不重试）。
		return
	submit_mischief.rpc_id(HOST_PEER_ID, behavior_id, target_id)


## 房主侧的世界快照（喂给 Rules.evaluate 的 ctx，5 个键）。
##
## ★ has_partner / needs_partner **不许硬编码**：
##   needs_partner 取自 Mischief.needs_partner（那张牌自己的字段）
##   has_partner 取自**实际搭档状态**（场上是否有另一个玩家在同一目标旁边）
func _gather_context(peer_id: int, behavior_id: StringName) -> Dictionary:
	var players := _gather_players()
	var me_pos := Vector2.ZERO
	var found_me := false
	for p in players:
		if int(p["peer_id"]) == peer_id:
			me_pos = p["position"]
			found_me = true
			break
	var nearest := Rules.NO_GUARD_NEAR_DISTANCE
	var alerted := false
	if guards_root != null:
		for child in guards_root.get_children():
			var g := child as Node2D
			if g == null:
				continue
			if found_me:
				nearest = minf(nearest, me_pos.distance_to(g.global_position))
			var brain := _node_property(g, &"brain") as GuardBrain
			if brain != null and brain.state == GuardBrain.State.CHASE:
				alerted = true
	var m := _find_behavior(behavior_id)
	var needs_partner := m != null and m.needs_partner
	var has_partner := false
	if found_me:
		has_partner = Interaction.has_partner_near(players, peer_id, me_pos)
	return {
		"nearest_guard_distance": nearest,
		"guard_alerted": alerted,
		"has_partner": has_partner,
		"needs_partner": needs_partner,
		"guard_catch_distance": Rules.CATCH_DISTANCE,
	}


## 场上玩家快照：[{ "peer_id": int, "position": Vector2 }]。
##
## ★ peer id 一律走 Player.resolve_authority()（**不许**自己写第三个解析器 ——
##   scripts/guard.gd 用的是宽松的整数判定（"007" → 7），两套口径不一致）。
func _gather_players() -> Array:
	var out: Array = []
	if players_root == null:
		return out
	for child in players_root.get_children():
		var n2d := child as Node2D
		if n2d == null:
			continue
		out.append({"peer_id": PlayerScript.resolve_authority(str(child.name)),
			"position": n2d.global_position})
	return out


## 读节点上的一个属性；属性不存在时返回 null（**不**打引擎错误）。
func _node_property(node: Object, prop: StringName) -> Variant:
	for p in node.get_property_list():
		if StringName(str(p.get("name", ""))) == prop:
			return node.get(prop)
	return null


## 房主侧查一个捣蛋行为（没注入时回退读 data/mischief.json）。
func _find_behavior(behavior_id: StringName) -> Mischief:
	for b in behaviors:
		var m := b as Mischief
		if m != null and m.id == behavior_id:
			return m
	if not _behavior_cache_loaded:
		_behavior_cache = Mischief.load_all()
		_behavior_cache_loaded = true
	for m in _behavior_cache:
		if m.id == behavior_id:
			return m
	return null


## ── Task 12 修复轮 2：拔掉路灯的世界效果 ────────────────────────────────
##
## ★ 机制早就有（scripts/guard.gd 的 _light_factor() → GuardBrain.compute_light_factor）
##   —— 缺的是「按下开关的那一下」：
##   房主裁决出「mess_lamps 成功」→ 把那盏灯的 meta "lamp_on" 写成 false
##   → 守卫的视野真的变短（每盏灭 −40%，1 盏 → 0.6）。
##
## ★ 「哪些行为有世界效果」的**扩展点**：_apply_world_effect() 按 behavior_id 分派。
##   本轮**只实现 mess_lamps** —— 设计文档只给路灯规定了世界效果，
##   其余 9 种在 P1 没有规定 → **不许自己发明**
##   （例如「偷走萝卜就把萝卜删掉」）。

## 房主 → 所有人：某盏路灯的亮灭状态变了。
##
## ★ 载荷是**纯数据**（int + bool）→ 符合「网络载荷必须是纯数据」。
## ★ call_remote → **发送方本地不会执行**它
##   → 房主自己那盏灯由房主本地写（见 _apply_world_effect）；
##   这个 RPC 只负责把「这盏灯灭了」告诉客户端
##   （与 Task 9 的 escort_finished / Task 10 的 submit_mischief 是同一个坑）。
@rpc("authority", "call_remote", "reliable")
func set_lamp_state(target_id: int, on: bool) -> void:
	var lamp := _find_prop_by_id(target_id)
	if lamp == null:
		return
	Interaction.set_lamp_on(lamp, on)


## 房主：裁决成功之后**改世界**（本轮只有「拔路灯」一条有世界效果）。
##
## ★ 只在 success == true 时才被调用（落败方**不产生任何后果** —— 零失败惩罚）。
## ★ 灯的状态**只**写 meta "lamp_on"（Interaction.set_lamp_on 是**唯一**入口）：
##   不许引入第二套灯状态，也不许碰 guard.set_lamps()
##   （双通道 → 同一盏灯被算两遍 → light_factor 变成 0.36 而不是 0.6）。
func _apply_world_effect(behavior_id: StringName, target_id: int) -> void:
	if behavior_id != &"mess_lamps":
		return
	var lamp := _find_prop_by_id(target_id)
	if lamp == null:
		return
	# ★ 房主本地先写（call_remote 的 .rpc() 本地不执行 → 这里必须自己写）。
	Interaction.set_lamp_on(lamp, false)
	# ★ 再通知远端客户端（纯数据载荷：int + bool）。
	set_lamp_state.rpc(target_id, false)


## 按 prop_id 找道具节点（房主与客户端各找自己的 props_root）。
##
## ★ prop_id 存在 meta 里（scripts/mischief_prop.gd 的 _ready() 写的），
##   与玩家侧读 target_id 的口径一致（scripts/player.gd 的 _prop_entries()）。
func _find_prop_by_id(target_id: int) -> Node:
	if props_root == null:
		return null
	for child in props_root.get_children():
		if int(child.get_meta("prop_id", -1)) == target_id:
			return child
	return null
