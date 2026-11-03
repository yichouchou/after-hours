extends SceneTree

## Task 7 修复轮 1：**双进程真实 RPC 测试**的子进程。
##
## 由父进程 tools/test_session_link.gd 用 OS.execute 拉起（修复轮 3 之后的新契约）：
##     <godot> --headless --path <proj> --quit-after 20000 \
##             --script res://tools/session_link_child.gd \
##             -- <mode> <base> <span> <handoff_path> [noise]
##
## | 位置          | 含义 |
## |---------------|------|
## | mode          | "host" / "client" / "noise" / "portprobe" |
## | base          | host：**候选起始端口**；client：**具体端口**；noise：0；portprobe：候选起始端口 |
## | span          | host：**候选个数**；client：1；noise：1；portprobe：候选个数 |
## | handoff_path  | host：**交接文件路径**；client/noise/portprobe："-" |
## | noise         | 可选标志，只有噪声探针用 |
##
## ★ **端口是动态分配的**（修复轮 3 / F3）：固定端口 = 隐含「全局只有我一个人跑」
##   的假设，而 SDD 流程里控制器的统一入口与复审子代理的测试**必然并发**
##   → 固定端口必然被抢 → 产生**假失败**。
##   → 房主按父进程给的候选序列逐个尝试，**绑定成功**才算这个端口可用。
##
## ★ **★ 端口的裁决权归「真实的服务端 socket」**：
##   **禁止「探测 → 关闭 → 盲信」** —— 探测与真实绑定之间有竞态窗口，
##   两个并发进程可能同时探测到同一个端口 → 那只是把「固定端口冲突」
##   换成了「概率性冲突」。所以这里**真的**去 bind，绑定失败就换下一个候选。
##
## ★ **★ 交接文件（handoff file）**：房主在**子进程**里，父进程必须在
##   **启动客户端之前**知道房主实际占的是哪个端口。
##   → 房主**绑定成功之后**立刻把端口号写进交接文件（一行一个整数）。
##     「文件存在」⟺「端口已被占住」→ 父进程轮询这个文件即可，
##     **不再需要 OS.delay_msec(1500) 那种魔法延迟**。
##
## 结果用 `LINK|` 开头的行写到 stdout，父进程解析。
##
## ★ **引擎的错误/告警输出保持打开**（修复轮 2 / N-A）：
##   修复轮 1 用 `Engine.print_error_messages = false` 把它们**整体压掉**了，
##   于是父进程那条「子进程零 ERROR/WARNING」断言**恒为 true**（虚假覆盖）。
##   压掉它们**不会**弄脏父进程的 stdout —— 父进程是用
##   `OS.execute(..., read_stderr=true)` **捕获**子进程的 stdout+stderr 的，不是继承。
##   修复轮 2 另加一个「噪声探针」子进程（第三个 user arg = "noise"），
##   故意打出 ERROR/WARNING，让父进程能证明那条断言**确实有检测力**。
##
## ★ **Session 实例走生产用的 autoload**（修复轮 2 / F2-3）：
##   真实对局走的是 `project.godot` 的 autoload `/root/Session`。
##   本子进程**优先**用它；拿不到才自己 new 一个并**显式命名为 "Session"**
##   （让 RPC 的节点路径与生产逐字一致）。解析结果回报给父进程
##   （`session_path=` / `session_source=`），由父进程断言路径是 `/root/Session`。
##
## ------------------------------------------------------------------
## 【房主必须比客户端活得久】（修复轮 1 的关键实测）
## ------------------------------------------------------------------
## 修复轮 1 第一版里，客户端常常在连上后 ~9 秒「掉线」。查出来的原因**不是**
## ENet 的空闲超时，而是**房主子进程先退出了**：房主进程一退出，它的 UDP 端口
## 就消失，客户端下一次收发收到 ICMP 端口不可达 → 套接字被重置 → ENet 判连接断开。
## （对照实验：原始 ENet 探针完全静默 13.7 秒也没掉线，见
##   .superpowers/.../_tmp_task7_review/probe_raw_link.gd）
## → 所以这里给房主一个**比客户端长**的寿命：房主活着，客户端才谈得上「没掉线」。
##
## 为什么要活过 8 秒：Session 的连接超时窗口是 8 秒（CONNECT_TIMEOUT_SEC）。
## 两个子进程都要活过这个窗口，才能证明「房主不会被自己的连接超时拆台」（C3）。

