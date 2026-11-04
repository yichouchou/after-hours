extends SceneTree

## Task 12：端到端冒烟的**子进程**（房主端 / 客户端端）。
##
## 由父进程 tools/test_smoke.gd 用 OS.execute 拉起：
##     <godot> --headless --path <proj> --quit-after 20000 \
##             --script res://tools/smoke_child.gd \
##             -- <mode> <base> <span> <handoff_path>
##
## | mode     | 含义                                                     |
## |----------|----------------------------------------------------------|
## | "host"   | 房主：绑定候选端口 → 写交接文件 → 等客户端 → 开局 → 收工    |
## | "client" | 客户端：连房主 → 等清单 → 进对局场景 → 等结算页            |
##
## ★ **端口是动态分配的**：候选池只有 27100–27299（tools/port_alloc.gd），
##   **绑定成功**才算这个端口可用（真实 socket 裁决，不许「探测完就交出去」）。
## ★ **交接文件**：房主绑定成功之后把端口号写进去 → 父进程轮询这个文件
##   → 客户端**一定**能连上房主（不用魔法延迟）。
## ★ 结果用 `SMOKE|` 开头的行写到 stdout，父进程解析。
## ★ **引擎的错误/告警输出保持打开** → 父进程要断言「零 ERROR/WARNING」。

const SessionScript := preload("res://scripts/net/session.gd")
const PortAlloc := preload("res://tools/port_alloc.gd")

const LOBBY_SCENE := "res://scenes/lobby.tscn"
const GAME_SCENE := "res://scenes/game.tscn"
const RESULT_SCENE := "res://scenes/result.tscn"

## 轮询间隔（秒）。
const STEP_SEC := 0.05
## 房主比客户端多活多久（Task 7 实测：房主先退会把客户端的连接掐断）。
const HOST_EXTRA_LIFE_MS := 2500
## 房主生成玩家之后，等一会儿再点「收工」（让客户端先收到生成消息）。
const HOST_SETTLE_MS := 1500
## 客户端在结算页上等一会儿再汇报（让**房主先汇报** —— 房主先退会把客户端掐断；
## 客户端先退的话，房主汇报时看到的就只剩 1 人了）。
const CLIENT_REPORT_DELAY_MS := 900

var _mode := "host"
var _base := 27100
var _span := 1
var _handoff := "-"
var _host_port := 0
var _host_err := 0
var _join_err := 0
var _session = null
var _t0 := 0

var _round_started := 0
var _round_ended := 0
var _summary: Dictionary = {}
var _roster: Array[int] = []

## 大厅里读到的对局场景路径（两端各自读自己的默认值 → 父进程逐字节比对）。
var _lobby_scene_path := ""

## 对局场景里的事实（**切到结算页之前**抓下来 —— 之后场景就没了）。
var _game_scene_file := ""
var _player_names := ""
var _player_count := 0
var _local_player_found := false
var _local_hand_size := 0
var _deal_hands := 0
var _card_ids := ""
var _finish_disabled := true

## 结算页里的事实。
var _result_scene_file := ""
var _result_cards := 0
var _result_text := ""


func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 1:
		_mode = str(args[0])
	if args.size() >= 2:
		_base = int(args[1])
	if args.size() >= 3:
		_span = int(args[2])
	if args.size() >= 4:
		_handoff = str(args[3])
	_t0 = Time.get_ticks_msec()

	_resolve_session()
	_session.set_transport(ENetTransport.new())
	_session.roster_changed.connect(_on_roster)
	_session.round_started.connect(_on_round_started)
	_session.round_ended.connect(_on_round_ended)

	if _mode == "host":
		await _run_host()
	else:
		await _run_client()
	_report()
	if _mode == "host":
		# 房主必须比客户端活得久（Task 7 实测）。
		await _sleep_ms(HOST_EXTRA_LIFE_MS)
	quit(0)


## ------------------------------------------------------------------
## 房主
## ------------------------------------------------------------------

