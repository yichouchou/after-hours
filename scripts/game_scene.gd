extends Node2D

## 镇子（对局场景）。**场景装配层 + 表现层**；不参与任何联机判定。
##
## 本文件是 **Node 层**脚本（纯逻辑层在 scripts/game/）。它只做三件事：
##   1) 铺地面、摆道具；
##   2) 生成玩家与守卫、把引用注入各节点；
##   3) 驱动 HUD（自己的清单 / 提示 / 被抓气泡）。
##
## ★ 权威模型（不变）：玩家移动 = 拥有者权威；守卫 AI 与捣蛋裁决 = 房主权威。
##   本文件**不裁决**任何东西，只装配场景。
##
## ★ 玩家生成**只走 MultiplayerSpawner**（不许手搓 players_root.add_child）：
##   spawn_function 收到房主下发的载荷 {peer_id, index, spawn} →
##   实例化 player.tscn 并把节点**改名成 str(peer_id)** → 客户端收到 spawn
##   消息后走**同一个** spawn_function → 两端节点名一致（节点名 = peer id
##   是 scripts/player.gd 的权威解析前提）。
##
## ★ player_index 是**稳定的 0–5 序号**（按房主名单里的出场顺序分配），
##   **不是** peer_id 推导 —— ENet 客户端 peer id 是随机 32 位数。
##
## ★ 出生点由**房主**算好、随 spawn 载荷一起下发 → 两端必然一致。
##
## ★ 路灯容器（Task 11 裁决）：**所有道具都在 Props 容器的直接子节点下**
##   （玩家只扫直接子节点 → 路灯若另开容器，玩家就摸不到路灯）。
##   守卫的 lamp_root 与玩家的 props_root **指向同一个 Props**，
##   且守卫**只**用 set_lamp_root() 这一条通道（绝不调 set_lamps()：
##   同一盏灯算两遍 → light_factor 变成 0.36 而不是 0.6）。

## 玩家场景（生成用）。
const PLAYER_SCENE := preload("res://scenes/player.tscn")

## 道具场景（铺道具用）。
const PROP_SCENE := preload("res://scenes/mischief_prop.tscn")

## 守卫场景。
const GUARD_SCENE := preload("res://scenes/guard.tscn")

## 结算页（天亮结算）。
const RESULT_SCENE := "res://scenes/result.tscn"

## 结算页脚本（静态变量用来跨场景递结算载荷）。
const ResultScreen := preload("res://scripts/ui/result_screen.gd")

## 玩家脚本（结算时按节点名解析 peer id）。
const PlayerScript := preload("res://scripts/player.gd")

## ★ 缺口 C（Task 12 实测钉死）：远端玩家的**生成要等一小会儿**。
##
## MultiplayerSpawner 的生成消息只发给**当时在树里**的 spawner：
## 客户端收到清单 → 切进 game.tscn → 它的 MultiplayerSpawner 这才进树。
## 房主若在客户端进场景之前就 spawn()，那条消息**没人接**
## （引擎没有「晚加入补发」的承诺）→ 客户端永远没有自己的玩家节点。
## → 场上真的有多人时，房主**等 REMOTE_SPAWN_DELAY_SEC 秒**再生成，
##   给客户端留出「收到清单 → 切场景 → spawner 进树」的时间。
const REMOTE_SPAWN_DELAY_SEC := 1.2

## 地面贴图（256×256 的草地，用 region + repeat 平铺成整张地图）。
const GROUND_TEXTURE := "res://assets/ground/ground_grass.png"

## 道具贴图格式：res://assets/props/prop_<tag>.png。
const PROP_TEXTURE_FORMAT := "res://assets/props/prop_%s.png"

## 玩家出生点（**格坐标**）。第 0 个 = (2,9) → 世界坐标 (64, 288)，
## 与既有测试夹具一致。6 个点两两不同、都在地图内、
## 都不与任何道具点重叠、也不在守卫岗位 (480, 288) 上。
const PLAYER_SPAWN_TILES := [
	Vector2i(2, 9), Vector2i(3, 10), Vector2i(2, 7),
	Vector2i(3, 5), Vector2i(5, 10), Vector2i(7, 9),
]