## ------------------------------------------------------------------
## 【回报时机：两个子进程都必须在「链路还活着」的时候回报】
## ------------------------------------------------------------------
## 修复轮 1 第一版里，房主活 10.5 秒、客户端也活 10.5 秒，但**客户端比房主晚
## 1.5 秒启动** → 客户端先退出 → 房主回报时名单已经缩回 1 人（房主看到对端
## 断开是正常现象），于是「两端名单一致」这类断言必然失败。
## → 现在把**回报时刻**和**退出时刻**分开：
##   * 房主：10 秒时**回报**（客户端还连着，名单是 2 人），14 秒才**退出**；
##   * 客户端：10.5 秒时**回报并退出**（房主还活着，连接状态是 CONNECTED）。
## 父进程断言的「房主 peer_count=2」「客户端 conn_status=2」就是这两条时序的护栏。

const SessionScript := preload("res://scripts/net/session.gd")
const PortAlloc := preload("res://tools/port_alloc.gd")

## 客户端：活到点就回报并退出（必须 > 8 秒的连接超时窗口，C3）。
const CLIENT_LIFE_MS := 10500
## 房主：活到点先回报（此时客户端还连着）。
const HOST_REPORT_MS := 10000
## 房主：回报之后再多活一会儿才退出（必须比客户端的回报时刻晚，
## 否则房主一退，客户端的连接就被掐断 —— 那正是修复轮 1 查出来的掉线真因）。
const HOST_EXIT_MS := 14000
const STEP_SEC := 0.05
## 「端口探针」模式（mode = "portprobe"）：绑定成功之后**持有端口**这么久再退出。
## 为什么要持有：让两个并发探针在时间上**确实重叠** ——
## 否则测的是「先后」而不是「并发」（先跑完的那个把端口放掉了，后一个就能白捡）。
const PROBE_HOLD_SEC := 2.0

var _mode := "host"
## 候选起始端口（host / portprobe）或具体端口（client）。
var _base := 27100
## 候选个数（host / portprobe）或 1（client）。
var _span := 1
## 交接文件路径（host 用；其它模式是 "-"）。
var _handoff := "-"
## 房主（/ 探针）**实际占住**的端口（0 = 还没占住）。
var _host_port := 0
## 端口探针的绑定结果（0 = 成功）。
var _probe_err := 0
var _session = null
## Session 实例的来源："autoload"（生产用的 /root/Session）或 "new_named"（兜底自建）。
var _session_source := ""
## Session 实例的绝对路径（父进程要断言它是 /root/Session）。
var _session_path := ""
## 噪声探针模式（mode = "noise"，或可选的第 5 个 user arg = "noise"）：
## 故意打出引擎 ERROR / WARNING。
var _noise_mode := false
var _t0 := 0

var _roster: Array[int] = []
var _deal_hands := 0
var _cards: Array = []
var _card_type := ""
var _round_started := 0
var _round_ended := 0
var _host_err := 0
var _join_err := 0
var _roster_changed_count := 0
var _roster_received_ms := 0
var _roster_cleared_ms := 0
var _conn_connected_ms := 0
var _conn_lost_ms := 0


func _initialize() -> void:
	# **刻意不压制引擎错误输出**（修复轮 2 / N-A）：
	# 父进程要靠子进程 stderr 里的 ERROR / WARNING 行，来证明「零 ERROR/WARNING」
	# 这条断言**有检测力**。整体压掉它会让那条断言恒为 true（虚假覆盖）。
	# 父进程是**捕获**（OS.execute + read_stderr=true）而不是继承子进程的输出，
	# 所以打开引擎日志不会污染父进程的 stdout。
	call_deferred("_boot")


