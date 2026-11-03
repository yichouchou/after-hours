extends SceneTree

## Task 7：Session 层（大厅、成员、回合）。
##
## ------------------------------------------------------------------
## 【headless 单进程的联机链限制】（必须先读）
## ------------------------------------------------------------------
## 两个 peer 不能同时挂在同一个 MultiplayerAPI 上 → **真实 RPC 链在单进程里跑不通**
## （这正是任务书把 apply_to_multiplayer() 排除在 host_game/join_game 之外的原因）。
## 所以本测试用「**接收入口直调**」覆盖联机链：
##   * 房主侧：断言**实际发出的数据** —— Session 的出站台账（_outbox）
##     与「peer id → 清单」映射表（deal_for_peer）；
##   * 客户端侧：把房主发出的消息按「发给谁」投递给客户端的接收入口
##     （_rpc_apply_roster / _rpc_apply_deal / _rpc_apply_round_ended，
##      与真实 RPC 的目标方法完全一致），断言**收到的数据被正确应用**。
## → **本测试不覆盖真实 RPC 传输链**（跨进程），端到端由 Task 13 双窗口手动验收覆盖。
##
## ------------------------------------------------------------------
## 【被改写的一条断言】（任务书第 66 行）
## ------------------------------------------------------------------
## 原断言：`s2.deal().is_empty()`（"客户端不能自己开回合（清单为空）"）。
## 该断言的**意图**是"客户端不能自己开回合"，但**写法**在「名单以房主为权威 +
## 清单定向发给本人」两条裁决落地之后是错的：客户端最终**会**拿到自己那一份清单
## （deal() 里是 1 份，不是空）。
## → 改写为断言「客户端调用 start_round() **没有产生新的回合**」：
##   ① 客户端的 round_started 信号**没有**被触发；
##   ② 房主的 round_started 也**没有**被触发（客户端开不了房主的回合）；
##   ③ 客户端自己的清单**没有**因为这次调用而改变。
## **断言没有被删除，也没有被改弱**（判定方式从"清单为空"换成"没有新回合"，
## 并且在客户端真的拿到清单之后**再验一次**）。
##
## ------------------------------------------------------------------
## 【名单语义】roster_changed 的载荷 = **全员** peer（含房主自己）。
## ------------------------------------------------------------------
## 裁决①：ENet server-relay 下客户端侧 Transport.peer_list() 只含服务器（id 1），
## 客户端用本地 peer_list() 算人数在 3 人局必错 → 名单一律以房主为权威。
## 裁决②：清单**定向**发给本人，客户端只看得到自己那一份。
##
## 端口：27030（2 人局）/ 27031（3 人局）/ 27032（占用）/ 27033（失败用例），
## 避开 Task 6 用过的 27015-27024。收尾全部 close() 并断言端口已释放。

const SessionScript := preload("res://scripts/net/session.gd")

const HOST_PORT := 27030
const THREE_HOST_PORT := 27031
const BUSY_PORT := 27032
const FAIL_PORT := 27033

## lobby_ui.gd 的 5 条 @onready 节点路径（必须与 scenes/lobby.tscn 完全一致）。
const LOBBY_PATHS := [
	"Center/Panel/Margin/VBox/Roster",
	"Center/Panel/Margin/VBox/Status",
	"Center/Panel/Margin/VBox/HostButton",
	"Center/Panel/Margin/VBox/JoinButton",
	"Center/Panel/Margin/VBox/StartButton",
]

## 惩罚性 token（零失败惩罚）。只扫源码，不含 "fail"/"failed" ——
## 传输层的 connection_failed 是正常词汇，不是惩罚。
const PENALTY_TOKENS := ["penalty", "penalized", "score", "points", "score_delta",
	"lives_lost", "eliminated", "hp", "damage", "扣分", "扣命", "淘汰", "死亡"]

var _fails := 0
var _total := 0

# 会话引用（按名字区分，避免按下标猜）
var _s_host: SessionScript = null
var _s_client: SessionScript = null
var _s_host2: SessionScript = null
var _s_c2a: SessionScript = null
var _s_c2b: SessionScript = null