func _run_host() -> void:
	# ★ 真实绑定裁决：按候选序列逐个尝试，绑定成功才算这个端口可用。
	var alloc := PortAlloc.new(_base, maxi(_span, 1), 0)
	var last_err: Error = ERR_CANT_CREATE
	while not alloc.exhausted():
		var p: int = alloc.next()
		if p < 0:
			break
		# 预期失败：引擎自己会打一条 ERROR（"Couldn't create an ENet host."）→ 压掉，保持输出干净。
		Engine.print_error_messages = false
		last_err = _session.host_game(p)
		Engine.print_error_messages = true
		if last_err != OK:
			continue
		_host_port = p
		# ★ 写交接文件（**绑定成功之后**才写 → 「文件存在」⟺「端口已被占住」）。
		if not _write_handoff(p):
			_host_err = ERR_FILE_CANT_OPEN
			return
		break
	if _host_port == 0:
		_host_err = last_err
		return
	# 先 host 成功，再挂到 MultiplayerAPI。
	_session.apply_to_multiplayer()

	# 进大厅（生产路径：Router 会自动切过去；--script 模式下 current_scene 为空，
	# 它不会自动跳 → 这里自己切，保持脚本可控）。
	await _sleep_ms(200)
	change_scene_to_file(LOBBY_SCENE)
	await _sleep_ms(300)
	var lobby = current_scene
	if lobby == null:
		return
	_lobby_scene_path = str(lobby.get("game_scene_path"))

	# 等客户端进来。
	var joined := false
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		if _session.peer_count() >= 2:
			joined = true
			break
		await create_timer(STEP_SEC).timeout
	if not joined:
		return

	# 房主点「开始这一夜」→ round_started → 大厅切进对局场景。
	lobby.call(&"_on_start")
	await create_timer(STEP_SEC).timeout

	# 等对局场景 + 玩家都生成出来（远端玩家的生成要等一小会儿 —— 缺口 C）。
	var in_game := false
	deadline = Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		if _current_scene_file() == GAME_SCENE:
			var players := _players_root()
			if players != null and players.get_child_count() >= 2:
				in_game = true
				break
		await create_timer(STEP_SEC).timeout
	if not in_game:
		return

	_capture_game_facts()

	# 让客户端先把生成消息处理完，再收工。
	await _sleep_ms(HOST_SETTLE_MS)

	# 点「收工」→ 组装摘要 → 广播 → 两端切到结算页。
	var game = current_scene
	if game != null:
		var hud = game.get_node_or_null("HUD")
		if hud != null:
			var btn = hud.get_node_or_null("FinishButton")
			if btn != null:
				btn.emit_signal(&"pressed")
	await create_timer(STEP_SEC).timeout

	# 等结算页。
	deadline = Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		if _current_scene_file() == RESULT_SCENE:
			break
		await create_timer(STEP_SEC).timeout
	_capture_result_facts()


## ------------------------------------------------------------------
## 客户端
## ------------------------------------------------------------------

func _run_client() -> void:
	# ★ 先把大厅装好，再连房主 —— 否则清单可能在客户端进大厅之前就到了，
	#   客户端就收不到 round_started（也就切不进对局场景）。
	await _sleep_ms(200)
	change_scene_to_file(LOBBY_SCENE)
	await _sleep_ms(300)
	var lobby = current_scene
	if lobby == null:
		return
	_lobby_scene_path = str(lobby.get("game_scene_path"))

	_join_err = _session.join_game("127.0.0.1", _base)
	if _join_err != OK:
		return
	_session.apply_to_multiplayer()

	# 等房主开局的清单。
	var deadline := Time.get_ticks_msec() + 25000
	while Time.get_ticks_msec() < deadline:
		if _round_started > 0:
			break
		await create_timer(STEP_SEC).timeout

	# 等对局场景 + **自己的**玩家节点（缺口 C 的核心：客户端必须真的拿到它）。
	var local_peer_id := get_multiplayer().get_unique_id()
	var got_player := false
	deadline = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		if _current_scene_file() == GAME_SCENE:
			var players := _players_root()
			if players != null and players.get_node_or_null(str(local_peer_id)) != null:
				got_player = true
				break
		await create_timer(STEP_SEC).timeout
	if not got_player:
		return

	_capture_game_facts()

	# 等结算页。
	deadline = Time.get_ticks_msec() + 25000
	while Time.get_ticks_msec() < deadline:
		if _current_scene_file() == RESULT_SCENE:
			break
		await create_timer(STEP_SEC).timeout
	_capture_result_facts()
	# ★ 回报前先等一小会儿：**房主的汇报必须发生在客户端退出之前**
	#   （房主先退会把客户端的连接掐断；反过来客户端先退，
	#   房主在汇报时看到的就只剩 1 人了）。
	await _sleep_ms(CLIENT_REPORT_DELAY_MS)