func _boot() -> void:
	var args := OS.get_cmdline_user_args()
	# 新契约：-- <mode> <base> <span> <handoff_path> [noise]
	if args.size() >= 1:
		_mode = str(args[0])
	if args.size() >= 2:
		_base = int(args[1])
	if args.size() >= 3:
		_span = int(args[2])
	if args.size() >= 4:
		_handoff = str(args[3])
	# 噪声标志（可选的第 5 个 user arg = "noise"）→ **噪声探针模式**
	# （修复轮 2 / N-A 的反向自检）：故意打出引擎 ERROR / WARNING，
	# 父进程据此证明「零 ERROR/WARNING」断言有检测力。
	if args.size() >= 5 and str(args[4]) == "noise":
		_noise_mode = true
	# mode 本身也可以是 "noise"（父进程用这个形状拉起噪声探针）。
	if _mode == "noise":
		_noise_mode = true
	_t0 = Time.get_ticks_msec()

	_resolve_session()
	_session.set_transport(ENetTransport.new())
	_session.roster_changed.connect(_on_roster)
	_session.round_started.connect(_on_round_started)
	_session.round_ended.connect(_on_round_ended)

	if _noise_mode:
		await _run_noise()
	elif _mode == "host":
		await _run_host()
	elif _mode == "portprobe":
		await _run_portprobe()
	else:
		await _run_client()
	_report()
	# 房主回报之后还要再活一会儿（见文件头）：客户端的回报时刻在房主退出之前。
	if _mode == "host" and not _noise_mode:
		while Time.get_ticks_msec() < _t0 + HOST_EXIT_MS:
			await create_timer(0.1).timeout
	quit(0)


## 解析要用的 Session 实例（修复轮 2 / F2-3）。
##
## **优先用生产用的 autoload**（`/root/Session`）—— 双进程测试必须走生产路径，
## 否则「autoload 路径两端一致」这句话永远没被实测过。
## `--script` 模式下 autoload **确实存在**（修复轮 2 实测，证据见 task-7-report.md §3.3）。
##
## 兜底：autoload 拿不到时自己 new 一个，并**显式命名为 "Session"** 再 add_child，
## 这样 RPC 的节点路径与生产**逐字一致**（`/root/Session`）。
func _resolve_session() -> void:
	var auto_node = root.get_node_or_null("Session")
	if auto_node != null:
		_session = auto_node
		_session_source = "autoload"
	else:
		_session = SessionScript.new()
		_session.name = "Session"
		root.add_child(_session)
		_session_source = "new_named"
	_session_path = str(_session.get_path())


## 噪声探针（修复轮 2 / N-A 的反向自检）。
##
## 故意用引擎的 `push_error` / `push_warning` 打出 ERROR / WARNING 行，
## 然后短暂停留（1.5 秒）让输出稳定刷出来，最后**正常退出**（退出码 0）。
## 父进程据此断言：这些行**确实**会让「零 ERROR/WARNING」那条断言判失败
## —— 证明那条断言有检测力，而不是恒真。
func _run_noise() -> void:
	push_error("SELFTEST_ENGINE_NOISE")
	push_warning("SELFTEST_ENGINE_WARNING")
	await create_timer(1.5).timeout


func _run_host() -> void:
	# ★ 真实绑定裁决：按候选序列逐个尝试，**绑定成功**才算这个端口可用。
	#   绑定失败 = 这个端口被别人占着 → 换下一个候选。
	#   候选全部失败 → 报告**最后一个**错误码，**不写交接文件**，正常退出。
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
			# 写失败 → 报告错误并退出（父进程会因等不到交接文件而判失败）。
			_host_err = ERR_FILE_CANT_OPEN
			return
		break
	if _host_port == 0:
		# 候选全部失败 → 不写交接文件，回报最后一个错误码。
		_host_err = last_err
		return
	# 先 host 成功，再挂到 MultiplayerAPI（attach_to 在没有 peer 时是空操作）
	_session.apply_to_multiplayer()
	var deadline := _t0 + HOST_REPORT_MS
	# 等客户端连进来（名单由房主广播）
	while _session.peer_count() < 2 and Time.get_ticks_msec() < deadline:
		await create_timer(STEP_SEC).timeout
		_track_conn()
	# 让名单广播稳下来
	await create_timer(0.6).timeout
	_session.start_round()
	# 活过 8 秒的连接超时窗口：房主必须还健在
	while Time.get_ticks_msec() < deadline:
		await create_timer(0.1).timeout
		_track_conn()


