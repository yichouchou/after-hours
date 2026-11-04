extends SceneTree

## 子进程：2026-11-04 用户报障的**端到端复现 + 回归**。
##
## 背景（探针 100% 复现的因果链）：
##   join_game() 起的 8 秒连接超时计时器**没有被 host_game() 停掉**
##   → 8 秒后 _on_connect_timeout() → _drop_transport()
##   → mp.multiplayer_peer = null
##   → 引擎每帧打一条 ERROR（scene_multiplayer.cpp:531
##     "No multiplayer peer is assigned. Unable to get unique ID."）
##   → get_unique_id() 返回 0 → is_multiplayer_authority() 恒为 false
##     → 输入被整个忽略（**角色卡住**）
##   → multiplayer.is_server() 恒为 false → 守卫 AI **完全停摆**。
##
## 三个阶段（父进程 tools/test_peer_null.gd 按这些标记判读）：
##   阶段 1：用户的原始流程 —— 「加入房间」（没人监听）→「创建房间」→ 等 9 秒
##   阶段 2：把 mp 的 peer 拆成 null → 跑 120 帧（玩家 + 守卫）
##   阶段 3：用 PeerState.restore_offline() 把 mp 恢复成「单机」→ 跑同样的 120 帧
##
## ★ 「引擎 ERROR 行数」由**父进程**统计（引擎错误直接写 stderr，本进程自察不到）。
##   做法与 tools/test_player.gd 的 §4-10-C 同款。

const SessionScript := preload("res://scripts/net/session.gd")
const PortAlloc := preload("res://tools/port_alloc.gd")
const PLAYER_SCENE := "res://scenes/player.tscn"
const GUARD_SCENE := "res://scenes/guard.tscn"

## 阶段 2 / 3 跑的帧数（120 帧 ≈ 2 秒）。
const RUN_FRAMES := 120


func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	await _phase1_join_then_host()
	await _phase2_null_peer()
	await _phase3_restore_offline()
	print("CHILD_DONE")
	quit(0)


## ── 阶段 1：用户的原始流程（加入房间 → 创建房间 → 等 9 秒）───────────────
func _phase1_join_then_host() -> void:
	var alloc := PortAlloc.new()
	# 「加入房间」的目标：**我们自己占住**一个端口（UDP socket 收包但不回应）
	# → 连不上（ENet 一直停在 connecting）→ 8 秒的连接超时兜底会被武装起来。
	# ★ 用真实 socket 占住端口 = 别的进程抢不走 → 不会出现「碰巧连上别人」的假通过。
	var dead_port := -1
	var sock := PacketPeerUDP.new()
	for i in 20:
		var p: int = alloc.next()
		if p < 0:
			break
		if sock.bind(p, "127.0.0.1") == OK:
			dead_port = p
			break
	print("P1_DEAD_PORT=", dead_port)
	if dead_port < 0:
		print("P1_SKIP=1")
		return

	var s := SessionScript.new()
	root.add_child(s)
	s.set_transport(ENetTransport.new())

	# ① 用户点「加入房间」（没人应答）
	var join_err: Error = s.join_game("127.0.0.1", dead_port)
	print("P1_JOIN_ERR=", join_err)

	# ② 用户接着点「创建房间」
	var host_port := -1
	for i in 60:
		var p2: int = alloc.next()
		if p2 < 0:
			break
		if s.host_game(p2) == OK:
			host_port = p2
			break
	print("P1_HOST_PORT=", host_port)
	print("P1_ALIVE_AFTER_HOST=", s.is_host())

	# ③ 等过连接超时的时限（8 秒）→ 房间还在吗？
	await create_timer(9.0).timeout
	print("P1_ALIVE_AFTER_9S=", s.is_host())

	sock.close()
	if s.get("_transport") != null:
		var peer = s.get("_transport").get_peer()
		if peer != null and peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
			peer.close()


## ── 阶段 2：mp 上没有 peer 时，场景层必须还能跑（不刷 ERROR、角色能动）──
func _phase2_null_peer() -> void:
	var mp := root.multiplayer
	mp.multiplayer_peer = null
	print("P2_PEER_IS_NULL=", mp.multiplayer_peer == null)
	await _run_scene_frames("P2")


## ── 阶段 3：用 PeerState.restore_offline() 把 mp 恢复成「单机」────────────
func _phase3_restore_offline() -> void:
	var mp := root.multiplayer
	var ps := load("res://scripts/net/peer_state.gd")
	if ps == null:
		print("P3_NO_PEER_STATE=1")
		return
	ps.restore_offline(mp)
	print("P3_UNIQUE_ID=", mp.get_unique_id())
	print("P3_IS_SERVER=", mp.is_server())
	await _run_scene_frames("P3")


## 造一个玩家（权威 1 = 房主）+ 一个守卫，跑 RUN_FRAMES 帧，报两者的位移。
func _run_scene_frames(tag: String) -> void:
	var player_packed: PackedScene = load(PLAYER_SCENE)
	var guard_packed: PackedScene = load(GUARD_SCENE)
	if player_packed == null or guard_packed == null:
		print(tag, "_SCENE_MISSING=1")
		return
	var p := player_packed.instantiate()
	p.name = "1"
	root.add_child(p)
	var g := guard_packed.instantiate()
	g.position = Vector2(300, 300)
	root.add_child(g)
	await process_frame
	var p0: Vector2 = p.position
	var g0: Vector2 = g.position
	Input.action_press("ui_right")
	for i in RUN_FRAMES:
		await physics_frame
	Input.action_release("ui_right")
	print(tag, "_PLAYER_DIST=", snappedf(p.position.distance_to(p0), 0.001))
	print(tag, "_PLAYER_MOVED=", p.position.distance_to(p0) > 1.0)
	print(tag, "_GUARD_DIST=", snappedf(g.position.distance_to(g0), 0.001))
	print(tag, "_GUARD_MOVED=", g.position.distance_to(g0) > 0.5)
	p.queue_free()
	g.queue_free()
	await process_frame