## ------------------------------------------------------------------
## 抓事实
## ------------------------------------------------------------------

## 抓对局场景里的事实（切走之前抓）。
func _capture_game_facts() -> void:
	var game = current_scene
	if game == null:
		return
	_game_scene_file = _current_scene_file()
	var players := _players_root()
	if players == null:
		return
	var names: Array[String] = []
	for child in players.get_children():
		names.append(str(child.name))
	_player_names = ",".join(names)
	_player_count = names.size()
	var local_peer_id := get_multiplayer().get_unique_id()
	var local = players.get_node_or_null(str(local_peer_id))
	_local_player_found = local != null
	if local != null:
		var hand: Array = local.get("hand")
		_local_hand_size = hand.size()
	var deal: Array = _session.deal()
	_deal_hands = deal.size()
	if deal.size() > 0:
		var hand0: Array = deal[0]
		var ids: Array[String] = []
		for m in hand0:
			ids.append(str(m.get("id")))
		_card_ids = ",".join(ids)
	var hud = game.get_node_or_null("HUD")
	if hud != null:
		var btn = hud.get_node_or_null("FinishButton")
		if btn != null:
			_finish_disabled = bool(btn.get("disabled"))


## 抓结算页里的事实。
func _capture_result_facts() -> void:
	_result_scene_file = _current_scene_file()
	var result = current_scene
	if result == null:
		return
	var cards = result.get_node_or_null("Center/Panel/Margin/HBox")
	if cards == null:
		return
	_result_cards = cards.get_child_count()
	var parts: Array[String] = []
	for card in cards.get_children():
		for lbl in _all_labels(card):
			parts.append(str(lbl.text))
	_result_text = "|".join(parts)


func _all_labels(node: Node) -> Array:
	var out: Array = []
	if node is Label:
		out.append(node)
	for c in node.get_children():
		out.append_array(_all_labels(c))
	return out


func _players_root() -> Node:
	var game = current_scene
	if game == null:
		return null
	return game.get_node_or_null("Players")


func _current_scene_file() -> String:
	var cs = current_scene
	if cs == null:
		return ""
	return str(cs.scene_file_path)


## ------------------------------------------------------------------
## 信号
## ------------------------------------------------------------------

func _on_roster(peers: Array[int]) -> void:
	_roster = peers.duplicate()


func _on_round_started(deal: Array) -> void:
	_round_started += 1


func _on_round_ended(summary: Dictionary) -> void:
	_round_ended += 1
	_summary = summary.duplicate(true)


## ------------------------------------------------------------------
## 工具
## ------------------------------------------------------------------

func _resolve_session() -> void:
	var auto_node = root.get_node_or_null("Session")
	if auto_node != null:
		_session = auto_node
	else:
		_session = SessionScript.new()
		_session.name = "Session"
		root.add_child(_session)


func _write_handoff(port: int) -> bool:
	if _handoff == "" or _handoff == "-":
		push_error("[smoke_child] 没有交接文件路径")
		return false
	var f := FileAccess.open(_handoff, FileAccess.WRITE)
	if f == null:
		push_error("[smoke_child] 交接文件打不开：%s" % _handoff)
		return false
	f.store_string("%d\n" % port)
	f.close()
	return true