## 「端口探针」模式（mode = "portprobe"）：取候选 → **真实绑定** → 回报端口号。
##
## 存在的理由：tools/test_port_alloc.gd 的 A3 要证明
## 「两个并发进程拿到**不同**的端口」。
## → 两个探针**从同一个候选开始**（父进程给同一个 base/span），
##   它们就会**真的抢同一个端口** → 输的那个必须换下一个候选。
##   这正是「真实绑定裁决」跨进程成立的直接证据。
## → 绑定成功之后**持有端口** PROBE_HOLD_SEC 再退出，
##   保证两个探针在时间上**确实重叠**。
func _run_portprobe() -> void:
	var alloc := PortAlloc.new(_base, maxi(_span, 1), 0)
	while not alloc.exhausted():
		var p: int = alloc.next()
		if p < 0:
			break
		var t := ENetTransport.new()
		Engine.print_error_messages = false
		var e: Error = t.host(p, 1)
		Engine.print_error_messages = true
		if e != OK:
			# 绑定失败 = 端口被别人占着 → 换下一个候选。
			continue
		_host_port = p
		_probe_err = 0
		# 持有端口一段时间 → 两个探针真正并发地各占一个端口。
		await create_timer(PROBE_HOLD_SEC).timeout
		return
	_probe_err = ERR_CANT_CREATE


## 把实际占住的端口写进**交接文件**（父进程据此知道该连哪个端口）。
##
## ★ 必须在**绑定成功之后**写 → 「文件存在」⟺「端口已被占住」。
## ★ 写失败（目录不存在 / 权限）→ 返回 false，让调用方**明确失败**。
func _write_handoff(port: int) -> bool:
	if _handoff == "" or _handoff == "-":
		push_error("[link_child] 没有交接文件路径")
		return false
	var f := FileAccess.open(_handoff, FileAccess.WRITE)
	if f == null:
		push_error("[link_child] 交接文件打不开：%s" % _handoff)
		return false
	f.store_string("%d\n" % port)
	f.close()
	return true


func _run_client() -> void:
	# ★ base 就是**具体端口**，span = 1：**只连这一个端口**。
	#   **不允许**在连不上时换端口（那会连到别人的服务器）。
	_join_err = _session.join_game("127.0.0.1", _base)
	if _join_err != OK:
		return
	_session.apply_to_multiplayer()
	var deadline := _t0 + CLIENT_LIFE_MS
	# 等房主广播的名单
	while _session.peer_count() < 2 and Time.get_ticks_msec() < deadline:
		await create_timer(STEP_SEC).timeout
		_track_conn()
	# 等房主定向发来的那一份清单
	while _round_started == 0 and Time.get_ticks_msec() < deadline:
		await create_timer(STEP_SEC).timeout
		_track_conn()
	# 活过 8 秒的连接超时窗口：客户端必须还连着
	while Time.get_ticks_msec() < deadline:
		await create_timer(0.1).timeout
		_track_conn()


func _on_roster(peers: Array[int]) -> void:
	_roster = peers.duplicate()
	_roster_changed_count += 1
	if peers.is_empty():
		if _roster_cleared_ms == 0:
			_roster_cleared_ms = Time.get_ticks_msec() - _t0
		return
	if _roster_received_ms == 0:
		_roster_received_ms = Time.get_ticks_msec() - _t0


func _on_round_started(deal: Array) -> void:
	_round_started += 1
	_deal_hands = deal.size()
	_cards = []
	_card_type = ""
	if deal.size() > 0:
		var hand: Array = deal[0]
		if hand.size() > 0:
			var c = hand[0]
			_card_type = "%d/%s" % [typeof(c), _script_name(c)]
			_cards = hand.duplicate()


func _on_round_ended(_summary: Dictionary) -> void:
	_round_ended += 1


