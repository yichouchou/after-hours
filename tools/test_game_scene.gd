extends SceneTree

## Task 11：镇子场景与 HUD —— 单元测试。
##
## 覆盖派单 §4 的 19 条断言（下面每段注释标了 [§4-N]）。
## 另加 3 处**反向自检**（[§4-11-R1/R2/R3]），证明关键断言不是恒真。
##
## ★ 修复轮 1（task-11-fix1-brief.md）新增 3 组断言：
##   [§4-20] 出生点**不与任何道具点重合**（派单 §2.8 的明文约束，此前无断言）
##   [§4-21] 守卫编号**不是写死的默认值**（静态兜底 + 行为可区分判定）
##   [§4-22] 两端对局场景路径一致（派单 §2.5，此前无断言）
##
## ★ 修复轮 2（task-11-fix2-brief.md）新增 1 组断言：
##   [§4-23] 派单 §2.8 的「6 个出生点」**全部**校验
##            （[§4-20] 只覆盖了本轮实际生成的那几个出生点）

const GAME_SCENE := "res://scenes/game.tscn"
const HUD_SCENE := "res://scenes/ui/hud.tscn"
const GAME_SRC := "res://scripts/game_scene.gd"
const HUD_SRC := "res://scripts/ui/hud.gd"
const LOBBY_UI_SRC := "res://scripts/ui/lobby_ui.gd"
const PLAYER_SCENE_PATH := "res://scenes/player.tscn"
const GUARD_SCENE_PATH := "res://scenes/guard.tscn"

## 惩罚性 token（零失败惩罚）。口径与 tools/test_player.gd 保持一致。
const PENALTY_TOKENS := ["penalty", "penalized", "score", "score_delta",
	"lives", "lives_lost", "eliminated", "damage", "扣分", "扣命", "淘汰", "死亡"]

## 两字母的惩罚性 token 必须按**词边界**匹配（子串扫会误伤无关标识符）。
const PENALTY_WORD_TOKENS := ["hp"]

## 硬编码绝对场景路径（不许出现）。
## ★ get_node_or_null("Session") 这种**相对**取节点是允许的；
##   禁掉的是 get_node("/root/...") 这种绝对路径。
const ABSOLUTE_PATH_TOKENS := ["get_node(\"/", "\"/root/", "get_node(\"/root/"]

## 派单 §2.8 写定的出生点表（**测试自己写一份**，不读实现 → 独立校验）。
const TEST_SPAWN_TILES := [
	Vector2i(2, 9), Vector2i(3, 10), Vector2i(2, 7),
	Vector2i(3, 5), Vector2i(5, 10), Vector2i(7, 9),
]

## 守卫岗位（派单 §3.2 / §2.8）。
const GUARD_HOME := Vector2(480, 288)


## 替身 Session：房主形状（全员手牌 + 按 peer 取的那一份）。
##
## ★ 用来验证「HUD 只显示自己那一份」：hands 故意放 2 份，
##   by_peer 只放本地那一份 → 房主侧拿到的必须是 1 份而不是 2 份。
class FakeSession extends Node:
	var roster: Array = []
	var hands: Array = []
	var by_peer: Dictionary = {}
	var has_deal_for_peer := true

	func peers() -> Array:
		return roster.duplicate()

	func deal() -> Array:
		return hands.duplicate()

	func deal_for_peer(peer_id: int) -> Array:
		if not has_deal_for_peer:
			return []
		var h: Variant = by_peer.get(peer_id, null)
		return h if typeof(h) == TYPE_ARRAY else []


var _fails := 0
var _total := 0