# 信号计数
var _host_round_started_count := 0
var _host_round_ended_count := 0
var _host_roster_changed_count := 0
var _client_round_started_count := 0
var _client_round_ended_count := 0
var _client_roster_changed_count := 0
var _c2a_round_started_count := 0
var _c2b_round_started_count := 0

# 收工摘要的键（断言"没有被塞进任何额外字段"）
var _host_summary_keys: Array = []
var _client_summary_keys: Array = []

# 收尾用：会话与传输
var _sessions: Array = []
var _transports: Array = []


func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	# ==================================================================
	# 0. 契约：autoload 注册 + lobby 场景的节点路径
	# ==================================================================
	var auto_session = root.get_node_or_null("Session")
	_fails += _check(auto_session != null, "Session 自动加载已注册")
	_fails += _check(root.get_node_or_null("Router") != null, "Router 自动加载仍在")

	var packed: PackedScene = load("res://scenes/lobby.tscn")
	_fails += _check(packed != null, "lobby.tscn 可加载")
	if packed != null:
		var lobby := packed.instantiate()
		root.add_child(lobby)
		await process_frame
		for p in LOBBY_PATHS:
			_fails += _check(lobby.get_node_or_null(p) != null,
				"lobby.tscn 存在节点路径 %s" % p)
		# 大厅界面必须能拿到 autoload 的 Session（否则 _ready 取不到）
		_fails += _check(lobby.get("_session") != null,
			"lobby_ui.gd 的 _ready 拿到了 /root/Session")
		lobby.queue_free()
		await process_frame

	# ==================================================================
	# 1. 房主单人局（任务书原用例）
	# ==================================================================
	_s_host = _new_session()
	_s_host.set_transport(ENetTransport.new())

	var e := _s_host.host_game(HOST_PORT)
	_fails += _check(e == OK, "Session 托管成功")
	_fails += _check(_s_host.is_host(), "Session 是 host")
	_fails += _check(_s_host.peer_count() == 1, "房主自己算 1 人")
	_fails += _check(_s_host.peers() == [1],
		"房主名单含自己（peer id 1），实际 %s" % str(_s_host.peers()))
	_fails += _check(_s_host.deal().is_empty(), "还没开回合时清单是空的")

	# set_available_tags 不得修改调用方传进来的数组（裁决⑤：GDScript 数组是引用类型）
	var tags: Array[StringName] = [&"carrot", &"hat", &"basket", &"chair", &"barrel",
		&"lamp", &"bench", &"pot", &"sign"]
	var tags_before := tags.duplicate()
	_s_host.set_available_tags(tags)
	_fails += _check(tags == tags_before,
		"set_available_tags 不修改调用方数组（实际 %s）" % str(tags))

	# 回合：房主生成清单
	_s_host.start_round()
	await process_frame
	_fails += _check(_host_round_started_count == 1,
		"房主开回合触发一次 round_started，实际 %d 次" % _host_round_started_count)
	_fails += _check(_s_host.deal().size() == 1, "单人局生成 1 份清单")
	_fails += _check((_s_host.deal()[0] as Array).size() == 3,
		"单人局 3 张牌，实际 %d" % (_s_host.deal()[0] as Array).size())

	# ==================================================================
	# 2. 客户端加入（任务书原用例）+ 名单以房主为权威（裁决①）
	# ==================================================================
	_s_client = _new_session()
	_s_client.set_transport(ENetTransport.new())
	_s_client.join_game("127.0.0.1", HOST_PORT)

	# 等房主侧的传输看到客户端（真实 ENet 握手）
	var host_saw_client := false
	for i in 300:
		await process_frame
		if _s_host.peers().size() == 2:
			host_saw_client = true
			break
	_fails += _check(host_saw_client,
		"房主侧握手成功，名单变成 2 人，实际 %s" % str(_s_host.peers()))

	var client_peer_id := 0
	for pid in _s_host.peers():
		if pid != 1:
			client_peer_id = pid
	_fails += _check(client_peer_id != 0, "房主名单里能找到客户端的 peer id")
	_fails += _check(_s_host.peers().has(1), "房主名单含自己")
	_fails += _check(_s_host.peers().has(client_peer_id), "房主名单含客户端")

	# 房主把名单广播给客户端（headless 下用接收入口直调模拟"消息到达"）
	var clients := {client_peer_id: _s_client}
	var cursor := _pump(_s_host, clients, 0)

	_fails += _check(_s_client.peer_count() == 2, "客户端已入房，实际 %d" % _s_client.peer_count())
	_fails += _check(not _s_client.is_host(), "客户端不是 host")
	_fails += _check(_s_client.peers() == _s_host.peers(),
		"客户端名单与房主一致（房主权威），客户端 %s / 房主 %s"
		% [str(_s_client.peers()), str(_s_host.peers())])
	_fails += _check(_client_roster_changed_count >= 1,
		"客户端收到名单后触发 roster_changed，实际 %d 次" % _client_roster_changed_count)

	# ==================================================================
	# 3. 客户端不能自己开回合（任务书原断言 → 改写判定方式，见文件头）
	# ==================================================================
	var client_deal_before = _s_client.deal().duplicate(true)
	var client_rs_before := _client_round_started_count
	var host_rs_before := _host_round_started_count
	_s_client.start_round()
	await process_frame
	_fails += _check(_client_round_started_count == client_rs_before,
		"客户端 start_round() 不触发客户端的 round_started（多触发了 %d 次）"
		% (_client_round_started_count - client_rs_before))
	_fails += _check(_host_round_started_count == host_rs_before,
		"客户端 start_round() 不会让房主开回合（多触发了 %d 次）"
		% (_host_round_started_count - host_rs_before))
	_fails += _check(_s_client.deal() == client_deal_before,
		"客户端 start_round() 不改变自己的清单")

	# ==================================================================
	# 4. 房主发清单：定向发给本人（裁决②）
	# ==================================================================
	_s_host.start_round()
	await process_frame
	_fails += _check(_s_host.deal().size() == 2,
		"2 人局生成 2 份清单，实际 %d" % _s_host.deal().size())
	_fails += _check((_s_host.deal()[0] as Array).size() == 3,
		"2 人局每人 3 张牌，实际 %d" % (_s_host.deal()[0] as Array).size())

	# 房主侧「peer id → 清单」映射表可查
	var client_hand = _s_host.deal_for_peer(client_peer_id)
	_fails += _check(client_hand.size() == 3,
		"房主侧 peer→清单 映射表可查（客户端那份 %d 张）" % client_hand.size())
	_fails += _check(not _same_hand(client_hand, _s_host.deal()[0]),
		"发给 peer 的那一份不是房主自己那份")

	cursor = _pump(_s_host, clients, cursor)
	_fails += _check(_s_client.deal().size() == 1,
		"客户端只拿到自己那一份（%d 份，总份数 %d）"
		% [_s_client.deal().size(), _s_host.deal().size()])
	_fails += _check(_s_client.deal().size() != _s_host.deal().size(),
		"客户端的清单份数不等于房主的总份数")
	_fails += _check((_s_client.deal()[0] as Array).size() == 3,
		"客户端那份只有 3 张牌，不是整副牌（实际 %d）"
		% (_s_client.deal()[0] as Array).size())
	_fails += _check(_same_hand(_s_client.deal()[0], client_hand),
		"客户端拿到的就是房主映射给它的那一份")
	_fails += _check(_client_round_started_count >= 1,
		"客户端收到清单时也触发 round_started，实际 %d 次" % _client_round_started_count)

	# ④ 的第二种写法：客户端**已经拿到清单**之后再调一次 start_round()，
	# 清单必须不变、且不产生新的回合。
	var client_deal_now = _s_client.deal().duplicate(true)
	var crs := _client_round_started_count
	var hrs := _host_round_started_count
	_s_client.start_round()
	await process_frame
	_fails += _check(_client_round_started_count == crs,
		"客户端拿到清单后再 start_round() 仍不触发 round_started（多触发了 %d 次）"
		% (_client_round_started_count - crs))
	_fails += _check(_host_round_started_count == hrs,
		"客户端拿到清单后再 start_round() 仍不会让房主开回合")
	_fails += _check(_s_client.deal() == client_deal_now,
		"客户端拿到清单后再 start_round() 清单不变")

	# ==================================================================
	# 5. 房主提前收工
	# ==================================================================
	var summary := {"note": "这一夜到此为止"}
	_s_host.end_round(summary)
	await process_frame
	_fails += _check(_s_host.deal().is_empty(), "结束后清单清空")
	_fails += _check(_host_round_ended_count == 1,
		"房主收工触发一次 round_ended，实际 %d 次" % _host_round_ended_count)
	_fails += _check(_host_summary_keys == summary.keys(),
		"收工摘要原样透传，不被塞进任何额外字段，实际 %s" % str(_host_summary_keys))

	cursor = _pump(_s_host, clients, cursor)
	_fails += _check(_s_client.deal().is_empty(), "客户端也清空清单")
	_fails += _check(_client_round_ended_count == 1,
		"客户端收到收工通知时触发 round_ended，实际 %d 次" % _client_round_ended_count)
	_fails += _check(_client_summary_keys == summary.keys(),
		"客户端收到的收工摘要与房主发出的一致，实际 %s" % str(_client_summary_keys))

	# 空标签：Session 自己补默认标签，且不得写回调用方的空数组（裁决⑤）
	var empty_tags: Array[StringName] = []
	_s_host.set_available_tags(empty_tags)
	var rounds_before := _host_round_started_count
	_s_host.start_round()
	await process_frame
	_fails += _check(empty_tags.is_empty(),
		"空标签时 start_round 不把默认标签写回调用方数组")
	_fails += _check(_host_round_started_count == rounds_before + 1,
		"空标签时 start_round 仍然开了一个回合")
	_fails += _check(_s_host.deal().size() == 2,
		"空标签时按默认标签发牌（2 人局 2 份清单），实际 %d" % _s_host.deal().size())

	# ==================================================================
	# 6. 3 人局（1 房主 + 2 客户端）—— 2 人局会掩盖名单算法的错误
	# ==================================================================
	_s_host2 = _new_session()
	_s_host2.set_transport(ENetTransport.new())
	var e2 := _s_host2.host_game(THREE_HOST_PORT)
	_fails += _check(e2 == OK, "3 人局的房主开房成功")

	_s_c2a = _new_session()
	_s_c2a.set_transport(ENetTransport.new())
	_s_c2a.join_game("127.0.0.1", THREE_HOST_PORT)
	_s_c2b = _new_session()
	_s_c2b.set_transport(ENetTransport.new())
	_s_c2b.join_game("127.0.0.1", THREE_HOST_PORT)

	var three_ready := false
	for i in 300:
		await process_frame
		if _s_host2.peer_count() == 3:
			three_ready = true
			break
	_fails += _check(three_ready,
		"3 人局：房主等到了两个客户端，实际 %d 人" % _s_host2.peer_count())
	_fails += _check(_s_host2.peer_count() == 3,
		"3 人局房主看到 3 人，实际 %d" % _s_host2.peer_count())
	_fails += _check(_s_host2.peers().size() == 3, "3 人局房主名单有 3 个 peer")

	var a_id := 0
	var b_id := 0
	for pid in _s_host2.peers():
		if pid == 1:
			continue
		if a_id == 0:
			a_id = pid
		else:
			b_id = pid
	_fails += _check(a_id != 0 and b_id != 0, "3 人局房主能区分两个客户端的 peer id")

	var clients2 := {a_id: _s_c2a, b_id: _s_c2b}
	_pump(_s_host2, clients2, 0)
	_fails += _check(_s_c2a.peer_count() == 3,
		"3 人局客户端 A 看到 3 人，实际 %d" % _s_c2a.peer_count())
	_fails += _check(_s_c2b.peer_count() == 3,
		"3 人局客户端 B 看到 3 人，实际 %d" % _s_c2b.peer_count())
	_fails += _check(_s_c2a.peers() == _s_host2.peers(), "3 人局客户端 A 的名单与房主一致")
	_fails += _check(_s_c2b.peers() == _s_host2.peers(), "3 人局客户端 B 的名单与房主一致")

	# 3 人局的清单同样定向
	_s_host2.start_round()
	await process_frame
	_fails += _check(_s_host2.deal().size() == 3,
		"3 人局生成 3 份清单，实际 %d" % _s_host2.deal().size())
	_fails += _check((_s_host2.deal()[0] as Array).size() == 4,
		"3 人局每人 4 张牌，实际 %d" % (_s_host2.deal()[0] as Array).size())
	_pump(_s_host2, clients2, 0)
	_fails += _check(_s_c2a.deal().size() == 1, "3 人局客户端 A 只拿到 1 份")
	_fails += _check(_s_c2b.deal().size() == 1, "3 人局客户端 B 只拿到 1 份")
	_fails += _check((_s_c2a.deal()[0] as Array).size() == 4,
		"3 人局客户端 A 那份只有 4 张牌，不是整副牌（实际 %d）"
		% (_s_c2a.deal()[0] as Array).size())
	_fails += _check((_s_c2b.deal()[0] as Array).size() == 4,
		"3 人局客户端 B 那份只有 4 张牌，不是整副牌（实际 %d）"
		% (_s_c2b.deal()[0] as Array).size())
	_fails += _check(_same_hand(_s_c2a.deal()[0], _s_host2.deal_for_peer(a_id)),
		"3 人局客户端 A 拿的是 A 自己那一份")
	_fails += _check(_same_hand(_s_c2b.deal()[0], _s_host2.deal_for_peer(b_id)),
		"3 人局客户端 B 拿的是 B 自己那一份")
	_fails += _check(not _same_hand(_s_c2a.deal()[0], _s_c2b.deal()[0]),
		"3 人局两个客户端拿到的不是同一份")
	_fails += _check(_c2a_round_started_count >= 1 and _c2b_round_started_count >= 1,
		"3 人局两个客户端都收到了 round_started")

	# ==================================================================
	# 7. 失败路径：返回非 OK 且状态自洽
	# ==================================================================
	var busy := ENetTransport.new()
	_transports.append(busy)
	var e_busy := busy.host(BUSY_PORT, 2)
	_fails += _check(e_busy == OK, "占用端口的对照 server 开房成功")

	var s3 = _new_session()
	s3.set_transport(ENetTransport.new())
	# 预期失败：压掉引擎自身的 ERROR 日志，保持测试输出干净
	Engine.print_error_messages = false
	var e3 := s3.host_game(BUSY_PORT)
	Engine.print_error_messages = true
	_fails += _check(e3 != OK, "端口被占时 host_game 返回非 OK 的 Error（实际 %d）" % e3)
	_fails += _check(not s3.is_host(), "host 失败后 is_host() 仍为 false")
	_fails += _check(s3.peer_count() == 0,
		"host 失败后 peer_count() 仍为 0，实际 %d" % s3.peer_count())
	_fails += _check(s3.deal().is_empty(), "host 失败后清单仍为空")
	_fails += _check(s3.peers().is_empty(),
		"host 失败后名单仍为空，实际 %s" % str(s3.peers()))

	var s4 = _new_session()
	s4.set_transport(ENetTransport.new())
	Engine.print_error_messages = false
	var e4 := s4.join_game("不是一个服务器地址", FAIL_PORT)
	Engine.print_error_messages = true
	_fails += _check(e4 != OK, "非法地址 join 返回非 OK 的 Error（实际 %d）" % e4)
	_fails += _check(not s4.is_host(), "join 失败后 is_host() 仍为 false")
	_fails += _check(s4.peer_count() == 0,
		"join 失败后 peer_count() 仍为 0，实际 %d" % s4.peer_count())
	_fails += _check(s4.peers().is_empty(), "join 失败后名单仍为空")

	# ==================================================================
	# 8. 纯净化 + 零失败惩罚
	# ==================================================================
	var net_files := ["res://scripts/net/session.gd", "res://scripts/net/transport.gd",
		"res://scripts/net/enet_transport.gd"]
	for path in net_files:
		var src := _read_source(path)
		_fails += _check(not src.contains("Steam."), "%s 不出现 Steam. 调用" % path)
	var ui_src := _read_source("res://scripts/ui/lobby_ui.gd")
	_fails += _check(not ui_src.contains("Steam."), "scripts/ui/lobby_ui.gd 不出现 Steam. 调用")
	var session_src := _read_source("res://scripts/net/session.gd")
	for token in PENALTY_TOKENS:
		_fails += _check(not session_src.contains(token),
			"Session 不出现惩罚性 token「%s」（零失败惩罚）" % token)

	# ==================================================================
	# 9. 收尾：释放会话与端口
	# ==================================================================
	for s5 in _sessions:
		s5.queue_free()
	await process_frame
	await process_frame
	for t in _transports:
		var p = t.get_peer()
		if p != null and p.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
			p.close()

	var probe := ENetTransport.new()
	var e_free := probe.host(HOST_PORT, 1)
	_fails += _check(e_free == OK, "收尾后端口 %d 已释放（实际 %d）" % [HOST_PORT, e_free])
	if probe.get_peer() != null:
		probe.get_peer().close()
	var probe2 := ENetTransport.new()
	var e_free2 := probe2.host(THREE_HOST_PORT, 1)
	_fails += _check(e_free2 == OK, "收尾后端口 %d 已释放（实际 %d）" % [THREE_HOST_PORT, e_free2])
	if probe2.get_peer() != null:
		probe2.get_peer().close()

	print("")
	print("断言总数：%d" % _total)
	if _fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % _fails)
		quit(1)