func _sleep_ms(ms: int) -> void:
	await create_timer(float(ms) / 1000.0).timeout


func _report() -> void:
	_link("mode=%s" % _mode)
	_link("session_path=%s" % str(_session.get_path()))
	_link("host_err=%d" % _host_err)
	_link("join_err=%d" % _join_err)
	_link("host_port=%d" % _host_port)
	_link("is_host=%d" % (1 if _session.is_host() else 0))
	_link("peer_count=%d" % _session.peer_count())
	_link("roster=%s" % _join_ids(_session.peers()))
	_link("round_started=%d" % _round_started)
	_link("round_ended=%d" % _round_ended)
	_link("lobby_scene_path=%s" % _lobby_scene_path)
	_link("game_scene_file=%s" % _game_scene_file)
	_link("player_names=%s" % _player_names)
	_link("player_count=%d" % _player_count)
	_link("local_player_found=%d" % (1 if _local_player_found else 0))
	_link("local_hand_size=%d" % _local_hand_size)
	_link("deal_hands=%d" % _deal_hands)
	_link("card_ids=%s" % _card_ids)
	_link("finish_disabled=%d" % (1 if _finish_disabled else 0))
	_link("result_scene_file=%s" % _result_scene_file)
	_link("result_cards=%d" % _result_cards)
	_link("result_text=%s" % _result_text)
	_link("summary_players=%d" % _summary.size())
	_link("summary_pure=%d" % (1 if _is_pure_data(_summary) else 0))
	var first_key := ""
	var first: Dictionary = {}
	if _summary.size() > 0:
		for k in _summary.keys():
			first_key = str(k)
			first = _summary[k]
			break
	_link("summary_first_key=%s" % first_key)
	_link("summary_done=%s" % str(first.get("done", -1)))
	_link("summary_caught=%s" % str(first.get("caught", -1)))
	_link("summary_name=%s" % str(first.get("name", "")))
	var titles: Array = first.get("mischief_titles", [])
	var ts: Array[String] = []
	for t in titles:
		ts.append(str(t))
	_link("summary_titles=%s" % ",".join(ts))
	_link("summary_fields=%s" % ",".join(_sorted_keys(first)))
	# 绝对时刻（epoch 毫秒）：**跨进程可比**（Time.get_ticks_msec() 是进程内的）。
	var now_epoch := int(Time.get_unix_time_from_system() * 1000.0)
	_link("epoch_ms=%d" % now_epoch)
	# 计划退出时刻（epoch 毫秒）：房主要**晚于**客户端的回报时刻退出
	# （房主先退 → UDP 端口消失 → 客户端的连接被掐断）。
	var exit_in := 0
	if _mode == "host":
		exit_in = HOST_EXTRA_LIFE_MS
	_link("exit_epoch_ms=%d" % (now_epoch + exit_in))
	_link("DONE")


## 载荷是不是**纯数据**（能跨进程传：没有 Object / Resource / Callable）。
func _is_pure_data(value: Variant) -> bool:
	match typeof(value):
		TYPE_OBJECT, TYPE_CALLABLE, TYPE_SIGNAL:
			return false
		TYPE_DICTIONARY:
			for k in (value as Dictionary).keys():
				if not _is_pure_data(k):
					return false
				if not _is_pure_data((value as Dictionary)[k]):
					return false
			return true
		TYPE_ARRAY:
			for v in (value as Array):
				if not _is_pure_data(v):
					return false
			return true
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, \
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, \
		TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY:
			return true
	return true


func _sorted_keys(d: Dictionary) -> Array:
	var out: Array = d.keys()
	out.sort()
	return out


func _join_ids(ids: Array) -> String:
	var parts: Array = []
	for i in ids:
		parts.append(str(i))
	return ",".join(parts)


func _link(s: String) -> void:
	print("SMOKE|" + s)