## 守卫的岗位（px）—— 守卫站在 sign 道具那一格。
const GUARD_HOME := Vector2(480, 288)

## 守卫的数据 id（**顺序 = data/guards.json 的顺序**）。P1 只有 1 个守卫。
const GUARD_DATA_IDS := ["old_chen"]

## 被抓时弹的吐槽气泡（P1 用固定文案；守卫台词个性化是 P3 的活）。
const CAUGHT_BUBBLE_TEXT := "我的萝卜呢？！"

## 相机在玩家节点下的名字。
const CAMERA_NODE_NAME := "Camera2D"

@onready var ground: Sprite2D = $Ground
@onready var props_root: Node2D = $Props
@onready var players_root: Node2D = $Players
@onready var guards_root: Node2D = $Guards
@onready var spawner: MultiplayerSpawner = $MultiplayerSpawner
@onready var rpc_node: Node = $RPC
@onready var hud: CanvasLayer = $HUD

## Session autoload 节点（运行时解析；测试可以注入替身）。
##
## ★ 房主取「自己那一份清单」用 deal_for_peer(本地 peer id)，
##   客户端用 deal()[0]（客户端没有 _deals_by_peer → deal_for_peer 返回空数组）。
var session: Node = null

## peer id → 稳定的 0–5 序号（房主维护；同一次会话内不变）。
var _peer_index: Dictionary = {}

## 本地 peer id（**只查一次并缓存**）。
##
## ★ 缓存的理由：MultiplayerAPI.get_unique_id() 在 peer 被关闭之后会打引擎 ERROR
##   （"The multiplayer instance isn't currently active."）—— 每帧问一次会刷一屏错误。
var _local_peer_id: int = 0

## 每个 peer 被抓的次数（结算用；纯数据，跨进程可传）。
var _caught_counts: Dictionary = {}

## 每个 peer 已完成的捣蛋标题（结算用；纯数据）。
var _done_titles: Dictionary = {}


func _ready() -> void:
	_local_peer_id = multiplayer.get_unique_id()
	_resolve_session()
	_configure_spawner()
	_build_world()
	_connect_rpc()
	_connect_session()
	_connect_hud_finish()
	# 先接上 child_entered_tree，再生成玩家 —— 否则新节点不会被注入。
	players_root.child_entered_tree.connect(_on_player_entered_tree)
	if multiplayer.is_server():
		_spawn_players_when_clients_ready()
	for child in players_root.get_children():
		_inject_player(child)
	_refresh_hud()


## ── 场景装配 ────────────────────────────────────────────────────────────

## 解析 Session autoload（不硬编码绝对路径；测试可注入替身）。
func _resolve_session() -> void:
	if session != null:
		return
	var tree := get_tree()
	if tree == null:
		return
	session = tree.root.get_node_or_null("Session")


## 登记可生成场景 + 指定生成位置。
##
## ★ spawn_function 在**两端**都要设（客户端收到 spawn 消息时走同一条路径）。
func _configure_spawner() -> void:
	spawner.spawn_path = ^"../Players"
	spawner.add_spawnable_scene(PLAYER_SCENE.resource_path)
	spawner.spawn_function = Callable(self, "_spawn_player_node")


## 铺地面 + 摆道具 + 建守卫。
func _build_world() -> void:
	var map := WorldMap.load_map()
	if not bool(map.get("ok", false)):
		push_error("[GameScene] 地图加载失败：" + str(map.get("error", "")))
		return
	var size: Vector2i = map.get("size", Vector2i.ZERO)
	ground.texture = load(GROUND_TEXTURE)
	ground.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	ground.region_enabled = true
	# ★ 一格 = WorldMap.TILE（不硬编码 32）。
	ground.region_rect = Rect2(Vector2.ZERO,
		Vector2(size.x * WorldMap.TILE, size.y * WorldMap.TILE))
	_build_props(map.get("props", {}))
	_build_guards()