## 新建一个 Session 并登记（便于收尾时统一 queue_free）。
func _new_session() -> SessionScript:
	var s = SessionScript.new()
	root.add_child(s)
	_sessions.append(s)
	s.roster_changed.connect(func(_peers): _on_roster_changed(s))
	s.round_started.connect(func(_deal): _on_round_started(s))
	s.round_ended.connect(func(summary): _on_round_ended(s, summary))
	return s


func _on_roster_changed(s: SessionScript) -> void:
	if s == null:
		return
	if s == _s_host:
		_host_roster_changed_count += 1
	elif s == _s_client:
		_client_roster_changed_count += 1


func _on_round_started(s: SessionScript) -> void:
	if s == null:
		return
	if s == _s_host:
		_host_round_started_count += 1
	elif s == _s_host2:
		pass
	elif s == _s_c2a:
		_c2a_round_started_count += 1
	elif s == _s_c2b:
		_c2b_round_started_count += 1
	else:
		_client_round_started_count += 1


func _on_round_ended(s: SessionScript, summary: Dictionary) -> void:
	if s == null:
		return
	if s == _s_host:
		_host_round_ended_count += 1
		_host_summary_keys = summary.keys()
	else:
		_client_round_ended_count += 1
		_client_summary_keys = summary.keys()


