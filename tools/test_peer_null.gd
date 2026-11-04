extends SceneTree

## 回归测试：2026-11-04 用户报障 ——
## 「ERROR: No multiplayer peer is assigned. Unable to get unique ID.」每帧刷屏
## + **角色卡住**（backtrace：scripts/guard.gd:88 / scripts/player.gd:198）。
##
## ------------------------------------------------------------------
## 【根因（headless 探针 100% 复现）】
## ------------------------------------------------------------------
##   用户的操作顺序是「加入房间」→「创建房间」：
##     * join_game() 起了 8 秒的连接超时兜底计时器；
##     * host_game() **没有停掉它**（加入房间的尝试其实已经被「创建房间」取代了）；
##     * 8 秒后那个计时器触发 → _drop_transport() → mp.multiplayer_peer = null
##       → 引擎每帧打一条 ERROR（scene_multiplayer.cpp:531），
##         get_unique_id() 返回 0 → is_multiplayer_authority() 恒为 false
##         → **输入被整个忽略（角色卡住）**；
##         multiplayer.is_server() 恒为 false → **守卫 AI 完全停摆**。
##
## ------------------------------------------------------------------
## 【修法（三条腿）】
## ------------------------------------------------------------------
##   ① host_game() 停掉残留的连接超时计时器（直接触发点）；
##   ② mp 上**永远不留 null peer**：没有 peer 时挂回 OfflineMultiplayerPeer
##      （引擎自己的默认值：unique_id == 1、is_server() == true）；
##   ③ 场景层（player.gd / guard.gd）改用 PeerState 判定，
##      「没有 peer」时按引擎的默认口径（**本机即房主，peer id 1**）走。
##
## 断言编号见下面各段注释（[PN-1] … [PN-8]）。

const SessionScript := preload("res://scripts/net/session.gd")
const PortAlloc := preload("res://tools/port_alloc.gd")
const PLAYER_SCENE := "res://scenes/player.tscn"
const GUARD_SCENE := "res://scenes/guard.tscn"
const LOBBY_SCENE := "res://scenes/lobby.tscn"

## 本测试的**帧预算**（统一入口用 --quit-after 600 跑）。
## headless 实测约 140 fps → 600 帧 ≈ 4.3 秒。
const FRAME_BUDGET := 560

## 场景里跑的帧数（玩家 / 守卫）。
const RUN_FRAMES := 30

var _fails := 0
var _total := 0


func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	await _pn1_connect_timeout_cleared_by_host()
	await _pn2_peer_state_semantics()
	await _pn3_restore_offline()
	await _pn4_player_without_peer()
	await _pn5_guard_without_peer()
	await _pn6_session_reports_failure()
	await _pn7_child_process_end_to_end()
	await _pn8_lobby_shows_reason()

	print("")
	print("断言总数：%d" % _total)
	print("本进程用掉的帧数：%d（预算 %d，统一入口的 --quit-after 是 600）"
		% [Engine.get_process_frames(), FRAME_BUDGET])
	if _fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % _fails)
		quit(1)


## ==================================================================
## [PN-1] host_game() 必须停掉 join_game() 留下的连接超时计时器
##
## ★ 这就是用户报障的**直接触发点**：
##   「加入房间」武装了 8 秒兜底 → 「创建房间」没停它 → 8 秒后房间被拆。
## ==================================================================
func _pn1_connect_timeout_cleared_by_host() -> void:
	var alloc := PortAlloc.new()
	var s := SessionScript.new()
	root.add_child(s)
	s.set_transport(ENetTransport.new())
	# ★ 缩短连接超时（测试缝；生产代码没有这个属性时 set() 是静默 no-op）。
	s.set("connect_timeout_sec", 0.4)

	# 「加入房间」的目标端口：自己占住一个 UDP socket（收包但不回应）→ 连不上。
	var dead_port := -1
	var sock := PacketPeerUDP.new()
	for i in 20:
		var p: int = alloc.next()
		if p < 0:
			break
		if sock.bind(p, "127.0.0.1") == OK:
			dead_port = p
			break
	_fails += _check(dead_port >= 0, "[PN-1a] 能占住一个端口当「加入房间」的目标")
	if dead_port < 0:
		return

	var join_err: Error = s.join_game("127.0.0.1", dead_port)
	_fails += _check(join_err == OK, "[PN-1b] 「加入房间」本身不报错（连不上是正常结局）")

	var timer: Timer = s.get("_timeout_timer")
	_fails += _check(timer != null, "[PN-1c] Session 有连接超时计时器")
	if timer == null:
		return
	_fails += _check(not timer.is_stopped(),
		"[PN-1d] 「加入房间」之后连接超时计时器是**武装**的（前提）")

	# 用户接着点「创建房间」
	var host_port := -1
	for i in 60:
		var p2: int = alloc.next()
		if p2 < 0:
			break
		if s.host_game(p2) == OK:
			host_port = p2
			break
	_fails += _check(host_port >= 0, "[PN-1e] 「创建房间」成功")
	_fails += _check(timer.is_stopped(),
		"[PN-1f] ★「创建房间」停掉了残留的连接超时计时器（用户报障的直接触发点）")
	_fails += _check(s.is_host(), "[PN-1g] 「创建房间」之后本机是房主")

	# 过了连接超时的时限之后，房间必须还在（修复前：被那个残留计时器拆掉）。
	await _wait_ms(700)
	_fails += _check(s.is_host(),
		"[PN-1h] ★过了连接超时时限，房间仍然是房主的（没被残留计时器拆掉）")
	_fails += _check(timer.is_stopped(),
		"[PN-1i] 连接超时计时器仍然是停的")

	sock.close()
	var peer = s.get("_transport").get_peer() if s.get("_transport") != null else null
	if peer != null and peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
		peer.close()
	s.queue_free()
	await process_frame