## 按地图摆道具。**全部是 Props 容器的直接子节点**（含路灯 —— 玩家只扫直接子节点）。
##
## prop_id **全图唯一**（房主「先到先得」台账的 key）。
func _build_props(props: Dictionary) -> void:
	var prop_id := 1
	for tag in props.keys():
		for pos in props[tag]:
			var p := PROP_SCENE.instantiate()
			p.set("prop_tag", StringName(str(tag)))
			p.set("prop_id", prop_id)
			p.position = pos
			var sprite := p.get_node_or_null("Sprite2D") as Sprite2D
			if sprite != null:
				var tex := load(PROP_TEXTURE_FORMAT % String(tag))
				if tex != null:
					sprite.texture = tex
			props_root.add_child(p)
			prop_id += 1


## 建守卫。
##
## ★ 守卫在**两端**都建一个节点：房主那个跑 AI（权威），客户端那个只按
##   guard_state 广播更新**表现**位置（scripts/guard.gd 自己判服务器/客户端）。
##   客户端没有守卫节点就**看不见守卫** → 所以这里两端都建。
## ★ 灯**只**走 lamp_root 一条通道（Interaction.attach_lamps 内部只调 set_lamp_root）。
func _build_guards() -> void:
	if GUARD_DATA_IDS.is_empty():
		return
	var wire_ids := Interaction.assign_guard_wire_ids(GUARD_DATA_IDS)
	var data_id := StringName(str(GUARD_DATA_IDS[0]))
	var g := GUARD_SCENE.instantiate()
	g.position = GUARD_HOME
	g.set("guard_id", data_id)
	# ★ 编号来自 assign_guard_wire_ids（不依赖场景里的默认值 1）。
	g.set("guard_wire_id", int(wire_ids.get(data_id, Interaction.GUARD_WIRE_ID_BASE)))
	guards_root.add_child(g)
	g.call(&"set_player_root", players_root)
	# ★ 单一通道：只给 lamp_root，绝不再调 set_lamps()。
	Interaction.attach_lamps(g, props_root)
	g.call(&"set_rpc", rpc_node)


## ── 玩家生成（房主权威）────────────────────────────────────────────────

## 房主：生成玩家。
##
## ★ 缺口 C（Task 12）：**真的有多人在线时**先等一小会儿再生成 ——
##   客户端的 MultiplayerSpawner 必须在树里才接得住生成消息。
##   没有别的玩家时没什么可等 → 立刻生成（本地模拟 / 单元测试不受影响）。
func _spawn_players_when_clients_ready() -> void:
	if _should_wait_for_clients():
		await get_tree().create_timer(REMOTE_SPAWN_DELAY_SEC).timeout
		if not is_inside_tree():
			return
	_spawn_players()


## 场上是不是真的有别的玩家（要等他们进场景）。
##
## ★ 用 Session 的公开接口 peer_count()：**真的开了一局多人联机**才会 > 1。
##   本地模拟 / 单元测试里的替身没有这个方法 → 视为「没人可等」。
func _should_wait_for_clients() -> bool:
	if session == null or not session.has_method(&"peer_count"):
		return false
	return int(session.call(&"peer_count")) > 1


## 房主：按出场顺序给名单里的每个人分配**稳定的 0–5 序号**并生成玩家。
func _spawn_players() -> void:
	var roster := _roster()
	for i in roster.size():
		_spawn_player(int(roster[i]), i)


## 房主名单（房主权威）。拿不到就退化成「只有自己」。
func _roster() -> Array:
	var out: Array = []
	if session != null and session.has_method(&"peers"):
		for p in session.call(&"peers"):
			out.append(int(p))
	if out.is_empty():
		out.append(_local_peer_id)
	return out


## 房主：给一个 peer 生成玩家（序号 = 加入顺序）。
func _spawn_player(peer_id: int, index: int) -> void:
	if players_root.has_node(str(peer_id)):
		return
	_peer_index[peer_id] = index
	spawner.spawn({
		"peer_id": peer_id,
		"index": index,
		"spawn": spawn_position_for_index(index),
	})