func _report() -> void:
	var t: Variant = _session.get("_transport")
	_link("mode=%s" % _mode)
	# F2-3：Session 实例的**绝对路径**与**来源**（父进程据此断言路径是 /root/Session）
	_link("session_path=%s" % _session_path)
	_link("session_source=%s" % _session_source)
	_link("host_err=%d" % _host_err)
	_link("join_err=%d" % _join_err)
	# ★ 房主（/ 探针）**实际占住**的端口。
	#   父进程要拿它和交接文件里的端口**交叉核对**（防交接文件写错）。
	_link("host_port=%d" % _host_port)
	_link("probe_err=%d" % _probe_err)
	_link("is_host=%d" % (1 if _session.is_host() else 0))
	_link("peer_count=%d" % _session.peer_count())
	_link("roster=%s" % _join_ids(_session.peers()))
	_link("outbox=%d" % _session.get("_outbox").size())
	_link("pending=%d" % _session.get("_pending").size())
	_link("outbox_methods=%s" % _outbox_methods())
	_link("roster_changed_count=%d" % _roster_changed_count)
	_link("roster_received_ms=%d" % _roster_received_ms)
	_link("roster_cleared_ms=%d" % _roster_cleared_ms)
	_link("conn_connected_ms=%d" % _conn_connected_ms)
	_link("conn_lost_ms=%d" % _conn_lost_ms)
	_link("transport_null=%d" % (1 if t == null else 0))
	_link("conn_status=%d" % _conn_status())
	_link("round_started=%d" % _round_started)
	_link("round_ended=%d" % _round_ended)
	_link("deal_hands=%d" % _deal_hands)
	_link("cards=%d" % _cards.size())
	if _cards.size() > 0:
		var c = _cards[0]
		_link("card_type=%s" % _card_type)
		_link("card_id=%s" % str(c.get("id")))
		_link("card_title_len=%d" % str(c.get("title")).length())
		_link("card_category=%s" % str(c.get("category")))
		_link("card_target_tag=%s" % str(c.get("target_tag")))
		_link("card_needs_partner=%s" % str(c.get("needs_partner")))
		_link("card_duration=%s" % str(c.get("duration")))
		_link("card_points=%s" % str(c.get("points")))
		_link("card_ids=%s" % _join_ids(_hand_ids(_cards)))
	if _mode == "host":
		var deal_now: Array = _session.deal()
		var own: Array = deal_now[0] if deal_now.size() > 0 else []
		_link("own_hand_ids=%s" % _join_ids(_hand_ids(own)))
		var client_pid := 0
		for pid in _session.peers():
			if pid != 1:
				client_pid = pid
		_link("client_hand_ids=%s" % _join_ids(_hand_ids(_session.deal_for_peer(client_pid))))
	_link("alive_ms=%d" % (Time.get_ticks_msec() - _t0))
	# 绝对时刻（epoch 毫秒）：**跨进程可比**（Time.get_ticks_msec() 是进程内的）。
	# 父进程用它验证「房主的退出时刻晚于客户端的回报时刻」——
	# 房主先退会把客户端的连接掐断（修复轮 1 查出来的掉线真因）。
	var now_epoch := int(Time.get_unix_time_from_system() * 1000.0)
	_link("epoch_ms=%d" % now_epoch)
	var exit_in := 0
	if _mode == "host":
		exit_in = HOST_EXIT_MS - (Time.get_ticks_msec() - _t0)
	_link("exit_epoch_ms=%d" % (now_epoch + maxi(exit_in, 0)))
	_link("DONE")


func _track_conn() -> void:
	var t: Variant = _session.get("_transport")
	if t == null:
		return
	var p = t.get_peer()
	if p == null:
		return
	var st := int(p.get_connection_status())
	if st == MultiplayerPeer.CONNECTION_CONNECTED and _conn_connected_ms == 0:
		_conn_connected_ms = Time.get_ticks_msec() - _t0
	if _conn_connected_ms != 0 and st == MultiplayerPeer.CONNECTION_DISCONNECTED \
			and _conn_lost_ms == 0:
		_conn_lost_ms = Time.get_ticks_msec() - _t0


func _conn_status() -> int:
	var t = _session.get("_transport")
	if t == null:
		return -1
	var p = t.get_peer()
	if p == null:
		return -2
	return int(p.get_connection_status())


## 对象的脚本名（用来证明客户端收到的是重建出来的 Mischief 对象，
## 而不是跨进程编码出来的 EncodedObjectAsID 占位符）。
func _script_name(obj) -> String:
	var sc = obj.get_script()
	if sc == null:
		return obj.get_class()
	var n := String(sc.get_global_name())
	return n if n != "" else obj.get_class()


func _outbox_methods() -> String:
	var parts: Array = []
	for msg in _session.get("_outbox"):
		var d: Dictionary = msg
		parts.append("%s@%d" % [String(d["method"]), int(d["peer"])])
	return ",".join(parts)


func _hand_ids(hand: Array) -> Array:
	var out: Array = []
	for m in hand:
		out.append(str(m.get("id")))
	return out


func _join_ids(ids: Array) -> String:
	var parts: Array = []
	for i in ids:
		parts.append(str(i))
	return ",".join(parts)


func _link(s: String) -> void:
	print("LINK|" + s)