## ==================================================================
## [PN-2] PeerState 的口径：没有 peer 时按引擎的默认口径走
##
## ★ 引擎的默认值是 OfflineMultiplayerPeer：unique_id == 1、is_server() == true
##   → 「没有 peer」= 「本机单机当房主」，而不是「本机什么都不是」。
## ==================================================================
func _pn2_peer_state_semantics() -> void:
	# ★ 用运行期 load()（不是 preload）：文件不存在时是**干净的断言失败**，
	#   而不是整个测试脚本编译不过。
	var ps := load("res://scripts/net/peer_state.gd")
	_fails += _check(ps != null, "[PN-2a] PeerState 脚本存在（scripts/net/peer_state.gd）")
	if ps == null:
		return

	var mp := root.multiplayer
	# 先把 mp 弄成「没有 peer」
	var saved = mp.multiplayer_peer
	mp.multiplayer_peer = null
	_fails += _check(not bool(ps.has_peer(mp)), "[PN-2b] 没有 peer 时 has_peer() == false")
	_fails += _check(int(ps.local_peer_id(mp)) == 1,
		"[PN-2c] 没有 peer 时 local_peer_id() == 1（引擎默认口径：单机即房主）")
	_fails += _check(bool(ps.is_local_host(mp)),
		"[PN-2d] 没有 peer 时 is_local_host() == true（本机即房主）")

	# 节点权威：权威 == 1 的节点归本机，别的节点不归本机。
	var owned := Node2D.new()
	owned.name = "1"
	root.add_child(owned)
	await process_frame
	owned.set_multiplayer_authority(1)
	_fails += _check(bool(ps.owns_node(owned)),
		"[PN-2e] 没有 peer 时：权威 == 1 的节点归本机")
	var other := Node2D.new()
	other.name = "2"
	root.add_child(other)
	await process_frame
	other.set_multiplayer_authority(2)
	_fails += _check(not bool(ps.owns_node(other)),
		"[PN-2f] 没有 peer 时：权威 != 1 的节点**不**归本机")

	owned.queue_free()
	other.queue_free()
	mp.multiplayer_peer = saved
	await process_frame


## ==================================================================
## [PN-3] PeerState.restore_offline()：把 mp 恢复成「单机」
##
## ★ 这条是「不刷 ERROR」的根本保障：
##   mp.multiplayer_peer == null 时，引擎每帧打一条 ERROR
##   （scene_multiplayer.cpp:531），而且 get_unique_id() 返回 0
##   → is_multiplayer_authority() 恒为 false → 角色卡住。
##   换回 OfflineMultiplayerPeer（引擎自己的默认值）之后：
##   unique_id == 1、is_server() == true、权威 1 的节点是本机权威。
## ==================================================================
func _pn3_restore_offline() -> void:
	var ps := load("res://scripts/net/peer_state.gd")
	if ps == null:
		_fails += _check(false, "[PN-3a] PeerState 脚本存在")
		return
	var mp := root.multiplayer
	var saved = mp.multiplayer_peer
	mp.multiplayer_peer = null
	ps.restore_offline(mp)
	_fails += _check(mp.multiplayer_peer != null,
		"[PN-3a] restore_offline() 之后 mp 上重新挂上了 peer")
	# ★ 这两个取值在 peer 为 null 时会打引擎 ERROR；恢复之后必须干净。
	Engine.print_error_messages = false
	var uid: int = mp.get_unique_id()
	var is_server: bool = mp.is_server()
	Engine.print_error_messages = true
	_fails += _check(uid == 1,
		"[PN-3b] 恢复之后 get_unique_id() == 1（实际 %d）" % uid)
	_fails += _check(is_server,
		"[PN-3c] 恢复之后 is_server() == true（本机即房主）")
	mp.multiplayer_peer = saved
	await process_frame