## 出生点（**世界坐标**）。由序号决定，不是由 peer id 决定。
func spawn_position_for_index(index: int) -> Vector2:
	if PLAYER_SPAWN_TILES.is_empty():
		return Vector2.ZERO
	var i := posmod(index, PLAYER_SPAWN_TILES.size())
	return Vector2(PLAYER_SPAWN_TILES[i]) * float(WorldMap.TILE)


## MultiplayerSpawner 的 spawn_function（**两端**都跑）。
##
## data = { "peer_id": int, "index": int, "spawn": Vector2 }（房主算好下发）。
## ★ 节点**改名成 str(peer_id)** —— 节点名 = peer id 是拥有者权威的前提；
##   不改名的话所有玩家会重名（MultiplayerSpawner 默认用场景根节点名命名）。
func _spawn_player_node(data: Variant) -> Node:
	var payload: Dictionary = {}
	if typeof(data) == TYPE_DICTIONARY:
		payload = data
	else:
		payload = {"peer_id": int(data)}
	var peer_id := int(payload.get("peer_id", 0))
	var index := int(payload.get("index", 0))
	var spawn_pos: Vector2 = payload.get("spawn", Vector2.ZERO)
	var p := PLAYER_SCENE.instantiate()
	p.name = str(peer_id)
	# ★ 在节点**进树之前**定好多人权威。
	#   引擎规则（MultiplayerSynchronizer 的报错原文）：权威只能在
	#   「spawner 的 _enter_tree 阶段」确定 —— 等 _ready() 再改，
	#   同步器就拿不到 network ID（会打一条引擎 ERROR）。
	#   这里用的是玩家脚本同一套解析口径（scripts/player.gd 的 resolve_authority）。
	p.set_multiplayer_authority(PlayerScript.resolve_authority(str(peer_id)))
	p.set("player_index", index)
	# ★ 显式设置出生点（被抓时自己走回这里）。
	p.call(&"set_spawn_position", spawn_pos)
	p.position = spawn_pos
	_attach_camera(p)
	return p


## ── 相机（表现层）──────────────────────────────────────────────────────

## 给玩家节点挂一台相机。
##
## 相机挂在玩家节点下 → 天然跟随玩家；它**不参与**任何联机判定。
## 开关在 _process 里按「本地 / 非本地」统一处理（见 _update_local_camera）。
func _attach_camera(player: Node) -> void:
	var cam := Camera2D.new()
	cam.name = CAMERA_NODE_NAME
	# 先不启用：节点进树之后再按本地与否打开（相机不在树里时不能 enable）。
	cam.enabled = false
	player.add_child(cam)


## ── 注入 ───────────────────────────────────────────────────────────────

## 有玩家节点进树 → 注入引用。
func _on_player_entered_tree(node: Node) -> void:
	_inject_player(node)


## 把容器 / RPC / 自己那一份清单注入一个玩家节点。
func _inject_player(node: Node) -> void:
	if node == null or not node.has_method(&"set_props_root"):
		return
	node.call(&"set_props_root", props_root)
	node.call(&"set_players_root", players_root)
	node.call(&"set_rpc", rpc_node)
	var is_local := str(node.name) == str(_local_peer_id)
	if is_local:
		node.call(&"set_hand", _own_hand())


## 每帧把镜头对准本地玩家：本地玩家那台相机开着且是当前相机，
## **别的玩家的相机一律关着**（否则两台机器各拉各的镜头）。
##
## 放在 _process 里而不是生成时：节点进树的时机（child_entered_tree 与
## 子节点进树信号的先后）不确定，在这里兜底最稳。
func _process(_delta: float) -> void:
	_update_local_camera()