func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var map := WorldMap.load_map()
	var size: Vector2i = map.get("size", Vector2i.ZERO)
	var map_props: Dictionary = map.get("props", {})

	# ------------------------------------------------------------------
	# 准备两份手牌（房主形状：全员 2 份；自己的那一份只有 1 份）
	# ------------------------------------------------------------------
	var hand_a := _make_mischief(&"steal_carrot", "偷萝卜")
	var hand_b := _make_mischief(&"move_chair", "搬椅子")
	var fake := FakeSession.new()
	# ★ 名单**必须 ≥ 2 人**（修复轮 1 Important 1）：
	#   名单只有 1 人时，房主路径只会用到 index 0 →
	#   spawn_position_for_index() 的 **index ≥ 1 分支从没被走过** →
	#   把所有玩家都放到第 0 个出生点，测试照样全绿（变异 M5 漏网）。
	fake.roster = [1, 2]
	# 房主形状：deal() = **全员手牌**（每人一份），by_peer = peer id → 自己那一份
	fake.hands = [[hand_a], [hand_b]]
	fake.by_peer = {1: [hand_a]}
	root.add_child(fake)

	# ==================================================================
	# [§4-1] game.tscn 可 load() 且 instantiate() 不报错；含全部节点
	# ==================================================================
	var packed: PackedScene = load(GAME_SCENE)
	_fails += _check(packed != null, "[§4-1] game.tscn 可加载")
	var game: Node = null
	if packed != null:
		game = packed.instantiate()
		_fails += _check(game != null, "[§4-1] game.tscn 可实例化")
		for n in ["Ground", "Props", "Players", "Guards", "MultiplayerSpawner", "RPC", "HUD"]:
			_fails += _check(game.get_node_or_null(n) != null,
				"[§4-1] game.tscn 含 %s 节点" % n)
		# 注入替身 Session（不硬编码绝对路径 → 测试可以换掉 autoload）
		game.set("session", fake)
		root.add_child(game)
		# 守卫一进场就开始巡逻 → 先把它冻住，后面的位置断言才是确定的。
		# （守卫的 AI 只在房主跑；这里只影响本测试进程。）
		var guards_now := game.get_node_or_null("Guards")
		if guards_now != null:
			for c in guards_now.get_children():
				c.set_physics_process(false)
	await process_frame
	await process_frame

	if game == null:
		_finish()
		return

	var ground := game.get_node_or_null("Ground") as Sprite2D
	var props_root := game.get_node_or_null("Props") as Node2D
	var players_root := game.get_node_or_null("Players") as Node2D
	var guards_root := game.get_node_or_null("Guards") as Node2D
	var spawner := game.get_node_or_null("MultiplayerSpawner") as MultiplayerSpawner
	var hud: Node = game.get_node_or_null("HUD")
	var local_peer_id: int = root.multiplayer.get_unique_id()

	# ==================================================================
	# [§4-2] hud.tscn 可加载；含 4 个节点；@onready 路径与场景逐字一致
	# ==================================================================
	var hud_packed: PackedScene = load(HUD_SCENE)
	_fails += _check(hud_packed != null, "[§4-2] hud.tscn 可加载")
	var hud_inst = null
	if hud_packed != null:
		hud_inst = hud_packed.instantiate()
		for n in ["CardList", "Hint", "Bubble", "BubbleTimer"]:
			_fails += _check(hud_inst.get_node_or_null(n) != null,
				"[§4-2] hud.tscn 含 %s 节点" % n)
	var hud_src := _read_source(HUD_SRC)
	var game_src := _read_source(GAME_SRC)
	_fails += _check(not hud_src.is_empty(), "[§4-2] hud.gd 可读")
	var scene_names: Array = []
	if hud_inst != null:
		for c in hud_inst.get_children():
			scene_names.append(str(c.name))
	var src_refs := _dollar_refs(hud_src)
	for n in scene_names:
		_fails += _check(src_refs.has(n),
			"[§4-2] hud.gd 的 @onready 路径与场景逐字一致：$%s" % n)
	for r in src_refs:
		_fails += _check(scene_names.has(r),
			"[§4-2] hud.gd 里的 $%s 在场景里真实存在" % r)

	# ==================================================================
	# [§4-3] 地面 region_rect 尺寸 == 地图尺寸 × 一格
	# ==================================================================
	if ground != null:
		var expect_px := Vector2(size.x * WorldMap.TILE, size.y * WorldMap.TILE)
		_fails += _check(ground.region_rect.size == expect_px,
			"[§4-3] 地面 region_rect.size == 地图尺寸 × TILE（期望 %s，实际 %s）"
			% [str(expect_px), str(ground.region_rect.size)])
		_fails += _check(ground.region_rect.size == Vector2(960, 576),
			"[§4-3] 地面 region_rect.size == (960, 576)（30×18 格 × 32）")
		_fails += _check(ground.region_enabled, "[§4-3] 地面 region 已启用")
		_fails += _check(ground.region_rect.position == Vector2.ZERO,
			"[§4-3] 地面 region 左上角在 (0,0)（centered = false 的前提）")

	# ==================================================================
	# [§4-4] 道具数量 == 地图里的道具点位数（dog 也算进去）
	# ==================================================================
	var expected_points := 0
	for tag in map_props.keys():
		expected_points += (map_props[tag] as Array).size()
	var prop_nodes: Array = props_root.get_children() if props_root != null else []
	_fails += _check(prop_nodes.size() == expected_points,
		"[§4-4] 道具数量 == 地图点位数（期望 %d，实际 %d）"
		% [expected_points, prop_nodes.size()])

	# ==================================================================
	# [§4-5] / [§4-16] 道具的 prop_tag / prop_id 与地图一致；prop_id 全图唯一
	# ==================================================================
	var map_points: Dictionary = {}
	for tag in map_props.keys():
		for pos in map_props[tag]:
			map_points["%d,%d" % [int(pos.x), int(pos.y)]] = String(tag)
	var seen_ids: Dictionary = {}
	var dup_ids: Array = []
	var tag_mismatch: Array = []
	var bad_ids: Array = []
	for child in prop_nodes:
		var tag := StringName(str(child.get("prop_tag")))
		var pid := int(child.get("prop_id"))
		var key := "%d,%d" % [int(child.position.x), int(child.position.y)]
		if String(map_points.get(key, "")) != String(tag):
			tag_mismatch.append("%s@%s" % [String(tag), key])
		if seen_ids.has(pid):
			dup_ids.append(pid)
		seen_ids[pid] = true
		if pid <= 0:
			bad_ids.append(pid)
	_fails += _check(tag_mismatch.is_empty(),
		"[§4-5] 每个道具的 prop_tag / 位置与地图一致%s" % _first(tag_mismatch))
	_fails += _check(dup_ids.is_empty(),
		"[§4-16] prop_id 全图唯一%s" % _first(dup_ids))
	_fails += _check(bad_ids.is_empty(),
		"[§4-16] prop_id 都是正整数%s" % _first(bad_ids))
	_fails += _check(seen_ids.size() == expected_points,
		"[§4-16] 唯一 prop_id 的个数 == 道具总数（%d）" % expected_points)

	# ==================================================================
	# [§4-14] ★ 全部道具（含路灯）都在 Props 的**直接子节点**下
	#         （player.gd:_prop_entries() 只扫直接子节点）
	# ==================================================================
	var lamp_nodes: Array = []
	for child in prop_nodes:
		if StringName(str(child.get("prop_tag"))) == &"lamp":
			lamp_nodes.append(child)
	_fails += _check(lamp_nodes.size() == (map_props.get(&"lamp", []) as Array).size(),
		"[§4-14] 路灯数 == 地图里的路灯数（%d）" % lamp_nodes.size())
	_fails += _check(lamp_nodes.size() > 0,
		"[§4-14] 路灯确实是 Props 的**直接子节点**（不是另开容器）")
	var nested_lamps := 0
	for child in prop_nodes:
		for gc in child.get_children():
			if StringName(str(gc.get("prop_tag"))) == &"lamp":
				nested_lamps += 1
	_fails += _check(nested_lamps == 0,
		"[§4-14] 没有路灯被藏进子容器里（玩家只扫直接子节点）")

	# ==================================================================
	# [§4-6] 房主侧生成 1 个守卫，位置 (480, 288)；player_root 已注入
	# ==================================================================
	_fails += _check(guards_root != null and guards_root.get_child_count() == 1,
		"[§4-6] 房主侧生成 1 个守卫（实际 %d）"
		% (guards_root.get_child_count() if guards_root != null else -1))
	var guard: Node2D = null
	if guards_root != null and guards_root.get_child_count() > 0:
		guard = guards_root.get_child(0) as Node2D
	if guard != null:
		_fails += _check(guard.position == GUARD_HOME,
			"[§4-6] 守卫位置 == (480, 288)（实际 %s）" % str(guard.position))
		_fails += _check(guard.get("_home") == GUARD_HOME,
			"[§4-6] 守卫的岗位(_home) == (480, 288)（巡逻围绕它进行）")
		_fails += _check(guard.get("player_root") != null,
			"[§4-6] 守卫的 player_root 已注入（非 null）")
		_fails += _check(guard.get("player_root") == players_root,
			"[§4-6] 注入给守卫的正是 Players 容器")

		# ==================================================================
		# [§4-17] ★ 守卫编号来自 Interaction.assign_guard_wire_ids()
		# ==================================================================
		var wire := Interaction.assign_guard_wire_ids(["old_chen"])
		_fails += _check(int(guard.get("guard_wire_id")) == int(wire["old_chen"]),
			"[§4-17] guard_wire_id == assign_guard_wire_ids([\"old_chen\"]) 的结果（%d）"
			% int(wire["old_chen"]))
		_fails += _check(game_src.contains("assign_guard_wire_ids"),
			"[§4-17] game_scene.gd 走的是 assign_guard_wire_ids（不是写死的默认值）")
		_fails += _check(not game_src.contains("guard_wire_id\", 1")
				and not game_src.contains("guard_wire_id = 1"),
			"[§4-17] game_scene.gd 没有把 guard_wire_id 写死成 1")

	# ==================================================================
	# [§4-21] ★ 守卫编号**不是写死的默认值**（修复轮 1 Important 2：断言强度）
	# ==================================================================
	# ① 静态兜底：源码的**代码部分**里必须出现**带限定前缀与调用括号**的形式
	#    Interaction.assign_guard_wire_ids( —— 生产代码里那句**注释**没有这个形式
	#    （注释写的是「assign_guard_wire_ids（……」）→ 注释满足不了这条，
	#    「把真调用换成字面量 dict、注释留着」骗不过它（变异 M8b）。
	var game_code := _strip_comments(game_src)
	_fails += _check(game_code.contains("Interaction.assign_guard_wire_ids("),
		"[§4-21] game_scene.gd 的代码部分里出现 Interaction.assign_guard_wire_ids(（带限定前缀与调用括号，注释满足不了）")
	# ② 静态兜底（正则）：guard_wire_id **不许**被赋成字面量数字（各种拼法都认）。
	var guard_literal_hits := _guard_wire_id_literals(game_code)
	_fails += _check(guard_literal_hits.is_empty(),
		"[§4-21] game_scene.gd 没有把 guard_wire_id 写死成字面量数字（各种拼法都认）%s"
		% _first(guard_literal_hits))
	# ③ 行为可区分：守卫名单扩成**两个**时，第二个必须拿到 2。
	#    （P1 只有 1 个守卫 → 「写死 1」与「按规则算出 1」数值上不可区分；
	#      编号规则本身必须按**名单顺序**递增 → 才能说明这条规则真的成立。）
	var wire_two := Interaction.assign_guard_wire_ids(["old_chen", "new_wang"])
	_fails += _check(wire_two.size() == 2
			and int(wire_two.get("old_chen", -1)) == 1
			and int(wire_two.get("new_wang", -1)) == 2,
		"[§4-21] 守卫编号按**名单顺序**分配：两个守卫 → 1 和 2（实际 %s）" % str(wire_two))
	# ④ 剥注释这个 helper 本身要被钉死（helper 改坏 → ① ② 一起失效）。
	_fails += _check(not _strip_comments("var a = 1  # guard_wire_id = 1").contains("guard_wire_id"),
		"[§4-21] 剥注释：**行尾注释**里的 guard_wire_id 不算进代码部分")
	_fails += _check(not _strip_comments("# guard_wire_id = 1\nvar b = 2").contains("guard_wire_id"),
		"[§4-21] 剥注释：**整行注释**里的 guard_wire_id 不算进代码部分")
	_fails += _check(_strip_comments("var s = \"# guard_wire_id = 1\"").contains("guard_wire_id"),
		"[§4-21] 剥注释：**字符串字面量**里的 # 不是注释起点")

	# ==================================================================
	# [§4-7] MultiplayerSpawner：spawn_path / 注册 player.tscn /
	#         spawn_function 产出的节点名 == 传入的 peer id；
	#         不许有手搓 players_root.add_child( 的路径
	# ==================================================================
	_fails += _check(spawner != null, "[§4-7] 场景里有 MultiplayerSpawner")
	var spawned: Node = null
	if spawner != null:
		_fails += _check(spawner.spawn_path == NodePath("../Players"),
			"[§4-7] spawn_path 指向 ../Players（实际 %s）" % str(spawner.spawn_path))
		var registered := false
		for i in spawner.get_spawnable_scene_count():
			# get_spawnable_scene(i) 返回的是**场景路径字符串**（Godot 4 的 _spawnable_scenes 是路径表）
			var s := str(spawner.get_spawnable_scene(i))
			if s == PLAYER_SCENE_PATH:
				registered = true
		_fails += _check(registered, "[§4-7] MultiplayerSpawner 已注册 player.tscn")
		# 用一个随机 peer id 走一遍 spawn_function（房主侧调用）
		# ★ index = 2（名单已经占了 index 0 / 1）→ 期望值**写字面量** (64, 224)，
		#   **不许**调生产的 spawn_position_for_index() 去算（那样就是自证、恒真）。
		spawned = spawner.spawn({"peer_id": 733754800, "index": 2, "spawn": Vector2(64, 224)})
		_fails += _check(spawned != null and str(spawned.name) == "733754800",
			"[§4-7] spawn_function 产出的节点名 == 传入的 peer id（实际 %s）"
			% (str(spawned.name) if spawned != null else "<null>"))
		_fails += _check(players_root.get_node_or_null("733754800") != null,
			"[§4-7] 能按 peer id 在 Players 容器下取到该节点")
	_fails += _check(not game_src.contains("players_root.add_child("),
		"[§4-7] 源码里没有手搓 players_root.add_child( 的路径")
	_fails += _check(game_src.contains("spawn_function"),
		"[§4-7] 源码里设置了 spawner 的 spawn_function")

	# ==================================================================
	# [§4-11-R2] 反向自检：节点名确实被改名过（不是场景根名 "Player"）
	# ==================================================================
	var player_scene_root_name := "Player"
	if spawned != null:
		_fails += _check(str(spawned.name) != player_scene_root_name,
			"[§4-11-R2] 反向自检：spawn 出来的节点名不是场景根名 \"%s\"（改名真的发生了）"
			% player_scene_root_name)
		# ==================================================================
		# [§4-8] player_index 是稳定的 0–5 序号（不是 peer_id - 1）
		# ==================================================================
		var idx := int(spawned.get("player_index"))
		# ★ 期望值随夹具走（修复轮 1 Important 1）：手工塞进来的玩家现在用的是
		#   index 2（假名单 [1, 2] 已经占了 index 0 / 1）。
		#   断言的**语义没变**：player_index == spawn 载荷里下发的那个序号。
		_fails += _check(idx == 2, "[§4-8] player_index 取自下发的稳定序号（期望 2，实际 %d）" % idx)
		_fails += _check(idx != 733754800 - 1,
			"[§4-8] player_index 不是 peer_id - 1（实际 %d）" % idx)
		_fails += _check(idx >= 0 and idx <= 5, "[§4-8] player_index ∈ [0, 5]（实际 %d）" % idx)
	_fails += _check(not game_src.contains("peer_id - 1")
			and not game_src.contains("peer_id-1"),
		"[§4-8] 源码里没有 peer_id - 1 之类的推导式")

	# ==================================================================
	# [§4-18] 注入齐全：每个玩家的 props_root / players_root 非 null；
	#         本地玩家的 hand 非空且**只有自己那一份**
	# ==================================================================
	var local_player: Node = null
	if players_root != null:
		local_player = players_root.get_node_or_null(str(local_peer_id))
	_fails += _check(local_player != null,
		"[§4-18] 本地玩家节点存在（节点名 == 本地 peer id %d）" % local_peer_id)
	var injected_ok := true
	for child in players_root.get_children():
		if child.get("props_root") == null or child.get("players_root") == null:
			injected_ok = false
	_fails += _check(injected_ok,
		"[§4-18] 每个玩家节点的 props_root / players_root 都非 null")
	_fails += _check(local_player != null
			and local_player.get("props_root") == props_root
			and local_player.get("players_root") == players_root,
		"[§4-18] 注入给玩家的是本场景的 Props / Players 容器")
	if local_player != null:
		var hand: Array = local_player.get("hand")
		_fails += _check(hand.size() > 0, "[§4-18] 本地玩家的 hand 非空（实际 %d 条）" % hand.size())
		_fails += _check(hand.size() == (fake.by_peer[1] as Array).size(),
			"[§4-18] 房主的 hand 长度 == deal_for_peer(本地 peer id) 的长度")
		_fails += _check(hand.size() != fake.hands.size(),
			"[§4-18] 房主的 hand 长度 != 全员牌数（%d vs %d）"
			% [hand.size(), fake.hands.size()])

	# ==================================================================
	# [§4-9] HUD 显示的是**自己那一份**（房主侧不显示别人的牌）
	# ==================================================================
	var card_list = hud.get_node_or_null("CardList") if hud != null else null
	_fails += _check(card_list != null, "[§4-9] HUD 有 CardList")
	if card_list != null:
		_fails += _check(card_list.get_child_count() == 1,
			"[§4-9] HUD 清单只有 1 条（自己那一份），不是全员 2 条（实际 %d）"
			% card_list.get_child_count())
		# ==================================================================
		# [§4-11-R3] 反向自检：直接塞 2 条 → 清单真的变成 2 行
		#            （证明上面那条「只有 1 条」不是恒真）
		# ==================================================================
		var two: Array[String] = ["甲", "乙"]
		hud.call(&"set_card_list", two)
		_fails += _check(card_list.get_child_count() == 2,
			"[§4-11-R3] 反向自检：set_card_list 给 2 条 → 清单 2 行（实际 %d）"
			% card_list.get_child_count())
		game.call(&"_refresh_hud")
		_fails += _check(card_list.get_child_count() == 1,
			"[§4-11-R3] 反向自检：刷新回自己那一份 → 又变回 1 行（实际 %d）"
			% card_list.get_child_count())

	# ==================================================================
	# [§4-9-B] 客户端形状：客户端的 deal_for_peer() 返回**空数组**
	#           （客户端没有 _deals_by_peer）→ 必须退回 deal()[0]，
	#           而且仍然只有**自己那一份**
	# ==================================================================
	var client_fake := FakeSession.new()
	client_fake.roster = [1]
	client_fake.hands = [[hand_a]]  # 客户端的 deal() 只有自己那一份
	client_fake.by_peer = {}       # 客户端没有 _deals_by_peer
	client_fake.has_deal_for_peer = false
	root.add_child(client_fake)
	var client_packed: PackedScene = load(GAME_SCENE)
	var client_game: Node = null
	if client_packed != null:
		client_game = client_packed.instantiate()
		client_game.set("session", client_fake)
		root.add_child(client_game)
		await process_frame
		await process_frame
		var c_players := client_game.get_node_or_null("Players") as Node2D
		var c_local: Node = null
		if c_players != null:
			c_local = c_players.get_node_or_null(str(local_peer_id))
		_fails += _check(c_local != null, "[§4-9-B] 客户端形状的本地玩家节点存在")
		if c_local != null:
			var c_hand: Array = c_local.get("hand")
			_fails += _check(c_hand.size() == 1,
				"[§4-9-B] 客户端形状：hand == deal()[0]（1 条，实际 %d）" % c_hand.size())
		var c_hud := client_game.get_node_or_null("HUD")
		var c_cards = c_hud.get_node_or_null("CardList") if c_hud != null else null
		_fails += _check(c_cards != null and c_cards.get_child_count() == 1,
			"[§4-9-B] 客户端形状：HUD 只显示自己那一份（1 行）")
		client_game.queue_free()
		await process_frame

	# ==================================================================
	# [§4-12] 相机：跟随本地玩家；非本地玩家的相机是禁用的；
	#         相机不参与任何联机判定
	# ==================================================================
	var enabled_cams := 0
	var local_cam_ok := false
	var cam_count := 0
	for child in players_root.get_children():
		var cam := child.get_node_or_null("Camera2D") as Camera2D
		_fails += _check(cam != null, "[§4-12] 玩家节点带 Camera2D")
		if cam == null:
			continue
		cam_count += 1
		_fails += _check(cam.get_node_or_null("MultiplayerSynchronizer") == null,
			"[§4-12] 相机不带 MultiplayerSynchronizer（不参与同步判定）")
		if cam.enabled:
			enabled_cams += 1
			if str(child.name) == str(local_peer_id):
				local_cam_ok = true
	_fails += _check(cam_count == players_root.get_child_count(),
		"[§4-12] 每个玩家节点都挂了相机（共 %d 个）" % cam_count)
	_fails += _check(enabled_cams == 1,
		"[§4-12] 只有 1 台相机启用（实际 %d）" % enabled_cams)
	_fails += _check(local_cam_ok, "[§4-12] 启用的是**本地玩家**那台相机")
	_fails += _check(not _camera_in_judgement_calls(game_src),
		"[§4-12] 相机不参与任何联机判定（没被注入 rpc / guard / 玩家）")

	# ==================================================================
	# [§4-13] Ground 的 centered == false
	# ==================================================================
	if ground != null:
		_fails += _check(ground.centered == false,
			"[§4-13] Ground.centered == false（region 左上角才落在 (0,0)）")

	# ==================================================================
	# [§4-15] ★ 灯只走一条通道：lamp_root 非 null 且没被注入 set_lamps()
	#         → 熄一盏灯：1.0 → 0.6（不是 0.36）；点亮回来 → 1.0
	# ==================================================================
	if guard != null and not lamp_nodes.is_empty():
		var lamp: Node2D = lamp_nodes[0] as Node2D
		_fails += _check(guard.get("lamp_root") == props_root,
			"[§4-15] 守卫的 lamp_root == Props 容器（与玩家的 props_root 同一个）")
		var injected: Array = guard.get("_injected_lamps")
		_fails += _check(injected.is_empty(),
			"[§4-15] 守卫**没有**被注入过 set_lamps() 数组（实际 %d 条）" % injected.size())
		# 守卫岗位 (480,288) 不在任何路灯的 160 px 半径内 → 临时挪到那盏灯上量
		var saved_pos: Vector2 = guard.position
		guard.position = lamp.position
		var bright := float(guard.call(&"_light_factor"))
		_fails += _check(is_equal_approx(bright, 1.0),
			"[§4-15] 灯全亮 → light_factor == 1.0（实测 %f）" % bright)
		Interaction.set_lamp_on(lamp, false)
		var dark := float(guard.call(&"_light_factor"))
		_fails += _check(is_equal_approx(dark, 0.6),
			"[§4-15] 熄一盏灯 → light_factor == 0.6（实测 %f，不是 0.36）" % dark)
		_fails += _check(not is_equal_approx(dark, 0.36),
			"[§4-15] 熄一盏灯**不是** 0.36（同一盏灯没被算两遍）")
		Interaction.set_lamp_on(lamp, true)
		var back := float(guard.call(&"_light_factor"))
		_fails += _check(is_equal_approx(back, 1.0),
			"[§4-15] 点亮回来 → light_factor == 1.0（实测 %f）" % back)
		guard.position = saved_pos
		_fails += _check(guard.position == GUARD_HOME,
			"[§4-15] 量完把守卫放回岗位 (480, 288)")

		# ==================================================================
		# [§4-11-R1] 反向自检：**双通道**（lamp_root + set_lamps）→ 0.36
		#            证明上面那条 0.6 的断言确实有检测力
		# ==================================================================
		# 先把那盏灯**熄灭**（模拟"拔路灯"），再叠加第二条通道
		Interaction.set_lamp_on(lamp, false)
		var probe_guard: Node2D = load(GUARD_SCENE_PATH).instantiate() as Node2D
		probe_guard.position = lamp.position
		probe_guard.call(&"set_lamp_root", props_root)
		probe_guard.call(&"set_lamps", [{"position": lamp.position, "on": false}])
		var doubled := float(probe_guard.call(&"_light_factor"))
		_fails += _check(is_equal_approx(doubled, 0.36),
			"[§4-11-R1] 反向自检：同一盏灯走两条通道 → light_factor == 0.36（实测 %f）"
			% doubled)
		probe_guard.free()
		Interaction.set_lamp_on(lamp, true)
		_fails += _check(is_equal_approx(float(guard.call(&"_light_factor")), 1.0),
			"[§4-11-R1] 反向自检收尾：灯点亮回来 → 守卫 light_factor 回到 1.0")

	# ==================================================================
	# [§4-19] ★ 出生点分配：显式设置过、各不相同、
	#         == 派单 §2.8 的 PLAYER_SPAWN_TILES × TILE 的前 N 项；
	#         第 0 个 == (64, 288)；没有与守卫岗位重合
	# ==================================================================
	var positions: Array = []
	var all_set := true
	var index_mismatch: Array = []
	for child in players_root.get_children():
		if not bool(child.get("_spawn_position_set")):
			all_set = false
		var sp: Vector2 = child.get("spawn_position")
		positions.append(sp)
		# 出生点由 **player_index** 决定（不是 peer id）→ 逐个核对
		var ci := int(child.get("player_index"))
		if ci >= 0 and ci < TEST_SPAWN_TILES.size():
			var expect_spawn := Vector2(TEST_SPAWN_TILES[ci]) * float(WorldMap.TILE)
			if sp != expect_spawn:
				index_mismatch.append("%s(index=%d): %s != %s"
					% [str(child.name), ci, str(sp), str(expect_spawn)])
	_fails += _check(all_set, "[§4-19] 每个玩家的 spawn_position 都被显式设置过")
	_fails += _check(index_mismatch.is_empty(),
		"[§4-19] 每个玩家的出生点 == PLAYER_SPAWN_TILES[player_index] × TILE%s"
		% _first(index_mismatch))
	_fails += _check(positions.size() == players_root.get_child_count(),
		"[§4-19] 每个玩家都有出生点（%d 个）" % positions.size())
	var unique: Dictionary = {}
	for p in positions:
		unique["%d,%d" % [int(p.x), int(p.y)]] = true
	_fails += _check(unique.size() == positions.size(),
		"[§4-19] 出生点两两不同（%d 个位置 / %d 个不同）" % [positions.size(), unique.size()])
	# 出生点**集合** == 派单表 × TILE 的前 N 项（N = 玩家数）
	var expect_set: Dictionary = {}
	for i in mini(positions.size(), TEST_SPAWN_TILES.size()):
		var e := Vector2(TEST_SPAWN_TILES[i]) * float(WorldMap.TILE)
		expect_set["%d,%d" % [int(e.x), int(e.y)]] = true
	var same_set := unique.size() == expect_set.size()
	if same_set:
		for k in unique.keys():
			if not expect_set.has(k):
				same_set = false
		for k in expect_set.keys():
			if not unique.has(k):
				same_set = false
	_fails += _check(same_set,
		"[§4-19] 出生点集合 == 派单 §2.8 的 PLAYER_SPAWN_TILES × TILE 的前 %d 项"
		% positions.size())
	_fails += _check(not positions.is_empty() and positions[0] == Vector2(64, 288),
		"[§4-19] 第 0 个出生点 == (64, 288)（与既有测试夹具一致）")
	var hits_guard := false
	for p in positions:
		if Vector2(p) == GUARD_HOME:
			hits_guard = true
	_fails += _check(not hits_guard, "[§4-19] 没有出生点与守卫岗位 (480, 288) 重合")

	# ==================================================================
	# [§4-20] ★ 出生点**不与任何道具点重合**（派单 §2.8 的明文约束）
	# ==================================================================
	# 派单 §2.8 写死「6 个出生点……都不与任何道具点重叠」——此前**没有任何断言**
	# （人工逐格核对才算成立）。这里把道具点换算成像素后逐个比对。
	var prop_points_px: Array = []
	for tag in map_props.keys():
		for pos in map_props[tag]:
			prop_points_px.append(Vector2(pos))
	_fails += _check(not prop_points_px.is_empty(),
		"[§4-20] 前提：地图里确实有道具点可比（%d 个）" % prop_points_px.size())
	var spawn_on_prop: Array = []
	for p in positions:
		for pp in prop_points_px:
			if is_equal_approx(Vector2(p).x, Vector2(pp).x) \
					and is_equal_approx(Vector2(p).y, Vector2(pp).y):
				spawn_on_prop.append("出生点 %s 与道具点 %s 重合" % [str(p), str(pp)])
	_fails += _check(spawn_on_prop.is_empty(),
		"[§4-20] 没有出生点与任何道具点重合（派单 §2.8）%s" % _first(spawn_on_prop))

	# ==================================================================
	# [§4-23] ★ 派单 §2.8 的「6 个出生点」**全部**校验（修复轮 2 Important I-1）
	# ==================================================================
	# ★ 病根：上面 [§4-20] 比对的 `positions` 来自 players_root.get_children()，
	#   而本轮夹具**只实际生成**了 3 个玩家 → 派单 §2.8 写死的 6 个出生点里，
	#   index 3 / 4 / 5（格坐标 (3,5) / (5,10) / (7,9)）**从没进过任何一次比对**。
	#   变异 T5（生产表第 4 项 (3,5) → (4,4)，即 data/map.json 的 carrot 道具点）
	#   就是这么全绿漏过去的。
	# ★ 覆盖面分工（两条断言**不互为完全蕴含**）：
	#   [§4-20] → 只管本轮**实际生成**的那些出生点（已生成的玩家被写错 → 它会红）；
	#   [§4-23] → 管**整张 6 项表**（没被生成的表项落到道具点上 → 它会红）。
	# ★ 期望值一律来自**测试自己那份 6 项字面量表** TEST_SPAWN_TILES；
	#   生产侧的 PLAYER_SPAWN_TILES 在这里只当**被测对象**（actual），不当期望值
	#   （拿生产常量算期望值 = 自证 = 恒真）。
	var prod_tiles: Array = []
	var prod_tiles_read := false
	var game_script: GDScript = load(GAME_SRC) as GDScript
	if game_script != null:
		var const_map: Dictionary = game_script.get_script_constant_map()
		var raw_tiles: Variant = const_map.get("PLAYER_SPAWN_TILES", null)
		if raw_tiles is Array:
			prod_tiles = (raw_tiles as Array).duplicate()
			prod_tiles_read = true
	# ★ 前提不许恒真：生产表读不到 / 项数不对 → 直接判失败，
	#   绝不「比较集合为空 → 整体通过」。
	_fails += _check(prod_tiles_read and prod_tiles.size() == TEST_SPAWN_TILES.size(),
		"[§4-23] 前提：生产侧出生点表 PLAYER_SPAWN_TILES 读得到且恰好 6 项（读到 %d 项）"
		% prod_tiles.size())
	var tile_mismatch: Array = []
	for i in mini(prod_tiles.size(), TEST_SPAWN_TILES.size()):
		if Vector2(prod_tiles[i]) != Vector2(TEST_SPAWN_TILES[i]):
			tile_mismatch.append("index %d：生产 %s != 规格 %s"
				% [i, str(prod_tiles[i]), str(TEST_SPAWN_TILES[i])])
	_fails += _check(prod_tiles.size() == TEST_SPAWN_TILES.size() and tile_mismatch.is_empty(),
		"[§4-23] 生产侧 6 个出生点逐项 == 测试自己那份 6 项字面量表（派单 §2.8）%s"
		% _first(tile_mismatch))
	var prod_on_prop: Array = []
	for i in prod_tiles.size():
		var prod_px := Vector2(prod_tiles[i]) * float(WorldMap.TILE)
		for pp in prop_points_px:
			if is_equal_approx(prod_px.x, Vector2(pp).x) \
					and is_equal_approx(prod_px.y, Vector2(pp).y):
				prod_on_prop.append("生产出生点 index %d (%s) 与道具点 %s 重合"
					% [i, str(prod_px), str(pp)])
	_fails += _check(prod_on_prop.is_empty(),
		"[§4-23] 生产侧 6 个出生点逐个都不与任何道具点重合（派单 §2.8）%s"
		% _first(prod_on_prop))
	var spec_on_prop: Array = []
	for i in TEST_SPAWN_TILES.size():
		var spec_px := Vector2(TEST_SPAWN_TILES[i]) * float(WorldMap.TILE)
		for pp in prop_points_px:
			if is_equal_approx(spec_px.x, Vector2(pp).x) \
					and is_equal_approx(spec_px.y, Vector2(pp).y):
				spec_on_prop.append("规格出生点 index %d (%s) 与道具点 %s 重合"
					% [i, str(spec_px), str(pp)])
	_fails += _check(spec_on_prop.is_empty(),
		"[§4-23] 测试自己那份 6 项字面量出生点也都不与任何道具点重合（派单 §2.8）%s"
		% _first(spec_on_prop))

	# ==================================================================
	# [§4-22] ★ 两端对局场景路径一致（派单 §2.5）
	# ==================================================================
	# 派单 §2.5 要求「Task 11 的联机测试里要断言两端路径相同」。
	# Task 11 交付的是**单进程** SceneTree 测试 → 真正的双进程一致性留给 Task 12；
	# 这里做**最小断言**：房主侧与「客户端侧」读到的 lobby_ui.gd.game_scene_path
	# **默认值相同**，且都等于 GAME_SCENE（res://scenes/game.tscn）。
	# ★ game_scene_path 是**可覆盖**的变量 → 这里读的是**默认值**（新建实例、没注入过）。
	var host_scene_path := ""
	var client_scene_path := ""
	var lobby_script: GDScript = load(LOBBY_UI_SRC)
	if lobby_script != null:
		var host_lobby: Node = lobby_script.new()
		var client_lobby: Node = lobby_script.new()
		host_scene_path = str(host_lobby.get("game_scene_path"))
		client_scene_path = str(client_lobby.get("game_scene_path"))
		host_lobby.free()
		client_lobby.free()
	_fails += _check(not host_scene_path.is_empty() and host_scene_path == client_scene_path,
		"[§4-22] 房主侧与客户端侧读到的 lobby_ui.gd.game_scene_path **默认值相同**（%s / %s）"
		% [host_scene_path, client_scene_path])
	_fails += _check(host_scene_path == GAME_SCENE and client_scene_path == GAME_SCENE,
		"[§4-22] 两端的 game_scene_path 默认值都 == GAME_SCENE（%s）" % GAME_SCENE)
	_fails += _check(ResourceLoader.exists(host_scene_path),
		"[§4-22] 两端默认路径指向的对局场景**真实存在**（%s）" % host_scene_path)

	# ==================================================================
	# [§4-10] 纯净化：不出现 Steam. / 惩罚性 token / 硬编码绝对场景路径
	# ==================================================================
	_fails += _check(not game_src.is_empty(), "[§4-10] game_scene.gd 可读")
	_fails += _check(not hud_src.is_empty(), "[§4-10] hud.gd 可读")
	for src in [game_src, hud_src]:
		var who := "game_scene.gd" if src == game_src else "hud.gd"
		_fails += _check(not src.contains("Steam."), "[§4-10] %s 不出现 Steam. 调用" % who)
		for token in PENALTY_TOKENS:
			_fails += _check(not src.contains(token),
				"[§4-10] %s 不出现惩罚性 token「%s」" % [who, token])
		for token in PENALTY_WORD_TOKENS:
			_fails += _check(not _has_word(src, token),
				"[§4-10] %s 不出现惩罚性 token「%s」（独立词）" % [who, token])
		for token in ABSOLUTE_PATH_TOKENS:
			_fails += _check(not src.contains(token),
				"[§4-10] %s 不出现硬编码绝对场景路径「%s」" % [who, token])

	# ------------------------------------------------------------------
	# 收尾：释放实例
	# ------------------------------------------------------------------
	if hud_inst != null:
		hud_inst.free()
	if game != null:
		game.queue_free()
	await process_frame
	_finish()