## ==================================================================
## [PN-4] 没有 peer 时，玩家**仍然响应输入**（角色不许卡住）
## ==================================================================
func _pn4_player_without_peer() -> void:
	var mp := root.multiplayer
	var saved = mp.multiplayer_peer
	mp.multiplayer_peer = null
	var packed: PackedScene = load(PLAYER_SCENE)
	if packed == null:
		_fails += _check(false, "[PN-4a] player.tscn 可加载")
		mp.multiplayer_peer = saved
		return
	var p := packed.instantiate()
	p.name = "1"
	root.add_child(p)
	await process_frame
	var before: Vector2 = p.position
	Input.action_press("ui_right")
	for i in RUN_FRAMES:
		await physics_frame
	Input.action_release("ui_right")
	var dist: float = p.position.distance_to(before)
	_fails += _check(dist > 1.0,
		"[PN-4a] ★没有 peer 时玩家仍然响应输入（位移 %.2f px）" % dist)
	p.queue_free()
	mp.multiplayer_peer = saved
	await process_frame


## ==================================================================
## [PN-5] 没有 peer 时，守卫 AI **仍然在跑**（不许整场停摆）
## ==================================================================
func _pn5_guard_without_peer() -> void:
	var mp := root.multiplayer
	var saved = mp.multiplayer_peer
	mp.multiplayer_peer = null
	var packed: PackedScene = load(GUARD_SCENE)
	if packed == null:
		_fails += _check(false, "[PN-5a] guard.tscn 可加载")
		mp.multiplayer_peer = saved
		return
	var g := packed.instantiate()
	g.position = Vector2(300, 300)
	root.add_child(g)
	await process_frame
	var before: Vector2 = g.position
	for i in RUN_FRAMES:
		await physics_frame
	var dist: float = g.position.distance_to(before)
	_fails += _check(dist > 0.5,
		"[PN-5a] ★没有 peer 时守卫 AI 仍然在跑（位移 %.2f px）" % dist)
	g.queue_free()
	mp.multiplayer_peer = saved
	await process_frame


## ==================================================================
## [PN-6] Session：连接超时 → 明确报告失败（信号 + 原因）+ 房间被拆
## ==================================================================
func _pn6_session_reports_failure() -> void:
	var alloc := PortAlloc.new()
	var s := SessionScript.new()
	root.add_child(s)
	s.set_transport(ENetTransport.new())
	s.set("connect_timeout_sec", 0.4)

	var lost: Array = []
	if s.has_signal(&"connection_lost"):
		s.connect(&"connection_lost", func(reason: String) -> void: lost.append(reason))
	_fails += _check(s.has_signal(&"connection_lost"),
		"[PN-6a] Session 有 connection_lost 信号（连接断了要有人知道）")

	var dead_port := -1
	var sock := PacketPeerUDP.new()
	for i in 20:
		var p: int = alloc.next()
		if p < 0:
			break
		if sock.bind(p, "127.0.0.1") == OK:
			dead_port = p
			break
	if dead_port < 0:
		_fails += _check(false, "[PN-6b] 能占住一个端口当「加入房间」的目标")
		return
	s.join_game("127.0.0.1", dead_port)

	await _wait_ms(700)
	_fails += _check(lost.size() == 1,
		"[PN-6b] 连接超时后发了**一次** connection_lost（实际 %d 次）" % lost.size())
	var reason := ""
	if s.has_method(&"failure_reason"):
		reason = str(s.call(&"failure_reason"))
	_fails += _check(not reason.is_empty(),
		"[PN-6c] 连接超时后记下了失败原因（给界面显示用）")
	_fails += _check(not s.is_host(),
		"[PN-6d] 连接超时后本机不再是房主（房间确实被拆了）")
	_fails += _check(s.peer_count() == 0,
		"[PN-6e] 连接超时后名单已清空（回到大厅态）")
	sock.close()
	s.queue_free()
	await process_frame