## 相机开关（**表现层**，不参与任何联机判定）。
func _update_local_camera() -> void:
	var local_id := str(_local_peer_id)
	for child in players_root.get_children():
		var cam := child.get_node_or_null(CAMERA_NODE_NAME) as Camera2D
		if cam == null:
			continue
		var is_local := str(child.name) == local_id
		# 相机不在树里时不能 enable（引擎会报 ERR_FAIL_COND）。
		cam.enabled = is_local and cam.is_inside_tree()
		if cam.enabled and not cam.is_current():
			cam.make_current()


## 「自己那一份」捣蛋清单。
##
## ★ 两端写法不一样（Task 11 裁决）：
##   房主 → deal_for_peer(本地 peer id)（房主侧才有 _deals_by_peer 映射表）；
##   客户端 → deal()[0]（客户端的 _deal 只有自己那一份）。
##   客户端调 deal_for_peer() 会返回**空数组** → 所以先试房主那条路，
##   拿不到再退到客户端那条路。**永远不**把全员 deal 整份塞给 HUD。
func _own_hand() -> Array:
	if session == null:
		return []
	var local_id := _local_peer_id
	if session.has_method(&"deal_for_peer"):
		var own: Variant = session.call(&"deal_for_peer", local_id)
		if typeof(own) == TYPE_ARRAY and not (own as Array).is_empty():
			return own
	if session.has_method(&"deal"):
		var all: Variant = session.call(&"deal")
		if typeof(all) == TYPE_ARRAY and (all as Array).size() > 0:
			var first: Variant = (all as Array)[0]
			if typeof(first) == TYPE_ARRAY:
				return first
	return []


## 把引用注入 RPC 节点，并接上表现层要听的信号。
func _connect_rpc() -> void:
	if rpc_node == null:
		return
	rpc_node.set("players_root", players_root)
	rpc_node.set("guards_root", guards_root)
	_connect_signal(rpc_node, &"caught_player_evt", Callable(self, "_on_caught_player_evt"))
	_connect_signal(rpc_node, &"mischief_resolved_evt",
		Callable(self, "_on_mischief_resolved_evt"))
	# ── 结算用的统计（Task 12）──────────────────────────────────────────
	_connect_signal(rpc_node, &"caught_player_evt", Callable(self, "_count_caught"))
	_connect_signal(rpc_node, &"mischief_resolved_evt",
		Callable(self, "_track_mischief_resolved"))


## 接 Session 的回合开始信号（清单到手后刷新 HUD 与本地玩家的手牌）。
func _connect_session() -> void:
	if session == null:
		return
	_connect_signal(session, &"round_started", Callable(self, "_on_round_started"))
	# ── 回合结束（Task 12）：两端对称切到结算页 ──────────────────────────
	_connect_signal(session, &"round_ended", Callable(self, "_on_round_ended"))


## 接信号（已接过就跳过，避免 "Signal already connected"）。
func _connect_signal(node: Node, sig: StringName, cb: Callable) -> void:
	if node == null or not node.has_signal(sig):
		return
	if node.is_connected(sig, cb):
		return
	node.connect(sig, cb)


## ── 表现层回调 ─────────────────────────────────────────────────────────

## 被抓 → **只有被抓的那一方**弹吐槽气泡（不是全局播报）。
func _on_caught_player_evt(peer_id: int, _guard_id: int) -> void:
	if peer_id != _local_peer_id:
		return
	if hud != null:
		hud.call(&"show_bubble", CAUGHT_BUBBLE_TEXT)


## 结算结果 → 刷新提示里的「已完成」计数。
func _on_mischief_resolved_evt(_peer_id: int, _behavior_id: StringName,
		_success: bool, _reason: String) -> void:
	_refresh_hud()


## 回合开始（清单到手）→ 重新注入本地玩家的手牌 + 刷新 HUD。
func _on_round_started(_deal: Array) -> void:
	var local := _local_player()
	if local != null:
		local.call(&"set_hand", _own_hand())
	_refresh_hud()


## 本地玩家节点（节点名 == 本地 peer id）。
func _local_player() -> Node:
	return players_root.get_node_or_null(str(_local_peer_id))