## 把房主「实际发出的」消息按发给谁投递给对应客户端的接收入口。
##
## headless 单进程里两个 peer 不能挂在同一个 MultiplayerAPI 上 → 真实 RPC 链跑不通。
## 这里模拟的只是"消息到达"这一步，**收方入口与真实 RPC 的目标方法完全一致**。
## 返回新的游标（已投递到的出站台账下标）。
func _pump(host: SessionScript, clients: Dictionary, from_index: int) -> int:
	var box: Array = host.get("_outbox")
	var i := from_index
	while i < box.size():
		var msg: Dictionary = box[i]
		i += 1
		var target = clients.get(int(msg["peer"]), null)
		if target == null:
			continue
		match String(msg["method"]):
			"_rpc_apply_roster":
				target._apply_roster(msg["args"][0])
			"_rpc_apply_deal":
				target._apply_deal(msg["args"][0])
			"_rpc_apply_round_ended":
				target._apply_round_ended(msg["args"][0])
	return i


## 两份清单（行为集合）是否相同 —— 按 id 比，不依赖容器比较语义。
func _same_hand(a: Array, b: Array) -> bool:
	return _hand_ids(a) == _hand_ids(b)


func _hand_ids(hand: Array) -> Array:
	var out: Array = []
	for m in hand:
		out.append(str(m.get("id")))
	return out


func _read_source(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


func _check(ok: bool, what: String) -> int:
	_total += 1
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