func _finish() -> void:
	print("")
	print("断言总数: %d" % _total)
	if _fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % _fails)
		quit(1)


## 造一张手牌（本地重建的 Mischief 对象）。
func _make_mischief(id: StringName, title: String) -> Mischief:
	var m := Mischief.new()
	m.id = id
	m.title = title
	m.category = &"food"
	m.target_tag = &"carrot"
	m.duration = 1.0
	m.points = 10
	return m


## 读源码（纯文本；**归一化换行**，避免依赖工作区的换行符）。
func _read_source(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text().replace("\r\n", "\n").replace("\r", "\n")


## 源码里所有 $标识符（@onready 路径的引用）。
func _dollar_refs(src: String) -> Array:
	var out: Array = []
	var re := RegEx.new()
	if re.compile("\\$([A-Za-z_][A-Za-z0-9_]*)") != OK:
		return out
	for m in re.search_all(src):
		out.append(m.get_string(1))
	return out


## 相机有没有被当成联机判定的参数传出去（set_rpc / set_player_root / …）。
func _camera_in_judgement_calls(src: String) -> bool:
	var judgement_calls := ["set_rpc(", "set_player_root(", "set_lamp_root(",
		"attach_lamps(", "set_hand(", "set_props_root(", "set_players_root("]
	for line in src.split("\n"):
		var low := line.to_lower()
		if not low.contains("cam"):
			continue
		for call in judgement_calls:
			if low.contains(call):
				return true
	return false


## 源码里有没有出现「作为一个独立词」的 token（词边界匹配）。
func _has_word(src: String, token: String) -> bool:
	var re := RegEx.new()
	if re.compile("\\b%s\\b" % token) != OK:
		return src.contains(token)
	return re.search(src) != null


## 把源码里的**注释**剥掉，只留**代码部分**。
##
## ★ 为什么需要（修复轮 1 Important 2）：断言要扫「game_scene.gd 是不是**调用**了
##   Interaction.assign_guard_wire_ids(」——而生产代码里那句**注释**也写着这个名字。
##   不剥注释的话，一条注释就能满足扫描（变异 M8b 直接漏网）。
## ★ 字符串字面量里的 '#' **不是**注释起点（否则会误剥代码）。
## ★ 输入先过 _read_source()（已把 \r\n 归一化成 \n），所以这里按 \n 分行。
func _strip_comments(src: String) -> String:
	var lines: Array[String] = []
	for line in src.split("\n"):
		var kept := ""
		var quote := ""
		var i := 0
		var n := line.length()
		while i < n:
			var ch := line[i]
			if quote != "":
				kept += ch
				if ch == "\\" and i + 1 < n:
					# 转义序列：把下一个字符原样带出来（不当作注释起点）
					kept += line[i + 1]
					i += 2
					continue
				if ch == quote:
					quote = ""
				i += 1
				continue
			if ch == "\"" or ch == "'":
				quote = ch
				kept += ch
				i += 1
				continue
			if ch == "#":
				break
			kept += ch
			i += 1
		lines.append(kept)
	return "\n".join(lines)


## game_scene.gd 里「guard_wire_id 被赋成字面量数字」的**各种写法**。
##
## ★ 不能只认一种拼法（否则换个写法就绕过去了）：
##   guard_wire_id = 1 / guard_wire_id := 1 / guard_wire_id": 1 /
##   guard_wire_id", 1 / set("guard_wire_id", 1) / guard_wire_id: 1 ……
## ★ 输入应该是**剥掉注释后的代码部分**（注释里写例子不算违规）。
func _guard_wire_id_literals(src: String) -> Array:
	var out: Array = []
	var re := RegEx.new()
	# 分隔符：, / := / = / :  （字典字面量、set(...) 实参、赋值、带类型的声明）
	if re.compile("guard_wire_id[\"']?\\s*(?:,|:=|=|:)\\s*\\(?\\s*-?\\d+(?:\\.\\d+)?") != OK:
		return ["<正则编译失败>"]
	for m in re.search_all(src):
		out.append(m.get_string())
	return out


## 违规列表的首条描述（用于失败诊断）。
func _first(bad: Array) -> String:
	if bad.is_empty():
		return ""
	return " —— 违规 %d 处，例如：%s" % [bad.size(), str(bad[0])]


func _check(ok: bool, what: String) -> int:
	_total += 1
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