## ==================================================================
## [PN-7] 子进程端到端：用户的原始场景 → 0 行 ERROR + 房间还在 + 玩家能动
##
## ★ 「引擎 ERROR 行数」只能从**子进程的 stderr** 里数（本进程自察不到）。
##   做法与 tools/test_player.gd 的 §4-10-C 同款（OS.execute + 抓输出）。
## ==================================================================
func _pn7_child_process_end_to_end() -> void:
	var child_out: Array = []
	var child_args := PackedStringArray([
		"--headless",
		"--path", ProjectSettings.globalize_path("res://"),
		"--quit-after", "4000",
		"--script", "res://tools/peer_null_child.gd",
	])
	var child_code := OS.execute(OS.get_executable_path(), child_args, child_out, true)
	var text := ""
	for chunk in child_out:
		text += str(chunk)
	var err_lines: Array[String] = []
	for line in text.split("\n"):
		if line.contains("ERROR"):
			err_lines.append(line.strip_edges())
	_fails += _check(child_code == 0,
		"[PN-7a] 端到端子进程正常退出（实际 %d）" % child_code)
	_fails += _check(text.contains("CHILD_DONE"),
		"[PN-7b] 端到端子进程跑完了三个阶段")
	_fails += _check(err_lines.is_empty(),
		"[PN-7c] ★子进程输出**没有**引擎 ERROR 行（实际 %d 行）%s"
		% [err_lines.size(), _first(err_lines)])
	_fails += _check(text.contains("P1_ALIVE_AFTER_9S=true"),
		"[PN-7d] ★「加入房间」→「创建房间」之后过了 9 秒，房间还在")
	_fails += _check(text.contains("P2_PLAYER_MOVED=true"),
		"[PN-7e] ★没有 peer 时玩家仍然能动")
	_fails += _check(text.contains("P2_GUARD_MOVED=true"),
		"[PN-7f] ★没有 peer 时守卫 AI 仍然在跑")
	_fails += _check(text.contains("P3_UNIQUE_ID=1"),
		"[PN-7g] restore_offline() 之后本机 peer id == 1")
	_fails += _check(text.contains("P3_PLAYER_MOVED=true"),
		"[PN-7h] 恢复成单机之后玩家仍然能动")


## ==================================================================
## [PN-8] 大厅界面：连接失败要在状态栏说清楚（不许静默）
## ==================================================================
func _pn8_lobby_shows_reason() -> void:
	var packed: PackedScene = load(LOBBY_SCENE)
	if packed == null:
		_fails += _check(false, "[PN-8a] lobby.tscn 可加载")
		return
	var lobby := packed.instantiate()
	root.add_child(lobby)
	await process_frame

	var alloc := PortAlloc.new()
	var s := SessionScript.new()
	root.add_child(s)
	s.set_transport(ENetTransport.new())
	s.set("connect_timeout_sec", 0.4)
	# 让大厅用这个 Session（连接要重新指到替身上）
	lobby.set("_session", s)
	lobby.call("_connect_session_signals")

	var dead_port := -1
	var sock := PacketPeerUDP.new()
	for i in 20:
		var p: int = alloc.next()
		if p < 0:
			break
		if sock.bind(p, "127.0.0.1") == OK:
			dead_port = p
			break
	if dead_port < 0:
		_fails += _check(false, "[PN-8b] 能占住一个端口当「加入房间」的目标")
		return
	s.join_game("127.0.0.1", dead_port)

	await _wait_ms(700)
	var status = lobby.get("_status")
	var text := "" if status == null else str(status.text)
	_fails += _check(text.contains("超时"),
		"[PN-8c] ★连接失败后大厅状态栏说清楚了（实际 '%s'）" % text)
	sock.close()
	s.queue_free()
	lobby.queue_free()
	await process_frame


## ── 小工具 ────────────────────────────────────────────────────────────

## 等一段时间（毫秒）。带**帧预算护栏**：预算用尽就立刻返回，
## 否则会把帧数用光 → 进程被引擎静默掐掉（退出码 0、没有 "TEST FAILED"）。
func _wait_ms(ms: int) -> void:
	var deadline := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < deadline:
		if Engine.get_process_frames() > FRAME_BUDGET:
			print("  [WARN] 帧预算用尽 → 提前结束等待")
			return
		await create_timer(0.05).timeout


## 违规列表的首条描述（用于失败诊断）。
func _first(bad: Array) -> String:
	if bad.is_empty():
		return ""
	return " —— 例如：%s" % str(bad[0])


func _check(ok: bool, what: String) -> int:
	_total += 1
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