## 刷新 HUD：清单（**只有自己那一份**）+ 提示。
func _refresh_hud() -> void:
	if hud == null:
		return
	var titles: Array[String] = []
	for m in _own_hand():
		var mi := m as Mischief
		if mi != null:
			titles.append(mi.title)
	hud.call(&"set_card_list", titles)
	hud.call(&"set_hint", _hint_text())
	# ── 「收工」按钮：**只有房主可点**（Task 12）────────────────────────
	hud.call(&"set_finish_enabled", _is_host())


## 提示文案：操作提示 + **已完成**的捣蛋次数（不是进行中进度 —— 两者语义不许混）。
func _hint_text() -> String:
	var done := 0
	var local := _local_player()
	if local != null:
		done = int(local.get("completed_mischief"))
	return "按住 E 捣蛋 · 已完成 %d 条" % done


## ── 收工 / 结算（Task 12）─────────────────────────────────────────────

## 接 HUD 上的「收工」按钮。
func _connect_hud_finish() -> void:
	if hud == null:
		return
	if not hud.has_signal(&"finish_pressed"):
		return
	_connect_signal(hud, &"finish_pressed", Callable(self, "_on_finish_pressed"))


## 「收工」被点了 → 组装摘要 → 广播收工。
##
## ★ 摘要的组装在**场景层**（这里）：手里有玩家节点
##   （已完成次数 / 被抓次数 / 捣蛋标题）；Session 只负责广播。
func _on_finish_pressed() -> void:
	if session == null:
		return
	if not session.has_method(&"end_round"):
		return
	session.call(&"end_round", build_round_summary())


## 组装结算载荷（**纯数据**，能跨进程传）。
##
## 结构：{ peer_id: { name, done, caught, mischief_titles } }。
## ★ name 两端必须一致 —— 摘要由**房主**组装并广播，两端显示的是同一份数据。
func build_round_summary() -> Dictionary:
	var summary: Dictionary = {}
	for child in players_root.get_children():
		var pid := PlayerScript.resolve_authority(str(child.name))
		summary[pid] = {
			"name": _player_display_name(pid),
			"done": int(child.get("completed_mischief")),
			"caught": int(_caught_counts.get(pid, 0)),
			"mischief_titles": (_done_titles.get(pid, []) as Array).duplicate(),
		}
	return summary


## 玩家显示名（按房主名单里的出场顺序；两端一致）。
func _player_display_name(peer_id: int) -> String:
	var roster := _roster()
	var idx := roster.find(peer_id)
	if idx < 0:
		return "玩家 %d" % peer_id
	return "玩家 %d" % (idx + 1)


## 行为 id → 标题（结算页显示的是标题，不是 id）。
func _mischief_title(behavior_id: StringName) -> String:
	for m in Mischief.load_all():
		if m.id == behavior_id:
			return m.title
	return String(behavior_id)


## 记一次被抓（结算用）。
func _count_caught(peer_id: int, _guard_id: int) -> void:
	_caught_counts[peer_id] = int(_caught_counts.get(peer_id, 0)) + 1


## 记一条已完成的捣蛋（结算用）。只有**成功**才算完成。
func _track_mischief_resolved(peer_id: int, behavior_id: StringName,
		success: bool, _reason: String) -> void:
	if not success:
		return
	var titles: Array = _done_titles.get(peer_id, [])
	titles.append(_mischief_title(behavior_id))
	_done_titles[peer_id] = titles


## 回合结束（**两端都会触发**）→ 存下摘要并切到结算页。
func _on_round_ended(summary: Dictionary) -> void:
	ResultScreen.set_pending_summary(summary)
	_goto_result_scene()


## 切到结算页（走 Router，缺失场景由 Router 安全跳过）。
func _goto_result_scene() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var router = tree.root.get_node_or_null("Router")
	if router == null:
		return
	router.call(&"goto", RESULT_SCENE)


## 本机是不是房主（只有房主能收工）。
func _is_host() -> bool:
	if session == null or not session.has_method(&"is_host"):
		return false
	return bool(session.call(&"is_host"))
